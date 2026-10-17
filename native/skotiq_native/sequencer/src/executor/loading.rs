//! Sequence loading and totals-rollup surface on the [`SequenceExecutor`].
//!
//! Two responsibilities live here, and they are siblings rather than the
//! same axis:
//!
//!   1. [`SequenceExecutor::load_sequence`] — public entry point that
//!      validates a [`SequenceDefinition`], builds the runtime node tree
//!      from it, computes the integration / exposure totals, and parks
//!      both on the executor. The bridge calls this once per sequence
//!      authoring round-trip; the executor then waits for `start()`.
//!   2. Pure read-only tree walks ([`SequenceExecutor::calculate_totals`]
//!      and [`SequenceExecutor::build_execution_order`]) used by load
//!      and by the checkpoint surface respectively. They are kept here
//!      because they share the `node_map` indexing pattern and the
//!      cycle-guard recursion idiom — moving one without the other
//!      would scatter the same walker across two files.
//!
//! Why `build_node_tree` lives here despite being called from `start()`:
//! it is the inverse of the totals walks (build the tree, then sum it
//! up), and `start()` already enforces "no sequence loaded" → error
//! before reaching any tree-walking code. Co-locating them keeps the
//! "what does a freshly-loaded executor know about its sequence" answer
//! in one place.
//!
//! What is deliberately NOT here:
//!   * `prepare_sequence_recovery_triggers` — that is a `start()`
//!     orchestration step (registers triggers on the live trigger
//!     manager) rather than a pure tree walk; it lives in `mod.rs`
//!     next to the orchestrator.
//!   * The recursive node builder (`build_runtime_node_from_map`) —
//!     that is a free helper kept in `mod.rs` because the inline
//!     `start()` closures share the helper namespace.
//!
//! Visibility: `build_execution_order` is `pub(super)` so the
//! checkpoint surface in `super::checkpoint` can call it without
//! widening the public API.

use super::{build_runtime_node_from_map, SequenceExecutor};
use crate::node::Node;
use crate::{NodeDefinition, NodeId, NodeType, SequenceDefinition};
use std::collections::HashMap;

impl SequenceExecutor {
    /// Load a sequence definition, build the runtime node tree, and
    /// seed the progress totals.
    ///
    /// Failure modes:
    ///   * `Err("No root node specified")` — the sequence has no
    ///     `root_node_id`. The bridge UI prevents this at authoring
    ///     time; we still hard-fail here so a hand-rolled JSON
    ///     sequence with the field missing is rejected loudly instead
    ///     of producing a silently-empty executor.
    ///   * `Err("Root node X not found")` — `root_node_id` references a
    ///     node id not present in the `nodes` Vec. Same loud-failure
    ///     reasoning.
    ///
    /// Side effects: writes `self.sequence`, `self.root_node`, and the
    /// `progress.total_*` slots. Indeterminate totals (unbounded
    /// loops, integration-budget cap engaged) zero out the totals and
    /// clear the ETA so the dashboard renders "?" instead of a
    /// misleading finite number.
    pub fn load_sequence(&mut self, sequence: SequenceDefinition) -> Result<(), String> {
        let root_node = self.build_node_tree(&sequence)?;

        let (total_exposures, total_integration, totals_indeterminate) =
            self.calculate_totals(&sequence);

        {
            let mut progress = self.progress.write();
            if totals_indeterminate {
                // Unbounded loops (while-dark/forever/etc.) don't have a meaningful finite ETA.
                progress.total_exposures = 0;
                progress.total_integration_secs = 0.0;
                progress.estimated_remaining_secs = None;
            } else {
                progress.total_exposures = total_exposures;
                progress.total_integration_secs = total_integration;
            }
        }

        self.sequence = Some(sequence);
        self.root_node = Some(root_node);

        Ok(())
    }

    /// Build the runtime node tree from a sequence definition.
    ///
    /// Private — `load_sequence` is the only documented entry point;
    /// constructing a tree without simultaneously updating
    /// `self.sequence` would leave the executor in a torn state.
    fn build_node_tree(&self, sequence: &SequenceDefinition) -> Result<Box<dyn Node>, String> {
        let node_map: HashMap<&str, &NodeDefinition> =
            sequence.nodes.iter().map(|n| (n.id.as_str(), n)).collect();

        let root_id = sequence
            .root_node_id
            .as_ref()
            .ok_or("No root node specified")?;

        let root_def = node_map
            .get(root_id.as_str())
            .ok_or_else(|| format!("Root node {} not found", root_id))?;

        Ok(Box::new(build_runtime_node_from_map(root_def, &node_map)))
    }

    /// Compute `(total_exposures, total_integration_secs, indeterminate)`
    /// for the supplied sequence by walking the node tree.
    ///
    /// `indeterminate = true` when:
    ///   * a cycle is detected in the node graph,
    ///   * a `Loop` with a non-`Count` condition (`while-dark`,
    ///     `forever`, …) is encountered,
    ///   * a `SmartExposure` node has an integration-budget cap that
    ///     trims the un-capped plan total,
    ///   * the un-capped exposure total exceeds `u32::MAX` and was
    ///     clamped.
    ///
    /// Indeterminate sequences are surfaced to the UI as "?" rather
    /// than a misleading finite number — see `load_sequence` for the
    /// progress-bar handling.
    ///
    /// `pub(crate)` would be enough for the load + tests, but the
    /// existing inherent visibility (private to the impl block) is
    /// kept — the tests in `mod.rs` reach into it via `SequenceExecutor`
    /// in the same crate.
    pub(super) fn calculate_totals(&self, sequence: &SequenceDefinition) -> (u32, f64, bool) {
        let root_id = match &sequence.root_node_id {
            Some(id) => id,
            None => return (0, 0.0, false),
        };

        let node_map: HashMap<&str, &NodeDefinition> =
            sequence.nodes.iter().map(|n| (n.id.as_str(), n)).collect();

        let mut total_exposures = 0u64;
        let mut total_integration = 0.0f64;
        let mut totals_indeterminate = false;
        let mut recursion_guard = std::collections::HashSet::new();

        fn walk(
            node_id: &str,
            multiplier: u64,
            node_map: &HashMap<&str, &NodeDefinition>,
            total_exposures: &mut u64,
            total_integration: &mut f64,
            totals_indeterminate: &mut bool,
            recursion_guard: &mut std::collections::HashSet<String>,
        ) {
            if multiplier == 0 {
                return;
            }

            if !recursion_guard.insert(node_id.to_string()) {
                tracing::warn!(
                    "Detected cycle while calculating sequence totals at node '{}'; marking totals indeterminate",
                    node_id
                );
                *totals_indeterminate = true;
                return;
            }

            let node = match node_map.get(node_id) {
                Some(node) => *node,
                None => {
                    *totals_indeterminate = true;
                    recursion_guard.remove(node_id);
                    return;
                }
            };

            if !node.enabled {
                recursion_guard.remove(node_id);
                return;
            }

            match &node.node_type {
                NodeType::TakeExposure(config) => {
                    // Why: `config.count` is u32; widening u32 -> u64 is lossless.
                    let count = u64::from(config.count);
                    *total_exposures =
                        total_exposures.saturating_add(count.saturating_mul(multiplier));
                    // Why: u64 -> f64 only loses precision above 2^53 (~9 PB of exposures);
                    // the saturating-add guarantees `count` and `multiplier` are bounded by
                    // u32::MAX worth of tree nodes, so loss is impossible here.
                    *total_integration += config.duration_secs * count as f64 * multiplier as f64;
                }
                // SmartExposure is a leaf that internally
                // dispatches per-filter TakeExposure batches. The walk() does
                // NOT recurse into the SmartExposure plans at runtime (the
                // node has no `children`), so we must count plan frames here
                // or the dashboard's "X of Y exposures" indicator stays at 0
                // for any sequence whose imaging plan is authored through
                // SmartExposure instead of hand-rolled FilterChange + Loop +
                // TakeExposure.
                //
                // When `integration_budget_secs > 0` and the un-capped sum of
                // plan-integration exceeds the cap, the runtime will return
                // Success before every plan completes — so the dashboard's
                // totals must reflect the same ceiling. We cap the
                // integration estimate and flag `totals_indeterminate` so the
                // UI can render "approximately" for the exposure count
                // (because rotation order + per-plan duration determine
                // which frames make it under the cap).
                NodeType::SmartExposure(config) => {
                    let mut plan_total_count: u64 = 0;
                    let mut plan_total_secs: f64 = 0.0;
                    for plan in &config.plans {
                        // Why: u32 -> u64 widens losslessly; saturating ops
                        // mirror the TakeExposure branch above.
                        let plan_count = u64::from(plan.count);
                        plan_total_count = plan_total_count.saturating_add(plan_count);
                        plan_total_secs += plan.duration_secs * plan_count as f64;
                    }
                    let budget_engaged = config.integration_budget_secs > 0.0
                        && plan_total_secs > config.integration_budget_secs;
                    let effective_secs = if budget_engaged {
                        config.integration_budget_secs
                    } else {
                        plan_total_secs
                    };
                    let frames_total = plan_total_count.saturating_mul(multiplier);
                    *total_exposures = total_exposures.saturating_add(frames_total);
                    *total_integration += effective_secs * multiplier as f64;
                    if budget_engaged {
                        *totals_indeterminate = true;
                    }
                }
                NodeType::Loop(config) => {
                    let child_multiplier = match config.condition {
                        crate::LoopCondition::Count => {
                            // Why: `config.iterations` is Option<u32>;
                            // `LoopCondition::Count` REQUIRES iterations to be Some at
                            // construction time (enforced by `node.rs:1697` and the UI), so
                            // None is unreachable. `1` ensures the totals-rollup is at least
                            // self-consistent if a future refactor breaks the invariant.
                            // Why: u32 -> u64 widening on Option<u32> default is lossless.
                            multiplier.saturating_mul(u64::from(config.iterations.unwrap_or(1)))
                        }
                        _ => {
                            *totals_indeterminate = true;
                            multiplier
                        }
                    };

                    for child_id in &node.children {
                        walk(
                            child_id,
                            child_multiplier,
                            node_map,
                            total_exposures,
                            total_integration,
                            totals_indeterminate,
                            recursion_guard,
                        );
                    }

                    recursion_guard.remove(node_id);
                    return;
                }
                _ => {}
            }

            for child_id in &node.children {
                walk(
                    child_id,
                    multiplier,
                    node_map,
                    total_exposures,
                    total_integration,
                    totals_indeterminate,
                    recursion_guard,
                );
            }

            recursion_guard.remove(node_id);
        }

        walk(
            root_id,
            1,
            &node_map,
            &mut total_exposures,
            &mut total_integration,
            &mut totals_indeterminate,
            &mut recursion_guard,
        );

        let capped_total_exposures = match u32::try_from(total_exposures) {
            Ok(n) => n,
            Err(_) => {
                // Why: TryFrom failure means total > u32::MAX; surface to UI as
                // indeterminate rather than silently truncating with `as`.
                tracing::warn!(
                    "Total exposure count {} exceeds u32::MAX; clamping totals",
                    total_exposures
                );
                totals_indeterminate = true;
                u32::MAX
            }
        };

        (
            capped_total_exposures,
            total_integration,
            totals_indeterminate,
        )
    }

    /// Compute a depth-first execution-order index for every node in
    /// the sequence.
    ///
    /// The map is `node_id -> tree-walk index`, where the index
    /// monotonically increases with the order the executor would visit
    /// each node during a fresh run. The checkpoint surface uses this
    /// to find the "last completed" node by tree-walk order rather
    /// than lexical `NodeId` ordering — the latter would falsely pick
    /// an earlier node whose id happens to sort after a later one
    /// (NodeIds are user-set strings).
    ///
    /// `pub(super)` because the checkpoint module is the only legit
    /// caller; opening this further would invite an alternative
    /// "what's the last node" computation that drifts from the
    /// canonical implementation here.
    pub(super) fn build_execution_order(
        &self,
        sequence: &SequenceDefinition,
    ) -> HashMap<NodeId, usize> {
        let mut order = HashMap::new();
        let mut index = 0usize;
        let node_map: HashMap<&str, &NodeDefinition> =
            sequence.nodes.iter().map(|n| (n.id.as_str(), n)).collect();
        let mut recursion_guard = std::collections::HashSet::new();

        fn walk(
            node_id: &str,
            node_map: &HashMap<&str, &NodeDefinition>,
            order: &mut HashMap<NodeId, usize>,
            index: &mut usize,
            recursion_guard: &mut std::collections::HashSet<String>,
        ) {
            if !recursion_guard.insert(node_id.to_string()) {
                tracing::warn!(
                    "Detected cycle while computing execution order at node '{}'",
                    node_id
                );
                return;
            }

            if let Some(node) = node_map.get(node_id) {
                order.insert(node.id.clone(), *index);
                *index = index.saturating_add(1);
                for child_id in &node.children {
                    walk(child_id, node_map, order, index, recursion_guard);
                }
            }

            recursion_guard.remove(node_id);
        }

        if let Some(root_id) = &sequence.root_node_id {
            walk(
                root_id,
                &node_map,
                &mut order,
                &mut index,
                &mut recursion_guard,
            );
        }

        order
    }
}
