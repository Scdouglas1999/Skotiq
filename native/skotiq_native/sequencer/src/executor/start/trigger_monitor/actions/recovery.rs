//! `Pause`, `Retry` and `PauseAndWaitForClear`: hand the run to the recovery
//! driver where the trigger has a recovery, or pause it for the operator.

use super::*;
use tokio::sync::mpsc::error::TrySendError;

/// `Pause`. A trigger with a recovery cause becomes a recovery request (the
/// driver freezes the node tree and runs its ladder); any other trigger, or a
/// driver that has gone, pauses the run for the operator.
pub(in super::super) async fn pause(
    trigger_id: &str,
    trigger_name: &str,
    recovery_tx: &mpsc::Sender<crate::recovery::RecoveryCause>,
    run: &RunControl,
) -> ActionFlow {
    let Some(cause) = trigger_recovery_cause(trigger_id) else {
        run.pause(None).await;
        return ActionFlow::Finished;
    };
    // The channel is bounded: Full means a recovery is already running or
    // queued, and the driver takes one cause at a time.
    match recovery_tx.try_send(cause.clone()) {
        Ok(()) => {
            tracing::info!(
                "[RECOVERY] Trigger '{}' promoted to recovery request ({:?})",
                trigger_name,
                cause
            );
        }
        Err(TrySendError::Full(_)) => {
            tracing::warn!(
                "[RECOVERY] Recovery channel full; dropping duplicate request from '{}'",
                trigger_name
            );
        }
        Err(TrySendError::Closed(_)) => run.pause(None).await,
    }
    ActionFlow::Finished
}

/// `Retry`. A trigger firing is not a failed node, so there is nothing to
/// re-run. Where the trigger has a recovery cause the driver takes it on the
/// first firing, so the node tree stops exposing through the failure; for any
/// other trigger `max_attempts` is how many firings the operator tolerates
/// before the run pauses.
pub(in super::super) async fn retry(
    trigger_id: &str,
    trigger_name: &str,
    max_attempts: u32,
    recovery_tx: &mpsc::Sender<crate::recovery::RecoveryCause>,
    retry_attempts: &mut HashMap<String, u32>,
    run: &RunControl,
) -> ActionFlow {
    if let Some(cause) = trigger_recovery_cause(trigger_id) {
        match recovery_tx.try_send(cause.clone()) {
            Ok(()) => {
                tracing::warn!(
                    "[RECOVERY] Trigger '{}' fired with a Retry action and maps \
                     to {:?}; handing it to the recovery driver so the node tree \
                     freezes instead of exposing through the failure",
                    trigger_name,
                    cause
                );
            }
            Err(TrySendError::Full(_)) => {
                // Already recovering or queued: the node tree is frozen either
                // way.
                tracing::warn!(
                    "[RECOVERY] Recovery channel full; dropping duplicate \
                     request from '{}'",
                    trigger_name
                );
            }
            Err(TrySendError::Closed(_)) => {
                // The run must still stop taking frames.
                tracing::error!(
                    "[RECOVERY] Recovery driver is gone; pausing the run for \
                     trigger '{}' rather than exposing through the failure",
                    trigger_name
                );
                run.pause(Some(format!("Paused: {} fired", trigger_name)))
                    .await;
                run.error(format!(
                    "Trigger '{}' fired and automatic recovery is not \
                     available. The run is paused — no further frames will \
                     be taken until you resume.",
                    trigger_name
                ));
            }
        }
        return ActionFlow::Finished;
    }

    let attempts = retry_attempts.entry(trigger_id.to_string()).or_insert(0);
    if *attempts < max_attempts {
        *attempts += 1;
        tracing::warn!(
            "Trigger '{}' fired {}/{} times; it has no automatic recovery, \
             so the run continues until the {} allowed firing{} are used",
            trigger_name,
            attempts,
            max_attempts,
            max_attempts,
            if max_attempts == 1 { "" } else { "s" }
        );
    } else {
        tracing::error!(
            "Trigger '{}' fired more than its {} allowed times; pausing \
             sequence",
            trigger_name,
            max_attempts
        );
        run.pause(Some(format!("Paused: {} kept firing", trigger_name)))
            .await;
        run.error(format!(
            "Trigger '{}' fired more than the {} times allowed; sequence \
             paused",
            trigger_name, max_attempts
        ));
    }
    ActionFlow::Finished
}

/// `PauseAndWaitForClear`: the weather recovery, so the dashboard banner, the
/// alert and the driver's resume-on-clear all apply. A plain pause when the
/// driver cannot take it.
pub(in super::super) async fn pause_and_wait_for_clear(
    trigger_name: &str,
    recovery_tx: &mpsc::Sender<crate::recovery::RecoveryCause>,
    run: &RunControl,
) -> ActionFlow {
    tracing::warn!(
        "[CLOUD] Trigger '{}' fired - pausing sequence (PauseAndWaitForClear)",
        trigger_name
    );
    let cause = crate::recovery::RecoveryCause::WeatherUnsafe;
    match recovery_tx.try_send(cause.clone()) {
        Ok(()) => {
            tracing::info!("[RECOVERY] PauseAndWaitForClear requested ({:?})", cause);
        }
        Err(TrySendError::Full(_)) => {
            tracing::warn!("[RECOVERY] Recovery channel full; falling back to plain Pause");
            run.pause(None).await;
        }
        Err(TrySendError::Closed(_)) => run.pause(None).await,
    }
    ActionFlow::Finished
}
