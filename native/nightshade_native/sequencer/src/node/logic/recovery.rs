//! Recovery logic node.
//!
//! Retries child nodes with exponential backoff (1s, 2s, 4s, 8s, ..., capped
//! at 64 s) up to `max_retries` times. After exhausting retries, the
//! configured recovery action determines the final outcome.

use crate::executor::ExecutorEvent;
use crate::instructions::{
    autofocus_failure_continues_the_run, execute_autofocus, notify_autofocus_failed_continuing,
    read_autofocus_position,
};
use crate::node::context::ExecutionContext;
use crate::node::instructions::autofocus::parse_autofocus_detail;
use crate::node::logic::sequential::execute_children_sequential;
use crate::node::progress::{ProgressDetail, ProgressUpdate};
use crate::node::runtime::{Node, RuntimeNode};
use crate::{NodeStatus, NodeType, RecoveryAction, RecoveryConfig};
use std::sync::atomic::Ordering;

pub(crate) async fn execute_custom_branch_children(
    node: &mut RuntimeNode,
    context: &mut ExecutionContext,
) -> NodeStatus {
    if node.children.is_empty() {
        let message = format!(
            "CustomBranch recovery node '{}' has no child nodes to execute",
            node.name()
        );
        tracing::error!("{}", message);
        if let Some(tx) = &context.event_tx {
            let _ = tx.send(ExecutorEvent::Error { message });
        }
        return NodeStatus::Failure;
    }

    for child in &mut node.children {
        child.reset();
    }

    tracing::info!(
        "Executing CustomBranch recovery subtree '{}' ({} child nodes)",
        node.name(),
        node.children.len()
    );
    execute_children_sequential(node, context).await
}

pub async fn execute_recovery(
    node: &mut RuntimeNode,
    config: RecoveryConfig,
    context: &mut ExecutionContext,
) -> NodeStatus {
    let mut attempts = 0;
    let max_attempts = config.max_retries.saturating_add(1);

    loop {
        attempts += 1;
        tracing::info!("Execution attempt {}/{}", attempts, max_attempts);

        // Each retry needs a fresh slate — stale Success/Failure on children
        // would let a flaky middle child short-circuit on the second attempt
        // before its real cause was actually retried.
        for child in &mut node.children {
            child.reset();
        }

        let result = execute_children_sequential(node, context).await;

        if result == NodeStatus::Success || result == NodeStatus::Cancelled {
            return result;
        }

        if attempts >= max_attempts {
            tracing::warn!(
                "Max recovery attempts ({}) reached, propagating failure",
                max_attempts
            );
            return match config.recovery_action {
                RecoveryAction::Continue => NodeStatus::Success,
                RecoveryAction::NextTarget => NodeStatus::Skipped,
                RecoveryAction::CustomBranch => execute_custom_branch_children(node, context).await,
                RecoveryAction::ParkAndAbort => {
                    // Both ParkAndAbort recovery paths
                    // (here and in executor.rs) route through
                    // `device_ops::try_park_with_retry` so park behaviour is
                    // consistent.
                    if let Some(mount_id) = &context.mount_id {
                        tracing::warn!(
                            "Recovery::ParkAndAbort: parking mount '{}' (max_retries=1, retry_delay=2s)",
                            mount_id
                        );
                        let park_outcome = crate::device_ops::try_park_with_retry(
                            &context.device_ops,
                            mount_id,
                            1,
                            2.0,
                        )
                        .await;
                        if !park_outcome.success {
                            let park_error = format!(
                                "Recovery::ParkAndAbort: mount park FAILED after {} attempt{}: {}. \
                                 Mount may be in an unsafe position — manual intervention required.",
                                park_outcome.attempts_made,
                                if park_outcome.attempts_made == 1 { "" } else { "s" },
                                park_outcome
                                    .last_error
                                    .clone()
                                    .unwrap_or_else(|| "unknown error".to_string()),
                            );
                            tracing::error!("{}", park_error);
                            if let Some(tx) = &context.event_tx {
                                let _ = tx.send(ExecutorEvent::Error {
                                    message: park_error,
                                });
                            }
                        }
                    } else {
                        tracing::error!(
                            "Recovery::ParkAndAbort fired but no mount is configured; the rig cannot be parked automatically."
                        );
                        if let Some(tx) = &context.event_tx {
                            let _ = tx.send(ExecutorEvent::Error {
                                message: "Recovery::ParkAndAbort fired but no mount is configured; the rig cannot be parked automatically.".to_string(),
                            });
                        }
                    }
                    NodeStatus::Failure
                }
                _ => NodeStatus::Failure,
            };
        }

        // Exponential backoff (1, 2, 4, 8, …, 64 s) gives transient device
        // faults a chance to clear while capping the wait so the user is not
        // staring at a frozen sequence. `attempts - 1` because attempts is
        // 1-based and the first retry should wait the minimum 1 s.
        let backoff_secs = 1u64 << (attempts - 1).min(6);
        tracing::info!(
            "Waiting {}s before retry attempt {}/{}",
            backoff_secs,
            attempts + 1,
            max_attempts
        );

        // The backoff sleep must remain cancellable — a 64 s wait that
        // ignores Stop would leave the user staring at a "stopping…" UI.
        tokio::select! {
            _ = tokio::time::sleep(std::time::Duration::from_secs(backoff_secs)) => {}
            _ = async {
                loop {
                    if context.is_cancelled.load(Ordering::Relaxed) {
                        return;
                    }
                    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                }
            } => {
                tracing::info!("Recovery cancelled during backoff wait");
                return NodeStatus::Cancelled;
            }
        }

        match &config.recovery_action {
            RecoveryAction::Retry { .. } => {
                tracing::info!("Retrying...");
            }
            RecoveryAction::Autofocus => {
                let autofocus_config = match configured_recovery_autofocus(node) {
                    Some(config) => config,
                    None => {
                        tracing::error!(
                            "Recovery action requested autofocus but no enabled autofocus child is configured"
                        );
                        return NodeStatus::Failure;
                    }
                };
                tracing::info!("Running recovery autofocus...");
                let ctx = context.to_instruction_context(node.id()).await;
                let progress_cb = context.progress_callback.clone();
                let progress_node_id = node.id().clone();
                let total_steps = autofocus_config
                    .steps_out
                    .saturating_mul(2)
                    .saturating_add(1);
                let progress_fn = move |progress: f64, detail_str: String| {
                    if let Some(cb) = progress_cb.as_ref() {
                        let (step, hfr) = parse_autofocus_detail(&detail_str);
                        cb(ProgressUpdate::instruction_progress(
                            progress_node_id.clone(),
                            "Autofocus",
                            progress,
                            ProgressDetail::Autofocus {
                                step: step.unwrap_or(0),
                                total_steps,
                                current_hfr: hfr,
                            },
                        ));
                    }
                };
                let position_before = read_autofocus_position(&ctx).await;
                let autofocus_result =
                    execute_autofocus(&autofocus_config, &ctx, Some(&progress_fn)).await;
                match autofocus_result.status {
                    NodeStatus::Success => {}
                    NodeStatus::Cancelled => return NodeStatus::Cancelled,
                    // A refocus that did not converge is reported and the
                    // retry goes ahead on the previous focus: a failed
                    // autofocus never decides the run (owner decision
                    // 2026-10-06).
                    _ if autofocus_failure_continues_the_run(&autofocus_result) => {
                        notify_autofocus_failed_continuing(
                            &ctx,
                            "Recovery autofocus",
                            &autofocus_result,
                            position_before,
                        )
                        .await;
                    }
                    _ => return autofocus_result.log_and_get_status("Recovery autofocus"),
                }
            }
            RecoveryAction::Pause => {
                tracing::info!("Pausing for manual intervention...");
                if !context.pause_and_wait_for_resume().await {
                    return NodeStatus::Cancelled;
                }
                tracing::info!("Resumed after pause, retrying...");
            }
            _ => {}
        }
    }
}

/// Look for an enabled Autofocus child inside this recovery node so
/// `RecoveryAction::Autofocus` knows what config to run.
pub(crate) fn configured_recovery_autofocus(node: &RuntimeNode) -> Option<crate::AutofocusConfig> {
    node.children.iter().find_map(|child| {
        if !child.is_enabled() {
            return None;
        }
        match child.node_type() {
            NodeType::Autofocus(config) => Some(config.clone()),
            _ => None,
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use async_trait::async_trait;
    use std::sync::atomic::AtomicUsize;
    use std::sync::Arc;

    struct FailingChild {
        id: crate::NodeId,
        node_type: NodeType,
        executions: Arc<AtomicUsize>,
        children: Vec<Box<dyn Node>>,
    }

    #[async_trait]
    impl Node for FailingChild {
        fn id(&self) -> &crate::NodeId {
            &self.id
        }

        fn name(&self) -> &str {
            "failing-child"
        }

        fn node_type(&self) -> &NodeType {
            &self.node_type
        }

        fn is_enabled(&self) -> bool {
            true
        }

        async fn execute(&mut self, _context: &mut ExecutionContext) -> NodeStatus {
            self.executions.fetch_add(1, Ordering::SeqCst);
            NodeStatus::Failure
        }

        fn reset(&mut self) {}

        async fn abort(&mut self) {}

        fn children(&self) -> &[Box<dyn Node>] {
            &self.children
        }

        fn children_mut(&mut self) -> &mut Vec<Box<dyn Node>> {
            &mut self.children
        }

        fn mark_completed(&mut self, _node_id: &crate::NodeId) {}
    }

    #[tokio::test(start_paused = true)]
    async fn max_retries_counts_retries_after_initial_attempt() {
        for max_retries in [0, 1, 3] {
            let executions = Arc::new(AtomicUsize::new(0));
            let mut node = RuntimeNode::from_definition(crate::NodeDefinition {
                id: format!("recovery-{max_retries}"),
                name: "Recovery".to_string(),
                node_type: NodeType::Recovery(RecoveryConfig {
                    trigger: None,
                    recovery_action: RecoveryAction::Retry {
                        max_attempts: max_retries,
                    },
                    max_retries,
                }),
                enabled: true,
                children: Vec::new(),
            });
            node.add_child(Box::new(FailingChild {
                id: format!("failure-{max_retries}"),
                node_type: NodeType::Park,
                executions: executions.clone(),
                children: Vec::new(),
            }));
            let mut context = ExecutionContext::new_for_test(node.id().clone());

            let status = execute_recovery(
                &mut node,
                RecoveryConfig {
                    trigger: None,
                    recovery_action: RecoveryAction::Retry {
                        max_attempts: max_retries,
                    },
                    max_retries,
                },
                &mut context,
            )
            .await;

            assert_eq!(status, NodeStatus::Failure);
            assert_eq!(
                executions.load(Ordering::SeqCst),
                (max_retries + 1) as usize,
                "max_retries={max_retries} must allow the initial execution plus that many retries"
            );
        }
    }
}
