//! PolarAlignment instruction node.

use crate::instructions::execute_polar_alignment;
use crate::node::context::ExecutionContext;
use crate::node::progress::ProgressUpdate;
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct PolarAlignmentInstruction;

#[async_trait]
impl InstructionNode for PolarAlignmentInstruction {
    fn type_name(&self) -> &'static str {
        "Polar Alignment"
    }

    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::PolarAlignment(config) = node_type else {
            tracing::error!("PolarAlignmentInstruction received non-PolarAlignment variant");
            return NodeStatus::Failure;
        };

        let ctx = context.to_instruction_context(node_id).await;
        let progress_cb = context.progress_callback.as_ref();
        let image_cb = context.polar_align_image_callback.as_ref();

        execute_polar_alignment(
            config,
            &ctx,
            |msg, _progress| {
                // Lifecycle-message shape: the polar-align engine emits
                // free-form status strings rather than instruction-progress
                // events.
                if let Some(cb) = progress_cb {
                    cb(ProgressUpdate::lifecycle(
                        node_id.to_string(),
                        NodeStatus::Running,
                        msg,
                    ));
                }
            },
            |image_data| {
                if let Some(cb) = image_cb {
                    cb(image_data);
                }
            },
        )
        .await
        .log_and_get_status_with_context("Polar Alignment", &ctx)
    }
}
