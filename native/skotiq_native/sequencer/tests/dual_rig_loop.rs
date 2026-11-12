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
use skotiq_sequencer::{CameraOps, FrameStoreOps};
use skotiq_sequencer::{DeviceResult, ExposureRequest, ImageData, NullDeviceOps};
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
impl CameraOps for RecordingOps {
    async fn camera_start_exposure(&self, request: ExposureRequest<'_>) -> DeviceResult<ImageData> {
        let ExposureRequest {
            duration_secs,
            gain,
            offset,
            ..
        } = request;
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
            color_filter: None,
            // As a DSLR delivers it; written only when the run keeps camera files.
            camera_file: Some(skotiq_device::CameraFile {
                file_name: "IMG_0001.NEF".to_string(),
                bytes: Arc::new(b"nef bytes".to_vec()),
            }),
        })
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
}

#[async_trait]
impl FrameStoreOps for RecordingOps {
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
    async fn calculate_image_hfr(&self, i: &ImageData) -> DeviceResult<Option<f64>> {
        self.inner.calculate_image_hfr(i).await
    }
    async fn detect_stars_in_image(&self, i: &ImageData) -> DeviceResult<Vec<(f64, f64, f64)>> {
        self.inner.detect_stars_in_image(i).await
    }
}

skotiq_sequencer::forward_device_ops!(RecordingOps => inner: MountOps, FocuserOps, FilterWheelOps, RotatorOps, GuiderOps, DomeOps, CoverCalibratorOps, SafetyOps, PlateSolveOps, OperatorNotifyOps, ConnectionOps, SiteOps);

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

/// The secondary camera's frames are the run's frames: with camera files
/// kept, each lands beside its FITS name with the camera's extension.
#[tokio::test]
async fn secondary_frames_keep_the_camera_file_when_the_run_does() {
    let tmp = temp_dir();
    let recorder = Arc::new(RecordingOps::new(Duration::from_millis(10)));
    let ops: Arc<dyn skotiq_sequencer::DeviceOps> = recorder.clone();
    let barrier = Arc::new(DitherBarrier::new(30.0, InFlightDitherPolicy::CompleteIfShort));
    let mut config = SecondaryRigConfig::new("cam-secondary", 0.01);
    config.frame_count = Some(1);
    config.rig_label = "WideField".to_string();
    let mut frame_meta = meta(&tmp);
    frame_meta.camera_file_saving = skotiq_sequencer::CameraFileSaving::Both;

    let rig = SecondaryRig::start(config, ops, barrier, frame_meta);
    for _ in 0..200 {
        if rig.status().frames_captured >= 1 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let saved = recorder.saved_frames();
    assert_eq!(saved.len(), 1);
    let camera_path = std::path::Path::new(&saved[0].0).with_extension("NEF");
    assert_eq!(std::fs::read(&camera_path).unwrap(), b"nef bytes");
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
