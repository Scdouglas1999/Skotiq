//! `MeridianFlip`: re-check that the flip is still due, run it, and act on a
//! failure as the operator configured.

use super::*;

/// Where a failed flip is latched so the run's verdict cannot read
/// `completed`.
pub(in super::super) struct FlipFailureLatch {
    pub failed: Arc<AtomicBool>,
    pub failure: Arc<StdRwLock<Option<String>>>,
}

impl FlipFailureLatch {
    /// Latch the first failure; a later one keeps the first message.
    fn latch(&self, message: impl FnOnce() -> String) {
        self.failed.store(true, Ordering::Release);
        self.failure.write().get_or_insert_with(message);
    }
}

/// What a trigger-fired flip needs.
pub(in super::super) struct FlipRequest<'a> {
    pub config: &'a crate::MeridianFlipConfig,
    pub rig: &'a Rig,
    pub run: &'a RunControl,
    pub decisions: &'a DecisionLog,
    pub failure: &'a FlipFailureLatch,
    pub park: &'a mut ParkSignals,
    pub camera_claim: &'a mut TriggerCameraClaim,
}

pub(in super::super) async fn run(request: FlipRequest<'_>) -> ActionFlow {
    let FlipRequest {
        config,
        rig,
        run,
        decisions,
        failure,
        park,
        camera_claim,
    } = request;
    // The imaging-train claim may have waited through an operator pause.
    // Only the running monitor may advance an automatic tracking-limit hold.
    if rig.trigger_state.read().await.run.hold() == Some(crate::triggers::RunHold::TrackingLimit)
        && (*run.executor_state.read().await != ExecutorState::Running || run.is_cancelled())
    {
        camera_claim.release().await;
        return ActionFlow::NotRun;
    }
    // An operator's request is consumed whatever happens next: it asked for
    // this flip, not for every later one.
    let requested = rig.trigger_state.write().await.meridian.take_request();
    if !still_due(config, requested, rig).await {
        camera_claim.release().await;
        return ActionFlow::NotRun;
    }
    tracing::info!(
        "[MERIDIAN] Trigger fired - executing meridian flip{}",
        if requested {
            " (requested by the operator)"
        } else {
            ""
        }
    );

    let target = rig.target().await;
    // A display label only; the flip context needs the coordinates.
    let target_name = target.name.unwrap_or_else(|| "Unknown".to_string());
    let autofocus_config = rig.runtime_config.read().autofocus.clone();
    let Some(flip_ctx) = build_trigger_flip_context(
        &rig.context,
        TriggerFlipTarget {
            name: target_name.clone(),
            ra_hours: target.ra_hours,
            dec_degrees: target.dec_degrees,
        },
        Some(run.is_cancelled.clone()),
        Some(rig.trigger_state.clone()),
        autofocus_config,
        target.filter,
    ) else {
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

    let mut flip_executor = crate::meridian_flip_executor::MeridianFlipExecutor::new(
        config.clone(),
        rig.device_ops.clone(),
    )
    // The executor emits the MeridianFlipOutcome verdict itself.
    .with_executor_event_tx(run.events.clone())
    .with_decision_tx(decisions.tx.clone(), decisions.run_id.clone());
    let flip_result = flip_executor.execute(&flip_ctx).await;
    camera_claim.release().await;
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
            failure.latch(|| {
                format!(
                    "Meridian flip for '{}' failed after {} attempt{}: {}",
                    target_name,
                    flip_attempts,
                    plural(flip_attempts),
                    error
                )
            });
            match action_taken {
                crate::FlipFailureAction::PauseAndAlert => {
                    // No separate Error event: the Critical MeridianFlipOutcome
                    // is the verdict, and both would record it twice.
                    run.pause(Some(format!(
                        "Meridian flip for '{}' FAILED after {} \
                         attempt{}: {}. Sequence paused — the \
                         mount may be on the wrong side of the \
                         pier; verify framing before resuming.",
                        target_name,
                        flip_attempts,
                        plural(flip_attempts),
                        error
                    )))
                    .await;
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
            ActionFlow::Finished
        }
    }
}

/// Whether the flip is still due now that its turn has come. It waited for
/// the imaging train, and a target change in the meantime can put the mount
/// on the post-flip side, so the pier side is read again. An operator's
/// request waives the window threshold but not the pre-flip side.
async fn still_due(config: &crate::MeridianFlipConfig, requested: bool, rig: &Rig) -> bool {
    let Some(mount_id) = rig.context.mount_id.as_deref() else {
        return true;
    };
    let fresh_pier = bounded_poll(
        "mount_side_of_pier",
        rig.device_ops.mount_side_of_pier(mount_id),
    )
    .await
    .ok()
    .map(super::super::polling::wire_pier_side);
    let hour_angle = {
        let mut ts = rig.trigger_state.write().await;
        if let Some(pier) = fresh_pier {
            ts.update_pier_side(pier);
        }
        ts.current_hour_angle
    };
    let pier_now = fresh_pier.or(rig.trigger_state.read().await.pier_side);
    let tracking_limit_hold =
        rig.trigger_state.read().await.run.hold() == Some(crate::triggers::RunHold::TrackingLimit);
    let due = if tracking_limit_hold {
        hour_angle.is_some_and(|ha| {
            crate::triggers::flip_window_open(
                ha,
                pier_now,
                crate::triggers::tracking_limit_flip_threshold(config),
            )
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
    }
    due
}

/// The flip failed and the operator chose to abort: the mount may be anywhere
/// between sides, so the node tree is stopped, guiding stopped and the mount
/// parked before the run ends.
async fn abort_and_park(rig: &Rig, run: &RunControl, park: &mut ParkSignals) {
    park.parking_begins();
    park.stop_node_tree(&run.is_cancelled).await;
    if let Err(error) = rig.device_ops.guider_stop().await {
        let msg = format!(
            "FlipFailure AbortAndPark: failed to stop \
             guiding before parking: {}",
            error
        );
        tracing::error!("{}", msg);
        run.error(msg);
    }
    if let Some(mount_id) = &rig.context.mount_id {
        tracing::warn!(
            "FlipFailure AbortAndPark: parking mount '{}' (max_retries=1, retry_delay=2s)",
            mount_id
        );
        let park_outcome =
            crate::device_ops::try_park_with_retry(&rig.device_ops, mount_id, 1, 2.0).await;
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
