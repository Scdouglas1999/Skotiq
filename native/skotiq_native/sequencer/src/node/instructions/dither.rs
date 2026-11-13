//! Dither instruction node.

use crate::instructions::execute_dither;
use crate::node::context::ExecutionContext;
use crate::node::progress::step_progress;
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct DitherInstruction;

#[async_trait]
impl InstructionNode for DitherInstruction {
    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::Dither(config) = node_type else {
            tracing::error!("DitherInstruction received non-Dither variant");
            return NodeStatus::Failure;
        };

        let ctx = context.to_instruction_context(node_id).await;

        let progress_fn = step_progress::<String>(context.progress_callback.as_ref(), node_id, "Dither");

        let result = execute_dither(config, &ctx, Some(&progress_fn)).await;
        result.settle("Dither", &ctx).await
    }
}
