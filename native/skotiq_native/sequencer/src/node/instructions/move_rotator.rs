//! MoveRotator instruction node.

use crate::instructions::execute_rotator_move;
use crate::node::context::ExecutionContext;
use crate::node::progress::step_progress;
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct MoveRotatorInstruction;

#[async_trait]
impl InstructionNode for MoveRotatorInstruction {
    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::MoveRotator(config) = node_type else {
            tracing::error!("MoveRotatorInstruction received non-MoveRotator variant");
            return NodeStatus::Failure;
        };

        let ctx = context.to_instruction_context(node_id).await;

        let progress_fn = step_progress::<String>(context.progress_callback.as_ref(), node_id, "Move Rotator");

        execute_rotator_move(config, &ctx, Some(&progress_fn))
            .await
            .settle("Move Rotator", &ctx)
            .await
    }
}
