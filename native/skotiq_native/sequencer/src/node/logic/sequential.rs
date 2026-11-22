//! Sequential child execution helper.
//!
//! Used by every container/logic node (TargetHeader, Loop, Conditional,
//! Recovery) for the "execute children in order" pass. Includes the
//! SkipToNode propagation logic.

use crate::node::context::ExecutionContext;
use crate::node::progress::ProgressUpdate;
use crate::node::runtime::RuntimeNode;
use crate::node::Node;
use crate::NodeStatus;

/// What a container checks at each of its child boundaries, on top of the
/// cancel, pause and next-target checks every walk makes.
#[async_trait::async_trait]
pub(crate) trait ChildBoundaries: Send {
    /// Before child `index` runs, after those checks and before the
    /// SkipToNode filter. `Some` ends the walk with that status.
    async fn before_child(
        &mut self,
        _node: &mut RuntimeNode,
        _context: &mut ExecutionContext,
        _index: usize,
        _total: usize,
    ) -> Option<NodeStatus> {
        None
    }

    /// After child `index` ran and neither failed nor was cancelled. `Some`
    /// ends the walk with that status.
    async fn after_child(
        &mut self,
        _node: &mut RuntimeNode,
        _context: &mut ExecutionContext,
        _index: usize,
        _total: usize,
    ) -> Option<NodeStatus> {
        None
    }
}

/// A container with nothing to check at its boundaries.
pub(crate) struct NoBoundaries;

impl ChildBoundaries for NoBoundaries {}

/// Execute the children of `node` sequentially.
///
/// Returns Cancelled / Skipped / Failure on the first child that produces
/// one (short-circuiting); returns Success only when every child finished
/// Success or Skipped. When a SkipToNode request is active, children whose
/// subtree does not contain the target are marked Skipped.
pub async fn execute_children_sequential(
    node: &mut RuntimeNode,
    context: &mut ExecutionContext,
) -> NodeStatus {
    if node.children.is_empty() {
        tracing::warn!("Node {} has no children to execute", node.id());
        return NodeStatus::Success;
    }
    walk_children(node, context, &mut NoBoundaries).await
}

/// The one child walker: cancel, pause, next-target request, the container's
/// own boundary checks, SkipToNode, the "Step i/n" progress and the child's
/// own status, child by child.
pub(crate) async fn walk_children(
    node: &mut RuntimeNode,
    context: &mut ExecutionContext,
    boundaries: &mut dyn ChildBoundaries,
) -> NodeStatus {
    let total = node.children.len();
    let node_id = node.id().clone();

    for i in 0..total {
        if context.is_cancelled().await {
            tracing::debug!("Execution cancelled before child {}", i);
            return NodeStatus::Cancelled;
        }
        // Honour an operator Pause / recovery freeze at the instruction
        // boundary: block here until resumed, and unwind if the sequence is
        // cancelled while paused. Without this the UI shows "Paused" while the
        // rig keeps slewing and exposing.
        if !context.wait_while_paused().await {
            tracing::debug!("Execution cancelled while paused before child {}", i);
            return NodeStatus::Cancelled;
        }
        if context.is_skip_to_next_target_requested() {
            tracing::info!(
                "Skipping remaining children in node {} due to next-target request",
                node_id
            );
            return NodeStatus::Skipped;
        }
        if let Some(status) = boundaries.before_child(node, context, i, total).await {
            return status;
        }

        let child = &mut node.children[i];
        // If a SkipToNode request is active, mark this child
        // as Skipped unless its subtree contains the target. When the child
        // IS the target (or contains it), the request stays pending so
        // deeper recursion can keep skipping siblings; we only clear it when
        // the executor reaches the target node itself.
        if let Some(ref target_id) = context.skip_to_node_target() {
            if child.id() == target_id {
                tracing::info!(
                    "[SKIP_TO_NODE] Reached target '{}'; clearing request and resuming normal execution",
                    target_id
                );
                context.clear_skip_to_node_request();
            } else if !child.contains_node(target_id) {
                tracing::info!(
                    "[SKIP_TO_NODE] Skipping child '{}' (id={}) — target '{}' is not in this subtree",
                    child.name(),
                    child.id(),
                    target_id
                );
                let mut update = ProgressUpdate::lifecycle(
                    child.id().clone(),
                    NodeStatus::Skipped,
                    format!("Skipped by SkipToNode request (target: {})", target_id),
                );
                update.current_child = Some(i);
                update.total_children = Some(total);
                context.send_progress(update);
                continue;
            }
            // The target is inside this child's subtree: the child runs and
            // its own walk keeps skipping until the target is reached.
        }

        tracing::info!(
            "Executing child {}/{}: '{}' (id={})",
            i + 1,
            total,
            child.name(),
            child.id()
        );

        let mut step_update = ProgressUpdate::lifecycle(
            node_id.clone(),
            NodeStatus::Running,
            format!("Step {}/{}: {}", i + 1, total, child.name()),
        );
        step_update.current_child = Some(i);
        step_update.total_children = Some(total);
        context.send_progress(step_update);

        let result = child.execute(context).await;

        tracing::info!(
            "Child '{}' completed with status: {:?}",
            child.name(),
            result
        );

        if result == NodeStatus::Skipped && context.is_skip_to_next_target_requested() {
            return NodeStatus::Skipped;
        }
        if result == NodeStatus::Failure || result == NodeStatus::Cancelled {
            return result;
        }
        if let Some(status) = boundaries.after_child(node, context, i, total).await {
            return status;
        }
    }

    NodeStatus::Success
}
