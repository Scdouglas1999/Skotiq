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
    pub recovery_driver_trigger_context: TriggerActionContext,
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
        recovery_driver_trigger_context,
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

        // Requests already queued before the tracking-limit hold was adopted
        // must not steal the mount back from its flip controller.
        if matches!(
            cause,
            crate::recovery::RecoveryCause::GuideStarLost
                | crate::recovery::RecoveryCause::MountTrackingLost
        ) && recovery_driver_trigger_mgr
            .read()
            .await
            .state()
            .read()
            .await
            .run
            .hold()
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
            let rc = recovery_driver_runtime.read();
            (
                rc.recovery.retry_interval_secs,
                rc.recovery.max_duration_secs,
                rc.recovery.stop_tracking_during_recovery,
            )
        };

        // A weather hold is not a repair with a budget: it checks the sky
        // often, never runs out, and never stops tracking. Weather alone must
        // not end the run, and a held mount that keeps tracking can image
        // again the moment the sky clears.
        let weather_hold = cause == crate::recovery::RecoveryCause::WeatherUnsafe;
        // A lost guide star is most often cloud too: the mount keeps tracking
        // so it is still on the target when the stars return, and the star is
        // looked for often enough that the run resumes soon after they do.
        let guide_star_hold = cause == crate::recovery::RecoveryCause::GuideStarLost;
        let (interval_secs, max_duration_secs, stop_tracking) = if weather_hold {
            (
                WEATHER_HOLD_CHECK_SECS,
                WEATHER_HOLD_NOMINAL_SPAN_SECS,
                false,
            )
        } else if guide_star_hold {
            (
                interval_secs.min(GUIDE_STAR_RECHECK_SECS),
                max_duration_secs,
                false,
            )
        } else {
            (interval_secs, max_duration_secs, stop_tracking)
        };
        let mut weather_safe_since: Option<std::time::Instant> = None;
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

        // 3. Optionally stop tracking, but never under a moving mount. On the
        // rig (2026-10-07) a guide-star loss caused by the run's own slew
        // stopped tracking 40 ms into that slew, and the Center after it
        // solved trailed frames.
        // Everything after this reads `stop_tracking` as "tracking was
        // stopped", so a moving mount clears it.
        let stop_tracking = stop_tracking
            && match &recovery_driver_mount_id {
                Some(mount_id) => {
                    let run_is_moving_mount = {
                        let manager = recovery_driver_trigger_mgr.read().await;
                        let depth = manager.state().read().await.guiding.motion_depth();
                        depth > 0
                    };
                    let moving = run_is_moving_mount
                        || matches!(
                            tokio::time::timeout(
                                std::time::Duration::from_secs(5),
                                recovery_driver_device_ops.mount_is_slewing(mount_id),
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
            if let Some(mount_id) = &recovery_driver_mount_id {
                tracing::info!(
                    "[RECOVERY] Stopping mount tracking on '{}' for the recovery loop",
                    mount_id
                );
                // The run's own stop is not a lost-tracking event.
                {
                    let manager = recovery_driver_trigger_mgr.read().await;
                    manager
                        .state()
                        .write()
                        .await
                        .run
                        .begin_hold(crate::triggers::RunHold::RecoveryTracking);
                }
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
        let mut handed_to_flip = false;
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
            if guide_star_hold
                && hand_off_tracking_limit(
                    &recovery_driver_device_ops,
                    recovery_driver_mount_id.as_deref(),
                    &recovery_driver_trigger_mgr,
                )
                .await
            {
                handed_to_flip = true;
                aborted_by_user = false;
                recovered = false;
                ctx.phase = crate::recovery::RecoveryPhase::Waiting;
                ctx.last_error =
                    Some("Guiding recovery handed to tracking-limit flip controller".into());
                break;
            }
            if !weather_hold && ctx.is_exhausted(chrono::Utc::now()) {
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

            let outcome = if weather_hold {
                let resume_after = recovery_driver_runtime
                    .read()
                    .weather_resume_after_safe_secs
                    .unwrap_or(DEFAULT_WEATHER_RESUME_AFTER_SAFE_SECS);
                weather_hold_attempt(
                    &recovery_driver_device_ops,
                    &recovery_driver_trigger_mgr,
                    &mut weather_safe_since,
                    resume_after,
                )
                .await
            } else {
                run_recovery_attempt(
                    &ctx.cause,
                    &recovery_driver_device_ops,
                    recovery_driver_mount_id.as_deref(),
                    &recovery_driver_device_ids,
                    &recovery_driver_trigger_mgr,
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

        // A handoff is still in progress, not a recovered or failed attempt.
        let ended_at = chrono::Utc::now();
        if !handed_to_flip {
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

        if handed_to_flip {
            // End this retry ladder without claiming recovery or releasing
            // exposures. The monitor owns the newly latched hold and keeps
            // polling safety while it waits for the configured flip window.
            *recovery_driver_current.write() = None;
            let message = "Mount tracking stopped near the meridian; guiding recovery is yielding to the flip controller.";
            let mut state = recovery_driver_state.write().await;
            if *state == ExecutorState::Recovering
                && !recovery_driver_is_cancelled.load(Ordering::Relaxed)
            {
                *state = ExecutorState::Running;
                let mut progress = recovery_driver_progress.write();
                progress.state = ExecutorState::Running;
                progress.message = Some(message.into());
                let _ = recovery_driver_event_tx
                    .send(ExecutorEvent::StateChanged(ExecutorState::Running));
            }
            tracing::warn!("[RECOVERY] {}", message);
            let _ = recovery_driver_event_tx.send(ExecutorEvent::Warning {
                message: message.into(),
            });
            let _ = recovery_driver_event_tx.send(ExecutorEvent::RecoveryCompleted {
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
            // An operator Pause during the ladder is the only thing that
            // turns `Recovering` into `Paused` while it runs. That hold is his,
            // so a successful ladder leaves it in place rather than resuming
            // the run under him.
            let operator_paused = *recovery_driver_state.read().await == ExecutorState::Paused;
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
            if weather_hold && !operator_paused {
                prepare_imaging_after_weather_hold(WeatherHoldExit {
                    held_secs: ctx.elapsed_secs(chrono::Utc::now()),
                    device_ops: &recovery_driver_device_ops,
                    trigger_mgr: &recovery_driver_trigger_mgr,
                    trigger_context: &recovery_driver_trigger_context,
                    runtime: &recovery_driver_runtime,
                    is_cancelled: &recovery_driver_is_cancelled,
                    event_tx: &recovery_driver_event_tx,
                })
                .await;
            }
            *recovery_driver_state.write().await = resumed_state;
            {
                let mut prog = recovery_driver_progress.write();
                prog.state = resumed_state;
                prog.message = Some(if operator_paused {
                    "Recovered — paused, as you left it".to_string()
                } else {
                    "Recovered — resuming sequence".to_string()
                });
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
            if !operator_paused {
                recovery_driver_is_paused.store(false, Ordering::Relaxed);
            }
            let _ = recovery_driver_event_tx.send(ExecutorEvent::StateChanged(resumed_state));
            let _ = recovery_driver_event_tx.send(ExecutorEvent::RecoveryCompleted {
                context: Box::new(ctx.clone()),
            });
        } else if !aborted_by_user
            && ctx.cause == crate::recovery::RecoveryCause::GuideStarLost
            && !stops_on_quality_problems(&recovery_driver_trigger_mgr).await
        {
            // The guide star did not come back within the budget. That costs
            // trailed frames, which grading marks, not the hardware, so the run
            // goes on unguided rather than ending the night (owner decision
            // 2026-10-06). "Stop the run for quality problems" brings back the
            // old ending below. Nothing is parked: the run is not ending.
            let active_run_id = *recovery_driver_active_run_id.read();
            continue_unguided(UnguidedContinuation {
                ctx: &ctx,
                active_run_id,
                decision_tx: &recovery_driver_decision_tx,
                device_ops: &recovery_driver_device_ops,
                event_tx: &recovery_driver_event_tx,
                generation: &recovery_driver_generation,
                is_paused: &recovery_driver_is_paused,
                mount_id: recovery_driver_mount_id.as_deref(),
                progress: &recovery_driver_progress,
                current: &recovery_driver_current,
                state: &recovery_driver_state,
                stop_tracking,
                trigger_mgr: &recovery_driver_trigger_mgr,
            })
            .await;
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
                // The ladder switched tracking off before its first attempt
                // (`stop_tracking_during_recovery`) and nothing restores it for
                // a run that has ended. Say so: "nothing has been moved" read
                // as "the mount is as you left it", and it was not.
                let tracking_note = if stop_tracking && recovery_driver_mount_id.is_some() {
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
                let _ = recovery_driver_event_tx.send(ExecutorEvent::Error {
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

        // Tracking is restored (or the run has ended); from here a tracking
        // change is the mount's own again.
        if stop_tracking && recovery_driver_mount_id.is_some() {
            let manager = recovery_driver_trigger_mgr.read().await;
            manager.state().write().await.run.end_hold();
        }
    }
}

/// What [`prepare_imaging_after_weather_hold`] needs.
struct WeatherHoldExit<'a> {
    held_secs: f64,
    device_ops: &'a SharedDeviceOps,
    trigger_mgr: &'a Arc<RwLock<TriggerManager>>,
    trigger_context: &'a TriggerActionContext,
    runtime: &'a Arc<StdRwLock<RuntimeConfig>>,
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
            ts.current_target_name.clone(),
            ts.target_ra.map(|ra| ra / 15.0),
            ts.target_dec,
            ts.current_filter.clone(),
        )
    };
    let recenter = exit.held_secs >= WEATHER_HOLD_RECENTER_AFTER_SECS
        && target_ra_hours.is_some()
        && target_dec.is_some()
        && exit.trigger_context.mount_id.is_some()
        && exit.trigger_context.camera_id.is_some();
    if recenter {
        tracing::info!(
            "[WEATHER] Held for {:.0} min; recentering on the target before imaging again",
            exit.held_secs / 60.0
        );
        let mut claim =
            TriggerCameraClaim::acquire(&state, exit.is_cancelled, &RecoveryAction::Recenter).await;
        let ctx = build_trigger_autofocus_context(
            exit.trigger_context,
            target_name,
            target_ra_hours,
            target_dec,
            current_filter,
            exit.is_cancelled.clone(),
            exit.device_ops.clone(),
            state.clone(),
            exit.runtime,
            Some(exit.event_tx.clone()),
        );
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
        exit.device_ops.guider_get_status().await,
        Ok(status) if guiding_is_settled(&status)
    );
    if settled {
        return;
    }
    tracing::info!(
        "[WEATHER] Guiding is not holding a star after the weather hold; it starts again on a \
         fresh star before the next light frame"
    );
    crate::instructions::stop_an_active_guider(exit.device_ops, "restart after the weather hold")
        .await;
    let mut ts = state.write().await;
    ts.set_guiding_enabled(false);
    ts.set_guide_star_lost(false);
    ts.guiding.set_resume_pending(true);
}

async fn stops_on_quality_problems(trigger_mgr: &Arc<RwLock<TriggerManager>>) -> bool {
    let manager = trigger_mgr.read().await;
    let state = manager.state();
    let stop = state.read().await.stop_on_quality_problems;
    stop
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
    progress: &'a StdRwLock<SequenceProgress>,
    current: &'a StdRwLock<Option<crate::recovery::RecoveryContext>>,
    state: &'a RwLock<ExecutorState>,
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
        if let Some(history) = state.guiding_rms_history.as_mut() {
            history.clear();
        }
    }

    let operator_paused = *c.state.read().await == ExecutorState::Paused;
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

    *c.state.write().await = resumed_state;
    {
        let mut prog = c.progress.write();
        prog.state = resumed_state;
        prog.message = Some("Guide star not re-acquired — imaging unguided".to_string());
    }
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
        c.progress.write().message = Some(warning.clone());
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
    let _ = c.event_tx.send(ExecutorEvent::StateChanged(resumed_state));
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
        let runtime = RuntimeConfig {
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
        let state = Arc::new(RwLock::new(ExecutorState::Running));
        let gave_up = Arc::new(AtomicBool::new(false));
        let is_cancelled = Arc::new(AtomicBool::new(false));
        let history = Arc::new(StdRwLock::new(Vec::new()));

        let driver = tokio::spawn(run_recovery_driver(RecoveryDriverArgs {
            recovery_driver_active_run_id: Arc::new(StdRwLock::new(None)),
            recovery_driver_cover_id: Some("cover-1".to_string()),
            recovery_driver_current: Arc::new(StdRwLock::new(None)),
            recovery_driver_decision_tx: decision_tx,
            recovery_driver_device_ids: device_ids,
            recovery_driver_device_ops: ops.clone(),
            recovery_driver_dome_id: Some("dome-1".to_string()),
            recovery_driver_event_tx: event_tx,
            recovery_driver_gave_up: gave_up.clone(),
            recovery_driver_generation: Arc::new(std::sync::atomic::AtomicU64::new(0)),
            recovery_driver_history: history.clone(),
            recovery_driver_is_cancelled: is_cancelled.clone(),
            recovery_driver_is_paused: Arc::new(AtomicBool::new(false)),
            recovery_driver_mount_id: Some("mount-1".to_string()),
            recovery_driver_progress: Arc::new(StdRwLock::new(SequenceProgress::default())),
            recovery_driver_runtime: Arc::new(StdRwLock::new(runtime)),
            recovery_driver_signals: signals.clone(),
            recovery_driver_state: state.clone(),
            recovery_driver_trigger_mgr: Arc::new(RwLock::new(TriggerManager::new())),
            recovery_driver_trigger_context: TriggerActionContext::default(),
            recovery_request_rx: request_rx,
        }));

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

        let final_state = *state.read().await;
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
    }

    /// Run a guide-star-lost recovery whose one attempt fails (the guider
    /// cannot start: no star) through the driver to its end.
    async fn guide_star_give_up(
        stop_on_quality: bool,
        park_and_close: bool,
        tracking_limit: bool,
    ) -> GuideStarGiveUp {
        let ops = Arc::new(ScriptedDeviceOps::new());
        ops.guiding.store(false, Ordering::SeqCst);
        ops.guider_start_fails.store(true, Ordering::SeqCst);
        // A zero retry interval gives the ladder one attempt, so the budget is
        // spent as soon as that attempt fails.
        let runtime = RuntimeConfig {
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
            use crate::device_ops::DeviceOps;
            ops.flip_on_slew.store(true, Ordering::Relaxed);
            ops.mount_set_tracking("mount-1", false).await.unwrap();
            let mut manager = trigger_mgr.write().await;
            manager.create_standard_triggers();
            manager.sync_state_from_config().await;
            let lock = manager.state();
            let mut state = lock.write().await;
            state.set_target(180.0, 45.0);
            state.current_hour_angle = Some(-0.55);
            // The driver must detect the stopped mount even before the
            // ordinary poll has consumed its falling edge.
            state.mount_is_tracking = Some(true);
            state.set_mount_tracking_expected(true);
        }
        {
            let manager = trigger_mgr.read().await;
            let state_lock = manager.state();
            let mut state = state_lock.write().await;
            state.stop_on_quality_problems = stop_on_quality;
            state.set_guiding_enabled(true);
            state.set_guide_star_lost(true);
        }
        let (event_tx, mut event_rx) = broadcast::channel(64);
        let (decision_tx, mut decision_rx) = broadcast::channel(16);
        let (request_tx, request_rx) = mpsc::channel(4);
        let state = Arc::new(RwLock::new(ExecutorState::Running));
        let gave_up = Arc::new(AtomicBool::new(false));
        let is_cancelled = Arc::new(AtomicBool::new(false));
        let is_paused = Arc::new(AtomicBool::new(false));

        let driver = tokio::spawn(run_recovery_driver(RecoveryDriverArgs {
            recovery_driver_active_run_id: Arc::new(StdRwLock::new(None)),
            recovery_driver_cover_id: Some("cover-1".to_string()),
            recovery_driver_current: Arc::new(StdRwLock::new(None)),
            recovery_driver_decision_tx: decision_tx,
            recovery_driver_device_ids: Vec::new(),
            recovery_driver_device_ops: ops.clone(),
            recovery_driver_dome_id: Some("dome-1".to_string()),
            recovery_driver_event_tx: event_tx,
            recovery_driver_gave_up: gave_up.clone(),
            recovery_driver_generation: Arc::new(std::sync::atomic::AtomicU64::new(0)),
            recovery_driver_history: Arc::new(StdRwLock::new(Vec::new())),
            recovery_driver_is_cancelled: is_cancelled.clone(),
            recovery_driver_is_paused: is_paused.clone(),
            recovery_driver_mount_id: Some("mount-1".to_string()),
            recovery_driver_progress: Arc::new(StdRwLock::new(SequenceProgress::default())),
            recovery_driver_runtime: Arc::new(StdRwLock::new(runtime)),
            recovery_driver_signals: Arc::new(crate::recovery::RecoverySignals::new()),
            recovery_driver_state: state.clone(),
            recovery_driver_trigger_mgr: trigger_mgr.clone(),
            recovery_driver_trigger_context: TriggerActionContext::default(),
            recovery_request_rx: request_rx,
        }));
        request_tx.send(RecoveryCause::GuideStarLost).await.unwrap();

        let mut errors = Vec::new();
        let mut warnings = Vec::new();
        let collect = async {
            loop {
                match event_rx.recv().await {
                    Ok(ExecutorEvent::Error { message }) => errors.push(message),
                    Ok(ExecutorEvent::Warning { message }) => warnings.push(message),
                    Ok(ExecutorEvent::RecoveryGaveUp { .. })
                    | Ok(ExecutorEvent::RecoveryCompleted { .. }) => break,
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
        let final_state = *state.read().await;
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
}
