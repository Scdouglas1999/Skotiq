//! ASCOM camera STA-thread wrapper.
//!
//! # `as`-cast policy
//!
//! Numeric casts in this file cluster into three patterns; sites with a
//! local `Why:` comment override the module-level reasoning.
//!
//! 1. **Sensor-dimension i32 → u32 after `> 0` guard** (lines 297, 314,
//!    482, 493, 531, 532). The ASCOM ICameraV3/V4 spec defines CameraXSize,
//!    CameraYSize and the SAFEARRAY dims as `int` (i32); a positive value
//!    fits trivially in u32. Negative or zero returns are surfaced as
//!    explicit `Err` immediately above each cast, not silently wrapped.
//! 2. **Subframe i32 ↔ u32** (lines 581-592). The pre-check on lines
//!    581-583 guarantees `start + width ≤ max` (i32 sums), making the
//!    subsequent u32 → i32 narrowing SAFE because each sensor dimension is
//!    already i32-bounded by the same driver.
//! 3. **Display-only widening** (line 55, line 850 readout-mode index).
//!    Progress percent and readout-mode index are bounded to small ranges
//!    by construction (percent ≤ 100; readout modes ≤ ~10).
//!
//! Two truncation-risk sites have explicit hardening:
//! - Line 517: ASCOM image_array() returns i32 SAFEARRAY samples; we
//!   `clamp(0, 65535)` before `as u16` — that bounds the cast.
//! - Line 829: bit-depth shift uses u64 intermediate then narrows to u32
//!   after the `bit_depth >= 32` early-return ceiling.
//!
//! # `unwrap_or` policy
//!
//! ASCOM is a Win32 COM protocol where many `ICameraV3` / `ICameraV4`
//! properties are **optional** (the spec lets a driver throw
//! `PropertyNotImplemented` rather than implement them). The `skotiq_ascom`
//! crate surfaces those properties as `Result<T, AscomError>`. Where this
//! wrapper composes them into the cross-driver `CameraCapabilities` /
//! `CameraStatus` structs we substitute a *baseline value* defined by the
//! ASCOM Platform 7 conformance guide:
//!
//! * boolean Can*/Has* probes → `unwrap_or(false)` — "the driver did not
//!   declare support, treat as not-supported"
//! * integer dimensions (`camera_x_size`, `camera_y_size`, `max_bin_*`,
//!   `gain`, `offset`, `bin_x/y`) → `unwrap_or(1)` — the ASCOM minimum
//!   meaningful value (1×1 binning, single-pixel sensor); never zero so
//!   downstream image-math never divides by zero.
//! * `state` integer → `unwrap_or(0)` — `cameraIdle` (CameraStates enum).
//! * floats (`pixel_size_x/y`, exposure remaining) → `unwrap_or(0.0)` —
//!   "unknown to UI" rendering.
//! * `readout_modes()` / `supported_actions()` `Vec<String>` →
//!   `unwrap_or_default()` — empty list = driver did not expose the
//!   optional list, UI shows "no choice" picker.
//!
//! These are NOT silent error fallbacks for hard failures: connection
//! errors are propagated via `Result<_, String>` from the worker channel
//! at the call-site; the optional-property fallbacks here only run after
//! the wrapper has already classified the error as "property absent".
use crate::ascom_wrapper::sta_worker::{register_device, PumpOutcome};
use crate::timeout_ops::Timeouts;
use skotiq_ascom::AscomCamera;
use skotiq_native::camera::{
    BayerPattern, CameraCapabilities, CameraState, CameraStatus, ExposureParams, ImageData,
    ReadoutMode, SensorInfo, SubFrame, VendorFeatures,
};
use skotiq_native::traits::{NativeCamera, NativeDevice, NativeError};
use skotiq_native::NativeVendor;
use std::fmt::Debug;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::RwLock;
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};

use crate::ascom_exposure_apply::ExposureApplyTarget;

/// bridge the real ASCOM COM camera to the platform-independent
/// exposure-parameter apply function. Each method forwards to the matching
/// ICameraV3 property setter/getter on the underlying COM object.
impl ExposureApplyTarget for AscomCamera {
    fn max_bin_x(&self) -> Result<i32, String> {
        AscomCamera::max_bin_x(self)
    }
    fn max_bin_y(&self) -> Result<i32, String> {
        AscomCamera::max_bin_y(self)
    }
    fn camera_x_size(&self) -> Result<i32, String> {
        AscomCamera::camera_x_size(self)
    }
    fn camera_y_size(&self) -> Result<i32, String> {
        AscomCamera::camera_y_size(self)
    }
    fn set_bin_x(&mut self, value: i32) -> Result<(), String> {
        AscomCamera::set_bin_x(self, value)
    }
    fn set_bin_y(&mut self, value: i32) -> Result<(), String> {
        AscomCamera::set_bin_y(self, value)
    }
    fn set_start_x(&mut self, value: i32) -> Result<(), String> {
        AscomCamera::set_start_x(self, value)
    }
    fn set_start_y(&mut self, value: i32) -> Result<(), String> {
        AscomCamera::set_start_y(self, value)
    }
    fn set_num_x(&mut self, value: i32) -> Result<(), String> {
        AscomCamera::set_num_x(self, value)
    }
    fn set_num_y(&mut self, value: i32) -> Result<(), String> {
        AscomCamera::set_num_y(self, value)
    }
    fn set_gain(&mut self, value: i32) -> Result<(), String> {
        AscomCamera::set_gain(self, value)
    }
    fn set_offset(&mut self, value: i32) -> Result<(), String> {
        AscomCamera::set_offset(self, value)
    }
}

/// Compute remaining exposure time from ASCOM `PercentCompleted` (0..=100)
/// and the total exposure duration we tracked at `StartExposure` time.
///
/// Why: ASCOM does not expose a "seconds remaining" property; per ICameraV3
/// the only progress signal is `PercentCompleted`. Both inputs must be
/// present and `pct` must be in range — anything else maps to `None` so
/// the UI can render "unknown" rather than a fabricated value.
fn compute_exposure_remaining(
    percent_completed: Option<i32>,
    total_secs: Option<f64>,
) -> Option<f64> {
    match (percent_completed, total_secs) {
        (Some(pct), Some(total)) if (0..=100).contains(&pct) && total >= 0.0 => {
            let remaining = ((100 - pct) as f64 / 100.0) * total;
            // Why: floating point can produce tiny negatives near the end of
            // the exposure; clamp at zero rather than surfacing -0.0001.
            Some(remaining.max(0.0))
        }
        _ => None,
    }
}

/// True when an ASCOM error is the driver stating a member does not exist,
/// as opposed to failing to answer for it.
///
/// `OwnedExcepInfo::describe` renders the driver's `scode` as `0x%08X`, so the
/// code is carried in the error text. `0x80040400` is ASCOM's `NotImplemented`
/// (what `PropertyNotImplementedException` sets) and `0x80004001` is COM's
/// `E_NOTIMPL`; both are permanent facts about the interface. Every other
/// failure — disconnect, RPC fault, STA pump timeout — is transport and says
/// nothing about the capability.
fn is_not_implemented_error(err: &str) -> bool {
    err.contains("0x80040400") || err.contains("0x80004001")
}

/// Try-once-cache lookup for an ASCOM "Can*" capability that the driver
/// does not expose declaratively. Probes via `probe()` only until the answer
/// is known; subsequent calls return the cached result.
///
/// The probe costs a COM round-trip, so its answer is cached — but only when
/// the driver actually reported the property as unsupported. A transport
/// failure leaves the cache unset so the next capability query re-probes:
/// caching `false` on a blip would strip cooler telemetry from a cooled camera
/// for the life of the connection, with nothing to re-probe it. Until the
/// answer is known the capability reads `false`, which understates rather than
/// fabricates. The cache is reset on disconnect, so a reconnect re-probes.
fn cooler_power_supported(
    cache: &mut Option<bool>,
    probe: impl FnOnce() -> Result<f64, String>,
) -> bool {
    if let Some(v) = *cache {
        return v;
    }
    match probe() {
        Ok(_) => {
            *cache = Some(true);
            true
        }
        Err(e) if is_not_implemented_error(&e) => {
            *cache = Some(false);
            false
        }
        Err(e) => {
            tracing::warn!(
                "ASCOM CoolerPower probe failed without a NotImplemented code ({}); \
                 leaving CanGetCoolerPower unresolved so the next capability query re-probes",
                e
            );
            false
        }
    }
}

/// The FITS `BAYERPAT` spelling of the element order named by ASCOM
/// `SensorType` plus the `BayerOffsetX`/`BayerOffsetY` pair.
///
/// The mapping itself lives in [`crate::ascom_sensor_type`], shared with the
/// Alpaca download path so both ASCOM transports read the same enum the same
/// way; this adapter only renders it as the `String` the capabilities struct
/// carries. `None` means the pattern is unknown, which leaves the frame
/// undebayered rather than debayered wrongly.
fn bayer_pattern_from_sensor(
    sensor_type: i32,
    offset_x: Option<i32>,
    offset_y: Option<i32>,
) -> Option<String> {
    crate::ascom_sensor_type::bayer_pattern_from_sensor(sensor_type, offset_x, offset_y)
        .map(|pattern| crate::ascom_sensor_type::bayer_pattern_fits_name(pattern).to_string())
}

/// Connection health status for ASCOM devices
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CameraConnectionHealth {
    /// Device is healthy and responding
    Healthy,
    /// Device is not responding but may recover
    Degraded,
    /// Device connection has failed
    Failed,
    /// Device health is unknown
    Unknown,
}

/// ASCOM camera capabilities returned from the device
#[derive(Debug, Clone, Default)]
pub struct AscomCameraCapabilities {
    pub max_width: u32,
    pub max_height: u32,
    /// ADC resolution BUCKET (8/16/32) inferred from `MaxADU`. Precision only —
    /// never a full-scale divisor. Use [`AscomCameraCapabilities::max_adu`].
    pub bit_depth: u32,
    /// ASCOM `ICameraV3.MaxADU` verbatim: the largest value the driver can put in
    /// a pixel. This is the pixel-container full scale and the only field that
    /// may be used to scale percentages / saturation. Reconstructing it from
    /// `bit_depth` as `2^bit_depth - 1` is wrong in both directions: 65535 for a
    /// driver honestly reporting 4095, and see `SensorInfo::max_adu` for the
    /// left-justified case.
    pub max_adu: u32,
    pub has_shutter: bool,
    pub can_set_ccd_temperature: bool,
    pub can_get_cooler_power: bool,
    pub can_bin: bool,
    pub max_bin_x: i32,
    pub max_bin_y: i32,
    pub can_abort_exposure: bool,
    pub can_stop_exposure: bool,
    pub can_set_gain: bool,
    pub can_set_offset: bool,
    pub pixel_size_x: Option<f64>,
    pub pixel_size_y: Option<f64>,
    pub is_color: bool,
    pub bayer_pattern: Option<String>,
    pub sensor_name: Option<String>,
    pub readout_modes: Vec<String>,
}

/// Command sent to the ASCOM worker thread
enum AscomCommand {
    Connect(oneshot::Sender<Result<(), String>>),
    SetupDialog(oneshot::Sender<Result<(), String>>),
    Disconnect(oneshot::Sender<Result<(), String>>),
    GetStatus(oneshot::Sender<Result<CameraStatus, String>>),
    GetCapabilities(oneshot::Sender<Result<AscomCameraCapabilities, String>>),
    StartExposure(ExposureParams, oneshot::Sender<Result<(), String>>),
    AbortExposure(oneshot::Sender<Result<(), String>>),
    IsExposureComplete(oneshot::Sender<Result<bool, String>>),
    DownloadImage(oneshot::Sender<Result<ImageData, String>>),
    SetSubframe(Option<SubFrame>, oneshot::Sender<Result<(), String>>),
    SetBinning(i32, i32, oneshot::Sender<Result<(), String>>),
    SetGain(i32, oneshot::Sender<Result<(), String>>),
    SetOffset(i32, oneshot::Sender<Result<(), String>>),
    SetReadoutMode(i32, oneshot::Sender<Result<(), String>>),
    SetCooler(bool, Option<f64>, oneshot::Sender<Result<(), String>>),
    /// Heartbeat check to verify device is still responding
    Heartbeat(oneshot::Sender<Result<CameraConnectionHealth, String>>),
    /// Get interface version number
    GetInterfaceVersion(oneshot::Sender<Result<i32, String>>),
    /// Get driver version string
    GetDriverVersion(oneshot::Sender<Result<String, String>>),
    /// Get driver info string
    GetDriverInfo(oneshot::Sender<Result<String, String>>),
    /// Get list of supported actions
    GetSupportedActions(oneshot::Sender<Result<Vec<String>, String>>),
    Stop(oneshot::Sender<Result<(), String>>),
}

/// Wrapper for ASCOM Camera whose COM object lives on the shared STA worker.
#[derive(Debug)]
pub struct AscomCameraWrapper {
    id: String,
    name: String,
    sender: mpsc::Sender<AscomCommand>,
    connected: AtomicBool,
    cached_capabilities: RwLock<CameraCapabilities>,
    cached_sensor_info: RwLock<SensorInfo>,
    cached_readout_modes: RwLock<Vec<ReadoutMode>>,
}

impl AscomCameraWrapper {
    pub fn new(prog_id: String) -> Result<Self, String> {
        let (tx, mut rx) = mpsc::channel(32);
        let prog_id_clone = prog_id.clone();

        // Build the COM object and its command pump on the process-wide STA
        // apartment. The per-command match arms below are unchanged from the
        // legacy per-device worker; only the loop shell and teardown differ.
        register_device(move || {
            let mut camera: Option<AscomCamera> = None;

            // Try to create the camera object immediately
            match AscomCamera::new(&prog_id_clone) {
                Ok(cam) => camera = Some(cam),
                Err(e) => tracing::error!("Failed to create ASCOM camera {}: {}", prog_id_clone, e),
            }

            // Track the last set temperature setpoint (ASCOM SetCCDTemperature is write-only)
            let mut last_target_temp: Option<f64> = None;
            // Why: ASCOM has no "last commanded exposure duration" property.
            // We capture it at StartExposure time so that GetStatus can convert
            // `PercentCompleted` (0..100) into a wall-clock seconds-remaining
            // value. Cleared on abort/stop/disconnect.
            let mut last_exposure_duration: Option<f64> = None;
            // Try-once-cache for the `CanGetCoolerPower` capability.
            // `None` = not yet resolved; `Some(_)` = cached result.
            let mut cooler_power_cache: Option<bool> = None;

            Ok(Box::new(move || {
                use tokio::sync::mpsc::error::TryRecvError;
                let cmd = match rx.try_recv() {
                    Ok(cmd) => cmd,
                    Err(TryRecvError::Empty) => return PumpOutcome::Idle,
                    Err(TryRecvError::Disconnected) => {
                        // Why: COM apartment teardown ordering matters. Release
                        // the typed `AscomCamera` (whose `IDispatch` Drop runs on
                        // this STA worker thread) by issuing an explicit
                        // disconnect here as a last-resort safety net — the COM
                        // object is then released when this closure is dropped,
                        // still on this thread. `AscomDeviceConnection::Drop` is
                        // intentionally a no-op to avoid wrong-thread COM calls,
                        // so this is the only correct location for the final
                        // disconnect. The apartment persists for the process
                        // lifetime, so COM is NOT uninitialized here.
                        if let Some(mut cam) = camera.take() {
                            if let Err(e) = cam.disconnect() {
                                tracing::warn!(
                                    "ASCOM camera STA-worker shutdown disconnect failed: {}",
                                    e
                                );
                            }
                            drop(cam);
                        }
                        return PumpOutcome::Finished;
                    }
                };
                match cmd {
                    AscomCommand::Connect(reply) => {
                        if let Some(cam) = &mut camera {
                            let _ = reply.send(cam.connect().map_err(|e| e.to_string()));
                        } else {
                            let _ = reply.send(Err("Camera not created".to_string()));
                        }
                    }
                    AscomCommand::SetupDialog(reply) => {
                        if let Some(cam) = &mut camera {
                            let _ = reply.send(cam.setup_dialog().map_err(|e| e.to_string()));
                        } else {
                            let _ = reply.send(Err("Camera not created".to_string()));
                        }
                    }
                    AscomCommand::Disconnect(reply) => {
                        if let Some(cam) = &mut camera {
                            // Why: a reconnect may target a different driver instance
                            // (e.g. user picked another camera in SetupDialog), so the
                            // cached `CanGetCoolerPower` probe and the in-flight
                            // exposure tracking must be invalidated here.
                            cooler_power_cache = None;
                            last_exposure_duration = None;
                            let _ = reply.send(cam.disconnect().map_err(|e| e.to_string()));
                        } else {
                            let _ = reply.send(Err("Camera not created".to_string()));
                        }
                    }
                    AscomCommand::GetStatus(reply) => {
                        if let Some(cam) = &camera {
                            // Use batch query for efficiency - fewer COM calls
                            let full_status = cam.get_full_status();

                            // Map ASCOM camera state to our CameraState enum
                            let state = match full_status.state.unwrap_or(0) {
                                0 => CameraState::Idle,
                                1 => CameraState::Idle, // Waiting maps to Idle
                                2 => CameraState::Exposing,
                                3 => CameraState::Reading,
                                4 => CameraState::Downloading,
                                5 => CameraState::Error,
                                _ => CameraState::Idle,
                            };

                            // Log thermal status if available
                            if let Some(temp) = full_status.thermal.temperature {
                                tracing::debug!("ASCOM camera temperature: {}C", temp);
                            }
                            if let Some(power) = full_status.thermal.cooler_power {
                                tracing::debug!("ASCOM cooler power: {}%", power);
                            }

                            // Use tracked target temp (ASCOM SetCCDTemperature is write-only)
                            let target_temp =
                                if full_status.thermal.can_set_temperature.unwrap_or(false) {
                                    last_target_temp
                                } else {
                                    None
                                };

                            // ASCOM `PercentCompleted` is only valid while
                            // CameraState is in {Exposing, Reading, Downloading}; outside
                            // that window we treat it (and exposure_remaining) as None
                            // rather than fabricating a stale residual.
                            let exposure_remaining = match state {
                                CameraState::Exposing
                                | CameraState::Reading
                                | CameraState::Downloading => compute_exposure_remaining(
                                    full_status.percent_completed,
                                    last_exposure_duration,
                                ),
                                _ => None,
                            };

                            let status = CameraStatus {
                                state,
                                sensor_temp: full_status.thermal.temperature,
                                cooler_power: full_status.thermal.cooler_power,
                                target_temp,
                                cooler_on: full_status.thermal.cooler_on.unwrap_or(false),
                                gain: full_status.exposure_settings.gain.unwrap_or(0),
                                offset: full_status.exposure_settings.offset.unwrap_or(0),
                                bin_x: full_status.exposure_settings.bin_x.unwrap_or(1),
                                bin_y: full_status.exposure_settings.bin_y.unwrap_or(1),
                                exposure_remaining,
                            };
                            let _ = reply.send(Ok(status));
                        } else {
                            let _ = reply.send(Err("Camera not created".to_string()));
                        }
                    }
                    AscomCommand::GetCapabilities(reply) => {
                        if let Some(cam) = &camera {
                            // Sensor width/height and bit-depth are load-bearing
                            // for every downstream image operation (FITS header, debayer,
                            // calibration). A transient COM failure must propagate as Err
                            // rather than fabricating a 1x1 sensor or a wrong bit-depth.
                            let sensor_config = cam.get_sensor_config();
                            let width = match sensor_config.width {
                                Some(w) if w > 0 => w as u32,
                                Some(w) => {
                                    let _ = reply.send(Err(format!(
                                        "ASCOM camera reported invalid CameraXSize={}",
                                        w
                                    )));
                                    return PumpOutcome::DidWork;
                                }
                                None => {
                                    let _ =
                                        reply
                                            .send(Err("ASCOM camera CameraXSize property failed"
                                                .to_string()));
                                    return PumpOutcome::DidWork;
                                }
                            };
                            let height = match sensor_config.height {
                                Some(h) if h > 0 => h as u32,
                                Some(h) => {
                                    let _ = reply.send(Err(format!(
                                        "ASCOM camera reported invalid CameraYSize={}",
                                        h
                                    )));
                                    return PumpOutcome::DidWork;
                                }
                                None => {
                                    let _ =
                                        reply
                                            .send(Err("ASCOM camera CameraYSize property failed"
                                                .to_string()));
                                    return PumpOutcome::DidWork;
                                }
                            };

                            // Bit-depth derives from `MaxADU` and feeds image
                            // scaling on every frame; a heuristic default of 65535 silently
                            // produces wrong output for 8-bit or 32-bit sensors. Propagate.
                            let max_adu = match cam.max_adu() {
                                Ok(v) => v,
                                Err(e) => {
                                    let _ = reply.send(Err(format!(
                                        "ASCOM camera MaxADU property failed: {}",
                                        e
                                    )));
                                    return PumpOutcome::DidWork;
                                }
                            };
                            let bit_depth = if max_adu > 65535 {
                                32
                            } else if max_adu > 255 {
                                16
                            } else {
                                8
                            };

                            // Colour and Bayer order are independent answers: a
                            // direct-colour sensor (SensorType 1) is colour with no
                            // BAYERPAT at all. An unreadable SensorType reads
                            // monochrome, because debayering a mono frame is a
                            // no-op while a wrong debayer is not.
                            let sensor_type = sensor_config.sensor_type.unwrap_or(0);
                            let is_color = crate::ascom_sensor_type::is_colour_sensor(sensor_type);

                            let bayer_pattern = bayer_pattern_from_sensor(
                                sensor_type,
                                sensor_config.bayer_offset_x,
                                sensor_config.bayer_offset_y,
                            );

                            // A colour sensor with no nameable Bayer order is left
                            // undebayered and writes no BAYERPAT card — correct for the
                            // direct-colour and CMYG families, but silent for a Bayer OSC
                            // whose driver misreports its SensorType as 1 now the OSC gate
                            // keys on SensorType==2. This read happens once per connect, so
                            // naming it here is the one place it can be surfaced without a
                            // per-frame flood; the capabilities carry the same fact to the
                            // app in structured form — `is_color` true beside a null
                            // `bayer_pattern`. The reason itself is derived (and tested) in
                            // the shared, always-compiled sensor-type module.
                            if let Some(reason) =
                                crate::ascom_sensor_type::debayer_skip_reason(sensor_type)
                            {
                                tracing::warn!("ASCOM camera reports a {}", reason);
                            }

                            // Why: ReadoutModes is optional in ASCOM ICameraV3; an Err here
                            // (typically NotImplementedException) just means the driver does
                            // not advertise readout modes. Treating absence as empty list is
                            // semantically correct, not a silent fallback.
                            let readout_modes = cam.readout_modes().unwrap_or_default();
                            let exposure_settings = cam.get_exposure_settings();

                            // Try-once-cache the CanGetCoolerPower probe.
                            let can_get_cooler_power =
                                cooler_power_supported(&mut cooler_power_cache, || {
                                    cam.cooler_power()
                                });

                            let caps = AscomCameraCapabilities {
                                max_width: width,
                                max_height: height,
                                bit_depth,
                                // Carry the driver's MaxADU through instead of
                                // dropping it after the bit-depth bucketing above.
                                max_adu: u32::try_from(max_adu).unwrap_or(65535),
                                has_shutter: cam.has_shutter().unwrap_or(false),
                                can_set_ccd_temperature: cam
                                    .can_set_ccd_temperature()
                                    .unwrap_or(false),
                                can_get_cooler_power,
                                can_bin: sensor_config.max_bin_x.unwrap_or(1) > 1,
                                max_bin_x: sensor_config.max_bin_x.unwrap_or(1),
                                max_bin_y: sensor_config.max_bin_y.unwrap_or(1),
                                can_abort_exposure: cam.can_abort_exposure().unwrap_or(false),
                                can_stop_exposure: cam.can_stop_exposure().unwrap_or(false),
                                can_set_gain: exposure_settings.gain.is_some(),
                                can_set_offset: exposure_settings.offset.is_some(),
                                pixel_size_x: sensor_config.pixel_size_x,
                                pixel_size_y: sensor_config.pixel_size_y,
                                is_color,
                                bayer_pattern,
                                sensor_name: cam.sensor_name().ok(),
                                readout_modes,
                            };
                            let _ = reply.send(Ok(caps));
                        } else {
                            let _ = reply.send(Err("Camera not created".to_string()));
                        }
                    }
                    AscomCommand::StartExposure(params, reply) => {
                        tracing::info!(
                            "ASCOM: StartExposure called with duration={} bin={}x{} gain={:?} offset={:?}",
                            params.duration_secs,
                            params.bin_x,
                            params.bin_y,
                            params.gain,
                            params.offset
                        );
                        if let Some(cam) = &mut camera {
                            // Apply the per-frame acquisition parameters BEFORE
                            // exposing, or the frame is shot at the camera's
                            // current settings — a silent mis-acquisition on any
                            // per-filter-gain or binned night. Order matters on
                            // ASCOM: binning must be set before frame geometry
                            // because NumX/NumY are in *binned* pixels. Fail
                            // closed on any setter error.
                            //
                            // The apply logic lives in the platform-independent
                            // `ascom_exposure_apply` module so it is regression-
                            // tested on every platform (this worker only compiles
                            // on Windows).
                            let apply_result = crate::ascom_exposure_apply::apply_exposure_params(
                                cam,
                                params.bin_x,
                                params.bin_y,
                                params.gain,
                                params.offset,
                                &params.subframe,
                            );
                            if let Err(e) = apply_result {
                                tracing::error!("ASCOM: failed to apply exposure params: {}", e);
                                let _ = reply.send(Err(format!(
                                    "Failed to apply exposure parameters: {}",
                                    e
                                )));
                                return PumpOutcome::DidWork;
                            }
                            tracing::info!(
                                "ASCOM: Calling cam.start_exposure({}, true)",
                                params.duration_secs
                            );
                            match cam.start_exposure(params.duration_secs, true) {
                                Ok(_) => {
                                    tracing::info!("ASCOM: start_exposure succeeded");
                                    // Capture the commanded duration so
                                    // GetStatus can convert ASCOM `PercentCompleted`
                                    // into a wall-clock seconds-remaining figure.
                                    last_exposure_duration = Some(params.duration_secs);
                                    let _ = reply.send(Ok(()));
                                }
                                Err(e) => {
                                    tracing::error!("ASCOM: start_exposure failed: {}", e);
                                    let _ =
                                        reply.send(Err(format!("Failed to start exposure: {}", e)));
                                }
                            }
                        } else {
                            tracing::error!("ASCOM: Camera not created");
                            let _ = reply.send(Err("Camera not created".to_string()));
                        }
                    }
                    AscomCommand::AbortExposure(reply) => {
                        tracing::info!("ASCOM: AbortExposure called");
                        if let Some(cam) = &mut camera {
                            let result = cam
                                .abort_exposure()
                                .map_err(|e| format!("Failed to abort exposure: {}", e));
                            // Why: aborted exposure has no defined remaining time;
                            // clearing prevents stale ETA figures on the next status read.
                            if result.is_ok() {
                                last_exposure_duration = None;
                            }
                            let _ = reply.send(result);
                        } else {
                            let _ = reply.send(Err("Camera not created".to_string()));
                        }
                    }
                    AscomCommand::IsExposureComplete(reply) => {
                        if let Some(cam) = &camera {
                            match cam.image_ready() {
                                Ok(ready) => {
                                    tracing::debug!("ASCOM: image_ready() returned {}", ready);
                                    let _ = reply.send(Ok(ready));
                                }
                                Err(e) => {
                                    tracing::error!("ASCOM: image_ready() failed: {}", e);
                                    let _ = reply
                                        .send(Err(format!("Failed to check image ready: {}", e)));
                                }
                            }
                        } else {
                            let _ = reply.send(Err("Camera not created".to_string()));
                        }
                    }
                    AscomCommand::DownloadImage(reply) => {
                        tracing::info!("ASCOM: DownloadImage called");
                        if let Some(cam) = &camera {
                            tracing::info!("ASCOM: Getting camera dimensions");
                            // The dimensions used here are only for the log
                            // line below — the authoritative dimensions come from
                            // `image_array()` itself which returns the SAFEARRAY shape.
                            // Even so, a transient COM error on CameraXSize/YSize must
                            // not silently produce a "1x1" log; propagate as Err so the
                            // bridge dispatch marks the device Disconnected rather than
                            // pretending the image download will succeed.
                            let width = match cam.camera_x_size() {
                                Ok(v) => v as u32,
                                Err(e) => {
                                    let _ = reply.send(Err(format!(
                                        "ASCOM camera CameraXSize failed: {}",
                                        e
                                    )));
                                    last_exposure_duration = None;
                                    return PumpOutcome::DidWork;
                                }
                            };
                            let height = match cam.camera_y_size() {
                                Ok(v) => v as u32,
                                Err(e) => {
                                    let _ = reply.send(Err(format!(
                                        "ASCOM camera CameraYSize failed: {}",
                                        e
                                    )));
                                    last_exposure_duration = None;
                                    return PumpOutcome::DidWork;
                                }
                            };
                            tracing::info!("ASCOM: Camera dimensions: {}x{}", width, height);

                            tracing::info!("ASCOM: Calling cam.image_array()");
                            match cam.image_array() {
                                Ok((data, w, h)) => {
                                    tracing::info!(
                                        "ASCOM: image_array() returned {} pixels ({}x{})",
                                        data.len(),
                                        w,
                                        h
                                    );

                                    // Convert i32 array to u16 array
                                    let u16_data: Vec<u16> =
                                        data.iter().map(|&v| v.max(0).min(65535) as u16).collect();

                                    // Log min/max values for debugging
                                    if let (Some(&min), Some(&max)) =
                                        (data.iter().min(), data.iter().max())
                                    {
                                        tracing::info!(
                                            "ASCOM: Image data range: {} to {}",
                                            min,
                                            max
                                        );
                                    }

                                    let image_data = ImageData {
                                        width: w as u32,
                                        height: h as u32,
                                        data: u16_data,
                                        bits_per_pixel: 16,
                                        bayer_pattern: None, // ASCOM doesn't provide bayer pattern info easily
                                        metadata: skotiq_native::camera::ImageMetadata {
                                            exposure_time: last_exposure_duration.unwrap_or(0.0),
                                            gain: 0,
                                            offset: 0,
                                            bin_x: 1,
                                            bin_y: 1,
                                            temperature: None,
                                            timestamp: chrono::Utc::now(),
                                            subframe: None,
                                            readout_mode: None,
                                            vendor_data: VendorFeatures::default(),
                                        },
                                    };
                                    tracing::info!(
                                        "ASCOM: Sending ImageData with {} pixels",
                                        image_data.data.len()
                                    );
                                    // Once the frame has been delivered the
                                    // tracked duration is no longer the "current" exposure;
                                    // clear it so subsequent GetStatus calls return None
                                    // instead of computing remaining-time from a stale total.
                                    last_exposure_duration = None;
                                    let _ = reply.send(Ok(image_data));
                                }
                                Err(e) => {
                                    tracing::error!("ASCOM: image_array() failed: {}", e);
                                    last_exposure_duration = None;
                                    let _ =
                                        reply.send(Err(format!("Failed to download image: {}", e)));
                                }
                            }
                        } else {
                            tracing::error!("ASCOM: Camera not created");
                            let _ = reply.send(Err("Camera not created".to_string()));
                        }
                    }
                    AscomCommand::SetSubframe(subframe, reply) => {
                        tracing::info!("ASCOM: SetSubframe called");
                        if let Some(cam) = &mut camera {
                            match subframe {
                                Some(sf) => {
                                    // Validate and set ROI
                                    let max_x = cam.camera_x_size().unwrap_or(1);
                                    let max_y = cam.camera_y_size().unwrap_or(1);

                                    if sf.start_x as i32 + sf.width as i32 > max_x
                                        || sf.start_y as i32 + sf.height as i32 > max_y
                                    {
                                        let _ = reply.send(Err(
                                            "Subframe exceeds sensor bounds".to_string()
                                        ));
                                    } else {
                                        let result = cam
                                            .set_start_x(sf.start_x as i32)
                                            .and_then(|_| cam.set_start_y(sf.start_y as i32))
                                            .and_then(|_| cam.set_num_x(sf.width as i32))
                                            .and_then(|_| cam.set_num_y(sf.height as i32))
                                            .map_err(|e| format!("Failed to set subframe: {}", e));
                                        let _ = reply.send(result);
                                    }
                                }
                                None => {
                                    // Reset to full frame
                                    let max_x = cam.camera_x_size().unwrap_or(1);
                                    let max_y = cam.camera_y_size().unwrap_or(1);
                                    let result = cam
                                        .set_start_x(0)
                                        .and_then(|_| cam.set_start_y(0))
                                        .and_then(|_| cam.set_num_x(max_x))
                                        .and_then(|_| cam.set_num_y(max_y))
                                        .map_err(|e| {
                                            format!("Failed to reset to full frame: {}", e)
                                        });
                                    let _ = reply.send(result);
                                }
                            }
                        } else {
                            let _ = reply.send(Err("Camera not created".to_string()));
                        }
                    }
                    AscomCommand::SetBinning(bin_x, bin_y, reply) => {
                        tracing::info!("ASCOM: SetBinning called: {}x{}", bin_x, bin_y);
                        if let Some(cam) = &mut camera {
                            let max_bin_x = cam.max_bin_x().unwrap_or(1);
                            let max_bin_y = cam.max_bin_y().unwrap_or(1);

                            if bin_x > max_bin_x || bin_y > max_bin_y {
                                let _ = reply.send(Err(format!(
                                    "Binning {}x{} exceeds max {}x{}",
                                    bin_x, bin_y, max_bin_x, max_bin_y
                                )));
                            } else {
                                let result = cam
                                    .set_bin_x(bin_x)
                                    .and_then(|_| cam.set_bin_y(bin_y))
                                    .map_err(|e| format!("Failed to set binning: {}", e));
                                let _ = reply.send(result);
                            }
                        } else {
                            let _ = reply.send(Err("Camera not created".to_string()));
                        }
                    }
                    AscomCommand::SetGain(gain, reply) => {
                        tracing::info!("ASCOM: SetGain called: {}", gain);
                        if let Some(cam) = &mut camera {
                            let result = cam
                                .set_gain(gain)
                                .map_err(|e| format!("Failed to set gain: {}", e));
                            let _ = reply.send(result);
                        } else {
                            let _ = reply.send(Err("Camera not created".to_string()));
                        }
                    }
                    AscomCommand::SetOffset(offset, reply) => {
                        tracing::info!("ASCOM: SetOffset called: {}", offset);
                        if let Some(cam) = &mut camera {
                            let result = cam
                                .set_offset(offset)
                                .map_err(|e| format!("Failed to set offset: {}", e));
                            let _ = reply.send(result);
                        } else {
                            let _ = reply.send(Err("Camera not created".to_string()));
                        }
                    }
                    AscomCommand::SetReadoutMode(mode_index, reply) => {
                        tracing::info!("ASCOM: SetReadoutMode called: {}", mode_index);
                        if let Some(cam) = &mut camera {
                            let result = cam
                                .set_readout_mode(mode_index)
                                .map_err(|e| format!("Failed to set readout mode: {}", e));
                            let _ = reply.send(result);
                        } else {
                            let _ = reply.send(Err("Camera not created".to_string()));
                        }
                    }
                    AscomCommand::SetCooler(enabled, target_temp, reply) => {
                        tracing::info!(
                            "ASCOM: SetCooler called: enabled={}, temp={:?}",
                            enabled,
                            target_temp
                        );
                        if let Some(cam) = &mut camera {
                            // Which setpoint (if any) may be written is decided
                            // by `cooler_policy`, not here — see that module for
                            // why an off-command must never carry one. Writing
                            // SetCCDTemperature unconditionally is what made
                            // "turn the cooler off" fail outright on a camera
                            // reporting CanSetCCDTemperature = False.
                            let writable = skotiq_ascom::cooler_policy::setpoint_to_write(
                                enabled,
                                target_temp,
                                cam.can_set_ccd_temperature().ok(),
                            );
                            if target_temp.is_some() && writable.is_none() {
                                tracing::info!(
                                    "ASCOM: skipping SetCCDTemperature write \
                                     (enabled={}, requested={:?}) — the driver does not \
                                     accept a setpoint here",
                                    enabled,
                                    target_temp
                                );
                            }
                            let mut outcome: Result<(), String> = Ok(());
                            if let Some(t) = writable {
                                outcome = cam.set_ccd_temperature(t);
                            }
                            if outcome.is_ok() {
                                outcome = cam.set_cooler_on(enabled);
                            }
                            let result =
                                outcome.map_err(|e| format!("Failed to set cooler: {}", e));
                            if result.is_ok() {
                                if let Some(t) = writable {
                                    // Track the setpoint since ASCOM SetCCDTemperature is write-only
                                    last_target_temp = Some(t);
                                }
                            }
                            let _ = reply.send(result);
                        } else {
                            let _ = reply.send(Err("Camera not created".to_string()));
                        }
                    }
                    AscomCommand::Heartbeat(reply) => {
                        if let Some(cam) = &camera {
                            // Perform heartbeat check and return health status
                            match cam.heartbeat() {
                                Ok(()) => {
                                    let health = cam.get_health();
                                    let status = match health {
                                        skotiq_ascom::ConnectionHealth::Healthy => {
                                            CameraConnectionHealth::Healthy
                                        }
                                        skotiq_ascom::ConnectionHealth::Degraded => {
                                            CameraConnectionHealth::Degraded
                                        }
                                        skotiq_ascom::ConnectionHealth::Failed => {
                                            CameraConnectionHealth::Failed
                                        }
                                        skotiq_ascom::ConnectionHealth::Unknown => {
                                            CameraConnectionHealth::Unknown
                                        }
                                    };
                                    let _ = reply.send(Ok(status));
                                }
                                Err(e) => {
                                    tracing::warn!("ASCOM heartbeat failed: {}", e);
                                    let _ = reply.send(Ok(CameraConnectionHealth::Degraded));
                                }
                            }
                        } else {
                            let _ = reply.send(Err("Camera not created".to_string()));
                        }
                    }
                    AscomCommand::GetInterfaceVersion(reply) => {
                        if let Some(ref camera) = camera {
                            let _ = reply.send(camera.interface_version());
                        } else {
                            let _ = reply.send(Err("Camera not created".to_string()));
                        }
                    }
                    AscomCommand::GetDriverVersion(reply) => {
                        if let Some(ref camera) = camera {
                            let _ = reply.send(camera.driver_version());
                        } else {
                            let _ = reply.send(Err("Camera not created".to_string()));
                        }
                    }
                    AscomCommand::GetDriverInfo(reply) => {
                        if let Some(ref camera) = camera {
                            let _ = reply.send(camera.driver_info());
                        } else {
                            let _ = reply.send(Err("Camera not created".to_string()));
                        }
                    }
                    AscomCommand::GetSupportedActions(reply) => {
                        if let Some(ref camera) = camera {
                            let _ = reply.send(camera.supported_actions());
                        } else {
                            let _ = reply.send(Err("Camera not created".to_string()));
                        }
                    }
                    AscomCommand::Stop(reply) => {
                        if let Some(cam) = &mut camera {
                            let result = cam
                                .stop_exposure()
                                .map_err(|e| format!("Failed to stop exposure: {}", e));
                            // Why: stopping the exposure terminates progress reporting;
                            // any subsequent GetStatus must report `None` rather than a
                            // residual based on the now-defunct duration.
                            if result.is_ok() {
                                last_exposure_duration = None;
                            }
                            let _ = reply.send(result);
                        } else {
                            let _ = reply.send(Err("Camera not created".to_string()));
                        }
                    }
                }
                PumpOutcome::DidWork
            })
                as crate::ascom_wrapper::sta_worker::DevicePump)
        })?;

        Ok(Self {
            id: prog_id.clone(),
            name: prog_id,
            sender: tx,
            connected: AtomicBool::new(false),
            cached_capabilities: RwLock::new(CameraCapabilities::default()),
            cached_sensor_info: RwLock::new(SensorInfo::default()),
            cached_readout_modes: RwLock::new(Vec::new()),
        })
    }

    fn map_bayer_pattern(pattern: Option<&str>) -> Option<BayerPattern> {
        match pattern {
            Some("RGGB") => Some(BayerPattern::Rggb),
            Some("GRBG") => Some(BayerPattern::Grbg),
            Some("GBRG") => Some(BayerPattern::Gbrg),
            Some("BGGR") => Some(BayerPattern::Bggr),
            _ => None,
        }
    }

    fn map_camera_capabilities(caps: &AscomCameraCapabilities) -> CameraCapabilities {
        CameraCapabilities {
            can_cool: caps.can_set_ccd_temperature,
            can_set_gain: caps.can_set_gain,
            can_set_offset: caps.can_set_offset,
            can_set_binning: caps.can_bin,
            can_subframe: true,
            has_shutter: caps.has_shutter,
            has_guider_port: false,
            max_bin_x: caps.max_bin_x.max(1),
            max_bin_y: caps.max_bin_y.max(1),
            supports_readout_modes: !caps.readout_modes.is_empty(),
        }
    }

    fn map_sensor_info(caps: &AscomCameraCapabilities) -> SensorInfo {
        let bit_depth = caps.bit_depth.max(1);
        // `SensorInfo::max_adu` is the pixel-container full scale, which for an
        // ASCOM driver is exactly `MaxADU`. Re-deriving it from the bucketed
        // bit-depth turned an honest `MaxADU: 4095` into 65535. 0 would mean the
        // driver reported no usable range; fall back to the 16-bit ceiling.
        let max_adu = if caps.max_adu == 0 {
            65535
        } else {
            caps.max_adu
        };
        SensorInfo {
            width: caps.max_width,
            height: caps.max_height,
            pixel_size_x: caps.pixel_size_x.unwrap_or(0.0),
            pixel_size_y: caps.pixel_size_y.unwrap_or(0.0),
            max_adu,
            bit_depth,
            color: caps.is_color,
            bayer_pattern: Self::map_bayer_pattern(caps.bayer_pattern.as_deref()),
        }
    }

    fn map_readout_modes(caps: &AscomCameraCapabilities) -> Vec<ReadoutMode> {
        caps.readout_modes
            .iter()
            .enumerate()
            .map(|(index, name)| ReadoutMode {
                name: name.clone(),
                description: name.clone(),
                index: index as i32,
                gain_min: None,
                gain_max: None,
                offset_min: None,
                offset_max: None,
            })
            .collect()
    }

    fn update_capability_cache(&self, caps: &AscomCameraCapabilities) {
        if let Ok(mut lock) = self.cached_capabilities.write() {
            *lock = Self::map_camera_capabilities(caps);
        }
        if let Ok(mut lock) = self.cached_sensor_info.write() {
            *lock = Self::map_sensor_info(caps);
        }
        if let Ok(mut lock) = self.cached_readout_modes.write() {
            *lock = Self::map_readout_modes(caps);
        }
    }

    /// Helper to receive a response with a timeout
    /// Returns an error if the receive times out or the operation fails
    async fn recv_with_timeout<T>(
        rx: oneshot::Receiver<Result<T, String>>,
        timeout: Duration,
        operation: &str,
    ) -> Result<T, NativeError> {
        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(result)) => result.map_err(|e| NativeError::SdkError(e)),
            Ok(Err(_recv_err)) => Err(NativeError::Unknown(format!(
                "Worker thread dead during {}",
                operation
            ))),
            Err(_elapsed) => Err(NativeError::Timeout(format!(
                "Camera {} timed out after {:?}",
                operation, timeout
            ))),
        }
    }

    /// Display the ASCOM driver SetupDialog to choose device/config
    /// This is used to let the user select which camera to use when multiple are connected
    pub async fn setup_dialog(&self) -> Result<(), NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCommand::SetupDialog(tx))
            .await
            .map_err(|_| NativeError::Unknown("Worker thread dead".to_string()))?;
        Self::recv_with_timeout(
            rx,
            Duration::from_secs(300), // Setup dialog can take a long time (user interaction)
            "setup_dialog",
        )
        .await
    }

    /// Get the camera's capabilities by querying the ASCOM device
    ///
    /// This queries all capability-related properties from the camera and returns
    /// a comprehensive capabilities struct. The device should be connected before
    /// calling this method.
    pub async fn get_capabilities(&self) -> Result<AscomCameraCapabilities, NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCommand::GetCapabilities(tx))
            .await
            .map_err(|_| NativeError::Unknown("Worker thread dead".to_string()))?;
        let caps =
            Self::recv_with_timeout(rx, Timeouts::property_read(), "get_capabilities").await?;
        self.update_capability_cache(&caps);
        Ok(caps)
    }

    /// Perform a heartbeat check to verify device is still responding
    ///
    /// This should be called periodically (e.g., every 30 seconds) to detect
    /// if the device has become unresponsive. Returns the current health status.
    pub async fn heartbeat(&self) -> Result<CameraConnectionHealth, NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCommand::Heartbeat(tx))
            .await
            .map_err(|_| NativeError::Unknown("Worker thread dead".to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::heartbeat(), "heartbeat").await
    }

    /// Get the ASCOM interface version number
    pub async fn interface_version(&self) -> Result<i32, NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCommand::GetInterfaceVersion(tx))
            .await
            .map_err(|_| NativeError::Unknown("Worker thread dead".to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "interface_version").await
    }

    /// Get the driver version string
    pub async fn driver_version(&self) -> Result<String, NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCommand::GetDriverVersion(tx))
            .await
            .map_err(|_| NativeError::Unknown("Worker thread dead".to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "driver_version").await
    }

    /// Get the driver info/description
    pub async fn driver_info(&self) -> Result<String, NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCommand::GetDriverInfo(tx))
            .await
            .map_err(|_| NativeError::Unknown("Worker thread dead".to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "driver_info").await
    }

    /// Get the list of supported actions
    pub async fn supported_actions(&self) -> Result<Vec<String>, NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCommand::GetSupportedActions(tx))
            .await
            .map_err(|_| NativeError::Unknown("Worker thread dead".to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "supported_actions").await
    }

    pub async fn stop_exposure(&mut self) -> Result<(), NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCommand::Stop(tx))
            .await
            .map_err(|_| NativeError::Unknown("Worker thread dead".to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_write(), "stop_exposure").await
    }
}

#[async_trait::async_trait]
impl NativeDevice for AscomCameraWrapper {
    fn id(&self) -> &str {
        &self.id
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn vendor(&self) -> NativeVendor {
        NativeVendor::Other("ASCOM".to_string())
    }

    fn is_connected(&self) -> bool {
        self.connected.load(Ordering::SeqCst)
    }

    async fn connect(&mut self) -> Result<(), NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCommand::Connect(tx))
            .await
            .map_err(|_| NativeError::Unknown("Worker thread dead".to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::connection(), "connect").await?;
        self.connected.store(true, Ordering::SeqCst);
        // Sensor size and bit depth are load-bearing for every
        // downstream image operation. If the device cannot answer those
        // properties immediately after connect, the camera is unusable and
        // must be marked Disconnected instead of pretending the connection
        // succeeded — otherwise the bridge dispatch would fabricate a 1x1
        // sensor for the first frame.
        if let Err(err) = self.get_capabilities().await {
            tracing::error!(
                "ASCOM camera capability refresh failed after connect; marking Disconnected: {}",
                err
            );
            self.connected.store(false, Ordering::SeqCst);
            // Best-effort hardware disconnect so the COM device is not left
            // in a half-connected state.
            let (dtx, drx) = oneshot::channel();
            if self
                .sender
                .send(AscomCommand::Disconnect(dtx))
                .await
                .is_ok()
            {
                let _ = Self::recv_with_timeout(drx, Timeouts::connection(), "disconnect").await;
            }
            return Err(err);
        }
        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), NativeError> {
        if let Err(err) = self.stop_exposure().await {
            tracing::warn!("Failed to stop exposure before disconnect: {}", err);
        }
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCommand::Disconnect(tx))
            .await
            .map_err(|_| NativeError::Unknown("Worker thread dead".to_string()))?;
        let result = Self::recv_with_timeout(rx, Timeouts::connection(), "disconnect").await;
        if result.is_ok() {
            self.connected.store(false, Ordering::SeqCst);
            if let Ok(mut caps) = self.cached_capabilities.write() {
                *caps = CameraCapabilities::default();
            }
            if let Ok(mut info) = self.cached_sensor_info.write() {
                *info = SensorInfo::default();
            }
            if let Ok(mut modes) = self.cached_readout_modes.write() {
                modes.clear();
            }
        }
        result
    }
}

#[async_trait::async_trait]
impl NativeCamera for AscomCameraWrapper {
    fn capabilities(&self) -> CameraCapabilities {
        self.cached_capabilities
            .read()
            .map(|caps| caps.clone())
            .unwrap_or_default()
    }

    async fn get_status(&self) -> Result<CameraStatus, NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCommand::GetStatus(tx))
            .await
            .map_err(|_| NativeError::Unknown("Worker thread dead".to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "get_status").await
    }

    async fn start_exposure(&mut self, params: ExposureParams) -> Result<(), NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCommand::StartExposure(params, tx))
            .await
            .map_err(|_| NativeError::Unknown("Worker thread dead".to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::exposure_start(), "start_exposure").await
    }

    async fn abort_exposure(&mut self) -> Result<(), NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCommand::AbortExposure(tx))
            .await
            .map_err(|_| NativeError::Unknown("Worker thread dead".to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_write(), "abort_exposure").await
    }

    async fn is_exposure_complete(&self) -> Result<bool, NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCommand::IsExposureComplete(tx))
            .await
            .map_err(|_| NativeError::Unknown("Worker thread dead".to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "is_exposure_complete").await
    }

    async fn download_image(&mut self) -> Result<ImageData, NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCommand::DownloadImage(tx))
            .await
            .map_err(|_| NativeError::Unknown("Worker thread dead".to_string()))?;
        // Image download can take a long time for large sensors
        Self::recv_with_timeout(rx, Timeouts::image_download_large(), "download_image").await
    }

    async fn set_cooler(
        &mut self,
        enabled: bool,
        target_temp: Option<f64>,
    ) -> Result<(), NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCommand::SetCooler(enabled, target_temp, tx))
            .await
            .map_err(|_| NativeError::Unknown("Worker thread dead".to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_write(), "set_cooler").await
    }

    async fn get_temperature(&self) -> Result<f64, NativeError> {
        // Temperature is included in status
        let status = self.get_status().await?;
        status.sensor_temp.ok_or(NativeError::NotSupported)
    }

    async fn get_cooler_power(&self) -> Result<f64, NativeError> {
        // Cooler power is included in status
        let status = self.get_status().await?;
        status.cooler_power.ok_or(NativeError::NotSupported)
    }

    async fn set_gain(&mut self, gain: i32) -> Result<(), NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCommand::SetGain(gain, tx))
            .await
            .map_err(|_| NativeError::Unknown("Worker thread dead".to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_write(), "set_gain").await
    }

    async fn get_gain(&self) -> Result<i32, NativeError> {
        // Gain is included in status
        let status = self.get_status().await?;
        Ok(status.gain)
    }

    async fn set_offset(&mut self, offset: i32) -> Result<(), NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCommand::SetOffset(offset, tx))
            .await
            .map_err(|_| NativeError::Unknown("Worker thread dead".to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_write(), "set_offset").await
    }

    async fn get_offset(&self) -> Result<i32, NativeError> {
        // Offset is included in status
        let status = self.get_status().await?;
        Ok(status.offset)
    }

    async fn set_binning(&mut self, bin_x: i32, bin_y: i32) -> Result<(), NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCommand::SetBinning(bin_x, bin_y, tx))
            .await
            .map_err(|_| NativeError::Unknown("Worker thread dead".to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_write(), "set_binning").await
    }

    async fn get_binning(&self) -> Result<(i32, i32), NativeError> {
        // Binning is included in status
        let status = self.get_status().await?;
        Ok((status.bin_x, status.bin_y))
    }

    async fn set_subframe(&mut self, subframe: Option<SubFrame>) -> Result<(), NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCommand::SetSubframe(subframe, tx))
            .await
            .map_err(|_| NativeError::Unknown("Worker thread dead".to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_write(), "set_subframe").await
    }

    fn get_sensor_info(&self) -> SensorInfo {
        self.cached_sensor_info
            .read()
            .map(|info| info.clone())
            .unwrap_or_default()
    }

    async fn get_readout_modes(&self) -> Result<Vec<ReadoutMode>, NativeError> {
        if let Ok(cached) = self.cached_readout_modes.read() {
            if !cached.is_empty() {
                return Ok(cached.clone());
            }
        }
        let _ = self.get_capabilities().await?;
        self.cached_readout_modes
            .read()
            .map(|modes| modes.clone())
            .map_err(|_| NativeError::Unknown("Failed to read readout mode cache".to_string()))
    }

    async fn set_readout_mode(&mut self, mode: &ReadoutMode) -> Result<(), NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCommand::SetReadoutMode(mode.index, tx))
            .await
            .map_err(|_| NativeError::Unknown("Worker thread dead".to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_write(), "set_readout_mode").await
    }

    async fn get_vendor_features(&self) -> Result<VendorFeatures, NativeError> {
        Ok(VendorFeatures::default())
    }

    async fn get_gain_range(&self) -> Result<(i32, i32), NativeError> {
        // Return a reasonable default gain range
        Ok((0, 100))
    }

    async fn get_offset_range(&self) -> Result<(i32, i32), NativeError> {
        // Return a reasonable default offset range
        Ok((0, 255))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
    use std::sync::Arc;
    use std::thread;

    fn build_test_wrapper<F>(handler: F) -> AscomCameraWrapper
    where
        F: FnMut(AscomCommand) -> bool + Send + 'static,
    {
        let (tx, mut rx) = mpsc::channel(8);
        let _handle = thread::spawn(move || {
            let mut handler = handler;
            while let Some(cmd) = crate::ascom_wrapper::pump_blocking_recv(&mut rx) {
                if handler(cmd) {
                    break;
                }
            }
        });

        AscomCameraWrapper {
            id: "test-camera".to_string(),
            name: "Test Camera".to_string(),
            sender: tx,
            connected: AtomicBool::new(false),
            cached_capabilities: std::sync::RwLock::new(CameraCapabilities::default()),
            cached_sensor_info: std::sync::RwLock::new(SensorInfo::default()),
            cached_readout_modes: std::sync::RwLock::new(Vec::new()),
        }
    }

    #[tokio::test]
    async fn test_disconnect_sends_stop_command() {
        let stop_called = Arc::new(AtomicBool::new(false));
        let stop_flag = Arc::clone(&stop_called);

        let mut wrapper = build_test_wrapper(move |cmd| {
            match cmd {
                AscomCommand::Stop(reply) => {
                    stop_flag.store(true, Ordering::SeqCst);
                    let _ = reply.send(Ok(()));
                }
                AscomCommand::Disconnect(reply) => {
                    let _ = reply.send(Ok(()));
                    return true;
                }
                _ => {}
            }
            false
        });

        wrapper.disconnect().await.expect("disconnect");
        assert!(stop_called.load(Ordering::SeqCst));
    }

    /// a transient COM error during DownloadImage must propagate as Err.
    /// Falling back to `cam.camera_x_size().unwrap_or(1)` would silently
    /// fabricate a 1x1 image instead of surfacing the worker error.
    #[tokio::test]
    async fn test_download_image_propagates_com_error() {
        let mut wrapper = build_test_wrapper(move |cmd| {
            if let AscomCommand::DownloadImage(reply) = cmd {
                let _ = reply.send(Err(
                    "ASCOM camera CameraXSize failed: COM error 0x80004005".to_string()
                ));
                return true;
            }
            false
        });

        let result = wrapper.download_image().await;
        assert!(result.is_err(), "transient COM error must propagate");
        match result.unwrap_err() {
            NativeError::SdkError(msg) => assert!(
                msg.contains("CameraXSize"),
                "error must reference the failed property, got: {}",
                msg
            ),
            other => panic!("expected SdkError, got {:?}", other),
        }
    }

    /// GetCapabilities must propagate sensor-size/bit-depth errors.
    #[tokio::test]
    async fn test_get_capabilities_propagates_com_error() {
        let wrapper = build_test_wrapper(move |cmd| {
            if let AscomCommand::GetCapabilities(reply) = cmd {
                let _ = reply.send(Err(
                    "ASCOM camera MaxADU property failed: COM error 0x80004005".to_string(),
                ));
                return true;
            }
            false
        });

        let result = wrapper.get_capabilities().await;
        assert!(result.is_err(), "MaxADU failure must propagate");
        match result.unwrap_err() {
            NativeError::SdkError(msg) => assert!(
                msg.contains("MaxADU"),
                "error must reference the failed property, got: {}",
                msg
            ),
            other => panic!("expected SdkError, got {:?}", other),
        }
    }

    /// the cooler-power capability cache must probe at most once.
    #[test]
    fn test_cooler_power_supported_caches_first_probe() {
        let probe_count = Arc::new(AtomicI32::new(0));

        // First call: probe runs.
        let mut cache: Option<bool> = None;
        let count1 = Arc::clone(&probe_count);
        let supported = cooler_power_supported(&mut cache, move || {
            count1.fetch_add(1, Ordering::SeqCst);
            Ok(0.5)
        });
        assert!(supported);
        assert_eq!(probe_count.load(Ordering::SeqCst), 1);
        assert_eq!(cache, Some(true));

        // Second call: probe must NOT run again.
        let count2 = Arc::clone(&probe_count);
        let supported_again = cooler_power_supported(&mut cache, move || {
            count2.fetch_add(1, Ordering::SeqCst);
            Ok(0.5)
        });
        assert!(supported_again);
        assert_eq!(
            probe_count.load(Ordering::SeqCst),
            1,
            "cache hit must not invoke the probe closure"
        );
    }

    /// A driver reporting the property as unsupported caches `false`, so we
    /// don't pay the COM round-trip on every subsequent capability query.
    #[test]
    fn test_cooler_power_supported_caches_not_implemented() {
        // The shape `OwnedExcepInfo::describe` produces for
        // PropertyNotImplementedException: sentence, source, ASCOM scode.
        const NOT_IMPLEMENTED: &str =
            "CoolerPower is not implemented (reported by ASCOM.Simulator.Camera, 0x80040400)";

        let probe_count = Arc::new(AtomicI32::new(0));
        let mut cache: Option<bool> = None;

        let count1 = Arc::clone(&probe_count);
        let supported = cooler_power_supported(&mut cache, move || {
            count1.fetch_add(1, Ordering::SeqCst);
            Err(NOT_IMPLEMENTED.to_string())
        });
        assert!(!supported);
        assert_eq!(cache, Some(false));

        let count2 = Arc::clone(&probe_count);
        let supported_again = cooler_power_supported(&mut cache, move || {
            count2.fetch_add(1, Ordering::SeqCst);
            Err(NOT_IMPLEMENTED.to_string())
        });
        assert!(!supported_again);
        assert_eq!(
            probe_count.load(Ordering::SeqCst),
            1,
            "a NotImplemented probe must cache the negative result"
        );
    }

    /// A transport failure must not be cached: it says nothing about the
    /// capability, and caching it would strip cooler telemetry from a cooled
    /// camera for the life of the connection.
    #[test]
    fn test_cooler_power_supported_retries_after_transport_error() {
        let probe_count = Arc::new(AtomicI32::new(0));
        let mut cache: Option<bool> = None;

        let count1 = Arc::clone(&probe_count);
        let supported = cooler_power_supported(&mut cache, move || {
            count1.fetch_add(1, Ordering::SeqCst);
            Err("The RPC server is unavailable. (0x800706BA)".to_string())
        });
        assert!(!supported, "an unresolved capability reads false");
        assert_eq!(cache, None, "a transport error must leave the cache unset");

        // The camera is reachable again: the next query re-probes and resolves.
        let count2 = Arc::clone(&probe_count);
        let supported_again = cooler_power_supported(&mut cache, move || {
            count2.fetch_add(1, Ordering::SeqCst);
            Ok(0.75)
        });
        assert!(supported_again);
        assert_eq!(cache, Some(true));
        assert_eq!(probe_count.load(Ordering::SeqCst), 2);
    }

    /// The Bayer element order comes from the offset pair, never from the
    /// SensorType family tag alone.
    #[test]
    fn test_bayer_pattern_from_sensor_reads_offsets() {
        assert_eq!(
            bayer_pattern_from_sensor(2, Some(0), Some(0)),
            Some("RGGB".to_string())
        );
        assert_eq!(
            bayer_pattern_from_sensor(2, Some(1), Some(0)),
            Some("GRBG".to_string())
        );
        assert_eq!(
            bayer_pattern_from_sensor(2, Some(0), Some(1)),
            Some("GBRG".to_string())
        );
        assert_eq!(
            bayer_pattern_from_sensor(2, Some(1), Some(1)),
            Some("BGGR".to_string())
        );
    }

    /// A BGGR sensor must not be reported as RGGB: red and blue would be
    /// transposed in every debayered frame and the wrong BAYERPAT written to
    /// the FITS header.
    #[test]
    fn test_bayer_pattern_from_sensor_does_not_assume_rggb() {
        assert_eq!(
            bayer_pattern_from_sensor(2, Some(1), Some(1)).as_deref(),
            Some("BGGR"),
            "the offset pair, not the SensorType ordinal, names the element order"
        );
    }

    /// Anything the offsets cannot pin down is unknown, so the frame is left
    /// undebayered rather than debayered with a guess.
    #[test]
    fn test_bayer_pattern_from_sensor_unknown_cases() {
        // Offsets unreadable on an RGGB-family sensor.
        assert_eq!(bayer_pattern_from_sensor(2, None, Some(0)), None);
        assert_eq!(bayer_pattern_from_sensor(2, Some(0), None), None);
        assert_eq!(bayer_pattern_from_sensor(2, None, None), None);
        // Offsets outside the 2x2 grid.
        assert_eq!(bayer_pattern_from_sensor(2, Some(2), Some(0)), None);
        assert_eq!(bayer_pattern_from_sensor(2, Some(-1), Some(1)), None);
        // Monochrome and direct-colour sensors carry no Bayer mask.
        assert_eq!(bayer_pattern_from_sensor(0, Some(0), Some(0)), None);
        assert_eq!(bayer_pattern_from_sensor(1, Some(0), Some(0)), None);
        // CMYG / CMYG2 / LRGB have no RGGB-style element order to name.
        assert_eq!(bayer_pattern_from_sensor(3, Some(0), Some(0)), None);
        assert_eq!(bayer_pattern_from_sensor(4, Some(0), Some(0)), None);
        assert_eq!(bayer_pattern_from_sensor(5, Some(0), Some(0)), None);
        // An unreadable SensorType names no family.
        assert_eq!(bayer_pattern_from_sensor(-1, Some(0), Some(0)), None);
    }

    /// Colour and Bayer order are independent answers: SensorType 1..=5 all
    /// mark the sensor colour, but only the RGGB family names a BAYERPAT.
    #[test]
    fn test_colour_sensors_without_a_nameable_bayer_order() {
        for sensor_type in [1, 3, 4, 5] {
            assert!(
                crate::ascom_sensor_type::is_colour_sensor(sensor_type),
                "SensorType={sensor_type} is a colour variant"
            );
            assert_eq!(
                bayer_pattern_from_sensor(sensor_type, Some(0), Some(0)),
                None,
                "SensorType={sensor_type} is colour without a BAYERPAT card"
            );
        }
    }

    /// Only the four patterns `map_bayer_pattern` accepts may be produced;
    /// anything else would be discarded downstream and read as mono.
    #[test]
    fn test_bayer_pattern_from_sensor_round_trips_to_native() {
        for (x, y) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
            let pattern = bayer_pattern_from_sensor(2, Some(x), Some(y));
            assert!(
                AscomCameraWrapper::map_bayer_pattern(pattern.as_deref()).is_some(),
                "offsets ({x}, {y}) produced {pattern:?}, which the native mapping drops"
            );
        }
    }

    /// PercentCompleted (0..100) translates into a wall-clock
    /// seconds-remaining figure when the total exposure duration is known.
    #[test]
    fn test_compute_exposure_remaining_typical() {
        // 25% complete on a 100s exposure → 75s remaining.
        assert_eq!(
            compute_exposure_remaining(Some(25), Some(100.0)),
            Some(75.0)
        );
        // 0% complete → full duration remaining.
        assert_eq!(compute_exposure_remaining(Some(0), Some(60.0)), Some(60.0));
        // 100% complete → zero remaining.
        assert_eq!(compute_exposure_remaining(Some(100), Some(60.0)), Some(0.0));
    }

    /// missing inputs or out-of-range values map to None
    /// rather than fabricating a residual.
    #[test]
    fn test_compute_exposure_remaining_invalid_inputs() {
        assert_eq!(compute_exposure_remaining(None, Some(60.0)), None);
        assert_eq!(compute_exposure_remaining(Some(50), None), None);
        assert_eq!(compute_exposure_remaining(Some(-1), Some(60.0)), None);
        assert_eq!(compute_exposure_remaining(Some(101), Some(60.0)), None);
        assert_eq!(compute_exposure_remaining(Some(50), Some(-1.0)), None);
    }

    /// the wrapper plumbs an `exposure_remaining` value
    /// reported by the worker through to the public `get_status` API.
    #[tokio::test]
    async fn test_get_status_plumbs_exposure_remaining() {
        let wrapper = build_test_wrapper(move |cmd| {
            if let AscomCommand::GetStatus(reply) = cmd {
                let status = CameraStatus {
                    state: CameraState::Exposing,
                    sensor_temp: None,
                    cooler_power: None,
                    target_temp: None,
                    cooler_on: false,
                    gain: 0,
                    offset: 0,
                    bin_x: 1,
                    bin_y: 1,
                    exposure_remaining: Some(7.5),
                };
                let _ = reply.send(Ok(status));
                return true;
            }
            false
        });

        let status = wrapper.get_status().await.expect("get_status");
        assert_eq!(
            status.exposure_remaining,
            Some(7.5),
            "exposure_remaining must be plumbed through the wrapper"
        );
    }
}
