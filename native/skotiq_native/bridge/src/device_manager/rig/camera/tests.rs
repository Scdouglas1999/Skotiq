use super::*;
use crate::device_manager::rig::camera::driver::DriverCamera;
use skotiq_device::{
    CameraCapabilities, CameraDriver, CameraState, DeviceDriver, DriverError, ExposureAbort,
    ExposureParams, ImageMetadata, ReadoutMode, SensorInfo, VendorFeatures,
};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

type Calls = Arc<Mutex<Vec<&'static str>>>;

struct GiveUp(AtomicBool);

impl ExposureAbort for GiveUp {
    fn request(&self) {
        self.0.store(true, Ordering::Release);
    }
}

/// A vendor camera whose frame read takes `read_takes`. With `gives_up` the
/// read checks for an abort request every 10 ms, as a driver that polls its
/// SDK for the frame does.
#[derive(Debug)]
struct SlowCamera {
    calls: Calls,
    read_takes: Duration,
    gives_up: bool,
    give_up: Arc<GiveUp>,
    connected: bool,
}

impl std::fmt::Debug for GiveUp {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("GiveUp")
    }
}

impl SlowCamera {
    fn new(read_takes: Duration, gives_up: bool) -> (Self, Calls) {
        let calls: Calls = Default::default();
        (
            Self {
                calls: calls.clone(),
                read_takes,
                gives_up,
                give_up: Arc::new(GiveUp(AtomicBool::new(false))),
                connected: true,
            },
            calls,
        )
    }

    fn saw(&self, call: &'static str) {
        self.calls.lock().expect("lock calls").push(call);
    }
}

#[async_trait]
impl DeviceDriver for SlowCamera {
    fn id(&self) -> &str {
        "native:test:slow"
    }
    fn name(&self) -> &str {
        "Slow Camera"
    }
    fn vendor(&self) -> skotiq_device::Vendor {
        skotiq_device::Vendor::Other("Test".to_string())
    }
    fn is_connected(&self) -> bool {
        self.connected
    }
    async fn connect(&mut self) -> Result<(), DriverError> {
        Ok(())
    }
    async fn disconnect(&mut self) -> Result<(), DriverError> {
        self.saw("disconnect");
        self.connected = false;
        Ok(())
    }
}

#[async_trait]
impl CameraDriver for SlowCamera {
    fn capabilities(&self) -> CameraCapabilities {
        CameraCapabilities::default()
    }
    fn exposure_abort(&self) -> Option<Arc<dyn ExposureAbort>> {
        self.gives_up
            .then(|| self.give_up.clone() as Arc<dyn ExposureAbort>)
    }
    async fn get_status(&self) -> Result<skotiq_device::CameraStatus, DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }
        Ok(skotiq_device::CameraStatus {
            state: CameraState::Idle,
            sensor_temp: None,
            cooler_power: None,
            target_temp: None,
            cooler_on: None,
            gain: 0,
            offset: 0,
            bin_x: 1,
            bin_y: 1,
            exposure_remaining: None,
        })
    }
    async fn start_exposure(&mut self, _params: ExposureParams) -> Result<(), DriverError> {
        self.saw("start_exposure");
        self.give_up.0.store(false, Ordering::Release);
        Ok(())
    }
    async fn abort_exposure(&mut self) -> Result<(), DriverError> {
        self.saw("abort_exposure");
        Ok(())
    }
    async fn is_exposure_complete(&self) -> Result<bool, DriverError> {
        Ok(true)
    }
    async fn download_image(&mut self) -> Result<ImageData, DriverError> {
        self.saw("download_image");
        let until = Instant::now() + self.read_takes;
        while Instant::now() < until {
            if self.gives_up && self.give_up.0.load(Ordering::Acquire) {
                self.saw("read given up");
                return Err(DriverError::Unknown("given up".to_string()));
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        self.saw("frame read");
        Ok(ImageData {
            width: 2,
            height: 1,
            data: vec![1, 2],
            bits_per_pixel: 16,
            bayer_pattern: None,
            metadata: ImageMetadata {
                exposure_time: 1.0,
                gain: 0,
                offset: 0,
                bin_x: 1,
                bin_y: 1,
                temperature: None,
                timestamp: chrono::Utc::now(),
                subframe: None,
                readout_mode: None,
                vendor_data: VendorFeatures::default(),
                camera_file: None,
            },
        })
    }
    async fn set_cooler(
        &mut self,
        _enabled: bool,
        _target: Option<f64>,
    ) -> Result<(), DriverError> {
        Ok(())
    }
    async fn get_temperature(&self) -> Result<f64, DriverError> {
        Err(DriverError::NotSupported)
    }
    async fn get_cooler_power(&self) -> Result<f64, DriverError> {
        Err(DriverError::NotSupported)
    }
    async fn set_gain(&mut self, _gain: i32) -> Result<(), DriverError> {
        Ok(())
    }
    async fn get_gain(&self) -> Result<i32, DriverError> {
        Ok(0)
    }
    async fn set_offset(&mut self, _offset: i32) -> Result<(), DriverError> {
        Ok(())
    }
    async fn get_offset(&self) -> Result<i32, DriverError> {
        Ok(0)
    }
    async fn set_binning(&mut self, _bin_x: i32, _bin_y: i32) -> Result<(), DriverError> {
        Ok(())
    }
    async fn get_binning(&self) -> Result<(i32, i32), DriverError> {
        Ok((1, 1))
    }
    async fn set_subframe(&mut self, _subframe: Option<SubFrame>) -> Result<(), DriverError> {
        Ok(())
    }
    fn get_sensor_info(&self) -> SensorInfo {
        SensorInfo::default()
    }
    async fn get_readout_modes(&self) -> Result<Vec<ReadoutMode>, DriverError> {
        Ok(Vec::new())
    }
    async fn set_readout_mode(&mut self, _mode: &ReadoutMode) -> Result<(), DriverError> {
        Ok(())
    }
    async fn get_vendor_features(&self) -> Result<VendorFeatures, DriverError> {
        Ok(VendorFeatures::default())
    }
    async fn get_gain_range(&self) -> Result<(i32, i32), DriverError> {
        Err(DriverError::NotSupported)
    }
    async fn get_offset_range(&self) -> Result<(i32, i32), DriverError> {
        Err(DriverError::NotSupported)
    }
}

fn vendor_camera(read_takes: Duration, gives_up: bool) -> (Arc<dyn Camera>, Calls) {
    let (driver, calls) = SlowCamera::new(read_takes, gives_up);
    (
        Arc::new(DriverCamera::vendor("native:test:slow", Box::new(driver))),
        calls,
    )
}

fn calls(calls: &Calls) -> Vec<&'static str> {
    calls.lock().expect("lock calls").clone()
}

/// The download's caller is answered when the abort is asked for, not when
/// the driver's frame read ends; the camera gets its stop command after the
/// read it could not interrupt, and the frame goes nowhere.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_abort_answers_the_download_while_the_frame_is_still_being_read() {
    let (camera, seen) = vendor_camera(Duration::from_millis(1500), false);
    let downloading = tokio::spawn({
        let camera = camera.clone();
        async move { download(camera.as_ref(), "native:test:slow").await }
    });
    tokio::time::sleep(Duration::from_millis(150)).await;

    let asked = Instant::now();
    let aborting = tokio::spawn({
        let camera = camera.clone();
        async move { abort(camera.as_ref()).await }
    });
    let answer = downloading.await.expect("download task");
    assert!(
        asked.elapsed() < Duration::from_millis(300),
        "the download waited {:?} for the frame read",
        asked.elapsed()
    );
    let error = answer
        .expect_err("an aborted exposure has no frame")
        .to_string();
    assert!(error.contains("aborted"), "{error}");

    aborting.await.expect("abort task").expect("abort");
    assert_eq!(
        calls(&seen),
        ["download_image", "frame read", "abort_exposure"],
        "the stop command follows the read in flight"
    );
}

/// A driver whose read polls for the frame ends it at the abort request, so
/// the camera is stopped and free for the next exposure at once.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_read_that_can_be_given_up_ends_at_the_abort() {
    let (camera, seen) = vendor_camera(Duration::from_secs(20), true);
    let downloading = tokio::spawn({
        let camera = camera.clone();
        async move { download(camera.as_ref(), "native:test:slow").await }
    });
    tokio::time::sleep(Duration::from_millis(150)).await;

    let asked = Instant::now();
    abort(camera.as_ref()).await.expect("abort");
    assert!(
        asked.elapsed() < Duration::from_millis(500),
        "the abort waited {:?} behind the frame read",
        asked.elapsed()
    );
    assert!(downloading.await.expect("download task").is_err());
    assert_eq!(
        calls(&seen),
        ["download_image", "read given up", "abort_exposure"]
    );

    // The next exposure is not aborted by the last one's request.
    camera
        .start_exposure(0.1, None, None, 1, 1, None, skotiq_device::FrameType::Light)
        .await
        .expect("start");
}

/// An abort with no download in flight does not poison the next download.
#[tokio::test]
async fn a_download_after_an_abort_reads_its_frame() {
    let (camera, _) = vendor_camera(Duration::from_millis(20), false);
    abort(camera.as_ref()).await.expect("abort");
    let frame = download(camera.as_ref(), "native:test:slow")
        .await
        .expect("frame");
    assert_eq!(frame.data, [1, 2]);
}

/// One camera's frame read holds up nothing of another camera: a guide
/// camera exposes, reads its frame and answers status while the imaging
/// camera is still downloading.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_second_camera_works_while_the_first_reads_its_frame() {
    let (imaging, _) = vendor_camera(Duration::from_millis(1500), false);
    let (guide, guide_seen) = vendor_camera(Duration::from_millis(20), false);
    let downloading = tokio::spawn({
        let camera = imaging.clone();
        async move { download(camera.as_ref(), "native:test:slow").await }
    });
    tokio::time::sleep(Duration::from_millis(100)).await;

    let started = Instant::now();
    guide
        .start_exposure(0.1, None, None, 1, 1, None, skotiq_device::FrameType::Light)
        .await
        .expect("guide exposure");
    guide.status().await.expect("guide status");
    download(guide.as_ref(), "native:test:guide")
        .await
        .expect("guide frame");
    assert!(
        started.elapsed() < Duration::from_millis(500),
        "the guide camera waited {:?}",
        started.elapsed()
    );
    assert!(
        !downloading.is_finished(),
        "the imaging read is still going"
    );
    assert_eq!(
        calls(&guide_seen),
        ["start_exposure", "download_image", "frame read"]
    );
    downloading
        .await
        .expect("download task")
        .expect("imaging frame");
}

/// A disconnect goes through behind the read in flight; what follows on a
/// handle someone still holds is the driver's own not-connected answer.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_disconnect_during_a_frame_read_closes_the_camera_after_it() {
    let (camera, seen) = vendor_camera(Duration::from_millis(400), false);
    let downloading = tokio::spawn({
        let camera = camera.clone();
        async move { download(camera.as_ref(), "native:test:slow").await }
    });
    tokio::time::sleep(Duration::from_millis(100)).await;
    camera.disconnect().await.expect("disconnect");
    assert_eq!(calls(&seen), ["download_image", "frame read", "disconnect"]);
    downloading
        .await
        .expect("download task")
        .expect("the read in flight finished");
    let error = camera.status().await.expect_err("closed");
    assert!(
        matches!(error, DeviceOpError::NotConnected { .. }),
        "{error:?}"
    );
}
