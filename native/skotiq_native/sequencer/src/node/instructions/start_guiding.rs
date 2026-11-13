//! StartGuiding instruction node.

use crate::instructions::execute_start_guiding;
use crate::node::context::ExecutionContext;
use crate::node::progress::step_progress;
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct StartGuidingInstruction;

#[async_trait]
impl InstructionNode for StartGuidingInstruction {
    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::StartGuiding(config) = node_type else {
            tracing::error!("StartGuidingInstruction received non-StartGuiding variant");
            return NodeStatus::Failure;
        };

        let ctx = context.to_instruction_context(node_id).await;

        let progress_fn = step_progress::<String>(context.progress_callback.as_ref(), node_id, "Start Guiding");

        execute_start_guiding(config, &ctx, Some(&progress_fn))
            .await
            .settle("Start Guiding", &ctx)
            .await
    }
}
