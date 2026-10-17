//! `dome.rs` — moved verbatim out of the former single-file `instructions.rs`
//! (release-pass C3 mechanical split). No logic changed; private items were
//! widened to `pub(crate)` so the sibling modules and the tests module still
//! see them, and `super::*` supplies the imports the original file had.

use super::*;

// Dome instructions

/// Maximum time to wait for a dome shutter to reach a commanded state.
/// Dome shutters are slow (30–90 s is typical on ASCOM/Alpaca observatory
/// domes), so this is generous. `DomeConfig` carries no per-node timeout
/// today (the Dart node only exposes `shutterOnly`), so this is the single
/// source of truth for the dome-shutter wait.
pub(crate) const DOME_SHUTTER_TIMEOUT_SECS: f64 = 120.0;

/// Result of waiting on a dome shutter to reach a commanded state. The `Ok`
/// arm distinguishes a *confirmed* arrival from a *degraded* one so callers
/// that need a genuine guarantee (the unattended safe-state sweep) can treat
/// the unconfirmed case as unsafe while the per-instruction path keeps its
/// roll-off-roof tolerance.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DomeShutterWaitOutcome {
    /// The dome reported it reached the commanded state.
    Confirmed,
    /// The dome never reported a definite shutter state (e.g. an INDI
    /// roll-off without a `DOME_SHUTTER` switch). The command was issued but
    /// arrival could NOT be confirmed. Surfaced, never silently treated as a
    /// clean success.
    Unconfirmed,
}

/// Poll the dome shutter status until it reaches `target` ("Open" or
/// "Closed"), or fail closed on timeout / a reported Error.
///
/// A fire-and-forget open/close lets the sequence slew and expose while the
/// shutter is still moving, or never moved at all, so domes poll for their
/// target state the way the cover/calibrator nodes do.
///
/// Some domes (e.g. INDI roll-offs without `DOME_SHUTTER` switches) cannot
/// report shutter state and the bridge returns Unknown/"Error" for them. When
/// EVERY poll comes back Unknown/"Error" (the device never reports a real
/// state), this degrades LOUDLY (warn + event) and returns
/// [`DomeShutterWaitOutcome::Unconfirmed`] rather than blocking a working
/// roll-off roof or claiming a clean success. A dome that reports a real state
/// but never reaches `target` within the timeout is a genuine failure and
/// fails closed (`Err`).
pub(crate) async fn wait_for_dome_shutter_state(
    ctx: &InstructionContext,
    dome_id: &str,
    target: &str,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
) -> Result<DomeShutterWaitOutcome, InstructionResult> {
    const POLL_SECS: f64 = 2.0;
    let mut elapsed = 0.0_f64;
    // Whether the dome ever reported a definite (non-Unknown) state. If it
    // never does, the device can't report status and we can't enforce a wait.
    let mut saw_definite_state = false;

    loop {
        if let Some(result) = ctx.check_cancelled() {
            return Err(result);
        }

        match ctx.device_ops.dome_get_shutter_status(dome_id).await {
            Ok(status) => {
                if status == target {
                    return Ok(DomeShutterWaitOutcome::Confirmed);
                }
                if status == "Open"
                    || status == "Closed"
                    || status == "Opening"
                    || status == "Closing"
                {
                    saw_definite_state = true;
                }

                if let Some(cb) = progress_callback {
                    // Hold progress in the 50–95% band while moving.
                    let pct = (50.0 + (elapsed / DOME_SHUTTER_TIMEOUT_SECS) * 45.0).min(95.0);
                    cb(pct, format!("Waiting for shutter ({status})"));
                }
            }
            Err(e) => {
                // A hard read error (driver fault / disconnect) is fatal —
                // we cannot verify the shutter, which is exactly the unsafe
                // case for a close.
                return Err(InstructionResult::failure(format!(
                    "Failed to read dome shutter status while waiting for {target}: {e}"
                )));
            }
        }

        if elapsed >= DOME_SHUTTER_TIMEOUT_SECS {
            if saw_definite_state {
                // The dome reports status but never reached the target — a
                // real motor/jam failure. Fail closed.
                return Err(InstructionResult::failure(format!(
                    "Dome shutter did not reach {target} within {:.0}s",
                    DOME_SHUTTER_TIMEOUT_SECS
                )));
            }
            // The dome never reported a real state — it cannot report shutter
            // position. Degrade loudly rather than failing a working dome, but
            // do NOT claim a clean success: return Unconfirmed so a caller that
            // needs a genuine guarantee (the unattended safe-state sweep) can
            // treat the never-confirmed close as unsafe.
            let msg = format!(
                "Dome shutter status unavailable; cannot confirm {target} \
                 (proceeding after issuing the command)"
            );
            tracing::warn!("{msg}");
            if let Some(event_tx) = &ctx.event_tx {
                let _ = event_tx.send(crate::executor::ExecutorEvent::Error { message: msg });
            }
            return Ok(DomeShutterWaitOutcome::Unconfirmed);
        }

        sleep(Duration::from_secs_f64(POLL_SECS)).await;
        elapsed += POLL_SECS;
    }
}

/// Execute open dome
pub async fn execute_open_dome(
    config: &DomeConfig,
    ctx: &InstructionContext,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
) -> InstructionResult {
    let dome_id = match ctx.dome_id().await {
        Ok(id) => id,
        Err(e) => return e,
    };

    // Report initial progress
    if let Some(cb) = progress_callback {
        cb(0.0, "Opening dome shutter".to_string());
    }

    tracing::info!("Opening dome shutter...");

    if let Some(result) = ctx.check_cancelled() {
        return result;
    }

    // Report waiting progress BEFORE the async call
    if let Some(cb) = progress_callback {
        cb(50.0, "Waiting for shutter to open".to_string());
    }

    if let Err(e) = ctx.device_ops.dome_open(&dome_id).await {
        return InstructionResult::failure(format!("Failed to open dome: {}", e));
    }

    if !config.shutter_only {
        // DeviceOps does not currently expose dome_unpark.
        // Operators must ensure dome park state is compatible with opening.
    }

    // Wait for the shutter to actually reach Open before declaring success,
    // or the next instruction slews and exposes against a closed roof.
    let open_outcome =
        match wait_for_dome_shutter_state(ctx, &dome_id, "Open", progress_callback).await {
            Ok(outcome) => outcome,
            Err(failure) => return failure,
        };

    // Report completion
    if let Some(cb) = progress_callback {
        cb(100.0, "Dome shutter open".to_string());
    }

    match open_outcome {
        DomeShutterWaitOutcome::Confirmed => {
            InstructionResult::success_with_message("Dome shutter opened")
        }
        DomeShutterWaitOutcome::Unconfirmed => InstructionResult::success_with_message(
            "Dome open command issued; shutter position could not be confirmed",
        ),
    }
}

/// Execute close dome
pub async fn execute_close_dome(
    _config: &DomeConfig,
    ctx: &InstructionContext,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
) -> InstructionResult {
    let dome_id = match ctx.dome_id().await {
        Ok(id) => id,
        Err(e) => return e,
    };

    // Report initial progress
    if let Some(cb) = progress_callback {
        cb(0.0, "Closing dome shutter".to_string());
    }

    tracing::info!("Closing dome shutter...");

    if let Some(result) = ctx.check_cancelled() {
        return result;
    }

    // Report waiting progress BEFORE the async call
    if let Some(cb) = progress_callback {
        cb(50.0, "Waiting for shutter to close".to_string());
    }

    if let Err(e) = ctx.device_ops.dome_close(&dome_id).await {
        return InstructionResult::failure(format!("Failed to close dome: {}", e));
    }

    // Confirm the shutter actually reached Closed — a roof that reports
    // "command accepted" but jams half-open would otherwise leave the scope
    // exposed for the rest of the night.
    let close_outcome =
        match wait_for_dome_shutter_state(ctx, &dome_id, "Closed", progress_callback).await {
            Ok(outcome) => outcome,
            Err(failure) => return failure,
        };

    // Report completion
    if let Some(cb) = progress_callback {
        cb(100.0, "Dome shutter closed".to_string());
    }

    match close_outcome {
        DomeShutterWaitOutcome::Confirmed => {
            InstructionResult::success_with_message("Dome shutter closed")
        }
        DomeShutterWaitOutcome::Unconfirmed => InstructionResult::success_with_message(
            "Dome close command issued; shutter position could not be confirmed",
        ),
    }
}

/// Execute park dome
pub async fn execute_park_dome(
    config: &DomeConfig,
    ctx: &InstructionContext,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
) -> InstructionResult {
    let dome_id = match ctx.dome_id().await {
        Ok(id) => id,
        Err(e) => return e,
    };

    // Report initial progress
    if let Some(cb) = progress_callback {
        cb(0.0, "Parking dome".to_string());
    }

    if let Some(result) = ctx.check_cancelled() {
        return result;
    }

    if !config.shutter_only {
        // Report waiting progress BEFORE the async call
        if let Some(cb) = progress_callback {
            cb(50.0, "Waiting for dome to reach park position".to_string());
        }

        tracing::info!("Parking dome...");
        if let Err(e) = ctx.device_ops.dome_park(&dome_id).await {
            return InstructionResult::failure(format!("Failed to park dome: {}", e));
        }
    }

    if let Some(result) = ctx.check_cancelled() {
        return result;
    }

    // Usually parking involves closing shutter too. This is safety-critical:
    // a swallowed close-error here would report "parked" while the scope sits
    // exposed under an open shutter all night. Propagate it (mirrors
    // `execute_close_dome`) rather than discarding the Result.
    tracing::info!("Closing shutter (park sequence)...");
    if let Err(e) = ctx.device_ops.dome_close(&dome_id).await {
        return InstructionResult::failure(format!(
            "Dome parked but failed to close shutter: {}",
            e
        ));
    }

    // Confirm the shutter reached Closed before claiming the park succeeded.
    if let Err(failure) =
        wait_for_dome_shutter_state(ctx, &dome_id, "Closed", progress_callback).await
    {
        return failure;
    }

    // Report completion
    if let Some(cb) = progress_callback {
        cb(100.0, "Dome parked".to_string());
    }

    InstructionResult::success_with_message("Dome parked")
}
