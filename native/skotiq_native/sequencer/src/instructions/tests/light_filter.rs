//! A capture with no filter of its own never shoots through the dark slot.
//!
//! On 2026-11-03 a stopped end-of-night calibration left the wheel on slot 8
//! "DARK"; the next plan's Center node (`filter: null`) took all five of its
//! solve frames through it, every solve failed and the run went on uncentered.

use super::*;
use crate::node::runtime::{Node, RuntimeNode};

const RIG_WHEEL: [&str; 8] = ["L", "R", "G", "B", "Ha", "OIII", "SII", "DARK"];

fn wheel_ops(names: &[&str], position: i32) -> Arc<ScriptedDomeRotatorOps> {
    let ops = ScriptedDomeRotatorOps {
        filter_names: names.iter().map(|n| n.to_string()).collect(),
        ..ScriptedDomeRotatorOps::new()
    };
    ops.filter_position.store(position, Ordering::SeqCst);
    Arc::new(ops)
}

fn one_attempt_center(filter: Option<&str>) -> CenterConfig {
    CenterConfig {
        use_target_coords: false,
        custom_ra: Some(0.05),
        custom_dec: Some(25.9),
        max_attempts: 1,
        exposure_duration: 0.01,
        filter: filter.map(str::to_string),
        ..CenterConfig::default()
    }
}

async fn center_ctx(ops: Arc<ScriptedDomeRotatorOps>) -> InstructionContext {
    let mut ctx = ctx_with_ops(ops).await;
    ctx.run.rig.mount_id = Some("mount-1".to_string());
    ctx
}

fn planned(name: &str, index: Option<i32>) -> PlannedLightFilter {
    PlannedLightFilter {
        name: Some(name.to_string()),
        index,
    }
}

#[tokio::test(start_paused = true)]
async fn center_on_the_dark_slot_moves_to_the_targets_first_light_filter() {
    let ops = wheel_ops(&RIG_WHEEL, 7);
    let mut ctx = center_ctx(ops.clone()).await;
    ctx.target_light_filters = vec![planned("Ha", Some(4)), planned("L", Some(0))];

    execute_center(&one_attempt_center(None), &ctx, None).await;

    assert_eq!(*ops.filter_moves.lock().unwrap(), vec![4]);
    assert_eq!(ops.filter_position.load(Ordering::SeqCst), 4);
    assert!(ops.camera_exposure_calls.load(Ordering::SeqCst) >= 1);
}

#[tokio::test(start_paused = true)]
async fn center_on_the_dark_slot_with_no_target_uses_the_first_slot_that_is_not_dark() {
    let ops = wheel_ops(&["Blank", "L", "R"], 0);
    let ctx = center_ctx(ops.clone()).await;

    execute_center(&one_attempt_center(None), &ctx, None).await;

    assert_eq!(*ops.filter_moves.lock().unwrap(), vec![1]);
    assert!(ops.camera_exposure_calls.load(Ordering::SeqCst) >= 1);
}

#[tokio::test(start_paused = true)]
async fn a_planned_filter_the_wheel_lacks_is_passed_over() {
    let ops = wheel_ops(&RIG_WHEEL, 7);
    let mut ctx = center_ctx(ops.clone()).await;
    ctx.target_light_filters = vec![planned("Lum", None), planned("oiii", None)];

    execute_center(&one_attempt_center(None), &ctx, None).await;

    assert_eq!(*ops.filter_moves.lock().unwrap(), vec![5]);
}

#[tokio::test(start_paused = true)]
async fn center_on_a_light_filter_leaves_the_wheel_alone() {
    let ops = wheel_ops(&RIG_WHEEL, 2);
    let mut ctx = center_ctx(ops.clone()).await;
    ctx.target_light_filters = vec![planned("L", Some(0))];

    execute_center(&one_attempt_center(None), &ctx, None).await;

    assert!(ops.filter_moves.lock().unwrap().is_empty());
    assert!(ops.camera_exposure_calls.load(Ordering::SeqCst) >= 1);
}

#[tokio::test(start_paused = true)]
async fn center_with_no_wheel_invents_no_filter() {
    let ops = wheel_ops(&RIG_WHEEL, 7);
    let mut ctx = center_ctx(ops.clone()).await;
    ctx.run.rig.filterwheel_id = None;

    execute_center(&one_attempt_center(None), &ctx, None).await;

    assert!(ops.filter_moves.lock().unwrap().is_empty());
    assert!(ops.camera_exposure_calls.load(Ordering::SeqCst) >= 1);
}

#[tokio::test(start_paused = true)]
async fn a_wheel_with_only_dark_slots_fails_center_before_it_captures() {
    let ops = wheel_ops(&["Dark", "Cap"], 0);
    let ctx = center_ctx(ops.clone()).await;

    let result = execute_center(&one_attempt_center(None), &ctx, None).await;

    assert_eq!(result.status, NodeStatus::Failure);
    assert!(
        result
            .message
            .as_deref()
            .is_some_and(|m| m.contains("dark slot \"Dark\"")),
        "{:?}",
        result.message
    );
    assert_eq!(ops.camera_exposure_calls.load(Ordering::SeqCst), 0);
}

#[tokio::test(start_paused = true)]
async fn a_stop_while_leaving_the_dark_slot_reads_as_cancelled() {
    let ops = wheel_ops(&RIG_WHEEL, 7);
    let ctx = center_ctx(ops.clone()).await;
    ctx.cancellation_token.store(true, Ordering::SeqCst);

    let result = leave_dark_slot_for_capture(&ctx, "Center")
        .await
        .expect_err("a stopped run cannot move the wheel");

    assert_eq!(result.status, NodeStatus::Cancelled, "{:?}", result.message);
}

#[tokio::test(start_paused = true)]
async fn center_moves_to_the_filter_the_node_names() {
    let ops = wheel_ops(&RIG_WHEEL, 7);
    let mut ctx = center_ctx(ops.clone()).await;
    ctx.target_light_filters = vec![planned("Ha", Some(4))];

    execute_center(&one_attempt_center(Some("r")), &ctx, None).await;

    assert_eq!(*ops.filter_moves.lock().unwrap(), vec![1]);
}

#[tokio::test(start_paused = true)]
async fn a_node_filter_the_wheel_lacks_still_leaves_the_dark_slot() {
    let ops = wheel_ops(&RIG_WHEEL, 7);
    let ctx = center_ctx(ops.clone()).await;

    execute_center(&one_attempt_center(Some("Clear")), &ctx, None).await;

    assert_eq!(*ops.filter_moves.lock().unwrap(), vec![0]);
}

#[tokio::test]
#[allow(clippy::await_holding_lock)]
async fn autofocus_on_the_dark_slot_moves_off_it_and_does_not_restore_it() {
    let _serial = AF_GATE_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let ops = wheel_ops(&RIG_WHEEL, 7);
    let mut ctx = ctx_with_ops(ops.clone()).await;
    ctx.target_light_filters = vec![planned("R", Some(1))];
    // No camera: the sweep itself fails at once, after the filter is set.
    ctx.run.rig.camera_id = None;

    let guard = try_admit_autofocus_run().expect("test autofocus must admit");
    execute_autofocus_admitted(&AutofocusConfig::default(), &ctx, None, guard).await;

    assert_eq!(*ops.filter_moves.lock().unwrap(), vec![1]);
    assert_eq!(ops.filter_position.load(Ordering::SeqCst), 1);
}

#[test]
fn dark_slot_names_match_the_end_of_night_calibration() {
    for name in [
        "DARK", "dark", " Darks ", "Blank", "OPAQUE", "Closed", "shutter", "Cap", "Blocked",
    ] {
        assert!(is_dark_slot_name(name), "{name}");
    }
    for name in ["L", "Ha", "Dark Sky", "Lum", "", "Capella"] {
        assert!(!is_dark_slot_name(name), "{name}");
    }
}

fn exposure_node(id: &str, frame_type: &str, filter: &str, index: Option<i32>) -> RuntimeNode {
    RuntimeNode::from_definition(crate::NodeDefinition {
        id: id.to_string(),
        name: id.to_string(),
        node_type: NodeType::TakeExposure(ExposureConfig {
            frame_type: frame_type.to_string(),
            filter: Some(filter.to_string()),
            filter_index: index,
            ..ExposureConfig::default()
        }),
        enabled: true,
        children: Vec::new(),
    })
}

#[test]
fn a_targets_light_filters_come_from_its_light_exposures_in_order() {
    let mut target = RuntimeNode::from_definition(crate::NodeDefinition {
        id: "target".to_string(),
        name: "NGC 7814".to_string(),
        node_type: NodeType::Delay(DelayConfig { seconds: 0.0 }),
        enabled: true,
        children: Vec::new(),
    });
    target.add_child(Box::new(exposure_node("darks", "Dark", "DARK", Some(7))));
    target.add_child(Box::new(exposure_node("ha", "Light", "Ha", Some(4))));
    let mut smart = RuntimeNode::from_definition(crate::NodeDefinition {
        id: "smart".to_string(),
        name: "smart".to_string(),
        node_type: NodeType::SmartExposure(crate::SmartExposureConfig {
            plans: vec![
                crate::FilterPlan {
                    filter_name: "OIII".to_string(),
                    filter_index: Some(5),
                    ..crate::FilterPlan::default()
                },
                crate::FilterPlan {
                    filter_name: "Ha".to_string(),
                    filter_index: Some(4),
                    ..crate::FilterPlan::default()
                },
            ],
            ..crate::SmartExposureConfig::default()
        }),
        enabled: true,
        children: Vec::new(),
    });
    smart.add_child(Box::new(exposure_node("inner", "Light", "SII", Some(6))));
    target.add_child(Box::new(smart));

    let filters = planned_light_filters(&target as &dyn Node);

    assert_eq!(
        filters,
        vec![
            planned("Ha", Some(4)),
            planned("OIII", Some(5)),
            planned("SII", Some(6)),
        ]
    );
}

#[test]
fn choose_light_slot_prefers_the_index_and_skips_dark_and_blank_slots() {
    let names: Vec<String> = ["", "DARK", "L"].iter().map(|n| n.to_string()).collect();
    assert_eq!(
        choose_light_slot(&names, &[planned("DARK", Some(1))]),
        Some((2, "L".to_string()))
    );
    assert_eq!(choose_light_slot(&names, &[]), Some((2, "L".to_string())));
}
