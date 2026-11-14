//! ParkDome instruction node.

use crate::instructions::execute_park_dome;
use crate::node::context::ExecutionContext;
use crate::node::progress::step_progress;
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct ParkDomeInstruction;

#[async_trait]
impl InstructionNode for ParkDomeInstruction {
    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::ParkDome(config) = node_type else {
            tracing::error!("ParkDomeInstruction received non-ParkDome variant");
            return NodeStatus::Failure;
        };

        let ctx = context.to_instruction_context(node_id).await;
        let progress_fn =
            step_progress::<String>(context.progress_callback.as_ref(), node_id, "Park Dome");
        execute_park_dome(config, &ctx, Some(&progress_fn))
            .await
            .settle("Park Dome", &ctx)
            .await
    }
}
