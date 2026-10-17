//! MeridianFlip instruction node.

use crate::instructions::execute_meridian_flip;
use crate::node::context::ExecutionContext;
use crate::node::progress::{ProgressDetail, ProgressUpdate};
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct MeridianFlipInstruction;

#[async_trait]
impl InstructionNode for MeridianFlipInstruction {
    fn type_name(&self) -> &'static str {
        "Meridian Flip"
    }

    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::MeridianFlip(config) = node_type else {
            tracing::error!("MeridianFlipInstruction received non-MeridianFlip variant");
            return NodeStatus::Failure;
        };

        let ctx = context.to_instruction_context(node_id).await;
        let progress_cb = context.progress_callback.as_ref();

        let progress_fn = |progress: f64, detail: String| {
            if let Some(cb) = progress_cb {
                cb(ProgressUpdate::instruction_progress(
                    node_id.to_string(),
                    "Meridian Flip",
                    progress,
                    ProgressDetail::MeridianFlip { phase: detail },
                ));
            }
        };

        execute_meridian_flip(config, &ctx, Some(&progress_fn))
            .await
            .log_and_get_status_with_context("Meridian Flip", &ctx)
    }
}
