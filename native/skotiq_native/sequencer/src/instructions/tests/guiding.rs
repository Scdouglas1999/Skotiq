//! `guiding` tests — moved verbatim out of the former single `instructions::tests`
//! module (release-pass C3 mechanical split). Shared fixtures stay in the parent
//! `tests` module and reach here through `use super::*;`.

use super::*;

#[test]
fn validate_calibration_rejects_uncalibrated_guider() {
    let calib = crate::GuidingCalibration {
        is_calibrated: false,
        ra_angle_deg: Some(0.0),
        dec_angle_deg: Some(90.0),
    };
    let result = validate_calibration_quality(&calib, &_cfg());
    assert!(result.is_err());
    assert!(result.unwrap_err().contains("not calibrated"));
}

#[test]
fn validate_calibration_accepts_perpendicular_axes() {
    let calib = crate::GuidingCalibration {
        is_calibrated: true,
        ra_angle_deg: Some(0.0),
        dec_angle_deg: Some(90.0),
    };
    assert!(validate_calibration_quality(&calib, &_cfg()).is_ok());
}

#[test]
fn validate_calibration_accepts_perpendicular_axes_modulo_180() {
    // Same physical geometry as (0°, 90°) — either axis could be the
    // "positive" pulse direction. The validator must not penalise this.
    let calib = crate::GuidingCalibration {
        is_calibrated: true,
        ra_angle_deg: Some(180.0),
        dec_angle_deg: Some(90.0),
    };
    assert!(validate_calibration_quality(&calib, &_cfg()).is_ok());
}

#[test]
fn validate_calibration_accepts_axes_within_tolerance() {
    // 15° off perpendicular — under the 20° default ceiling.
    let calib = crate::GuidingCalibration {
        is_calibrated: true,
        ra_angle_deg: Some(0.0),
        dec_angle_deg: Some(75.0),
    };
    assert!(validate_calibration_quality(&calib, &_cfg()).is_ok());
}

#[test]
fn validate_calibration_rejects_grossly_non_perpendicular_axes() {
    // Axes parallel — calibration was almost certainly broken (mount
    // pulsed in the same direction for both axes).
    let calib = crate::GuidingCalibration {
        is_calibrated: true,
        ra_angle_deg: Some(0.0),
        dec_angle_deg: Some(0.0),
    };
    let result = validate_calibration_quality(&calib, &_cfg());
    assert!(result.is_err());
    let msg = result.unwrap_err();
    assert!(msg.contains("off-perpendicular"), "got: {}", msg);
}

#[test]
fn validate_calibration_passes_when_angles_missing() {
    // Driver didn't report angles — we can't validate geometry, but the
    // is_calibrated flag is true so we let it through. The RMS sampling
    // step is the safety net for this case.
    let calib = crate::GuidingCalibration {
        is_calibrated: true,
        ra_angle_deg: None,
        dec_angle_deg: None,
    };
    assert!(validate_calibration_quality(&calib, &_cfg()).is_ok());
}

#[test]
fn validate_calibration_honours_custom_tolerance() {
    // 25° off perpendicular — over default 20° ceiling but under custom 30°.
    let calib = crate::GuidingCalibration {
        is_calibrated: true,
        ra_angle_deg: Some(0.0),
        dec_angle_deg: Some(65.0),
    };
    let strict = StartGuidingConfig::default();
    assert!(validate_calibration_quality(&calib, &strict).is_err());

    let lax = StartGuidingConfig {
        max_calibration_axis_error_deg: 30.0,
        ..StartGuidingConfig::default()
    };
    assert!(validate_calibration_quality(&calib, &lax).is_ok());
}

#[tokio::test(start_paused = true)]
async fn guiding_validation_failure_stops_started_guider() {
    let ops = Arc::new(
        ScriptedDomeRotatorOps::new().with_guider_calibration(GuidingCalibration {
            is_calibrated: false,
            ra_angle_deg: Some(0.0),
            dec_angle_deg: Some(90.0),
        }),
    );
    let ctx = ctx_with_ops(ops.clone()).await;
    let config = StartGuidingConfig {
        settle_time: 0.0,
        settle_timeout: 10.0,
        ..StartGuidingConfig::default()
    };

    let result = execute_start_guiding(&config, &ctx, None).await;

    assert_eq!(result.status, NodeStatus::Failure);
    assert_eq!(ops.guider_start_calls.load(Ordering::SeqCst), 1);
    assert_eq!(
        ops.guider_stop_calls.load(Ordering::SeqCst),
        1,
        "every post-start validation failure must stop the guider before returning"
    );
    assert!(!ops.guiding.load(Ordering::SeqCst));
}

/// What a StartGuiding run left behind: its result, whether the guider is
/// still guiding, and what the operator was told.
struct GuidingQualityRun {
    result: InstructionResult,
    still_guiding: bool,
    warnings: Vec<String>,
    decisions: Vec<String>,
    /// `guider_start` calls made before each fresh star selection.
    fresh_star_selections: Vec<u32>,
    guider_starts: u32,
    imaging_unguided: bool,
}

async fn start_guiding_with(
    ops: ScriptedDomeRotatorOps,
    stop_on_quality_problems: bool,
) -> GuidingQualityRun {
    let ops = Arc::new(ops);
    let mut ec = crate::node::context::ExecutionContext::new_for_test("guide".to_string());
    ec.device_ops = ops.clone();
    let mut state = crate::triggers::TriggerState::new();
    state.stop_on_quality_problems = stop_on_quality_problems;
    let trigger_state = Arc::new(tokio::sync::RwLock::new(state));
    ec.trigger_state = Some(trigger_state.clone());
    let (event_tx, mut events) = tokio::sync::broadcast::channel(64);
    ec.event_tx = Some(event_tx);
    let (decision_tx, mut decision_rx) = tokio::sync::broadcast::channel(64);
    ec.decision_tx = Some(decision_tx);
    let ctx = ec.to_instruction_context("guide").await;
    let config = StartGuidingConfig {
        settle_time: 0.0,
        settle_timeout: 10.0,
        ..StartGuidingConfig::default()
    };

    let result = execute_start_guiding(&config, &ctx, None).await;

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
    let fresh_star_selections = ops.fresh_star_selections.lock().unwrap().clone();
    let imaging_unguided = trigger_state.read().await.guiding.is_unguided();
    GuidingQualityRun {
        result,
        still_guiding: ops.guiding.load(Ordering::SeqCst),
        warnings,
        decisions,
        fresh_star_selections,
        guider_starts: ops.guider_start_calls.load(Ordering::SeqCst),
        imaging_unguided,
    }
}

/// StartGuiding has PHD2 pick a star from a fresh frame before it guides. On
/// the rig a StartGuiding after slew and center guided on the previous field's
/// lock position, which was empty sky.
#[tokio::test(start_paused = true)]
async fn start_guiding_selects_a_fresh_star_before_it_guides() {
    let run = start_guiding_with(ScriptedDomeRotatorOps::new(), false).await;
    assert_eq!(run.result.status, NodeStatus::Success, "{:?}", run.result);
    assert_eq!(
        run.fresh_star_selections,
        vec![0],
        "one fresh star selection, before the guider was started"
    );
    assert_eq!(run.guider_starts, 1);
}

/// No star in a fresh frame is the sky's judgment, not a fault: the operator
/// is told and the run images on unguided (owner decision 2026-10-06).
#[tokio::test(start_paused = true)]
async fn no_guide_star_notifies_and_the_run_images_unguided() {
    let run = start_guiding_with(ScriptedDomeRotatorOps::new().with_no_guide_star(), false).await;
    assert_eq!(run.result.status, NodeStatus::Success, "{:?}", run.result);
    assert_eq!(run.guider_starts, 0, "guiding started on the old star");
    assert!(run.imaging_unguided, "the run must know it images unguided");
    assert!(
        run.warnings
            .iter()
            .any(|w| w.contains("no guide star") && w.contains("Imaging continues unguided")),
        "{:?}",
        run.warnings
    );
}

/// The operator who asked for quality problems to stop the run gets a failed
/// StartGuiding.
#[tokio::test(start_paused = true)]
async fn no_guide_star_fails_start_guiding_when_the_operator_asked_for_it() {
    let run = start_guiding_with(ScriptedDomeRotatorOps::new().with_no_guide_star(), true).await;
    assert_eq!(run.result.status, NodeStatus::Failure);
    assert!(
        run.result
            .message
            .as_deref()
            .is_some_and(|m| m.contains("no guide star")),
        "{:?}",
        run.result.message
    );
    assert_eq!(run.guider_starts, 0);
    assert!(!run.imaging_unguided);
}

/// Owner decision 2026-10-06: a judgment the software makes about guiding
/// never stops a run by itself. Both StartGuiding checks — calibration axes
/// off-perpendicular, and RMS over the post-settle ceiling — failed the node,
/// which ended the run, on a guider that was guiding.
#[tokio::test(start_paused = true)]
async fn start_guiding_quality_checks_notify_and_keep_guiding() {
    let skewed = || {
        ScriptedDomeRotatorOps::new().with_guider_calibration(GuidingCalibration {
            is_calibrated: true,
            ra_angle_deg: Some(0.0),
            dec_angle_deg: Some(30.0),
        })
    };
    let noisy = || ScriptedDomeRotatorOps::new().with_guider_rms(5.0);

    for (label, ops, problem) in [
        ("skewed calibration", skewed(), "off-perpendicular"),
        (
            "high post-settle RMS",
            noisy(),
            "Post-settle guiding RMS too high",
        ),
    ] {
        let run = start_guiding_with(ops, false).await;
        assert_eq!(
            run.result.status,
            NodeStatus::Success,
            "{label}: {:?}",
            run.result.message
        );
        assert!(
            run.still_guiding,
            "{label}: the guider must be left guiding"
        );
        assert!(
            run.warnings
                .iter()
                .any(|w| w.contains(problem) && w.contains("The run continues")),
            "{label}: {:?}",
            run.warnings
        );
        assert_eq!(
            run.decisions,
            vec![crate::executor::QUALITY_PROBLEM_CONTINUED_SUMMARY],
            "{label}"
        );
    }

    // The operator who asked for quality problems to stop the run gets the
    // old behavior: the node fails and the guider is stopped.
    for (label, ops) in [
        ("skewed calibration", skewed()),
        ("high post-settle RMS", noisy()),
    ] {
        let run = start_guiding_with(ops, true).await;
        assert_eq!(run.result.status, NodeStatus::Failure, "{label}");
        assert!(!run.still_guiding, "{label}");
        assert!(run.decisions.is_empty(), "{label}: {:?}", run.decisions);
    }
}

/// After the guide-star recovery ran out the run images unguided (owner
/// decision 2026-10-06). The steps that need a guider must not then fail or
/// stall the run.
mod while_imaging_unguided {
    use super::*;

    struct UnguidedRun {
        result: InstructionResult,
        imaging_unguided: bool,
        warnings: Vec<String>,
        decisions: Vec<String>,
    }

    async fn unguided_ctx(
        ops: Arc<ScriptedDomeRotatorOps>,
    ) -> (
        InstructionContext,
        tokio::sync::broadcast::Receiver<crate::executor::ExecutorEvent>,
        tokio::sync::broadcast::Receiver<crate::decision::DecisionEvent>,
    ) {
        let mut ec = crate::node::context::ExecutionContext::new_for_test("guide".to_string());
        ec.device_ops = ops;
        let mut state = crate::triggers::TriggerState::new();
        state.guiding.set_unguided(true);
        ec.trigger_state = Some(Arc::new(tokio::sync::RwLock::new(state)));
        let (event_tx, events) = tokio::sync::broadcast::channel(64);
        ec.event_tx = Some(event_tx);
        let (decision_tx, decisions) = tokio::sync::broadcast::channel(64);
        ec.decision_tx = Some(decision_tx);
        (ec.to_instruction_context("guide").await, events, decisions)
    }

    async fn finish(
        ctx: &InstructionContext,
        result: InstructionResult,
        mut events: tokio::sync::broadcast::Receiver<crate::executor::ExecutorEvent>,
        mut decisions: tokio::sync::broadcast::Receiver<crate::decision::DecisionEvent>,
    ) -> UnguidedRun {
        let mut warnings = Vec::new();
        while let Ok(event) = events.try_recv() {
            if let crate::executor::ExecutorEvent::Warning { message } = event {
                warnings.push(message);
            }
        }
        let mut summaries = Vec::new();
        while let Ok(decision) = decisions.try_recv() {
            summaries.push(decision.summary);
        }
        UnguidedRun {
            result,
            imaging_unguided: ctx
                .trigger_state
                .as_ref()
                .unwrap()
                .read()
                .await
                .guiding
                .is_unguided(),
            warnings,
            decisions: summaries,
        }
    }

    #[tokio::test(start_paused = true)]
    async fn a_guider_that_cannot_start_does_not_fail_start_guiding() {
        let ops = Arc::new(ScriptedDomeRotatorOps::new().with_guider_resume_that_never_guides());
        let (ctx, events, decisions) = unguided_ctx(ops.clone()).await;
        let config = StartGuidingConfig {
            settle_time: 0.0,
            settle_timeout: 10.0,
            ..StartGuidingConfig::default()
        };

        let result = execute_start_guiding(&config, &ctx, None).await;
        let run = finish(&ctx, result, events, decisions).await;

        assert_eq!(
            run.result.status,
            NodeStatus::Success,
            "{:?}",
            run.result.message
        );
        assert!(run.imaging_unguided);
        assert_eq!(
            run.decisions,
            vec![crate::executor::QUALITY_PROBLEM_CONTINUED_SUMMARY]
        );
        assert!(
            run.warnings
                .iter()
                .any(|w| w.contains("did not reach active state") && w.contains("unguided")),
            "{:?}",
            run.warnings
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_guider_that_starts_ends_unguided_imaging() {
        let ops = Arc::new(ScriptedDomeRotatorOps::new());
        let (ctx, events, decisions) = unguided_ctx(ops.clone()).await;
        let config = StartGuidingConfig {
            settle_time: 0.0,
            settle_timeout: 10.0,
            ..StartGuidingConfig::default()
        };

        let result = execute_start_guiding(&config, &ctx, None).await;
        let run = finish(&ctx, result, events, decisions).await;

        assert_eq!(run.result.status, NodeStatus::Success);
        assert!(!run.imaging_unguided, "guiding is back");
    }

    #[tokio::test]
    async fn a_dither_node_is_skipped_without_asking_the_guider() {
        let ops = Arc::new(ScriptedDomeRotatorOps::new().with_dither_failing("Not guiding"));
        let (ctx, events, decisions) = unguided_ctx(ops.clone()).await;

        let result = execute_dither(&DitherConfig::default(), &ctx, None).await;
        let run = finish(&ctx, result, events, decisions).await;

        assert_eq!(run.result.status, NodeStatus::Success);
        assert!(
            ops.dithers_after_frame.lock().unwrap().is_empty(),
            "no dither may be sent to a guider that is not guiding"
        );
        assert!(
            run.result
                .message
                .as_deref()
                .is_some_and(|m| m.contains("unguided")),
            "{:?}",
            run.result.message
        );
    }
}

/// A context for the guiding restart before a light frame: a mount, the
/// run's trigger state, and the operator's feed.
async fn restart_ctx(
    ops: Arc<ScriptedDomeRotatorOps>,
) -> (
    InstructionContext,
    Arc<tokio::sync::RwLock<crate::triggers::TriggerState>>,
    tokio::sync::broadcast::Receiver<crate::executor::ExecutorEvent>,
) {
    let mut ec = crate::node::context::ExecutionContext::new_for_test("light".to_string());
    ec.device_ops = ops;
    ec.mount_id = Some("mount-1".to_string());
    let trigger_state = Arc::new(tokio::sync::RwLock::new(
        crate::triggers::TriggerState::new(),
    ));
    ec.trigger_state = Some(trigger_state.clone());
    let (event_tx, events) = tokio::sync::broadcast::channel(64);
    ec.event_tx = Some(event_tx);
    (
        ec.to_instruction_context("light").await,
        trigger_state,
        events,
    )
}

fn drain_warnings(
    events: &mut tokio::sync::broadcast::Receiver<crate::executor::ExecutorEvent>,
) -> Vec<String> {
    let mut warnings = Vec::new();
    while let Ok(event) = events.try_recv() {
        if let crate::executor::ExecutorEvent::Warning { message } = event {
            warnings.push(message);
        }
    }
    warnings
}

/// On 2026-10-24 the light frame's guiding restart ran for 51 min on a mount
/// stopped at its tracking limit, PHD2 sending 2.5 s pulses after a star the
/// sky carried away, and the run said "Imaging continues unguided". Nothing
/// is started on a mount that is not tracking; the restart waits for it and
/// the operator is told once.
#[tokio::test(start_paused = true)]
async fn guiding_is_not_restarted_on_a_mount_that_is_not_tracking() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new().with_mount_tracking(false));
    let (ctx, trigger_state, mut events) = restart_ctx(ops.clone()).await;
    trigger_state.write().await.guiding.set_resume_pending(true);

    assert!(resume_guiding_after_motion(&ctx).await.is_none());
    assert!(resume_guiding_after_motion(&ctx).await.is_none());

    assert_eq!(ops.guider_start_calls.load(Ordering::SeqCst), 0);
    assert!(trigger_state.read().await.guiding.resume_pending());
    let warnings = drain_warnings(&mut events);
    assert_eq!(
        warnings
            .iter()
            .filter(|w| w.contains("not tracking"))
            .count(),
        1,
        "{warnings:?}"
    );
    assert!(
        !warnings.iter().any(|w| w.contains("unguided")),
        "{warnings:?}"
    );

    *ops.mount_tracking.lock().unwrap() = Some(true);
    assert!(resume_guiding_after_motion(&ctx).await.is_none());
    assert_eq!(ops.guider_start_calls.load(Ordering::SeqCst), 1);
    let state = trigger_state.read().await;
    assert!(!state.guiding.resume_pending());
    assert!(state.guiding.is_enabled());
}

/// A night whose guiding was lost does not stay unguided: before a light
/// frame the run tries again every ten minutes, and says so when guiding is
/// back.
#[tokio::test(start_paused = true)]
async fn an_unguided_run_tries_guiding_again_every_ten_minutes() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new());
    let (ctx, trigger_state, mut events) = restart_ctx(ops.clone()).await;
    trigger_state.write().await.guiding.give_up_guiding();

    assert!(resume_guiding_after_motion(&ctx).await.is_none());
    assert_eq!(
        ops.guider_start_calls.load(Ordering::SeqCst),
        0,
        "not straight after the recovery gave up"
    );

    tokio::time::advance(UNGUIDED_RETRY_INTERVAL).await;
    assert!(resume_guiding_after_motion(&ctx).await.is_none());

    assert_eq!(ops.guider_start_calls.load(Ordering::SeqCst), 1);
    let state = trigger_state.read().await;
    assert!(!state.guiding.is_unguided());
    assert!(state.guiding.is_enabled());
    drop(state);
    let warnings = drain_warnings(&mut events);
    assert!(
        warnings
            .iter()
            .any(|w| w.contains("Guiding is running again")),
        "{warnings:?}"
    );
}

/// M10: "Guiding confirmed active: RMS total=0.00" was logged straight after
/// the guide command, before PHD2 had measured one guide step. An empty
/// statistics window does not confirm guiding.
#[tokio::test(start_paused = true)]
async fn guiding_without_a_measured_guide_step_is_not_confirmed() {
    let run = start_guiding_with(ScriptedDomeRotatorOps::new().with_guider_rms(0.0), false).await;
    assert_eq!(run.result.status, NodeStatus::Failure, "{:?}", run.result);
    assert!(
        run.result
            .message
            .as_deref()
            .is_some_and(|m| m.contains("did not reach active state")),
        "{:?}",
        run.result.message
    );
}

/// A tracking-limit hold stops the guider; a dither in that hold fails
/// against the stopped guider and reads as a guider error. It is skipped.
#[tokio::test]
async fn a_dither_is_skipped_while_the_run_holds_the_guider_stopped() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new());
    let (ctx, trigger_state, _events) = restart_ctx(ops.clone()).await;
    {
        let mut state = trigger_state.write().await;
        state
            .run
            .begin_hold(crate::triggers::RunHold::TrackingLimit);
        state.guiding.guiding_stopped_by_motion();
    }

    let result = execute_dither(&crate::DitherConfig::default(), &ctx, None).await;

    assert_eq!(result.status, NodeStatus::Success, "{:?}", result.message);
    assert!(
        result
            .message
            .as_deref()
            .is_some_and(|m| m.starts_with("Dither skipped")),
        "{:?}",
        result.message
    );
    assert!(
        ops.dithers_after_frame.lock().unwrap().is_empty(),
        "the guider is not asked to dither"
    );

    // A move's stopped guiding, not started again yet, is held the same way.
    trigger_state.write().await.run.end_hold();
    let result = execute_dither(&crate::DitherConfig::default(), &ctx, None).await;
    assert!(ops.dithers_after_frame.lock().unwrap().is_empty());
    assert!(result
        .message
        .is_some_and(|m| m.starts_with("Dither skipped")));

    // Guiding running again: the dither goes ahead.
    trigger_state.write().await.guiding.take_resume_pending();
    let _ = execute_dither(&crate::DitherConfig::default(), &ctx, None).await;
    assert_eq!(ops.dithers_after_frame.lock().unwrap().len(), 1);
}

/// A dither whose settle runs out while the guider holds the star is a
/// dither done: no failure, no failure streak, and the bar below the
/// measured RMS is told once.
#[tokio::test]
async fn a_dither_settle_that_runs_out_with_the_star_held_is_not_a_failure() {
    let ops = Arc::new(
        ScriptedDomeRotatorOps::new()
            .with_guiding(true)
            .with_guider_rms(0.62)
            .with_dither_failing("Dither did not settle: PHD2 settle failed (status 1): timed-out waiting for guider to settle"),
    );
    let (ctx, trigger_state, mut events) = restart_ctx(ops.clone()).await;
    let config = crate::DitherConfig {
        settle_pixels: 0.5,
        settle_time: 10.0,
        settle_timeout: 30.0,
        ..crate::DitherConfig::default()
    };

    for _ in 0..2 {
        let result = execute_dither(&config, &ctx, None).await;
        assert_eq!(result.status, NodeStatus::Success, "{:?}", result.message);
        assert!(
            !result.message.as_deref().unwrap_or("").contains("failed"),
            "{:?}",
            result.message
        );
    }
    assert_eq!(trigger_state.read().await.consecutive_dither_failures, 0);
    let warnings = drain_warnings(&mut events);
    assert_eq!(
        warnings
            .iter()
            .filter(|w| w.contains("did not settle below 0.5 px"))
            .count(),
        1,
        "{warnings:?}"
    );
    assert!(
        !warnings.iter().any(|w| w.contains("Dither failed")),
        "{warnings:?}"
    );
}

#[tokio::test]
async fn lost_star_rms_does_not_recommend_hundreds_of_pixels_for_settling() {
    let state = Arc::new(tokio::sync::RwLock::new(
        crate::triggers::TriggerState::new(),
    ));
    let settle = crate::GuiderSettle {
        pixels: 0.5,
        ..Default::default()
    };
    for (is_guiding, rms) in [(true, 134.89), (false, 1.0), (true, f64::NAN), (true, 0.0)] {
        let status = GuidingStatus {
            is_guiding,
            rms_ra: rms,
            rms_dec: 0.0,
            rms_total: rms,
        };
        assert!(settle_bar_warning(Some(&state), settle, &status)
            .await
            .is_none());
        assert!(!state.read().await.settle_bar_warning_given);
    }
    let held = GuidingStatus {
        is_guiding: true,
        rms_ra: 1.0,
        rms_dec: 0.0,
        rms_total: 1.0,
    };
    let warning = settle_bar_warning(Some(&state), settle, &held)
        .await
        .unwrap();
    assert!(warning.contains("currently reports 1.00 px"));
    assert!(!warning.contains("suits this guiding"));
    assert!(settle_bar_warning(Some(&state), settle, &held)
        .await
        .is_none());
}
