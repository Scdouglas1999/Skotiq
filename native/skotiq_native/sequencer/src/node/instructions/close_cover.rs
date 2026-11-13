//! CloseCover instruction node.

use crate::instructions::execute_close_cover;
use crate::node::context::ExecutionContext;
use crate::node::progress::text_progress;
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct CloseCoverInstruction;

#[async_trait]
impl InstructionNode for CloseCoverInstruction {
    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::CloseCover(config) = node_type else {
            tracing::error!("CloseCoverInstruction received non-CloseCover variant");
            return NodeStatus::Failure;
        };
        let ctx = context.to_instruction_context(node_id).await;
        let progress_fn = text_progress(context.progress_callback.as_ref(), node_id, "Close Cover");
        execute_close_cover(config, &ctx, Some(&progress_fn))
            .await
            .settle("Close Cover", &ctx)
            .await
    }
}
