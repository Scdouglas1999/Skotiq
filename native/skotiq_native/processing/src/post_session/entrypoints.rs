use crate::post_session::args::IntegrateSessionArgs;
use crate::post_session::calibration_master::{
    build_calibration_master_impl, BuildCalibrationMasterArgs,
};
use crate::post_session::cancel::{cancel_op, PostSessionCancelArgs};
use crate::post_session::delivery::master_deliver;
use crate::post_session::integrate::run_integration;
use crate::post_session::masters::{
    build_master_flat_impl, master_add, master_create, master_finalize, master_info,
    save_fits_master_impl, BuildMasterFlatArgs, MasterOp, SaveFitsMasterArgs,
};
use crate::post_session::multi_night::{check_build_calibration, master_build};
use crate::post_session::telemetry::emit_pass_telemetry;

/// The work behind the bridge's `api_integrate_session`, which describes the request
/// and the reply.
pub fn integrate_session(args_json: String) -> Result<String, String> {
    let args: IntegrateSessionArgs =
        serde_json::from_str(&args_json).map_err(|e| format!("invalid integrate args: {e}"))?;
    let run_id = args.run_id.clone();
    let lane = args.telemetry.lane.clone();
    let result = run_integration(args);
    match &result {
        Ok(r) => tracing::info!(
            "integration {run_id:?} finished: {} subs integrated, {} rejected",
            r.frames_integrated,
            r.frames_rejected
        ),
        Err(e) => tracing::warn!("integration {run_id:?} failed: {e}"),
    }
    emit_pass_telemetry(
        &run_id,
        "run_ended",
        serde_json::json!({
            "lane": lane,
            "ok": result.is_ok(),
            "error": result.as_ref().err(),
        }),
    );
    let result = result?;
    serde_json::to_string(&result).map_err(|e| format!("failed to encode result: {e}"))
}

/// The work behind the bridge's `api_master_accumulate`, which describes the request
/// and the reply.
pub fn master_accumulate(args_json: String) -> Result<String, String> {
    let op: MasterOp =
        serde_json::from_str(&args_json).map_err(|e| format!("invalid accumulate args: {e}"))?;
    let started = std::time::Instant::now();
    let result = master_accumulate_op(&op.op, &args_json);
    match &result {
        Ok(_) => tracing::info!(
            "master {} finished in {:.1} s",
            op.op,
            started.elapsed().as_secs_f64()
        ),
        Err(e) => tracing::warn!(
            "master {} failed after {:.1} s: {e}",
            op.op,
            started.elapsed().as_secs_f64()
        ),
    }
    result
}

fn master_accumulate_op(op: &str, args_json: &str) -> Result<String, String> {
    let encoded = match op {
        "create" => serde_json::to_string(&master_create(args_json)?),
        "add" => serde_json::to_string(&master_add(args_json)?),
        "finalize" => serde_json::to_string(&master_finalize(args_json)?),
        "info" => serde_json::to_string(&master_info(args_json)?),
        "build" => serde_json::to_string(&master_build(args_json)?),
        "checkCalibration" => serde_json::to_string(&check_build_calibration(args_json)?),
        "deliverUniform" => serde_json::to_string(&super::uniform_delivery::deliver(args_json)?),
        "registrationPreview" => serde_json::to_string(
            &super::registration_preview::registration_preview(args_json)?,
        ),
        "deliver" => serde_json::to_string(&master_deliver(args_json)?),
        other => {
            return Err(format!(
                "unknown master op '{other}'; expected create/add/finalize/info/build/checkCalibration/deliver/deliverUniform/registrationPreview"
            ))
        }
    };
    encoded.map_err(|e| format!("failed to encode result: {e}"))
}

/// The work behind the bridge's `api_build_master_flat`, which describes the request
/// and the reply.
pub fn build_master_flat(args_json: String) -> Result<String, String> {
    let args: BuildMasterFlatArgs =
        serde_json::from_str(&args_json).map_err(|e| format!("invalid flat args: {e}"))?;
    let output = args.output_path.clone();
    let result = build_master_flat_impl(args).inspect_err(|e| {
        tracing::warn!("master flat '{output}' failed: {e}");
    })?;
    tracing::info!(
        "master flat '{output}' built from {} flats ({} left out)",
        result.frame_count,
        result.excluded.len()
    );
    serde_json::to_string(&result).map_err(|e| format!("failed to encode result: {e}"))
}

/// The work behind the bridge's `api_build_calibration_master`, which describes the request
/// and the reply.
pub fn build_calibration_master(args_json: String) -> Result<String, String> {
    let args: BuildCalibrationMasterArgs = serde_json::from_str(&args_json)
        .map_err(|e| format!("invalid calibration master args: {e}"))?;
    let result = build_calibration_master_impl(args)
        .inspect_err(|e| tracing::warn!("calibration master failed: {e}"))?;
    serde_json::to_string(&result).map_err(|e| format!("failed to encode result: {e}"))
}

/// The work behind the bridge's `api_save_fits_master`, which describes the request
/// and the reply.
pub fn save_fits_master(args_json: String) -> Result<String, String> {
    let args: SaveFitsMasterArgs =
        serde_json::from_str(&args_json).map_err(|e| format!("invalid save args: {e}"))?;
    let result = save_fits_master_impl(args)?;
    serde_json::to_string(&result).map_err(|e| format!("failed to encode result: {e}"))
}

/// The work behind the bridge's `api_post_session_cancel`, which describes the request
/// and the reply.
pub fn post_session_cancel(args_json: String) -> Result<String, String> {
    let args: PostSessionCancelArgs =
        serde_json::from_str(&args_json).map_err(|e| format!("invalid cancel args: {e}"))?;
    let result = cancel_op(args)?;
    serde_json::to_string(&result).map_err(|e| format!("failed to encode result: {e}"))
}
