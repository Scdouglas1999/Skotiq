//! Integration tests for the dual-rig secondary capture loop
//! ([`skotiq_sequencer::dual_rig`]).
//!
//! These exercise the loop body with a recording mock `DeviceOps` (built on
//! [`NullDeviceOps`]) to verify:
//!   * frames are saved with the right rig attribution (`rig_label`) and into
//!     the `<base>/<rig_label>/` subfolder;
//!   * a fixed `frame_count` stops the loop cleanly;
//!   * `SecondaryRig::stop` (end-of-sequence) terminates a run-until-stopped
//!     loop promptly;
//!   * the loop blocks while a dither is pending and resumes after release.

use async_trait::async_trait;
use skotiq_sequencer::dual_rig::{
    DitherBarrier, InFlightDitherPolicy, SecondaryFrameMeta, SecondaryRig, SecondaryRigConfig,
};
use skotiq_sequencer::scheduling::FrameContext;
use skotiq_sequencer::{
    DeviceResult, GuidingCalibration, GuidingStatus, ImageData, NullDeviceOps, PlateSolveResult,
};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// Recording mock: delegates everything to `NullDeviceOps` except the capture +
/// save methods, which it records. Exposure time is shortened so the loop runs
/// fast regardless of the configured exposure_secs.
struct RecordingOps {
    inner: Arc<NullDeviceOps>,
    exposures: AtomicU32,
    aborts: AtomicU32,
    saved: Mutex<Vec<(String, Option<String>)>>, // (path, rig_label)
    /// Exposure wall time per frame; small for fast tests.
    exposure_wait: Duration,
}

impl RecordingOps {
    fn new(exposure_wait: Duration) -> Self {
        Self {
            inner: Arc::new(NullDeviceOps),
            exposures: AtomicU32::new(0),
            aborts: AtomicU32::new(0),
            saved: Mutex::new(Vec::new()),
            exposure_wait,
        }
    }
    fn exposure_count(&self) -> u32 {
        self.exposures.load(Ordering::SeqCst)
    }
    fn saved_frames(&self) -> Vec<(String, Option<String>)> {
        self.saved.lock().unwrap().clone()
    }
    fn abort_count(&self) -> u32 {
        self.aborts.load(Ordering::SeqCst)
    }
}

#[async_trait]
impl skotiq_sequencer::DeviceOps for RecordingOps {
    async fn camera_start_exposure(
        &self,
        _camera_id: &str,
        duration_secs: f64,
        gain: Option<i32>,
        offset: Option<i32>,
        _bin_x: i32,
        _bin_y: i32,
    ) -> DeviceResult<ImageData> {
        self.exposures.fetch_add(1, Ordering::SeqCst);
        tokio::time::sleep(self.exposure_wait).await;
        Ok(ImageData {
            width: 100,
            height: 100,
            data: vec![0u16; 100 * 100],
            bits_per_pixel: 16,
            exposure_secs: duration_secs,
            gain,
            offset,
            temperature: Some(-5.0),
            filter: None,
            timestamp: 0,
            sensor_type: Some("Monochrome".to_string()),
            bayer_offset: None,
        })
    }

    async fn save_fits(
        &self,
        _image_data: &ImageData,
        file_path: &str,
        frame_ctx: &FrameContext,
    ) -> DeviceResult<()> {
        self.saved
            .lock()
            .unwrap()
            .push((file_path.to_string(), frame_ctx.rig_label.clone()));
        Ok(())
    }

    // Everything else delegates to NullDeviceOps
    async fn mount_slew_to_coordinates(&self, m: &str, ra: f64, dec: f64) -> DeviceResult<()> {
        self.inner.mount_slew_to_coordinates(m, ra, dec).await
    }
    async fn mount_abort_slew(&self, m: &str) -> DeviceResult<()> {
        self.inner.mount_abort_slew(m).await
    }
    async fn mount_get_coordinates(&self, m: &str) -> DeviceResult<(f64, f64)> {
        self.inner.mount_get_coordinates(m).await
    }
    async fn mount_sync(&self, m: &str, ra: f64, dec: f64) -> DeviceResult<()> {
        self.inner.mount_sync(m, ra, dec).await
    }
    async fn mount_park(&self, m: &str) -> DeviceResult<()> {
        self.inner.mount_park(m).await
    }
    async fn mount_unpark(&self, m: &str) -> DeviceResult<()> {
        self.inner.mount_unpark(m).await
    }
    async fn mount_is_slewing(&self, m: &str) -> DeviceResult<bool> {
        self.inner.mount_is_slewing(m).await
    }
    async fn mount_is_parked(&self, m: &str) -> DeviceResult<bool> {
        self.inner.mount_is_parked(m).await
    }
    async fn mount_can_flip(&self, m: &str) -> DeviceResult<bool> {
        self.inner.mount_can_flip(m).await
    }
    async fn mount_side_of_pier(
        &self,
        m: &str,
    ) -> DeviceResult<skotiq_sequencer::meridian::PierSide> {
        self.inner.mount_side_of_pier(m).await
    }
    async fn mount_is_tracking(&self, m: &str) -> DeviceResult<bool> {
        self.inner.mount_is_tracking(m).await
    }
    async fn mount_set_tracking(&self, m: &str, e: bool) -> DeviceResult<()> {
        self.inner.mount_set_tracking(m, e).await
    }
    async fn camera_abort_exposure(&self, c: &str) -> DeviceResult<()> {
        self.aborts.fetch_add(1, Ordering::SeqCst);
        self.inner.camera_abort_exposure(c).await
    }
    async fn camera_set_cooler(&self, c: &str, e: bool, t: f64) -> DeviceResult<()> {
        self.inner.camera_set_cooler(c, e, t).await
    }
    async fn camera_get_temperature(&self, c: &str) -> DeviceResult<f64> {
        self.inner.camera_get_temperature(c).await
    }
    async fn camera_get_cooler_power(&self, c: &str) -> DeviceResult<f64> {
        self.inner.camera_get_cooler_power(c).await
    }
    async fn focuser_move_to(&self, f: &str, p: i32) -> DeviceResult<()> {
        self.inner.focuser_move_to(f, p).await
    }
    async fn focuser_get_position(&self, f: &str) -> DeviceResult<i32> {
        self.inner.focuser_get_position(f).await
    }
    async fn focuser_is_moving(&self, f: &str) -> DeviceResult<bool> {
        self.inner.focuser_is_moving(f).await
    }
    async fn focuser_get_temperature(&self, f: &str) -> DeviceResult<Option<f64>> {
        self.inner.focuser_get_temperature(f).await
    }
    async fn focuser_halt(&self, f: &str) -> DeviceResult<()> {
        self.inner.focuser_halt(f).await
    }
    async fn filterwheel_set_position(&self, w: &str, p: i32) -> DeviceResult<()> {
        self.inner.filterwheel_set_position(w, p).await
    }
    async fn filterwheel_get_position(&self, w: &str) -> DeviceResult<i32> {
        self.inner.filterwheel_get_position(w).await
    }
    async fn filterwheel_get_names(&self, w: &str) -> DeviceResult<Vec<String>> {
        self.inner.filterwheel_get_names(w).await
    }
    async fn filterwheel_set_filter_by_name(&self, w: &str, n: &str) -> DeviceResult<i32> {
        self.inner.filterwheel_set_filter_by_name(w, n).await
    }
    async fn rotator_move_to(&self, r: &str, a: f64) -> DeviceResult<()> {
        self.inner.rotator_move_to(r, a).await
    }
    async fn rotator_move_relative(&self, r: &str, d: f64) -> DeviceResult<()> {
        self.inner.rotator_move_relative(r, d).await
    }
    async fn rotator_get_angle(&self, r: &str) -> DeviceResult<f64> {
        self.inner.rotator_get_angle(r).await
    }
    async fn rotator_halt(&self, r: &str) -> DeviceResult<()> {
        self.inner.rotator_halt(r).await
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
    async fn guider_get_status(&self) -> DeviceResult<GuidingStatus> {
        self.inner.guider_get_status().await
    }
    async fn guider_get_calibration(&self) -> DeviceResult<GuidingCalibration> {
        self.inner.guider_get_calibration().await
    }
    async fn guider_start(&self, sp: f64, st: f64, sto: f64) -> DeviceResult<()> {
        self.inner.guider_start(sp, st, sto).await
    }
    async fn guider_stop(&self) -> DeviceResult<()> {
        self.inner.guider_stop().await
    }
    async fn plate_solve(
        &self,
        i: &ImageData,
        ra: Option<f64>,
        dec: Option<f64>,
        s: Option<f64>,
    ) -> DeviceResult<PlateSolveResult> {
        self.inner.plate_solve(i, ra, dec, s).await
    }
    async fn send_notification(
        &self,
        l: &str,
        t: &str,
        m: &str,
        e: Option<&[String]>,
    ) -> DeviceResult<()> {
        self.inner.send_notification(l, t, m, e).await
    }
    fn calculate_altitude(&self, ra: f64, dec: f64, lat: f64, lon: f64) -> f64 {
        self.inner.calculate_altitude(ra, dec, lat, lon)
    }
    fn get_observer_location(&self) -> Option<(f64, f64)> {
        self.inner.get_observer_location()
    }
    async fn polar_align_update(
        &self,
        r: &skotiq_sequencer::PolarAlignResult,
    ) -> DeviceResult<()> {
        self.inner.polar_align_update(r).await
    }
    async fn dome_open(&self, d: &str) -> DeviceResult<()> {
        self.inner.dome_open(d).await
    }
    async fn dome_close(&self, d: &str) -> DeviceResult<()> {
        self.inner.dome_close(d).await
    }
    async fn dome_park(&self, d: &str) -> DeviceResult<()> {
        self.inner.dome_park(d).await
    }
    async fn dome_get_shutter_status(&self, d: &str) -> DeviceResult<String> {
        self.inner.dome_get_shutter_status(d).await
    }
    async fn safety_is_safe(&self, s: Option<&str>) -> DeviceResult<bool> {
        self.inner.safety_is_safe(s).await
    }
    async fn calculate_image_hfr(&self, i: &ImageData) -> DeviceResult<Option<f64>> {
        self.inner.calculate_image_hfr(i).await
    }
    async fn detect_stars_in_image(&self, i: &ImageData) -> DeviceResult<Vec<(f64, f64, f64)>> {
        self.inner.detect_stars_in_image(i).await
    }
    async fn cover_calibrator_open_cover(&self, c: &str) -> DeviceResult<()> {
        self.inner.cover_calibrator_open_cover(c).await
    }
    async fn cover_calibrator_close_cover(&self, c: &str) -> DeviceResult<()> {
        self.inner.cover_calibrator_close_cover(c).await
    }
    async fn cover_calibrator_halt_cover(&self, c: &str) -> DeviceResult<()> {
        self.inner.cover_calibrator_halt_cover(c).await
    }
    async fn cover_calibrator_calibrator_on(&self, c: &str, b: i32) -> DeviceResult<()> {
        self.inner.cover_calibrator_calibrator_on(c, b).await
    }
    async fn cover_calibrator_calibrator_off(&self, c: &str) -> DeviceResult<()> {
        self.inner.cover_calibrator_calibrator_off(c).await
    }
    async fn cover_calibrator_get_cover_state(&self, c: &str) -> DeviceResult<i32> {
        self.inner.cover_calibrator_get_cover_state(c).await
    }
    async fn cover_calibrator_get_calibrator_state(&self, c: &str) -> DeviceResult<i32> {
        self.inner.cover_calibrator_get_calibrator_state(c).await
    }
    async fn cover_calibrator_get_brightness(&self, c: &str) -> DeviceResult<i32> {
        self.inner.cover_calibrator_get_brightness(c).await
    }
    async fn cover_calibrator_get_max_brightness(&self, c: &str) -> DeviceResult<i32> {
        self.inner.cover_calibrator_get_max_brightness(c).await
    }
}

/// A scratch directory that deletes itself when the test ends.
/// `Drop` rather than a cleanup call at the end of each test: the leak was
/// worst exactly when a test FAILED, and drop still runs while a panic unwinds.
struct TempDir(std::path::PathBuf);

impl std::ops::Deref for TempDir {
    type Target = std::path::Path;
    fn deref(&self) -> &std::path::Path {
        &self.0
    }
}

// Deref alone does not satisfy a generic `AsRef<Path>` bound, which several
// call sites here rely on.
impl AsRef<std::path::Path> for TempDir {
    fn as_ref(&self) -> &std::path::Path {
        &self.0
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        // Best-effort: a test asserting on a half-removed tree should fail on
        // its own assertion, not on cleanup.
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn temp_dir() -> TempDir {
    TempDir(std::env::temp_dir().join(format!("dualrig-test-{}", uuid::Uuid::new_v4())))
}

fn meta(base: &std::path::Path) -> SecondaryFrameMeta {
    SecondaryFrameMeta {
        session_id: "test-session".to_string(),
        target_name: Some("M31".to_string()),
        save_base: Some(base.to_path_buf()),
        ..Default::default()
    }
}

#[tokio::test]
async fn fixed_frame_count_stops_loop_and_attributes_rig() {
    let tmp = temp_dir();
    // Keep a typed handle so we can inspect recorded saves, plus a trait-object
    // clone for the loop.
    let recorder = Arc::new(RecordingOps::new(Duration::from_millis(10)));
    let ops: Arc<dyn skotiq_sequencer::DeviceOps> = recorder.clone();
    let barrier = Arc::new(DitherBarrier::new(
        30.0,
        InFlightDitherPolicy::CompleteIfShort,
    ));

    let mut config = SecondaryRigConfig::new("cam-secondary", 0.01);
    config.frame_count = Some(3);
    config.rig_label = "WideField".to_string();

    let rig = SecondaryRig::start(config, ops, barrier, meta(&tmp));

    // Wait for all 3 frames to be captured (the loop stops itself afterwards).
    // Poll on frame count rather than `running` so we don't race the spawn.
    for _ in 0..200 {
        if rig.status().frames_captured >= 3 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    // Give the loop task a moment to flip `running` false after the last frame.
    tokio::time::sleep(Duration::from_millis(50)).await;
    let status = rig.status();
    assert!(!status.running, "loop should stop after fixed frame count");
    assert_eq!(status.frames_captured, 3);
    assert_eq!(recorder.exposure_count(), 3);

    // Every saved frame is attributed to the WideField rig and lives in the
    // <base>/WideField/ subfolder.
    let saved = recorder.saved_frames();
    assert_eq!(saved.len(), 3);
    for (path, rig_label) in &saved {
        assert_eq!(rig_label.as_deref(), Some("WideField"));
        assert!(
            path.contains("WideField"),
            "frame path {path} should be under the rig subfolder"
        );
        assert!(
            path.contains("M31"),
            "frame name should carry target M31: {path}"
        );
    }
}

#[tokio::test]
async fn run_until_stopped_terminates_on_stop() {
    let tmp = temp_dir();
    let ops: Arc<dyn skotiq_sequencer::DeviceOps> =
        Arc::new(RecordingOps::new(Duration::from_millis(10)));
    let barrier = Arc::new(DitherBarrier::new(
        30.0,
        InFlightDitherPolicy::CompleteIfShort,
    ));

    let config = SecondaryRigConfig::new("cam-secondary", 0.01); // frame_count None
    let rig = SecondaryRig::start(config, ops, barrier, meta(&tmp));

    // Let it capture a few frames.
    tokio::time::sleep(Duration::from_millis(80)).await;
    assert!(
        rig.status().running,
        "run-until-stopped should keep running"
    );

    let handle = rig.stop();
    let stopped = tokio::time::timeout(Duration::from_secs(3), handle)
        .await
        .expect("secondary stop timed out")
        .expect("secondary task panicked");
    assert!(stopped.is_ok(), "secondary stop failed: {stopped:?}");
}

#[tokio::test]
async fn stop_aborts_and_joins_a_long_in_flight_exposure() {
    let tmp = temp_dir();
    let recorder = Arc::new(RecordingOps::new(Duration::from_secs(30)));
    let ops: Arc<dyn skotiq_sequencer::DeviceOps> = recorder.clone();
    let barrier = Arc::new(DitherBarrier::new(
        30.0,
        InFlightDitherPolicy::CompleteIfShort,
    ));

    let config = SecondaryRigConfig::new("cam-secondary", 30.0);
    let rig = SecondaryRig::start(config, ops, barrier, meta(&tmp));
    for _ in 0..100 {
        if rig.status().exposing {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert!(rig.status().exposing, "test exposure never started");

    let stopped = tokio::time::timeout(Duration::from_secs(1), rig.stop())
        .await
        .expect("stop must not wait for the 30-second exposure")
        .expect("secondary task panicked");
    assert!(stopped.is_ok(), "secondary stop failed: {stopped:?}");
    assert_eq!(recorder.abort_count(), 1);
}

#[tokio::test]
async fn secondary_blocks_while_dither_pending_then_resumes() {
    let tmp = temp_dir();
    let ops: Arc<dyn skotiq_sequencer::DeviceOps> =
        Arc::new(RecordingOps::new(Duration::from_millis(10)));
    let barrier = Arc::new(DitherBarrier::new(
        30.0,
        InFlightDitherPolicy::CompleteIfShort,
    ));

    // Announce a dither BEFORE starting the loop so the first thing it does is
    // park at the gate.
    barrier.begin_dither();

    let config = SecondaryRigConfig::new("cam-secondary", 0.01);
    let rig = SecondaryRig::start(config, ops, barrier.clone(), meta(&tmp));

    tokio::time::sleep(Duration::from_millis(100)).await;
    let parked = rig.status();
    assert!(
        parked.waiting_for_dither,
        "secondary must park during dither"
    );
    assert_eq!(parked.frames_captured, 0, "no frames while dither pending");

    // Release; the loop should now start capturing.
    barrier.end_dither();
    tokio::time::sleep(Duration::from_millis(120)).await;
    assert!(
        rig.status().frames_captured >= 1,
        "secondary must resume after dither release"
    );

    let _ = rig.stop().await;
}
