//! `slew.rs` — moved verbatim out of the former single-file `instructions.rs`
//! (release-pass C3 mechanical split). No logic changed; private items were
//! widened to `pub(crate)` so the sibling modules and the tests module still
//! see them, and `super::*` supplies the imports the original file had.

use super::*;

// Slew instruction

/// Default tolerance for slew position validation in degrees (1 arcminute = 1/60 degree)
pub(crate) const SLEW_POSITION_TOLERANCE_DEG: f64 = 1.0 / 60.0;

/// Normalize RA difference to account for wraparound at 24 hours
/// Returns the shortest angular distance between two RA values in hours
pub(crate) fn normalize_ra_diff_hours(diff: f64) -> f64 {
    // Normalize to [-12, +12] h so the sign of the result is the shortest
    // signed angular distance — necessary because a raw 23 h difference is
    // physically a -1 h move, not a 23 h move.
    let mut wrapped = diff % 24.0;
    if wrapped > 12.0 {
        wrapped -= 24.0;
    } else if wrapped < -12.0 {
        wrapped += 24.0;
    }
    wrapped
}

/// Validate that mount reached the target position within tolerance
/// ra_target and ra_actual are in hours, dec_target and dec_actual are in degrees
/// tolerance_deg is the maximum allowed difference in degrees
pub(crate) fn validate_slew_position(
    ra_target: f64,
    dec_target: f64,
    ra_actual: f64,
    dec_actual: f64,
    tolerance_deg: f64,
) -> Result<(), String> {
    let ra_diff_hours = normalize_ra_diff_hours(ra_actual - ra_target);
    // On the sky, not in raw RA degrees: an hour of RA spans cos(Dec) of the
    // arc it does on the equator. Without the factor the effective tolerance
    // near the pole shrank to seconds of arc, below the jitter of a good
    // mount's RA read-back there, and landed slews were failed as misses.
    let ra_diff_deg = ra_diff_hours * 15.0 * dec_target.to_radians().cos();

    // Dec is bounded to [-90, +90] so there is no wraparound to handle; a
    // raw subtraction is the signed angular distance directly.
    let dec_diff_deg = dec_actual - dec_target;

    if ra_diff_deg.abs() > tolerance_deg || dec_diff_deg.abs() > tolerance_deg {
        return Err(format!(
            "Mount slew did not reach target position. Expected RA={:.4}h, Dec={:.4}deg, \
             got RA={:.4}h, Dec={:.4}deg (diff: RA={:.2}', Dec={:.2}')",
            ra_target,
            dec_target,
            ra_actual,
            dec_actual,
            ra_diff_deg * 60.0, // Convert to arcminutes for readability
            dec_diff_deg * 60.0
        ));
    }

    Ok(())
}

/// Execute a slew instruction
pub async fn execute_slew(
    config: &SlewConfig,
    ctx: &InstructionContext,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
) -> InstructionResult {
    let mount_id = match ctx.mount_id() {
        Ok(id) => id,
        Err(e) => return e,
    };

    // Slewing a parked mount on most drivers either silently no-ops or
    // errors deep in the slew loop; surfacing the precondition here gives
    // the user a clean error with a recovery hint (unpark) before any
    // long-running motion is attempted.
    match ctx.device_ops.mount_is_parked(mount_id).await {
        Ok(true) => {
            tracing::warn!("Mount is parked, cannot slew. Please unpark the mount first.");
            return InstructionResult::failure_with_recovery(
                "Mount is parked. Please unpark the mount before slewing.",
                "MOUNT_PARKED",
            );
        }
        Ok(false) => {
            tracing::debug!("Mount is not parked, proceeding with slew");
        }
        Err(e) => {
            // Old INDI drivers and some serial mounts lack park-status reporting.
            // Treat the query failure as "unknown" rather than "parked" so we do
            // not block slewing on mounts that genuinely cannot tell us.
            tracing::debug!("Could not check mount park status: {}", e);
        }
    }

    let (ra, dec) = if config.use_target_coords {
        match (ctx.target_ra, ctx.target_dec) {
            (Some(ra), Some(dec)) => (ra, dec),
            _ => return InstructionResult::failure("No target coordinates available"),
        }
    } else {
        match (config.custom_ra, config.custom_dec) {
            (Some(ra), Some(dec)) => (ra, dec),
            _ => return InstructionResult::failure("No custom coordinates specified"),
        }
    };

    // Refuse to drive the mount to a target whose coordinates were never set.
    // Only the inherited-pointing case can carry the placeholder; a custom-
    // coordinate slew is an explicit instruction from the operator.
    if config.use_target_coords {
        if let Some(reason) =
            unset_target_pointing_reason(ctx.target_name.as_deref(), ra, dec, "slew to target")
        {
            tracing::warn!("{reason}");
            return InstructionResult::failure_with_recovery(reason, UNSET_TARGET_RECOVERY_CODE);
        }
    }

    // W1 native daylight gate (structural). A slew that points the rig at the
    // active sky/science target (`use_target_coords`) is the on-sky pointing
    // step of a LIGHT-frame run; refuse it while the Sun is up so a raw
    // sequence started via `api_sequencer_start` (including a mosaic) cannot
    // slew + expose lights in full daylight. Slews to custom coordinates
    // (park positions, flat-panel pointing, alignment moves) are NOT gated —
    // only the science-target slew. Abstains when the observer location is
    // unset (see `daylight_gate_block_reason`).
    if config.use_target_coords {
        let max_sun_alt = resolve_max_sun_altitude(ctx).await;
        if let Some(reason) =
            daylight_gate_block_reason(ctx.latitude, ctx.longitude, max_sun_alt, "slew to target")
        {
            tracing::warn!("{reason}");
            return InstructionResult::failure_with_recovery(reason, DAYLIGHT_GATE_RECOVERY_CODE);
        }
    }

    tracing::info!("Slewing to RA: {:.4}h, Dec: {:.4}°", ra, dec);

    if let Some(cb) = progress_callback {
        cb(0.0, format!("Slewing to RA: {:.2}h, Dec: {:.1}°", ra, dec));
    }

    if let Some(result) = ctx.check_cancelled() {
        return result;
    }

    tokio::select! {
        result = ctx.device_ops.mount_slew_to_coordinates(mount_id, ra, dec) => {
            match result {
                Ok(_) => {
                    // 1800 s = 30 min handles the longest realistic slew on
                    // weight-belt direct-drives doing a full-sky move; tighter
                    // would false-alarm on heavily loaded mounts.
                    match wait_for_mount_idle_with_progress(mount_id, ctx, Duration::from_secs(1800), progress_callback).await {
                        Ok(_) => {
                            // The mount reports "not slewing" before its
                            // axes have fully settled on some drivers, so we
                            // re-read coordinates and validate against the
                            // target before declaring success — silent
                            // mis-pointing would feed bad data downstream.
                            match ctx.device_ops.mount_get_coordinates(mount_id).await {
                                Ok((actual_ra, actual_dec)) => {
                                    tracing::debug!(
                                        "Slew completed. Target: RA={:.4}h, Dec={:.4}°, Actual: RA={:.4}h, Dec={:.4}°",
                                        ra, dec, actual_ra, actual_dec
                                    );

                                    // Validate in the frame the mount REPORTS,
                                    // not the J2000 frame the target is held in.
                                    // The device layer precesses coordinates on
                                    // the way out and leaves read-backs alone,
                                    // so comparing the raw target against a
                                    // read-back fails by the precession offset —
                                    // 16.00' of RA and 8.49' of Dec measured on
                                    // the owner's OnStep mount on 2026-09-14,
                                    // against a 1' tolerance, on a slew that had
                                    // in fact landed within 0.4". Every sequence
                                    // with a target node died on its first slew.
                                    let (expect_ra, expect_dec) = match ctx
                                        .device_ops
                                        .mount_readback_frame(mount_id, ra, dec)
                                        .await
                                    {
                                        Ok(pair) => pair,
                                        // Without the mount's frame there is no
                                        // sound comparison to make. Say so
                                        // rather than validating against the
                                        // wrong frame and calling a good slew a
                                        // failure.
                                        Err(e) => {
                                            tracing::warn!(
                                                "Slew position not validated: could not resolve the \
                                                 mount's coordinate frame: {}",
                                                e
                                            );
                                            if let Some(cb) = progress_callback {
                                                cb(100.0, format!("Arrived at RA: {:.2}h, Dec: {:.1} deg", actual_ra, actual_dec));
                                            }
                                            return InstructionResult::success_with_message(format!(
                                                "Slewed to RA: {:.4}h, Dec: {:.4} deg (not verified: {})",
                                                actual_ra, actual_dec, e
                                            ));
                                        }
                                    };

                                    if let Err(e) = validate_slew_position(
                                        expect_ra, expect_dec, actual_ra, actual_dec,
                                        SLEW_POSITION_TOLERANCE_DEG,
                                    ) {
                                        tracing::warn!("Slew position validation failed: {}", e);
                                        return InstructionResult::failure_with_recovery(
                                            &e,
                                            "SLEW_POSITION_MISMATCH",
                                        );
                                    }

                                    if let Some(cb) = progress_callback {
                                        cb(100.0, format!("Arrived at RA: {:.2}h, Dec: {:.1} deg", actual_ra, actual_dec));
                                    }
                                    InstructionResult::success_with_message(format!(
                                        "Slewed to RA: {:.4}h, Dec: {:.4} deg (verified)",
                                        actual_ra, actual_dec
                                    ))
                                }
                                Err(e) => {
                                    tracing::warn!(
                                        "Slew completed but position verification failed: {}. \
                                         Failing closed because final mount coordinates are unknown.",
                                        e
                                    );
                                    if let Some(cb) = progress_callback {
                                        cb(
                                            100.0,
                                            format!(
                                                "Slew reached command target but verification failed: {}",
                                                e
                                            ),
                                        );
                                    }
                                    InstructionResult::failure_with_recovery(
                                        format!(
                                            "Slew completed but mount position verification failed: {}",
                                            e
                                        ),
                                        "SLEW_UNVERIFIED_POSITION",
                                    )
                                }
                            }
                        }
                        Err(e) => InstructionResult::failure(e),
                    }
                }
                Err(e) => InstructionResult::failure(format!("Slew failed: {}", e)),
            }
        }
        _ = wait_for_cancellation(ctx.cancellation_token.clone()) => {
            tracing::info!("Slew cancelled, aborting...");
            if let Err(error) = ctx.device_ops.mount_abort_slew(mount_id).await {
                tracing::warn!(
                    "Slew: abort-slew failed on cancel ({}); the mount may still be moving",
                    error
                );
            }
            InstructionResult::cancelled("Slew cancelled")
        }
    }
}
