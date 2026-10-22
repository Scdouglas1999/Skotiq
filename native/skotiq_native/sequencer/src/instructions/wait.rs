//! `wait.rs` — moved verbatim out of the former single-file `instructions.rs`
//! (release-pass C3 mechanical split). No logic changed; private items were
//! widened to `pub(crate)` so the sibling modules and the tests module still
//! see them, and `super::*` supplies the imports the original file had.

use super::*;

/// Wait for a slew the mount has accepted to finish, reporting the distance
/// still to go. `target` is in the mount's read-back frame; without one the
/// wait still refuses to take an idle `Slewing` flag read straight after the
/// command as the end of the slew (see [`crate::slew_arrival`]).
///
/// Cancellation aborts the slew.
pub(crate) async fn wait_for_mount_arrival(
    mount_id: &str,
    ctx: &InstructionContext,
    target: Option<(f64, f64)>,
    timeout: Duration,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
) -> Result<crate::slew_arrival::SlewProgress, String> {
    use crate::slew_arrival::{wait_for_slew_arrival, SlewArrivalTimings, SlewWaitError};

    let mut polls = 0u32;
    let result = wait_for_slew_arrival(
        target,
        &SlewArrivalTimings::goto(timeout),
        || ctx.device_ops.mount_slew_state(mount_id),
        || ctx.cancellation_token.load(Ordering::Relaxed),
        |progress| {
            polls += 1;
            // Every other read: once a second is enough for a readout.
            if !polls.is_multiple_of(2) {
                return;
            }
            if let Some(cb) = progress_callback {
                // Held below 100 until the mount has stopped.
                let percent = progress.fraction().map_or_else(
                    || (progress.elapsed.as_secs_f64() / 60.0 * 100.0).min(95.0),
                    |f| (f * 100.0).min(95.0),
                );
                cb(percent, progress.describe());
            }
        },
    )
    .await;

    if matches!(
        result,
        Err(SlewWaitError::Cancelled) | Err(SlewWaitError::TimedOut(_))
    ) {
        if let Err(error) = ctx.device_ops.mount_abort_slew(mount_id).await {
            tracing::warn!(
                "Wait-for-slew: abort-slew failed ({}); the mount may still be moving",
                error
            );
        }
    }
    result.map_err(|e| e.to_string())
}

/// Wait for focuser to stop moving with timeout
pub(crate) async fn wait_for_focuser_idle(
    focuser_id: &str,
    ctx: &InstructionContext,
    timeout: Duration,
) -> Result<(), String> {
    let start = std::time::Instant::now();
    loop {
        if ctx.cancellation_token.load(Ordering::Relaxed) {
            // A bare cancel without halting can leave the focuser to overshoot
            // the original target; halt + wait-for-stop guarantees the user's
            // next instruction (e.g. autofocus restart) sees a stationary motor.
            tracing::info!("Cancellation detected during focuser move, halting focuser");
            if let Err(e) = ctx.device_ops.focuser_halt(focuser_id).await {
                tracing::warn!("Failed to halt focuser during cancellation: {}", e);
            }
            wait_for_focuser_stop_after_halt(focuser_id, &ctx.device_ops, Duration::from_secs(10))
                .await;
            return Err("Operation cancelled".to_string());
        }

        match ctx.device_ops.focuser_is_moving(focuser_id).await {
            Ok(is_moving) => {
                if !is_moving {
                    // 100 ms settle absorbs motor backlash on stepper focusers
                    // — the driver reports "stopped" before the gear train
                    // physically settles, and a subsequent exposure would catch
                    // the tail-end vibration.
                    sleep(Duration::from_millis(100)).await;
                    tracing::debug!("Focuser reached target position");
                    return Ok(());
                }
            }
            Err(e) => {
                tracing::warn!("Error checking focuser status: {}", e);
            }
        }

        if start.elapsed() > timeout {
            return Err(format!(
                "Focuser move timed out after {} seconds",
                timeout.as_secs()
            ));
        }

        // 100 ms (vs 500 ms for mount) — focusers complete moves in seconds,
        // not minutes, so a coarser cadence would lose alignment precision.
        sleep(Duration::from_millis(100)).await;
    }
}

/// Wait for focuser to stop moving after a halt command (ignores cancellation token).
/// This is used during cancellation handling to ensure the focuser has actually stopped
/// before returning control. The timeout is shorter since we're just waiting for halt.
pub async fn wait_for_focuser_stop_after_halt(
    focuser_id: &str,
    device_ops: &crate::device_ops::SharedDeviceOps,
    timeout: Duration,
) -> bool {
    let start = std::time::Instant::now();
    loop {
        match device_ops.focuser_is_moving(focuser_id).await {
            Ok(is_moving) => {
                if !is_moving {
                    tracing::debug!("Focuser stopped after halt");
                    return true;
                }
            }
            Err(e) => {
                tracing::warn!("Error checking focuser status after halt: {}", e);
            }
        }

        if start.elapsed() > timeout {
            tracing::warn!(
                "Focuser did not stop within {} seconds after halt",
                timeout.as_secs()
            );
            return false;
        }

        sleep(Duration::from_millis(100)).await;
    }
}

/// Wait for filter wheel to reach target position with timeout
pub(crate) async fn wait_for_filterwheel_idle(
    fw_id: &str,
    target_position: i32,
    ctx: &InstructionContext,
    timeout: Duration,
) -> Result<(), String> {
    let start = std::time::Instant::now();

    // Some filter wheels (notably ZWO EFW) still report the old position for
    // ~50 ms after issuing a move command; polling immediately would treat
    // the "already at target" reading as success and return before the wheel
    // has even started turning.
    sleep(Duration::from_millis(100)).await;

    loop {
        if ctx.cancellation_token.load(Ordering::Relaxed) {
            return Err("Operation cancelled".to_string());
        }

        match ctx.device_ops.filterwheel_get_position(fw_id).await {
            Ok(current_pos) => {
                if current_pos == target_position {
                    tracing::debug!("Filter wheel reached target position {}", target_position);
                    return Ok(());
                }
                tracing::trace!(
                    "Filter wheel at position {}, waiting for {}",
                    current_pos,
                    target_position
                );
            }
            Err(e) => {
                tracing::warn!("Error checking filter wheel position: {}", e);
            }
        }

        if start.elapsed() > timeout {
            return Err(format!(
                "Filter wheel move timed out after {} seconds (target: {})",
                timeout.as_secs(),
                target_position
            ));
        }

        sleep(Duration::from_millis(200)).await;
    }
}

pub(crate) async fn wait_for_cancellation(token: Arc<AtomicBool>) {
    loop {
        if token.load(Ordering::Relaxed) {
            return;
        }
        sleep(Duration::from_millis(100)).await;
    }
}
