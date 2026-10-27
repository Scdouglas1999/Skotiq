//! `Recenter`: the Drift Limit recovery, a Center run on the current target.

use super::*;

/// Solved reference and the planned target it belongs to. The target is
/// checked after acquiring the camera so a late frame cannot slew back to
/// a target the sequence has already left.
pub(in super::super) struct FrameReference {
    pub target_ra_deg: f64,
    pub target_dec_deg: f64,
    pub ra_deg: f64,
    pub dec_deg: f64,
}

/// What a trigger-fired recenter needs.
pub(in super::super) struct RecenterRequest<'a> {
    pub trigger_id: &'a str,
    pub trigger_name: &'a str,
    pub rig: &'a Rig,
    pub run: &'a RunControl,
    pub decisions: &'a DecisionLog,
    /// Whether the operator has been told about the current run of recenters
    /// that could not solve; a successful recenter ends that run.
    pub failure_told: &'a mut bool,
    pub camera_claim: &'a mut TriggerCameraClaim,
    pub reference: Option<FrameReference>,
}

pub(in super::super) async fn run(request: RecenterRequest<'_>) -> ActionFlow {
    let RecenterRequest {
        trigger_id,
        trigger_name,
        rig,
        run,
        decisions,
        failure_told,
        camera_claim,
        reference,
    } = request;
    tracing::info!(
        "[DRIFT] Trigger '{}' fired - executing recenter",
        trigger_name
    );
    let mut target = rig.target().await;
    if let Some(reference) = reference {
        if target.ra_hours != Some(reference.target_ra_deg / 15.0)
            || target.dec_degrees != Some(reference.target_dec_deg)
        {
            return ActionFlow::NotRun;
        }
        target.ra_hours = Some(reference.ra_deg / 15.0);
        target.dec_degrees = Some(reference.dec_deg);
    }
    if target.ra_hours.is_none() || target.dec_degrees.is_none() {
        tracing::error!(
            "[DRIFT] Recenter requested but no target RA/Dec set; pausing for operator intervention"
        );
        run.pause(None).await;
        camera_claim.release().await;
        return ActionFlow::Finished;
    }
    let recenter_ctx = rig.instruction_context(target, run);
    let center_config = crate::CenterConfig {
        use_target_coords: true,
        custom_ra: None,
        custom_dec: None,
        accuracy_arcsec: 10.0,
        max_attempts: 3,
        exposure_duration: 5.0,
        filter: None,
    };
    let result = crate::instructions::execute_center(&center_config, &recenter_ctx, None).await;
    // The solve exposures are done; the capture loop may go on.
    camera_claim.release().await;
    let stop_on_quality_problems = rig.trigger_state.read().await.stop_on_quality_problems;
    if result.status == NodeStatus::Success {
        *failure_told = false;
    } else if crate::instructions::center_did_not_converge(&result) && !stop_on_quality_problems {
        // Not solving or converging (cloud, a sparse field) is a judgment, not
        // a fault: the frames carry on where the mount points and the operator
        // is told once per run of failures.
        let problem = format!(
            "{}. The mount stays where the last correction put it.",
            result
                .message
                .as_deref()
                .unwrap_or("Recenter did not converge")
        );
        if *failure_told {
            tracing::warn!("[DRIFT] Recenter failed again: {}", problem);
        } else {
            *failure_told = true;
            let continuation = crate::executor::quality_problem_continuation(
                &format!("{trigger_name} recenter"),
                &problem,
                serde_json::json!({ "trigger_id": trigger_id }),
            );
            tracing::warn!("[DRIFT] {}", continuation.operator_message);
            decisions.send(continuation.decision);
            run.warning(continuation.operator_message);
        }
    } else {
        tracing::warn!(
            "[DRIFT] Recenter failed: {:?} - pausing sequence",
            result.message
        );
        run.pause(None).await;
        run.error(format!(
            "DriftLimit recenter failed: {}",
            result.message.unwrap_or_default()
        ));
    }
    ActionFlow::Finished
}
