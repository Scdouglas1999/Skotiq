//! Replay Debug — smoke tests for the decision channel + emit
//! path. These exercise the public surface of the [`decision`] module
//! and the [`SequenceExecutor::emit_decision`] / `subscribe_decisions`
//! pair from outside the crate, so a future refactor that breaks the
//! contract fails fast.

use skotiq_sequencer::{DecisionCategory, DecisionEvent, SequenceExecutor};

#[tokio::test]
async fn executor_emit_decision_round_trips_through_channel() {
    let executor = SequenceExecutor::new();
    let mut rx = executor.subscribe_decisions();

    executor.set_active_sequence_run_id(Some(42));
    let event = DecisionEvent::new(
        DecisionCategory::SchedulerPick,
        "picked M27",
        serde_json::json!({ "target_id": "m27", "score": 78.0 }),
    );
    assert!(executor.emit_decision(event));

    let received = rx.recv().await.expect("decision delivered through channel");
    assert_eq!(received.category, DecisionCategory::SchedulerPick);
    assert_eq!(received.summary, "picked M27");
    assert_eq!(received.sequence_run_id, Some(42));
    assert_eq!(received.details["target_id"], serde_json::json!("m27"));
}

#[tokio::test]
async fn disabling_logging_short_circuits_emit() {
    let executor = SequenceExecutor::new();
    let _rx = executor.subscribe_decisions();
    executor.set_decision_logging_enabled(false);
    let sent = executor.emit_decision(DecisionEvent::new(
        DecisionCategory::SystemEvent,
        "should be dropped",
        serde_json::Value::Null,
    ));
    assert!(!sent, "emit_decision must return false when disabled");
}

#[tokio::test]
async fn category_wire_keys_are_distinct() {
    // Guard against accidental collisions if a future agent adds a new
    // variant — every wire key must round-trip.
    let cats = [
        DecisionCategory::SchedulerPick,
        DecisionCategory::TriggerFired,
        DecisionCategory::RecoveryEntered,
        DecisionCategory::BudgetMet,
        DecisionCategory::AdaptiveSwap,
        DecisionCategory::FrameAccepted,
        DecisionCategory::FrameRejected,
        DecisionCategory::PluginNodeInvoked,
        DecisionCategory::ManualIntervention,
        DecisionCategory::SystemEvent,
    ];
    let mut seen = std::collections::HashSet::new();
    for cat in cats {
        let key = cat.wire_key();
        assert!(seen.insert(key), "duplicate wire key: {key}");
        assert_eq!(
            DecisionCategory::from_wire_key(key),
            Some(cat),
            "round-trip failed for {key}",
        );
    }
}

#[tokio::test]
async fn active_run_id_is_stamped_when_emit_does_not_set_one() {
    let executor = SequenceExecutor::new();
    let mut rx = executor.subscribe_decisions();
    executor.set_active_sequence_run_id(Some(99));

    let event = DecisionEvent::new(
        DecisionCategory::FrameAccepted,
        "frame 1/10 accepted",
        serde_json::json!({ "hfr": 1.7 }),
    );
    assert_eq!(event.sequence_run_id, None);
    assert!(executor.emit_decision(event));

    let received = rx.recv().await.expect("decision delivered");
    assert_eq!(
        received.sequence_run_id,
        Some(99),
        "executor must stamp active run id when emit site did not"
    );
}

#[tokio::test]
async fn manual_intervention_decisions_emit_from_command_helpers() {
    let executor = SequenceExecutor::new();
    let mut rx = executor.subscribe_decisions();
    executor.set_active_sequence_run_id(Some(7));

    // pause() emits a ManualIntervention even without an active command
    // channel (the helper is called as a side-effect of the public method).
    let _ = executor.pause().await;
    let received = rx
        .recv()
        .await
        .expect("pause emits ManualIntervention decision");
    assert_eq!(received.category, DecisionCategory::ManualIntervention);
    assert!(received.summary.contains("pause"));
}

/// The origin mechanism must be pinned at the PRODUCER, not only at the
/// renderer. A scheduler-origin stop is a system
/// event; an operator stop (None origin) is a manual intervention that the
/// logging toggle can never silence; any other named origin (a rollback) is
/// a gated system event.
#[tokio::test]
async fn stop_origin_selects_the_decision_category() {
    // Scheduler origin -> SystemEvent "Autopilot: stop".
    let mut executor = SequenceExecutor::new();
    let mut rx = executor.subscribe_decisions();
    let _ = executor.stop_with_origin(Some("scheduler")).await;
    let received = rx.recv().await.expect("autopilot decision delivered");
    assert_eq!(received.category, DecisionCategory::SystemEvent);
    assert_eq!(received.summary, "Autopilot: stop");
    assert_eq!(received.details["origin"], serde_json::json!("scheduler"));

    // Operator (None) origin -> ManualIntervention, even with logging OFF.
    let mut executor = SequenceExecutor::new();
    let mut rx = executor.subscribe_decisions();
    executor.set_decision_logging_enabled(false);
    let _ = executor.stop().await;
    let received = rx.recv().await.expect("operator stop decision delivered");
    assert_eq!(received.category, DecisionCategory::ManualIntervention);
    assert_eq!(received.summary, "Operator: stop");

    // Rollback origin -> gated SystemEvent; silenced when logging is off.
    let mut executor = SequenceExecutor::new();
    let mut rx = executor.subscribe_decisions();
    executor.set_decision_logging_enabled(false);
    let _ = executor.stop_with_origin(Some("rollback")).await;
    assert!(
        rx.try_recv().is_err(),
        "a rollback stop is system noise the logging toggle may silence"
    );
}
