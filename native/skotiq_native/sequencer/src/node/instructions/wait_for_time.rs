//! WaitForTime instruction node.

use crate::instructions::execute_wait_time;
use crate::node::context::ExecutionContext;
use crate::node::progress::{ProgressDetail, ProgressUpdate};
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct WaitForTimeInstruction;

#[async_trait]
impl InstructionNode for WaitForTimeInstruction {
    fn type_name(&self) -> &'static str {
        "Wait"
    }

    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::WaitForTime(config) = node_type else {
            tracing::error!("WaitForTimeInstruction received non-WaitForTime variant");
            return NodeStatus::Failure;
        };

        let ctx = context.to_instruction_context(node_id).await;
        let progress_cb = context.progress_callback.as_ref();

        let progress_fn = |progress: f64, detail: String| {
            if let Some(cb) = progress_cb {
                // Try to extract seconds remaining from the detail string.
                let remaining = parse_remaining_secs(&detail);
                let pd = match remaining {
                    Some(r) => ProgressDetail::Wait { remaining_secs: r },
                    None => ProgressDetail::Generic(detail),
                };
                cb(ProgressUpdate::instruction_progress(
                    node_id.to_string(),
                    "Wait",
                    progress,
                    pd,
                ));
            }
        };

        execute_wait_time(config, &ctx, Some(&progress_fn))
            .await
            .log_and_get_status_with_context("Wait For Time", &ctx)
    }
}

fn parse_remaining_secs(detail: &str) -> Option<f64> {
    // Pull the first numeric token from strings like "30s remaining" or "1h 5m".
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
