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
//    documented Nightshade-default science thresholds and FITS-format
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
use nightshade_imaging::{
    calculate_airmass, validate_fits_header, validate_image, write_fits, BayerPattern,
    DebayerAlgorithm, FitsHeader, ImageData,
};
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
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
/// needs.
///
/// Standalone autofocus and focuser backlash calibration are both started by
/// an operator with no producing sequence node, save no FITS frames and grade
/// nothing, so every field outside the camera, the focuser, cancellation and
/// the executor-event bridge is the honest empty value. Shared between the two
/// entry points so they cannot drift apart — they drive the same hardware
/// through the same instruction layer and must present it the same context.
fn one_shot_focus_context(
    camera_id: String,
    focuser_id: String,
    cancellation_token: Arc<AtomicBool>,
    event_tx: tokio::sync::broadcast::Sender<nightshade_sequencer::ExecutorEvent>,
    device_ops: nightshade_sequencer::SharedDeviceOps,
) -> nightshade_sequencer::instructions::InstructionContext {
    nightshade_sequencer::instructions::InstructionContext {
        // One-shot bridge capture: no producing sequence node.
        node_id: String::new(),
        target_ra: None,
        target_dec: None,
        target_name: None,
        target_rotation: None,
        current_filter: None,
        current_binning: nightshade_sequencer::Binning::One,
        cancellation_token,
        camera_id: Some(camera_id),
        mount_id: None,
        focuser_id: Some(focuser_id),
        filterwheel_id: None,
        dome_id: None,
        rotator_id: None,
        cover_calibrator_id: None,
        save_path: None,
        latitude: None,
        longitude: None,
        device_ops,
        trigger_state: None,
        filter_focus_offsets: std::collections::HashMap::new(),
        event_tx: Some(event_tx),
        recovery_request_tx: None,
        // Image Grading: standalone autofocus from the API does
        // not save FITS frames, so empty FITS-metadata defaults are
        // honest here. The InstructionContext fields exist to be passed
        // through to execute_exposure; execute_autofocus ignores them.
        session_id: String::new(),
        target_id: None,
        mosaic_panel: None,
        current_filter_index: None,
        set_temp_c: None,
        bayer_pattern: None,
        observer_name: None,
        site_elevation_m: None,
        camera_make: None,
        camera_model: None,
        telescope_name: None,
        telescope_focal_length_mm: None,
        telescope_aperture_mm: None,
        last_plate_solve: std::sync::Arc::new(tokio::sync::RwLock::new(None)),
        hfr_baseline: std::sync::Arc::new(tokio::sync::RwLock::new(None)),
        hfr_baseline_samples: std::sync::Arc::new(tokio::sync::RwLock::new(Vec::new())),
        consecutive_rejects: std::sync::Arc::new(std::sync::atomic::AtomicU32::new(0)),
        frames_accepted: std::sync::Arc::new(std::sync::atomic::AtomicU32::new(0)),
        frames_rejected: std::sync::Arc::new(std::sync::atomic::AtomicU32::new(0)),
        default_quality_check: None,
        reject_folder_path: None,
        // defect map state. Standalone autofocus from
        // the API does not save FITS frames so this is unused; pass an
        // empty slot to satisfy the struct contract.
        defect_map_apply: std::sync::Arc::new(tokio::sync::RwLock::new(None)),
        // Forensics: standalone autofocus doesn't grade frames.
        forensics_history: std::sync::Arc::new(tokio::sync::RwLock::new(
            std::collections::VecDeque::new(),
        )),
        current_sky_brightness_mag: std::sync::Arc::new(tokio::sync::RwLock::new(None)),
        cloud_motion_snapshot: std::sync::Arc::new(tokio::sync::RwLock::new(
            nightshade_sequencer::CloudMotionSnapshot::default(),
        )),
        current_wind_kph: std::sync::Arc::new(tokio::sync::RwLock::new(None)),
        current_sensor_temp_c: std::sync::Arc::new(tokio::sync::RwLock::new(None)),
        // Replay Debug — one-shot bridge API doesn't emit decisions.
        decision_tx: None,
        active_sequence_run_id: std::sync::Arc::new(parking_lot::RwLock::new(None)),
        // Standalone autofocus from the API is not driven by the node-runtime
        // disconnect-retry loop, so this one-shot context owns a fresh,
        // unshared flag (no recovery driver observes it here).
        device_disconnect_recovery_pending: std::sync::Arc::new(
            std::sync::atomic::AtomicBool::new(false),
        ),
        // Dual-rig — standalone autofocus runs with no secondary coordination.
        dither_barrier: None,
        // An Imaging-tab capture is attended: one attempt, as before.
        device_retry: nightshade_sequencer::instructions::DeviceRetryHandle::single_attempt(),
    }
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
) -> Result<AutofocusResultApi, NightshadeError> {
    tracing::info!(
        "Starting autofocus with camera {} and focuser {}",
        camera_id,
        device_id
    );

    if !config.exposure_time.is_finite() || config.exposure_time <= 0.0 {
        return Err(NightshadeError::InvalidParameter(
            "autofocus exposure time must be finite and positive".to_string(),
        ));
    }
    if config.step_size <= 0 || !(1..=50).contains(&config.steps_out) {
        return Err(NightshadeError::InvalidParameter(
            "autofocus step size must be positive and steps out must be 1..50".to_string(),
        ));
    }
    if !(1..=4).contains(&config.binning)
        || !(1..=10).contains(&config.number_of_attempts)
        || !(1..=20).contains(&config.exposures_per_point)
    {
        return Err(NightshadeError::InvalidParameter(
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
        return Err(NightshadeError::InvalidParameter(
            "autofocus R²/crop settings are invalid".to_string(),
        ));
    }
    if config.focuser_settle_time_ms > 10_000 || config.backlash_in < 0 || config.backlash_out < 0 {
        return Err(NightshadeError::InvalidParameter(
            "autofocus settle/backlash settings are out of range".to_string(),
        ));
    }
    if config.gain.is_some_and(|gain| gain < 0) || config.offset.is_some_and(|offset| offset < 0) {
        return Err(NightshadeError::InvalidParameter(
            "autofocus gain and offset cannot be negative".to_string(),
        ));
    }

    use nightshade_sequencer::instructions::{
        execute_autofocus_admitted, try_admit_autofocus_run, InstructionContext,
    };
    use nightshade_sequencer::{AutofocusConfig, AutofocusMethod, Binning, NodeStatus};
    use serde::Deserialize;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[derive(Debug, Deserialize)]
    struct LegacyAutofocusPayload {
        best_position: i32,
        best_hfr: f64,
        r_squared: f64,
        focus_data: Vec<(i32, f64)>,
    }

    let autofocus_guard = try_admit_autofocus_run().ok_or_else(|| NightshadeError::DeviceBusy {
        device_id: device_id.clone(),
        current_operation: "autofocus".to_string(),
    })?;

    // Reset cancellation token only after admission. A rejected second Start
    // must never clear the active run's pending cancellation request.
    let cancel_token = get_autofocus_cancel_token();
    cancel_token.store(false, Ordering::Relaxed);

    // Store the method string for result
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
    // reach the same NightshadeEvent stream Dart subscribes to. Without this
    // the user only sees a generic "autofocus failed" return code with no
    // hint that the underlying problem was a write error or drive disconnect.
    // The original sender lives on the stack for the duration of the call;
    // the cloned handle is moved into `InstructionContext::event_tx`. When the
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

    let progress_fn = |_: f64, detail: String| {
        if !detail.contains("\"type\":\"autofocus_progress\"") {
            return;
        }
        get_state().publish_equipment_event(
            EquipmentEvent::PropertyChanged {
                device_type: "focuser".to_string(),
                device_id: progress_focuser_id.clone(),
                property: "AutofocusProgress".to_string(),
                value: detail,
            },
            EventSeverity::Info,
        );
    };

    let result =
        execute_autofocus_admitted(&af_config, &ctx, Some(&progress_fn), autofocus_guard).await;

    // Get current timestamp
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);

    match result.status {
        NodeStatus::Success => {
            let data = result.data.ok_or_else(|| {
                NightshadeError::OperationFailed(
                    "Autofocus completed without a result payload".to_string(),
                )
            })?;

            // Canonical payload (nightshade_sequencer::AutofocusResult)
            if let Ok(af_result) =
                serde_json::from_value::<nightshade_sequencer::AutofocusResult>(data.clone())
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

            Err(NightshadeError::OperationFailed(
                "Autofocus completed but returned an unrecognized payload format".to_string(),
            ))
        }
        NodeStatus::Failure => Err(NightshadeError::OperationFailed(
            result.message.unwrap_or("Autofocus failed".to_string()),
        )),
        NodeStatus::Cancelled => Err(NightshadeError::Cancelled),
        _ => Err(NightshadeError::OperationFailed(
            "Unknown error".to_string(),
        )),
    }
}

/// Cancel autofocus
pub async fn api_cancel_autofocus() -> Result<(), NightshadeError> {
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
/// `config_json` is a [`nightshade_sequencer::instructions::BacklashCalibrationConfig`]
/// and the returned string is a
/// [`nightshade_sequencer::instructions::BacklashCalibrationOutcome`]. JSON on
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
) -> Result<String, NightshadeError> {
    use nightshade_sequencer::instructions::{
        execute_backlash_calibration_admitted, try_admit_autofocus_run,
        validate_backlash_calibration_config, BacklashCalibrationConfig,
        BACKLASH_CALIBRATION_CANCELLED,
    };

    let config: BacklashCalibrationConfig =
        serde_json::from_str(&config_json).map_err(|error| {
            NightshadeError::InvalidParameter(format!(
                "backlash calibration config is not valid: {}",
                error
            ))
        })?;
    validate_backlash_calibration_config(&config).map_err(NightshadeError::InvalidParameter)?;

    // The calibration drives the same camera and focuser as a sweep, so it
    // takes the autofocus admission gate rather than a gate of its own.
    let guard = try_admit_autofocus_run().ok_or_else(|| NightshadeError::DeviceBusy {
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
                NightshadeError::Cancelled
            } else {
                NightshadeError::OperationFailed(error)
            }
        })?;

    serde_json::to_string(&outcome).map_err(|error| {
        NightshadeError::OperationFailed(format!(
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
/// [`nightshade_sequencer::instructions::BacklashCalibrationPlan`] as JSON.
pub async fn api_plan_focuser_backlash_calibration(
    config_json: String,
    center_position: i32,
) -> Result<String, NightshadeError> {
    use nightshade_sequencer::instructions::{
        plan_backlash_calibration, validate_backlash_calibration_config, BacklashCalibrationConfig,
    };

    let config: BacklashCalibrationConfig =
        serde_json::from_str(&config_json).map_err(|error| {
            NightshadeError::InvalidParameter(format!(
                "backlash calibration config is not valid: {}",
                error
            ))
        })?;
    validate_backlash_calibration_config(&config).map_err(NightshadeError::InvalidParameter)?;

    let plan = plan_backlash_calibration(&config, center_position);
    serde_json::to_string(&plan).map_err(|error| {
        NightshadeError::OperationFailed(format!(
            "backlash calibration plan could not be encoded: {}",
            error
        ))
    })
}

/// Ask a running backlash calibration to stop. The routine returns the focuser
/// to where the operator left it before reporting the cancellation.
pub async fn api_cancel_focuser_backlash_calibration() -> Result<(), NightshadeError> {
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

/// Convert grayscale (1 byte/pixel) or RGB (3 bytes/pixel) display data to RGBA (4 bytes/pixel).
/// Uses rayon for parallel conversion on large images.
pub(crate) fn display_data_to_rgba(data: &[u8], is_color: bool) -> Vec<u8> {
    if is_color {
        // RGB -> RGBA
        let num_pixels = data.len() / 3;
        let mut rgba = vec![0u8; num_pixels * 4];
        rgba.par_chunks_exact_mut(4)
            .zip(data.par_chunks_exact(3))
            .for_each(|(dst, src)| {
                dst[0] = src[0]; // R
                dst[1] = src[1]; // G
                dst[2] = src[2]; // B
                dst[3] = 255; // A
            });
        rgba
    } else {
        // Grayscale -> RGBA
        let num_pixels = data.len();
        let mut rgba = vec![0u8; num_pixels * 4];
        rgba.par_chunks_exact_mut(4)
            .zip(data.par_iter())
            .for_each(|(dst, &gray)| {
                dst[0] = gray; // R
                dst[1] = gray; // G
                dst[2] = gray; // B
                dst[3] = 255; // A
            });
        rgba
    }
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

/// Stars sampled for the per-frame medians: the brightest half of the
/// detections, never more than this many. Detection returns stars brightest
/// first, so the sample is the same set on every run over the same frame.
const FRAME_METRIC_SAMPLE_CAP: usize = 50;

/// Largest HFR or FWHM, in pixels, that a detection can contribute to a frame
/// median. A value at or past it is a smear or a detection artefact, not a star
/// this frame can be measured by.
const FRAME_METRIC_MAX_PIXELS: f64 = 20.0;

/// Median of the sampled stars' `value`, or `None` when none of them carries a
/// usable one.
fn frame_metric_median(
    stars: &[nightshade_imaging::DetectedStar],
    value: impl Fn(&nightshade_imaging::DetectedStar) -> f64,
) -> Option<f64> {
    let sample = (stars.len() / 2).clamp(1, FRAME_METRIC_SAMPLE_CAP);
    let mut values: Vec<f64> = stars
        .iter()
        .take(sample)
        .map(&value)
        .filter(|v| *v > 0.0 && *v < FRAME_METRIC_MAX_PIXELS)
        .collect();
    if values.is_empty() {
        return None;
    }
    values.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    Some(values[values.len() / 2])
}

/// The stats block a captured frame publishes to the last-image cache, built
/// from that frame's own statistics and the stars already detected in it.
///
/// Every path that stores a frame builds its block here — the simulated
/// exposure, the real-camera exposure, and the sequencer's own exposure through
/// `UnifiedDeviceOps` — so one frame reports the same measurements whoever asked
/// for it. The sequencer path used to fill the struct itself and left `hfr` and
/// `fwhm` out, so a whole night of frames answered `/api/camera/last-image` with
/// a real star count beside a null HFR while the same frames' HFR was measured,
/// logged and stored.
///
/// It measures nothing new: `stats` and `stars` are the results the caller
/// already computed for the frame, and the medians are read out of them.
///
/// `None` for HFR, FWHM or eccentricity means too few usable stars to measure
/// this frame — never a fabricated 0.
pub(crate) fn frame_stats_result(
    stats: &nightshade_imaging::ImageStats,
    stars: &[nightshade_imaging::DetectedStar],
) -> ImageStatsResult {
    ImageStatsResult {
        min: stats.min,
        max: stats.max,
        mean: stats.mean,
        median: stats.median,
        std_dev: stats.std_dev,
        hfr: frame_metric_median(stars, |s| s.hfr),
        eccentricity: nightshade_imaging::frame_eccentricity(stars),
        fwhm: frame_metric_median(stars, |s| s.fwhm),
        star_count: stars.len() as u32,
    }
}

/// Raw image info with metadata - used by sequencer for actual image analysis
/// This preserves the original 16-bit sensor data needed for HFR calculation, plate solving, etc.
#[derive(Debug, Clone)]
pub struct RawImageInfo {
    pub width: u32,
    pub height: u32,
    pub data: Vec<u16>,                   // Raw 16-bit sensor data
    pub sensor_type: Option<String>,      // "Monochrome" or "Color"
    pub bayer_offset: Option<(i32, i32)>, // Bayer pattern offset for color sensors
}

/// Unified captured image data - contains all image data for atomic updates
/// This ensures the UI never sees inconsistent state between raw data and display data
#[derive(Debug, Clone)]
pub struct CapturedImageData {
    /// Display-ready image result (8-bit for UI)
    pub display: CapturedImageResult,
    /// Raw 16-bit image info with metadata (for FITS saving, HFR, etc.)
    pub raw_info: RawImageInfo,
}

/// Per-device image storage capacity.
///
/// Why 50: A typical 4-hour imaging session at 30s exposures produces ~480 frames,
/// but the storage is keyed by device-id, not by frame, so each connected camera
/// occupies one slot. 50 covers any realistic rig (1-5 cameras) with generous
/// headroom for transient reconnections that rotate the device-id (e.g. USB
/// re-enumeration appending a new serial suffix). At ~24 MB per u16 frame
/// (4144x2822 sensors), the cap holds worst-case ~1.2 GB which keeps 16 GB
/// laptops safe under prolonged sessions.
pub(crate) const UNIFIED_IMAGE_STORAGE_CAPACITY: usize = 50;

/// Per-device image storage - keyed by device ID to support multi-camera operation.
///
/// Each camera's image data is stored independently, preventing race conditions
/// where concurrent cameras could overwrite each other's captured images.
///
/// Bounded with an LRU policy so unique device-ids accumulated over long sessions
/// (USB re-enumeration, network device churn) cannot leak raw u16 buffers
/// indefinitely. On eviction the oldest-touched entry is dropped and a debug
/// trace is emitted; see `store_captured_image_atomically`.
pub(crate) static UNIFIED_IMAGE_STORAGE: OnceLock<
    Arc<tokio::sync::Mutex<lru::LruCache<String, CapturedImageData>>>,
> = OnceLock::new();

pub(crate) fn get_unified_image_storage(
) -> &'static Arc<tokio::sync::Mutex<lru::LruCache<String, CapturedImageData>>> {
    UNIFIED_IMAGE_STORAGE.get_or_init(|| {
        let cap = std::num::NonZeroUsize::new(UNIFIED_IMAGE_STORAGE_CAPACITY)
            .expect("UNIFIED_IMAGE_STORAGE_CAPACITY must be non-zero");
        Arc::new(tokio::sync::Mutex::new(lru::LruCache::new(cap)))
    })
}

/// Store captured image data atomically for a specific device
/// This ensures all image-related data (display, raw, metadata) is updated together,
/// preventing race conditions where the UI could see inconsistent state.
///
/// If the cache is at capacity and `device_id` is not already present, the
/// least-recently-used entry is evicted. Evictions emit a `tracing::debug!`
/// trace so memory pressure on long sessions is observable.
pub(crate) async fn store_captured_image_atomically(
    device_id: &str,
    display: CapturedImageResult,
    raw_info: RawImageInfo,
) {
    let mut storage = get_unified_image_storage().lock().await;
    let value = CapturedImageData { display, raw_info };
    if let Some((evicted_id, _evicted)) = storage.push(device_id.to_string(), value) {
        if evicted_id != device_id {
            tracing::debug!(
                "UNIFIED_IMAGE_STORAGE: evicted LRU entry for device_id={} (cap={})",
                evicted_id,
                UNIFIED_IMAGE_STORAGE_CAPACITY
            );
        }
    }
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
) -> Result<(), NightshadeError> {
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
) -> Result<(), NightshadeError> {
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
            return Err(NightshadeError::InvalidParameter(
                "Camera subframe width and height must be positive".to_string(),
            ));
        }
        Some(nightshade_sequencer::CameraSubframe {
            start_x: start_x.expect("checked above"),
            start_y: start_y.expect("checked above"),
            width,
            height,
        })
    } else if supplied.iter().any(|value| *value) {
        return Err(NightshadeError::InvalidParameter(
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
        nightshade_native::camera::FrameType::from_str_lenient(&frame_type),
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
) -> Result<(), NightshadeError> {
    camera_start_exposure_configured_opt(
        device_id,
        duration_secs,
        gain,
        offset,
        bin_x,
        bin_y,
        None,
        nightshade_native::camera::FrameType::Light,
    )
    .await
}

/// Turn a `DeviceOps` capture error into the narrowest `NightshadeError` that
/// still describes it.
///
/// `camera_start_exposure_configured` reports every failure as a bare `String`.
/// A frame rejected by image validation (saturated, all-zero) is the operator's
/// exposure to fix, not a fault: it becomes [`NightshadeError::ExposureFailed`],
/// which the headless mapper renders as 422. Everything else falls through to
/// [`NightshadeError::OperationFailed`] (HTTP 500). The split matters because a
/// client retrying on 5xx would otherwise retry a request that can only fail again.
fn classify_exposure_failure(device_id: &str, error: String) -> NightshadeError {
    match error.strip_prefix(crate::unified_device_ops::IMAGE_VALIDATION_FAILED_PREFIX) {
        Some(reason) => NightshadeError::ExposureFailed {
            camera_id: device_id.to_string(),
            reason: reason.to_string(),
        },
        None => NightshadeError::OperationFailed(error),
    }
}

/// Terminate a simulated exposure the operator aborted.
///
/// Mirrors what the real path does after its own generation check: park the
/// sensor, publish a FAILED completion so nothing downstream treats the
/// abandoned frame as a keeper, and report the cancellation to the caller.
async fn sim_exposure_cancelled() -> Result<(), NightshadeError> {
    {
        let mut camera = get_sim_camera().write().await;
        camera.status.state = CameraState::Idle;
    }
    get_state().publish_imaging_event(
        ImagingEvent::ExposureComplete { success: false },
        EventSeverity::Info,
    );
    tracing::info!("Exposure cancelled");
    Err(NightshadeError::OperationFailed(
        "Exposure cancelled".to_string(),
    ))
}

#[allow(clippy::too_many_arguments)]
pub(crate) async fn camera_start_exposure_configured_opt(
    device_id: String,
    duration_secs: f64,
    gain: Option<i32>,
    offset: Option<i32>,
    bin_x: i32,
    bin_y: i32,
    subframe: Option<nightshade_sequencer::CameraSubframe>,
    frame_type: nightshade_native::camera::FrameType,
) -> Result<(), NightshadeError> {
    tracing::info!(
        "Starting {}s exposure with gain={:?}, offset={:?}, bin={}x{}",
        duration_secs,
        gain,
        offset,
        bin_x,
        bin_y
    );

    // Check if simulator or real device
    if device_id.starts_with("sim_") {
        // Simulator path (existing code)
        // Same abort ledger the real path uses, so `api_camera_cancel_exposure`
        // means the same thing on both. Without it the simulated exposure ran
        // to full duration after the operator aborted, then published
        // ExposureComplete{success:true} and stored the frame — the one
        // failure mode a simulator must not have, because it makes an abort
        // that is broken look like an abort that works.
        let acquisition_generation =
            crate::unified_device_ops::exposure_abort_generation(&device_id).await;
        // Update camera state to exposing
        {
            let mut camera = get_sim_camera().write().await;
            camera.status.state = CameraState::Exposing;
        }

        // Publish exposure started event
        get_state().publish_imaging_event(
            ImagingEvent::ExposureStarted {
                duration_secs,
                frame_type: crate::device::FrameType::Light,
            },
            EventSeverity::Info,
        );

        // Simulate exposure with progress updates using adaptive polling
        // This reduces CPU overhead for long simulated exposures while maintaining
        // responsiveness for progress updates
        let start_time = std::time::Instant::now();
        let duration = std::time::Duration::from_secs_f64(duration_secs);
        let mut poller: AdaptivePoller<String> =
            AdaptivePoller::from_preset(PollerPreset::Exposure);

        while start_time.elapsed() < duration {
            if crate::unified_device_ops::exposure_abort_generation(&device_id).await
                != acquisition_generation
            {
                return sim_exposure_cancelled().await;
            }

            let progress = start_time.elapsed().as_secs_f64() / duration_secs;
            let progress_bucket = format!("{:.1}", progress); // Bucket progress for change detection

            get_state().publish_imaging_event(
                ImagingEvent::ExposureProgress {
                    progress,
                    remaining_secs: duration_secs - start_time.elapsed().as_secs_f64(),
                },
                EventSeverity::Info,
            );

            // Adaptive polling: backs off when progress isn't changing significantly
            let poll_interval = poller.tick(&progress_bucket);
            tokio::time::sleep(poll_interval).await;
        }

        // An abort landing during the last poll interval must still discard the
        // frame: storing it would put an exposure the operator gave up on into
        // the gallery and the session's frame count.
        if crate::unified_device_ops::exposure_abort_generation(&device_id).await
            != acquisition_generation
        {
            return sim_exposure_cancelled().await;
        }

        // Update camera state to reading
        {
            let mut camera = get_sim_camera().write().await;
            camera.status.state = CameraState::Reading;
        }

        // Render the frame through the simulated-capture renderer the sequencer's
        // DeviceManager download uses. One renderer serves both paths, so a
        // simulated frame is plate-solvable and everything downstream of a solve —
        // Slew & Center, framing, mosaic tiles, meridian-flip recentre, polar
        // alignment — is exercisable from the Imaging screen.
        //
        // The simulator commands no real hardware, so an unspecified (None)
        // gain falls back to 0 for brightness math.
        let sim_gain = gain.unwrap_or(0);
        // The geometry the camera advertises, not a second hardcoded sensor: the
        // Framing FOV box and every measurement taken through this path must
        // describe the frames this same camera delivers to the sequencer path.
        let (advertised_width, advertised_height, sim_pixel_size, sim_offset, sim_max_adu) = {
            let camera = get_sim_camera().read().await;
            (
                camera.status.sensor_width,
                camera.status.sensor_height,
                camera.status.pixel_size_x,
                camera.status.offset,
                camera.status.max_adu,
            )
        };
        let sim_frame =
            crate::sim_capture::render_sim_frame(crate::sim_capture::SimCaptureRequest {
                exposure_secs: duration_secs,
                sensor_width: advertised_width.max(1),
                sensor_height: advertised_height.max(1),
                pixel_size_um: sim_pixel_size,
                gain: sim_gain,
                offset: offset.unwrap_or(sim_offset),
                bin_x: bin_x.max(1) as u32,
                bin_y: bin_y.max(1) as u32,
                subframe: subframe
                    .as_ref()
                    .map(|roi| (roi.start_x, roi.start_y, roi.width, roi.height)),
                frame_type,
                max_adu: sim_max_adu.clamp(1, u32::from(u16::MAX)) as u16,
            })
            .await;
        // Binning and subframing both change the delivered geometry, so take it
        // from the renderer rather than re-deriving it here.
        let (sensor_width, sensor_height) = (sim_frame.width, sim_frame.height);
        let raw_data = sim_frame.data;

        // Measure the simulated frame with the same code the real-camera branch
        // uses, so autofocus and guiding regressions show up in simulator metrics.
        let image_bytes: Vec<u8> = raw_data.iter().flat_map(|&val| val.to_le_bytes()).collect();
        let image = nightshade_imaging::ImageData {
            width: sensor_width,
            height: sensor_height,
            channels: 1,
            pixel_type: nightshade_imaging::PixelType::U16,
            data: image_bytes,
        };
        let stats = nightshade_imaging::calculate_stats_u16(&image);
        let stretch_params = nightshade_imaging::auto_stretch_stf(&image);
        let display_data_raw = nightshade_imaging::apply_stretch(&image, &stretch_params);
        let mut histogram = vec![0u32; 256];
        for &pixel in &display_data_raw {
            histogram[pixel as usize] += 1;
        }
        let stars = nightshade_imaging::detect_stars(
            &image,
            &nightshade_imaging::StarDetectionConfig::default(),
        );
        let frame_stats = frame_stats_result(&stats, &stars);
        tracing::info!(
            "Simulated capture: {}x{}, {} stars detected, median HFR: {:?}, median ecc: {:?}",
            sensor_width,
            sensor_height,
            frame_stats.star_count,
            frame_stats.hfr,
            frame_stats.eccentricity
        );

        // Convert grayscale display data to RGBA for Flutter rendering
        let display_data = display_data_to_rgba(&display_data_raw, false);

        // Store all image data atomically to prevent race conditions
        // This ensures the UI never sees inconsistent state between raw and display data
        let display_result = CapturedImageResult {
            width: sensor_width,
            height: sensor_height,
            display_data,
            histogram,
            stats: frame_stats,
            exposure_time: duration_secs,
            timestamp: chrono::Utc::now().format("%Y-%m-%dT%H:%M:%S").to_string(),
            is_color: false, // Simulated images are grayscale
        };

        let raw_info = RawImageInfo {
            width: sensor_width,
            height: sensor_height,
            data: raw_data,
            sensor_type: Some("Monochrome".to_string()), // Simulated camera is mono
            bayer_offset: None,
        };

        store_captured_image_atomically(&device_id, display_result, raw_info).await;

        // Update camera state back to idle
        {
            let mut camera = get_sim_camera().write().await;
            camera.status.state = CameraState::Idle;
        }

        // Publish exposure complete event
        get_state().publish_imaging_event(
            ImagingEvent::ExposureComplete { success: true },
            EventSeverity::Info,
        );

        tracing::info!("Exposure complete");
        Ok(())
    } else {
        // Real camera path - use UnifiedDeviceOps which routes through DeviceManager
        // Events (ExposureStarted, ExposureProgress, ExposureComplete) are published by UnifiedDeviceOps
        let device_ops = create_unified_device_ops();

        // Start exposure and get raw data (blocks until complete, events published by UnifiedDeviceOps)
        let seq_image = device_ops
            .camera_start_exposure_configured(
                &device_id,
                duration_secs,
                // Already Option: None leaves the driver's current value
                // untouched instead of forcing it to 0.
                gain,
                offset,
                bin_x,
                bin_y,
                subframe,
                frame_type.as_str(),
            )
            .await
            .map_err(|e| classify_exposure_failure(&device_id, e))?;

        // Everything from here to `store_captured_image_atomically` is pure CPU
        // over the whole frame — debayer, stretch, statistics and star
        // detection, which on a 24 MP sensor is seconds of work. Run it on a
        // blocking thread: on the async runtime it starves the event bridge,
        // the device heartbeats and the headless HTTP handlers for its whole
        // duration.
        let (display_result, raw_info) = tokio::task::spawn_blocking(move || {
        // Convert SeqImageData to ImageData for processing
        let image = ImageData::from_u16(seq_image.width, seq_image.height, 1, &seq_image.data);

        // DIAGNOSTIC: Log raw data statistics to debug mid-gray image issue
        {
            let raw_data = &seq_image.data;
            if !raw_data.is_empty() {
                let min_val = raw_data.iter().min().copied().unwrap_or(0);
                let max_val = raw_data.iter().max().copied().unwrap_or(0);
                let sum: u64 = raw_data.iter().map(|&v| v as u64).sum();
                let mean_val = sum / raw_data.len() as u64;
                let unique_vals: std::collections::HashSet<_> =
                    raw_data.iter().take(10000).collect();
                tracing::info!(
                    "[DIAGNOSTIC] Raw image data: size={}, min={}, max={}, mean={}, unique_sample_count={}",
                    raw_data.len(), min_val, max_val, mean_val, unique_vals.len()
                );
                if max_val == min_val {
                    tracing::error!("[DIAGNOSTIC] WARNING: All pixels have same value! Data appears uniform/invalid.");
                } else if max_val < 100 {
                    tracing::warn!("[DIAGNOSTIC] WARNING: Max value is very low ({}), image may be underexposed or data corrupted.", max_val);
                } else if min_val > 60000 {
                    tracing::warn!("[DIAGNOSTIC] WARNING: Min value is very high ({}), image may be saturated.", min_val);
                }
            } else {
                tracing::error!("[DIAGNOSTIC] WARNING: Raw data is empty!");
            }
        }

        // Automatic color detection from camera metadata
        let is_color =
            seq_image.sensor_type.as_deref() == Some("Color") && seq_image.bayer_offset.is_some();

        // Determine Bayer pattern from offsets (if color)
        let bayer_pattern = if is_color {
            match seq_image.bayer_offset {
                Some((0, 0)) => BayerPattern::RGGB, // RGGB
                Some((1, 0)) => BayerPattern::GRBG, // GRBG
                Some((0, 1)) => BayerPattern::GBRG, // GBRG
                Some((1, 1)) => BayerPattern::BGGR, // BGGR
                _ => BayerPattern::RGGB,            // Default
            }
        } else {
            BayerPattern::RGGB // Doesn't matter for mono
        };

        let display_data_raw: Vec<u8>;

        if is_color {
            // Color debayering path
            let algorithm = DebayerAlgorithm::Bilinear;

            tracing::info!("Debayering color image with pattern {:?}", bayer_pattern);

            // 2. Debayer to RGB16 (if color)
            // Safe conversion from u8 buffer to u16 values
            if image.data.len() % 2 != 0 {
                return Err(NightshadeError::ImageError(
                    "Odd byte count in image data — cannot convert to u16 pixels".to_string(),
                ));
            }
            let u16_data: Vec<u16> = image
                .data
                .as_chunks::<2>().0.iter()
                .map(|b| u16::from_ne_bytes([b[0], b[1]]))
                .collect();

            let mut rgb_data = nightshade_imaging::debayer_to_rgb16(
                &u16_data,
                seq_image.width,
                seq_image.height,
                bayer_pattern,
                algorithm,
            );

            // 2.5. Apply Auto White Balance (Histogram Peak Alignment)
            apply_auto_white_balance(&mut rgb_data);

            // 3. Auto-stretch RGB through the same MAD-based PixInsight STF the
            // mono path uses, so color captures get the noise-scaled curve too.
            //
            // Unlinked (PixInsight's default): per-channel independent STF
            // maximizes per-channel contrast. The Dart-side
            // `AutoStretchSettings.linkedChannels` flag re-links the channels
            // once auto-stretch is explicitly enabled (see
            // `auto_stretch_provider.dart`).
            //
            // Degenerate input: `auto_stretch_rgb_with_mode` returns
            // `StretchParams::default()` (shadows=0, highlights=1, midtones=0.5 —
            // the identity MTF) when a channel has MAD = 0 (constant data) or is
            // empty, and `apply_stretch_rgb_per_channel` then emits an identity
            // stretch for that channel rather than a black frame.
            let (r_params, g_params, b_params) = nightshade_imaging::auto_stretch_rgb_with_mode(
                &rgb_data,
                seq_image.width,
                seq_image.height,
                nightshade_imaging::RgbStretchMode::Unlinked,
            );

            tracing::info!(
                "[DIAGNOSTIC] RGB STF params (Unlinked): R(s={:.4}, h={:.4}, m={:.4}) \
                G(s={:.4}, h={:.4}, m={:.4}) B(s={:.4}, h={:.4}, m={:.4})",
                r_params.shadows,
                r_params.highlights,
                r_params.midtones,
                g_params.shadows,
                g_params.highlights,
                g_params.midtones,
                b_params.shadows,
                b_params.highlights,
                b_params.midtones,
            );

            // 4. Apply per-channel STF to convert RGB u16 -> RGB u8.
            display_data_raw = nightshade_imaging::apply_stretch_rgb_per_channel(
                &rgb_data,
                seq_image.width,
                seq_image.height,
                &r_params,
                &g_params,
                &b_params,
            );
        } else {
            // Grayscale: auto-stretch to u8
            let stretch_params = nightshade_imaging::auto_stretch_stf(&image);
            tracing::info!(
                "[DIAGNOSTIC] Stretch params: shadows={:.6}, highlights={:.6}, midtones={:.6}",
                stretch_params.shadows,
                stretch_params.highlights,
                stretch_params.midtones
            );
            display_data_raw = nightshade_imaging::apply_stretch(&image, &stretch_params);

            // Check display data distribution.
            //
            // Gated, because this is a whole-frame scan run purely to build one
            // log line.
            if tracing::enabled!(tracing::Level::DEBUG) {
                if let Some((display_min, display_max, display_mean)) =
                    display_data_summary(&display_data_raw)
                {
                    tracing::debug!(
                        "[DIAGNOSTIC] Display data after stretch: min={}, max={}, mean={}",
                        display_min,
                        display_max,
                        display_mean,
                    );
                }
            }
        }

        // Calculate statistics
        let stats = nightshade_imaging::calculate_stats_u16(&image);
        let stars = nightshade_imaging::detect_stars(
            &image,
            &nightshade_imaging::StarDetectionConfig::default(),
        );
        let frame_stats = frame_stats_result(&stats, &stars);
        tracing::info!(
            "Star detection: {} stars found, median HFR: {:?}, median ecc: {:?}",
            frame_stats.star_count,
            frame_stats.hfr,
            frame_stats.eccentricity
        );

        // Calculate histogram from pre-RGBA display data (256 bins for u8 pixel values)
        let mut histogram = vec![0u32; 256];
        for &pixel in &display_data_raw {
            histogram[pixel as usize] += 1;
        }

        // Convert to RGBA for Flutter rendering (parallel, fast in Rust)
        let display_data = display_data_to_rgba(&display_data_raw, is_color);

        // Store all image data atomically to prevent race conditions
        // This ensures the UI never sees inconsistent state between raw and display data
        let display_result = CapturedImageResult {
            width: seq_image.width,
            height: seq_image.height,
            display_data,
            histogram,
            stats: frame_stats,
            exposure_time: duration_secs,
            timestamp: chrono::Utc::now().format("%Y-%m-%dT%H:%M:%S").to_string(),
            is_color,
        };

        // `seq_image.data` is not read again, so the frame moves out instead of
        // being copied — one w*h*2-byte allocation and memcpy less per light
        // frame (48 MB on a 24 MP sensor).
        let raw_info = RawImageInfo {
            width: seq_image.width,
            height: seq_image.height,
            data: seq_image.data,
            sensor_type: seq_image.sensor_type,
            bayer_offset: seq_image.bayer_offset,
        };

            Ok::<_, NightshadeError>((display_result, raw_info))
        })
        .await
        .map_err(|e| {
            NightshadeError::OperationFailed(format!("Image analysis task failed: {}", e))
        })??;

        let star_count = display_result.stats.star_count;
        store_captured_image_atomically(&device_id, display_result, raw_info).await;

        // Note: ExposureComplete event is published by UnifiedDeviceOps
        tracing::info!(
            "Real camera exposure complete, {} stars detected",
            star_count
        );
        Ok(())
    }
}

/// Get the last captured image for a specific device (display-ready format)
/// Reads from per-device atomic storage to ensure consistency with raw data
pub async fn api_get_last_image(device_id: String) -> Result<CapturedImageResult, NightshadeError> {
    // Log at debug: dashboards/companions POLL this every few seconds for a
    // preview, so INFO-per-call was the single largest source of log volume, and
    // "no image yet" is a NORMAL pre-capture state that the typed
    // `NoImageAvailable` error already reports to the caller — a WARN for it
    // flooded the log with non-problems (130 in one session).
    tracing::debug!("API: api_get_last_image called for device: {}", device_id);
    let mut storage = get_unified_image_storage().lock().await;
    match storage.get(&device_id) {
        Some(data) => {
            tracing::debug!(
                "API: Returning stored image {}x{}, display_data size: {} bytes",
                data.display.width,
                data.display.height,
                data.display.display_data.len()
            );
            Ok(data.display.clone())
        }
        None => {
            tracing::debug!("API: No image available for device: {}", device_id);
            Err(NightshadeError::NoImageAvailable)
        }
    }
}

/// Get the last captured raw image data (u16) for a specific device
/// This is used for saving FITS files with original bit depth
/// Reads from per-device atomic storage to ensure consistency with display data
pub async fn api_get_last_raw_image_data(device_id: String) -> Result<Vec<u16>, NightshadeError> {
    let mut storage = get_unified_image_storage().lock().await;
    storage
        .get(&device_id)
        .map(|data| data.raw_info.data.clone())
        .ok_or(NightshadeError::NoImageAvailable)
}

/// Get the last captured raw image info with full metadata for a specific device
/// This is used by the sequencer for HFR calculation, plate solving, and other analysis
/// that requires original 16-bit sensor data (not display-stretched 8-bit data)
/// Reads from per-device atomic storage to ensure consistency with display data
#[flutter_rust_bridge::frb(ignore)]
pub async fn get_last_raw_image_info(
    device_id: &str,
) -> Result<Option<RawImageInfo>, NightshadeError> {
    let mut storage = get_unified_image_storage().lock().await;
    Ok(storage.get(device_id).map(|data| data.raw_info.clone()))
}

/// Clear stored image data for a specific device
/// This is used to free memory when a camera is disconnected or when explicitly requested
pub async fn api_clear_device_image(device_id: String) -> Result<(), NightshadeError> {
    tracing::info!("API: Clearing stored image for device: {}", device_id);
    let mut storage = get_unified_image_storage().lock().await;
    storage.pop(&device_id);
    Ok(())
}

/// Cancel current exposure
pub async fn api_camera_cancel_exposure(device_id: String) -> Result<(), NightshadeError> {
    if device_id.starts_with("sim_") {
        // Invalidating the acquisition is what actually stops the simulated
        // exposure: setting the state to Idle alone left the exposure future
        // sleeping to full duration, so a 30 s light aborted at 24 s still
        // "completed" 7 s later. The in-flight exposure sees the new generation
        // and takes `sim_exposure_cancelled`, which parks the sensor.
        crate::unified_device_ops::mark_camera_exposure_aborted(&device_id).await;
        tracing::info!("Exposure cancelled");
        Ok(())
    } else {
        // Route real devices through DeviceManager
        crate::unified_device_ops::mark_camera_exposure_aborted(&device_id).await;
        let mgr = get_device_manager();
        mgr.camera_abort_exposure(&device_id)
            .await
            .map_err(NightshadeError::from)
    }
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
        nightshade_imaging::PixelType::U8 => image_data
            .data
            .iter()
            .map(|&value| value as f64)
            .collect::<Vec<f64>>(),
        nightshade_imaging::PixelType::U16 => image_data
            .data
            .as_chunks::<2>()
            .0
            .iter()
            .map(|chunk| u16::from_le_bytes([chunk[0], chunk[1]]) as f64)
            .collect::<Vec<f64>>(),
        nightshade_imaging::PixelType::U32 => image_data
            .data
            .as_chunks::<4>()
            .0
            .iter()
            .map(|chunk| u32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]) as f64)
            .collect::<Vec<f64>>(),
        nightshade_imaging::PixelType::F32 => image_data
            .data
            .as_chunks::<4>()
            .0
            .iter()
            .map(|chunk| f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]) as f64)
            .collect::<Vec<f64>>(),
        nightshade_imaging::PixelType::F64 => image_data
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
pub async fn api_read_fits_file(file_path: String) -> Result<FitsReadResult, NightshadeError> {
    use std::path::Path;

    tracing::info!("Reading FITS file: {}", file_path);

    let path = Path::new(&file_path);
    if !path.exists() {
        return Err(NightshadeError::IoError(format!(
            "File not found: {}",
            file_path
        )));
    }

    // Read the actual FITS file
    let (image_data, header) = nightshade_imaging::read_fits(path)
        .map_err(|e| NightshadeError::ImageError(format!("Failed to read FITS: {}", e)))?;

    // Extract header keywords
    let object_name = header.get_string("OBJECT").map(|s| s.to_string());
    let exposure_time = header.get_float("EXPTIME");
    let filter = header.get_string("FILTER").map(|s| s.to_string());
    let ra = header.get_float("RA");
    let dec = header.get_float("DEC");
    let date_obs = header.get_string("DATE-OBS").map(|s| s.to_string());
    let bitpix = header.get_int("BITPIX").unwrap_or(16) as i32;
    let bayer_pattern = header.get_string("BAYERPAT").map(|s| s.to_string());

    // Calculate statistics
    let stats = nightshade_imaging::calculate_stats_u16(&image_data);

    // Auto stretch for display
    let stretch_params = nightshade_imaging::auto_stretch_stf(&image_data);
    let display_data_raw = nightshade_imaging::apply_stretch(&image_data, &stretch_params);

    // Calculate histogram from pre-RGBA data
    let mut histogram = vec![0u32; 256];
    for &pixel in &display_data_raw {
        histogram[pixel as usize] += 1;
    }

    // Convert grayscale to RGBA for Flutter rendering
    let display_data = display_data_to_rgba(&display_data_raw, false);

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
        display_data,
        histogram,
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

// FITS header keyword update (science writeback)

/// A single keyword to inject (or overwrite) on an existing FITS file.
///
/// Exactly one of `string_value`, `int_value`, `float_value` must be `Some`.
/// The remaining fields must be `None`. The Rust side validates this and
/// returns an `InvalidParameters` error rather than guessing — silent
/// fallbacks would let a caller bury a typo and have the keyword vanish.
#[derive(Debug, Clone)]
pub struct FitsKeywordUpdate {
    /// FITS keyword. Uppercased on insert. Must be 1..=8 ASCII chars per the
    /// FITS Standard (4.4.2.1); longer keys are rejected at write time.
    pub keyword: String,
    /// Optional inline comment ("/ comment" segment of the value card).
    pub comment: Option<String>,
    pub string_value: Option<String>,
    pub int_value: Option<i64>,
    pub float_value: Option<f64>,
}

/// Update (overwrite or inject) one or more keywords on an existing FITS file.
///
/// Implementation: reads the full file into memory, mutates the header in
/// place, writes the result to a sibling `<filename>.nshatmp` file, then
/// atomically renames it over the original. If any step fails the original
/// file is left untouched.
///
/// This is the writeback mechanism used by `ScienceProcessingService` to
/// stamp `MAGZP`, `MAGZPERR`, `TRANSPAR`, etc. back onto captured frames so
/// that PixInsight / AstroPixelProcessor / Siril can read Nightshade's
/// science products without going through our database.
pub async fn api_update_fits_keywords(
    file_path: String,
    updates: Vec<FitsKeywordUpdate>,
) -> Result<(), NightshadeError> {
    use std::path::Path;

    if updates.is_empty() {
        return Ok(());
    }

    // Validate every update first — fail fast before touching disk.
    for u in &updates {
        let provided = [
            u.string_value.is_some(),
            u.int_value.is_some(),
            u.float_value.is_some(),
        ]
        .iter()
        .filter(|x| **x)
        .count();
        if provided != 1 {
            return Err(NightshadeError::InvalidParameter(format!(
                "FITS keyword update for `{}` must set exactly one of \
                string_value/int_value/float_value (got {})",
                u.keyword, provided
            )));
        }
        if u.keyword.is_empty() || u.keyword.len() > 8 {
            return Err(NightshadeError::InvalidParameter(format!(
                "FITS keyword `{}` must be 1..=8 ASCII chars (FITS 4.4.2.1)",
                u.keyword
            )));
        }
        if !u
            .keyword
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
        {
            return Err(NightshadeError::InvalidParameter(format!(
                "FITS keyword `{}` contains illegal characters",
                u.keyword
            )));
        }
    }

    let path = Path::new(&file_path);
    if !path.exists() {
        return Err(NightshadeError::IoError(format!(
            "File not found: {}",
            file_path
        )));
    }

    let (image_data, mut header) = nightshade_imaging::read_fits(path)
        .map_err(|e| NightshadeError::ImageError(format!("Failed to read FITS: {}", e)))?;

    for u in &updates {
        let key = u.keyword.to_uppercase();
        if let Some(ref s) = u.string_value {
            header.set_string(&key, s);
        } else if let Some(i) = u.int_value {
            header.set_int(&key, i);
        } else if let Some(f) = u.float_value {
            header.set_float(&key, f);
        }
        if let Some(ref c) = u.comment {
            header.set_comment(&key, c);
        }
    }

    // Atomic write: temp sibling, then rename. Why: a half-written FITS file
    // is worse than no writeback at all — astronomers would lose the original
    // capture data. The rename is atomic on Windows and POSIX when source and
    // destination are on the same filesystem (which they are by construction).
    let tmp_path = {
        let mut p = path.to_path_buf();
        let mut ext = p.extension().map(|e| e.to_owned()).unwrap_or_default();
        ext.push(".nshatmp");
        p.set_extension(ext);
        p
    };
    nightshade_imaging::write_fits(&tmp_path, &image_data, &header)
        .map_err(|e| NightshadeError::ImageError(format!("Failed to write FITS: {}", e)))?;
    std::fs::rename(&tmp_path, path).map_err(|e| {
        // Best-effort cleanup if rename failed.
        let _ = std::fs::remove_file(&tmp_path);
        NightshadeError::IoError(format!("Failed to atomically replace FITS: {}", e))
    })?;

    tracing::info!(
        "Updated {} FITS keyword{} on {}",
        updates.len(),
        if updates.len() == 1 { "" } else { "s" },
        file_path
    );
    Ok(())
}

/// Read a FITS file and return unstretched linear pixel values for science analysis.
pub async fn api_read_fits_linear_data(
    file_path: String,
) -> Result<FitsLinearReadResult, NightshadeError> {
    use std::path::Path;

    tracing::info!("Reading FITS linear data: {}", file_path);

    let path = Path::new(&file_path);
    if !path.exists() {
        return Err(NightshadeError::IoError(format!(
            "File not found: {}",
            file_path
        )));
    }

    let (image_data, header) = nightshade_imaging::read_fits(path)
        .map_err(|e| NightshadeError::ImageError(format!("Failed to read FITS: {}", e)))?;

    let object_name = header.get_string("OBJECT").map(|s| s.to_string());
    let exposure_time = header.get_float("EXPTIME");
    let filter = header.get_string("FILTER").map(|s| s.to_string());
    let ra = header.get_float("RA");
    let dec = header.get_float("DEC");
    let date_obs = header.get_string("DATE-OBS").map(|s| s.to_string());
    let bitpix = header.get_int("BITPIX").unwrap_or(16) as i32;
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
) -> Result<QualityMapsResultApi, NightshadeError> {
    let started = Instant::now();
    let raw_info = get_last_raw_image_info(&device_id)
        .await?
        .ok_or(NightshadeError::NoImageAvailable)?;

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
) -> Result<QualityMapsResultApi, NightshadeError> {
    use std::path::Path;

    let started = Instant::now();
    let path = Path::new(&file_path);
    if !path.exists() {
        return Err(NightshadeError::IoError(format!(
            "File not found: {}",
            file_path
        )));
    }

    let (image_data, _header) = nightshade_imaging::read_fits(path)
        .map_err(|e| NightshadeError::ImageError(format!("Failed to read FITS: {}", e)))?;
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
) -> Result<StarDetectionResultApi, NightshadeError> {
    use std::path::Path;

    tracing::info!("Detecting stars in: {}", file_path);

    let path = Path::new(&file_path);
    let (image_data, _header) = nightshade_imaging::read_fits(path)
        .map_err(|e| NightshadeError::ImageError(format!("Failed to read FITS: {}", e)))?;

    let config = config.unwrap_or_default();
    let detection_config = nightshade_imaging::StarDetectionConfig {
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

    let result = nightshade_imaging::detect_stars_with_stats(&image_data, &detection_config);

    let stars: Vec<DetectedStarInfo> = result
        .stars
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
        stars,
        star_count: result.star_count,
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
) -> Result<Vec<StarCropApi>, NightshadeError> {
    use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};

    tracing::info!(
        "API: api_get_star_crops_from_last_image for device: {}, max_crops: {}",
        device_id,
        max_crops
    );

    // Get the last raw image for this device
    let mut storage = get_unified_image_storage().lock().await;
    let image_data = storage
        .get(&device_id)
        .ok_or(NightshadeError::NoImageAvailable)?;

    // Convert to imaging format
    let img = nightshade_imaging::ImageData::from_u16(
        image_data.raw_info.width,
        image_data.raw_info.height,
        1,
        &image_data.raw_info.data,
    );

    // Detect stars
    let config = nightshade_imaging::StarDetectionConfig::default();
    let stars = nightshade_imaging::detect_stars(&img, &config);

    if stars.is_empty() {
        tracing::info!("No stars detected for star crop extraction");
        return Ok(vec![]);
    }

    // Extract top star crops (80x80 pixels each)
    let crops = nightshade_imaging::extract_top_star_crops(&img, &stars, max_crops as usize, 80);

    // Convert to API format
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

/// Calculate HFR for a FITS file
pub async fn api_calculate_hfr(file_path: String) -> Result<Option<f64>, NightshadeError> {
    use std::path::Path;

    let path = Path::new(&file_path);
    let (image_data, _header) = nightshade_imaging::read_fits(path)
        .map_err(|e| NightshadeError::ImageError(format!("Failed to read FITS: {}", e)))?;

    Ok(nightshade_imaging::calculate_median_hfr(&image_data))
}

/// Calculate histogram for a FITS file
pub async fn api_calculate_histogram(
    file_path: String,
    _bins: u32,
    logarithmic: u8,
) -> Result<Vec<f32>, NightshadeError> {
    use std::path::Path;

    let path = Path::new(&file_path);
    let (image_data, _header) = nightshade_imaging::read_fits(path)
        .map_err(|e| NightshadeError::ImageError(format!("Failed to read FITS: {}", e)))?;

    let logarithmic_bool = logarithmic != 0;
    let histogram = nightshade_imaging::calculate_display_histogram(&image_data, logarithmic_bool);
    Ok(histogram)
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
) -> Result<StretchParamsApi, NightshadeError> {
    use std::path::Path;

    let path = Path::new(&file_path);
    let (image_data, _header) = nightshade_imaging::read_fits(path)
        .map_err(|e| NightshadeError::ImageError(format!("Failed to read FITS: {}", e)))?;

    let params = nightshade_imaging::auto_stretch_stf(&image_data);

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
) -> Result<Vec<u8>, NightshadeError> {
    use std::path::Path;

    let path = Path::new(&file_path);
    let (image_data, _header) = nightshade_imaging::read_fits(path)
        .map_err(|e| NightshadeError::ImageError(format!("Failed to read FITS: {}", e)))?;

    let stretch_params = nightshade_imaging::StretchParams {
        shadows: params.shadows,
        highlights: params.highlights,
        midtones: params.midtones,
    };

    let display_data_raw = nightshade_imaging::apply_stretch(&image_data, &stretch_params);
    // Convert grayscale to RGBA for Flutter rendering
    Ok(display_data_to_rgba(&display_data_raw, false))
}

// Debayering (color cameras)

/// Bayer pattern type
#[derive(Debug, Clone, Copy)]
pub enum BayerPatternApi {
    RGGB,
    BGGR,
    GRBG,
    GBRG,
}

/// Debayer algorithm
#[derive(Debug, Clone, Copy)]
pub enum DebayerAlgorithmApi {
    Bilinear,
    VNG,
    SuperPixel,
}

/// Debayer a raw FITS image and return RGB display data
/// Debayer a raw FITS file and return RGB display data
pub async fn api_debayer_fits_file(
    file_path: String,
    pattern: BayerPatternApi,
    algorithm: DebayerAlgorithmApi,
) -> Result<Vec<u8>, NightshadeError> {
    use std::path::Path;

    let path = Path::new(&file_path);
    let (image_data, _header) = nightshade_imaging::read_fits(path)
        .map_err(|e| NightshadeError::ImageError(format!("Failed to read FITS: {}", e)))?;

    let bayer_pattern = match pattern {
        BayerPatternApi::RGGB => nightshade_imaging::BayerPattern::RGGB,
        BayerPatternApi::BGGR => nightshade_imaging::BayerPattern::BGGR,
        BayerPatternApi::GRBG => nightshade_imaging::BayerPattern::GRBG,
        BayerPatternApi::GBRG => nightshade_imaging::BayerPattern::GBRG,
    };

    let debayer_alg = match algorithm {
        DebayerAlgorithmApi::Bilinear => nightshade_imaging::DebayerAlgorithm::Bilinear,
        DebayerAlgorithmApi::VNG => nightshade_imaging::DebayerAlgorithm::VNG,
        DebayerAlgorithmApi::SuperPixel => nightshade_imaging::DebayerAlgorithm::SuperPixel,
    };

    let rgb_image = nightshade_imaging::debayer(
        &image_data.data,
        image_data.width,
        image_data.height,
        bayer_pattern,
        debayer_alg,
    );

    // Return RGBA8 for Flutter display
    Ok(rgb_image.to_rgba8())
}

// XISF file support

/// XISF file read result
#[derive(Debug, Clone)]
pub struct XisfReadResult {
    pub width: u32,
    pub height: u32,
    pub channels: u32,
    pub display_data: Vec<u8>, // Always RGBA (width*height*4), alpha=255
    pub histogram: Vec<u32>,
    pub stats: ImageStatsResult,
    pub properties: Vec<(String, String)>,
}

/// Read an XISF file
pub async fn api_read_xisf_file(file_path: String) -> Result<XisfReadResult, NightshadeError> {
    use std::path::Path;

    tracing::info!("Reading XISF file: {}", file_path);

    let path = Path::new(&file_path);
    if !path.exists() {
        return Err(NightshadeError::IoError(format!(
            "File not found: {}",
            file_path
        )));
    }

    let (image_data, metadata) = nightshade_imaging::read_xisf(path)
        .map_err(|e| NightshadeError::ImageError(format!("Failed to read XISF: {}", e)))?;

    // Calculate statistics
    let stats = nightshade_imaging::calculate_stats_u16(&image_data);

    // Auto stretch for display
    let stretch_params = nightshade_imaging::auto_stretch_stf(&image_data);
    let display_data_raw = nightshade_imaging::apply_stretch(&image_data, &stretch_params);

    // Calculate histogram from pre-RGBA data
    let mut histogram = vec![0u32; 256];
    for &pixel in &display_data_raw {
        histogram[pixel as usize] += 1;
    }

    // Convert grayscale to RGBA for Flutter rendering
    let display_data = display_data_to_rgba(&display_data_raw, false);

    // Convert properties to strings
    let properties: Vec<(String, String)> = metadata
        .properties
        .iter()
        .map(|(k, v)| (k.clone(), format!("{:?}", v)))
        .chain(
            metadata
                .fits_keywords
                .iter()
                .map(|(k, v)| (k.clone(), v.clone())),
        )
        .collect();

    tracing::info!(
        "XISF file loaded: {}x{}x{}",
        image_data.width,
        image_data.height,
        image_data.channels
    );

    Ok(XisfReadResult {
        width: image_data.width,
        height: image_data.height,
        channels: image_data.channels,
        display_data,
        histogram,
        stats: ImageStatsResult {
            min: stats.min,
            max: stats.max,
            mean: stats.mean,
            median: stats.median,
            std_dev: stats.std_dev,
            // XISF load runs no star detection: honest None for both.
            hfr: None,
            eccentricity: None,
            fwhm: None,
            star_count: 0,
        },
        properties,
    })
}

/// Save image as XISF
pub async fn api_save_xisf_file(
    file_path: String,
    width: u32,
    height: u32,
    data: Vec<u16>,
    properties: Vec<(String, String)>,
) -> Result<(), NightshadeError> {
    use std::path::Path;

    tracing::info!("Saving XISF file: {}", file_path);

    let image_data = nightshade_imaging::ImageData::from_u16(width, height, 1, &data);

    let mut metadata = nightshade_imaging::XisfMetadata::default();
    for (key, value) in properties {
        metadata.fits_keywords.insert(key, value);
    }

    let path = Path::new(&file_path);
    nightshade_imaging::write_xisf(path, &image_data, &metadata)
        .map_err(|e| NightshadeError::ImageError(format!("Failed to write XISF: {}", e)))?;

    tracing::info!("XISF file saved: {}", file_path);
    Ok(())
}

/// Save image as TIFF (16-bit preserving)
pub async fn api_save_tiff_file(
    file_path: String,
    width: u32,
    height: u32,
    data: Vec<u16>,
) -> Result<(), NightshadeError> {
    use std::path::Path;

    tracing::info!("Saving TIFF file: {}", file_path);

    let image_data = nightshade_imaging::ImageData::from_u16(width, height, 1, &data);

    let path = Path::new(&file_path);
    nightshade_imaging::write_tiff(path, &image_data)
        .map_err(|e| NightshadeError::ImageError(format!("Failed to write TIFF: {}", e)))?;

    tracing::info!("TIFF file saved: {}", file_path);
    Ok(())
}

/// Save image as PNG (16-bit preserving, lossless)
pub async fn api_save_png_file(
    file_path: String,
    width: u32,
    height: u32,
    data: Vec<u16>,
) -> Result<(), NightshadeError> {
    use std::path::Path;

    tracing::info!("Saving PNG file: {}", file_path);

    let image_data = nightshade_imaging::ImageData::from_u16(width, height, 1, &data);

    let path = Path::new(&file_path);
    nightshade_imaging::write_png(path, &image_data)
        .map_err(|e| NightshadeError::ImageError(format!("Failed to write PNG: {}", e)))?;

    tracing::info!("PNG file saved: {}", file_path);
    Ok(())
}

/// Save image as JPEG (8-bit, lossy - for previews)
pub async fn api_save_jpeg_file(
    file_path: String,
    width: u32,
    height: u32,
    data: Vec<u16>,
    quality: u8,
) -> Result<(), NightshadeError> {
    use std::path::Path;

    tracing::info!("Saving JPEG file: {} (quality: {})", file_path, quality);

    let image_data = nightshade_imaging::ImageData::from_u16(width, height, 1, &data);

    let path = Path::new(&file_path);
    nightshade_imaging::write_jpeg(path, &image_data, quality)
        .map_err(|e| NightshadeError::ImageError(format!("Failed to write JPEG: {}", e)))?;

    tracing::info!("JPEG file saved: {}", file_path);
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
/// as [`NightshadeError::ImageError`] rather than silently truncating or
/// padding, which would write a corrupt/garbage image that looks plausible.
pub async fn api_save_rgba_png_file(
    file_path: String,
    width: u32,
    height: u32,
    rgba: Vec<u8>,
) -> Result<(), NightshadeError> {
    use image::RgbaImage;
    use std::path::Path;

    tracing::info!("Saving RGBA PNG file: {} ({}x{})", file_path, width, height);

    let expected = (width as usize)
        .checked_mul(height as usize)
        .and_then(|px| px.checked_mul(4))
        .ok_or_else(|| {
            NightshadeError::ImageError(format!(
                "RGBA PNG dimensions overflow: {}x{}",
                width, height
            ))
        })?;
    if rgba.len() != expected {
        return Err(NightshadeError::ImageError(format!(
            "RGBA PNG buffer length mismatch: got {} bytes, expected {} for {}x{}x4",
            rgba.len(),
            expected,
            width,
            height
        )));
    }

    let image: RgbaImage = RgbaImage::from_raw(width, height, rgba).ok_or_else(|| {
        NightshadeError::ImageError(format!(
            "Failed to build {}x{} RGBA image buffer",
            width, height
        ))
    })?;

    let path = Path::new(&file_path);
    image
        .save(path)
        .map_err(|e| NightshadeError::ImageError(format!("Failed to write RGBA PNG: {}", e)))?;

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
/// upstream bug and is surfaced as [`NightshadeError::ImageError`].
pub async fn api_save_rgba_jpeg_file(
    file_path: String,
    width: u32,
    height: u32,
    rgba: Vec<u8>,
    quality: u8,
) -> Result<(), NightshadeError> {
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
            NightshadeError::ImageError(format!(
                "RGBA JPEG dimensions overflow: {}x{}",
                width, height
            ))
        })?;
    if rgba.len() != expected {
        return Err(NightshadeError::ImageError(format!(
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
        NightshadeError::ImageError(format!(
            "Failed to build {}x{} RGB image buffer",
            width, height
        ))
    })?;

    let path = Path::new(&file_path);
    let file = File::create(path)
        .map_err(|e| NightshadeError::ImageError(format!("Failed to create JPEG file: {}", e)))?;
    let writer = BufWriter::new(file);
    let encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(writer, quality);
    encoder
        .write_image(rgb_image.as_raw(), width, height, image::ColorType::Rgb8)
        .map_err(|e| NightshadeError::ImageError(format!("Failed to encode RGBA JPEG: {}", e)))?;

    tracing::info!("RGBA JPEG file saved: {}", file_path);
    Ok(())
}

#[cfg(test)]
mod rgba_save_tests;

// File naming patterns

/// Frame type for file naming
#[derive(Debug, Clone, Copy)]
pub enum FrameTypeApi {
    Light,
    Dark,
    Flat,
    Bias,
    DarkFlat,
    Snapshot,
}

/// Generate a filename from pattern and context
pub async fn api_generate_filename(
    pattern: String,
    base_dir: String,
    target: Option<String>,
    filter: Option<String>,
    exposure_time: f64,
    frame_type: FrameTypeApi,
    frame_number: u32,
    gain: Option<i32>,
    offset: Option<i32>,
    temperature: Option<f64>,
    binning_x: u32,
    binning_y: u32,
    camera: Option<String>,
    telescope: Option<String>,
    extension: String,
) -> String {
    let frame_type_impl = match frame_type {
        FrameTypeApi::Light => nightshade_imaging::FrameType::Light,
        FrameTypeApi::Dark => nightshade_imaging::FrameType::Dark,
        FrameTypeApi::Flat => nightshade_imaging::FrameType::Flat,
        FrameTypeApi::Bias => nightshade_imaging::FrameType::Bias,
        FrameTypeApi::DarkFlat => nightshade_imaging::FrameType::DarkFlat,
        FrameTypeApi::Snapshot => nightshade_imaging::FrameType::Snapshot,
    };

    let mut context = nightshade_imaging::NamingContext::new()
        .with_current_time()
        .with_exposure(exposure_time)
        .with_frame_type(frame_type_impl)
        .with_frame_number(frame_number)
        .with_binning(binning_x, binning_y);

    if let Some(t) = target {
        context = context.with_target(t);
    }
    if let Some(f) = filter {
        context = context.with_filter(f);
    }
    if let Some(g) = gain {
        context = context.with_gain(g);
    }
    if let Some(o) = offset {
        context = context.with_offset(o);
    }
    if let Some(t) = temperature {
        context = context.with_temperature(t);
    }
    if let Some(c) = camera {
        context = context.with_camera(c);
    }
    if let Some(t) = telescope {
        context = context.with_telescope(t);
    }

    let naming_pattern = nightshade_imaging::NamingPattern::new(pattern)
        .with_base_dir(base_dir)
        .with_extension(extension);

    naming_pattern
        .generate(&context)
        .to_string_lossy()
        .to_string()
}

/// Get the next frame number for a directory
pub async fn api_get_next_frame_number(
    base_dir: String,
    pattern: String,
    target: Option<String>,
    filter: Option<String>,
    frame_type: FrameTypeApi,
) -> u32 {
    use std::path::Path;

    let frame_type_impl = match frame_type {
        FrameTypeApi::Light => nightshade_imaging::FrameType::Light,
        FrameTypeApi::Dark => nightshade_imaging::FrameType::Dark,
        FrameTypeApi::Flat => nightshade_imaging::FrameType::Flat,
        FrameTypeApi::Bias => nightshade_imaging::FrameType::Bias,
        FrameTypeApi::DarkFlat => nightshade_imaging::FrameType::DarkFlat,
        FrameTypeApi::Snapshot => nightshade_imaging::FrameType::Snapshot,
    };

    let mut context = nightshade_imaging::NamingContext::new().with_frame_type(frame_type_impl);

    if let Some(t) = target {
        context = context.with_target(t);
    }
    if let Some(f) = filter {
        context = context.with_filter(f);
    }

    let naming_pattern = nightshade_imaging::NamingPattern::new(pattern);
    let base_path = Path::new(&base_dir);

    nightshade_imaging::scan_for_next_frame_number(base_path, &naming_pattern, &context)
}

// FITS file saving

/// Header data for FITS file writing.
///
/// Public FRB-exposed surface. Kept frozen at the original 22 fields so
/// Dart consumers (Dart-driven snapshot saves, network-backend FITS writes)
/// don't need a coordinated FRB regen.
///
/// Image Grading: the sequencer's per-frame save path uses
/// [`FitsWriteHeaderRich`] instead, which carries every extended keyword
/// (focuser position, rotator angle, guide RMS, plate-solve, mosaic
/// panel, etc.). The rich path is internal — not exposed via FRB — so
/// sequencer-driven saves can grow the FITS surface without disrupting
/// Dart-side FRB schema.
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

/// Image Grading: internal FITS-header bundle used by the
/// sequencer's per-frame save path. Carries every field the standard
/// astrophotography FITS header expects PLUS the Nightshade-specific
/// session / mosaic / plate-solve keywords.
///
/// Not FRB-exposed: only Rust code (the sequencer's `save_fits` impl in
/// `real_device_ops.rs` / `unified_device_ops.rs` / `sequencer_ops.rs`)
/// constructs this. Dart callers continue to use the simpler
/// [`FitsWriteHeader`] for ad-hoc snapshot saves.
#[derive(Debug, Clone, Default)]
pub struct FitsWriteHeaderRich {
    pub object_name: Option<String>,
    pub exposure_time: f64,
    pub capture_timestamp: String,
    pub frame_type: String,
    pub filter: Option<String>,
    /// 1-based filter wheel position (FITS `FILTPOS`).
    pub filter_position: Option<i32>,
    pub gain: Option<i32>,
    pub offset: Option<i32>,
    pub ccd_temp: Option<f64>,
    /// Cooler target temperature in °C (FITS `SET-TEMP`).
    pub set_temp: Option<f64>,
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
    // Image grading additions — populated from FrameContext.
    /// Focuser absolute position (FITS `FOCUSPOS`).
    pub focuser_position: Option<i32>,
    /// Focuser temperature in °C (FITS `FOCTEMP`).
    pub focuser_temperature: Option<f64>,
    /// Rotator mechanical angle in degrees (FITS `ROTATPOS`).
    pub rotator_angle: Option<f64>,
    /// Total guiding RMS in arcseconds (FITS `GUIDERMS`).
    pub guide_rms_arcsec: Option<f64>,
    /// Plate-solved RA in hours (FITS `SOLVED-RA`).
    pub solved_ra_hours: Option<f64>,
    /// Plate-solved Dec in degrees (FITS `SOLVED-DEC`).
    pub solved_dec_degrees: Option<f64>,
    /// Solved pixel scale in arcsec/pixel (FITS `PIXSCALE`).
    pub plate_solve_pixel_scale_arcsec: Option<f64>,
    /// Solved field rotation in degrees (FITS `CROTA1` and `CROTA2`).
    pub plate_solve_rotation_deg: Option<f64>,
    /// Bayer pattern ("RGGB", "BGGR", etc.) (FITS `BAYERPAT`).
    pub bayer_pattern: Option<String>,
    /// Nightshade session identifier (FITS `NS-SESID`).
    pub session_id: Option<String>,
    /// 1-based frame index within the burst (FITS `NS-FIDX`).
    pub frame_index: Option<u32>,
    /// Total planned frames in the burst (FITS `NS-NPLN`).
    pub total_planned_frames: Option<u32>,
    /// Mosaic identification (FITS `NS-MOSNM`).
    pub mosaic_name: Option<String>,
    /// 0-based mosaic panel index (FITS `NS-PIDX`).
    pub mosaic_panel_index: Option<i32>,
    /// Mosaic panel row (FITS `NS-PROW`).
    pub mosaic_panel_row: Option<i32>,
    /// Mosaic panel column (FITS `NS-PCOL`).
    pub mosaic_panel_column: Option<i32>,
    /// Mosaic total panel count (FITS `NS-NPAN`).
    pub mosaic_total_panels: Option<i32>,
    // per-frame defect-map correction provenance.
    // Emitted as a FITS HISTORY card so the calibration trace is visible
    // in any FITS viewer (PixInsight, APP, NINA's image viewer, ds9).
    // `None` => no correction was applied (no map configured, or skipped
    // due to camera/sensor mismatch).
    pub defect_map_correction: Option<nightshade_sequencer::scheduling::DefectMapCorrectionRecord>,
    // Science — photometric FITS keywords.
    //
    //   * OBJCAT   - target catalogue designation
    //   * REFSTARS - comma-separated reference star catalogue IDs
    //   * MJD-OBS  - Modified Julian Date at exposure midpoint
    //   * INSTRMAG - instrumental magnitude (live-reduced)
    //   * DIFFMAG  - differential magnitude (against references)
    //   * FWHM     - measured FWHM in arcseconds
    //   * SNR      - measured target SNR
    //
    // All fields are Option<_> so non-photometry captures omit the
    // keywords entirely.
    pub photometry_object_catalog: Option<String>,
    pub photometry_reference_stars: Option<String>,
    pub photometry_mjd_obs: Option<f64>,
    pub photometry_instrumental_mag: Option<f64>,
    pub photometry_differential_mag: Option<f64>,
    pub photometry_fwhm_arcsec: Option<f64>,
    pub photometry_snr: Option<f64>,
    /// Dual-rig — optical-train / camera attribution for multi-camera
    /// sessions (FITS `NS-RIG`). `None` for the single-rig case.
    pub rig_label: Option<String>,
}

impl From<FitsWriteHeader> for FitsWriteHeaderRich {
    fn from(h: FitsWriteHeader) -> Self {
        Self {
            object_name: h.object_name,
            exposure_time: h.exposure_time,
            capture_timestamp: h.capture_timestamp,
            frame_type: h.frame_type,
            filter: h.filter,
            filter_position: None,
            gain: h.gain,
            offset: h.offset,
            ccd_temp: h.ccd_temp,
            set_temp: None,
            ra: h.ra,
            dec: h.dec,
            altitude: h.altitude,
            telescope: h.telescope,
            instrument: h.instrument,
            observer: h.observer,
            bin_x: h.bin_x,
            bin_y: h.bin_y,
            focal_length: h.focal_length,
            aperture: h.aperture,
            pixel_size_x: h.pixel_size_x,
            pixel_size_y: h.pixel_size_y,
            site_latitude: h.site_latitude,
            site_longitude: h.site_longitude,
            site_elevation: h.site_elevation,
            ..Default::default()
        }
    }
}

impl FitsWriteHeaderRich {
    /// Build from a sequencer `FrameContext`. Pure data shuffling — no
    /// I/O, used by the sequencer-driven save paths in the bridge.
    ///
    /// FRB regen: this helper is consumed only by Rust callers
    /// (sequencer-driven `save_fits`). FRB picks up `&FrameContext` in the
    /// signature and tries to expose `FrameContext` as a Dart opaque type,
    /// which fails because `nightshade_sequencer::scheduling::FrameContext`
    /// isn't imported in `frb_generated.rs`. Tagging the helper with
    /// `frb(ignore)` keeps it Rust-only and unblocks the generator.
    #[flutter_rust_bridge::frb(ignore)]
    pub fn from_frame_context(ctx: &nightshade_sequencer::scheduling::FrameContext) -> Self {
        let instrument = match (ctx.camera_make.as_deref(), ctx.camera_model.as_deref()) {
            (Some(make), Some(model)) => Some(format!("{} {}", make, model)),
            (Some(s), None) | (None, Some(s)) => Some(s.to_string()),
            (None, None) => None,
        };

        // Where the telescope WAS, falling back to where the sequence meant to
        // be — the same preference `build_rich_header` applies for the
        // sequencer's own save path, applied here so the two other
        // `DeviceOps::save_fits` impls (real_device_ops, unified_device_ops),
        // which build the header from the context and nothing else, agree with
        // it. Taken as a PAIR rather than field by field: half a mount
        // pointing and half a target's is a coordinate that was never true of
        // anything, and the altitude below is derived from the same pair.
        let (ra, dec) = match ctx.recorded_pointing() {
            Some((ra_hours, dec_degrees)) => (Some(ra_hours), Some(dec_degrees)),
            None => (None, None),
        };

        Self {
            object_name: ctx.target_name.clone(),
            exposure_time: ctx.duration_secs,
            // DATE-OBS is the START of the observation. This was `Utc::now()`,
            // sampled here while building the header -- which runs after
            // readout -- so every sequenced frame's DATE-OBS was late by
            // exactly its own EXPTIME. Fall back to now() only when the
            // capture path genuinely did not record a start, which is still
            // wrong but no worse than before and never silently absent.
            capture_timestamp: ctx
                .exposure_started_at
                .unwrap_or_else(chrono::Utc::now)
                .format("%Y-%m-%dT%H:%M:%S")
                .to_string(),
            frame_type: ctx.frame_type.clone(),
            filter: ctx.filter_name.clone(),
            filter_position: ctx.filter_index,
            gain: ctx.gain,
            offset: ctx.offset,
            ccd_temp: ctx.sensor_temp_c,
            set_temp: ctx.set_temp_c,
            ra,
            dec,
            // The altitude of the pointing selected just above — the mount's
            // when it was read, otherwise the target's, computed from the site
            // and the exposure midpoint. `recorded_altitude_deg` keeps OBJCTALT
            // and AIRMASS describing the same direction as the RA/DEC cards by
            // construction, including on a rig imaging without a mount attached.
            altitude: ctx.recorded_altitude_deg(),
            telescope: ctx.telescope_name.clone(),
            instrument,
            observer: ctx.observer_name.clone(),
            bin_x: ctx.binning_x as i32,
            bin_y: ctx.binning_y as i32,
            focal_length: ctx.telescope_focal_length_mm,
            aperture: ctx.telescope_aperture_mm,
            // The unbinned pitch the camera reported for this frame. This was
            // hardcoded `None`, so every sequenced sub carried FOCALLEN and
            // APTDIA but no XPIXSZ/YPIXSZ and ASTAP, PixInsight and AstroBin
            // could not derive its plate scale from the file alone — the
            // manual-snapshot path had already been fixed to write them, which
            // left two frames of the same rig disagreeing about the sensor.
            // The writer below multiplies by XBINNING/YBINNING, which is why
            // the context carries the unbinned value.
            pixel_size_x: ctx.camera_pixel_size_x_um,
            pixel_size_y: ctx.camera_pixel_size_y_um,
            site_latitude: ctx.site_latitude_deg,
            site_longitude: ctx.site_longitude_deg,
            site_elevation: ctx.site_elevation_m,
            focuser_position: ctx.focuser_position,
            focuser_temperature: ctx.focuser_temperature_c,
            rotator_angle: ctx.rotator_angle_deg,
            guide_rms_arcsec: ctx.guide_rms_arcsec,
            solved_ra_hours: ctx.plate_solve_ra_hours,
            solved_dec_degrees: ctx.plate_solve_dec_degrees,
            plate_solve_pixel_scale_arcsec: ctx.plate_solve_pixel_scale_arcsec,
            plate_solve_rotation_deg: ctx.plate_solve_rotation_deg,
            bayer_pattern: ctx.bayer_pattern.clone(),
            session_id: Some(ctx.session_id.clone()).filter(|s| !s.is_empty()),
            frame_index: Some(ctx.frame_index),
            total_planned_frames: ctx.total_planned_frames,
            mosaic_name: ctx.mosaic_panel.as_ref().map(|p| p.mosaic_name.clone()),
            mosaic_panel_index: ctx.mosaic_panel.as_ref().map(|p| p.panel_index),
            mosaic_panel_row: ctx.mosaic_panel.as_ref().map(|p| p.row),
            mosaic_panel_column: ctx.mosaic_panel.as_ref().map(|p| p.column),
            mosaic_total_panels: ctx.mosaic_panel.as_ref().map(|p| p.total_panels),
            defect_map_correction: ctx.defect_map_correction.clone(),
            // Science — photometric metadata. The
            // SciencePhotometryInstruction stamps these onto the
            // FrameContext just before the FITS save call.
            photometry_object_catalog: ctx.photometry_object_catalog.clone(),
            photometry_reference_stars: ctx
                .photometry_reference_stars
                .as_ref()
                .map(|refs| refs.join(",")),
            photometry_mjd_obs: ctx.photometry_mjd_obs,
            photometry_instrumental_mag: ctx.photometry_instrumental_mag,
            photometry_differential_mag: ctx.photometry_differential_mag,
            photometry_fwhm_arcsec: ctx.photometry_fwhm_arcsec,
            photometry_snr: ctx.photometry_snr,
            // Dual-rig — carry the rig attribution into the FITS header.
            rig_label: ctx.rig_label.clone(),
        }
    }
}

/// Format a signed sexagesimal angle as `±DD MM SS.SS`, the space-separated
/// form MaxIm DL / N.I.N.A. write for `OBJCTRA` / `OBJCTDEC`.
#[flutter_rust_bridge::frb(ignore)]
fn format_sexagesimal(value: f64, signed: bool) -> String {
    let negative = value < 0.0;
    let mut total_seconds = value.abs() * 3600.0;
    // Round to 1/100 s first so a value like 7.9999999 h renders as 08 00 00.00
    // instead of 07 59 60.00.
    total_seconds = (total_seconds * 100.0).round() / 100.0;
    let units = (total_seconds / 3600.0).floor();
    let minutes = ((total_seconds - units * 3600.0) / 60.0).floor();
    let seconds = total_seconds - units * 3600.0 - minutes * 60.0;
    let sign = if signed {
        if negative {
            "-"
        } else {
            "+"
        }
    } else if negative {
        "-"
    } else {
        ""
    };
    format!(
        "{}{:02} {:02} {:05.2}",
        sign, units as i64, minutes as i64, seconds
    )
}

/// Write the pointing keywords for a frame.
///
/// Nightshade carries RA in **hours** everywhere internally (the ASCOM
/// `RightAscension` convention) while Dec is in degrees. The numeric FITS
/// `RA` card, however, is degrees by universal convention — PixInsight,
/// Siril, ASTAP, AstroImageJ and astrometry.net all read it that way — so
/// passing the hour value straight through mis-located every frame by 15x
/// in RA. Convert here, at the one boundary where the unit changes, and
/// also emit the unambiguous sexagesimal `OBJCTRA`/`OBJCTDEC` pair that
/// MaxIm DL and N.I.N.A. write.
#[flutter_rust_bridge::frb(ignore)]
fn set_pointing_keywords(header: &mut FitsHeader, ra_hours: Option<f64>, dec_degrees: Option<f64>) {
    if let Some(ra) = ra_hours {
        if ra.is_finite() {
            header.set_float("RA", ra * 15.0);
            header.set_string("OBJCTRA", &format_sexagesimal(ra, false));
        }
    }
    if let Some(dec) = dec_degrees {
        if dec.is_finite() {
            header.set_float("DEC", dec);
            header.set_string("OBJCTDEC", &format_sexagesimal(dec, true));
        }
    }
}

/// Write the `OBJCTALT` altitude card and the `AIRMASS` derived from it,
/// omitting either when it cannot be stated truthfully.
///
/// The two are gated differently because they are different kinds of number.
/// `OBJCTALT` is the measurement: a parked mount really is at −9.9°, and that
/// is a fact about the frame worth recording. `AIRMASS` is an atmosphere model
/// evaluated at that altitude, and it is undefined below the horizon.
///
/// Recording the altitude and not only the airmass is what makes a frame
/// re-reducible. Airmass is lossy in the direction that matters: the published
/// formulae disagree by ~20% at the horizon (Pickering 38.7 vs Young 31.7 at
/// h=0°), so a photometry pipeline that wants to apply its own extinction
/// model cannot recover the altitude the writer started from. Every mainstream
/// capture app records it for that reason — N.I.N.A. and SGP as `OBJCTALT`,
/// MaxIm DL as `CENTALT` — so a Nightshade file without it is one a
/// photometry workflow can tell apart from every other app's.
///
/// AIRMASS itself is a convenience keyword — every stacker works without it —
/// but [`calculate_airmass`] deliberately refuses sub-horizon altitudes, and
/// darks and flats are by definition taken parked or capped (Alt < 0).
/// Propagating that refusal with `?` aborts the entire FITS write and destroys
/// the frame: the thumbnail lands on disk and the science data does not. Losing
/// an optional keyword is always better than losing the exposure, so warn and
/// skip the card instead.
#[flutter_rust_bridge::frb(ignore)]
fn set_horizon_keywords(header: &mut FitsHeader, altitude_degrees: Option<f64>) {
    let Some(altitude) = altitude_degrees else {
        return;
    };
    // A non-finite altitude is a broken read, not a pointing, so neither card
    // is written — same rule `set_pointing_keywords` applies to RA/DEC.
    if !altitude.is_finite() {
        return;
    }
    header.set_float("OBJCTALT", altitude);
    match calculate_airmass(altitude) {
        Ok(airmass) => header.set_float("AIRMASS", airmass),
        Err(e) => tracing::warn!(
            "Omitting AIRMASS from FITS header: cannot compute for altitude {}°: {}. \
             The frame itself, and its OBJCTALT card, are unaffected.",
            altitude,
            e
        ),
    }
}

/// Save image data to FITS file
pub async fn api_save_fits_file(
    file_path: String,
    width: u32,
    height: u32,
    data: Vec<u16>,
    header_data: FitsWriteHeader,
) -> Result<(), NightshadeError> {
    tracing::info!("Saving FITS file to: {}", file_path);

    // Create ImageData
    let image = ImageData::from_u16(width, height, 1, &data);

    // Validate image data
    let validation = validate_image(&image, Some(width), Some(height));
    if !validation.is_valid {
        tracing::warn!("Image validation failed: {:?}", validation.errors);
    }
    for warning in &validation.warnings {
        tracing::warn!("Image validation warning: {}", warning);
    }

    // Create FitsHeader
    let mut header = FitsHeader::new();

    // Core observation metadata
    header.set_float("EXPTIME", header_data.exposure_time);
    header.set_string("DATE-OBS", &header_data.capture_timestamp);
    header.set_string("IMAGETYP", &header_data.frame_type);

    if let Some(name) = header_data.object_name {
        header.set_string("OBJECT", &name);
    }
    if let Some(filter) = header_data.filter {
        header.set_string("FILTER", &filter);
    }

    // Camera settings.
    // Why: gain/offset/bin_{x,y} are i32; widening to i64 (sign-extended) is always safe.
    if let Some(gain) = header_data.gain {
        header.set_int("GAIN", gain as i64);
    }
    if let Some(offset) = header_data.offset {
        header.set_int("OFFSET", offset as i64);
    }
    if let Some(temp) = header_data.ccd_temp {
        header.set_float("CCD-TEMP", temp);
    }

    header.set_int("XBINNING", header_data.bin_x as i64);
    header.set_int("YBINNING", header_data.bin_y as i64);

    // Pixel size information
    if let Some(pixel_x) = header_data.pixel_size_x {
        header.set_float("PIXSIZE1", pixel_x);
        header.set_float("XPIXSZ", pixel_x * header_data.bin_x as f64);
    }
    if let Some(pixel_y) = header_data.pixel_size_y {
        header.set_float("PIXSIZE2", pixel_y);
        header.set_float("YPIXSZ", pixel_y * header_data.bin_y as f64);
    }

    // Telescope/optics information
    if let Some(focal_length) = header_data.focal_length {
        header.set_float("FOCALLEN", focal_length);
    }
    if let Some(aperture) = header_data.aperture {
        header.set_float("APTDIA", aperture);
    }
    if let Some(telescope) = header_data.telescope {
        header.set_string("TELESCOP", &telescope);
    }
    if let Some(instrument) = header_data.instrument {
        header.set_string("INSTRUME", &instrument);
    }

    // Observer information
    if let Some(observer) = header_data.observer {
        header.set_string("OBSERVER", &observer);
    }

    // Observer location
    if let Some(lat) = header_data.site_latitude {
        header.set_float("SITELAT", lat);
    }
    if let Some(long) = header_data.site_longitude {
        header.set_float("SITELONG", long);
    }
    if let Some(elev) = header_data.site_elevation {
        header.set_float("SITEELEV", elev);
    }

    // Target coordinates + horizon coordinates. RA arrives in hours and
    // leaves in degrees; OBJCTALT/AIRMASS are optional and never fatal (see
    // helpers above).
    set_pointing_keywords(&mut header, header_data.ra, header_data.dec);
    set_horizon_keywords(&mut header, header_data.altitude);

    // Validate header completeness
    let header_validation = validate_fits_header(&header);
    for warning in &header_validation.warnings {
        tracing::debug!("FITS header warning: {}", warning);
    }

    // Ensure directory exists
    if let Some(parent) = std::path::Path::new(&file_path).parent() {
        std::fs::create_dir_all(parent).map_err(|e| {
            NightshadeError::OperationFailed(format!("Failed to create directory: {}", e))
        })?;
    }

    // Write file
    // write_fits is blocking, so execute it in spawn_blocking.

    let path = std::path::PathBuf::from(file_path);

    tokio::task::spawn_blocking(move || write_fits(&path, &image, &header))
        .await
        .map_err(|e| NightshadeError::OperationFailed(format!("Task join error: {}", e)))?
        .map_err(|e| NightshadeError::OperationFailed(format!("Failed to write FITS: {}", e)))?;

    Ok(())
}

/// Image Grading: save FITS with the rich (~40-keyword) header
/// bundle. Used by the sequencer's per-frame save path. Not FRB-exposed —
/// Dart callers continue to use [`api_save_fits_file`] / [`FitsWriteHeader`].
///
/// Writes every keyword the standard astrophotography workflow expects
/// (NINA / SGP / APP / PixInsight / ASTAP all read these), plus the
/// Nightshade-specific `NS-*` keywords for session / mosaic / frame
/// accounting. Missing optional fields are silently omitted — never
/// substituted with sentinel values.
pub async fn save_fits_file_rich(
    file_path: String,
    width: u32,
    height: u32,
    data: Vec<u16>,
    header_data: FitsWriteHeaderRich,
) -> Result<(), NightshadeError> {
    tracing::info!("Saving rich-header FITS file to: {}", file_path);

    let image = ImageData::from_u16(width, height, 1, &data);

    let validation = validate_image(&image, Some(width), Some(height));
    if !validation.is_valid {
        tracing::warn!("Image validation failed: {:?}", validation.errors);
    }
    for warning in &validation.warnings {
        tracing::warn!("Image validation warning: {}", warning);
    }

    let mut header = FitsHeader::new();

    // Core observation metadata.
    header.set_float("EXPTIME", header_data.exposure_time);
    header.set_string("DATE-OBS", &header_data.capture_timestamp);
    header.set_string("IMAGETYP", &header_data.frame_type);

    if let Some(name) = &header_data.object_name {
        header.set_string("OBJECT", name);
    }
    if let Some(filter) = &header_data.filter {
        header.set_string("FILTER", filter);
    }
    if let Some(pos) = header_data.filter_position {
        header.set_int("FILTPOS", pos as i64);
    }

    // Camera / sensor configuration.
    if let Some(gain) = header_data.gain {
        header.set_int("GAIN", gain as i64);
    }
    if let Some(offset) = header_data.offset {
        header.set_int("OFFSET", offset as i64);
    }
    if let Some(temp) = header_data.ccd_temp {
        header.set_float("CCD-TEMP", temp);
    }
    if let Some(set_temp) = header_data.set_temp {
        header.set_float("SET-TEMP", set_temp);
    }

    header.set_int("XBINNING", header_data.bin_x as i64);
    header.set_int("YBINNING", header_data.bin_y as i64);

    if let Some(pixel_x) = header_data.pixel_size_x {
        header.set_float("PIXSIZE1", pixel_x);
        header.set_float("XPIXSZ", pixel_x * header_data.bin_x as f64);
    }
    if let Some(pixel_y) = header_data.pixel_size_y {
        header.set_float("PIXSIZE2", pixel_y);
        header.set_float("YPIXSZ", pixel_y * header_data.bin_y as f64);
    }

    if let Some(bayer) = &header_data.bayer_pattern {
        header.set_string("BAYERPAT", bayer);
    }

    // Telescope / optics identification.
    if let Some(focal_length) = header_data.focal_length {
        header.set_float("FOCALLEN", focal_length);
    }
    if let Some(aperture) = header_data.aperture {
        header.set_float("APTDIA", aperture);
    }
    if let Some(telescope) = &header_data.telescope {
        header.set_string("TELESCOP", telescope);
    }
    if let Some(instrument) = &header_data.instrument {
        header.set_string("INSTRUME", instrument);
    }

    // Observer / site.
    if let Some(observer) = &header_data.observer {
        header.set_string("OBSERVER", observer);
    }
    if let Some(lat) = header_data.site_latitude {
        header.set_float("SITELAT", lat);
    }
    if let Some(long) = header_data.site_longitude {
        header.set_float("SITELONG", long);
    }
    if let Some(elev) = header_data.site_elevation {
        header.set_float("SITEELEV", elev);
    }

    // Target coordinates + horizon coordinates. RA arrives in hours and
    // leaves in degrees; OBJCTALT/AIRMASS are optional and never fatal (see
    // helpers above).
    set_pointing_keywords(&mut header, header_data.ra, header_data.dec);
    set_horizon_keywords(&mut header, header_data.altitude);

    // Image grading: live device telemetry.
    if let Some(pos) = header_data.focuser_position {
        header.set_int("FOCUSPOS", pos as i64);
    }
    if let Some(t) = header_data.focuser_temperature {
        header.set_float("FOCTEMP", t);
    }
    if let Some(angle) = header_data.rotator_angle {
        header.set_float("ROTATPOS", angle);
    }
    if let Some(rms) = header_data.guide_rms_arcsec {
        header.set_float("GUIDERMS", rms);
    }

    // Plate-solve result. SOLVED-RA / SOLVED-DEC are Nightshade
    // conventions consumed by re-stacking workflows that want to
    // compare the commanded pointing (RA/DEC) against where the field
    // actually landed.
    // Plate-solve result. FITS keywords are capped at 8 characters; we use
    // `SOLVRA` / `SOLVDEC` (Nightshade convention, also used by Voyager and
    // some PixInsight imports) plus the standard `PIXSCALE`.
    if let Some(ra) = header_data.solved_ra_hours {
        header.set_float("SOLVRA", ra);
    }
    if let Some(dec) = header_data.solved_dec_degrees {
        header.set_float("SOLVDEC", dec);
    }
    if let Some(scale) = header_data.plate_solve_pixel_scale_arcsec {
        header.set_float("PIXSCALE", scale);
    }
    if let Some(rot) = header_data.plate_solve_rotation_deg {
        // CROTA1 and CROTA2 are the WCS-standard field-rotation keywords;
        // every stacker reads at least one of them. Setting both follows
        // NINA's convention so PI / APP pick it up without configuration.
        header.set_float("CROTA1", rot);
        header.set_float("CROTA2", rot);
    }

    // Nightshade-specific session / frame / mosaic accounting (NS-*).
    if let Some(session_id) = &header_data.session_id {
        header.set_string("NS-SESID", session_id);
    }
    if let Some(idx) = header_data.frame_index {
        header.set_int("NS-FIDX", idx as i64);
    }
    if let Some(total) = header_data.total_planned_frames {
        header.set_int("NS-NPLN", total as i64);
    }
    if let Some(name) = &header_data.mosaic_name {
        // MOSAIC=1 is the boolean "this frame is part of a mosaic"
        // flag, kept as an integer keyword for maximum reader
        // compatibility (some tools refuse BOOLEAN FITS values).
        header.set_int("MOSAIC", 1);
        header.set_string("NS-MOSNM", name);
    }
    if let Some(idx) = header_data.mosaic_panel_index {
        // 1-based for human readability in viewers (panel 1, 2, 3 ...)
        // while keeping the original 0-based index in NS-PIDX for the
        // re-import path.
        header.set_int("PANELIDX", (idx + 1) as i64);
        header.set_int("NS-PIDX", idx as i64);
    }
    if let Some(row) = header_data.mosaic_panel_row {
        header.set_int("PANELROW", row as i64);
        header.set_int("NS-PROW", row as i64);
    }
    if let Some(col) = header_data.mosaic_panel_column {
        header.set_int("PANELCOL", col as i64);
        header.set_int("NS-PCOL", col as i64);
    }
    if let Some(total) = header_data.mosaic_total_panels {
        header.set_int("NS-NPAN", total as i64);
    }
    // Dual-rig — optical-train / camera attribution for multi-camera sessions.
    // Omitted for the single-rig case so existing frames are unchanged.
    if let Some(rig) = &header_data.rig_label {
        header.set_string("NS-RIG", rig);
    }

    // defect-map correction HISTORY card. When the
    // sequencer applied a defect map to this frame, record the
    // provenance so re-stacking workflows know the cosmetic correction
    // has already been done (and can skip re-applying it).
    if let Some(record) = &header_data.defect_map_correction {
        let history = format!(
            "Nightshade applied defect map v1 for camera {}: corrected {} of {} \
             defective pixels with {}x{} kernel using {} replacement.",
            record.camera_id,
            record.corrected_count,
            record.defect_count,
            record.kernel_diameter,
            record.kernel_diameter,
            record.method,
        );
        header.add_history(&history);
    }

    // Science — photometric metadata. Stamped when the frame
    // was captured by the SciencePhotometryInstruction. Non-photometric
    // captures omit every keyword.
    if let Some(catalog) = &header_data.photometry_object_catalog {
        if !catalog.is_empty() {
            header.set_string("OBJCAT", catalog);
        }
    }
    if let Some(refs) = &header_data.photometry_reference_stars {
        if !refs.is_empty() {
            // FITS keyword values are 70 chars after the equals sign;
            // the joined reference-star list can exceed that, so we
            // store it on a CONTINUE-style card as a comment. For
            // ergonomic readability via FITS viewers we use a single
            // REFSTARS card and truncate beyond 68 characters (the
            // standard one-card payload).
            let truncated = if refs.len() > 68 {
                format!("{}...", &refs[..65])
            } else {
                refs.clone()
            };
            header.set_string("REFSTARS", &truncated);
        }
    }
    if let Some(mjd) = header_data.photometry_mjd_obs {
        header.set_float("MJD-OBS", mjd);
    }
    if let Some(mag) = header_data.photometry_instrumental_mag {
        header.set_float("INSTRMAG", mag);
    }
    if let Some(mag) = header_data.photometry_differential_mag {
        header.set_float("DIFFMAG", mag);
    }
    if let Some(fwhm) = header_data.photometry_fwhm_arcsec {
        header.set_float("FWHM", fwhm);
    }
    if let Some(snr) = header_data.photometry_snr {
        header.set_float("SNR", snr);
    }

    // Validate header completeness — warnings only; we never refuse to
    // write a frame because of a missing nice-to-have keyword.
    let header_validation = validate_fits_header(&header);
    for warning in &header_validation.warnings {
        tracing::debug!("FITS header warning: {}", warning);
    }

    if let Some(parent) = std::path::Path::new(&file_path).parent() {
        std::fs::create_dir_all(parent).map_err(|e| {
            NightshadeError::OperationFailed(format!("Failed to create directory: {}", e))
        })?;
    }

    let path = std::path::PathBuf::from(file_path);

    tokio::task::spawn_blocking(move || write_fits(&path, &image, &header))
        .await
        .map_err(|e| NightshadeError::OperationFailed(format!("Task join error: {}", e)))?
        .map_err(|e| NightshadeError::OperationFailed(format!("Failed to write FITS: {}", e)))?;

    Ok(())
}

/// Save FITS file directly from the last captured image stored in Rust
/// This eliminates the need to transfer raw pixel data across the FFI boundary
/// by using the image data already stored from the last exposure.
///
/// Returns an error if no image has been captured yet for the specified device.
pub async fn api_save_fits_from_last_capture(
    device_id: String,
    file_path: String,
    header_data: FitsWriteHeader,
) -> Result<(), NightshadeError> {
    tracing::info!(
        "Saving FITS from last capture for device {} to: {}",
        device_id,
        file_path
    );

    // Get the stored raw image data for this device
    let mut storage = get_unified_image_storage().lock().await;
    let captured_data = storage.get(&device_id).ok_or_else(|| {
        NightshadeError::OperationFailed(format!(
            "No captured image available for device {}. Please capture an image first.",
            device_id
        ))
    })?;

    // Clone the data we need so we can release the lock before the blocking write
    let width = captured_data.raw_info.width;
    let height = captured_data.raw_info.height;
    let data = captured_data.raw_info.data.clone();
    drop(storage); // Release the lock

    // Now save using the existing logic
    tracing::info!("Saving {}x{} image ({} pixels)", width, height, data.len());

    // Create ImageData
    let image = ImageData::from_u16(width, height, 1, &data);

    // Validate image data
    let validation = validate_image(&image, Some(width), Some(height));
    if !validation.is_valid {
        tracing::warn!("Image validation failed: {:?}", validation.errors);
    }
    for warning in &validation.warnings {
        tracing::warn!("Image validation warning: {}", warning);
    }

    // Create FitsHeader
    let mut header = FitsHeader::new();

    // Core observation metadata
    header.set_float("EXPTIME", header_data.exposure_time);
    header.set_string("DATE-OBS", &header_data.capture_timestamp);
    header.set_string("IMAGETYP", &header_data.frame_type);

    if let Some(name) = header_data.object_name {
        header.set_string("OBJECT", &name);
    }
    if let Some(filter) = header_data.filter {
        header.set_string("FILTER", &filter);
    }

    // Camera settings.
    // Why: gain/offset/bin_{x,y} are i32; widening to i64 (sign-extended) is always safe.
    if let Some(gain) = header_data.gain {
        header.set_int("GAIN", gain as i64);
    }
    if let Some(offset) = header_data.offset {
        header.set_int("OFFSET", offset as i64);
    }
    if let Some(temp) = header_data.ccd_temp {
        header.set_float("CCD-TEMP", temp);
    }

    header.set_int("XBINNING", header_data.bin_x as i64);
    header.set_int("YBINNING", header_data.bin_y as i64);

    // Pixel size information
    if let Some(pixel_x) = header_data.pixel_size_x {
        header.set_float("PIXSIZE1", pixel_x);
        header.set_float("XPIXSZ", pixel_x * header_data.bin_x as f64);
    }
    if let Some(pixel_y) = header_data.pixel_size_y {
        header.set_float("PIXSIZE2", pixel_y);
        header.set_float("YPIXSZ", pixel_y * header_data.bin_y as f64);
    }

    // Telescope/optics information
    if let Some(focal_length) = header_data.focal_length {
        header.set_float("FOCALLEN", focal_length);
    }
    if let Some(aperture) = header_data.aperture {
        header.set_float("APTDIA", aperture);
    }
    if let Some(telescope) = header_data.telescope {
        header.set_string("TELESCOP", &telescope);
    }
    if let Some(instrument) = header_data.instrument {
        header.set_string("INSTRUME", &instrument);
    }

    // Observer information
    if let Some(observer) = header_data.observer {
        header.set_string("OBSERVER", &observer);
    }

    // Observer location
    if let Some(lat) = header_data.site_latitude {
        header.set_float("SITELAT", lat);
    }
    if let Some(long) = header_data.site_longitude {
        header.set_float("SITELONG", long);
    }
    if let Some(elev) = header_data.site_elevation {
        header.set_float("SITEELEV", elev);
    }

    // Target coordinates + horizon coordinates. RA arrives in hours and
    // leaves in degrees; OBJCTALT/AIRMASS are optional and never fatal (see
    // helpers above).
    set_pointing_keywords(&mut header, header_data.ra, header_data.dec);
    set_horizon_keywords(&mut header, header_data.altitude);

    // Validate header completeness
    let header_validation = validate_fits_header(&header);
    for warning in &header_validation.warnings {
        tracing::debug!("FITS header warning: {}", warning);
    }

    // Ensure directory exists
    if let Some(parent) = std::path::Path::new(&file_path).parent() {
        std::fs::create_dir_all(parent).map_err(|e| {
            NightshadeError::OperationFailed(format!("Failed to create directory: {}", e))
        })?;
    }

    // Write file using spawn_blocking
    let path = std::path::PathBuf::from(file_path);

    tokio::task::spawn_blocking(move || write_fits(&path, &image, &header))
        .await
        .map_err(|e| NightshadeError::OperationFailed(format!("Task join error: {}", e)))?
        .map_err(|e| NightshadeError::OperationFailed(format!("Failed to write FITS: {}", e)))?;

    tracing::info!("FITS file saved successfully from last capture");
    Ok(())
}

/// `(min, max, mean)` of a stretched display buffer in ONE pass.
///
/// `None` for an empty buffer — the caller logs nothing rather than dividing
/// by a zero pixel count.
fn display_data_summary(display_data: &[u8]) -> Option<(u8, u8, u64)> {
    if display_data.is_empty() {
        return None;
    }
    let (min, max, sum) = display_data
        .iter()
        .fold((u8::MAX, u8::MIN, 0u64), |(min, max, sum), &v| {
            (min.min(v), max.max(v), sum + v as u64)
        });
    Some((min, max, sum / display_data.len() as u64))
}

// Image processing

/// Calculate image statistics
fn image_stats(width: u32, height: u32, data: Vec<u16>) -> nightshade_imaging::ImageStats {
    let image = ImageData::from_u16(width, height, 1, &data);
    nightshade_imaging::calculate_stats_u16(&image)
}

/// Auto-stretch image for display. Returns RGBA (4 bytes per pixel, alpha=255).
fn auto_stretch_image(width: u32, height: u32, data: Vec<u16>) -> Vec<u8> {
    let image = ImageData::from_u16(width, height, 1, &data);
    let params = nightshade_imaging::auto_stretch_stf(&image);
    let grayscale = nightshade_imaging::apply_stretch(&image, &params);

    // Convert grayscale to RGBA
    let num_pixels = grayscale.len();
    let mut rgba = vec![0u8; num_pixels * 4];
    rgba.par_chunks_exact_mut(4)
        .zip(grayscale.par_iter())
        .for_each(|(dst, &gray)| {
            dst[0] = gray; // R
            dst[1] = gray; // G
            dst[2] = gray; // B
            dst[3] = 255; // A
        });
    rgba
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
    use nightshade_imaging::{apply_stretch_rgb_per_channel, auto_stretch_rgb};

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

/// Debayer image to RGBA8
fn debayer_image(
    width: u32,
    height: u32,
    data: Vec<u16>,
    pattern: BayerPattern,
    algorithm: DebayerAlgorithm,
) -> Vec<u8> {
    // Convert u16 vec to u8 slice (little endian)
    let bytes: Vec<u8> = data.iter().flat_map(|&v| v.to_le_bytes()).collect();

    let rgb = nightshade_imaging::debayer(&bytes, width, height, pattern, algorithm);
    rgb.to_rgba8()
}

/// Calculate image statistics
#[flutter_rust_bridge::frb(sync)]
pub fn api_get_image_stats(
    width: u32,
    height: u32,
    data: Vec<u16>,
) -> Result<ImageStatsResult, NightshadeError> {
    let stats = image_stats(width, height, data);
    Ok(ImageStatsResult {
        min: stats.min,
        max: stats.max,
        mean: stats.mean,
        median: stats.median,
        std_dev: stats.std_dev,
        // Basic-stats path runs no star detection: honest None for both.
        hfr: None,
        eccentricity: None,
        fwhm: None,
        star_count: 0,
    })
}

/// Auto-stretch image for display
#[flutter_rust_bridge::frb(sync)]
pub fn api_auto_stretch_image(
    width: u32,
    height: u32,
    data: Vec<u16>,
) -> Result<Vec<u8>, NightshadeError> {
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
) -> Result<Vec<u8>, NightshadeError> {
    Ok(auto_stretch_color_image(width, height, data))
}

/// Debayer image
#[flutter_rust_bridge::frb(sync)]
pub fn api_debayer_image(
    width: u32,
    height: u32,
    data: Vec<u16>,
    pattern_str: String,
    algo_str: String,
) -> Result<Vec<u8>, NightshadeError> {
    let pattern = BayerPattern::from_str(&pattern_str).ok_or_else(|| {
        NightshadeError::InvalidParameter(format!("Invalid bayer pattern: {}", pattern_str))
    })?;

    let algorithm = match algo_str.to_lowercase().as_str() {
        "bilinear" => DebayerAlgorithm::Bilinear,
        "vng" => DebayerAlgorithm::VNG,
        "superpixel" => DebayerAlgorithm::SuperPixel,
        _ => DebayerAlgorithm::Bilinear,
    };

    Ok(debayer_image(width, height, data, pattern, algorithm))
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
) -> Result<Vec<u8>, NightshadeError> {
    let _permit = thumbnail_generation_gate()
        .acquire()
        .await
        .map_err(|e| NightshadeError::OperationFailed(format!("Thumbnail gate closed: {}", e)))?;

    tokio::task::spawn_blocking(move || generate_fits_thumbnail_jpeg(&file_path, max_size))
        .await
        .map_err(|e| {
            NightshadeError::OperationFailed(format!("Thumbnail task join error: {}", e))
        })?
}

/// The blocking body of [`api_generate_fits_thumbnail`]. Never call this from
/// an async context without `spawn_blocking`.
fn generate_fits_thumbnail_jpeg(
    file_path: &str,
    max_size: u32,
) -> Result<Vec<u8>, NightshadeError> {
    use nightshade_imaging::read_fits;
    use std::path::Path;

    // Read FITS file
    let path = Path::new(file_path);
    let (image_data, _header) = read_fits(path)
        .map_err(|e| NightshadeError::ImageError(format!("Failed to read FITS: {:?}", e)))?;

    let width = image_data.width;
    let height = image_data.height;
    let channels = image_data.channels as usize;
    if width == 0 || height == 0 {
        return Err(NightshadeError::ImageError(format!(
            "Cannot generate thumbnail for empty FITS image {}x{}",
            width, height
        )));
    }
    if channels == 0 {
        return Err(NightshadeError::ImageError(
            "Cannot generate thumbnail for FITS image with zero channels".to_string(),
        ));
    }
    if max_size == 0 {
        return Err(NightshadeError::InvalidParameter(
            "Thumbnail max_size must be greater than zero".to_string(),
        ));
    }

    let pixel_count = (width as usize)
        .checked_mul(height as usize)
        .ok_or_else(|| {
            NightshadeError::ImageError(format!(
                "FITS image dimensions overflow: {}x{}",
                width, height
            ))
        })?;
    let sample_count = pixel_count.checked_mul(channels).ok_or_else(|| {
        NightshadeError::ImageError(format!(
            "FITS sample count overflows for {}x{} image with {} channels",
            width, height, channels
        ))
    })?;
    let expected_bytes = sample_count
        .checked_mul(image_data.pixel_type.byte_size())
        .ok_or_else(|| {
            NightshadeError::ImageError(format!(
                "FITS buffer size overflows for {} samples",
                sample_count
            ))
        })?;
    if image_data.data.len() != expected_bytes {
        return Err(NightshadeError::ImageError(format!(
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
    let sample_at = |index: usize| -> Result<u16, NightshadeError> {
        let offset = index * bytes_per_sample;
        let chunk = raw.get(offset..offset + bytes_per_sample).ok_or_else(|| {
            NightshadeError::ImageError(format!(
                "FITS sample {} falls outside its validated buffer",
                index
            ))
        })?;
        Ok(match image_data.pixel_type {
            nightshade_imaging::PixelType::U8 => u16::from(chunk[0]) << 8,
            nightshade_imaging::PixelType::U16 => u16::from_le_bytes([chunk[0], chunk[1]]),
            // High 16 bits, matching the whole-frame conversion this replaced.
            nightshade_imaging::PixelType::U32 => {
                (u32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]) >> 16) as u16
            }
            nightshade_imaging::PixelType::F32 => {
                let value = f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
                (value.clamp(0.0, 1.0) * 65535.0) as u16
            }
            nightshade_imaging::PixelType::F64 => {
                let value = f64::from_le_bytes([
                    chunk[0], chunk[1], chunk[2], chunk[3], chunk[4], chunk[5], chunk[6], chunk[7],
                ]);
                (value.clamp(0.0, 1.0) * 65535.0) as u16
            }
        })
    };

    // Calculate downscale factor
    let max_dimension = width.max(height);
    let scale = (max_dimension / max_size + u32::from(max_dimension % max_size != 0)).max(1);

    // Downscale image
    let new_width = (width / scale).max(1);
    let new_height = (height / scale).max(1);
    let thumbnail_pixels = (new_width as usize)
        .checked_mul(new_height as usize)
        .ok_or_else(|| {
            NightshadeError::ImageError(format!(
                "Thumbnail dimensions overflow: {}x{}",
                new_width, new_height
            ))
        })?;
    let expected_rgba_bytes = thumbnail_pixels.checked_mul(4).ok_or_else(|| {
        NightshadeError::ImageError(format!(
            "Thumbnail RGBA buffer size overflows for {} pixels",
            thumbnail_pixels
        ))
    })?;
    let mut downscaled = Vec::new();
    downscaled
        .try_reserve_exact(thumbnail_pixels)
        .map_err(|e| {
            NightshadeError::ImageError(format!(
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
                .ok_or_else(|| {
                    NightshadeError::ImageError("FITS pixel index overflow".to_string())
                })?;
            let sample_idx = pixel_idx.checked_mul(channels).ok_or_else(|| {
                NightshadeError::ImageError("FITS sample index overflow".to_string())
            })?;
            let sample_end = sample_idx.checked_add(channels).ok_or_else(|| {
                NightshadeError::ImageError("FITS sample index overflow".to_string())
            })?;
            if sample_end > sample_count {
                return Err(NightshadeError::ImageError(format!(
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
        return Err(NightshadeError::ImageError(format!(
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
        return Err(NightshadeError::ImageError(format!(
            "Invalid grayscale thumbnail length: expected {} bytes, got {}",
            thumbnail_pixels,
            stretched.len()
        )));
    }

    // Encode as JPEG
    use image::{GrayImage, ImageEncoder};
    use std::io::Cursor;

    let gray_img = GrayImage::from_raw(new_width, new_height, stretched).ok_or_else(|| {
        NightshadeError::ImageError("Failed to create grayscale image".to_string())
    })?;

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
        .map_err(|e| NightshadeError::ImageError(format!("JPEG encoding failed: {}", e)))?;

    Ok(jpeg_data)
}

/// Apply Auto White Balance using Histogram Peak Alignment
/// This aligns the background sky peak of R and B channels to the G channel
pub(crate) fn apply_auto_white_balance(image: &mut [u16]) {
    if image.len() % 3 != 0 {
        return;
    }

    let mut hist_r = vec![0u32; 65536];
    let mut hist_g = vec![0u32; 65536];
    let mut hist_b = vec![0u32; 65536];

    // 1. Compute histograms
    for chunk in image.chunks(3) {
        hist_r[chunk[0] as usize] += 1;
        hist_g[chunk[1] as usize] += 1;
        hist_b[chunk[2] as usize] += 1;
    }

    // 2. Find peaks (modes), ignoring bottom 1% to avoid clipping noise
    // A simple mode might be noisy, so let's find the max bin
    // We start searching from a small offset to avoid black clipping
    let start_idx = 100; // arbitrary small offset

    let get_peak = |hist: &[u32]| -> u16 {
        let mut max_count = 0;
        let mut peak_idx = 0;
        for (i, &count) in hist.iter().enumerate().skip(start_idx) {
            if count > max_count {
                max_count = count;
                peak_idx = i;
            }
        }
        peak_idx as u16
    };

    let peak_r = get_peak(&hist_r);
    let peak_g = get_peak(&hist_g);
    let peak_b = get_peak(&hist_b);

    tracing::info!("AWB Peaks: R={}, G={}, B={}", peak_r, peak_g, peak_b);

    if peak_r == 0 || peak_g == 0 || peak_b == 0 {
        tracing::warn!("AWB failed: peak is 0");
        return;
    }

    // 3. Calculate scaling factors to align to Green
    let target = peak_g as f32;
    let scale_r = target / peak_r as f32;
    let scale_b = target / peak_b as f32;

    tracing::info!("AWB Scales: R={:.3}, B={:.3}", scale_r, scale_b);

    // 4. Apply scaling
    // Use parallel iterator for speed if possible, but slice is mutable
    // Rayon's par_chunks_mut is perfect
    use rayon::prelude::*;
    image.par_chunks_mut(3).for_each(|pixel| {
        // R
        pixel[0] = (pixel[0] as f32 * scale_r).min(65535.0) as u16;
        // G (unchanged)
        // B
        pixel[2] = (pixel[2] as f32 * scale_b).min(65535.0) as u16;
    });
}

// INDI autofocus

/// INDI autofocus configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IndiAutofocusConfigApi {
    pub method: String, // "vcurve", "quadratic", "hyperbolic"
    pub step_size: i32,
    pub steps_out: u32,
    pub exposure_duration: f64,
    pub backlash_compensation: i32,
    pub use_temperature_prediction: bool,
    pub max_star_count_change: Option<f64>,
    pub outlier_rejection_sigma: f64,
    pub binning: i32,
    pub move_timeout_secs: u64,
    pub settling_time_ms: u64,
}

impl Default for IndiAutofocusConfigApi {
    fn default() -> Self {
        Self {
            method: "vcurve".to_string(),
            step_size: 100,
            steps_out: 7,
            exposure_duration: 3.0,
            backlash_compensation: 0,
            use_temperature_prediction: true,
            max_star_count_change: Some(0.5),
            outlier_rejection_sigma: 3.0,
            binning: 1,
            move_timeout_secs: 120,
            settling_time_ms: 500,
        }
    }
}

/// INDI autofocus result
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IndiAutofocusResultApi {
    pub best_position: i32,
    pub best_hfr: f64,
    pub curve_fit_quality: f64,
    pub method_used: String,
    pub data_points: Vec<FocusDataPointApi>,
    pub temperature_celsius: Option<f64>,
    pub backlash_applied: bool,
    pub success: bool,
    pub error_message: Option<String>,
}

/// Focus data point for autofocus curve
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FocusDataPointApi {
    pub position: i32,
    pub hfr: f64,
    pub fwhm: Option<f64>,
    pub star_count: u32,
}

/// Run the INDI autofocus routine and return the best focus position with its
/// curve data. Device ids are INDI-form: `indi:host:port:device_name`.
pub async fn api_run_indi_autofocus(
    camera_id: String,
    focuser_id: String,
    config: IndiAutofocusConfigApi,
) -> Result<IndiAutofocusResultApi, NightshadeError> {
    tracing::info!(
        "Starting INDI autofocus: camera={}, focuser={}, method={}",
        camera_id,
        focuser_id,
        config.method
    );

    // Validate device IDs are INDI
    if !camera_id.starts_with("indi:") || !focuser_id.starts_with("indi:") {
        return Err(NightshadeError::InvalidParameter(
            "Both camera and focuser must be INDI devices".to_string(),
        ));
    }

    // Get INDI clients for camera and focuser
    let device_manager = get_device_manager();

    let camera_client = device_manager
        .get_indi_client(&camera_id)
        .await
        .ok_or_else(|| {
            NightshadeError::NotConnected(format!("INDI camera not connected: {}", camera_id))
        })?;

    let focuser_client = device_manager
        .get_indi_client(&focuser_id)
        .await
        .ok_or_else(|| {
            NightshadeError::NotConnected(format!("INDI focuser not connected: {}", focuser_id))
        })?;

    // Extract device names from IDs (format: "indi:host:port:device_name")
    let camera_parts: Vec<&str> = camera_id.split(':').collect();
    let camera_device_name = camera_parts[3..].join(":");

    let focuser_parts: Vec<&str> = focuser_id.split(':').collect();
    let focuser_device_name = focuser_parts[3..].join(":");

    // Create INDI camera and focuser wrappers
    let camera = Arc::new(nightshade_indi::IndiCamera::new(
        camera_client,
        &camera_device_name,
    ));

    let focuser = Arc::new(nightshade_indi::IndiFocuser::new(
        focuser_client,
        &focuser_device_name,
    ));

    // Convert config
    let method = match config.method.as_str() {
        "vcurve" => nightshade_indi::autofocus::AutofocusMethod::VCurve,
        "quadratic" => nightshade_indi::autofocus::AutofocusMethod::Quadratic,
        "hyperbolic" => nightshade_indi::autofocus::AutofocusMethod::Hyperbolic,
        _ => nightshade_indi::autofocus::AutofocusMethod::VCurve,
    };

    let af_config = nightshade_indi::autofocus::IndiAutofocusConfig {
        method,
        step_size: config.step_size,
        steps_out: config.steps_out,
        exposure_duration: config.exposure_duration,
        backlash_compensation: config.backlash_compensation,
        use_temperature_prediction: config.use_temperature_prediction,
        max_star_count_change: config.max_star_count_change,
        outlier_rejection_sigma: config.outlier_rejection_sigma,
        binning: config.binning,
        move_timeout_secs: config.move_timeout_secs,
        settling_time_ms: config.settling_time_ms,
    };

    // Create autofocus engine
    let autofocus = nightshade_indi::autofocus::IndiAutofocus::new(camera, focuser, af_config);

    // Run autofocus
    let result = autofocus
        .run()
        .await
        .map_err(|e| NightshadeError::OperationFailed(format!("INDI autofocus failed: {}", e)))?;

    // Convert result
    let method_str = match result.method_used {
        nightshade_indi::autofocus::AutofocusMethod::VCurve => "vcurve",
        nightshade_indi::autofocus::AutofocusMethod::Quadratic => "quadratic",
        nightshade_indi::autofocus::AutofocusMethod::Hyperbolic => "hyperbolic",
    };

    let data_points: Vec<FocusDataPointApi> = result
        .data_points
        .iter()
        .map(|dp| FocusDataPointApi {
            position: dp.position,
            hfr: dp.hfr,
            fwhm: dp.fwhm,
            star_count: dp.star_count,
        })
        .collect();

    Ok(IndiAutofocusResultApi {
        best_position: result.best_position,
        best_hfr: result.best_hfr,
        curve_fit_quality: result.curve_fit_quality,
        method_used: method_str.to_string(),
        data_points,
        temperature_celsius: result.temperature_celsius,
        backlash_applied: result.backlash_applied,
        success: result.success,
        error_message: result.error_message,
    })
}

// Image calibration

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
) -> Result<(), NightshadeError> {
    use nightshade_imaging::{calibration, read_image, write_fits, FitsHeader, ImageFormat};
    use std::path::Path;

    // Load light frame
    let light_result = read_image(Path::new(&light_path)).map_err(|e| {
        NightshadeError::ImageError(format!(
            "Failed to read light frame '{}': {}",
            light_path, e
        ))
    })?;

    // Load optional calibration frames
    let dark = match &dark_path {
        Some(p) if !p.is_empty() => {
            let result = read_image(Path::new(p)).map_err(|e| {
                NightshadeError::ImageError(format!("Failed to read dark frame '{}': {}", p, e))
            })?;
            Some(result.image)
        }
        _ => None,
    };

    let flat = match &flat_path {
        Some(p) if !p.is_empty() => {
            let result = read_image(Path::new(p)).map_err(|e| {
                NightshadeError::ImageError(format!("Failed to read flat frame '{}': {}", p, e))
            })?;
            Some(result.image)
        }
        _ => None,
    };

    let bias = match &bias_path {
        Some(p) if !p.is_empty() => {
            let result = read_image(Path::new(p)).map_err(|e| {
                NightshadeError::ImageError(format!("Failed to read bias frame '{}': {}", p, e))
            })?;
            Some(result.image)
        }
        _ => None,
    };

    // Run calibration pipeline
    let calibrated = calibration::calibrate_frame(
        &light_result.image,
        dark.as_ref(),
        flat.as_ref(),
        bias.as_ref(),
    )
    .map_err(|e| NightshadeError::ImageError(format!("Calibration failed: {}", e)))?;

    // Save calibrated image, preserving original format
    let out = Path::new(&output_path);
    let ext = out.extension().and_then(|e| e.to_str()).unwrap_or("fits");
    let out_format = ImageFormat::from_extension(ext).unwrap_or(ImageFormat::Fits);

    match out_format {
        ImageFormat::Fits => {
            // Carry over header from original light, add calibration note.
            // set_value_token, not set_string: the read path flattened each
            // value to header text, and re-quoting it would ship
            // EXPTIME = '120.0' — a string card no stacker reads as a number.
            let mut header = FitsHeader::new();
            for (key, value) in &light_result.header {
                header.set_value_token(key, value);
            }
            header.set_string("CALSTAT", "calibrated by Nightshade");
            if let Some(ref path) = dark_path {
                if !path.is_empty() {
                    header.set_string("DARKFILE", path);
                }
            }
            if let Some(ref path) = flat_path {
                if !path.is_empty() {
                    header.set_string("FLATFILE", path);
                }
            }
            if let Some(ref path) = bias_path {
                if !path.is_empty() {
                    header.set_string("BIASFILE", path);
                }
            }

            write_fits(out, &calibrated, &header).map_err(|e| {
                NightshadeError::ImageError(format!("Failed to write calibrated FITS: {:?}", e))
            })?;
        }
        ImageFormat::Xisf => {
            nightshade_imaging::write_xisf(
                out,
                &calibrated,
                &nightshade_imaging::XisfMetadata::default(),
            )
            .map_err(|e| {
                NightshadeError::ImageError(format!("Failed to write calibrated XISF: {:?}", e))
            })?;
        }
        ImageFormat::Tiff => {
            nightshade_imaging::write_tiff(out, &calibrated).map_err(|e| {
                NightshadeError::ImageError(format!("Failed to write calibrated TIFF: {}", e))
            })?;
        }
        ImageFormat::Png => {
            nightshade_imaging::write_png(out, &calibrated).map_err(|e| {
                NightshadeError::ImageError(format!("Failed to write calibrated PNG: {}", e))
            })?;
        }
        _ => {
            // Default to FITS for unsupported output formats
            let header = FitsHeader::new();
            write_fits(out, &calibrated, &header).map_err(|e| {
                NightshadeError::ImageError(format!("Failed to write calibrated file: {:?}", e))
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
) -> Result<Vec<u16>, NightshadeError> {
    use nightshade_imaging::{calibration, ImageData};

    let light = ImageData::from_u16(width, height, 1, &light_data);

    let dark = dark_data.map(|d| ImageData::from_u16(width, height, 1, &d));
    let flat = flat_data.map(|f| ImageData::from_u16(width, height, 1, &f));
    let bias = bias_data.map(|b| ImageData::from_u16(width, height, 1, &b));

    let calibrated =
        calibration::calibrate_frame(&light, dark.as_ref(), flat.as_ref(), bias.as_ref())
            .map_err(|e| NightshadeError::ImageError(format!("Calibration failed: {}", e)))?;

    calibrated.as_u16().ok_or_else(|| {
        NightshadeError::ImageError(
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
) -> Result<ApiLiveStackingStats, NightshadeError> {
    let result = crate::stacking_api::stacking_start(reference_image_path, convert_config(config))
        .map_err(|e| NightshadeError::ImageError(e))?;
    Ok(convert_stats(result))
}

/// Start live stacking from raw pixel data in memory.
pub fn api_stacking_start_from_data(
    width: u32,
    height: u32,
    data: Vec<u16>,
    config: ApiLiveStackingConfig,
) -> Result<ApiLiveStackingStats, NightshadeError> {
    let result =
        crate::stacking_api::stacking_start_from_data(width, height, data, convert_config(config))
            .map_err(|e| NightshadeError::ImageError(e))?;
    Ok(convert_stats(result))
}

/// Add a frame to the live stack from a file path.
///
/// Returns the current stacked result.
pub fn api_stacking_add_frame(
    image_path: String,
) -> Result<ApiLiveStackingResult, NightshadeError> {
    let result = crate::stacking_api::stacking_add_frame(image_path)
        .map_err(|e| NightshadeError::ImageError(e))?;
    Ok(convert_result(result))
}

/// Add a frame to the live stack from raw pixel data.
pub fn api_stacking_add_frame_from_data(
    width: u32,
    height: u32,
    data: Vec<u16>,
) -> Result<ApiLiveStackingResult, NightshadeError> {
    let result = crate::stacking_api::stacking_add_frame_from_data(width, height, data)
        .map_err(|e| NightshadeError::ImageError(e))?;
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
) -> Result<ApiLiveStackingMaster, NightshadeError> {
    // The write is blocking (and a full-frame master is tens of megabytes), so
    // it runs off the async executor like the other FITS writers here.
    let result = tokio::task::spawn_blocking(move || {
        crate::stacking_api::stacking_save_master_fits(file_path)
    })
    .await
    .map_err(|e| NightshadeError::OperationFailed(format!("Task join error: {}", e)))?
    .map_err(NightshadeError::ImageError)?;

    Ok(ApiLiveStackingMaster {
        file_path: result.file_path,
        stacked_frame_count: result.stacked_frame_count,
        total_integration_secs: result.total_integration_secs,
        date_obs: result.date_obs,
    })
}

/// Get the current stacked result without adding a frame.
pub fn api_stacking_get_result() -> Result<ApiLiveStackingResult, NightshadeError> {
    let result =
        crate::stacking_api::stacking_get_result().map_err(|e| NightshadeError::ImageError(e))?;
    Ok(convert_result(result))
}

/// Get the current stacking statistics.
pub fn api_stacking_get_stats() -> Result<ApiLiveStackingStats, NightshadeError> {
    let result =
        crate::stacking_api::stacking_get_stats().map_err(|e| NightshadeError::ImageError(e))?;
    Ok(convert_stats(result))
}

/// Reset the live stacker, clearing accumulated data but keeping the reference.
pub fn api_stacking_reset() -> Result<(), NightshadeError> {
    crate::stacking_api::stacking_reset().map_err(|e| NightshadeError::ImageError(e))
}

/// Stop live stacking and release all resources.
pub fn api_stacking_stop() -> Result<(), NightshadeError> {
    crate::stacking_api::stacking_stop().map_err(|e| NightshadeError::ImageError(e))
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
    // Why: NIGHTSHADE_DATA_DIR is the standard per-platform application
    // data path set by the Flutter shell on launch (see main_headless.dart
    // and the FFI bridge startup). The temp_dir fallback exists for unit
    // tests and for headless invocations where the env var hasn't been
    // populated yet — for those callers the defect maps are session-scoped
    // and don't need to survive a reboot. Production hosts hit the env-var
    // branch first.
    let base = std::env::var_os("NIGHTSHADE_DATA_DIR")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir().join("nightshade"));
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
/// `$NIGHTSHADE_DATA_DIR/defect_maps/` keyed by camera id, sensor size and
/// temperature bucket, and the status is returned.
pub async fn api_defect_map_build(
    camera_id: String,
    dark_frame_paths: Vec<String>,
    sensor_temperature_celsius: f64,
) -> Result<ApiDefectMapStatus, NightshadeError> {
    if camera_id.trim().is_empty() {
        return Err(NightshadeError::InvalidParameter(
            "camera_id is empty".to_string(),
        ));
    }
    if dark_frame_paths.len() < nightshade_imaging::defect_map::MIN_CONSISTENCY_FRAMES {
        return Err(NightshadeError::InvalidParameter(format!(
            "defect map build requires at least {} dark frames; got {}",
            nightshade_imaging::defect_map::MIN_CONSISTENCY_FRAMES,
            dark_frame_paths.len()
        )));
    }

    let darks: Vec<ImageData> = tokio::task::spawn_blocking(move || {
        let mut frames = Vec::with_capacity(dark_frame_paths.len());
        for path in &dark_frame_paths {
            let result = nightshade_imaging::read_image(std::path::Path::new(path))
                .map_err(|e| format!("failed to read {}: {}", path, e))?;
            frames.push(result.image);
        }
        Ok::<_, String>(frames)
    })
    .await
    .map_err(|e| NightshadeError::ImageError(format!("join error reading darks: {}", e)))?
    .map_err(NightshadeError::ImageError)?;

    let bucket = nightshade_imaging::defect_map::bucket_temperature(sensor_temperature_celsius);
    let dark_refs: Vec<&ImageData> = darks.iter().collect();
    let map = nightshade_imaging::defect_map::build_defect_map(&dark_refs, bucket)
        .map_err(|e| NightshadeError::ImageError(e.to_string()))?;

    let path = defect_map_path(&camera_id, map.width, map.height, bucket);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| {
            NightshadeError::ImageError(format!(
                "failed to create defect map directory {}: {}",
                parent.display(),
                e
            ))
        })?;
    }
    map.write_to_file(&path)
        .map_err(|e| NightshadeError::ImageError(e.to_string()))?;

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
) -> Result<(), NightshadeError> {
    if camera_id.trim().is_empty() {
        return Err(NightshadeError::InvalidParameter(
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
) -> Result<(), NightshadeError> {
    if camera_id.trim().is_empty() {
        return Err(NightshadeError::InvalidParameter(
            "camera_id is empty".to_string(),
        ));
    }
    let bucket = nightshade_imaging::defect_map::bucket_temperature(sensor_temperature_celsius);
    let path = defect_map_path(&camera_id, width, height, bucket);
    if path.exists() {
        std::fs::remove_file(&path).map_err(|e| {
            NightshadeError::ImageError(format!(
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
) -> Result<(), NightshadeError> {
    if camera_id.trim().is_empty() {
        return Err(NightshadeError::InvalidParameter(
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

    let kernel = nightshade_imaging::defect_map::KernelSize::from_diameter(kernel_diameter)
        .ok_or_else(|| {
            NightshadeError::InvalidParameter(format!(
                "kernel_diameter must be 3, 5, or 7; got {}",
                kernel_diameter
            ))
        })?;
    let method_parsed = nightshade_imaging::defect_map::CorrectionMethod::from_wire(&method);

    let bucket = nightshade_imaging::defect_map::bucket_temperature(sensor_temperature_celsius);
    let path = defect_map_path(&camera_id, width, height, bucket);
    if !path.exists() {
        return Err(NightshadeError::InvalidParameter(format!(
            "No defect map stored for camera={} {}x{} at {} deci-celsius; \
             build one before enabling apply-during-capture.",
            camera_id, width, height, bucket,
        )));
    }
    let map = nightshade_imaging::defect_map::DefectMap::read_from_file(&path)
        .map_err(|e| NightshadeError::ImageError(e.to_string()))?;

    // Mirror the persisted apply flag so `get_status` round-trips the
    // user's preference correctly.
    {
        let mut flags = defect_apply_flags().lock().await;
        flags.insert(camera_id.clone(), true);
    }

    let state = nightshade_sequencer::DefectMapApplyState {
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
) -> Result<Option<ApiDefectMapStatus>, NightshadeError> {
    if camera_id.trim().is_empty() {
        return Err(NightshadeError::InvalidParameter(
            "camera_id is empty".to_string(),
        ));
    }
    let bucket = nightshade_imaging::defect_map::bucket_temperature(sensor_temperature_celsius);
    let path = defect_map_path(&camera_id, width, height, bucket);
    if !path.exists() {
        return Ok(None);
    }
    let map = nightshade_imaging::defect_map::DefectMap::read_from_file(&path)
        .map_err(|e| NightshadeError::ImageError(e.to_string()))?;
    let metadata = std::fs::metadata(&path).map_err(|e| {
        NightshadeError::ImageError(format!(
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

#[cfg(test)]
mod unified_image_storage_tests;

// Image grading: round-trip test for the rich-header save path.

#[cfg(test)]
mod rich_header_tests;

// Master calibration frame combination
//
// Why this lives here: master-frame combine is a sibling of the existing
// `api_calibrate_image_*` and `api_defect_map_build` entry points — both
// operate on a list of FITS/XISF inputs and write a single calibration
// product to disk. Dart-side `dark_library_service.dart::_medianCombine`
// is the legacy isolate path we are superseding; new code (and the OTA
// flat / bias library that will follow) calls these instead.

/// Combine method exposed across the FFI surface.
///
/// Dart sends a tag string ("MEAN", "MEDIAN", "SIGMA_CLIP") with optional
/// sigma parameters. We deliberately use a flat struct rather than a
/// tagged enum here because flutter_rust_bridge handles plain structs
/// with optional fields cleanly across both Dart isolates and the new
/// codec path.
pub struct ApiCombineMethod {
    /// "MEAN" | "MEDIAN" | "SIGMA_CLIP" (case-insensitive)
    pub method: String,
    /// Kappa threshold for sigma clip; required for SIGMA_CLIP, ignored otherwise.
    pub sigma_kappa: Option<f64>,
    /// Number of clip iterations; required for SIGMA_CLIP, ignored otherwise.
    pub sigma_iterations: Option<u32>,
}

/// Result returned from a master-frame build.
pub struct ApiMasterFrameResult {
    /// Where the master FITS was written.
    pub output_path: String,
    /// "BIAS" | "DARK" | "FLAT"
    pub kind: String,
    /// "U16" | "F32"
    pub output_type: String,
    /// How many input frames contributed.
    pub frame_count: u32,
    /// String rendering of the combine method actually used.
    pub method: String,
    /// Width of the resulting master in pixels.
    pub width: u32,
    /// Height of the resulting master in pixels.
    pub height: u32,
    /// Channel count of the resulting master.
    pub channels: u32,
    /// Pre-normalisation mean of the combined master.
    pub input_mean: f64,
    /// Post-normalisation mean (equals `input_mean` for bias/dark, 1.0 / 32768 for flat).
    pub output_mean: f64,
}

fn parse_master_kind(
    s: &str,
) -> Result<nightshade_imaging::stacking::MasterFrameKind, NightshadeError> {
    match s.trim().to_ascii_uppercase().as_str() {
        "BIAS" => Ok(nightshade_imaging::stacking::MasterFrameKind::Bias),
        "DARK" => Ok(nightshade_imaging::stacking::MasterFrameKind::Dark),
        "FLAT" => Ok(nightshade_imaging::stacking::MasterFrameKind::Flat),
        other => Err(NightshadeError::InvalidParameter(format!(
            "unknown master frame kind '{}': expected BIAS, DARK, or FLAT",
            other
        ))),
    }
}

fn parse_output_type(
    s: &str,
) -> Result<nightshade_imaging::stacking::MasterOutputType, NightshadeError> {
    match s.trim().to_ascii_uppercase().as_str() {
        "U16" => Ok(nightshade_imaging::stacking::MasterOutputType::U16),
        "F32" => Ok(nightshade_imaging::stacking::MasterOutputType::F32),
        other => Err(NightshadeError::InvalidParameter(format!(
            "unknown master output type '{}': expected U16 or F32",
            other
        ))),
    }
}

fn parse_combine_method(
    m: &ApiCombineMethod,
) -> Result<nightshade_imaging::stacking::CombineMethod, NightshadeError> {
    use nightshade_imaging::stacking::CombineMethod;
    match m.method.trim().to_ascii_uppercase().as_str() {
        "MEAN" => Ok(CombineMethod::Mean),
        "MEDIAN" => Ok(CombineMethod::Median),
        "SIGMA_CLIP" | "SIGMACLIP" => {
            let kappa = m.sigma_kappa.ok_or_else(|| {
                NightshadeError::InvalidParameter("SIGMA_CLIP requires sigma_kappa".to_string())
            })?;
            let iterations = m.sigma_iterations.ok_or_else(|| {
                NightshadeError::InvalidParameter(
                    "SIGMA_CLIP requires sigma_iterations".to_string(),
                )
            })?;
            Ok(CombineMethod::SigmaClip { kappa, iterations })
        }
        other => Err(NightshadeError::InvalidParameter(format!(
            "unknown combine method '{}': expected MEAN, MEDIAN, or SIGMA_CLIP",
            other
        ))),
    }
}

/// Combine a set of calibration frames into a single master and write it
/// to disk as FITS.
///
/// Inputs:
/// - `input_paths`: paths to each constituent calibration frame. All must
///   exist, share dimensions/channels/pixel type, and be readable by the
///   normal Nightshade image reader (FITS/XISF/PNG/TIFF/etc).
/// - `kind`: "BIAS" | "DARK" | "FLAT" — controls normalisation (flats only).
/// - `method`: combine algorithm + parameters; see `ApiCombineMethod`.
/// - `output_type`: "U16" | "F32" — pixel type of the produced master.
/// - `output_path`: where to write the FITS master.
///
/// Errors:
/// - Empty input list, mismatched dimensions/channels/pixel types, or any
///   read failure surfaces as `NightshadeError::ImageError`/`InvalidParameter`.
///   No silent fallback to a partial result.
pub async fn api_combine_master_frames(
    input_paths: Vec<String>,
    kind: String,
    method: ApiCombineMethod,
    output_type: String,
    output_path: String,
) -> Result<ApiMasterFrameResult, NightshadeError> {
    if input_paths.is_empty() {
        return Err(NightshadeError::InvalidParameter(
            "api_combine_master_frames: input_paths is empty".to_string(),
        ));
    }
    if output_path.trim().is_empty() {
        return Err(NightshadeError::InvalidParameter(
            "api_combine_master_frames: output_path is empty".to_string(),
        ));
    }

    let kind_enum = parse_master_kind(&kind)?;
    let method_enum = parse_combine_method(&method)?;
    let output_type_enum = parse_output_type(&output_type)?;

    // Frame I/O and the combine itself run on a blocking pool — they are
    // CPU-bound and allocate proportional to (frames * pixels), so we keep
    // them off the tokio worker threads. Mirrors `api_defect_map_build`.
    let paths_clone = input_paths.clone();
    let frames: Vec<ImageData> = tokio::task::spawn_blocking(move || {
        let mut out = Vec::with_capacity(paths_clone.len());
        for path in &paths_clone {
            let result = nightshade_imaging::read_image(std::path::Path::new(path))
                .map_err(|e| format!("failed to read {}: {}", path, e))?;
            out.push(result.image);
        }
        Ok::<_, String>(out)
    })
    .await
    .map_err(|e| {
        NightshadeError::ImageError(format!("join error reading master frame inputs: {}", e))
    })?
    .map_err(NightshadeError::ImageError)?;

    let combine_kind = kind_enum;
    let combine_method = method_enum;
    let combine_output_type = output_type_enum;
    let master = tokio::task::spawn_blocking(move || {
        nightshade_imaging::stacking::combine_master_frames(
            &frames,
            combine_kind,
            combine_method,
            combine_output_type,
        )
    })
    .await
    .map_err(|e| NightshadeError::ImageError(format!("join error combining frames: {}", e)))?
    .map_err(NightshadeError::ImageError)?;

    // Write the master as FITS with rich provenance so downstream tooling
    // (and humans inspecting the file) know exactly how it was produced.
    let out_path = std::path::PathBuf::from(&output_path);
    if let Some(parent) = out_path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent).map_err(|e| {
                NightshadeError::ImageError(format!(
                    "failed to create output directory {}: {}",
                    parent.display(),
                    e
                ))
            })?;
        }
    }

    let mut header = FitsHeader::new();
    let kind_str = master.kind.as_str();
    header.set_string("IMAGETYP", kind_str);
    header.set_string("FRAMETYP", "MASTER");
    header.set_string("CALSTAT", &format!("Nightshade master {}", kind_str));
    header.set_int("NFRAMES", master.frame_count as i64);
    header.set_string("COMBMETH", &master.method.as_str());
    header.set_string(
        "MASTRTYP",
        match master.output_type {
            nightshade_imaging::stacking::MasterOutputType::U16 => "U16",
            nightshade_imaging::stacking::MasterOutputType::F32 => "F32",
        },
    );
    // FITS keywords are capped at 8 chars (see `fits::is_valid_keyword`).
    header.set_float("INMEAN", master.input_mean);
    header.set_float("OUTMEAN", master.output_mean);

    let master_image_for_write = master.image.clone();
    let out_path_for_write = out_path.clone();
    tokio::task::spawn_blocking(move || {
        write_fits(&out_path_for_write, &master_image_for_write, &header).map_err(|e| {
            format!(
                "failed to write master FITS {}: {:?}",
                out_path_for_write.display(),
                e
            )
        })
    })
    .await
    .map_err(|e| NightshadeError::ImageError(format!("join error writing master: {}", e)))?
    .map_err(NightshadeError::ImageError)?;

    tracing::info!(
        "Wrote master {} ({} frames, {}) to {}",
        kind_str,
        master.frame_count,
        master.method.as_str(),
        output_path
    );

    Ok(ApiMasterFrameResult {
        output_path,
        kind: kind_str.to_string(),
        output_type: match master.output_type {
            nightshade_imaging::stacking::MasterOutputType::U16 => "U16".to_string(),
            nightshade_imaging::stacking::MasterOutputType::F32 => "F32".to_string(),
        },
        frame_count: master.frame_count,
        method: master.method.as_str(),
        width: master.image.width,
        height: master.image.height,
        channels: master.image.channels,
        input_mean: master.input_mean,
        output_mean: master.output_mean,
    })
}

// FITS keyword update round-trip test

#[cfg(test)]
mod exposure_failure_classification_tests;

#[cfg(test)]
mod fits_keyword_update_tests;

#[cfg(test)]
mod sim_exposure_tests;

#[cfg(test)]
mod auto_stretch_color_tests;

#[cfg(test)]
mod display_diagnostic_tests;

#[cfg(test)]
mod calibrate_header_carry_over_tests;

#[cfg(test)]
mod frame_stats_tests;

#[cfg(test)]
mod fits_thumbnail_tests;
