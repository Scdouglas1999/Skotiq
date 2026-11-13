//! OpenCover instruction node.

use crate::instructions::execute_open_cover;
use crate::node::context::ExecutionContext;
use crate::node::progress::text_progress;
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct OpenCoverInstruction;

#[async_trait]
impl InstructionNode for OpenCoverInstruction {
    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::OpenCover(config) = node_type else {
            tracing::error!("OpenCoverInstruction received non-OpenCover variant");
            return NodeStatus::Failure;
        };
        let ctx = context.to_instruction_context(node_id).await;
        let progress_fn = text_progress(context.progress_callback.as_ref(), node_id, "Open Cover");
        execute_open_cover(config, &ctx, Some(&progress_fn))
            .await
            .settle("Open Cover", &ctx)
            .await
    }
}
