//! WaitForTime instruction node.

use crate::instructions::execute_wait_time;
use crate::node::context::ExecutionContext;
use crate::node::progress::step_progress;
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct WaitForTimeInstruction;

#[async_trait]
impl InstructionNode for WaitForTimeInstruction {
    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::WaitForTime(config) = node_type else {
            tracing::error!("WaitForTimeInstruction received non-WaitForTime variant");
            return NodeStatus::Failure;
        };

        let ctx = context.to_instruction_context(node_id).await;

        let progress_fn = step_progress::<String>(context.progress_callback.as_ref(), node_id, "Wait");

        execute_wait_time(config, &ctx, Some(&progress_fn))
            .await
            .settle("Wait For Time", &ctx)
            .await
    }
}
