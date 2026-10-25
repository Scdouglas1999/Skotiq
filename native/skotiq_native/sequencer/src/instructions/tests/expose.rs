//! `expose` tests — moved verbatim out of the former single `instructions::tests`
//! module (release-pass C3 mechanical split). Shared fixtures stay in the parent
//! `tests` module and reach here through `use super::*;`.

use super::*;

/// Pause must stop a burst mid-flight. The node tree only checks `is_paused`
/// between instructions and a burst is N frames inside ONE instruction, so
/// without an in-burst check a Pause pressed during frame 2 of a 3x8s Take
/// Exposures shows a PAUSED badge and "Paused 33%" while the log goes
/// `Pausing sequence execution` -> `Capturing frame 3/3 (8.0s)` and the run
/// records `status=completed, framesCaptured=3` with Resume never pressed.
#[tokio::test]
async fn pause_stops_the_burst_before_the_next_frame_starts() {
    let paused = Arc::new(AtomicBool::new(false));
    let ops = Arc::new(ScriptedDomeRotatorOps::new().pausing_after_first_exposure(paused.clone()));
    let dir = std::env::temp_dir().join(format!("sk-pause-burst-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).expect("temp dir");

    let mut ec = crate::node::context::ExecutionContext::new_for_test("pause-node".to_string());
    ec.device_ops = ops.clone();
    ec.camera_id = Some("camera-1".to_string());
    ec.save_path = Some(dir.clone());
    ec.is_paused = paused.clone();
    let ctx = ec.to_instruction_context("pause-node").await;
    let control = BurstControl {
        pause: ec.pause_gate(),
        status: None,
    };
    // Calibration frames so the burst is not daylight-gated or graded.
    let config = ExposureConfig {
        count: 3,
        duration_secs: 0.0,
        frame_type: "dark".to_string(),
        ..ExposureConfig::default()
    };

    let burst = std::pin::pin!(execute_exposure_with_renderer(
        &config,
        &ctx,
        None,
        &control,
        |_, _, _| {}
    ));
    let mut burst = burst;

    let held = tokio::time::timeout(Duration::from_millis(400), &mut burst).await;
    assert!(
        held.is_err(),
        "the burst must still be holding while the operator has it paused"
    );
    assert_eq!(
        ops.camera_exposure_calls.load(Ordering::SeqCst),
        1,
        "no NEW exposure may start while paused — the operator pauses to \
             stand in front of the telescope"
    );

    paused.store(false, Ordering::SeqCst);
    let result = tokio::time::timeout(Duration::from_secs(10), burst)
        .await
        .expect("resume must let the burst finish");

    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(result.status, NodeStatus::Success);
    assert_eq!(
        ops.camera_exposure_calls.load(Ordering::SeqCst),
        3,
        "Resume must complete the remaining frames"
    );
}

#[tokio::test]
async fn dropped_exposure_instruction_aborts_camera() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new().with_hanging_camera());
    let ctx = ctx_with_ops(ops.clone()).await;
    let config = ExposureConfig {
        duration_secs: 60.0,
        count: 1,
        ..ExposureConfig::default()
    };

    let task = tokio::spawn(async move { execute_exposure(&config, &ctx, |_, _, _| {}).await });
    while ops.camera_exposure_calls.load(Ordering::SeqCst) == 0 {
        tokio::task::yield_now().await;
    }
    task.abort();
    let _ = task.await;
    for _ in 0..20 {
        if ops.camera_abort_calls.load(Ordering::SeqCst) > 0 {
            break;
        }
        tokio::task::yield_now().await;
    }

    assert_eq!(
        ops.camera_abort_calls.load(Ordering::SeqCst),
        1,
        "dropping the instruction future must abort the physical exposure"
    );
}

#[tokio::test]
async fn requested_filter_without_wheel_fails_before_capture() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new());
    let mut ctx = ctx_with_ops(ops.clone()).await;
    ctx.filterwheel_id = None;
    let config = ExposureConfig {
        duration_secs: 0.01,
        count: 1,
        filter: Some("Ha".to_string()),
        ..ExposureConfig::default()
    };

    let result = execute_exposure(&config, &ctx, |_, _, _| {}).await;

    assert_eq!(result.status, NodeStatus::Failure);
    assert!(
        result
            .message
            .as_deref()
            .is_some_and(|message| message.contains("no filter wheel")),
        "missing hardware must be surfaced instead of capturing mislabeled data"
    );
    assert_eq!(
        ops.camera_exposure_calls.load(Ordering::SeqCst),
        0,
        "capture must not start when its requested filter cannot be applied"
    );
}

// Device arbitration between a trigger action and the capture loop.
//
// The 2026-09-14 race, in its own words. The Smart Exposure node was cycling
// Ha/SII/OIII on an 8-position ZWO EFW while the HFR-Degradation trigger fired
// an autofocus that wanted "L" (position 0). Autofocus reported:
//
//   Failed to switch to autofocus filter "L": filter wheel did not reach
//   position 0 within 120 seconds
//
// Measured over the HTTP API at that moment: the wheel was connected, NOT
// moving, at position 5 (SII), with all 8 names present and answering status
// polls. Nothing was wrong with the wheel. The capture loop had commanded it,
// and the camera-only claim did not cover it.

/// While a trigger action holds the imaging train, the capture loop must not
/// touch the filter wheel — not the camera, and not the wheel either.
#[tokio::test]
async fn the_capture_loop_does_not_move_the_wheel_under_a_trigger_claim() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new());
    let mut ctx = expose_ctx(ops.clone(), None, live_sun_alt() + 5.0).await;
    // The owner's 8-position ZWO EFW, which the Smart Exposure node and the
    // autofocus trigger were both driving.
    ctx.filterwheel_id = Some("efw-1".to_string());
    let trigger_state = ctx
        .trigger_state
        .clone()
        .expect("expose_ctx wires a trigger state");

    // The trigger-fired autofocus takes the train and is part-way through its
    // own move to "L".
    let af_token = trigger_state
        .write()
        .await
        .try_claim_imaging_train("autofocus", 600.0)
        .expect("an idle imaging train must be claimable");

    let config = ExposureConfig {
        // Position 5 is SII on the owner's wheel — the slot that stranded the
        // autofocus move.
        filter_index: Some(5),
        filter: Some("SII".to_string()),
        ..one_light()
    };

    // Run the burst concurrently and give it room to reach the wheel if it is
    // going to.
    let burst_ctx = ctx;
    let burst =
        tokio::spawn(async move { execute_exposure(&config, &burst_ctx, |_, _, _| {}).await });
    tokio::time::sleep(std::time::Duration::from_millis(400)).await;

    assert!(
        ops.filter_moves.lock().unwrap().is_empty(),
        "the capture loop moved the wheel while autofocus held the imaging train; \
         that is the collision that stranded a 120 s filter move on a healthy wheel: {:?}",
        ops.filter_moves.lock().unwrap()
    );

    // Hand it back; the burst proceeds and takes the wheel.
    trigger_state.write().await.release_imaging_train(af_token);
    let _ = burst.await.expect("the burst task must not panic");
    assert_eq!(
        *ops.filter_moves.lock().unwrap(),
        vec![5],
        "and it moves the wheel as soon as the trigger action releases"
    );
}

/// And the reverse direction: while the capture loop holds the train for a
/// frame, a trigger action cannot take it.
///
/// This is the half that the old predicted-deadline claim got wrong once an
/// exposure overran its estimate.
#[tokio::test]
async fn a_trigger_action_cannot_take_the_train_mid_frame() {
    let mut state = crate::triggers::TriggerState::new();
    // A 180 s light, as on the owner's rig.
    let frame_token = state
        .try_claim_imaging_train("the next exposure", 180.0)
        .expect("an idle imaging train must be claimable");

    // The drift-recenter trigger wants a 5 s plate-solve frame.
    assert!(
        state.try_claim_imaging_train("recenter", 5.0).is_none(),
        "a recenter must not start a 5 s exposure on a camera mid-180 s frame"
    );
    let hold = state
        .imaging_train_hold()
        .expect("the capture loop still holds it");
    assert_eq!(hold.holder, "the next exposure");
    assert!(
        hold.expected_remaining_secs > 180.0,
        "the wait a trigger is told to expect comes from the 180 s frame in flight, \
         not from its own 5 s request plus a fixed margin: got {:.0}s",
        hold.expected_remaining_secs
    );

    state.release_imaging_train(frame_token);
    assert!(
        state.try_claim_imaging_train("recenter", 5.0).is_some(),
        "and the recenter runs the moment the frame is downloaded"
    );
}

/// Which frames of a burst a dither follows. Nothing counted dithers, so
/// dithering calibration bursts, dithering after the final frame, or never
/// dithering at all each passed the whole suite.
mod dither_cadence {
    use super::*;

    async fn dithers_for(frame_type: &str, count: u32, dither_every: u32) -> Vec<u32> {
        let ops = Arc::new(ScriptedDomeRotatorOps::new());
        let ctx = expose_ctx(ops.clone(), None, live_sun_alt() + 5.0).await;
        let config = ExposureConfig {
            duration_secs: 0.01,
            count,
            frame_type: frame_type.to_string(),
            dither_every: Some(dither_every),
            ..ExposureConfig::default()
        };
        let result = execute_exposure(&config, &ctx, |_, _, _| {}).await;
        assert_eq!(result.status, NodeStatus::Success, "{:?}", result.message);
        assert_eq!(ops.camera_exposure_calls.load(Ordering::SeqCst), count);
        let dithers = ops.dithers_after_frame.lock().unwrap().clone();
        dithers
    }

    #[tokio::test]
    async fn a_light_burst_dithers_every_nth_frame_but_not_after_the_last() {
        assert_eq!(dithers_for("Light", 4, 2).await, vec![2]);
        assert_eq!(dithers_for("Light", 5, 2).await, vec![2, 4]);
    }

    #[tokio::test]
    async fn a_calibration_burst_never_moves_the_mount() {
        assert!(dithers_for("Dark", 3, 1).await.is_empty());
        assert!(dithers_for("Flat", 3, 1).await.is_empty());
    }
}

/// Light frames are measured and graded; calibration frames are neither. The
/// grader itself is tested, but the default test double measures nothing, so
/// skipping the HFR, star-count or eccentricity measurement on LIGHT frames
/// (the calibration check inverted) left every test green: a cloudy or
/// defocused night would then be accepted frame after frame.
mod light_frame_grading {
    use super::*;

    /// Run one frame of `frame_type` with the given measurements and check,
    /// and return the grading verdict the frame event carried.
    async fn grade_one(
        frame_type: &str,
        metrics: (f64, usize, f64),
        check: crate::quality::ImageQualityCheck,
    ) -> Result<(), (String, Option<f64>, Option<u32>)> {
        let scratch = scratch_dir("light-grading");
        let ops = Arc::new(
            ScriptedDomeRotatorOps::new()
                .with_scripted_frame_metrics(metrics.0, metrics.1, metrics.2),
        );
        let (event_tx, mut event_rx) = tokio::sync::broadcast::channel(64);
        let mut ctx = saving_expose_ctx(ops.clone(), scratch.0.clone(), event_tx).await;
        let mut ts = crate::triggers::TriggerState::new();
        ts.set_max_sun_altitude_degrees(live_sun_alt() + 5.0);
        ctx.trigger_state = Some(std::sync::Arc::new(tokio::sync::RwLock::new(ts)));
        let config = ExposureConfig {
            duration_secs: 0.01,
            count: 1,
            frame_type: frame_type.to_string(),
            quality_check: Some(check),
            ..ExposureConfig::default()
        };

        let result = execute_exposure(&config, &ctx, |_, _, _| {}).await;
        assert_eq!(result.status, NodeStatus::Success, "{:?}", result.message);

        let mut verdict = None;
        while let Ok(event) = event_rx.try_recv() {
            if let crate::executor::ExecutorEvent::NodeProgress {
                structured_detail: Some(detail),
                ..
            } = event
            {
                match *detail {
                    crate::node::ProgressDetail::FrameAccepted { .. } => verdict = Some(Ok(())),
                    crate::node::ProgressDetail::FrameRejected {
                        reason,
                        hfr,
                        star_count,
                        ..
                    } => verdict = Some(Err((reason, hfr, star_count))),
                    _ => {}
                }
            }
        }
        verdict.expect("a saved frame reports its grading verdict")
    }

    fn check(
        f: impl FnOnce(&mut crate::quality::ImageQualityCheck),
    ) -> crate::quality::ImageQualityCheck {
        let mut check = crate::quality::ImageQualityCheck::default();
        f(&mut check);
        check
    }

    #[tokio::test]
    async fn a_soft_light_frame_is_rejected_on_its_measured_hfr() {
        let (reason, hfr, _) = grade_one(
            "Light",
            (5.0, 60, 0.1),
            check(|c| c.hfr_threshold = Some(3.0)),
        )
        .await
        .expect_err("a 5 px frame against a 3 px limit must be rejected");
        assert_eq!(hfr, Some(5.0));
        assert!(reason.contains("HFR"), "{reason}");
    }

    #[tokio::test]
    async fn a_clouded_light_frame_is_rejected_on_its_star_count() {
        let (_, _, stars) = grade_one(
            "Light",
            (2.0, 3, 0.1),
            check(|c| c.star_count_min = Some(20)),
        )
        .await
        .expect_err("3 stars against a floor of 20 must be rejected");
        assert_eq!(stars, Some(3));
    }

    #[tokio::test]
    async fn a_trailed_light_frame_is_rejected_on_its_eccentricity() {
        let (reason, _, _) = grade_one(
            "Light",
            (2.0, 60, 0.8),
            check(|c| c.eccentricity_threshold = Some(0.5)),
        )
        .await
        .expect_err("0.8 eccentricity against a 0.5 limit must be rejected");
        assert!(reason.contains("eccentricity"), "{reason}");
    }

    #[tokio::test]
    async fn a_dark_with_the_same_numbers_is_never_graded() {
        grade_one(
            "Dark",
            (5.0, 3, 0.8),
            check(|c| {
                c.hfr_threshold = Some(3.0);
                c.star_count_min = Some(20);
                c.eccentricity_threshold = Some(0.5);
            }),
        )
        .await
        .expect("a calibration frame has no stars to grade");
    }

    /// Accepted frames set the star-count baseline of their target and filter
    /// and a later frame that keeps too few of those stars is rejected.
    #[tokio::test]
    async fn a_frame_that_lost_most_of_the_baseline_stars_is_rejected() {
        let scratch = scratch_dir("star-count-baseline");
        let grading = check(|c| {
            c.star_count_min = Some(10);
            c.star_count_drop_percent = Some(crate::quality::DEFAULT_STAR_COUNT_DROP_PERCENT);
        });
        let run = |stars: usize, count: u32, baselines: crate::quality::StarCountBaselines| {
            let scratch = scratch.0.clone();
            let grading = grading.clone();
            async move {
                let ops = Arc::new(
                    ScriptedDomeRotatorOps::new().with_scripted_frame_metrics(2.5, stars, 0.4),
                );
                let (event_tx, mut event_rx) = tokio::sync::broadcast::channel(64);
                let mut ctx = saving_expose_ctx(ops, scratch, event_tx).await;
                ctx.star_count_baselines = baselines;
                let mut ts = crate::triggers::TriggerState::new();
                ts.set_max_sun_altitude_degrees(live_sun_alt() + 5.0);
                ctx.trigger_state = Some(std::sync::Arc::new(tokio::sync::RwLock::new(ts)));
                let config = ExposureConfig {
                    duration_secs: 0.01,
                    count,
                    frame_type: "Light".to_string(),
                    quality_check: Some(grading),
                    ..ExposureConfig::default()
                };
                let result = execute_exposure(&config, &ctx, |_, _, _| {}).await;
                assert_eq!(result.status, NodeStatus::Success, "{:?}", result.message);
                let mut rejects = Vec::new();
                while let Ok(event) = event_rx.try_recv() {
                    if let crate::executor::ExecutorEvent::NodeProgress {
                        structured_detail: Some(detail),
                        ..
                    } = event
                    {
                        if let crate::node::ProgressDetail::FrameRejected { reason, .. } = *detail {
                            rejects.push(reason);
                        }
                    }
                }
                rejects
            }
        };

        let baselines = crate::quality::StarCountBaselines::default();
        assert!(run(2000, 3, baselines.clone()).await.is_empty());
        let rejects = run(400, 1, baselines.clone()).await;
        assert_eq!(rejects.len(), 1, "{rejects:?}");
        assert!(
            rejects[0].starts_with("star count 400 is 20%"),
            "{rejects:?}"
        );
        assert!(run(1500, 1, baselines).await.is_empty());
    }
}

/// A dither between frames that does not settle is a judgment about guiding,
/// and the standalone Dither node already carried on through it. In a burst
/// it failed the burst, which ended the run (owner decision 2026-10-06: only a
/// risk to the hardware stops a run by itself).
mod in_burst_dither_failure {
    use super::*;

    struct Burst {
        result: InstructionResult,
        frames: u32,
        warnings: Vec<String>,
        decisions: Vec<String>,
    }

    async fn burst_with_failing_dither(stop_on_quality_problems: bool) -> Burst {
        let ops = Arc::new(
            ScriptedDomeRotatorOps::new().with_dither_failing("Settle timed out after 60s"),
        );
        let ctx = expose_ctx(ops.clone(), None, live_sun_alt() + 5.0).await;
        if let Some(state) = &ctx.trigger_state {
            state.write().await.stop_on_quality_problems = stop_on_quality_problems;
        }
        let (event_tx, mut events) = tokio::sync::broadcast::channel(64);
        let (decision_tx, mut decision_rx) = tokio::sync::broadcast::channel(64);
        let ctx = InstructionContext {
            event_tx: Some(event_tx),
            decision_tx: Some(decision_tx),
            ..ctx
        };
        let config = ExposureConfig {
            duration_secs: 0.01,
            count: 4,
            frame_type: "Light".to_string(),
            dither_every: Some(1),
            ..ExposureConfig::default()
        };
        let result = execute_exposure(&config, &ctx, |_, _, _| {}).await;
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
        Burst {
            result,
            frames: ops.camera_exposure_calls.load(Ordering::SeqCst),
            warnings,
            decisions,
        }
    }

    #[tokio::test]
    async fn the_burst_keeps_imaging_and_the_operator_is_told_once() {
        let burst = burst_with_failing_dither(false).await;
        assert_eq!(
            burst.result.status,
            NodeStatus::Success,
            "{:?}",
            burst.result.message
        );
        assert_eq!(burst.frames, 4, "every frame of the burst is taken");
        assert_eq!(
            burst.decisions,
            vec![crate::executor::QUALITY_PROBLEM_CONTINUED_SUMMARY],
            "three failed dithers in a row are one notification"
        );
        assert!(
            burst
                .warnings
                .iter()
                .any(|w| w.contains("Settle timed out") && w.contains("The run continues")),
            "{:?}",
            burst.warnings
        );
    }

    #[tokio::test]
    async fn the_operator_who_asked_for_it_still_gets_the_stop() {
        let burst = burst_with_failing_dither(true).await;
        assert_eq!(burst.result.status, NodeStatus::Failure);
        assert_eq!(burst.frames, 1);
        assert!(burst.decisions.is_empty(), "{:?}", burst.decisions);
    }
}

/// After the guide-star recovery ran out the run images unguided (owner
/// decision 2026-10-06): a burst's dithers are skipped rather than sent to a
/// guider that is not guiding, each one a settle timeout and a notice.
#[tokio::test]
async fn a_burst_while_imaging_unguided_skips_its_dithers() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new().with_dither_failing("Not guiding"));
    let ctx = expose_ctx(ops.clone(), None, live_sun_alt() + 5.0).await;
    if let Some(state) = &ctx.trigger_state {
        state.write().await.guiding.set_unguided(true);
    }
    let (decision_tx, mut decision_rx) = tokio::sync::broadcast::channel(64);
    let ctx = InstructionContext {
        decision_tx: Some(decision_tx),
        ..ctx
    };
    let config = ExposureConfig {
        duration_secs: 0.01,
        count: 4,
        frame_type: "Light".to_string(),
        dither_every: Some(1),
        ..ExposureConfig::default()
    };

    let result = execute_exposure(&config, &ctx, |_, _, _| {}).await;

    assert_eq!(result.status, NodeStatus::Success, "{:?}", result.message);
    assert_eq!(ops.camera_exposure_calls.load(Ordering::SeqCst), 4);
    assert!(
        ops.dithers_after_frame.lock().unwrap().is_empty(),
        "{:?}",
        ops.dithers_after_frame.lock().unwrap()
    );
    assert!(
        decision_rx.try_recv().is_err(),
        "the operator was already told the run is unguided"
    );
}

#[tokio::test(start_paused = true)]
async fn tracking_hold_blocks_pending_guide_restart_before_exposure() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new());
    let mut ec = crate::node::context::ExecutionContext::new_for_test("held-light".into());
    ec.device_ops = ops.clone();
    ec.camera_id = Some("camera-1".into());
    ec.is_paused.store(true, Ordering::SeqCst);
    let mut state = crate::triggers::TriggerState::new();
    state.guiding.set_resume_pending(true);
    ec.trigger_state = Some(Arc::new(tokio::sync::RwLock::new(state)));
    let ctx = ec.to_instruction_context("held-light").await;
    let control = BurstControl {
        pause: ec.pause_gate(),
        status: None,
    };
    let config = ExposureConfig {
        count: 1,
        duration_secs: 0.0,
        ..Default::default()
    };
    let result = tokio::time::timeout(
        Duration::from_secs(1),
        execute_exposure_with_renderer(&config, &ctx, None, &control, |_, _, _| {}),
    )
    .await;
    assert!(result.is_err(), "the exposure must remain held");
    assert_eq!(
        ops.guider_start_calls.load(Ordering::SeqCst),
        0,
        "a pending guide restart cannot bypass the tracking-limit hold"
    );
    assert_eq!(ops.camera_exposure_calls.load(Ordering::SeqCst), 0);
}

/// A light frame that was exposing when a tracking-limit hold began is
/// trailed, so it is saved to the reject folder with the reason, whatever
/// its stars say, and counted as rejected.
#[tokio::test(start_paused = true)]
async fn a_frame_exposing_when_tracking_stops_is_rejected_with_the_reason() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new());
    let dir = std::env::temp_dir().join(format!("sk-untracked-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).expect("temp dir");
    let mut ec = crate::node::context::ExecutionContext::new_for_test("untracked".into());
    ec.device_ops = ops.clone();
    ec.camera_id = Some("camera-1".into());
    ec.save_path = Some(dir.clone());
    let mut state = crate::triggers::TriggerState::new();
    state
        .run
        .begin_hold(crate::triggers::RunHold::TrackingLimit);
    ec.trigger_state = Some(Arc::new(tokio::sync::RwLock::new(state)));
    let ctx = ec.to_instruction_context("untracked").await;
    let control = BurstControl {
        pause: ec.pause_gate(),
        status: None,
    };
    let config = ExposureConfig {
        count: 1,
        duration_secs: 0.0,
        ..Default::default()
    };
    let (events, mut rx) = tokio::sync::broadcast::channel(64);
    let mut ctx = ctx;
    ctx.event_tx = Some(events);
    let result = execute_exposure_with_renderer(&config, &ctx, None, &control, |_, _, _| {}).await;
    let rejected_files = std::fs::read_dir(dir.join("Reject"))
        .map(|entries| entries.count())
        .unwrap_or(0);
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(result.status, NodeStatus::Success, "{:?}", result.message);
    assert_eq!(ec.frames_rejected.load(Ordering::SeqCst), 1);
    assert_eq!(rejected_files, 1);
    let mut warned = false;
    while let Ok(event) = rx.try_recv() {
        if let crate::executor::ExecutorEvent::Warning { message } = event {
            warned |= message.contains("stopped tracking during this exposure");
        }
    }
    assert!(warned, "the rejection is announced");
}

/// Guiding is never restarted on a mount that reads tracking off: the frame
/// waits, and starts with guiding restarted once the mount tracks again.
#[tokio::test(start_paused = true)]
async fn a_pending_guide_restart_waits_for_the_mount_to_track() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new());
    let dir = std::env::temp_dir().join(format!("sk-guide-wait-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).expect("temp dir");
    let mut ec = crate::node::context::ExecutionContext::new_for_test("guide-wait".into());
    ec.device_ops = ops.clone();
    ec.camera_id = Some("camera-1".into());
    ec.save_path = Some(dir.clone());
    let mut state = crate::triggers::TriggerState::new();
    state.guiding.set_resume_pending(true);
    state.mount_is_tracking = Some(false);
    let state = Arc::new(tokio::sync::RwLock::new(state));
    ec.trigger_state = Some(state.clone());
    let ctx = ec.to_instruction_context("guide-wait").await;
    let control = BurstControl {
        pause: ec.pause_gate(),
        status: None,
    };
    let config = ExposureConfig {
        count: 1,
        duration_secs: 0.0,
        ..Default::default()
    };
    let mut burst = std::pin::pin!(execute_exposure_with_renderer(
        &config,
        &ctx,
        None,
        &control,
        |_, _, _| {}
    ));
    assert!(tokio::time::timeout(Duration::from_secs(30), &mut burst)
        .await
        .is_err());
    assert_eq!(ops.guider_start_calls.load(Ordering::SeqCst), 0);
    assert_eq!(ops.camera_exposure_calls.load(Ordering::SeqCst), 0);

    state.write().await.mount_is_tracking = Some(true);
    let result = tokio::time::timeout(Duration::from_secs(600), burst)
        .await
        .expect("the frame runs once the mount tracks");
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(result.status, NodeStatus::Success, "{:?}", result.message);
    assert_eq!(ops.guider_start_calls.load(Ordering::SeqCst), 1);
    assert_eq!(ops.camera_exposure_calls.load(Ordering::SeqCst), 1);
}

/// A run imaging unguided tries guiding again before a light frame once the
/// retry interval has passed, through the same gate that restarts guiding
/// after a move.
#[tokio::test(start_paused = true)]
async fn an_unguided_run_retries_guiding_before_a_light_frame() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new());
    let dir = std::env::temp_dir().join(format!("sk-unguided-retry-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).expect("temp dir");
    let mut ec = crate::node::context::ExecutionContext::new_for_test("unguided-retry".into());
    ec.device_ops = ops.clone();
    ec.camera_id = Some("camera-1".into());
    ec.mount_id = Some("mount-1".into());
    ec.save_path = Some(dir.clone());
    let mut state = crate::triggers::TriggerState::new();
    state.guiding.give_up_guiding();
    let state = Arc::new(tokio::sync::RwLock::new(state));
    ec.trigger_state = Some(state.clone());
    let ctx = ec.to_instruction_context("unguided-retry").await;
    let control = BurstControl {
        pause: ec.pause_gate(),
        status: None,
    };
    let config = ExposureConfig {
        count: 1,
        duration_secs: 0.0,
        ..Default::default()
    };
    tokio::time::advance(crate::instructions::guiding::UNGUIDED_RETRY_INTERVAL).await;
    let result = tokio::time::timeout(
        Duration::from_secs(600),
        execute_exposure_with_renderer(&config, &ctx, None, &control, |_, _, _| {}),
    )
    .await
    .expect("the frame runs");
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(result.status, NodeStatus::Success, "{:?}", result.message);
    assert_eq!(ops.guider_start_calls.load(Ordering::SeqCst), 1);
    assert_eq!(ops.camera_exposure_calls.load(Ordering::SeqCst), 1);
    assert!(!state.read().await.guiding.is_unguided());
}

/// A pending restart that finds the mount not tracking when it asks the
/// mount (the monitor has not read the stop yet) waits like one the monitor
/// already knew about, and never starts the guider.
#[tokio::test(start_paused = true)]
async fn a_pending_guide_restart_waits_when_the_mount_itself_reads_not_tracking() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new().with_mount_tracking(false));
    let dir = std::env::temp_dir().join(format!("sk-guide-wait-dev-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).expect("temp dir");
    let mut ec = crate::node::context::ExecutionContext::new_for_test("guide-wait-dev".into());
    ec.device_ops = ops.clone();
    ec.camera_id = Some("camera-1".into());
    ec.mount_id = Some("mount-1".into());
    ec.save_path = Some(dir.clone());
    let mut state = crate::triggers::TriggerState::new();
    state.guiding.set_resume_pending(true);
    ec.trigger_state = Some(Arc::new(tokio::sync::RwLock::new(state)));
    let ctx = ec.to_instruction_context("guide-wait-dev").await;
    let control = BurstControl {
        pause: ec.pause_gate(),
        status: None,
    };
    let config = ExposureConfig {
        count: 1,
        duration_secs: 0.0,
        ..Default::default()
    };
    let mut burst = std::pin::pin!(execute_exposure_with_renderer(
        &config,
        &ctx,
        None,
        &control,
        |_, _, _| {}
    ));
    assert!(tokio::time::timeout(Duration::from_secs(30), &mut burst)
        .await
        .is_err());
    assert_eq!(ops.guider_start_calls.load(Ordering::SeqCst), 0);
    assert_eq!(ops.camera_exposure_calls.load(Ordering::SeqCst), 0);
    // Past the wait the frame is taken without restarting guiding.
    let result = tokio::time::timeout(Duration::from_secs(600), burst)
        .await
        .expect("the frame runs after the wait");
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(result.status, NodeStatus::Success, "{:?}", result.message);
    assert_eq!(ops.guider_start_calls.load(Ordering::SeqCst), 0);
    assert_eq!(ops.camera_exposure_calls.load(Ordering::SeqCst), 1);
}
