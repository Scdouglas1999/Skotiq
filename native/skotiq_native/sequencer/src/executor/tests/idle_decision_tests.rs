//! A lifecycle command with no run under way leaves no row in the decision
//! log: there is no run to record it in. The event bridges listen from host
//! start, so a row sent while idle would reach the replay log and the run
//! report before any run of the launch.

use super::*;
use crate::decision::{DecisionCategory, DecisionEvent};
use tokio::sync::broadcast::Receiver;

fn drain(rx: &mut Receiver<DecisionEvent>) -> Vec<String> {
    let mut rows = Vec::new();
    while let Ok(row) = rx.try_recv() {
        rows.push(row.summary);
    }
    rows
}

/// Every lifecycle command that records a row, as an operator or the system
/// sends it.
async fn send_every_command(executor: &mut SequenceExecutor) {
    let handle = executor.handle();
    let _ = handle.pause_from(None).await;
    let _ = handle.resume().await;
    let _ = handle.skip().await;
    let _ = handle.recovery_try_now().await;
    let _ = handle.recovery_abort().await;
    let _ = executor.request_stop(StopOrigin::Scheduler).await;
    let _ = executor
        .request_stop(StopOrigin::System("weather".to_string()))
        .await;
    let _ = executor.request_stop(StopOrigin::Operator).await;
}

#[tokio::test]
async fn commands_to_an_idle_or_finished_executor_record_nothing() {
    for state in [
        ExecutorState::Idle,
        ExecutorState::Completed,
        ExecutorState::Failed,
        ExecutorState::Cancelled,
    ] {
        let mut executor = SequenceExecutor::new();
        let mut rx = executor.handle().subscribe_decisions();
        executor.run_state.force(state);
        send_every_command(&mut executor).await;
        assert_eq!(drain(&mut rx), Vec::<String>::new(), "{state:?}");
    }
}

#[tokio::test]
async fn commands_to_a_run_in_flight_are_recorded() {
    let mut executor = SequenceExecutor::new();
    let mut rx = executor.handle().subscribe_decisions();
    executor.run_state.force(ExecutorState::Running);
    executor.handle().pause_from(None).await.unwrap();
    executor.run_state.force(ExecutorState::Paused);
    executor.handle().resume().await.unwrap();
    executor.handle().skip().await.unwrap();
    let _ = executor.request_stop(StopOrigin::Operator).await;
    let rows = drain(&mut rx);
    assert_eq!(rows.len(), 4, "{rows:?}");
    assert_eq!(rows.last().map(String::as_str), Some("Operator: stop"));
}

/// The operator's stop is recorded with decision logging off, as before.
#[tokio::test]
async fn the_operators_stop_of_a_run_is_recorded_with_logging_off() {
    let mut executor = SequenceExecutor::new();
    let mut rx = executor.handle().subscribe_decisions();
    executor
        .handle()
        .update_run_config(|config| config.decision_logging_enabled = false)
        .await
        .unwrap();
    executor.run_state.force(ExecutorState::Running);
    let _ = executor.request_stop(StopOrigin::Operator).await;
    assert_eq!(drain(&mut rx), vec!["Operator: stop".to_string()]);
}

/// The stop's origin picks its row: the operator's is a manual intervention
/// that the logging toggle never silences, the autopilot's a system event, and
/// any other named origin (a rollback) a system event the toggle silences.
#[tokio::test]
async fn a_run_stop_is_recorded_by_its_origin() {
    let running = || {
        let executor = SequenceExecutor::new();
        executor.run_state.force(ExecutorState::Running);
        executor
    };

    let mut executor = running();
    let mut rx = executor.handle().subscribe_decisions();
    let _ = executor
        .request_stop(StopOrigin::from_wire(Some("scheduler")))
        .await;
    let row = rx.try_recv().expect("autopilot stop recorded");
    assert_eq!(row.category, DecisionCategory::SystemEvent);
    assert_eq!(row.summary, "Autopilot: stop");
    assert_eq!(row.details["origin"], serde_json::json!("scheduler"));

    let mut executor = running();
    let mut rx = executor.handle().subscribe_decisions();
    executor
        .handle()
        .update_run_config(|config| config.decision_logging_enabled = false)
        .await
        .unwrap();
    let _ = executor.request_stop(StopOrigin::from_wire(None)).await;
    let row = rx.try_recv().expect("operator stop recorded");
    assert_eq!(row.category, DecisionCategory::ManualIntervention);
    assert_eq!(row.summary, "Operator: stop");

    let mut executor = running();
    let mut rx = executor.handle().subscribe_decisions();
    executor
        .handle()
        .update_run_config(|config| config.decision_logging_enabled = false)
        .await
        .unwrap();
    let _ = executor
        .request_stop(StopOrigin::from_wire(Some("rollback")))
        .await;
    assert!(rx.try_recv().is_err());
}
