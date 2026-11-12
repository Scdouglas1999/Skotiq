//! One dither of the mount, whoever asks for it: the Dither node, a Smart
//! Exposure plan's cadence, the Dither Interval trigger ([`execute_dither`])
//! and a burst's dither-every (`execute_exposure_with_renderer`) all go through
//! [`dither_once`].

use super::*;

/// When a dither counts as done: announced to the run
/// ([`crate::executor::ExecutorEvent::DitherPerformed`], from which the run's
/// dither count is counted) and ending the failure streak.
///
/// What counts is an open owner question: once the mount has moved and the
/// guider holds the star, or only once the guider settled. Each caller keeps
/// the rule it has always had by passing it here.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DitherCounts {
    /// When the guider settles, or when the settle runs out while the guider
    /// holds the star at RMS within the reacquire bar
    /// ([`crate::executor::REACQUIRE_SETTLE_PIXELS`]): the frames after it are
    /// guided. The Dither node, a Smart Exposure plan and the Dither Interval
    /// trigger.
    OnceStarHeld,
    /// Only when the guider settles inside the dither's own bar and time. A
    /// burst's dither-every.
    OnlyWhenSettled,
}

/// Why a dither asked nothing of the guider.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DitherSkip {
    /// The guide-star recovery ran out and the run images unguided. A guider
    /// that is not guiding cannot dither, and asking it costs a settle timeout;
    /// the operator was told when guiding was given up.
    Unguided,
    /// The run itself holds the guider stopped (a tracking-limit or
    /// pre-meridian hold, a mount move); asking it only fails and reads as a
    /// guider error. Carries the reason in words.
    GuiderHeld(&'static str),
    /// The grid's center cell is the target position: no move is needed.
    GridCenter,
}

/// How one dither ended.
#[derive(Debug)]
pub(crate) enum DitherOutcome {
    /// The mount moved and the dither counts under the caller's
    /// [`DitherCounts`].
    Dithered,
    Skipped(DitherSkip),
    /// The guider refused or did not settle (by the caller's rule).
    /// `streak` is the failures in a row, this one included.
    Failed { error: DeviceError, streak: u32 },
}

/// Dither the mount once and settle at `config`'s settle values.
pub(crate) async fn dither_once(
    ctx: &InstructionContext,
    config: &crate::DitherConfig,
    counts: DitherCounts,
) -> DitherOutcome {
    if ctx.imaging_unguided().await {
        return DitherOutcome::Skipped(DitherSkip::Unguided);
    }
    if let Some(why) = ctx.run_holds_guider_stopped().await {
        return DitherOutcome::Skipped(DitherSkip::GuiderHeld(why));
    }
    let Some(pixels) = dither_pixels(ctx, config).await else {
        return DitherOutcome::Skipped(DitherSkip::GridCenter);
    };

    let settle = crate::GuiderSettle::from(config);
    ctx.run
        .device_ops
        .guider_note_stop_reason(Some(crate::GuidingStopReason::DitherSettle))
        .await;
    let result = dither_guarded(ctx, || {
        ctx.run.device_ops.guider_dither(
            pixels,
            settle.pixels,
            settle.time_secs,
            settle.timeout_secs,
            config.ra_only,
        )
    })
    .await;
    ctx.run.device_ops.guider_note_stop_reason(None).await;
    let result = match result {
        Err(error)
            if counts == DitherCounts::OnceStarHeld
                && is_settle_timeout(&error.to_string())
                && star_held_after_settle_ran_out(ctx, settle).await =>
        {
            Ok(())
        }
        other => other,
    };

    let trigger_state = ctx.run.trigger_state.as_ref();
    match result {
        Ok(()) => {
            announce_dither_performed(ctx);
            // A success ends the streak, so "3 in a row" means three in a row
            // and not three all night.
            if let Some(state) = trigger_state {
                state.write().await.latches.consecutive_dither_failures = 0;
            }
            DitherOutcome::Dithered
        }
        Err(error) => {
            let streak = match trigger_state {
                Some(state) => {
                    let mut state = state.write().await;
                    state.latches.consecutive_dither_failures =
                        state.latches.consecutive_dither_failures.saturating_add(1);
                    state.latches.consecutive_dither_failures
                }
                None => 1,
            };
            DitherOutcome::Failed { error, streak }
        }
    }
}

/// The offset to dither by, or `None` for the grid's center cell.
async fn dither_pixels(ctx: &InstructionContext, config: &crate::DitherConfig) -> Option<f64> {
    if config.pattern == crate::DitherPattern::Random {
        tracing::info!("Dithering {} pixels (random)", config.pixels);
        return Some(config.pixels);
    }
    // The grid's next cell must be sticky across calls, so the walk needs
    // the run's trigger state; without it every call would take the same cell.
    let Some(trigger_state) = ctx.run.trigger_state.as_ref() else {
        tracing::warn!("Grid dither requested but no trigger state available, falling back to random");
        return Some(config.pixels);
    };
    let (ra_offset, dec_offset) = {
        let mut state = trigger_state.write().await;
        let offset = state.next_grid_dither_offset(config.grid_size, config.pixels);
        tracing::info!(
            "Grid dither: position {}/{} -> RA={:.1}px, Dec={:.1}px",
            state.latches.grid_dither_index,
            config.grid_size * config.grid_size,
            offset.0,
            offset.1
        );
        offset
    };
    // The guider takes one magnitude and dithers in a random direction by
    // it; the grid's coverage comes from walking the cells, not from the
    // direction.
    let magnitude = (ra_offset * ra_offset + dec_offset * dec_offset).sqrt();
    (magnitude >= 0.01).then_some(magnitude)
}

/// After a settle ran out: whether the guider still holds the star at RMS
/// within the reacquire bar, so the frames after the dither are guided. Tells
/// the operator once when the dither's settle bar sits below what the guider
/// holds.
async fn star_held_after_settle_ran_out(
    ctx: &InstructionContext,
    settle: crate::GuiderSettle,
) -> bool {
    let Ok(status) = ctx.run.device_ops.guider_get_status().await else {
        return false;
    };
    if let Some(warning) = settle_bar_warning(ctx.run.trigger_state.as_ref(), settle, &status).await
    {
        tracing::warn!("{warning}");
        if let Some(event_tx) = &ctx.run.event_tx {
            let _ = event_tx.send(crate::executor::ExecutorEvent::Warning { message: warning });
        }
    }
    let held = status.is_guiding
        && status.rms_total > 0.0
        && status.rms_total <= crate::executor::REACQUIRE_SETTLE_PIXELS;
    if held {
        tracing::info!(
            "Dither settle ran out at {:.1} px, but the guider holds the star at RMS {:.2} px; \
             imaging goes on",
            settle.pixels,
            status.rms_total
        );
    }
    held
}

/// The Dither node, a Smart Exposure plan's dither and the Dither Interval
/// trigger: one dither under [`DitherCounts::OnceStarHeld`]. A dither that
/// fails never fails the step: it costs some stacking quality, not the
/// frames, and failing it made the sequential parent skip every remaining
/// exposure (reproduced live as [Exposures x10, Dither, Exposures x10] ending
/// with 10 frames and `status=failed` on a rig with no guider connected). It
/// is still reported in the step's message and the log.
///
/// The Dither Interval cadence restarts whatever the dither came to, so a
/// dither that cannot run now (no guider, a refusal) is not asked for again
/// on the very next frame.
pub async fn execute_dither(
    config: &DitherConfig,
    ctx: &InstructionContext,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
) -> InstructionResult {
    let report = |percent: f64, detail: &str| {
        if let Some(cb) = progress_callback {
            cb(percent, detail.to_string());
        }
    };
    report(0.0, "Starting dither");
    // There is no interrupting the guider once it dithers and settles.
    if let Some(result) = ctx.check_cancelled() {
        return result;
    }
    report(70.0, "Waiting for guiding to settle");

    let outcome = dither_once(ctx, config, DitherCounts::OnceStarHeld).await;
    if let Some(trigger_state) = &ctx.run.trigger_state {
        trigger_state.write().await.mark_dither_performed();
    }

    let (detail, message) = match outcome {
        DitherOutcome::Dithered => {
            let pattern = match config.pattern {
                crate::DitherPattern::Random => "random",
                crate::DitherPattern::Grid => "grid",
            };
            (
                "Dither complete",
                format!("Dither ({pattern}) and settle complete"),
            )
        }
        DitherOutcome::Skipped(DitherSkip::Unguided) => {
            tracing::info!("Dither skipped: the run is imaging unguided");
            (
                "Dither skipped: imaging unguided",
                "Dither skipped: the run is imaging unguided since the guide star was lost"
                    .to_string(),
            )
        }
        DitherOutcome::Skipped(DitherSkip::GuiderHeld(why)) => {
            tracing::info!("Dither skipped: {why}");
            (
                "Dither skipped: guiding is held",
                format!("Dither skipped: {why}"),
            )
        }
        DitherOutcome::Skipped(DitherSkip::GridCenter) => {
            tracing::info!("Grid dither at center position, skipping");
            (
                "Grid dither at center - skipping",
                "Grid dither at center position (no move needed)".to_string(),
            )
        }
        DitherOutcome::Failed { error, streak } => {
            let message = if streak > 1 {
                format!(
                    "Dither failed ({streak} in a row): {error}. Continuing to image without \
                     dithering — frames are unaffected, but check the guider: repeated dither \
                     failures usually mean guiding has stopped."
                )
            } else {
                format!(
                    "Dither failed: {error}. Continuing to image without dithering — the frames \
                     themselves are unaffected."
                )
            };
            tracing::warn!("{}", message);
            ("Dither failed; continuing", message)
        }
    };
    report(100.0, detail);
    InstructionResult::success_with_message(message)
}

/// Tell the run a dither counts (see [`DitherCounts`]), so it is counted once
/// (see [`crate::executor::ExecutorEvent::DitherPerformed`]).
pub(crate) fn announce_dither_performed(ctx: &InstructionContext) {
    if let Some(event_tx) = &ctx.run.event_tx {
        let node_id = Some(ctx.node_id.clone()).filter(|id| !id.is_empty());
        let _ = event_tx.send(crate::executor::ExecutorEvent::DitherPerformed { node_id });
    }
}

/// Dual-rig dither coordination wrapper.
///
/// Wraps a guider-dither call (the mount-moving pulse + settle) so a
/// piggybacking secondary camera is never mid-exposure during the pulse:
///
///   1. announce "dither pending" on the shared barrier — secondary stops
///      launching new exposures;
///   2. wait (bounded by the barrier's max-wait) for the secondary to clear
///      its in-flight exposure — a stuck secondary can NEVER stall the primary
///      past max-wait (we log and proceed);
///   3. run the actual dither;
///   4. release the barrier — secondary resumes its loop.
///
/// When `ctx.dither_barrier` is `None` (single-rig — the common case) this is a
/// plain `closure().await` with zero overhead. The barrier is released even if
/// the dither itself fails, so a failed pulse never leaves the secondary parked
/// forever.
pub(crate) async fn dither_guarded<F, Fut>(
    ctx: &InstructionContext,
    dither_call: F,
) -> DeviceResult<()>
where
    F: FnOnce() -> Fut,
    Fut: std::future::Future<Output = DeviceResult<()>>,
{
    let Some(barrier) = ctx.run.dither_barrier.clone() else {
        return dither_call().await;
    };

    barrier.begin_dither();
    let cleared = barrier.wait_for_secondary_clear().await;
    if !cleared {
        tracing::warn!(
            "Dual-rig: secondary did not clear within {:.0}s max-wait; \
             dithering anyway (secondary frame may be discarded). \
             forced_proceeds={}",
            barrier.max_wait_secs(),
            barrier.forced_proceed_count(),
        );
        if let Some(event_tx) = &ctx.run.event_tx {
            let _ = event_tx.send(crate::executor::ExecutorEvent::StepProblem {
                message: format!(
                    "Dual-rig: secondary camera did not clear within {:.0}s; \
                     dithered anyway",
                    barrier.max_wait_secs(),
                ),
            });
        }
    }

    let result = dither_call().await;
    // Always release, even on dither failure — otherwise a failed pulse would
    // leave the secondary parked indefinitely.
    barrier.end_dither();
    result
}
