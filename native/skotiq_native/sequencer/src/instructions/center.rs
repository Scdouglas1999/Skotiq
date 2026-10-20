//! `center.rs` — moved verbatim out of the former single-file `instructions.rs`
//! (release-pass C3 mechanical split). No logic changed; private items were
//! widened to `pub(crate)` so the sibling modules and the tests module still
//! see them, and `super::*` supplies the imports the original file had.

use super::*;

// Center instruction (Plate Solve + Sync + Slew Loop)

pub(crate) const CENTER_CORRECTION_SLEW_START_TIMEOUT: Duration = Duration::from_secs(5);
pub(crate) const CENTER_CORRECTION_SLEW_COMPLETE_TIMEOUT: Duration = Duration::from_secs(300);
pub(crate) const CENTER_CORRECTION_SLEW_POLL_INTERVAL: Duration = Duration::from_millis(500);

/// Wait for an asynchronous correction slew to first report motion and then
/// report idle. The startup phase is essential for ASCOM/Alpaca/INDI drivers
/// that acknowledge the command before their `Slewing` property changes.
pub(crate) async fn wait_for_centering_correction_slew(
    mount_id: &str,
    ctx: &InstructionContext,
) -> Result<(), InstructionResult> {
    let start_deadline = tokio::time::Instant::now() + CENTER_CORRECTION_SLEW_START_TIMEOUT;
    loop {
        if let Some(result) = ctx.check_cancelled() {
            if let Err(error) = ctx.device_ops.mount_abort_slew(mount_id).await {
                tracing::warn!(
                    "Centering: abort-slew failed while cancelling before the correction slew \
                     started ({}); the mount may still be moving",
                    error
                );
            }
            return Err(result);
        }

        match ctx.device_ops.mount_is_slewing(mount_id).await {
            Ok(true) => break,
            Ok(false) => {}
            Err(error) => tracing::warn!(
                "Centering: slew-state read failed while waiting for startup ({}); retrying",
                error
            ),
        }

        if tokio::time::Instant::now() >= start_deadline {
            if let Err(error) = ctx.device_ops.mount_abort_slew(mount_id).await {
                tracing::warn!(
                    "Centering: abort-slew failed after the correction slew never reported \
                     startup ({}); the mount may still be moving",
                    error
                );
            }
            return Err(InstructionResult::failure(format!(
                "Centering correction slew did not report startup within {}s",
                CENTER_CORRECTION_SLEW_START_TIMEOUT.as_secs()
            )));
        }
        sleep(CENTER_CORRECTION_SLEW_POLL_INTERVAL).await;
    }

    let complete_deadline = tokio::time::Instant::now() + CENTER_CORRECTION_SLEW_COMPLETE_TIMEOUT;
    loop {
        if let Some(result) = ctx.check_cancelled() {
            if let Err(error) = ctx.device_ops.mount_abort_slew(mount_id).await {
                tracing::warn!(
                    "Centering: abort-slew failed while cancelling the in-progress correction \
                     slew ({}); the mount may still be moving",
                    error
                );
            }
            return Err(result);
        }

        match ctx.device_ops.mount_is_slewing(mount_id).await {
            Ok(false) => return Ok(()),
            Ok(true) => {}
            Err(error) => tracing::warn!(
                "Centering: slew-state read failed while waiting for completion ({}); retrying",
                error
            ),
        }

        if tokio::time::Instant::now() >= complete_deadline {
            if let Err(error) = ctx.device_ops.mount_abort_slew(mount_id).await {
                tracing::warn!(
                    "Centering: abort-slew failed after the correction slew overran its \
                     completion timeout ({}); the mount may still be moving",
                    error
                );
            }
            return Err(InstructionResult::failure(format!(
                "Centering correction slew did not complete within {}s",
                CENTER_CORRECTION_SLEW_COMPLETE_TIMEOUT.as_secs()
            )));
        }
        sleep(CENTER_CORRECTION_SLEW_POLL_INTERVAL).await;
    }
}

/// Execute a center instruction (plate solve + sync + slew loop)
pub async fn execute_center(
    config: &CenterConfig,
    ctx: &InstructionContext,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
) -> InstructionResult {
    // Capture, solve, sync and correction slews are one move of the mount.
    let motion = MountMotion::begin(ctx, "center").await;
    let result = center(config, ctx, progress_callback).await;
    motion.end().await;
    result
}

async fn center(
    config: &CenterConfig,
    ctx: &InstructionContext,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
) -> InstructionResult {
    let mount_id = match ctx.mount_id() {
        Ok(id) => id.to_string(),
        Err(e) => return e,
    };
    let camera_id = match ctx.camera_id() {
        Ok(id) => id.to_string(),
        Err(e) => return e,
    };

    let (target_ra_hours, target_dec) = if config.use_target_coords {
        match (ctx.target_ra, ctx.target_dec) {
            (Some(ra), Some(dec)) => (ra, dec),
            _ => return InstructionResult::failure("No target coordinates available"),
        }
    } else if let (Some(ra), Some(dec)) = (config.custom_ra, config.custom_dec) {
        (ra, dec)
    } else {
        match ctx.device_ops.mount_get_coordinates(&mount_id).await {
            Ok((ra, dec)) => (ra, dec),
            Err(e) => {
                return InstructionResult::failure(format!(
                    "Custom center coordinates were not provided and current mount coordinates could not be read: {}",
                    e
                ))
            }
        }
    };

    // Same placeholder gate as `execute_slew`: Center slews too, and it is the
    // node an automated sequence usually uses instead of a bare Slew, so
    // leaving it ungated would leave the defect reachable by the more common
    // authoring pattern. Custom / mount-current coordinates are the operator's
    // own numbers and are never gated.
    if config.use_target_coords {
        if let Some(reason) = unset_target_pointing_reason(
            ctx.target_name.as_deref(),
            target_ra_hours,
            target_dec,
            "center on target",
        ) {
            tracing::warn!("{reason}");
            return InstructionResult::failure_with_recovery(reason, UNSET_TARGET_RECOVERY_CODE);
        }
    }

    let target_ra_deg = target_ra_hours * 15.0;

    tracing::info!(
        "Centering on RA: {:.4}°, Dec: {:.4}° (accuracy: {:.1}\")",
        target_ra_deg,
        target_dec,
        config.accuracy_arcsec
    );

    if let Some(cb) = progress_callback {
        cb(
            0.0,
            format!("Centering (target: {:.1}\")", config.accuracy_arcsec),
        );
    }

    for attempt in 1..=config.max_attempts {
        if let Some(result) = ctx.check_cancelled() {
            return result;
        }

        // Why: attempt is a u32 loop counter bounded by max_attempts (also u32);
        // both lossless to f64.
        let attempt_progress = (f64::from(attempt - 1) / f64::from(config.max_attempts)) * 100.0;
        tracing::info!("Center attempt {}/{}", attempt, config.max_attempts);

        if let Some(cb) = progress_callback {
            cb(
                attempt_progress,
                format!("Attempt {}/{}: Capturing...", attempt, config.max_attempts),
            );
        }

        // A transient camera fault retries the capture under the run's camera
        // retry budget; it is not a centering attempt, which is about the
        // solve and the pointing.
        let mut camera_retries_done = 0u32;
        let image_data = loop {
            let result = tokio::select! {
                // Full resolution + 1x1 binning gives the plate solver the highest
                // possible star count; binning would reduce SNR enough to fail on
                // sparse fields.
                result = ctx.device_ops.camera_start_exposure(
                    &camera_id,
                    config.exposure_duration,
                    None,
                    None,
                    1, 1,
                ) => result,
                _ = wait_for_cancellation(ctx.cancellation_token.clone()) => {
                    tracing::info!("Center cancelled during exposure, aborting...");
                    if let Err(error) = ctx.device_ops.camera_abort_exposure(&camera_id).await {
                        tracing::warn!(
                            "Center: abort-exposure failed on cancel ({}); the camera may still be \
                             integrating and the next instruction can find it busy",
                            error
                        );
                    }
                    return InstructionResult::cancelled("Center cancelled");
                }
            };
            match result {
                Ok(data) => {
                    tracing::info!(
                        "[SEQ] Exposure completed: {}x{} image ({} pixels)",
                        data.width,
                        data.height,
                        data.data.len()
                    );
                    break data;
                }
                Err(e) => match after_failed_attempt(
                    ctx,
                    RetriedDevice::Camera,
                    camera_retries_done,
                    &e,
                    &format!("on the centering frame (attempt {})", attempt),
                )
                .await
                {
                    RetryOutcome::Retry => camera_retries_done += 1,
                    RetryOutcome::Cancelled => {
                        return InstructionResult::cancelled("Center cancelled")
                    }
                    RetryOutcome::GiveUp(message) => {
                        return InstructionResult::failure(format!(
                            "Failed to capture image: {}",
                            message
                        ))
                    }
                },
            }
        };

        // Hard cap on the solver call: a hung solver process (stalled IO,
        // bad catalog, zombie child) would otherwise block this select
        // indefinitely — cancellation is the only other exit, and an
        // unattended night never presses cancel. Treated exactly like a
        // failed solve so the attempt loop's retry applies.
        const PLATE_SOLVE_TIMEOUT: Duration = Duration::from_secs(180);
        let solve_result = tokio::select! {
            result = tokio::time::timeout(
                PLATE_SOLVE_TIMEOUT,
                ctx.device_ops.plate_solve(
                    &image_data,
                    Some(target_ra_deg),
                    Some(target_dec),
                    None,
                ),
            ) => {
                match result {
                    Ok(Ok(result)) if result.success => result,
                    Ok(Ok(_)) => {
                        tracing::warn!("Plate solve failed on attempt {}", attempt);
                        continue;
                    }
                    Ok(Err(e)) => {
                        tracing::warn!("Plate solve error on attempt {}: {}", attempt, e);
                        continue;
                    }
                    Err(_) => {
                        tracing::warn!(
                            "Plate solve timed out after {}s on attempt {}",
                            PLATE_SOLVE_TIMEOUT.as_secs(),
                            attempt
                        );
                        continue;
                    }
                }
            }
            _ = wait_for_cancellation(ctx.cancellation_token.clone()) => {
                tracing::info!("Center cancelled during plate solve");
                return InstructionResult::cancelled("Center cancelled");
            }
        };

        let separation_arcsec = calculate_separation_arcsec(
            target_ra_deg,
            target_dec,
            solve_result.ra_degrees,
            solve_result.dec_degrees,
        );
        tracing::info!("Current separation: {:.1}\" from target", separation_arcsec);

        // Feeding the solve back into trigger state is what enables the
        // DriftLimit trigger to detect cumulative drift across exposures
        // without re-solving on every frame -- but only the solve centering
        // ends on. An attempt that is about to be corrected is not drift: the
        // first solve of a target is routinely degrees away, and publishing it
        // fired DriftLimit's own recenter in the middle of this one, which then
        // exposed over this loop's next frame and failed the node with "No
        // exposure is available to download" (found by the simulator soak).
        if separation_arcsec <= config.accuracy_arcsec {
            if let Some(trigger_state_lock) = &ctx.trigger_state {
                let mut trigger_state = trigger_state_lock.write().await;
                trigger_state.update_plate_solve(
                    solve_result.ra_degrees,
                    solve_result.dec_degrees,
                    solve_result.pixel_scale,
                );
                tracing::debug!(
                    "Updated trigger state with plate solve: RA={:.4}°, Dec={:.4}°, scale={:.2}\"/px",
                    solve_result.ra_degrees,
                    solve_result.dec_degrees,
                    solve_result.pixel_scale
                );
            }
        }

        if let Some(cb) = progress_callback {
            cb(
                // Why: config.max_attempts is u32; lossless to f64.
                attempt_progress + 50.0 / f64::from(config.max_attempts),
                format!(
                    "Attempt {}/{}: {:.1}\" off",
                    attempt, config.max_attempts, separation_arcsec
                ),
            );
        }

        if separation_arcsec <= config.accuracy_arcsec {
            if let Some(cb) = progress_callback {
                cb(95.0, format!("Centered: {:.1}\"", separation_arcsec));
            }

            // Apply the target's framing rotation as part of centering. On a
            // rig with a rotator, imaging at the wrong camera angle breaks
            // mosaics / framing, so the rotator must be moved to the target
            // mechanical angle and VERIFIED before we declare the target
            // centered. If the target specifies no rotation, or no rotator is
            // configured, this is a clean skip (not an error).
            if let Err(rotate_err) = apply_center_rotation(ctx, attempt, progress_callback).await {
                return rotate_err;
            }

            if let Some(cb) = progress_callback {
                cb(100.0, format!("Centered: {:.1}\"", separation_arcsec));
            }
            return InstructionResult::success_with_message(format!(
                "Centered within {:.1}\" after {} attempt{}",
                separation_arcsec,
                attempt,
                if attempt == 1 { "" } else { "s" }
            ));
        }

        // Sync corrects the mount's internal model to the plate-solved truth
        // before re-slewing; without it, the next slew would land at the same
        // wrong spot (the mount thinks it's already at target).
        if let Err(e) = ctx
            .device_ops
            .mount_sync(
                &mount_id,
                solve_result.ra_degrees / 15.0,
                solve_result.dec_degrees,
            )
            .await
        {
            return InstructionResult::failure(format!(
                "Mount sync failed during centering on attempt {}: {}",
                attempt, e
            ));
        }

        tracing::info!("Slewing to correct position...");
        if let Some(cb) = progress_callback {
            cb(
                // Why: config.max_attempts is u32; lossless to f64.
                attempt_progress + 75.0 / f64::from(config.max_attempts),
                format!("Attempt {}/{}: Correcting...", attempt, config.max_attempts),
            );
        }

        tokio::select! {
            result = ctx.device_ops.mount_slew_to_coordinates(&mount_id, target_ra_deg / 15.0, target_dec) => {
                if let Err(e) = result {
                    return InstructionResult::failure(format!(
                        "Correction slew command failed during centering on attempt {}: {}",
                        attempt, e
                    ));
                }
            }
            _ = wait_for_cancellation(ctx.cancellation_token.clone()) => {
                tracing::info!("Center cancelled during correction slew, aborting...");
                if let Err(error) = ctx.device_ops.mount_abort_slew(&mount_id).await {
                    tracing::warn!(
                        "Center: abort-slew failed while cancelling the correction slew ({}); \
                         the mount may still be moving",
                        error
                    );
                }
                return InstructionResult::cancelled("Center cancelled");
            }
        }

        // Wait for the correction slew to ACTUALLY FINISH before settling and
        // re-imaging. The slew command above returns as soon as it is issued
        // (ASCOM/Alpaca async slews, INDI set-coords) — it does NOT block until
        // the mount stops. Without this poll the next plate-solve exposure
        // fires ~2 s later while the mount is still moving (real offsets take
        // 10-60+ s), so the frame is motion-blurred / off-target, the solve
        // mis-corrects or fails, and the loop burns all attempts without
        // converging. Mirrors the meridian-flip slew-completion poll.
        if let Err(result) = wait_for_centering_correction_slew(&mount_id, ctx).await {
            return result;
        }

        // 2 s post-slew settle absorbs mount oscillation before the next
        // plate-solve exposure; without it, the solve sees motion-blurred
        // stars and the iteration produces a noisy correction vector.
        sleep(Duration::from_secs(2)).await;
    }

    InstructionResult {
        data: Some(serde_json::json!({ CENTER_NOT_CONVERGED_KEY: true })),
        ..InstructionResult::failure(format!(
            "Failed to center within {:.1}\" after {} attempts",
            config.accuracy_arcsec, config.max_attempts
        ))
    }
}

/// Marks the result of a centering loop that ran out of attempts without
/// solving and converging — every frame was captured and every correction slew
/// completed, but the solver found no solution or the pointing stayed outside
/// the accuracy asked for. Callers that carry on through that (a Center node,
/// a post-flip recenter) tell it apart from a device error by this key.
pub(crate) const CENTER_NOT_CONVERGED_KEY: &str = "center_not_converged";

/// Whether `result` is a centering loop that ran out of attempts, as opposed to
/// a capture, mount or rotator error, a missing target or a cancel.
pub(crate) fn center_did_not_converge(result: &InstructionResult) -> bool {
    result.status == NodeStatus::Failure
        && result
            .data
            .as_ref()
            .and_then(|data| data.get(CENTER_NOT_CONVERGED_KEY))
            .and_then(serde_json::Value::as_bool)
            == Some(true)
}

/// Apply the active target's framing rotation during centering.
///
/// Returns `Ok(())` (leaving the rotator untouched — both are clean, expected
/// skips, NOT errors) when:
/// * the target specifies no rotation (`ctx.target_rotation` is `None`), or
/// * no rotator device is configured (`ctx.rotator_id` is `None`).
///
/// When BOTH a target rotation and a rotator are present, the rotator is moved
/// to the target mechanical angle and the achieved angle is verified within
/// `ROTATOR_TOLERANCE_DEG`. Any move/read error or arrival timeout fails closed
/// via the returned `Err(InstructionResult)` so the caller aborts centering
/// rather than imaging at the wrong angle.
pub(crate) async fn apply_center_rotation(
    ctx: &InstructionContext,
    attempt: u32,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
) -> Result<(), InstructionResult> {
    let Some(target_rotation) = ctx.target_rotation else {
        // No framing rotation requested for this target — leave the rotator
        // wherever it is.
        return Ok(());
    };
    if !target_rotation.is_finite() {
        return Err(InstructionResult::failure(format!(
            "Target framing rotation is not a finite angle ({})",
            target_rotation
        )));
    }
    let Some(rotator_id) = ctx.rotator_id.as_deref() else {
        // Target wants a specific angle but no rotator is configured. This is a
        // clean skip: the rig physically cannot rotate, so centering succeeds
        // on position alone (matches the behaviour of a non-rotator rig).
        tracing::info!(
            "Center: target requests rotation {:.1}° but no rotator is configured; \
             skipping rotation",
            target_rotation
        );
        return Ok(());
    };

    tracing::info!(
        "Center: applying target framing rotation {:.1}° on attempt {}",
        target_rotation,
        attempt
    );
    if let Some(cb) = progress_callback {
        cb(96.0, format!("Rotating to {:.1}°", target_rotation));
    }

    let achieved = rotator_move_to_verified(ctx, rotator_id, target_rotation, |pct, msg| {
        if let Some(cb) = progress_callback {
            // Map the rotator's 0-100 progress into the 96-99 tail of the
            // centering bar so the final "Centered" cb keeps 100.
            cb(96.0 + (pct / 100.0) * 3.0, msg);
        }
    })
    .await?;

    tracing::info!(
        "Center: rotator verified at {:.1}° (target {:.1}°)",
        achieved,
        target_rotation
    );
    Ok(())
}

/// N.I.N.A.-style pre-exposure meridian-flip gate.
///
/// When a MinutesPastMeridian flip trigger is armed and the next frame would
/// still be exposing at the moment the trigger fires, hold here (polling the
/// shared trigger state) until the trigger-driven flip completes, instead of
/// starting a frame the flip slew would ruin mid-exposure.
///
/// Returns `None` to proceed with the exposure, `Some(cancelled)` when the
/// sequence was cancelled while holding. Bounded: gives up with a loud
/// warning after [`MERIDIAN_GATE_MAX_WAIT`] so a failed or disabled flip can
/// never deadlock the night — the post-crossing trigger remains the backstop
/// exactly as before this gate existed.
pub(crate) async fn wait_for_meridian_flip_window(
    ctx: &InstructionContext,
    exposure_secs: f64,
    control: &BurstControl<'_>,
) -> Option<InstructionResult> {
    /// Margin between predicted frame end and predicted trigger fire.
    const SAFETY_MARGIN_SECS: f64 = 30.0;
    const POLL_INTERVAL: Duration = Duration::from_secs(5);
    const MERIDIAN_GATE_MAX_WAIT: Duration = Duration::from_secs(30 * 60);
    /// How far PAST its predicted fire time a flip may be and still be
    /// treated as "about to happen".
    ///
    /// Sized to outlast a whole flip rather than to be tight: a flip plus
    /// re-centre takes 5-8 minutes, and the retry ladder
    /// (`retry_delays_secs` defaults to 30/60/120s on top of the attempts)
    /// can stretch that towards a quarter of an hour. Inside that window
    /// "due and not yet flipped" is indistinguishable from "a flip is
    /// running right now", so the gate keeps waiting. Beyond it the flip
    /// cannot still be in progress — the trigger monitor re-evaluates every
    /// second, so one that was ever going to be requested was requested long
    /// ago.
    const OVERDUE_GRACE_SECS: f64 = 15.0 * 60.0;

    let lock = ctx.trigger_state.as_ref()?;
    let started = tokio::time::Instant::now();
    let mut announced = false;
    // Kept apart from `announced`, which scopes the escape hatches below to
    // gate entry; a hold for a request must not switch them off.
    let mut announced_request = false;
    loop {
        if let Some(result) = ctx.check_cancelled() {
            return Some(result);
        }
        let (
            threshold_min,
            polled_ha,
            flipped,
            pier,
            trigger_has_target,
            mount_parked,
            mount_following,
            flip_requested,
        ) = {
            let state = lock.read().await;
            (
                state.meridian_flip_minutes_past,
                state.current_hour_angle,
                state.has_flipped_this_target,
                state.pier_side,
                state.target_ra.is_some() && state.target_dec.is_some(),
                state.mount_parked == Some(true),
                // The trigger's other precondition: it will not flip a mount
                // that is parked or not tracking (see `TriggerType::MeridianFlip`
                // in `Trigger::check`), so holding for it there waits out the
                // whole bound on every frame.
                state.mount_parked != Some(true) && state.mount_is_tracking != Some(false),
                state.meridian_flip_requested && state.manual_flip_refusal().is_none(),
            )
        };
        // An operator's flip request fires the trigger on its next tick, and
        // the flip then takes the imaging train. Hold here until the request
        // has been taken up, so this frame does not take the train first and
        // put the flip back by a whole exposure. Any trigger method, so this
        // is checked before the MinutesPastMeridian-only prediction below.
        if flip_requested {
            if started.elapsed() > MERIDIAN_GATE_MAX_WAIT {
                let message = format!(
                    "Held the next exposure {}s for the requested meridian flip without it \
                     starting; proceeding with the exposure.",
                    started.elapsed().as_secs()
                );
                tracing::warn!("{}", message);
                control.report(&message);
                return None;
            }
            if !announced_request {
                let message = format!(
                    "Holding the next {exposure_secs:.0}s exposure for the requested meridian flip."
                );
                tracing::info!("{}", message);
                control.report(&message);
                announced_request = true;
            }
            tokio::select! {
                _ = sleep(Duration::from_millis(500)) => {}
                _ = wait_for_cancellation(ctx.cancellation_token.clone()) => {
                    return Some(InstructionResult::cancelled("Exposure cancelled"));
                }
            }
            continue;
        }
        // No MinutesPastMeridian trigger armed / already flipped — nothing
        // predictable to gate on.
        let threshold_min = threshold_min?;
        if flipped {
            return None;
        }
        // Mirror the trigger's own precondition: a flip is meaningless without
        // a target, and the trigger returns false outright in that case.
        if !trigger_has_target {
            return None;
        }
        if !mount_following && !announced {
            let message = format!(
                "Not holding the next {exposure_secs:.0}s exposure for a meridian flip: the \
                 mount is {}, and the flip trigger does not flip a mount in that state.",
                if mount_parked {
                    "parked"
                } else {
                    "not tracking"
                }
            );
            tracing::warn!("{}", message);
            control.report(&message);
            return None;
        }
        let ha = current_target_hour_angle(ctx).or(polled_ha)?;
        // The trigger's own pre-flip-side test, called rather than re-derived:
        // a target east of the meridian has no flip to be interrupted by, and
        // pier East is the post-flip side where the trigger can no longer fire.
        //
        // Testing only the East case holds a target EAST of the meridian
        // (negative HA) with unreported pier side: `fire_in_secs` comes out
        // non-positive from a stale HA left over by an earlier run — the
        // monitor only runs while a sequence is executing, so the first frame
        // of a run reads the previous run's value — and every light frame then
        // blocks for the gate's full bound on a trigger that cannot fire.
        if !crate::triggers::on_pre_flip_side(ha, pier) {
            return None;
        }

        let fire_in_secs = (threshold_min - ha * 60.0) * 60.0;
        if fire_in_secs > exposure_secs + SAFETY_MARGIN_SECS {
            return None; // frame finishes comfortably before the flip fires
        }
        // A flip that is hours OVERDUE is not a flip that is imminent.
        //
        // `fire_in_secs` goes arbitrarily negative once the target is past
        // the meridian — at HA +9.9h with a 5-minute threshold it is about
        // -35_000 — and the announcement clamps the number to zero, so holding
        // on every negative value tells the operator "the flip fires in ~0s"
        // about a flip that has been due for the best part of a day. A target
        // hours west of the meridian is routine (a run that starts on a setting
        // target, or a mount whose reported pointing the flip trigger reads
        // differently from the target's own coordinates), and the trigger in that
        // state never fires, so nothing releases the gate: each frame pays the
        // full MERIDIAN_GATE_MAX_WAIT.
        //
        // `announced` is only ever set once this call has decided to hold, so
        // testing it here scopes the escape hatch to gate ENTRY. A hold that
        // began legitimately (the flip was imminent, then a flip started
        // running) is still governed by MERIDIAN_GATE_MAX_WAIT and is not cut
        // short by the target drifting further past the meridian while we
        // wait.
        if !announced && fire_in_secs < -OVERDUE_GRACE_SECS {
            let message = format!(
                "Meridian flip is overdue by {:.0} min and has not fired (hour angle \
                 {:+.2}h, threshold {:.0} min past meridian) — proceeding with the next \
                 {:.0}s exposure instead of waiting for it. Check that the flip trigger \
                 is enabled and that the mount reports its position.",
                -fire_in_secs / 60.0,
                ha,
                threshold_min,
                exposure_secs
            );
            tracing::warn!("{}", message);
            control.report(&message);
            return None;
        }
        // The gate does not perform the flip — it waits for the TRIGGER to
        // request one, and holding is only meaningful while the trigger could
        // still fire. Both now read the same quantity (the TARGET's hour
        // angle: this gate computes it directly, the trigger reads the copy
        // the executor's monitor refreshes each tick), so the only remaining
        // way for the trigger to be unable to fire is for the monitor not to
        // have published a value yet — no target stamped into the trigger
        // state, or no observing site.
        //
        // That gap used to be a permanent disagreement rather than a startup
        // race: the trigger evaluated the MOUNT's hour angle. Live repro
        // (headless Linux build, sim camera + sim mount, site 40N 42E, target
        // pinned 12 min west of the meridian, threshold 5 min): the run
        // reached 1/3 and reported
        //   Waiting for the meridian flip before the next 2s exposure: the
        //   flip became due 423s ago (hour angle +0.20h, threshold 5 min past
        //   meridian) and would interrupt the frame
        // then sat there, because the mount was never slewed to the target so
        // its own hour angle never made the trigger fire. The overdue escape
        // hatch above does not catch this: at 12 minutes past a 5-minute
        // threshold the flip is only 7 minutes late, well inside
        // OVERDUE_GRACE_SECS, so every frame paid the full 30-minute bound.
        //
        // Checked at gate ENTRY only (`!announced`) so a hold that began
        // legitimately still runs to MERIDIAN_GATE_MAX_WAIT while a flip is
        // actually in progress.
        let trigger_can_fire = polled_ha.is_some_and(|published_ha| published_ha > 0.0);
        if !announced && !trigger_can_fire {
            let observed = match polled_ha {
                Some(published_ha) => format!("evaluating hour angle {published_ha:+.2}h"),
                None => "has no hour angle for the target yet".to_string(),
            };
            let message = format!(
                "Not holding the next {exposure_secs:.0}s exposure for a meridian flip: the \
                 target is {ha:+.2}h past the meridian but the flip trigger is {observed}, so \
                 it cannot fire. Exposing instead of waiting for a flip that will not happen — \
                 check that the observing site is set and a target is active."
            );
            tracing::warn!("{}", message);
            control.report(&message);
            return None;
        }
        if started.elapsed() > MERIDIAN_GATE_MAX_WAIT {
            let message = format!(
                "Meridian gate held the next exposure for {}s without observing a \
                 completed flip — proceeding anyway (the flip trigger remains the backstop)",
                started.elapsed().as_secs()
            );
            tracing::warn!("{}", message);
            control.report(&message);
            return None;
        }
        if !announced {
            // Say which side of the fire time we are on. Clamping a negative
            // `fire_in_secs` to zero reported "fires in ~0s" for a flip that
            // was already due, which reads as "any second now" when the real
            // state is "should have happened and has not".
            let when = if fire_in_secs >= 0.0 {
                format!("fires in ~{:.0}s", fire_in_secs)
            } else {
                format!("became due {:.0}s ago", -fire_in_secs)
            };
            let message = format!(
                "Waiting for the meridian flip before the next {:.0}s exposure: the flip \
                 {} (hour angle {:+.2}h, threshold {:.0} min past meridian) \
                 and would interrupt the frame",
                exposure_secs, when, ha, threshold_min
            );
            tracing::info!("{}", message);
            control.report(&message);
            announced = true;
        }
        tokio::select! {
            _ = sleep(POLL_INTERVAL) => {}
            _ = wait_for_cancellation(ctx.cancellation_token.clone()) => {
                return Some(InstructionResult::cancelled("Exposure cancelled"));
            }
        }
    }
}

/// Hour angle of the ACTIVE TARGET right now, in hours, normalized to
/// [-12, +12]. Negative is east of the meridian.
///
/// Recomputed from this instruction's own target RA and observer longitude
/// rather than read off `TriggerState::current_hour_angle`, which the
/// executor's monitor loop writes only while a sequence is running and does
/// not invalidate between runs. This is fresh by construction. Falls back to
/// the published value when the target or the site is unknown here — the two
/// are the same quantity, computed from the same target coordinates.
pub(crate) fn current_target_hour_angle(ctx: &InstructionContext) -> Option<f64> {
    let longitude = ctx.longitude?;
    let now = chrono::Utc::now();
    // J2000 target, of-date LST: precess first, as the trigger monitor does.
    // Without a declination, fall back to the trigger monitor's published
    // value, which is computed that way.
    let (ra_hours, _) = crate::meridian::target_of_date(ctx.target_ra?, ctx.target_dec?, now);
    let jd = crate::meridian::julian_day(&now);
    let lst = crate::meridian::local_sidereal_time(jd, longitude);
    Some(crate::meridian::hour_angle(ra_hours, lst))
}

/// Calculate separation between two coordinates in arcseconds
pub(crate) fn calculate_separation_arcsec(
    ra1_deg: f64,
    dec1_deg: f64,
    ra2_deg: f64,
    dec2_deg: f64,
) -> f64 {
    let dec1_rad = dec1_deg.to_radians();
    let dec2_rad = dec2_deg.to_radians();
    let delta_ra = (ra2_deg - ra1_deg).to_radians();
    let delta_dec = (dec2_deg - dec1_deg).to_radians();

    // Haversine (not law-of-cosines) — at sub-arcsecond centering tolerances
    // the LoC formula loses precision near zero separation due to acos(~1.0)
    // rounding to 1.0 exactly.
    let a = (delta_dec / 2.0).sin().powi(2)
        + dec1_rad.cos() * dec2_rad.cos() * (delta_ra / 2.0).sin().powi(2);
    let c = 2.0 * a.sqrt().asin();

    c.to_degrees() * 3600.0
}
