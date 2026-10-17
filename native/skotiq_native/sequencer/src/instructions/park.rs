//! `park.rs` — moved verbatim out of the former single-file `instructions.rs`
//! (release-pass C3 mechanical split). No logic changed; private items were
//! widened to `pub(crate)` so the sibling modules and the tests module still
//! see them, and `super::*` supplies the imports the original file had.

use super::*;

// PARK/UNPARK instructions

/// Execute park
pub async fn execute_park(ctx: &InstructionContext) -> InstructionResult {
    let mount_id = match ctx.mount_id() {
        Ok(id) => id.to_string(),
        Err(e) => return e,
    };

    tracing::info!("Parking mount");

    if let Err(e) = ctx.device_ops.mount_park(&mount_id).await {
        return InstructionResult::failure(format!("Park failed: {}", e));
    }

    // mount_park only ISSUES the park on most drivers (ASCOM/Alpaca/INDI return
    // as soon as the command is acknowledged); a park slew takes 30-90 s.
    // Returning success immediately would let an automated end-of-night
    // shutdown advance to the next step (close dome / cut power) while the OTA
    // is still swinging, and would report success even for a park the driver
    // silently rejected (e.g. CanPark=false). Wait for the mount to report
    // PARKED — the authoritative completion signal across all driver types
    // (mount_is_slewing is unreliable for INDI parking, which uses a separate
    // property) — and fail closed if it never does.
    let park_deadline = tokio::time::Instant::now() + Duration::from_secs(300);
    loop {
        if let Some(result) = ctx.check_cancelled() {
            return result;
        }
        match ctx.device_ops.mount_is_parked(&mount_id).await {
            Ok(true) => {
                return InstructionResult::success_with_message("Mount parked");
            }
            Ok(false) => {
                // Still parking.
            }
            Err(e) => {
                tracing::warn!("Park: is_parked read failed ({}); retrying", e);
            }
        }
        if tokio::time::Instant::now() > park_deadline {
            return InstructionResult::failure(
                "Mount did not report parked within 300s of issuing Park. The driver may not \
                 support Park (CanPark=false), the park was rejected, or the mount is stuck \
                 mid-slew — NOT safe to assume parked."
                    .to_string(),
            );
        }
        sleep(Duration::from_millis(500)).await;
    }
}

/// Execute unpark
pub async fn execute_unpark(ctx: &InstructionContext) -> InstructionResult {
    let mount_id = match ctx.mount_id() {
        Ok(id) => id.to_string(),
        Err(e) => return e,
    };

    // Owner decision (2026-08-14): unpark only when the mount actually reports
    // PARKED. The autopilot puts an `Unpark` at the head of every dispatched
    // sequence, so a mount that is already tracking a target gets the command
    // mid-run; several drivers treat Unpark as "release the axes", which drops
    // tracking (and on some ASCOM mounts re-homes) under an in-flight target.
    // Not parked is not an error — there is simply nothing to do, and saying so
    // in the log keeps the no-op visible instead of silent.
    //
    // A parked-state read that FAILS is not a licence to skip: an unpark on an
    // already-unparked mount is the milder outcome, so fall through and issue
    // it (this is the pre-decision behaviour).
    match ctx.device_ops.mount_is_parked(&mount_id).await {
        Ok(false) => {
            tracing::info!("Unpark: mount already reports unparked; nothing to do");
            return InstructionResult::success_with_message("Mount already unparked");
        }
        Ok(true) => {}
        Err(e) => {
            tracing::warn!("Unpark: is_parked read failed ({}); unparking anyway", e);
        }
    }

    tracing::info!("Unparking mount");

    match ctx.device_ops.mount_unpark(&mount_id).await {
        Ok(_) => InstructionResult::success_with_message("Mount unparked"),
        Err(e) => InstructionResult::failure(format!("Unpark failed: {}", e)),
    }
}
