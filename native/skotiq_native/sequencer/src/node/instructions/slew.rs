//! SlewToTarget instruction node.

use crate::instructions::{execute_slew, slew_position_mismatch};
use crate::node::context::ExecutionContext;
use crate::node::progress::{ProgressDetail, ProgressUpdate};
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct SlewInstruction;

#[async_trait]
impl InstructionNode for SlewInstruction {
    fn type_name(&self) -> &'static str {
        "Slew"
    }

    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::SlewToTarget(config) = node_type else {
            tracing::error!("SlewInstruction received non-SlewToTarget variant");
            return NodeStatus::Failure;
        };

        let ctx = context.to_instruction_context(node_id).await;
        let progress_cb = context.progress_callback.as_ref();
        let target_ra = context.target_ra;
        let target_dec = context.target_dec;

        let progress_fn = |progress: f64, _detail_str: String| {
            if let Some(cb) = progress_cb {
                // Slew instruction reports phases like "Slewing to coords"
                // or "Waiting for mount to settle"; the structured payload
                // carries the actual target RA/Dec instead of the parsed
                // string so the UI can render coords without parsing.
                cb(ProgressUpdate::instruction_progress(
                    node_id.to_string(),
                    "Slew",
                    progress,
                    ProgressDetail::Slew {
                        target_ra_hours: target_ra,
                        target_dec_degrees: target_dec,
                    },
                ));
            }
        };

        let result = execute_slew(config, &ctx, Some(&progress_fn)).await;
        // The mount moved and stopped near the target, just outside the
        // tolerance. Centering, which normally follows, solves from there.
        // By default the operator is told and the run goes on (owner decision
        // 2026-10-06: only a risk to the hardware stops a run by itself);
        // Failure would end the target and, through it, the night, as it did
        // on 2026-11-08 over a 2.11' miss.
        if slew_position_mismatch(&result) && !ctx.stops_on_quality_problems().await {
            let problem = format!(
                "{} Skotiq slewed twice and goes on from here.",
                result.message.as_deref().unwrap_or("The slew landed off target.")
            );
            ctx.notify_quality_problem_continuing("Slew", &problem);
            return NodeStatus::Skipped;
        }
        result.log_and_get_status_with_context("Slew", &ctx)
    }
}
