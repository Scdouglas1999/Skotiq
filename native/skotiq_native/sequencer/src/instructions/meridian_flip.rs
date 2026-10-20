//! `meridian_flip.rs` — moved verbatim out of the former single-file `instructions.rs`
//! (release-pass C3 mechanical split). No logic changed; private items were
//! widened to `pub(crate)` so the sibling modules and the tests module still
//! see them, and `super::*` supplies the imports the original file had.

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
    // Surface a "starting" progress immediately so UI shows activity even
    // before the executor begins emitting its own events. The executor uses
    // its event channel for granular per-step progress so we do not wire
    // through that channel here — the explicit instruction node has its own
    // progress reporter (the callback we received) and a brief
    // 0%/100% bracket is sufficient.
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

    // Why: target name is a display/log label for meridian-flip
    // status events; the load-bearing inputs (target_ra, target_dec) are already
    // validated as Some above and return failure when missing. "Unknown" is the
    // documented UI fallback when the user starts a sequence without a named target.
    let target_name = ctx
        .target_name
        .clone()
        .unwrap_or_else(|| "Unknown".to_string());

    // Pre-flight: do not invoke the executor when no flip is actually needed
    // — its altitude/cover/pier-side preflight assume the flip is required
    // and would otherwise emit confusing "Aborted" events for routine
    // pre-meridian sequence runs.
    let (_lat, lon) = match ctx.device_ops.get_observer_location() {
        Some((lat, lon)) => (lat, lon),
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

    let flip_ctx = crate::meridian_flip_executor::FlipContext {
        target_name,
        target_ra_hours: target_ra,
        target_dec_degrees: target_dec,
        mount_id,
        camera_id: ctx.camera_id.clone(),
        focuser_id: ctx.focuser_id.clone(),
        // Resolve through the accessor, not the raw field: the context's cover
        // role is never populated on a real run, which silently disabled the
        // pre-flip "is the dust cap closed?" check that exists to stop a flip
        // ending in a failed plate solve and a parked mount.
        cover_calibrator_id: ctx.cover_calibrator_id().await.ok(),
        cancellation_token: Some(ctx.cancellation_token.clone()),
        trigger_state: ctx.trigger_state.clone(),
        // Carry the tuned autofocus config PLUS the live filter context
        // (current filter, wheel id, per-filter focus offsets) so the post-flip
        // refocus does not fall back to defaults on the wrong filter.
        autofocus_config: autofocus_config.map(|cfg| {
            crate::meridian_flip_executor::PostFlipAutofocusConfig {
                config: cfg.clone(),
                current_filter: ctx.current_filter.clone(),
                filterwheel_id: ctx.filterwheel_id.clone(),
                filter_focus_offsets: ctx.filter_focus_offsets.clone(),
            }
        }),
        // Real sequence-driven flip: command the hardware. The dry-run path
        // (Phase G) is the only caller that sets this true.
        simulate: false,
    };

    let mut flip_executor = crate::meridian_flip_executor::MeridianFlipExecutor::new(
        config.clone(),
        ctx.device_ops.clone(),
    );
    // forward the live executor event channel so the
    // post-flip refocus emits its instruction-level failures to UI
    // subscribers (FITS-save errors during the test exposure, etc.).
    // When the instruction runs outside a live executor (unit tests),
    // ctx.event_tx is None and the chain remains silent.
    if let Some(event_tx) = ctx.event_tx.clone() {
        flip_executor = flip_executor.with_executor_event_tx(event_tx);
    }
    if let Some(decision_tx) = ctx.decision_tx.clone() {
        flip_executor =
            flip_executor.with_decision_tx(decision_tx, ctx.active_sequence_run_id.clone());
    }

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
        } => InstructionResult::failure_with_recovery(
            format!(
                "Meridian flip failed: {} (action taken: {:?})",
                error, action_taken
            ),
            "FLIP_FAILED",
        ),
        crate::meridian_flip_executor::FlipResult::Aborted { reason } => {
            InstructionResult::cancelled(reason)
        }
    }
}
