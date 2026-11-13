//! Delay instruction node.

use crate::instructions::execute_delay;
use crate::node::context::ExecutionContext;
use crate::node::progress::text_progress;
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct DelayInstruction;

#[async_trait]
impl InstructionNode for DelayInstruction {
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

        let progress_fn = text_progress(context.progress_callback.as_ref(), node_id, "Delay");

        execute_delay(config, context, Some(&progress_fn))
            .await
            .settle("Delay", &ctx)
            .await
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
