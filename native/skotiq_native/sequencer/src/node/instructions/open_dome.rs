//! OpenDome instruction node.

use crate::instructions::execute_open_dome;
use crate::node::context::ExecutionContext;
use crate::node::progress::step_progress;
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct OpenDomeInstruction;

#[async_trait]
impl InstructionNode for OpenDomeInstruction {
    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::OpenDome(config) = node_type else {
            tracing::error!("OpenDomeInstruction received non-OpenDome variant");
            return NodeStatus::Failure;
        };

        let ctx = context.to_instruction_context(node_id).await;
        let progress_fn =
            step_progress::<String>(context.progress_callback.as_ref(), node_id, "Open Dome");
        execute_open_dome(config, &ctx, Some(&progress_fn))
            .await
            .settle("Open Dome", &ctx)
            .await
    }
}
