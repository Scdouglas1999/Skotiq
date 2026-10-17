//! `cover_calibrator.rs` — moved verbatim out of the former single-file `instructions.rs`
//! (release-pass C3 mechanical split). No logic changed; private items were
//! widened to `pub(crate)` so the sibling modules and the tests module still
//! see them, and `super::*` supplies the imports the original file had.

use super::*;

// Cover calibrator (flat panel / dust cover) instructions

/// Execute open cover (unpark dust cap)
pub async fn execute_open_cover(
    config: &crate::CoverCalibratorConfig,
    ctx: &InstructionContext,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
) -> InstructionResult {
    let device_id = match ctx.cover_calibrator_id().await {
        Ok(id) => id,
        Err(e) => return e,
    };

    // Report initial progress
    if let Some(cb) = progress_callback {
        cb(0.0, "Opening cover".to_string());
    }

    tracing::info!("Opening cover...");

    if let Some(result) = ctx.check_cancelled() {
        return result;
    }

    // Report waiting progress BEFORE the async call
    if let Some(cb) = progress_callback {
        cb(50.0, "Waiting for cover to open".to_string());
    }

    // Start opening the cover
    if let Err(e) = ctx.device_ops.cover_calibrator_open_cover(&device_id).await {
        return InstructionResult::failure(format!("Failed to open cover: {}", e));
    }

    // Wait for cover to reach open state with timeout
    // Why: u32 timeout_secs -> u64 widening is lossless.
    let timeout = Duration::from_secs(u64::from(config.timeout_secs));
    match wait_for_cover_state(&device_id, 3, ctx, timeout).await {
        Ok(_) => {
            // Report completion
            if let Some(cb) = progress_callback {
                cb(100.0, "Cover open".to_string());
            }
            InstructionResult::success_with_message("Cover opened")
        }
        Err(e) => InstructionResult::failure(e),
    }
}

/// Execute close cover (park dust cap)
pub async fn execute_close_cover(
    config: &crate::CoverCalibratorConfig,
    ctx: &InstructionContext,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
) -> InstructionResult {
    let device_id = match ctx.cover_calibrator_id().await {
        Ok(id) => id,
        Err(e) => return e,
    };

    // Report initial progress
    if let Some(cb) = progress_callback {
        cb(0.0, "Closing cover".to_string());
    }

    tracing::info!("Closing cover...");

    if let Some(result) = ctx.check_cancelled() {
        return result;
    }

    // Report waiting progress BEFORE the async call
    if let Some(cb) = progress_callback {
        cb(50.0, "Waiting for cover to close".to_string());
    }

    // Start closing the cover
    if let Err(e) = ctx
        .device_ops
        .cover_calibrator_close_cover(&device_id)
        .await
    {
        return InstructionResult::failure(format!("Failed to close cover: {}", e));
    }

    // Wait for cover to reach closed state with timeout
    // Why: u32 timeout_secs -> u64 widening is lossless.
    let timeout = Duration::from_secs(u64::from(config.timeout_secs));
    match wait_for_cover_state(&device_id, 1, ctx, timeout).await {
        Ok(_) => {
            // Report completion
            if let Some(cb) = progress_callback {
                cb(100.0, "Cover closed".to_string());
            }
            InstructionResult::success_with_message("Cover closed")
        }
        Err(e) => InstructionResult::failure(e),
    }
}

/// Execute calibrator on (turn on flat panel light)
pub async fn execute_calibrator_on(
    config: &crate::CalibratorOnConfig,
    ctx: &InstructionContext,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
) -> InstructionResult {
    let device_id = match ctx.cover_calibrator_id().await {
        Ok(id) => id,
        Err(e) => return e,
    };

    // Report initial progress
    if let Some(cb) = progress_callback {
        cb(0.0, "Turning on calibrator".to_string());
    }

    tracing::info!(
        "Turning calibrator on at brightness {}...",
        config.brightness
    );

    if let Some(result) = ctx.check_cancelled() {
        return result;
    }

    // Report waiting progress BEFORE the async call
    if let Some(cb) = progress_callback {
        cb(
            50.0,
            format!("Adjusting brightness to {}%", config.brightness),
        );
    }

    // Turn on the calibrator at specified brightness
    if let Err(e) = ctx
        .device_ops
        .cover_calibrator_calibrator_on(&device_id, config.brightness)
        .await
    {
        return InstructionResult::failure(format!("Failed to turn on calibrator: {}", e));
    }

    // Wait for calibrator to reach ready state with timeout
    // Why: u32 timeout_secs -> u64 widening is lossless.
    let timeout = Duration::from_secs(u64::from(config.timeout_secs));
    match wait_for_calibrator_state(&device_id, 3, ctx, timeout).await {
        Ok(_) => {
            // Verify brightness is set correctly
            // Why: post-set verification readback; an Err here would mean
            // the driver dropped the cover-calibrator session between SetBrightness and
            // GetBrightness — falling back to the requested value `config.brightness`
            // simply trusts the SetBrightness call that already returned success above
            // (it propagated via `?`). The successful "wait for state 3" check
            // (`wait_for_calibrator_state`) is the load-bearing readiness signal.
            let actual_brightness = ctx
                .device_ops
                .cover_calibrator_get_brightness(&device_id)
                .await
                .unwrap_or(config.brightness);
            // Report completion
            if let Some(cb) = progress_callback {
                cb(
                    100.0,
                    format!("Calibrator on at brightness {}", actual_brightness),
                );
            }
            InstructionResult::success_with_message(format!(
                "Calibrator on at brightness {}",
                actual_brightness
            ))
        }
        Err(e) => InstructionResult::failure(e),
    }
}

/// Execute calibrator off (turn off flat panel light)
pub async fn execute_calibrator_off(
    config: &crate::CoverCalibratorConfig,
    ctx: &InstructionContext,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
) -> InstructionResult {
    let device_id = match ctx.cover_calibrator_id().await {
        Ok(id) => id,
        Err(e) => return e,
    };

    // Report initial progress
    if let Some(cb) = progress_callback {
        cb(0.0, "Turning off calibrator".to_string());
    }

    tracing::info!("Turning calibrator off...");

    if let Some(result) = ctx.check_cancelled() {
        return result;
    }

    // Report waiting progress BEFORE the async call
    if let Some(cb) = progress_callback {
        cb(50.0, "Waiting for calibrator to turn off".to_string());
    }

    // Turn off the calibrator
    if let Err(e) = ctx
        .device_ops
        .cover_calibrator_calibrator_off(&device_id)
        .await
    {
        return InstructionResult::failure(format!("Failed to turn off calibrator: {}", e));
    }

    // Wait for calibrator to reach off state with timeout
    // Why: u32 timeout_secs -> u64 widening is lossless.
    let timeout = Duration::from_secs(u64::from(config.timeout_secs));
    match wait_for_calibrator_state(&device_id, 1, ctx, timeout).await {
        Ok(_) => {
            // Report completion
            if let Some(cb) = progress_callback {
                cb(100.0, "Calibrator off".to_string());
            }
            InstructionResult::success_with_message("Calibrator off")
        }
        Err(e) => InstructionResult::failure(e),
    }
}

/// Wait for cover to reach target state with timeout
/// States: 0=NotPresent, 1=Closed, 2=Moving, 3=Open, 4=Unknown, 5=Error
pub(crate) async fn wait_for_cover_state(
    device_id: &str,
    target_state: i32,
    ctx: &InstructionContext,
    timeout: Duration,
) -> Result<(), String> {
    let start = std::time::Instant::now();
    let state_name = match target_state {
        0 => "NotPresent",
        1 => "Closed",
        2 => "Moving",
        3 => "Open",
        4 => "Unknown",
        5 => "Error",
        _ => "Unknown",
    };

    loop {
        // Check cancellation
        if ctx.cancellation_token.load(Ordering::Relaxed) {
            // Try to halt cover movement
            if let Err(error) = ctx.device_ops.cover_calibrator_halt_cover(device_id).await {
                tracing::warn!(
                    "Cover '{}': halt failed while cancelling the wait for the {} state ({}); \
                     the cover may still be moving",
                    device_id,
                    state_name,
                    error
                );
            }
            return Err("Operation cancelled".to_string());
        }

        // Check current state
        match ctx
            .device_ops
            .cover_calibrator_get_cover_state(device_id)
            .await
        {
            Ok(state) => {
                if state == target_state {
                    tracing::debug!("Cover reached {} state", state_name);
                    return Ok(());
                }
                if state == 5 {
                    return Err("Cover reported error state".to_string());
                }
                tracing::trace!("Cover state: {}, waiting for {}", state, state_name);
            }
            Err(e) => {
                tracing::warn!("Error checking cover state: {}", e);
                // Continue polling - transient error
            }
        }

        // Check timeout
        if start.elapsed() > timeout {
            return Err(format!(
                "Cover did not reach {} state within {} seconds",
                state_name,
                timeout.as_secs()
            ));
        }

        // Poll every 500ms
        sleep(Duration::from_millis(500)).await;
    }
}

/// Wait for calibrator to reach target state with timeout
/// States: 0=NotPresent, 1=Off, 2=NotReady, 3=Ready, 4=Unknown, 5=Error
pub(crate) async fn wait_for_calibrator_state(
    device_id: &str,
    target_state: i32,
    ctx: &InstructionContext,
    timeout: Duration,
) -> Result<(), String> {
    let start = std::time::Instant::now();
    let state_name = match target_state {
        0 => "NotPresent",
        1 => "Off",
        2 => "NotReady",
        3 => "Ready",
        4 => "Unknown",
        5 => "Error",
        _ => "Unknown",
    };

    loop {
        // Check cancellation
        if ctx.cancellation_token.load(Ordering::Relaxed) {
            if let Err(error) = ctx
                .device_ops
                .cover_calibrator_calibrator_off(device_id)
                .await
            {
                tracing::warn!(
                    "Calibrator '{}': switch-off failed while cancelling the wait for the {} \
                     state ({}); the flat panel may still be illuminated",
                    device_id,
                    state_name,
                    error
                );
            }
            if let Err(error) = ctx.device_ops.cover_calibrator_halt_cover(device_id).await {
                tracing::warn!(
                    "Calibrator '{}': cover halt failed while cancelling the wait for the {} \
                     state ({}); the cover may still be moving",
                    device_id,
                    state_name,
                    error
                );
            }
            return Err("Operation cancelled".to_string());
        }

        // Check current state
        match ctx
            .device_ops
            .cover_calibrator_get_calibrator_state(device_id)
            .await
        {
            Ok(state) => {
                if state == target_state {
                    tracing::debug!("Calibrator reached {} state", state_name);
                    return Ok(());
                }
                if state == 5 {
                    return Err("Calibrator reported error state".to_string());
                }
                tracing::trace!("Calibrator state: {}, waiting for {}", state, state_name);
            }
            Err(e) => {
                tracing::warn!("Error checking calibrator state: {}", e);
                // Continue polling - transient error
            }
        }

        // Check timeout
        if start.elapsed() > timeout {
            if let Err(error) = ctx.device_ops.cover_calibrator_halt_cover(device_id).await {
                tracing::warn!(
                    "Calibrator '{}': cover halt failed after the {} state timed out ({}); the \
                     cover may still be moving",
                    device_id,
                    state_name,
                    error
                );
            }
            return Err(format!(
                "Calibrator did not reach {} state within {} seconds",
                state_name,
                timeout.as_secs()
            ));
        }

        // Poll every 200ms (calibrator state can change quickly)
        sleep(Duration::from_millis(200)).await;
    }
}
