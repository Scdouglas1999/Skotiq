//! Unpark instruction node.

use crate::instructions::execute_unpark;
use crate::node::context::ExecutionContext;
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct UnparkInstruction;

#[async_trait]
impl InstructionNode for UnparkInstruction {
    fn type_name(&self) -> &'static str {
        "Unpark"
    }

    async fn execute(
        &self,
        node_id: &str,
        _node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let ctx = context.to_instruction_context(node_id).await;
        execute_unpark(&ctx)
            .await
            .log_and_get_status_with_context("Unpark", &ctx)
    }
}
