//! FlatWizard instruction node.

use crate::node::context::ExecutionContext;
use crate::node::progress::{ProgressDetail, ProgressUpdate};
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct FlatWizardInstruction;

#[async_trait]
impl InstructionNode for FlatWizardInstruction {
    fn type_name(&self) -> &'static str {
        "Flat Wizard"
    }

    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::FlatWizard(config) = node_type else {
            tracing::error!("FlatWizardInstruction received non-FlatWizard variant");
            return NodeStatus::Failure;
        };

        let ctx = context.to_instruction_context(node_id).await;
        let progress_cb = context.progress_callback.as_ref();
        let target_adu = config.target_adu;

        let progress_fn = |progress: f64, detail: String| {
            if let Some(cb) = progress_cb {
                let current_adu = extract_adu(&detail);
                let current_exposure = extract_exposure_secs(&detail);
                cb(ProgressUpdate::instruction_progress(
                    node_id.to_string(),
                    "Flat Wizard",
                    progress,
                    ProgressDetail::FlatWizard {
                        current_adu,
                        target_adu,
                        current_exposure_secs: current_exposure,
                    },
                ));
            }
        };

        crate::flat_wizard::execute_flat_wizard(config, &ctx, Some(&progress_fn))
            .await
            .log_and_get_status_with_context("Flat Wizard", &ctx)
    }
}

fn extract_adu(detail: &str) -> Option<u16> {
    let lower = detail.to_lowercase();
    let idx = lower.find("adu")?;
    let rest = &detail[idx + "adu".len()..];
    let mut buf = String::new();
    for c in rest.chars() {
        if c.is_ascii_digit() {
            buf.push(c);
        } else if !buf.is_empty() {
            break;
        }
    }
    if buf.is_empty() {
        None
    } else {
        buf.parse::<u16>().ok()
    }
}

fn extract_exposure_secs(detail: &str) -> Option<f64> {
    // Look for an "Xs" pattern.
    let chars: Vec<char> = detail.chars().collect();
    for (i, c) in chars.iter().enumerate() {
        if (*c == 's' || *c == 'S') && i > 0 {
            // Walk back through digits and a dot.
            let mut start = i;
            while start > 0 {
                let prev = chars[start - 1];
                if prev.is_ascii_digit() || prev == '.' {
                    start -= 1;
                } else {
                    break;
                }
            }
            if start < i {
                let candidate: String = chars[start..i].iter().collect();
                if let Ok(v) = candidate.parse::<f64>() {
                    return Some(v);
                }
            }
        }
    }
    None
}
