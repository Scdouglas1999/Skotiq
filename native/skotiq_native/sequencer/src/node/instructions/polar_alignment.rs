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
                if let Some(cb) = progress_cb {
                    cb(polar_alignment_status(node_id, msg));
                }
            },
            |image_data| {
                if let Some(cb) = image_cb {
                    cb(image_data);
                }
            },
        )
        .await
        .settle("Polar Alignment", &ctx)
        .await
    }
}

/// A polar alignment status line, as the step's report.
fn polar_alignment_status(node_id: &str, words: String) -> ProgressUpdate {
    ProgressUpdate::status(node_id.to_string(), "Polar Alignment", words).with_bare_status_line()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_polar_alignment_status_is_the_steps_report() {
        let update = polar_alignment_status("pa", "Rotating mount for point 2...".to_string());
        assert_eq!(update.instruction.as_deref(), Some("Polar Alignment"));
        assert_eq!(update.status, NodeStatus::Running);
        assert_eq!(
            update.legacy_message().as_deref(),
            Some("Rotating mount for point 2...")
        );
    }
}
