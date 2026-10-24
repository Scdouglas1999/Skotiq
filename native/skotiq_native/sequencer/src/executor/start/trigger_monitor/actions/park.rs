//! `ParkAndAbort`: end the run, parking and closing the rig unless the
//! operator's park setting says to leave it. When the trigger ends the night
//! (dawn, an obstruction), the plan's own shutdown steps run afterwards.

use super::super::super::night_end::{self, AlreadySafe, StepOutcome};
use super::custom_branch::CustomBranches;
use super::*;

/// The plan's shutdown steps, when `trigger_id` ends the night and the run has
/// a plan to read them from.
async fn finish_the_night(
    trigger_id: &str,
    trigger_name: &str,
    rig: &Rig,
    plan: &CustomBranches,
    run: &RunControl,
    already: AlreadySafe,
) -> Vec<StepOutcome> {
    if !night_end::ends_the_night(trigger_id) {
        return Vec::new();
    }
    let Some(sequence) = plan.sequence.as_ref() else {
        return Vec::new();
    };
    {
        let mut progress = run.progress.write();
        progress.message = Some(format!("{trigger_name}: putting the rig away"));
    }
    night_end::run_plan_shutdown_steps(
        trigger_name,
        sequence,
        &plan.context,
        &rig.device_ops,
        already,
    )
    .await
}

/// Stop the guider before the rig is put away. Guiding is device state the
/// node tree does not own. Returns whether it is stopped (or there is none).
async fn stop_guiding(rig: &Rig, run: &RunControl) -> bool {
    match rig.device_ops.guider_stop().await {
        Ok(()) => true,
        // An unguided rig has nothing to stop; reporting it would bury the
        // abort's real cause.
        Err(error) if crate::device_ops::is_no_guider_configured(&error) => {
            tracing::debug!("ParkAndAbort: no guider to stop ({})", error);
            true
        }
        Err(error) => {
            let msg = format!(
                "ParkAndAbort: failed to stop guiding before parking: {}",
                error
            );
            tracing::error!("{}", msg);
            run.error(msg);
            false
        }
    }
}

/// "Park before dawn" is off: end the run as the dawn rule does and leave the
/// mount, cover and dome as they are, apart from what the plan's own shutdown
/// steps do. The node tree is cancelled first so the exposure in flight is
/// aborted rather than cut off.
pub(in super::super) async fn end_without_parking(
    trigger_id: &str,
    trigger_name: &str,
    rig: &Rig,
    plan: &CustomBranches,
    run: &RunControl,
    park: &mut ParkSignals,
) -> ActionFlow {
    park.stop_node_tree(&run.is_cancelled).await;
    let guiding_stopped = night_end::ends_the_night(trigger_id) && stop_guiding(rig, run).await;
    let steps = finish_the_night(
        trigger_id,
        trigger_name,
        rig,
        plan,
        run,
        AlreadySafe {
            guiding_stopped,
            ..AlreadySafe::default()
        },
    )
    .await;
    let mount_moved = steps.iter().any(StepOutcome::moved_mount);
    let message = if mount_moved {
        format!(
            "{trigger_name}: the run has ended. Park before dawn is off, so the \
             mount was moved only by the plan's own shutdown steps, and the \
             cover and dome were not closed."
        )
    } else {
        format!(
            "{trigger_name}: the run has ended. The mount was not parked and the \
             cover and dome were not closed, because Park before dawn is off. \
             The mount may still be tracking."
        )
    };
    tracing::warn!("{}", message);
    run.error(message);
    ActionFlow::Terminate {
        recorded: RecoveryAction::ParkAndAbort,
        reason: "Dawn Approaching without parking",
    }
}

/// Stop the node tree, stop guiding, then park the mount and close the cover
/// and dome through the shared safe-state sweep. Every step's failure is
/// logged as well as sent, since a headless run has no event subscriber.
pub(in super::super) async fn park_and_abort(
    trigger_id: &str,
    trigger_name: &str,
    rig: &Rig,
    plan: &CustomBranches,
    run: &RunControl,
    park: &mut ParkSignals,
) -> ActionFlow {
    // The exposure instruction aborts its integration on cancellation before
    // the tree reports quiescence; only then may hardware move.
    park.parking_begins();
    park.stop_node_tree(&run.is_cancelled).await;

    let guiding_stopped = stop_guiding(rig, run).await;

    let devices = &rig.context;
    if devices.mount_id.is_some() {
        tracing::warn!(
            "ParkAndAbort: parking mount '{}' (max_retries=1, retry_delay=2s)",
            devices.mount_id.as_deref().unwrap_or("?")
        );
    } else {
        tracing::warn!("ParkAndAbort: no mount configured, cannot park");
    }
    if let Some(cover_id) = &devices.cover_calibrator_id {
        tracing::warn!("ParkAndAbort: closing cover '{}'", cover_id);
    }
    if let Some(dome_id) = &devices.dome_id {
        tracing::warn!("ParkAndAbort: closing dome shutter '{}'", dome_id);
    }

    let safe_state = crate::device_ops::park_and_close_safe_state(
        &rig.device_ops,
        devices.mount_id.as_deref(),
        devices.cover_calibrator_id.as_deref(),
        devices.dome_id.as_deref(),
        1,
        2.0,
    )
    .await;

    match &safe_state.park {
        Some(park_outcome) if !park_outcome.success => {
            let msg = format!(
                "ParkAndAbort: mount park FAILED after {} attempt{}: {}. \
                 Mount may be in an unsafe position — manual intervention required.",
                park_outcome.attempts_made,
                if park_outcome.attempts_made == 1 {
                    ""
                } else {
                    "s"
                },
                park_outcome
                    .last_error
                    .clone()
                    .unwrap_or_else(|| "unknown error".to_string()),
            );
            tracing::error!("{}", msg);
            run.error(msg);
        }
        None => {
            let msg = "ParkAndAbort fired but no mount is configured; the rig cannot be parked automatically.".to_string();
            tracing::error!("{}", msg);
            run.error(msg);
        }
        _ => {}
    }
    if let (Some(cover_id), Some(e)) = (&devices.cover_calibrator_id, &safe_state.cover_close_error)
    {
        let msg = format!(
            "ParkAndAbort: failed to close cover '{}': {}. \
             Optics may be left exposed — manual intervention required.",
            cover_id, e
        );
        tracing::error!("{}", msg);
        run.error(msg);
    }
    if let (Some(dome_id), Some(e)) = (&devices.dome_id, &safe_state.dome_close_error) {
        let msg = format!(
            "ParkAndAbort: failed to close dome '{}': {} — \
             scope may be exposed under an open roof. Manual intervention required.",
            dome_id, e
        );
        tracing::error!("{}", msg);
        run.error(msg);
    }

    let already = AlreadySafe {
        guiding_stopped,
        mount_parked: safe_state.park.as_ref().is_some_and(|p| p.success),
        cover_closed: devices.cover_calibrator_id.is_some()
            && safe_state.cover_close_error.is_none(),
        dome_closed: devices.dome_id.is_some() && safe_state.dome_close_error.is_none(),
    };
    finish_the_night(trigger_id, trigger_name, rig, plan, run, already).await;

    park.parked();
    ActionFlow::Terminate {
        recorded: RecoveryAction::ParkAndAbort,
        reason: "RecoveryAction::ParkAndAbort",
    }
}
