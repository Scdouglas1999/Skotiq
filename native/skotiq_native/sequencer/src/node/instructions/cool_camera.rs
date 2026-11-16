//! CoolCamera instruction node.

use crate::instructions::{execute_cool_camera, ThermalReading};
use crate::node::context::ExecutionContext;
use crate::node::progress::step_progress;
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct CoolCameraInstruction;

#[async_trait]
impl InstructionNode for CoolCameraInstruction {
    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::CoolCamera(config) = node_type else {
            tracing::error!("CoolCameraInstruction received non-CoolCamera variant");
            return NodeStatus::Failure;
        };

        let ctx = context.to_instruction_context(node_id).await;
        let target_temp = config.target_temp;

        let progress_fn = step_progress::<ThermalReading>(
            context.progress_callback.as_ref(),
            node_id,
            "Cool Camera",
        );

        let asked_at = tokio::time::Instant::now();
        let status = execute_cool_camera(config, &ctx, Some(&progress_fn))
            .await
            .settle("Cool Camera", &ctx)
            .await;

        // The set-point sticks until another CoolCamera / WarmCamera changes
        // it: every later frame's SET-TEMP, and the set-point darks and bias
        // hold to, with the time the cooler was given to reach it. Only a
        // cool step that succeeded knows the set-point.
        if status == NodeStatus::Success {
            context.set_temp_c = Some(target_temp);
            context.set_point_settle_by = Some(asked_at + config.settle_budget());
            tracing::debug!(
                "ExecutionContext.set_temp_c updated to {:.1}°C after CoolCamera success",
                target_temp
            );
        }

        status
    }
}
