//! `guiding.rs` — moved verbatim out of the former single-file `instructions.rs`
//! (release-pass C3 mechanical split). No logic changed; private items were
//! widened to `pub(crate)` so the sibling modules and the tests module still
//! see them, and `super::*` supplies the imports the original file had.

use super::*;

// Guiding START/STOP instructions

pub(crate) struct GuiderStartupCleanupGuard {
    device_ops: SharedDeviceOps,
    armed: bool,
}

impl GuiderStartupCleanupGuard {
    fn new(device_ops: SharedDeviceOps) -> Self {
        Self {
            device_ops,
            armed: true,
        }
    }

    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for GuiderStartupCleanupGuard {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }

        let device_ops = self.device_ops.clone();
        match tokio::runtime::Handle::try_current() {
            Ok(handle) => {
                let _cleanup_task = handle.spawn(async move {
                    if let Err(error) = device_ops.guider_stop().await {
                        tracing::error!("Failed to stop guider during startup cleanup: {}", error);
                    }
                });
            }
            Err(error) => tracing::error!(
                "Could not schedule guider cleanup after dropped startup: {}",
                error
            ),
        }
    }
}

/// Why guiding did not start.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum GuidingStartError {
    /// The guider found no guide star in a fresh frame.
    NoStar(String),
    /// The guider would not start guiding.
    Start(String),
}

impl GuidingStartError {
    pub(crate) fn message(&self) -> &str {
        match self {
            Self::NoStar(message) | Self::Start(message) => message,
        }
    }
}

/// Start guiding on a star the guider has just picked from a fresh frame.
///
/// Every place the run (re)starts guiding goes through here, because the field
/// may have changed since the guider last selected a star: after a slew, a
/// center, a target change, a flip or an autofocus run. Started without it,
/// PHD2 kept the previous field's lock position and guided on nothing (owner
/// report from the rig, 2026-10-06).
pub(crate) async fn start_guiding_on_fresh_star(
    device_ops: &SharedDeviceOps,
    settle_pixels: f64,
    settle_time: f64,
    settle_timeout: f64,
) -> Result<(), GuidingStartError> {
    device_ops
        .guider_select_fresh_star()
        .await
        .map_err(GuidingStartError::NoStar)?;
    device_ops
        .guider_start(settle_pixels, settle_time, settle_timeout)
        .await
        .map_err(GuidingStartError::Start)
}

/// A mount move the run is making: a slew, a center, a sync or a flip.
///
/// A guider cannot guide through a move. Left guiding, PHD2 chases the star
/// out of its frame and reports it lost, and on the rig (2026-10-07) that loss
/// paused the run and the recovery stopped tracking under a running slew. So,
/// as N.I.N.A. does, the outermost move stops a guider that is guiding first.
/// Guiding this run had started is picked up again on a fresh star before the
/// next light frame ([`resume_guiding_after_motion`]), not straight after the
/// move: a Slew is usually followed by a Center and a StartGuiding, and each
/// of those would otherwise restart and settle it again. Guiding the run never
/// started (the previous run's, or the operator's) is stopped and left
/// stopped. While any move is in progress the guiding triggers stand down.
///
/// Call [`MountMotion::end`] when the move is over. A move dropped without it
/// (a cancelled future) still ends, from a spawned task.
pub(crate) struct MountMotion {
    trigger_state: Option<Arc<tokio::sync::RwLock<crate::triggers::TriggerState>>>,
}

impl MountMotion {
    pub(crate) async fn begin(ctx: &InstructionContext, what: &str) -> Self {
        Self::begin_with(&ctx.device_ops, ctx.trigger_state.clone(), what).await
    }

    /// [`Self::begin`] for a caller with no instruction context (the
    /// meridian flip).
    ///
    /// A guider is stopped whether or not the run keeps trigger state: a
    /// Center run outside a sequence moves the mount just the same.
    pub(crate) async fn begin_with(
        device_ops: &SharedDeviceOps,
        trigger_state: Option<Arc<tokio::sync::RwLock<crate::triggers::TriggerState>>>,
        what: &str,
    ) -> Self {
        let start = match &trigger_state {
            Some(state) => state.write().await.guiding.begin_motion(),
            None => crate::triggers::MotionStart {
                outermost: true,
                run_was_guiding: false,
            },
        };
        if start.outermost {
            stop_an_active_guider(device_ops, what).await;
            if start.run_was_guiding {
                if let Some(state) = &trigger_state {
                    state.write().await.guiding.guiding_stopped_by_motion();
                }
            }
        }
        Self { trigger_state }
    }

    pub(crate) async fn end(mut self) {
        if let Some(trigger_state) = self.trigger_state.take() {
            trigger_state.write().await.guiding.end_motion();
        }
    }
}

/// Stop the guider before the mount moves if it may move the mount itself
/// (see [`crate::device_ops::DeviceOps::guider_is_active`]). A guider whose
/// state cannot be read is stopped too: guiding through a move is the worse
/// mistake, and stopping an idle guider costs nothing. A rig with no guider
/// has nothing to stop.
pub(crate) async fn stop_an_active_guider(device_ops: &SharedDeviceOps, what: &str) {
    let active = match device_ops.guider_is_active().await {
        Ok(active) => active,
        Err(error) if crate::device_ops::is_no_guider_configured(&error) => false,
        Err(error) => {
            tracing::warn!(
                "[GUIDING] Could not read the guider's state before the {what} ({error}); \
                 stopping it so it cannot guide while the mount moves"
            );
            true
        }
    };
    if !active {
        return;
    }
    tracing::info!(
        "[GUIDING] Stopping the guider for the {what}: it cannot guide while the mount moves"
    );
    if let Err(error) = device_ops.guider_stop().await {
        tracing::warn!("[GUIDING] The guider did not stop for the {what}: {error}");
    }
}

impl Drop for MountMotion {
    fn drop(&mut self) {
        let Some(trigger_state) = self.trigger_state.take() else {
            return;
        };
        if let Ok(handle) = tokio::runtime::Handle::try_current() {
            let _end = handle.spawn(async move {
                trigger_state.write().await.guiding.end_motion();
            });
        }
    }
}

/// How long a light frame waits for guiding a move stopped to settle again.
const GUIDING_AFTER_MOTION_DEADLINE: Duration = Duration::from_secs(120);

/// Start guiding again, on a fresh star, when a move stopped the guiding this
/// run had started. Called before a light frame.
///
/// A guider that does not come back is a notice and the run images unguided,
/// unless the operator asked quality problems to stop the run; then the frame
/// fails.
pub(crate) async fn resume_guiding_after_motion(
    ctx: &InstructionContext,
) -> Option<InstructionResult> {
    let trigger_state = ctx.trigger_state.as_ref()?;
    if !trigger_state.write().await.guiding.take_resume_pending() {
        return None;
    }
    let defaults = StartGuidingConfig::default();
    tracing::info!("[GUIDING] Resuming guiding on a fresh star after the mount moved");
    let problem = match start_guiding_on_fresh_star(
        &ctx.device_ops,
        defaults.settle_pixels,
        defaults.settle_time,
        defaults.settle_timeout,
    )
    .await
    {
        Err(error) => error.message().to_string(),
        Ok(()) => {
            let deadline = tokio::time::Instant::now() + GUIDING_AFTER_MOTION_DEADLINE;
            loop {
                if let Ok(status) = ctx.device_ops.guider_get_status().await {
                    if crate::executor::guiding_is_settled(&status) {
                        trigger_state.write().await.set_guiding_enabled(true);
                        return None;
                    }
                }
                if let Some(cancelled) = ctx.check_cancelled() {
                    return Some(cancelled);
                }
                if tokio::time::Instant::now() >= deadline {
                    break;
                }
                sleep(Duration::from_secs(2)).await;
            }
            format!(
                "Guiding did not settle within {} s after the mount moved",
                GUIDING_AFTER_MOTION_DEADLINE.as_secs()
            )
        }
    };
    if ctx.stops_on_quality_problems().await {
        return Some(InstructionResult::failure(problem));
    }
    trigger_state.write().await.guiding.set_unguided(true);
    ctx.notify_quality_problem_continuing(
        "Resume guiding",
        &format!("{problem}. Imaging continues unguided."),
    );
    None
}

/// Recovery code on a StartGuiding failure that was the guider finding no star.
pub(crate) const NO_GUIDE_STAR_RECOVERY_CODE: &str = "NO_GUIDE_STAR";

fn is_no_guide_star(result: &InstructionResult) -> bool {
    result
        .data
        .as_ref()
        .and_then(|data| data.get("recovery_code"))
        .and_then(|code| code.as_str())
        == Some(NO_GUIDE_STAR_RECOVERY_CODE)
}

/// Execute start guiding - starts PHD2 guiding and waits for settle
pub async fn execute_start_guiding(
    config: &StartGuidingConfig,
    ctx: &InstructionContext,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
) -> InstructionResult {
    // This node starts guiding itself; the next light frame has nothing to
    // resume.
    if let Some(trigger_state) = &ctx.trigger_state {
        trigger_state
            .write()
            .await
            .guiding
            .set_resume_pending(false);
    }
    let result = start_guiding(config, ctx, progress_callback).await;
    // No guide star in the frame is the sky's judgment (cloud, a sparse
    // field), not a fault: by default the operator is told and the run images
    // on unguided (owner decision 2026-10-06).
    let no_star_continues = matches!(result.status, NodeStatus::Failure)
        && is_no_guide_star(&result)
        && !ctx.stops_on_quality_problems().await;
    if no_star_continues {
        if let Some(trigger_state) = &ctx.trigger_state {
            trigger_state.write().await.guiding.set_unguided(true);
        }
    } else if !ctx.imaging_unguided().await {
        return result;
    }
    match result.status {
        NodeStatus::Success => {
            // Guiding is back: the steps that need it get it again.
            if let Some(trigger_state) = &ctx.trigger_state {
                trigger_state.write().await.guiding.set_unguided(false);
            }
            result
        }
        // The run already carries on unguided because the guide star was not
        // re-acquired; a guider that still cannot start is the same problem,
        // not a reason to end the night (owner decision 2026-10-06).
        NodeStatus::Failure => {
            let reason = result
                .message
                .unwrap_or_else(|| "Guiding did not start".to_string());
            ctx.notify_quality_problem_continuing(
                "Start guiding",
                &format!("{reason} Imaging continues unguided."),
            );
            InstructionResult::success_with_message(format!(
                "Guiding did not start; imaging continues unguided ({reason})"
            ))
        }
        _ => result,
    }
}

async fn start_guiding(
    config: &StartGuidingConfig,
    ctx: &InstructionContext,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
) -> InstructionResult {
    tracing::info!(
        "Starting guiding with settle threshold {} px",
        config.settle_pixels
    );

    if let Some(cb) = progress_callback {
        cb(0.0, "Starting guiding".to_string());
    }

    if let Some(result) = ctx.check_cancelled() {
        return result;
    }

    if let Some(cb) = progress_callback {
        cb(20.0, "Connecting to guider".to_string());
    }

    // Pre-flight status read serves two purposes: surface connection
    // problems before issuing a guider_start (which has worse error
    // diagnostics), and seed the log with the pre-state so post-start
    // RMS readings can be compared to the baseline.
    match ctx.device_ops.guider_get_status().await {
        Ok(status) => {
            tracing::debug!(
                "Guider status: is_guiding={}, rms_total={:.2}",
                status.is_guiding,
                status.rms_total
            );
        }
        Err(e) => {
            // Some guiders (PHD2 in calibration) cannot answer status
            // queries but still accept Start; treat the read failure as a
            // soft warning rather than abort the sequence.
            tracing::warn!("Could not get guider status: {}", e);
        }
    }

    if let Some(result) = ctx.check_cancelled() {
        return result;
    }

    if let Some(cb) = progress_callback {
        cb(40.0, "Starting guide camera loop".to_string());
    }

    if let Some(cb) = progress_callback {
        cb(60.0, "Waiting for guiding to stabilize".to_string());
    }

    let started = if config.auto_select_star {
        start_guiding_on_fresh_star(
            &ctx.device_ops,
            config.settle_pixels,
            config.settle_time,
            config.settle_timeout,
        )
        .await
    } else {
        ctx.device_ops
            .guider_start(
                config.settle_pixels,
                config.settle_time,
                config.settle_timeout,
            )
            .await
            .map_err(GuidingStartError::Start)
    };
    match started {
        Ok(_) => {
            let mut cleanup_guard = GuiderStartupCleanupGuard::new(ctx.device_ops.clone());
            let result = async {
                // ENG-F10: Validate that guiding actually reached "guiding" state.
                // guider_start() may return Ok without the guider truly locking on.
                // Poll status with a timeout to confirm guiding is active.
                if let Some(cb) = progress_callback {
                    cb(80.0, "Verifying guiding is active".to_string());
                }

                // Why: settle_timeout is f64 seconds (UI-bounded 0..3600 typical).
                // f64 -> u64 saturates per Rust 1.45 spec; negatives clamp to 0
                // which Duration::from_secs treats as "no wait" — surfaces as an
                // immediate timeout, not a silent hang.
                let verification_timeout = Duration::from_secs(config.settle_timeout as u64);
                let poll_interval = Duration::from_secs(2);
                let deadline = tokio::time::Instant::now() + verification_timeout;
                let mut guiding_confirmed = false;

                while tokio::time::Instant::now() < deadline {
                    if let Some(result) = ctx.check_cancelled() {
                        return result;
                    }

                    match ctx.device_ops.guider_get_status().await {
                        Ok(status) if status.is_guiding => {
                            tracing::info!("Guiding confirmed active: {}", status.rms_summary());
                            guiding_confirmed = true;
                            break;
                        }
                        Ok(status) => {
                            tracing::debug!(
                                "Guiding not yet active (is_guiding={}), waiting...",
                                status.is_guiding
                            );
                        }
                        Err(e) => {
                            tracing::warn!("Guider status poll failed: {}", e);
                        }
                    }

                    sleep(poll_interval).await;
                }

                if !guiding_confirmed {
                    return InstructionResult::failure(format!(
                        "Guiding did not reach active state within {:.0}s timeout. \
                     The guider may have failed to calibrate or lock onto a star.",
                        config.settle_timeout
                    ));
                }

                // P3-7: post-start calibration quality validation. A guider can
                // report `is_guiding == true` and still be hopelessly miscalibrated
                // — wrong axis directions, mirror-flipped pulses, near-singular
                // matrix. The audit specifically flagged that bad calibrations
                // were "slipping through" the existing is_guiding poll, so this
                // gate is fail-closed (errors fail the StartGuiding instruction
                // rather than letting the night drift away silently).
                if config.validate_calibration {
                    if let Some(cb) = progress_callback {
                        cb(90.0, "Validating calibration quality".to_string());
                    }

                    // Step 1: axis geometry — fetch calibration data and check
                    // that the reported axis angles are reasonably perpendicular.
                    match ctx.device_ops.guider_get_calibration().await {
                        Ok(calib) => {
                            if let Err(reason) = validate_calibration_quality(&calib, config) {
                                // Skewed axes are a judgment about a guider that is
                                // guiding, so by default the operator is told and
                                // the run goes on (owner decision 2026-10-06). A
                                // guider that says it is not calibrated is not
                                // guiding the frames at all and keeps its failure.
                                if !calib.is_calibrated || ctx.stops_on_quality_problems().await {
                                    return InstructionResult::failure(reason);
                                }
                                ctx.notify_quality_problem_continuing("Start guiding", &reason);
                            }
                        }
                        Err(e) => {
                            // Driver doesn't expose calibration angles (some Alpaca
                            // backends): warn but don't fail — the RMS check below
                            // is the safety net.
                            tracing::warn!(
                                "Skipping calibration-axis validation: {} \
                             (driver does not report calibration data)",
                                e
                            );
                        }
                    }

                    // Step 2: post-settle RMS sanity — sample over a short window
                    // to catch calibrations whose RMS only blows up after the
                    // initial settle (drift / over-correction).
                    let rms_samples: u32 = 3;
                    let rms_interval = Duration::from_secs(2);
                    let mut max_rms: f64 = 0.0;
                    let mut sample_count: u32 = 0;
                    for _ in 0..rms_samples {
                        if let Some(result) = ctx.check_cancelled() {
                            return result;
                        }
                        sleep(rms_interval).await;
                        match ctx.device_ops.guider_get_status().await {
                            Ok(status) => {
                                max_rms = max_rms.max(status.rms_total);
                                sample_count += 1;
                            }
                            Err(e) => {
                                tracing::warn!("RMS sample failed during validation: {}", e);
                            }
                        }
                    }
                    if sample_count > 0 && max_rms > config.max_post_settle_rms_pixels {
                        let problem = format!(
                            "Post-settle guiding RMS too high: {:.2}px peak across {} sample{} \
                         over {}s (limit {:.2}px). Calibration looks poor — \
                         recalibrate the guider before continuing.",
                            max_rms,
                            sample_count,
                            if sample_count == 1 { "" } else { "s" },
                            rms_samples as u64 * rms_interval.as_secs(),
                            config.max_post_settle_rms_pixels
                        );
                        // The guider is guiding; how well is a judgment, so by
                        // default it notifies and the run goes on.
                        if ctx.stops_on_quality_problems().await {
                            return InstructionResult::failure(problem);
                        }
                        ctx.notify_quality_problem_continuing("Start guiding", &problem);
                    } else {
                        tracing::info!(
                            "Calibration validation passed: peak RMS {:.2}px over {}s window",
                            max_rms,
                            rms_samples as u64 * rms_interval.as_secs()
                        );
                    }
                }

                // Arm the GuideStarLost trigger now that guiding is confirmed
                // active. Without this the trigger's `guiding_enabled` gate stays
                // false and a lost star is never detected — the sequence would
                // silently take unguided subs until dawn. The executor poll also
                // latches this from live status, but setting it here closes the
                // window between StartGuiding completing and the next poll tick.
                if let Some(trigger_state_lock) = &ctx.trigger_state {
                    trigger_state_lock.write().await.set_guiding_enabled(true);
                }

                if let Some(cb) = progress_callback {
                    cb(100.0, "Guiding active".to_string());
                }
                InstructionResult::success_with_message("Guiding started and verified active")
            }
            .await;

            if matches!(result.status, NodeStatus::Success) {
                cleanup_guard.disarm();
                result
            } else {
                match ctx.device_ops.guider_stop().await {
                    Ok(()) => {
                        cleanup_guard.disarm();
                        if let Some(trigger_state) = &ctx.trigger_state {
                            trigger_state.write().await.set_guiding_enabled(false);
                        }
                        result
                    }
                    Err(error) => {
                        let mut result = result;
                        let prior = result
                            .message
                            .take()
                            .unwrap_or_else(|| "Guiding startup did not complete".to_string());
                        result.status = NodeStatus::Failure;
                        result.message = Some(format!(
                            "{}; CRITICAL CLEANUP FAILURE: failed to stop guider: {}",
                            prior, error
                        ));
                        result
                    }
                }
            }
        }
        Err(GuidingStartError::NoStar(e)) => InstructionResult::failure_with_recovery(
            format!("The guider found no guide star in a fresh frame: {}.", e),
            NO_GUIDE_STAR_RECOVERY_CODE,
        ),
        Err(GuidingStartError::Start(e)) => {
            InstructionResult::failure(format!("Failed to start guiding: {}", e))
        }
    }
}

/// Pure validation function over a `GuidingCalibration` snapshot. Kept out of
/// `execute_start_guiding` so it can be unit-tested without spinning up a full
/// device stack.
///
/// Returns `Err(reason)` with a user-facing message if calibration looks
/// broken; `Ok(())` if it should proceed.
pub fn validate_calibration_quality(
    calib: &crate::GuidingCalibration,
    config: &StartGuidingConfig,
) -> Result<(), String> {
    if !calib.is_calibrated {
        return Err(
            "Guider reports it is not calibrated after StartGuiding completed. \
             This usually means calibration was cancelled or failed silently."
                .to_string(),
        );
    }

    if let (Some(ra), Some(dec)) = (calib.ra_angle_deg, calib.dec_angle_deg) {
        // The axes should be ~90° apart (modulo 180°, since either axis
        // could be the "positive" direction). Compute the deviation from
        // perpendicularity in degrees in [0, 90].
        let raw_diff = (ra - dec).abs() % 180.0;
        let perpendicularity_error = (raw_diff - 90.0).abs();
        if perpendicularity_error > config.max_calibration_axis_error_deg {
            return Err(format!(
                "Calibration axes look broken: RA angle {:.1}°, Dec angle {:.1}° \
                 — off-perpendicular by {:.1}° (limit {:.1}°). \
                 The guider may have miscalibrated; recalibrate before continuing.",
                ra, dec, perpendicularity_error, config.max_calibration_axis_error_deg
            ));
        }
    }

    Ok(())
}

/// Execute stop guiding - stops PHD2 guiding
pub async fn execute_stop_guiding(
    ctx: &InstructionContext,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
) -> InstructionResult {
    tracing::info!("Stopping guiding");

    if let Some(cb) = progress_callback {
        cb(0.0, "Stopping guiding".to_string());
    }

    if let Some(result) = ctx.check_cancelled() {
        return result;
    }

    if let Some(cb) = progress_callback {
        cb(50.0, "Sending stop command".to_string());
    }

    match ctx.device_ops.guider_stop().await {
        Ok(_) => {
            // Disarm the GuideStarLost trigger on an intentional stop, so the
            // subsequent is_guiding==false does not get misread as a lost star
            // (which would request recovery for a deliberately-stopped guider).
            if let Some(trigger_state_lock) = &ctx.trigger_state {
                let mut tstate = trigger_state_lock.write().await;
                tstate.set_guiding_enabled(false);
                tstate.set_guide_star_lost(false);
                tstate.guiding.set_resume_pending(false);
            }
            if let Some(cb) = progress_callback {
                cb(100.0, "Guiding stopped".to_string());
            }
            InstructionResult::success_with_message("Guiding stopped")
        }
        Err(e) => InstructionResult::failure(format!("Failed to stop guiding: {}", e)),
    }
}
