//! WarmCamera instruction node.

use crate::instructions::{execute_warm_camera, ThermalReading};
use crate::node::context::ExecutionContext;
use crate::node::progress::step_progress;
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct WarmCameraInstruction;

#[async_trait]
impl InstructionNode for WarmCameraInstruction {
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
        let target_temp = config.target_temp;

        let progress_fn = step_progress::<ThermalReading>(context.progress_callback.as_ref(), node_id, "Warm Camera");

        let status = execute_warm_camera(config, &ctx, Some(&progress_fn))
            .await
            .settle("Warm Camera", &ctx)
            .await;

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
