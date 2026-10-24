//! Scenario sims for the ways a run ends at the end of the night: the plan's
//! shutdown steps after its targets must still run when a trigger ends the
//! night by cancelling the node tree.

use super::scenario_sim_tests::{
    bring_dawn_near, drain_fired_and_errors, wait_for_monitor, wait_for_state, ScriptedDeviceOps,
    DAWN_OFF,
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
