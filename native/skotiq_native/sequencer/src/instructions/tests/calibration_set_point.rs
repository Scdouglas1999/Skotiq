//! Darks, bias and dark flats are taken at the cooler's set-point, reached
//! from either side, against a simulated cooled camera whose sensor moves
//! toward its set-point over time.

use super::*;
use crate::executor::{RunConfig, RunConfigStore};
use crate::scheduling::FrameContext;

/// A TEC camera in simulated time: with the cooler on the sensor is pulled
/// toward its set-point (never warmer than the air around it, a TEC cannot
/// heat), with it off it drifts to ambient. Pulling down is quicker than the
/// passive warm-up, as on real hardware.
struct SimCooledCamera {
    inner: Arc<NullDeviceOps>,
    thermal: Mutex<Thermal>,
    /// Sensor temperature as each exposure started.
    exposure_temps: Mutex<Vec<f64>>,
    /// `(CCD-TEMP, SET-TEMP)` of every frame written.
    saved: Mutex<Vec<(Option<f64>, Option<f64>)>>,
}

struct Thermal {
    sensor_c: f64,
    ambient_c: f64,
    cooler: Option<f64>,
    at: tokio::time::Instant,
}

const COOL_RATE_C_PER_SEC: f64 = 0.5;
const WARM_RATE_C_PER_SEC: f64 = 0.1;

impl SimCooledCamera {
    fn new(sensor_c: f64, ambient_c: f64, cooler: Option<f64>) -> Self {
        Self {
            inner: Arc::new(NullDeviceOps),
            thermal: Mutex::new(Thermal {
                sensor_c,
                ambient_c,
                cooler,
                at: tokio::time::Instant::now(),
            }),
            exposure_temps: Mutex::new(Vec::new()),
            saved: Mutex::new(Vec::new()),
        }
    }

    fn sensor_now(&self) -> f64 {
        let mut t = self.thermal.lock().unwrap();
        let now = tokio::time::Instant::now();
        let secs = now.duration_since(t.at).as_secs_f64();
        t.at = now;
        let goal = t.cooler.map_or(t.ambient_c, |set| set.min(t.ambient_c));
        let rate = if goal < t.sensor_c {
            COOL_RATE_C_PER_SEC
        } else {
            WARM_RATE_C_PER_SEC
        };
        let step = rate * secs;
        t.sensor_c = if (goal - t.sensor_c).abs() <= step {
            goal
        } else {
            t.sensor_c + step * (goal - t.sensor_c).signum()
        };
        t.sensor_c
    }
}

crate::forward_device_ops!(SimCooledCamera => inner: MountOps, FocuserOps, FilterWheelOps, RotatorOps, GuiderOps, DomeOps, CoverCalibratorOps, SafetyOps, PlateSolveOps, OperatorNotifyOps, ConnectionOps, SiteOps);

#[async_trait]
impl CameraOps for SimCooledCamera {
    async fn camera_start_exposure(&self, request: ExposureRequest<'_>) -> DeviceResult<ImageData> {
        self.exposure_temps.lock().unwrap().push(self.sensor_now());
        tokio::time::sleep(Duration::from_secs_f64(request.duration_secs)).await;
        Ok(ImageData {
            width: 16,
            height: 16,
            data: vec![500; 256],
            bits_per_pixel: 16,
            exposure_secs: request.duration_secs,
            gain: request.gain,
            offset: request.offset,
            temperature: Some(self.sensor_now()),
            filter: None,
            timestamp: chrono::Utc::now().timestamp(),
            sensor_type: Some("Monochrome".to_string()),
            color_filter: None,
            camera_file: None,
            readout_mode: None,
        })
    }
    async fn camera_abort_exposure(&self, _id: &str) -> DeviceResult<()> {
        Ok(())
    }
    async fn camera_set_cooler(&self, _id: &str, enabled: bool, target: f64) -> DeviceResult<()> {
        self.sensor_now();
        self.thermal.lock().unwrap().cooler = enabled.then_some(target);
        Ok(())
    }
    async fn camera_get_temperature(&self, _id: &str) -> DeviceResult<f64> {
        Ok(self.sensor_now())
    }
    async fn camera_get_cooler_power(&self, _id: &str) -> DeviceResult<f64> {
        let sensor = self.sensor_now();
        let t = self.thermal.lock().unwrap();
        Ok(match t.cooler {
            Some(set) if sensor > set - SETPOINT_TOLERANCE_C => 60.0,
            _ => 0.0,
        })
    }
    async fn camera_get_cooler_on(&self, _id: &str) -> DeviceResult<Option<bool>> {
        Ok(Some(self.thermal.lock().unwrap().cooler.is_some()))
    }
    async fn camera_get_cooler_setpoint(&self, _id: &str) -> DeviceResult<Option<f64>> {
        Ok(self.thermal.lock().unwrap().cooler)
    }
}

#[async_trait]
impl FrameStoreOps for SimCooledCamera {
    async fn save_fits(
        &self,
        _image: &ImageData,
        _path: &str,
        frame_ctx: &FrameContext,
    ) -> DeviceResult<()> {
        self.saved
            .lock()
            .unwrap()
            .push((frame_ctx.sensor_temp_c, frame_ctx.set_temp_c));
        Ok(())
    }
    fn frame_file_extension(&self) -> &'static str {
        self.inner.frame_file_extension()
    }
    async fn measure_light_frame(&self, image: &ImageData) -> DeviceResult<LightFrameMeasurement> {
        self.inner.measure_light_frame(image).await
    }
}

/// The dark library's tolerance as the operator set it.
const TOLERANCE_C: f64 = 2.0;

async fn calibration_ctx(
    camera: Arc<SimCooledCamera>,
    scratch: &ScratchDir,
) -> crate::node::context::ExecutionContext {
    let mut ec = expose_node_execution_ctx(camera, scratch.0.clone()).await;
    ec.run.rig.filterwheel_id = None;
    ec.run.settings = Some(RunConfigStore::new(RunConfig {
        calibration_temperature_tolerance_c: Some(TOLERANCE_C),
        ..RunConfig::default()
    }));
    ec
}

async fn cool_to(
    set_point_c: f64,
    minutes: f64,
    ec: &mut crate::node::context::ExecutionContext,
) -> NodeStatus {
    let node_type = NodeType::CoolCamera(CoolConfig {
        target_temp: set_point_c,
        duration_mins: Some(minutes),
    });
    crate::node::instructions::cool_camera::CoolCameraInstruction
        .execute("cool", &node_type, ec)
        .await
}

fn calibration_frames(frame_type: FrameType, count: u32) -> ExposureConfig {
    ExposureConfig {
        frame_type,
        duration_secs: 3.0,
        count,
        ..Default::default()
    }
}

/// End-of-night calibration reaches its warm block with the camera still at
/// the night's -10 °C. Cooling to the warmer 1 °C set-point is done at once
/// (the sensor is colder), but the darks wait for the sensor to warm up to
/// 1 °C and every one is taken there, recorded at the temperature it was
/// taken at under the set-point it was taken for.
#[tokio::test(start_paused = true)]
async fn darks_for_a_warmer_set_point_wait_for_the_sensor_to_warm_to_it() {
    let scratch = scratch_dir("warm-block");
    let camera = Arc::new(SimCooledCamera::new(-10.0, 12.0, Some(-10.0)));
    let mut ec = calibration_ctx(camera.clone(), &scratch).await;

    assert_eq!(cool_to(1.0, 15.0, &mut ec).await, NodeStatus::Success);
    let status = run_expose_node(calibration_frames(FrameType::Dark, 4), &mut ec).await;

    assert_eq!(status, NodeStatus::Success);
    let temps = camera.exposure_temps.lock().unwrap().clone();
    assert_eq!(temps.len(), 4, "every dark is taken: {temps:?}");
    assert!(
        temps.iter().all(|t| (t - 1.0).abs() <= TOLERANCE_C),
        "each dark starts within {TOLERANCE_C} °C of the 1 °C set-point: {temps:?}"
    );
    for (ccd, set) in camera.saved.lock().unwrap().iter() {
        assert_eq!(*set, Some(1.0));
        assert!(
            ccd.is_some_and(|c| (c - 1.0).abs() <= TOLERANCE_C),
            "CCD-TEMP {ccd:?}"
        );
    }
}

/// On a night colder than the set-point the sensor cannot warm up to it.
/// Its darks are skipped with a notice once the time given to the cooler is
/// up, none taken at the wrong temperature, and the bias at the same
/// set-point is skipped at once rather than waiting all over again.
#[tokio::test(start_paused = true)]
async fn calibration_frames_at_a_set_point_the_sensor_cannot_reach_are_skipped() {
    let scratch = scratch_dir("unreachable-block");
    let camera = Arc::new(SimCooledCamera::new(-10.0, -6.0, Some(-10.0)));
    let mut ec = calibration_ctx(camera.clone(), &scratch).await;
    let (events, mut rx) = tokio::sync::broadcast::channel(64);
    ec.run.event_tx = Some(events);

    assert_eq!(cool_to(1.0, 5.0, &mut ec).await, NodeStatus::Success);
    let started = tokio::time::Instant::now();
    let darks = run_expose_node(calibration_frames(FrameType::Dark, 4), &mut ec).await;
    let darks_waited = started.elapsed();
    let bias_started = tokio::time::Instant::now();
    let bias = run_expose_node(calibration_frames(FrameType::Bias, 4), &mut ec).await;

    assert_eq!(darks, NodeStatus::Skipped);
    assert_eq!(bias, NodeStatus::Skipped);
    assert!(
        camera.exposure_temps.lock().unwrap().is_empty(),
        "no frame is taken off its set-point"
    );
    assert!(
        darks_waited <= Duration::from_secs(5 * 60 + 15),
        "the darks wait no longer than the cooler was given: {darks_waited:?}"
    );
    assert!(
        bias_started.elapsed() < Duration::from_secs(1),
        "the bias does not wait again: {:?}",
        bias_started.elapsed()
    );
    let mut notices = Vec::new();
    while let Ok(event) = rx.try_recv() {
        if let crate::executor::ExecutorEvent::NoticedWarning { message, .. } = event {
            notices.push(message);
        }
    }
    assert!(
        notices
            .iter()
            .any(|m| m.contains("0 of 4 dark frames at 1.0°C") && m.contains("-6.0°C")),
        "the operator is told why the darks were skipped: {notices:?}"
    );
}

/// Lights keep the cooling rule: colder than the set-point is fine, so a
/// light after a cool step on a cold night is not held.
#[tokio::test(start_paused = true)]
async fn a_light_after_cooling_is_not_held_for_a_warmer_set_point() {
    let scratch = scratch_dir("light-colder");
    let camera = Arc::new(SimCooledCamera::new(-14.0, -14.0, None));
    let mut ec = calibration_ctx(camera.clone(), &scratch).await;

    assert_eq!(cool_to(-10.0, 15.0, &mut ec).await, NodeStatus::Success);
    let started = tokio::time::Instant::now();
    let status = run_expose_node(calibration_frames(FrameType::Light, 1), &mut ec).await;

    assert_eq!(status, NodeStatus::Success);
    assert_eq!(camera.exposure_temps.lock().unwrap().len(), 1);
    assert!(started.elapsed() < Duration::from_secs(10));
}
