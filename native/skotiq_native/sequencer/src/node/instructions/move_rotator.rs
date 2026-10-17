//! MoveRotator instruction node.

use crate::instructions::execute_rotator_move;
use crate::node::context::ExecutionContext;
use crate::node::progress::{ProgressDetail, ProgressUpdate};
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct MoveRotatorInstruction;

#[async_trait]
impl InstructionNode for MoveRotatorInstruction {
    fn type_name(&self) -> &'static str {
        "Move Rotator"
    }

    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::MoveRotator(config) = node_type else {
            tracing::error!("MoveRotatorInstruction received non-MoveRotator variant");
            return NodeStatus::Failure;
        };

        let ctx = context.to_instruction_context(node_id).await;
        let progress_cb = context.progress_callback.as_ref();
        let target_angle = config.target_angle;

        let progress_fn = |progress: f64, _detail: String| {
            if let Some(cb) = progress_cb {
                cb(ProgressUpdate::instruction_progress(
                    node_id.to_string(),
                    "Move Rotator",
                    progress,
                    ProgressDetail::Rotator {
                        current_angle_deg: None,
                        target_angle_deg: target_angle,
                    },
                ));
            }
        };

        execute_rotator_move(config, &ctx, Some(&progress_fn))
            .await
            .log_and_get_status_with_context("Move Rotator", &ctx)
    }
}
