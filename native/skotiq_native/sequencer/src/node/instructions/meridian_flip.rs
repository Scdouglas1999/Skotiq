//! MeridianFlip instruction node.

use crate::instructions::execute_meridian_flip;
use crate::node::context::ExecutionContext;
use crate::node::progress::text_progress;
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct MeridianFlipInstruction;

#[async_trait]
impl InstructionNode for MeridianFlipInstruction {
    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::MeridianFlip(config) = node_type else {
            tracing::error!("MeridianFlipInstruction received non-MeridianFlip variant");
            return NodeStatus::Failure;
        };

        let ctx = context.to_instruction_context(node_id).await;

        let progress_fn = text_progress(context.progress_callback.as_ref(), node_id, "Meridian Flip");

        execute_meridian_flip(config, &ctx, Some(&progress_fn))
            .await
            .settle("Meridian Flip", &ctx)
            .await
    }
}
