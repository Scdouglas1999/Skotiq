//! Scenario sims for the ways a run ends at the end of the night: the plan's
//! shutdown steps after its targets must still run when a trigger ends the
//! night by cancelling the node tree.

use super::scenario_sim_tests::{
    bring_dawn_near, drain_fired_and_errors, start_run_in_guide_star_recovery, wait_for_monitor,
    wait_for_state, ScriptedDeviceOps, DAWN_OFF,
};
use crate::device_ops::SharedDeviceOps;
use crate::{
    DelayConfig, LoopCondition, LoopConfig, NodeDefinition, NodeType, SequenceDefinition,
    WarmConfig,
};
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::Duration;

fn node(id: &str, name: &str, node_type: NodeType) -> NodeDefinition {
    NodeDefinition {
        id: id.into(),
        name: name.into(),
        enabled: true,
        node_type,
        children: vec![],
    }
}

/// A plan shaped like the owner's Smart Night plans: one long imaging step,
/// then Stop Guiding, `put_away` and Warm Camera.
fn night_plan(put_away: NodeDefinition) -> SequenceDefinition {
    let steps = vec![
        node(
            "imaging",
            "Imaging",
            NodeType::Delay(DelayConfig { seconds: 600.0 }),
        ),
        node("stop-guiding", "Stop Guiding", NodeType::StopGuiding),
        put_away,
        node(
            "warm",
            "Warm camera",
            NodeType::WarmCamera(WarmConfig::default()),
        ),
    ];
    let mut root = node(
        "root",
        "Night",
        NodeType::Loop(LoopConfig {
            iterations: Some(1),
            condition: LoopCondition::Count,
            ..Default::default()
        }),
    );
    root.children = steps.iter().map(|n| n.id.clone()).collect();
    let mut sequence = SequenceDefinition::new("Night".into());
    sequence.root_node_id = Some("root".into());
    sequence.nodes = std::iter::once(root).chain(steps).collect();
    sequence
}

async fn start_night(
    mut executor: super::SequenceExecutor,
    ops: Arc<ScriptedDeviceOps>,
    plan: SequenceDefinition,
) -> super::SequenceExecutor {
    ops.cooler_idle.store(true, Ordering::SeqCst);
    executor.set_devices(
        Some("cam-1".to_string()),
        Some("mount-1".to_string()),
        None,
        None,
        None,
    );
    executor.set_device_ops(ops as SharedDeviceOps);
    executor.load_sequence(plan).expect("sequence loads");
    executor.start().await.expect("executor starts");
    executor
}

async fn wait_until_finished(executor: &super::SequenceExecutor) -> super::ExecutorState {
    wait_for_state(executor, Duration::from_secs(20), |s| {
        matches!(
            s,
            super::ExecutorState::Cancelled
                | super::ExecutorState::Completed
                | super::ExecutorState::Failed
        )
    })
    .await
}

fn notified(calls: &[String], text: &str) -> bool {
    calls
        .iter()
        .any(|c| c.starts_with("notify:") && c.contains(text))
}

/// The dawn park ends the run and the plan's own shutdown still runs:
/// guiding stopped, the mount left parked rather than sent home from the park
/// position, and the camera warmed. Every step is told to the operator.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn dawn_park_still_runs_the_plans_shutdown_steps() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    let plan = night_plan(node("home", "Home mount", NodeType::HomeMount));
    let mut executor = start_night(super::SequenceExecutor::new(), ops.clone(), plan).await;
    wait_for_monitor(&ops).await;

    bring_dawn_near(&executor).await;
    let state = wait_until_finished(&executor).await;
    let calls = ops.calls();
    let _ = executor.stop().await;

    assert_eq!(state, super::ExecutorState::Cancelled, "calls={calls:?}");
    let park = calls.iter().position(|c| c == "mount_park:mount-1");
    let warm = calls
        .iter()
        .position(|c| c == "camera_set_cooler:cam-1:false");
    assert!(park.is_some(), "dawn must park; calls={calls:?}");
    assert!(
        warm.is_some_and(|w| w > park.unwrap()),
        "the plan's Warm camera must run after the park; calls={calls:?}"
    );
    assert_eq!(
        calls.iter().filter(|c| *c == "guider_stop").count(),
        1,
        "guiding is stopped once, by the park; calls={calls:?}"
    );
    assert!(
        !calls.iter().any(|c| c.starts_with("mount_find_home")),
        "a parked mount is not sent home; calls={calls:?}"
    );
    assert!(notified(&calls, "Home mount: not run"), "calls={calls:?}");
    assert!(notified(&calls, "Warm camera: done"), "calls={calls:?}");
}

/// With Park before dawn off, the plan's own Park step is what puts the mount
/// away, and the operator is told so rather than that it may still track.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn dawn_without_parking_runs_the_plans_own_park_and_warm() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    let mut executor = super::SequenceExecutor::new();
    let mut events = executor.subscribe();
    executor.set_park_policy(DAWN_OFF);
    let plan = night_plan(node("park", "Park mount", NodeType::Park));
    let mut executor = start_night(executor, ops.clone(), plan).await;
    wait_for_monitor(&ops).await;

    bring_dawn_near(&executor).await;
    let state = wait_until_finished(&executor).await;
    let calls = ops.calls();
    let _ = executor.stop().await;
    let (_, errors) = drain_fired_and_errors(&mut events);

    assert_eq!(state, super::ExecutorState::Cancelled, "calls={calls:?}");
    assert!(calls.iter().any(|c| c == "guider_stop"), "calls={calls:?}");
    assert!(
        calls.iter().any(|c| c == "mount_park:mount-1"),
        "the plan's Park step must run; calls={calls:?}"
    );
    assert!(
        calls.iter().any(|c| c == "camera_set_cooler:cam-1:false"),
        "calls={calls:?}"
    );
    assert!(
        errors
            .iter()
            .any(|m| m.contains("plan's own shutdown steps")),
        "errors={errors:?}"
    );
}

/// A weather park in the middle of the night does not end the night: the
/// camera stays cold for when the sky clears.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_weather_park_does_not_run_the_end_of_night_steps() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    let plan = night_plan(node("home", "Home mount", NodeType::HomeMount));
    let mut executor = start_night(super::SequenceExecutor::new(), ops.clone(), plan).await;
    wait_for_monitor(&ops).await;

    executor.update_weather_verdict(Some(true)).await;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while ops.call_count("mount_park") == 0 && tokio::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    tokio::time::sleep(Duration::from_secs(2)).await;
    let calls = ops.calls();
    let _ = executor.stop().await;

    assert!(
        calls.iter().any(|c| c == "mount_park:mount-1"),
        "calls={calls:?}"
    );
    assert!(
        !calls.iter().any(|c| c.starts_with("camera_set_cooler")),
        "calls={calls:?}"
    );
}

fn target_plan(end_when: crate::scheduling::TargetTrigger) -> SequenceDefinition {
    let config: crate::TargetHeaderConfig = serde_json::from_value(serde_json::json!({
        "target_name": "NGC0891",
        "ra_hours": 2.376,
        "dec_degrees": 42.35,
        "rotation": null,
        "priority": 0,
        "min_altitude": null,
        "max_altitude": null,
    }))
    .unwrap();
    let mut target = node(
        "target",
        "Target — NGC0891",
        NodeType::TargetHeader(crate::TargetHeaderConfig {
            end_when: Some(end_when),
            ..config
        }),
    );
    target.children = vec!["imaging".into()];
    let imaging = node(
        "imaging",
        "Imaging",
        NodeType::Delay(DelayConfig { seconds: 600.0 }),
    );
    let warm = node(
        "warm",
        "Warm camera",
        NodeType::WarmCamera(WarmConfig::default()),
    );
    let mut root = node(
        "root",
        "Night",
        NodeType::Loop(LoopConfig {
            iterations: Some(1),
            condition: LoopCondition::Count,
            ..Default::default()
        }),
    );
    root.children = vec!["target".into(), "warm".into()];
    let mut sequence = SequenceDefinition::new("Night".into());
    sequence.root_node_id = Some("root".into());
    sequence.nodes = vec![root, target, imaging, warm];
    sequence
}

/// A plan that kept last night's absolute stop time images tonight: the time
/// is moved to tonight and the operator is told, instead of the target being
/// skipped and the camera warmed at dusk.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn last_nights_stop_time_is_rolled_to_tonight_and_the_target_images() {
    use crate::scheduling::TargetTrigger;
    let ops = Arc::new(ScriptedDeviceOps::new());
    let executor = super::SequenceExecutor::new();
    let mut events = executor.subscribe();
    let yesterday_morning = chrono::Utc::now().timestamp() - 15 * 3600;
    let plan = target_plan(TargetTrigger::TimeAfter(yesterday_morning));
    let mut executor = start_night(executor, ops.clone(), plan).await;
    tokio::time::sleep(Duration::from_secs(2)).await;
    let state = executor.get_state().await;
    let calls = ops.calls();
    let _ = executor.stop().await;

    let mut warnings = Vec::new();
    let mut skipped = false;
    while let Ok(event) = events.try_recv() {
        match event {
            super::ExecutorEvent::Warning { message } => warnings.push(message),
            super::ExecutorEvent::TriggerFired { trigger_id, .. }
                if trigger_id == crate::node::logic::target_header::TARGET_END_WHEN_TRIGGER_ID =>
            {
                skipped = true
            }
            _ => {}
        }
    }
    assert_eq!(state, super::ExecutorState::Running, "calls={calls:?}");
    assert!(!skipped, "the target must not be skipped");
    assert!(
        warnings
            .iter()
            .any(|m| m.contains("earlier night") && m.contains("NGC0891")),
        "warnings={warnings:?}"
    );
    assert!(
        !calls.iter().any(|c| c.starts_with("camera_set_cooler")),
        "the camera must not be warmed at dusk; calls={calls:?}"
    );
}

/// A plan whose only target's end time passed earlier tonight refuses to
/// start with a clear message: no shutdown steps run and no 0-frame run is
/// recorded as completed.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_plan_with_nothing_left_to_image_refuses_to_start() {
    use crate::scheduling::TargetTrigger;
    let ops = Arc::new(ScriptedDeviceOps::new());
    ops.cooler_idle.store(true, Ordering::SeqCst);
    let mut executor = super::SequenceExecutor::new();
    executor.set_devices(
        Some("cam-1".to_string()),
        Some("mount-1".to_string()),
        None,
        None,
        None,
    );
    executor.set_device_ops(ops.clone() as SharedDeviceOps);
    let an_hour_ago = chrono::Utc::now().timestamp() - 3600;
    executor
        .load_sequence(target_plan(TargetTrigger::TimeAfter(an_hour_ago)))
        .expect("sequence loads");
    let refusal = executor.start().await.expect_err("start is refused");
    assert!(refusal.contains("Nothing to image"), "{refusal}");
    assert_eq!(executor.get_state().await, super::ExecutorState::Idle);
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(ops.calls().is_empty(), "calls={:?}", ops.calls());
}

/// A run that dawn ends in the middle of a guide-star recovery takes the
/// recovery with it: the status API stops reporting one, so no banner is left
/// on screen after the night.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn dawn_during_a_recovery_ends_the_recovery_with_the_run() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    let mut executor = start_run_in_guide_star_recovery(ops.clone(), 30.0).await;
    assert!(executor.current_recovery().is_some());

    bring_dawn_near(&executor).await;
    let state = wait_until_finished(&executor).await;
    let recovery = executor.current_recovery();
    let calls = ops.calls();
    let _ = executor.stop().await;

    assert_eq!(state, super::ExecutorState::Cancelled, "calls={calls:?}");
    assert!(recovery.is_none(), "recovery={recovery:?}");
}

/// With end-of-night calibration to follow, the plan's Warm Camera step is
/// deferred: the camera stays at its set-point for the darks.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn dawn_park_leaves_a_deferred_warm_up_to_calibration() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    let mut plan = night_plan(node("home", "Home mount", NodeType::HomeMount));
    for n in &mut plan.nodes {
        if let NodeType::WarmCamera(config) = &mut n.node_type {
            config.defer_to_calibration = true;
        }
    }
    let mut executor = start_night(super::SequenceExecutor::new(), ops.clone(), plan).await;
    wait_for_monitor(&ops).await;

    bring_dawn_near(&executor).await;
    let state = wait_until_finished(&executor).await;
    let calls = ops.calls();
    let _ = executor.stop().await;

    assert_eq!(state, super::ExecutorState::Cancelled, "calls={calls:?}");
    assert!(
        calls.iter().any(|c| c == "mount_park:mount-1"),
        "calls={calls:?}"
    );
    assert!(
        !calls.iter().any(|c| c.starts_with("camera_set_cooler")),
        "the cooler must stay at its set-point; calls={calls:?}"
    );
    assert!(
        notified(&calls, "Warm camera: not run, end-of-night calibration"),
        "calls={calls:?}"
    );
}
