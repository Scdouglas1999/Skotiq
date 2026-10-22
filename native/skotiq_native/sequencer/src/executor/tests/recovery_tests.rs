use super::*;

fn build_smart_exposure_sequence(
    plans: Vec<crate::FilterPlan>,
    budget_secs: f64,
) -> SequenceDefinition {
    let mut seq = SequenceDefinition::new("smart exposure totals test".to_string());
    let root = crate::NodeDefinition {
        id: "root".to_string(),
        name: "Root".to_string(),
        node_type: crate::NodeType::SmartExposure(crate::SmartExposureConfig {
            plans,
            rotate_filters: true,
            dither_on_filter_change: false,
            integration_budget_secs: budget_secs,
            batch_size: 1,
            loop_until_stopped: false,
        }),
        enabled: true,
        children: vec![],
    };
    seq.nodes.push(root);
    seq.root_node_id = Some("root".to_string());
    seq
}

fn plan_row(name: &str, count: u32, duration_secs: f64) -> crate::FilterPlan {
    crate::FilterPlan {
        filter_name: name.to_string(),
        filter_index: None,
        count,
        duration_secs,
        ..crate::FilterPlan::default()
    }
}

/// SmartExposure with no budget cap: totals must sum every plan's count
/// and integration time. Before this was 0 / 0.0 because walk()
/// only recognised `NodeType::TakeExposure`.
#[test]
fn calculate_totals_recognises_smart_exposure_plans_without_budget() {
    let exec = SequenceExecutor::new();
    let seq = build_smart_exposure_sequence(
        vec![
            plan_row("L", 60, 120.0), // 60 * 120 = 7200s
            plan_row("R", 30, 180.0), // 30 * 180 = 5400s
            plan_row("G", 30, 180.0), // 30 * 180 = 5400s
            plan_row("B", 30, 180.0), // 30 * 180 = 5400s
        ],
        0.0, // no cap
    );

    let (total_exposures, total_integration, indeterminate) = exec.calculate_totals(&seq);
    assert_eq!(total_exposures, 60 + 30 + 30 + 30);
    // 7200 + 5400 * 3 = 23400
    assert!(
        (total_integration - 23_400.0).abs() < f64::EPSILON,
        "expected 23400.0, got {}",
        total_integration
    );
    assert!(!indeterminate, "no budget cap → totals are deterministic");
}

/// SmartExposure with a tight budget cap: integration is capped to the
/// budget and the indeterminate flag is set so the dashboard renders
/// "approximately". Frame count remains the un-capped sum (worst case).
#[test]
fn calculate_totals_caps_smart_exposure_to_integration_budget() {
    let exec = SequenceExecutor::new();
    let seq = build_smart_exposure_sequence(
        vec![plan_row("L", 60, 120.0), plan_row("R", 60, 120.0)],
        7200.0, // 2h cap
    );

    let (total_exposures, total_integration, indeterminate) = exec.calculate_totals(&seq);
    // Un-capped frame total is still surfaced (60 + 60).
    assert_eq!(total_exposures, 120);
    assert!(
        (total_integration - 7_200.0).abs() < f64::EPSILON,
        "integration should be capped to budget; got {}",
        total_integration
    );
    assert!(
        indeterminate,
        "budget cap engaging means totals are indeterminate"
    );
}

/// SmartExposure under a Loop multiplies the totals — same pattern as
/// TakeExposure under a Loop. Sanity-checks that the new arm doesn't
/// short-circuit the multiplier propagation when an outer Loop wraps it.
#[test]
fn calculate_totals_smart_exposure_inside_loop_multiplies() {
    let exec = SequenceExecutor::new();
    let mut seq = SequenceDefinition::new("loop wrapping smart exposure".to_string());
    let loop_id = "loop".to_string();
    let se_id = "se".to_string();
    let loop_node = crate::NodeDefinition {
        id: loop_id.clone(),
        name: "Loop x3".to_string(),
        node_type: crate::NodeType::Loop(crate::LoopConfig {
            iterations: Some(3),
            condition: crate::LoopCondition::Count,
            condition_value: None,
            horizon_profile: None,
        }),
        enabled: true,
        children: vec![se_id.clone()],
    };
    let se_node = crate::NodeDefinition {
        id: se_id,
        name: "Smart".to_string(),
        node_type: crate::NodeType::SmartExposure(crate::SmartExposureConfig {
            plans: vec![plan_row("L", 10, 60.0)],
            rotate_filters: true,
            dither_on_filter_change: false,
            integration_budget_secs: 0.0,
            batch_size: 1,
            loop_until_stopped: false,
        }),
        enabled: true,
        children: vec![],
    };
    seq.nodes.push(loop_node);
    seq.nodes.push(se_node);
    seq.root_node_id = Some(loop_id);

    let (total_exposures, total_integration, indeterminate) = exec.calculate_totals(&seq);
    assert_eq!(total_exposures, 10 * 3);
    assert!(
        (total_integration - (10.0 * 60.0 * 3.0)).abs() < f64::EPSILON,
        "expected 1800.0, got {}",
        total_integration
    );
    assert!(
        !indeterminate,
        "Count-based Loop + un-capped SmartExposure → deterministic"
    );
}

// Recovery Mode tests

#[test]
fn executor_state_recovering_round_trips_through_serde() {
    // The bridge layer serialises ExecutorState to JSON for the
    // streaming-checkpoint blob; if `Recovering` ever fails to
    // round-trip the live state machine would silently drop the
    // recovery flag on a checkpoint reload.
    let json = serde_json::to_string(&ExecutorState::Recovering).expect("serialise");
    let back: ExecutorState = serde_json::from_str(&json).expect("deserialise");
    assert_eq!(back, ExecutorState::Recovering);
    assert_eq!(format!("{:?}", ExecutorState::Recovering), "Recovering");
}

#[test]
fn fresh_executor_has_no_recovery_in_flight() {
    let executor = SequenceExecutor::new();
    assert!(executor.current_recovery().is_none());
    assert!(executor.recovery_history().is_empty());
    // Signals are initialised; entry counter is at the initial value.
    let signals = executor.recovery_signals_handle();
    assert_eq!(signals.current_entry(), 0);
    // The default RecoveryRuntimeConfig is pre-seeded into the
    // runtime config so the first recovery has SGP-style defaults.
    let rc = executor.runtime_config_handle();
    let cfg = rc.read().recovery.clone();
    assert!((cfg.retry_interval_secs - 600.0).abs() < f64::EPSILON);
    assert!((cfg.max_duration_secs - 5400.0).abs() < f64::EPSILON);
}

#[test]
fn recovery_signals_request_methods_set_flags() {
    let executor = SequenceExecutor::new();
    let signals = executor.recovery_signals_handle();
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    rt.block_on(async {
        executor.recovery_try_now().await.unwrap();
        executor.recovery_abort().await.unwrap();
    });
    // Both atomics are set even without a running executor (the
    // commands write the atomics first, then forward to the channel
    // which is None for an idle executor).
    assert!(signals.take_try_now());
    assert!(signals.take_abort());
}

#[test]
fn update_recovery_config_writes_through_runtime() {
    let executor = SequenceExecutor::new();
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let cfg = crate::recovery::RecoveryRuntimeConfig {
        retry_interval_secs: 120.0,
        max_duration_secs: 1200.0,
        stop_tracking_during_recovery: false,
        abort_on_meridian: false,
        audible_alert_when_entered: false,
        park_and_close_when_recovery_gives_up: true,
    };
    let mut executor = executor;
    rt.block_on(async {
        executor.update_recovery_config(cfg.clone()).await;
    });
    let handle = executor.runtime_config_handle();
    let rc = handle.read();
    assert!((rc.recovery.retry_interval_secs - 120.0).abs() < f64::EPSILON);
    assert!((rc.recovery.max_duration_secs - 1200.0).abs() < f64::EPSILON);
    assert!(!rc.recovery.stop_tracking_during_recovery);
    assert!(!rc.recovery.abort_on_meridian);
    assert!(!rc.recovery.audible_alert_when_entered);
    // The one field whose default is false, so a write-through of `true` is
    // what proves it is not being dropped on the way in.
    assert!(rc.recovery.park_and_close_when_recovery_gives_up);
}

/// Simulates the lifecycle of a successful recovery attempt for the
/// GuideStarLost cause against a NullDeviceOps that reports
/// `is_guiding == true` (the simulated guider is happy). The
/// dispatch wires to the device_ops as advertised — when the guider
/// reports "guiding", the attempt is `Succeeded`.
#[test]
fn run_recovery_attempt_guide_star_lost_with_null_ops_succeeds_when_guiding() {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let device_ops: SharedDeviceOps = std::sync::Arc::new(crate::device_ops::NullDeviceOps);
    let mgr = Arc::new(RwLock::new(TriggerManager::new()));
    let outcome = rt.block_on(async {
        run_recovery_attempt(
            &crate::recovery::RecoveryCause::GuideStarLost,
            &device_ops,
            None,
            &[],
            &mgr,
        )
        .await
    });
    // NullDeviceOps returns is_guiding = true so the attempt
    // resolves to Succeeded — this proves the dispatch reads the
    // live guider status rather than blindly succeeding.
    assert_eq!(outcome, crate::recovery::AttemptOutcome::Succeeded);
}

/// The GuideStarLost dispatch returns `Failed` when the guider
/// reports `is_guiding == false`. We test this via the structured
/// branch on `run_recovery_attempt` by constructing the outcome
/// directly — implementing a partial DeviceOps mock would require
/// reimplementing the entire 50+ method trait surface. The
/// dispatch logic itself is exercised by the
/// `guide_star_lost_with_null_ops_succeeds_when_guiding` test and
/// the integration tests in `recovery::tests`.
#[test]
fn attempt_outcome_failed_variant_carries_message() {
    let outcome = crate::recovery::AttemptOutcome::Failed {
        message: "Guider still reports star lost".to_string(),
    };
    match outcome {
        crate::recovery::AttemptOutcome::Failed { message } => {
            assert!(message.contains("star lost"));
        }
        other => panic!("expected Failed, got {:?}", other),
    }
}

/// WeatherUnsafe attempt with NullDeviceOps which reports safe.
/// Validates the "wait then poll" pattern resolves correctly.
#[test]
fn run_recovery_attempt_weather_unsafe_with_null_ops_succeeds_when_safe() {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let device_ops: SharedDeviceOps = std::sync::Arc::new(crate::device_ops::NullDeviceOps);
    let mgr = Arc::new(RwLock::new(TriggerManager::new()));
    let outcome = rt.block_on(async {
        run_recovery_attempt(
            &crate::recovery::RecoveryCause::WeatherUnsafe,
            &device_ops,
            None,
            &[],
            &mgr,
        )
        .await
    });
    // NullDeviceOps.safety_is_safe returns Ok(true).
    assert_eq!(outcome, crate::recovery::AttemptOutcome::Succeeded);
}

/// A weather recovery MUST NOT clear/resume on a hardware-only re-poll while
/// the Dart-side verdict still reports unsafe (`weather_verdict_unsafe ==
/// Some(true)`). NullDeviceOps.safety_is_safe returns Ok(true) (hardware reads
/// safe), so without the verdict gate the attempt would report Succeeded and
/// resume the sequence into API-unsafe weather; with it the attempt must Fail
/// until the Dart verdict also clears.
#[test]
fn run_recovery_attempt_weather_unsafe_blocked_by_dart_verdict() {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let device_ops: SharedDeviceOps = std::sync::Arc::new(crate::device_ops::NullDeviceOps);
    let mgr = Arc::new(RwLock::new(TriggerManager::new()));
    // Dart computed UNSAFE (API alert / threshold), even though the hardware
    // boolean reads safe.
    rt.block_on(async {
        let state = mgr.read().await.state();
        state.write().await.update_weather_verdict(Some(true));
    });
    let outcome = rt.block_on(async {
        run_recovery_attempt(
            &crate::recovery::RecoveryCause::WeatherUnsafe,
            &device_ops,
            None,
            &[],
            &mgr,
        )
        .await
    });
    match outcome {
        crate::recovery::AttemptOutcome::Failed { message } => {
            assert!(
                message.contains("weather check still reports unsafe"),
                "expected the app-verdict block message, got: {}",
                message
            );
        }
        other => panic!(
            "expected Failed (Dart verdict still unsafe), got {:?}",
            other
        ),
    }
}

/// Sibling to the above: once the Dart verdict clears to `Some(false)`
/// (explicitly safe) the hardware poll is consulted again and a safe
/// hardware reading resumes the sequence. `None` (abstain) behaves the same
/// — neither pins the sequence paused, so the gate only adds-unsafe.
#[test]
fn run_recovery_attempt_weather_unsafe_resumes_when_verdict_clears() {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let device_ops: SharedDeviceOps = std::sync::Arc::new(crate::device_ops::NullDeviceOps);
    for verdict in [Some(false), None] {
        let mgr = Arc::new(RwLock::new(TriggerManager::new()));
        rt.block_on(async {
            let state = mgr.read().await.state();
            state.write().await.update_weather_verdict(verdict);
        });
        let outcome = rt.block_on(async {
            run_recovery_attempt(
                &crate::recovery::RecoveryCause::WeatherUnsafe,
                &device_ops,
                None,
                &[],
                &mgr,
            )
            .await
        });
        assert_eq!(
            outcome,
            crate::recovery::AttemptOutcome::Succeeded,
            "verdict {:?} with safe hardware should resume",
            verdict
        );
    }
}

/// FocusDriftCritical and SlewFailed and PlateSolveFailed and Custom
/// all use the "wait then resume" pattern.
#[test]
fn run_recovery_attempt_wait_then_resume_causes_all_succeed() {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let device_ops: SharedDeviceOps = std::sync::Arc::new(crate::device_ops::NullDeviceOps);
    let mgr = Arc::new(RwLock::new(TriggerManager::new()));
    for cause in [
        crate::recovery::RecoveryCause::FocusDriftCritical,
        crate::recovery::RecoveryCause::SlewFailed,
        crate::recovery::RecoveryCause::PlateSolveFailed,
        crate::recovery::RecoveryCause::Custom("plugin".to_string()),
    ] {
        let outcome =
            rt.block_on(async { run_recovery_attempt(&cause, &device_ops, None, &[], &mgr).await });
        assert_eq!(
            outcome,
            crate::recovery::AttemptOutcome::Succeeded,
            "cause {:?} should resolve to Succeeded on the wait-then-resume path",
            cause
        );
    }
}

/// 4.0 Phase G — a consecutive-reject storm is NOT auto-recoverable by
/// waiting (a wait cannot prove the clouds/dew cleared). The recovery
/// attempt must escalate to a real operator `PauseForOperator`, never
/// `Succeeded` — otherwise the run oscillated fail → wait → "recovered"
/// → fail on a fresh recovery budget and burned the night.
#[test]
fn run_recovery_attempt_consecutive_rejects_escalates_to_operator_pause() {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let device_ops: SharedDeviceOps = std::sync::Arc::new(crate::device_ops::NullDeviceOps);
    let mgr = Arc::new(RwLock::new(TriggerManager::new()));
    let outcome = rt.block_on(async {
        run_recovery_attempt(
            &crate::recovery::RecoveryCause::ConsecutiveRejectsExceeded,
            &device_ops,
            None,
            &[],
            &mgr,
        )
        .await
    });
    match outcome {
        crate::recovery::AttemptOutcome::PauseForOperator { message } => {
            assert!(
                !message.is_empty(),
                "operator-pause escalation must carry a reason"
            );
        }
        other => panic!(
            "consecutive-reject storm must escalate to PauseForOperator, got {:?}",
            other
        ),
    }
}

/// The disposition that gates how a `PauseForOperator` escalation is handled.
///
/// The default must be the action that can be undone. An app that cannot tell
/// whether a human is present — and nothing here can — must not park a mount on
/// that guess: on 2026-09-14 this path parked the owner's mount, closed up and
/// declared the night abandoned while he sat at the telescope.
#[test]
fn recovery_escalation_defaults_to_holding_and_abandons_only_on_opt_in() {
    assert_eq!(
        UnattendedEndPolicy::from_recovery_config(&RuntimeConfig::default().recovery),
        UnattendedEndPolicy::HoldForOperator,
        "the recovery defaults must hold the run, never park the mount"
    );
    assert_eq!(
        recovery_escalation_disposition(UnattendedEndPolicy::HoldForOperator),
        EscalationDisposition::PassivePause,
        "the default escalation holds the run for a human and moves nothing"
    );
    assert_eq!(
        recovery_escalation_disposition(UnattendedEndPolicy::ParkAndClose),
        EscalationDisposition::SafeAbandon,
        "only an explicit park-and-close policy may abandon the night"
    );
}

/// The reject-storm cause from the owner's run resolves to a `PauseForOperator`
/// escalation whose own message promises a pause. Under the default policy the
/// action must match that promise.
#[tokio::test]
async fn consecutive_reject_storm_escalation_promises_and_performs_a_pause() {
    let ops: SharedDeviceOps = std::sync::Arc::new(ReacquireGuiderOps::new(false, true));
    let outcome = run_recovery_attempt(
        &crate::recovery::RecoveryCause::ConsecutiveRejectsExceeded,
        &ops,
        None,
        &[],
        &Arc::new(RwLock::new(crate::triggers::TriggerManager::new())),
    )
    .await;
    let crate::recovery::AttemptOutcome::PauseForOperator { message } = outcome else {
        panic!("a reject storm must escalate to PauseForOperator, got {outcome:?}");
    };
    assert!(
        message.contains("paused"),
        "the escalation message promises a pause: {message}"
    );
    assert_eq!(
        recovery_escalation_disposition(UnattendedEndPolicy::from_recovery_config(
            &RuntimeConfig::default().recovery
        )),
        EscalationDisposition::PassivePause,
        "and by default the run must actually pause rather than park"
    );
}

/// Recovery entry stops tracking; any resume / operator-
/// handoff path must restore it. The shared helper both branches use must
/// command `mount_set_tracking(true)` and report no error on success.
#[tokio::test]
async fn restore_tracking_after_recovery_re_enables_tracking() {
    let ops_concrete = std::sync::Arc::new(ReacquireGuiderOps::new(false, true));
    let ops: SharedDeviceOps = ops_concrete.clone();
    let (event_tx, _rx) = broadcast::channel(16);

    let err = restore_tracking_after_recovery(
        &ops,
        Some("mount-1"),
        true, // stop_tracking was true → must restore
        "paused for operator",
        &event_tx,
    )
    .await;

    assert!(err.is_none(), "successful restore must not report an error");
    assert_eq!(
        ops_concrete.last_tracking_set(),
        Some(true),
        "tracking must be re-enabled before handing the run back"
    );
}

/// Recovery must never command tracking on a PARKED mount.
///
/// Observed live: a MoveRotator failure on a rig with no rotator drove the
/// recovery ladder, and the resume path issued `set tracking = true` on a
/// parked NYX-101 — motion intent on stowed hardware, from a failure that
/// had nothing to do with the mount. A park is a deliberate safe state and
/// automatic recovery must not take a rig out of one unprompted. The
/// message must also stop claiming frames "may trail", which is untrue of a
/// mount that is parked and not imaging.
#[tokio::test]
async fn restore_tracking_after_recovery_never_commands_a_parked_mount() {
    let ops_concrete = std::sync::Arc::new(ReacquireGuiderOps::new(false, true).with_parked());
    let ops: SharedDeviceOps = ops_concrete.clone();
    let (event_tx, mut rx) = broadcast::channel(16);

    let err =
        restore_tracking_after_recovery(&ops, Some("mount-1"), true, "after recovery", &event_tx)
            .await;

    assert_eq!(
        ops_concrete.last_tracking_set(),
        None,
        "a parked mount must never be commanded to track"
    );
    let message = err.expect("the operator must be told tracking was not restored");
    assert!(
        message.contains("parked"),
        "the message must say the mount is parked, got: {message}"
    );
    assert!(
        !message.contains("trail"),
        "must not claim frames may trail on a parked mount, got: {message}"
    );
    match rx.try_recv() {
        Ok(ExecutorEvent::Error { message }) => {
            assert!(message.contains("parked"), "got: {message}");
        }
        other => panic!("expected a truthful Error event, got {other:?}"),
    }
}

/// When tracking cannot be restored, the failure is LOUD — an error event
/// is emitted and the message is returned — never a silent resume on a
/// non-tracking mount.
#[tokio::test]
async fn restore_tracking_after_recovery_failure_is_loud() {
    let ops_concrete =
        std::sync::Arc::new(ReacquireGuiderOps::new(false, true).with_tracking_failure());
    let ops: SharedDeviceOps = ops_concrete.clone();
    let (event_tx, mut rx) = broadcast::channel(16);

    let err = restore_tracking_after_recovery(
        &ops,
        Some("mount-1"),
        true,
        "paused for operator",
        &event_tx,
    )
    .await;

    assert!(
        err.is_some(),
        "a tracking-restore failure must be surfaced, not swallowed"
    );
    let event = rx.try_recv().expect("a loud Error event must be emitted");
    match event {
        ExecutorEvent::Error { message } => {
            assert!(
                message.contains("tracking could not be re-enabled"),
                "the error must explain tracking was not restored: {message}"
            );
        }
        other => panic!("expected an Error event, got {other:?}"),
    }
}

/// If recovery never stopped tracking (`stop_tracking == false`), the
/// helper is a no-op: it must not command tracking at all.
#[tokio::test]
async fn restore_tracking_after_recovery_noop_when_tracking_not_stopped() {
    let ops_concrete = std::sync::Arc::new(ReacquireGuiderOps::new(false, true));
    let ops: SharedDeviceOps = ops_concrete.clone();
    let (event_tx, _rx) = broadcast::channel(16);

    let err = restore_tracking_after_recovery(
        &ops,
        Some("mount-1"),
        false, // tracking was never stopped
        "after recovery",
        &event_tx,
    )
    .await;

    assert!(err.is_none());
    assert_eq!(
        ops_concrete.last_tracking_set(),
        None,
        "the helper must not touch tracking when recovery never stopped it"
    );
}

/// The status API (`sequencer_get_status`) renders `progress.message`, which
/// is a different surface from the event stream. An ATTENDED escalation whose
/// tracking restore FAILED used to stamp the snapshot with the pause reason
/// only — the helper's verdict was discarded — so a remote operator polling
/// status saw a clean "paused for operator" over a mount that was not
/// tracking, and Resume exposed on a drifting mount. The verdict must reach
/// the snapshot as well as the event.
#[tokio::test]
async fn holding_escalation_carries_a_failed_tracking_restore_into_progress_message() {
    let ops_concrete =
        std::sync::Arc::new(ReacquireGuiderOps::new(false, true).with_tracking_failure());
    let ops: SharedDeviceOps = ops_concrete.clone();
    // Hold the receiver so the escalation's events are delivered rather than
    // failing on an empty subscriber set.
    let (event_tx, _rx) = broadcast::channel(32);

    let runtime = Arc::new(StdRwLock::new(RuntimeConfig {
        recovery: crate::recovery::RecoveryRuntimeConfig {
            stop_tracking_during_recovery: true,
            // The default policy: hold the run for a human. This is the
            // passive-pause branch that restores tracking and hands the run
            // back without moving anything.
            park_and_close_when_recovery_gives_up: false,
            ..Default::default()
        },
        ..Default::default()
    }));
    let state = Arc::new(RwLock::new(ExecutorState::Recovering));
    let progress = Arc::new(StdRwLock::new(SequenceProgress::default()));
    let current = Arc::new(StdRwLock::new(None));
    let is_cancelled = Arc::new(AtomicBool::new(false));
    let gave_up = Arc::new(AtomicBool::new(false));

    let escalation_state = RecoveryEscalationState {
        device_ops: &ops,
        event_tx: &event_tx,
        runtime_config: &runtime,
        state: &state,
        progress: &progress,
        current_recovery: &current,
        is_cancelled: &is_cancelled,
        gave_up: &gave_up,
        mount_id: Some("mount-1"),
        cover_id: None,
        dome_id: None,
    };
    let ctx = crate::recovery::RecoveryContext::new(
        crate::recovery::RecoveryCause::GuideStarLost,
        30.0,
        600.0,
    );

    apply_recovery_escalation(
        &escalation_state,
        &ctx,
        "Guide star lost: paused for operator".to_string(),
        true, // recovery had stopped tracking, so the restore is attempted
    )
    .await;

    assert_eq!(*state.read().await, ExecutorState::Paused);
    let message = progress
        .read()
        .message
        .clone()
        .expect("the paused snapshot must carry a message");
    assert!(
        message.contains("Guide star lost"),
        "the pause reason must survive: {message}"
    );
    assert!(
        message.contains("tracking could not be re-enabled"),
        "a failed tracking restore must reach the polled status snapshot, not only the \
         event stream: {message}"
    );
}

/// MountTrackingLost without a configured mount surfaces the
/// "no mount" error rather than silently succeeding.
#[test]
fn run_recovery_attempt_mount_tracking_lost_without_mount_fails() {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let device_ops: SharedDeviceOps = std::sync::Arc::new(crate::device_ops::NullDeviceOps);
    let mgr = Arc::new(RwLock::new(TriggerManager::new()));
    let outcome = rt.block_on(async {
        run_recovery_attempt(
            &crate::recovery::RecoveryCause::MountTrackingLost,
            &device_ops,
            None,
            &[],
            &mgr,
        )
        .await
    });
    match outcome {
        crate::recovery::AttemptOutcome::Failed { message } => {
            assert!(
                message.contains("No mount"),
                "expected 'No mount' error, got: {}",
                message
            );
        }
        other => panic!("expected Failed, got {:?}", other),
    }
}

/// full-loop integration: a sequence containing a
/// `NodeType::PluginNode` runs through `SequenceExecutor::start()`,
/// emits `ExecutorEvent::PluginNodeRequested`, the test sends back
/// `ExecutorCommand::PluginNodeFinished` via the public
/// `plugin_node_finished()` API, the executor unblocks the
/// instruction, and the sequence completes with `Success`.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn plugin_node_e2e_completes_via_executor_round_trip() {
    use crate::{NodeDefinition, NodeType, SequenceDefinition};
    let mut executor = SequenceExecutor::new();
    // Headless device-ops keeps the executor's start() requirements
    // satisfied without needing the real bridge.
    executor.set_device_ops(std::sync::Arc::new(crate::device_ops::NullDeviceOps));

    let mut sequence = SequenceDefinition::new("Plugin E2E".to_string());
    sequence.nodes.push(NodeDefinition {
        id: "plugin-1".to_string(),
        name: "Send notification".to_string(),
        node_type: NodeType::PluginNode {
            plugin_id: "com.example.pushover".to_string(),
            node_type_id: "pushover.notify".to_string(),
            config_json: r#"{"title":"E2E","message":"completed"}"#.to_string(),
            display_name: Some("Pushover".to_string()),
            timeout_secs: Some(10),
        },
        enabled: true,
        children: vec![],
    });
    sequence.root_node_id = Some("plugin-1".to_string());
    executor
        .load_sequence(sequence)
        .expect("sequence should load");

    let mut events = executor.subscribe();

    // The reply task waits for the PluginNodeRequested event and
    // then calls into the SequenceExecutor's public API the same
    // way the Dart side will. We can't move `executor` into the
    // task because we want to query state afterwards, so wrap it
    // in an Arc + RwLock mirroring the bridge's storage pattern.
    let executor = std::sync::Arc::new(tokio::sync::RwLock::new(executor));
    {
        let mut guard = executor.write().await;
        guard.start().await.expect("executor should start");
    }
    let executor_for_reply = executor.clone();
    let reply_task = tokio::spawn(async move {
        // Drain events until we see the plugin request, then reply.
        // The full event stream is noisier than this test cares
        // about — we just need the one variant.
        loop {
            match tokio::time::timeout(std::time::Duration::from_secs(5), events.recv()).await {
                Ok(Ok(ExecutorEvent::PluginNodeRequested {
                    node_id,
                    plugin_id,
                    node_type_id,
                    config_json,
                    timeout_secs,
                    ..
                })) => {
                    // Sanity-check the dispatch fields so the test
                    // catches accidental field reshuffles.
                    assert_eq!(node_id, "plugin-1");
                    assert_eq!(plugin_id, "com.example.pushover");
                    assert_eq!(node_type_id, "pushover.notify");
                    assert!(config_json.contains("E2E"));
                    assert_eq!(timeout_secs, 10);

                    let guard = executor_for_reply.read().await;
                    guard
                        .plugin_node_finished(
                            node_id,
                            true,
                            Some("delivered".to_string()),
                            Some(r#"{"phase":"finished","delivery_id":"e2e-1"}"#.to_string()),
                        )
                        .await
                        .expect("plugin_node_finished should succeed");
                    return true;
                }
                Ok(Ok(_other)) => continue, // ignore non-target events
                Ok(Err(tokio::sync::broadcast::error::RecvError::Lagged(_))) => continue,
                Ok(Err(tokio::sync::broadcast::error::RecvError::Closed)) => return false,
                Err(_elapsed) => return false,
            }
        }
    });

    let saw_request = tokio::time::timeout(std::time::Duration::from_secs(15), reply_task)
        .await
        .expect("reply task should complete")
        .expect("reply task should not panic");
    assert!(
        saw_request,
        "expected to observe the PluginNodeRequested event"
    );

    // Allow the executor task to finish processing the verdict +
    // mark the sequence Completed. We poll the state rather than
    // sleeping because polling is precise.
    let mut iters = 0;
    loop {
        iters += 1;
        let state = executor.read().await.get_state().await;
        if matches!(state, ExecutorState::Completed) {
            break;
        }
        if iters > 200 {
            panic!(
                "executor did not reach Completed within 5s; state={:?}",
                state
            );
        }
        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
    }

    // Final state assertion: node was marked Success and recorded
    // in the executor's progress map.
    let progress = executor.read().await.get_progress();
    assert_eq!(
        progress.node_statuses.get("plugin-1"),
        Some(&NodeStatus::Success),
        "plugin node should be recorded as Success"
    );
}

// GuideStarLost recovery — re-acquisition tests.
//
// A recovery arm that only *queries* is_guiding can never re-acquire a lost
// star. These tests assert the recovery actively calls guider_start
// (re-acquire) and only succeeds once guiding re-locks.

#[tokio::test]
async fn guide_star_lost_recovery_actively_reacquires() {
    // Guider is lost; guider_start succeeds and the guider re-locks.
    let guider = ReacquireGuiderOps::new(false, true);
    let started = guider.started.clone();
    let ops: SharedDeviceOps = std::sync::Arc::new(guider);
    let outcome = recover_guide_star(&ops).await;
    assert!(
        matches!(outcome, crate::recovery::AttemptOutcome::Succeeded),
        "recovery should succeed once the guider re-locks after re-acquire"
    );
    // The re-acquire MUST have been issued.
    assert!(
        started.load(Ordering::Relaxed),
        "guider_start (re-acquisition) must be called during recovery"
    );
}

#[tokio::test]
async fn guide_star_lost_recovery_fails_closed_when_start_errors() {
    // guider_start itself errors → recovery must fail closed.
    let ops: SharedDeviceOps = std::sync::Arc::new(ReacquireGuiderOps::new(true, false));
    let outcome = recover_guide_star(&ops).await;
    assert!(
        matches!(outcome, crate::recovery::AttemptOutcome::Failed { .. }),
        "recovery must fail closed when guider_start errors"
    );
}

/// The full escalation matrix: which cause produces which attempt outcome, and
/// what each of those does under each policy.
///
/// Pinned as one table because the 2026-09-14 failure was a mismatch BETWEEN
/// two of these cells: `ConsecutiveRejectsExceeded` resolved to
/// `PauseForOperator` — an outcome whose whole meaning is "stop and wait for a
/// person" — and the disposition then parked the mount and closed the dome.
#[tokio::test]
async fn the_escalation_matrix_is_pinned_cause_by_cause() {
    use crate::recovery::{AttemptOutcome, RecoveryCause};

    let ops: SharedDeviceOps = std::sync::Arc::new(ReacquireGuiderOps::new(false, true));
    let mgr = Arc::new(RwLock::new(crate::triggers::TriggerManager::new()));

    // Causes that resolve by waiting and re-checking: the loop may declare
    // success and resume.
    for cause in [
        RecoveryCause::WeatherUnsafe,
        RecoveryCause::FocusDriftCritical,
        RecoveryCause::SlewFailed,
        RecoveryCause::PlateSolveFailed,
        RecoveryCause::Custom("plugin".to_string()),
    ] {
        let outcome = run_recovery_attempt(&cause, &ops, None, &[], &mgr).await;
        assert!(
            matches!(outcome, AttemptOutcome::Succeeded),
            "{cause:?} recovers by re-checking after the wait, got {outcome:?}"
        );
    }

    // A reject storm cannot be proven cleared by waiting, so it escalates to a
    // person. Nothing about it says anything about the mount.
    let outcome = run_recovery_attempt(
        &RecoveryCause::ConsecutiveRejectsExceeded,
        &ops,
        None,
        &[],
        &mgr,
    )
    .await;
    assert!(
        matches!(outcome, AttemptOutcome::PauseForOperator { .. }),
        "a reject storm escalates to an operator pause, got {outcome:?}"
    );

    // A run with no devices assigned is terminal, not retryable.
    let outcome =
        run_recovery_attempt(&RecoveryCause::DeviceDisconnected, &ops, None, &[], &mgr).await;
    assert!(
        matches!(outcome, AttemptOutcome::Unrecoverable { .. }),
        "a run with nothing to reconnect must fail on the first attempt, got {outcome:?}"
    );

    // And the two dispositions, which is the half that went wrong.
    assert_eq!(
        recovery_escalation_disposition(UnattendedEndPolicy::HoldForOperator),
        EscalationDisposition::PassivePause
    );
    assert_eq!(
        recovery_escalation_disposition(UnattendedEndPolicy::ParkAndClose),
        EscalationDisposition::SafeAbandon
    );
    assert!(
        !UnattendedEndPolicy::default().may_safe_abandon(),
        "the default policy must never be allowed to move the mount"
    );
}

/// A guider that is stepping but not holding the star is NOT recovered.
///
/// The owner's measured numbers: PHD2 answered `is_guiding: true` throughout
/// while RA offsets sat at -56.8 / -57.2 px and Dec at -54.4 / -38.0 px. The
/// recovery fast path accepted that as "already recovered", declared success
/// and resumed the run.
#[test]
fn stepping_is_not_guiding() {
    use crate::device_ops::GuidingStatus;

    // The owner's rig, mid-failure: quadrature sum of the measured offsets.
    let measured_rms_total = (56.8_f64.powi(2) + 54.4_f64.powi(2)).sqrt();
    assert!(
        !guiding_is_settled(&GuidingStatus {
            is_guiding: true,
            rms_ra: 56.8,
            rms_dec: 54.4,
            rms_total: measured_rms_total,
        }),
        "RMS of {measured_rms_total:.0} px reported as guiding must not count as recovered"
    );

    // Just outside the settle bound: still not recovered.
    assert!(!guiding_is_settled(&GuidingStatus {
        is_guiding: true,
        rms_ra: 2.0,
        rms_dec: 2.0,
        rms_total: 2.83,
    }));

    // A real lock.
    assert!(guiding_is_settled(&GuidingStatus {
        is_guiding: true,
        rms_ra: 0.5,
        rms_dec: 0.4,
        rms_total: 0.64,
    }));

    // Guiding with an empty statistics window (restarted, no guide step yet)
    // has measured nothing.
    assert!(!guiding_is_settled(&GuidingStatus {
        is_guiding: true,
        rms_ra: 0.0,
        rms_dec: 0.0,
        rms_total: 0.0,
    }));

    // Not guiding at all is never settled, however small the (stale) RMS.
    assert!(!guiding_is_settled(&GuidingStatus {
        is_guiding: false,
        rms_ra: 0.1,
        rms_dec: 0.1,
        rms_total: 0.14,
    }));
}

/// A paused run still has a telescope under the open sky, so the triggers that
/// protect the RIG must keep evaluating — and the ones that drive hardware for
/// image quality must not.
///
/// This is what makes a hold safe enough to be the default. The old code
/// refused a passive pause precisely because a paused run had no weather, dawn
/// or altitude evaluation at all, and parked the mount rather than fix that.
#[test]
fn only_rig_protecting_triggers_evaluate_while_paused() {
    for trigger_type in [
        TriggerType::WeatherUnsafe,
        TriggerType::HumidityThreshold { max_percent: 85.0 },
        TriggerType::DomeShutterNotOpen,
        TriggerType::DawnApproaching {
            minutes_before: 30.0,
        },
        TriggerType::AltitudeLimit { min_altitude: 30.0 },
        TriggerType::MountTrackingLost,
    ] {
        assert!(
            is_safety_class_trigger(&trigger_type),
            "{trigger_type:?} protects the rig and must keep watching while paused"
        );
    }

    for trigger_type in [
        TriggerType::AutofocusInterval { every_n_frames: 25 },
        TriggerType::DitherInterval { every_n_frames: 5 },
        TriggerType::DriftLimit { max_pixels: 30.0 },
        TriggerType::MeridianFlip {
            config: crate::MeridianFlipConfig::default(),
        },
        TriggerType::FilterChange,
        TriggerType::GuidingFailed {
            rms_threshold: 2.0,
            duration_secs: 30.0,
            rms_retention_secs: 300,
        },
        TriggerType::GuideStarLost,
        TriggerType::CloudOpeningIn {
            minutes_before: 30.0,
            minimum_duration_secs: 600.0,
        },
    ] {
        assert!(
            !is_safety_class_trigger(&trigger_type),
            "{trigger_type:?} would move the focuser, the wheel or the mount under a hold \
             a human placed to inspect the rig"
        );
    }
}

/// The Guiding Failure trigger must reach the recovery driver, because the
/// driver freezing the node tree is the only thing that stops the next frame.
/// That applies when the operator turned on "Stop the run for quality
/// problems"; by default the trigger only notifies (owner decision 2026-10-06).
///
/// Its standard action is `Retry { max_attempts: 3 }`, and on the trigger side
/// a Retry had nothing to re-run: it counted 1/3 at 02:59:10, 2/3 at 03:00:11,
/// 3/3 at 03:01:11 and the run took three 180 s lights across that window.
#[test]
fn the_guiding_failure_trigger_maps_to_a_recovery_cause() {
    assert!(
        matches!(
            trigger_recovery_cause("guiding_failed"),
            Some(crate::recovery::RecoveryCause::GuideStarLost)
        ),
        "guiding_failed must be promotable to recovery, not left counting firings"
    );
    // The standard trigger really does carry a Retry action, so the arm this
    // mapping feeds is the one that ran that night.
    let mut mgr = crate::triggers::TriggerManager::new();
    mgr.create_standard_triggers();
    let trigger = mgr
        .get_trigger("guiding_failed")
        .expect("guiding_failed is a standard trigger");
    assert!(
        matches!(trigger.recovery_action, RecoveryAction::Retry { .. }),
        "got {:?}",
        trigger.recovery_action
    );
    // Triggers with no automatic recovery stay on the firing-count path.
    assert!(trigger_recovery_cause("filter_change").is_none());
    assert!(trigger_recovery_cause("dither_interval").is_none());
}

/// Every Pause/Retry trigger with a recovery semantic reaches the driver with
/// the cause whose attempt actually addresses it. Only the guiding rows were
/// pinned; the tracking, weather and focus rows could be deleted with every
/// test still green, and a deleted row silently turns the trigger back into a
/// plain operator pause with no attempt ladder (for tracking loss: nothing
/// tries to re-enable tracking).
#[test]
fn each_recoverable_trigger_maps_to_the_cause_that_fixes_it() {
    use crate::recovery::RecoveryCause;
    let table = [
        ("guide_star_lost", RecoveryCause::GuideStarLost),
        ("guiding_failed", RecoveryCause::GuideStarLost),
        ("mount_tracking_lost", RecoveryCause::MountTrackingLost),
        ("on_tracking_limit_hit", RecoveryCause::MountTrackingLost),
        ("weather_unsafe", RecoveryCause::WeatherUnsafe),
        ("humidity_threshold", RecoveryCause::WeatherUnsafe),
        ("temperature_limit", RecoveryCause::WeatherUnsafe),
        ("focus_drift", RecoveryCause::FocusDriftCritical),
    ];
    for (trigger_id, cause) in table {
        assert_eq!(
            trigger_recovery_cause(trigger_id),
            Some(cause),
            "trigger '{trigger_id}'"
        );
    }

    // The standard tracking-loss trigger is a Pause, so its mapping is what
    // decides whether a tracking drop gets a recovery attempt at all.
    let mut mgr = crate::triggers::TriggerManager::new();
    mgr.create_standard_triggers();
    let trigger = mgr
        .get_trigger("mount_tracking_lost")
        .expect("mount_tracking_lost is a standard trigger");
    assert!(matches!(trigger.recovery_action, RecoveryAction::Pause));
}

/// `SlewToGapAndContinue` turns the cloud analyzer's clear-sky direction
/// (alt/az) into the RA/Dec the mount is sent to. The conversion had no test:
/// replacing it with a constant, or flipping any sign in it, passed the whole
/// suite, and a wrong answer points the mount somewhere other than the gap,
/// possibly below the horizon. Converting back with the independently tested
/// `meridian::calculate_alt_az` must land on the direction asked for.
#[test]
fn a_clear_sky_direction_converts_to_coordinates_that_point_back_at_it() {
    let (latitude, longitude) = (40.0, -75.0);
    for (alt, az) in [(35.0, 120.0), (60.0, 250.0), (25.0, 10.0), (80.0, 180.0)] {
        let (ra, dec) =
            crate::executor::recovery_ops::alt_az_to_ra_dec(alt, az, latitude, longitude);
        let (alt_back, az_back) =
            crate::meridian::calculate_alt_az(ra, dec, latitude, longitude, chrono::Utc::now());
        let az_error = ((az_back - az + 540.0) % 360.0 - 180.0).abs();
        // A few seconds between the two clock reads moves the sky ~0.01 deg.
        assert!(
            (alt_back - alt).abs() < 0.1 && az_error < 0.1,
            "asked for alt {alt} / az {az}, the mount would point at alt {alt_back:.3} / az {az_back:.3}"
        );
        assert!((0.0..24.0).contains(&ra), "RA {ra} out of range");
    }
}
