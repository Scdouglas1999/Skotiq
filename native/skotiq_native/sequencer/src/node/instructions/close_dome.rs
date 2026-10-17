//! CloseDome instruction node.

use crate::instructions::execute_close_dome;
use crate::node::context::ExecutionContext;
use crate::node::progress::{ProgressDetail, ProgressUpdate};
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct CloseDomeInstruction;

#[async_trait]
impl InstructionNode for CloseDomeInstruction {
    fn type_name(&self) -> &'static str {
        "Close Dome"
    }

    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::CloseDome(config) = node_type else {
            tracing::error!("CloseDomeInstruction received non-CloseDome variant");
            return NodeStatus::Failure;
        };

        let ctx = context.to_instruction_context(node_id).await;
        let progress_cb = context.progress_callback.as_ref();
        let progress_fn = |progress: f64, detail: String| {
            if let Some(cb) = progress_cb {
                cb(ProgressUpdate::instruction_progress(
                    node_id.to_string(),
                    "Close Dome",
                    progress,
                    ProgressDetail::Dome { phase: detail },
                ));
            }
        };
        execute_close_dome(config, &ctx, Some(&progress_fn))
            .await
            .log_and_get_status_with_context("Close Dome", &ctx)
    }
}
