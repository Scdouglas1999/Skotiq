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
    let imaging_unguided = trigger_state.read().await.imaging_unguided;
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
        state.imaging_unguided = true;
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
                .imaging_unguided,
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
