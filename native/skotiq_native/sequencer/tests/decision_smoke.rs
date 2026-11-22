//! Replay Debug — smoke tests for the decision channel + emit
//! path. These exercise the public surface of the [`decision`] module
//! and the [`SequenceExecutor::emit_decision`] / `subscribe_decisions`
//! pair from outside the crate, so a future refactor that breaks the
//! contract fails fast.

use skotiq_sequencer::{DecisionCategory, DecisionEvent, RunNotice, SequenceExecutor};

#[tokio::test]
async fn executor_emit_decision_round_trips_through_channel() {
    let executor = SequenceExecutor::new();
    let mut rx = executor.handle().subscribe_decisions();

    executor.handle().set_active_sequence_run_id(Some(42));
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
    let _rx = executor.handle().subscribe_decisions();
    executor
        .handle()
        .update_run_config(|config| config.decision_logging_enabled = false)
        .await
        .unwrap();
    let sent = executor.emit_decision(DecisionEvent::new(
        DecisionCategory::SystemEvent,
        "should be dropped",
        serde_json::Value::Null,
    ));
    assert!(!sent, "emit_decision must return false when disabled");
}

#[tokio::test]
async fn a_row_the_operator_is_notified_from_goes_out_with_logging_off() {
    let executor = SequenceExecutor::new();
    let mut rx = executor.handle().subscribe_decisions();
    executor
        .handle()
        .update_run_config(|config| config.decision_logging_enabled = false)
        .await
        .expect("decision logging setting applies");
    let sent = executor.emit_decision(
        DecisionEvent::new(
            DecisionCategory::SystemEvent,
            "Problem noticed — the run continues",
            serde_json::json!({ "source": "Center" }),
        )
        .with_notice(RunNotice::ProblemNoticed {
            source: "Center".to_string(),
            problem: "the frame did not solve".to_string(),
        }),
    );
    assert!(sent);
    assert_eq!(
        rx.recv().await.expect("notice row delivered").notice,
        Some(RunNotice::ProblemNoticed {
            source: "Center".to_string(),
            problem: "the frame did not solve".to_string(),
        })
    );
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
    let mut rx = executor.handle().subscribe_decisions();
    executor.handle().set_active_sequence_run_id(Some(99));

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
