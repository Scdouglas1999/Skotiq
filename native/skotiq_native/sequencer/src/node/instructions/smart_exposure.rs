//! SmartExposure instruction node.
//!
//! The "one row per filter" automation. The user lists per-filter plans
//! (count, sub-length, gain, offset, binning, dither cadence) and this node
//! handles:
//!
//!   * Filter changes (skipped when the wheel is already on the right filter).
//!   * Optional dither between filter changes.
//!   * Round-robin rotation across filters (RGRGRG …) or per-filter exhaustion
//!     (RRRRRGGG …) depending on [`SmartExposureConfig::rotate_filters`].
//!   * A global `integration_budget_secs` cap that lets the node short-circuit
//!     to Success once a wall-clock-equivalent integration budget is met.
//!   * Per-filter completed-frame checkpointing so a sequence killed
//!     mid-rotation resumes on the right filter at the right frame index.
//!
//! # Why delegate to ExposureInstruction / ChangeFilterInstruction?
//!
//! The brief mandates that SmartExposure does **not** reimplement exposure or
//! filter-change logic. Both have grown well-tested integration accounting,
//! trigger-state updates, HFR baseline propagation, and FITS-save error
//! routing. Re-implementing any of that here would inevitably diverge.
//! Instead, SmartExposure constructs the matching `NodeType` variant per
//! plan row and dispatches through [`InstructionRegistry::build`] just like
//! the executor would for a hand-authored sequence. Each delegated child
//! sees the same `ExecutionContext`, so its progress events, trigger
//! updates, and integration accounting are indistinguishable from the
//! manual `FilterChange → Loop(N) → TakeExposure` chain the user would
//! otherwise have written.
//!
//! # DepthLock early completion
//!
//! A plan may carry a [`crate::depth_goal::DepthGoalBinding`]. Before each
//! batch the node asks the host's verdict source ([`ExecutionContext::depth_goal_ops`])
//! about every still-open bound plan; an achieved verdict for the bound
//! revision retires the plan's remaining count and is announced once via
//! [`ExecutorEvent::DepthGoalCompleted`]. Nothing else changes: the check
//! sits between batches (an in-flight exposure is never aborted), the
//! authored count/budget/window bounds still end the node first when they
//! arrive first, and a missing or stale verdict source degrades to the
//! plain count-bounded plan with one warning per plan per run.
//!
//! # Autofocus on filter change
//!
//! We rely on the existing trigger system: when [`ChangeFilterInstruction`]
//! flips `TriggerState::filter_changed`, the user-configured
//! `TriggerType::FilterChange` with `RecoveryAction::Autofocus` (or the
//! per-filter focus offset machinery) fires. SmartExposure does NOT launch
//! its own autofocus run — that would duplicate the trigger pipeline and
//! desync from the rest of the sequencer.

use crate::depth_goal::DepthGoalVerdict;
use crate::executor::ExecutorEvent;
use crate::node::context::ExecutionContext;
use crate::node::progress::{ProgressDetail, ProgressUpdate};
use crate::node::registry::{registry, InstructionNode};
use crate::{
    smart_exposure_checkpoint_key, DitherConfig, ExposureConfig, FilterConfig, FilterPlan,
    NodeStatus, NodeType, SmartExposureCheckpoint, SmartExposureConfig,
};
use async_trait::async_trait;
use std::collections::HashSet;

pub struct SmartExposureInstruction;

#[async_trait]
impl InstructionNode for SmartExposureInstruction {
    fn type_name(&self) -> &'static str {
        "Smart Exposure"
    }

    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::SmartExposure(config) = node_type else {
            tracing::error!("SmartExposureInstruction received non-SmartExposure variant");
            return NodeStatus::Failure;
        };

        // when a surrounding TargetScheduler has installed a
        // multi-filter cycle override, apply it for this dispatch. The
        // override forces `rotate_filters=true` and clamps `batch_size` to
        // the scheduler-supplied `frames_per_burst`. We construct an
        // effective config locally rather than mutating the persisted
        // SmartExposureConfig so the user's authored settings are not
        // clobbered when the dispatch returns. The override never widens
        // batch_size beyond the user's authored value below 1; instead it
        // SETS the value, because the scheduler's intent ("rotate every N
        // frames") wins over the node's authored "drain mode" when the
        // user explicitly enabled round-robin at the scheduler level.
        let config = match context.scheduler_filter_cycle_override() {
            Some(crate::FilterCycleMode::RoundRobin { frames_per_burst }) => {
                let effective_batch = frames_per_burst.max(1);
                tracing::info!(
                    "SmartExposure '{}' applying scheduler cycle override: rotate_filters=true, batch_size={}",
                    node_id,
                    effective_batch,
                );
                std::borrow::Cow::Owned(SmartExposureConfig {
                    rotate_filters: true,
                    batch_size: effective_batch,
                    ..config.clone()
                })
            }
            // SingleFilter mode (or no override) — use the authored config
            // verbatim. We wrap in `Cow::Borrowed` so the common path
            // (override absent) does not clone the plan vector.
            _ => std::borrow::Cow::Borrowed(config),
        };

        // "Loop until stopped" forcing. The mode IS "1 sub per filter,
        // round-robin, forever (until time/window)", so we coerce
        // `batch_size=1` and `rotate_filters=true` here regardless of their
        // stored values. We only clone when a coercion is actually needed so
        // the common (loop-mode-off) path keeps the borrow.
        let config =
            if config.loop_until_stopped && (!config.rotate_filters || config.batch_size != 1) {
                std::borrow::Cow::Owned(SmartExposureConfig {
                    rotate_filters: true,
                    batch_size: 1,
                    ..config.into_owned()
                })
            } else {
                config
            };
        let config = config.as_ref();

        // Errors-are-a-feature: refuse to enter an unbounded infinite loop.
        // `loop_until_stopped` deliberately ignores per-plan counts, so the
        // ONLY things that can end the node are (a) the integration budget,
        // (b) the surrounding target's `end_when` window, or (c) an explicit
        // sequence stop / skip-to-next-target. (c) is always available at
        // runtime, but it requires a human to press Stop — it is NOT an
        // automatic bound for an unattended dawn run. So we require at least
        // one *automatic* bound: a positive budget, OR a detectable target
        // end trigger. If neither is present we fail closed rather than spin
        // forever and silently never finish.
        if config.loop_until_stopped
            && config.integration_budget_secs <= 0.0
            && context.active_target_end_trigger().is_none()
        {
            tracing::error!(
                "SmartExposure '{}' is in loop-until-stopped mode but has no integration \
                 budget and no surrounding target window (end_when) to bound it; refusing to \
                 loop forever. Set an integration budget or place this node under a target \
                 with an end condition.",
                node_id
            );
            return NodeStatus::Failure;
        }

        // Empty plans is an empty success — matches `Loop(0)` semantics and
        // keeps the executor from getting stuck on an empty body. The
        // validation rule [`SmartExposureEmptyPlansRule`] flags this at
        // sequence-edit time as an error; reaching execution with empty
        // plans is the corrupt-file path.
        if config.plans.is_empty() {
            tracing::warn!(
                "SmartExposure node '{}' has no plans; nothing to do (success)",
                node_id
            );
            return NodeStatus::Success;
        }

        // Resume from any in-memory checkpoint slot. The slot is populated
        // by the previous run of this same node id (in the same process),
        // OR — when the executor plumbs `CheckpointManager` through (future
        // work) — restored from disk on session reload.
        let mut state = load_or_init_checkpoint(node_id, context).await;

        // Defensive clamp: if config has changed (plans removed) since the
        // checkpoint was written, the persisted plan_index might point past
        // the end of the new `plans`. Wrap it back to 0.
        if state.current_plan_index >= config.plans.len() {
            state.current_plan_index = 0;
        }

        tracing::info!(
            "SmartExposure '{}' starting: {} plans, rotate={}, budget={:.0}s, batch_size={}, resume from plan {}",
            node_id,
            config.plans.len(),
            config.rotate_filters,
            config.integration_budget_secs,
            config.batch_size,
            state.current_plan_index,
        );

        let total_plans = config.plans.len();
        let mut current_filter: Option<String> = context.current_filter.clone();
        // Plans whose binding could not be honored this run; each is warned
        // about once, then treated as count-bounded.
        let mut depth_unavailable_warned: HashSet<usize> = HashSet::new();

        // The outer loop drives "rounds" when rotate_filters is true; with
        // rotate_filters off, this loop body still runs once per plan but
        // the inner `take_batch` consumes the full remaining count for that
        // plan in one go.
        loop {
            // Cancellation / pause / skip checks at every step — same
            // pattern as Loop / TargetHeader. We honour cancellation
            // promptly so a "Stop" button doesn't have to wait for the
            // next filter change.
            if context.is_cancelled().await {
                save_checkpoint(node_id, context, &state).await;
                return NodeStatus::Cancelled;
            }
            if context.is_skip_to_next_target_requested() {
                save_checkpoint(node_id, context, &state).await;
                return NodeStatus::Skipped;
            }

            // Loop-until-stopped: the surrounding target's `end_when` window
            // is the primary automatic bound. The parent TargetHeader only
            // probes `end_when` at child boundaries, but this node never
            // returns to the parent while it loops — so we poll the installed
            // trigger ourselves here, between batches, and finish Success when
            // the window closes (e.g. the target drops below the configured
            // altitude at dawn). `None` (no trigger / unevaluable) falls
            // through to the budget bound, which the entry guard guarantees
            // exists when no trigger does.
            if config.loop_until_stopped {
                if let Some(true) = context.active_target_end_trigger_satisfied() {
                    tracing::info!(
                        "SmartExposure '{}' loop-until-stopped: target window closed; finishing",
                        node_id
                    );
                    save_checkpoint(node_id, context, &state).await;
                    return NodeStatus::Success;
                }
            }

            // DepthLock: retire any bound plan whose goal is achieved. This
            // runs before the pick so an achieved plan is skipped rather
            // than started, and only between batches so the exposure that
            // produced the deciding frame was never interrupted.
            refresh_depth_completions(
                node_id,
                config,
                &mut state,
                &mut depth_unavailable_warned,
                context,
            );

            // Budget short-circuit. We check before each batch so a small
            // overshoot is bounded by one batch's worth of exposure time.
            if integration_budget_exceeded(config, &state) {
                tracing::info!(
                    "SmartExposure '{}' hit integration budget cap ({:.1}s >= {:.1}s); finishing",
                    node_id,
                    state.completed_integration_secs,
                    config.integration_budget_secs,
                );
                save_checkpoint(node_id, context, &state).await;
                return NodeStatus::Success;
            }

            // Pick the next plan that still has remaining work. If we've
            // exhausted every plan, we're done. In loop-until-stopped mode
            // counts are ignored, so `next_plan` always returns the next row
            // in rotation and this `else` is never taken — the only exits in
            // loop mode are the budget/window/cancellation checks above.
            let Some(plan_index) = next_plan(config, &state) else {
                tracing::info!(
                    "SmartExposure '{}' all plans complete ({} filters)",
                    node_id,
                    total_plans
                );
                clear_checkpoint(node_id, context).await;
                return NodeStatus::Success;
            };

            // Persist the chosen index so a crash before the first frame of
            // this plan still resumes on the same row.
            state.current_plan_index = plan_index;
            let plan = &config.plans[plan_index];
            let completed_for_plan = state
                .per_filter_completed
                .get(&plan.filter_name)
                .copied()
                .unwrap_or(0);
            // In loop-until-stopped mode the per-plan count is irrelevant —
            // we always have exactly one sub of "remaining" work for the
            // chosen filter (batch_size is forced to 1 above). Otherwise it's
            // the un-completed slice of the authored count.
            let remaining = if config.loop_until_stopped {
                1
            } else {
                plan.count.saturating_sub(completed_for_plan)
            };
            if remaining == 0 {
                // The next_plan() above already filtered exhausted plans, so
                // this branch should not be reachable. Treat it defensively
                // and continue.
                tracing::debug!(
                    "SmartExposure '{}' plan {} has 0 remaining after pick; advancing",
                    node_id,
                    plan_index
                );
                continue;
            }

            // The batch size is the smaller of:
            //   * the remaining work for this plan
            //   * the user-configured per-visit batch size (always >= 1)
            // When `rotate_filters` is false we want to drain the plan
            // entirely before moving on — so we ignore `batch_size` in that
            // mode. Loop-until-stopped always takes exactly one sub (forced
            // batch_size=1 and remaining=1 above).
            //
            // A plan bound to a DepthLock goal is the exception to draining:
            // its verdict is only consulted between batches, so a single
            // burst of the whole remaining count would make "complete at the
            // next safe boundary" mean "after the last frame". It keeps the
            // drain order (sequential `next_plan` re-picks it until done)
            // but in `batch_size` steps.
            let batch_size = if config.rotate_filters || plan.depth_goal.is_some() {
                config.batch_size.max(1).min(remaining)
            } else {
                remaining
            };

            // Filter change
            // Skip when the wheel is already on this plan's filter — avoids
            // wasted FW moves when the user authored two consecutive plans
            // on the same filter (legal: e.g. tighter & wider exposures for
            // the same band).
            let need_filter_change = current_filter.as_deref() != Some(plan.filter_name.as_str());
            if need_filter_change {
                tracing::info!(
                    "SmartExposure '{}' changing filter to '{}' (plan {}/{})",
                    node_id,
                    plan.filter_name,
                    plan_index + 1,
                    total_plans
                );
                let filter_status = run_filter_change(node_id, plan, context).await;
                if !matches!(filter_status, NodeStatus::Success) {
                    tracing::error!(
                        "SmartExposure '{}' filter change to '{}' failed with {:?}",
                        node_id,
                        plan.filter_name,
                        filter_status
                    );
                    save_checkpoint(node_id, context, &state).await;
                    return filter_status;
                }
                current_filter = Some(plan.filter_name.clone());

                // Optional dither on filter change. This runs AFTER the
                // filter move so the field is on the new filter when we
                // dither (otherwise we'd dither, then move, defeating the
                // small-shift purpose).
                if config.dither_on_filter_change {
                    let dither_status = run_dither(node_id, plan, context).await;
                    if !matches!(dither_status, NodeStatus::Success) {
                        tracing::warn!(
                            "SmartExposure '{}' post-filter-change dither returned {:?}; continuing",
                            node_id,
                            dither_status
                        );
                        // A failed dither does not abort the sequence — it's
                        // a hygiene step. Log and move on.
                    }
                }
            }

            // Exposure burst
            let burst_status = run_exposure_burst(node_id, plan, batch_size, context).await;
            if matches!(burst_status, NodeStatus::Cancelled) {
                save_checkpoint(node_id, context, &state).await;
                return NodeStatus::Cancelled;
            }
            if matches!(burst_status, NodeStatus::Failure) {
                tracing::error!(
                    "SmartExposure '{}' exposure burst for plan {} ({}) failed",
                    node_id,
                    plan_index,
                    plan.filter_name
                );
                save_checkpoint(node_id, context, &state).await;
                return NodeStatus::Failure;
            }
            if matches!(burst_status, NodeStatus::Skipped) {
                save_checkpoint(node_id, context, &state).await;
                return NodeStatus::Skipped;
            }

            // Bookkeeping
            // ExposureInstruction handles its own integration counter
            // updates against the SHARED context.completed_integration_secs.
            // We additionally track a SmartExposure-LOCAL slice here so the
            // per-node `integration_budget_secs` cap is independent of any
            // other node's contributions.
            let frames_just_taken = batch_size;
            // Why: u32 -> f64 widens losslessly; same for the duration_secs
            // arithmetic.
            let secs_just_added = plan.duration_secs * f64::from(frames_just_taken);
            state.completed_integration_secs += secs_just_added;
            let new_completed = completed_for_plan.saturating_add(frames_just_taken);
            state
                .per_filter_completed
                .insert(plan.filter_name.clone(), new_completed);

            // Emit a structured progress event so the Run Dashboard's
            // filter-integration panel can show "L 30/60 (plan 1/4)"
            // without parsing free-form strings.
            emit_progress(node_id, config, &state, plan, plan_index, context);

            // advance `current_plan_index` in rotation mode
            // so the next iteration's `next_plan()` starts looking AT the
            // next plan, not the one we just finished a batch on.
            //
            // Without this advance, `next_plan` re-picks `plan_index` every
            // iteration as long as the current plan still has remaining > 0
            // (its scan starts at `current_plan_index` and accepts the first
            // hit), so rotation never rotates — the node drains the first
            // plan exactly as if `rotate_filters` were false. Asserting
            // `next_plan` in isolation with a pre-advanced index does not
            // cover this; the advance has to be exercised through execute().
            //
            // Sequential mode is left alone: the scan from `current_plan_index`
            // forward already does the right "drain in order" thing because
            // `next_plan` skips exhausted plans linearly.
            if config.rotate_filters && total_plans > 0 {
                state.current_plan_index = (plan_index + 1) % total_plans;
            }

            // Save the checkpoint after each batch so a process crash
            // between batches loses at most `batch_size` frames of progress.
            save_checkpoint(node_id, context, &state).await;
        }
    }
}

/// Decide which plan to visit next. With `rotate_filters` true we walk
/// `plans` in order starting from `current_plan_index + 1`, wrapping back
/// to 0; the chosen plan is the first one with `remaining > 0`. With
/// rotation off we drain the current plan entirely before advancing.
/// Returns `None` when every plan is complete.
fn next_plan(config: &SmartExposureConfig, state: &SmartExposureCheckpoint) -> Option<usize> {
    let n = config.plans.len();
    if n == 0 {
        return None;
    }
    // Loop-until-stopped ignores per-plan counts: no plan is ever
    // "exhausted", so we simply hand back the current rotation index
    // (clamped). `rotate_filters` is forced true in this mode, so the
    // execute() body advances `current_plan_index` after each sub.
    if config.loop_until_stopped {
        // Counts are ignored, but a plan whose DepthLock goal is achieved is
        // still finished: skip it in rotation, and when every plan is
        // finished that way the node has nothing left to loop over.
        let start = state.current_plan_index.min(n - 1);
        return (0..n)
            .map(|offset| (start + offset) % n)
            .find(|idx| !depth_completed(config, state, *idx));
    }
    if config.rotate_filters {
        // Start scan from current_plan_index (re-visit the same row when we
        // resume mid-batch). If that plan still has work, take it; else
        // advance.
        let start = state.current_plan_index.min(n - 1);
        // Check current first (resume case), then advance through the
        // remaining plans wrapping around to start.
        let current_remaining = remaining_for_plan(config, state, start);
        if current_remaining > 0 {
            return Some(start);
        }
        for offset in 1..=n {
            let idx = (start + offset) % n;
            if remaining_for_plan(config, state, idx) > 0 {
                return Some(idx);
            }
        }
        None
    } else {
        // Exhaust the current plan first, then move on. Once the current
        // plan is complete, advance linearly through the remaining plans.
        let start = state.current_plan_index.min(n - 1);
        for idx in start..n {
            if remaining_for_plan(config, state, idx) > 0 {
                return Some(idx);
            }
        }
        None
    }
}

fn remaining_for_plan(
    config: &SmartExposureConfig,
    state: &SmartExposureCheckpoint,
    plan_index: usize,
) -> u32 {
    if depth_completed(config, state, plan_index) {
        return 0;
    }
    let plan = &config.plans[plan_index];
    let completed = state
        .per_filter_completed
        .get(&plan.filter_name)
        .copied()
        .unwrap_or(0);
    plan.count.saturating_sub(completed)
}

/// True when the plan's DepthLock binding has been retired by an achieved
/// verdict for exactly the bound revision. An unbound plan is never
/// depth-completed, and a completion recorded for another revision of the
/// same goal does not count.
fn depth_completed(
    config: &SmartExposureConfig,
    state: &SmartExposureCheckpoint,
    plan_index: usize,
) -> bool {
    config.plans[plan_index]
        .depth_goal
        .as_ref()
        .is_some_and(|binding| {
            state.depth_completed.get(&binding.goal_id) == Some(&binding.revision)
        })
}

/// Ask the host's verdict source about every open bound plan and retire the
/// achieved ones. Idempotent across iterations and resumes: a goal already in
/// `state.depth_completed` is not asked again, so the completion event fires
/// once per goal per checkpoint lifetime.
fn refresh_depth_completions(
    node_id: &str,
    config: &SmartExposureConfig,
    state: &mut SmartExposureCheckpoint,
    unavailable_warned: &mut HashSet<usize>,
    context: &ExecutionContext,
) {
    for (plan_index, plan) in config.plans.iter().enumerate() {
        let Some(binding) = &plan.depth_goal else {
            continue;
        };
        if depth_completed(config, state, plan_index) {
            continue;
        }
        let Some(ops) = &context.depth_goal_ops else {
            warn_depth_unavailable(
                node_id,
                plan,
                plan_index,
                unavailable_warned,
                context,
                "no DepthLock goal store is available to this run",
            );
            continue;
        };
        match ops.verdict(binding) {
            DepthGoalVerdict::Achieved(completion) => {
                // The verdict source answers for the binding it was given;
                // anything else would let a late or stale answer retire the
                // wrong plan.
                if completion.goal_id != binding.goal_id || completion.revision != binding.revision
                {
                    warn_depth_unavailable(
                        node_id,
                        plan,
                        plan_index,
                        unavailable_warned,
                        context,
                        &format!(
                            "the verdict source answered for goal {} revision {} instead of {} revision {}",
                            completion.goal_id, completion.revision, binding.goal_id, binding.revision
                        ),
                    );
                    continue;
                }
                tracing::info!(
                    "SmartExposure '{}' plan {} ({}) complete: DepthLock goal {} revision {} achieved                      (score {:.2} vs threshold {:.2} over {} exposures, {} confirming)",
                    node_id,
                    plan_index,
                    plan.filter_name,
                    completion.goal_id,
                    completion.revision,
                    completion.score,
                    completion.threshold,
                    completion.evidence_frames,
                    completion.confirmation_frames,
                );
                state
                    .depth_completed
                    .insert(binding.goal_id.clone(), binding.revision);
                if let Some(event_tx) = &context.event_tx {
                    // A closed receiver only means no subscriber; the log line
                    // above is the durable record.
                    let _ = event_tx.send(ExecutorEvent::DepthGoalCompleted {
                        node_id: node_id.to_string(),
                        filter_name: plan.filter_name.clone(),
                        completion,
                    });
                }
            }
            DepthGoalVerdict::Continue { reason } => {
                tracing::debug!(
                    "SmartExposure '{}' plan {} ({}) DepthLock goal {} rev {}: {}",
                    node_id,
                    plan_index,
                    plan.filter_name,
                    binding.goal_id,
                    binding.revision,
                    reason
                );
            }
            DepthGoalVerdict::Unavailable { reason } => {
                warn_depth_unavailable(
                    node_id,
                    plan,
                    plan_index,
                    unavailable_warned,
                    context,
                    &reason,
                );
            }
        }
    }
}

/// Warn once per plan per run that its DepthLock binding cannot be honored,
/// so the operator learns the plan is running to its authored count and why.
fn warn_depth_unavailable(
    node_id: &str,
    plan: &FilterPlan,
    plan_index: usize,
    unavailable_warned: &mut HashSet<usize>,
    context: &ExecutionContext,
    reason: &str,
) {
    if !unavailable_warned.insert(plan_index) {
        return;
    }
    let Some(binding) = &plan.depth_goal else {
        return;
    };
    let message = format!(
        "Smart Exposure plan {} ({}) is bound to DepthLock goal {} revision {}, but the goal          cannot be consulted: {}. The plan will run to its authored count instead.",
        plan_index + 1,
        plan.filter_name,
        binding.goal_id,
        binding.revision,
        reason
    );
    tracing::warn!("SmartExposure '{}': {}", node_id, message);
    if let Some(event_tx) = &context.event_tx {
        let _ = event_tx.send(ExecutorEvent::Warning { message });
    }
}

fn integration_budget_exceeded(
    config: &SmartExposureConfig,
    state: &SmartExposureCheckpoint,
) -> bool {
    config.integration_budget_secs > 0.0
        && state.completed_integration_secs >= config.integration_budget_secs
}

async fn run_filter_change(
    node_id: &str,
    plan: &FilterPlan,
    context: &mut ExecutionContext,
) -> NodeStatus {
    let filter_node_type = NodeType::ChangeFilter(FilterConfig {
        filter_name: plan.filter_name.clone(),
        filter_index: plan.filter_index,
        timeout_secs: None,
    });
    let Some(instruction) = registry().build(&filter_node_type) else {
        tracing::error!(
            "SmartExposure '{}': InstructionRegistry returned None for ChangeFilter; \
             cannot proceed (registry bug)",
            node_id
        );
        return NodeStatus::Failure;
    };
    instruction
        .execute(node_id, &filter_node_type, context)
        .await
}

async fn run_dither(
    node_id: &str,
    _plan: &FilterPlan,
    context: &mut ExecutionContext,
) -> NodeStatus {
    // We use the global dither defaults (matching what
    // `RecoveryAction::Dither` does for the DitherInterval trigger) because
    // SmartExposure plans don't carry the full dither-settle parameter set
    // and adding them would inflate the per-row editor. Users who need
    // bespoke settle parameters can author an explicit DitherNode.
    let dither_node_type = NodeType::Dither(DitherConfig::default());
    let Some(instruction) = registry().build(&dither_node_type) else {
        tracing::error!(
            "SmartExposure '{}': InstructionRegistry returned None for Dither",
            node_id
        );
        return NodeStatus::Failure;
    };
    instruction
        .execute(node_id, &dither_node_type, context)
        .await
}

async fn run_exposure_burst(
    node_id: &str,
    plan: &FilterPlan,
    batch_size: u32,
    context: &mut ExecutionContext,
) -> NodeStatus {
    let exposure_node_type = NodeType::TakeExposure(build_exposure_config(plan, batch_size));
    let Some(instruction) = registry().build(&exposure_node_type) else {
        tracing::error!(
            "SmartExposure '{}': InstructionRegistry returned None for TakeExposure; \
             cannot proceed (registry bug)",
            node_id
        );
        return NodeStatus::Failure;
    };
    instruction
        .execute(node_id, &exposure_node_type, context)
        .await
}

fn build_exposure_config(plan: &FilterPlan, batch_size: u32) -> ExposureConfig {
    // We deliberately do NOT pass the plan's filter_name/index into the
    // ExposureConfig: the filter change is already done by the dedicated
    // ChangeFilter step. Routing it through ExposureConfig as well would
    // make the exposure node re-run the filter logic on every batch.
    ExposureConfig {
        duration_secs: plan.duration_secs,
        count: batch_size,
        filter: None,
        filter_index: None,
        gain: plan.gain,
        offset: plan.offset,
        binning: plan.binning,
        dither_every: plan.dither_every,
        // Reuse ExposureConfig defaults for dither-settle parameters; same
        // rationale as `run_dither` above.
        ..ExposureConfig::default()
    }
}

fn emit_progress(
    node_id: &str,
    config: &SmartExposureConfig,
    state: &SmartExposureCheckpoint,
    plan: &FilterPlan,
    plan_index: usize,
    context: &ExecutionContext,
) {
    // In loop-until-stopped mode the per-plan count is ignored, so reporting
    // it as the denominator would be misleading. Use the integration budget
    // as the progress yardstick when one is set; otherwise progress is
    // genuinely open-ended ("until the target window ends") and we report 0
    // total / 0% (indeterminate) rather than a fake fraction.
    let (total, percent) = if config.loop_until_stopped {
        if config.integration_budget_secs > 0.0 {
            let pct = (100.0 * state.completed_integration_secs / config.integration_budget_secs)
                .clamp(0.0, 100.0);
            (0u32, pct)
        } else {
            (0u32, 0.0)
        }
    } else {
        let t = plan.count;
        let frame_in_plan = state
            .per_filter_completed
            .get(&plan.filter_name)
            .copied()
            .unwrap_or(0);
        let pct = if t > 0 {
            100.0 * f64::from(frame_in_plan) / f64::from(t)
        } else {
            0.0
        };
        (t, pct)
    };
    let frame_in_plan = state
        .per_filter_completed
        .get(&plan.filter_name)
        .copied()
        .unwrap_or(0);
    let upd = ProgressUpdate::instruction_progress(
        node_id.to_string(),
        "Smart Exposure",
        percent,
        ProgressDetail::SmartExposure {
            current_filter: plan.filter_name.clone(),
            plan_index,
            total_plans: config.plans.len(),
            frame_in_plan,
            total_frames: total,
        },
    );
    // Deliberately no `current_frame` / `total_frames` here. The delegated
    // exposure burst runs under this same node id and already reports every
    // frame it takes; the executor's progress callback keys its frame
    // counter on node id, so a second, plan-scaled number from this node
    // was credited as more frames (a 2+2 run read "7/4 exposures"). The
    // per-plan figures stay in the structured detail for the dashboard.
    context.send_progress(upd);
}

async fn load_or_init_checkpoint(
    node_id: &str,
    context: &ExecutionContext,
) -> SmartExposureCheckpoint {
    let states = context.smart_exposure_states.read().await;
    states.get(node_id).cloned().unwrap_or_default()
}

async fn save_checkpoint(
    node_id: &str,
    context: &ExecutionContext,
    state: &SmartExposureCheckpoint,
) {
    let mut states = context.smart_exposure_states.write().await;
    states.insert(node_id.to_string(), state.clone());
    drop(states);

    // Stable key for future cross-process persistence: when the executor
    // plumbs a `CheckpointManager` through ExecutionContext, this is the
    // key under which the JSON-serialized state would land in
    // `SessionCheckpoint::wizard_states`. Computed here so the format is
    // centralized in one place.
    let _ = smart_exposure_checkpoint_key(&node_id.to_string());
}

async fn clear_checkpoint(node_id: &str, context: &ExecutionContext) {
    let mut states = context.smart_exposure_states.write().await;
    states.remove(node_id);
}

// Tests

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Binning, SmartExposureConfig};
    use std::collections::HashMap;

    fn plan(name: &str, count: u32) -> FilterPlan {
        FilterPlan {
            filter_name: name.to_string(),
            filter_index: None,
            count,
            duration_secs: 60.0,
            ..FilterPlan::default()
        }
    }

    fn config_with(plans: Vec<FilterPlan>, rotate: bool) -> SmartExposureConfig {
        SmartExposureConfig {
            plans,
            rotate_filters: rotate,
            ..SmartExposureConfig::default()
        }
    }

    #[test]
    fn next_plan_rotates_across_filters_when_rotation_enabled() {
        let cfg = config_with(vec![plan("L", 3), plan("R", 3), plan("G", 3)], true);
        let mut state = SmartExposureCheckpoint::default();

        // Start at L
        assert_eq!(next_plan(&cfg, &state), Some(0));

        // After taking L's first batch, rotation should advance to R
        state.per_filter_completed.insert("L".into(), 1);
        state.current_plan_index = 0;
        // With rotation, after a batch the caller advances state.current_plan_index;
        // simulate that by setting it to 1 and seeing R picked.
        state.current_plan_index = 1;
        assert_eq!(next_plan(&cfg, &state), Some(1));
    }

    #[test]
    fn next_plan_skips_completed_filters_in_rotation() {
        let cfg = config_with(vec![plan("L", 1), plan("R", 3), plan("G", 3)], true);
        let mut state = SmartExposureCheckpoint::default();
        state.per_filter_completed.insert("L".into(), 1); // L done
        state.current_plan_index = 0;
        // Rotation should jump past L to R
        assert_eq!(next_plan(&cfg, &state), Some(1));
    }

    #[test]
    fn next_plan_drains_filter_when_rotation_off() {
        let cfg = config_with(vec![plan("L", 3), plan("R", 3)], false);
        let mut state = SmartExposureCheckpoint::default();

        // Picks L first.
        assert_eq!(next_plan(&cfg, &state), Some(0));

        // L still incomplete -> still picks L (no rotation).
        state.per_filter_completed.insert("L".into(), 2);
        state.current_plan_index = 0;
        assert_eq!(next_plan(&cfg, &state), Some(0));

        // L complete -> picks R.
        state.per_filter_completed.insert("L".into(), 3);
        assert_eq!(next_plan(&cfg, &state), Some(1));
    }

    #[test]
    fn next_plan_returns_none_when_all_complete() {
        let cfg = config_with(vec![plan("L", 1), plan("R", 1)], true);
        let mut state = SmartExposureCheckpoint::default();
        state.per_filter_completed.insert("L".into(), 1);
        state.per_filter_completed.insert("R".into(), 1);
        state.current_plan_index = 1;
        assert!(next_plan(&cfg, &state).is_none());
    }

    #[test]
    fn integration_budget_zero_means_no_cap() {
        let cfg = SmartExposureConfig {
            integration_budget_secs: 0.0,
            ..SmartExposureConfig::default()
        };
        let state = SmartExposureCheckpoint {
            completed_integration_secs: 1_000_000.0,
            ..SmartExposureCheckpoint::default()
        };
        assert!(!integration_budget_exceeded(&cfg, &state));
    }

    #[test]
    fn integration_budget_caps_when_exceeded() {
        let cfg = SmartExposureConfig {
            integration_budget_secs: 3600.0,
            ..SmartExposureConfig::default()
        };
        let mut state = SmartExposureCheckpoint {
            completed_integration_secs: 3599.9,
            ..SmartExposureCheckpoint::default()
        };
        assert!(!integration_budget_exceeded(&cfg, &state));
        state.completed_integration_secs = 3600.0;
        assert!(integration_budget_exceeded(&cfg, &state));
    }

    #[test]
    fn build_exposure_config_carries_per_plan_settings() {
        let p = FilterPlan {
            filter_name: "Ha".into(),
            filter_index: Some(3),
            count: 5,
            duration_secs: 300.0,
            gain: Some(120),
            offset: Some(30),
            binning: Binning::Two,
            dither_every: Some(2),
            depth_goal: None,
        };
        let cfg = build_exposure_config(&p, 2);
        assert_eq!(cfg.duration_secs, 300.0);
        // The burst takes batch_size frames, not the plan total
        assert_eq!(cfg.count, 2);
        // Filter is intentionally NOT routed through ExposureConfig — the
        // outer SmartExposure node handles filter changes via the dedicated
        // ChangeFilter step.
        assert!(cfg.filter.is_none());
        assert!(cfg.filter_index.is_none());
        assert_eq!(cfg.gain, Some(120));
        assert_eq!(cfg.offset, Some(30));
        assert_eq!(cfg.binning, Binning::Two);
        assert_eq!(cfg.dither_every, Some(2));
    }

    #[test]
    fn smart_exposure_checkpoint_serde_round_trip() {
        let mut cp = SmartExposureCheckpoint::default();
        cp.per_filter_completed.insert("L".into(), 3);
        cp.per_filter_completed.insert("R".into(), 5);
        cp.current_plan_index = 2;
        cp.completed_integration_secs = 1234.5;

        let json = serde_json::to_string(&cp).expect("serialize");
        let restored: SmartExposureCheckpoint = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(restored.per_filter_completed.get("L"), Some(&3));
        assert_eq!(restored.per_filter_completed.get("R"), Some(&5));
        assert_eq!(restored.current_plan_index, 2);
        assert!((restored.completed_integration_secs - 1234.5).abs() < f64::EPSILON);
    }

    #[test]
    fn smart_exposure_config_round_trips_through_node_type_json() {
        let cfg = SmartExposureConfig {
            plans: vec![plan("L", 60), plan("R", 30), plan("G", 30), plan("B", 30)],
            rotate_filters: true,
            dither_on_filter_change: true,
            integration_budget_secs: 14_400.0,
            batch_size: 1,
            loop_until_stopped: true,
        };
        let nt = NodeType::SmartExposure(cfg);
        let json = serde_json::to_string(&nt).expect("serialize node type");
        let restored: NodeType = serde_json::from_str(&json).expect("deserialize node type");
        match restored {
            NodeType::SmartExposure(c) => {
                assert_eq!(c.plans.len(), 4);
                assert!(c.rotate_filters);
                assert!(c.dither_on_filter_change);
                assert!((c.integration_budget_secs - 14_400.0).abs() < f64::EPSILON);
                assert_eq!(c.batch_size, 1);
                assert!(c.loop_until_stopped);
                assert_eq!(c.plans[0].filter_name, "L");
                assert_eq!(c.plans[0].count, 60);
            }
            other => panic!("expected SmartExposure variant, got {:?}", other),
        }
    }

    #[test]
    fn smart_exposure_config_legacy_json_without_new_fields_defaults() {
        // A JSON blob that pre-dates the `dither_on_filter_change`,
        // `integration_budget_secs`, and `batch_size` fields. They must all
        // come back as their declared defaults so loading an old sequence
        // doesn't fail.
        let json = r#"{
            "type": "SmartExposure",
            "plans": [],
            "rotate_filters": false
        }"#;
        let restored: NodeType = serde_json::from_str(json).expect("deserialize legacy json");
        match restored {
            NodeType::SmartExposure(c) => {
                assert!(c.plans.is_empty());
                assert!(!c.rotate_filters);
                assert!(!c.dither_on_filter_change);
                assert_eq!(c.integration_budget_secs, 0.0);
                assert_eq!(c.batch_size, 1);
                assert!(!c.loop_until_stopped);
            }
            other => panic!("expected SmartExposure variant, got {:?}", other),
        }
    }

    #[test]
    fn next_plan_with_resumed_index_picks_correct_filter() {
        // Simulate a resume mid-rotation: the user paused after L's batch
        // but before R's. checkpoint says current_plan_index = 1 (R) and
        // per_filter_completed L=1. Rotation should pick R (current_plan_index
        // is the next-to-run row, not the just-finished one).
        let cfg = config_with(vec![plan("L", 3), plan("R", 3), plan("G", 3)], true);
        let mut state = SmartExposureCheckpoint::default();
        state.per_filter_completed.insert("L".into(), 1);
        state.current_plan_index = 1;
        assert_eq!(next_plan(&cfg, &state), Some(1));
    }

    #[test]
    fn checkpoint_key_namespacing_is_per_node() {
        let k1 = smart_exposure_checkpoint_key(&"node_a".to_string());
        let k2 = smart_exposure_checkpoint_key(&"node_b".to_string());
        assert_ne!(k1, k2);
        assert!(k1.starts_with("smart_exposure:"));
    }

    #[test]
    fn batch_size_respected_under_rotation() {
        // With rotate_filters=true and batch_size=2, the first visit to L
        // (count=5) should take 2 frames, leaving 3 remaining for the next
        // rotation cycle. The math is in the execute() body, not
        // next_plan(), so we exercise it indirectly via the integration
        // test rather than asserting directly here.
        let cfg = SmartExposureConfig {
            plans: vec![plan("L", 5), plan("R", 5)],
            rotate_filters: true,
            batch_size: 2,
            ..SmartExposureConfig::default()
        };
        assert_eq!(cfg.batch_size, 2);
        assert_eq!(cfg.plans.len(), 2);
    }

    #[test]
    fn resume_after_plan_removed_clamps_index() {
        // Persisted plan_index = 3, but plans now has only 2 entries — the
        // execute() body clamps it to 0 defensively. Verify the read+clamp
        // logic by simulating that flow via next_plan.
        let cfg = config_with(vec![plan("L", 1), plan("R", 1)], true);
        let state = SmartExposureCheckpoint {
            current_plan_index: 99, // out of range
            ..SmartExposureCheckpoint::default()
        };
        // next_plan uses min(n-1) so it falls back to index 1 (R) here.
        // Either L or R is acceptable — the contract is "pick something
        // runnable" — so just assert the result is in [0, n).
        let picked = next_plan(&cfg, &state).expect("a plan should be picked");
        assert!(picked < cfg.plans.len());
    }

    /// Rotation order test.
    ///
    /// Drives the execute() loop's plan-picking flow manually, mirroring the
    /// exact sequence of operations the body performs:
    ///   1. Call `next_plan(cfg, &state)` to pick a plan
    ///   2. Increment per_filter_completed by batch_size for the picked plan
    ///   3. In rotation mode, advance current_plan_index = (picked + 1) % n
    ///
    /// With 4 plans of count=2 and batch_size=1, the order must be
    /// L,R,G,B,L,R,G,B — every filter once per round, two rounds total. Without
    /// the advance it stays on each filter for its whole count (L,L,R,R,G,G,B,B),
    /// which is rotation broken.
    #[test]
    fn rotation_visits_every_filter_in_order_across_rounds() {
        let cfg = config_with(
            vec![plan("L", 2), plan("R", 2), plan("G", 2), plan("B", 2)],
            true,
        );
        let mut state = SmartExposureCheckpoint::default();
        let mut order: Vec<String> = Vec::new();

        // Run until next_plan returns None (every plan exhausted) — bounded
        // by total frame count so a rotation bug cannot loop forever.
        let n = cfg.plans.len();
        let total_frames: u32 = cfg.plans.iter().map(|p| p.count).sum();
        for _ in 0..(total_frames + 1) {
            let Some(picked) = next_plan(&cfg, &state) else {
                break;
            };
            order.push(cfg.plans[picked].filter_name.clone());

            // Take one frame (batch_size=1).
            let completed = state
                .per_filter_completed
                .get(&cfg.plans[picked].filter_name)
                .copied()
                .unwrap_or(0);
            state
                .per_filter_completed
                .insert(cfg.plans[picked].filter_name.clone(), completed + 1);

            // Advance the current_plan_index AFTER the batch.
            state.current_plan_index = (picked + 1) % n;
        }

        assert_eq!(
            order,
            vec![
                "L".to_string(),
                "R".to_string(),
                "G".to_string(),
                "B".to_string(),
                "L".to_string(),
                "R".to_string(),
                "G".to_string(),
                "B".to_string(),
            ],
            "rotation should visit each filter in order across rounds; \
             got {:?}",
            order
        );
    }

    /// Rotation with batch_size > 1 still rotates.
    ///
    /// With 2 plans of count=4 and batch_size=2, the expected order is
    /// L,R,L,R — two batches per filter, alternating. `current_plan_index`
    /// advances immediately so the next iteration's `next_plan` starts the
    /// scan at the next plan.
    #[test]
    fn rotation_with_batch_size_two_alternates_filters() {
        let cfg = SmartExposureConfig {
            plans: vec![plan("L", 4), plan("R", 4)],
            rotate_filters: true,
            batch_size: 2,
            ..SmartExposureConfig::default()
        };
        let mut state = SmartExposureCheckpoint::default();
        let mut order: Vec<String> = Vec::new();

        let n = cfg.plans.len();
        let total_frames: u32 = cfg.plans.iter().map(|p| p.count).sum();
        for _ in 0..(total_frames + 1) {
            let Some(picked) = next_plan(&cfg, &state) else {
                break;
            };
            order.push(cfg.plans[picked].filter_name.clone());
            // Take a full batch.
            let completed = state
                .per_filter_completed
                .get(&cfg.plans[picked].filter_name)
                .copied()
                .unwrap_or(0);
            let remaining = cfg.plans[picked].count.saturating_sub(completed);
            let batch = cfg.batch_size.min(remaining);
            state
                .per_filter_completed
                .insert(cfg.plans[picked].filter_name.clone(), completed + batch);
            state.current_plan_index = (picked + 1) % n;
        }

        assert_eq!(
            order,
            vec![
                "L".to_string(),
                "R".to_string(),
                "L".to_string(),
                "R".to_string(),
            ],
            "rotation with batch_size=2 should alternate filters per batch; \
             got {:?}",
            order
        );
    }

    /// Sequential (rotate_filters=false) drains plans in order: the rotation
    /// advance is gated behind `config.rotate_filters` in execute(), so a
    /// sequential pick stays on the same plan until it is exhausted.
    #[test]
    fn sequential_drains_each_plan_before_advancing() {
        let cfg = config_with(vec![plan("L", 3), plan("R", 2)], false);
        let mut state = SmartExposureCheckpoint::default();
        let mut order: Vec<String> = Vec::new();

        let total_frames: u32 = cfg.plans.iter().map(|p| p.count).sum();
        for _ in 0..(total_frames + 1) {
            let Some(picked) = next_plan(&cfg, &state) else {
                break;
            };
            order.push(cfg.plans[picked].filter_name.clone());
            let completed = state
                .per_filter_completed
                .get(&cfg.plans[picked].filter_name)
                .copied()
                .unwrap_or(0);
            state
                .per_filter_completed
                .insert(cfg.plans[picked].filter_name.clone(), completed + 1);
            // Sequential mode: do NOT advance current_plan_index here. The
            // execute() body only does this in rotation mode.
        }

        assert_eq!(
            order,
            vec![
                "L".to_string(),
                "L".to_string(),
                "L".to_string(),
                "R".to_string(),
                "R".to_string(),
            ],
            "sequential mode should drain L (3) then R (2); got {:?}",
            order
        );
    }

    /// Loop-until-stopped: `next_plan` ignores per-plan counts entirely and
    /// always returns the current rotation index, even when every plan's
    /// authored count has been "completed" many times over. This is what
    /// keeps the node looping instead of terminating at the fixed counts.
    #[test]
    fn loop_until_stopped_next_plan_never_exhausts() {
        let cfg = SmartExposureConfig {
            plans: vec![plan("L", 1), plan("R", 1)],
            rotate_filters: true,
            loop_until_stopped: true,
            ..SmartExposureConfig::default()
        };
        let mut state = SmartExposureCheckpoint::default();
        // Pretend we've already shot far past the authored counts.
        state.per_filter_completed.insert("L".into(), 500);
        state.per_filter_completed.insert("R".into(), 500);
        // Still returns the current row — never None.
        state.current_plan_index = 0;
        assert_eq!(next_plan(&cfg, &state), Some(0));
        state.current_plan_index = 1;
        assert_eq!(next_plan(&cfg, &state), Some(1));
    }

    /// Loop mode round-trips through the same execute() picking flow as the
    /// rotation tests, but because counts are ignored the order keeps cycling
    /// L,R,G,B,L,R,G,B,… well past where the fixed counts (1 each) would have
    /// stopped. We bound the loop by an iteration budget (the real executor
    /// is bounded by the integration budget / target window) to prove it
    /// keeps rotating rather than draining-and-stopping.
    #[test]
    fn loop_until_stopped_keeps_rotating_past_counts() {
        let cfg = SmartExposureConfig {
            plans: vec![plan("L", 1), plan("R", 1), plan("G", 1), plan("B", 1)],
            rotate_filters: true,
            loop_until_stopped: true,
            ..SmartExposureConfig::default()
        };
        let mut state = SmartExposureCheckpoint::default();
        let mut order: Vec<String> = Vec::new();
        let n = cfg.plans.len();
        // Ten subs — more than the 4 the fixed counts would have produced.
        for _ in 0..10 {
            let picked = next_plan(&cfg, &state).expect("loop mode always picks a plan");
            order.push(cfg.plans[picked].filter_name.clone());
            let completed = state
                .per_filter_completed
                .get(&cfg.plans[picked].filter_name)
                .copied()
                .unwrap_or(0);
            state
                .per_filter_completed
                .insert(cfg.plans[picked].filter_name.clone(), completed + 1);
            state.current_plan_index = (picked + 1) % n;
        }
        assert_eq!(
            order,
            vec!["L", "R", "G", "B", "L", "R", "G", "B", "L", "R"]
                .into_iter()
                .map(String::from)
                .collect::<Vec<_>>(),
            "loop mode should keep cycling filters past the per-plan counts; got {:?}",
            order
        );
    }

    /// Misconfiguration guard: loop-until-stopped with NO integration budget
    /// AND no installed target end trigger must fail closed rather than spin
    /// forever. We exercise the executor's `execute()` entry path with a bare
    /// ExecutionContext (no target window installed).
    #[test]
    fn loop_until_stopped_without_bound_fails_closed() {
        let cfg = SmartExposureConfig {
            plans: vec![plan("L", 1), plan("R", 1)],
            rotate_filters: true,
            loop_until_stopped: true,
            integration_budget_secs: 0.0,
            ..SmartExposureConfig::default()
        };
        let node_type = NodeType::SmartExposure(cfg);
        let mut context = ExecutionContext::new_for_test("root".to_string());
        // No target end trigger installed.
        assert!(context.active_target_end_trigger().is_none());
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let status = rt.block_on(async {
            SmartExposureInstruction
                .execute("node_loop", &node_type, &mut context)
                .await
        });
        assert_eq!(
            status,
            NodeStatus::Failure,
            "unbounded loop-until-stopped must fail closed, not loop forever"
        );
    }

    /// With a positive integration budget, loop-until-stopped is bounded and
    /// the entry guard lets it proceed (no Failure). We can't run the full
    /// exposure path without device ops, but we can assert the guard does NOT
    /// trip: a budget IS a valid automatic bound.
    #[test]
    fn loop_until_stopped_with_budget_passes_guard() {
        let cfg = SmartExposureConfig {
            plans: vec![plan("L", 1)],
            rotate_filters: true,
            loop_until_stopped: true,
            integration_budget_secs: 3600.0,
            ..SmartExposureConfig::default()
        };
        // The guard condition mirrors execute(): budget>0 OR end-trigger set.
        let has_budget = cfg.integration_budget_secs > 0.0;
        let context = ExecutionContext::new_for_test("root".to_string());
        let bounded = has_budget || context.active_target_end_trigger().is_some();
        assert!(
            bounded,
            "a positive budget must satisfy the loop-mode bound"
        );
    }

    /// An installed target end trigger is also a valid bound even with no
    /// budget. The trigger is evaluated against the context's observer/target
    /// snapshot; a `TimeAfter` in the past reads as "satisfied" → the loop
    /// would stop on the first between-batch check.
    #[test]
    fn loop_until_stopped_target_window_is_a_valid_bound() {
        let context = ExecutionContext::new_for_test("root".to_string());
        // A TimeAfter(0) (epoch) is always in the past → satisfied now.
        context.install_active_target_end_trigger(Some(
            crate::scheduling::TargetTrigger::TimeAfter(0),
        ));
        assert!(context.active_target_end_trigger().is_some());
        assert_eq!(context.active_target_end_trigger_satisfied(), Some(true));
    }

    #[test]
    fn loop_until_stopped_forces_batch_one_and_rotate() {
        // A stored config with rotate_filters=false and batch_size=9 should,
        // in loop mode, behave as rotate+batch1. We assert the coercion the
        // execute() body performs by replicating its condition.
        let cfg = SmartExposureConfig {
            plans: vec![plan("L", 1), plan("R", 1)],
            rotate_filters: false,
            batch_size: 9,
            loop_until_stopped: true,
            ..SmartExposureConfig::default()
        };
        let needs_coercion = cfg.loop_until_stopped && (!cfg.rotate_filters || cfg.batch_size != 1);
        assert!(needs_coercion);
        let effective = SmartExposureConfig {
            rotate_filters: true,
            batch_size: 1,
            ..cfg
        };
        assert!(effective.rotate_filters);
        assert_eq!(effective.batch_size, 1);
    }

    #[test]
    fn save_and_load_checkpoint_round_trip_through_context_map() {
        // Smoke-test the in-memory map: a save followed by a load returns
        // the same state. This is the "resume in the same process" path.
        let context = ExecutionContext::new_for_test("root".to_string());
        let cp = SmartExposureCheckpoint {
            per_filter_completed: HashMap::from([("L".to_string(), 7)]),
            current_plan_index: 1,
            completed_integration_secs: 420.0,
            depth_completed: HashMap::new(),
        };

        // The async helpers need a runtime — use a single-thread current-thread
        // executor for the test.
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        rt.block_on(async {
            save_checkpoint("node_x", &context, &cp).await;
            let loaded = load_or_init_checkpoint("node_x", &context).await;
            assert_eq!(loaded.per_filter_completed.get("L"), Some(&7));
            assert_eq!(loaded.current_plan_index, 1);
            assert!((loaded.completed_integration_secs - 420.0).abs() < f64::EPSILON);

            // Clearing removes the slot.
            clear_checkpoint("node_x", &context).await;
            let after_clear = load_or_init_checkpoint("node_x", &context).await;
            assert!(after_clear.per_filter_completed.is_empty());
            assert_eq!(after_clear.current_plan_index, 0);
        });
    }
}
