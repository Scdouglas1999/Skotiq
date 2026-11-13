//! Autofocus instruction node.

use crate::instructions::{execute_autofocus_for_node, AutofocusProgress};
use crate::node::context::ExecutionContext;
use crate::node::progress::{ProgressDetail, ProgressUpdate};
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct AutofocusInstruction;

#[async_trait]
impl InstructionNode for AutofocusInstruction {
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
        let total_steps = config.sweep_point_count();

        let progress_fn = |percent: f64, progress: &AutofocusProgress| {
            if let Some(cb) = progress_cb {
                cb(ProgressUpdate::instruction_progress(
                    node_id.to_string(),
                    "Autofocus",
                    percent,
                    autofocus_detail(progress, total_steps),
                ));
            }
        };

        let pause = context.pause_gate();
        let result = execute_autofocus_for_node(config, &ctx, Some(&progress_fn), &pause).await;

        if result.status == NodeStatus::Success {
            if let Some(trigger_state_lock) = &context.run.trigger_state {
                let mut trigger_state = trigger_state_lock.write().await;
                if let Some(best_hfr) = result.hfr_values.first() {
                    trigger_state.update_hfr(*best_hfr);
                    trigger_state.reset_baseline_hfr();
                    tracing::debug!("Reset HFR baseline to {:.2} after autofocus", best_hfr);
                }
                trigger_state.mark_autofocus_performed();
                tracing::debug!(
                    "Marked autofocus performed at exposure {}",
                    trigger_state.latches.completed_exposures
                );
            }
        }

        result.settle("Autofocus", &ctx).await
    }
}

/// The progress of an autofocus sweep, for the node and for a refocus run on
/// behalf of another step (a trigger, an exposure, a recovery): the point and
/// HFR while the sweep measures, the step itself in words otherwise. A
/// finished sweep reports its last point and final HFR as an autofocus
/// detail: the app counts a successful autofocus by the step's last detail
/// being one.
pub(crate) fn autofocus_detail(progress: &AutofocusProgress, total_steps: u32) -> ProgressDetail {
    let step = match progress {
        AutofocusProgress::Complete { .. } => Some(total_steps),
        _ => progress
            .sweep()
            .map(|sweep| u32::try_from(sweep.point).unwrap_or(u32::MAX)),
    };
    match step {
        Some(step) => ProgressDetail::Autofocus {
            step,
            total_steps,
            current_hfr: progress.hfr(),
            star_count: progress
                .sweep()
                .map(|sweep| u32::try_from(sweep.star_count).unwrap_or(u32::MAX)),
        },
        None => ProgressDetail::Generic(progress.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::instructions::{FocusRange, SweepSnapshot};

    fn measured(point: usize, hfr: f64) -> AutofocusProgress {
        AutofocusProgress::PointMeasured(Box::new(SweepSnapshot {
            point,
            total_points: 9,
            hfr,
            star_count: 40,
            focus_range: FocusRange {
                min: 600,
                max: 1400,
            },
            vcurve_points: Vec::new(),
            star_crops: Vec::new(),
        }))
    }

    fn complete() -> AutofocusProgress {
        AutofocusProgress::Complete {
            position: 1012,
            hfr: 2.3456,
            hfr_measured: true,
            r_squared: 0.98765,
        }
    }

    /// What the run's status line and the step's progress panel read for each
    /// step of a sweep, whether a node or a refocus runs it.
    #[test]
    fn a_sweep_reports_the_point_and_hfr_while_measuring_and_words_otherwise() {
        let line = |progress: &AutofocusProgress| autofocus_detail(progress, 9).detail_text();
        assert_eq!(line(&AutofocusProgress::Starting), "Starting autofocus...");
        assert_eq!(
            line(&AutofocusProgress::MovingToStart { position: 600 }),
            "Moving to start position: 600"
        );
        assert_eq!(
            line(&AutofocusProgress::MovingToPoint {
                point: 3,
                total_points: 9,
                position: 800
            }),
            "Point 3/9: pos 800"
        );
        assert_eq!(line(&measured(5, 3.871)), "step 5/9 HFR 3.87");
        assert_eq!(
            line(&AutofocusProgress::Validating),
            "Validating focus data..."
        );
        assert_eq!(
            line(&AutofocusProgress::MovingToBestFocus { position: 1012 }),
            "Moving to best focus: 1012"
        );
        assert_eq!(line(&complete()), "step 9/9 HFR 2.35");
        assert_eq!(
            line(&AutofocusProgress::FocusBeyondSweep { sweep_center: 1600 }),
            "Focus lies beyond the sweep; sweeping around 1600"
        );
        assert_eq!(
            line(&AutofocusProgress::AttemptFailed {
                attempt: 1,
                attempts: 3
            }),
            "Autofocus attempt 1/3 failed; retrying full sweep"
        );
        assert!(matches!(
            autofocus_detail(&measured(5, 3.871), 9),
            ProgressDetail::Autofocus {
                step: 5,
                total_steps: 9,
                current_hfr: Some(hfr),
                star_count: Some(40),
            } if hfr == 3.871
        ));
    }

    /// A finished sweep ends on an autofocus detail, which the app counts a
    /// successful autofocus by.
    #[test]
    fn a_finished_sweep_ends_on_an_autofocus_detail() {
        assert!(matches!(
            autofocus_detail(&complete(), 9),
            ProgressDetail::Autofocus {
                step: 9,
                total_steps: 9,
                current_hfr: Some(hfr),
                star_count: None,
            } if hfr == 2.3456
        ));
    }
}
