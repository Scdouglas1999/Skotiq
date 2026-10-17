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
    let total = node.children.len();
    let node_id = node.id().clone();

    tracing::debug!(
        "execute_children_sequential: node {} has {} children",
        node_id,
        total
    );

    if total == 0 {
        tracing::warn!("Node {} has no children to execute", node_id);
        return NodeStatus::Success;
    }

    tracing::info!("About to enter for loop with {} children", total);

    for (i, child) in node.children.iter_mut().enumerate() {
        tracing::info!("FOR LOOP ENTERED: iteration {} of {}", i, total);

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
                // Fall through to normal child.execute below.
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
            // else: the target is somewhere INSIDE this child's subtree, but
            // is not this child itself. Fall through to execute the child
            // normally — the recursive skip logic inside the child will keep
            // filtering siblings until the target is reached.
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
    }

    NodeStatus::Success
}

/// Cancellable wait until a target Unix timestamp.
pub async fn wait_until_timestamp_or_cancel(
    context: &ExecutionContext,
    target_timestamp: i64,
) -> NodeStatus {
    use std::sync::atomic::Ordering;
    loop {
        if context.is_cancelled.load(Ordering::Relaxed) {
            tracing::info!("Cancelled while waiting for scheduled start time");
            return NodeStatus::Cancelled;
        }
        if context.is_skip_to_next_target_requested() {
            tracing::info!("Skip requested while waiting for scheduled start time");
            return NodeStatus::Skipped;
        }

        let now = chrono::Utc::now().timestamp();
        if now >= target_timestamp {
            return NodeStatus::Success;
        }

        // `.min(1)` clamps to [_, 1] i64; the `now >= target_timestamp`
        // check above guarantees the difference is positive, so i64 -> u64 is
        // lossless. The clamp keeps the wait granular for cancellation polling.
        let sleep_secs = u64::try_from((target_timestamp - now).min(1)).unwrap_or(0);
        tokio::time::sleep(std::time::Duration::from_secs(sleep_secs.max(1))).await;
    }
}
