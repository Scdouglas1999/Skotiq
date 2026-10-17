//! OpenCover instruction node.

use crate::instructions::execute_open_cover;
use crate::node::context::ExecutionContext;
use crate::node::progress::{ProgressDetail, ProgressUpdate};
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct OpenCoverInstruction;

#[async_trait]
impl InstructionNode for OpenCoverInstruction {
    fn type_name(&self) -> &'static str {
        "Open Cover"
    }

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
        let progress_cb = context.progress_callback.as_ref();
        let progress_fn = |progress: f64, detail: String| {
            if let Some(cb) = progress_cb {
                cb(ProgressUpdate::instruction_progress(
                    node_id.to_string(),
                    "Open Cover",
                    progress,
                    ProgressDetail::CoverCalibrator { state: detail },
                ));
            }
        };
        execute_open_cover(config, &ctx, Some(&progress_fn))
            .await
            .log_and_get_status_with_context("Open Cover", &ctx)
    }
}
