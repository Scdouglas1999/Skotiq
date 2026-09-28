//! CenterTarget instruction node.

use crate::instructions::{execute_center, ImagingTrainClaimGuard};
use crate::node::context::ExecutionContext;
use crate::node::progress::{ProgressDetail, ProgressUpdate};
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

/// Time a centering attempt takes beyond its exposure: download, plate solve,
/// sync and the correction slew. Sizes the imaging-train claim's expected
/// duration; the claim's own grace covers a slow solve.
const CENTER_ATTEMPT_OVERHEAD_SECS: f64 = 45.0;

pub struct CenterInstruction;

#[async_trait]
impl InstructionNode for CenterInstruction {
    fn type_name(&self) -> &'static str {
        "Center"
    }

    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::CenterTarget(config) = node_type else {
            tracing::error!("CenterInstruction received non-CenterTarget variant");
            return NodeStatus::Failure;
        };

        let ctx = context.to_instruction_context(node_id).await;
        let progress_cb = context.progress_callback.as_ref();
        let max_attempts = config.max_attempts;

        let progress_fn = |progress: f64, detail_str: String| {
            if let Some(cb) = progress_cb {
                let attempt = extract_attempt(&detail_str).unwrap_or(0);
                let separation = extract_separation(&detail_str);
                cb(ProgressUpdate::instruction_progress(
                    node_id.to_string(),
                    "Center",
                    progress,
                    ProgressDetail::Center {
                        attempt,
                        max_attempts,
                        last_separation_arcsec: separation,
                    },
                ));
            }
        };

        // The Center node owns the imaging train for its whole loop, as an
        // exposure does for its frame: capture, solve, sync and correction
        // slew are one operation, and a trigger action that exposes or moves
        // the mount in the middle of it either takes the node's frame ("No
        // exposure is available to download") or invalidates the solve it is
        // about to sync on. Taken here rather than in `execute_center`, which
        // the DriftLimit recenter also runs while already holding the claim.
        let expected_secs = f64::from(config.max_attempts.max(1))
            * (config.exposure_duration.max(0.0) + CENTER_ATTEMPT_OVERHEAD_SECS);
        let claim = match ImagingTrainClaimGuard::acquire(&ctx, "centering", expected_secs).await {
            Ok(claim) => claim,
            Err(cancelled) => {
                return cancelled.log_and_get_status_with_context("Center Target", &ctx);
            }
        };
        let result = execute_center(config, &ctx, Some(&progress_fn)).await;
        claim.release(&ctx).await;
        result.log_and_get_status_with_context("Center Target", &ctx)
    }
}

/// Best-effort parse of "attempt N/M" from the instruction's legacy detail.
fn extract_attempt(detail: &str) -> Option<u32> {
    let lower = detail.to_lowercase();
    let idx = lower.find("attempt ")?;
    let rest = &detail[idx + "attempt ".len()..];
    let slash = rest.find('/')?;
    rest[..slash].trim().parse::<u32>().ok()
}

/// Best-effort parse of an arcsecond separation if surfaced.
fn extract_separation(detail: &str) -> Option<f64> {
    let lower = detail.to_lowercase();
    let idx = lower.find("sep")?;
    let rest = &detail[idx..];
    let mut chars = rest.chars().peekable();
    while let Some(&c) = chars.peek() {
        if c.is_ascii_digit() || c == '-' || c == '.' {
            break;
        }
        chars.next();
    }
    let mut token = String::new();
    for c in chars {
        if c.is_ascii_digit() || c == '.' || c == '-' {
            token.push(c);
        } else {
            break;
        }
    }
    if token.is_empty() {
        None
    } else {
        token.parse::<f64>().ok()
    }
}
