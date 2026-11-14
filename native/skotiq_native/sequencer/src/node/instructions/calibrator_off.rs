//! CalibratorOff instruction node.

use crate::instructions::execute_calibrator_off;
use crate::node::context::ExecutionContext;
use crate::node::progress::step_progress;
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct CalibratorOffInstruction;

#[async_trait]
impl InstructionNode for CalibratorOffInstruction {
    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::CalibratorOff(config) = node_type else {
            tracing::error!("CalibratorOffInstruction received non-CalibratorOff variant");
            return NodeStatus::Failure;
        };
        let ctx = context.to_instruction_context(node_id).await;
        let progress_fn = step_progress::<String>(
            context.progress_callback.as_ref(),
            node_id,
            "Calibrator Off",
        );
        execute_calibrator_off(config, &ctx, Some(&progress_fn))
            .await
            .settle("Calibrator Off", &ctx)
            .await
    }
}
