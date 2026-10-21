//! `Autofocus`: a trigger-fired focus sweep, and what the run does with its
//! verdict. A failed sweep never parks or ends the run; one that left the
//! guider dead pauses it.

use super::*;

/// What a trigger-fired autofocus needs.
pub(in super::super) struct AutofocusRequest<'a> {
    pub trigger_id: &'a str,
    pub trigger_name: &'a str,
    pub rig: &'a Rig,
    pub run: &'a RunControl,
    pub decisions: &'a DecisionLog,
    /// The context progress is published through, under a synthetic node id.
    pub progress_context: &'a ExecutionContext,
    pub camera_claim: &'a mut TriggerCameraClaim,
}

pub(in super::super) async fn run(request: AutofocusRequest<'_>) -> ActionFlow {
    let AutofocusRequest {
        trigger_id,
        trigger_name,
        rig,
        run,
        decisions,
        progress_context,
        camera_claim,
    } = request;
    tracing::info!("Executing autofocus as trigger recovery action");
    if let Some(missing) = autofocus_trigger_skip_reason(
        rig.context.camera_id.as_ref(),
        rig.context.focuser_id.as_ref(),
    ) {
        skip_impossible_autofocus(trigger_name, missing, rig, run).await;
        return ActionFlow::Finished;
    }

    let af_ctx = rig.instruction_context(rig.target().await, run);
    // The operator's tuning, seeded at start from the sequence's Autofocus
    // node or pushed through the runtime config.
    let af_config = match rig.runtime_config.read().autofocus.clone() {
        Some(cfg) => cfg,
        None => {
            tracing::warn!(
                "Trigger autofocus running with LIBRARY DEFAULTS \
                 (no Autofocus node / profile AF config available) — \
                 focus quality may suffer on a non-default rig"
            );
            crate::AutofocusConfig::default()
        }
    };
    let progress_context = progress_context.clone();
    let progress_node_id = format!("trigger:{trigger_id}:autofocus");
    let completed_node_id = progress_node_id.clone();
    // A synthesized node has no tree entry to name it, so it names itself in
    // the shape a tree node uses before it reports progress.
    progress_context.send_progress(ProgressUpdate::lifecycle(
        progress_node_id.clone(),
        NodeStatus::Running,
        format!("Executing: Autofocus ({trigger_name})"),
    ));
    // Admission is taken here so a refocus turned away by another autofocus
    // is told apart from one that ran and failed. It moved nothing, so the
    // stale-focus latch is kept and the trigger asks again after its
    // cooldown.
    let Some(af_admission) = crate::instructions::try_admit_autofocus_run() else {
        camera_claim.release().await;
        let message = format!(
            "Trigger '{trigger_name}' asked for an autofocus while another \
             autofocus held the camera and focuser. This refocus was \
             skipped; the trigger will ask again."
        );
        tracing::warn!("{}", message);
        run.send(ExecutorEvent::NodeCompleted {
            id: completed_node_id,
            status: NodeStatus::Skipped,
        });
        run.warning(message);
        return ActionFlow::Finished;
    };
    let total_steps = af_config.steps_out.saturating_mul(2).saturating_add(1);
    let progress_fn = move |progress: f64, detail_str: String| {
        let (step, hfr) = parse_autofocus_detail(&detail_str);
        progress_context.send_progress(ProgressUpdate::instruction_progress(
            progress_node_id.clone(),
            "Autofocus",
            progress,
            ProgressDetail::Autofocus {
                step: step.unwrap_or(0),
                total_steps,
                current_hfr: hfr,
            },
        ));
    };
    // Recorded so the decision row can name the focus the run kept.
    let position_before_af =
        read_focuser_position(&rig.device_ops, rig.context.focuser_id.as_ref()).await;

    let af_result = crate::instructions::execute_autofocus_admitted(
        &af_config,
        &af_ctx,
        Some(&progress_fn),
        af_admission,
    )
    .await;

    // A sweep that left the guider dead is held below. Freeze the node tree
    // before handing the camera back, or the capture loop, waiting past its
    // pause check, starts one more unguided light.
    if af_result.status == NodeStatus::Failure
        && !run.is_cancelled()
        && autofocus_trigger_failure_cost(af_result.data.as_ref())
            == AutofocusTriggerFailureCost::EveryFrameUnguided
    {
        run.hold_node_tree();
    }
    camera_claim.release().await;

    // The sweep's own status, so a cancelled sweep reports cancelled.
    run.send(ExecutorEvent::NodeCompleted {
        id: completed_node_id,
        status: af_result.status,
    });

    if af_result.status == NodeStatus::Success {
        if let Some(best_hfr) = af_result.hfr_values.first() {
            let mut ts = rig.trigger_state.write().await;
            ts.update_hfr(*best_hfr);
            ts.reset_baseline_hfr();
            ts.mark_autofocus_performed();
        }
        return ActionFlow::Finished;
    }
    if af_result.status == NodeStatus::Cancelled || run.is_cancelled() {
        // A sweep the stop cut short is not a failed autofocus.
        tracing::info!(
            "Trigger autofocus '{}' ended by the run stopping; not \
             judging it as a failed refocus",
            trigger_name
        );
        return ActionFlow::Finished;
    }
    judge_failed_sweep(FailedSweep {
        trigger_id,
        trigger_name,
        rig,
        run,
        decisions,
        af_result,
        tolerance_ratio: af_config.failure_hfr_tolerance_ratio,
        position_before_af,
    })
    .await;
    ActionFlow::Finished
}

/// No camera or no focuser: the action is impossible rather than failing, and
/// a run must not be held by a recovery it can never perform. The stale-focus
/// latch is dropped so the trigger stops re-forcing, and imaging continues.
/// `start()` disarms these triggers when there is no focuser; this covers a
/// device that disappears mid-run.
async fn skip_impossible_autofocus(trigger_name: &str, missing: &str, rig: &Rig, run: &RunControl) {
    tracing::warn!(
        "Autofocus trigger '{}' fired but {} configured; \
         skipping the refocus and continuing the run",
        trigger_name,
        missing
    );
    rig.trigger_state
        .write()
        .await
        .clear_autofocus_invalidation();
    run.error(format!(
        "Trigger '{trigger_name}' asked for an autofocus but {missing} \
         configured for this run. The refocus was skipped and imaging \
         continues — focus is not being corrected automatically."
    ));
}

struct FailedSweep<'a> {
    trigger_id: &'a str,
    trigger_name: &'a str,
    rig: &'a Rig,
    run: &'a RunControl,
    decisions: &'a DecisionLog,
    af_result: crate::instructions::InstructionResult,
    tolerance_ratio: f64,
    position_before_af: Option<i32>,
}

/// A sweep that did not converge. The run carries on at the focus the sweep
/// restored, and the operator is told how the frames measure, unless the
/// sweep left the guider stopped, which pauses the run.
async fn judge_failed_sweep(sweep: FailedSweep<'_>) {
    let FailedSweep {
        trigger_id,
        trigger_name,
        rig,
        run,
        decisions,
        af_result,
        tolerance_ratio,
        position_before_af,
    } = sweep;
    // Read the reference before `reset_baseline_hfr` overwrites it.
    let verdict = {
        let ts = rig.trigger_state.read().await;
        autofocus_failure_verdict(ts.baseline_hfr, ts.current_hfr, tolerance_ratio)
    };
    {
        let mut ts = rig.trigger_state.write().await;
        // Re-base on the degraded HFR, and move the cadence anchor: the
        // interval trigger has no time cooldown and would re-fire the failed
        // sweep after every frame.
        ts.reset_baseline_hfr();
        ts.mark_autofocus_attempted();
        tracing::warn!(
            "Autofocus failed — HFR baseline reset to current value ({:?}) \
             and the interval cadence anchor advanced so the failed sweep \
             does not re-fire on every subsequent frame",
            ts.baseline_hfr
        );
    }

    // Absent (not `false`) when the sweep never moved the focuser.
    let origin_restored = af_result
        .data
        .as_ref()
        .and_then(|data| data.get("autofocus_origin_restored"))
        .and_then(|value| value.as_bool());
    let position_after_af =
        read_focuser_position(&rig.device_ops, rig.context.focuser_id.as_ref()).await;
    let failure_cost = autofocus_trigger_failure_cost(af_result.data.as_ref());
    let reason = af_result
        .message
        .unwrap_or_else(|| "autofocus did not converge".to_string());

    if failure_cost == AutofocusTriggerFailureCost::EveryFrameUnguided {
        // The guider was stopped and not proven back. Every further frame
        // would trail, so the run pauses: reversible by one button, and
        // nothing is moved or closed. Safety triggers keep acting while
        // paused. Decided before the focus verdict, which a dead guider with
        // good focus would otherwise pass.
        let hold =
            autofocus_trigger_unguided_hold(trigger_id, trigger_name, &reason, position_after_af);
        decisions.send(hold.decision);
        tracing::error!("{}", hold.operator_message);
        // Or the trigger re-fires on resume and stops the guider again.
        rig.trigger_state
            .write()
            .await
            .clear_autofocus_invalidation();
        run.pause(Some(
            "Paused: autofocus left the guider stopped".to_string(),
        ))
        .await;
        run.error(hold.operator_message);
        return;
    }

    // A failed autofocus never parks, closes or ends the run; the focuser is
    // already back where the sweep started. A Warning, not an Error: every
    // sequencer Error reads as a failed run.
    let focus_note = match verdict {
        AutofocusOutcome::KeepImaging { .. } => format!(
            " {}, so frames will be slightly soft until focus is \
             retried.",
            verdict.describe()
        ),
        AutofocusOutcome::TooSoft { .. } => format!(
            " {}: frames may be soft enough to be rejected — check \
             focus.",
            verdict.describe()
        ),
        AutofocusOutcome::Unmeasurable => String::new(),
    };
    let continuation = autofocus_trigger_continuation(
        trigger_id,
        trigger_name,
        &reason,
        position_before_af,
        position_after_af,
        origin_restored,
    );
    decisions.send(continuation.decision);
    let message = format!("{}{}", continuation.operator_message, focus_note);
    tracing::warn!("{}", message);
    run.warning(message);
}
