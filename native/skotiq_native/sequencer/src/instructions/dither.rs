//! `dither.rs` — moved verbatim out of the former single-file `instructions.rs`
//! (release-pass C3 mechanical split). No logic changed; private items were
//! widened to `pub(crate)` so the sibling modules and the tests module still
//! see them, and `super::*` supplies the imports the original file had.

use super::*;

// Dither instruction

/// Execute dither
pub async fn execute_dither(
    config: &DitherConfig,
    ctx: &InstructionContext,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
) -> InstructionResult {
    if let Some(cb) = progress_callback {
        cb(0.0, "Starting dither".to_string());
    }

    if let Some(result) = ctx.check_cancelled() {
        return result;
    }

    // The guide-star recovery ran out and the run carries on unguided. A
    // guider that is not guiding cannot dither, and asking it costs a settle
    // timeout; the operator was told when guiding was given up.
    if ctx.imaging_unguided().await {
        tracing::info!("Dither skipped: the run is imaging unguided");
        if let Some(cb) = progress_callback {
            cb(100.0, "Dither skipped: imaging unguided".to_string());
        }
        return InstructionResult::success_with_message(
            "Dither skipped: the run is imaging unguided since the guide star was lost",
        );
    }

    let (dither_pixels, ra_only) = match config.pattern {
        crate::DitherPattern::Random => {
            tracing::info!("Dithering {} pixels (random)", config.pixels);
            (config.pixels, config.ra_only)
        }
        crate::DitherPattern::Grid => {
            // Grid pattern requires trigger state because the next position
            // must be sticky across calls — without it we cannot walk the
            // NxN cells in order and would loop the same cell.
            if let Some(ref trigger_state) = ctx.trigger_state {
                let (ra_offset, dec_offset) = {
                    let mut state = trigger_state.write().await;
                    let offset = state.next_grid_dither_offset(config.grid_size, config.pixels);
                    tracing::info!(
                        "Grid dither: position {}/{} -> RA={:.1}px, Dec={:.1}px",
                        state.grid_dither_index,
                        config.grid_size * config.grid_size,
                        offset.0,
                        offset.1
                    );
                    offset
                };

                // guider_dither takes a single magnitude scalar, so we
                // collapse the 2D grid offset into its Euclidean magnitude.
                // The guider then performs a random-direction dither of that
                // magnitude, which is acceptable because the grid algorithm
                // already enforces spatial coverage at the planning layer.
                let magnitude = (ra_offset * ra_offset + dec_offset * dec_offset).sqrt();
                if magnitude < 0.01 {
                    // The (0,0) cell is the original target position — a
                    // dither of 0 px would still trigger a settle wait for no
                    // benefit. Returning a synthetic Success keeps the grid
                    // cadence intact (next call advances to the next cell).
                    tracing::info!("Grid dither at center position, skipping");
                    if let Some(cb) = progress_callback {
                        cb(100.0, "Grid dither at center - skipping".to_string());
                    }
                    return InstructionResult::success_with_message(
                        "Grid dither at center position (no move needed)",
                    );
                }

                // Grid mode passes the user's explicit `ra_only` flag through
                // unchanged, so the next grid cell's RA *and* Dec offsets reach the
                // guider. Collapsing to RA-only when `dec_offset.abs() < 0.01` turns a
                // requested 2D grid into 1D dithering for any cell whose Dec component
                // happens to round near zero.
                (magnitude, config.ra_only)
            } else {
                tracing::warn!(
                    "Grid dither requested but no trigger state available, falling back to random"
                );
                (config.pixels, config.ra_only)
            }
        }
    };

    if let Some(cb) = progress_callback {
        cb(30.0, "Sending dither command to guider".to_string());
    }

    // guider_dither blocks until the move + settle completes. We can only
    // emit synthetic progress points around it; the device-ops layer does
    // not expose sub-step progress, so the UI shows discrete checkpoints
    // rather than a smooth bar during this phase.
    if let Some(cb) = progress_callback {
        cb(50.0, "Waiting for dither to complete".to_string());
    }

    // Last cancellation check before a potentially 60+ s blocking call —
    // there is no way to interrupt guider_dither once it's running.
    if let Some(result) = ctx.check_cancelled() {
        return result;
    }

    if let Some(cb) = progress_callback {
        cb(70.0, "Waiting for guiding to settle".to_string());
    }

    // Dual-rig — coordinate with a piggybacking secondary capture loop (if
    // any). `dither_guarded` announces the pending dither, waits (bounded) for
    // the secondary to clear its in-flight exposure, runs the closure (the
    // actual mount pulse + settle), then releases the barrier so the secondary
    // resumes. With no barrier installed this is a plain pass-through.
    let dither_result = dither_guarded(ctx, || {
        ctx.device_ops.guider_dither(
            dither_pixels,
            config.settle_pixels,
            config.settle_time,
            config.settle_timeout,
            ra_only,
        )
    })
    .await;

    match dither_result {
        Ok(_) => {
            if let Some(cb) = progress_callback {
                cb(100.0, "Dither complete".to_string());
            }
            // A success ends the streak, so "3 in a row" in the warning above
            // means three in a row and not three all night.
            if let Some(trigger_state) = &ctx.trigger_state {
                trigger_state.write().await.consecutive_dither_failures = 0;
            }
            let pattern_name = match config.pattern {
                crate::DitherPattern::Random => "random",
                crate::DitherPattern::Grid => "grid",
            };
            InstructionResult::success_with_message(format!(
                "Dither ({}) and settle complete",
                pattern_name
            ))
        }
        Err(e) => {
            // A dither that fails does NOT justify ending the night.
            //
            // Dithering decorrelates fixed-pattern noise between subs. Losing
            // it costs a little stacking quality; the frames themselves are
            // perfectly good science. Returning a failure here made the
            // sequential parent short-circuit, so one failed dither threw away
            // every remaining exposure: reproduced live as
            // [Exposures x10, Dither, Exposures x10] finishing with 10 frames
            // of 20 and `status=failed`, on a rig whose only problem was that
            // no guider was connected.
            //
            // It is still reported loudly — as a warning on the node, in the
            // log, and in the run's message list — because a dither failing
            // every time usually means the guider has gone, and that IS worth
            // an operator's attention even though it is not worth the night.
            let consecutive = if let Some(trigger_state) = &ctx.trigger_state {
                let mut state = trigger_state.write().await;
                state.consecutive_dither_failures =
                    state.consecutive_dither_failures.saturating_add(1);
                state.consecutive_dither_failures
            } else {
                1
            };

            let message = if consecutive > 1 {
                format!(
                    "Dither failed ({consecutive} in a row): {e}. Continuing to image without \
                     dithering — frames are unaffected, but check the guider: repeated dither \
                     failures usually mean guiding has stopped."
                )
            } else {
                format!(
                    "Dither failed: {e}. Continuing to image without dithering — the frames \
                     themselves are unaffected."
                )
            };
            tracing::warn!("{}", message);
            if let Some(cb) = progress_callback {
                cb(100.0, "Dither failed; continuing".to_string());
            }
            InstructionResult::success_with_message(message)
        }
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
    let Some(barrier) = ctx.dither_barrier.clone() else {
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
        if let Some(event_tx) = &ctx.event_tx {
            let _ = event_tx.send(crate::executor::ExecutorEvent::Error {
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
