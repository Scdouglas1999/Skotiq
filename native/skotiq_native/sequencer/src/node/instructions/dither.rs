//! Dither instruction node.

use crate::instructions::execute_dither;
use crate::node::context::ExecutionContext;
use crate::node::progress::{ProgressDetail, ProgressUpdate};
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct DitherInstruction;

#[async_trait]
impl InstructionNode for DitherInstruction {
    fn type_name(&self) -> &'static str {
        "Dither"
    }

    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::Dither(config) = node_type else {
            tracing::error!("DitherInstruction received non-Dither variant");
            return NodeStatus::Failure;
        };

        let ctx = context.to_instruction_context(node_id).await;
        let progress_cb = context.progress_callback.as_ref();
        let dither_pixels = config.pixels;
        let dither_settle = config.settle_pixels;
        let ra_only = config.ra_only;

        let progress_fn = |progress: f64, _detail: String| {
            if let Some(cb) = progress_cb {
                cb(ProgressUpdate::instruction_progress(
                    node_id.to_string(),
                    "Dither",
                    progress,
                    ProgressDetail::Dither {
                        pixels: dither_pixels,
                        settle_pixels: dither_settle,
                        ra_only,
                    },
                ));
            }
        };

        let result = execute_dither(config, &ctx, Some(&progress_fn)).await;

        if result.status == NodeStatus::Success {
            if let Some(trigger_state_lock) = &context.trigger_state {
                let mut trigger_state = trigger_state_lock.write().await;
                trigger_state.mark_dither_performed();
                tracing::debug!(
                    "Marked dither performed at exposure {}",
                    trigger_state.completed_exposures
                );
            }
        }

        result.log_and_get_status_with_context("Dither", &ctx)
    }
}
