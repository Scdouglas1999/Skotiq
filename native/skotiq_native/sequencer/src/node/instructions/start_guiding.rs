//! StartGuiding instruction node.

use crate::instructions::execute_start_guiding;
use crate::node::context::ExecutionContext;
use crate::node::progress::{ProgressDetail, ProgressUpdate};
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct StartGuidingInstruction;

#[async_trait]
impl InstructionNode for StartGuidingInstruction {
    fn type_name(&self) -> &'static str {
        "Start Guiding"
    }

    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::StartGuiding(config) = node_type else {
            tracing::error!("StartGuidingInstruction received non-StartGuiding variant");
            return NodeStatus::Failure;
        };

        let ctx = context.to_instruction_context(node_id).await;
        let progress_cb = context.progress_callback.as_ref();

        let progress_fn = |progress: f64, detail: String| {
            if let Some(cb) = progress_cb {
                let is_settled = detail.to_lowercase().contains("settled");
                let rms_total = extract_rms(&detail);
                cb(ProgressUpdate::instruction_progress(
                    node_id.to_string(),
                    "Start Guiding",
                    progress,
                    ProgressDetail::Guiding {
                        rms_total,
                        is_settled,
                    },
                ));
            }
        };

        execute_start_guiding(config, &ctx, Some(&progress_fn))
            .await
            .log_and_get_status_with_context("Start Guiding", &ctx)
    }
}

fn extract_rms(detail: &str) -> Option<f64> {
    let lower = detail.to_lowercase();
    let idx = lower.find("rms")?;
    let rest = &detail[idx + "rms".len()..];
    let mut start = None;
    for (i, c) in rest.char_indices() {
        if c.is_ascii_digit() || c == '.' || c == '-' {
            start = Some(i);
            break;
        }
    }
    let start = start?;
    let tail = &rest[start..];
    let mut end = tail.len();
    for (i, c) in tail.char_indices() {
        if !(c.is_ascii_digit() || c == '.' || c == '-') {
            end = i;
            break;
        }
    }
    tail[..end].parse::<f64>().ok()
}
