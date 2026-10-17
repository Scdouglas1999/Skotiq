//! StopGuiding instruction node.

use crate::instructions::execute_stop_guiding;
use crate::node::context::ExecutionContext;
use crate::node::progress::{ProgressDetail, ProgressUpdate};
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct StopGuidingInstruction;

#[async_trait]
impl InstructionNode for StopGuidingInstruction {
    fn type_name(&self) -> &'static str {
        "Stop Guiding"
    }

    async fn execute(
        &self,
        node_id: &str,
        _node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let ctx = context.to_instruction_context(node_id).await;
        let progress_cb = context.progress_callback.as_ref();
        let progress_fn = |progress: f64, detail: String| {
            if let Some(cb) = progress_cb {
                cb(ProgressUpdate::instruction_progress(
                    node_id.to_string(),
                    "Stop Guiding",
                    progress,
                    ProgressDetail::Generic(detail),
                ));
            }
        };
        execute_stop_guiding(&ctx, Some(&progress_fn))
            .await
            .log_and_get_status_with_context("Stop Guiding", &ctx)
    }
}
