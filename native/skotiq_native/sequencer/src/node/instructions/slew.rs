//! SlewToTarget instruction node.

use crate::instructions::execute_slew;
use crate::node::context::ExecutionContext;
use crate::node::progress::{ProgressDetail, ProgressUpdate};
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct SlewInstruction;

#[async_trait]
impl InstructionNode for SlewInstruction {
    fn type_name(&self) -> &'static str {
        "Slew"
    }

    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::SlewToTarget(config) = node_type else {
            tracing::error!("SlewInstruction received non-SlewToTarget variant");
            return NodeStatus::Failure;
        };

        let ctx = context.to_instruction_context(node_id).await;
        let progress_cb = context.progress_callback.as_ref();
        let target_ra = context.target_ra;
        let target_dec = context.target_dec;

        let progress_fn = |progress: f64, _detail_str: String| {
            if let Some(cb) = progress_cb {
                // Slew instruction reports phases like "Slewing to coords"
                // or "Waiting for mount to settle"; the structured payload
                // carries the actual target RA/Dec instead of the parsed
                // string so the UI can render coords without parsing.
                cb(ProgressUpdate::instruction_progress(
                    node_id.to_string(),
                    "Slew",
                    progress,
                    ProgressDetail::Slew {
                        target_ra_hours: target_ra,
                        target_dec_degrees: target_dec,
                    },
                ));
            }
        };

        execute_slew(config, &ctx, Some(&progress_fn))
            .await
            .log_and_get_status_with_context("Slew", &ctx)
    }
}
