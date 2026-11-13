//! FlatWizard instruction node.

use crate::node::context::ExecutionContext;
use crate::node::progress::step_progress;
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct FlatWizardInstruction;

#[async_trait]
impl InstructionNode for FlatWizardInstruction {
    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::FlatWizard(config) = node_type else {
            tracing::error!("FlatWizardInstruction received non-FlatWizard variant");
            return NodeStatus::Failure;
        };

        let ctx = context.to_instruction_context(node_id).await;

        let progress_fn =
            step_progress::<String>(context.progress_callback.as_ref(), node_id, "Flat Wizard");

        let result =
            crate::flat_wizard::execute_flat_wizard(config, &ctx, Some(&progress_fn)).await;

        result.settle("Flat Wizard", &ctx).await
    }
}
