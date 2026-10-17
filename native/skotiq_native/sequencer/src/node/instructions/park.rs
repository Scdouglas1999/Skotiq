//! Park instruction node.

use crate::instructions::execute_park;
use crate::node::context::ExecutionContext;
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct ParkInstruction;

#[async_trait]
impl InstructionNode for ParkInstruction {
    fn type_name(&self) -> &'static str {
        "Park"
    }

    async fn execute(
        &self,
        node_id: &str,
        _node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let ctx = context.to_instruction_context(node_id).await;
        execute_park(&ctx)
            .await
            .log_and_get_status_with_context("Park", &ctx)
    }
}
