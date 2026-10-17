//! DepthLock completion through the real executor.
//!
//! A two-filter Smart Exposure run against a recording device double and a
//! scripted verdict source proves the contract in `depth_goal.rs`: an achieved
//! verdict for the bound revision retires that plan at the next batch
//! boundary, the other plan runs to its authored count, the completion is
//! explained by one `DepthGoalCompleted` event, and every way the verdict can
//! be wrong or missing (other revision, no store, still collecting) leaves
//! the bounded plan exactly as authored.

use super::*;
use crate::depth_goal::{DepthGoalBinding, DepthGoalCompletion, DepthGoalOps, DepthGoalVerdict};
use crate::device_ops::{DeviceOps, DeviceResult, ImageData, NullDeviceOps, PlateSolveResult};
use crate::{FilterPlan, NodeType, SequenceDefinition, SmartExposureConfig};
use async_trait::async_trait;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

/// Delegates to [`NullDeviceOps`] except that filter moves are instant and
/// every exposure is counted under the filter the wheel was last set to.
struct RecordingOps {
    inner: NullDeviceOps,
    current_filter: Mutex<Option<String>>,
    exposures_by_filter: Mutex<HashMap<String, u32>>,
    total_exposures: Arc<AtomicU32>,
}

impl RecordingOps {
    fn new(total_exposures: Arc<AtomicU32>) -> Self {
        Self {
            inner: NullDeviceOps,
            current_filter: Mutex::new(None),
            exposures_by_filter: Mutex::new(HashMap::new()),
            total_exposures,
        }
    }

    fn exposures(&self, filter: &str) -> u32 {
        self.exposures_by_filter
            .lock()
            .unwrap()
            .get(filter)
            .copied()
            .unwrap_or(0)
    }
}

#[async_trait]
impl DeviceOps for RecordingOps {
    async fn camera_start_exposure(
        &self,
        camera_id: &str,
        _duration_secs: f64,
        gain: Option<i32>,
        offset: Option<i32>,
        bin_x: i32,
        bin_y: i32,
    ) -> DeviceResult<crate::device_ops::ImageData> {
        let filter = self
            .current_filter
            .lock()
            .unwrap()
            .clone()
            .unwrap_or_else(|| "<none>".to_string());
        *self
            .exposures_by_filter
            .lock()
            .unwrap()
            .entry(filter)
            .or_insert(0) += 1;
        self.total_exposures.fetch_add(1, Ordering::SeqCst);
        self.inner
            .camera_start_exposure(camera_id, 0.01, gain, offset, bin_x, bin_y)
            .await
    }

    async fn filterwheel_set_position(&self, _fw_id: &str, _position: i32) -> DeviceResult<()> {
        Ok(())
    }

    async fn filterwheel_set_filter_by_name(&self, _fw_id: &str, name: &str) -> DeviceResult<i32> {
        *self.current_filter.lock().unwrap() = Some(name.to_string());
        Ok(1)
    }

    async fn filterwheel_get_names(&self, _fw_id: &str) -> DeviceResult<Vec<String>> {
        Ok(vec!["L".into(), "R".into()])
    }

    // Everything else delegates to the null double.

    fn calculate_altitude(&self, ra_hours: f64, dec_degrees: f64, lat: f64, lon: f64) -> f64 {
        self.inner
            .calculate_altitude(ra_hours, dec_degrees, lat, lon)
    }

    fn get_observer_location(&self) -> Option<(f64, f64)> {
        self.inner.get_observer_location()
    }

    async fn mount_slew_to_coordinates(
        &self,
        mount_id: &str,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> DeviceResult<()> {
        self.inner
            .mount_slew_to_coordinates(mount_id, ra_hours, dec_degrees)
            .await
    }

    async fn mount_abort_slew(&self, mount_id: &str) -> DeviceResult<()> {
        self.inner.mount_abort_slew(mount_id).await
    }

    async fn mount_get_coordinates(&self, mount_id: &str) -> DeviceResult<(f64, f64)> {
        self.inner.mount_get_coordinates(mount_id).await
    }

    async fn mount_sync(
        &self,
        mount_id: &str,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> DeviceResult<()> {
        self.inner.mount_sync(mount_id, ra_hours, dec_degrees).await
    }

    async fn mount_park(&self, mount_id: &str) -> DeviceResult<()> {
        self.inner.mount_park(mount_id).await
    }

    async fn mount_unpark(&self, mount_id: &str) -> DeviceResult<()> {
        self.inner.mount_unpark(mount_id).await
    }

    async fn mount_is_slewing(&self, mount_id: &str) -> DeviceResult<bool> {
        self.inner.mount_is_slewing(mount_id).await
    }

    async fn mount_is_parked(&self, mount_id: &str) -> DeviceResult<bool> {
        self.inner.mount_is_parked(mount_id).await
    }

    async fn mount_can_flip(&self, mount_id: &str) -> DeviceResult<bool> {
        self.inner.mount_can_flip(mount_id).await
    }

    async fn mount_side_of_pier(&self, mount_id: &str) -> DeviceResult<crate::meridian::PierSide> {
        self.inner.mount_side_of_pier(mount_id).await
    }

    async fn mount_is_tracking(&self, mount_id: &str) -> DeviceResult<bool> {
        self.inner.mount_is_tracking(mount_id).await
    }

    async fn mount_set_tracking(&self, mount_id: &str, enabled: bool) -> DeviceResult<()> {
        self.inner.mount_set_tracking(mount_id, enabled).await
    }

    async fn camera_abort_exposure(&self, camera_id: &str) -> DeviceResult<()> {
        self.inner.camera_abort_exposure(camera_id).await
    }

    async fn camera_set_cooler(
        &self,
        camera_id: &str,
        enabled: bool,
        target_temp: f64,
    ) -> DeviceResult<()> {
        self.inner
            .camera_set_cooler(camera_id, enabled, target_temp)
            .await
    }

    async fn camera_get_temperature(&self, camera_id: &str) -> DeviceResult<f64> {
        self.inner.camera_get_temperature(camera_id).await
    }

    async fn camera_get_cooler_power(&self, camera_id: &str) -> DeviceResult<f64> {
        self.inner.camera_get_cooler_power(camera_id).await
    }

    async fn focuser_move_to(&self, focuser_id: &str, position: i32) -> DeviceResult<()> {
        self.inner.focuser_move_to(focuser_id, position).await
    }

    async fn focuser_get_position(&self, focuser_id: &str) -> DeviceResult<i32> {
        self.inner.focuser_get_position(focuser_id).await
    }

    async fn focuser_is_moving(&self, focuser_id: &str) -> DeviceResult<bool> {
        self.inner.focuser_is_moving(focuser_id).await
    }

    async fn focuser_get_temperature(&self, focuser_id: &str) -> DeviceResult<Option<f64>> {
        self.inner.focuser_get_temperature(focuser_id).await
    }

    async fn focuser_halt(&self, focuser_id: &str) -> DeviceResult<()> {
        self.inner.focuser_halt(focuser_id).await
    }

    async fn filterwheel_get_position(&self, fw_id: &str) -> DeviceResult<i32> {
        self.inner.filterwheel_get_position(fw_id).await
    }

    async fn rotator_move_to(&self, rotator_id: &str, angle: f64) -> DeviceResult<()> {
        self.inner.rotator_move_to(rotator_id, angle).await
    }

    async fn rotator_move_relative(&self, rotator_id: &str, delta: f64) -> DeviceResult<()> {
        self.inner.rotator_move_relative(rotator_id, delta).await
    }

    async fn rotator_get_angle(&self, rotator_id: &str) -> DeviceResult<f64> {
        self.inner.rotator_get_angle(rotator_id).await
    }

    async fn rotator_halt(&self, rotator_id: &str) -> DeviceResult<()> {
        self.inner.rotator_halt(rotator_id).await
    }

    async fn guider_dither(
        &self,
        pixels: f64,
        settle_pixels: f64,
        settle_time: f64,
        settle_timeout: f64,
        ra_only: bool,
    ) -> DeviceResult<()> {
        self.inner
            .guider_dither(pixels, settle_pixels, settle_time, settle_timeout, ra_only)
            .await
    }

    async fn guider_get_status(&self) -> DeviceResult<GuidingStatus> {
        self.inner.guider_get_status().await
    }

    async fn guider_start(
        &self,
        settle_pixels: f64,
        settle_time: f64,
        settle_timeout: f64,
    ) -> DeviceResult<()> {
        self.inner
            .guider_start(settle_pixels, settle_time, settle_timeout)
            .await
    }

    async fn guider_stop(&self) -> DeviceResult<()> {
        self.inner.guider_stop().await
    }

    async fn plate_solve(
        &self,
        image_data: &ImageData,
        hint_ra: Option<f64>,
        hint_dec: Option<f64>,
        hint_scale: Option<f64>,
    ) -> DeviceResult<PlateSolveResult> {
        self.inner
            .plate_solve(image_data, hint_ra, hint_dec, hint_scale)
            .await
    }

    async fn save_fits(
        &self,
        image_data: &ImageData,
        file_path: &str,
        frame_ctx: &crate::scheduling::FrameContext,
    ) -> DeviceResult<()> {
        self.inner.save_fits(image_data, file_path, frame_ctx).await
    }

    async fn send_notification(
        &self,
        level: &str,
        title: &str,
        message: &str,
        explicit_transports: Option<&[String]>,
    ) -> DeviceResult<()> {
        self.inner
            .send_notification(level, title, message, explicit_transports)
            .await
    }

    async fn polar_align_update(
        &self,
        result: &crate::polar_align::PolarAlignResult,
    ) -> DeviceResult<()> {
        self.inner.polar_align_update(result).await
    }

    async fn dome_open(&self, dome_id: &str) -> DeviceResult<()> {
        self.inner.dome_open(dome_id).await
    }

    async fn dome_close(&self, dome_id: &str) -> DeviceResult<()> {
        self.inner.dome_close(dome_id).await
    }

    async fn dome_park(&self, dome_id: &str) -> DeviceResult<()> {
        self.inner.dome_park(dome_id).await
    }

    async fn dome_get_shutter_status(&self, dome_id: &str) -> DeviceResult<String> {
        self.inner.dome_get_shutter_status(dome_id).await
    }

    async fn safety_is_safe(&self, safety_id: Option<&str>) -> DeviceResult<bool> {
        self.inner.safety_is_safe(safety_id).await
    }

    async fn calculate_image_hfr(&self, image_data: &ImageData) -> DeviceResult<Option<f64>> {
        self.inner.calculate_image_hfr(image_data).await
    }

    async fn detect_stars_in_image(
        &self,
        image_data: &ImageData,
    ) -> DeviceResult<Vec<(f64, f64, f64)>> {
        self.inner.detect_stars_in_image(image_data).await
    }

    async fn cover_calibrator_open_cover(&self, device_id: &str) -> DeviceResult<()> {
        self.inner.cover_calibrator_open_cover(device_id).await
    }

    async fn cover_calibrator_close_cover(&self, device_id: &str) -> DeviceResult<()> {
        self.inner.cover_calibrator_close_cover(device_id).await
    }

    async fn cover_calibrator_halt_cover(&self, device_id: &str) -> DeviceResult<()> {
        self.inner.cover_calibrator_halt_cover(device_id).await
    }

    async fn cover_calibrator_calibrator_on(
        &self,
        device_id: &str,
        brightness: i32,
    ) -> DeviceResult<()> {
        self.inner
            .cover_calibrator_calibrator_on(device_id, brightness)
            .await
    }

    async fn cover_calibrator_calibrator_off(&self, device_id: &str) -> DeviceResult<()> {
        self.inner.cover_calibrator_calibrator_off(device_id).await
    }

    async fn cover_calibrator_get_cover_state(&self, device_id: &str) -> DeviceResult<i32> {
        self.inner.cover_calibrator_get_cover_state(device_id).await
    }

    async fn cover_calibrator_get_calibrator_state(&self, device_id: &str) -> DeviceResult<i32> {
        self.inner
            .cover_calibrator_get_calibrator_state(device_id)
            .await
    }

    async fn cover_calibrator_get_brightness(&self, device_id: &str) -> DeviceResult<i32> {
        self.inner.cover_calibrator_get_brightness(device_id).await
    }

    async fn cover_calibrator_get_max_brightness(&self, device_id: &str) -> DeviceResult<i32> {
        self.inner
            .cover_calibrator_get_max_brightness(device_id)
            .await
    }
}

/// Answers `Achieved` for one goal id + revision once the shared exposure
/// counter reaches `achieve_after`; `Continue` before that; `Unavailable`
/// for any other goal.
struct ScriptedDepthOps {
    goal_id: String,
    revision: u64,
    achieve_after: u32,
    total_exposures: Arc<AtomicU32>,
    /// The completion's own goal id / revision — normally the binding's, but
    /// a test can make them disagree to model a confused store.
    answer_revision: u64,
    asked: AtomicU32,
}

impl DepthGoalOps for ScriptedDepthOps {
    fn verdict(&self, binding: &DepthGoalBinding) -> DepthGoalVerdict {
        self.asked.fetch_add(1, Ordering::SeqCst);
        if binding.goal_id != self.goal_id || binding.revision != self.revision {
            return DepthGoalVerdict::Unavailable {
                reason: format!(
                    "goal {} is at revision {}, not {}",
                    binding.goal_id, self.revision, binding.revision
                ),
            };
        }
        if self.total_exposures.load(Ordering::SeqCst) < self.achieve_after {
            return DepthGoalVerdict::Continue {
                reason: "still collecting".to_string(),
            };
        }
        DepthGoalVerdict::Achieved(DepthGoalCompletion {
            goal_id: self.goal_id.clone(),
            revision: self.answer_revision,
            evidence_frames: 48,
            confirmation_frames: 16,
            score: 7.3,
            threshold: 5.0,
        })
    }
}

fn two_filter_sequence(
    l_count: u32,
    r_count: u32,
    binding: Option<DepthGoalBinding>,
    rotate_filters: bool,
) -> SequenceDefinition {
    let mut sequence = SequenceDefinition::new("DepthLock probe".to_string());
    sequence.nodes.push(crate::NodeDefinition {
        id: "root".to_string(),
        name: "Target".to_string(),
        node_type: NodeType::TargetHeader(crate::TargetHeaderConfig {
            target_name: "Faint Nebula".to_string(),
            ra_hours: 5.5,
            dec_degrees: 22.0,
            ..Default::default()
        }),
        enabled: true,
        children: vec!["smart".to_string()],
    });
    sequence.nodes.push(crate::NodeDefinition {
        id: "smart".to_string(),
        name: "Smart Exposure".to_string(),
        node_type: NodeType::SmartExposure(SmartExposureConfig {
            plans: vec![
                FilterPlan {
                    filter_name: "L".to_string(),
                    count: l_count,
                    duration_secs: 0.01,
                    depth_goal: binding,
                    ..Default::default()
                },
                FilterPlan {
                    filter_name: "R".to_string(),
                    count: r_count,
                    duration_secs: 0.01,
                    ..Default::default()
                },
            ],
            rotate_filters,
            batch_size: 1,
            ..Default::default()
        }),
        enabled: true,
        children: vec![],
    });
    sequence.root_node_id = Some("root".to_string());
    sequence
}

struct RunOutcome {
    state: ExecutorState,
    completions: Vec<(String, DepthGoalCompletion)>,
    warnings: Vec<String>,
}

async fn run(
    sequence: SequenceDefinition,
    ops: Arc<RecordingOps>,
    depth_ops: Option<Arc<ScriptedDepthOps>>,
) -> RunOutcome {
    let dir = std::env::temp_dir().join(format!("ns-depthlock-{}", uuid::Uuid::new_v4()));
    let mut executor = SequenceExecutor::new();
    executor.set_device_ops(ops);
    executor.set_depth_goal_ops(depth_ops.map(|d| d as crate::depth_goal::SharedDepthGoalOps));
    executor.load_sequence(sequence).expect("sequence loads");
    executor.set_save_path(Some(dir.clone()));
    executor.set_devices(
        Some("cam-1".to_string()),
        None,
        None,
        Some("fw-1".to_string()),
        None,
    );
    let mut events = executor.subscribe();

    executor.start().await.expect("run starts");
    let mut state = executor.get_state().await;
    for _ in 0..2_000 {
        state = executor.get_state().await;
        if matches!(
            state,
            ExecutorState::Completed | ExecutorState::Failed | ExecutorState::Cancelled
        ) {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    executor.stop().await.ok();
    let _ = std::fs::remove_dir_all(&dir);

    let mut completions = Vec::new();
    let mut warnings = Vec::new();
    while let Ok(event) = events.try_recv() {
        match event {
            ExecutorEvent::DepthGoalCompleted {
                filter_name,
                completion,
                ..
            } => completions.push((filter_name, completion)),
            ExecutorEvent::Warning { message } if message.contains("DepthLock") => {
                warnings.push(message)
            }
            _ => {}
        }
    }
    RunOutcome {
        state,
        completions,
        warnings,
    }
}

fn binding() -> DepthGoalBinding {
    DepthGoalBinding {
        goal_id: "goal-l".to_string(),
        revision: 3,
    }
}

fn scripted(achieve_after: u32, counter: &Arc<AtomicU32>) -> Arc<ScriptedDepthOps> {
    Arc::new(ScriptedDepthOps {
        goal_id: "goal-l".to_string(),
        revision: 3,
        achieve_after,
        total_exposures: counter.clone(),
        answer_revision: 3,
        asked: AtomicU32::new(0),
    })
}

/// Acceptance scenario 1: the achieved filter completes early, the other
/// filter continues through the same node to its count, and the transition
/// is explained once.
#[tokio::test]
async fn an_achieved_goal_completes_its_filter_and_the_other_runs_to_count() {
    let counter = Arc::new(AtomicU32::new(0));
    let ops = Arc::new(RecordingOps::new(counter.clone()));
    // Rotation L,R,L,R,… : the verdict flips after the 4th exposure, so L is
    // retired at the boundary before its third frame.
    let depth = scripted(4, &counter);
    let outcome = run(
        two_filter_sequence(6, 3, Some(binding()), true),
        ops.clone(),
        Some(depth),
    )
    .await;

    assert_eq!(outcome.state, ExecutorState::Completed);
    assert_eq!(
        ops.exposures("L"),
        2,
        "L stops at the boundary after the verdict"
    );
    assert_eq!(
        ops.exposures("R"),
        3,
        "R is unaffected and runs to its count"
    );
    assert_eq!(outcome.completions.len(), 1, "exactly one completion event");
    let (filter, completion) = &outcome.completions[0];
    assert_eq!(filter, "L");
    assert_eq!(completion.goal_id, "goal-l");
    assert_eq!(completion.revision, 3);
    assert_eq!(completion.evidence_frames, 48);
    assert!(
        outcome.warnings.is_empty(),
        "no DepthLock warnings: {:?}",
        outcome.warnings
    );
}

/// Drain mode (`rotate_filters = false`) would normally take L's whole count
/// in one burst; a bound plan is stepped at `batch_size` so the verdict is
/// still honored mid-plan.
#[tokio::test]
async fn a_bound_plan_in_drain_mode_still_completes_between_exposures() {
    let counter = Arc::new(AtomicU32::new(0));
    let ops = Arc::new(RecordingOps::new(counter.clone()));
    let depth = scripted(2, &counter);
    let outcome = run(
        two_filter_sequence(5, 2, Some(binding()), false),
        ops.clone(),
        Some(depth),
    )
    .await;

    assert_eq!(outcome.state, ExecutorState::Completed);
    assert_eq!(ops.exposures("L"), 2);
    assert_eq!(ops.exposures("R"), 2);
    assert_eq!(outcome.completions.len(), 1);
}

/// Acceptance scenario 7: the count limit arriving first ends the plan as
/// authored and does NOT produce a completion — the goal stays open.
#[tokio::test]
async fn a_still_collecting_goal_leaves_the_bounded_plan_unchanged() {
    let counter = Arc::new(AtomicU32::new(0));
    let ops = Arc::new(RecordingOps::new(counter.clone()));
    let depth = scripted(u32::MAX, &counter);
    let outcome = run(
        two_filter_sequence(3, 2, Some(binding()), true),
        ops.clone(),
        Some(depth.clone()),
    )
    .await;

    assert_eq!(outcome.state, ExecutorState::Completed);
    assert_eq!(ops.exposures("L"), 3);
    assert_eq!(ops.exposures("R"), 2);
    assert!(outcome.completions.is_empty());
    assert!(outcome.warnings.is_empty());
    assert!(
        depth.asked.load(Ordering::SeqCst) >= 3,
        "the store is consulted at each boundary"
    );
}

/// Acceptance scenario 6: a binding to a revision the store has moved past
/// cannot complete the plan; the operator is warned exactly once.
#[tokio::test]
async fn a_stale_revision_binding_is_warned_once_and_runs_to_count() {
    let counter = Arc::new(AtomicU32::new(0));
    let ops = Arc::new(RecordingOps::new(counter.clone()));
    let stale = DepthGoalBinding {
        goal_id: "goal-l".to_string(),
        revision: 2,
    };
    let depth = scripted(0, &counter);
    let outcome = run(
        two_filter_sequence(3, 2, Some(stale), true),
        ops.clone(),
        Some(depth),
    )
    .await;

    assert_eq!(outcome.state, ExecutorState::Completed);
    assert_eq!(ops.exposures("L"), 3);
    assert_eq!(ops.exposures("R"), 2);
    assert!(outcome.completions.is_empty());
    assert_eq!(outcome.warnings.len(), 1, "{:?}", outcome.warnings);
    assert!(outcome.warnings[0].contains("goal-l revision 2"));
    assert!(outcome.warnings[0].contains("authored count"));
}

/// A store that answers for the wrong revision (a confused or late worker)
/// is treated as unavailable, never as an authorization.
#[tokio::test]
async fn an_achieved_answer_for_another_revision_does_not_complete_the_plan() {
    let counter = Arc::new(AtomicU32::new(0));
    let ops = Arc::new(RecordingOps::new(counter.clone()));
    let depth = Arc::new(ScriptedDepthOps {
        goal_id: "goal-l".to_string(),
        revision: 3,
        achieve_after: 0,
        total_exposures: counter.clone(),
        answer_revision: 4,
        asked: AtomicU32::new(0),
    });
    let outcome = run(
        two_filter_sequence(3, 1, Some(binding()), true),
        ops.clone(),
        Some(depth),
    )
    .await;

    assert_eq!(outcome.state, ExecutorState::Completed);
    assert_eq!(ops.exposures("L"), 3);
    assert!(outcome.completions.is_empty());
    assert_eq!(outcome.warnings.len(), 1);
    assert!(outcome.warnings[0].contains("revision 4 instead of goal-l revision 3"));
}

/// Without a verdict source (a host with no goal store) a bound plan is an
/// ordinary count-bounded plan plus one warning.
#[tokio::test]
async fn no_verdict_source_keeps_the_bounded_plan_with_one_warning() {
    let counter = Arc::new(AtomicU32::new(0));
    let ops = Arc::new(RecordingOps::new(counter.clone()));
    let outcome = run(
        two_filter_sequence(3, 2, Some(binding()), true),
        ops.clone(),
        None,
    )
    .await;

    assert_eq!(outcome.state, ExecutorState::Completed);
    assert_eq!(ops.exposures("L"), 3);
    assert_eq!(ops.exposures("R"), 2);
    assert!(outcome.completions.is_empty());
    assert_eq!(outcome.warnings.len(), 1, "{:?}", outcome.warnings);
    assert!(outcome.warnings[0].contains("no DepthLock goal store"));
}

/// Acceptance scenario 8 (prior behaviour): an unbound sequence never
/// touches the verdict source.
#[tokio::test]
async fn an_unbound_sequence_never_consults_the_store() {
    let counter = Arc::new(AtomicU32::new(0));
    let ops = Arc::new(RecordingOps::new(counter.clone()));
    let depth = scripted(0, &counter);
    let outcome = run(
        two_filter_sequence(2, 2, None, true),
        ops.clone(),
        Some(depth.clone()),
    )
    .await;

    assert_eq!(outcome.state, ExecutorState::Completed);
    assert_eq!(ops.exposures("L"), 2);
    assert_eq!(ops.exposures("R"), 2);
    assert!(outcome.completions.is_empty());
    assert_eq!(depth.asked.load(Ordering::SeqCst), 0);
}

/// A pre-feature checkpoint has no `depth_completed`; a resumed one carrying
/// a completion is honored without re-announcing it.
#[test]
fn checkpoint_depth_completed_is_optional_on_the_wire() {
    let legacy = r#"{"per_filter_completed":{"L":2},"current_plan_index":1,"completed_integration_secs":120.0}"#;
    let restored: crate::SmartExposureCheckpoint =
        serde_json::from_str(legacy).expect("legacy loads");
    assert!(restored.depth_completed.is_empty());

    let mut with_completion = restored.clone();
    with_completion
        .depth_completed
        .insert("goal-l".to_string(), 3);
    let json = serde_json::to_string(&with_completion).unwrap();
    let round: crate::SmartExposureCheckpoint = serde_json::from_str(&json).unwrap();
    assert_eq!(round.depth_completed.get("goal-l"), Some(&3));
}

/// The binding is optional in the sequence document: pre-feature plans
/// deserialize with `depth_goal: None`, and a bound plan round-trips.
#[test]
fn filter_plan_binding_is_optional_on_the_wire() {
    let legacy = r#"{"filter_name":"L","count":10,"duration_secs":60.0}"#;
    let plan: FilterPlan = serde_json::from_str(legacy).expect("legacy plan loads");
    assert!(plan.depth_goal.is_none());
    let serialized = serde_json::to_value(&plan).unwrap();
    assert!(
        serialized.get("depth_goal").is_none(),
        "unbound plans do not grow a field"
    );

    let bound = FilterPlan {
        depth_goal: Some(binding()),
        ..plan
    };
    let json = serde_json::to_string(&bound).unwrap();
    assert!(json.contains(r#""depth_goal":{"goal_id":"goal-l","revision":3}"#));
    let round: FilterPlan = serde_json::from_str(&json).unwrap();
    assert_eq!(round.depth_goal, Some(binding()));
}
