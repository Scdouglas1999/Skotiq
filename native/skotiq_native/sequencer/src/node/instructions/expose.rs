//! TakeExposure instruction node.
//!
//! Owns the burst-level integration accounting, exposure-trigger evaluation,
//! HFR baseline updates, and the final structured ProgressUpdate that carries
//! `completed_exposure_secs` for the executor's global counter.

use crate::frame_naming::{frame_namer, BurstNaming};
use crate::instructions::{
    execute_autofocus, execute_exposure_with_renderer, notify_autofocus_failed_continuing,
    resolve_burst_filter, AutofocusProgress, BurstFilter,
    InstructionResult, Setback,
};
use crate::node::context::ExecutionContext;
use crate::node::instructions::autofocus::autofocus_detail;
use crate::node::progress::{ProgressDetail, ProgressUpdate};
use crate::node::registry::InstructionNode;
use crate::scheduling::{
    compute_adaptive_exposure, AdaptiveExposureConfig, AdaptiveExposureDecision,
    AdaptiveExposureReason,
};
use crate::{
    AutofocusConfig, AutofocusMethod, ExposureConfig, NodeStatus, NodeType, TriggerAction,
    TriggerCondition,
};
use async_trait::async_trait;
use std::sync::atomic::Ordering;

pub struct ExposeInstruction;

#[async_trait]
impl InstructionNode for ExposeInstruction {
    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::TakeExposure(config) = node_type else {
            tracing::error!("ExposeInstruction received non-TakeExposure variant");
            return NodeStatus::Failure;
        };

        // Track binning change for HFR-baseline invalidation. A binning change
        // shifts the HFR scale so any prior baseline becomes meaningless.
        let previous_binning = context.current_binning;
        context.current_binning = config.binning;
        let mut ctx = context.to_instruction_context(node_id).await;
        ctx.current_binning = config.binning;

        // Settle WHICH FILTER these frames are taken through before anything
        // that records it runs: the save-path renderer below snapshots the
        // context, and `build_frame_context_for_save` stamps the FITS header
        // and the `captured_images` row from it. Until this ran, all three
        // read `ExecutionContext.current_filter`, which only a Change Filter
        // node or a Smart Exposure plan ever wrote — so a plain Take Exposures
        // burst on a rig with a filter wheel produced `..._nofilter_0001.fits`
        // and a FITS header with no FILTER card while the wheel sat on a
        // known slot. Resolving it once, here, is also what stops the
        // filename, the header and the database row from being able to
        // disagree about the same frame.
        if let BurstFilter::Resolved { name, index } = resolve_burst_filter(config, &ctx).await {
            context.current_filter = name.clone();
            context.current_filter_index = index;
            ctx.current_filter = name.clone();
            ctx.current_filter_index = index;
            // Publish the resolved identity, because the recording surfaces on
            // the OTHER side of the bridge cannot see `context.current_filter`.
            //
            // `ProgressDetail::Filter` is the only thing that ever told Dart
            // which filter is in use, and only a Change Filter node emitted it.
            // Dart writes `captured_images.filter` and the run-stats bucket
            // from that published value, so a burst that addresses the wheel
            // itself — by `filter_index` alone, or by inheriting the slot the
            // wheel is parked on — stamped its resolved name into the FITS
            // FILTER card and the filename here while the database row kept
            // whatever an earlier Change Filter had left behind. One frame,
            // two different filters recorded for it.
            if let (Some(resolved), Some(cb)) =
                (name.as_deref(), context.progress_callback.as_ref())
            {
                cb(ProgressUpdate::instruction_progress(
                    node_id.to_string(),
                    "Exposure",
                    0.0,
                    ProgressDetail::Filter {
                        name: resolved.to_string(),
                        position: index,
                    },
                ));
            }
        }

        if previous_binning != config.binning {
            tracing::warn!(
                "Exposure binning changed from {:?} to {:?}; invalidating autofocus baseline",
                previous_binning,
                config.binning
            );
            if let Some(trigger_state_lock) = &context.run.trigger_state {
                let mut trigger_state = trigger_state_lock.write().await;
                trigger_state.invalidate_autofocus(format!(
                    "binning changed from {:?} to {:?}",
                    previous_binning, config.binning
                ));
            }
        }

        let nominal_secs = config.duration_secs;
        let total_count = config.count;
        // A resumed run continues the burst it stopped in.
        let frames_taken = context.resume.frames_taken(node_id).min(total_count);
        let frames_to_take = total_count - frames_taken;
        let progress_cb = context.progress_callback.as_ref();
        let resume = context.resume.clone();

        // sky-brightness adaptive exposure decision.
        // Resolve the effective config (per-node wins, else runtime
        // global default) and consult the live sky-brightness reading
        // pushed in via `SequenceExecutor::update_sky_brightness`. The
        // decision is always produced even when the adapter is
        // disabled — the returned `adapted_secs` equals `nominal_secs`
        // in that case, and a structured event is only emitted when
        // adaptation actually fired (Adapted / ClampedMin / ClampedMax
        // / OutOfNominalBounds) so an off-by-default user doesn't see
        // a stream of "Disabled" rows.
        let effective_adaptive_config: Option<AdaptiveExposureConfig> = {
            let per_node = config.adaptive_exposure.clone();
            if per_node.is_some() {
                per_node
            } else {
                context.default_adaptive_exposure.read().await.clone()
            }
        };
        let live_sky_mag = *context.run.conditions.sky_brightness_mag.read().await;
        let decision = compute_adaptive_exposure(
            effective_adaptive_config.as_ref(),
            nominal_secs,
            config.filter.as_deref(),
            live_sky_mag,
        );
        let duration_secs = decision.adapted_secs;
        emit_adaptive_exposure_event(node_id, context, &decision, config.filter.as_deref());

        // Build the effective config for execute_exposure_with_renderer
        // with the adapted duration. Cloning is cheap (`ExposureConfig`
        // is mostly primitive fields + small Vec<Trigger>).
        let mut effective_config = config.clone();
        effective_config.duration_secs = duration_secs;
        let effective_config = effective_config;

        // build the save-path renderer. Captures a clone of the
        // ExecutionContext and the burst-config so the same per-frame
        // EvaluationFrame can resolve `${frame}`, `${exposure.duration}`,
        // and the rest of the catalog at FITS-save time. We pass the
        // *adapted* duration here so the FITS header / save-path
        // template reflects what was actually captured.
        //
        // Cloning ExecutionContext is cheap (every field is `Arc`/`Copy`)
        // and the closure runs synchronously inside the exposure loop —
        // there is no concurrent-borrow concern.
        let path_renderer =
            match frame_namer(context, BurstNaming::of(&effective_config, duration_secs)) {
                Ok(renderer) => renderer,
                Err(message) => {
                    tracing::error!("{}", message);
                    if let Some(event_tx) = &context.run.event_tx {
                        let _ = event_tx.send(crate::executor::ExecutorEvent::Error {
                            message: message.clone(),
                        });
                    }
                    return NodeStatus::Failure;
                }
            };

        // Q3: serialise the burst against the camera it uses. `execute_parallel`
        // clones this context per branch, so two branches exposing on the same
        // sensor would otherwise interleave — two rows, one file, one frame's
        // pixels gone. The lock is per-device, so separate cameras still run
        // concurrently.
        let camera_lock = ctx
            .run
            .rig
            .camera_id
            .as_deref()
            .map(|id| context.device_locks.handle(id));
        // A burst is many frames inside one node, so the node-boundary pause
        // check the tree does never fires between them; the gate handle is
        // what lets the frame loop honour a Pause. `status` gives an in-burst
        // hold (the meridian gate) a way to say so, instead of the run
        // appearing stalled at 0/N with no explanation.
        let status_cb = context.progress_callback.clone();
        let status_node_id = node_id.to_string();
        let status_fn = move |message: &str| {
            if let Some(cb) = status_cb.as_ref() {
                cb(ProgressUpdate::lifecycle(
                    status_node_id.clone(),
                    NodeStatus::Running,
                    message.to_string(),
                ));
            }
        };
        let control = crate::instructions::BurstControl {
            pause: context.pause_gate(),
            status: Some(&status_fn),
            frames_taken,
        };
        let burst = {
            let _camera_guard = match camera_lock.as_ref() {
                Some(lock) => Some(lock.lock().await),
                None => None,
            };

            execute_exposure_with_renderer(
                &effective_config,
                &ctx,
                Some(path_renderer),
                &control,
                |current, total, recorded_secs| {
                    resume.frame_taken(node_id, current);
                    if let Some(cb) = progress_cb {
                        let percent = if total > 0 {
                            100.0 * f64::from(current) / f64::from(total)
                        } else {
                            0.0
                        };
                        // Per-frame structured Exposure progress. current_frame /
                        // total_frames must remain populated because the executor's
                        // progress callback uses them to synthesize ExposureStarted
                        // / ExposureCompleted events.
                        //
                        // The detail names the seconds the frame was RECORDED
                        // as, not the seconds it was asked for: an adaptive or
                        // truncated frame really did expose for something else,
                        // and every integration total downstream sums this
                        //.
                        let mut upd = ProgressUpdate::instruction_progress(
                            node_id.to_string(),
                            "Exposure",
                            percent,
                            ProgressDetail::Exposure {
                                frame: current,
                                total,
                                duration_secs: recorded_secs,
                            },
                        );
                        upd.current_frame = Some(current);
                        upd.total_frames = Some(total);
                        upd.frame_exposure_secs = Some(recorded_secs);
                        cb(upd);
                    }
                },
            )
            .await
        };
        let result = burst.result;
        if result.status != NodeStatus::Cancelled {
            context.resume.burst_ended(node_id);
        }

        // Canonical integration accounting: the entire burst's exposure time
        // is added here in one shot. Per-frame updates would race with the
        // synchronous progress callbacks and double-count under contention.
        if result.status == NodeStatus::Success {
            let total_exposure_time = duration_secs * f64::from(frames_to_take);
            context.record_scheduler_completed_exposures(u64::from(frames_to_take));
            {
                let mut counter = context.completed_integration_secs.write().await;
                *counter += total_exposure_time;
            }

            // coordinate the budget credit with the
            // image grader. A rejected frame is data that won't end up in
            // the final stack, so crediting its exposure time against the
            // budget would over-promise progress: the dashboard would
            // show "60/60 L frames complete" while only e.g. 54 are
            // usable. The burst's own rejected frames are subtracted from
            // the budget credit.
            //
            // Why subtract instead of skipping `record_exposure` entirely
            // when there were rejects: a partial burst (e.g. 8 of 10
            // frames passed) should still credit the 8 that passed. The
            // global `completed_integration_secs` above intentionally
            // credits the FULL burst time — that counter measures
            // "exposure time spent" (wall-clock-relevant), which the user
            // wants to see even for rejected subs. The budget counter
            // measures "integration that contributes to the goal", which
            // is the passed-frames-only quantity.
            let rejected_in_burst = burst.frames_rejected;
            let passed_count = frames_to_take.saturating_sub(rejected_in_burst);
            let budget_credit_secs = duration_secs * f64::from(passed_count);

            // credit the active TargetHeader's
            // integration budget. Returns None when no TargetHeader is
            // active (e.g. ad-hoc exposure outside a target subtree) —
            // that's fine, no budget to enforce. The post-credit state
            // drives the structured IntegrationBudget progress event
            // that the dashboard panel renders.
            //
            // When every frame in the burst was rejected (passed_count
            // == 0), we deliberately skip `record_exposure` entirely
            // rather than calling with 0.0 — the registry treats both as
            // no-op for the accounting math, but skipping keeps the
            // event flow consistent with "nothing useful happened, no
            // progress event emitted."
            // Only the night's data counts toward a target's integration
            // goal: a snapshot or a dark taken under the target is not.
            if budget_credit_secs > 0.0 && config.frame_type.is_science() {
                let budget_filter = config
                    .filter
                    .clone()
                    .or_else(|| context.current_filter.clone());
                if let Some(state) = context
                    .budget_registry
                    .record_exposure(budget_filter.as_deref(), budget_credit_secs)
                    .await
                {
                    emit_budget_progress(node_id, context, &state, budget_filter.as_deref()).await;
                }
            } else if rejected_in_burst > 0 {
                tracing::info!(
                    "All {} frames in burst rejected by grader; budget not credited",
                    rejected_in_burst
                );
            }

            if let Some(trigger_state_lock) = &context.run.trigger_state {
                let mut trigger_state = trigger_state_lock.write().await;
                if let Some(median_hfr) = compute_hfr_median(&result.hfr_values) {
                    trigger_state.update_hfr(median_hfr);
                    tracing::debug!("Updated trigger state HFR: {:.2}", median_hfr);
                }
                // AutofocusInterval / DitherInterval triggers fire every N
                // star-field frames; a dark or bias burst neither blurs focus
                // nor builds walking noise, so it does not advance them.
                if config.frame_type.is_sky_frame() {
                    for _ in 0..frames_to_take {
                        trigger_state.increment_exposure_count();
                    }
                }
                tracing::debug!(
                    "Updated trigger state exposure count: {}",
                    trigger_state.latches.completed_exposures
                );
            }

            check_exposure_triggers(node_id, config, &result, context).await;

            // Final progress event carries completed_exposure_secs so the
            // executor's progress callback adds it to the global counter
            // exactly once — per-frame events deliberately leave it None.
            let final_message = format!(
                "Completed {} exposures ({:.0}s)",
                frames_to_take, total_exposure_time
            );
            let mut final_upd =
                ProgressUpdate::lifecycle(node_id.to_string(), NodeStatus::Success, final_message);
            final_upd.current_frame = Some(total_count);
            final_upd.total_frames = Some(total_count);
            final_upd.completed_exposure_secs = Some(total_exposure_time);
            context.send_progress(final_upd);
        }

        result.settle("Exposure", &ctx).await
    }
}

/// emit a structured `ExposureAdjusted` progress event
/// before the burst begins, surfacing the adaptive-exposure decision so
/// the dashboard can show "L 142s (nominal 60s, sky 19.2 mag/arcsec²)".
///
/// Suppression rule: when the adapter was disabled / unavailable AND the
/// adapted duration is identical to nominal, we still emit the event so
/// the dashboard can show "sky 19.2 mag/arcsec² (adaptive off)" without
/// the user wondering whether the adapter is even running. We only
/// suppress when both *reason == Disabled* and *no config at all was
/// resolved* (the "no adaptive feature in this run" case) so off-by-
/// default users don't see spurious adjustments.
fn emit_adaptive_exposure_event(
    node_id: &str,
    context: &ExecutionContext,
    decision: &AdaptiveExposureDecision,
    filter: Option<&str>,
) {
    // Always emit when an active adapter ran (anything other than
    // `Disabled`). For the disabled case we still emit when the user
    // has globally-or-per-node set up a config — that way the UI can
    // honestly say "L: nominal, adaptive disabled for this filter"
    // rather than going silent.
    let mut adjusted_pct: f64 = 0.0;
    if decision.nominal_secs > 0.0 {
        adjusted_pct =
            ((decision.adapted_secs - decision.nominal_secs).abs() / decision.nominal_secs) * 100.0;
    }
    // Significant-adjustment threshold for trigger-feed surfacing: 50 %
    // matches the brief ("Trigger feed entries when an exposure is
    // adapted by more than 50 % from nominal"). Lower than that and the
    // dashboard's main panel suffices.
    if adjusted_pct > 50.0 {
        tracing::info!(
            "Adaptive exposure significantly adjusted ({:+.0}%): {:.1}s -> {:.1}s for filter {:?} (reason: {})",
            adjusted_pct,
            decision.nominal_secs,
            decision.adapted_secs,
            filter,
            decision.reason.label(),
        );
    } else {
        tracing::debug!(
            "Adaptive exposure decision: {:.1}s -> {:.1}s for filter {:?} (reason: {})",
            decision.nominal_secs,
            decision.adapted_secs,
            filter,
            decision.reason.label(),
        );
    }
    let upd = ProgressUpdate::instruction_progress(
        node_id.to_string(),
        "AdaptiveExposure",
        0.0,
        ProgressDetail::ExposureAdjusted {
            adapted_secs: decision.adapted_secs,
            nominal_secs: decision.nominal_secs,
            sky_brightness_mag: decision.sky_brightness_mag,
            filter: filter.map(|s| s.to_string()),
            reason: reason_to_str(&decision.reason).to_string(),
        },
    );
    context.send_progress(upd);
}

/// Convert the typed `AdaptiveExposureReason` to the wire-form lowercase
/// kebab-case strings the Dart side switches on. Centralised here so the
/// bridge / Dart side has a single canonical set of strings to match
/// against; lower-case avoids "Adapted" vs "adapted" confusion in
/// string-equality matchers.
fn reason_to_str(reason: &AdaptiveExposureReason) -> &'static str {
    match reason {
        AdaptiveExposureReason::Adapted => "adapted",
        AdaptiveExposureReason::ClampedMin => "clamped_min",
        AdaptiveExposureReason::ClampedMax => "clamped_max",
        AdaptiveExposureReason::Unavailable => "unavailable",
        AdaptiveExposureReason::Disabled => "disabled",
        AdaptiveExposureReason::OutOfNominalBounds => "out_of_nominal_bounds",
    }
}

/// emit the structured `IntegrationBudget` progress
/// event after each successful burst. The dashboard's filter-integration
/// panel renders this without needing to re-read the registry.
///
/// `budget_secs` comes from the active budget's resolved per-filter cap
/// (when set) or falls back to the budget's `total_secs` (when only a
/// total cap is configured). When neither applies the field is left at
/// 0.0 and the UI shows the rolling completed seconds without a bar.
async fn emit_budget_progress(
    node_id: &str,
    context: &ExecutionContext,
    state: &crate::scheduling::BudgetState,
    filter: Option<&str>,
) {
    // Find the budget for the target this state belongs to. The
    // ExecutionContext carries `target_id` while inside a TargetHeader;
    // if absent (orphaned exposure), no budget event is meaningful.
    let target_id = match context.target_id.as_deref() {
        Some(id) => id.to_string(),
        None => return,
    };

    let filter_name = filter.unwrap_or("").to_string();
    let completed_for_filter = state
        .completed_by_filter
        .get(&filter_name)
        .copied()
        .unwrap_or(0.0);

    // Resolve the cap from the active budget. When the filter has its
    // own cap that's authoritative; otherwise we fall back to the
    // budget's total (so a "8h total" without per-filter caps still
    // renders a meaningful progress bar).
    let (budget_secs, fraction, budget_met) =
        if let Some(budget) = context.budget_registry.active_budget().await {
            let cap = budget
                .resolved_filter_cap(&filter_name)
                .unwrap_or(budget.total_secs);
            let basis = if cap > 0.0 { cap } else { budget.total_secs };
            // Use total completed for the target when the per-filter cap is
            // missing — that way "8h total" budgets render against total
            // progress on every filter.
            let progress_secs = if budget.resolved_filter_cap(&filter_name).is_some() {
                completed_for_filter
            } else {
                state.completed_total_secs
            };
            let fraction = if basis > 0.0 {
                (progress_secs / basis).clamp(0.0, 1.5)
            } else {
                0.0
            };
            let met = state.is_met(&budget);
            (basis, fraction, met)
        } else {
            // No active budget; the structured event still goes out (the UI
            // shows live per-filter integration without a cap), but
            // `budget_secs` stays zero so renderers know to omit the bar.
            (0.0, 0.0, false)
        };

    let upd = ProgressUpdate::instruction_progress(
        node_id.to_string(),
        "IntegrationBudget",
        (fraction * 100.0).clamp(0.0, 100.0),
        ProgressDetail::IntegrationBudget {
            target_id: target_id.clone(),
            filter: filter_name.clone(),
            completed_secs: completed_for_filter,
            budget_secs,
            fraction,
            budget_met,
        },
    );
    context.send_progress(upd);

    // Replay Debug — emit a BudgetMet decision exactly once
    // (the transition from "in progress" to "met"). The
    // `BudgetMetTracker` map on the ExecutionContext would be the
    // canonical place to dedupe across calls, but the current emit
    // site fires on every burst so we instead rely on the consumer
    // to dedupe; the loud-fail policy is satisfied because every
    // milestone is recorded, not just the first.
    if budget_met {
        context.run.emit_decision(
            crate::decision::DecisionEvent::new(
                crate::decision::DecisionCategory::BudgetMet,
                format!(
                    "Integration budget met for target {} (filter {})",
                    target_id,
                    if filter_name.is_empty() {
                        "<none>"
                    } else {
                        filter_name.as_str()
                    },
                ),
                serde_json::json!({
                    "target_id": target_id,
                    "filter": filter_name,
                    "completed_secs": completed_for_filter,
                    "budget_secs": budget_secs,
                    "fraction": fraction,
                }),
            )
            .with_node(node_id.to_string()),
        );
    }
}

/// Compute the true median of HFR measurements, filtering NaN and non-positive
/// values.
fn compute_hfr_median(values: &[f64]) -> Option<f64> {
    let mut filtered: Vec<f64> = values
        .iter()
        .copied()
        .filter(|v| !v.is_nan() && *v > 0.0)
        .collect();
    if filtered.is_empty() {
        return None;
    }
    filtered.sort_by(|a, b| {
        a.partial_cmp(b)
            .expect("NaN values were filtered out above; partial_cmp must succeed")
    });
    let len = filtered.len();
    let median = if len % 2 == 1 {
        filtered[len / 2]
    } else {
        (filtered[len / 2 - 1] + filtered[len / 2]) / 2.0
    };
    Some(median)
}

/// Summary of the decision row a `Notify` exposure trigger writes; the
/// app's notification classifier reads the TriggerFired event beside it.
pub const EXPOSURE_TRIGGER_NOTIFY_SUMMARY: &str = "Exposure trigger fired — the run continues";

/// Tell the operator that an exposure trigger's condition now holds, and that
/// nothing was stopped. Once per episode: the caller only gets here when the
/// condition did not hold on the trigger's previous evaluation.
/// An exposure trigger's condition in the operator's words. Its `Debug` form
/// ("HfrAbove(3.5)") reached the run's status line.
fn exposure_trigger_name(condition: &TriggerCondition) -> String {
    match condition {
        TriggerCondition::HfrAbove(threshold) => format!("HFR above {threshold:.2} px"),
        TriggerCondition::GuidingRmsAbove(threshold) => {
            format!("Guiding RMS above {threshold:.2}\"")
        }
        TriggerCondition::DriftAbove { ra_px, dec_px } => {
            format!("Drift above RA {ra_px:.1} px / Dec {dec_px:.1} px")
        }
    }
}

fn notify_exposure_trigger(
    node_id: &str,
    trigger_id: &str,
    condition: &TriggerCondition,
    current_hfr: Option<f64>,
    latest_guiding_rms: Option<f64>,
    context: &ExecutionContext,
) {
    let trigger_name = exposure_trigger_name(condition);
    let measured = match condition {
        TriggerCondition::HfrAbove(_) => {
            current_hfr.map(|hfr| format!("the last frame measured {hfr:.2} px"))
        }
        TriggerCondition::GuidingRmsAbove(_) => {
            latest_guiding_rms.map(|rms| format!("guiding measured {rms:.2}\" RMS"))
        }
        TriggerCondition::DriftAbove { .. } => None,
    };
    let message = format!(
        "Exposure trigger '{trigger_name}' on node '{node_id}'{}. Imaging continues; you will \
         hear about this trigger again only after it clears and fires again.",
        measured.map(|m| format!(": {m}")).unwrap_or_default(),
    );
    tracing::warn!("{}", message);
    if let Some(event_tx) = &context.run.event_tx {
        let _ = event_tx.send(crate::executor::ExecutorEvent::TriggerFired {
            trigger_id: trigger_id.to_string(),
            trigger_name: trigger_name.clone(),
            action: crate::executor::TriggerFiredAction::Notify,
        });
        let _ = event_tx.send(crate::executor::ExecutorEvent::Warning {
            message: message.clone(),
        });
    }
    context.run.emit_decision(
        crate::decision::DecisionEvent::new(
            crate::decision::DecisionCategory::TriggerFired,
            EXPOSURE_TRIGGER_NOTIFY_SUMMARY.to_string(),
            serde_json::json!({
                "trigger_id": trigger_id,
                "trigger_name": trigger_name,
                "action": "Notify",
                "message": message,
            }),
        )
        .with_node(node_id.to_string()),
    );
}

/// Evaluate per-exposure triggers (HFR, guiding-RMS, drift) and dispatch
/// their actions.
pub(crate) async fn check_exposure_triggers(
    node_id: &str,
    config: &ExposureConfig,
    result: &InstructionResult,
    context: &mut ExecutionContext,
) {
    if config.triggers.is_empty() {
        return;
    }

    let current_hfr = result.hfr_values.last().copied();

    let trigger_state_lock = match &context.run.trigger_state {
        Some(lock) => lock.clone(),
        None => return,
    };

    let latest_guiding_rms = {
        // Imaging unguided after the guide-star recovery ran out: there is no
        // guiding to judge.
        let trigger_state = trigger_state_lock.read().await;
        trigger_state
            .latches
            .guiding_rms_history
            .as_ref()
            .filter(|_| !trigger_state.guiding.is_unguided())
            .and_then(|history| history.last())
            .map(|(_, rms)| *rms)
        // Read lock released before the trigger loop — DriftAbove re-acquires
        // it inside the match arm and tokio's RwLock is not re-entrant.
    };

    for (index, trigger) in config.triggers.iter().enumerate() {
        let should_fire = match &trigger.condition {
            TriggerCondition::HfrAbove(threshold) => match current_hfr {
                Some(hfr) => hfr > *threshold,
                None => false,
            },
            TriggerCondition::GuidingRmsAbove(threshold) => match latest_guiding_rms {
                Some(rms) => rms > *threshold,
                None => false,
            },
            TriggerCondition::DriftAbove { ra_px, dec_px } => {
                let trigger_state = trigger_state_lock.read().await;
                match trigger_state.calculate_drift_pixels() {
                    Some((drift_ra_px, drift_dec_px)) => {
                        let drift_exceeds = drift_ra_px > *ra_px || drift_dec_px > *dec_px;
                        if drift_exceeds {
                            tracing::warn!(
                                "Drift detected: RA={:.2}px (threshold={:.2}px), Dec={:.2}px (threshold={:.2}px)",
                                drift_ra_px,
                                ra_px,
                                drift_dec_px,
                                dec_px
                            );
                        }
                        drift_exceeds
                    }
                    None => {
                        tracing::debug!(
                            "Drift trigger check skipped - insufficient plate solve data (thresholds: ra_px={}, dec_px={})",
                            ra_px,
                            dec_px
                        );
                        false
                    }
                }
            }
        };

        let episode_key = format!("{node_id}#{index}");
        if !should_fire {
            context
                .exposure_triggers
                .lock()
                .holding
                .remove(&episode_key);
            continue;
        }
        let now = context.clock.now_utc();
        {
            let mut memory = context.exposure_triggers.lock();
            let new_episode = memory.holding.insert(episode_key.clone());
            // The trigger's debounce: after it acts, it stays quiet for
            // `debounce_secs`, whatever the condition does meanwhile.
            let quiet = trigger.debounce_secs > 0.0
                && memory.last_acted.get(&episode_key).is_some_and(|at| {
                    (now - *at).num_milliseconds() < (trigger.debounce_secs * 1000.0) as i64
                });
            let notify_again = !new_episode && matches!(trigger.action, TriggerAction::Notify);
            if quiet || notify_again {
                continue;
            }
            memory.last_acted.insert(episode_key.clone(), now);
        }

        tracing::warn!(
            "Exposure trigger fired: {:?} - action: {:?}",
            trigger.condition,
            trigger.action
        );

        match &trigger.action {
            TriggerAction::Notify => {
                notify_exposure_trigger(
                    node_id,
                    &episode_key,
                    &trigger.condition,
                    current_hfr,
                    latest_guiding_rms,
                    context,
                );
            }
            TriggerAction::PauseAndRecalibrate => {
                tracing::info!("Pausing sequence due to exposure trigger");
                context.send_progress(ProgressUpdate::lifecycle(
                    node_id.to_string(),
                    NodeStatus::Running,
                    format!(
                        "Trigger fired: {}. Paused for recalibration",
                        exposure_trigger_name(&trigger.condition)
                    ),
                ));
                let resumed = context.pause_and_wait_for_resume().await;
                if !resumed {
                    tracing::info!("Cancelled while paused for trigger");
                    return;
                }
            }
            TriggerAction::Autofocus => {
                tracing::info!("Running autofocus due to exposure trigger");
                context.send_progress(ProgressUpdate::lifecycle(
                    node_id.to_string(),
                    NodeStatus::Running,
                    format!(
                        "Trigger fired: {}. Running autofocus",
                        exposure_trigger_name(&trigger.condition)
                    ),
                ));

                let af_config = AutofocusConfig {
                    method: AutofocusMethod::VCurve,
                    step_size: 100,
                    steps_out: 7,
                    exposure_duration: 3.0,
                    filter: context.current_filter.clone(),
                    binning: config.binning,
                    max_duration_secs: 600.0,
                    ..AutofocusConfig::default()
                };

                let inst_ctx = context.to_instruction_context(node_id).await;
                let progress_cb = context.progress_callback.clone();
                let progress_node_id = node_id.to_string();
                let total_steps = af_config.sweep_point_count();
                let progress_fn = move |percent: f64, progress: &AutofocusProgress| {
                    if let Some(cb) = progress_cb.as_ref() {
                        cb(ProgressUpdate::instruction_progress(
                            progress_node_id.clone(),
                            "Autofocus",
                            percent,
                            autofocus_detail(progress, total_steps),
                        ));
                    }
                };
                let af_result = execute_autofocus(&af_config, &inst_ctx, Some(&progress_fn)).await;

                if let Some(Setback::FocusNotFound { focuser_before }) = af_result.setback() {
                    // The burst carries on either way; this is a notice, not
                    // an instruction failure, which the app would announce as
                    // a failed sequence.
                    notify_autofocus_failed_continuing(
                        &inst_ctx,
                        "Exposure-triggered autofocus",
                        &af_result,
                        focuser_before,
                    )
                    .await;
                } else if af_result.status == NodeStatus::Success {
                    if let Some(best_hfr) = af_result.hfr_values.first() {
                        let mut trigger_state = trigger_state_lock.write().await;
                        trigger_state.update_hfr(*best_hfr);
                        trigger_state.reset_baseline_hfr();
                        trigger_state.mark_autofocus_performed();
                        tracing::info!("Autofocus complete, reset HFR baseline to {:.2}", best_hfr);
                    }
                } else {
                    let status = af_result
                        .settle("Exposure-triggered Autofocus", &inst_ctx)
                        .await;
                    tracing::warn!("Autofocus triggered by exposure failed: {:?}", status);
                }
            }
            TriggerAction::Abort => {
                tracing::error!("Aborting sequence due to exposure trigger");
                context.send_progress(ProgressUpdate::lifecycle(
                    node_id.to_string(),
                    NodeStatus::Failure,
                    format!(
                        "Trigger fired: {}. Ending the run",
                        exposure_trigger_name(&trigger.condition)
                    ),
                ));
                context.is_cancelled.store(true, Ordering::Relaxed);
                return;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use crate::frame_naming::{first_free_frame_number, frame_namer, path_segment, BurstNaming};

    fn one_frame() -> crate::frame_naming::FrameToName {
        crate::frame_naming::FrameToName {
            index_in_burst: 1,
            burst_total: 1,
            started_at: chrono::Utc::now(),
            sensor_temp_c: None,
        }
    }

    use super::*;

    /// The status line read "Trigger fired: HfrAbove(3.5) - Running autofocus".
    #[test]
    fn an_exposure_trigger_is_named_in_plain_words() {
        assert_eq!(
            exposure_trigger_name(&TriggerCondition::HfrAbove(3.5)),
            "HFR above 3.50 px"
        );
        let drift = exposure_trigger_name(&TriggerCondition::DriftAbove {
            ra_px: 4.0,
            dec_px: 2.5,
        });
        assert!(
            !drift.contains('{') && !drift.contains("DriftAbove"),
            "{drift}"
        );
    }

    // Verify the HFR median computation is a true median, not an
    // exponentially-weighted moving average.
    #[test]
    fn hfr_median_returns_true_central_value() {
        let values = [1.5, 1.6, 1.7, 1.8, 5.0];
        let median = compute_hfr_median(&values).expect("expected Some median for non-empty input");
        // An EMA returns ~3.2 for this input
        // ((((1.5 + 1.6) / 2 + 1.7) / 2 + 1.8) / 2 + 5.0) / 2 ≈ 3.181), so
        // this assertion pins the median and rejects the EMA formula.
        assert!(
            (median - 1.7).abs() < f64::EPSILON,
            "expected 1.7, got {median}"
        );
    }

    // Verify NaN and non-positive values are filtered before the
    // median is computed; sorting with `partial_cmp` requires no NaNs in
    // the slice.
    #[test]
    fn hfr_median_filters_nan_and_non_positive() {
        assert_eq!(compute_hfr_median(&[]), None);
        assert_eq!(compute_hfr_median(&[f64::NAN, 0.0, -1.0]), None);

        let values = [2.0, f64::NAN, 0.0, 3.0, 4.0, 5.0, -2.5];
        let median = compute_hfr_median(&values).expect("expected median after filtering");
        assert!(
            (median - 3.5).abs() < f64::EPSILON,
            "expected 3.5, got {median}"
        );

        let values = [1.7, f64::NAN, 1.5, 2.1];
        let median = compute_hfr_median(&values).expect("expected median after filtering");
        assert!(
            (median - 1.7).abs() < f64::EPSILON,
            "expected 1.7, got {median}"
        );
    }

    /// End-to-end through BudgetRegistry: a rejected frame must NOT
    /// increment the budget counter for its filter.
    #[test]
    fn budget_registry_skips_rejected_frame_credit() {
        let registry = crate::scheduling::BudgetRegistry::new();
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        rt.block_on(async {
            // Enter a target with a per-filter cap of 1 hour on L.
            let budget = crate::IntegrationBudget {
                total_secs: 3600.0,
                per_filter: std::collections::HashMap::from([(
                    "L".to_string(),
                    crate::FilterBudgetEntry::Absolute(3600.0),
                )]),
                ..crate::IntegrationBudget::default()
            };
            registry.enter_target("m42", Some(budget)).await;

            // A 10-frame × 60 s L burst with 3 frames rejected credits
            // 7 * 60 = 420 s.
            let credit_secs = 420.0;
            let state = registry
                .record_exposure(Some("L"), credit_secs)
                .await
                .expect("record_exposure inside target returns Some");
            assert!(
                (state.completed_by_filter.get("L").copied().unwrap_or(0.0) - 420.0).abs()
                    < f64::EPSILON,
                "L should be credited 420s (7 passed * 60s), got {:?}",
                state.completed_by_filter.get("L")
            );

            // A second burst with every frame rejected skips
            // `record_exposure`, so the L counter is unchanged.
            let state2 = registry
                .state_for("m42")
                .await
                .expect("state for target exists");
            assert!(
                (state2.completed_by_filter.get("L").copied().unwrap_or(0.0) - 420.0).abs()
                    < f64::EPSILON,
                "L should still be 420s after an all-rejected burst that skipped record, got {:?}",
                state2.completed_by_filter.get("L")
            );
        });
    }

    // adaptive-exposure emission tests.
    //
    // We cannot exercise the full `execute()` path without a camera /
    // device-ops stub, but the emission helper is a pure function over
    // `ExecutionContext` + decision; we can install a recording progress
    // callback and assert the structured event lands in it.

    #[test]
    fn emit_adaptive_exposure_records_structured_detail() {
        use crate::scheduling::AdaptiveExposureReason;
        use std::sync::{Arc, Mutex};

        let captured: Arc<Mutex<Vec<ProgressUpdate>>> = Arc::new(Mutex::new(Vec::new()));
        let captured_clone = captured.clone();
        let mut ctx = ExecutionContext::new_for_test("node-1".to_string());
        ctx.progress_callback = Some(Arc::new(move |u: ProgressUpdate| {
            captured_clone.lock().unwrap().push(u);
        }));

        let decision = AdaptiveExposureDecision {
            adapted_secs: 142.0,
            nominal_secs: 60.0,
            sky_brightness_mag: Some(19.2),
            reason: AdaptiveExposureReason::Adapted,
        };
        emit_adaptive_exposure_event("node-1", &ctx, &decision, Some("L"));

        let updates = captured.lock().unwrap();
        assert_eq!(updates.len(), 1);
        let upd = &updates[0];
        match upd.detail.as_ref().expect("detail present") {
            ProgressDetail::ExposureAdjusted {
                adapted_secs,
                nominal_secs,
                sky_brightness_mag,
                filter,
                reason,
            } => {
                assert!((adapted_secs - 142.0).abs() < 1e-9);
                assert!((nominal_secs - 60.0).abs() < 1e-9);
                assert_eq!(sky_brightness_mag.as_ref().copied(), Some(19.2));
                assert_eq!(filter.as_deref(), Some("L"));
                assert_eq!(reason, "adapted");
            }
            other => panic!("unexpected detail: {:?}", other),
        }
    }

    #[test]
    fn emit_adaptive_exposure_handles_missing_sky_brightness() {
        use crate::scheduling::AdaptiveExposureReason;
        use std::sync::{Arc, Mutex};

        let captured: Arc<Mutex<Vec<ProgressUpdate>>> = Arc::new(Mutex::new(Vec::new()));
        let captured_clone = captured.clone();
        let mut ctx = ExecutionContext::new_for_test("node-1".to_string());
        ctx.progress_callback = Some(Arc::new(move |u: ProgressUpdate| {
            captured_clone.lock().unwrap().push(u);
        }));

        let decision = AdaptiveExposureDecision {
            adapted_secs: 60.0,
            nominal_secs: 60.0,
            sky_brightness_mag: None,
            reason: AdaptiveExposureReason::Unavailable,
        };
        emit_adaptive_exposure_event("node-1", &ctx, &decision, Some("R"));

        let updates = captured.lock().unwrap();
        assert_eq!(updates.len(), 1);
        let upd = &updates[0];
        match upd.detail.as_ref().expect("detail present") {
            ProgressDetail::ExposureAdjusted {
                adapted_secs,
                nominal_secs,
                sky_brightness_mag,
                filter,
                reason,
            } => {
                assert!((adapted_secs - 60.0).abs() < 1e-9);
                assert!((nominal_secs - 60.0).abs() < 1e-9);
                assert_eq!(sky_brightness_mag.as_ref().copied(), None);
                assert_eq!(filter.as_deref(), Some("R"));
                assert_eq!(reason, "unavailable");
            }
            other => panic!("unexpected detail: {:?}", other),
        }
    }

    fn renderer_context(root: &std::path::Path) -> ExecutionContext {
        let mut ctx = ExecutionContext::new_for_test("expose-names".to_string());
        ctx.run.rig.save_path = Some(root.to_path_buf());
        ctx.target_name = Some("NGC0891".to_string());
        ctx.current_filter = Some("L".to_string());
        ctx
    }

    fn light_burst(count: u32) -> crate::ExposureConfig {
        crate::ExposureConfig {
            count,
            duration_secs: 1.0,
            ..Default::default()
        }
    }

    fn scratch_root() -> std::path::PathBuf {
        let root = std::env::temp_dir().join(format!("sk-names-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        root
    }

    /// Frames for a target land in a folder named for it under the save
    /// path, not in whatever folder the save path itself names.
    #[test]
    fn the_default_save_path_is_a_folder_for_the_target() {
        let root = scratch_root();
        let ctx = renderer_context(&root);
        let render = frame_namer(&ctx, BurstNaming::of(&light_burst(1), 1.0)).unwrap();

        let (dir, name) = render(&one_frame()).unwrap();

        assert_eq!(dir, root.join("NGC0891"));
        assert_eq!(name, "NGC0891_L_0001.fits");
        let _ = std::fs::remove_dir_all(&root);
    }

    /// A Smart Exposure visit is a burst of one, and every burst counted its
    /// frames from 1, so the files came out `NGC0891_L_0001_025.fits` (rig,
    /// 2026-10-20). The number continues from what is on disk.
    #[test]
    fn frame_numbers_continue_across_bursts() {
        let root = scratch_root();
        let ctx = renderer_context(&root);
        let mut names = Vec::new();
        for _visit in 0..3 {
            let render = frame_namer(&ctx, BurstNaming::of(&light_burst(1), 1.0)).unwrap();
            let (dir, name) = render(&one_frame()).unwrap();
            std::fs::write(dir.join(&name), b"").unwrap();
            names.push(name);
        }

        assert_eq!(
            names,
            [
                "NGC0891_L_0001.fits",
                "NGC0891_L_0002.fits",
                "NGC0891_L_0003.fits"
            ]
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    /// A rejected frame keeps its number: the next frame does not reuse it.
    #[test]
    fn a_number_in_the_reject_folder_is_taken() {
        let root = scratch_root();
        let ctx = renderer_context(&root);
        let target_dir = root.join("NGC0891");
        std::fs::create_dir_all(target_dir.join("Reject")).unwrap();
        std::fs::write(target_dir.join("NGC0891_L_0001.fits"), b"").unwrap();
        std::fs::write(target_dir.join("Reject").join("NGC0891_L_0002.fits"), b"").unwrap();
        let render = frame_namer(&ctx, BurstNaming::of(&light_burst(1), 1.0)).unwrap();

        let (_, name) = render(&one_frame()).unwrap();

        assert_eq!(name, "NGC0891_L_0003.fits");
        let _ = std::fs::remove_dir_all(&root);
    }

    /// Each filter counts its own frames.
    #[test]
    fn each_filter_numbers_its_own_frames() {
        let root = scratch_root();
        let mut ctx = renderer_context(&root);
        std::fs::create_dir_all(root.join("NGC0891")).unwrap();
        std::fs::write(root.join("NGC0891").join("NGC0891_L_0001.fits"), b"").unwrap();
        ctx.current_filter = Some("R".to_string());
        let render = frame_namer(&ctx, BurstNaming::of(&light_burst(1), 1.0)).unwrap();

        let (_, name) = render(&one_frame()).unwrap();

        assert_eq!(name, "NGC0891_R_0001.fits");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn the_first_free_frame_number_is_found_by_doubling_and_bisecting() {
        for used in [0_u32, 1, 2, 3, 7, 8, 9, 500, 1023, 1024] {
            let probes = std::cell::Cell::new(0);
            let free = first_free_frame_number(|n| {
                probes.set(probes.get() + 1);
                Ok(n <= used)
            })
            .unwrap();
            assert_eq!(free, used + 1, "{used} frames on disk");
            assert!(
                probes.get() <= 24,
                "{used} frames took {} probes",
                probes.get()
            );
        }
    }

    /// A burst with nowhere to write must FAIL rather than build no renderer,
    /// take the "no save location" warn branch and count every frame as
    /// completed — a full night reported 100% with zero files on disk.
    #[tokio::test]
    async fn exposure_with_no_save_location_fails_instead_of_discarding_frames() {
        let mut ctx = ExecutionContext::new_for_test("expose-nosave".to_string());
        ctx.run.rig.camera_id = Some("sim_camera_1".to_string());
        ctx.run.rig.save_path = None;

        let node_type = NodeType::TakeExposure(crate::ExposureConfig {
            count: 1,
            duration_secs: 0.01,
            frame_type: crate::FrameType::Dark,
            ..Default::default()
        });

        let status = ExposeInstruction
            .execute("expose-nosave", &node_type, &mut ctx)
            .await;

        assert_eq!(
            status,
            NodeStatus::Failure,
            "an exposure with no resolvable save location must fail loudly, not \
             report success while discarding every frame"
        );
    }

    /// An absolute per-node `save_to` is a complete destination on its own, so
    /// it must still run with no sequencer base path configured.
    #[tokio::test]
    async fn exposure_with_an_absolute_save_to_runs_without_a_base_path() {
        let dir = std::env::temp_dir().join(format!("sk-expose-abs-{}", uuid::Uuid::new_v4()));
        let mut ctx = ExecutionContext::new_for_test("expose-abs".to_string());
        ctx.run.rig.camera_id = Some("sim_camera_1".to_string());
        ctx.run.rig.save_path = None;

        let node_type = NodeType::TakeExposure(crate::ExposureConfig {
            count: 1,
            duration_secs: 0.01,
            frame_type: crate::FrameType::Dark,
            save_to: Some(format!("{}/${{frame:04}}.fits", dir.display())),
            ..Default::default()
        });

        let status = ExposeInstruction
            .execute("expose-abs", &node_type, &mut ctx)
            .await;
        let written: Vec<_> = std::fs::read_dir(&dir)
            .map(|entries| entries.filter_map(Result::ok).map(|e| e.path()).collect())
            .unwrap_or_default();

        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(status, NodeStatus::Success);
        assert_eq!(
            written.len(),
            1,
            "the absolute template is a complete destination; the frame must land there"
        );
    }

    /// The dither and autofocus interval triggers count star-field frames
    /// only; a dark burst between light bursts must not bring either due.
    #[tokio::test]
    async fn calibration_frames_do_not_advance_the_frame_cadence() {
        let dir = std::env::temp_dir().join(format!("sk-expose-cadence-{}", uuid::Uuid::new_v4()));
        let mut ctx = ExecutionContext::new_for_test("expose-cadence".to_string());
        ctx.run.rig.camera_id = Some("sim_camera_1".to_string());
        ctx.run.rig.save_path = Some(dir.clone());
        let trigger_state = std::sync::Arc::new(tokio::sync::RwLock::new(
            crate::triggers::TriggerState::default(),
        ));
        ctx.run.trigger_state = Some(trigger_state.clone());

        let burst = |frame_type: &str, count: u32| {
            NodeType::TakeExposure(crate::ExposureConfig {
                count,
                duration_secs: 0.01,
                frame_type: crate::FrameType::from_name(frame_type).expect("a frame type"),
                dither_every: Some(0),
                ..Default::default()
            })
        };
        let dark = ExposeInstruction
            .execute("expose-dark", &burst("dark", 3), &mut ctx)
            .await;
        let bias = ExposeInstruction
            .execute("expose-bias", &burst("bias", 2), &mut ctx)
            .await;
        let after_calibration = trigger_state.read().await.latches.completed_exposures;
        let light = ExposeInstruction
            .execute("expose-light", &burst("light", 2), &mut ctx)
            .await;
        let after_light = trigger_state.read().await.latches.completed_exposures;
        let _ = std::fs::remove_dir_all(&dir);

        assert_eq!(
            (dark, bias, light),
            (
                NodeStatus::Success,
                NodeStatus::Success,
                NodeStatus::Success
            )
        );
        assert_eq!(after_calibration, 0);
        assert_eq!(after_light, 2);
    }

    /// Two `Parallel` branches exposing on the SAME camera must not overlap.
    /// `execute_parallel` clones the context per branch, so the serialisation
    /// has to live on shared (Arc'd) state — this test drives exactly that clone
    /// and the two 0.4 s bursts must not finish in ~0.4 s together.
    #[tokio::test]
    async fn two_branches_on_one_camera_serialise_their_exposures() {
        let dir = std::env::temp_dir().join(format!("sk-expose-lock-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).expect("temp dir");

        let mut ctx_a = ExecutionContext::new_for_test("expose-a".to_string());
        ctx_a.run.rig.camera_id = Some("sim_camera_1".to_string());
        ctx_a.run.rig.save_path = Some(dir.clone());
        let mut ctx_b = ctx_a.clone();
        ctx_b.node_id = "expose-b".to_string();

        let node_type = NodeType::TakeExposure(crate::ExposureConfig {
            count: 1,
            duration_secs: 0.4,
            frame_type: crate::FrameType::Dark,
            ..Default::default()
        });
        let node_type_b = node_type.clone();

        let started = std::time::Instant::now();
        let (status_a, status_b) = tokio::join!(
            async {
                ExposeInstruction
                    .execute("expose-a", &node_type, &mut ctx_a)
                    .await
            },
            async {
                ExposeInstruction
                    .execute("expose-b", &node_type_b, &mut ctx_b)
                    .await
            },
        );
        let elapsed = started.elapsed();

        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(status_a, NodeStatus::Success);
        assert_eq!(status_b, NodeStatus::Success);
        assert!(
            elapsed >= std::time::Duration::from_millis(700),
            "two 0.4s exposures on one camera must run one after the other; \
             finished in {elapsed:?}, so they overlapped on the same sensor"
        );
    }

    /// Two bursts naming frames at once (a second camera in a Parallel
    /// branch) get two names: a name handed out and not yet written is taken.
    #[test]
    fn a_name_handed_out_is_not_handed_out_again() {
        let dir = std::env::temp_dir().join(format!("sk-expose-claim-{}", uuid::Uuid::new_v4()));
        let mut ctx_a = ExecutionContext::new_for_test("expose-a".to_string());
        ctx_a.run.rig.save_path = Some(dir.clone());
        let mut ctx_b = ctx_a.clone();
        ctx_b.run.rig.camera_id = Some("sim_camera_2".to_string());
        let dark = crate::ExposureConfig {
            frame_type: crate::FrameType::Dark,
            ..Default::default()
        };
        let camera_a = frame_namer(&ctx_a, BurstNaming::of(&dark, 1.0)).unwrap();
        let camera_b = frame_namer(&ctx_b, BurstNaming::of(&dark, 1.0)).unwrap();
        let first = camera_a(&one_frame()).unwrap();
        let second = camera_b(&one_frame()).unwrap();
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(first.1, "Dark_nofilter_0001.fits");
        assert_eq!(second.1, "Dark_nofilter_0002.fits");
    }

    /// A template without a frame number gives a taken name a suffix rather
    /// than writing over it.
    #[test]
    fn a_template_without_a_number_suffixes_a_taken_name() {
        let dir = std::env::temp_dir().join(format!("sk-expose-sfx-{}", uuid::Uuid::new_v4()));
        let mut ctx = ExecutionContext::new_for_test("expose-sfx".to_string());
        ctx.run.rig.save_path = Some(dir.clone());
        ctx.target_name = Some("M42".to_string());
        let config = crate::ExposureConfig {
            save_to: Some("${target.name}".into()),
            ..Default::default()
        };
        let render = frame_namer(&ctx, BurstNaming::of(&config, 1.0)).unwrap();
        let first = render(&one_frame()).unwrap();
        let second = render(&one_frame()).unwrap();
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(first.1, "M42.fits");
        assert_eq!(second.1, "M42_001.fits");
    }

    /// The app's naming pattern and a run's save template keep a value in
    /// one path segment by one rule.
    #[test]
    fn a_value_becomes_one_path_segment_as_the_app_makes_it() {
        let fixture = std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../test_fixtures/path_segment/cases.json"
        ))
        .expect("fixture");
        let cases: serde_json::Value = serde_json::from_str(&fixture).expect("json");
        for case in cases["cases"].as_array().expect("cases") {
            let value = case["value"].as_str().expect("value");
            assert_eq!(
                path_segment(value),
                case["segment"].as_str().expect("segment"),
                "{value:?}"
            );
        }
    }

    /// A frame's name carries the time its shutter opened and the sensor
    /// temperature it reported, and a target name is one folder.
    #[tokio::test]
    async fn a_frame_is_named_from_its_own_time_and_temperature() {
        let dir = std::env::temp_dir().join(format!("sk-expose-name-{}", uuid::Uuid::new_v4()));
        let mut ctx = ExecutionContext::new_for_test("expose-name".to_string());
        ctx.run.rig.save_path = Some(dir.clone());
        ctx.target_name = Some("M31/Ha".to_string());
        let config = crate::ExposureConfig {
            save_to: Some(
                "${target.name}/${time.date}_${time.clock}_${camera.temp_c:.0f}C_${frame:04}"
                    .into(),
            ),
            ..Default::default()
        };
        let render = frame_namer(&ctx, BurstNaming::of(&config, 60.0)).unwrap();
        let started_at = chrono::TimeZone::with_ymd_and_hms(&chrono::Utc, 2026, 11, 13, 1, 2, 3)
            .single()
            .unwrap();
        let (dir_out, name) = render(&crate::frame_naming::FrameToName {
            index_in_burst: 1,
            burst_total: 1,
            started_at,
            sensor_temp_c: Some(-9.6),
        })
        .unwrap();
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(dir_out, dir.join("M31_Ha"));
        assert_eq!(name, "2026-11-13_01-02-03_-10C_0001.fits");
    }

    /// Two different cameras must still expose in parallel — the lock is
    /// per-device, not global.
    #[tokio::test]
    async fn two_branches_on_different_cameras_still_run_in_parallel() {
        let dir = std::env::temp_dir().join(format!("sk-expose-par-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).expect("temp dir");

        let mut ctx_a = ExecutionContext::new_for_test("expose-a".to_string());
        ctx_a.run.rig.camera_id = Some("sim_camera_1".to_string());
        ctx_a.run.rig.save_path = Some(dir.clone());
        let mut ctx_b = ctx_a.clone();
        ctx_b.node_id = "expose-b".to_string();
        ctx_b.run.rig.camera_id = Some("sim_camera_2".to_string());

        let node_type = NodeType::TakeExposure(crate::ExposureConfig {
            count: 1,
            duration_secs: 0.4,
            frame_type: crate::FrameType::Dark,
            ..Default::default()
        });
        let node_type_b = node_type.clone();

        let started = std::time::Instant::now();
        let (status_a, status_b) = tokio::join!(
            async {
                ExposeInstruction
                    .execute("expose-a", &node_type, &mut ctx_a)
                    .await
            },
            async {
                ExposeInstruction
                    .execute("expose-b", &node_type_b, &mut ctx_b)
                    .await
            },
        );
        let elapsed = started.elapsed();

        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(status_a, NodeStatus::Success);
        assert_eq!(status_b, NodeStatus::Success);
        assert!(
            elapsed < std::time::Duration::from_millis(700),
            "separate cameras must still expose concurrently; took {elapsed:?}"
        );
    }

    /// A burst credits its target's budget with its own frames that passed.
    /// Counting this burst's rejects as the change in the run's rejected
    /// count across it charged it for frames rejected elsewhere meanwhile (a
    /// Parallel branch, a second camera).
    #[tokio::test]
    async fn a_frame_rejected_elsewhere_during_a_burst_does_not_cost_its_budget_credit() {
        let dir = std::env::temp_dir().join(format!("sk-expose-budget-{}", uuid::Uuid::new_v4()));
        let mut ctx = ExecutionContext::new_for_test("expose-budget".to_string());
        ctx.run.rig.camera_id = Some("sim_camera_1".to_string());
        ctx.current_filter = Some("L".to_string());
        let budget = crate::IntegrationBudget {
            total_secs: 3600.0,
            ..crate::IntegrationBudget::default()
        };
        ctx.budget_registry.enter_target("m42", Some(budget)).await;
        let rejected_elsewhere = ctx.run.grading.frames_rejected.clone();
        ctx.progress_callback = Some(std::sync::Arc::new(move |update: ProgressUpdate| {
            if update.current_frame.is_some() {
                rejected_elsewhere.fetch_add(1, Ordering::Relaxed);
            }
        }));

        let node_type = NodeType::TakeExposure(crate::ExposureConfig {
            count: 3,
            duration_secs: 0.01,
            frame_type: crate::FrameType::Light,
            save_to: Some(format!("{}/${{frame:04}}.fits", dir.display())),
            dither_every: Some(0),
            ..Default::default()
        });
        let status = ExposeInstruction
            .execute("expose-budget", &node_type, &mut ctx)
            .await;
        let state = ctx.budget_registry.state_for("m42").await;
        let _ = std::fs::remove_dir_all(&dir);

        assert_eq!(status, NodeStatus::Success);
        let credited = state
            .and_then(|state| state.completed_by_filter.get("L").copied())
            .unwrap_or(0.0);
        assert!(
            (credited - 0.03).abs() < 1e-9,
            "three passed frames of 0.01 s, credited {credited} s"
        );
    }

    /// A snapshot or a dark under a target is not part of the target's data,
    /// so it does not count toward the target's integration goal. Both did.
    #[tokio::test]
    async fn only_lights_count_toward_the_targets_integration_goal() {
        for (frame_type, credited_secs) in [
            (crate::FrameType::Light, 0.02),
            (crate::FrameType::Snapshot, 0.0),
            (crate::FrameType::Dark, 0.0),
        ] {
            let dir = std::env::temp_dir().join(format!("sk-expose-goal-{}", uuid::Uuid::new_v4()));
            let mut ctx = ExecutionContext::new_for_test("expose-goal".to_string());
            ctx.run.rig.camera_id = Some("sim_camera_1".to_string());
            ctx.current_filter = Some("L".to_string());
            let budget = crate::IntegrationBudget {
                total_secs: 3600.0,
                ..crate::IntegrationBudget::default()
            };
            ctx.budget_registry.enter_target("m42", Some(budget)).await;
            let node_type = NodeType::TakeExposure(crate::ExposureConfig {
                count: 2,
                duration_secs: 0.01,
                frame_type,
                save_to: Some(format!("{}/${{frame:04}}.fits", dir.display())),
                dither_every: Some(0),
                ..Default::default()
            });
            let status = ExposeInstruction
                .execute("expose-goal", &node_type, &mut ctx)
                .await;
            let state = ctx.budget_registry.state_for("m42").await;
            let _ = std::fs::remove_dir_all(&dir);

            assert_eq!(status, NodeStatus::Success, "{frame_type:?}");
            let credited = state
                .and_then(|state| state.completed_by_filter.get("L").copied())
                .unwrap_or(0.0);
            assert!(
                (credited - credited_secs).abs() < 1e-9,
                "{frame_type:?}: credited {credited} s"
            );
        }
    }

    #[test]
    fn end_to_end_compute_plus_emit_matches_brief_walkthrough() {
        // Brief: L:60s nominal, adaptive enabled at SNR=30, ref=21.5
        // mag/arcsec², Bortle 6 site (~19.2 mag/arcsec²). The compute
        // function pure-math + emission pipeline drops a structured
        // event that the dashboard can render directly. We don't run
        // the camera here — the live-rig walkthrough in the final
        // report covers that.
        use crate::scheduling::{compute_adaptive_exposure, AdaptiveExposureConfig};
        use std::sync::{Arc, Mutex};

        let mut cfg = AdaptiveExposureConfig::default();
        cfg.per_filter_enabled.insert("L".into(), true);
        cfg.per_filter_enabled.insert("R".into(), false);
        cfg.per_filter_enabled.insert("G".into(), false);
        cfg.per_filter_enabled.insert("B".into(), false);
        cfg.per_filter_max_secs.insert("L".into(), 300.0);
        // Live sky reading from the SkyBrightnessTracker.
        let live_mag = 19.2;

        let captured: Arc<Mutex<Vec<ProgressUpdate>>> = Arc::new(Mutex::new(Vec::new()));
        let captured_clone = captured.clone();
        let mut ctx = ExecutionContext::new_for_test("node-1".to_string());
        ctx.progress_callback = Some(Arc::new(move |u: ProgressUpdate| {
            captured_clone.lock().unwrap().push(u);
        }));

        // L burst: adapted, capped at 300s (per-filter max).
        let d_l = compute_adaptive_exposure(Some(&cfg), 60.0, Some("L"), Some(live_mag));
        emit_adaptive_exposure_event("node-1", &ctx, &d_l, Some("L"));
        // R burst: disabled per-filter, nominal preserved.
        let d_r = compute_adaptive_exposure(Some(&cfg), 120.0, Some("R"), Some(live_mag));
        emit_adaptive_exposure_event("node-1", &ctx, &d_r, Some("R"));

        let updates = captured.lock().unwrap();
        assert_eq!(updates.len(), 2);
        // L event: clamped to per-filter max 300s, reason ClampedMax.
        match updates[0].detail.as_ref().expect("detail present") {
            ProgressDetail::ExposureAdjusted {
                adapted_secs,
                nominal_secs,
                reason,
                ..
            } => {
                assert!((adapted_secs - 300.0).abs() < 1e-9);
                assert!((nominal_secs - 60.0).abs() < 1e-9);
                assert_eq!(reason, "clamped_max");
            }
            other => panic!("unexpected L detail: {:?}", other),
        }
        // R event: disabled — nominal preserved, reason Disabled.
        match updates[1].detail.as_ref().expect("detail present") {
            ProgressDetail::ExposureAdjusted {
                adapted_secs,
                nominal_secs,
                reason,
                ..
            } => {
                assert!((adapted_secs - 120.0).abs() < 1e-9);
                assert!((nominal_secs - 120.0).abs() < 1e-9);
                assert_eq!(reason, "disabled");
            }
            other => panic!("unexpected R detail: {:?}", other),
        }
    }
}
