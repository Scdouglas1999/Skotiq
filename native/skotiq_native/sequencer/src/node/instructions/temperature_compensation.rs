//! TemperatureCompensation instruction node.

use crate::node::context::ExecutionContext;
use crate::node::progress::{ProgressDetail, ProgressUpdate};
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct TemperatureCompensationInstruction;

#[async_trait]
impl InstructionNode for TemperatureCompensationInstruction {
    fn type_name(&self) -> &'static str {
        "Temp Comp"
    }

    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::TemperatureCompensation(config) = node_type else {
            tracing::error!(
                "TemperatureCompensationInstruction received non-TemperatureCompensation variant"
            );
            return NodeStatus::Failure;
        };
        let ctx = context.to_instruction_context(node_id).await;
        let progress_cb = context.progress_callback.as_ref();
        let progress_fn = |progress: f64, detail: String| {
            if let Some(cb) = progress_cb {
                cb(ProgressUpdate::instruction_progress(
                    node_id.to_string(),
                    "Temp Comp",
                    progress,
                    ProgressDetail::Generic(detail),
                ));
            }
        };
        crate::temperature_compensation::execute_temperature_compensation(
            config,
            &ctx,
            Some(&progress_fn),
        )
        .await
        .log_and_get_status_with_context("Temperature Compensation", &ctx)
    }
}
