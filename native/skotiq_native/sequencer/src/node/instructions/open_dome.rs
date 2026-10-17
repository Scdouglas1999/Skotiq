//! OpenDome instruction node.

use crate::instructions::execute_open_dome;
use crate::node::context::ExecutionContext;
use crate::node::progress::{ProgressDetail, ProgressUpdate};
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct OpenDomeInstruction;

#[async_trait]
impl InstructionNode for OpenDomeInstruction {
    fn type_name(&self) -> &'static str {
        "Open Dome"
    }

    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::OpenDome(config) = node_type else {
            tracing::error!("OpenDomeInstruction received non-OpenDome variant");
            return NodeStatus::Failure;
        };

        let ctx = context.to_instruction_context(node_id).await;
        let progress_cb = context.progress_callback.as_ref();
        let progress_fn = |progress: f64, detail: String| {
            if let Some(cb) = progress_cb {
                cb(ProgressUpdate::instruction_progress(
                    node_id.to_string(),
                    "Open Dome",
                    progress,
                    ProgressDetail::Dome { phase: detail },
                ));
            }
        };
        execute_open_dome(config, &ctx, Some(&progress_fn))
            .await
            .log_and_get_status_with_context("Open Dome", &ctx)
    }
}
