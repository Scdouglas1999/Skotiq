//! SlewToTarget instruction node.

use crate::instructions::execute_slew;
use crate::node::context::ExecutionContext;
use crate::node::progress::text_progress;
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct SlewInstruction;

#[async_trait]
impl InstructionNode for SlewInstruction {
    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::SlewToTarget(config) = node_type else {
            tracing::error!("SlewInstruction received non-SlewToTarget variant");
            return NodeStatus::Failure;
        };

        let ctx = context.to_instruction_context(node_id).await;

        let progress_fn = text_progress(context.progress_callback.as_ref(), node_id, "Slew");

        execute_slew(config, &ctx, Some(&progress_fn))
            .await
            .settle("Slew", &ctx)
            .await
    }
}
