use super::*;
use crate::SequenceDefinition;

mod depth_goal_tests;
mod recovery_tests;
mod runtime_tests;

/// A failed dither that does not reset the interval leaves the trigger
/// permanently due for a condition that cannot change mid-run: an unguided
/// 12-frame dark run logs 12 identical "Trigger-initiated dither failed: No
/// active guider configured" WARNs, one per exposure.
#[test]
fn dither_without_a_guider_is_a_skip_not_a_failure() {
    assert_eq!(
        classify_dither_result(
            NodeStatus::Failure,
            Some("Dither failed: No active guider configured"),
        ),
        DitherTriggerOutcome::SkippedNoGuider,
    );
}

#[test]
fn a_real_dither_failure_still_fails() {
    for message in [
        "Dither failed: guide star lost",
        "Dither failed: settle timed out after 120s",
        "PHD2 connection refused",
    ] {
        assert_eq!(
            classify_dither_result(NodeStatus::Failure, Some(message)),
            DitherTriggerOutcome::Failed,
            "{message} should keep warning and stay due for retry",
        );
    }
}

#[test]
fn a_failure_with_no_message_still_fails() {
    assert_eq!(
        classify_dither_result(NodeStatus::Failure, None),
        DitherTriggerOutcome::Failed,
    );
}

/// Owner decision (2026-08-14): a trigger-fired autofocus that misses its
/// curve fit must not pause an unattended run. The run keeps the pre-sweep
/// focus and the replay log says so, naming both positions.
#[test]
fn a_failed_autofocus_trigger_records_the_focus_the_run_kept() {
    let continuation = autofocus_trigger_continuation(
        "autofocus_interval",
        "Autofocus Interval",
        "curve fit R² 0.31 below minimum 0.80",
        Some(21_400),
        Some(21_400),
        Some(true),
    );

    assert_eq!(
        continuation.decision.category,
        crate::decision::DecisionCategory::SystemEvent
    );
    assert_eq!(
        continuation.decision.summary,
        "Autofocus failed — continuing with last-good focus"
    );
    assert_eq!(
        continuation.decision.details["focuser_position_before"],
        serde_json::json!(21_400)
    );
    assert_eq!(
        continuation.decision.details["focuser_position_after"],
        serde_json::json!(21_400)
    );
    assert_eq!(
        continuation.decision.details["reason"],
        serde_json::json!("curve fit R² 0.31 below minimum 0.80")
    );
    assert!(
        continuation.operator_message.contains("imaging continues"),
        "the operator must be told the run carried on: {}",
        continuation.operator_message
    );
}

/// A failed RETURN move is a different night: the motor is parked somewhere
/// on the sweep and the frames from here on may be badly soft. The run still
/// continues, but the notice must not claim the focuser came home.
#[test]
fn a_failed_position_restore_is_called_out_not_smoothed_over() {
    let continuation = autofocus_trigger_continuation(
        "autofocus_interval",
        "Autofocus Interval",
        "focuser timed out",
        Some(21_400),
        Some(19_950),
        Some(false),
    );

    assert!(
        continuation
            .operator_message
            .contains("could NOT be returned"),
        "a failed restore must be named: {}",
        continuation.operator_message
    );
    assert!(continuation.operator_message.contains("19950"));
    assert_eq!(
        continuation.decision.details["pre_autofocus_position_restored"],
        serde_json::json!(false)
    );
}

/// An autofocus rejected at the admission gate never moved the focuser, so
/// the marker is absent rather than `false`. Reading that as a failed
/// restore would warn about focus on a run whose focuser never moved.
#[test]
fn an_autofocus_that_never_moved_the_focuser_does_not_warn_about_restore() {
    let continuation = autofocus_trigger_continuation(
        "autofocus_interval",
        "Autofocus Interval",
        "Autofocus is already running on this equipment host",
        Some(21_400),
        Some(21_400),
        None,
    );

    assert!(
        !continuation
            .operator_message
            .contains("could NOT be returned"),
        "an autofocus that never moved the focuser must not warn about the restore: {}",
        continuation.operator_message
    );
    assert_eq!(
        continuation.decision.details["pre_autofocus_position_restored"],
        serde_json::Value::Null
    );
}

#[test]
fn a_successful_dither_is_performed() {
    assert_eq!(
        classify_dither_result(NodeStatus::Success, None),
        DitherTriggerOutcome::Performed,
    );
}

#[test]
fn test_executor_creation() {
    let executor = SequenceExecutor::new();
    assert!(executor.sequence.is_none());
    assert!(executor.root_node.is_none());
}

#[test]
fn test_load_sequence() {
    let mut executor = SequenceExecutor::new();
    let mut sequence = SequenceDefinition::new("Test Sequence".to_string());

    let node = crate::NodeDefinition {
        id: "root".to_string(),
        name: "Root".to_string(),
        node_type: crate::NodeType::Delay(crate::DelayConfig::default()),
        enabled: true,
        children: vec![],
    };
    sequence.nodes.push(node);
    sequence.root_node_id = Some("root".to_string());

    let result = executor.load_sequence(sequence);
    assert!(
        result.is_ok(),
        "Failed to load sequence: {:?}",
        result.err()
    );
    assert!(executor.sequence.is_some());
}

fn single_exposure_sequence(save_to: Option<String>) -> SequenceDefinition {
    let mut sequence = SequenceDefinition::new("Capture".to_string());
    sequence.nodes.push(crate::NodeDefinition {
        id: "root".to_string(),
        name: "Root".to_string(),
        node_type: crate::NodeType::TakeExposure(crate::ExposureConfig {
            count: 1,
            duration_secs: 0.01,
            frame_type: "dark".to_string(),
            save_to,
            ..Default::default()
        }),
        enabled: true,
        children: vec![],
    });
    sequence.root_node_id = Some("root".to_string());
    sequence
}

/// Reproduce run 70's stored tree: the builder nested each newly added
/// instruction inside the previous one while drawing them as a flat list,
/// so `Target -> Unpark -> SlewToTarget -> TakeExposure` all sat on one
/// spine. `Unpark` is a leaf, so the executor ran it, returned Success and
/// never descended.
fn nested_leaf_chain_sequence() -> SequenceDefinition {
    let mut sequence = SequenceDefinition::new("New Sequence".to_string());
    sequence.nodes.push(crate::NodeDefinition {
        id: "target".to_string(),
        name: "Target".to_string(),
        node_type: crate::NodeType::TargetHeader(crate::TargetHeaderConfig::default()),
        enabled: true,
        children: vec!["unpark".to_string()],
    });
    sequence.nodes.push(crate::NodeDefinition {
        id: "unpark".to_string(),
        name: "Unpark Mount".to_string(),
        node_type: crate::NodeType::Unpark,
        enabled: true,
        children: vec!["slew".to_string()],
    });
    sequence.nodes.push(crate::NodeDefinition {
        id: "slew".to_string(),
        name: "Slew to Target".to_string(),
        node_type: crate::NodeType::SlewToTarget(crate::SlewConfig::default()),
        enabled: true,
        children: vec!["expose".to_string()],
    });
    sequence.nodes.push(crate::NodeDefinition {
        id: "expose".to_string(),
        name: "Take Exposures".to_string(),
        node_type: crate::NodeType::TakeExposure(crate::ExposureConfig {
            count: 3,
            duration_secs: 0.01,
            frame_type: "dark".to_string(),
            ..Default::default()
        }),
        enabled: true,
        children: vec![],
    });
    sequence.root_node_id = Some("target".to_string());
    sequence
}

/// A run must emit `ExecutorEvent::TargetStarted`: Dart's
/// `SequenceProgress.currentTarget` is fed by it, and without it
/// `sequence_runs.stats_json.targetBreakdown` falls through to its fallback
/// and keys a whole night under the SEQUENCE name while the frames on disk
/// carry the target's.
#[tokio::test]
async fn entering_a_target_announces_the_target_by_name() {
    let mut sequence = SequenceDefinition::new("New Sequence".to_string());
    sequence.nodes.push(crate::NodeDefinition {
        id: "target".to_string(),
        // Deliberately different from `target_name`: the wire must carry
        // the TARGET, not the node's display label.
        name: "Target".to_string(),
        node_type: crate::NodeType::TargetHeader(crate::TargetHeaderConfig {
            target_name: "M31".to_string(),
            ra_hours: 0.712,
            dec_degrees: 41.269,
            ..crate::TargetHeaderConfig::default()
        }),
        enabled: true,
        children: vec!["wait".to_string()],
    });
    sequence.nodes.push(crate::NodeDefinition {
        id: "wait".to_string(),
        name: "Wait".to_string(),
        node_type: crate::NodeType::Delay(crate::DelayConfig { seconds: 0.01 }),
        enabled: true,
        children: vec![],
    });
    sequence.root_node_id = Some("target".to_string());

    let mut executor = SequenceExecutor::new();
    executor.set_device_ops(Arc::new(crate::device_ops::NullDeviceOps));
    executor.load_sequence(sequence).expect("sequence loads");
    let mut events = executor.subscribe();

    executor.start().await.expect("run starts");

    for _ in 0..200 {
        if matches!(
            executor.get_state().await,
            ExecutorState::Completed | ExecutorState::Failed | ExecutorState::Cancelled
        ) {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
    }
    executor.stop().await.ok();

    let mut started = Vec::new();
    let mut completed = Vec::new();
    while let Ok(event) = events.try_recv() {
        match event {
            ExecutorEvent::TargetStarted { name, ra, dec } => started.push((name, ra, dec)),
            ExecutorEvent::TargetCompleted { name } => completed.push(name),
            _ => {}
        }
    }

    assert_eq!(
        started,
        vec![("M31".to_string(), 0.712, 41.269)],
        "entering the target must announce it exactly once, with its \
         configured coordinates"
    );
    assert_eq!(
        completed,
        vec!["M31".to_string()],
        "a target whose subtree succeeded must be announced as completed"
    );
}

/// A target with no name is left OFF the wire rather than announced under
/// an invented one — the save-path resolver already labels those frames
/// "untargeted", and a third spelling on the wire is the defect, not a fix.
#[tokio::test]
async fn an_unnamed_target_is_not_announced() {
    let mut sequence = SequenceDefinition::new("New Sequence".to_string());
    sequence.nodes.push(crate::NodeDefinition {
        id: "target".to_string(),
        name: "New Target".to_string(),
        node_type: crate::NodeType::TargetHeader(crate::TargetHeaderConfig::default()),
        enabled: true,
        children: vec!["wait".to_string()],
    });
    sequence.nodes.push(crate::NodeDefinition {
        id: "wait".to_string(),
        name: "Wait".to_string(),
        node_type: crate::NodeType::Delay(crate::DelayConfig { seconds: 0.01 }),
        enabled: true,
        children: vec![],
    });
    sequence.root_node_id = Some("target".to_string());

    let mut executor = SequenceExecutor::new();
    executor.set_device_ops(Arc::new(crate::device_ops::NullDeviceOps));
    executor.load_sequence(sequence).expect("sequence loads");
    let mut events = executor.subscribe();

    executor.start().await.expect("run starts");
    for _ in 0..200 {
        if matches!(
            executor.get_state().await,
            ExecutorState::Completed | ExecutorState::Failed | ExecutorState::Cancelled
        ) {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
    }
    executor.stop().await.ok();

    while let Ok(event) = events.try_recv() {
        assert!(
            !matches!(event, ExecutorEvent::TargetStarted { .. }),
            "an unnamed target must not be announced"
        );
    }
}

#[test]
fn instructions_parented_under_a_leaf_are_reported_as_unreachable() {
    let mut executor = SequenceExecutor::new();
    executor
        .load_sequence(nested_leaf_chain_sequence())
        .expect("sequence loads");
    let mut names = Vec::new();
    unreachable_instructions(&**executor.root_node.as_ref().expect("root"), &mut names);
    assert_eq!(
        names,
        vec!["Slew to Target".to_string(), "Take Exposures".to_string()],
        "everything below the Unpark leaf is stored, drawn and never executed"
    );
}

/// A run that walked one instruction of four must not report Completed: the
/// Session Report would show a green Completed badge, 0 frames and
/// `errorMessages: []` against a header chip reading "3 frames".
#[tokio::test]
async fn a_run_that_never_reaches_part_of_its_tree_does_not_report_completed() {
    let dir = std::env::temp_dir().join(format!("ns-unreachable-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).expect("temp dir");

    let mut executor = SequenceExecutor::new();
    executor.set_device_ops(Arc::new(crate::device_ops::NullDeviceOps));
    executor.set_devices(
        Some("camera-1".to_string()),
        Some("mount-1".to_string()),
        None,
        None,
        None,
    );
    executor.set_save_path(Some(dir.clone()));
    executor
        .load_sequence(nested_leaf_chain_sequence())
        .expect("sequence loads");
    let mut events = executor.subscribe();

    executor.start().await.expect("run starts");

    let mut final_state = None;
    for _ in 0..200 {
        let state = executor.get_state().await;
        if matches!(
            state,
            ExecutorState::Completed | ExecutorState::Failed | ExecutorState::Cancelled
        ) {
            final_state = Some(state);
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
    }
    executor.stop().await.ok();
    let _ = std::fs::remove_dir_all(&dir);

    assert_eq!(
        final_state,
        Some(ExecutorState::Failed),
        "a run that skipped most of its instructions must not report completed"
    );

    let mut failure_reason = None;
    while let Ok(event) = events.try_recv() {
        if let ExecutorEvent::SequenceFailed { error } = event {
            failure_reason = Some(error);
        }
    }
    let reason = failure_reason.expect("the run must publish a terminal failure reason");
    assert!(
        reason.contains("Slew to Target") && reason.contains("Take Exposures"),
        "the failure must name the instructions that never executed; got: {reason}"
    );
}

/// The terminal `SequenceFailed` must carry the instruction's real reason —
/// with a hardcoded "Sequence failed" the toast, the Session Report Errors
/// section and the persisted `stats_json.errorMessages` all hide the cause
/// (e.g. "Daylight gate: refusing light-frame exposure") that only the log
/// holds.
#[tokio::test]
async fn a_failed_run_reports_the_reason_the_instruction_gave() {
    // A misconfigured script fails immediately with a specific, quotable
    // reason and touches no device — the point is the wire, not the
    // instruction.
    let mut sequence = SequenceDefinition::new("Misconfigured script".to_string());
    sequence.nodes.push(crate::NodeDefinition {
        id: "script".to_string(),
        name: "Run Script".to_string(),
        node_type: crate::NodeType::RunScript(crate::ScriptConfig {
            script_path: "/nonexistent/nightshade-test-script".to_string(),
            timeout_secs: Some(0),
            ..Default::default()
        }),
        enabled: true,
        children: vec![],
    });
    sequence.root_node_id = Some("script".to_string());

    let mut executor = SequenceExecutor::new();
    executor.set_device_ops(Arc::new(crate::device_ops::NullDeviceOps));
    executor.load_sequence(sequence).expect("sequence loads");
    let mut events = executor.subscribe();

    executor.start().await.expect("run starts");

    for _ in 0..200 {
        if matches!(
            executor.get_state().await,
            ExecutorState::Completed | ExecutorState::Failed | ExecutorState::Cancelled
        ) {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
    }
    executor.stop().await.ok();

    let mut failure_reason = None;
    while let Ok(event) = events.try_recv() {
        if let ExecutorEvent::SequenceFailed { error } = event {
            failure_reason = Some(error);
        }
    }
    let reason = failure_reason.expect("a failed run must publish a terminal failure reason");
    assert!(
        reason.contains("timeout_secs must be greater than zero"),
        "the terminal event must carry the instruction's real reason, not a \
         placeholder; got: {reason}"
    );
}

/// A night that dies on a target trigger it cannot evaluate must say so on the
/// surfaces an operator can reach.
///
/// The last progress message the tree emits is the ROOT container's
/// "Failed: <root name>", and that string is verbatim what
/// `GET /api/sequencer/status` returns as `message`. A run refused for a
/// missing observer location therefore answered "Failed: Night root" — the
/// container the operator never configured — while the real refusal sat in the
/// Rust log only. Both halves are asserted here: the terminal event carries the
/// reason (that is what reaches `stats_json.errorMessages` and the Session
/// Report) and the run's own progress message carries it too (that is what
/// reaches `/api/sequencer/status`).
#[tokio::test]
async fn an_unevaluable_target_trigger_states_its_reason_on_the_run() {
    let mut sequence = SequenceDefinition::new("No observer".to_string());
    sequence.nodes.push(crate::NodeDefinition {
        id: "root".to_string(),
        name: "Night root".to_string(),
        node_type: crate::NodeType::TargetHeader(crate::TargetHeaderConfig {
            target_name: "D3 Field".to_string(),
            ra_hours: 20.9629,
            dec_degrees: 40.0,
            start_when: Some(crate::scheduling::TargetTrigger::AltitudeAbove(35.0)),
            ..Default::default()
        }),
        enabled: true,
        children: vec![],
    });
    sequence.root_node_id = Some("root".to_string());

    let mut executor = SequenceExecutor::new();
    executor.set_device_ops(Arc::new(crate::device_ops::NullDeviceOps));
    // No observer location is set on the executor — the condition under test.
    executor.load_sequence(sequence).expect("sequence loads");
    let mut events = executor.subscribe();

    executor.start().await.expect("run starts");

    for _ in 0..200 {
        if matches!(
            executor.get_state().await,
            ExecutorState::Completed | ExecutorState::Failed | ExecutorState::Cancelled
        ) {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
    }
    assert_eq!(
        executor.get_state().await,
        ExecutorState::Failed,
        "a target trigger that cannot be evaluated must fail the run closed"
    );

    let mut failure_reason = None;
    while let Ok(event) = events.try_recv() {
        if let ExecutorEvent::SequenceFailed { error } = event {
            failure_reason = Some(error);
        }
    }
    let reason = failure_reason.expect("a failed run must publish a terminal failure reason");
    assert!(
        reason.contains("D3 Field") && reason.contains("no observer location is set"),
        "the terminal event must name the target and the reason, not the \
         \"Sequence failed\" placeholder; got: {reason}"
    );

    let message = executor
        .get_progress()
        .message
        .expect("a terminal run publishes a progress message");
    assert_eq!(
        message, reason,
        "GET /api/sequencer/status returns this string; it must be the reason, \
         not the root container's \"Failed: Night root\""
    );
}

/// The rule that replaced "prefer the most recent reason". A dying run's most
/// recent complaint is its teardown; see `executor::failure_cause`.
#[tokio::test]
async fn the_reported_reason_is_the_first_fault_not_the_cancelled_cleanup() {
    let (tx, rx) = broadcast::channel(16);
    let collector = super::failure_cause::FailureCollector::spawn(rx);
    let _ = tx.send(ExecutorEvent::InstructionFailed {
        node_name: "Take Exposures".to_string(),
        message: "Daylight gate: refusing light-frame exposure".to_string(),
    });
    // What the executor's cancellation cascade adds on the way out, and what
    // the owner was shown instead of the line above.
    let _ = tx.send(ExecutorEvent::InstructionFailed {
        node_name: "Change Filter".to_string(),
        message: "Operation cancelled".to_string(),
    });

    let report = collector.finish(None).await;
    assert_eq!(
        report.cause.as_deref(),
        Some("Take Exposures: Daylight gate: refusing light-frame exposure")
    );
    assert_eq!(
        report.cascade.len(),
        2,
        "the cancelled step is kept, just not promoted to the reason"
    );

    let empty = super::failure_cause::FailureCollector::spawn(tx.subscribe())
        .finish(None)
        .await;
    assert_eq!(
        empty.cause, None,
        "a run with no failure at all must not invent one"
    );
}

/// A capture sequence with no save path configured is refused at the door:
/// starting it reports 100% complete and writes nothing.
#[tokio::test]
async fn start_refuses_a_capture_sequence_with_no_save_path() {
    let mut executor = SequenceExecutor::new();
    executor.set_device_ops(Arc::new(crate::device_ops::NullDeviceOps));
    executor
        .load_sequence(single_exposure_sequence(None))
        .expect("sequence loads");
    executor.set_save_path(None);

    let error = executor
        .start()
        .await
        .expect_err("a capture run with nowhere to write must be refused");
    assert!(
        error.contains("save"),
        "the refusal must name the save path; got: {error}"
    );
    executor.stop().await.ok();
}

/// D2b's sibling at the executor: a configured-but-unwritable directory is
/// just as fatal as no directory at all, and must be caught before the run.
#[tokio::test]
async fn start_refuses_a_save_path_that_cannot_be_written() {
    let mut executor = SequenceExecutor::new();
    executor.set_device_ops(Arc::new(crate::device_ops::NullDeviceOps));
    executor
        .load_sequence(single_exposure_sequence(None))
        .expect("sequence loads");
    // Uncreatable on every platform: a child of a regular FILE. `/proc/...`
    // only refuses on Linux — Windows reads it as a path on the current drive
    // and creates it happily, so the run was never refused and the test failed
    // there.
    let blocker = std::env::temp_dir().join(format!("ns-not-a-dir-{}", uuid::Uuid::new_v4()));
    std::fs::write(&blocker, b"not a directory").expect("blocker file writes");
    executor.set_save_path(Some(blocker.join("nightshade-cannot-write")));

    let error = executor
        .start()
        .await
        .expect_err("an uncreatable save directory must be refused");
    assert!(
        error.contains("save"),
        "the refusal must name the save path; got: {error}"
    );
    executor.stop().await.ok();
    std::fs::remove_file(&blocker).ok();
}

/// The gate must not fire when there is a real destination.
#[tokio::test]
async fn start_accepts_a_capture_sequence_with_a_writable_save_path() {
    let dir = std::env::temp_dir().join(format!("ns-start-gate-{}", uuid::Uuid::new_v4()));
    let mut executor = SequenceExecutor::new();
    executor.set_device_ops(Arc::new(crate::device_ops::NullDeviceOps));
    executor
        .load_sequence(single_exposure_sequence(None))
        .expect("sequence loads");
    executor.set_save_path(Some(dir.clone()));
    // A camera is now equally mandatory for a capture run; assign one so
    // this test still isolates the SAVE-PATH gate.
    executor.set_devices(Some("cam-1".to_string()), None, None, None, None);

    let result = executor.start().await;
    executor.stop().await.ok();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(result.is_ok(), "unexpected refusal: {:?}", result.err());
}

/// Live-rig L6 (2026-08-09). A capture sequence started with NO camera
/// assigned answered `{"status":"started"}` and then sat at
/// `{"state":"recovering","message":"Recovering: Device disconnected",
/// "progress":0.0}` writing nothing, because `TakeExposure` failed
/// "No camera connected", the disconnect classifier promoted that to a
/// `DeviceDisconnected` recovery, and the loop then waited for a device
/// that was never configured.
///
/// Reverting either `collect_required_devices` or the
/// `validate_required_devices` call in `start()` puts the run back on that
/// path: this test then sees `Ok` from `start()` instead of the refusal.
#[tokio::test]
async fn start_refuses_a_capture_sequence_with_no_camera() {
    let dir = std::env::temp_dir().join(format!("ns-cam-gate-{}", uuid::Uuid::new_v4()));
    let mut executor = SequenceExecutor::new();
    executor.set_device_ops(Arc::new(crate::device_ops::NullDeviceOps));
    executor
        .load_sequence(single_exposure_sequence(None))
        .expect("sequence loads");
    // Save path is fine — this must isolate the CAMERA gate, so the run
    // cannot be refused for the reason the save-path preflight already
    // covers.
    executor.set_save_path(Some(dir.clone()));

    let error = executor
        .start()
        .await
        .expect_err("a capture run with no camera assigned must be refused");
    executor.stop().await.ok();
    let _ = std::fs::remove_dir_all(&dir);

    assert!(
        error.contains("camera"),
        "the refusal must name the camera; got: {error}"
    );
    assert!(
        !error.contains("save path"),
        "must fail on the camera, not fall through to the save-path gate: {error}"
    );
}

/// The same tree starts once a camera is assigned — proving the gate keys
/// on the missing camera and nothing else. This mirrors the live-rig proof:
/// with `POST /api/sequencer/devices` pushing the camera id (and the
/// equipment profile still empty) the identical sequence ran to
/// `{"state":"completed","progress":1.0}`.
#[tokio::test]
async fn start_accepts_a_capture_sequence_once_a_camera_is_assigned() {
    let dir = std::env::temp_dir().join(format!("ns-cam-gate-ok-{}", uuid::Uuid::new_v4()));
    let mut executor = SequenceExecutor::new();
    executor.set_device_ops(Arc::new(crate::device_ops::NullDeviceOps));
    executor
        .load_sequence(single_exposure_sequence(None))
        .expect("sequence loads");
    executor.set_save_path(Some(dir.clone()));
    executor.set_devices(
        Some("ascom:ASCOM.ASICamera2.Camera".to_string()),
        None,
        None,
        None,
        None,
    );

    let result = executor.start().await;
    executor.stop().await.ok();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(result.is_ok(), "unexpected refusal: {:?}", result.err());
}

/// The gate must not over-reach: a sequence that never exposes needs no
/// camera, and refusing one would break every park / delay / notification
/// utility sequence on a rig with the camera intentionally left off.
#[tokio::test]
async fn start_allows_a_non_capturing_sequence_with_no_camera() {
    let mut sequence = SequenceDefinition::new("No capture".to_string());
    sequence.nodes.push(crate::NodeDefinition {
        id: "root".to_string(),
        name: "Wait".to_string(),
        node_type: crate::NodeType::Delay(crate::DelayConfig { seconds: 0.01 }),
        enabled: true,
        children: vec![],
    });
    sequence.root_node_id = Some("root".to_string());

    let mut executor = SequenceExecutor::new();
    executor.set_device_ops(Arc::new(crate::device_ops::NullDeviceOps));
    executor.load_sequence(sequence).expect("sequence loads");

    let result = executor.start().await;
    executor.stop().await.ok();
    assert!(
        result.is_ok(),
        "a sequence with no exposure must not need a camera: {:?}",
        result.err()
    );
}

/// An absolute `save_to` exempts a `TakeExposure` from the base-save-path
/// gate, but nothing exempts it from needing a camera — this shape gets past
/// the save-path preflight and must still fail on the missing camera rather
/// than hang in recovery.
#[tokio::test]
async fn start_refuses_an_absolute_save_to_capture_with_no_camera() {
    let dir = std::env::temp_dir().join(format!("ns-cam-abs-{}", uuid::Uuid::new_v4()));
    let mut executor = SequenceExecutor::new();
    executor.set_device_ops(Arc::new(crate::device_ops::NullDeviceOps));
    executor
        .load_sequence(single_exposure_sequence(Some(
            dir.to_string_lossy().into_owned(),
        )))
        .expect("sequence loads");
    // Deliberately NO base save path: the absolute save_to is what makes
    // the save-path gate stand down, exactly as on the rig.
    executor.set_save_path(None);

    let error = executor
        .start()
        .await
        .expect_err("an absolute save_to does not remove the need for a camera");
    executor.stop().await.ok();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(
        error.contains("camera"),
        "the refusal must name the camera; got: {error}"
    );
}

/// Unit-level companion to the two `start()` tests above: the whitespace
/// case. An id of `"   "` is not an id, and treating it as one would send
/// the run straight back into the disconnect-recovery loop.
#[test]
fn validate_required_devices_rejects_absent_and_blank_ids() {
    let required = std::collections::BTreeMap::from([(
        RequiredDevice::Camera,
        DeviceRequirement {
            node_name: "Take Exposures".to_string(),
            captures_frames: true,
        },
    )]);
    let with = |id: Option<&str>| {
        let owned = id.map(str::to_string);
        validate_required_devices(&required, move |_| owned.clone())
    };

    assert!(with(None).is_err());
    assert!(with(Some("")).is_err());
    assert!(with(Some("   ")).is_err());
    assert!(with(Some("ascom:ASCOM.ASICamera2.Camera")).is_ok());
}

/// Build a one-instruction sequence under a named target, the shape every
/// live-rig reproduction below used.
fn single_instruction_sequence(name: &str, node_type: crate::NodeType) -> SequenceDefinition {
    let mut sequence = SequenceDefinition::new(format!("{name} probe"));
    sequence.nodes.push(crate::NodeDefinition {
        id: "root".to_string(),
        name: "Target".to_string(),
        node_type: crate::NodeType::TargetHeader(crate::TargetHeaderConfig {
            target_name: "GuardProbe".to_string(),
            ra_hours: 5.5,
            dec_degrees: 22.0,
            ..Default::default()
        }),
        enabled: true,
        children: vec!["step".to_string()],
    });
    sequence.nodes.push(crate::NodeDefinition {
        id: "step".to_string(),
        name: name.to_string(),
        node_type,
        enabled: true,
        children: vec![],
    });
    sequence.root_node_id = Some("root".to_string());
    sequence
}

async fn start_refusal_for(node_type: crate::NodeType, step_name: &str) -> String {
    let dir = std::env::temp_dir().join(format!("ns-dev-gate-{}", uuid::Uuid::new_v4()));
    let mut executor = SequenceExecutor::new();
    executor.set_device_ops(Arc::new(crate::device_ops::NullDeviceOps));
    executor
        .load_sequence(single_instruction_sequence(step_name, node_type))
        .expect("sequence loads");
    // A real destination, so nothing can be refused for the reason the
    // save-path preflight already covers.
    executor.set_save_path(Some(dir.clone()));

    let outcome = executor.start().await;
    executor.stop().await.ok();
    let _ = std::fs::remove_dir_all(&dir);
    match outcome {
        Ok(()) => panic!("{step_name} with no device assigned must be refused at start"),
        Err(error) => error,
    }
}

/// Pre-flight refuses a missing save path and a missing plate solver; a
/// sequence that declares a DEVICE the executor cannot resolve must be
/// refused the same way rather than starting and dying mid-run.
///
/// Reproduced against the Linux appliance (release bundle, headless, no
/// devices connected): each one answers `POST /api/sequencer/start -> 200
/// {"status":"started"}` followed by
/// `{"state":"failed","message":"Cancelled: Target"}`, with the real reason
/// only in the log — `ERROR Change Filter failed: No filter wheel
/// connected`, `ERROR Slew failed: No mount connected`, `ERROR Cool Camera
/// failed: No camera connected`, `ERROR Autofocus failed: No camera
/// connected`, `ERROR Center Target failed: No mount connected`,
/// `ERROR Move Rotator failed: No rotator connected` — each immediately
/// promoted to a futile disconnect recovery.
///
/// Narrowing `collect_required_devices` to a `TakeExposure | SmartExposure |
/// FlatWizard` camera-only predicate puts every case below back on that path:
/// `start()` then returns `Ok`.
#[tokio::test]
async fn start_refuses_a_filter_change_with_no_filter_wheel() {
    let error = start_refusal_for(
        crate::NodeType::ChangeFilter(crate::FilterConfig {
            filter_name: "Ha".to_string(),
            filter_index: Some(2),
            timeout_secs: None,
        }),
        "Change Filter",
    )
    .await;
    assert!(
        error.contains("filter wheel") && error.contains("Change Filter"),
        "the refusal must name the wheel and the step; got: {error}"
    );
}

#[tokio::test]
async fn start_refuses_an_exposure_that_requests_a_filter_with_no_filter_wheel() {
    let dir = std::env::temp_dir().join(format!("ns-fw-gate-{}", uuid::Uuid::new_v4()));
    let mut executor = SequenceExecutor::new();
    executor.set_device_ops(Arc::new(crate::device_ops::NullDeviceOps));
    executor
        .load_sequence(single_instruction_sequence(
            "Take Exposures",
            crate::NodeType::TakeExposure(crate::ExposureConfig {
                count: 1,
                duration_secs: 0.01,
                filter_index: Some(0),
                ..Default::default()
            }),
        ))
        .expect("sequence loads");
    executor.set_save_path(Some(dir.clone()));
    // A camera IS assigned — this isolates the wheel, and is the live-rig
    // case: "an exposure on filter position 0, wheel not visible to the
    // executor" started and failed mid-run.
    executor.set_devices(Some("cam-1".to_string()), None, None, None, None);

    let error = executor
        .start()
        .await
        .expect_err("an exposure on filter position 0 with no wheel must be refused");
    executor.stop().await.ok();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(
        error.contains("filter wheel"),
        "the refusal must name the wheel; got: {error}"
    );
    assert!(
        !error.contains("no camera"),
        "a camera was assigned; the refusal must be about the wheel: {error}"
    );
}

/// A SmartExposure plan that names NO filter still moves the wheel.
///
/// `smart_exposure.rs` fires its ChangeFilter whenever
/// `current_filter != Some(plan.filter_name)`, and `current_filter` is
/// `None` at the start of a run — so `""` differs and the change runs.
/// Reproduced against the Linux appliance on 2026-08-09 with the sim
/// camera / mount / focuser connected and no wheel:
/// `POST /api/sequencer/start -> 200 {"status":"started"}`, then
/// `ERROR Change Filter failed: No filter wheel connected` +
/// `WARN [RECOVERY] Change Filter promoted device disconnect to recovery`,
/// five retries, `Failure`. Requiring a wheel only for a plan that NAMES
/// one left that path open.
#[tokio::test]
async fn start_refuses_a_smart_exposure_whose_plan_names_no_filter() {
    let dir = std::env::temp_dir().join(format!("ns-se-gate-{}", uuid::Uuid::new_v4()));
    let mut executor = SequenceExecutor::new();
    executor.set_device_ops(Arc::new(crate::device_ops::NullDeviceOps));
    executor
        .load_sequence(single_instruction_sequence(
            "Smart Exposure",
            crate::NodeType::SmartExposure(crate::SmartExposureConfig {
                plans: vec![crate::FilterPlan {
                    filter_name: String::new(),
                    count: 1,
                    duration_secs: 0.01,
                    ..Default::default()
                }],
                ..Default::default()
            }),
        ))
        .expect("sequence loads");
    executor.set_save_path(Some(dir.clone()));
    executor.set_devices(Some("cam-1".to_string()), None, None, None, None);

    let error = executor
        .start()
        .await
        .expect_err("a smart exposure with no wheel must be refused");
    executor.stop().await.ok();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(
        error.contains("filter wheel"),
        "the refusal must name the wheel; got: {error}"
    );
}

/// An autofocus node pinned to a filter reads the wheel before it sweeps.
///
/// Reproduced against the Linux appliance on 2026-08-09 with the sim
/// camera and focuser connected and no wheel: start answered 200 and the
/// node then failed `Autofocus is configured to use filter "Ha", but no
/// filter wheel is connected`.
#[tokio::test]
async fn start_refuses_autofocus_pinned_to_a_filter_with_no_filter_wheel() {
    let dir = std::env::temp_dir().join(format!("ns-af-fw-{}", uuid::Uuid::new_v4()));
    let mut executor = SequenceExecutor::new();
    executor.set_device_ops(Arc::new(crate::device_ops::NullDeviceOps));
    executor
        .load_sequence(single_instruction_sequence(
            "Autofocus",
            crate::NodeType::Autofocus(crate::AutofocusConfig {
                filter: Some("Ha".to_string()),
                ..Default::default()
            }),
        ))
        .expect("sequence loads");
    executor.set_save_path(Some(dir.clone()));
    executor.set_devices(
        Some("cam-1".to_string()),
        None,
        Some("focuser-1".to_string()),
        None,
        None,
    );

    let error = executor
        .start()
        .await
        .expect_err("an autofocus pinned to a filter with no wheel must be refused");
    executor.stop().await.ok();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(
        error.contains("filter wheel"),
        "the refusal must name the wheel; got: {error}"
    );
}

/// …and an autofocus that names no filter is NOT blocked for a wheel.
/// With no wheel the per-filter overrides simply go unapplied and the
/// sweep still runs, so demanding one here would refuse a run that works.
#[tokio::test]
async fn start_allows_autofocus_without_a_filter_when_there_is_no_wheel() {
    let dir = std::env::temp_dir().join(format!("ns-af-nofw-{}", uuid::Uuid::new_v4()));
    let mut executor = SequenceExecutor::new();
    executor.set_device_ops(Arc::new(crate::device_ops::NullDeviceOps));
    executor
        .load_sequence(single_instruction_sequence(
            "Autofocus",
            crate::NodeType::Autofocus(crate::AutofocusConfig::default()),
        ))
        .expect("sequence loads");
    executor.set_save_path(Some(dir.clone()));
    executor.set_devices(
        Some("cam-1".to_string()),
        None,
        Some("focuser-1".to_string()),
        None,
        None,
    );

    let result = executor.start().await;
    executor.stop().await.ok();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(
        result.is_ok(),
        "an unfiltered autofocus needs no wheel: {:?}",
        result.err()
    );
}

#[tokio::test]
async fn start_refuses_a_slew_with_no_mount() {
    let error = start_refusal_for(
        crate::NodeType::SlewToTarget(crate::SlewConfig::default()),
        "Slew to Target",
    )
    .await;
    assert!(
        error.contains("mount") && error.contains("Slew to Target"),
        "the refusal must name the mount and the step; got: {error}"
    );
}

#[tokio::test]
async fn start_refuses_a_park_with_no_mount() {
    let error = start_refusal_for(crate::NodeType::Park, "Park").await;
    assert!(
        error.contains("mount"),
        "the refusal must name the mount; got: {error}"
    );
}

#[tokio::test]
async fn start_refuses_cool_camera_with_no_camera() {
    let error = start_refusal_for(
        crate::NodeType::CoolCamera(crate::CoolConfig::default()),
        "Cool Camera",
    )
    .await;
    assert!(
        error.contains("camera") && error.contains("Cool Camera"),
        "the refusal must name the camera and the step; got: {error}"
    );
    assert!(
        !error.contains("captures frames"),
        "cooling captures nothing; the capture wording would be a lie: {error}"
    );
}

#[tokio::test]
async fn start_refuses_autofocus_naming_both_the_camera_and_the_focuser() {
    let error = start_refusal_for(
        crate::NodeType::Autofocus(crate::AutofocusConfig::default()),
        "Autofocus",
    )
    .await;
    assert!(
        error.contains("camera"),
        "autofocus exposes; the refusal must name the camera: {error}"
    );
    assert!(
        error.contains("focuser"),
        "autofocus moves the focuser; the refusal must name it too: {error}"
    );
}

#[tokio::test]
async fn start_refuses_center_target_with_no_mount_or_camera() {
    let error = start_refusal_for(
        crate::NodeType::CenterTarget(crate::CenterConfig::default()),
        "Center Target",
    )
    .await;
    assert!(
        error.contains("camera") && error.contains("mount"),
        "centering needs both; the refusal must name both: {error}"
    );
}

#[tokio::test]
async fn start_refuses_a_rotator_move_with_no_rotator() {
    let error = start_refusal_for(
        crate::NodeType::MoveRotator(crate::RotatorConfig {
            target_angle: 90.0,
            relative: false,
        }),
        "Move Rotator",
    )
    .await;
    assert!(
        error.contains("rotator") && error.contains("Move Rotator"),
        "the refusal must name the rotator and the step; got: {error}"
    );
}

/// The same trees start once the hardware is assigned — proving the gate
/// keys on the missing device and nothing else.
#[tokio::test]
async fn start_accepts_those_same_sequences_once_the_devices_are_assigned() {
    for (name, node_type) in [
        (
            "Change Filter",
            crate::NodeType::ChangeFilter(crate::FilterConfig {
                filter_name: "Ha".to_string(),
                filter_index: Some(2),
                timeout_secs: None,
            }),
        ),
        (
            "Slew to Target",
            crate::NodeType::SlewToTarget(crate::SlewConfig::default()),
        ),
        (
            "Cool Camera",
            crate::NodeType::CoolCamera(crate::CoolConfig::default()),
        ),
        (
            "Move Rotator",
            crate::NodeType::MoveRotator(crate::RotatorConfig {
                target_angle: 90.0,
                relative: false,
            }),
        ),
    ] {
        let dir = std::env::temp_dir().join(format!("ns-dev-ok-{}", uuid::Uuid::new_v4()));
        let mut executor = SequenceExecutor::new();
        executor.set_device_ops(Arc::new(crate::device_ops::NullDeviceOps));
        executor
            .load_sequence(single_instruction_sequence(name, node_type))
            .expect("sequence loads");
        executor.set_save_path(Some(dir.clone()));
        executor.set_devices(
            Some("cam-1".to_string()),
            Some("mount-1".to_string()),
            Some("focuser-1".to_string()),
            Some("wheel-1".to_string()),
            Some("rotator-1".to_string()),
        );

        let result = executor.start().await;
        executor.stop().await.ok();
        let _ = std::fs::remove_dir_all(&dir);
        assert!(result.is_ok(), "{name} was refused: {:?}", result.err());
    }
}

/// The gate must not over-reach. A DISABLED node is skipped before it ever
/// reaches hardware (`RuntimeNode::execute` returns `Skipped` without
/// descending), so it must not block a start — otherwise switching a step
/// off, the operator's normal way of working round missing kit, would stop
/// working.
#[tokio::test]
async fn start_ignores_devices_only_a_disabled_subtree_would_need() {
    let mut sequence = single_instruction_sequence(
        "Change Filter",
        crate::NodeType::ChangeFilter(crate::FilterConfig {
            filter_name: "Ha".to_string(),
            filter_index: Some(2),
            timeout_secs: None,
        }),
    );
    sequence
        .nodes
        .iter_mut()
        .find(|node| node.id == "step")
        .expect("step node")
        .enabled = false;

    let dir = std::env::temp_dir().join(format!("ns-dev-off-{}", uuid::Uuid::new_v4()));
    let mut executor = SequenceExecutor::new();
    executor.set_device_ops(Arc::new(crate::device_ops::NullDeviceOps));
    executor.load_sequence(sequence).expect("sequence loads");
    executor.set_save_path(Some(dir.clone()));

    let result = executor.start().await;
    executor.stop().await.ok();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(
        result.is_ok(),
        "a disabled filter change needs no wheel: {:?}",
        result.err()
    );
}

/// And the flat wizard is not blocked for a wheel it will not touch:
/// `FlatWizardRun::do_filter_change` returns `Ok` when there is no wheel.
#[tokio::test]
async fn start_does_not_demand_a_filter_wheel_for_a_flat_wizard() {
    let dir = std::env::temp_dir().join(format!("ns-flat-gate-{}", uuid::Uuid::new_v4()));
    let mut executor = SequenceExecutor::new();
    executor.set_device_ops(Arc::new(crate::device_ops::NullDeviceOps));
    executor
        .load_sequence(single_instruction_sequence(
            "Flat Wizard",
            crate::NodeType::FlatWizard(crate::FlatWizardConfig {
                filter: Some("Ha".to_string()),
                ..Default::default()
            }),
        ))
        .expect("sequence loads");
    executor.set_save_path(Some(dir.clone()));
    executor.set_devices(Some("cam-1".to_string()), None, None, None, None);

    let result = executor.start().await;
    executor.stop().await.ok();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(
        result.is_ok(),
        "the flat wizard skips its filter change without a wheel: {:?}",
        result.err()
    );
}

#[test]
fn custom_branch_recovery_node_registers_trigger_spec() {
    let mut sequence = SequenceDefinition::new("Custom Recovery".to_string());
    sequence.nodes.push(crate::NodeDefinition {
        id: "root".to_string(),
        name: "Root".to_string(),
        node_type: crate::NodeType::Delay(crate::DelayConfig { seconds: 0.0 }),
        enabled: true,
        children: vec!["recovery".to_string()],
    });
    sequence.nodes.push(crate::NodeDefinition {
        id: "recovery".to_string(),
        name: "Guide Recovery".to_string(),
        node_type: crate::NodeType::Recovery(crate::RecoveryConfig {
            trigger: Some(crate::TriggerType::GuideStarLost),
            recovery_action: crate::RecoveryAction::CustomBranch,
            max_retries: 1,
        }),
        enabled: true,
        children: vec!["delay".to_string()],
    });
    sequence.nodes.push(crate::NodeDefinition {
        id: "delay".to_string(),
        name: "Wait".to_string(),
        node_type: crate::NodeType::Delay(crate::DelayConfig { seconds: 0.0 }),
        enabled: true,
        children: vec![],
    });
    sequence.root_node_id = Some("root".to_string());

    let specs = sequence_recovery_trigger_specs(&sequence);

    assert_eq!(specs.len(), 1);
    assert_eq!(specs[0].trigger_id, "recovery_node:recovery");
    assert_eq!(specs[0].trigger_name, "Recovery: Guide Recovery");
    assert!(matches!(
        specs[0].trigger_type,
        crate::TriggerType::GuideStarLost
    ));
    assert!(matches!(
        specs[0].recovery_action,
        crate::RecoveryAction::CustomBranch
    ));
    assert_eq!(specs[0].custom_branch_node_id.as_deref(), Some("recovery"));
}

use crate::device_ops::{DeviceOps, DeviceResult, GuidingStatus};

/// DeviceOps that simulates a guider which is NOT guiding until
/// `guider_start` is called, after which `guider_get_status` reports
/// guiding. Records whether `guider_start` was invoked.
pub(super) struct ReacquireGuiderOps {
    inner: std::sync::Arc<crate::device_ops::NullDeviceOps>,
    /// Shared so the test can observe whether re-acquire was issued.
    started: std::sync::Arc<std::sync::atomic::AtomicBool>,
    start_should_fail: bool,
    relock_after_start: bool,
    /// Records the last `mount_set_tracking(enabled)` value so a test can
    /// assert tracking was restored. `None` => never called.
    last_tracking_set: std::sync::Arc<std::sync::Mutex<Option<bool>>>,
    /// When true, `mount_set_tracking(true)` returns Err so a test can
    /// exercise the loud-error-on-failure path.
    tracking_set_should_fail: bool,
    /// When true, `mount_is_parked` reports the mount as parked.
    parked: bool,
    /// When true, `mount_is_tracking` never returns — the driver that
    /// accepts the call and then goes away, which is what R1 is about.
    mount_is_tracking_hangs: bool,
}

impl ReacquireGuiderOps {
    pub(super) fn new(start_should_fail: bool, relock_after_start: bool) -> Self {
        Self {
            inner: std::sync::Arc::new(crate::device_ops::NullDeviceOps),
            started: std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false)),
            start_should_fail,
            relock_after_start,
            last_tracking_set: std::sync::Arc::new(std::sync::Mutex::new(None)),
            tracking_set_should_fail: false,
            parked: false,
            mount_is_tracking_hangs: false,
        }
    }

    pub(super) fn with_parked(mut self) -> Self {
        self.parked = true;
        self
    }

    pub(super) fn with_hanging_tracking_poll(mut self) -> Self {
        self.mount_is_tracking_hangs = true;
        self
    }

    pub(super) fn with_tracking_failure(mut self) -> Self {
        self.tracking_set_should_fail = true;
        self
    }

    pub(super) fn last_tracking_set(&self) -> Option<bool> {
        *self.last_tracking_set.lock().unwrap()
    }
}

#[async_trait::async_trait]
impl DeviceOps for ReacquireGuiderOps {
    async fn mount_set_tracking(&self, id: &str, enabled: bool) -> DeviceResult<()> {
        *self.last_tracking_set.lock().unwrap() = Some(enabled);
        if self.tracking_set_should_fail && enabled {
            return Err(format!("simulated tracking-enable failure for {}", id));
        }
        Ok(())
    }

    async fn guider_get_status(&self) -> DeviceResult<GuidingStatus> {
        // Guiding only once a (successful) re-acquire has been issued.
        let guiding = self.started.load(Ordering::Relaxed) && self.relock_after_start;
        Ok(GuidingStatus {
            is_guiding: guiding,
            rms_ra: 0.5,
            rms_dec: 0.4,
            rms_total: 0.64,
        })
    }

    async fn guider_start(
        &self,
        _settle_pixels: f64,
        _settle_time: f64,
        _settle_timeout: f64,
    ) -> DeviceResult<()> {
        if self.start_should_fail {
            return Err("simulated guider_start failure".to_string());
        }
        self.started.store(true, Ordering::Relaxed);
        Ok(())
    }

    // Delegating methods (every other DeviceOps method)
    async fn mount_slew_to_coordinates(&self, id: &str, ra: f64, dec: f64) -> DeviceResult<()> {
        self.inner.mount_slew_to_coordinates(id, ra, dec).await
    }
    async fn mount_abort_slew(&self, id: &str) -> DeviceResult<()> {
        self.inner.mount_abort_slew(id).await
    }
    async fn mount_get_coordinates(&self, id: &str) -> DeviceResult<(f64, f64)> {
        self.inner.mount_get_coordinates(id).await
    }
    async fn mount_sync(&self, id: &str, ra: f64, dec: f64) -> DeviceResult<()> {
        self.inner.mount_sync(id, ra, dec).await
    }
    async fn mount_park(&self, id: &str) -> DeviceResult<()> {
        self.inner.mount_park(id).await
    }
    async fn mount_unpark(&self, id: &str) -> DeviceResult<()> {
        self.inner.mount_unpark(id).await
    }
    async fn mount_is_slewing(&self, id: &str) -> DeviceResult<bool> {
        self.inner.mount_is_slewing(id).await
    }
    async fn mount_is_parked(&self, id: &str) -> DeviceResult<bool> {
        if self.parked {
            return Ok(true);
        }
        self.inner.mount_is_parked(id).await
    }
    async fn mount_can_flip(&self, id: &str) -> DeviceResult<bool> {
        self.inner.mount_can_flip(id).await
    }
    async fn mount_side_of_pier(&self, id: &str) -> DeviceResult<crate::meridian::PierSide> {
        self.inner.mount_side_of_pier(id).await
    }
    async fn mount_is_tracking(&self, id: &str) -> DeviceResult<bool> {
        if self.mount_is_tracking_hangs {
            std::future::pending::<()>().await;
        }
        self.inner.mount_is_tracking(id).await
    }
    async fn camera_start_exposure(
        &self,
        id: &str,
        d: f64,
        g: Option<i32>,
        o: Option<i32>,
        bx: i32,
        by: i32,
    ) -> DeviceResult<crate::device_ops::ImageData> {
        self.inner.camera_start_exposure(id, d, g, o, bx, by).await
    }
    async fn camera_abort_exposure(&self, id: &str) -> DeviceResult<()> {
        self.inner.camera_abort_exposure(id).await
    }
    async fn camera_set_cooler(&self, id: &str, e: bool, t: f64) -> DeviceResult<()> {
        self.inner.camera_set_cooler(id, e, t).await
    }
    async fn camera_get_temperature(&self, id: &str) -> DeviceResult<f64> {
        self.inner.camera_get_temperature(id).await
    }
    async fn camera_get_cooler_power(&self, id: &str) -> DeviceResult<f64> {
        self.inner.camera_get_cooler_power(id).await
    }
    async fn focuser_move_to(&self, id: &str, p: i32) -> DeviceResult<()> {
        self.inner.focuser_move_to(id, p).await
    }
    async fn focuser_get_position(&self, id: &str) -> DeviceResult<i32> {
        self.inner.focuser_get_position(id).await
    }
    async fn focuser_is_moving(&self, id: &str) -> DeviceResult<bool> {
        self.inner.focuser_is_moving(id).await
    }
    async fn focuser_get_temperature(&self, id: &str) -> DeviceResult<Option<f64>> {
        self.inner.focuser_get_temperature(id).await
    }
    async fn focuser_halt(&self, id: &str) -> DeviceResult<()> {
        self.inner.focuser_halt(id).await
    }
    async fn filterwheel_set_position(&self, id: &str, p: i32) -> DeviceResult<()> {
        self.inner.filterwheel_set_position(id, p).await
    }
    async fn filterwheel_get_position(&self, id: &str) -> DeviceResult<i32> {
        self.inner.filterwheel_get_position(id).await
    }
    async fn filterwheel_get_names(&self, id: &str) -> DeviceResult<Vec<String>> {
        self.inner.filterwheel_get_names(id).await
    }
    async fn filterwheel_set_filter_by_name(&self, id: &str, n: &str) -> DeviceResult<i32> {
        self.inner.filterwheel_set_filter_by_name(id, n).await
    }
    async fn rotator_move_to(&self, id: &str, a: f64) -> DeviceResult<()> {
        self.inner.rotator_move_to(id, a).await
    }
    async fn rotator_move_relative(&self, id: &str, d: f64) -> DeviceResult<()> {
        self.inner.rotator_move_relative(id, d).await
    }
    async fn rotator_get_angle(&self, id: &str) -> DeviceResult<f64> {
        self.inner.rotator_get_angle(id).await
    }
    async fn rotator_halt(&self, id: &str) -> DeviceResult<()> {
        self.inner.rotator_halt(id).await
    }
    async fn guider_dither(
        &self,
        p: f64,
        sp: f64,
        st: f64,
        sto: f64,
        ra: bool,
    ) -> DeviceResult<()> {
        self.inner.guider_dither(p, sp, st, sto, ra).await
    }
    async fn guider_stop(&self) -> DeviceResult<()> {
        self.inner.guider_stop().await
    }
    async fn plate_solve(
        &self,
        d: &crate::device_ops::ImageData,
        ra: Option<f64>,
        dec: Option<f64>,
        s: Option<f64>,
    ) -> DeviceResult<crate::device_ops::PlateSolveResult> {
        self.inner.plate_solve(d, ra, dec, s).await
    }
    async fn save_fits(
        &self,
        d: &crate::device_ops::ImageData,
        f: &str,
        fctx: &crate::scheduling::FrameContext,
    ) -> DeviceResult<()> {
        self.inner.save_fits(d, f, fctx).await
    }
    async fn send_notification(
        &self,
        l: &str,
        t: &str,
        m: &str,
        x: Option<&[String]>,
    ) -> DeviceResult<()> {
        self.inner.send_notification(l, t, m, x).await
    }
    fn calculate_altitude(&self, r: f64, d: f64, la: f64, lo: f64) -> f64 {
        self.inner.calculate_altitude(r, d, la, lo)
    }
    fn get_observer_location(&self) -> Option<(f64, f64)> {
        self.inner.get_observer_location()
    }
    async fn polar_align_update(
        &self,
        r: &crate::polar_align::PolarAlignResult,
    ) -> DeviceResult<()> {
        self.inner.polar_align_update(r).await
    }
    async fn dome_open(&self, id: &str) -> DeviceResult<()> {
        self.inner.dome_open(id).await
    }
    async fn dome_close(&self, id: &str) -> DeviceResult<()> {
        self.inner.dome_close(id).await
    }
    async fn dome_park(&self, id: &str) -> DeviceResult<()> {
        self.inner.dome_park(id).await
    }
    async fn dome_get_shutter_status(&self, id: &str) -> DeviceResult<String> {
        self.inner.dome_get_shutter_status(id).await
    }
    async fn safety_is_safe(&self, id: Option<&str>) -> DeviceResult<bool> {
        self.inner.safety_is_safe(id).await
    }
    async fn calculate_image_hfr(
        &self,
        d: &crate::device_ops::ImageData,
    ) -> DeviceResult<Option<f64>> {
        self.inner.calculate_image_hfr(d).await
    }
    async fn detect_stars_in_image(
        &self,
        d: &crate::device_ops::ImageData,
    ) -> DeviceResult<Vec<(f64, f64, f64)>> {
        self.inner.detect_stars_in_image(d).await
    }
    async fn cover_calibrator_open_cover(&self, id: &str) -> DeviceResult<()> {
        self.inner.cover_calibrator_open_cover(id).await
    }
    async fn cover_calibrator_close_cover(&self, id: &str) -> DeviceResult<()> {
        self.inner.cover_calibrator_close_cover(id).await
    }
    async fn cover_calibrator_halt_cover(&self, id: &str) -> DeviceResult<()> {
        self.inner.cover_calibrator_halt_cover(id).await
    }
    async fn cover_calibrator_calibrator_on(&self, id: &str, b: i32) -> DeviceResult<()> {
        self.inner.cover_calibrator_calibrator_on(id, b).await
    }
    async fn cover_calibrator_calibrator_off(&self, id: &str) -> DeviceResult<()> {
        self.inner.cover_calibrator_calibrator_off(id).await
    }
    async fn cover_calibrator_get_cover_state(&self, id: &str) -> DeviceResult<i32> {
        self.inner.cover_calibrator_get_cover_state(id).await
    }
    async fn cover_calibrator_get_calibrator_state(&self, id: &str) -> DeviceResult<i32> {
        self.inner.cover_calibrator_get_calibrator_state(id).await
    }
    async fn cover_calibrator_get_brightness(&self, id: &str) -> DeviceResult<i32> {
        self.inner.cover_calibrator_get_brightness(id).await
    }
    async fn cover_calibrator_get_max_brightness(&self, id: &str) -> DeviceResult<i32> {
        self.inner.cover_calibrator_get_max_brightness(id).await
    }
}

/// The terminal message a finished run publishes is the run's own verdict.
///
/// `/api/sequencer/status` returns `state` and `message` side by side, and the
/// message used to be whatever progress update happened to land last — a night
/// that finished cleanly answered `state: "completed"` with the last line a
/// filter-change autofocus had queued ("Autofocus: step 0/9 HFR 2.11 (100%)").
#[tokio::test]
async fn a_finished_run_publishes_its_own_verdict_as_the_terminal_message() {
    let mut sequence = SequenceDefinition::new("Night".to_string());
    sequence.nodes.push(crate::NodeDefinition {
        id: "root".to_string(),
        name: "Night root".to_string(),
        node_type: crate::NodeType::Loop(crate::LoopConfig {
            iterations: Some(1),
            condition: crate::LoopCondition::Count,
            condition_value: None,
            horizon_profile: None,
        }),
        enabled: true,
        children: vec!["wait".to_string()],
    });
    sequence.nodes.push(crate::NodeDefinition {
        id: "wait".to_string(),
        name: "Settle".to_string(),
        node_type: crate::NodeType::Delay(crate::DelayConfig { seconds: 0.0 }),
        enabled: true,
        children: vec![],
    });
    sequence.root_node_id = Some("root".to_string());

    let mut executor = SequenceExecutor::new();
    executor.set_device_ops(Arc::new(crate::device_ops::NullDeviceOps));
    executor.load_sequence(sequence).expect("sequence loads");
    executor.start().await.expect("run starts");

    for _ in 0..200 {
        if matches!(
            executor.get_state().await,
            ExecutorState::Completed | ExecutorState::Failed | ExecutorState::Cancelled
        ) {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
    }
    assert_eq!(executor.get_state().await, ExecutorState::Completed);
    assert_eq!(
        executor
            .get_progress()
            .message
            .expect("a terminal run publishes a progress message"),
        "Completed: Night root",
        "the message must name the root's outcome, not the last node to report"
    );
}

/// A fault the run recovered from is not the reason a later fault ended it.
///
/// The Recovery node below absorbs its child's failure and the run carries on,
/// so that failure is history by the time the target refuses to start. Naming
/// it as the reason would blame, say, a USB drop that reconnected at 21:00 for
/// a guider death at 03:00.
#[tokio::test]
async fn a_fault_the_run_recovered_from_is_not_the_reason_it_failed() {
    let mut sequence = SequenceDefinition::new("Survived then failed".to_string());
    sequence.nodes.push(crate::NodeDefinition {
        id: "root".to_string(),
        name: "Night".to_string(),
        node_type: crate::NodeType::TargetHeader(crate::TargetHeaderConfig {
            target_name: "Night".to_string(),
            ra_hours: 20.9629,
            dec_degrees: 40.0,
            ..Default::default()
        }),
        enabled: true,
        children: vec!["recovery".to_string(), "target".to_string()],
    });
    sequence.nodes.push(crate::NodeDefinition {
        id: "recovery".to_string(),
        name: "Recover and continue".to_string(),
        node_type: crate::NodeType::Recovery(crate::RecoveryConfig {
            trigger: None,
            recovery_action: crate::RecoveryAction::Continue,
            max_retries: 0,
        }),
        enabled: true,
        children: vec!["script".to_string()],
    });
    sequence.nodes.push(crate::NodeDefinition {
        id: "script".to_string(),
        name: "Run Script".to_string(),
        node_type: crate::NodeType::RunScript(crate::ScriptConfig {
            script_path: "/nonexistent/nightshade-test-script".to_string(),
            timeout_secs: Some(0),
            ..Default::default()
        }),
        enabled: true,
        children: vec![],
    });
    sequence.nodes.push(crate::NodeDefinition {
        id: "target".to_string(),
        name: "D3 Field".to_string(),
        node_type: crate::NodeType::TargetHeader(crate::TargetHeaderConfig {
            target_name: "D3 Field".to_string(),
            ra_hours: 20.9629,
            dec_degrees: 40.0,
            start_when: Some(crate::scheduling::TargetTrigger::AltitudeAbove(35.0)),
            ..Default::default()
        }),
        enabled: true,
        children: vec![],
    });
    sequence.root_node_id = Some("root".to_string());

    let mut executor = SequenceExecutor::new();
    executor.set_device_ops(Arc::new(crate::device_ops::NullDeviceOps));
    executor.load_sequence(sequence).expect("sequence loads");
    let mut events = executor.subscribe();

    executor.start().await.expect("run starts");

    for _ in 0..200 {
        if matches!(
            executor.get_state().await,
            ExecutorState::Completed | ExecutorState::Failed | ExecutorState::Cancelled
        ) {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
    }
    executor.stop().await.ok();

    let mut failure_reason = None;
    let mut survived = false;
    while let Ok(event) = events.try_recv() {
        match event {
            ExecutorEvent::SequenceFailed { error } => failure_reason = Some(error),
            ExecutorEvent::InstructionFailed { message, .. }
                if message.contains("timeout_secs must be greater than zero") =>
            {
                survived = true;
            }
            _ => {}
        }
    }
    assert!(
        survived,
        "the script must fail inside the Recovery node, or this test proves nothing"
    );
    let reason = failure_reason.expect("a failed run must publish a terminal failure reason");
    assert!(
        reason.contains("no observer location is set"),
        "the run failed on the target it could not evaluate, not on the fault it recovered \
         from; got: {reason}"
    );
}
