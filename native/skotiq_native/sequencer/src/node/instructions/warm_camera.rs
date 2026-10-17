//! WarmCamera instruction node.

use crate::instructions::execute_warm_camera;
use crate::node::context::ExecutionContext;
use crate::node::progress::{ProgressDetail, ProgressUpdate};
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct WarmCameraInstruction;

#[async_trait]
impl InstructionNode for WarmCameraInstruction {
    fn type_name(&self) -> &'static str {
        "Warm Camera"
    }

    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::WarmCamera(config) = node_type else {
            tracing::error!("WarmCameraInstruction received non-WarmCamera variant");
            return NodeStatus::Failure;
        };

        let ctx = context.to_instruction_context(node_id).await;
        let progress_cb = context.progress_callback.as_ref();
        let target_temp = config.target_temp;

        let progress_fn = |progress: f64, _detail: String| {
            if let Some(cb) = progress_cb {
                cb(ProgressUpdate::instruction_progress(
                    node_id.to_string(),
                    "Warm Camera",
                    progress,
                    ProgressDetail::Thermal {
                        current_temp_c: None,
                        target_temp_c: target_temp,
                    },
                ));
            }
        };

        let status = execute_warm_camera(config, &ctx, Some(&progress_fn))
            .await
            .log_and_get_status_with_context("Warm Camera", &ctx);

        // clear the cooler set-point on the ExecutionContext so
        // subsequent FITS headers omit SET-TEMP (cooler is being warmed /
        // turned off). When WarmCamera carries an explicit target_temp it
        // sticks; otherwise the cooler is being turned off entirely.
        if status == NodeStatus::Success {
            context.set_temp_c = target_temp;
            tracing::debug!(
                "ExecutionContext.set_temp_c cleared/updated to {:?}°C after WarmCamera success",
                target_temp
            );
        }

        status
    }
}
