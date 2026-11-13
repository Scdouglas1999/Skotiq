//! CalibratorOn instruction node.

use crate::instructions::execute_calibrator_on;
use crate::node::context::ExecutionContext;
use crate::node::progress::step_progress;
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct CalibratorOnInstruction;

#[async_trait]
impl InstructionNode for CalibratorOnInstruction {
    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::CalibratorOn(config) = node_type else {
            tracing::error!("CalibratorOnInstruction received non-CalibratorOn variant");
            return NodeStatus::Failure;
        };
        let ctx = context.to_instruction_context(node_id).await;
        let progress_fn =
            step_progress::<String>(context.progress_callback.as_ref(), node_id, "Calibrator On");
        execute_calibrator_on(config, &ctx, Some(&progress_fn))
            .await
            .settle("Calibrator On", &ctx)
            .await
    }
}
