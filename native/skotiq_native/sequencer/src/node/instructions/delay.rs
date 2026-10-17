//! Delay instruction node.

use crate::instructions::execute_delay;
use crate::node::context::ExecutionContext;
use crate::node::progress::{ProgressDetail, ProgressUpdate};
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct DelayInstruction;

#[async_trait]
impl InstructionNode for DelayInstruction {
    fn type_name(&self) -> &'static str {
        "Delay"
    }

    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::Delay(config) = node_type else {
            tracing::error!("DelayInstruction received non-Delay variant");
            return NodeStatus::Failure;
        };

        let ctx = context.to_instruction_context(node_id).await;
        let progress_cb = context.progress_callback.as_ref();
        let total_secs = config.seconds;

        let progress_fn = |progress: f64, _detail: String| {
            if let Some(cb) = progress_cb {
                // Delay reports progress as a fraction of total elapsed; we
                // turn that into structured `remaining_secs` without parsing.
                let remaining = (total_secs * (1.0 - progress / 100.0)).max(0.0);
                cb(ProgressUpdate::instruction_progress(
                    node_id.to_string(),
                    "Delay",
                    progress,
                    ProgressDetail::Wait {
                        remaining_secs: remaining,
                    },
                ));
            }
        };

        execute_delay(config, context, Some(&progress_fn))
            .await
            .log_and_get_status_with_context("Delay", &ctx)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::node::context::ExecutionContext;
    use std::sync::atomic::Ordering;
    use std::time::Duration;

    #[tokio::test]
    async fn pause_does_not_consume_delay_time() {
        let context = ExecutionContext::new_for_test("delay-test".to_string());
        let paused = context.is_paused.clone();
        let resume_context = context.clone();
        let task = tokio::spawn(async move {
            execute_delay(&crate::DelayConfig { seconds: 0.5 }, &context, None).await
        });

        tokio::time::sleep(Duration::from_millis(150)).await;
        paused.store(true, Ordering::Relaxed);
        tokio::time::sleep(Duration::from_millis(600)).await;
        assert!(
            !task.is_finished(),
            "a paused delay must not complete on the original wall clock"
        );

        resume_context.resume();
        let result = tokio::time::timeout(Duration::from_secs(2), task)
            .await
            .expect("resumed delay should complete")
            .expect("delay task should not panic");
        assert_eq!(result.status, NodeStatus::Success);
    }
}
