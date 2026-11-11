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
    ctx.run.rig.mount_id = Some("mount-1".to_string());

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
    context.run.device_ops = ops;
    context.run.rig.camera_id = Some("cam-1".to_string());
    context.run.rig.mount_id = Some("mount-1".to_string());
    context.target_name = Some("M31".to_string());
    context.target_ra = Some(0.712);
    context.target_dec = Some(41.27);
    let mut state = crate::triggers::TriggerState::new();
    state.settings.stop_on_quality_problems = stop_on_quality_problems;
    context.run.trigger_state = Some(Arc::new(tokio::sync::RwLock::new(state)));
    let (event_tx, mut events) = tokio::sync::broadcast::channel(64);
    context.run.event_tx = Some(event_tx);
    let (decision_tx, mut decision_rx) = tokio::sync::broadcast::channel(64);
    context.run.decision_tx = Some(decision_tx);
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

/// What the run's status line and the app read from a Center node: the
/// attempt whose frame is being taken or corrected, and attempt 0 while the
/// step starts and once it has centered.
#[tokio::test(start_paused = true)]
async fn a_center_node_reports_the_attempt_it_is_on() {
    use crate::node::registry::InstructionNode;
    let ops = Arc::new(
        ScriptedDomeRotatorOps::new()
            .with_off_target_solves(1)
            .with_mount_slewing_states(vec![true, false]),
    );
    let mut context = crate::node::context::ExecutionContext::new_for_test("center".to_string());
    context.run.device_ops = ops;
    context.run.rig.camera_id = Some("cam-1".to_string());
    context.run.rig.mount_id = Some("mount-1".to_string());
    context.target_ra = Some(0.712);
    context.target_dec = Some(41.27);
    let lines = Arc::new(std::sync::Mutex::new(Vec::new()));
    let sink = lines.clone();
    context.progress_callback = Some(Arc::new(move |update: crate::node::ProgressUpdate| {
        sink.lock().unwrap().push(update.legacy_message().expect("a progress line"));
    }));
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

    assert_eq!(status, NodeStatus::Success);
    assert_eq!(
        *lines.lock().unwrap(),
        vec![
            "Center: attempt 0/2 (0%)",
            "Center: attempt 1/2 (0%)",
            "Center: attempt 1/2 (25%)",
            "Center: attempt 1/2 (38%)",
            "Center: attempt 2/2 (50%)",
            "Center: attempt 2/2 (75%)",
            "Center: attempt 0/2 (95%)",
            "Center: attempt 0/2 (100%)",
        ]
    );
}

/// "Center where the mount points" takes the mount's read-back, which is of
/// date, and centers on it in J2000: the solves it is compared with and the
/// slew path both speak J2000.
#[tokio::test(start_paused = true)]
async fn centering_on_the_mount_position_centers_on_it_in_j2000() {
    let ops = Arc::new(
        ScriptedDomeRotatorOps::new()
            .with_scripted_mount_coordinates(10.0, 50.0)
            .with_readback_to_j2000_offset(-0.02, -0.1),
    );
    let mut ctx = ctx_with_ops(ops.clone()).await;
    ctx.run.rig.mount_id = Some("mount-1".to_string());
    let config = CenterConfig {
        use_target_coords: false,
        custom_ra: None,
        custom_dec: None,
        max_attempts: 1,
        exposure_duration: 0.01,
        ..CenterConfig::default()
    };

    execute_center(&config, &ctx, None).await;

    // The solve is checked against the target it is handed as a hint.
    let hints = ops.plate_solve_hints.lock().unwrap().clone();
    let (ra_deg, dec) = *hints.first().expect("centering solves a frame");
    let (ra_deg, dec) = (ra_deg.unwrap(), dec.unwrap());
    assert!(
        (ra_deg - 9.98 * 15.0).abs() < 1e-9 && (dec - 49.9).abs() < 1e-9,
        "centered on ({ra_deg}, {dec}), not the J2000 place of the mount's position"
    );
}
