//! CloseDome instruction node.

use crate::instructions::execute_close_dome;
use crate::node::context::ExecutionContext;
use crate::node::progress::step_progress;
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct CloseDomeInstruction;

#[async_trait]
impl InstructionNode for CloseDomeInstruction {
    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::CloseDome(config) = node_type else {
            tracing::error!("CloseDomeInstruction received non-CloseDome variant");
            return NodeStatus::Failure;
        };

        let ctx = context.to_instruction_context(node_id).await;
        let progress_fn =
            step_progress::<String>(context.progress_callback.as_ref(), node_id, "Close Dome");
        execute_close_dome(config, &ctx, Some(&progress_fn))
            .await
            .settle("Close Dome", &ctx)
            .await
    }
}
