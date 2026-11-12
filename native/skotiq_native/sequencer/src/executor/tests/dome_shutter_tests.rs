//! The Dome Shutter Not Open trigger through a whole executor: the run's Open
//! Dome step arms it, a shutter that closes on its own afterwards fires it,
//! and the run does only what the operator configured.

use super::*;
use crate::executor::scenario_sim_tests::ScriptedDeviceOps;
use crate::triggers::StandardTrigger;
use crate::{
    DelayConfig, DomeConfig, LoopCondition, LoopConfig, NodeDefinition, NodeType, RecoveryAction,
    RecoveryConfig, TriggerType,
};
use std::time::Duration;
use tokio::sync::broadcast;

fn node(id: &str, node_type: NodeType, children: &[&str]) -> NodeDefinition {
    NodeDefinition {
        id: id.to_string(),
        name: id.to_string(),
        node_type,
        enabled: true,
        children: children.iter().map(|c| c.to_string()).collect(),
    }
}

/// One pass of: open the dome (when `open_dome`), then wait a minute inside a
/// Recovery step for a closed shutter (when `recovery` is given).
fn plan(open_dome: bool, recovery: Option<RecoveryAction>) -> SequenceDefinition {
    let mut sequence = SequenceDefinition::new("Dome night".to_string());
    let mut steps = Vec::new();
    if open_dome {
        steps.push("open");
        sequence.nodes.push(node(
            "open",
            NodeType::OpenDome(DomeConfig { shutter_only: true }),
            &[],
        ));
    }
    let wait = node("wait", NodeType::Delay(DelayConfig { seconds: 60.0 }), &[]);
    match recovery {
        Some(action) => {
            steps.push("guard");
            sequence.nodes.push(node(
                "guard",
                NodeType::Recovery(RecoveryConfig {
                    trigger: Some(TriggerType::DomeShutterNotOpen),
                    recovery_action: action,
                    max_retries: 3,
                }),
                &["wait"],
            ));
        }
        None => steps.push("wait"),
    }
    sequence.nodes.push(wait);
    sequence.nodes.push(node(
        "night",
        NodeType::Loop(LoopConfig {
            iterations: Some(1),
            condition: LoopCondition::Count,
            condition_value: None,
            horizon_profile: None,
        }),
        &steps,
    ));
    sequence.root_node_id = Some("night".to_string());
    sequence
}

struct DomeRun {
    executor: SequenceExecutor,
    ops: Arc<ScriptedDeviceOps>,
    events: broadcast::Receiver<ExecutorEvent>,
}

/// Start `sequence` on a rig whose dome reads open, with the standard Dome
/// Shutter Not Open trigger as the only standard trigger armed.
async fn start(sequence: SequenceDefinition) -> DomeRun {
    let ops = Arc::new(ScriptedDeviceOps::new());
    let mut executor = SequenceExecutor::new();
    executor.set_device_ops(ops.clone());
    executor.dome_id = Some("dome-1".to_string());
    executor.set_safety_check_interval_secs(5).await;
    {
        let mut manager = executor.trigger_manager.write().await;
        let ids: Vec<String> = manager.triggers().iter().map(|t| t.id.clone()).collect();
        for id in ids {
            manager.remove_trigger(&id);
        }
        manager.add_trigger(StandardTrigger::DomeShutterNotOpen.build());
    }
    let events = executor.subscribe();
    executor.load_sequence(sequence).expect("sequence loads");
    executor.start().await.expect("run starts");
    DomeRun {
        executor,
        ops,
        events,
    }
}

impl DomeRun {
    async fn expects_open_shutter(&self) -> bool {
        let state = self.executor.trigger_manager.read().await.state();
        let expected = state.read().await.telemetry.dome_shutter_open_expected;
        expected
    }

    async fn wait_until_the_run_expects_an_open_shutter(&self) {
        tokio::time::timeout(Duration::from_secs(10), async {
            while !self.expects_open_shutter().await {
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        })
        .await
        .expect("the Open Dome step makes the run expect an open shutter");
    }

    /// The dome's own safety closes the shutter.
    fn close_shutter_outside_the_run(&self) {
        *self.ops.shutter_state.lock().unwrap() = "Closed".to_string();
    }

    /// Firings ("<id> -> <action>") and warnings seen within `window`.
    async fn collect(&mut self, window: Duration) -> (Vec<String>, Vec<String>) {
        let mut fired = Vec::new();
        let mut warnings = Vec::new();
        let _ = tokio::time::timeout(window, async {
            loop {
                match self.events.recv().await {
                    Ok(ExecutorEvent::TriggerFired {
                        trigger_id, action, ..
                    }) => fired.push(format!("{trigger_id} -> {action}")),
                    Ok(
                        ExecutorEvent::Warning { message }
                        | ExecutorEvent::NoticedWarning { message, .. },
                    ) => warnings.push(message),
                    Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(broadcast::error::RecvError::Closed) => return,
                }
            }
        })
        .await;
        (fired, warnings)
    }
}

/// The run opened the dome, then the shutter closed by itself. Every run arms
/// the standard trigger, so it tells the operator once and the run keeps
/// going: it never parks or stops on its own account.
#[tokio::test]
async fn a_shutter_that_closes_after_the_run_opened_it_is_told_once_and_the_run_goes_on() {
    let mut run = start(plan(true, None)).await;
    run.wait_until_the_run_expects_an_open_shutter().await;
    run.close_shutter_outside_the_run();

    let (fired, warnings) = run.collect(Duration::from_secs(12)).await;

    assert_eq!(
        fired,
        vec!["dome_shutter_not_open -> Notify"],
        "{warnings:?}"
    );
    assert!(
        warnings.iter().any(|w| w.starts_with(
            "Dome Shutter Not Open: the dome reports its shutter closed while the run expects \
             it open. Imaging continues"
        ) && w.contains("add a Recovery step for Dome Shutter Not Open")),
        "{warnings:?}"
    );
    assert_eq!(run.executor.get_state().await, ExecutorState::Running);
    assert!(
        !run.ops.calls().iter().any(|c| c.starts_with("mount_park")),
        "{:?}",
        run.ops.calls()
    );
}

/// A run that never opened the dome has no reason to expect it open, so a
/// closed shutter says nothing.
#[tokio::test]
async fn a_closed_shutter_the_run_never_opened_is_not_a_firing() {
    let mut run = start(plan(false, None)).await;
    run.close_shutter_outside_the_run();

    let (fired, _) = run.collect(Duration::from_secs(7)).await;

    assert!(fired.is_empty(), "{fired:?}");
    assert!(!run.expects_open_shutter().await);
    assert_eq!(run.executor.get_state().await, ExecutorState::Running);
}

/// The operator's Recovery step for a closed shutter does what it says.
#[tokio::test]
async fn a_recovery_step_for_a_closed_shutter_does_the_action_the_operator_chose() {
    let mut run = start(plan(true, Some(RecoveryAction::Pause))).await;
    run.wait_until_the_run_expects_an_open_shutter().await;
    run.close_shutter_outside_the_run();

    let (fired, warnings) = run.collect(Duration::from_secs(12)).await;

    assert!(
        fired.contains(&"recovery_node:guard -> Pause".to_string()),
        "{fired:?} {warnings:?}"
    );
    assert_eq!(run.executor.get_state().await, ExecutorState::Paused);
    // The standard trigger still says what it read, without claiming the run
    // goes on: the plan's own step decided.
    assert!(
        warnings.contains(
            &"Dome Shutter Not Open: the dome reports its shutter closed while the run expects \
              it open."
                .to_string()
        ),
        "{warnings:?}"
    );
}
