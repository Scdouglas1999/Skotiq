//! `MeridianFlip`: re-check that the flip is still due, run it, and act on a
//! failure as the operator configured.

use super::*;

/// What a trigger-fired flip needs.
pub(in super::super) struct FlipRequest<'a> {
    pub config: &'a crate::MeridianFlipConfig,
    pub rig: &'a Rig,
    pub run: &'a RunControl,
    pub failure: &'a FlipFailureLatch,
    pub park: &'a mut ParkSignals,
    pub camera_claim: &'a mut TriggerCameraClaim,
}

pub(in super::super) async fn run(request: FlipRequest<'_>) -> ActionFlow {
    let FlipRequest {
        config,
        rig,
        run,
        failure,
        park,
        camera_claim,
    } = request;
    // The imaging-train claim may have waited through an operator pause.
    // Only the running monitor may advance an automatic tracking-limit hold.
    if rig.trigger_state.read().await.run.hold() == Some(crate::triggers::RunHold::TrackingLimit)
        && (run.state.get() != ExecutorState::Running || run.is_cancelled())
    {
        camera_claim.release().await;
        return ActionFlow::NotRun;
    }
    // An operator's request is consumed whatever happens next: it asked for
    // this flip, not for every later one.
    let requested = rig.trigger_state.write().await.meridian.take_request();
    let Some(early) = still_due(config, requested, rig).await else {
        camera_claim.release().await;
        return ActionFlow::NotRun;
    };
    tracing::info!(
        "[MERIDIAN] Trigger fired - executing meridian flip{}",
        if requested {
            " (requested by the operator)"
        } else {
            ""
        }
    );

    let autofocus_config = Some(
        rig.runtime_config
            .read()
            .autofocus
            .clone()
            .unwrap_or_default(),
    );
    let flip_instruction = rig.instruction_context(rig.target().await, run);
    // A display label only; the flip context needs the coordinates.
    let target_name = flip_instruction
        .target_name
        .clone()
        .unwrap_or_else(|| "Unknown".to_string());
    let Some(flip_ctx) = crate::meridian_flip_executor::FlipContext::for_instruction(
        &flip_instruction,
        autofocus_config,
    )
    .await
    else {
        // A flip that fires and cannot run leaves the mount past the meridian
        // unflipped: a safety event the run records.
        let message = format!(
            "Meridian flip trigger fired for '{}' but the flip \
             could not be executed: mount not connected or \
             target coordinates not set. The mount is past the \
             meridian and was NOT flipped.",
            target_name
        );
        tracing::error!("[MERIDIAN] {}", message);
        failure.latch(|| message.clone());
        run.error(message);
        camera_claim.release().await;
        return ActionFlow::Finished;
    };

    let run_state = run.state.clone();
    let mut flip_executor = crate::meridian_flip_executor::MeridianFlipExecutor::in_run(
        config.clone(),
        rig.shared.clone(),
    )
    .with_run_message(Arc::new(move |message| {
        run_state.set_message(message);
    }))
    .with_early_tracking_limit_flip(early);
    let flip_result = flip_executor.execute(&flip_ctx).await;
    // Keep capture held until failure handling has paused or stopped the run.
    // A flip that succeeded only on a retry is degraded, and the operator is
    // told how many attempts it took.
    let flip_attempts = flip_executor.attempts_made();
    match flip_result {
        crate::meridian_flip_executor::FlipResult::Success {
            new_pier_side,
            duration_secs,
        } => {
            tracing::info!(
                "[MERIDIAN] Flip completed successfully: new pier side {:?}, took {:.1}s",
                new_pier_side,
                duration_secs
            );
            rig.trigger_state.write().await.mark_flip_performed();
            failure.clear();
            ActionFlow::Finished
        }
        crate::meridian_flip_executor::FlipResult::Failed {
            error,
            action_taken,
        } => {
            tracing::error!(
                "[MERIDIAN] Flip failed: {} (action: {:?})",
                error,
                action_taken
            );
            // The executor records the flip once the new pier side is
            // verified, so a later failure is acquisition recovery failing.
            let flipped = rig.trigger_state.read().await.meridian.has_flipped();
            if flipped {
                // The mount is where the run expects it. The pause below
                // tells the operator; the run's verdict is no longer the
                // flip's.
                failure.clear();
            } else {
                failure.latch(|| {
                    format!(
                        "Meridian flip for '{}' failed after {} attempt{}: {}",
                        target_name,
                        flip_attempts,
                        plural(flip_attempts),
                        error
                    )
                });
            }
            match action_taken {
                crate::FlipFailureAction::PauseAndAlert => {
                    // No separate Error event: the Critical MeridianFlipOutcome
                    // is the verdict, and both would record it twice.
                    let message = if flipped {
                        format!(
                            "The meridian flip for '{}' moved the mount to the new pier side, \
                             but imaging recovery failed: {}. Sequence paused under the configured \
                             flip failure action; the mount must not flip again.",
                            target_name,
                            without_final_period(&error)
                        )
                    } else {
                        format!(
                            "Meridian flip for '{}' FAILED after {} attempt{}: {}. Sequence \
                             paused; the mount did not reach the other side of the pier. \
                             Verify framing before resuming.",
                            target_name,
                            flip_attempts,
                            plural(flip_attempts),
                            without_final_period(&error)
                        )
                    };
                    run.pause(Some(message));
                    ActionFlow::Finished
                }
                crate::FlipFailureAction::AbortAndPark => {
                    abort_and_park(rig, run, park).await;
                    ActionFlow::Terminate {
                        recorded: RecoveryAction::ParkAndAbort,
                        reason: "FlipFailureAction::AbortAndPark",
                    }
                }
            }
        }
        crate::meridian_flip_executor::FlipResult::Aborted { reason } => {
            tracing::warn!("[MERIDIAN] Flip aborted: {}", reason);
            if early && !run.is_cancelled() {
                // The mount would not take the east side this early. Wait for
                // the configured window instead; tracking stays off.
                //
                // Nothing here forces the other side or restarts tracking.
                // A GoTo leaves the side to the driver, which picks it from
                // the hour angle and its own limits, so a slew to the same
                // target, or to an hour angle past the meridian and back,
                // lands on the side it refused. ASCOM's SideOfPier setter
                // (CanSetPierSide) forces a flip only on drivers that offer it,
                // and inside the same limits. The limit that stopped tracking
                // is the mount's protection of the tube against the pier or
                // tripod, so restarting tracking past it to keep imaging would
                // drive the tube toward what the limit guards. The flip window
                // is the earliest point the mount itself accepts.
                let wait = {
                    let mut state = rig.trigger_state.write().await;
                    state.run.refuse_early_flip();
                    state.target.current_hour_angle.map(|ha| {
                        (crate::triggers::tracking_limit_flip_threshold(config) - ha).max(0.0)
                            * 60.0
                    })
                };
                let message = format!(
                    "The mount did not flip early ({reason}). It stopped tracking at its own \
                     limit and only takes the east side past the meridian, so tracking stays \
                     off and nothing is exposed until the flip window, {:.0} min past the \
                     meridian{}.",
                    crate::triggers::tracking_limit_flip_threshold(config) * 60.0,
                    match wait {
                        Some(minutes) => format!(", about {minutes:.0} min away"),
                        None => String::new(),
                    }
                );
                tracing::warn!("[MERIDIAN] {}", message);
                run.warning(message);
            } else if !run.is_cancelled() {
                // The pre-frame gate stops holding frames for this flip; the
                // trigger tries again when its cooldown ends.
                rig.trigger_state
                    .write()
                    .await
                    .meridian
                    .mark_refused(reason);
            }
            ActionFlow::Finished
        }
    }
}

/// Whether the flip is still due now that its turn has come, and if so
/// whether it is an early tracking-limit flip. It waited for the imaging
/// train, and a target change in the meantime can put the mount on the
/// post-flip side, so the pier side is read again. An operator's request
/// waives the window threshold but not the pre-flip side.
async fn still_due(config: &crate::MeridianFlipConfig, requested: bool, rig: &Rig) -> Option<bool> {
    let Some(mount_id) = rig.devices().mount_id.as_deref() else {
        return Some(false);
    };
    let fresh_pier = bounded_poll(
        "mount_side_of_pier",
        rig.device_ops().mount_side_of_pier(mount_id),
    )
    .await
    .ok()
    .map(super::super::polling::wire_pier_side);
    let hour_angle = {
        let mut ts = rig.trigger_state.write().await;
        if let Some(pier) = fresh_pier {
            ts.update_pier_side(pier);
        }
        ts.target.current_hour_angle
    };
    let pier_now = fresh_pier.or(rig.trigger_state.read().await.telemetry.pier_side);
    let (tracking_limit_hold, early_refused) = {
        let state = rig.trigger_state.read().await;
        (
            state.run.hold() == Some(crate::triggers::RunHold::TrackingLimit),
            state.run.early_flip_refused(),
        )
    };
    let due = if tracking_limit_hold {
        hour_angle.is_some_and(|ha| {
            crate::triggers::tracking_limit_flip_due(config, ha, pier_now, early_refused)
        })
    } else if requested {
        hour_angle.is_some_and(|ha| crate::triggers::on_pre_flip_side(ha, pier_now))
    } else {
        crate::triggers::flip_still_due(config, hour_angle, pier_now)
    };
    if !due {
        tracing::info!(
            "[MERIDIAN] Flip no longer due when its turn came (hour angle {:?}h, \
             pier side {:?}); the mount is already on the post-flip side",
            hour_angle,
            pier_now
        );
        return None;
    }
    Some(
        tracking_limit_hold
            && hour_angle.is_some_and(|ha| {
                crate::triggers::tracking_limit_flip_is_early(config, ha, pier_now)
            }),
    )
}

/// The flip failed and the operator chose to abort: the mount may be anywhere
/// between sides, so the node tree is stopped, guiding stopped and the mount
/// parked before the run ends.
pub(in super::super) async fn abort_and_park(rig: &Rig, run: &RunControl, park: &mut ParkSignals) {
    park.parking_begins();
    park.stop_node_tree(&run.is_cancelled).await;
    rig.device_ops()
        .guider_note_stop_reason(Some(crate::GuidingStopReason::RunStopped))
        .await;
    if let Err(error) = rig.device_ops().guider_stop().await {
        let msg = format!(
            "FlipFailure AbortAndPark: failed to stop \
             guiding before parking: {}",
            error
        );
        tracing::error!("{}", msg);
        run.error(msg);
    }
    if let Some(mount_id) = &rig.devices().mount_id {
        tracing::warn!(
            "FlipFailure AbortAndPark: parking mount '{}' (max_retries=1, retry_delay=2s)",
            mount_id
        );
        let park_outcome =
            crate::device_ops::try_park_with_retry(&**rig.device_ops(), mount_id, 1, 2.0).await;
        if !park_outcome.success {
            run.error(format!(
                "FlipFailure AbortAndPark: mount park FAILED after {} attempt{}: {}. \
                 Mount may be in an unsafe position — manual intervention required.",
                park_outcome.attempts_made,
                plural(park_outcome.attempts_made),
                park_outcome
                    .last_error
                    .unwrap_or_else(|| "unknown error".to_string()),
            ));
        }
    }
    park.parked();
}

fn plural(count: u32) -> &'static str {
    if count == 1 {
        ""
    } else {
        "s"
    }
}

/// `error` ready to be followed by ". Sequence paused": the executor's errors
/// often end in a period of their own, and the pause message read
/// "...may not have flipped correctly.. Sequence paused".
fn without_final_period(error: &str) -> &str {
    let trimmed = error.trim_end();
    trimmed.strip_suffix('.').unwrap_or(trimmed)
}

#[cfg(test)]
mod message_tests {
    use super::without_final_period;

    #[test]
    fn a_flip_error_ending_in_a_period_does_not_double_it() {
        let error = "Verifying pier side: Pier side did not change after flip (still West). \
                     The mount may not have flipped correctly.";
        let message = format!("{}. Sequence paused", without_final_period(error));
        assert!(
            message.ends_with("flipped correctly. Sequence paused"),
            "{message}"
        );
        assert_eq!(without_final_period("no solution"), "no solution");
    }
}
