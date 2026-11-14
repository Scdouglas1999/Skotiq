use super::*;

// Meridian flip instruction

/// Execute a meridian flip via the canonical [`MeridianFlipExecutor`].
///
/// The single source of truth lives in `crate::meridian_flip_executor`; this
/// wrapper builds a [`FlipContext`] from the instruction context and calls
/// `executor.execute()`. The cancellation token, the trigger-state flip
/// bookkeeping, the cover-state pre-check and the configurable autofocus
/// parameters all flow through the FlipContext, so timeouts, the post-flip
/// altitude check, settle behaviour, plate-solve failure handling, pier-side
/// telemetry fallback and abort-during-flip semantics cannot diverge from the
/// executor's.
pub async fn execute_meridian_flip(
    config: &MeridianFlipConfig,
    ctx: &InstructionContext,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
) -> InstructionResult {
    execute_meridian_flip_with_autofocus(config, None, ctx, progress_callback).await
}

/// Execute a meridian flip with an optional operator-tuned autofocus profile
/// for the post-flip refocus step.
///
/// The compatibility wrapper above retains the existing direct-call API.
/// Sequence executors that have resolved a real equipment-profile autofocus
/// config must call this entry point so filter, gain/offset, step, exposure,
/// and backlash settings reach `FlipContext` intact.
pub async fn execute_meridian_flip_with_autofocus(
    config: &MeridianFlipConfig,
    autofocus_config: Option<&AutofocusConfig>,
    ctx: &InstructionContext,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
) -> InstructionResult {
    // The step reports a 0%/100% bracket through its own progress callback;
    // the flip's per-step detail goes to the log and its verdict and retries
    // to the run's event feed.
    if let Some(cb) = progress_callback {
        cb(0.0, "Starting meridian flip".to_string());
    }

    let mount_id = match ctx.mount_id() {
        Ok(id) => id.to_string(),
        Err(e) => return e,
    };

    let target_ra = match ctx.target_ra {
        Some(ra) => ra,
        None => return InstructionResult::failure("No target RA available for meridian flip"),
    };

    let target_dec = match ctx.target_dec {
        Some(dec) => dec,
        None => {
            return InstructionResult::failure("No target declination available for meridian flip")
        }
    };

    // Pre-flight: do not invoke the executor when no flip is actually needed
    // — its altitude/cover/pier-side preflight assume the flip is required
    // and would otherwise emit confusing "Aborted" events for routine
    // pre-meridian sequence runs.
    let lon = match ctx.run.rig.longitude {
        Some(lon) => lon,
        None => {
            return InstructionResult::failure(
                "Observer location not configured. Meridian flip requires location for calculations."
            );
        }
    };

    let now = chrono::Utc::now();
    // The target is J2000 and LST is of date: precess before asking about the
    // meridian, or a flip inside the ~1.3 min precession window (2026) slews
    // without changing pier side. The flip itself still gets the J2000 target
    // below; the device layer precesses what it sends.
    let (target_ra_of_date, _) = crate::meridian::target_of_date(target_ra, target_dec, now);
    let should_flip =
        crate::meridian::should_flip_now(target_ra_of_date, lon, now, config.minutes_past_meridian);
    if !should_flip {
        let ha = crate::meridian::hour_angle(
            target_ra_of_date,
            crate::meridian::local_sidereal_time(crate::meridian::julian_day(&now), lon),
        );
        tracing::info!(
            "Meridian flip not yet required (HA={:.4}h, threshold={:.2} min)",
            ha,
            config.minutes_past_meridian
        );
        if let Some(cb) = progress_callback {
            cb(100.0, "Flip not yet required".to_string());
        }
        return InstructionResult::success_with_message("Meridian flip not yet required");
    }

    if let Some(reason) = flip_not_for_this_mount(ctx, &mount_id, target_ra_of_date, lon, now).await
    {
        tracing::info!("[MERIDIAN] Meridian flip step not run: {reason}");
        if let Some(cb) = progress_callback {
            cb(100.0, format!("Flip not needed: {reason}"));
        }
        return InstructionResult::success_with_message(format!(
            "Meridian flip not needed: {reason}"
        ));
    }

    let Some(flip_ctx) =
        crate::meridian_flip_executor::FlipContext::for_instruction(ctx, autofocus_config.cloned())
            .await
    else {
        return InstructionResult::failure("No target coordinates available for meridian flip");
    };
    let mut flip_executor = crate::meridian_flip_executor::MeridianFlipExecutor::in_run(
        config.clone(),
        ctx.run.clone(),
    );

    match flip_executor.execute(&flip_ctx).await {
        crate::meridian_flip_executor::FlipResult::Success {
            new_pier_side,
            duration_secs,
        } => {
            tracing::info!(
                "Meridian flip complete (pier side: {:?}, took {:.1}s)",
                new_pier_side,
                duration_secs
            );
            if let Some(cb) = progress_callback {
                cb(100.0, "Flip complete".to_string());
            }
            // mark_flip_performed is invoked inside the executor on
            // success when trigger_state is supplied; the instruction-path
            // populates trigger_state via the FlipContext above so the same
            // bookkeeping happens regardless of caller.
            InstructionResult::success_with_message(format!(
                "Meridian flip completed successfully (pier side: {:?})",
                new_pier_side
            ))
        }
        crate::meridian_flip_executor::FlipResult::Failed {
            error,
            action_taken,
        } => InstructionResult::failure_because(
            format!(
                "Meridian flip failed: {} (action taken: {:?})",
                error, action_taken
            ),
            Setback::FlipFailed,
        ),
        crate::meridian_flip_executor::FlipResult::Aborted { reason } => {
            InstructionResult::cancelled(reason)
        }
    }
}

/// Why a flip step must leave the mount where it is, or `None` when it may
/// flip. A flip step can run long after imaging stopped (after the plan parked
/// the mount, or after the run's own trigger already flipped), and flipping
/// then would unpark the mount or slew it back across the meridian. A parked
/// mount, a stopped mount, a flip already made for this target, and a mount
/// already on the post-flip side for a target west of the meridian all mean no
/// flip.
async fn flip_not_for_this_mount(
    ctx: &InstructionContext,
    mount_id: &str,
    target_ra_of_date: f64,
    longitude: f64,
    now: chrono::DateTime<chrono::Utc>,
) -> Option<String> {
    if matches!(ctx.run.device_ops.mount_is_parked(mount_id).await, Ok(true)) {
        return Some("the mount is parked".to_string());
    }
    if matches!(
        ctx.run.device_ops.mount_is_tracking(mount_id).await,
        Ok(false)
    ) {
        return Some("the mount is not tracking".to_string());
    }
    if let Some(state) = &ctx.run.trigger_state {
        if state.read().await.meridian.has_flipped() {
            return Some("the mount already flipped for this target".to_string());
        }
    }
    let hour_angle = crate::meridian::hour_angle(
        target_ra_of_date,
        crate::meridian::local_sidereal_time(crate::meridian::julian_day(&now), longitude),
    );
    if hour_angle > 0.0
        && matches!(
            ctx.run.device_ops.mount_side_of_pier(mount_id).await,
            Ok(crate::meridian::PierSide::East)
        )
    {
        return Some("the mount is already on the post-flip side (pier East)".to_string());
    }
    None
}
