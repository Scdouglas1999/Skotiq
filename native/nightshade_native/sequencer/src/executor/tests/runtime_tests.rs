use super::*;

#[test]
fn test_executor_state_transitions() {
    let executor = SequenceExecutor::new();

    // Use tokio runtime for async tests
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();

    rt.block_on(async {
        assert_eq!(executor.get_state().await, ExecutorState::Idle);
    });
}

/// A finished run that leaves the executor parked in a terminal state, with
/// nothing to return it to `Idle`, refuses the second sequence of a night with
/// "Cannot start: executor is Completed" — one run per app launch, and the
/// desktop Start button shows nothing at all, because the native refusal is
/// rolled back by an immediate stop.
///
/// The assertion is on the error KIND, not on success: `start()` still bails
/// out later for want of a loaded sequence, which is exactly what this
/// bare executor should report.
#[tokio::test]
async fn start_recycles_a_terminal_executor_instead_of_refusing() {
    for terminal in [
        ExecutorState::Completed,
        ExecutorState::Failed,
        ExecutorState::Cancelled,
    ] {
        let mut executor = SequenceExecutor::new();
        executor.set_state(terminal).await;

        let err = executor
            .start()
            .await
            .expect_err("a bare executor has no sequence loaded");
        assert!(
            !err.contains("Cannot start"),
            "start() from {terminal:?} must recycle to Idle, not refuse; got: {err}"
        );
        assert_eq!(
            executor.get_state().await,
            ExecutorState::Idle,
            "{terminal:?} must be recycled to Idle by an explicit start"
        );
    }
}

/// The flip side: a start must NOT bulldoze a live run. Silently resetting
/// here would abandon a sequence that is mid-exposure.
#[tokio::test]
async fn start_still_refuses_a_busy_executor() {
    for busy in [
        ExecutorState::Running,
        ExecutorState::Paused,
        ExecutorState::Stopping,
        ExecutorState::Recovering,
    ] {
        let mut executor = SequenceExecutor::new();
        executor.set_state(busy).await;

        let err = executor.start().await.expect_err("busy must be refused");
        assert!(
            err.contains("Cannot start"),
            "start() during {busy:?} must be refused; got: {err}"
        );
        assert_eq!(
            executor.get_state().await,
            busy,
            "a refused start must leave {busy:?} untouched"
        );
    }
}

#[test]
fn test_progress_tracking() {
    let executor = SequenceExecutor::new();

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();

    rt.block_on(async {
        let progress = executor.get_progress();
        assert_eq!(progress.completed_exposures, 0);
        assert_eq!(progress.completed_integration_secs, 0.0);
        assert!(progress.current_node_id.is_none());
    });
}

#[test]
fn test_location_configuration() {
    let mut executor = SequenceExecutor::new();

    executor.set_location(Some(45.5), Some(-122.6));

    assert_eq!(executor.latitude, Some(45.5));
    assert_eq!(executor.longitude, Some(-122.6));
}

/// An unset observing site reaches the executor as `Some(0, 0)` (that is what
/// the persisted settings hold and what the bridge seeds). Accepting it as a
/// real site puts the rig on Null Island: the daylight gate refuses every
/// light frame of an Australian night quoting a Greenwich Sun altitude, and
/// the altitude limits gate on the wrong sky.
#[test]
fn null_island_is_an_unset_site_not_a_site_at_0n_0e() {
    let mut executor = SequenceExecutor::new();

    executor.set_location(Some(0.0), Some(0.0));

    assert_eq!(executor.latitude, None);
    assert_eq!(executor.longitude, None);
}

#[tokio::test]
async fn update_location_also_rejects_null_island() {
    let mut executor = SequenceExecutor::new();
    executor.update_location(Some(0.0), Some(0.0)).await;

    assert_eq!(executor.latitude, None);
    assert_eq!(executor.longitude, None);
    let handle = executor.runtime_config_handle();
    let rc = handle.read();
    assert_eq!(rc.latitude, None);
    assert_eq!(rc.longitude, None);
}

#[test]
fn safety_fail_mode_updates_runtime_config() {
    let mut executor = SequenceExecutor::new();

    executor.set_safety_fail_mode(crate::SafetyFailMode::WarnOnly);

    assert_eq!(executor.safety_fail_mode, crate::SafetyFailMode::WarnOnly);
    assert_eq!(
        executor.runtime_config.read().safety_fail_mode,
        crate::SafetyFailMode::WarnOnly
    );
}

#[test]
fn safety_check_interval_is_clamped_and_defaulted() {
    assert_eq!(
        effective_safety_check_interval_secs(0),
        DEFAULT_SAFETY_CHECK_INTERVAL_SECS
    );
    assert_eq!(effective_safety_check_interval_secs(3), 5);
    assert_eq!(effective_safety_check_interval_secs(45), 45);
    assert_eq!(effective_safety_check_interval_secs(9999), 3600);
}

/// One half of the pinned cross-language fail-mode truth table; the Dart half
/// is `weather_fail_mode_parity_test.dart`. BOTH must encode the identical
/// rows:
///
///   FailClosed -> Unsafe  (Rust: weather_safe=false; Dart verdict: Some(true))
///   FailOpen   -> Safe    (Rust: weather_safe=true;  Dart verdict: None/abstain)
///   WarnOnly   -> Preserve(Rust: weather_safe unchanged; Dart verdict: None/abstain)
///
/// The single shared definition is `safety_fail_mode_no_data_resolution`
/// (consumed by the executor safety poll), mirrored in Dart as
/// `noDataFailModeResolution`. A row changed here must be changed in the Dart
/// test too, or the two implementations have silently drifted.
#[test]
fn safety_fail_mode_no_data_resolution_truth_table() {
    assert_eq!(
        safety_fail_mode_no_data_resolution(SafetyFailMode::FailClosed),
        NoDataResolution::Unsafe,
        "failClosed must resolve no-data as UNSAFE"
    );
    assert_eq!(
        safety_fail_mode_no_data_resolution(SafetyFailMode::FailOpen),
        NoDataResolution::Safe,
        "failOpen must resolve no-data as SAFE"
    );
    assert_eq!(
        safety_fail_mode_no_data_resolution(SafetyFailMode::WarnOnly),
        NoDataResolution::Preserve,
        "warnOnly must resolve no-data as PRESERVE (last reading wins)"
    );
}

/// `MountTrackingLost` must be edge-triggered, not
/// level-triggered. The trigger monitor arms `mount_tracking_expected` at
/// startup before the mount has begun tracking, so a not-yet-tracking poll
/// (`previously_tracking` is `None`, or the mount is still parked) must NOT
/// be reported as a loss — otherwise a loaded sequence self-cancels ~1.5 s
/// after start, immune to `safety_fail_mode = FailOpen` because this is a
/// mount trigger rather than a weather one.
#[test]
fn mount_tracking_loss_is_edge_triggered_not_level_triggered() {
    // First poll: expected armed, mount reports not tracking, no prior
    // reading. This is the not-yet-tracking condition — must NOT flag a loss.
    assert!(
        !mount_tracking_just_lost(true, false, None, false),
        "a not-yet-tracking mount on the first poll must not be 'lost'"
    );

    // Still parked / not tracking after the first poll recorded `false`.
    assert!(
        !mount_tracking_just_lost(true, false, Some(false), false),
        "a mount that was never tracking must not be reported as 'lost'"
    );

    // The genuine case the trigger exists for: tracking was ON, now OFF.
    assert!(
        mount_tracking_just_lost(true, false, Some(true), false),
        "a true -> false transition is a real tracking loss"
    );

    // Already flagged — don't re-flag (idempotent within a loss episode).
    assert!(
        !mount_tracking_just_lost(true, false, Some(true), true),
        "loss must not be re-flagged once already recorded"
    );

    // Tracking healthy — never a loss regardless of history.
    assert!(!mount_tracking_just_lost(true, true, Some(true), false));

    // Not expected (no mount configured / detector disarmed) — never a loss.
    assert!(!mount_tracking_just_lost(false, false, Some(true), false));
}

/// Subsystem 2 step 3: the weather-verdict staleness window resolver
/// defaults a `0` to the documented default and clamps non-zero values to a
/// sane floor/ceiling so a misconfiguration cannot make every tick warn or
/// disable the observability.
#[test]
fn weather_verdict_staleness_is_clamped_and_defaulted() {
    assert_eq!(
        effective_weather_verdict_staleness_secs(0),
        DEFAULT_WEATHER_VERDICT_STALENESS_SECS
    );
    assert_eq!(effective_weather_verdict_staleness_secs(5), 30);
    assert_eq!(effective_weather_verdict_staleness_secs(600), 600);
    assert_eq!(effective_weather_verdict_staleness_secs(1_000_000), 86_400);
}

/// Subsystem 2 step 3: the stale-unsafe verdict warning EMITS on the rising
/// edge, is RATE-LIMITED while the feed stays stale, and RE-ARMS once a fresh
/// verdict clears the stale condition. This is the "emits the warning" half
/// of the stale-verdict requirement (the "stays unsafe / does NOT resume"
/// half is pinned by `triggers.rs`
/// `weather_verdict_stale_unsafe_stays_unsafe_and_is_detected`).
#[test]
fn weather_verdict_stale_warning_emits_once_then_rearms() {
    let mut warned = false;

    // Not stale -> no warning, latch stays disarmed.
    assert!(weather_verdict_stale_warning(false, 360, &mut warned).is_none());
    assert!(!warned);

    // Rising edge (stale & unsafe) -> emit, latch arms, message carries the
    // fail-closed framing + the staleness window.
    let msg = weather_verdict_stale_warning(true, 360, &mut warned)
        .expect("stale unsafe verdict must emit a warning on the rising edge");
    assert!(warned, "latch must arm after emitting");
    assert!(
        msg.contains("stale") && msg.contains("paused") && msg.contains("360"),
        "warning must name the stale fail-closed hold + the window: {msg}"
    );

    // Still stale -> rate-limited (no repeat while the feed stays dead).
    assert!(
        weather_verdict_stale_warning(true, 360, &mut warned).is_none(),
        "a still-stale verdict must not re-warn every poll"
    );
    assert!(warned);

    // Fresh / no-longer-unsafe -> re-arm, no warning.
    assert!(weather_verdict_stale_warning(false, 360, &mut warned).is_none());
    assert!(!warned, "latch must re-arm once the condition clears");

    // A subsequent stale episode warns again (proves re-arm works).
    assert!(
        weather_verdict_stale_warning(true, 360, &mut warned).is_some(),
        "a fresh stale episode after clearing must warn again"
    );
}

#[test]
fn safety_check_interval_updates_runtime_config() {
    let mut executor = SequenceExecutor::new();

    executor.set_safety_check_interval_secs(45);

    assert_eq!(
        executor.runtime_config.read().safety_check_interval_secs,
        45
    );

    executor.set_safety_check_interval_secs(3);

    assert_eq!(executor.runtime_config.read().safety_check_interval_secs, 5);
}

#[test]
fn test_save_path_configuration() {
    let mut executor = SequenceExecutor::new();

    executor.set_save_path(Some(std::path::PathBuf::from("/tmp/images")));

    assert!(executor.save_path.is_some());
}

#[test]
fn test_get_set_state() {
    let executor = SequenceExecutor::new();

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();

    rt.block_on(async {
        // Test state transitions
        assert_eq!(executor.get_state().await, ExecutorState::Idle);

        executor.set_state(ExecutorState::Running).await;
        assert_eq!(executor.get_state().await, ExecutorState::Running);

        executor.set_state(ExecutorState::Paused).await;
        assert_eq!(executor.get_state().await, ExecutorState::Paused);

        executor.set_state(ExecutorState::Stopping).await;
        assert_eq!(executor.get_state().await, ExecutorState::Stopping);

        executor.set_state(ExecutorState::Completed).await;
        assert_eq!(executor.get_state().await, ExecutorState::Completed);
    });
}

#[test]
fn test_executor_state_debug() {
    // Test Debug trait (which is derived)
    assert_eq!(format!("{:?}", ExecutorState::Idle), "Idle");
    assert_eq!(format!("{:?}", ExecutorState::Running), "Running");
    assert_eq!(format!("{:?}", ExecutorState::Paused), "Paused");
    assert_eq!(format!("{:?}", ExecutorState::Stopping), "Stopping");
    assert_eq!(format!("{:?}", ExecutorState::Cancelled), "Cancelled");
    assert_eq!(format!("{:?}", ExecutorState::Completed), "Completed");
}

#[test]
fn test_node_status_debug() {
    // Test Debug trait (which is derived)
    assert_eq!(format!("{:?}", NodeStatus::Pending), "Pending");
    assert_eq!(format!("{:?}", NodeStatus::Running), "Running");
    assert_eq!(format!("{:?}", NodeStatus::Success), "Success");
    assert_eq!(format!("{:?}", NodeStatus::Failure), "Failure");
    assert_eq!(format!("{:?}", NodeStatus::Skipped), "Skipped");
}

#[test]
fn test_executor_default() {
    let executor = SequenceExecutor::default();
    assert!(executor.sequence.is_none());
}

#[test]
fn test_executor_state_for_result_keeps_cancelled_distinct() {
    assert_eq!(
        executor_state_for_result(NodeStatus::Cancelled),
        ExecutorState::Cancelled
    );
    assert_eq!(
        executor_state_for_result(NodeStatus::Success),
        ExecutorState::Completed
    );
}

#[test]
fn test_trigger_autofocus_context_preserves_runtime_metadata() {
    let trigger_context = TriggerActionContext {
        camera_id: Some("camera".to_string()),
        mount_id: Some("mount".to_string()),
        focuser_id: Some("focuser".to_string()),
        filterwheel_id: Some("wheel".to_string()),
        rotator_id: Some("rotator".to_string()),
        dome_id: Some("dome".to_string()),
        cover_calibrator_id: Some("panel".to_string()),
        save_path: Some(PathBuf::from("C:/captures")),
        latitude: Some(45.0),
        longitude: Some(-122.0),
        filter_focus_offsets: HashMap::from([("Ha".to_string(), 42)]),
    };
    let runtime_config = Arc::new(StdRwLock::new(RuntimeConfig::default()));
    let instruction_ctx = build_trigger_autofocus_context(
        &trigger_context,
        Some("M31".to_string()),
        Some(1.25),
        Some(41.0),
        Some("Ha".to_string()),
        Arc::new(AtomicBool::new(false)),
        Arc::new(crate::device_ops::NullDeviceOps),
        Arc::new(RwLock::new(TriggerState::new())),
        &runtime_config,
        None,
    );

    assert_eq!(instruction_ctx.target_name.as_deref(), Some("M31"));
    assert_eq!(
        instruction_ctx.save_path,
        Some(PathBuf::from("C:/captures"))
    );
    assert_eq!(instruction_ctx.latitude, Some(45.0));
    assert_eq!(instruction_ctx.longitude, Some(-122.0));
    assert_eq!(instruction_ctx.filter_focus_offsets.get("Ha"), Some(&42));
}

#[test]
fn test_trigger_flip_context_keeps_focuser_id() {
    let trigger_context = TriggerActionContext {
        mount_id: Some("mount".to_string()),
        camera_id: Some("camera".to_string()),
        focuser_id: Some("focuser".to_string()),
        ..TriggerActionContext::default()
    };

    let flip_ctx = build_trigger_flip_context(
        &trigger_context,
        TriggerFlipTarget {
            name: "M42".to_string(),
            ra_hours: Some(5.5),
            dec_degrees: Some(-5.0),
        },
        None,
        None,
        None,
        None,
    )
    .expect("flip context should be created");

    assert_eq!(flip_ctx.focuser_id.as_deref(), Some("focuser"));
    assert_eq!(flip_ctx.mount_id, "mount");
}

#[test]
fn trigger_flip_context_preserves_real_autofocus_config() {
    let trigger_context = TriggerActionContext {
        mount_id: Some("mount".to_string()),
        filterwheel_id: Some("wheel".to_string()),
        filter_focus_offsets: HashMap::from([("L".to_string(), 0), ("Ha".to_string(), 180)]),
        ..TriggerActionContext::default()
    };
    let autofocus_config = crate::AutofocusConfig {
        filter: Some("Ha".to_string()),
        step_size: 275,
        exposure_duration: 6.5,
        backlash_compensation: 180,
        ..crate::AutofocusConfig::default()
    };

    let flip_ctx = build_trigger_flip_context(
        &trigger_context,
        TriggerFlipTarget {
            name: "M42".to_string(),
            ra_hours: Some(5.5),
            dec_degrees: Some(-5.0),
        },
        None,
        None,
        Some(autofocus_config),
        Some("L".to_string()),
    )
    .expect("flip context should be created");

    let observed = flip_ctx
        .autofocus_config
        .expect("runtime autofocus config must reach the flip executor");
    assert_eq!(observed.config.filter.as_deref(), Some("Ha"));
    assert_eq!(observed.config.step_size, 275);
    assert!((observed.config.exposure_duration - 6.5).abs() < f64::EPSILON);
    assert_eq!(observed.config.backlash_compensation, 180);
    assert_eq!(observed.current_filter.as_deref(), Some("L"));
    assert_eq!(observed.filterwheel_id.as_deref(), Some("wheel"));
    assert_eq!(observed.filter_focus_offsets.get("Ha"), Some(&180));
}

#[test]
fn skip_to_node_acceptance_is_not_an_error_event() {
    let event = skip_to_node_accepted_event("target-node".to_string());

    assert!(
        !matches!(event, ExecutorEvent::Error { .. }),
        "an accepted SkipToNode command must not enter error/recovery UX"
    );
    match event {
        ExecutorEvent::NodeProgress {
            node_id,
            instruction,
            progress_percent,
            ..
        } => {
            assert_eq!(node_id, "target-node");
            assert_eq!(instruction, "SkipToNode");
            assert_eq!(progress_percent, 100.0);
        }
        other => panic!("expected a non-error skip acknowledgment, got {other:?}"),
    }
}

#[tokio::test]
async fn park_and_abort_cancels_and_quiesces_before_safe_state_work() {
    let is_cancelled = Arc::new(AtomicBool::new(false));
    let ordering = Arc::new(std::sync::Mutex::new(Vec::new()));
    let (quiesced_tx, mut quiesced_rx) = watch::channel(false);

    let cancellation_for_instruction = is_cancelled.clone();
    let ordering_for_instruction = ordering.clone();
    let instruction = tokio::spawn(async move {
        while !cancellation_for_instruction.load(Ordering::Acquire) {
            tokio::task::yield_now().await;
        }
        ordering_for_instruction
            .lock()
            .unwrap()
            .push("camera_abort");
        let _ = quiesced_tx.send(true);
    });

    cancel_and_wait_for_execution(&is_cancelled, &mut quiesced_rx).await;
    ordering.lock().unwrap().push("park");
    instruction.await.unwrap();

    assert!(is_cancelled.load(Ordering::Acquire));
    assert_eq!(
        *ordering.lock().unwrap(),
        vec!["camera_abort", "park"],
        "camera cancellation cleanup must finish before park/close begins"
    );
}

#[tokio::test]
async fn stop_waits_for_executor_cleanup_acknowledgment() {
    let mut executor = SequenceExecutor::new();
    let (command_tx, mut command_rx) = mpsc::channel(1);
    let (completion_tx, completion_rx) = oneshot::channel();
    let cleanup_confirmed = Arc::new(AtomicBool::new(false));
    executor.command_tx = Some(command_tx);
    executor.run_completion_rx = Some(completion_rx);

    let cancellation = executor.is_cancelled.clone();
    let cleanup_confirmed_for_task = cleanup_confirmed.clone();
    let simulated_executor = tokio::spawn(async move {
        assert!(matches!(
            command_rx.recv().await,
            Some(ExecutorCommand::Stop)
        ));
        assert!(
            cancellation.load(Ordering::Acquire),
            "Stop must signal cancellation before the command is handled"
        );
        cleanup_confirmed_for_task.store(true, Ordering::Release);
        let _ = completion_tx.send(());
    });

    executor.stop().await.expect("Stop should be confirmed");
    simulated_executor.await.unwrap();

    assert!(
        cleanup_confirmed.load(Ordering::Acquire),
        "stop() must not return before executor cleanup is acknowledged"
    );
    assert!(executor.command_tx.is_none());
    assert!(executor.run_completion_rx.is_none());
}

/// `terminate_with` must always set the cancellation flag
/// before returning. Future RecoveryAction variants that exit through
/// this helper inherit the invariant by construction.
#[test]
fn terminate_with_sets_is_cancelled_before_returning_triggers() {
    let flag = Arc::new(AtomicBool::new(false));
    let triggers = vec![
        ("trig_a".to_string(), RecoveryAction::ParkAndAbort),
        ("trig_b".to_string(), RecoveryAction::Pause),
    ];
    let returned = terminate_with(&flag, triggers, "unit-test");
    assert!(
        flag.load(Ordering::Relaxed),
        "terminate_with must store true into is_cancelled"
    );
    assert_eq!(returned.len(), 2);
    assert_eq!(returned[0].0, "trig_a");
    assert_eq!(returned[1].0, "trig_b");
}

/// A failed autofocus is judged on what the frames measure, not on the
/// fact that the sweep failed. Slightly-soft frames stack and deconvolve
/// fine; donuts are wasted disk.
#[test]
fn autofocus_failure_is_judged_on_hfr_not_on_the_failure() {
    // Soft but usable: a run whose good HFR is 2.5 keeps imaging at 3.8.
    assert_eq!(
        autofocus_failure_verdict(Some(2.5), Some(3.8), 1.6),
        AutofocusOutcome::KeepImaging {
            current_hfr: 3.8,
            limit: 4.0
        }
    );

    // Donuts: the same rig at HFR 10 is not producing anything worth
    // keeping, and an unattended night should stop rather than fill the
    // disk.
    assert!(matches!(
        autofocus_failure_verdict(Some(2.5), Some(10.0), 1.6),
        AutofocusOutcome::TooSoft { .. }
    ));

    // The boundary belongs to the operator: exactly at the limit keeps
    // imaging, a hair past it does not.
    assert!(matches!(
        autofocus_failure_verdict(Some(2.0), Some(4.0), 2.0),
        AutofocusOutcome::KeepImaging { .. }
    ));
    assert!(matches!(
        autofocus_failure_verdict(Some(2.0), Some(4.001), 2.0),
        AutofocusOutcome::TooSoft { .. }
    ));

    // A tighter tolerance rejects what a looser one accepts — the setting
    // has to actually move the decision, or it is decoration.
    assert!(matches!(
        autofocus_failure_verdict(Some(2.5), Some(3.8), 1.2),
        AutofocusOutcome::TooSoft { .. }
    ));
}

/// Never claim the frames are fine on the strength of no evidence: that
/// is how an unattended night fills a disk with donuts. Missing or absurd
/// inputs report Unmeasurable so the failure action decides knowing the
/// focus is unknown.
#[test]
fn autofocus_verdict_refuses_to_guess() {
    for (reference, current) in [
        (None, Some(3.0)),
        (Some(2.5), None),
        (None, None),
        (Some(0.0), Some(3.0)),
        (Some(2.5), Some(0.0)),
        (Some(f64::NAN), Some(3.0)),
        (Some(2.5), Some(f64::INFINITY)),
    ] {
        assert_eq!(
            autofocus_failure_verdict(reference, current, 1.6),
            AutofocusOutcome::Unmeasurable,
            "reference {reference:?} / current {current:?} must not produce a verdict"
        );
    }

    // Zero or negative disables the tolerance entirely: every failure is
    // then unrecoverable, which is the behaviour this setting replaced.
    assert_eq!(
        autofocus_failure_verdict(Some(2.5), Some(2.6), 0.0),
        AutofocusOutcome::Unmeasurable
    );
    assert_eq!(
        autofocus_failure_verdict(Some(2.5), Some(2.6), -1.0),
        AutofocusOutcome::Unmeasurable
    );
}

/// A trigger-fired autofocus that starts while the capture loop is
/// mid-frame destroys that frame — the loop's download finds the camera
/// empty ("No exposure is available to download"), the exposure node
/// fails, and the sequential parent takes the run with it. That happened
/// at frame 25 of every run, the default autofocus cadence.
#[tokio::test]
async fn camera_idle_wait_holds_for_an_exposure_then_releases() {
    let state = Arc::new(RwLock::new(crate::triggers::TriggerState::new()));
    let cancelled = Arc::new(AtomicBool::new(false));

    // Nothing in flight: the action must not be delayed at all.
    let started = tokio::time::Instant::now();
    let idle_token = claim_camera_for_trigger_action(&state, &cancelled, "autofocus")
        .await
        .expect("an idle imaging train must be claimable");
    assert!(
        started.elapsed() < std::time::Duration::from_millis(100),
        "an idle camera must not delay a trigger action"
    );
    // Hand it back before simulating a frame. The old API let the capture loop
    // overwrite a live trigger claim outright, which is the frame-destroying
    // race the claim exists to close; the token-based API refuses instead, so
    // the release has to be real.
    state.write().await.release_imaging_train(idle_token);

    // A frame in flight holds the action until the frame releases it.
    let frame_token = state
        .write()
        .await
        .try_claim_imaging_train("the next exposure", 30.0)
        .expect("an idle imaging train must be claimable");
    assert!(
        state
            .read()
            .await
            .imaging_train_hold()
            .is_some_and(|hold| hold.expected_remaining_secs > 30.0),
        "the claim's expected finish must cover the exposure plus download slack"
    );

    let release_state = state.clone();
    tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        release_state
            .write()
            .await
            .release_imaging_train(frame_token);
    });

    let started = tokio::time::Instant::now();
    claim_camera_for_trigger_action(&state, &cancelled, "autofocus").await;
    let waited = started.elapsed();
    assert!(
        waited >= std::time::Duration::from_millis(250),
        "the action must wait for the in-flight frame, waited {waited:?}"
    );
    assert!(
        waited < std::time::Duration::from_secs(5),
        "the action must run as soon as the frame releases, not sit out the \
         whole 30s claim; waited {waited:?}"
    );
}

/// An operator Stop must not have to wait out a 10-minute sub.
#[tokio::test]
async fn camera_idle_wait_releases_immediately_on_cancel() {
    let state = Arc::new(RwLock::new(crate::triggers::TriggerState::new()));
    let cancelled = Arc::new(AtomicBool::new(false));
    state
        .write()
        .await
        .try_claim_imaging_train("the next exposure", 600.0)
        .expect("an idle imaging train must be claimable");

    let flag = cancelled.clone();
    tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        flag.store(true, Ordering::Relaxed);
    });

    let started = tokio::time::Instant::now();
    claim_camera_for_trigger_action(&state, &cancelled, "autofocus").await;
    assert!(
        started.elapsed() < std::time::Duration::from_secs(5),
        "a cancelled sequence must release the wait immediately"
    );
}

/// The claim lapses rather than latching, so a holder that died without
/// releasing costs minutes, not the night.
#[tokio::test]
async fn imaging_train_claim_expires_rather_than_wedging() {
    let mut state = crate::triggers::TriggerState::new();
    state
        .try_claim_imaging_train("the next exposure", 30.0)
        .expect("an idle imaging train must be claimable");
    let claim = state
        .imaging_train_claim
        .as_mut()
        .expect("the claim was just installed");
    claim.expires_at_ms = chrono::Utc::now().timestamp_millis() - 1;
    assert!(
        state.imaging_train_hold().is_none(),
        "a claim past its hard expiry must read as free"
    );
}

/// An estimate that runs a little long must NOT hand the devices over.
///
/// This is the measured defect the two-deadline design fixes. The old claim
/// used `duration + 20 s` as both the estimate and the expiry, so a 180 s light
/// whose readout overran released the camera while the sensor was still
/// integrating; a drift-recenter trigger then started its own 5 s plate-solve
/// exposure on the busy camera and failed on `did not complete within 65.0s
/// timeout (5.0s requested exposure plus safety margin)` — a bound derived from
/// its own request, with no relationship to the 180 s frame it was queued
/// behind.
#[tokio::test]
async fn an_overrunning_exposure_keeps_the_imaging_train() {
    let mut state = crate::triggers::TriggerState::new();
    state
        .try_claim_imaging_train("the next exposure", 180.0)
        .expect("an idle imaging train must be claimable");

    // Walk the clock past the 180 s + 20 s estimate, as a slow download does.
    let claim = state
        .imaging_train_claim
        .as_mut()
        .expect("the claim was just installed");
    claim.expected_finish_ms = chrono::Utc::now().timestamp_millis() - 25_000;

    let hold = state
        .imaging_train_hold()
        .expect("an overrunning holder still holds the imaging train");
    assert_eq!(
        hold.expected_remaining_secs, 0.0,
        "the estimate has passed, and the hold says so honestly"
    );
    assert!(
        hold.max_remaining_secs > 0.0,
        "but the claim has NOT lapsed, so the camera cannot be taken mid-frame"
    );
    assert!(
        state.try_claim_imaging_train("recenter", 5.0).is_none(),
        "a waiting trigger must not be handed a camera that is still exposing"
    );
}

/// The claim covers the filter wheel as well as the camera, as one resource.
///
/// Arbitrating the camera alone is what produced the 2026-09-14 filter-wheel
/// timeout: the autofocus trigger held the camera and commanded the wheel to
/// "L" (position 0) while the capture loop had already commanded it to "SII"
/// (position 5), and autofocus then polled a healthy, idle wheel for 120 s for
/// a position nothing was going to move it to.
#[tokio::test]
async fn the_imaging_train_claim_covers_the_filter_wheel_too() {
    let mut state = crate::triggers::TriggerState::new();
    let token = state
        .try_claim_imaging_train("autofocus", 600.0)
        .expect("an idle imaging train must be claimable");
    assert!(
        state
            .try_claim_imaging_train("the capture loop's filter change", 30.0)
            .is_none(),
        "the capture loop must not be able to move the wheel while autofocus holds the train"
    );
    state.release_imaging_train(token);
    assert!(
        state
            .try_claim_imaging_train("the capture loop's filter change", 30.0)
            .is_some(),
        "and it must get the wheel the moment autofocus hands it back"
    );
}

/// A stale release must not free somebody else's claim — doing so destroys
/// exactly the frame the claim exists to protect.
#[tokio::test]
async fn a_stale_release_cannot_free_a_newer_claim() {
    let mut state = crate::triggers::TriggerState::new();
    let first = state
        .try_claim_imaging_train("autofocus", 600.0)
        .expect("an idle imaging train must be claimable");
    state.release_imaging_train(first);
    let second = state
        .try_claim_imaging_train("the next exposure", 180.0)
        .expect("the train is free again");
    assert_ne!(first, second, "tokens are never reused");

    state.release_imaging_train(first);
    assert!(
        state.imaging_train_hold().is_some(),
        "a release presenting a stale token must do nothing"
    );
    state.release_imaging_train(second);
    assert!(
        state.imaging_train_hold().is_none(),
        "the real holder's release works"
    );
}

#[test]
fn trigger_action_in_flight_guard_sets_and_clears_on_every_exit() {
    let flag = Arc::new(AtomicBool::new(false));

    // Normal scope exit.
    {
        let _guard = TriggerActionInFlightGuard::new(&flag);
        assert!(
            flag.load(Ordering::Acquire),
            "guard must latch the flag while the action runs"
        );
    }
    assert!(
        !flag.load(Ordering::Acquire),
        "guard must clear the flag on normal scope exit"
    );

    // Early return out of the guarded scope (mirrors
    // `return terminate_with(...)` inside the action dispatch).
    fn early_return(flag: &Arc<AtomicBool>) -> &'static str {
        let _guard = TriggerActionInFlightGuard::new(flag);
        // The branch keeps this a *real* early return (not a tail
        // expression), which is the shape under test; it also proves the
        // guard has already latched at the return point.
        if flag.load(Ordering::Acquire) {
            return "terminated";
        }
        "guard never latched"
    }
    assert_eq!(early_return(&flag), "terminated");
    assert!(
        !flag.load(Ordering::Acquire),
        "guard must clear the flag when the dispatch returns early"
    );

    // Unwind (a panicking device call must not wedge the latch).
    let unwound = std::panic::catch_unwind({
        let flag = flag.clone();
        move || {
            let _guard = TriggerActionInFlightGuard::new(&flag);
            panic!("device blew up mid-action");
        }
    });
    assert!(unwound.is_err(), "the closure was expected to panic");
    assert!(
        !flag.load(Ordering::Acquire),
        "guard must clear the flag while unwinding a panic"
    );
}

/// The quiesce budget must comfortably exceed the shipped default meridian
/// retry ladder (30 s + 60 s + 120 s of waiting plus four flip attempts).
/// Shrinking it below the ladder abandons a perfectly normal retry sequence
/// to the timeout instead of awaiting it — the orphaned-retry defect through
/// the back door.
#[test]
fn trigger_action_quiesce_budget_covers_the_default_retry_ladder() {
    let default_retry_wait_secs: u64 = 30 + 60 + 120;
    assert!(
        TRIGGER_ACTION_QUIESCE_MAX_SECS > default_retry_wait_secs * 2,
        "quiesce budget {}s must leave room for the {}s default retry \
         ladder plus the flip attempts themselves",
        TRIGGER_ACTION_QUIESCE_MAX_SECS,
        default_retry_wait_secs
    );
}

/// `update_dither_config` must write through the shared
/// `runtime_config` Arc so the next dither uses the new pixel count.
/// A `let _` on the parameters here is a silent fallback: the call is
/// accepted and nothing changes.
#[tokio::test]
async fn update_dither_config_writes_through_runtime_config() {
    let mut executor = SequenceExecutor::new();
    executor
        .update_dither_config(7.5, 0.5, 8.0, 60.0, true)
        .await;
    let handle = executor.runtime_config_handle();
    let rc = handle.read();
    assert!((rc.dither.pixels - 7.5).abs() < f64::EPSILON);
    assert!((rc.dither.settle_pixels - 0.5).abs() < f64::EPSILON);
    assert!((rc.dither.settle_time - 8.0).abs() < f64::EPSILON);
    assert!((rc.dither.settle_timeout - 60.0).abs() < f64::EPSILON);
    assert!(rc.dither.ra_only);
}

/// `update_location` must update the executor's own fields (used by
/// next-start seeding), the runtime_config Arc, and — for an idle
/// executor, which has no task to send a command to — the trigger state
/// the altitude/dawn/meridian evaluators read.
#[tokio::test]
async fn update_location_writes_through_runtime_config() {
    let mut executor = SequenceExecutor::new();
    executor.update_location(Some(40.7), Some(-74.0)).await;
    assert_eq!(executor.latitude, Some(40.7));
    assert_eq!(executor.longitude, Some(-74.0));
    {
        let handle = executor.runtime_config_handle();
        let rc = handle.read();
        assert_eq!(rc.latitude, Some(40.7));
        assert_eq!(rc.longitude, Some(-74.0));
    }
    let manager = executor.trigger_manager.read().await;
    let state = manager.state();
    let guard = state.read().await;
    assert_eq!(guard.observer_latitude, Some(40.7));
    assert_eq!(guard.observer_longitude, Some(-74.0));
}

/// R2: `update_location` wrote `runtime_config` and the executor's own
/// fields and stopped there. The live `TriggerState` — the only place
/// `AltitudeLimit`, `DawnApproaching` and the meridian hour-angle read the
/// observer's position from — was written by exactly one code path, the
/// `ExecutorCommand::UpdateLocation` arm, which had no sender anywhere in
/// the workspace. So a mid-run location change reached nothing, and the
/// method's own doc comment claimed it did.
#[tokio::test]
async fn a_mid_run_location_change_reaches_the_altitude_dawn_and_meridian_inputs() {
    const NEW_YORK: (f64, f64) = (40.71, -74.01);
    const SYDNEY: (f64, f64) = (-33.87, 151.21);

    let mut sequence = SequenceDefinition::new("New Sequence".to_string());
    sequence.nodes.push(crate::NodeDefinition {
        id: "target".to_string(),
        name: "Target".to_string(),
        node_type: crate::NodeType::TargetHeader(crate::TargetHeaderConfig {
            // The pole's altitude equals observer latitude at every sidereal
            // time. An ordinary target can have nearly equal altitudes at
            // these two sites, so an arbitrary minimum difference is flaky.
            target_name: "North celestial pole".to_string(),
            ra_hours: 0.712,
            dec_degrees: 90.0,
            ..crate::TargetHeaderConfig::default()
        }),
        enabled: true,
        children: vec!["wait".to_string()],
    });
    sequence.nodes.push(crate::NodeDefinition {
        id: "wait".to_string(),
        name: "Wait".to_string(),
        // Long enough that the 1 Hz trigger monitor gets many ticks; the
        // test stops the run as soon as it has its evidence.
        node_type: crate::NodeType::Delay(crate::DelayConfig { seconds: 30.0 }),
        enabled: true,
        children: vec![],
    });
    sequence.root_node_id = Some("target".to_string());

    let mut executor = SequenceExecutor::new();
    executor.set_device_ops(Arc::new(crate::device_ops::NullDeviceOps));
    // The poll phase (what this test is about) runs before trigger
    // dispatch, so dropping the action triggers keeps the run from being
    // steered by an AltitudeLimit/MeridianFlip firing mid-assertion.
    {
        let mut manager = executor.trigger_manager.write().await;
        for id in ["altitude_limit", "meridian_flip", "hfr_degraded"] {
            manager.remove_trigger(id);
        }
    }
    executor.load_sequence(sequence).expect("sequence loads");
    executor.start().await.expect("run starts");

    async fn wait_for(
        executor: &SequenceExecutor,
        what: &str,
        predicate: impl Fn(&TriggerState) -> bool,
    ) -> TriggerState {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
        loop {
            let snapshot = {
                let manager = executor.trigger_manager.read().await;
                let state = manager.state();
                let guard = state.read().await;
                guard.clone()
            };
            if predicate(&snapshot) {
                return snapshot;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "timed out waiting for {what}"
            );
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
    }

    executor
        .update_location(Some(NEW_YORK.0), Some(NEW_YORK.1))
        .await;
    let first = wait_for(&executor, "the pushed New York location", |s| {
        s.observer_latitude == Some(NEW_YORK.0)
            && s.dawn_time.is_some()
            && s.current_altitude.is_some()
    })
    .await;

    executor
        .update_location(Some(SYDNEY.0), Some(SYDNEY.1))
        .await;
    // `dawn_time.is_some()` matters: the push invalidates the cache, and it
    // is the monitor's NEXT tick that recomputes it for the new site.
    // Waiting only for "different" would accept the transient `None`.
    let second = wait_for(&executor, "dawn recomputed for Sydney", |s| {
        s.observer_latitude == Some(SYDNEY.0)
            && s.dawn_time.is_some()
            && s.dawn_time != first.dawn_time
    })
    .await;

    executor.stop().await.ok();

    assert_eq!(
        second.observer_longitude,
        Some(SYDNEY.1),
        "the meridian hour-angle is computed from TriggerState::observer_longitude, \
         so a location change that never lands there flips on the old site"
    );
    assert_ne!(
        second.dawn_time, first.dawn_time,
        "DawnApproaching reads TriggerState::dawn_time; a cached dawn from the \
         previous site would stop the run at the wrong hour"
    );
    for (snapshot, latitude) in [(&first, NEW_YORK.0), (&second, SYDNEY.0)] {
        assert!(
            snapshot
                .current_altitude
                .is_some_and(|altitude| (altitude - latitude).abs() < 0.001),
            "pole altitude must be recomputed for observer latitude {latitude}: {:?}",
            snapshot.current_altitude,
        );
    }
}

/// Every production device call in the trigger monitor is bounded. A driver
/// that accepts a call and never answers — a documented ASCOM hazard — parks
/// the monitor's loop forever, and parking is not an exit, so the `select!`
/// that joins the monitor never notices: the execution branch keeps exposing
/// with weather, altitude, drift, tracking-loss, dome and meridian protection
/// all silently gone.
///
/// A stalled poll is a poll FAILURE, which is a verdict the trigger state
/// already has a field for and the evaluators already know how to read.
#[tokio::test]
async fn a_hung_device_poll_is_reported_as_a_failure_instead_of_parking_the_monitor() {
    let mut sequence = SequenceDefinition::new("New Sequence".to_string());
    sequence.nodes.push(crate::NodeDefinition {
        id: "wait".to_string(),
        name: "Wait".to_string(),
        node_type: crate::NodeType::Delay(crate::DelayConfig { seconds: 120.0 }),
        enabled: true,
        children: vec![],
    });
    sequence.root_node_id = Some("wait".to_string());

    let mut executor = SequenceExecutor::new();
    executor.set_device_ops(Arc::new(
        ReacquireGuiderOps::new(false, false).with_hanging_tracking_poll(),
    ));
    executor.set_devices(None, Some("mount-1".to_string()), None, None, None);
    executor.load_sequence(sequence).expect("sequence loads");
    executor.start().await.expect("run starts");

    // Generous next to the 10 s poll bound, tight next to "never".
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(40);
    let mut query_failed = false;
    while std::time::Instant::now() < deadline {
        {
            let manager = executor.trigger_manager.read().await;
            let state = manager.state();
            if state.read().await.mount_status_query_failed {
                query_failed = true;
                break;
            }
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    executor.stop().await.ok();

    assert!(
        query_failed,
        "the monitor never got past the hung mount poll, so every protection it \
         enforces was off and nothing said so"
    );
}

/// The bound itself, stated once so the message a stalled poll produces is
/// pinned: it must name the call, because "some poll timed out" is not
/// something an operator can act on at 3am.
#[tokio::test(start_paused = true)]
async fn a_device_poll_that_never_answers_is_reported_as_a_poll_failure() {
    let error = bounded_poll(
        "mount_side_of_pier",
        std::future::pending::<crate::device_ops::DeviceResult<bool>>(),
    )
    .await
    .expect_err("a hung driver call must never be reported as a reading");
    assert!(error.contains("mount_side_of_pier"), "got: {error}");
    assert!(error.contains("poll failure"), "got: {error}");
}

/// The per-call bounds cannot see a stall they are not wrapping — a
/// blocking call that never yields, a deadlocked lock. The watchdog is the
/// backstop that turns "hung" into "exited", the one shape the fail-closed
/// handler downstream can act on.
#[tokio::test(start_paused = true)]
async fn the_stall_watchdog_fires_only_once_the_monitor_stops_beating() {
    let stall = std::time::Duration::from_secs(60);
    let (heartbeat_tx, heartbeat_rx) = watch::channel(0_u64);
    let watchdog =
        trigger_monitor_stall_watchdog(heartbeat_rx, Arc::new(AtomicBool::new(false)), stall);
    tokio::pin!(watchdog);

    for beat in 1..=5_u64 {
        tokio::time::sleep(stall / 2).await;
        heartbeat_tx.send(beat).expect("watchdog still listening");
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(1), &mut watchdog)
                .await
                .is_err(),
            "a monitor completing iterations is alive"
        );
    }

    tokio::time::timeout(stall * 2, &mut watchdog)
        .await
        .expect("a monitor that stopped beating is a stall");
}

/// A meridian-flip retry ladder holds the monitor's loop for minutes by
/// design. Mistaking that for a dead monitor would abort the run at the
/// exact moment the flip needed to finish, so the watchdog watches the
/// poll phase and holds off while an action is in flight.
#[tokio::test(start_paused = true)]
async fn the_stall_watchdog_holds_off_while_a_trigger_action_is_in_flight() {
    let stall = std::time::Duration::from_secs(60);
    let (_heartbeat_tx, heartbeat_rx) = watch::channel(0_u64);
    let action_in_flight = Arc::new(AtomicBool::new(true));
    let watchdog = trigger_monitor_stall_watchdog(heartbeat_rx, action_in_flight.clone(), stall);
    tokio::pin!(watchdog);

    assert!(
        tokio::time::timeout(stall * 10, &mut watchdog)
            .await
            .is_err(),
        "a long-running recovery action is not a dead monitor"
    );

    action_in_flight.store(false, Ordering::Release);
    tokio::time::timeout(stall * 2, &mut watchdog)
        .await
        .expect("once the action is done, a monitor that still never beats is dead");
}

/// The daylight gate's max Sun altitude must be populated from Dart. With no
/// setter the field holds the derive-default and the native gate blocks only
/// above the geometric horizon (0°), opening a twilight gap against the Dart
/// -12° gate. `update_max_sun_altitude` writes the Dart value through
/// `runtime_config` AND patches the live trigger state so the gate honours it.
#[tokio::test]
async fn update_max_sun_altitude_writes_through_runtime_config_and_trigger_state() {
    let mut executor = SequenceExecutor::new();

    // A pushed value lands verbatim in the runtime config...
    executor.update_max_sun_altitude(Some(-6.0)).await;
    {
        let handle = executor.runtime_config_handle();
        let rc = handle.read();
        assert_eq!(
            rc.max_sun_altitude_degrees,
            Some(-6.0),
            "the pushed Dart threshold must be written through runtime_config"
        );
    }
    // ...and is patched into the live trigger state so the gate (which reads
    // through the trigger-state handle) sees it without a sequence reload.
    {
        let mgr = executor.trigger_manager.read().await;
        let state = mgr.state();
        let guard = state.read().await;
        assert_eq!(
            guard.max_sun_altitude_degrees,
            Some(-6.0),
            "the trigger state the gate reads must carry the pushed threshold"
        );
    }

    // A None / non-finite push resolves to the DEFAULT (-12°) in the live
    // trigger state so the gate is NEVER weaker than the Dart W1 gate, while
    // the runtime config records the raw None (unset).
    executor.update_max_sun_altitude(None).await;
    {
        let handle = executor.runtime_config_handle();
        assert_eq!(handle.read().max_sun_altitude_degrees, None);
    }
    {
        let mgr = executor.trigger_manager.read().await;
        let state = mgr.state();
        let guard = state.read().await;
        assert_eq!(
            guard.max_sun_altitude_degrees,
            Some(crate::instructions::DEFAULT_MAX_SUN_ALTITUDE_DEGREES),
            "a None push must resolve to the -12° default in the gate's state"
        );
    }
}

/// The native default must equal the Dart
/// `SchedulerConfig.maxSunAltitudeDegrees` default (-12°, nautical darkness)
/// so an un-pushed native gate is no weaker than the Dart one.
#[test]
fn default_max_sun_altitude_matches_dart_nautical_darkness() {
    assert_eq!(
        crate::instructions::DEFAULT_MAX_SUN_ALTITUDE_DEGREES,
        -12.0,
        "native daylight-gate default must mirror the Dart scheduler's -12° \
         default so the twilight gap is closed"
    );
}

/// `update_filter_offsets` must propagate to runtime_config
/// so the next filter change reads the updated map.
#[tokio::test]
async fn update_filter_offsets_writes_through_runtime_config() {
    let mut executor = SequenceExecutor::new();
    let mut offsets = std::collections::HashMap::new();
    offsets.insert("Ha".to_string(), 250);
    offsets.insert("OIII".to_string(), -120);
    executor.update_filter_offsets(offsets.clone()).await;
    let handle = executor.runtime_config_handle();
    let rc = handle.read();
    assert_eq!(rc.filter_focus_offsets.get("Ha"), Some(&250));
    assert_eq!(rc.filter_focus_offsets.get("OIII"), Some(&-120));
}

/// a single `Arc<CheckpointManager>` must be shared between
/// the executor public API and the streaming-checkpoint task. Pointer
/// equality on the Arc is a structural invariant; if `set_checkpoint_dir`
/// ever drops back to `Box`/owned semantics this test fails immediately.
#[test]
fn checkpoint_manager_is_arc_shared() {
    let mut executor = SequenceExecutor::new();
    executor.set_checkpoint_dir("/tmp/nightshade_checkpoint_test_§1_16");
    let mgr_a = executor
        .checkpoint_manager
        .clone()
        .expect("checkpoint manager set");
    let mgr_b = executor
        .checkpoint_manager
        .clone()
        .expect("checkpoint manager set");
    assert!(
        Arc::ptr_eq(&mgr_a, &mgr_b),
        "set_checkpoint_dir must produce a single shared Arc"
    );
}

// calculate_totals must recognise SmartExposure.

/// The meridian flip drives the camera too, and firing it on top of an
/// in-flight light destroys that light: the flip's plate solve restarts the
/// same sensor mid-exposure, and the burst then downloads the SOLVE frame and
/// saves it as the light — a frame a fraction of its requested length, filed
/// under the target as accepted, while the node card still reads the
/// requested duration.
///
/// So every camera-driving trigger action takes the capture loop's claim, not
/// just autofocus. The capture loop's pre-frame gate holds the NEXT frame; it
/// cannot hold the one already exposing.
#[tokio::test]
async fn every_camera_driving_trigger_action_waits_for_the_frame_in_flight() {
    // The list itself is the contract: an action that exposes and is missing
    // here silently regains the ability to stomp a light frame.
    assert_eq!(
        camera_driving_trigger_action(&RecoveryAction::Autofocus),
        Some("autofocus")
    );
    assert_eq!(
        camera_driving_trigger_action(&RecoveryAction::MeridianFlip(
            crate::MeridianFlipConfig::default()
        )),
        Some("meridian flip"),
        "a flip plate-solves, which is an exposure on the imaging camera"
    );
    assert_eq!(
        camera_driving_trigger_action(&RecoveryAction::Recenter),
        Some("recenter"),
        "a recenter plate-solves, which is an exposure on the imaging camera"
    );
    // Actions that never touch the sensor must NOT wait — holding a dither or
    // a park behind a 10-minute sub would be its own defect.
    assert_eq!(camera_driving_trigger_action(&RecoveryAction::Pause), None);
    assert_eq!(
        camera_driving_trigger_action(&RecoveryAction::ParkAndAbort),
        None
    );
    assert_eq!(
        camera_driving_trigger_action(&RecoveryAction::Dither(crate::DitherConfig::default())),
        None
    );

    // And the flip actually waits behind the capture loop's claim.
    let state = Arc::new(RwLock::new(crate::triggers::TriggerState::new()));
    let cancelled = Arc::new(AtomicBool::new(false));
    // The capture loop takes the claim for the frame it is exposing.
    let frame_token = state
        .write()
        .await
        .try_claim_imaging_train("the next exposure", 15.0)
        .expect("an idle imaging train must be claimable");

    let release_state = state.clone();
    tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        release_state
            .write()
            .await
            .release_imaging_train(frame_token);
    });

    let label = camera_driving_trigger_action(&RecoveryAction::MeridianFlip(
        crate::MeridianFlipConfig::default(),
    ))
    .expect("the flip must be a camera-driving action");
    let started = tokio::time::Instant::now();
    claim_camera_for_trigger_action(&state, &cancelled, label).await;
    let waited = started.elapsed();
    assert!(
        waited >= std::time::Duration::from_millis(250),
        "the flip must wait for the light frame in flight, waited {waited:?}"
    );
    assert!(
        waited < std::time::Duration::from_secs(5),
        "the flip must start as soon as the frame lands, waited {waited:?}"
    );
}

/// Taking the claim is only half a protocol. Every exit of every
/// camera-driving arm has to hand it back, and the autofocus arm had one that
/// did not: the `(Some, Some)` camera+focuser branch released after the sweep,
/// but its sibling `_ =>` branch — a rig whose focuser (or camera) is absent —
/// logged "skipping the refocus and continuing the run" and fell straight
/// through. Nothing released, so the hold sat there until
/// `TRIGGER_CAMERA_CLAIM_SECS` expired, and for those ten minutes the capture
/// loop's pre-frame gate (`instructions/expose.rs`) blocked EVERY frame. The
/// run keeps saying it is imaging and takes no light for ten minutes.
///
/// This is the shape the refutation named, expressed as the invariant instead
/// of as one branch: acquire, take any exit, camera free.
#[tokio::test]
async fn the_autofocus_skip_branch_hands_the_camera_back() {
    let state = Arc::new(RwLock::new(crate::triggers::TriggerState::new()));
    let cancelled = Arc::new(AtomicBool::new(false));

    // The monitor takes the claim above the action match, for every
    // camera-driving action.
    let claim = TriggerCameraClaim::acquire(&state, &cancelled, &RecoveryAction::Autofocus).await;
    assert!(
        claim.is_held(),
        "autofocus drives the camera, so it claims it"
    );
    assert!(
        state.read().await.imaging_train_hold().is_some(),
        "the claim must actually be held while the action runs"
    );

    // The skip branch: camera present, focuser gone mid-run. Its whole body is
    // a warn, a latch reset and an Error event — it never touches the sensor
    // and never reaches the sweep's release, so the exit itself has to.
    assert_eq!(
        autofocus_trigger_skip_reason(Some(&"cam".to_string()), None),
        Some("no focuser is"),
        "a rig with a camera and no focuser must take the skip branch"
    );
    {
        let mut ts = state.write().await;
        ts.clear_autofocus_invalidation();
    }
    drop(claim);
    // Drop is synchronous; the uncontended try_write path releases inline.
    tokio::task::yield_now().await;

    assert!(
        state.read().await.imaging_train_hold().is_none(),
        "the skipped refocus must hand the camera back; a hold left to expire \
         blocks every frame for TRIGGER_CAMERA_CLAIM_SECS while the run still \
         reports itself as imaging"
    );
}

/// The refutation enumerated the branches, so enumerate them here. Every
/// (camera, focuser) combination the autofocus arm can see, and for the three
/// non-runnable ones the claim must come back — the leak was not specific to
/// the missing focuser, it was specific to "this branch does not reach the
/// release".
#[tokio::test]
async fn every_autofocus_device_gap_hands_the_camera_back() {
    let cam = "cam-1".to_string();
    let focuser = "focuser-1".to_string();

    assert_eq!(
        autofocus_trigger_skip_reason(Some(&cam), Some(&focuser)),
        None,
        "camera + focuser is the only combination that can actually refocus"
    );

    for (camera_id, focuser_id, expected) in [
        (None, None, "no camera and no focuser are"),
        (None, Some(&focuser), "no camera is"),
        (Some(&cam), None, "no focuser is"),
    ] {
        assert_eq!(
            autofocus_trigger_skip_reason(camera_id, focuser_id),
            Some(expected)
        );

        let state = Arc::new(RwLock::new(crate::triggers::TriggerState::new()));
        let cancelled = Arc::new(AtomicBool::new(false));
        let claim =
            TriggerCameraClaim::acquire(&state, &cancelled, &RecoveryAction::Autofocus).await;
        assert!(claim.is_held());
        drop(claim);
        tokio::task::yield_now().await;

        assert!(
            state.read().await.imaging_train_hold().is_none(),
            "the {expected} branch left the claim held; the capture loop would \
             block every frame until the ten-minute expiry"
        );
    }
}

/// The other two camera-driving actions have their own non-running exits — a
/// flip whose mount or target coordinates are missing, a recenter with no
/// target RA/Dec. None of them expose, all of them must hand the camera back.
#[tokio::test]
async fn every_camera_driving_action_hands_the_camera_back_on_a_silent_exit() {
    for action in [
        RecoveryAction::Autofocus,
        RecoveryAction::MeridianFlip(crate::MeridianFlipConfig::default()),
        RecoveryAction::Recenter,
    ] {
        let state = Arc::new(RwLock::new(crate::triggers::TriggerState::new()));
        let cancelled = Arc::new(AtomicBool::new(false));

        let mut claim = TriggerCameraClaim::acquire(&state, &cancelled, &action).await;
        assert!(claim.is_held(), "{action:?} drives the camera");

        // The arm exits without ever calling `release()` — the skip branch, a
        // `continue`, a `return terminate_with(...)`.
        drop(claim);
        tokio::task::yield_now().await;
        assert!(
            state.read().await.imaging_train_hold().is_none(),
            "{action:?} exited without releasing the camera claim"
        );

        // And the explicit release, which the arms that DO expose call the
        // moment they are done, so the next frame starts immediately rather
        // than waiting for the release after the match.
        claim = TriggerCameraClaim::acquire(&state, &cancelled, &action).await;
        claim.release().await;
        assert!(
            state.read().await.imaging_train_hold().is_none(),
            "{action:?} did not release explicitly"
        );
    }
}

/// The token is one shared deadline, so a release that fires late must not
/// clear a claim that is no longer its own. The capture loop takes the camera
/// the instant the trigger action gives it back; a second, stale release would
/// drop the loop's hold and reopen the mid-frame race the whole protocol
/// exists to close.
#[tokio::test]
async fn a_stale_release_cannot_steal_the_capture_loops_claim() {
    let state = Arc::new(RwLock::new(crate::triggers::TriggerState::new()));
    let cancelled = Arc::new(AtomicBool::new(false));

    let mut claim =
        TriggerCameraClaim::acquire(&state, &cancelled, &RecoveryAction::Autofocus).await;
    claim.release().await;

    // The capture loop wins the free camera for its next 300 s light.
    assert!(
        state
            .write()
            .await
            .try_claim_imaging_train("the next exposure", 300.0)
            .is_some(),
        "the imaging train must be free once the trigger action releases"
    );

    // The guard falls out of scope at the end of the dispatch. It has nothing
    // left to give back and must not touch the frame in flight.
    claim.release().await;
    drop(claim);
    tokio::task::yield_now().await;
    assert!(
        state.read().await.imaging_train_hold().is_some(),
        "a stale release cleared the capture loop's own claim, which is exactly \
         how a light frame gets destroyed"
    );
}

/// A wait that ends because the operator pressed Stop never held the token.
/// Treating it as held would make the guard release a claim someone else owns.
#[tokio::test]
async fn a_cancelled_wait_never_claims_and_never_releases() {
    let state = Arc::new(RwLock::new(crate::triggers::TriggerState::new()));
    let cancelled = Arc::new(AtomicBool::new(true));
    // The capture loop is mid-frame and keeps its claim throughout.
    state
        .write()
        .await
        .try_claim_imaging_train("the next exposure", 300.0)
        .expect("an idle imaging train must be claimable");

    let claim = TriggerCameraClaim::acquire(&state, &cancelled, &RecoveryAction::Autofocus).await;
    assert!(
        !claim.is_held(),
        "a cancelled wait returns without the token, so the guard holds nothing"
    );
    drop(claim);
    tokio::task::yield_now().await;

    assert!(
        state.read().await.imaging_train_hold().is_some(),
        "the cancelled action released a claim it never took"
    );
}

/// Actions that never touch the sensor must not take the claim at all —
/// holding a dither or a park behind a ten-minute sub would be its own defect.
#[tokio::test]
async fn non_camera_actions_take_no_claim() {
    let state = Arc::new(RwLock::new(crate::triggers::TriggerState::new()));
    let cancelled = Arc::new(AtomicBool::new(false));

    for action in [
        RecoveryAction::Pause,
        RecoveryAction::ParkAndAbort,
        RecoveryAction::Dither(crate::DitherConfig::default()),
    ] {
        let claim = TriggerCameraClaim::acquire(&state, &cancelled, &action).await;
        assert!(!claim.is_held(), "{action:?} does not drive the camera");
        assert!(
            state.read().await.imaging_train_hold().is_none(),
            "{action:?} claimed the camera it never uses"
        );
    }
}

/// The guard's coverage is only real while it is the ONLY way the trigger
/// dispatch hands the imaging train back: a hand-placed
/// `release_imaging_train()` per arm plus a comment claiming every exit is
/// covered is a claim rather than a check, and one arm goes uncovered.
///
/// So check it: a bare release inside the dispatch is a release that some
/// future early exit will route around.
#[test]
fn the_trigger_dispatch_releases_the_camera_only_through_the_guard() {
    let start_rs = include_str!("../start.rs");
    let bare_releases = start_rs.matches("release_imaging_train(").count();
    assert_eq!(
        bare_releases, 0,
        "executor/start.rs releases the imaging-train claim directly in {bare_releases} \
         place(s). Route it through `camera_claim.release().await` instead: a per-arm release \
         only covers the exits someone remembered, and the autofocus device-missing branch is \
         what happens when one is forgotten — ten minutes of blocked frames per firing."
    );
}

/// The live defect (2026-08-17, D1 sim-night harness, release bundle): the
/// meridian-flip trigger fired 1.5 ms after the run started, on a target 1.5h
/// EAST of the meridian, and the flip's own banner printed the contradiction —
///
///   [MERIDIAN] FLIP TRIGGER ACTIVATED
///   [MERIDIAN]   Hour Angle: -1.50h (-90.0 minutes past meridian)
///   [MERIDIAN]   Current Pier Side: Unknown
///
/// — because the trigger was evaluating a hour angle recomputed from
/// `mount_get_coordinates`, and the mount was still sitting at its parked
/// RA 0h while the sequence changed its first filter. HA = LST - 0h = +2.6h
/// that morning: 159 minutes "past the meridian" against a 5-minute window.
///
/// The published hour angle must be the TARGET's. The function takes no mount
/// reading at all, which is the structural half of the proof; the numeric
/// assertions below are the other half, and the parked-mount value is asserted
/// AGAINST so that re-deriving it from mount coordinates fails here.
#[test]
fn the_published_hour_angle_belongs_to_the_target_not_the_mount() {
    use chrono::TimeZone;

    let latitude = 40.0;
    let longitude = -105.0;
    let now = chrono::Utc
        .with_ymd_and_hms(2026, 8, 17, 11, 55, 26)
        .unwrap();
    let lst = crate::meridian::local_sidereal_time(crate::meridian::julian_day(&now), longitude);

    // The harness target: 1.5h east of the meridian, at dec = latitude.
    let target_ra_hours = (lst + 1.5).rem_euclid(24.0);
    let sky = target_sky_state(
        Some(target_ra_hours * 15.0),
        Some(latitude),
        Some(latitude),
        Some(longitude),
        now,
    )
    .expect("target and site are both known");

    assert!(
        (sky.hour_angle_hours - -1.5).abs() < 1e-6,
        "a target 1.5h east of the meridian must publish HA -1.50h, got {:+.4}h",
        sky.hour_angle_hours
    );

    // What the retired mount-derived computation would have published: the
    // simulator (and plenty of drivers) park at RA 0h, so its hour angle is
    // the local sidereal time itself — positive for half of every day, and
    // hours "past the meridian" for a target that has not transited.
    let parked_mount_hour_angle = crate::meridian::hour_angle(0.0, lst);
    assert!(
        parked_mount_hour_angle > 2.0,
        "the parked mount really is hours 'past the meridian' at this instant: {parked_mount_hour_angle:+.4}h"
    );
    assert!(
        (sky.hour_angle_hours - parked_mount_hour_angle).abs() > 4.0,
        "the published hour angle must not be the parked mount's"
    );

    // Altitude is target-derived too, and always was: 1.5h east of transit at
    // dec = latitude is high but no longer overhead.
    assert!(
        (60.0..85.0).contains(&sky.altitude_degrees),
        "target altitude {:.2}° is not the geometry of a target 1.5h from transit \
         at dec = latitude",
        sky.altitude_degrees
    );
}

/// No target, or no observing site, means the sky state cannot be computed —
/// and an absent value is what keeps the altitude and meridian triggers inert
/// rather than firing on a fabricated one.
#[test]
fn the_sky_state_abstains_without_a_target_or_a_site() {
    let now = chrono::Utc::now();
    assert!(target_sky_state(None, Some(40.0), Some(40.0), Some(-105.0), now).is_none());
    assert!(target_sky_state(Some(60.0), None, Some(40.0), Some(-105.0), now).is_none());
    assert!(target_sky_state(Some(60.0), Some(40.0), None, Some(-105.0), now).is_none());
    assert!(target_sky_state(Some(60.0), Some(40.0), Some(40.0), None, now).is_none());
}

/// A trigger-fired autofocus is not a node in the tree, so nothing emits the
/// "Executing: <name>" entry message the progress callback reads display names
/// out of, and its fallback published the literal word "Unknown" as the current
/// node for the whole sweep. Measured against the running bundle: 60 s of
/// "CURRENT NODE / Unknown" on the phone panel and `name=Unknown` in the run
/// log, while the id beside it spelled out `trigger:hfr_degraded:autofocus` and
/// the message line one row below named the autofocus.
///
/// The trigger knows what it fired, so the interlude announces itself.
#[tokio::test]
async fn a_trigger_fired_autofocus_names_itself_on_the_wire() {
    let mut sequence = SequenceDefinition::new("New Sequence".to_string());
    sequence.nodes.push(crate::NodeDefinition {
        id: "wait".to_string(),
        name: "Wait".to_string(),
        // Long enough that the run is still going when the trigger fires; the
        // test stops it as soon as it has the announcement.
        node_type: crate::NodeType::Delay(crate::DelayConfig { seconds: 120.0 }),
        enabled: true,
        children: vec![],
    });
    sequence.root_node_id = Some("wait".to_string());

    let mut executor = SequenceExecutor::new();
    executor.set_device_ops(Arc::new(crate::device_ops::NullDeviceOps));
    // The autofocus arm only runs for a rig that has both devices; without
    // them the trigger takes the skip branch and there is no interlude at all.
    executor.camera_id = Some("sim_camera_1".to_string());
    executor.focuser_id = Some("sim_focuser_1".to_string());
    {
        let mut manager = executor.trigger_manager.write().await;
        // Leave exactly one trigger armed so nothing else steers the run, and
        // let a single degraded frame fire it: the production tolerance of
        // three consecutive frames is about seeing spikes, not about what the
        // interlude is called.
        for id in [
            "hfr_degraded",
            "meridian_flip",
            "guiding_failed",
            "altitude_limit",
            "weather_unsafe",
            "temperature_shift",
            "filter_change",
            "dawn_approaching",
            "autofocus_interval",
            "dither_interval",
        ] {
            manager.remove_trigger(id);
        }
        manager.add_trigger(Trigger::new(
            "hfr_degraded",
            "HFR Degradation",
            crate::TriggerType::HfrDegraded {
                threshold_percent: 20.0,
                absolute_threshold: 0.0,
                consecutive_frames: 1,
            },
            crate::RecoveryAction::Autofocus,
        ));
    }
    let mut events = executor.subscribe();
    executor.load_sequence(sequence).expect("sequence loads");
    executor.start().await.expect("run starts");

    // Focus drifts: one good frame sets the baseline, then one well past the
    // 20% threshold. The evaluator counts one sample per graded frame, so the
    // two must land on different monitor ticks.
    let trigger_state = {
        let manager = executor.trigger_manager.read().await;
        manager.state()
    };
    trigger_state.write().await.update_hfr(2.0);
    tokio::time::sleep(std::time::Duration::from_millis(1500)).await;
    trigger_state.write().await.update_hfr(4.0);

    let announced = tokio::time::timeout(std::time::Duration::from_secs(20), async {
        loop {
            match events.recv().await {
                Ok(ExecutorEvent::NodeStarted { id, name })
                    if id.starts_with("trigger:") && id.ends_with(":autofocus") =>
                {
                    return (id, name);
                }
                Ok(_) => continue,
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                    panic!("the event stream closed before the interlude started")
                }
            }
        }
    })
    .await
    .expect("the trigger-fired autofocus announces itself");
    executor.stop().await.ok();

    let (id, name) = announced;
    assert_eq!(id, "trigger:hfr_degraded:autofocus");
    assert_ne!(
        name, "Unknown",
        "the id already says what this is; \"Unknown\" is for work nobody can name"
    );
    assert!(
        name.contains("Autofocus"),
        "the interlude must name the work it is doing, got {name:?}"
    );
    assert!(
        name.contains("HFR Degradation"),
        "the interlude must name the trigger that fired it, got {name:?}"
    );
}

/// A paused run is still watched for weather. `is_safety_class_trigger` is
/// tested on its own, but nothing ran the monitor through a pause: deleting
/// the `Paused` arm of the monitor's state gate (so a paused run is not
/// evaluated at all, the defect the passive hold depends on being fixed), or
/// inverting the paused-run filter, left every test green.
#[tokio::test]
async fn weather_turning_unsafe_during_a_pause_still_fires_the_weather_trigger() {
    let mut sequence = SequenceDefinition::new("Paused Run".to_string());
    sequence.nodes.push(crate::NodeDefinition {
        id: "wait".to_string(),
        name: "Wait".to_string(),
        node_type: crate::NodeType::Delay(crate::DelayConfig { seconds: 120.0 }),
        enabled: true,
        children: vec![],
    });
    sequence.root_node_id = Some("wait".to_string());

    let mut executor = SequenceExecutor::new();
    executor.set_device_ops(Arc::new(ReacquireGuiderOps::new(false, false)));
    executor.set_devices(None, Some("mount-1".to_string()), None, None, None);
    let mut events = executor.subscribe();
    executor.load_sequence(sequence).expect("sequence loads");
    executor.start().await.expect("run starts");

    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    while executor.get_state().await != ExecutorState::Running {
        assert!(std::time::Instant::now() < deadline, "run never started");
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    executor.pause().await.expect("pause accepted");
    while executor.get_state().await != ExecutorState::Paused {
        assert!(std::time::Instant::now() < deadline, "run never paused");
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    // Nothing was unsafe before the pause.
    while let Ok(event) = events.try_recv() {
        if let ExecutorEvent::TriggerFired { trigger_id, .. } = event {
            assert_ne!(trigger_id, "weather_unsafe", "fired before the sky changed");
        }
    }

    executor.update_weather_verdict(Some(true)).await;

    let fired = tokio::time::timeout(std::time::Duration::from_secs(15), async {
        loop {
            match events.recv().await {
                Ok(ExecutorEvent::TriggerFired { trigger_id, .. })
                    if trigger_id == "weather_unsafe" =>
                {
                    return true;
                }
                Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => {}
                Err(broadcast::error::RecvError::Closed) => return false,
            }
        }
    })
    .await
    .unwrap_or(false);
    executor.stop().await.ok();

    assert!(
        fired,
        "the weather trigger must keep protecting the rig while the run is paused"
    );
}
