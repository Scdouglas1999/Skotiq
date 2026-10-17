//! `cooling` tests — moved verbatim out of the former single `instructions::tests`
//! module (release-pass C3 mechanical split). Shared fixtures stay in the parent
//! `tests` module and reach here through `use super::*;`.

use super::*;

/// A WarmCamera whose final "switch the cooler off" fails must not report
/// success. On the reference rig (2026-08-09, L19) that call failed for
/// every request — the instruction ran its whole ramp, discarded the
/// error, and reported "Camera warmed to ambient" with the TEC still
/// powered.
#[tokio::test(start_paused = true)]
async fn warm_camera_reports_failure_when_the_cooler_will_not_switch_off() {
    let ops =
        Arc::new(ScriptedDomeRotatorOps::new().with_failing_cooler_off(
            "Failed to set cooler: Failed to set property SetCCDTemperature",
        ));
    let ctx = ctx_with_ops(ops.clone()).await;

    let result = execute_warm_camera(
        &WarmConfig {
            rate_per_min: 60.0,
            target_temp: Some(20.0),
        },
        &ctx,
        None,
    )
    .await;

    assert_eq!(
        result.status,
        NodeStatus::Failure,
        "a warm-up that could not switch the cooler off must not report success: {:?}",
        result.message
    );
    let message = result.message.unwrap_or_default();
    assert!(
        message.contains("could not switch the cooler off"),
        "the failure must name what actually went wrong, got: {message}"
    );
    assert!(
        ops.cooler_commands
            .lock()
            .unwrap()
            .iter()
            .any(|(enabled, _)| !*enabled),
        "the instruction must still have attempted the cooler-off"
    );
}

/// What a CoolCamera node did: its status, the set-point later frames record,
/// and what the operator was told.
struct CoolRun {
    status: NodeStatus,
    set_temp_c: Option<f64>,
    warnings: Vec<String>,
    decisions: Vec<String>,
}

/// Run a CoolCamera node to -10 °C with a 1-minute timeout on a sensor that
/// reads `temps` in turn.
async fn cool_node_with(temps: &[f64], stop_on_quality_problems: bool) -> CoolRun {
    use crate::node::registry::InstructionNode;

    let ops = Arc::new(ScriptedDomeRotatorOps::new().with_camera_temperatures(temps));
    let mut ec = crate::node::context::ExecutionContext::new_for_test("cool".to_string());
    ec.device_ops = ops;
    ec.camera_id = Some("camera-1".to_string());
    let mut state = crate::triggers::TriggerState::new();
    state.stop_on_quality_problems = stop_on_quality_problems;
    ec.trigger_state = Some(Arc::new(tokio::sync::RwLock::new(state)));
    let (event_tx, mut events) = tokio::sync::broadcast::channel(64);
    ec.event_tx = Some(event_tx);
    let (decision_tx, mut decision_rx) = tokio::sync::broadcast::channel(64);
    ec.decision_tx = Some(decision_tx);
    let node = crate::NodeType::CoolCamera(CoolConfig {
        target_temp: -10.0,
        duration_mins: Some(1.0),
    });

    let status = crate::node::instructions::cool_camera::CoolCameraInstruction
        .execute("cool", &node, &mut ec)
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
    CoolRun {
        status,
        set_temp_c: ec.set_temp_c,
        warnings,
        decisions,
    }
}

/// Owner decision 2026-10-06: a cooler that does not reach its set-point in
/// time is not a reason to end the night. The node failed and the run ended
/// with it; it now tells the operator where the cooler got to and the run
/// images at that temperature (each frame's CCD-TEMP records it).
#[tokio::test(start_paused = true)]
async fn a_cooler_short_of_its_setpoint_notifies_and_the_run_continues() {
    let run = cool_node_with(&[20.0, 5.0, -2.0, -5.0], false).await;

    assert_eq!(run.status, NodeStatus::Success);
    assert_eq!(
        run.set_temp_c,
        Some(-10.0),
        "the cooler keeps its set-point"
    );
    assert_eq!(
        run.decisions,
        vec![crate::executor::QUALITY_PROBLEM_CONTINUED_SUMMARY]
    );
    assert!(
        run.warnings
            .iter()
            .any(|w| w.contains("-5.0") && w.contains("-10.0") && w.contains("The run continues")),
        "{:?}",
        run.warnings
    );
}

#[tokio::test(start_paused = true)]
async fn a_cooler_short_of_its_setpoint_still_fails_for_the_operator_who_asked() {
    let run = cool_node_with(&[20.0, 5.0, -2.0, -5.0], true).await;

    assert_eq!(run.status, NodeStatus::Failure);
    assert_eq!(run.set_temp_c, None);
    assert!(run.decisions.is_empty(), "{:?}", run.decisions);
}

/// A sensor that warms while its cooler runs is a cooler fault (a dead fan, a
/// TEC driven the wrong way) and a risk to the camera, so it stops the run
/// whatever the quality setting says.
#[tokio::test(start_paused = true)]
async fn a_sensor_warming_under_its_cooler_is_a_fault_that_still_stops() {
    let run = cool_node_with(&[20.0, 22.0, 24.0, 26.0], false).await;

    assert_eq!(run.status, NodeStatus::Failure);
    assert_eq!(run.set_temp_c, None);
    assert!(run.decisions.is_empty(), "{:?}", run.decisions);
}
