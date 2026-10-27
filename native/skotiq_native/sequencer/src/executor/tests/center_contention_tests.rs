//! A Center node and the trigger monitor must not both drive the camera.
//!
//! Found by the simulator soak (tools/harness/sim_night_soak) on its first
//! run: a Center node's first solve landed far from the target -- as the first
//! solve of any night does when the mount starts away from it -- and the
//! solve went straight into the drift state. The DriftLimit trigger read that
//! intermediate solve as the sequence having drifted off target and started
//! its own recenter while the Center node was still correcting. Both then
//! exposed on one camera; one of them downloaded the other's frame and the
//! Center node failed with "No exposure is available to download", ending the
//! run 40 s in:
//!
//!     Current separation: 103033.1" from target
//!     Trigger fired: Plate-Solve Drift Limit (drift_limit) - Recenter
//!     Center attempt 2/4
//!     Center Target failed: Failed to capture image: Failed to download image:
//!       No exposure is available to download from the simulated camera.

use super::*;
use crate::device_ops::{DeviceResult, GuidingStatus, ImageData, PlateSolveResult};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;

const TARGET_RA_HOURS: f64 = 10.0;
const TARGET_DEC: f64 = 40.0;

/// A rig whose camera takes real time to expose and refuses to be driven by
/// two callers at once, and whose first plate solve lands two degrees off.
struct CenterContentionOps {
    inner: Arc<crate::device_ops::NullDeviceOps>,
    in_flight: Arc<AtomicU32>,
    max_in_flight: Arc<AtomicU32>,
    solves: Arc<AtomicU32>,
    /// When the last slew was commanded; the mount reports `slewing` for a
    /// moment afterwards, as every mount does.
    slewed_at: std::sync::Mutex<Option<std::time::Instant>>,
}

impl CenterContentionOps {
    fn new() -> Self {
        Self {
            inner: Arc::new(crate::device_ops::NullDeviceOps),
            in_flight: Arc::new(AtomicU32::new(0)),
            max_in_flight: Arc::new(AtomicU32::new(0)),
            solves: Arc::new(AtomicU32::new(0)),
            slewed_at: std::sync::Mutex::new(None),
        }
    }
}

#[async_trait::async_trait]
impl DeviceOps for CenterContentionOps {
    async fn camera_start_exposure(
        &self,
        _id: &str,
        duration: f64,
        gain: Option<i32>,
        offset: Option<i32>,
        _bx: i32,
        _by: i32,
    ) -> DeviceResult<ImageData> {
        let now = self.in_flight.fetch_add(1, Ordering::SeqCst) + 1;
        self.max_in_flight.fetch_max(now, Ordering::SeqCst);
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        self.in_flight.fetch_sub(1, Ordering::SeqCst);
        if now > 1 {
            // What the simulator and a real single-sensor driver answer when a
            // second caller starts an exposure over the first one's.
            return Err("No exposure is available to download".to_string());
        }
        Ok(ImageData {
            width: 64,
            height: 64,
            data: vec![0u16; 64 * 64],
            bits_per_pixel: 16,
            exposure_secs: duration,
            gain,
            offset,
            temperature: None,
            filter: None,
            timestamp: chrono::Utc::now().timestamp(),
            sensor_type: Some("Monochrome".to_string()),
            bayer_offset: None,
        })
    }

    async fn plate_solve(
        &self,
        _d: &ImageData,
        _ra: Option<f64>,
        _dec: Option<f64>,
        _s: Option<f64>,
    ) -> DeviceResult<PlateSolveResult> {
        // The first solve is two degrees off (the mount started somewhere
        // else); after the centering slew every solve is on target.
        let n = self.solves.fetch_add(1, Ordering::SeqCst);
        let offset_deg = if n == 0 { 2.0 } else { 0.0005 };
        // Long enough for the 1 Hz trigger monitor to see the first solve.
        tokio::time::sleep(std::time::Duration::from_millis(1500)).await;
        Ok(PlateSolveResult {
            ra_degrees: TARGET_RA_HOURS * 15.0 + offset_deg,
            dec_degrees: TARGET_DEC + offset_deg,
            pixel_scale: 1.0,
            rotation: 0.0,
            up_position_angle_deg: 0.0,
            success: true,
        })
    }

    async fn mount_slew_to_coordinates(&self, _id: &str, _ra: f64, _dec: f64) -> DeviceResult<()> {
        *self.slewed_at.lock().unwrap() = Some(std::time::Instant::now());
        Ok(())
    }
    async fn mount_get_coordinates(&self, _id: &str) -> DeviceResult<(f64, f64)> {
        Ok((TARGET_RA_HOURS, TARGET_DEC))
    }
    async fn mount_sync(&self, _id: &str, _ra: f64, _dec: f64) -> DeviceResult<()> {
        Ok(())
    }
    async fn mount_is_slewing(&self, _id: &str) -> DeviceResult<bool> {
        Ok(self
            .slewed_at
            .lock()
            .unwrap()
            .is_some_and(|at| at.elapsed() < std::time::Duration::from_millis(600)))
    }
    async fn mount_is_parked(&self, _id: &str) -> DeviceResult<bool> {
        Ok(false)
    }
    async fn mount_is_tracking(&self, _id: &str) -> DeviceResult<bool> {
        Ok(true)
    }
    async fn mount_set_tracking(&self, id: &str, enabled: bool) -> DeviceResult<()> {
        self.inner.mount_set_tracking(id, enabled).await
    }
    async fn guider_get_status(&self) -> DeviceResult<GuidingStatus> {
        self.inner.guider_get_status().await
    }
    async fn guider_start(&self, sp: f64, st: f64, sto: f64) -> DeviceResult<()> {
        self.inner.guider_start(sp, st, sto).await
    }
    async fn mount_abort_slew(&self, id: &str) -> DeviceResult<()> {
        self.inner.mount_abort_slew(id).await
    }
    async fn mount_park(&self, id: &str) -> DeviceResult<()> {
        self.inner.mount_park(id).await
    }
    async fn mount_unpark(&self, id: &str) -> DeviceResult<()> {
        self.inner.mount_unpark(id).await
    }
    async fn mount_can_flip(&self, id: &str) -> DeviceResult<bool> {
        self.inner.mount_can_flip(id).await
    }
    async fn mount_side_of_pier(&self, id: &str) -> DeviceResult<crate::meridian::PierSide> {
        self.inner.mount_side_of_pier(id).await
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
    async fn guider_stop(&self) -> DeviceResult<()> {
        self.inner.guider_stop().await
    }
    async fn save_fits(
        &self,
        d: &crate::device_ops::ImageData,
        f: &str,
        fctx: &crate::scheduling::FrameContext,
    ) -> DeviceResult<()> {
        self.inner.save_fits(d, f, fctx).await
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
        r: &crate::polar_align::PolarAlignResult,
    ) -> DeviceResult<()> {
        self.inner.polar_align_update(r).await
    }
    async fn dome_open(&self, id: &str) -> DeviceResult<()> {
        self.inner.dome_open(id).await
    }
    async fn dome_close(&self, id: &str) -> DeviceResult<()> {
        self.inner.dome_close(id).await
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
    async fn calculate_image_hfr(
        &self,
        d: &crate::device_ops::ImageData,
    ) -> DeviceResult<Option<f64>> {
        self.inner.calculate_image_hfr(d).await
    }
    async fn detect_stars_in_image(
        &self,
        d: &crate::device_ops::ImageData,
    ) -> DeviceResult<Vec<(f64, f64, f64)>> {
        self.inner.detect_stars_in_image(d).await
    }
    async fn cover_calibrator_open_cover(&self, id: &str) -> DeviceResult<()> {
        self.inner.cover_calibrator_open_cover(id).await
    }
    async fn cover_calibrator_close_cover(&self, id: &str) -> DeviceResult<()> {
        self.inner.cover_calibrator_close_cover(id).await
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

fn center_sequence() -> SequenceDefinition {
    let mut sequence = SequenceDefinition::new("Center contention".to_string());
    sequence.nodes.push(crate::NodeDefinition {
        id: "target".to_string(),
        name: "Far target".to_string(),
        node_type: crate::NodeType::TargetHeader(crate::TargetHeaderConfig {
            target_name: "Far target".to_string(),
            ra_hours: TARGET_RA_HOURS,
            dec_degrees: TARGET_DEC,
            ..crate::TargetHeaderConfig::default()
        }),
        enabled: true,
        children: vec!["center".to_string()],
    });
    sequence.nodes.push(crate::NodeDefinition {
        id: "center".to_string(),
        name: "Center".to_string(),
        node_type: crate::NodeType::CenterTarget(crate::CenterConfig {
            accuracy_arcsec: 15.0,
            max_attempts: 4,
            exposure_duration: 0.3,
            ..crate::CenterConfig::default()
        }),
        enabled: true,
        children: vec![],
    });
    sequence.root_node_id = Some("target".to_string());
    sequence
}

struct CenterRun {
    state: ExecutorState,
    max_in_flight: u32,
    trigger_actions: Vec<String>,
    failures: Vec<String>,
    /// Whether the imaging train was claimed while the Center node was
    /// between its captures (solving, syncing, slewing).
    train_held_mid_center: bool,
}

/// Run the one-target Center sequence with only `keep` triggers armed.
async fn run_center(keep: &[&str]) -> CenterRun {
    // The start pre-flight refuses a centering sequence on a machine with no
    // solver; the double's plate_solve never runs one, so an existing file at
    // the configured ASTAP path is all the pre-flight needs to see.
    let solver_dir = std::env::temp_dir().join(format!("sk-center-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&solver_dir).unwrap();
    let astap = solver_dir.join("astap");
    std::fs::write(&astap, b"").unwrap();
    skotiq_imaging::set_solver_preference(astap.to_str(), None, None, None);

    let ops = Arc::new(CenterContentionOps::new());
    let mut executor = SequenceExecutor::new();
    executor.set_device_ops(ops.clone());
    executor.set_devices(
        Some("cam-1".to_string()),
        Some("mount-1".to_string()),
        None,
        None,
        None,
    );
    {
        // Only the triggers under test, so nothing else steers the run.
        let mut manager = executor.trigger_manager.write().await;
        let ids: Vec<String> = manager
            .triggers()
            .iter()
            .map(|t| t.id.clone())
            .filter(|id| !keep.contains(&id.as_str()))
            .collect();
        for id in ids {
            manager.remove_trigger(&id);
        }
        // Exercise an explicit pixel-drift trigger as well as the new
        // first-frame watcher; only the built-in default is replaced.
        if let Some(trigger) = manager.get_trigger_mut("drift_limit") {
            trigger.id = "test_drift".into();
        }
    }
    let mut events = executor.subscribe();
    executor
        .load_sequence(center_sequence())
        .expect("sequence loads");
    executor.start().await.expect("run starts");

    let trigger_state = {
        let manager = executor.trigger_manager.read().await;
        manager.state()
    };
    let mut state = executor.get_state().await;
    let mut train_held_mid_center = false;
    for _ in 0..1_500 {
        state = executor.get_state().await;
        if matches!(
            state,
            ExecutorState::Completed | ExecutorState::Failed | ExecutorState::Cancelled
        ) {
            break;
        }
        // The first solve is in flight (1.5 s) and no exposure is.
        if ops.solves.load(Ordering::SeqCst) == 1 && ops.in_flight.load(Ordering::SeqCst) == 0 {
            train_held_mid_center |= trigger_state.read().await.imaging_train_hold().is_some();
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    executor.stop().await.ok();
    let _ = std::fs::remove_dir_all(&solver_dir);

    let mut trigger_actions = Vec::new();
    let mut failures = Vec::new();
    while let Ok(event) = events.try_recv() {
        match event {
            ExecutorEvent::TriggerFired { trigger_id, .. } => trigger_actions.push(trigger_id),
            ExecutorEvent::InstructionFailed { message, .. } => failures.push(message),
            ExecutorEvent::Error { message } => failures.push(message),
            _ => {}
        }
    }
    CenterRun {
        state,
        max_in_flight: ops.max_in_flight.load(Ordering::SeqCst),
        trigger_actions,
        failures,
        train_held_mid_center,
    }
}

/// The soak's failure: the Center node's own first solve fired DriftLimit.
#[tokio::test]
async fn a_center_nodes_first_solve_does_not_fire_the_drift_limit() {
    let run = run_center(&["drift_limit"]).await;
    assert_eq!(
        run.state,
        ExecutorState::Completed,
        "the Center node must converge on its own; failures: {:?}, triggers: {:?}",
        run.failures,
        run.trigger_actions
    );
    assert!(
        run.trigger_actions.is_empty(),
        "DriftLimit acted on a solve the Center node was about to correct: {:?}",
        run.trigger_actions
    );
    assert_eq!(
        run.max_in_flight, 1,
        "the camera was driven by two callers at once"
    );
}

/// A Center node owns the imaging train for its whole loop -- capture, solve,
/// sync, correction slew -- like an exposure does for its frame. It did not,
/// so a trigger that came due as a new target started (autofocus after the
/// target change, a stale meridian flip, a drift recenter) took the camera
/// between the Center node's captures: in the simulator soak the refocus's
/// sweep frame was downloaded by the Center node's next capture and the run
/// failed "No exposure is available to download", twice, at the second
/// target's start.
#[tokio::test]
async fn a_center_node_holds_the_imaging_train_between_its_captures() {
    let run = run_center(&[]).await;
    assert_eq!(run.state, ExecutorState::Completed, "{:?}", run.failures);
    assert!(
        run.train_held_mid_center,
        "the imaging train was free while the Center node was solving; any \
         camera-driving trigger could start exposing over its next capture"
    );
}
