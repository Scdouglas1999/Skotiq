//! StopGuiding instruction node.

use crate::instructions::execute_stop_guiding;
use crate::node::context::ExecutionContext;
use crate::node::progress::step_progress;
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct StopGuidingInstruction;

#[async_trait]
impl InstructionNode for StopGuidingInstruction {
    async fn execute(
        &self,
        node_id: &str,
        _node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let ctx = context.to_instruction_context(node_id).await;
        let progress_fn = step_progress::<String>(context.progress_callback.as_ref(), node_id, "Stop Guiding");
        execute_stop_guiding(&ctx, Some(&progress_fn))
            .await
            .settle("Stop Guiding", &ctx)
            .await
    }
}
