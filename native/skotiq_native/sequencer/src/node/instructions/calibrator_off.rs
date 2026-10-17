//! CalibratorOff instruction node.

use crate::instructions::execute_calibrator_off;
use crate::node::context::ExecutionContext;
use crate::node::progress::{ProgressDetail, ProgressUpdate};
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct CalibratorOffInstruction;

#[async_trait]
impl InstructionNode for CalibratorOffInstruction {
    fn type_name(&self) -> &'static str {
        "Calibrator Off"
    }

    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::CalibratorOff(config) = node_type else {
            tracing::error!("CalibratorOffInstruction received non-CalibratorOff variant");
            return NodeStatus::Failure;
        };
        let ctx = context.to_instruction_context(node_id).await;
        let progress_cb = context.progress_callback.as_ref();
        let progress_fn = |progress: f64, detail: String| {
            if let Some(cb) = progress_cb {
                cb(ProgressUpdate::instruction_progress(
                    node_id.to_string(),
                    "Calibrator Off",
                    progress,
                    ProgressDetail::CoverCalibrator { state: detail },
                ));
            }
        };
        execute_calibrator_off(config, &ctx, Some(&progress_fn))
            .await
            .log_and_get_status_with_context("Calibrator Off", &ctx)
    }
}
