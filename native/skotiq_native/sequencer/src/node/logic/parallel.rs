//! Parallel logic node.
//!
//! Each branch gets its context from a single `ctx.clone()` call. The clone
//! is cheap because every non-Copy field is wrapped in `Arc`, so cloning is a
//! refcount bump.

use crate::node::context::ExecutionContext;
use crate::node::progress::ProgressUpdate;
use crate::node::runtime::RuntimeNode;
use crate::node::Node;
use crate::{NodeDefinition, NodeStatus, NodeType, ParallelConfig};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use tokio::sync::Mutex as TokioMutex;

pub async fn execute_parallel(
    node: &mut RuntimeNode,
    config: ParallelConfig,
    context: &mut ExecutionContext,
) -> NodeStatus {
    let total_children = node.children.len();
    if total_children == 0 {
        return NodeStatus::Success;
    }

    // `required_successes: Option<u32>` — None means all children must succeed,
    // which matches the parallel-AND default.
    let required = config.required_successes.unwrap_or(total_children);
    let node_id = node.id().clone();

    let mut update = ProgressUpdate::lifecycle(
        node_id.clone(),
        NodeStatus::Running,
        format!("Running {} parallel branches", total_children),
    );
    update.current_child = Some(0);
    update.total_children = Some(total_children);
    context.send_progress(update);

    // /P2: honor an operator Pause / recovery freeze before launching the
    // parallel branches, matching sequential.rs (which gates `wait_while_paused`
    // at every child boundary). Without this gate a paused-then-executing
    // parallel node spawns its branch tasks regardless of the pause flag, so a
    // parallel subtree whose children are hardware instructions (slew, expose,
    // dome control) keeps driving the rig while the UI reports "Paused". Block
    // here until resumed; unwind (Cancelled) if the sequence is cancelled while
    // paused. This is the sole pause-enforcement seam for parallel — it adds the
    // missing gate without altering any W1-W5 decision/dispatch/enforcement math.
    if !context.wait_while_paused().await {
        tracing::debug!("Execution cancelled while paused before parallel branches");
        return NodeStatus::Cancelled;
    }

    let success_count = Arc::new(AtomicUsize::new(0));
    let cancelled = Arc::new(AtomicBool::new(false));

    // Children are owned by &mut node but the spawned tasks need 'static
    // lifetimes; wrapping each in Arc<Mutex<_>> lets them survive join_all
    // without cloning the underlying Node. They are unwrapped back into
    // node.children below after every task completes.
    let children = std::mem::take(&mut node.children);
    let children: Vec<Arc<TokioMutex<Box<dyn Node>>>> = children
        .into_iter()
        .map(|c| Arc::new(TokioMutex::new(c)))
        .collect();

    let handles: Vec<_> = children
        .iter()
        .enumerate()
        .map(|(i, child)| {
            let child = child.clone();
            let success_count = success_count.clone();
            let cancelled = cancelled.clone();
            // The callbacks are `Arc<dyn Fn>` rather than `Box<dyn Fn>`,
            // which is what lets `ExecutionContext` derive `Clone`: every
            // non-Copy field is Arc'd, so the whole context clones cheaply.
            let mut branch_context = context.clone();
            branch_context.node_id = format!("{}_branch_{}", node_id, i);
            // Spawned branches do not report progress to the parent's
            // callback. The other Arc'd shared-state fields stay populated so
            // the branch can still cancel, update trigger state, etc.
            branch_context.progress_callback = None;
            branch_context.polar_align_image_callback = None;

            let is_cancelled = context.is_cancelled.clone();

            tokio::spawn(async move {
                if is_cancelled.load(Ordering::Relaxed) || cancelled.load(Ordering::Relaxed) {
                    return (i, NodeStatus::Cancelled);
                }

                let mut child_guard = child.lock().await;
                let result = child_guard.execute(&mut branch_context).await;

                match result {
                    NodeStatus::Success => {
                        success_count.fetch_add(1, Ordering::Relaxed);
                    }
                    NodeStatus::Cancelled => {
                        cancelled.store(true, Ordering::Relaxed);
                    }
                    _ => {}
                }

                (i, result)
            })
        })
        .collect();

    let _results: Vec<_> = futures::future::join_all(handles)
        .await
        .into_iter()
        .filter_map(|r| r.ok())
        .collect();

    // Restore children from mutex wrappers. A try_unwrap failure means
    // another task is still holding a clone of the child Arc — the
    // parallel-execution invariant has been violated — so this returns
    // Failure rather than dropping the unrecovered child. Unrecovered
    // children are replaced with placeholder Failed nodes so subsequent walks
    // see a structurally valid tree (length and order preserved).
    let mut restored_children = Vec::with_capacity(children.len());
    let mut unrecovered = 0usize;
    for child_mutex in children {
        match Arc::try_unwrap(child_mutex) {
            Ok(mutex) => {
                restored_children.push(mutex.into_inner());
            }
            Err(_arc) => {
                tracing::error!(
                    "[NODE_TREE] Failed to reclaim child from parallel execution; a spawned task is still holding the Arc. \
                     This is a logical-impossibility violation — returning Failure so the user is told."
                );
                unrecovered += 1;
                let placeholder_def = NodeDefinition {
                    id: format!("__unrecovered_child_{}", unrecovered),
                    name: "Unrecovered parallel child".to_string(),
                    // Park is a no-op for the walker; the surrounding
                    // NodeStatus::Failure return is the actual signal to the caller.
                    node_type: NodeType::Park,
                    enabled: false,
                    children: Vec::new(),
                };
                let placeholder = RuntimeNode::from_definition(placeholder_def);
                restored_children.push(Box::new(placeholder));
            }
        }
    }
    node.children = restored_children;
    if unrecovered > 0 {
        return NodeStatus::Failure;
    }

    if context.is_cancelled.load(Ordering::Relaxed) || cancelled.load(Ordering::Relaxed) {
        return NodeStatus::Cancelled;
    }

    let successes = success_count.load(Ordering::Relaxed);

    let final_status = if successes >= required {
        NodeStatus::Success
    } else {
        NodeStatus::Failure
    };
    let mut final_update = ProgressUpdate::lifecycle(
        node_id.clone(),
        final_status,
        format!("{}/{} branches succeeded", successes, total_children),
    );
    final_update.current_child = Some(total_children);
    final_update.total_children = Some(total_children);
    context.send_progress(final_update);

    if successes >= required {
        NodeStatus::Success
    } else {
        tracing::warn!(
            "Parallel node: only {}/{} branches succeeded, required {}",
            successes,
            total_children,
            required
        );
        NodeStatus::Failure
    }
}

#[cfg(test)]
mod pause_gate_tests {
    use super::*;
    use crate::node::context::ExecutionContext;
    use crate::node::Node;
    use crate::{NodeId, NodeStatus, NodeType, ParallelConfig};
    use async_trait::async_trait;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::Duration;

    /// Leaf spy that records how many times `execute` was actually entered.
    /// Stands in for a hardware-instruction child (slew / expose / dome). If
    /// the parallel pause gate fails, the spawned branch task reaches this
    /// node and bumps the counter — exactly the "rig keeps moving while
    /// Paused" violation is about.
    struct ExecSpy {
        id: NodeId,
        node_type: NodeType,
        executed: Arc<AtomicUsize>,
        no_children: Vec<Box<dyn Node>>,
    }

    impl ExecSpy {
        fn new(id: &str, executed: Arc<AtomicUsize>) -> Self {
            Self {
                id: id.to_string(),
                // Park is an inert NodeType for the trait surface; the spy
                // overrides `execute` so the variant is never dispatched.
                node_type: NodeType::Park,
                executed,
                no_children: Vec::new(),
            }
        }
    }

    #[async_trait]
    impl Node for ExecSpy {
        fn id(&self) -> &NodeId {
            &self.id
        }
        fn name(&self) -> &str {
            "exec-spy"
        }
        fn node_type(&self) -> &NodeType {
            &self.node_type
        }
        fn is_enabled(&self) -> bool {
            true
        }
        async fn execute(&mut self, _context: &mut ExecutionContext) -> NodeStatus {
            self.executed.fetch_add(1, Ordering::SeqCst);
            NodeStatus::Success
        }
        fn reset(&mut self) {}
        async fn abort(&mut self) {}
        fn children(&self) -> &[Box<dyn Node>] {
            &self.no_children
        }
        fn children_mut(&mut self) -> &mut Vec<Box<dyn Node>> {
            &mut self.no_children
        }
        fn mark_completed(&mut self, _node_id: &NodeId) {}
    }

    fn parallel_node_with_spies(spies: Vec<ExecSpy>) -> RuntimeNode {
        let mut node = RuntimeNode::from_definition(crate::NodeDefinition {
            id: "par".to_string(),
            name: "par".to_string(),
            node_type: NodeType::Parallel(ParallelConfig {
                required_successes: None,
            }),
            enabled: true,
            children: Vec::new(),
        });
        for spy in spies {
            node.children.push(Box::new(spy));
        }
        node
    }

    /// with the pause flag already set on entry, `execute_parallel` must
    /// block on `wait_while_paused`; cancelling while paused must unwind to
    /// Cancelled and NO branch may have executed (no exposure / slew). Without
    /// the gate, the branches spawn and run regardless of the pause flag.
    #[tokio::test]
    async fn paused_parallel_does_not_spawn_branches_and_cancels() {
        let executed = Arc::new(AtomicUsize::new(0));
        let spy_a = ExecSpy::new("a", executed.clone());
        let spy_b = ExecSpy::new("b", executed.clone());
        let mut node = parallel_node_with_spies(vec![spy_a, spy_b]);

        let mut ctx = ExecutionContext::new_for_test("par".to_string());
        // Operator Pause is active before the node runs.
        ctx.is_paused.store(true, Ordering::Relaxed);

        let is_cancelled = ctx.is_cancelled.clone();
        let resume_notify = ctx.resume_notify.clone();

        // Operator never resumes — instead the sequence is cancelled while
        // paused (e.g. they hit Stop). The gate must observe is_cancelled and
        // return Cancelled.
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(150)).await;
            is_cancelled.store(true, Ordering::Relaxed);
            resume_notify.notify_waiters();
        });

        let cfg = ParallelConfig {
            required_successes: None,
        };
        let status = execute_parallel(&mut node, cfg, &mut ctx).await;

        assert_eq!(
            status,
            NodeStatus::Cancelled,
            "cancel-while-paused before parallel branches must unwind to Cancelled"
        );
        assert_eq!(
            executed.load(Ordering::SeqCst),
            0,
            "no parallel branch may execute while the node is paused (rig must stay frozen)"
        );
    }

    /// Guard the happy path: with NO pause active, the gate is a no-op and
    /// every branch runs.
    #[tokio::test]
    async fn unpaused_parallel_runs_all_branches() {
        let executed = Arc::new(AtomicUsize::new(0));
        let spy_a = ExecSpy::new("a", executed.clone());
        let spy_b = ExecSpy::new("b", executed.clone());
        let mut node = parallel_node_with_spies(vec![spy_a, spy_b]);

        let mut ctx = ExecutionContext::new_for_test("par".to_string());
        let cfg = ParallelConfig {
            required_successes: None,
        };
        let status = execute_parallel(&mut node, cfg, &mut ctx).await;

        assert_eq!(status, NodeStatus::Success);
        assert_eq!(
            executed.load(Ordering::SeqCst),
            2,
            "both branches must run when not paused"
        );
    }
}
