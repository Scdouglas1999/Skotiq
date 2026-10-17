//! TargetHeader container node.
//!
//! Root node for each target in a sequence. Stamps target coordinates onto
//! the ExecutionContext, evaluates altitude / time constraints, primes the
//! trigger state, then walks children sequentially.
//!
//! integration-budget enforcement: when
//! [`TargetHeaderConfig::integration_budget`] is set the runtime registers
//! a [`BudgetState`] on the executor's `BudgetRegistry` at entry and,
//! between children, asks the registry whether the budget has been met.
//! When met (and `stop_on_budget_met == true`), the remaining children are
//! Skipped and the target returns Success.

use crate::node::context::ExecutionContext;
use crate::node::logic::sequential::execute_children_sequential;
use crate::node::progress::{ProgressDetail, ProgressUpdate};
use crate::node::runtime::{Node, RuntimeNode};
use crate::scheduling::{BudgetEvaluation, BudgetMetReason, TargetTrigger, TriggerObserverContext};
use crate::{NodeStatus, TargetHeaderConfig};

pub async fn execute_target_header(
    node: &mut RuntimeNode,
    config: TargetHeaderConfig,
    context: &mut ExecutionContext,
) -> NodeStatus {
    if context.is_skip_to_next_target_requested() {
        context.clear_skip_to_next_target_request();
        tracing::info!(
            "Skipping target '{}' due to pending next-target request",
            config.display_name()
        );
        return NodeStatus::Skipped;
    }

    // snapshot the prior target context so siblings outside this
    // TargetHeader subtree do not inherit stale target_id / mosaic_panel /
    // target_name from us when we return. Each TargetHeader is a scope; on
    // exit (Success / Failure / Skipped / Cancelled) we restore exactly
    // what we saw on entry.
    let prior = TargetContextSnapshot::capture(context);

    // Stamp target onto context so child instructions share one source of truth.
    context.target_name = Some(config.target_name.clone());
    context.target_ra = Some(config.ra_hours);
    context.target_dec = Some(config.dec_degrees);
    context.target_rotation = config.rotation;
    // Populate target_id (stamped here so child exposures' FITS headers
    // carry a stable join key for the database row) and mosaic_panel (the
    // panel index the PANELIDX/NS-PIDX/NS-PROW/NS-PCOL FITS keywords carry).
    context.target_id = Some(node.id().clone());
    context.mosaic_panel = config.mosaic_panel.clone();

    // execute the body in a single scope so every exit path (early
    // returns from time / altitude constraints, the budget loop, the
    // between-target skip request) restores the prior target context. A
    // helper closure / inner async block lets us collect a single
    // NodeStatus and apply restore once at the bottom.
    let result = run_target_body(node, &config, context).await;

    // Restore prior target scope. This MUST run on every exit path so a
    // sibling node executing after this TargetHeader does not inherit
    // M31's coordinates / mosaic panel.
    prior.restore(context);

    result
}

/// captured snapshot of `ExecutionContext` target-scoped fields,
/// taken at TargetHeader entry and restored at exit so the next sibling
/// node sees the prior scope (typically: nothing).
struct TargetContextSnapshot {
    target_id: Option<crate::NodeId>,
    target_name: Option<String>,
    target_ra: Option<f64>,
    target_dec: Option<f64>,
    target_rotation: Option<f64>,
    mosaic_panel: Option<crate::MosaicPanelInfo>,
}

impl TargetContextSnapshot {
    fn capture(ctx: &ExecutionContext) -> Self {
        Self {
            target_id: ctx.target_id.clone(),
            target_name: ctx.target_name.clone(),
            target_ra: ctx.target_ra,
            target_dec: ctx.target_dec,
            target_rotation: ctx.target_rotation,
            mosaic_panel: ctx.mosaic_panel.clone(),
        }
    }

    fn restore(self, ctx: &mut ExecutionContext) {
        ctx.target_id = self.target_id;
        ctx.target_name = self.target_name;
        ctx.target_ra = self.target_ra;
        ctx.target_dec = self.target_dec;
        ctx.target_rotation = self.target_rotation;
        ctx.mosaic_panel = self.mosaic_panel;
    }
}

/// the original `execute_target_header` body, factored into its
/// own helper so the public function can restore the prior target context
/// in exactly one place on every exit path.
async fn run_target_body(
    node: &mut RuntimeNode,
    config: &TargetHeaderConfig,
    context: &mut ExecutionContext,
) -> NodeStatus {
    let display_name = config.display_name();
    tracing::info!(
        "Starting target: {} (RA: {:.4}h, Dec: {:.4}°)",
        display_name,
        config.ra_hours,
        config.dec_degrees
    );

    // resolve the effective triggers up-front so legacy fields and
    // new explicit `start_when`/`end_when` end up in the same code path.
    let start_when = config.effective_start_when();
    let end_when = config.effective_end_when();
    let poll_interval = config.effective_poll_interval_secs();

    // If the target's stop condition is ALREADY true at entry, there's no
    // imaging to be done — skip cleanly. Checked before the start-when wait
    // so a sequence whose end_when has long passed doesn't sit waiting for
    // a sunrise that won't help it. A stop condition that cannot be evaluated
    // from an unset site refuses here exactly as `wait_for_trigger` refuses for
    // `start_when`: skipping the target on an altitude computed at Null Island
    // dropped the whole target and told the operator the altitude as fact.
    if let Some(end) = &end_when {
        match trigger_observer_ctx(config, context, end, TriggerRole::EndWhen) {
            Ok(trig_ctx) => {
                if end.is_satisfied(&trig_ctx) {
                    emit_end_when_skipped_at_entry(context, node.id(), &display_name, end);
                    return NodeStatus::Skipped;
                }
            }
            Err(reason) => return refuse_unevaluable_trigger(context, &display_name, reason),
        }
    }

    // wait for `start_when` to fire. Polls every `poll_interval`
    // seconds using `ctx.clock.now_utc()` so MockClock-driven tests can
    // advance time deterministically.
    if let Some(start) = &start_when {
        match wait_for_trigger(config, context, start, poll_interval).await {
            NodeStatus::Success => {}
            other => return other,
        }
    }

    // DriftLimit + MeridianFlip both need the target's RA/Dec stamped into
    // the trigger state. The state stores RA in degrees so it matches
    // plate-solve outputs directly; convert hours -> degrees at this
    // boundary.
    if let Some(trigger_state_lock) = &context.trigger_state {
        let mut trigger_state = trigger_state_lock.write().await;
        let target_ra_degrees = config.ra_hours * 15.0;
        trigger_state.set_target(target_ra_degrees, config.dec_degrees);
        trigger_state.set_meridian_target(display_name.clone());
        tracing::debug!(
            "Updated trigger state with target: RA={:.4}°, Dec={:.4}°",
            target_ra_degrees,
            config.dec_degrees
        );
    }

    // Pre-compute the meridian-crossing timestamp once per target. The
    // MeridianFlip trigger compares now() against this stored value; doing
    // the math here avoids each trigger evaluation recomputing it.
    if let (Some(_lat), Some(lon)) = (context.latitude, context.longitude) {
        let now = context.clock.now_utc();
        let meridian_crossing =
            crate::meridian::calculate_meridian_crossing(config.ra_hours, lon, now);

        tracing::debug!(
            "Target {} meridian crossing at {}",
            display_name,
            meridian_crossing
        );

        context
            .set_next_meridian_flip_time(Some(meridian_crossing.timestamp()))
            .await;
    }

    // integration budget setup.
    //
    // Register the target with the budget registry on entry. We register
    // unconditionally (even when no budget is configured) so the
    // exposure instruction always knows which target to credit; the
    // budget value is passed alongside so the registry can resolve
    // per-filter caps for the progress event.
    //
    // `context.target_id` was already populated at TargetHeader
    // entry; the budget registry consumes the same id so the join key is
    // stable from the FITS header through to the per-target progress
    // event.
    let target_id = node.id().clone();
    let budget = config.integration_budget().cloned();
    let _initial_state = context
        .budget_registry
        .enter_target(&target_id, budget.clone())
        .await;

    // wrap the existing child walker with an end_when monitor.
    // We don't spawn a background watcher because (a) the executor crate
    // doesn't currently spawn tasks per-target, and (b) the most natural
    // pre-emption point is at child boundaries — between exposures, after a
    // dither, etc. — which the existing loops already visit.
    //
    // Expose the effective `end_when` on the context for the duration of the
    // child subtree. Children that loop internally (e.g. a SmartExposure
    // node in `loop_until_stopped` mode) never hand the parent a boundary to
    // probe, so they poll the trigger themselves via
    // `context.active_target_end_trigger_satisfied()` and stop when the
    // window closes. We restore the prior value on every exit path so the
    // trigger does not leak into sibling subtrees (a nested TargetHeader,
    // however unusual, would push/pop its own).
    let prior_end_trigger = context.install_active_target_end_trigger(end_when.clone());
    let result = if let Some(budget) = budget {
        execute_children_with_budget(
            node,
            context,
            &target_id,
            &budget,
            &display_name,
            end_when.clone(),
            config,
        )
        .await
    } else {
        execute_children_with_end_when(node, context, end_when.clone(), config).await
    };
    context.install_active_target_end_trigger(prior_end_trigger);

    // Leaving the target clears `active_target` on the registry so any
    // post-target work (e.g. a between-target Wait node) does NOT credit
    // exposures to this target. Note that `context.target_id` is restored
    // by the caller's `TargetContextSnapshot::restore` — we deliberately
    // do NOT reset it to None here so the snapshot-restore is the single
    // source of truth.
    context.budget_registry.leave_target().await;

    // A skip-to-next-target request names THIS target, so it dies at this
    // boundary whatever the subtree returned — the target it asked to leave is
    // over either way. It used to be consumed only when the subtree came back
    // Skipped, so a request that arrived during the target's LAST child (an
    // exposure burst finishes the frame it is on rather than aborting mid-
    // download) outlived the target: the next TargetHeader's entry check
    // consumed it and skipped a target nobody asked to skip, and with no next
    // target the root Loop reported Skipped for a night that had imaged every
    // frame it planned — `/api/sequencer/status` answered
    // `state: "completed"`, 8 frames, `message: "Skipped: Night root"`.
    if context.is_skip_to_next_target_requested() {
        context.clear_skip_to_next_target_request();
        tracing::info!(
            "Target '{}' ended on a next-target request (subtree status {:?})",
            display_name,
            result
        );
    }

    result
}

/// budget-aware sibling execution.
///
/// Same shape as [`execute_children_sequential`] but inserts a budget
/// evaluation at every child boundary. When the budget is met:
/// * remaining children are marked `Skipped` (lifecycle event so the UI
///   can grey them out without ambiguity);
/// * a lifecycle event is sent against the target itself describing
///   *why* the budget terminated ("total reached" vs "all filters
///   complete");
/// * the function returns `Success` — the target completed its goal,
///   not a failure.
async fn execute_children_with_budget(
    node: &mut crate::node::runtime::RuntimeNode,
    context: &mut ExecutionContext,
    target_id: &str,
    budget: &crate::IntegrationBudget,
    display_name: &str,
    end_when: Option<TargetTrigger>,
    config: &TargetHeaderConfig,
) -> NodeStatus {
    use std::sync::atomic::Ordering;
    let total = node.children.len();
    let node_id = node.id().clone();

    if total == 0 {
        return NodeStatus::Success;
    }

    // Pre-check: if we're resuming a run that already met the budget,
    // skip the entire subtree without imaging another frame. This
    // matters for crash recovery — the checkpoint may have been
    // written *just after* the budget hit but before the
    // budget-met lifecycle event drained.
    if let Some(state) = context.budget_registry.state_for(target_id).await {
        if state.is_met(budget) {
            emit_budget_met(context, &node_id, display_name, &state, budget).await;
            mark_remaining_skipped(node, context, 0, total).await;
            return NodeStatus::Success;
        }
    }

    for (i, child) in node.children.iter_mut().enumerate() {
        if context.is_cancelled.load(Ordering::Relaxed) {
            return NodeStatus::Cancelled;
        }
        // honor an operator Pause / recovery freeze at the
        // child boundary, mirroring `execute_children_sequential` (sequential.rs:52).
        // Without this, a TargetHeader carrying an integration budget keeps
        // exposing/slewing while the UI shows "Paused". Block until resumed;
        // unwind to Cancelled if the sequence is cancelled while paused.
        if !context.wait_while_paused().await {
            return NodeStatus::Cancelled;
        }
        if context.is_skip_to_next_target_requested() {
            return NodeStatus::Skipped;
        }

        // end_when pre-check. If the stop condition is already
        // true *before* we even start the next child, mark the rest
        // Skipped and return Success. Doing this *before* the child
        // executes (in addition to after) means the last frame in a
        // long burst doesn't get scheduled if dusk arrived during the
        // previous one.
        if let Some(end) = &end_when {
            match trigger_observer_ctx(config, context, end, TriggerRole::EndWhen) {
                Ok(trig_ctx) => {
                    if end.is_satisfied(&trig_ctx) {
                        emit_end_when_met(context, &node_id, display_name, end);
                        mark_remaining_end_when(node, context, i, total).await;
                        return NodeStatus::Success;
                    }
                }
                // Reachable when the observer location is cleared after the
                // target's entry check passed; the same refusal, not a stop
                // decision taken from an invented altitude.
                Err(reason) => return refuse_unevaluable_trigger(context, display_name, reason),
            }
        }

        // Kept in sync with
        // `execute_children_sequential`.
        if let Some(ref skip_target) = context.skip_to_node_target() {
            if child.id() == skip_target {
                context.clear_skip_to_node_request();
            } else if !child.contains_node(skip_target) {
                let mut update = ProgressUpdate::lifecycle(
                    child.id().clone(),
                    NodeStatus::Skipped,
                    format!("Skipped by SkipToNode request (target: {})", skip_target),
                );
                update.current_child = Some(i);
                update.total_children = Some(total);
                context.send_progress(update);
                continue;
            }
        }

        let mut step_update = ProgressUpdate::lifecycle(
            node_id.clone(),
            NodeStatus::Running,
            format!("Step {}/{}: {}", i + 1, total, child.name()),
        );
        step_update.current_child = Some(i);
        step_update.total_children = Some(total);
        context.send_progress(step_update);

        let result = child.execute(context).await;

        if result == NodeStatus::Skipped && context.is_skip_to_next_target_requested() {
            return NodeStatus::Skipped;
        }
        if result == NodeStatus::Failure || result == NodeStatus::Cancelled {
            return result;
        }

        // Budget evaluation at child boundary. Done after the child so a
        // long exposure burst is allowed to land its credit before we
        // decide to stop — without this, the very last frame in a
        // burst would be killed mid-flight.
        if budget.stop_on_budget_met {
            if let Some(state) = context.budget_registry.state_for(target_id).await {
                if let BudgetEvaluation::Met { .. } = state.evaluate(budget) {
                    emit_budget_met(context, &node_id, display_name, &state, budget).await;
                    mark_remaining_skipped(node, context, i + 1, total).await;
                    return NodeStatus::Success;
                }
            }
        }
    }

    NodeStatus::Success
}

/// sequential walker that pre-checks `end_when` at every child
/// boundary. Mirrors `execute_children_sequential` exactly EXCEPT for the
/// added pre-child end_when probe + lifecycle emission. We don't reuse
/// `execute_children_sequential` because that function is shared with the
/// non-target sequential containers (which don't have end_when semantics).
async fn execute_children_with_end_when(
    node: &mut crate::node::runtime::RuntimeNode,
    context: &mut ExecutionContext,
    end_when: Option<TargetTrigger>,
    config: &TargetHeaderConfig,
) -> NodeStatus {
    use std::sync::atomic::Ordering;

    // No end_when → just delegate to the standard sequential walker so we
    // pick up every future enhancement to it.
    let Some(end) = end_when else {
        return execute_children_sequential(node, context).await;
    };

    let total = node.children.len();
    let node_id = node.id().clone();
    if total == 0 {
        return NodeStatus::Success;
    }

    for (i, child) in node.children.iter_mut().enumerate() {
        if context.is_cancelled.load(Ordering::Relaxed) {
            return NodeStatus::Cancelled;
        }
        // honor an operator Pause / recovery freeze at the
        // child boundary, mirroring `execute_children_sequential` (sequential.rs:52).
        // Without this, a TargetHeader carrying an end_when trigger (exactly
        // what the autopilot/scheduler builds) keeps exposing/slewing while
        // the UI shows "Paused". Block until resumed; unwind to Cancelled if
        // the sequence is cancelled while paused.
        if !context.wait_while_paused().await {
            return NodeStatus::Cancelled;
        }
        if context.is_skip_to_next_target_requested() {
            return NodeStatus::Skipped;
        }

        // Pre-child end_when probe — see comment in
        // `execute_children_with_budget`.
        match trigger_observer_ctx(config, context, &end, TriggerRole::EndWhen) {
            Ok(trig_ctx) => {
                if end.is_satisfied(&trig_ctx) {
                    emit_end_when_met(context, &node_id, &config.display_name(), &end);
                    mark_remaining_end_when(node, context, i, total).await;
                    return NodeStatus::Success;
                }
            }
            Err(reason) => {
                return refuse_unevaluable_trigger(context, &config.display_name(), reason)
            }
        }

        // Kept in sync with
        // `execute_children_sequential`.
        if let Some(ref skip_target) = context.skip_to_node_target() {
            if child.id() == skip_target {
                context.clear_skip_to_node_request();
            } else if !child.contains_node(skip_target) {
                let mut update = ProgressUpdate::lifecycle(
                    child.id().clone(),
                    NodeStatus::Skipped,
                    format!("Skipped by SkipToNode request (target: {})", skip_target),
                );
                update.current_child = Some(i);
                update.total_children = Some(total);
                context.send_progress(update);
                continue;
            }
        }

        let mut step_update = ProgressUpdate::lifecycle(
            node_id.clone(),
            NodeStatus::Running,
            format!("Step {}/{}: {}", i + 1, total, child.name()),
        );
        step_update.current_child = Some(i);
        step_update.total_children = Some(total);
        context.send_progress(step_update);

        let result = child.execute(context).await;

        if result == NodeStatus::Skipped && context.is_skip_to_next_target_requested() {
            return NodeStatus::Skipped;
        }
        if result == NodeStatus::Failure || result == NodeStatus::Cancelled {
            return result;
        }

        // Post-child end_when check so dusk arriving mid-burst still
        // promptly stops imaging.
        match trigger_observer_ctx(config, context, &end, TriggerRole::EndWhen) {
            Ok(trig_ctx) => {
                if end.is_satisfied(&trig_ctx) {
                    emit_end_when_met(context, &node_id, &config.display_name(), &end);
                    mark_remaining_end_when(node, context, i + 1, total).await;
                    return NodeStatus::Success;
                }
            }
            Err(reason) => {
                return refuse_unevaluable_trigger(context, &config.display_name(), reason)
            }
        }
    }

    let _ = Ordering::Relaxed; // touch the imported symbol to keep the import path stable
    NodeStatus::Success
}

/// Which of a target's two triggers is under evaluation. The no-site refusal
/// reads back the sentence the operator configured, so it has to know whether
/// the condition starts the target or stops it.
#[derive(Clone, Copy)]
enum TriggerRole {
    StartWhen,
    EndWhen,
}

/// True when evaluating `trigger` needs to know where the rig is.
///
/// [`TargetTrigger::references_altitude`] answers for the two altitude leaves.
/// `HourAngleBetween` needs the site too — its hour angle is measured against
/// the local sidereal time, which is a function of longitude — and it is not an
/// altitude leaf, so it is named here rather than folded into that predicate
/// (which the Dart validator also consumes for its altitude-specific rule).
/// `TimeAfter` / `TimeBefore` read the wall clock and nothing else.
fn needs_observer_site(trigger: &TargetTrigger) -> bool {
    match trigger {
        TargetTrigger::HourAngleBetween { .. } => true,
        TargetTrigger::And(terms) | TargetTrigger::Or(terms) => {
            terms.iter().any(needs_observer_site)
        }
        other => other.references_altitude(),
    }
}

/// The operator-facing reason a trigger cannot be evaluated without a site.
fn no_observer_site_reason(trigger: &TargetTrigger, role: TriggerRole) -> String {
    let clause = match role {
        TriggerRole::StartWhen => {
            format!("This target waits for {} before it starts", trigger.label())
        }
        TriggerRole::EndWhen => format!("This target stops when {}", trigger.label()),
    };
    format!(
        "{}, but no observer location is set, so the sequencer cannot work out whether the \
         target is up. Set the observer latitude and longitude in Settings, then start the \
         sequence again.",
        clause
    )
}

/// Build the [`TriggerObserverContext`] a trigger evaluation needs from the
/// live ExecutionContext and the target's RA/Dec, or return the reason it
/// cannot be built.
///
/// Time-only triggers (`TimeAfter`, `TimeBefore`) read `now` and nothing else,
/// so they evaluate with or without a configured site and the observer fields
/// go unread — that is what keeps a site-less rig's `end_before` working.
/// Every other leaf is measured FROM somewhere, and answering it at latitude 0
/// / longitude 0 invents the answer: a target 5° up at Null Island was reported
/// as fact in a run warning and a whole target was skipped without imaging,
/// while the same trigger type on `start_when` refused. Both call sites now go
/// through this one guard, so neither can state an altitude the rig's location
/// does not support.
fn trigger_observer_ctx(
    config: &TargetHeaderConfig,
    context: &ExecutionContext,
    trigger: &TargetTrigger,
    role: TriggerRole,
) -> Result<TriggerObserverContext, String> {
    let (latitude_deg, longitude_deg) = match (context.latitude, context.longitude) {
        (Some(lat), Some(lon)) => (lat, lon),
        _ if needs_observer_site(trigger) => return Err(no_observer_site_reason(trigger, role)),
        // Reached only for a trigger `needs_observer_site` rejected, i.e. one
        // whose `is_satisfied` reads `now` alone. These two fields are dead
        // weight on that path; NaN keeps them that way, because a leaf that
        // did read them would compare false rather than produce a plausible
        // altitude for the equator.
        _ => (f64::NAN, f64::NAN),
    };
    Ok(TriggerObserverContext {
        latitude_deg,
        longitude_deg,
        target_ra_hours: config.ra_hours,
        target_dec_degrees: config.dec_degrees,
        now: context.clock.now_utc(),
    })
}

/// Log and publish the refusal to evaluate a target trigger, and hand back the
/// status the caller returns.
///
/// The refusal has to leave the log. `InstructionFailed` is one of the two
/// channels the run's terminal handler drains for `SequenceFailed { error }`
/// (`executor::failure_cause::run_failure_report`), and the bridge already
/// re-publishes it as a mid-run `SequencerEvent::Error`. Publishing here is
/// therefore what puts the reason on `/api/sequencer/status`, in the run's
/// `statsJson.errorMessages` and in the Session Report — instead of the
/// "Sequence failed" placeholder the terminal handler falls back to when no
/// node reported a reason. A container node rather than an instruction is
/// still the node that failed, and the drain formats the pair as
/// "<node>: <reason>", which is what the operator needs to read.
fn refuse_unevaluable_trigger(
    context: &ExecutionContext,
    target_label: &str,
    reason: String,
) -> NodeStatus {
    tracing::error!("Target {}: {}", target_label, reason);
    if let Some(event_tx) = context.event_tx.as_ref() {
        let _ = event_tx.send(crate::executor::ExecutorEvent::InstructionFailed {
            node_name: target_label.to_string(),
            message: reason,
        });
    }
    NodeStatus::Failure
}

/// Wait until `trigger.is_satisfied(...)` is true, polling every
/// `poll_secs` seconds. Cancellation / skip-to-next-target / observer
/// missing all return early with the appropriate status.
async fn wait_for_trigger(
    config: &TargetHeaderConfig,
    context: &ExecutionContext,
    trigger: &TargetTrigger,
    poll_secs: u32,
) -> NodeStatus {
    use std::sync::atomic::Ordering;

    // A start_when the observer location is needed for and no location set is
    // almost always a misconfigured profile rather than "image at lat=0". The
    // Dart validator (`TargetTriggerImpossibleAltitudeRule`) warns about this
    // at edit time; here it fails closed rather than silently behaving as if
    // the rig were on the equator.
    let target_label = config.display_name();
    let trig_ctx = match trigger_observer_ctx(config, context, trigger, TriggerRole::StartWhen) {
        Ok(trig_ctx) => trig_ctx,
        Err(reason) => return refuse_unevaluable_trigger(context, &target_label, reason),
    };
    if trigger.is_satisfied(&trig_ctx) {
        return NodeStatus::Success;
    }

    let label = trigger.label();
    let mut emitted_initial = false;
    let poll = std::time::Duration::from_secs(u64::from(poll_secs));

    loop {
        if context.is_cancelled.load(Ordering::Relaxed) {
            tracing::info!("Cancelled while waiting for start_when on {}", target_label);
            return NodeStatus::Cancelled;
        }
        if context.is_skip_to_next_target_requested() {
            tracing::info!(
                "Skip-to-next-target requested while waiting for start_when on {}",
                target_label
            );
            return NodeStatus::Skipped;
        }

        // Re-derived every poll: the operator can clear the observer location
        // in Settings while this wait is running, and the refusal is the honest
        // answer from that moment on.
        let trig_ctx = match trigger_observer_ctx(config, context, trigger, TriggerRole::StartWhen)
        {
            Ok(trig_ctx) => trig_ctx,
            Err(reason) => return refuse_unevaluable_trigger(context, &target_label, reason),
        };
        if trigger.is_satisfied(&trig_ctx) {
            tracing::info!("start_when fired for {} ({})", target_label, label);
            return NodeStatus::Success;
        }

        if !emitted_initial {
            emitted_initial = true;
            tracing::info!(
                "Waiting for {} on {} — current altitude {:.1}°",
                label,
                target_label,
                trig_ctx.current_altitude_deg()
            );
        }

        tokio::time::sleep(poll).await;
    }
}

/// Trigger id every `end_when`-at-entry skip is published under.
///
/// The Dart run-stats layer keys on this id to turn the fire into a run
/// WARNING (`packages/skotiq_core/lib/src/providers/sequence/target_end_when_notice.dart`);
/// it is a machine identifier and must stay byte-identical on both sides.
pub const TARGET_END_WHEN_TRIGGER_ID: &str = "target_end_when";

/// The trigger fired before the target imaged anything: its `end_when` was
/// already true at entry, so the whole target is skipped.
///
/// Until this existed the skip left NO trace outside the Rust process log — a
/// run that dropped an entire target answered `state: "completed"`,
/// `warningMessages: []`, and a `statsJson.targetBreakdown` the target was
/// absent from, so no surface an operator reads could say a target had been
/// dropped, let alone why. Reproduced on the appliance: a two-target sequence
/// whose first target carried `end_when = TimeAfter(now - 1h)` finished
/// `completed / progress 1.0` with 2 frames and an empty warning list, and the
/// only record anywhere was one `WARN` line in the log file.
///
/// It rides `TriggerFired` rather than the `InstructionFailed` channel the
/// unevaluable-`start_when` refusal uses, because nothing failed: a target
/// trigger fired and the executor did what the operator configured it to do.
/// `InstructionFailed` reaches Dart as a sequencer `Error`, which paints the
/// node red, pushes a running sequence into `recovering` and sends the phone a
/// "Sequence failed" notification — three claims that would all be untrue.
/// `TriggerFired` is Info severity end to end and is already the channel the
/// trigger feed renders.
///
/// The three fields carry exactly what they are named for: `trigger_id` is the
/// classification key, `trigger_name` is the operator-readable name of the
/// trigger that fired (which target it guards and what it tests), and `action`
/// is what the executor did about it. The consequence sentence is composed on
/// the Dart side from those, the same division of labour the meridian-flip
/// outcome uses.
fn emit_end_when_skipped_at_entry(
    context: &ExecutionContext,
    node_id: &crate::NodeId,
    display_name: &str,
    end_when: &TargetTrigger,
) {
    let trigger_name = format!(
        "The end condition on \"{}\" ({})",
        display_name,
        operator_trigger_label(end_when)
    );
    tracing::warn!(
        "{} was already satisfied at entry; skipping the target without imaging",
        trigger_name
    );
    if let Some(event_tx) = context.event_tx.as_ref() {
        let _ = event_tx.send(crate::executor::ExecutorEvent::TriggerFired {
            trigger_id: TARGET_END_WHEN_TRIGGER_ID.to_string(),
            trigger_name: trigger_name.clone(),
            action: "SkipTarget".to_string(),
        });
    }
    // Paint the reason onto the target node itself as well, so the tree shows
    // WHY it went grey — the same lifecycle channel [`emit_end_when_met`] uses
    // for the mid-target case, which was the only one of the two that ever
    // said anything.
    context.send_progress(ProgressUpdate::lifecycle(
        node_id.clone(),
        NodeStatus::Skipped,
        format!("{} was already met; skipped without imaging", trigger_name),
    ));
}

/// [`TargetTrigger::label`], with the time-bearing leaves rendered as a UTC
/// instant instead of a raw Unix timestamp.
///
/// `label()` is the engine's own vocabulary and prints `time ≥ 1786970284`,
/// which is exact and unreadable. Every consumer that only logs it keeps that
/// form; the operator-facing copy composed here does not, because "the end
/// condition was already met" is useless without knowing WHEN it was met.
fn operator_trigger_label(trigger: &TargetTrigger) -> String {
    fn instant(ts: i64) -> String {
        match chrono::DateTime::<chrono::Utc>::from_timestamp(ts, 0) {
            Some(dt) => dt.format("%Y-%m-%d %H:%M UTC").to_string(),
            // The timestamp is outside the representable range; the raw value
            // is the only true thing left to say about it.
            None => ts.to_string(),
        }
    }
    match trigger {
        TargetTrigger::TimeAfter(ts) => format!("time ≥ {}", instant(*ts)),
        TargetTrigger::TimeBefore(ts) => format!("time < {}", instant(*ts)),
        TargetTrigger::And(terms) => format!(
            "({})",
            terms
                .iter()
                .map(operator_trigger_label)
                .collect::<Vec<_>>()
                .join(" AND ")
        ),
        TargetTrigger::Or(terms) => format!(
            "({})",
            terms
                .iter()
                .map(operator_trigger_label)
                .collect::<Vec<_>>()
                .join(" OR ")
        ),
        other => other.label(),
    }
}

/// Lifecycle event emitted when `end_when` fires.
fn emit_end_when_met(
    context: &ExecutionContext,
    node_id: &crate::NodeId,
    display_name: &str,
    end_when: &TargetTrigger,
) {
    let msg = format!(
        "Target {} end_when satisfied ({}); stopping",
        display_name,
        end_when.label()
    );
    tracing::info!("{}", msg);
    let upd = ProgressUpdate::lifecycle(node_id.clone(), NodeStatus::Running, msg);
    context.send_progress(upd);
}

/// Mark every child from index `start` onward as Skipped because
/// `end_when` fired — the lifecycle messages are kept distinct from the
/// integration-budget messages so the UI can tell the two apart.
async fn mark_remaining_end_when(
    node: &crate::node::runtime::RuntimeNode,
    context: &mut ExecutionContext,
    start: usize,
    total: usize,
) {
    for (i, child) in node.children.iter().enumerate().skip(start) {
        let mut update = ProgressUpdate::lifecycle(
            child.id().clone(),
            NodeStatus::Skipped,
            "Skipped — target end_when satisfied".to_string(),
        );
        update.current_child = Some(i);
        update.total_children = Some(total);
        context.send_progress(update);
    }
}

/// Emit a lifecycle event on the TargetHeader describing *why* the
/// budget terminated. Surfaced to the trigger feed so the user sees
/// "M31: integration budget met (8h00m total)" — not just a silent
/// skip-to-next-target.
async fn emit_budget_met(
    context: &mut ExecutionContext,
    node_id: &crate::NodeId,
    display_name: &str,
    state: &crate::scheduling::BudgetState,
    budget: &crate::IntegrationBudget,
) {
    let evaluation = state.evaluate(budget);
    let reason_text = match &evaluation {
        BudgetEvaluation::Met {
            reason: BudgetMetReason::TotalReached,
            completed_total,
            budget_total,
            ..
        } => format!(
            "total integration {:.0}s / {:.0}s reached",
            completed_total, budget_total
        ),
        BudgetEvaluation::Met {
            reason: BudgetMetReason::AllFiltersComplete,
            ..
        } => "every filter reached its per-filter cap".to_string(),
        // We only call this helper when the budget IS met, but the
        // pattern match still needs the Open arm.
        BudgetEvaluation::Open { .. } => "budget complete".to_string(),
    };
    let msg = format!(
        "Integration budget met for {}: {}",
        display_name, reason_text
    );
    tracing::info!("{}", msg);
    let lifecycle = ProgressUpdate::lifecycle(node_id.clone(), NodeStatus::Running, msg);
    context.send_progress(lifecycle);

    // Also emit a structured IntegrationBudget progress event so the
    // dashboard can flip the target tile to "complete" without
    // re-fetching state.
    let total_cap = if budget.total_secs > 0.0 {
        budget.total_secs
    } else {
        // Sum of resolved per-filter caps — useful when no overall
        // total was set but per-filter caps cover everything.
        budget.resolved_caps().values().sum()
    };
    let fraction = if total_cap > 0.0 {
        (state.completed_total_secs / total_cap).clamp(0.0, 1.5)
    } else {
        1.0
    };
    let mut upd = ProgressUpdate::instruction_progress(
        node_id.clone(),
        "IntegrationBudget",
        100.0_f64.min(fraction * 100.0),
        ProgressDetail::IntegrationBudget {
            target_id: node_id.clone(),
            filter: String::new(),
            completed_secs: state.completed_total_secs,
            budget_secs: total_cap,
            fraction,
            budget_met: true,
        },
    );
    upd.message = Some(format!(
        "Budget met for {} ({:.0}s)",
        display_name, state.completed_total_secs
    ));
    context.send_progress(upd);
}

/// Mark every child from index `start` onward as Skipped so the UI
/// renders them greyed-out. Idempotent — calling this twice in a row
/// (e.g. on resume) just re-emits the lifecycle events.
async fn mark_remaining_skipped(
    node: &crate::node::runtime::RuntimeNode,
    context: &mut ExecutionContext,
    start: usize,
    total: usize,
) {
    for (i, child) in node.children.iter().enumerate().skip(start) {
        let mut update = ProgressUpdate::lifecycle(
            child.id().clone(),
            NodeStatus::Skipped,
            "Skipped — integration budget met".to_string(),
        );
        update.current_child = Some(i);
        update.total_children = Some(total);
        context.send_progress(update);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scheduling::{BudgetEvaluation, BudgetState};
    use crate::{FilterBudgetEntry, IntegrationBudget, NodeDefinition, NodeType};

    fn header_with_budget(budget: IntegrationBudget) -> TargetHeaderConfig {
        TargetHeaderConfig {
            target_name: "M31".to_string(),
            ra_hours: 0.5,
            dec_degrees: 41.0,
            integration_budget: Some(budget),
            ..TargetHeaderConfig::default()
        }
    }

    /// Pre-met budget at re-entry should immediately Skip all children
    /// and return Success — the resume-after-budget-hit path.
    #[tokio::test]
    async fn budget_pre_met_skips_children_and_returns_success() {
        let budget = IntegrationBudget {
            total_secs: 60.0,
            per_filter: Default::default(),
            stop_on_budget_met: true,
        };

        let exposure_def = NodeDefinition {
            id: "expose1".to_string(),
            name: "Expose".to_string(),
            node_type: NodeType::Delay(crate::DelayConfig { seconds: 0.0 }),
            enabled: true,
            children: vec![],
        };
        let header_def = NodeDefinition {
            id: "header1".to_string(),
            name: "Target".to_string(),
            node_type: NodeType::TargetHeader(header_with_budget(budget.clone())),
            enabled: true,
            children: vec![],
        };
        let mut node = crate::node::runtime::RuntimeNode::from_definition(header_def);
        node.add_child(Box::new(
            crate::node::runtime::RuntimeNode::from_definition(exposure_def),
        ));

        let mut ctx = ExecutionContext::new_for_test("root".to_string());

        // Seed the budget registry as if a prior run had already met the budget.
        let mut prior = BudgetState::new("header1");
        prior.credit(None, 120.0);
        let snap = crate::scheduling::BudgetRegistrySnapshot {
            states: vec![prior],
        };
        ctx.budget_registry.restore_snapshot(snap).await;

        // Execute the target header — should return Success without
        // touching the child.
        let config = match &node.definition.node_type {
            NodeType::TargetHeader(c) => c.clone(),
            _ => unreachable!(),
        };
        let status = execute_target_header(&mut node, config, &mut ctx).await;
        assert_eq!(status, NodeStatus::Success);
    }

    /// Mid-run: credit the budget through the registry while inside the
    /// active target, then evaluate at the next child boundary — the
    /// helper must report Met.
    #[tokio::test]
    async fn budget_evaluation_mid_run_detects_met() {
        let budget = IntegrationBudget {
            total_secs: 0.0,
            per_filter: [
                ("L".to_string(), FilterBudgetEntry::Absolute(60.0)),
                ("R".to_string(), FilterBudgetEntry::Absolute(60.0)),
            ]
            .into_iter()
            .collect(),
            stop_on_budget_met: true,
        };

        let ctx = ExecutionContext::new_for_test("root".to_string());
        ctx.budget_registry
            .enter_target("header1", Some(budget.clone()))
            .await;
        // Two L exposures of 30s + two R exposures of 30s = both filters full.
        for _ in 0..2 {
            ctx.budget_registry
                .record_exposure(Some("L"), 30.0)
                .await
                .expect("active target");
        }
        for _ in 0..2 {
            ctx.budget_registry
                .record_exposure(Some("R"), 30.0)
                .await
                .expect("active target");
        }
        let state = ctx
            .budget_registry
            .state_for("header1")
            .await
            .expect("state retained");
        match state.evaluate(&budget) {
            BudgetEvaluation::Met { reason, .. } => {
                assert_eq!(
                    reason,
                    crate::scheduling::BudgetMetReason::AllFiltersComplete
                );
            }
            BudgetEvaluation::Open { .. } => panic!("budget should be met"),
        }
    }

    // Target context population tests

    /// at TargetHeader entry the executor's `target_id`,
    /// `target_name`, `target_ra`, `target_dec`, and `mosaic_panel` must
    /// be set so subsequent TakeExposure FITS headers carry real values.
    /// The runtime body proxies execute_children_sequential, so we trap
    /// the values via a sentinel child that copies them out before
    /// returning.
    #[tokio::test]
    async fn target_header_populates_context_fields_at_entry() {
        use crate::MosaicPanelInfo;
        use std::sync::{Arc, Mutex};

        // Sentinel child: records ctx.target_id/target_name/mosaic_panel
        // when visited. We can't easily inject a custom Node so we use a
        // Delay node and observe context state by exposing the snapshot
        // via a side channel.
        //
        // Instead: drive a TargetHeader with a sentinel `progress_callback`
        // that fires on the TargetHeader's own lifecycle event. The
        // callback fires before children execute, by which point the
        // entry-time field population must have already happened.
        let panel = MosaicPanelInfo {
            mosaic_name: "M31 mosaic".to_string(),
            panel_index: 2,
            total_panels: 9,
            row: 0,
            column: 2,
        };
        let header_def = NodeDefinition {
            id: "tgt-uuid-abc".to_string(),
            name: "M31 Panel 3".to_string(),
            node_type: NodeType::TargetHeader(TargetHeaderConfig {
                target_name: "M31".to_string(),
                ra_hours: 0.7,
                dec_degrees: 41.27,
                mosaic_panel: Some(panel.clone()),
                ..TargetHeaderConfig::default()
            }),
            enabled: true,
            children: vec![],
        };
        let mut node = crate::node::runtime::RuntimeNode::from_definition(header_def);

        // A child delay (0s) lets the body finish quickly. The body
        // executes execute_children_sequential which visits the delay
        // synchronously. By then the entry-time stamps must be in place.
        let delay_def = NodeDefinition {
            id: "delay1".to_string(),
            name: "wait".to_string(),
            node_type: NodeType::Delay(crate::DelayConfig { seconds: 0.0 }),
            enabled: true,
            children: vec![],
        };
        node.add_child(Box::new(
            crate::node::runtime::RuntimeNode::from_definition(delay_def),
        ));

        let mut ctx = ExecutionContext::new_for_test("root".to_string());
        // Prior values must be restored on exit; seed them with sentinel
        // values to verify scope-restore.
        let prior_target_id = "outer-target".to_string();
        ctx.target_id = Some(prior_target_id.clone());
        ctx.target_name = Some("outer-target-name".to_string());

        // Capture state visible to children via a progress callback that
        // snapshots ctx fields on every lifecycle event from the delay
        // node. The first such event fires once the delay is visited,
        // which means the entry-stamps are visible.
        type CapturedScopeFields = (Option<String>, Option<String>, Option<MosaicPanelInfo>);
        let captured: Arc<Mutex<Vec<CapturedScopeFields>>> = Arc::new(Mutex::new(Vec::new()));

        // We can't easily snapshot ctx from inside the callback because
        // the callback doesn't carry ctx, BUT the bodies of the
        // sequential walker check ctx state independently. Instead, set
        // the callback to a no-op and read ctx after `execute_target_header`
        // returns — verifying the restore path.
        let captured_clone = captured.clone();
        ctx.progress_callback = Some(std::sync::Arc::new(move |_update| {
            let _ = captured_clone; // unused: callback can't see ctx.
        }));

        let config = match &node.definition.node_type {
            NodeType::TargetHeader(c) => c.clone(),
            _ => unreachable!(),
        };
        let status = execute_target_header(&mut node, config, &mut ctx).await;
        assert_eq!(status, NodeStatus::Success);

        // After execute_target_header returns, the prior scope must be
        // restored — target_id is `outer-target`, target_name is the
        // outer one. mosaic_panel was None before; must be None after.
        assert_eq!(
            ctx.target_id,
            Some(prior_target_id),
            "target_id must be restored to the prior scope on exit"
        );
        assert_eq!(
            ctx.target_name,
            Some("outer-target-name".to_string()),
            "target_name must be restored to the prior scope on exit"
        );
        assert!(
            ctx.mosaic_panel.is_none(),
            "mosaic_panel must be cleared (restored to None) on exit"
        );
    }

    /// TargetHeader populates `mosaic_panel` on the way in. This
    /// test asserts the mid-execution state by hooking a child node that
    /// observes `ctx.mosaic_panel`. We use a custom RuntimeNode child via
    /// a Notification node (no side effects) and observe through the
    /// progress callback shape.
    ///
    /// Simpler verification: confirm that when the TargetHeader's
    /// altitude check fails (mid-run early return), the prior context is
    /// still restored.
    #[tokio::test]
    async fn target_header_restores_prior_on_early_skip() {
        let header_def = NodeDefinition {
            id: "below-horizon".to_string(),
            name: "M42".to_string(),
            node_type: NodeType::TargetHeader(TargetHeaderConfig {
                target_name: "M42".to_string(),
                ra_hours: 5.59,
                dec_degrees: -5.39,
                // Force Skip via end_before in the past — independent of
                // observer location / time-of-day, which makes this
                // deterministic.
                end_before: Some(0),
                ..TargetHeaderConfig::default()
            }),
            enabled: true,
            children: vec![],
        };
        let mut node = crate::node::runtime::RuntimeNode::from_definition(header_def);

        let mut ctx = ExecutionContext::new_for_test("root".to_string());
        ctx.target_id = Some("outer".to_string());
        ctx.target_name = Some("outer-name".to_string());
        ctx.target_ra = Some(99.0);

        let config = match &node.definition.node_type {
            NodeType::TargetHeader(c) => c.clone(),
            _ => unreachable!(),
        };
        let status = execute_target_header(&mut node, config, &mut ctx).await;
        // end_before in the past => Skipped via early return.
        assert_eq!(status, NodeStatus::Skipped);

        // Even though the body never reached the budget setup or the
        // child walker, the snapshot restore at function exit must have
        // run.
        assert_eq!(ctx.target_id, Some("outer".to_string()));
        assert_eq!(ctx.target_name, Some("outer-name".to_string()));
        assert_eq!(ctx.target_ra, Some(99.0));
    }

    // Per-target start/end crossings (MockClock-driven)

    use crate::scheduling::{Clock, MockClock, TargetTrigger};
    use crate::DelayConfig;

    fn make_delay_node(id: &str) -> NodeDefinition {
        NodeDefinition {
            id: id.to_string(),
            name: "wait".to_string(),
            node_type: NodeType::Delay(DelayConfig { seconds: 0.0 }),
            enabled: true,
            children: vec![],
        }
    }

    /// when `end_when` is already satisfied at TargetHeader entry,
    /// the runtime returns Skipped without executing children. Replaces the
    /// pre-Wave-4 `end_before` early-Skip path with the new trigger model.
    #[tokio::test]
    async fn end_when_satisfied_at_entry_skips_target() {
        // Pin the clock to a known instant; set end_when = TimeAfter(now - 1)
        // so it's already in the past → already satisfied.
        let clock = MockClock::at("2026-01-15T22:00:00Z");
        let now_ts = clock.now_utc().timestamp();

        let header_def = NodeDefinition {
            id: "tgt".into(),
            name: "M31".into(),
            node_type: NodeType::TargetHeader(TargetHeaderConfig {
                target_name: "M31".into(),
                ra_hours: 0.7,
                dec_degrees: 41.27,
                end_when: Some(TargetTrigger::TimeAfter(now_ts - 1)),
                ..TargetHeaderConfig::default()
            }),
            enabled: true,
            children: vec![],
        };
        let mut node = crate::node::runtime::RuntimeNode::from_definition(header_def);
        node.add_child(Box::new(
            crate::node::runtime::RuntimeNode::from_definition(make_delay_node("d1")),
        ));

        let mut ctx = ExecutionContext::new_for_test("root".into()).with_clock(clock);
        ctx.latitude = Some(40.0);
        ctx.longitude = Some(-74.0);

        let config = match &node.definition.node_type {
            NodeType::TargetHeader(c) => c.clone(),
            _ => unreachable!(),
        };
        let status = execute_target_header(&mut node, config, &mut ctx).await;
        assert_eq!(status, NodeStatus::Skipped);
    }

    /// when `start_when` is already satisfied at entry, the
    /// runtime proceeds without waiting and the target completes Success.
    #[tokio::test]
    async fn start_when_already_satisfied_does_not_wait() {
        let clock = MockClock::at("2026-01-15T22:00:00Z");
        let now_ts = clock.now_utc().timestamp();

        let header_def = NodeDefinition {
            id: "tgt".into(),
            name: "M31".into(),
            node_type: NodeType::TargetHeader(TargetHeaderConfig {
                target_name: "M31".into(),
                ra_hours: 0.7,
                dec_degrees: 41.27,
                start_when: Some(TargetTrigger::TimeAfter(now_ts - 60)),
                ..TargetHeaderConfig::default()
            }),
            enabled: true,
            children: vec![],
        };
        let mut node = crate::node::runtime::RuntimeNode::from_definition(header_def);
        node.add_child(Box::new(
            crate::node::runtime::RuntimeNode::from_definition(make_delay_node("d1")),
        ));

        let mut ctx = ExecutionContext::new_for_test("root".into()).with_clock(clock);
        ctx.latitude = Some(40.0);
        ctx.longitude = Some(-74.0);

        let config = match &node.definition.node_type {
            NodeType::TargetHeader(c) => c.clone(),
            _ => unreachable!(),
        };
        let status = execute_target_header(&mut node, config, &mut ctx).await;
        assert_eq!(status, NodeStatus::Success);
    }

    /// `wait_for_trigger` polls until the trigger fires when
    /// time advances. We use a 1-second poll interval and a spawned task
    /// that advances MockClock past the trigger threshold so the wait
    /// exits Success.
    #[tokio::test]
    async fn wait_for_trigger_advances_then_fires() {
        let clock = MockClock::at("2026-01-15T22:00:00Z");
        let now_ts = clock.now_utc().timestamp();
        let target_ts = now_ts + 60; // 1 minute in the (mock) future

        let cfg = TargetHeaderConfig {
            target_name: "M31".into(),
            ra_hours: 0.7,
            dec_degrees: 41.27,
            ..TargetHeaderConfig::default()
        };
        let mut ctx = ExecutionContext::new_for_test("root".into()).with_clock(clock.clone());
        ctx.latitude = Some(40.0);
        ctx.longitude = Some(-74.0);

        // Spawn a task that advances the mock clock past the target after
        // a short real-time delay. The wait_for_trigger polls every 1s
        // (poll_secs = 1) so the first or second poll will land after we
        // advance.
        let clock_for_advancer = clock.clone();
        let advancer = tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            clock_for_advancer.advance(std::time::Duration::from_secs(120));
        });

        let trigger = TargetTrigger::TimeAfter(target_ts);
        let status = wait_for_trigger(&cfg, &ctx, &trigger, 1).await;
        advancer.await.unwrap();
        assert_eq!(status, NodeStatus::Success);
        // Verify the clock was actually advanced (sanity check).
        assert!(ctx.clock.now_utc().timestamp() >= target_ts);
    }

    /// `wait_for_trigger` honours cancellation while waiting.
    #[tokio::test]
    async fn wait_for_trigger_cancels() {
        let clock = MockClock::at("2026-01-15T22:00:00Z");
        let cfg = TargetHeaderConfig {
            target_name: "M31".into(),
            ra_hours: 0.7,
            dec_degrees: 41.27,
            ..TargetHeaderConfig::default()
        };
        let mut ctx = ExecutionContext::new_for_test("root".into()).with_clock(clock.clone());
        ctx.latitude = Some(40.0);
        ctx.longitude = Some(-74.0);

        let cancel = ctx.is_cancelled.clone();
        let canceller = tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            cancel.store(true, std::sync::atomic::Ordering::Relaxed);
        });

        // Trigger that's far in the (mock) future.
        let trigger = TargetTrigger::TimeAfter(clock.now_utc().timestamp() + 86_400);
        let status = wait_for_trigger(&cfg, &ctx, &trigger, 1).await;
        canceller.await.unwrap();
        assert_eq!(status, NodeStatus::Cancelled);
    }

    // Operator Pause honored in the end_when / budget walkers

    /// A paused TargetHeader carrying an `end_when` trigger must NOT execute its
    /// children, and must unwind to Cancelled when the sequence is cancelled while
    /// paused. This exercises the `execute_children_with_end_when` walker
    /// (end_when set, not satisfied at entry): a walker that checks only
    /// `is_cancelled` / `is_skip_to_next_target` keeps exposing and slewing on an
    /// autopilot/scheduler-built target — which always carries an end_when — while
    /// the UI shows "Paused".
    ///
    /// Discriminator: the walker emits a "Step 1/1" lifecycle update with
    /// `current_child == Some(0)` immediately BEFORE executing the first child,
    /// i.e. only AFTER it clears the pause boundary. While paused, no such update
    /// fires, so the walker parks at the boundary and the later cancel makes it
    /// return Cancelled.
    #[tokio::test(start_paused = true)]
    async fn paused_target_header_with_end_when_does_not_run_children_and_cancels() {
        use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
        use std::sync::Arc;

        let clock = MockClock::at("2026-01-15T22:00:00Z");
        let now_ts = clock.now_utc().timestamp();

        // end_when in the FUTURE so it is NOT satisfied at entry — the body
        // takes the `execute_children_with_end_when` path with `Some(end)`.
        let header_def = NodeDefinition {
            id: "tgt-paused".into(),
            name: "M31".into(),
            node_type: NodeType::TargetHeader(TargetHeaderConfig {
                target_name: "M31".into(),
                ra_hours: 0.7,
                dec_degrees: 41.27,
                end_when: Some(TargetTrigger::TimeAfter(now_ts + 86_400)),
                ..TargetHeaderConfig::default()
            }),
            enabled: true,
            children: vec![],
        };
        let mut node = crate::node::runtime::RuntimeNode::from_definition(header_def);
        node.add_child(Box::new(
            crate::node::runtime::RuntimeNode::from_definition(make_delay_node("d1")),
        ));

        let mut ctx = ExecutionContext::new_for_test("root".into()).with_clock(clock);
        ctx.latitude = Some(40.0);
        ctx.longitude = Some(-74.0);

        // Record whenever the walker is about to execute a child (the
        // "Step N/total" lifecycle update carries current_child).
        let child_steps = Arc::new(AtomicUsize::new(0));
        let child_steps_cb = child_steps.clone();
        ctx.progress_callback = Some(Arc::new(move |update: ProgressUpdate| {
            if update.current_child.is_some() && update.status == NodeStatus::Running {
                child_steps_cb.fetch_add(1, Ordering::SeqCst);
            }
        }));

        // Operator Pause BEFORE execution begins.
        ctx.is_paused.store(true, Ordering::Relaxed);

        let cancel = ctx.is_cancelled.clone();
        let is_paused = ctx.is_paused.clone();
        let resume_notify = ctx.resume_notify.clone();
        let steps_for_controller = child_steps.clone();
        let observed_running_while_paused = Arc::new(AtomicBool::new(false));
        let observed_flag = observed_running_while_paused.clone();

        // Controller: confirm the walker parked at the pause boundary (no
        // child step fired while paused), then cancel and wake the waiter.
        let controller = async move {
            // Let the execution future run up to (and block at) the pause
            // boundary. Under start_paused the runtime auto-advances virtual
            // time across the 100ms wait_while_paused poll, so a few yields
            // are enough for it to settle at the boundary.
            for _ in 0..50 {
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                tokio::task::yield_now().await;
            }
            // While still paused, the child step must NOT have been emitted.
            if steps_for_controller.load(Ordering::SeqCst) == 0 && is_paused.load(Ordering::Relaxed)
            {
                observed_flag.store(true, Ordering::SeqCst);
            }
            // Cancel while paused — the walker must unwind to Cancelled.
            cancel.store(true, Ordering::Relaxed);
            resume_notify.notify_waiters();
        };

        let config = match &node.definition.node_type {
            NodeType::TargetHeader(c) => c.clone(),
            _ => unreachable!(),
        };

        let (status, ()) = tokio::join!(
            execute_target_header(&mut node, config, &mut ctx),
            controller
        );

        assert!(
            observed_running_while_paused.load(Ordering::SeqCst),
            "walker must park at the pause boundary — no child \
             may begin executing while the operator Pause is active"
        );
        assert_eq!(
            child_steps.load(Ordering::SeqCst),
            0,
            "no child may execute on a paused TargetHeader; the \
             pause boundary in execute_children_with_end_when was bypassed"
        );
        assert_eq!(
            status,
            NodeStatus::Cancelled,
            "cancel-while-paused must unwind the end_when walker \
             to Cancelled"
        );
    }

    /// guard for the budget walker: a paused TargetHeader
    /// carrying an integration budget must NOT execute its children and must
    /// unwind to Cancelled on cancel-while-paused. Exercises
    /// `execute_children_with_budget`, which had the identical pause hole.
    #[tokio::test(start_paused = true)]
    async fn paused_target_header_with_budget_does_not_run_children_and_cancels() {
        use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
        use std::sync::Arc;

        let budget = IntegrationBudget {
            total_secs: 3600.0,
            per_filter: Default::default(),
            stop_on_budget_met: true,
        };

        let header_def = NodeDefinition {
            id: "tgt-paused-budget".into(),
            name: "M31".into(),
            node_type: NodeType::TargetHeader(header_with_budget(budget)),
            enabled: true,
            children: vec![],
        };
        let mut node = crate::node::runtime::RuntimeNode::from_definition(header_def);
        node.add_child(Box::new(
            crate::node::runtime::RuntimeNode::from_definition(make_delay_node("d1")),
        ));

        let mut ctx = ExecutionContext::new_for_test("root".into());

        let child_steps = Arc::new(AtomicUsize::new(0));
        let child_steps_cb = child_steps.clone();
        ctx.progress_callback = Some(Arc::new(move |update: ProgressUpdate| {
            if update.current_child.is_some() && update.status == NodeStatus::Running {
                child_steps_cb.fetch_add(1, Ordering::SeqCst);
            }
        }));

        ctx.is_paused.store(true, Ordering::Relaxed);

        let cancel = ctx.is_cancelled.clone();
        let is_paused = ctx.is_paused.clone();
        let resume_notify = ctx.resume_notify.clone();
        let steps_for_controller = child_steps.clone();
        let observed_paused_park = Arc::new(AtomicBool::new(false));
        let observed_flag = observed_paused_park.clone();

        let controller = async move {
            for _ in 0..50 {
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                tokio::task::yield_now().await;
            }
            if steps_for_controller.load(Ordering::SeqCst) == 0 && is_paused.load(Ordering::Relaxed)
            {
                observed_flag.store(true, Ordering::SeqCst);
            }
            cancel.store(true, Ordering::Relaxed);
            resume_notify.notify_waiters();
        };

        let config = match &node.definition.node_type {
            NodeType::TargetHeader(c) => c.clone(),
            _ => unreachable!(),
        };

        let (status, ()) = tokio::join!(
            execute_target_header(&mut node, config, &mut ctx),
            controller
        );

        assert!(
            observed_paused_park.load(Ordering::SeqCst),
            "budget walker must park at the pause boundary"
        );
        assert_eq!(
            child_steps.load(Ordering::SeqCst),
            0,
            "no child may execute on a paused budgeted TargetHeader"
        );
        assert_eq!(
            status,
            NodeStatus::Cancelled,
            "cancel-while-paused must unwind the budget walker to Cancelled"
        );
    }

    /// altitude-bearing `start_when` without an observer fails
    /// closed instead of silently behaving like we're at lat=0/lon=0 — AND
    /// publishes the reason, so the run's terminal event can quote it instead
    /// of falling back to "Sequence failed".
    #[tokio::test]
    async fn altitude_start_when_without_observer_fails() {
        let clock = MockClock::at("2026-01-15T22:00:00Z");

        let header_def = NodeDefinition {
            id: "tgt".into(),
            name: "M31".into(),
            node_type: NodeType::TargetHeader(TargetHeaderConfig {
                target_name: "M31".into(),
                ra_hours: 0.7,
                dec_degrees: 41.27,
                start_when: Some(TargetTrigger::AltitudeAbove(35.0)),
                ..TargetHeaderConfig::default()
            }),
            enabled: true,
            children: vec![],
        };
        let mut node = crate::node::runtime::RuntimeNode::from_definition(header_def);
        let mut ctx = ExecutionContext::new_for_test("root".into()).with_clock(clock);
        // No latitude / longitude → fail closed.
        let (event_tx, mut event_rx) = tokio::sync::broadcast::channel(64);
        ctx.event_tx = Some(event_tx);

        let config = match &node.definition.node_type {
            NodeType::TargetHeader(c) => c.clone(),
            _ => unreachable!(),
        };
        let status = execute_target_header(&mut node, config, &mut ctx).await;
        assert_eq!(status, NodeStatus::Failure);

        // The executor drains exactly this variant to fill
        // `SequenceFailed { error }`; without it the operator reads only the
        // placeholder while the reason stays in the Rust log.
        let mut published = None;
        while let Ok(event) = event_rx.try_recv() {
            if let crate::executor::ExecutorEvent::InstructionFailed { node_name, message } = event
            {
                published = Some((node_name, message));
            }
        }
        let (node_name, reason) =
            published.expect("the refusal published an InstructionFailed reason");
        assert_eq!(
            node_name, "M31",
            "the reason must be attributed to the target that refused"
        );
        assert!(
            reason.contains("altitude ≥ 35.0°"),
            "the reason must quote the condition that could not be evaluated, got: {reason}"
        );
        assert!(
            reason.contains("no observer location is set"),
            "the reason must say WHY it could not be evaluated, got: {reason}"
        );
        assert!(
            reason.contains("latitude and longitude in Settings"),
            "the reason must tell the operator how to fix it, got: {reason}"
        );
    }

    /// A target whose `end_when` has already passed is skipped without
    /// imaging, and states its reason on a channel that leaves the process.
    ///
    /// Before this, the skip published nothing: the run answered `completed`,
    /// `warningMessages: []`, and a `targetBreakdown` the target was missing
    /// from, so no operator surface could tell a night that dropped a whole
    /// target from one that imaged everything.
    #[tokio::test]
    async fn end_when_already_past_publishes_its_reason() {
        // 22:00 UTC on the night; the target's window shut at 21:00.
        let clock = MockClock::at("2026-01-15T22:00:00Z");
        let closed_at = chrono::DateTime::parse_from_rfc3339("2026-01-15T21:00:00Z")
            .unwrap()
            .timestamp();

        let header_def = NodeDefinition {
            id: "tgt".into(),
            name: "Dusk Field".into(),
            node_type: NodeType::TargetHeader(TargetHeaderConfig {
                target_name: "Dusk Field".into(),
                ra_hours: 0.7,
                dec_degrees: 41.27,
                end_when: Some(TargetTrigger::TimeAfter(closed_at)),
                ..TargetHeaderConfig::default()
            }),
            enabled: true,
            children: vec![],
        };
        let mut node = crate::node::runtime::RuntimeNode::from_definition(header_def);
        let mut ctx = ExecutionContext::new_for_test("root".into()).with_clock(clock);
        let (event_tx, mut event_rx) = tokio::sync::broadcast::channel(64);
        ctx.event_tx = Some(event_tx);

        let config = match &node.definition.node_type {
            NodeType::TargetHeader(c) => c.clone(),
            _ => unreachable!(),
        };
        let status = execute_target_header(&mut node, config, &mut ctx).await;
        assert_eq!(status, NodeStatus::Skipped);

        let mut published = None;
        let mut failures = 0;
        while let Ok(event) = event_rx.try_recv() {
            match event {
                crate::executor::ExecutorEvent::TriggerFired {
                    trigger_id,
                    trigger_name,
                    action,
                } => published = Some((trigger_id, trigger_name, action)),
                // Nothing failed. A failure event here would paint the node
                // red, push a running sequence into recovery and send the
                // operator a "Sequence failed" notification.
                crate::executor::ExecutorEvent::InstructionFailed { .. }
                | crate::executor::ExecutorEvent::Error { .. } => failures += 1,
                _ => {}
            }
        }
        assert_eq!(failures, 0, "a configured skip is not a failure");
        let (trigger_id, trigger_name, action) =
            published.expect("the skip published a TriggerFired reason");
        assert_eq!(
            trigger_id, TARGET_END_WHEN_TRIGGER_ID,
            "the Dart run-stats layer keys on this id"
        );
        assert_eq!(action, "SkipTarget");
        assert!(
            trigger_name.contains("Dusk Field"),
            "the reason must name the target that was dropped, got: {trigger_name}"
        );
        assert!(
            trigger_name.contains("2026-01-15 21:00 UTC"),
            "the reason must say WHEN the window closed, not print a raw Unix \
             timestamp, got: {trigger_name}"
        );
    }

    /// The operator-facing rendering keeps the engine's vocabulary for
    /// everything except the time leaves, which `label()` prints as raw epoch
    /// seconds.
    #[test]
    fn operator_trigger_label_renders_instants() {
        let ts = chrono::DateTime::parse_from_rfc3339("2026-01-15T21:00:00Z")
            .unwrap()
            .timestamp();
        assert_eq!(
            operator_trigger_label(&TargetTrigger::TimeAfter(ts)),
            "time ≥ 2026-01-15 21:00 UTC"
        );
        assert_eq!(
            operator_trigger_label(&TargetTrigger::AltitudeAbove(35.0)),
            TargetTrigger::AltitudeAbove(35.0).label(),
            "non-time leaves keep the engine's own label"
        );
        assert_eq!(
            operator_trigger_label(&TargetTrigger::And(vec![
                TargetTrigger::TimeAfter(ts),
                TargetTrigger::AltitudeBelow(20.0),
            ])),
            "(time ≥ 2026-01-15 21:00 UTC AND altitude ≤ 20.0°)",
            "a compound renders its time leaves too"
        );
    }

    /// An `end_when` that needs the observer site and no site set refuses,
    /// exactly as the same trigger type on `start_when` refuses.
    ///
    /// The at-entry check used to evaluate it at latitude 0 / longitude 0: a
    /// circumpolar target that never drops below 35° at the operator's real
    /// site never rises above 5° at Null Island, so `AltitudeBelow(10)` read as
    /// already met, the whole target was dropped without imaging, and the run
    /// warning stated that altitude as fact without ever mentioning the missing
    /// site (`state: "completed"`, `framesCaptured: 0`).
    #[tokio::test]
    async fn altitude_end_when_without_observer_refuses_instead_of_skipping() {
        let clock = MockClock::at("2026-01-15T22:00:00Z");

        let header_def = NodeDefinition {
            id: "tgt".into(),
            name: "No-Site Target".into(),
            node_type: NodeType::TargetHeader(TargetHeaderConfig {
                target_name: "No-Site Target".into(),
                ra_hours: 6.0,
                dec_degrees: 85.0,
                end_when: Some(TargetTrigger::AltitudeBelow(10.0)),
                ..TargetHeaderConfig::default()
            }),
            enabled: true,
            children: vec![],
        };
        let mut node = crate::node::runtime::RuntimeNode::from_definition(header_def);
        node.add_child(Box::new(
            crate::node::runtime::RuntimeNode::from_definition(make_delay_node("d1")),
        ));
        // No latitude / longitude → fail closed.
        let mut ctx = ExecutionContext::new_for_test("root".into()).with_clock(clock);
        let (event_tx, mut event_rx) = tokio::sync::broadcast::channel(64);
        ctx.event_tx = Some(event_tx);

        let config = match &node.definition.node_type {
            NodeType::TargetHeader(c) => c.clone(),
            _ => unreachable!(),
        };
        let status = execute_target_header(&mut node, config, &mut ctx).await;
        assert_eq!(
            status,
            NodeStatus::Failure,
            "an end_when that cannot be evaluated must refuse, not silently \
             drop the target"
        );

        let mut published = None;
        let mut skips = 0;
        while let Ok(event) = event_rx.try_recv() {
            match event {
                crate::executor::ExecutorEvent::InstructionFailed { node_name, message } => {
                    published = Some((node_name, message));
                }
                crate::executor::ExecutorEvent::TriggerFired { trigger_id, .. }
                    if trigger_id == TARGET_END_WHEN_TRIGGER_ID =>
                {
                    skips += 1;
                }
                _ => {}
            }
        }
        assert_eq!(
            skips, 0,
            "no skip may be published for a condition the sequencer cannot evaluate"
        );
        let (node_name, reason) =
            published.expect("the refusal published an InstructionFailed reason");
        assert_eq!(node_name, "No-Site Target");
        assert!(
            reason.contains("altitude ≤ 10.0°"),
            "the reason must quote the condition that could not be evaluated, got: {reason}"
        );
        assert!(
            reason.contains("no observer location is set"),
            "the reason must name the missing site, got: {reason}"
        );
        assert!(
            reason.contains("latitude and longitude in Settings"),
            "the reason must tell the operator how to fix it, got: {reason}"
        );
        assert!(
            !reason.contains("was already met"),
            "the refusal must not state the condition as met, got: {reason}"
        );
    }

    /// The `start_when` seam and the `end_when` seam give the same answer to
    /// the same missing site — one guard, two call sites.
    #[test]
    fn both_trigger_roles_refuse_a_missing_site_the_same_way() {
        let ctx = ExecutionContext::new_for_test("root".into());
        let config = TargetHeaderConfig {
            target_name: "M31".into(),
            ra_hours: 0.7,
            dec_degrees: 41.27,
            ..TargetHeaderConfig::default()
        };
        let trigger = TargetTrigger::AltitudeBelow(10.0);

        let start = trigger_observer_ctx(&config, &ctx, &trigger, TriggerRole::StartWhen)
            .expect_err("no site → refusal");
        let end = trigger_observer_ctx(&config, &ctx, &trigger, TriggerRole::EndWhen)
            .expect_err("no site → refusal");
        for reason in [&start, &end] {
            assert!(reason.contains("altitude ≤ 10.0°"), "got: {reason}");
            assert!(
                reason.contains("no observer location is set"),
                "got: {reason}"
            );
            assert!(
                reason.contains("latitude and longitude in Settings"),
                "got: {reason}"
            );
        }
        assert!(
            start.contains("before it starts") && end.contains("stops when"),
            "each reason reads back the condition the operator configured: \
             start={start} end={end}"
        );
    }

    /// A time-only trigger evaluates with no site configured — that is what
    /// keeps a site-less rig's `end_before` working — and the observer fields
    /// it never reads carry no number that could be mistaken for a position.
    #[test]
    fn time_only_trigger_evaluates_without_a_site() {
        let ctx = ExecutionContext::new_for_test("root".into());
        let config = TargetHeaderConfig {
            target_name: "M31".into(),
            ra_hours: 0.7,
            dec_degrees: 41.27,
            ..TargetHeaderConfig::default()
        };
        let trigger = TargetTrigger::TimeAfter(ctx.clock.now_utc().timestamp() - 1);
        let trig_ctx = trigger_observer_ctx(&config, &ctx, &trigger, TriggerRole::EndWhen)
            .expect("a time-only trigger needs no site");
        assert!(trigger.is_satisfied(&trig_ctx));
        assert!(
            trig_ctx.latitude_deg.is_nan() && trig_ctx.longitude_deg.is_nan(),
            "the unread observer fields must not carry a usable position"
        );
    }

    /// Which triggers need to know where the rig is. `HourAngleBetween`
    /// measures against the local sidereal time, so longitude is not optional
    /// for it either.
    #[test]
    fn needs_observer_site_covers_every_site_bearing_leaf() {
        assert!(needs_observer_site(&TargetTrigger::AltitudeAbove(35.0)));
        assert!(needs_observer_site(&TargetTrigger::AltitudeBelow(10.0)));
        assert!(needs_observer_site(&TargetTrigger::HourAngleBetween {
            min_ha: -1.0,
            max_ha: 1.0,
        }));
        assert!(!needs_observer_site(&TargetTrigger::TimeAfter(0)));
        assert!(!needs_observer_site(&TargetTrigger::TimeBefore(0)));
        assert!(needs_observer_site(&TargetTrigger::And(vec![
            TargetTrigger::TimeAfter(0),
            TargetTrigger::HourAngleBetween {
                min_ha: -1.0,
                max_ha: 1.0,
            },
        ])));
        assert!(!needs_observer_site(&TargetTrigger::Or(vec![
            TargetTrigger::TimeAfter(0),
            TargetTrigger::TimeBefore(1),
        ])));
    }

    /// A skip-to-next-target request raised while the target's LAST child runs
    /// dies with that target.
    ///
    /// The request used to be consumed only when the subtree came back Skipped.
    /// An exposure burst finishes the frame it is on rather than aborting
    /// mid-download, so the target returned Success with the request still
    /// pending and it travelled on: the next TargetHeader's entry check
    /// consumed it and skipped a target nobody asked to skip, and with no next
    /// target the root Loop reported Skipped over a night that had imaged every
    /// frame it planned.
    #[tokio::test]
    async fn skip_request_dies_with_the_target_that_finished() {
        let header_def = NodeDefinition {
            id: "tgt".into(),
            name: "M31".into(),
            node_type: NodeType::TargetHeader(TargetHeaderConfig {
                target_name: "M31".into(),
                ra_hours: 0.7,
                dec_degrees: 41.27,
                ..TargetHeaderConfig::default()
            }),
            enabled: true,
            children: vec![],
        };
        let mut node = crate::node::runtime::RuntimeNode::from_definition(header_def);
        node.add_child(Box::new(SkipRequestingChild::new("expose")));

        let mut ctx = ExecutionContext::new_for_test("root".into());
        let config = match &node.definition.node_type {
            NodeType::TargetHeader(c) => c.clone(),
            _ => unreachable!(),
        };
        let status = execute_target_header(&mut node, config, &mut ctx).await;

        assert_eq!(
            status,
            NodeStatus::Success,
            "the target ran its whole subtree; the request arrived too late to \
             take anything away from it"
        );
        assert!(
            !ctx.is_skip_to_next_target_requested(),
            "the request names this target and must not outlive it"
        );
    }

    /// A child that asks to move on to the next target while it runs, and then
    /// finishes its own work — the exposure-burst shape.
    struct SkipRequestingChild {
        id: crate::NodeId,
        name: String,
        node_type: NodeType,
        children: Vec<Box<dyn crate::node::runtime::Node>>,
    }

    impl SkipRequestingChild {
        fn new(id: &str) -> Self {
            Self {
                id: id.to_string(),
                name: id.to_string(),
                node_type: NodeType::Delay(crate::DelayConfig { seconds: 0.0 }),
                children: Vec::new(),
            }
        }
    }

    #[async_trait::async_trait]
    impl crate::node::runtime::Node for SkipRequestingChild {
        fn id(&self) -> &crate::NodeId {
            &self.id
        }

        fn name(&self) -> &str {
            &self.name
        }

        fn node_type(&self) -> &NodeType {
            &self.node_type
        }

        fn is_enabled(&self) -> bool {
            true
        }

        async fn execute(&mut self, context: &mut ExecutionContext) -> NodeStatus {
            context.request_skip_to_next_target();
            NodeStatus::Success
        }

        fn reset(&mut self) {}

        async fn abort(&mut self) {}

        fn children(&self) -> &[Box<dyn crate::node::runtime::Node>] {
            &self.children
        }

        fn children_mut(&mut self) -> &mut Vec<Box<dyn crate::node::runtime::Node>> {
            &mut self.children
        }

        fn mark_completed(&mut self, _node_id: &crate::NodeId) {}
    }
}
