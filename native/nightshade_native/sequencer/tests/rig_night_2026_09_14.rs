//! The 2026-09-14 failure chain, replayed through a whole executor on the
//! night's own frames.
//!
//! What the rig did (Rust log `nightshade.log.2026-09-15`, PHD2 guide log
//! `PHD2_GuideLog_2026-09-14_205309.txt`, both copied read-only from the
//! laptop): an HFR-trigger autofocus stopped PHD2 at 02:56:34 UTC; its cleanup
//! asked PHD2 to guide at 02:58:39.99 and gave up 30 ms later with "CRITICAL
//! CLEANUP FAILURE: guider accepted resume but did not report guiding". PHD2
//! logged "Guiding Begins" at 22:58:49 local, nine seconds after the request.
//! The run went on exposing, three 180 s lights were rejected in a row, and
//! recovery parked the mount on an "unattended" guess while the owner sat at
//! it. PHD2's lost-star readings (SNR 117 -> 18, offsets past 50 px) start at
//! 23:01:49 local, with that park, not before it.
//!
//! The lights here are the real rejected frames (1024x1024 center crops, see
//! `test-fixtures/rig-2026-09-14/manifest.json`), graded with the same
//! measurements the app grades with and the thresholds the rig ran under.
//! Their stars really are trailed: an independent PSF fit gives eccentricity
//! 0.82-0.98, so on this rig trailing went on while PHD2 reported a lock.
//!
//! One autofocus at a time per process, so these share a lock.

use async_trait::async_trait;
use nightshade_sequencer::quality::ImageQualityCheck;
use nightshade_sequencer::{
    AutofocusConfig, DeviceOps, DeviceResult, ExecutorEvent, ExecutorState, GuidingStatus,
    ImageData, NodeDefinition, NodeType, NullDeviceOps, PlateSolveResult, SequenceDefinition,
    SequenceExecutor,
};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

static SERIAL: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// What PHD2 is doing.
#[derive(Clone, Copy)]
enum Guider {
    Guiding,
    Stopped,
    /// Asked to guide at this instant.
    Resuming(std::time::Instant),
}

struct ReplayRig {
    inner: NullDeviceOps,
    calls: Mutex<Vec<String>>,
    guider: Mutex<Guider>,
    /// How long after a guide request PHD2 reports guiding; `None` never.
    lock_after: Option<Duration>,
    focuser_read_ms: std::sync::atomic::AtomicU64,
    lights: Vec<ImageData>,
    lights_taken: AtomicUsize,
    focused: ImageData,
}

impl ReplayRig {
    fn new(lock_after: Option<Duration>) -> Self {
        Self {
            inner: NullDeviceOps,
            calls: Mutex::new(Vec::new()),
            guider: Mutex::new(Guider::Guiding),
            lock_after,
            focuser_read_ms: std::sync::atomic::AtomicU64::new(0),
            lights: [
                "trailed_Ha_0001_001.fits",
                "trailed_SII_0001_001.fits",
                "trailed_OIII_0001.fits",
            ]
            .iter()
            .map(|name| fixture(name))
            .collect(),
            lights_taken: AtomicUsize::new(0),
            focused: fixture("focused_L_0005.fits"),
        }
    }

    fn is_guiding(&self) -> bool {
        match *self.guider.lock().unwrap() {
            Guider::Guiding => true,
            Guider::Stopped => false,
            Guider::Resuming(asked) => self
                .lock_after
                .is_some_and(|after| asked.elapsed() >= after),
        }
    }

    fn record(&self, call: impl Into<String>) {
        self.calls.lock().unwrap().push(call.into());
    }

    fn calls(&self) -> Vec<String> {
        self.calls.lock().unwrap().clone()
    }
}

fn fixture(name: &str) -> ImageData {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../test-fixtures/rig-2026-09-14")
        .join(name);
    let (image, _) =
        nightshade_imaging::read_fits(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    ImageData {
        width: image.width,
        height: image.height,
        data: image.as_u16().expect("16-bit frame"),
        bits_per_pixel: 16,
        exposure_secs: 180.0,
        gain: Some(139),
        offset: Some(21),
        temperature: Some(-10.0),
        filter: None,
        timestamp: 0,
        sensor_type: Some("Monochrome".to_string()),
        bayer_offset: None,
    }
}

fn imaging(d: &ImageData) -> nightshade_imaging::ImageData {
    nightshade_imaging::ImageData::from_u16(d.width, d.height, 1, &d.data)
}

/// The measurement the app grades with (`UnifiedDeviceOps`).
fn shape(d: &ImageData) -> Option<nightshade_imaging::FrameShape> {
    nightshade_imaging::measure_frame_shape(&imaging(d))
}

#[async_trait]
impl DeviceOps for ReplayRig {
    async fn guider_get_status(&self) -> DeviceResult<GuidingStatus> {
        let guiding = self.is_guiding();
        self.record(format!("guider_get_status->{guiding}"));
        Ok(GuidingStatus {
            is_guiding: guiding,
            rms_ra: 0.5,
            rms_dec: 0.4,
            rms_total: 0.64,
        })
    }
    async fn guider_start(&self, _sp: f64, _st: f64, _sto: f64) -> DeviceResult<()> {
        self.record("guider_start");
        *self.guider.lock().unwrap() = Guider::Resuming(std::time::Instant::now());
        Ok(())
    }
    async fn guider_stop(&self) -> DeviceResult<()> {
        self.record("guider_stop");
        *self.guider.lock().unwrap() = Guider::Stopped;
        Ok(())
    }
    async fn mount_park(&self, id: &str) -> DeviceResult<()> {
        self.record(format!("mount_park:{id}"));
        Ok(())
    }
    async fn cover_calibrator_close_cover(&self, id: &str) -> DeviceResult<()> {
        self.record(format!("cover_close:{id}"));
        Ok(())
    }
    async fn dome_close(&self, id: &str) -> DeviceResult<()> {
        self.record(format!("dome_close:{id}"));
        Ok(())
    }
    async fn camera_start_exposure(
        &self,
        id: &str,
        d: f64,
        _g: Option<i32>,
        _o: Option<i32>,
        _bx: i32,
        _by: i32,
    ) -> DeviceResult<ImageData> {
        self.record(format!("camera_start_exposure:{id}:{d}"));
        // Lights get the night's real 180 s frames in the order they were
        // taken; the autofocus sweep gets the in-focus 2 s frame.
        if d >= 1.0 {
            let n = self.lights_taken.fetch_add(1, Ordering::SeqCst);
            Ok(self.lights[n % self.lights.len()].clone())
        } else {
            Ok(self.focused.clone())
        }
    }
    async fn mount_slew_to_coordinates(&self, id: &str, ra: f64, dec: f64) -> DeviceResult<()> {
        self.inner.mount_slew_to_coordinates(id, ra, dec).await
    }
    async fn mount_abort_slew(&self, id: &str) -> DeviceResult<()> {
        self.inner.mount_abort_slew(id).await
    }
    async fn mount_get_coordinates(&self, id: &str) -> DeviceResult<(f64, f64)> {
        self.inner.mount_get_coordinates(id).await
    }
    async fn mount_sync(&self, id: &str, ra: f64, dec: f64) -> DeviceResult<()> {
        self.inner.mount_sync(id, ra, dec).await
    }
    async fn mount_unpark(&self, id: &str) -> DeviceResult<()> {
        self.inner.mount_unpark(id).await
    }
    async fn mount_is_slewing(&self, id: &str) -> DeviceResult<bool> {
        self.inner.mount_is_slewing(id).await
    }
    async fn mount_is_parked(&self, id: &str) -> DeviceResult<bool> {
        self.inner.mount_is_parked(id).await
    }
    async fn mount_can_flip(&self, id: &str) -> DeviceResult<bool> {
        self.inner.mount_can_flip(id).await
    }
    async fn mount_side_of_pier(
        &self,
        id: &str,
    ) -> DeviceResult<nightshade_sequencer::meridian::PierSide> {
        self.inner.mount_side_of_pier(id).await
    }
    async fn mount_is_tracking(&self, id: &str) -> DeviceResult<bool> {
        self.inner.mount_is_tracking(id).await
    }
    async fn mount_set_tracking(&self, id: &str, enabled: bool) -> DeviceResult<()> {
        self.inner.mount_set_tracking(id, enabled).await
    }
    async fn camera_abort_exposure(&self, id: &str) -> DeviceResult<()> {
        self.inner.camera_abort_exposure(id).await
    }
    async fn camera_set_cooler(&self, id: &str, e: bool, t: f64) -> DeviceResult<()> {
        self.inner.camera_set_cooler(id, e, t).await
    }
    async fn camera_get_temperature(&self, id: &str) -> DeviceResult<f64> {
        self.inner.camera_get_temperature(id).await
    }
    async fn camera_get_cooler_power(&self, id: &str) -> DeviceResult<f64> {
        self.inner.camera_get_cooler_power(id).await
    }
    async fn focuser_move_to(&self, id: &str, p: i32) -> DeviceResult<()> {
        self.inner.focuser_move_to(id, p).await
    }
    async fn focuser_get_position(&self, id: &str) -> DeviceResult<i32> {
        let delay = self.focuser_read_ms.load(Ordering::SeqCst);
        if delay > 0 {
            tokio::time::sleep(Duration::from_millis(delay)).await;
        }
        self.inner.focuser_get_position(id).await
    }
    async fn focuser_is_moving(&self, id: &str) -> DeviceResult<bool> {
        self.inner.focuser_is_moving(id).await
    }
    async fn focuser_get_temperature(&self, id: &str) -> DeviceResult<Option<f64>> {
        self.inner.focuser_get_temperature(id).await
    }
    async fn focuser_halt(&self, id: &str) -> DeviceResult<()> {
        self.inner.focuser_halt(id).await
    }
    async fn filterwheel_set_position(&self, id: &str, p: i32) -> DeviceResult<()> {
        self.inner.filterwheel_set_position(id, p).await
    }
    async fn filterwheel_get_position(&self, id: &str) -> DeviceResult<i32> {
        self.inner.filterwheel_get_position(id).await
    }
    async fn filterwheel_get_names(&self, id: &str) -> DeviceResult<Vec<String>> {
        self.inner.filterwheel_get_names(id).await
    }
    async fn filterwheel_set_filter_by_name(&self, id: &str, n: &str) -> DeviceResult<i32> {
        self.inner.filterwheel_set_filter_by_name(id, n).await
    }
    async fn rotator_move_to(&self, id: &str, a: f64) -> DeviceResult<()> {
        self.inner.rotator_move_to(id, a).await
    }
    async fn rotator_move_relative(&self, id: &str, d: f64) -> DeviceResult<()> {
        self.inner.rotator_move_relative(id, d).await
    }
    async fn rotator_get_angle(&self, id: &str) -> DeviceResult<f64> {
        self.inner.rotator_get_angle(id).await
    }
    async fn rotator_halt(&self, id: &str) -> DeviceResult<()> {
        self.inner.rotator_halt(id).await
    }
    async fn guider_dither(
        &self,
        p: f64,
        sp: f64,
        st: f64,
        sto: f64,
        ra: bool,
    ) -> DeviceResult<()> {
        self.inner.guider_dither(p, sp, st, sto, ra).await
    }
    async fn plate_solve(
        &self,
        d: &ImageData,
        ra: Option<f64>,
        dec: Option<f64>,
        s: Option<f64>,
    ) -> DeviceResult<PlateSolveResult> {
        self.inner.plate_solve(d, ra, dec, s).await
    }
    async fn save_fits(
        &self,
        d: &ImageData,
        f: &str,
        ctx: &nightshade_sequencer::scheduling::FrameContext,
    ) -> DeviceResult<()> {
        self.inner.save_fits(d, f, ctx).await
    }
    async fn send_notification(
        &self,
        l: &str,
        t: &str,
        m: &str,
        x: Option<&[String]>,
    ) -> DeviceResult<()> {
        self.inner.send_notification(l, t, m, x).await
    }
    fn calculate_altitude(&self, r: f64, d: f64, la: f64, lo: f64) -> f64 {
        self.inner.calculate_altitude(r, d, la, lo)
    }
    fn get_observer_location(&self) -> Option<(f64, f64)> {
        self.inner.get_observer_location()
    }
    async fn polar_align_update(
        &self,
        r: &nightshade_sequencer::PolarAlignResult,
    ) -> DeviceResult<()> {
        self.inner.polar_align_update(r).await
    }
    async fn dome_open(&self, id: &str) -> DeviceResult<()> {
        self.inner.dome_open(id).await
    }
    async fn dome_park(&self, id: &str) -> DeviceResult<()> {
        self.inner.dome_park(id).await
    }
    async fn dome_get_shutter_status(&self, id: &str) -> DeviceResult<String> {
        self.inner.dome_get_shutter_status(id).await
    }
    async fn safety_is_safe(&self, id: Option<&str>) -> DeviceResult<bool> {
        self.inner.safety_is_safe(id).await
    }
    async fn calculate_image_hfr(&self, d: &ImageData) -> DeviceResult<Option<f64>> {
        Ok(shape(d).map(|s| s.hfr))
    }
    async fn detect_stars_in_image(&self, d: &ImageData) -> DeviceResult<Vec<(f64, f64, f64)>> {
        let stars = nightshade_imaging::detect_stars(
            &imaging(d),
            &nightshade_imaging::StarDetectionConfig::default(),
        );
        Ok(stars.iter().map(|s| (s.x, s.y, s.hfr)).collect())
    }
    async fn measure_frame_eccentricity(&self, d: &ImageData) -> DeviceResult<Option<f64>> {
        Ok(shape(d).map(|s| s.eccentricity))
    }
    async fn cover_calibrator_open_cover(&self, id: &str) -> DeviceResult<()> {
        self.inner.cover_calibrator_open_cover(id).await
    }
    async fn cover_calibrator_halt_cover(&self, id: &str) -> DeviceResult<()> {
        self.inner.cover_calibrator_halt_cover(id).await
    }
    async fn cover_calibrator_calibrator_on(&self, id: &str, b: i32) -> DeviceResult<()> {
        self.inner.cover_calibrator_calibrator_on(id, b).await
    }
    async fn cover_calibrator_calibrator_off(&self, id: &str) -> DeviceResult<()> {
        self.inner.cover_calibrator_calibrator_off(id).await
    }
    async fn cover_calibrator_get_cover_state(&self, id: &str) -> DeviceResult<i32> {
        self.inner.cover_calibrator_get_cover_state(id).await
    }
    async fn cover_calibrator_get_calibrator_state(&self, id: &str) -> DeviceResult<i32> {
        self.inner.cover_calibrator_get_calibrator_state(id).await
    }
    async fn cover_calibrator_get_brightness(&self, id: &str) -> DeviceResult<i32> {
        self.inner.cover_calibrator_get_brightness(id).await
    }
    async fn cover_calibrator_get_max_brightness(&self, id: &str) -> DeviceResult<i32> {
        self.inner.cover_calibrator_get_max_brightness(id).await
    }
}
/// The grading the rig ran under: `default_quality_check: enabled=true,
/// hfr=Some(3.5), hfr_baseline=Some(50.0), ecc=Some(0.7), stars=Some(10),
/// max_rejects=3`.
fn rig_quality_check() -> ImageQualityCheck {
    ImageQualityCheck {
        hfr_threshold: Some(3.5),
        hfr_baseline_percent: Some(50.0),
        eccentricity_threshold: Some(0.7),
        star_count_min: Some(10),
        max_consecutive_rejects: 3,
    }
}

struct Outcome {
    state: ExecutorState,
    calls: Vec<String>,
    messages: Vec<String>,
}

/// Run lights on the replay rig, force the refocus once the first light has
/// been taken (the rig's was forced by a filter change), and let the run play
/// out until it stops on its own, `seen(messages, calls)` says there is enough
/// evidence, or `settle` passes.
async fn replay(
    rig: Arc<ReplayRig>,
    settle: Duration,
    seen: impl Fn(&[String], &[String]) -> bool,
) -> Outcome {
    let mut executor = SequenceExecutor::new();
    executor.set_device_ops(rig.clone());
    executor.set_save_path(Some(std::env::temp_dir().join("rig-night-2026-09-14")));
    executor.set_devices(
        Some("cam-1".to_string()),
        Some("mount-1".to_string()),
        Some("focuser-1".to_string()),
        None,
        None,
    );
    executor
        .update_autofocus_config(AutofocusConfig {
            disable_guiding_during_af: true,
            number_of_attempts: 1,
            steps_out: 2,
            exposure_duration: 0.01,
            focuser_settle_time_ms: 0,
            // The rig ran with "failure action=PauseAndAlert". There is no
            // failure action any more: a failed autofocus always notifies and
            // carries on (owner decision 2026-10-06).
            ..AutofocusConfig::default()
        })
        .await;
    executor
        .update_default_quality_check(Some(rig_quality_check()))
        .await;
    let mut sequence = SequenceDefinition::new("NGC7380".to_string());
    sequence.nodes.push(NodeDefinition {
        id: "lights".to_string(),
        name: "NGC7380 lights".to_string(),
        // 1 s stands in for the 180 s the frames were taken at.
        node_type: NodeType::TakeExposure(nightshade_sequencer::ExposureConfig {
            count: 50,
            duration_secs: 1.0,
            frame_type: "light".to_string(),
            ..Default::default()
        }),
        enabled: true,
        children: vec![],
    });
    sequence.root_node_id = Some("lights".to_string());
    executor.load_sequence(sequence).expect("sequence loads");
    let mut events = executor.subscribe();
    executor.start().await.expect("run starts");

    let messages = Arc::new(Mutex::new(Vec::new()));
    let listener = {
        let messages = messages.clone();
        tokio::spawn(async move {
            loop {
                match events.recv().await {
                    Ok(ExecutorEvent::Error { message })
                    | Ok(ExecutorEvent::Warning { message }) => {
                        messages.lock().unwrap().push(message)
                    }
                    Ok(_) | Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
                    Err(_) => break,
                }
            }
        })
    };

    wait_until(Duration::from_secs(60), "no light was ever taken", || {
        rig.calls()
            .iter()
            .any(|c| c == "camera_start_exposure:cam-1:1")
    })
    .await;
    // The rig's trigger had an HFR reference when its sweep failed ("HFR
    // baseline reset to current value"), which is what let it carry on
    // imaging on the last-good focus. Here that reference is the first
    // light's own measured HFR. (Invalidation clears it, so it goes first.)
    let first_light_hfr = shape(&rig.lights[0]).expect("measurable").hfr;
    executor
        .update_trigger_state(move |ts| {
            ts.invalidate_autofocus("replay: filter changed");
            ts.baseline_hfr = Some(first_light_hfr);
            ts.current_hfr = Some(first_light_hfr);
        })
        .await;

    let deadline = tokio::time::Instant::now() + settle;
    while tokio::time::Instant::now() < deadline {
        let state = executor.get_state().await;
        if !matches!(state, ExecutorState::Running) {
            // Give anything the run does after it stops time to reach the rig.
            tokio::time::sleep(Duration::from_secs(3)).await;
            break;
        }
        let enough = seen(&messages.lock().unwrap(), &rig.calls());
        if enough {
            break;
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    let state = executor.get_state().await;
    let calls = rig.calls();
    let _ = executor.stop().await;
    listener.abort();
    let messages = messages.lock().unwrap().clone();
    Outcome {
        state,
        calls,
        messages,
    }
}

async fn wait_until(timeout: Duration, what: &str, done: impl Fn() -> bool) {
    let deadline = tokio::time::Instant::now() + timeout;
    while !done() {
        assert!(tokio::time::Instant::now() < deadline, "{what}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

fn parked_or_closed(calls: &[String]) -> bool {
    calls.iter().any(|c| {
        c.starts_with("mount_park") || c.starts_with("cover_close") || c.starts_with("dome_close")
    })
}

fn lights_after_sweep(calls: &[String]) -> usize {
    let Some(last_sweep_frame) = calls
        .iter()
        .rposition(|c| c == "camera_start_exposure:cam-1:0.01")
    else {
        return 0;
    };
    calls[last_sweep_frame..]
        .iter()
        .filter(|c| *c == "camera_start_exposure:cam-1:1")
        .count()
}

/// The guider fault the cleanup reported: PHD2 accepts the resume and never
/// guides. Not one more light may start, and nothing may be parked.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_guider_that_never_resumes_stops_the_lights_and_parks_nothing() {
    let _serial = SERIAL.lock().await;
    let rig = Arc::new(ReplayRig::new(None));
    let Outcome {
        state,
        calls,
        messages,
    } = replay(rig, Duration::from_secs(240), |_, _| false).await;
    assert!(
        calls.iter().any(|c| c == "guider_stop"),
        "the sweep never stopped the guider, so this proves nothing; messages={messages:?}"
    );
    assert_eq!(
        lights_after_sweep(&calls),
        0,
        "lights started after the sweep left the guider down; messages={messages:?} calls={calls:?}"
    );
    assert!(
        !parked_or_closed(&calls),
        "the run parked or closed the rig; messages={messages:?} calls={calls:?}"
    );
    assert_eq!(state, ExecutorState::Paused, "messages={messages:?}");
}

fn lights_started(calls: &[String]) -> usize {
    calls
        .iter()
        .filter(|c| *c == "camera_start_exposure:cam-1:1")
        .count()
}

fn is_streak_notice(message: &str) -> bool {
    message.contains("frames in a row rejected")
}

/// The guider as PHD2 really behaved: guiding nine seconds after the resume.
/// The lights that follow are the night's real trailed frames; the grader
/// must reject them, and the third reject tells the operator once. It used to
/// hold the run there; the owner's decision of 2026-10-06 is that a reject
/// limit never stops a sequence or ends a night, so the run keeps imaging and
/// nothing is parked.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_real_night_notifies_and_keeps_imaging() {
    let _serial = SERIAL.lock().await;
    let rig = Arc::new(ReplayRig::new(Some(Duration::from_secs(9))));
    let Outcome {
        state,
        calls,
        messages,
    } = replay(rig, Duration::from_secs(300), |messages, calls| {
        // Enough lights past the third reject to show the run did not stop.
        messages.iter().any(|m| is_streak_notice(m)) && lights_started(calls) >= 6
    })
    .await;
    assert!(
        calls.iter().any(|c| c == "guider_stop") && calls.iter().any(|c| c == "guider_start"),
        "the sweep never stopped and restarted the guider; messages={messages:?}"
    );
    assert!(
        !messages
            .iter()
            .any(|m| m.contains("CRITICAL CLEANUP FAILURE")),
        "a guider that came back nine seconds later was declared dead; messages={messages:?}"
    );
    assert_eq!(
        messages.iter().filter(|m| is_streak_notice(m)).count(),
        1,
        "the trailed lights must be reported once per streak; messages={messages:?}"
    );
    assert!(
        lights_started(&calls) >= 6,
        "the run stopped taking lights after the reject limit; messages={messages:?}"
    );
    assert!(
        !parked_or_closed(&calls),
        "the run parked or closed the rig; messages={messages:?} calls={calls:?}"
    );
    assert_eq!(state, ExecutorState::Running, "messages={messages:?}");
}
