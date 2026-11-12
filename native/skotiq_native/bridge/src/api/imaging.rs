// split from monolithic api.rs
#![allow(unused_imports)]
// Shared imports inherited from the monolithic api.rs.
//
// # `as`-cast policy
//
// This file is the FFI surface for imaging; numeric casts cluster into:
// - **Sensor-dimension widening** (`u32 as usize`, `u32 as f64`): >=32-bit
//   usize on every target; f64 mantissa fits any real sensor's pixel count.
// - **Bin / gain / exposure config** (`f64 as u16` or `u32 as f64`): bounded
//   by camera-driver advertised ranges. Saturation per Rust 1.45 spec matches
//   the "clamp out-of-range UI value" intent at the FFI boundary.
// - **Simulator math** (synthetic exposure path): pixel counts and star
//   counts are bounded by simulator config, and `width * height` allocations
//   use `checked_mul` with `u64` promotion (see `simulate_*` helpers below).
// - **Histogram indexing** (`pixel as usize`): pixel is u16; usize on every
//   target trivially holds 65536 entries.
//
// Sites with their own `Why:` comment override the module-level reasoning.
//
// # `unwrap_or` policy
//
// Three documented patterns appear in this file:
//
// 1. **Float partial_cmp in sort** — `a.partial_cmp(b).unwrap_or(Ordering::Equal)`.
//    Required because `f32`/`f64` are `PartialOrd`, not `Ord`, due to NaN.
//    Treating NaN as `Equal` keeps the sort stable; HFR/SNR computation
//    upstream already filters out NaN before this point, so the fallback is
//    only protective.
// 2. **`SystemTime::elapsed().unwrap_or(Duration::ZERO)`** — `elapsed()`
//    only errors when the monotonic clock went backwards (a system-clock
//    adjustment). Reporting "0 elapsed" is the standard recovery and our
//    timing dashboards already skip the resulting outlier frame.
// 3. **Optional config defaults** — `config.min_hfr.unwrap_or(1.0)`,
//    `config.min_snr.unwrap_or(5.0)`, `config.max_sharpness.unwrap_or(0.95)`,
//    `BITPIX.unwrap_or(16)`, `extension().unwrap_or("fits")`. These are the
//    documented Skotiq-default science thresholds and FITS-format
//    fallback used when the FFI caller passes a minimal config. The same
//    defaults are surfaced in the science-quality UI as the placeholders.
// 4. **`min().unwrap_or(0)` / `max().unwrap_or(0)`** — empty image stripe
//    would already have failed validation upstream; `0` here is unreachable
//    but cheaper than `expect`. The `&min == &max == 0` produces a flat
//    histogram which the renderer handles gracefully.
//
// Hard-error paths (FFI deserialisation failures, missing-device errors)
// remain `Result<_, String>` propagation; no error class is silenced.
use crate::adaptive_polling::{AdaptivePoller, PollerPreset};
use crate::device::*;
use crate::device_manager::DeviceManager;
use crate::error::*;
use crate::event::*;
use crate::state::*;
use crate::storage::{AppSettings, ObserverLocation};
use crate::unified_device_ops::create_unified_device_ops;
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use skotiq_imaging::{
    calculate_airmass, validate_fits_header, validate_image, write_fits, BayerPattern,
    DebayerAlgorithm, FitsHeader, ImageData,
};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::sync::OnceLock;
use std::time::{Duration, Instant};
use tokio::sync::Mutex;
use tokio::sync::RwLock;
// Sibling-module items via the parent's pub use re-exports.
use super::*;

/// Global cancellation token for autofocus
pub(crate) static AUTOFOCUS_CANCEL_TOKEN: OnceLock<Arc<AtomicBool>> = OnceLock::new();

pub(crate) fn get_autofocus_cancel_token() -> &'static Arc<AtomicBool> {
    // OnceLock is immutable after initialization, so reuse one persistent token
    // and reset its flag between autofocus runs.
    AUTOFOCUS_CANCEL_TOKEN.get_or_init(|| Arc::new(AtomicBool::new(false)))
}

/// The [`InstructionContext`] a one-shot focus operation driven from the API
/// needs: standalone autofocus and focuser backlash calibration drive the
/// camera and focuser for an operator, outside any sequence run, and report
/// through the executor-event bridge.
fn one_shot_focus_context(
    camera_id: String,
    focuser_id: String,
    cancellation_token: Arc<AtomicBool>,
    event_tx: tokio::sync::broadcast::Sender<skotiq_sequencer::ExecutorEvent>,
    device_ops: skotiq_sequencer::SharedDeviceOps,
) -> skotiq_sequencer::instructions::InstructionContext {
    let mut run = skotiq_sequencer::instructions::RunShared::new(device_ops);
    run.rig.camera_id = Some(camera_id);
    run.rig.focuser_id = Some(focuser_id);
    run.event_tx = Some(event_tx);
    skotiq_sequencer::instructions::InstructionContext::new(run, cancellation_token)
}

/// Autofocus configuration for API
#[derive(Debug, Clone)]
pub struct AutofocusConfigApi {
    pub exposure_time: f64,
    pub step_size: i32,
    pub steps_out: i32,
    pub method: String, // "VCurve", "Hyperbolic", "Parabolic"
    pub binning: i32,
    pub gain: Option<i32>,
    pub offset: Option<i32>,
    pub number_of_attempts: u32,
    pub exposures_per_point: u32,
    pub r_squared_threshold: f64,
    pub outer_crop_ratio: f64,
    pub inner_crop_ratio: f64,
    pub use_brightest_n_stars: u32,
    pub focuser_settle_time_ms: u64,
    pub backlash_comp_method: String,
    pub backlash_in: i32,
    pub backlash_out: i32,
    /// Backlash this app measured on THIS focuser, from its stored
    /// calibration. `None` when it has never been calibrated.
    ///
    /// Never gated on `backlash_comp_method`, unlike `backlash_in`. That
    /// selector governs the overshoot moves during the sweep; this figure only
    /// sizes the final run-up, which happens either way because best focus has
    /// to be reached from the same side it was measured from. All this does is
    /// make that unavoidable move shorter and aimed at a known clearance
    /// instead of running all the way back to the sweep's start.
    pub measured_backlash_in: Option<i32>,
}

/// A single focus data point (position and HFR)
#[derive(Debug, Clone)]
pub struct FocusDataPoint {
    pub position: i32,
    pub hfr: f64,
    pub fwhm: Option<f64>,
    pub star_count: u32,
}

/// Autofocus result containing all data for display and analysis
#[derive(Debug, Clone)]
pub struct AutofocusResultApi {
    pub best_position: i32,
    pub best_hfr: f64,
    pub focus_data: Vec<FocusDataPoint>,
    pub method: String,
    pub temperature: Option<f64>,
    pub timestamp: i64,
    pub curve_fit_quality: f64,
    pub backlash_applied: bool,
}

/// Run autofocus
pub async fn api_run_autofocus(
    device_id: String, // Focuser ID
    camera_id: String,
    config: AutofocusConfigApi,
) -> Result<AutofocusResultApi, SkotiqError> {
    tracing::info!(
        "Starting autofocus with camera {} and focuser {}",
        camera_id,
        device_id
    );

    if !config.exposure_time.is_finite() || config.exposure_time <= 0.0 {
        return Err(SkotiqError::InvalidParameter(
            "autofocus exposure time must be finite and positive".to_string(),
        ));
    }
    if config.step_size <= 0 || !(1..=50).contains(&config.steps_out) {
        return Err(SkotiqError::InvalidParameter(
            "autofocus step size must be positive and steps out must be 1..50".to_string(),
        ));
    }
    if !(1..=4).contains(&config.binning)
        || !(1..=10).contains(&config.number_of_attempts)
        || !(1..=20).contains(&config.exposures_per_point)
    {
        return Err(SkotiqError::InvalidParameter(
            "autofocus binning, attempts, or exposures-per-point is out of range".to_string(),
        ));
    }
    if !config.r_squared_threshold.is_finite()
        || !(0.0..=1.0).contains(&config.r_squared_threshold)
        || !config.outer_crop_ratio.is_finite()
        || !config.inner_crop_ratio.is_finite()
        || config.outer_crop_ratio <= 0.0
        || config.outer_crop_ratio > 1.0
        || config.inner_crop_ratio < 0.0
        || config.inner_crop_ratio >= config.outer_crop_ratio
    {
        return Err(SkotiqError::InvalidParameter(
            "autofocus R²/crop settings are invalid".to_string(),
        ));
    }
    if config.focuser_settle_time_ms > 10_000 || config.backlash_in < 0 || config.backlash_out < 0 {
        return Err(SkotiqError::InvalidParameter(
            "autofocus settle/backlash settings are out of range".to_string(),
        ));
    }
    if config.gain.is_some_and(|gain| gain < 0) || config.offset.is_some_and(|offset| offset < 0) {
        return Err(SkotiqError::InvalidParameter(
            "autofocus gain and offset cannot be negative".to_string(),
        ));
    }

    use serde::Deserialize;
    use skotiq_sequencer::instructions::{
        execute_autofocus_admitted, try_admit_autofocus_run, AutofocusProgress, InstructionContext,
    };
    use skotiq_sequencer::{AutofocusConfig, AutofocusMethod, Binning, NodeStatus};
    use std::time::{SystemTime, UNIX_EPOCH};

    #[derive(Debug, Deserialize)]
    struct LegacyAutofocusPayload {
        best_position: i32,
        best_hfr: f64,
        r_squared: f64,
        focus_data: Vec<(i32, f64)>,
    }

    let autofocus_guard = try_admit_autofocus_run().ok_or_else(|| SkotiqError::DeviceBusy {
        device_id: device_id.clone(),
        current_operation: "autofocus".to_string(),
    })?;

    // Reset cancellation token only after admission. A rejected second Start
    // must never clear the active run's pending cancellation request.
    let cancel_token = get_autofocus_cancel_token();
    cancel_token.store(false, Ordering::Relaxed);

    let method_str = config.method.clone();

    // Map method string to enum
    let method = match config.method.as_str() {
        "Hyperbolic" => AutofocusMethod::Hyperbolic,
        "Parabolic" => AutofocusMethod::Quadratic,
        _ => AutofocusMethod::VCurve,
    };

    // Map binning
    let binning = match config.binning {
        2 => Binning::Two,
        3 => Binning::Three,
        4 => Binning::Four,
        _ => Binning::One,
    };

    let backlash_enabled = !config
        .backlash_comp_method
        .trim()
        .eq_ignore_ascii_case("none");
    let af_config = AutofocusConfig {
        exposure_duration: config.exposure_time,
        step_size: config.step_size,
        steps_out: config.steps_out as u32,
        method,
        binning,
        filter: None, // Optional: add filter support
        gain: config.gain,
        offset: config.offset,
        max_duration_secs: 600.0,
        number_of_attempts: config.number_of_attempts,
        exposures_per_point: config.exposures_per_point,
        r_squared_threshold: config.r_squared_threshold,
        outer_crop_ratio: config.outer_crop_ratio,
        inner_crop_ratio: config.inner_crop_ratio,
        use_brightest_n_stars: config.use_brightest_n_stars,
        focuser_settle_time_ms: config.focuser_settle_time_ms,
        backlash_compensation: if backlash_enabled {
            config.backlash_in
        } else {
            0
        },
        backlash_out_compensation: if backlash_enabled {
            config.backlash_out
        } else {
            0
        },
        measured_backlash_in: config.measured_backlash_in,
        ..AutofocusConfig::default()
    };

    // Create context - use UnifiedDeviceOps which routes through DeviceManager
    let device_ops = create_unified_device_ops();

    // Try to get focuser temperature before autofocus
    let temperature = device_ops
        .focuser_get_temperature(&device_id)
        .await
        .ok()
        .flatten();

    // spawn an executor-event bridge so instruction-level
    // emergencies (FITS-save failures from the autofocus V-curve frames, etc.)
    // reach the same SkotiqEvent stream Dart subscribes to. Without this
    // the user only sees a generic "autofocus failed" return code with no
    // hint that the underlying problem was a write error or drive disconnect.
    // The original sender lives on the stack for the duration of the call;
    // the cloned handle is moved into `RunShared::event_tx`. When the
    // function returns and the binding is dropped, the background bridge task
    // exits naturally.
    let event_tx =
        crate::util::executor_event_bridge::spawn_executor_event_bridge(get_state().clone());
    let progress_focuser_id = device_id.clone();

    let ctx = one_shot_focus_context(
        camera_id,
        device_id,
        cancel_token.clone(),
        event_tx.clone(),
        device_ops,
    );

    let progress_fn = |_: f64, progress: &AutofocusProgress| {
        let Some(sweep) = progress.sweep() else {
            return;
        };
        get_state().publish_equipment_event(
            EquipmentEvent::PropertyChanged {
                device_type: "focuser".to_string(),
                device_id: progress_focuser_id.clone(),
                property: "AutofocusProgress".to_string(),
                value: sweep.to_json(),
            },
            EventSeverity::Info,
        );
    };

    let result =
        execute_autofocus_admitted(&af_config, &ctx, Some(&progress_fn), autofocus_guard).await;

    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);

    match result.status {
        NodeStatus::Success => {
            let data = result.data.ok_or_else(|| {
                SkotiqError::OperationFailed(
                    "Autofocus completed without a result payload".to_string(),
                )
            })?;

            // Canonical payload (skotiq_sequencer::AutofocusResult)
            if let Ok(af_result) =
                serde_json::from_value::<skotiq_sequencer::AutofocusResult>(data.clone())
            {
                let focus_data: Vec<FocusDataPoint> = af_result
                    .data_points
                    .iter()
                    .map(|dp| FocusDataPoint {
                        position: dp.position,
                        hfr: dp.hfr,
                        fwhm: dp.fwhm,
                        star_count: dp.star_count,
                    })
                    .collect();

                return Ok(AutofocusResultApi {
                    best_position: af_result.best_position,
                    best_hfr: af_result.best_hfr,
                    focus_data,
                    method: method_str,
                    temperature: af_result.temperature_celsius.or(temperature),
                    timestamp,
                    curve_fit_quality: af_result.curve_fit_quality,
                    backlash_applied: af_result.backlash_applied,
                });
            }

            // Backward compatibility for legacy tuple payloads
            if let Ok(legacy) = serde_json::from_value::<LegacyAutofocusPayload>(data.clone()) {
                let focus_data = legacy
                    .focus_data
                    .into_iter()
                    .map(|(position, hfr)| FocusDataPoint {
                        position,
                        hfr,
                        fwhm: None,
                        star_count: 0,
                    })
                    .collect();
                return Ok(AutofocusResultApi {
                    best_position: legacy.best_position,
                    best_hfr: legacy.best_hfr,
                    focus_data,
                    method: method_str,
                    temperature,
                    timestamp,
                    curve_fit_quality: legacy.r_squared,
                    backlash_applied: false,
                });
            }

            Err(SkotiqError::OperationFailed(
                "Autofocus completed but returned an unrecognized payload format".to_string(),
            ))
        }
        NodeStatus::Failure => Err(SkotiqError::OperationFailed(
            result.message.unwrap_or("Autofocus failed".to_string()),
        )),
        NodeStatus::Cancelled => Err(SkotiqError::Cancelled),
        _ => Err(SkotiqError::OperationFailed("Unknown error".to_string())),
    }
}

/// Cancel autofocus
pub async fn api_cancel_autofocus() -> Result<(), SkotiqError> {
    tracing::info!("Cancelling autofocus...");
    let cancel_token = get_autofocus_cancel_token();
    cancel_token.store(true, Ordering::Relaxed);
    Ok(())
}

// Focuser backlash calibration

/// Cancellation for a backlash calibration run.
///
/// Separate from the autofocus token even though the two share the hardware
/// admission gate and can never run at once: cancelling the calibration from
/// its own wizard must not read as cancelling an autofocus, in the UI or in
/// the log.
static BACKLASH_CALIBRATION_CANCEL_TOKEN: OnceLock<Arc<AtomicBool>> = OnceLock::new();

fn get_backlash_calibration_cancel_token() -> &'static Arc<AtomicBool> {
    BACKLASH_CALIBRATION_CANCEL_TOKEN.get_or_init(|| Arc::new(AtomicBool::new(false)))
}

/// Measure this focuser's mechanical backlash by scanning focus twice, once
/// approaching every point from below and once from above.
///
/// `config_json` is a [`skotiq_sequencer::instructions::BacklashCalibrationConfig`]
/// and the returned string is a
/// [`skotiq_sequencer::instructions::BacklashCalibrationOutcome`]. JSON on
/// both sides deliberately: the outcome carries both scans' full point sets,
/// both vertices, a confidence with its grounds and — when the scans cannot
/// support a figure — a tagged refusal with a remedy. That is not a shape a
/// flat FFI struct can carry, and keeping it as serde means the evidence the
/// operator sees can grow without another round of bridge codegen.
///
/// A refusal comes back as `Ok`: the run happened and reached a conclusion,
/// which is that no figure is warranted. `Err` is reserved for the run not
/// happening — no camera, no focuser, a move that failed, a cancellation.
/// Live progress arrives on the event stream as a focuser `PropertyChanged`
/// with property `FocuserBacklashCalibrationProgress`.
pub async fn api_run_focuser_backlash_calibration(
    device_id: String, // Focuser ID
    camera_id: String,
    config_json: String,
) -> Result<String, SkotiqError> {
    use skotiq_sequencer::instructions::{
        execute_backlash_calibration_admitted, try_admit_autofocus_run,
        validate_backlash_calibration_config, BacklashCalibrationConfig,
        BACKLASH_CALIBRATION_CANCELLED,
    };

    let config: BacklashCalibrationConfig =
        serde_json::from_str(&config_json).map_err(|error| {
            SkotiqError::InvalidParameter(format!(
                "backlash calibration config is not valid: {}",
                error
            ))
        })?;
    validate_backlash_calibration_config(&config).map_err(SkotiqError::InvalidParameter)?;

    // The calibration drives the same camera and focuser as a sweep, so it
    // takes the autofocus admission gate rather than a gate of its own.
    let guard = try_admit_autofocus_run().ok_or_else(|| SkotiqError::DeviceBusy {
        device_id: device_id.clone(),
        current_operation: "autofocus".to_string(),
    })?;

    // Only after admission, so a rejected second start cannot clear a pending
    // cancellation belonging to the run that is already going.
    let cancel_token = get_backlash_calibration_cancel_token();
    cancel_token.store(false, Ordering::Relaxed);

    tracing::info!(
        "Starting focuser backlash calibration with camera {} and focuser {}",
        camera_id,
        device_id
    );

    let event_tx =
        crate::util::executor_event_bridge::spawn_executor_event_bridge(get_state().clone());
    let progress_focuser_id = device_id.clone();
    let ctx = one_shot_focus_context(
        camera_id,
        device_id.clone(),
        cancel_token.clone(),
        event_tx.clone(),
        create_unified_device_ops(),
    );

    let progress_fn = move |_: f64, detail: String| {
        get_state().publish_equipment_event(
            EquipmentEvent::PropertyChanged {
                device_type: "focuser".to_string(),
                device_id: progress_focuser_id.clone(),
                property: "FocuserBacklashCalibrationProgress".to_string(),
                value: detail,
            },
            EventSeverity::Info,
        );
    };

    let outcome = execute_backlash_calibration_admitted(&config, &ctx, Some(&progress_fn), guard)
        .await
        .map_err(|error| {
            // An operator who pressed Cancel did not suffer a failure, and the
            // wizard must not tell them they did. The focuser has been returned
            // to where they left it either way.
            if error.starts_with(BACKLASH_CALIBRATION_CANCELLED) {
                SkotiqError::Cancelled
            } else {
                SkotiqError::OperationFailed(error)
            }
        })?;

    serde_json::to_string(&outcome).map_err(|error| {
        SkotiqError::OperationFailed(format!(
            "backlash calibration finished but its result could not be encoded: {}",
            error
        ))
    })
}

/// What a backlash calibration would cost, without running it: points per
/// scan, total exposures, the range it scans, the total travel including the
/// run-up either side, and an estimated duration.
///
/// The UI needs this to tell the operator what they are agreeing to — it needs
/// stars, rough focus and a few minutes — so the estimate is worked out by the
/// same code that will do the run rather than guessed again in Dart. Returns a
/// [`skotiq_sequencer::instructions::BacklashCalibrationPlan`] as JSON.
pub async fn api_plan_focuser_backlash_calibration(
    config_json: String,
    center_position: i32,
) -> Result<String, SkotiqError> {
    use skotiq_sequencer::instructions::{
        plan_backlash_calibration, validate_backlash_calibration_config, BacklashCalibrationConfig,
    };

    let config: BacklashCalibrationConfig =
        serde_json::from_str(&config_json).map_err(|error| {
            SkotiqError::InvalidParameter(format!(
                "backlash calibration config is not valid: {}",
                error
            ))
        })?;
    validate_backlash_calibration_config(&config).map_err(SkotiqError::InvalidParameter)?;

    let plan = plan_backlash_calibration(&config, center_position);
    serde_json::to_string(&plan).map_err(|error| {
        SkotiqError::OperationFailed(format!(
            "backlash calibration plan could not be encoded: {}",
            error
        ))
    })
}

/// Ask a running backlash calibration to stop. The routine returns the focuser
/// to where the operator left it before reporting the cancellation.
pub async fn api_cancel_focuser_backlash_calibration() -> Result<(), SkotiqError> {
    tracing::info!("Cancelling focuser backlash calibration...");
    get_backlash_calibration_cancel_token().store(true, Ordering::Relaxed);
    Ok(())
}

// Camera exposure & image capture

/// Captured image result containing display-ready data
#[derive(Debug, Clone)]
pub struct CapturedImageResult {
    pub width: u32,
    pub height: u32,
    pub display_data: Vec<u8>, // Always RGBA (width*height*4), alpha=255
    pub histogram: Vec<u32>,   // 256-bin histogram (computed from pre-RGBA pixel values)
    pub stats: ImageStatsResult,
    pub exposure_time: f64,
    pub timestamp: String,
    pub is_color: bool, // true if source was color (RGB), false if grayscale — retained for stretch/analysis paths
}

/// Image statistics
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImageStatsResult {
    pub min: f64,
    pub max: f64,
    pub mean: f64,
    pub median: f64,
    pub std_dev: f64,
    pub hfr: Option<f64>,
    /// Per-frame median star eccentricity (0.0 = round, →1.0 = trailed).
    /// `None` when too few reliable stars to honestly measure — never a
    /// fabricated value.
    pub eccentricity: Option<f64>,
    pub fwhm: Option<f64>,
    pub star_count: u32,
}

/// Start a camera exposure
/// Returns progress updates via events, final image available via api_get_last_image
/// Public bridge entry point. Gain/offset are explicit (`i32`) here so the
/// generated FFI signature stays stable; this delegates to
/// [`camera_start_exposure_opt`] with `Some(..)`, commanding both values
/// exactly as before.
pub async fn api_camera_start_exposure(
    device_id: String,
    duration_secs: f64,
    gain: i32,
    offset: i32,
    bin_x: i32,
    bin_y: i32,
) -> Result<(), SkotiqError> {
    camera_start_exposure_opt(
        device_id,
        duration_secs,
        Some(gain),
        Some(offset),
        bin_x,
        bin_y,
    )
    .await
}

/// Start an exposure without collapsing omitted controls to zero and with the
/// complete per-frame geometry/frame-type contract.
#[allow(clippy::too_many_arguments)]
pub async fn api_camera_start_exposure_configured(
    device_id: String,
    duration_secs: f64,
    gain: Option<i32>,
    offset: Option<i32>,
    bin_x: i32,
    bin_y: i32,
    start_x: Option<u32>,
    start_y: Option<u32>,
    width: Option<u32>,
    height: Option<u32>,
    frame_type: String,
) -> Result<(), SkotiqError> {
    let supplied = [
        start_x.is_some(),
        start_y.is_some(),
        width.is_some(),
        height.is_some(),
    ];
    let subframe = if supplied.iter().all(|value| *value) {
        let width = width.expect("checked above");
        let height = height.expect("checked above");
        if width == 0 || height == 0 {
            return Err(SkotiqError::InvalidParameter(
                "Camera subframe width and height must be positive".to_string(),
            ));
        }
        Some(skotiq_sequencer::CameraSubframe {
            start_x: start_x.expect("checked above"),
            start_y: start_y.expect("checked above"),
            width,
            height,
        })
    } else if supplied.iter().any(|value| *value) {
        return Err(SkotiqError::InvalidParameter(
            "Camera subframe requires start_x, start_y, width, and height together".to_string(),
        ));
    } else {
        None
    };

    camera_start_exposure_configured_opt(
        device_id,
        duration_secs,
        gain,
        offset,
        bin_x,
        bin_y,
        subframe,
        skotiq_device::FrameType::from_str_lenient(&frame_type),
    )
    .await
}

/// Start a camera exposure with *optional* gain/offset.
///
/// `None` means "leave the camera's current gain/offset unchanged": it is
/// threaded through to the device layer (which skips the setter for `None`)
/// and is NOT collapsed to `0`, which on drivers that honor it would actively
/// command a gain/offset of zero. Internal callers that carry the documented
/// "camera default" semantics (e.g. polar alignment) use this directly.
pub(crate) async fn camera_start_exposure_opt(
    device_id: String,
    duration_secs: f64,
    gain: Option<i32>,
    offset: Option<i32>,
    bin_x: i32,
    bin_y: i32,
) -> Result<(), SkotiqError> {
    camera_start_exposure_configured_opt(
        device_id,
        duration_secs,
        gain,
        offset,
        bin_x,
        bin_y,
        None,
        skotiq_device::FrameType::Light,
    )
    .await
}

/// Turn a `DeviceOps` capture error into the narrowest `SkotiqError` that
/// still describes it.
///
/// A frame rejected by image validation (saturated, all-zero) is the operator's
/// exposure to fix, not a fault: it becomes [`SkotiqError::ExposureFailed`],
/// which the headless mapper renders as 422. Everything else falls through to
/// [`SkotiqError::OperationFailed`] (HTTP 500). The split matters because a
/// client retrying on 5xx would otherwise retry a request that can only fail again.
fn classify_exposure_failure(device_id: &str, error: skotiq_sequencer::DeviceError) -> SkotiqError {
    match error {
        skotiq_sequencer::DeviceError::InvalidFrame(reason) => SkotiqError::ExposureFailed {
            camera_id: device_id.to_string(),
            reason,
        },
        other => SkotiqError::OperationFailed(other.to_string()),
    }
}

/// Expose, download, and make the frame the camera's last frame (see
/// `crate::last_frame`). Simulated and real cameras take the same path.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn camera_start_exposure_configured_opt(
    device_id: String,
    duration_secs: f64,
    gain: Option<i32>,
    offset: Option<i32>,
    bin_x: i32,
    bin_y: i32,
    subframe: Option<skotiq_sequencer::CameraSubframe>,
    frame_type: skotiq_device::FrameType,
) -> Result<(), SkotiqError> {
    tracing::info!(
        "Starting {}s exposure with gain={:?}, offset={:?}, bin={}x{}",
        duration_secs,
        gain,
        offset,
        bin_x,
        bin_y
    );
    create_unified_device_ops()
        .camera_start_exposure(
            skotiq_sequencer::ExposureRequest::new(&device_id, duration_secs)
                // None leaves the driver's current value untouched.
                .gain(gain)
                .offset(offset)
                .binning(bin_x, bin_y)
                .subframe(subframe)
                .frame_type(frame_type.as_str()),
        )
        .await
        .map_err(|e| classify_exposure_failure(&device_id, e))?;
    Ok(())
}

/// The device's last captured frame, display-ready.
pub async fn api_get_last_image(device_id: String) -> Result<CapturedImageResult, SkotiqError> {
    // Debug, not info: dashboards and companions poll this every few seconds,
    // and "no image yet" is a normal state the typed error already reports.
    tracing::debug!("API: api_get_last_image called for device: {}", device_id);
    crate::last_frame::display(&device_id)
        .await
        .ok_or(SkotiqError::NoImageAvailable)
}

/// The device's last captured frame as the camera delivered it (u16).
pub async fn api_get_last_raw_image_data(device_id: String) -> Result<Vec<u16>, SkotiqError> {
    crate::last_frame::raw(&device_id)
        .await
        .map(|frame| frame.data)
        .ok_or(SkotiqError::NoImageAvailable)
}

/// Free the device's stored frame (camera disconnected or on request).
pub async fn api_clear_device_image(device_id: String) -> Result<(), SkotiqError> {
    tracing::info!("API: Clearing stored image for device: {}", device_id);
    crate::last_frame::clear(&device_id).await;
    Ok(())
}

/// Cancel current exposure.
///
/// The abort generation moves first: it is what stops the exposure waiting
/// in `UnifiedDeviceOps`, and some SDKs report a finished exposure right after
/// the stop, which must not be downloaded as a frame.
pub async fn api_camera_cancel_exposure(device_id: String) -> Result<(), SkotiqError> {
    crate::unified_device_ops::mark_camera_exposure_aborted(&device_id).await;
    get_device_manager()
        .camera_abort_exposure(&device_id)
        .await
        .map_err(SkotiqError::from)
}

// Real FITS file operations

/// Result from reading a FITS file
#[derive(Debug, Clone)]
pub struct FitsReadResult {
    pub width: u32,
    pub height: u32,
    pub bitpix: i32,
    pub display_data: Vec<u8>, // Always RGBA (width*height*4), alpha=255
    pub histogram: Vec<u32>,
    pub stats: ImageStatsResult,
    pub object_name: Option<String>,
    pub exposure_time: Option<f64>,
    pub filter: Option<String>,
    pub ra: Option<f64>,
    pub dec: Option<f64>,
    pub date_obs: Option<String>,
    pub bayer_pattern: Option<String>,
}

/// Result from reading FITS file linear pixel data.
/// This is intended for scientific workflows that require unstretched values.
#[derive(Debug, Clone)]
pub struct FitsLinearReadResult {
    pub width: u32,
    pub height: u32,
    pub bitpix: i32,
    pub linear_data: Vec<f64>,
    pub object_name: Option<String>,
    pub exposure_time: Option<f64>,
    pub filter: Option<String>,
    pub ra: Option<f64>,
    pub dec: Option<f64>,
    pub date_obs: Option<String>,
    pub bayer_pattern: Option<String>,
}

/// Frame-level quality metrics for Science visualizations.
#[derive(Debug, Clone)]
pub struct QualityFrameMetricsApi {
    pub median: f64,
    pub mean: f64,
    pub std_dev: f64,
    pub mad: f64,
    pub background: f64,
    pub noise: f64,
    pub snr: f64,
    pub dynamic_range_p1_p99: f64,
    pub low_clip_percent: f64,
    pub high_clip_percent: f64,
    pub uniformity_cv: f64,
    pub gradient_x: f64,
    pub gradient_y: f64,
    pub processing_tier: String,
    pub processing_ms: u32,
}

/// Tile-level quality metrics for Science overlays/surfaces.
#[derive(Debug, Clone)]
pub struct QualityTileMetricApi {
    pub layer_type: String,
    pub tile_row: u32,
    pub tile_col: u32,
    pub sample_count: u32,
    pub value: f64,
    pub p05: f64,
    pub p50: f64,
    pub p95: f64,
    pub aux_value: f64,
}

/// Result container for quality map computation endpoints.
#[derive(Debug, Clone)]
pub struct QualityMapsResultApi {
    pub frame: QualityFrameMetricsApi,
    pub tiles: Vec<QualityTileMetricApi>,
}

/// Decode an [`ImageData`] byte buffer into linear `f64` samples.
///
/// `ImageData.data` is an in-memory host-endian (little-endian) buffer, NOT the
/// big-endian wire format of a FITS file: every producer in the imaging crate
/// writes it with `to_le_bytes` (`fits.rs` after BZERO/BSCALE scaling, the
/// camera drivers, `processing.rs`) and every other consumer reads it back with
/// `from_le_bytes` (`ImageData::as_u16`/`as_f32`, `calibration.rs`,
/// `background_extraction.rs::read_pixel`). Decoding big-endian here byte-swaps
/// every sample, which does not merely scale the data — it destroys the star
/// field (a 440 ADU background reads as 47105 and a 40614 ADU star as 42654,
/// i.e. stars come back DARKER than the sky), so downstream star detection finds
/// nothing at all.
pub(crate) fn image_data_to_linear_f64(image_data: &ImageData) -> Vec<f64> {
    match image_data.pixel_type {
        skotiq_imaging::PixelType::U8 => image_data
            .data
            .iter()
            .map(|&value| value as f64)
            .collect::<Vec<f64>>(),
        skotiq_imaging::PixelType::U16 => image_data
            .data
            .as_chunks::<2>()
            .0
            .iter()
            .map(|chunk| u16::from_le_bytes([chunk[0], chunk[1]]) as f64)
            .collect::<Vec<f64>>(),
        skotiq_imaging::PixelType::U32 => image_data
            .data
            .as_chunks::<4>()
            .0
            .iter()
            .map(|chunk| u32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]) as f64)
            .collect::<Vec<f64>>(),
        skotiq_imaging::PixelType::F32 => image_data
            .data
            .as_chunks::<4>()
            .0
            .iter()
            .map(|chunk| f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]) as f64)
            .collect::<Vec<f64>>(),
        skotiq_imaging::PixelType::F64 => image_data
            .data
            .as_chunks::<8>()
            .0
            .iter()
            .map(|chunk| {
                f64::from_le_bytes([
                    chunk[0], chunk[1], chunk[2], chunk[3], chunk[4], chunk[5], chunk[6], chunk[7],
                ])
            })
            .collect::<Vec<f64>>(),
    }
}

#[cfg(test)]
mod linear_decode_tests;

/// Read a FITS file from disk
pub async fn api_read_fits_file(file_path: String) -> Result<FitsReadResult, SkotiqError> {
    use std::path::Path;

    tracing::info!("Reading FITS file: {}", file_path);

    let path = Path::new(&file_path);
    if !path.exists() {
        return Err(SkotiqError::IoError(format!(
            "File not found: {}",
            file_path
        )));
    }

    let (image_data, header) = skotiq_imaging::read_frame(path)
        .map_err(|e| SkotiqError::ImageError(format!("Failed to read the image: {}", e)))?;

    let object_name = header.get_string("OBJECT").map(|s| s.to_string());
    let exposure_time = header.get_float("EXPTIME");
    let filter = header.get_string("FILTER").map(|s| s.to_string());
    let ra = header.get_float("RA");
    let dec = header.get_float("DEC");
    let date_obs = header.get_string("DATE-OBS").map(|s| s.to_string());
    let bitpix = match image_data.pixel_type {
        skotiq_imaging::PixelType::U8 => 8,
        skotiq_imaging::PixelType::U16 => 16,
        skotiq_imaging::PixelType::U32 => 32,
        skotiq_imaging::PixelType::F32 => -32,
        skotiq_imaging::PixelType::F64 => -64,
    };
    let bayer_pattern = header.get_string("BAYERPAT").map(|s| s.to_string());

    let stats = skotiq_imaging::calculate_stats_u16(&image_data);

    let display = crate::frame_display::mono(&image_data);

    tracing::info!(
        "FITS file loaded: {}x{}, {} pixels",
        image_data.width,
        image_data.height,
        image_data.width * image_data.height
    );

    Ok(FitsReadResult {
        width: image_data.width,
        height: image_data.height,
        bitpix,
        display_data: display.rgba,
        histogram: display.histogram,
        stats: ImageStatsResult {
            min: stats.min,
            max: stats.max,
            mean: stats.mean,
            median: stats.median,
            std_dev: stats.std_dev,
            // This load path does not run star detection, so neither HFR nor
            // eccentricity is measured here — honest None, not a fabricated 0.
            hfr: None,
            eccentricity: None,
            fwhm: None,
            star_count: 0,
        },
        object_name,
        exposure_time,
        filter,
        ra,
        dec,
        date_obs,
        bayer_pattern,
    })
}

/// Read a FITS file and return unstretched linear pixel values for science analysis.
pub async fn api_read_fits_linear_data(
    file_path: String,
) -> Result<FitsLinearReadResult, SkotiqError> {
    use std::path::Path;

    tracing::info!("Reading FITS linear data: {}", file_path);

    let path = Path::new(&file_path);
    if !path.exists() {
        return Err(SkotiqError::IoError(format!(
            "File not found: {}",
            file_path
        )));
    }

    let (image_data, header) = skotiq_imaging::read_frame(path)
        .map_err(|e| SkotiqError::ImageError(format!("Failed to read the image: {}", e)))?;

    let object_name = header.get_string("OBJECT").map(|s| s.to_string());
    let exposure_time = header.get_float("EXPTIME");
    let filter = header.get_string("FILTER").map(|s| s.to_string());
    let ra = header.get_float("RA");
    let dec = header.get_float("DEC");
    let date_obs = header.get_string("DATE-OBS").map(|s| s.to_string());
    let bitpix = match image_data.pixel_type {
        skotiq_imaging::PixelType::U8 => 8,
        skotiq_imaging::PixelType::U16 => 16,
        skotiq_imaging::PixelType::U32 => 32,
        skotiq_imaging::PixelType::F32 => -32,
        skotiq_imaging::PixelType::F64 => -64,
    };
    let bayer_pattern = header.get_string("BAYERPAT").map(|s| s.to_string());
    let linear_data = image_data_to_linear_f64(&image_data);

    Ok(FitsLinearReadResult {
        width: image_data.width,
        height: image_data.height,
        bitpix,
        linear_data,
        object_name,
        exposure_time,
        filter,
        ra,
        dec,
        date_obs,
        bayer_pattern,
    })
}

mod quality_math;
pub(crate) use quality_math::{
    compute_quality_maps_from_linear_data, mad, median, percentile, percentile_sorted,
};

/// Compute quality maps from the last captured image in memory for a device.
pub async fn api_compute_last_capture_quality_maps(
    device_id: String,
    grid_rows: u32,
    grid_cols: u32,
    low_clip_adu: u32,
    high_clip_adu: u32,
) -> Result<QualityMapsResultApi, SkotiqError> {
    let started = Instant::now();
    let raw_info = crate::last_frame::raw(&device_id)
        .await
        .ok_or(SkotiqError::NoImageAvailable)?;

    // Why: raw_info.width/height are u32; widening to usize via `as` is value-preserving
    // on every Tier 1 target. raw_info.data is Vec<u16>; widening u16 -> f64 is lossless
    // (53-bit mantissa easily holds 16-bit values).
    let width = raw_info.width as usize;
    let height = raw_info.height as usize;
    let linear_data = raw_info
        .data
        .iter()
        .map(|value| *value as f64)
        .collect::<Vec<_>>();

    let mut result = compute_quality_maps_from_linear_data(
        width,
        height,
        &linear_data,
        grid_rows,
        grid_cols,
        low_clip_adu,
        high_clip_adu,
        "live",
    )?;
    // Why: as_millis() returns u128; we clamp to u32::MAX first then cast, so the
    // value cannot exceed u32::MAX. u128 -> u32 with clamped value is safe.
    result.frame.processing_ms = started.elapsed().as_millis().min(u32::MAX as u128) as u32;
    Ok(result)
}

/// Compute quality maps directly from a FITS file.
pub async fn api_compute_fits_quality_maps(
    file_path: String,
    grid_rows: u32,
    grid_cols: u32,
    low_clip_adu: u32,
    high_clip_adu: u32,
) -> Result<QualityMapsResultApi, SkotiqError> {
    use std::path::Path;

    let started = Instant::now();
    let path = Path::new(&file_path);
    if !path.exists() {
        return Err(SkotiqError::IoError(format!(
            "File not found: {}",
            file_path
        )));
    }

    let (image_data, _header) = skotiq_imaging::read_frame(path)
        .map_err(|e| SkotiqError::ImageError(format!("Failed to read the image: {}", e)))?;
    let linear_data = image_data_to_linear_f64(&image_data);

    let mut result = compute_quality_maps_from_linear_data(
        image_data.width as usize,
        image_data.height as usize,
        &linear_data,
        grid_rows,
        grid_cols,
        low_clip_adu,
        high_clip_adu,
        "deferred",
    )?;
    result.frame.processing_ms = started.elapsed().as_millis().min(u32::MAX as u128) as u32;
    Ok(result)
}

#[cfg(test)]
mod quality_map_tests;

/// FITS header for writing

// Star detection and image analysis

/// Detected star information
#[derive(Debug, Clone)]
pub struct DetectedStarInfo {
    pub x: f64,
    pub y: f64,
    pub flux: f64,
    pub hfr: f64,
    pub fwhm: f64,
    pub peak: f64,
    pub background: f64,
    pub snr: f64,
    /// Eccentricity: 0 = perfect circle, 1 = line (elongated)
    pub eccentricity: f64,
    /// Sharpness: ratio of peak to spread - hot pixels have high sharpness
    pub sharpness: f64,
}

/// Star detection result
#[derive(Debug, Clone)]
pub struct StarDetectionResultApi {
    pub stars: Vec<DetectedStarInfo>,
    pub star_count: u32,
    pub median_hfr: f64,
    pub median_fwhm: f64,
    pub median_snr: f64,
    /// Per-frame median star eccentricity (0.0 = round, →1.0 = trailed).
    /// `None` when too few reliable stars to honestly measure.
    pub median_eccentricity: Option<f64>,
    pub background: f64,
    pub noise: f64,
}

/// Star detection configuration
#[derive(Debug, Clone)]
#[flutter_rust_bridge::frb]
pub struct StarDetectionConfigApi {
    pub detection_sigma: f64,
    pub min_area: u32,
    pub max_area: u32,
    pub max_eccentricity: f64,
    pub saturation_limit: u32,
    pub hfr_radius: u32,
    /// Minimum HFR to be considered a real star (filters hot pixels)
    pub min_hfr: Option<f64>,
    /// Minimum SNR to be considered a valid detection
    pub min_snr: Option<f64>,
    /// Maximum sharpness (filters hot pixels which have very high sharpness)
    pub max_sharpness: Option<f64>,
}

impl Default for StarDetectionConfigApi {
    fn default() -> Self {
        Self {
            detection_sigma: 5.0,
            min_area: 9,
            max_area: 10000,
            max_eccentricity: 0.7,
            saturation_limit: 60000,
            hfr_radius: 20,
            min_hfr: Some(1.0), // Real stars have HFR > ~1.0; hot pixels < 0.8
            min_snr: Some(5.0), // Modest SNR threshold - real stars in short subs can be faint
            max_sharpness: Some(0.95), // Only reject extreme hot pixels (sharpness ~1.0)
        }
    }
}

/// Detect stars in a FITS file
pub async fn api_detect_stars_in_file(
    file_path: String,
    config: Option<StarDetectionConfigApi>,
) -> Result<StarDetectionResultApi, SkotiqError> {
    use std::path::Path;

    tracing::info!("Detecting stars in: {}", file_path);

    let path = Path::new(&file_path);
    let (image_data, _header) = skotiq_imaging::read_frame(path)
        .map_err(|e| SkotiqError::ImageError(format!("Failed to read the image: {}", e)))?;

    let config = config.unwrap_or_default();
    let detection_config = skotiq_imaging::StarDetectionConfig {
        detection_sigma: config.detection_sigma,
        min_area: config.min_area,
        max_area: config.max_area,
        max_eccentricity: config.max_eccentricity,
        saturation_limit: config.saturation_limit as u16,
        hfr_radius: config.hfr_radius,
        min_hfr: config.min_hfr.unwrap_or(1.0),
        min_snr: config.min_snr.unwrap_or(5.0),
        max_sharpness: config.max_sharpness.unwrap_or(0.95),
        noise_model: None,
    };

    let result = skotiq_imaging::detect_stars_with_stats(&image_data, &detection_config);

    // The star list honors the caller's own eccentricity ceiling. A caller
    // that asks for more than the working-star ceiling is measuring the field
    // (PSF and eccentricity maps, photometry), and a list narrowed to round
    // stars cannot show a trailed field. At the default ceiling the two
    // populations are the same.
    let stars: Vec<DetectedStarInfo> = result
        .sources
        .iter()
        .map(|s| DetectedStarInfo {
            x: s.x,
            y: s.y,
            flux: s.flux,
            hfr: s.hfr,
            fwhm: s.fwhm,
            peak: s.peak,
            background: s.background,
            snr: s.snr,
            eccentricity: s.eccentricity,
            sharpness: s.sharpness,
        })
        .collect();

    tracing::info!(
        "Detected {} stars, median HFR: {:.2}",
        result.star_count,
        result.median_hfr
    );

    Ok(StarDetectionResultApi {
        star_count: stars.len() as u32,
        stars,
        median_hfr: result.median_hfr,
        median_fwhm: result.median_fwhm,
        median_snr: result.median_snr,
        median_eccentricity: result.median_eccentricity,
        background: result.background,
        noise: result.noise,
    })
}

/// Star crop data for UI display
#[derive(Debug, Clone)]
pub struct StarCropApi {
    /// Base64-encoded grayscale pixel data
    pub pixels_base64: String,
    /// Width of the crop
    pub width: u32,
    /// Height of the crop
    pub height: u32,
    /// HFR of this star
    pub hfr: f64,
    /// SNR of this star
    pub snr: f64,
}

/// Get star crops from the last captured image for a device
///
/// This extracts the top N brightest stars from the last image and returns
/// cropped 80x80 pixel regions centered on each star, auto-stretched for display.
/// Used by the autofocus UI to show star crops for visual feedback.
pub async fn api_get_star_crops_from_last_image(
    device_id: String,
    max_crops: u32,
) -> Result<Vec<StarCropApi>, SkotiqError> {
    use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};

    tracing::info!(
        "API: api_get_star_crops_from_last_image for device: {}, max_crops: {}",
        device_id,
        max_crops
    );

    let raw = crate::last_frame::raw(&device_id)
        .await
        .ok_or(SkotiqError::NoImageAvailable)?;
    let img = skotiq_imaging::ImageData::from_u16(raw.width, raw.height, 1, &raw.data);

    let config = skotiq_imaging::StarDetectionConfig::default();
    let stars = skotiq_imaging::detect_stars(&img, &config);

    if stars.is_empty() {
        tracing::info!("No stars detected for star crop extraction");
        return Ok(vec![]);
    }

    // Extract top star crops (80x80 pixels each)
    let crops = skotiq_imaging::extract_top_star_crops(&img, &stars, max_crops as usize, 80);

    let result: Vec<StarCropApi> = crops
        .iter()
        .map(|crop| StarCropApi {
            pixels_base64: BASE64.encode(&crop.pixels),
            width: crop.width,
            height: crop.height,
            hfr: crop.hfr,
            snr: crop.snr,
        })
        .collect();

    tracing::info!("Extracted {} star crops", result.len());
    Ok(result)
}

/// Stretch parameters for manual control
#[derive(Debug, Clone)]
pub struct StretchParamsApi {
    pub shadows: f64,
    pub highlights: f64,
    pub midtones: f64,
}

/// Auto-calculate stretch parameters for an image
pub async fn api_calculate_auto_stretch(
    file_path: String,
) -> Result<StretchParamsApi, SkotiqError> {
    use std::path::Path;

    let path = Path::new(&file_path);
    let (image_data, _header) = skotiq_imaging::read_frame(path)
        .map_err(|e| SkotiqError::ImageError(format!("Failed to read the image: {}", e)))?;

    let params = skotiq_imaging::auto_stretch_stf(&image_data);

    Ok(StretchParamsApi {
        shadows: params.shadows,
        highlights: params.highlights,
        midtones: params.midtones,
    })
}

/// Apply stretch to a FITS file and return display data
pub async fn api_apply_stretch(
    file_path: String,
    params: StretchParamsApi,
) -> Result<Vec<u8>, SkotiqError> {
    use std::path::Path;

    let path = Path::new(&file_path);
    let (image_data, _header) = skotiq_imaging::read_frame(path)
        .map_err(|e| SkotiqError::ImageError(format!("Failed to read the image: {}", e)))?;

    let stretch_params = skotiq_imaging::StretchParams {
        shadows: params.shadows,
        highlights: params.highlights,
        midtones: params.midtones,
    };

    let gray = skotiq_imaging::apply_stretch(&image_data, &stretch_params);
    Ok(crate::frame_display::gray_to_rgba(&gray))
}

/// Save image as PNG (16-bit preserving, lossless)
pub async fn api_save_png_file(
    file_path: String,
    width: u32,
    height: u32,
    data: Vec<u16>,
) -> Result<(), SkotiqError> {
    use std::path::Path;

    tracing::info!("Saving PNG file: {}", file_path);

    let image_data = skotiq_imaging::ImageData::from_u16(width, height, 1, &data);

    let path = Path::new(&file_path);
    skotiq_imaging::write_png(path, &image_data)
        .map_err(|e| SkotiqError::ImageError(format!("Failed to write PNG: {}", e)))?;

    tracing::info!("PNG file saved: {}", file_path);
    Ok(())
}

/// Save an 8-bit RGBA buffer as a PNG, preserving color and alpha losslessly.
///
/// Unlike [`api_save_png_file`] (which takes a mono `u16` buffer and is meant
/// for raw/linear single-channel data), this accepts an already-finalized
/// 8-bit RGBA image — the auto-stretched result the share-card / export path
/// produces. Routing that through the mono path would discard color, and
/// round-tripping it through the Dart `image` package re-encodes/re-decodes the
/// pixels unnecessarily. The alpha channel is written verbatim so transparent
/// regions (e.g. a watermark composited with partial opacity) survive.
///
/// The caller guarantees `rgba.len() == width * height * 4`. A mismatch is a
/// programming error upstream (wrong stride, truncated buffer); we surface it
/// as [`SkotiqError::ImageError`] rather than silently truncating or
/// padding, which would write a corrupt/garbage image that looks plausible.
pub async fn api_save_rgba_png_file(
    file_path: String,
    width: u32,
    height: u32,
    rgba: Vec<u8>,
) -> Result<(), SkotiqError> {
    use image::RgbaImage;
    use std::path::Path;

    tracing::info!("Saving RGBA PNG file: {} ({}x{})", file_path, width, height);

    let expected = (width as usize)
        .checked_mul(height as usize)
        .and_then(|px| px.checked_mul(4))
        .ok_or_else(|| {
            SkotiqError::ImageError(format!(
                "RGBA PNG dimensions overflow: {}x{}",
                width, height
            ))
        })?;
    if rgba.len() != expected {
        return Err(SkotiqError::ImageError(format!(
            "RGBA PNG buffer length mismatch: got {} bytes, expected {} for {}x{}x4",
            rgba.len(),
            expected,
            width,
            height
        )));
    }

    let image: RgbaImage = RgbaImage::from_raw(width, height, rgba).ok_or_else(|| {
        SkotiqError::ImageError(format!(
            "Failed to build {}x{} RGBA image buffer",
            width, height
        ))
    })?;

    let path = Path::new(&file_path);
    image
        .save(path)
        .map_err(|e| SkotiqError::ImageError(format!("Failed to write RGBA PNG: {}", e)))?;

    tracing::info!("RGBA PNG file saved: {}", file_path);
    Ok(())
}

/// Save an 8-bit RGBA buffer as a JPEG, flattening alpha onto black.
///
/// Companion to [`api_save_rgba_png_file`] for the lossy export path. JPEG has
/// no alpha channel, so we explicitly composite each pixel over an opaque black
/// background (`out = src * alpha / 255`) and encode the resulting RGB. Doing
/// the flatten here — rather than handing `Rgba8` straight to the encoder,
/// which would treat the buffer as fully opaque RGB and ignore alpha entirely —
/// keeps transparent regions rendering as black instead of leaking whatever
/// stale color bytes happen to sit under a transparent pixel.
///
/// Length validation matches [`api_save_rgba_png_file`]: a mismatch is an
/// upstream bug and is surfaced as [`SkotiqError::ImageError`].
pub async fn api_save_rgba_jpeg_file(
    file_path: String,
    width: u32,
    height: u32,
    rgba: Vec<u8>,
    quality: u8,
) -> Result<(), SkotiqError> {
    use image::{ImageEncoder, RgbImage};
    use std::fs::File;
    use std::io::BufWriter;
    use std::path::Path;

    tracing::info!(
        "Saving RGBA JPEG file: {} ({}x{}, quality: {})",
        file_path,
        width,
        height,
        quality
    );

    let expected = (width as usize)
        .checked_mul(height as usize)
        .and_then(|px| px.checked_mul(4))
        .ok_or_else(|| {
            SkotiqError::ImageError(format!(
                "RGBA JPEG dimensions overflow: {}x{}",
                width, height
            ))
        })?;
    if rgba.len() != expected {
        return Err(SkotiqError::ImageError(format!(
            "RGBA JPEG buffer length mismatch: got {} bytes, expected {} for {}x{}x4",
            rgba.len(),
            expected,
            width,
            height
        )));
    }

    // Flatten RGBA onto an opaque black background -> packed RGB8.
    let pixel_count = (width as usize) * (height as usize);
    let mut rgb = Vec::with_capacity(pixel_count * 3);
    for px in rgba.as_chunks::<4>().0.iter() {
        // `px` is [r, g, b, a]; composite over black: out = src * a / 255.
        let a = px[3] as u32;
        rgb.push(((px[0] as u32 * a) / 255) as u8);
        rgb.push(((px[1] as u32 * a) / 255) as u8);
        rgb.push(((px[2] as u32 * a) / 255) as u8);
    }

    let rgb_image: RgbImage = RgbImage::from_raw(width, height, rgb).ok_or_else(|| {
        SkotiqError::ImageError(format!(
            "Failed to build {}x{} RGB image buffer",
            width, height
        ))
    })?;

    let path = Path::new(&file_path);
    let file = File::create(path)
        .map_err(|e| SkotiqError::ImageError(format!("Failed to create JPEG file: {}", e)))?;
    let writer = BufWriter::new(file);
    let encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(writer, quality);
    encoder
        .write_image(rgb_image.as_raw(), width, height, image::ColorType::Rgb8)
        .map_err(|e| SkotiqError::ImageError(format!("Failed to encode RGBA JPEG: {}", e)))?;

    tracing::info!("RGBA JPEG file saved: {}", file_path);
    Ok(())
}

#[cfg(test)]
mod rgba_save_tests;

// FITS file saving

/// What the Imaging screen knows about a manual capture when it saves it.
/// The header is built by `crate::frame_header`, the same builder every
/// sequenced frame goes through; RA is in hours.
#[derive(Debug, Clone)]
pub struct FitsWriteHeader {
    pub object_name: Option<String>,
    pub exposure_time: f64,
    pub capture_timestamp: String,
    pub frame_type: String,
    pub filter: Option<String>,
    pub gain: Option<i32>,
    pub offset: Option<i32>,
    pub ccd_temp: Option<f64>,
    pub ra: Option<f64>,
    pub dec: Option<f64>,
    pub altitude: Option<f64>,
    pub telescope: Option<String>,
    pub instrument: Option<String>,
    pub observer: Option<String>,
    pub bin_x: i32,
    pub bin_y: i32,
    pub focal_length: Option<f64>,
    pub aperture: Option<f64>,
    pub pixel_size_x: Option<f64>,
    pub pixel_size_y: Option<f64>,
    pub site_latitude: Option<f64>,
    pub site_longitude: Option<f64>,
    pub site_elevation: Option<f64>,
}

/// Save image data to FITS file
pub async fn api_save_fits_file(
    file_path: String,
    width: u32,
    height: u32,
    data: Vec<u16>,
    header_data: FitsWriteHeader,
) -> Result<(), SkotiqError> {
    crate::frame_header::write_capture_frame(file_path, width, height, data, header_data.into()).await
}

/// One card to set in a frame file's metadata. Exactly one value is given.
#[derive(Debug, Clone)]
pub struct FrameCardUpdate {
    pub keyword: String,
    pub string_value: Option<String>,
    pub int_value: Option<i64>,
    pub double_value: Option<f64>,
    pub comment: Option<String>,
}

/// Set cards in a frame file's metadata, FITS or XISF, keeping its pixels and
/// everything else it holds. The file is replaced whole, never left half
/// written.
pub async fn api_update_frame_cards(
    file_path: String,
    cards: Vec<FrameCardUpdate>,
) -> Result<(), SkotiqError> {
    tokio::task::spawn_blocking(move || {
        skotiq_imaging::rewrite_frame_header(std::path::Path::new(&file_path), |header| {
            for card in &cards {
                if let Some(v) = &card.string_value {
                    header.set_string(&card.keyword, v);
                } else if let Some(v) = card.int_value {
                    header.set_int(&card.keyword, v);
                } else if let Some(v) = card.double_value {
                    header.set_float(&card.keyword, v);
                }
                if let Some(comment) = &card.comment {
                    header.set_comment(&card.keyword, comment);
                }
            }
        })
    })
    .await
    .map_err(|e| SkotiqError::OperationFailed(format!("Task join error: {e}")))?
    .map_err(|e| SkotiqError::ImageError(format!("Could not update the frame's metadata: {e}")))
}

/// Square cutouts of a mono frame file, `2 * half + 1` pixels on a side,
/// centered on each (`centers_x[i]`, `centers_y[i]`) (0-based, row 0 = first
/// stored row), concatenated in that order. A center whose cutout leaves the
/// image is refused.
pub async fn api_read_frame_cutouts(
    file_path: String,
    centers_x: Vec<i32>,
    centers_y: Vec<i32>,
    half: u32,
) -> Result<Vec<f64>, SkotiqError> {
    tokio::task::spawn_blocking(move || {
        let (image, _) = skotiq_imaging::read_frame(std::path::Path::new(&file_path))
            .map_err(|e| SkotiqError::ImageError(format!("Failed to read the image: {e}")))?;
        if image.channels != 1 {
            return Err(SkotiqError::InvalidParameter(
                "cutouts are taken from single-channel frames".to_string(),
            ));
        }
        let (w, h, half) = (image.width as i64, image.height as i64, i64::from(half));
        let size = image.pixel_type.byte_size();
        let mut out = Vec::with_capacity(centers_x.len() * ((2 * half + 1) * (2 * half + 1)) as usize);
        for (&cx, &cy) in centers_x.iter().zip(&centers_y) {
            let (cx, cy) = (i64::from(cx), i64::from(cy));
            if cx - half < 0 || cy - half < 0 || cx + half >= w || cy + half >= h {
                return Err(SkotiqError::InvalidParameter(format!(
                    "a cutout at ({cx}, {cy}) leaves the {w}x{h} image"
                )));
            }
            for y in cy - half..=cy + half {
                for x in cx - half..=cx + half {
                    let at = ((y * w + x) as usize) * size;
                    out.push(skotiq_imaging::samples::sample_from_le(
                        &image.data[at..at + size],
                        image.pixel_type,
                    ));
                }
            }
        }
        Ok(out)
    })
    .await
    .map_err(|e| SkotiqError::OperationFailed(format!("Task join error: {e}")))?
}

/// Set the file format captured frames are saved in: `format` is `FITS` or
/// `XISF`; `xisf_compression` names an XISF codec as its `compression`
/// attribute does (`zstd+sh`, `lz4`, ...) or `none`.
pub fn api_set_capture_file_format(
    format: String,
    xisf_compression: String,
    xisf_checksums: bool,
) -> Result<(), SkotiqError> {
    crate::capture_file_format::set(&format, &xisf_compression, xisf_checksums)
        .map_err(SkotiqError::InvalidParameter)
}

/// Save the device's last captured frame as FITS, without moving its pixels
/// across the FFI boundary.
///
/// Returns an error if no image has been captured yet for the specified device.
pub async fn api_save_fits_from_last_capture(
    device_id: String,
    file_path: String,
    header_data: FitsWriteHeader,
) -> Result<(), SkotiqError> {
    tracing::info!(
        "Saving FITS from last capture for device {} to: {}",
        device_id,
        file_path
    );

    let frame = crate::last_frame::raw(&device_id).await.ok_or_else(|| {
        SkotiqError::OperationFailed(format!(
            "No captured image available for device {}. Please capture an image first.",
            device_id
        ))
    })?;
    let header = crate::frame_header::FrameHeader {
        bayer_pattern: frame.bayer_pattern.map(crate::frame_header::bayerpat),
        ..header_data.into()
    };
    crate::frame_header::write_capture_frame(file_path, frame.width, frame.height, frame.data, header)
        .await?;
    tracing::info!("FITS file saved successfully from last capture");
    Ok(())
}

// Image processing

/// Auto-stretch image for display. Returns RGBA (4 bytes per pixel, alpha=255).
fn auto_stretch_image(width: u32, height: u32, data: Vec<u16>) -> Vec<u8> {
    crate::frame_display::mono(&ImageData::from_u16(width, height, 1, &data)).rgba
}

/// Auto-stretch an interleaved RGB16 image for display, returning RGBA
/// (4 bytes per pixel, alpha=255).
///
/// Each channel is stretched independently with its own PixInsight MAD-based
/// Screen-Transfer-Function (the "Unlinked" mode that maximizes per-channel
/// contrast), mirroring the colour path the native capture pipeline uses. This
/// is the colour counterpart to [`auto_stretch_image`]; the OSC live-stacking /
/// Stack-and-Share display delegates here rather than reimplementing the STF in
/// Dart, so the curve is computed in exactly one place.
///
/// `data` must be `width * height * 3` u16 samples (interleaved R,G,B). A
/// mismatched length yields a fully black RGBA buffer of the correct size
/// (matching `apply_stretch_rgb_per_channel`'s defensive length guard).
fn auto_stretch_color_image(width: u32, height: u32, data: Vec<u16>) -> Vec<u8> {
    use skotiq_imaging::{apply_stretch_rgb_per_channel, auto_stretch_rgb};

    let pixel_count = (width as usize) * (height as usize);
    if data.len() != pixel_count * 3 {
        return vec![0u8; pixel_count * 4];
    }

    let (r_params, g_params, b_params) = auto_stretch_rgb(&data, width, height);
    let rgb8 = apply_stretch_rgb_per_channel(&data, width, height, &r_params, &g_params, &b_params);

    // Expand interleaved RGB8 → RGBA8 (opaque alpha) so the display layer
    // consumes the same 4-byte layout as the grayscale path.
    let mut rgba = vec![0u8; pixel_count * 4];
    rgba.par_chunks_exact_mut(4)
        .zip(rgb8.par_chunks_exact(3))
        .for_each(|(dst, src)| {
            dst[0] = src[0];
            dst[1] = src[1];
            dst[2] = src[2];
            dst[3] = 255;
        });
    rgba
}

/// Auto-stretch image for display
#[flutter_rust_bridge::frb(sync)]
pub fn api_auto_stretch_image(
    width: u32,
    height: u32,
    data: Vec<u16>,
) -> Result<Vec<u8>, SkotiqError> {
    Ok(auto_stretch_image(width, height, data))
}

/// Auto-stretch an interleaved RGB16 image for display.
///
/// The colour counterpart to [`api_auto_stretch_image`]: `data` is
/// `width * height * 3` u16 samples (interleaved R,G,B) and each channel is
/// stretched with its own PixInsight MAD-based STF ("Unlinked" mode). Returns
/// RGBA8 (4 bytes per pixel, alpha=255). OSC live-stacking / Stack-and-Share
/// display delegates here so the STF lives in one place (Rust) rather than being
/// reimplemented in Dart.
#[flutter_rust_bridge::frb(sync)]
pub fn api_auto_stretch_color_image(
    width: u32,
    height: u32,
    data: Vec<u16>,
) -> Result<Vec<u8>, SkotiqError> {
    Ok(auto_stretch_color_image(width, height, data))
}

/// How many FITS thumbnails may be generated at the same time.
///
/// One generation holds the frame in memory twice: the raw FITS buffer plus the
/// `u16` copy it is converted into. For the ASI1600MM's 4656 x 3520 frames that
/// is 32.8 MB each, so a surface asking for a whole night's thumbnails at once
/// would start a hundred of those together and exhaust memory. Admitting four
/// at a time keeps a modern imaging laptop's cores busy while capping the
/// transient cost at roughly 260 MB.
const THUMBNAIL_GENERATION_CONCURRENCY: usize = 4;

fn thumbnail_generation_gate() -> &'static tokio::sync::Semaphore {
    static GATE: OnceLock<tokio::sync::Semaphore> = OnceLock::new();
    GATE.get_or_init(|| tokio::sync::Semaphore::new(THUMBNAIL_GENERATION_CONCURRENCY))
}

/// Generate thumbnail from FITS file
/// Returns JPEG-encoded thumbnail data (~512x512 pixels)
///
/// Async and off-thread on purpose. This reads the whole FITS off disk,
/// converts it to `u16`, downsamples, auto-stretches and JPEG-encodes it —
/// hundreds of milliseconds of blocking I/O and CPU for a full-frame CMOS
/// capture. It used to be `#[frb(sync)]`, which runs the whole of that on the
/// Dart isolate that called it: the UI isolate. A frame strip asking for N
/// thumbnails therefore froze the app for N serialised full-frame decodes,
/// which is exactly what the owner saw when a night's Dashboard showed no
/// thumbnails at all. The work now runs on the blocking pool and the caller
/// awaits it, so the UI isolate stays free to paint.
pub async fn api_generate_fits_thumbnail(
    file_path: String,
    max_size: u32,
) -> Result<Vec<u8>, SkotiqError> {
    let _permit = thumbnail_generation_gate()
        .acquire()
        .await
        .map_err(|e| SkotiqError::OperationFailed(format!("Thumbnail gate closed: {}", e)))?;

    tokio::task::spawn_blocking(move || generate_fits_thumbnail_jpeg(&file_path, max_size))
        .await
        .map_err(|e| SkotiqError::OperationFailed(format!("Thumbnail task join error: {}", e)))?
}

/// A grayscale JPEG of an 8-bit display preview, no larger than `max_size`.
fn encode_preview_jpeg(
    preview: &skotiq_imaging::ImageData,
    max_size: u32,
) -> Result<Vec<u8>, SkotiqError> {
    use image::ImageEncoder;
    let channels = preview.channels.max(1) as usize;
    let scale = preview.width.max(preview.height).div_ceil(max_size.max(1)).max(1);
    let (w, h) = ((preview.width / scale).max(1), (preview.height / scale).max(1));
    let mut gray = Vec::with_capacity((w * h) as usize);
    for y in 0..h {
        for x in 0..w {
            let at = ((y * scale) as usize * preview.width as usize + (x * scale) as usize) * channels;
            let pixel = &preview.data[at..at + channels];
            gray.push(if channels >= 3 {
                ((77 * u32::from(pixel[0]) + 150 * u32::from(pixel[1]) + 29 * u32::from(pixel[2]) + 128) >> 8) as u8
            } else {
                pixel[0]
            });
        }
    }
    let mut jpeg = Vec::new();
    image::codecs::jpeg::JpegEncoder::new_with_quality(std::io::Cursor::new(&mut jpeg), 85)
        .write_image(&gray, w, h, image::ColorType::L8)
        .map_err(|e| SkotiqError::ImageError(format!("Failed to encode the preview: {e}")))?;
    Ok(jpeg)
}

/// The blocking body of [`api_generate_fits_thumbnail`]. Never call this from
/// an async context without `spawn_blocking`.
fn generate_fits_thumbnail_jpeg(file_path: &str, max_size: u32) -> Result<Vec<u8>, SkotiqError> {
    use skotiq_imaging::read_frame;
    use std::path::Path;

    let path = Path::new(file_path);
    // A stored preview is already stretched; only a full frame is stretched
    // here. A preview that cannot be read is no reason to fail: the frame is.
    match skotiq_imaging::read_frame_preview(path, max_size) {
        Ok(Some(preview)) => return encode_preview_jpeg(&preview, max_size),
        Ok(None) => {}
        Err(e) => tracing::debug!("No stored preview in {}: {}", file_path, e),
    }
    let (image_data, _header) = read_frame(path)
        .map_err(|e| SkotiqError::ImageError(format!("Failed to read the image: {}", e)))?;

    let width = image_data.width;
    let height = image_data.height;
    let channels = image_data.channels as usize;
    if width == 0 || height == 0 {
        return Err(SkotiqError::ImageError(format!(
            "Cannot generate thumbnail for empty FITS image {}x{}",
            width, height
        )));
    }
    if channels == 0 {
        return Err(SkotiqError::ImageError(
            "Cannot generate thumbnail for FITS image with zero channels".to_string(),
        ));
    }
    if max_size == 0 {
        return Err(SkotiqError::InvalidParameter(
            "Thumbnail max_size must be greater than zero".to_string(),
        ));
    }

    let pixel_count = (width as usize)
        .checked_mul(height as usize)
        .ok_or_else(|| {
            SkotiqError::ImageError(format!(
                "FITS image dimensions overflow: {}x{}",
                width, height
            ))
        })?;
    let sample_count = pixel_count.checked_mul(channels).ok_or_else(|| {
        SkotiqError::ImageError(format!(
            "FITS sample count overflows for {}x{} image with {} channels",
            width, height, channels
        ))
    })?;
    let expected_bytes = sample_count
        .checked_mul(image_data.pixel_type.byte_size())
        .ok_or_else(|| {
            SkotiqError::ImageError(format!(
                "FITS buffer size overflows for {} samples",
                sample_count
            ))
        })?;
    if image_data.data.len() != expected_bytes {
        return Err(SkotiqError::ImageError(format!(
            "Invalid FITS buffer length: expected {} bytes, got {}",
            expected_bytes,
            image_data.data.len()
        )));
    }

    // One sample, converted on demand.
    //
    // This used to convert the WHOLE frame to `Vec<u16>` first — a second
    // 32.8 MB allocation for an ASI1600 frame, and 16.4 million conversions —
    // and then read one sample in every `scale` from it. A 512 px thumbnail of
    // a 4656 px frame keeps one pixel in 81, so all but 1.2% of that work was
    // thrown away. Converting per sampled sample instead costs the same per
    // pixel that survives and nothing for the pixels that do not.
    let bytes_per_sample = image_data.pixel_type.byte_size();
    let raw = image_data.data.as_slice();
    let sample_at = |index: usize| -> Result<u16, SkotiqError> {
        let offset = index * bytes_per_sample;
        let chunk = raw.get(offset..offset + bytes_per_sample).ok_or_else(|| {
            SkotiqError::ImageError(format!(
                "FITS sample {} falls outside its validated buffer",
                index
            ))
        })?;
        Ok(match image_data.pixel_type {
            skotiq_imaging::PixelType::U8 => u16::from(chunk[0]) << 8,
            skotiq_imaging::PixelType::U16 => u16::from_le_bytes([chunk[0], chunk[1]]),
            // High 16 bits, matching the whole-frame conversion this replaced.
            skotiq_imaging::PixelType::U32 => {
                (u32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]) >> 16) as u16
            }
            skotiq_imaging::PixelType::F32 => {
                let value = f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
                (value.clamp(0.0, 1.0) * 65535.0) as u16
            }
            skotiq_imaging::PixelType::F64 => {
                let value = f64::from_le_bytes([
                    chunk[0], chunk[1], chunk[2], chunk[3], chunk[4], chunk[5], chunk[6], chunk[7],
                ]);
                (value.clamp(0.0, 1.0) * 65535.0) as u16
            }
        })
    };

    let max_dimension = width.max(height);
    let scale = (max_dimension / max_size + u32::from(max_dimension % max_size != 0)).max(1);

    // Downscale image
    let new_width = (width / scale).max(1);
    let new_height = (height / scale).max(1);
    let thumbnail_pixels = (new_width as usize)
        .checked_mul(new_height as usize)
        .ok_or_else(|| {
            SkotiqError::ImageError(format!(
                "Thumbnail dimensions overflow: {}x{}",
                new_width, new_height
            ))
        })?;
    let expected_rgba_bytes = thumbnail_pixels.checked_mul(4).ok_or_else(|| {
        SkotiqError::ImageError(format!(
            "Thumbnail RGBA buffer size overflows for {} pixels",
            thumbnail_pixels
        ))
    })?;
    let mut downscaled = Vec::new();
    downscaled
        .try_reserve_exact(thumbnail_pixels)
        .map_err(|e| {
            SkotiqError::ImageError(format!(
                "Failed to allocate {}-pixel thumbnail: {}",
                thumbnail_pixels, e
            ))
        })?;

    for y in 0..new_height {
        for x in 0..new_width {
            let src_x = x * scale;
            let src_y = y * scale;
            let pixel_idx = (src_y as usize)
                .checked_mul(width as usize)
                .and_then(|row| row.checked_add(src_x as usize))
                .ok_or_else(|| SkotiqError::ImageError("FITS pixel index overflow".to_string()))?;
            let sample_idx = pixel_idx
                .checked_mul(channels)
                .ok_or_else(|| SkotiqError::ImageError("FITS sample index overflow".to_string()))?;
            let sample_end = sample_idx
                .checked_add(channels)
                .ok_or_else(|| SkotiqError::ImageError("FITS sample index overflow".to_string()))?;
            if sample_end > sample_count {
                return Err(SkotiqError::ImageError(format!(
                    "FITS pixel {} falls outside its validated sample buffer",
                    pixel_idx
                )));
            }
            if channels >= 3 {
                let r = u32::from(sample_at(sample_idx)?);
                let g = u32::from(sample_at(sample_idx + 1)?);
                let b = u32::from(sample_at(sample_idx + 2)?);
                downscaled.push(((77 * r + 150 * g + 29 * b + 128) >> 8) as u16);
            } else {
                downscaled.push(sample_at(sample_idx)?);
            }
        }
    }

    // Auto-stretch for display
    let stretched_rgba = auto_stretch_image(new_width, new_height, downscaled);
    if stretched_rgba.len() != expected_rgba_bytes {
        return Err(SkotiqError::ImageError(format!(
            "Invalid stretched thumbnail length: expected {} bytes, got {}",
            expected_rgba_bytes,
            stretched_rgba.len()
        )));
    }
    let stretched: Vec<u8> = stretched_rgba
        .as_chunks::<4>()
        .0
        .iter()
        .map(|rgba| rgba[0])
        .collect();
    if stretched.len() != thumbnail_pixels {
        return Err(SkotiqError::ImageError(format!(
            "Invalid grayscale thumbnail length: expected {} bytes, got {}",
            thumbnail_pixels,
            stretched.len()
        )));
    }

    // Encode as JPEG
    use image::{GrayImage, ImageEncoder};
    use std::io::Cursor;

    let gray_img = GrayImage::from_raw(new_width, new_height, stretched)
        .ok_or_else(|| SkotiqError::ImageError("Failed to create grayscale image".to_string()))?;

    let mut jpeg_data = Vec::new();
    let mut cursor = Cursor::new(&mut jpeg_data);
    let encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut cursor, 85);
    encoder
        .write_image(
            gray_img.as_raw(),
            new_width,
            new_height,
            image::ColorType::L8,
        )
        .map_err(|e| SkotiqError::ImageError(format!("JPEG encoding failed: {}", e)))?;

    Ok(jpeg_data)
}

/// Calibrate an image file using dark, flat, and/or bias calibration frames.
///
/// Loads the light frame and any provided calibration frames from disk,
/// applies the calibration pipeline, and saves the result to `output_path`.
///
/// The calibration order is:
/// 1. Subtract bias from dark and flat (if bias provided)
/// 2. Subtract dark from light
/// 3. Divide light by normalized flat
///
/// Any calibration frame path can be empty/None to skip that correction.
pub fn api_calibrate_image_file(
    light_path: String,
    dark_path: Option<String>,
    flat_path: Option<String>,
    bias_path: Option<String>,
    output_path: String,
) -> Result<(), SkotiqError> {
    use skotiq_imaging::{calibration, read_image, write_fits, FitsHeader, ImageFormat};
    use std::path::Path;

    let light_result = read_image(Path::new(&light_path)).map_err(|e| {
        SkotiqError::ImageError(format!(
            "Failed to read light frame '{}': {}",
            light_path, e
        ))
    })?;

    let dark = match &dark_path {
        Some(p) if !p.is_empty() => {
            let result = read_image(Path::new(p)).map_err(|e| {
                SkotiqError::ImageError(format!("Failed to read dark frame '{}': {}", p, e))
            })?;
            Some(result.image)
        }
        _ => None,
    };

    let flat = crate::api::post_session::load_optional_flat(&flat_path)
        .map_err(|e| SkotiqError::ImageError(format!("Failed to read flat frame: {e}")))?;

    let bias = match &bias_path {
        Some(p) if !p.is_empty() => {
            let result = read_image(Path::new(p)).map_err(|e| {
                SkotiqError::ImageError(format!("Failed to read bias frame '{}': {}", p, e))
            })?;
            Some(result.image)
        }
        _ => None,
    };

    let calibrated = crate::api::post_session::calibrate_with_flat_state(
        &light_result.image,
        dark.as_ref(),
        flat.as_ref(),
        bias.as_ref(),
    )
    .map_err(|e| SkotiqError::ImageError(format!("Calibration failed: {}", e)))?;

    // Save calibrated image, preserving original format
    let out = Path::new(&output_path);
    let ext = out.extension().and_then(|e| e.to_str()).unwrap_or("fits");
    let out_format = ImageFormat::from_extension(ext).unwrap_or(ImageFormat::Fits);

    match out_format {
        ImageFormat::Fits | ImageFormat::Xisf => {
            // Carry over header from original light, add calibration note.
            // set_value_token, not set_string: the read path flattened each
            // value to header text, and re-quoting it would ship
            // EXPTIME = '120.0' — a string card no stacker reads as a number.
            let mut header = FitsHeader::new();
            for (key, value) in &light_result.header {
                header.set_value_token(key, value);
            }
            header.set_string("CALSTAT", "calibrated by Skotiq");
            for (card, path) in [
                ("DARKFILE", &dark_path),
                ("FLATFILE", &flat_path),
                ("BIASFILE", &bias_path),
            ] {
                if let Some(path) = path.as_deref().filter(|p| !p.is_empty()) {
                    header.set_string(card, path);
                }
            }
            skotiq_imaging::write_frame(out, &calibrated, &header).map_err(|e| {
                SkotiqError::ImageError(format!("Failed to write the calibrated frame: {e}"))
            })?;
        }
        ImageFormat::Tiff => {
            skotiq_imaging::write_tiff(out, &calibrated).map_err(|e| {
                SkotiqError::ImageError(format!("Failed to write calibrated TIFF: {}", e))
            })?;
        }
        ImageFormat::Png => {
            skotiq_imaging::write_png(out, &calibrated).map_err(|e| {
                SkotiqError::ImageError(format!("Failed to write calibrated PNG: {}", e))
            })?;
        }
        _ => {
            // Default to FITS for unsupported output formats
            let header = FitsHeader::new();
            write_fits(out, &calibrated, &header).map_err(|e| {
                SkotiqError::ImageError(format!("Failed to write calibrated file: {:?}", e))
            })?;
        }
    }

    tracing::info!(
        "Calibrated image saved to: {} (dark={}, flat={}, bias={})",
        output_path,
        dark_path
            .as_ref()
            .map_or("none", |p| if p.is_empty() { "none" } else { p.as_str() }),
        flat_path
            .as_ref()
            .map_or("none", |p| if p.is_empty() { "none" } else { p.as_str() }),
        bias_path
            .as_ref()
            .map_or("none", |p| if p.is_empty() { "none" } else { p.as_str() }),
    );

    Ok(())
}

/// Calibrate raw pixel data in memory (u16).
///
/// Takes pixel data directly rather than file paths. Returns calibrated pixel data.
/// All frames must have the same dimensions and be single-channel u16.
#[flutter_rust_bridge::frb(sync)]
pub fn api_calibrate_image_data(
    width: u32,
    height: u32,
    light_data: Vec<u16>,
    dark_data: Option<Vec<u16>>,
    flat_data: Option<Vec<u16>>,
    bias_data: Option<Vec<u16>>,
) -> Result<Vec<u16>, SkotiqError> {
    use skotiq_imaging::{calibration, ImageData};

    let light = ImageData::from_u16(width, height, 1, &light_data);

    let dark = dark_data.map(|d| ImageData::from_u16(width, height, 1, &d));
    let flat = flat_data.map(|f| ImageData::from_u16(width, height, 1, &f));
    let bias = bias_data.map(|b| ImageData::from_u16(width, height, 1, &b));

    let calibrated =
        calibration::calibrate_frame(&light, dark.as_ref(), flat.as_ref(), bias.as_ref())
            .map_err(|e| SkotiqError::ImageError(format!("Calibration failed: {}", e)))?;

    calibrated.as_u16().ok_or_else(|| {
        SkotiqError::ImageError(
            "Failed to extract u16 pixel data from calibrated image".to_string(),
        )
    })
}

// Live stacking API

/// Live stacking configuration exposed to Dart
pub struct ApiLiveStackingConfig {
    pub sigma_clip_enabled: bool,
    pub sigma_clip_threshold: f64,
    pub max_match_stars: u32,
    pub match_radius_px: f64,
    pub match_flux_tolerance: f64,
    pub min_matched_pairs: u32,
    /// Sensor acquisition mode: `"mono"`, `"osc"`, or `"auto"` (case-insensitive),
    /// defaulting to `"mono"`. The three modes are specified on
    /// `stacking_api::LiveStackingConfigApi::sensor_mode`.
    pub sensor_mode: String,
    /// Explicit Bayer pattern override (`"RGGB"`/`"BGGR"`/`"GRBG"`/`"GBRG"`,
    /// case-insensitive). When `None`, OSC/auto sessions fall back to the pattern
    /// the reference frame declares via its FITS `BAYERPAT` geometry. An
    /// unrecognised string is a hard error.
    pub bayer_pattern: Option<String>,
    /// Demosaic quality: `"bilinear"`, `"vng"`, or `"superpixel"`
    /// (case-insensitive). Defaults to `"bilinear"`. An unrecognised value is a
    /// hard error rather than a silent best-guess.
    pub demosaic_quality: String,
}

impl Default for ApiLiveStackingConfig {
    fn default() -> Self {
        // Mirror `LiveStackingConfigApi::default()` so the FRB wrapper and the
        // underlying bridge config agree on the monochrome baseline.
        Self {
            sigma_clip_enabled: true,
            sigma_clip_threshold: 2.5,
            max_match_stars: 100,
            match_radius_px: 50.0,
            match_flux_tolerance: 0.7,
            min_matched_pairs: 5,
            sensor_mode: "mono".to_string(),
            bayer_pattern: None,
            demosaic_quality: "bilinear".to_string(),
        }
    }
}

/// Live stacking statistics returned to Dart
pub struct ApiLiveStackingStats {
    pub stacked_frame_count: u32,
    pub total_frames_attempted: u32,
    pub rejected_alignment_failures: u32,
    pub avg_matched_pairs: f64,
    pub avg_alignment_residual: f64,
    pub total_sigma_rejected_pixels: u64,
    /// Frames left out for being taken through another filter than the stack's.
    pub other_filter_frames: u32,
    /// The filter of the most recent such frame.
    pub last_other_filter: Option<String>,
    /// The filter the stack is of; `None` when its reference named none.
    pub filter: Option<String>,
}

/// Result from adding a frame to the live stack
pub struct ApiLiveStackingResult {
    pub width: u32,
    pub height: u32,
    /// Channel count of the stacked result: `1` for a monochrome session, `3`
    /// for an OSC/colour session. The Dart side uses this to interpret `data` as
    /// a single luminance plane vs interleaved RGB16.
    pub channels: u32,
    pub data: Vec<u16>,
    pub stats: ApiLiveStackingStats,
}

pub(crate) fn convert_config(
    config: ApiLiveStackingConfig,
) -> crate::stacking_api::LiveStackingConfigApi {
    crate::stacking_api::LiveStackingConfigApi {
        sigma_clip_enabled: config.sigma_clip_enabled,
        sigma_clip_threshold: config.sigma_clip_threshold,
        max_match_stars: config.max_match_stars,
        match_radius_px: config.match_radius_px,
        match_flux_tolerance: config.match_flux_tolerance,
        min_matched_pairs: config.min_matched_pairs,
        // OSC fields pass straight through. Validation of the string values
        // (sensor mode / Bayer pattern / demosaic quality) happens loudly inside
        // `LiveStackConfig::try_from`, so an invalid value surfaces as an error
        // to the caller rather than being silently normalised here.
        sensor_mode: config.sensor_mode,
        bayer_pattern: config.bayer_pattern,
        demosaic_quality: config.demosaic_quality,
    }
}

pub(crate) fn convert_stats(
    stats: crate::stacking_api::LiveStackingStatsApi,
) -> ApiLiveStackingStats {
    ApiLiveStackingStats {
        stacked_frame_count: stats.stacked_frame_count,
        total_frames_attempted: stats.total_frames_attempted,
        rejected_alignment_failures: stats.rejected_alignment_failures,
        avg_matched_pairs: stats.avg_matched_pairs,
        avg_alignment_residual: stats.avg_alignment_residual,
        total_sigma_rejected_pixels: stats.total_sigma_rejected_pixels,
        other_filter_frames: stats.other_filter_frames,
        last_other_filter: stats.last_other_filter,
        filter: stats.filter,
    }
}

pub(crate) fn convert_result(
    result: crate::stacking_api::LiveStackingAddFrameResult,
) -> ApiLiveStackingResult {
    ApiLiveStackingResult {
        width: result.width,
        height: result.height,
        channels: result.channels,
        data: result.data,
        stats: convert_stats(result.stats),
    }
}

/// Start live stacking with a reference image file.
///
/// All subsequent frames will be aligned to this reference.
pub fn api_stacking_start(
    reference_image_path: String,
    config: ApiLiveStackingConfig,
) -> Result<ApiLiveStackingStats, SkotiqError> {
    let result = crate::stacking_api::stacking_start(reference_image_path, convert_config(config))
        .map_err(|e| SkotiqError::ImageError(e))?;
    Ok(convert_stats(result))
}

/// Start live stacking from raw pixel data in memory.
pub fn api_stacking_start_from_data(
    width: u32,
    height: u32,
    data: Vec<u16>,
    config: ApiLiveStackingConfig,
) -> Result<ApiLiveStackingStats, SkotiqError> {
    let result =
        crate::stacking_api::stacking_start_from_data(width, height, data, convert_config(config))
            .map_err(|e| SkotiqError::ImageError(e))?;
    Ok(convert_stats(result))
}

/// Add a frame to the live stack from a file path.
///
/// Returns the current stacked result.
pub fn api_stacking_add_frame(image_path: String) -> Result<ApiLiveStackingResult, SkotiqError> {
    let result = crate::stacking_api::stacking_add_frame(image_path)
        .map_err(|e| SkotiqError::ImageError(e))?;
    Ok(convert_result(result))
}

/// Add a frame to the live stack from raw pixel data.
pub fn api_stacking_add_frame_from_data(
    width: u32,
    height: u32,
    data: Vec<u16>,
) -> Result<ApiLiveStackingResult, SkotiqError> {
    let result = crate::stacking_api::stacking_add_frame_from_data(width, height, data)
        .map_err(|e| SkotiqError::ImageError(e))?;
    Ok(convert_result(result))
}

/// What was written when the stacked master was saved.
pub struct ApiLiveStackingMaster {
    pub file_path: String,
    pub stacked_frame_count: u32,
    /// The master's `EXPTIME`: Σ of the exposures the stacked frames reported.
    /// `0.0` means no frame reported one (an in-memory stack has no headers to
    /// read); the FITS card comment says so.
    pub total_integration_secs: f64,
    /// The master's `DATE-OBS`: the earliest stacked frame's stamp, or the
    /// moment the stack started when no frame carried one.
    pub date_obs: String,
}

/// Save the accumulated stack as a FITS master.
///
/// This is the session's data product — a PNG of the same pixels carries no
/// header, no WCS and no integration time.
pub async fn api_stacking_save_master_fits(
    file_path: String,
) -> Result<ApiLiveStackingMaster, SkotiqError> {
    // The write is blocking (and a full-frame master is tens of megabytes), so
    // it runs off the async executor like the other FITS writers here.
    let result = tokio::task::spawn_blocking(move || {
        crate::stacking_api::stacking_save_master_fits(file_path)
    })
    .await
    .map_err(|e| SkotiqError::OperationFailed(format!("Task join error: {}", e)))?
    .map_err(SkotiqError::ImageError)?;

    Ok(ApiLiveStackingMaster {
        file_path: result.file_path,
        stacked_frame_count: result.stacked_frame_count,
        total_integration_secs: result.total_integration_secs,
        date_obs: result.date_obs,
    })
}

/// Get the current stacked result without adding a frame.
pub fn api_stacking_get_result() -> Result<ApiLiveStackingResult, SkotiqError> {
    let result =
        crate::stacking_api::stacking_get_result().map_err(|e| SkotiqError::ImageError(e))?;
    Ok(convert_result(result))
}

/// Get the current stacking statistics.
pub fn api_stacking_get_stats() -> Result<ApiLiveStackingStats, SkotiqError> {
    let result =
        crate::stacking_api::stacking_get_stats().map_err(|e| SkotiqError::ImageError(e))?;
    Ok(convert_stats(result))
}

/// Reset the live stacker, clearing accumulated data but keeping the reference.
pub fn api_stacking_reset() -> Result<(), SkotiqError> {
    crate::stacking_api::stacking_reset().map_err(|e| SkotiqError::ImageError(e))
}

/// Stop live stacking and release all resources.
pub fn api_stacking_stop() -> Result<(), SkotiqError> {
    crate::stacking_api::stacking_stop().map_err(|e| SkotiqError::ImageError(e))
}

/// Check if live stacking is currently active.
#[flutter_rust_bridge::frb(sync)]
pub fn api_stacking_is_active() -> bool {
    crate::stacking_api::stacking_is_active()
}

/// Get the current stacked frame count.
#[flutter_rust_bridge::frb(sync)]
pub fn api_stacking_frame_count() -> u32 {
    crate::stacking_api::stacking_frame_count()
}

// Defect-map / bad-pixel cosmetic correction API

/// Status of a stored defect map for a given camera / sensor / temperature.
pub struct ApiDefectMapStatus {
    pub camera_id: String,
    pub width: u32,
    pub height: u32,
    pub temperature_bucket_decicelsius: i16,
    pub defective_pixel_count: u32,
    pub last_rebuilt_unix_seconds: i64,
    pub apply_during_capture: bool,
    pub stored_on_disk: bool,
}

pub(crate) fn defect_maps_root() -> std::path::PathBuf {
    // Why: SKOTIQ_DATA_DIR is the standard per-platform application
    // data path set by the Flutter shell on launch (see main_headless.dart
    // and the FFI bridge startup). The temp_dir fallback exists for unit
    // tests and for headless invocations where the env var hasn't been
    // populated yet — for those callers the defect maps are session-scoped
    // and don't need to survive a reboot. Production hosts hit the env-var
    // branch first.
    let base = std::env::var_os("SKOTIQ_DATA_DIR")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir().join("skotiq"));
    base.join("defect_maps")
}

pub(crate) fn sanitize_camera_id(camera_id: &str) -> String {
    camera_id
        .chars()
        .map(|c| match c {
            'a'..='z' | 'A'..='Z' | '0'..='9' | '-' | '_' => c,
            _ => '_',
        })
        .collect()
}

pub(crate) fn defect_map_path(
    camera_id: &str,
    width: u32,
    height: u32,
    bucket_decicelsius: i16,
) -> std::path::PathBuf {
    defect_maps_root().join(format!(
        "{}_{}x{}_{:+05}.ndm",
        sanitize_camera_id(camera_id),
        width,
        height,
        bucket_decicelsius
    ))
}

/// Tracks whether the user has enabled per-capture defect correction for
/// each camera_id. The bool is the toggle state; the runtime cache of the
/// map itself is loaded on demand by the capture pipeline.
pub(crate) static DEFECT_APPLY_FLAGS: OnceLock<Mutex<HashMap<String, bool>>> = OnceLock::new();

pub(crate) fn defect_apply_flags() -> &'static Mutex<HashMap<String, bool>> {
    DEFECT_APPLY_FLAGS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Build a defect map for a camera from a set of dark frames provided as
/// FITS/XISF file paths. Frames must all share dimensions and pixel type.
///
/// The resulting map is written to disk under
/// `$SKOTIQ_DATA_DIR/defect_maps/` keyed by camera id, sensor size and
/// temperature bucket, and the status is returned.
pub async fn api_defect_map_build(
    camera_id: String,
    dark_frame_paths: Vec<String>,
    sensor_temperature_celsius: f64,
) -> Result<ApiDefectMapStatus, SkotiqError> {
    if camera_id.trim().is_empty() {
        return Err(SkotiqError::InvalidParameter(
            "camera_id is empty".to_string(),
        ));
    }
    if dark_frame_paths.len() < skotiq_imaging::defect_map::MIN_CONSISTENCY_FRAMES {
        return Err(SkotiqError::InvalidParameter(format!(
            "defect map build requires at least {} dark frames; got {}",
            skotiq_imaging::defect_map::MIN_CONSISTENCY_FRAMES,
            dark_frame_paths.len()
        )));
    }

    let darks: Vec<ImageData> = tokio::task::spawn_blocking(move || {
        let mut frames = Vec::with_capacity(dark_frame_paths.len());
        for path in &dark_frame_paths {
            let result = skotiq_imaging::read_image(std::path::Path::new(path))
                .map_err(|e| format!("failed to read {}: {}", path, e))?;
            frames.push(result.image);
        }
        Ok::<_, String>(frames)
    })
    .await
    .map_err(|e| SkotiqError::ImageError(format!("join error reading darks: {}", e)))?
    .map_err(SkotiqError::ImageError)?;

    let bucket = skotiq_imaging::defect_map::bucket_temperature(sensor_temperature_celsius);
    let dark_refs: Vec<&ImageData> = darks.iter().collect();
    let map = skotiq_imaging::defect_map::build_defect_map(&dark_refs, bucket)
        .map_err(|e| SkotiqError::ImageError(e.to_string()))?;

    let path = defect_map_path(&camera_id, map.width, map.height, bucket);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| {
            SkotiqError::ImageError(format!(
                "failed to create defect map directory {}: {}",
                parent.display(),
                e
            ))
        })?;
    }
    map.write_to_file(&path)
        .map_err(|e| SkotiqError::ImageError(e.to_string()))?;

    let apply_during_capture = {
        // Why: absence of a flag for this camera id is the canonical "off"
        // state — apply-during-capture is opt-in and the map is only written
        // when the user toggles it on for a specific (camera, temperature)
        // pair. No need to surface this as an error.
        let flags = defect_apply_flags().lock().await;
        flags.get(&camera_id).copied().unwrap_or(false)
    };

    Ok(ApiDefectMapStatus {
        camera_id,
        width: map.width,
        height: map.height,
        temperature_bucket_decicelsius: bucket,
        defective_pixel_count: map.defective_count(),
        last_rebuilt_unix_seconds: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0),
        apply_during_capture,
        stored_on_disk: true,
    })
}

/// Toggle whether the defect map for this camera is applied to lights
/// during capture. The map must already exist on disk for the toggle to
/// take effect at the next capture; this call only updates the user's
/// preference.
pub async fn api_defect_map_apply(
    camera_id: String,
    apply_during_capture: bool,
) -> Result<(), SkotiqError> {
    if camera_id.trim().is_empty() {
        return Err(SkotiqError::InvalidParameter(
            "camera_id is empty".to_string(),
        ));
    }
    let mut flags = defect_apply_flags().lock().await;
    flags.insert(camera_id, apply_during_capture);
    Ok(())
}

/// Delete the defect map stored on disk for the given camera, sensor
/// dimensions and temperature bucket. Also resets the apply-during-
/// capture flag for that camera.
pub async fn api_defect_map_clear(
    camera_id: String,
    width: u32,
    height: u32,
    sensor_temperature_celsius: f64,
) -> Result<(), SkotiqError> {
    if camera_id.trim().is_empty() {
        return Err(SkotiqError::InvalidParameter(
            "camera_id is empty".to_string(),
        ));
    }
    let bucket = skotiq_imaging::defect_map::bucket_temperature(sensor_temperature_celsius);
    let path = defect_map_path(&camera_id, width, height, bucket);
    if path.exists() {
        std::fs::remove_file(&path).map_err(|e| {
            SkotiqError::ImageError(format!(
                "failed to delete defect map {}: {}",
                path.display(),
                e
            ))
        })?;
    }
    let mut flags = defect_apply_flags().lock().await;
    flags.remove(&camera_id);
    Ok(())
}

/// push the active defect-map application state to the
/// running sequencer.
///
/// When `enabled == true`, the bridge loads the `.ndm` file for
/// `(camera_id, width, height, sensor_temperature_celsius)` from disk
/// (returning an error if no map exists), wraps it in a
/// `DefectMapApplyState` along with the configured method + kernel +
/// save-original flag, and pushes the state via
/// `executor.update_defect_map(Some(state))`. When `enabled == false`,
/// `None` is pushed (the sequencer disables per-frame correction).
///
/// Method / kernel come from the user's settings (validated here so a
/// bad combination is rejected at the FFI boundary rather than at
/// per-frame application time).
pub async fn api_sequencer_apply_defect_map(
    camera_id: String,
    width: u32,
    height: u32,
    sensor_temperature_celsius: f64,
    enabled: bool,
    method: String,
    kernel_diameter: u8,
    save_original: bool,
) -> Result<(), SkotiqError> {
    if camera_id.trim().is_empty() {
        return Err(SkotiqError::InvalidParameter(
            "camera_id is empty".to_string(),
        ));
    }

    if !enabled {
        // Clear the live state. Also reset the apply flag so a future
        // `api_defect_map_get_status` call honestly reflects the off
        // state.
        {
            let mut flags = defect_apply_flags().lock().await;
            flags.insert(camera_id.clone(), false);
        }
        let mut executor = crate::api::sequencer::get_sequence_executor().write().await;
        executor.update_defect_map(None).await;
        tracing::info!(
            "Defect map application disabled for camera {} (no map pushed to sequencer)",
            camera_id
        );
        return Ok(());
    }

    let kernel = skotiq_imaging::defect_map::KernelSize::from_diameter(kernel_diameter)
        .ok_or_else(|| {
            SkotiqError::InvalidParameter(format!(
                "kernel_diameter must be 3, 5, or 7; got {}",
                kernel_diameter
            ))
        })?;
    let method_parsed = skotiq_imaging::defect_map::CorrectionMethod::from_wire(&method);

    let bucket = skotiq_imaging::defect_map::bucket_temperature(sensor_temperature_celsius);
    let path = defect_map_path(&camera_id, width, height, bucket);
    if !path.exists() {
        return Err(SkotiqError::InvalidParameter(format!(
            "No defect map stored for camera={} {}x{} at {} deci-celsius; \
             build one before enabling apply-during-capture.",
            camera_id, width, height, bucket,
        )));
    }
    let map = skotiq_imaging::defect_map::DefectMap::read_from_file(&path)
        .map_err(|e| SkotiqError::ImageError(e.to_string()))?;

    // Mirror the persisted apply flag so `get_status` round-trips the
    // user's preference correctly.
    {
        let mut flags = defect_apply_flags().lock().await;
        flags.insert(camera_id.clone(), true);
    }

    let state = skotiq_sequencer::DefectMapApplyState {
        camera_id: camera_id.clone(),
        map: std::sync::Arc::new(map),
        method: method_parsed,
        kernel,
        save_original,
    };

    let mut executor = crate::api::sequencer::get_sequence_executor().write().await;
    executor.update_defect_map(Some(state)).await;
    tracing::info!(
        "Defect map application enabled for camera {} ({}x{}, bucket={} dC) method={}, kernel={}, save_original={}",
        camera_id,
        width,
        height,
        bucket,
        method,
        kernel_diameter,
        save_original,
    );
    Ok(())
}

/// Look up the status of the stored defect map for a camera at the given
/// sensor size and temperature. Returns `Ok(None)` if no map is stored
/// for that combination.
pub async fn api_defect_map_get_status(
    camera_id: String,
    width: u32,
    height: u32,
    sensor_temperature_celsius: f64,
) -> Result<Option<ApiDefectMapStatus>, SkotiqError> {
    if camera_id.trim().is_empty() {
        return Err(SkotiqError::InvalidParameter(
            "camera_id is empty".to_string(),
        ));
    }
    let bucket = skotiq_imaging::defect_map::bucket_temperature(sensor_temperature_celsius);
    let path = defect_map_path(&camera_id, width, height, bucket);
    if !path.exists() {
        return Ok(None);
    }
    let map = skotiq_imaging::defect_map::DefectMap::read_from_file(&path)
        .map_err(|e| SkotiqError::ImageError(e.to_string()))?;
    let metadata = std::fs::metadata(&path).map_err(|e| {
        SkotiqError::ImageError(format!(
            "failed to stat defect map {}: {}",
            path.display(),
            e
        ))
    })?;
    let last_rebuilt = metadata
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);

    let apply_during_capture = {
        // Why: absence of a flag for this camera id is the canonical "off"
        // state — apply-during-capture is opt-in and the map is only written
        // when the user toggles it on for a specific (camera, temperature)
        // pair. No need to surface this as an error.
        let flags = defect_apply_flags().lock().await;
        flags.get(&camera_id).copied().unwrap_or(false)
    };

    Ok(Some(ApiDefectMapStatus {
        camera_id,
        width: map.width,
        height: map.height,
        temperature_bucket_decicelsius: map.temperature_bucket_decicelsius,
        defective_pixel_count: map.defective_count(),
        last_rebuilt_unix_seconds: last_rebuilt,
        apply_during_capture,
        stored_on_disk: true,
    }))
}

// Image grading: round-trip test for the rich-header save path.

#[cfg(test)]
mod exposure_failure_classification_tests;

#[cfg(test)]
mod sim_exposure_tests;

#[cfg(test)]
mod auto_stretch_color_tests;

#[cfg(test)]
mod calibrate_header_carry_over_tests;

#[cfg(test)]
mod fits_thumbnail_tests;

#[cfg(test)]
mod detect_stars_in_file_tests;
