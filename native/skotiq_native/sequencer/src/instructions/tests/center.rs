//! `center` tests — moved verbatim out of the former single `instructions::tests`
//! module (release-pass C3 mechanical split). Shared fixtures stay in the parent
//! `tests` module and reach here through `use super::*;`.

use super::*;

#[tokio::test(start_paused = true)]
async fn centering_waits_for_slew_startup_before_accepting_idle() {
    let ops = Arc::new(
        ScriptedDomeRotatorOps::new()
            .with_mount_slewing_states(vec![false, false, true, true, false]),
    );
    let mut ctx = ctx_with_ops(ops.clone()).await;
    ctx.mount_id = Some("mount-1".to_string());

    wait_for_centering_correction_slew("mount-1", &ctx)
        .await
        .expect("slew should start after the driver's delayed status update and then finish");

    assert_eq!(
        ops.mount_slew_state_calls.load(Ordering::SeqCst),
        5,
        "the initial idle polls must not be mistaken for slew completion"
    );
}

/// What a Center node did with a sky that would not solve.
struct CenterNodeRun {
    status: NodeStatus,
    warnings: Vec<String>,
    decisions: Vec<String>,
}

async fn center_node_on_cloud(stop_on_quality_problems: bool) -> CenterNodeRun {
    use crate::node::registry::InstructionNode;
    let ops = Arc::new(ScriptedDomeRotatorOps::new().with_plate_solve_failing());
    let mut context = crate::node::context::ExecutionContext::new_for_test("center".to_string());
    context.device_ops = ops;
    context.camera_id = Some("cam-1".to_string());
    context.mount_id = Some("mount-1".to_string());
    context.target_name = Some("M31".to_string());
    context.target_ra = Some(0.712);
    context.target_dec = Some(41.27);
    let mut state = crate::triggers::TriggerState::new();
    state.stop_on_quality_problems = stop_on_quality_problems;
    context.trigger_state = Some(Arc::new(tokio::sync::RwLock::new(state)));
    let (event_tx, mut events) = tokio::sync::broadcast::channel(64);
    context.event_tx = Some(event_tx);
    let (decision_tx, mut decision_rx) = tokio::sync::broadcast::channel(64);
    context.decision_tx = Some(decision_tx);
    let config = crate::CenterConfig {
        max_attempts: 2,
        exposure_duration: 0.01,
        ..Default::default()
    };

    let status = crate::node::instructions::center::CenterInstruction
        .execute(
            "center",
            &crate::NodeType::CenterTarget(config),
            &mut context,
        )
        .await;

    let mut warnings = Vec::new();
    while let Ok(event) = events.try_recv() {
        if let crate::executor::ExecutorEvent::Warning { message } = event {
            warnings.push(message);
        }
    }
    let mut decisions = Vec::new();
    while let Ok(decision) = decision_rx.try_recv() {
        decisions.push(decision.summary);
    }
    CenterNodeRun {
        status,
        warnings,
        decisions,
    }
}

/// A Center that could not solve (cloud, a sparse field, a solver that could
/// not cope) failed its node, and the failure ended the target and the night.
/// Owner decision 2026-10-06: only a risk to the hardware stops a run by
/// itself. The mount was slewed to the target; the run goes on from there.
#[tokio::test(start_paused = true)]
async fn a_center_that_does_not_converge_notifies_and_the_run_goes_on() {
    let run = center_node_on_cloud(false).await;
    assert_eq!(
        run.status,
        NodeStatus::Skipped,
        "Skipped lets the target's container step past it; Failure ends the target"
    );
    assert_eq!(
        run.decisions,
        vec![crate::executor::QUALITY_PROBLEM_CONTINUED_SUMMARY]
    );
    assert!(
        run.warnings
            .iter()
            .any(|w| w.contains("Failed to center") && w.contains("The run continues")),
        "{:?}",
        run.warnings
    );

    let run = center_node_on_cloud(true).await;
    assert_eq!(
        run.status,
        NodeStatus::Failure,
        "the operator asked for the stop"
    );
    assert!(run.decisions.is_empty(), "{:?}", run.decisions);
}
