//! `rotator.rs` — moved verbatim out of the former single-file `instructions.rs`
//! (release-pass C3 mechanical split). No logic changed; private items were
//! widened to `pub(crate)` so the sibling modules and the tests module still
//! see them, and `super::*` supplies the imports the original file had.

use super::*;

// Rotator move + verify (shared by RotateToAngle instruction and centering)

/// Tolerance (degrees) within which a rotator is considered "at" its target.
pub(crate) const ROTATOR_TOLERANCE_DEG: f64 = 1.0;
/// Maximum time to wait for a rotator to reach its target before failing closed.
pub(crate) const ROTATOR_TIMEOUT_SECS: f64 = 120.0;
/// Rotator arrival poll interval.
pub(crate) const ROTATOR_POLL_SECS: f64 = 1.0;

/// Normalise an angle into `[0, 360)`. Non-finite input collapses to 0.
pub(crate) fn normalize_rotator_angle(a: f64) -> f64 {
    let r = a.rem_euclid(360.0);
    if r.is_finite() {
        r
    } else {
        0.0
    }
}

/// Smallest signed angular distance `a - b` in degrees, accounting for the
/// 360° wrap. Result is in `[-180, 180]`.
pub(crate) fn rotator_angle_diff(a: f64, b: f64) -> f64 {
    (a - b + 540.0).rem_euclid(360.0) - 180.0
}

/// Move a rotator to an ABSOLUTE mechanical angle and block until it actually
/// reaches it (or fail closed on error / timeout).
///
/// The driver-level `rotator_move_to` only ISSUES the move on ASCOM/Alpaca/INDI
/// (it returns as soon as the command is accepted), so this helper polls
/// `rotator_get_angle` until the achieved angle is within
/// `ROTATOR_TOLERANCE_DEG` of the target. Used by both the explicit
/// `RotateToAngle` instruction and by `execute_center` so a target's framing
/// rotation is physically applied during centering.
///
/// `progress` is invoked with `(percent_0_to_100, message)` for UI feedback.
pub(crate) async fn rotator_move_to_verified(
    ctx: &InstructionContext,
    rotator_id: &str,
    target_abs_deg: f64,
    mut progress: impl FnMut(f64, String),
) -> Result<f64, InstructionResult> {
    let target_abs = normalize_rotator_angle(target_abs_deg);

    if let Err(e) = ctx.device_ops.rotator_move_to(rotator_id, target_abs).await {
        return Err(InstructionResult::failure(format!(
            "Rotator move failed: {}",
            e
        )));
    }

    let mut elapsed = 0.0_f64;
    loop {
        if let Some(result) = ctx.check_cancelled() {
            return Err(result);
        }
        let current = match ctx.device_ops.rotator_get_angle(rotator_id).await {
            Ok(a) => a,
            Err(e) => {
                return Err(InstructionResult::failure(format!(
                    "Failed to read rotator angle during move: {}",
                    e
                )))
            }
        };
        if rotator_angle_diff(current, target_abs).abs() <= ROTATOR_TOLERANCE_DEG {
            progress(100.0, format!("Rotator at {:.1}°", current));
            return Ok(current);
        }
        if elapsed >= ROTATOR_TIMEOUT_SECS {
            return Err(InstructionResult::failure(format!(
                "Rotator did not reach {:.1}° within {:.0}s (last {:.1}°)",
                target_abs, ROTATOR_TIMEOUT_SECS, current
            )));
        }
        let pct = (elapsed / ROTATOR_TIMEOUT_SECS * 95.0).min(95.0);
        progress(
            pct,
            format!("Rotating to {:.1}° (at {:.1}°)", target_abs, current),
        );
        sleep(Duration::from_secs_f64(ROTATOR_POLL_SECS)).await;
        elapsed += ROTATOR_POLL_SECS;
    }
}

// Rotator instruction

/// Execute rotator move
pub async fn execute_rotator_move(
    config: &RotatorConfig,
    ctx: &InstructionContext,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
) -> InstructionResult {
    let rotator_id = match ctx.rotator_id() {
        Ok(id) => id.to_string(),
        Err(e) => return e,
    };

    tracing::info!(
        "Moving rotator to {} (relative: {})",
        config.target_angle,
        config.relative
    );

    // Report initial progress
    if let Some(cb) = progress_callback {
        cb(0.0, format!("Moving to {:.1}", config.target_angle));
    }

    // Resolve the ABSOLUTE target so we can verify arrival even for a relative
    // move — we must read the current angle BEFORE issuing the move.
    let target_abs = if config.relative {
        match ctx.device_ops.rotator_get_angle(&rotator_id).await {
            Ok(current) => normalize_rotator_angle(current + config.target_angle),
            Err(e) => {
                return InstructionResult::failure(format!(
                    "Failed to read rotator angle before relative move: {}",
                    e
                ))
            }
        }
    } else {
        normalize_rotator_angle(config.target_angle)
    };

    // Move to the absolute target and verify arrival within tolerance (fails
    // closed on error / timeout). The driver move call only ISSUES the move on
    // ASCOM/Alpaca/INDI, so without this verify the next instruction (e.g. an
    // exposure) could start while the camera angle is still slewing — smearing
    // field rotation across the frame and breaking any rotation-matched
    // mosaic/flat. Issuing an absolute move (rather than the relative driver
    // call) keeps the verified-target and the issued-target identical.
    match rotator_move_to_verified(ctx, &rotator_id, target_abs, |pct, msg| {
        if let Some(cb) = progress_callback {
            cb(pct, msg);
        }
    })
    .await
    {
        Ok(current) => InstructionResult::success_with_message(format!(
            "Rotator at {:.1} (target {:.1})",
            current, target_abs
        )),
        Err(result) => result,
    }
}
