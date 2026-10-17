//! ParkDome instruction node.

use crate::instructions::execute_park_dome;
use crate::node::context::ExecutionContext;
use crate::node::progress::{ProgressDetail, ProgressUpdate};
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct ParkDomeInstruction;

#[async_trait]
impl InstructionNode for ParkDomeInstruction {
    fn type_name(&self) -> &'static str {
        "Park Dome"
    }

    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::ParkDome(config) = node_type else {
            tracing::error!("ParkDomeInstruction received non-ParkDome variant");
            return NodeStatus::Failure;
        };

        let ctx = context.to_instruction_context(node_id).await;
        let progress_cb = context.progress_callback.as_ref();
        let progress_fn = |progress: f64, detail: String| {
            if let Some(cb) = progress_cb {
                cb(ProgressUpdate::instruction_progress(
                    node_id.to_string(),
                    "Park Dome",
                    progress,
                    ProgressDetail::Dome { phase: detail },
                ));
            }
        };
        execute_park_dome(config, &ctx, Some(&progress_fn))
            .await
            .log_and_get_status_with_context("Park Dome", &ctx)
    }
}
