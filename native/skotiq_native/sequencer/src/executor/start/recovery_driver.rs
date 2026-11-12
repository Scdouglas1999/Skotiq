//! The recovery driver: serialises recovery requests from the trigger monitor
//! and the node tree, runs each attempt ladder, and drives the give-up safing
//! sweep when the budget is exhausted.

use super::*;
use crate::recovery::{HoldKind, OnGiveUp};

/// `instruction_shared` is the run's (see [`Run::instruction_shared`]); the
/// driver's moves run against it.
pub(super) async fn run_recovery_driver(
    run: Arc<Run>,
    mut instruction_shared: crate::instructions::RunShared,
    mut recovery_request_rx: mpsc::Receiver<crate::recovery::RecoveryCause>,
) {
    // The driver ends when the node tree and the monitor drop their senders,
    // so it must not hold one itself.
    instruction_shared.recovery_request_tx = None;
    let run_state = run.control.state.clone();
    let event_tx = run_state.events().clone();
    let is_cancelled = run.control.is_cancelled.clone();
    let is_paused = run.control.is_paused.clone();
    let active_run_id = run.decisions.run_id.clone();
    let decision_tx = run.decisions.tx.clone();
    let current = run.recovery.current.clone();
    let history = run.recovery.history.clone();
    let signals = run.recovery.signals.clone();
    let generation = run.recovery.generation.clone();
    let gave_up = run.outside_failures.recovery_gave_up.clone();
    let device_ops = run.device_ops.clone();
    let runtime = run.config.clone();
    let trigger_mgr = run.triggers.clone();
    let device_ids = run.recovery.reconnect_device_ids.clone();
    let mount_id = run.rig.mount_id.clone();
    let dome_id = run.rig.dome_id.clone();
    let cover_id = run.rig.cover_calibrator_id.clone();
    while let Some(cause) = recovery_request_rx.recv().await {
        // Don't enter recovery if the executor has already
        // been told to stop — the operator's Stop overrides
        // every other state machine.
        if is_cancelled.load(Ordering::Relaxed) {
            tracing::info!(
                "[RECOVERY] Ignoring recovery request ({:?}) — sequence is cancelling",
                cause
            );
            continue;
        }

        // Requests already queued before the tracking-limit hold was adopted
        // must not steal the mount back from its flip controller.
        if cause.policy().yields_to_tracking_limit_flip()
            && trigger_mgr.read().await.state().read().await.run.hold()
                == Some(crate::triggers::RunHold::TrackingLimit)
        {
            continue;
        }

        // Build the context from the live runtime config.
        // Reading once and capturing into the context locks
        // the cadence for this loop; a mid-loop
        // UpdateRecoveryConfig only affects the *next*
        // recovery (predictable behaviour for the operator).
        let (interval_secs, max_duration_secs, stop_tracking) = {
            let rc = runtime.read();
            (
                rc.recovery.retry_interval_secs,
                rc.recovery.max_duration_secs,
                rc.recovery.stop_tracking_during_recovery,
            )
        };
        let configured_cadence = (interval_secs, max_duration_secs);

        // Latched for the loop, and replaced when an attempt hands the
        // recovery to another cause.
        let mut policy = cause.policy();
        let (interval_secs, max_duration_secs) =
            policy.cadence.resolve(interval_secs, max_duration_secs);
        let stop_tracking = stop_tracking && policy.may_stop_tracking;
        let mut weather_safe_since: Option<std::time::Instant> = None;
        let mut ctx =
            crate::recovery::RecoveryContext::new(cause.clone(), interval_secs, max_duration_secs);

        // Re-arm so any TryNow / Abort left over from a
        // previous loop is cleared, and the entry counter
        // increments so the Dart side knows this is a
        // fresh recovery.
        signals.arm();

        // 1. Flip state -> Recovering and publish.
        let recovering = run_state.store(ExecutorState::Recovering, |progress| {
            progress.message = Some(format!("Recovering: {}", cause.display_label()));
        });
        *current.write() = Some(ctx.clone());
        recovering.announce();
        let _ = event_tx.send(ExecutorEvent::RecoveryStarted {
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
                    "cause_kind": policy.kind,
                    "cause_label": ctx.cause.display_label(),
                    "max_attempts": ctx.max_attempts,
                    "retry_interval_secs": ctx.retry_interval_secs,
                    "max_duration_secs": ctx.max_duration_secs,
                }),
            );
            decision_event.sequence_run_id = *active_run_id.read();
            let _ = decision_tx.send(decision_event);
        }

        // 2. Freeze node tree.
        is_paused.store(true, Ordering::Relaxed);

        // 3. Optionally stop tracking, but never under a moving mount. On the
        // rig (2026-10-07) a guide-star loss caused by the run's own slew
        // stopped tracking 40 ms into that slew, and the Center after it
        // solved trailed frames.
        // Everything after this reads `stop_tracking` as "tracking was
        // stopped", so a moving mount clears it.
        let stop_tracking = stop_tracking
            && match &mount_id {
                Some(mount_id) => {
                    let run_is_moving_mount = {
                        let manager = trigger_mgr.read().await;
                        let depth = manager.state().read().await.guiding.motion_depth();
                        depth > 0
                    };
                    let moving = run_is_moving_mount
                        || matches!(
                            tokio::time::timeout(
                                std::time::Duration::from_secs(5),
                                device_ops.mount_is_slewing(mount_id),
                            )
                            .await,
                            Ok(Ok(true))
                        );
                    if moving {
                        tracing::info!(
                            "[RECOVERY] Leaving tracking on '{}': the mount is moving",
                            mount_id
                        );
                    }
                    !moving
                }
                None => true,
            };
        if stop_tracking {
            if let Some(mount_id) = &mount_id {
                tracing::info!(
                    "[RECOVERY] Stopping mount tracking on '{}' for the recovery loop",
                    mount_id
                );
                // The run's own stop is not a lost-tracking event.
                {
                    let manager = trigger_mgr.read().await;
                    manager
                        .state()
                        .write()
                        .await
                        .run
                        .begin_hold(crate::triggers::RunHold::RecoveryTracking);
                }
                if let Err(e) = device_ops.mount_set_tracking(mount_id, false).await {
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
        let mut handed_to_flip = false;
        loop {
            if is_cancelled.load(Ordering::Relaxed) {
                tracing::info!("[RECOVERY] Sequence cancelled mid-recovery — exiting loop");
                cancelled_under_recovery = true;
                aborted_by_user = false;
                recovered = false;
                ctx.phase = crate::recovery::RecoveryPhase::GaveUp;
                break;
            }
            if signals.take_abort() {
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
            if policy.yields_to_tracking_limit_flip()
                && hand_off_tracking_limit(&device_ops, mount_id.as_deref(), &trigger_mgr).await
            {
                handed_to_flip = true;
                aborted_by_user = false;
                recovered = false;
                ctx.phase = crate::recovery::RecoveryPhase::Waiting;
                ctx.last_error = Some("Recovery handed to the tracking-limit flip".into());
                break;
            }
            if policy.can_give_up && ctx.is_exhausted(chrono::Utc::now()) {
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
                *current.write() = Some(ctx.clone());
                let _ = event_tx.send(ExecutorEvent::RecoveryProgress {
                    context: Box::new(ctx.clone()),
                });

                let wait_start = std::time::Instant::now();
                let wait_duration = std::time::Duration::from_secs_f64(wait_secs);
                let poll_step = std::time::Duration::from_millis(500);
                let mut interrupted = false;
                while wait_start.elapsed() < wait_duration {
                    if signals.take_try_now() {
                        tracing::info!("[RECOVERY] TryNow consumed — bypassing wait timer");
                        interrupted = true;
                        break;
                    }
                    if signals.take_abort() {
                        // Replant the abort flag so the
                        // top-of-loop check picks it up
                        // and exits with the right
                        // aborted_by_user value.
                        signals.request_abort();
                        break;
                    }
                    if is_cancelled.load(Ordering::Relaxed) {
                        break;
                    }
                    tokio::time::sleep(poll_step).await;
                }
                if !interrupted && !is_cancelled.load(Ordering::Relaxed) {
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
            *current.write() = Some(ctx.clone());
            let _ = event_tx.send(ExecutorEvent::RecoveryProgress {
                context: Box::new(ctx.clone()),
            });

            let outcome = if policy.hold == Some(HoldKind::Weather) {
                let resume_after = runtime
                    .read()
                    .weather_resume_after_safe_secs
                    .unwrap_or(DEFAULT_WEATHER_RESUME_AFTER_SAFE_SECS);
                weather_hold_attempt(
                    &device_ops,
                    &trigger_mgr,
                    &mut weather_safe_since,
                    resume_after,
                )
                .await
            } else {
                run_recovery_attempt(
                    &ctx.cause,
                    &device_ops,
                    mount_id.as_deref(),
                    &device_ids,
                    &trigger_mgr,
                )
                .await
            };

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
                    if policy.hold == Some(HoldKind::Tracking) {
                        ctx.retry_interval_secs =
                            policy.cadence.after_failure(ctx.retry_interval_secs);
                        let _ = event_tx.send(ExecutorEvent::Warning {
                            message: format!(
                                "{message}. Trying again in {:.0} s; the run stays held until \
                                 the mount tracks.",
                                ctx.retry_interval_secs
                            ),
                        });
                    }
                    ctx.last_error = Some(message);
                    ctx.phase = crate::recovery::RecoveryPhase::Waiting;
                    *current.write() = Some(ctx.clone());
                    let _ = event_tx.send(ExecutorEvent::RecoveryProgress {
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
                    *current.write() = Some(ctx.clone());
                    let _ = event_tx.send(ExecutorEvent::RecoveryProgress {
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
                crate::recovery::AttemptOutcome::HandOff { cause, message } => {
                    tracing::warn!(
                        "[RECOVERY] {} (after {} attempt{} for {:?})",
                        message,
                        ctx.attempt_count,
                        if ctx.attempt_count == 1 { "" } else { "s" },
                        ctx.cause
                    );
                    let _ = event_tx.send(ExecutorEvent::Warning {
                        message: message.clone(),
                    });
                    // The new cause takes its own recovery: a stopped mount
                    // gets the tracking hold's growing, never-exhausted wait.
                    policy = cause.policy();
                    let (interval, max_duration) = configured_cadence;
                    let (interval, max_duration) = policy.cadence.resolve(interval, max_duration);
                    ctx = crate::recovery::RecoveryContext::new(cause, interval, max_duration);
                    ctx.last_error = Some(message);
                    *current.write() = Some(ctx.clone());
                    let _ = event_tx.send(ExecutorEvent::RecoveryProgress {
                        context: Box::new(ctx.clone()),
                    });
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

        // A handoff is still in progress, not a recovered or failed attempt.
        let ended_at = chrono::Utc::now();
        if !handed_to_flip {
            let mut history = history.write();
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

        if handed_to_flip {
            // End this retry ladder without claiming recovery or releasing
            // exposures. The monitor owns the newly latched hold and keeps
            // polling safety while it waits for the configured flip window.
            *current.write() = None;
            let message = "Mount tracking stopped near the meridian; recovery is handing the mount to the meridian flip.";
            run_state.transition_from(
                ExecutorState::Recovering,
                ExecutorState::Running,
                message,
                || !is_cancelled.load(Ordering::Relaxed),
            );
            tracing::warn!("[RECOVERY] {}", message);
            let _ = event_tx.send(ExecutorEvent::Warning {
                message: message.into(),
            });
            let _ = event_tx.send(ExecutorEvent::RecoveryCompleted {
                context: Box::new(ctx.clone()),
            });
        } else if cancelled_under_recovery && !recovered && paused_for_operator.is_none() {
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
            *current.write() = None;
        } else if let Some(pause_message) = paused_for_operator {
            // The PauseForOperator escalation handling lives in
            // `apply_recovery_escalation` so an integration test can drive the
            // SafeAbandon vs PassivePause branch, and the
            // tracking-restore-before-Paused ordering, against real device-ops
            // without spinning up this whole closure.
            let escalation_state = RecoveryEscalationState {
                device_ops: &device_ops,
                run_state: &run_state,
                runtime_config: &runtime,
                current_recovery: &current,
                is_cancelled: &is_cancelled,
                gave_up: &gave_up,
                mount_id: mount_id.as_deref(),
                cover_id: cover_id.as_deref(),
                dome_id: dome_id.as_deref(),
            };
            apply_recovery_escalation(&escalation_state, &ctx, pause_message, stop_tracking).await;
        } else if recovered {
            // An operator Pause during the ladder is the only thing that
            // turns `Recovering` into `Paused` while it runs. That hold is his,
            // so a successful ladder leaves it in place rather than resuming
            // the run under him.
            let operator_paused = run_state.get() == ExecutorState::Paused;
            let resumed_state = if operator_paused {
                ExecutorState::Paused
            } else {
                ExecutorState::Running
            };
            tracing::info!(
                "[RECOVERY] Loop succeeded after {} attempt{}; {}",
                ctx.attempt_count,
                if ctx.attempt_count == 1 { "" } else { "s" },
                if operator_paused {
                    "the run stays paused as the operator left it"
                } else {
                    "resuming sequence"
                }
            );
            if policy.hold == Some(HoldKind::Weather) && !operator_paused {
                prepare_imaging_after_weather_hold(WeatherHoldExit {
                    held_secs: ctx.elapsed_secs(chrono::Utc::now()),
                    shared: &instruction_shared,
                    trigger_mgr: &trigger_mgr,
                    is_cancelled: &is_cancelled,
                    event_tx: &event_tx,
                })
                .await;
            }
            if policy.hold == Some(HoldKind::Tracking) {
                // The attempt confirmed the axes track. Record that, so the
                // poll's unresolved loss cannot fire the trigger again.
                let lock = trigger_mgr.read().await.state();
                let mut state = lock.write().await;
                state.telemetry.mount_is_tracking = Some(true);
                state.reset_tracking_limit_detection();
                state.set_mount_tracking_expected(true);
                let _ = event_tx.send(ExecutorEvent::Warning {
                    message: format!(
                        "Mount tracking is restored and confirmed from the mount's pointing after \
                         {} attempt{}.",
                        ctx.attempt_count,
                        if ctx.attempt_count == 1 { "" } else { "s" }
                    ),
                });
            }
            let resumed = run_state.store(resumed_state, |progress| {
                progress.message = Some(if operator_paused {
                    "Recovered — paused, as you left it".to_string()
                } else {
                    "Recovered — resuming sequence".to_string()
                });
            });
            *current.write() = None;

            // Re-enable tracking if the recovery loop stopped it
            // (stop_tracking_during_recovery) — for ALL causes, not
            // only MountTrackingLost, because resuming on a
            // non-tracking mount trails the rest of the night while
            // the UI reports "Recovered". A restore that fails
            // raises a loud error rather than resuming untracked.
            let tracking_warning = restore_tracking_after_recovery(
                &device_ops,
                mount_id.as_deref(),
                stop_tracking,
                "after recovery",
                &event_tx,
            )
            .await;
            // `sequencer_get_status()` reports `progress.message`, and it was
            // stamped "Recovered — resuming sequence" above BEFORE the restore
            // ran. A restore that failed then left the status line claiming a
            // clean recovery while every subsequent frame trailed. Overwrite it
            // with the helper's verdict so the poll surface and the event
            // stream tell the same story.
            if let Some(warning) = &tracking_warning {
                run_state.set_message(warning.clone());
            }

            // Publish completion BEFORE clearing the pause, so an
            // instruction that observes the cleared pause can always
            // also observe the advanced generation (no window where
            // it sees "not paused" with a stale generation).
            generation.fetch_add(1, Ordering::AcqRel);
            if !operator_paused {
                is_paused.store(false, Ordering::Relaxed);
            }
            resumed.announce();
            let _ = event_tx.send(ExecutorEvent::RecoveryCompleted {
                context: Box::new(ctx.clone()),
            });
        } else if !aborted_by_user
            && policy.on_give_up == OnGiveUp::ContinueUnguided
            && !crate::triggers::stops_on_quality_problems(Some(&trigger_mgr.read().await.state()))
                .await
        {
            // The guide star did not come back within the budget. That costs
            // trailed frames, which grading marks, not the hardware, so the run
            // goes on unguided rather than ending the night (owner decision
            // 2026-10-06). "Stop the run for quality problems" brings back the
            // old ending below. Nothing is parked: the run is not ending.
            let active_run_id = *active_run_id.read();
            continue_unguided(UnguidedContinuation {
                ctx: &ctx,
                active_run_id,
                decision_tx: &decision_tx,
                device_ops: &device_ops,
                event_tx: &event_tx,
                generation: &generation,
                is_paused: &is_paused,
                mount_id: mount_id.as_deref(),
                run_state: &run_state,
                current: &current,
                stop_tracking,
                trigger_mgr: &trigger_mgr,
            })
            .await;
        } else {
            tracing::error!(
                "[RECOVERY] Loop gave up after {} attempt{} (aborted={})",
                ctx.attempt_count,
                if ctx.attempt_count == 1 { "" } else { "s" },
                aborted_by_user
            );
            *current.write() = None;

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
            let end_policy = UnattendedEndPolicy::from_recovery_config(&runtime.read().recovery);
            if !aborted_by_user {
                gave_up.store(true, Ordering::Relaxed);
            }
            if !aborted_by_user && !end_policy.may_safe_abandon() {
                // The ladder switched tracking off before its first attempt
                // (`stop_tracking_during_recovery`) and nothing restores it for
                // a run that has ended. Say so: "nothing has been moved" read
                // as "the mount is as you left it", and it was not.
                let tracking_note = if stop_tracking && mount_id.is_some() {
                    " Mount tracking was switched off for the recovery and is still off."
                } else {
                    ""
                };
                tracing::warn!(
                    "[RECOVERY] Recovery exhausted for {:?} after {} attempt{}; operator policy \
                     is '{}', so the run ends WITHOUT parking or closing anything.{}",
                    ctx.cause,
                    ctx.attempt_count,
                    if ctx.attempt_count == 1 { "" } else { "s" },
                    end_policy.label(),
                    tracking_note
                );
                let _ = event_tx.send(ExecutorEvent::Error {
                    message: format!(
                        "Recovery could not fix {} after {} attempt{}. The run has stopped. \
                         Nothing has been parked or closed.{} Check the rig when you can.",
                        ctx.cause.display_label(),
                        ctx.attempt_count,
                        if ctx.attempt_count == 1 { "" } else { "s" },
                        tracking_note
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
                    &device_ops,
                    mount_id.as_deref(),
                    cover_id.as_deref(),
                    dome_id.as_deref(),
                    2,
                    2.0,
                )
                .await;

                if let (Some(mount_id), Some(park)) = (&mount_id, &outcome.park) {
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
                        let _ = event_tx.send(ExecutorEvent::Error { message: msg });
                    }
                }

                if let (Some(cover_id), Some(e)) = (&cover_id, &outcome.cover_close_error) {
                    let msg = format!(
                        "Recovery give-up: failed to close cover '{}': {}",
                        cover_id, e
                    );
                    tracing::error!("[RECOVERY] {}", msg);
                    let _ = event_tx.send(ExecutorEvent::Error { message: msg });
                }
                if let (Some(dome_id), Some(e)) = (&dome_id, &outcome.dome_close_error) {
                    let msg = format!(
                        "Recovery give-up: failed to close dome '{}': {} — scope may be exposed.",
                        dome_id, e
                    );
                    tracing::error!("[RECOVERY] {}", msg);
                    let _ = event_tx.send(ExecutorEvent::Error { message: msg });
                }
            }

            // Transition to Failed and emit the gave-up
            // event. Leave `is_paused` set — the node tree
            // is going to be cancelled by the outer logic
            // anyway, but the explicit Cancelled signal
            // ensures any active instruction returns
            // promptly.
            is_cancelled.store(true, Ordering::Relaxed);
            run_state.transition_with_message(
                ExecutorState::Failed,
                format!(
                    "Recovery {} after {} attempt{}",
                    if aborted_by_user {
                        "aborted by operator"
                    } else {
                        "exhausted"
                    },
                    ctx.attempt_count,
                    if ctx.attempt_count == 1 { "" } else { "s" }
                ),
            );
            let _ = event_tx.send(ExecutorEvent::RecoveryGaveUp {
                context: Box::new(ctx.clone()),
                aborted_by_user,
            });
            // Loop body exit — the outer trigger_monitor
            // task observed Cancelled and will end the
            // sequence on its next tick.
        }

        // Tracking is restored (or the run has ended); from here a tracking
        // change is the mount's own again.
        if stop_tracking && mount_id.is_some() {
            let manager = trigger_mgr.read().await;
            manager.state().write().await.run.end_hold();
        }
    }
}

/// What [`prepare_imaging_after_weather_hold`] needs.
struct WeatherHoldExit<'a> {
    held_secs: f64,
    shared: &'a crate::instructions::RunShared,
    trigger_mgr: &'a Arc<RwLock<TriggerManager>>,
    is_cancelled: &'a Arc<AtomicBool>,
    event_tx: &'a broadcast::Sender<ExecutorEvent>,
}

/// Get the rig ready to image again after a weather hold, before the node tree
/// is released: recenter on the target after a long hold, and have guiding
/// that lost its star during the hold start again on a fresh star before the
/// next light frame. Neither can end the run; a recenter that fails is told
/// and the run images where the mount points.
async fn prepare_imaging_after_weather_hold(exit: WeatherHoldExit<'_>) {
    let state = exit.trigger_mgr.read().await.state();
    let (target_name, target_ra_hours, target_dec, current_filter) = {
        let ts = state.read().await;
        (
            ts.target.current_target_name.clone(),
            ts.target.target_ra.map(|ra| ra / 15.0),
            ts.target.target_dec,
            ts.latches.current_filter.clone(),
        )
    };
    let recenter = exit.held_secs >= WEATHER_HOLD_RECENTER_AFTER_SECS
        && target_ra_hours.is_some()
        && target_dec.is_some()
        && exit.shared.rig.mount_id.is_some()
        && exit.shared.rig.camera_id.is_some();
    if recenter {
        tracing::info!(
            "[WEATHER] Held for {:.0} min; recentering on the target before imaging again",
            exit.held_secs / 60.0
        );
        let mut claim =
            TriggerCameraClaim::acquire(&state, exit.is_cancelled, &RecoveryAction::Recenter).await;
        let ctx = crate::instructions::InstructionContext {
            target_ra: target_ra_hours,
            target_dec,
            target_name,
            current_filter,
            ..crate::instructions::InstructionContext::new(
                exit.shared.for_step(),
                exit.is_cancelled.clone(),
            )
        };
        let config = crate::CenterConfig {
            use_target_coords: true,
            custom_ra: None,
            custom_dec: None,
            accuracy_arcsec: 10.0,
            max_attempts: 3,
            exposure_duration: 5.0,
            filter: None,
        };
        let result = crate::instructions::execute_center(&config, &ctx, None).await;
        claim.release().await;
        if result.status != NodeStatus::Success {
            let message = format!(
                "Recentering after the weather hold did not succeed ({}). The run images where \
                 the mount points.",
                result.message.as_deref().unwrap_or("no detail")
            );
            tracing::warn!("[WEATHER] {}", message);
            let _ = exit.event_tx.send(ExecutorEvent::Warning { message });
        }
        // The Center's own move marked this run's guiding for a restart on a
        // fresh star before the next light frame.
        return;
    }

    let run_guiding = state.read().await.guiding.is_enabled();
    if !run_guiding {
        return;
    }
    let settled = matches!(
        exit.shared.device_ops.guider_get_status().await,
        Ok(status) if guiding_is_settled(&status)
    );
    if settled {
        return;
    }
    tracing::info!(
        "[WEATHER] Guiding is not holding a star after the weather hold; it starts again on a \
         fresh star before the next light frame"
    );
    crate::instructions::stop_an_active_guider(
        &exit.shared.device_ops,
        "restart after the weather hold",
        crate::GuidingStopReason::MountMove,
    )
    .await;
    let mut ts = state.write().await;
    ts.set_guiding_enabled(false);
    ts.set_guide_star_lost(false);
    ts.guiding.set_resume_pending(true);
}

struct UnguidedContinuation<'a> {
    ctx: &'a crate::recovery::RecoveryContext,
    active_run_id: Option<i64>,
    decision_tx: &'a crate::decision::DecisionSender,
    device_ops: &'a SharedDeviceOps,
    event_tx: &'a broadcast::Sender<ExecutorEvent>,
    generation: &'a std::sync::atomic::AtomicU64,
    is_paused: &'a AtomicBool,
    mount_id: Option<&'a str>,
    run_state: &'a RunCell,
    current: &'a StdRwLock<Option<crate::recovery::RecoveryContext>>,
    stop_tracking: bool,
    trigger_mgr: &'a Arc<RwLock<TriggerManager>>,
}

/// End a guide-star recovery that ran out by imaging on without guiding.
///
/// The star-lost trigger is disarmed (the guider is not guiding, so it would
/// fire again at once) and the run is marked as imaging unguided, which the
/// steps that need a guider read: dithers are skipped, a guider that cannot
/// start does not fail them, and guiding RMS is not judged. The trigger
/// monitor clears the mark and re-arms the trigger when it next sees the
/// guider guiding, whether the operator restarted it or PHD2 found a star.
async fn continue_unguided(c: UnguidedContinuation<'_>) {
    {
        let manager = c.trigger_mgr.read().await;
        let state_lock = manager.state();
        let mut state = state_lock.write().await;
        state.guiding.give_up_guiding();
        // The failures stay for the obstruction check; the next recovery
        // measures how far guiding moves the mount from where it begins.
        if let Some(stall) = state.latches.guide_recovery.as_mut() {
            stall.origin = None;
        }
        if let Some(history) = state.latches.guiding_rms_history.as_mut() {
            history.clear();
        }
    }

    let operator_paused = c.run_state.get() == ExecutorState::Paused;
    let resumed_state = if operator_paused {
        ExecutorState::Paused
    } else {
        ExecutorState::Running
    };
    let minutes = c.ctx.elapsed_secs(chrono::Utc::now()) / 60.0;
    let problem = format!(
        "The guide star was not re-acquired after {} attempt{} over {:.0} min{}. Imaging \
         continues unguided; every frame is still graded, so trailed frames are marked. Guiding \
         picks up again as soon as the guider is guiding.",
        c.ctx.attempt_count,
        if c.ctx.attempt_count == 1 { "" } else { "s" },
        minutes,
        c.ctx
            .last_error
            .as_deref()
            .map(|e| format!(" (last: {e})"))
            .unwrap_or_default(),
    );
    tracing::warn!("[RECOVERY] {}", problem);

    let resumed = c.run_state.store(resumed_state, |progress| {
        progress.message = Some("Guide star not re-acquired — imaging unguided".to_string());
    });
    *c.current.write() = None;

    let tracking_warning = restore_tracking_after_recovery(
        c.device_ops,
        c.mount_id,
        c.stop_tracking,
        "after the guide-star recovery",
        c.event_tx,
    )
    .await;
    if let Some(warning) = &tracking_warning {
        c.run_state.set_message(warning.clone());
    }

    let continuation = crate::executor::quality_problem_continuation(
        "Guide star recovery",
        &problem,
        serde_json::json!({
            "cause": c.ctx.cause.wire_key(),
            "attempts": c.ctx.attempt_count,
            "imaging_unguided": true,
        }),
    );
    let mut decision = continuation.decision;
    decision.sequence_run_id = c.active_run_id;
    let _ = c.decision_tx.send(decision);
    let _ = c.event_tx.send(ExecutorEvent::Warning {
        message: continuation.operator_message,
    });

    // Same ordering as a recovery that succeeded: the generation advances
    // before the node tree is released.
    c.generation.fetch_add(1, Ordering::AcqRel);
    if !operator_paused {
        c.is_paused.store(false, Ordering::Relaxed);
    }
    resumed.announce();
    let _ = c.event_tx.send(ExecutorEvent::RecoveryCompleted {
        context: Box::new(c.ctx.clone()),
    });
}

/// The give-up branch of the real driver loop. The escalation branch has its
/// own seam (`apply_recovery_escalation`, scenario 7); this one is inline, and
/// the scenario that claimed to cover it (6) called `park_and_close_safe_state`
/// directly. With the driver's policy check inverted, a default-policy give-up
/// parked the mount and every test stayed green.
#[cfg(test)]
mod tests {
    use super::*;
    use crate::device_ops::MountOps;
    use crate::executor::scenario_sim_tests::ScriptedDeviceOps;
    use crate::recovery::{RecoveryCause, RecoveryHistoryEntry, RecoveryRuntimeConfig};

    struct GiveUp {
        calls: Vec<String>,
        state: ExecutorState,
        gave_up: bool,
        is_cancelled: bool,
        history: Vec<RecoveryHistoryEntry>,
        errors: Vec<String>,
        gave_up_event_aborted: Option<bool>,
    }

    /// Run one recovery through the driver to its end. `DeviceDisconnected`
    /// with no device ids is unrecoverable on the first attempt, so the loop
    /// reaches the give-up branch without waiting out a retry interval.
    /// `abort_first` has the operator press Abort before the first attempt.
    async fn give_up_with(park_and_close: bool, abort_first: bool) -> GiveUp {
        let ops = Arc::new(ScriptedDeviceOps::new());
        // For the abort case: a camera that no reconnect revives, so every
        // attempt fails and the loop sits in its retry wait, where the
        // operator's Abort is read.
        ops.connect_succeeds.store(false, Ordering::SeqCst);
        let device_ids = if abort_first {
            vec!["cam-1".to_string()]
        } else {
            Vec::new()
        };
        let runtime = RunConfig {
            recovery: RecoveryRuntimeConfig {
                stop_tracking_during_recovery: false,
                park_and_close_when_recovery_gives_up: park_and_close,
                ..Default::default()
            },
            ..Default::default()
        };
        let (event_tx, mut event_rx) = broadcast::channel(64);
        let (decision_tx, _decision_rx) = broadcast::channel(16);
        let (request_tx, request_rx) = mpsc::channel(4);
        let signals = Arc::new(crate::recovery::RecoverySignals::new());
        let state = RunCell::starting_in(event_tx, ExecutorState::Running);
        let gave_up = Arc::new(AtomicBool::new(false));
        let is_cancelled = Arc::new(AtomicBool::new(false));
        let history = Arc::new(StdRwLock::new(Vec::new()));

        let mut run = Run::detached(ops.clone(), state.clone());
        run.control.is_cancelled = is_cancelled.clone();
        run.decisions.tx = decision_tx;
        run.config = RunConfigStore::new(runtime);
        run.recovery.signals = signals.clone();
        run.recovery.history = history.clone();
        run.recovery.reconnect_device_ids = device_ids;
        run.outside_failures.recovery_gave_up = gave_up.clone();
        run.rig = RunRig {
            mount_id: Some("mount-1".to_string()),
            dome_id: Some("dome-1".to_string()),
            cover_calibrator_id: Some("cover-1".to_string()),
            ..RunRig::default()
        };
        let shared = run.instruction_shared(request_tx.clone()).await;
        let driver = tokio::spawn(run_recovery_driver(Arc::new(run), shared, request_rx));

        if abort_first {
            // `arm()` on recovery entry clears signals left from a previous
            // loop, so the abort has to land after entry: wait for the first
            // failed attempt.
            request_tx
                .send(RecoveryCause::DeviceDisconnected)
                .await
                .unwrap();
            loop {
                match event_rx.recv().await.unwrap() {
                    ExecutorEvent::RecoveryProgress { context } if context.last_error.is_some() => {
                        break
                    }
                    _ => continue,
                }
            }
            signals.request_abort();
        } else {
            request_tx
                .send(RecoveryCause::DeviceDisconnected)
                .await
                .unwrap();
        }

        let mut errors = Vec::new();
        let mut gave_up_event_aborted = None;
        let collect = async {
            loop {
                match event_rx.recv().await {
                    Ok(ExecutorEvent::Error { message }) => errors.push(message),
                    Ok(ExecutorEvent::RecoveryGaveUp {
                        aborted_by_user, ..
                    }) => {
                        gave_up_event_aborted = Some(aborted_by_user);
                        break;
                    }
                    Ok(_) => {}
                    Err(broadcast::error::RecvError::Lagged(_)) => {}
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        };
        tokio::time::timeout(std::time::Duration::from_secs(30), collect)
            .await
            .expect("the recovery never reached its end");
        drop(request_tx);
        driver.await.unwrap();

        let final_state = state.get();
        let history = history.read().clone();
        GiveUp {
            calls: ops.calls(),
            state: final_state,
            gave_up: gave_up.load(Ordering::Relaxed),
            is_cancelled: is_cancelled.load(Ordering::Relaxed),
            history,
            errors,
            gave_up_event_aborted,
        }
    }

    fn moved_hardware(calls: &[String]) -> Vec<&String> {
        calls
            .iter()
            .filter(|c| {
                c.starts_with("mount_park")
                    || c.starts_with("cover_close")
                    || c.starts_with("dome_close")
            })
            .collect()
    }

    #[tokio::test]
    async fn by_default_a_recovery_that_gives_up_ends_the_run_without_moving_anything() {
        let r = give_up_with(false, false).await;

        assert!(
            moved_hardware(&r.calls).is_empty(),
            "the default policy must never park or close: {:?}",
            r.calls
        );
        assert_eq!(r.state, ExecutorState::Failed);
        assert!(r.gave_up, "a real give-up must be reported as one");
        assert!(r.is_cancelled, "the node tree must be stopped");
        assert_eq!(r.gave_up_event_aborted, Some(false));
        assert!(
            r.errors
                .iter()
                .any(|e| e.contains("Nothing has been parked or closed")),
            "the operator must be told the run stopped and nothing moved: {:?}",
            r.errors
        );
        assert_eq!(r.history.len(), 1);
        assert!(!r.history[0].recovered);
        assert!(!r.history[0].aborted_by_user);
    }

    #[tokio::test]
    async fn with_park_and_close_opted_in_a_give_up_parks_then_closes() {
        let r = give_up_with(true, false).await;

        assert_eq!(
            moved_hardware(&r.calls),
            [
                "mount_park:mount-1",
                "cover_close:cover-1",
                "dome_close:dome-1"
            ],
            "{:?}",
            r.calls
        );
        assert_eq!(r.state, ExecutorState::Failed);
        assert!(r.gave_up);
        assert!(
            !r.errors
                .iter()
                .any(|e| e.contains("Nothing has been parked")),
            "{:?}",
            r.errors
        );
    }

    #[tokio::test]
    async fn an_operator_abort_moves_nothing_even_with_park_and_close_on() {
        // The operator is at the controls; the opt-in is for when nobody is.
        let r = give_up_with(true, true).await;

        assert!(moved_hardware(&r.calls).is_empty(), "{:?}", r.calls);
        assert_eq!(r.gave_up_event_aborted, Some(true));
        assert!(!r.gave_up, "an operator abort is not recovery giving up");
        assert!(
            !r.errors
                .iter()
                .any(|e| e.contains("Recovery could not fix")),
            "{:?}",
            r.errors
        );
        assert_eq!(r.history.len(), 1);
        assert!(r.history[0].aborted_by_user);
    }

    struct GuideStarGiveUp {
        calls: Vec<String>,
        state: ExecutorState,
        is_paused: bool,
        is_cancelled: bool,
        gave_up: bool,
        errors: Vec<String>,
        warnings: Vec<String>,
        decisions: Vec<String>,
        trigger_state: crate::triggers::TriggerState,
        ended_as: Option<RecoveryCause>,
    }

    /// Run a guide-star-lost recovery whose one attempt fails (the guider
    /// cannot start: no star) through the driver to its end.
    async fn guide_star_give_up(
        stop_on_quality: bool,
        park_and_close: bool,
        tracking_limit: bool,
    ) -> GuideStarGiveUp {
        guide_star_recovery(stop_on_quality, park_and_close, tracking_limit, false).await
    }

    async fn guide_star_recovery(
        stop_on_quality: bool,
        park_and_close: bool,
        tracking_limit: bool,
        mount_stopped: bool,
    ) -> GuideStarGiveUp {
        let ops = Arc::new(ScriptedDeviceOps::new());
        ops.guiding.store(false, Ordering::SeqCst);
        ops.guider_start_fails.store(true, Ordering::SeqCst);
        if mount_stopped {
            ops.mount_set_tracking("mount-1", false).await.unwrap();
        }
        // A zero retry interval gives the ladder one attempt, so the budget is
        // spent as soon as that attempt fails.
        let runtime = RunConfig {
            recovery: RecoveryRuntimeConfig {
                retry_interval_secs: 0.0,
                stop_tracking_during_recovery: false,
                park_and_close_when_recovery_gives_up: park_and_close,
                ..Default::default()
            },
            ..Default::default()
        };
        let trigger_mgr = Arc::new(RwLock::new(TriggerManager::new()));
        if tracking_limit {
            ops.flip_on_slew.store(true, Ordering::Relaxed);
            ops.mount_set_tracking("mount-1", false).await.unwrap();
            let mut manager = trigger_mgr.write().await;
            manager.create_standard_triggers();
            manager.sync_state_from_config().await;
            let lock = manager.state();
            let mut state = lock.write().await;
            state.set_target(180.0, 45.0);
            state.target.current_hour_angle = Some(-0.55);
            // The driver must detect the stopped mount even before the
            // ordinary poll has consumed its falling edge.
            state.telemetry.mount_is_tracking = Some(true);
            state.set_mount_tracking_expected(true);
        }
        {
            let manager = trigger_mgr.read().await;
            let state_lock = manager.state();
            let mut state = state_lock.write().await;
            state.settings.stop_on_quality_problems = stop_on_quality;
            state.set_guiding_enabled(true);
            state.set_guide_star_lost(true);
        }
        let (event_tx, mut event_rx) = broadcast::channel(64);
        let (decision_tx, mut decision_rx) = broadcast::channel(16);
        let (request_tx, request_rx) = mpsc::channel(4);
        let state = RunCell::starting_in(event_tx, ExecutorState::Running);
        let gave_up = Arc::new(AtomicBool::new(false));
        let is_cancelled = Arc::new(AtomicBool::new(false));
        let is_paused = Arc::new(AtomicBool::new(false));

        let mut run = Run::detached(ops.clone(), state.clone());
        run.control.is_cancelled = is_cancelled.clone();
        run.control.is_paused = is_paused.clone();
        run.decisions.tx = decision_tx;
        run.config = RunConfigStore::new(runtime);
        run.outside_failures.recovery_gave_up = gave_up.clone();
        run.triggers = trigger_mgr.clone();
        run.rig = RunRig {
            mount_id: Some("mount-1".to_string()),
            dome_id: Some("dome-1".to_string()),
            cover_calibrator_id: Some("cover-1".to_string()),
            ..RunRig::default()
        };
        let shared = run.instruction_shared(request_tx.clone()).await;
        let driver = tokio::spawn(run_recovery_driver(Arc::new(run), shared, request_rx));
        request_tx.send(RecoveryCause::GuideStarLost).await.unwrap();

        let mut errors = Vec::new();
        let mut warnings = Vec::new();
        let mut ended_as = None;
        let collect = async {
            loop {
                match event_rx.recv().await {
                    Ok(ExecutorEvent::Error { message }) => errors.push(message),
                    Ok(ExecutorEvent::Warning { message }) => warnings.push(message),
                    Ok(ExecutorEvent::RecoveryGaveUp { context, .. })
                    | Ok(ExecutorEvent::RecoveryCompleted { context }) => {
                        ended_as = Some(context.cause.clone());
                        break;
                    }
                    Ok(_) => {}
                    Err(broadcast::error::RecvError::Lagged(_)) => {}
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        };
        tokio::time::timeout(std::time::Duration::from_secs(30), collect)
            .await
            .expect("the recovery never reached its end");
        drop(request_tx);
        driver.await.unwrap();

        let mut decisions = Vec::new();
        while let Ok(decision) = decision_rx.try_recv() {
            decisions.push(decision.summary);
        }
        let trigger_state = {
            let manager = trigger_mgr.read().await;
            let state_lock = manager.state();
            let state = state_lock.read().await.clone();
            state
        };
        let final_state = state.get();
        GuideStarGiveUp {
            calls: ops.calls(),
            state: final_state,
            is_paused: is_paused.load(Ordering::Relaxed),
            is_cancelled: is_cancelled.load(Ordering::Relaxed),
            gave_up: gave_up.load(Ordering::Relaxed),
            errors,
            warnings,
            decisions,
            trigger_state,
            ended_as,
        }
    }

    /// Owner decision 2026-10-06: a guide star that the ladder could not get
    /// back is not a reason to end the night. Imaging goes on unguided (the
    /// frames are still graded, so trailed ones are marked) and the operator
    /// is told once.
    #[tokio::test]
    async fn a_guide_star_never_reacquired_resumes_imaging_unguided_and_notifies() {
        let r = guide_star_give_up(false, false, false).await;

        assert_eq!(r.state, ExecutorState::Running);
        assert!(!r.is_paused, "the node tree must be released");
        assert!(!r.is_cancelled, "the run must go on");
        assert!(!r.gave_up);
        assert!(r.errors.is_empty(), "{:?}", r.errors);
        assert!(moved_hardware(&r.calls).is_empty(), "{:?}", r.calls);
        assert_eq!(
            r.decisions
                .iter()
                .filter(|s| s.as_str() == crate::executor::QUALITY_PROBLEM_CONTINUED_SUMMARY)
                .count(),
            1,
            "{:?}",
            r.decisions
        );
        assert!(
            r.warnings.iter().any(|w| w.contains("unguided")),
            "{:?}",
            r.warnings
        );
        assert!(r.trigger_state.guiding.is_unguided());
        assert!(
            !r.trigger_state.guiding.is_enabled(),
            "the star-lost trigger must be disarmed or it fires again at once"
        );
        assert!(!r.trigger_state.guiding.star_lost());
    }

    #[tokio::test]
    async fn unguided_imaging_never_parks_even_with_park_and_close_on() {
        // The run is not ending, so the give-up opt-in has nothing to act on.
        let r = guide_star_give_up(false, true, false).await;

        assert!(moved_hardware(&r.calls).is_empty(), "{:?}", r.calls);
        assert_eq!(r.state, ExecutorState::Running);
    }

    #[tokio::test]
    async fn with_stop_for_quality_problems_on_a_lost_guide_star_still_ends_the_run() {
        let r = guide_star_give_up(true, false, false).await;

        assert_eq!(r.state, ExecutorState::Failed);
        assert!(r.is_cancelled);
        assert!(r.gave_up);
        assert!(moved_hardware(&r.calls).is_empty(), "{:?}", r.calls);
        assert!(
            r.errors
                .iter()
                .any(|e| e.contains("Nothing has been parked or closed")),
            "{:?}",
            r.errors
        );
        assert!(!r.trigger_state.guiding.is_unguided());
    }

    #[tokio::test]
    async fn with_stop_for_quality_problems_on_and_park_and_close_a_lost_guide_star_parks() {
        let r = guide_star_give_up(true, true, false).await;

        assert_eq!(r.state, ExecutorState::Failed);
        assert_eq!(
            moved_hardware(&r.calls),
            [
                "mount_park:mount-1",
                "cover_close:cover-1",
                "dome_close:dome-1"
            ],
            "{:?}",
            r.calls
        );
    }
    #[tokio::test(start_paused = true)]
    async fn tracking_limit_recovery_takes_over_an_active_guide_retry() {
        let r = guide_star_give_up(false, false, true).await;
        assert_eq!(r.state, ExecutorState::Running);
        assert!(r.is_paused, "exposures must stay held until the flip");
        assert!(!r.is_cancelled);
        assert!(!r.gave_up);
        assert_eq!(
            r.trigger_state.run.hold(),
            Some(crate::triggers::RunHold::TrackingLimit)
        );
        assert!(r.errors.is_empty(), "{:?}", r.errors);
        assert!(
            !r.calls
                .iter()
                .any(|c| c == "guider_start" || c == "mount_set_tracking:mount-1:true"),
            "{:?}",
            r.calls
        );
    }

    /// On 2026-10-22/23 a guide-star recovery ran 133 attempts against a
    /// mount that had stopped tracking. A stopped mount is handed to the
    /// tracking-loss recovery, which restores tracking, and no guide-star
    /// attempt is spent on it.
    #[tokio::test]
    async fn a_guide_star_recovery_on_a_stopped_mount_hands_over_to_tracking() {
        let r = guide_star_recovery(false, false, false, true).await;
        assert_eq!(r.ended_as, Some(RecoveryCause::MountTrackingLost));
        assert!(
            !r.calls
                .iter()
                .any(|c| c == "guider_start" || c == "guider_select_fresh_star"),
            "{:?}",
            r.calls
        );
        assert!(
            r.calls
                .iter()
                .any(|c| c == "mount_set_tracking:mount-1:true"),
            "{:?}",
            r.calls
        );
        assert!(
            r.warnings.iter().any(|w| w.contains("not tracking")),
            "the operator is told: {:?}",
            r.warnings
        );
        assert!(r.errors.is_empty(), "{:?}", r.errors);
    }
}
