//! TemperatureCompensation instruction node.

use crate::node::context::ExecutionContext;
use crate::node::progress::step_progress;
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct TemperatureCompensationInstruction;

#[async_trait]
impl InstructionNode for TemperatureCompensationInstruction {
    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::TemperatureCompensation(config) = node_type else {
            tracing::error!(
                "TemperatureCompensationInstruction received non-TemperatureCompensation variant"
            );
            return NodeStatus::Failure;
        };
        let ctx = context.to_instruction_context(node_id).await;
        let progress_fn = step_progress::<String>(context.progress_callback.as_ref(), node_id, "Temperature Compensation");
        crate::temperature_compensation::execute_temperature_compensation(
            config,
            &ctx,
            Some(&progress_fn),
        )
        .await
        .settle("Temperature Compensation", &ctx)
        .await
    }
}
