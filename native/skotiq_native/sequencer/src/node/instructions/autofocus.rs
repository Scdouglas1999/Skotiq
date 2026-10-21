//! Autofocus instruction node.

use crate::instructions::{
    autofocus_failure_continues_the_run, execute_autofocus_for_node,
    notify_autofocus_failed_continuing, read_autofocus_position,
};
use crate::node::context::ExecutionContext;
use crate::node::progress::{ProgressDetail, ProgressUpdate};
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct AutofocusInstruction;

#[async_trait]
impl InstructionNode for AutofocusInstruction {
    fn type_name(&self) -> &'static str {
        "Autofocus"
    }

    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::Autofocus(config) = node_type else {
            tracing::error!("AutofocusInstruction received non-Autofocus variant");
            return NodeStatus::Failure;
        };

        let ctx = context.to_instruction_context(node_id).await;
        let progress_cb = context.progress_callback.as_ref();
        let steps_out = config.steps_out;
        let total_steps = steps_out.saturating_mul(2).saturating_add(1);

        let progress_fn = |progress: f64, detail_str: String| {
            if let Some(cb) = progress_cb {
                let (step, hfr) = parse_autofocus_point(&detail_str)
                    .unwrap_or_else(|| parse_autofocus_detail(&detail_str));
                let detail = if step.is_some() || hfr.is_some() {
                    ProgressDetail::Autofocus {
                        step: step.unwrap_or(0),
                        total_steps,
                        current_hfr: hfr,
                    }
                } else {
                    ProgressDetail::Generic(detail_str)
                };
                cb(ProgressUpdate::instruction_progress(
                    node_id.to_string(),
                    "Autofocus",
                    progress,
                    detail,
                ));
            }
        };

        let pause = context.pause_gate();
        let position_before = read_autofocus_position(&ctx).await;
        let result = execute_autofocus_for_node(config, &ctx, Some(&progress_fn), &pause).await;

        // A missed focus does not end the target, and with it the night: the
        // sweep has put the focuser back where it started, the operator is
        // told, and the sequence goes on at that focus (owner decision
        // 2026-10-06). The node reports Skipped, which its container steps
        // past; Failure would short-circuit every sibling after it.
        if autofocus_failure_continues_the_run(&result) {
            notify_autofocus_failed_continuing(&ctx, "Autofocus", &result, position_before).await;
            return NodeStatus::Skipped;
        }

        if result.status == NodeStatus::Success {
            if let Some(trigger_state_lock) = &context.trigger_state {
                let mut trigger_state = trigger_state_lock.write().await;
                if let Some(best_hfr) = result.hfr_values.first() {
                    trigger_state.update_hfr(*best_hfr);
                    trigger_state.reset_baseline_hfr();
                    tracing::debug!("Reset HFR baseline to {:.2} after autofocus", best_hfr);
                }
                trigger_state.mark_autofocus_performed();
                tracing::debug!(
                    "Marked autofocus performed at exposure {}",
                    trigger_state.completed_exposures
                );
            }
        }

        result.log_and_get_status_with_context("Autofocus", &ctx)
    }
}

/// The point number and HFR from the sweep's `autofocus_progress` JSON, which
/// the text parser below reads as step 0.
fn parse_autofocus_point(s: &str) -> Option<(Option<u32>, Option<f64>)> {
    let value: serde_json::Value = serde_json::from_str(s).ok()?;
    if value.get("type")?.as_str()? != "autofocus_progress" {
        return None;
    }
    let point = value
        .get("point")
        .and_then(serde_json::Value::as_u64)
        .and_then(|p| u32::try_from(p).ok());
    let hfr = value.get("hfr").and_then(serde_json::Value::as_f64);
    Some((point, hfr))
}

/// Parse "step N" and "hfr X.Y" style fragments from the autofocus
/// instruction's free-form detail string.
pub(crate) fn parse_autofocus_detail(s: &str) -> (Option<u32>, Option<f64>) {
    let lower = s.to_lowercase();
    let step = lower.find("step ").and_then(|idx| {
        let rest = &s[idx + "step ".len()..];
        rest.split(|c: char| !c.is_ascii_digit())
            .next()
            .and_then(|t| t.parse::<u32>().ok())
    });
    let hfr = lower.find("hfr").and_then(|idx| {
        let rest = &s[idx + "hfr".len()..];
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
    });
    (step, hfr)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_step_and_hfr() {
        let (s, h) = parse_autofocus_detail("step 3 of 13 HFR 2.45");
        assert_eq!(s, Some(3));
        assert_eq!(h, Some(2.45));
    }

    #[test]
    fn reads_the_point_from_the_sweep_json() {
        let detail = r#"{"type":"autofocus_progress","point":5,"total_points":9,"hfr":3.87}"#;
        assert_eq!(parse_autofocus_point(detail), Some((Some(5), Some(3.87))));
        assert_eq!(parse_autofocus_point("step 3 of 13 HFR 2.45"), None);
    }

    #[test]
    fn handles_missing_fields() {
        let (s, h) = parse_autofocus_detail("Moving focuser");
        assert!(s.is_none());
        assert!(h.is_none());
    }
}
