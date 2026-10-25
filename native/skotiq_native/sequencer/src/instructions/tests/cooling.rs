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
            ..WarmConfig::default()
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

/// Run a default WarmCamera (2 °C/min to 20 °C) on `ops` and return what it
/// reported with every cooler command it issued.
async fn warm_with(ops: Arc<ScriptedDomeRotatorOps>) -> (InstructionResult, Vec<(bool, f64)>) {
    let ctx = ctx_with_ops(ops.clone()).await;
    let result = execute_warm_camera(
        &WarmConfig {
            rate_per_min: 2.0,
            target_temp: None,
            ..WarmConfig::default()
        },
        &ctx,
        None,
    )
    .await;
    let commands = ops.cooler_commands.lock().unwrap().clone();
    (result, commands)
}

/// A camera whose cooler is off has nothing to warm. Warming it must not
/// switch the cooler on at the current sensor temperature.
#[tokio::test(start_paused = true)]
async fn warming_a_camera_whose_cooler_is_off_does_nothing() {
    let ops = Arc::new(
        ScriptedDomeRotatorOps::new()
            .with_camera_temperatures(&[11.2])
            .with_cooler(Some(false), 0.0),
    );
    let (result, commands) = warm_with(ops).await;

    assert_eq!(result.status, NodeStatus::Success);
    assert!(
        commands.is_empty(),
        "no cooler command may be sent to a cooler that is off, got {commands:?}"
    );
    assert_eq!(
        result.message.as_deref(),
        Some("Cooler already off, nothing to warm")
    );
}

/// A cooler that is on but idle (sensor at ambient, ~0 % power) is switched
/// off at once: a ramp would only hold it on at a warm set-point.
#[tokio::test(start_paused = true)]
async fn warming_an_idle_cooler_switches_it_off_without_a_ramp() {
    let ops = Arc::new(
        ScriptedDomeRotatorOps::new()
            .with_camera_temperatures(&[11.2])
            .with_cooler(Some(true), 0.0),
    );
    let (result, commands) = warm_with(ops).await;

    assert_eq!(result.status, NodeStatus::Success);
    assert_eq!(
        commands.len(),
        1,
        "one cooler-off command, got {commands:?}"
    );
    assert!(!commands[0].0, "the one command switches the cooler off");
}

/// A driver with no on/off reading still never ramps a cooler drawing no
/// power: that is a sensor already at ambient.
#[tokio::test(start_paused = true)]
async fn warming_with_no_cooler_reading_and_no_power_switches_off() {
    let ops = Arc::new(
        ScriptedDomeRotatorOps::new()
            .with_camera_temperatures(&[11.2])
            .with_cooler(None, 0.0),
    );
    let (result, commands) = warm_with(ops).await;

    assert_eq!(result.status, NodeStatus::Success);
    assert!(
        commands.iter().all(|(enabled, _)| !*enabled),
        "the cooler must never be switched on, got {commands:?}"
    );
}

/// A cooler actively holding a cold sensor still gets the gradual ramp.
#[tokio::test(start_paused = true)]
async fn warming_a_working_cooler_ramps_then_switches_off() {
    let ops = Arc::new(
        ScriptedDomeRotatorOps::new()
            .with_camera_temperatures(&[-10.0])
            .with_cooler(Some(true), 45.0),
    );
    let (result, commands) = warm_with(ops).await;

    assert_eq!(result.status, NodeStatus::Success);
    assert!(commands.len() > 2, "a ramp of set-points, got {commands:?}");
    assert!(commands[..commands.len() - 1].iter().all(|(on, _)| *on));
    assert!(!commands.last().unwrap().0, "ends with the cooler off");
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

/// A Warm Camera step handed to end-of-night calibration leaves the cooler
/// alone: the darks are taken at the set-point and calibration warms after.
#[tokio::test(start_paused = true)]
async fn a_warm_up_deferred_to_calibration_leaves_the_cooler_on() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new());
    let ctx = ctx_with_ops(ops.clone()).await;

    let result = execute_warm_camera(
        &WarmConfig {
            defer_to_calibration: true,
            ..WarmConfig::default()
        },
        &ctx,
        None,
    )
    .await;

    assert_eq!(result.status, NodeStatus::Success);
    assert!(result.message.unwrap_or_default().contains("deferred"));
    assert!(ops.cooler_commands.lock().unwrap().is_empty());
}
