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
                    node_detail(progress, total_steps),
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

/// The node's progress for one step of its sweep: the point and HFR while
/// the sweep measures, the step itself in words otherwise.
fn node_detail(progress: &AutofocusProgress, total_steps: u32) -> ProgressDetail {
    let point = progress.sweep().map(|sweep| sweep.point);
    match (point, progress.hfr()) {
        (None, None) => ProgressDetail::Generic(progress.to_string()),
        (point, current_hfr) => ProgressDetail::Autofocus {
            step: point.map_or(0, |point| u32::try_from(point).unwrap_or(u32::MAX)),
            total_steps,
            current_hfr,
        },
    }
}

/// The progress of an autofocus run on behalf of another step (a trigger, an
/// exposure, a recovery): always an autofocus detail, with the HFR when the
/// step has one.
pub(crate) fn refocus_detail(progress: &AutofocusProgress, total_steps: u32) -> ProgressDetail {
    ProgressDetail::Autofocus {
        step: 0,
        total_steps,
        current_hfr: progress.hfr(),
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
            focus_range: FocusRange { min: 600, max: 1400 },
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

    /// What the run's status line and the node's progress panel read for each
    /// step of a node's sweep.
    #[test]
    fn a_node_reports_the_point_and_hfr_while_measuring_and_words_otherwise() {
        let line = |progress: &AutofocusProgress| node_detail(progress, 9).detail_text();
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
        assert_eq!(line(&AutofocusProgress::Validating), "Validating focus data...");
        assert_eq!(
            line(&AutofocusProgress::MovingToBestFocus { position: 1012 }),
            "Moving to best focus: 1012"
        );
        assert_eq!(line(&complete()), "step 0/9 HFR 2.35");
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
            node_detail(&measured(5, 3.871), 9),
            ProgressDetail::Autofocus {
                step: 5,
                total_steps: 9,
                current_hfr: Some(hfr),
            } if hfr == 3.871
        ));
    }

    /// A trigger's, an exposure's or a recovery's refocus always reads as an
    /// autofocus, which the app counts the sweep by.
    #[test]
    fn a_refocus_always_reports_an_autofocus_detail() {
        let line = |progress: &AutofocusProgress| refocus_detail(progress, 9).detail_text();
        assert_eq!(line(&AutofocusProgress::Starting), "step 0/9");
        assert_eq!(line(&measured(5, 3.871)), "step 0/9 HFR 3.87");
        assert_eq!(line(&complete()), "step 0/9 HFR 2.35");
    }
}
