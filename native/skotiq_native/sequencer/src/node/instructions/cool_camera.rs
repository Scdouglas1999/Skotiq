//! CoolCamera instruction node.

use crate::instructions::execute_cool_camera;
use crate::node::context::ExecutionContext;
use crate::node::progress::{ProgressDetail, ProgressUpdate};
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct CoolCameraInstruction;

#[async_trait]
impl InstructionNode for CoolCameraInstruction {
    fn type_name(&self) -> &'static str {
        "Cool Camera"
    }

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
        let progress_cb = context.progress_callback.as_ref();
        let target_temp = config.target_temp;

        let progress_fn = |progress: f64, detail: String| {
            if let Some(cb) = progress_cb {
                let current_temp = parse_temp(&detail);
                cb(ProgressUpdate::instruction_progress(
                    node_id.to_string(),
                    "Cool Camera",
                    progress,
                    ProgressDetail::Thermal {
                        current_temp_c: current_temp,
                        target_temp_c: Some(target_temp),
                    },
                ));
            }
        };

        let status = execute_cool_camera(config, &ctx, Some(&progress_fn))
            .await
            .log_and_get_status_with_context("Cool Camera", &ctx);

        // stamp the cooler set-point onto the ExecutionContext so
        // every subsequent TakeExposure's FITS header carries SET-TEMP.
        // This sticks until another CoolCamera / WarmCamera changes it.
        // We populate on Success only — a failed cool command should not
        // claim we know the cooler set-point.
        if status == NodeStatus::Success {
            context.set_temp_c = Some(target_temp);
            tracing::debug!(
                "ExecutionContext.set_temp_c updated to {:.1}°C after CoolCamera success",
                target_temp
            );
        }

        status
    }
}

fn parse_temp(detail: &str) -> Option<f64> {
    // Match "<number>°C" or "<number>C" or "<number>°".
    let mut buf = String::new();
    let mut found_digit = false;
    for c in detail.chars() {
        if c.is_ascii_digit() || c == '.' || c == '-' {
            buf.push(c);
            found_digit = true;
        } else if found_digit {
            break;
        }
    }
    if buf.is_empty() {
        None
    } else {
        buf.parse::<f64>().ok()
    }
}
