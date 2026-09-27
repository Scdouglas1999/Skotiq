//! The recovery driver: serialises recovery requests from the trigger monitor
//! and the node tree, runs each attempt ladder, and drives the give-up safing
//! sweep when the budget is exhausted.

use super::*;

pub(super) struct RecoveryDriverArgs {
    pub recovery_driver_active_run_id: Arc<StdRwLock<Option<i64>>>,
    pub recovery_driver_cover_id: Option<String>,
    pub recovery_driver_current: Arc<StdRwLock<Option<crate::recovery::RecoveryContext>>>,
    pub recovery_driver_decision_tx: crate::decision::DecisionSender,
    pub recovery_driver_device_ids: Vec<String>,
    pub recovery_driver_device_ops: SharedDeviceOps,
    pub recovery_driver_dome_id: Option<String>,
    pub recovery_driver_event_tx: broadcast::Sender<ExecutorEvent>,
    pub recovery_driver_gave_up: Arc<AtomicBool>,
    pub recovery_driver_generation: Arc<std::sync::atomic::AtomicU64>,
    pub recovery_driver_history: Arc<StdRwLock<Vec<crate::recovery::RecoveryHistoryEntry>>>,
    pub recovery_driver_is_cancelled: Arc<AtomicBool>,
    pub recovery_driver_is_paused: Arc<AtomicBool>,
    pub recovery_driver_mount_id: Option<String>,
    pub recovery_driver_progress: Arc<StdRwLock<SequenceProgress>>,
    pub recovery_driver_runtime: Arc<StdRwLock<RuntimeConfig>>,
    pub recovery_driver_signals: Arc<crate::recovery::RecoverySignals>,
    pub recovery_driver_state: Arc<RwLock<ExecutorState>>,
    pub recovery_driver_trigger_mgr: Arc<RwLock<TriggerManager>>,
    pub recovery_request_rx: mpsc::Receiver<crate::recovery::RecoveryCause>,
}

pub(super) async fn run_recovery_driver(args: RecoveryDriverArgs) {
    let RecoveryDriverArgs {
        recovery_driver_active_run_id,
        recovery_driver_cover_id,
        recovery_driver_current,
        recovery_driver_decision_tx,
        recovery_driver_device_ids,
        recovery_driver_device_ops,
        recovery_driver_dome_id,
        recovery_driver_event_tx,
        recovery_driver_gave_up,
        recovery_driver_generation,
        recovery_driver_history,
        recovery_driver_is_cancelled,
        recovery_driver_is_paused,
        recovery_driver_mount_id,
        recovery_driver_progress,
        recovery_driver_runtime,
        recovery_driver_signals,
        recovery_driver_state,
        recovery_driver_trigger_mgr,
        mut recovery_request_rx,
    } = args;
    while let Some(cause) = recovery_request_rx.recv().await {
        // Don't enter recovery if the executor has already
        // been told to stop — the operator's Stop overrides
        // every other state machine.
        if recovery_driver_is_cancelled.load(Ordering::Relaxed) {
            tracing::info!(
                "[RECOVERY] Ignoring recovery request ({:?}) — sequence is cancelling",
                cause
            );
            continue;
        }

        // Build the context from the live runtime config.
        // Reading once and capturing into the context locks
        // the cadence for this loop; a mid-loop
        // UpdateRecoveryConfig only affects the *next*
        // recovery (predictable behaviour for the operator).
        let (interval_secs, max_duration_secs, stop_tracking) = {
            let rc = recovery_driver_runtime.read();
            (
                rc.recovery.retry_interval_secs,
                rc.recovery.max_duration_secs,
                rc.recovery.stop_tracking_during_recovery,
            )
        };

        let mut ctx =
            crate::recovery::RecoveryContext::new(cause.clone(), interval_secs, max_duration_secs);

        // Re-arm so any TryNow / Abort left over from a
        // previous loop is cleared, and the entry counter
        // increments so the Dart side knows this is a
        // fresh recovery.
        recovery_driver_signals.arm();

        // 1. Flip state -> Recovering and publish.
        *recovery_driver_state.write().await = ExecutorState::Recovering;
        {
            let mut prog = recovery_driver_progress.write();
            prog.state = ExecutorState::Recovering;
            prog.message = Some(format!("Recovering: {}", cause.display_label()));
        }
        *recovery_driver_current.write() = Some(ctx.clone());
        let _ =
            recovery_driver_event_tx.send(ExecutorEvent::StateChanged(ExecutorState::Recovering));
        let _ = recovery_driver_event_tx.send(ExecutorEvent::RecoveryStarted {
            context: Box::new(ctx.clone()),
        });
        // Replay Debug — promote recovery entry to
        // a first-class decision so the replay timeline
        // can render "Recovery entered: GuideStarLost"
        // (with the cause-kind + countdown context).
        {
            let mut decision_event = crate::decision::DecisionEvent::new(
                crate::decision::DecisionCategory::RecoveryEntered,
                format!("Recovery entered: {}", ctx.cause.display_label()),
                serde_json::json!({
                    "cause_kind": match &ctx.cause {
                        crate::recovery::RecoveryCause::GuideStarLost => "GuideStarLost",
                        crate::recovery::RecoveryCause::SlewFailed => "SlewFailed",
                        crate::recovery::RecoveryCause::PlateSolveFailed => "PlateSolveFailed",
                        crate::recovery::RecoveryCause::WeatherUnsafe => "WeatherUnsafe",
                        crate::recovery::RecoveryCause::MountTrackingLost => "MountTrackingLost",
                        crate::recovery::RecoveryCause::FocusDriftCritical => "FocusDriftCritical",
                        crate::recovery::RecoveryCause::ConsecutiveRejectsExceeded => "ConsecutiveRejectsExceeded",
                        crate::recovery::RecoveryCause::DeviceDisconnected => "DeviceDisconnected",
                        crate::recovery::RecoveryCause::Custom(_) => "Custom",
                    },
                    "cause_label": ctx.cause.display_label(),
                    "max_attempts": ctx.max_attempts,
                    "retry_interval_secs": ctx.retry_interval_secs,
                    "max_duration_secs": ctx.max_duration_secs,
                }),
            );
            decision_event.sequence_run_id = *recovery_driver_active_run_id.read();
            let _ = recovery_driver_decision_tx.send(decision_event);
        }

        // 2. Freeze node tree.
        recovery_driver_is_paused.store(true, Ordering::Relaxed);

        // 3. Optionally stop tracking.
        if stop_tracking {
            if let Some(mount_id) = &recovery_driver_mount_id {
                tracing::info!(
                    "[RECOVERY] Stopping mount tracking on '{}' for the recovery loop",
                    mount_id
                );
                if let Err(e) = recovery_driver_device_ops
                    .mount_set_tracking(mount_id, false)
                    .await
                {
                    tracing::warn!(
                        "[RECOVERY] Failed to stop tracking on '{}': {} \
                         (continuing — operator may want to park manually)",
                        mount_id,
                        e
                    );
                }
            }
        }

        // 4. Drive the retry loop.
        let aborted_by_user;
        let recovered;
        // Set when an attempt resolves as PauseForOperator —
        // the cause is not auto-recoverable by waiting, so the
        // loop exits into a real operator Pause (not resume,
        // not park-and-abort). Carries the operator message.
        let mut paused_for_operator: Option<String> = None;
        // Set when the run was cancelled under the ladder (an operator Stop, a
        // safety trigger's park-and-abort). That is not recovery running out,
        // and whoever cancelled owns how the run ends.
        let mut cancelled_under_recovery = false;
        loop {
            if recovery_driver_is_cancelled.load(Ordering::Relaxed) {
                tracing::info!("[RECOVERY] Sequence cancelled mid-recovery — exiting loop");
                cancelled_under_recovery = true;
                aborted_by_user = false;
                recovered = false;
                ctx.phase = crate::recovery::RecoveryPhase::GaveUp;
                break;
            }
            if recovery_driver_signals.take_abort() {
                tracing::warn!(
                    "[RECOVERY] Operator aborted recovery for cause {:?} after {} attempt{}",
                    ctx.cause,
                    ctx.attempt_count,
                    if ctx.attempt_count == 1 { "" } else { "s" }
                );
                aborted_by_user = true;
                recovered = false;
                ctx.phase = crate::recovery::RecoveryPhase::GaveUp;
                break;
            }
            if ctx.is_exhausted(chrono::Utc::now()) {
                tracing::warn!(
                    "[RECOVERY] Exhausted (attempts={}/{}, elapsed={:.0}s/{:.0}s)",
                    ctx.attempt_count,
                    ctx.max_attempts,
                    ctx.elapsed_secs(chrono::Utc::now()),
                    ctx.max_duration_secs
                );
                aborted_by_user = false;
                recovered = false;
                ctx.phase = crate::recovery::RecoveryPhase::GaveUp;
                break;
            }

            // Wait phase — uses tokio sleep + a polling
            // hot-check on the signal flags + cancellation
            // so the operator can punch through. We
            // resolve the wait as the *minimum* of the
            // configured interval and 0.5s (so the polling
            // is responsive). On the first attempt
            // `next_attempt_in_secs` returns 0 so we
            // skip the wait entirely.
            let wait_secs = ctx.next_attempt_in_secs(chrono::Utc::now());
            if wait_secs > 0.0 {
                ctx.phase = crate::recovery::RecoveryPhase::Waiting;
                *recovery_driver_current.write() = Some(ctx.clone());
                let _ = recovery_driver_event_tx.send(ExecutorEvent::RecoveryProgress {
                    context: Box::new(ctx.clone()),
                });

                let wait_start = std::time::Instant::now();
                let wait_duration = std::time::Duration::from_secs_f64(wait_secs);
                let poll_step = std::time::Duration::from_millis(500);
                let mut interrupted = false;
                while wait_start.elapsed() < wait_duration {
                    if recovery_driver_signals.take_try_now() {
                        tracing::info!("[RECOVERY] TryNow consumed — bypassing wait timer");
                        interrupted = true;
                        break;
                    }
                    if recovery_driver_signals.take_abort() {
                        // Replant the abort flag so the
                        // top-of-loop check picks it up
                        // and exits with the right
                        // aborted_by_user value.
                        recovery_driver_signals.request_abort();
                        break;
                    }
                    if recovery_driver_is_cancelled.load(Ordering::Relaxed) {
                        break;
                    }
                    tokio::time::sleep(poll_step).await;
                }
                if !interrupted && !recovery_driver_is_cancelled.load(Ordering::Relaxed) {
                    // Wait elapsed without a fast-forward;
                    // fall through to attempt.
                }
            }

            // Attempt phase.
            ctx.attempt_count = ctx.attempt_count.saturating_add(1);
            ctx.last_attempt_at = Some(chrono::Utc::now());
            ctx.phase = crate::recovery::RecoveryPhase::Attempting;
            tracing::info!(
                "[RECOVERY] Attempt {}/{} (cause={:?})",
                ctx.attempt_count,
                ctx.max_attempts,
                ctx.cause
            );
            *recovery_driver_current.write() = Some(ctx.clone());
            let _ = recovery_driver_event_tx.send(ExecutorEvent::RecoveryProgress {
                context: Box::new(ctx.clone()),
            });

            let outcome = run_recovery_attempt(
                &ctx.cause,
                &recovery_driver_device_ops,
                recovery_driver_mount_id.as_deref(),
                &recovery_driver_device_ids,
                &recovery_driver_trigger_mgr,
            )
            .await;

            match outcome {
                crate::recovery::AttemptOutcome::Succeeded => {
                    ctx.phase = crate::recovery::RecoveryPhase::Recovered;
                    aborted_by_user = false;
                    recovered = true;
                    break;
                }
                crate::recovery::AttemptOutcome::Failed { message } => {
                    tracing::warn!(
                        "[RECOVERY] Attempt {} failed: {}",
                        ctx.attempt_count,
                        message
                    );
                    ctx.last_error = Some(message);
                    ctx.phase = crate::recovery::RecoveryPhase::Waiting;
                    *recovery_driver_current.write() = Some(ctx.clone());
                    let _ = recovery_driver_event_tx.send(ExecutorEvent::RecoveryProgress {
                        context: Box::new(ctx.clone()),
                    });
                }
                crate::recovery::AttemptOutcome::Unrecoverable { message } => {
                    tracing::error!(
                        "[RECOVERY] Cause {:?} is not retryable: {} — ending the \
                         loop after {} attempt{} instead of burning the budget",
                        ctx.cause,
                        message,
                        ctx.attempt_count,
                        if ctx.attempt_count == 1 { "" } else { "s" }
                    );
                    // Take the ordinary give-up path (park, close
                    // cover/dome, fail) rather than sleeping the
                    // retry interval for an answer that cannot change.
                    aborted_by_user = false;
                    recovered = false;
                    ctx.last_error = Some(message);
                    ctx.phase = crate::recovery::RecoveryPhase::GaveUp;
                    *recovery_driver_current.write() = Some(ctx.clone());
                    let _ = recovery_driver_event_tx.send(ExecutorEvent::RecoveryProgress {
                        context: Box::new(ctx.clone()),
                    });
                    break;
                }
                crate::recovery::AttemptOutcome::Cancelled => {
                    tracing::info!("[RECOVERY] Attempt cancelled — exiting loop");
                    cancelled_under_recovery = true;
                    aborted_by_user = false;
                    recovered = false;
                    ctx.phase = crate::recovery::RecoveryPhase::GaveUp;
                    break;
                }
                crate::recovery::AttemptOutcome::PauseForOperator { message } => {
                    tracing::warn!(
                        "[RECOVERY] Cause {:?} escalated to operator Pause: {}",
                        ctx.cause,
                        message
                    );
                    // Not a recovery, not a give-up: a real
                    // operator Pause. Leave the node tree frozen
                    // (is_paused stays true) and hand the run to
                    // the operator.
                    aborted_by_user = false;
                    recovered = false;
                    ctx.last_error = Some(message.clone());
                    ctx.phase = crate::recovery::RecoveryPhase::GaveUp;
                    paused_for_operator = Some(message);
                    break;
                }
            }
        }

        // Record the history entry regardless of outcome.
        let ended_at = chrono::Utc::now();
        {
            let mut history = recovery_driver_history.write();
            history.push(crate::recovery::RecoveryHistoryEntry {
                started_at: ctx.started_at,
                ended_at,
                cause: ctx.cause.clone(),
                attempts: ctx.attempt_count,
                recovered,
                aborted_by_user,
                last_error: ctx.last_error.clone(),
            });
        }

        if cancelled_under_recovery && !recovered && paused_for_operator.is_none() {
            // No give-up message, no give-up sweep, no Failed stamp: reporting
            // "Recovery could not fix" for a run that was stopped, or parked
            // by the weather rule, would blame the wrong thing, and under the
            // park-and-close opt-in it would run a second sweep nobody asked
            // for.
            tracing::info!(
                "[RECOVERY] Recovery for {:?} ended because the run was cancelled after {} \
                 attempt{}",
                ctx.cause,
                ctx.attempt_count,
                if ctx.attempt_count == 1 { "" } else { "s" }
            );
            *recovery_driver_current.write() = None;
        } else if let Some(pause_message) = paused_for_operator {
            // The PauseForOperator escalation handling lives in
            // `apply_recovery_escalation` so an integration test can drive the
            // SafeAbandon vs PassivePause branch, and the
            // tracking-restore-before-Paused ordering, against real device-ops
            // without spinning up this whole closure.
            let escalation_state = RecoveryEscalationState {
                device_ops: &recovery_driver_device_ops,
                event_tx: &recovery_driver_event_tx,
                runtime_config: &recovery_driver_runtime,
                state: &recovery_driver_state,
                progress: &recovery_driver_progress,
                current_recovery: &recovery_driver_current,
                is_cancelled: &recovery_driver_is_cancelled,
                gave_up: &recovery_driver_gave_up,
                mount_id: recovery_driver_mount_id.as_deref(),
                cover_id: recovery_driver_cover_id.as_deref(),
                dome_id: recovery_driver_dome_id.as_deref(),
            };
            apply_recovery_escalation(&escalation_state, &ctx, pause_message, stop_tracking).await;
        } else if recovered {
            tracing::info!(
                "[RECOVERY] Loop succeeded after {} attempt{}; resuming sequence",
                ctx.attempt_count,
                if ctx.attempt_count == 1 { "" } else { "s" }
            );
            *recovery_driver_state.write().await = ExecutorState::Running;
            {
                let mut prog = recovery_driver_progress.write();
                prog.state = ExecutorState::Running;
                prog.message = Some("Recovered — resuming sequence".to_string());
            }
            *recovery_driver_current.write() = None;

            // Re-enable tracking if the recovery loop stopped it
            // (stop_tracking_during_recovery) — for ALL causes, not
            // only MountTrackingLost, because resuming on a
            // non-tracking mount trails the rest of the night while
            // the UI reports "Recovered". A restore that fails
            // raises a loud error rather than resuming untracked.
            let tracking_warning = restore_tracking_after_recovery(
                &recovery_driver_device_ops,
                recovery_driver_mount_id.as_deref(),
                stop_tracking,
                "after recovery",
                &recovery_driver_event_tx,
            )
            .await;
            // `sequencer_get_status()` reports `progress.message`, and it was
            // stamped "Recovered — resuming sequence" above BEFORE the restore
            // ran. A restore that failed then left the status line claiming a
            // clean recovery while every subsequent frame trailed. Overwrite it
            // with the helper's verdict so the poll surface and the event
            // stream tell the same story.
            if let Some(warning) = &tracking_warning {
                let mut prog = recovery_driver_progress.write();
                prog.message = Some(warning.clone());
            }

            // Publish completion BEFORE clearing the pause, so an
            // instruction that observes the cleared pause can always
            // also observe the advanced generation (no window where
            // it sees "not paused" with a stale generation).
            recovery_driver_generation.fetch_add(1, Ordering::AcqRel);
            recovery_driver_is_paused.store(false, Ordering::Relaxed);
            let _ =
                recovery_driver_event_tx.send(ExecutorEvent::StateChanged(ExecutorState::Running));
            let _ = recovery_driver_event_tx.send(ExecutorEvent::RecoveryCompleted {
                context: Box::new(ctx.clone()),
            });
        } else {
            tracing::error!(
                "[RECOVERY] Loop gave up after {} attempt{} (aborted={})",
                ctx.attempt_count,
                if ctx.attempt_count == 1 { "" } else { "s" },
                aborted_by_user
            );
            *recovery_driver_current.write() = None;

            // Recovery exhausted on a real failure (NOT an operator abort).
            // Whether the run may now park the mount and close up is the
            // operator's standing decision, read from the same
            // `UnattendedEndPolicy` the PauseForOperator escalation consults —
            // there is exactly one gate on irreversible hardware action in the
            // recovery path, so a park cannot reappear here under another name.
            //
            // Under the default `HoldForOperator` the run still ends (a
            // 90-minute budget really is exhausted and the night needs a
            // terminal event and a report), but it ends without moving
            // anything. If the operator wants the mount parked at dawn on a
            // remote rig, `ParkAndClose` is the setting that says so; the
            // safety-class triggers (weather unsafe, dawn approaching, dome
            // shutter) keep their own configured ParkAndAbort behaviour either
            // way, so a rig in actual danger is still protected.
            let end_policy =
                UnattendedEndPolicy::from_recovery_config(&recovery_driver_runtime.read().recovery);
            if !aborted_by_user {
                recovery_driver_gave_up.store(true, Ordering::Relaxed);
            }
            if !aborted_by_user && !end_policy.may_safe_abandon() {
                tracing::warn!(
                    "[RECOVERY] Recovery exhausted for {:?} after {} attempt{}; operator policy \
                     is '{}', so the run ends WITHOUT parking or closing anything. The mount has \
                     not been moved.",
                    ctx.cause,
                    ctx.attempt_count,
                    if ctx.attempt_count == 1 { "" } else { "s" },
                    end_policy.label()
                );
                let _ = recovery_driver_event_tx.send(ExecutorEvent::Error {
                    message: format!(
                        "Recovery could not fix {} after {} attempt{}. The run has stopped. \
                         Nothing has been parked or closed — check the rig when you can.",
                        ctx.cause.display_label(),
                        ctx.attempt_count,
                        if ctx.attempt_count == 1 { "" } else { "s" }
                    ),
                });
            }
            if !aborted_by_user && end_policy.may_safe_abandon() {
                // Single source of truth for the park → close
                // cover → close dome safe-state sweep
                // `device_ops::park_and_close_safe_state` is the single
                // source of truth for the park → close cover → close
                // dome sweep; this path passes 2 park retries at a 2 s
                // delay. Each call site words its own operator-facing
                // events from the returned outcome.
                // wording from the returned outcome.
                let outcome = crate::device_ops::park_and_close_safe_state(
                    &recovery_driver_device_ops,
                    recovery_driver_mount_id.as_deref(),
                    recovery_driver_cover_id.as_deref(),
                    recovery_driver_dome_id.as_deref(),
                    2,
                    2.0,
                )
                .await;

                if let (Some(mount_id), Some(park)) = (&recovery_driver_mount_id, &outcome.park) {
                    if park.success {
                        tracing::info!(
                            "[RECOVERY] Parked mount '{}' on give-up ({} attempt{})",
                            mount_id,
                            park.attempts_made,
                            if park.attempts_made == 1 { "" } else { "s" }
                        );
                    } else {
                        let msg = format!(
                            "Recovery exhausted and the mount could not be parked ({}): {} — mount may be UNSAFE.",
                            mount_id,
                            park.last_error
                                .clone()
                                .unwrap_or_else(|| "unknown".to_string())
                        );
                        tracing::error!("[RECOVERY] {}", msg);
                        let _ =
                            recovery_driver_event_tx.send(ExecutorEvent::Error { message: msg });
                    }
                }

                if let (Some(cover_id), Some(e)) =
                    (&recovery_driver_cover_id, &outcome.cover_close_error)
                {
                    let msg = format!(
                        "Recovery give-up: failed to close cover '{}': {}",
                        cover_id, e
                    );
                    tracing::error!("[RECOVERY] {}", msg);
                    let _ = recovery_driver_event_tx.send(ExecutorEvent::Error { message: msg });
                }
                if let (Some(dome_id), Some(e)) =
                    (&recovery_driver_dome_id, &outcome.dome_close_error)
                {
                    let msg = format!(
                        "Recovery give-up: failed to close dome '{}': {} — scope may be exposed.",
                        dome_id, e
                    );
                    tracing::error!("[RECOVERY] {}", msg);
                    let _ = recovery_driver_event_tx.send(ExecutorEvent::Error { message: msg });
                }
            }

            // Transition to Failed and emit the gave-up
            // event. Leave `is_paused` set — the node tree
            // is going to be cancelled by the outer logic
            // anyway, but the explicit Cancelled signal
            // ensures any active instruction returns
            // promptly.
            recovery_driver_is_cancelled.store(true, Ordering::Relaxed);
            *recovery_driver_state.write().await = ExecutorState::Failed;
            {
                let mut prog = recovery_driver_progress.write();
                prog.state = ExecutorState::Failed;
                prog.message = Some(if aborted_by_user {
                    format!(
                        "Recovery aborted by operator after {} attempt{}",
                        ctx.attempt_count,
                        if ctx.attempt_count == 1 { "" } else { "s" }
                    )
                } else {
                    format!(
                        "Recovery exhausted after {} attempt{}",
                        ctx.attempt_count,
                        if ctx.attempt_count == 1 { "" } else { "s" }
                    )
                });
            }
            let _ =
                recovery_driver_event_tx.send(ExecutorEvent::StateChanged(ExecutorState::Failed));
            let _ = recovery_driver_event_tx.send(ExecutorEvent::RecoveryGaveUp {
                context: Box::new(ctx.clone()),
                aborted_by_user,
            });
            // Loop body exit — the outer trigger_monitor
            // task observed Cancelled and will end the
            // sequence on its next tick.
        }
    }
}
