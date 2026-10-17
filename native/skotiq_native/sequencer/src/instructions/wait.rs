//! `wait.rs` — moved verbatim out of the former single-file `instructions.rs`
//! (release-pass C3 mechanical split). No logic changed; private items were
//! widened to `pub(crate)` so the sibling modules and the tests module still
//! see them, and `super::*` supplies the imports the original file had.

use super::*;

/// Wait for mount to stop slewing with timeout and progress updates
pub(crate) async fn wait_for_mount_idle_with_progress(
    mount_id: &str,
    ctx: &InstructionContext,
    timeout: Duration,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
) -> Result<(), String> {
    let start = std::time::Instant::now();
    let mut poll_count = 0u32;

    loop {
        if ctx.cancellation_token.load(Ordering::Relaxed) {
            if let Err(error) = ctx.device_ops.mount_abort_slew(mount_id).await {
                tracing::warn!(
                    "Wait-for-slew: abort-slew failed on cancel ({}); the mount may still be \
                     moving",
                    error
                );
            }
            return Err("Operation cancelled".to_string());
        }

        match ctx.device_ops.mount_is_slewing(mount_id).await {
            Ok(is_slewing) => {
                if !is_slewing {
                    tracing::debug!("Mount reached target position");
                    return Ok(());
                }
            }
            Err(e) => {
                // Transient query failures are common during slews on serial
                // mounts; we keep polling so a one-off error does not abort
                // an otherwise healthy slew.
                tracing::warn!("Error checking slew status: {}", e);
            }
        }

        // Slew progress lacks a real percentage from drivers, so we synthesize
        // a 0–95% estimate from elapsed time using the typical 30–60 s slew
        // duration. Capped at 95% so the user does not see "100%" before the
        // mount actually reports idle.
        poll_count += 1;
        if poll_count.is_multiple_of(4) {
            let elapsed_secs = start.elapsed().as_secs();
            // Why: elapsed_secs is a u64 wall-clock; even months of elapsed time fit
            // in f64's 53-bit mantissa. Lossless for any plausible slew duration.
            let progress = ((elapsed_secs as f64 / 60.0) * 100.0).min(95.0);
            if let Some(cb) = progress_callback {
                cb(progress, format!("Slewing... ({:.0}s)", elapsed_secs));
            }
        }

        if start.elapsed() > timeout {
            return Err(format!(
                "Mount slew timed out after {} seconds",
                timeout.as_secs()
            ));
        }

        // 500 ms balances responsiveness against driver query cost on serial
        // mounts (where each poll round-trips through USB-to-serial).
        sleep(Duration::from_millis(500)).await;
    }
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
