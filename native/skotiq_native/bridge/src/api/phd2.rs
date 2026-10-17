// split from monolithic api.rs
#![allow(unused_imports)]
// Shared imports inherited from the monolithic api.rs.
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

/// PHD2 connection state
#[derive(Debug, Clone)]
pub struct Phd2Status {
    pub connected: bool,
    pub state: String, // "Disconnected", "Connected", "Calibrating", "Guiding", "Looping", "Paused"
    pub rms_ra: f64,
    pub rms_dec: f64,
    pub rms_total: f64,
    pub snr: f64,
    pub star_mass: f64,
    pub pixel_scale: f64,
}

/// PHD2 calibration data
#[derive(Debug, Clone)]
pub struct Phd2CalibrationData {
    /// Whether the mount is calibrated
    pub is_calibrated: bool,
    /// RA axis rotation angle (degrees)
    pub ra_angle: Option<f64>,
    /// Dec axis rotation angle (degrees)
    pub dec_angle: Option<f64>,
    /// RA guide rate (pixels/second)
    pub ra_rate: Option<f64>,
    /// Dec guide rate (pixels/second)
    pub dec_rate: Option<f64>,
}

/// PHD2 star image data
#[derive(Debug, Clone)]
pub struct Phd2StarImage {
    /// Frame number
    pub frame: u32,
    /// Image width in pixels
    pub width: u32,
    /// Image height in pixels
    pub height: u32,
    /// Star centroid X position
    pub star_x: f64,
    /// Star centroid Y position
    pub star_y: f64,
    /// Raw pixel data (16-bit grayscale as bytes)
    pub pixels: Vec<u8>,
}

/// PHD2 Brain algorithm parameter
#[derive(Debug, Clone)]
pub struct Phd2AlgoParam {
    /// Parameter name
    pub name: String,
    /// Parameter value
    pub value: f64,
}

/// Check if PHD2 is running
#[flutter_rust_bridge::frb(sync)]
pub fn api_is_phd2_running() -> bool {
    skotiq_imaging::is_phd2_running()
}

/// Canonical PHD2 guider device id.
///
/// PHD2 lives in two independent registries and this constant is the join key
/// between them:
///
/// * the **client registry** (`PHD2_CLIENT` below) owns the live TCP client and
///   answers "can I issue an RPC right now";
/// * the **guider-state registry** (`AppState.devices`, written by
///   `api_phd2_connect` / `api_phd2_disconnect`) answers "is a guider
///   connected" for `get_active_guider_id_for_ops` and the storage API.
///
/// The two are separate — see the module note on `resolve_guider_backend` — but
/// they must agree on the id, so every PHD2 site reads it from here instead of
/// respelling the literal. The Dart side pins the same value as
/// `kPhd2CanonicalId` (`packages/skotiq_core/lib/src/utils/device_id.dart`).
pub(crate) const PHD2_DEVICE_ID: &str = "phd2_guider";

/// Static PHD2 client storage
pub(crate) static PHD2_CLIENT: OnceLock<Arc<RwLock<Option<skotiq_imaging::Phd2Client>>>> =
    OnceLock::new();

#[flutter_rust_bridge::frb(ignore)]
pub fn get_phd2_storage() -> &'static Arc<RwLock<Option<skotiq_imaging::Phd2Client>>> {
    PHD2_CLIENT.get_or_init(|| Arc::new(RwLock::new(None)))
}

/// The PHD2 **client registry** accessor: takes the write lock and hands back the
/// live client, or the `NotConnected("PHD2")` error every PHD2 entry point
/// reports when there is none.
///
/// The returned guard holds the write lock for as long as it is alive; drop it
/// early where a long wait must not stall other PHD2 calls (see
/// `api_phd2_dither`).
async fn phd2_client(
) -> Result<tokio::sync::RwLockMappedWriteGuard<'static, skotiq_imaging::Phd2Client>, SkotiqError> {
    let storage = get_phd2_storage().write().await;
    tokio::sync::RwLockWriteGuard::try_map(storage, |slot| slot.as_mut())
        .map_err(|_| SkotiqError::NotConnected("PHD2".to_string()))
}

/// Which guider backend owns a guider device id.
///
/// This is the **guider-state registry** half of the PHD2 split: the mapping
/// from a device id to the backend that services it. Every `api_guider_*` entry
/// point resolves through [`resolve_guider_backend`], so a third backend is a
/// single new arm rather than eleven edits.
enum GuiderBackend {
    Phd2,
    Builtin,
}

/// Resolve a guider device id to its backend.
///
/// Order matters: PHD2 ids are matched first (they have four spellings — see
/// `is_phd2_device_id`), then the built-in guider's single id; anything else is
/// an `Unsupported guider device` error.
fn resolve_guider_backend(device_id: &str) -> Result<GuiderBackend, SkotiqError> {
    if is_phd2_device_id(device_id) {
        return Ok(GuiderBackend::Phd2);
    }
    if device_id == crate::builtin_guider::device_id() {
        return Ok(GuiderBackend::Builtin);
    }
    Err(SkotiqError::OperationFailed(format!(
        "Unsupported guider device: {}",
        device_id
    )))
}

#[flutter_rust_bridge::frb(ignore)]
pub async fn get_active_guider_id_for_ops() -> Option<String> {
    if let Some(profile_guider) = get_state().get_profile_device_id(DeviceType::Guider).await {
        return Some(profile_guider);
    }
    if get_state()
        .is_device_connected(DeviceType::Guider, crate::builtin_guider::device_id())
        .await
    {
        return Some(crate::builtin_guider::device_id().to_string());
    }
    if get_state()
        .is_device_connected(DeviceType::Guider, PHD2_DEVICE_ID)
        .await
    {
        return Some(PHD2_DEVICE_ID.to_string());
    }
    get_state()
        .get_devices(DeviceType::Guider)
        .await
        .into_iter()
        .map(|device| device.id)
        .next()
}

/// Connect to PHD2
pub async fn api_phd2_connect(host: Option<String>, port: Option<u16>) -> Result<(), SkotiqError> {
    // Why: localhost + PHD2 default port 4400 are the
    // documented PHD2 defaults from the PHD2 EventMonitoring wiki and the
    // Skotiq PHD2-settings UI placeholder values.
    let host =
        skotiq_imaging::normalize_phd2_tcp_host(&host.unwrap_or_else(|| "127.0.0.1".to_string()));
    let port = port.unwrap_or(4400);

    tracing::info!("Connecting to PHD2 at {}:{}", host, port);

    {
        let mut storage = get_phd2_storage().write().await;
        if let Some(mut existing) = storage.take() {
            existing.disconnect();
        }
    }

    let mut client = skotiq_imaging::Phd2Client::new(&host, port);

    // Set up event callback to forward PHD2 events to the main event stream.
    // This callback runs on the PHD2 reader std::thread, NOT on the tokio runtime.
    // It publishes to the broadcast channel which is picked up by api_event_stream.
    client.set_event_callback(move |event| {
        let subscriber_count = get_state().event_bus.subscriber_count();
        // Per-event plumbing trace — fires on every looping frame (~1 Hz), so
        // keep it at debug to avoid flooding the log during normal guiding.
        tracing::debug!(
            "PHD2 event callback received: {:?} (event bus subscribers: {})",
            std::mem::discriminant(&event),
            subscriber_count
        );

        let guiding_event = match event {
            skotiq_imaging::Phd2Event::GuideStep(ref frame) => {
                tracing::debug!(
                    "PHD2 GuideStep: RA={:.3}, Dec={:.3}, SNR={:.1}",
                    frame.ra_distance,
                    frame.dec_distance,
                    frame.snr
                );
                // Forward guide step correction data
                let event_id = get_state().publish_guiding_event(
                    GuidingEvent::Correction {
                        ra: frame.ra_distance,
                        dec: frame.dec_distance,
                        ra_raw: frame.ra_distance,
                        dec_raw: frame.dec_distance,
                    },
                    EventSeverity::Info,
                );
                tracing::debug!("PHD2: Published Correction event (id={})", event_id);
                // Also forward guide stats (SNR and star mass)
                let stats_id = get_state().publish_guiding_event(
                    GuidingEvent::GuideStats {
                        snr: frame.snr,
                        star_mass: frame.star_mass,
                    },
                    EventSeverity::Info,
                );
                tracing::debug!("PHD2: Published GuideStats event (id={})", stats_id);
                return;
            }
            skotiq_imaging::Phd2Event::StateChanged(state) => {
                // PHD2 re-emits its state on every looping frame, so this would
                // log "Looping" once a second. The meaningful transitions are
                // surfaced to the UI as GuidingEvents; keep the raw log at debug.
                tracing::debug!("PHD2 state changed: {:?}", state);
                match state {
                    skotiq_imaging::Phd2State::Guiding => GuidingEvent::GuidingStarted,
                    skotiq_imaging::Phd2State::Connected => GuidingEvent::GuidingStopped,
                    skotiq_imaging::Phd2State::Disconnected => GuidingEvent::Disconnected,
                    skotiq_imaging::Phd2State::Paused => GuidingEvent::Paused,
                    skotiq_imaging::Phd2State::LostLock => GuidingEvent::LostStar,
                    skotiq_imaging::Phd2State::Looping => GuidingEvent::Looping,
                    skotiq_imaging::Phd2State::Calibrating => GuidingEvent::Calibrating,
                    skotiq_imaging::Phd2State::Settling => GuidingEvent::Settling,
                    // Why: PHD2 occasionally introduces new app-states; we
                    // forward the raw name as a generic `Disconnected` event
                    // (the safest superset for sequencer logic) but the
                    // warning is already emitted upstream in
                    // `parse_phd2_app_state`. Surfacing the literal string in
                    // the GuidingEvent stream would require extending the
                    // FFI enum, which is out of scope here.
                    skotiq_imaging::Phd2State::Unknown(raw) => {
                        tracing::warn!(
                            "PHD2: unrecognised state {:?} bubbled into bridge — \
                             treating as Disconnected for guiding-event mapping",
                            raw
                        );
                        GuidingEvent::Disconnected
                    }
                }
            }
            skotiq_imaging::Phd2Event::StarLost => GuidingEvent::LostStar,
            skotiq_imaging::Phd2Event::StarSelected { x, y } => GuidingEvent::StarSelected { x, y },
            skotiq_imaging::Phd2Event::SettleBegin => GuidingEvent::Settling,
            skotiq_imaging::Phd2Event::SettleDone {
                status,
                ref error,
                total_frames: _,
                dropped_frames: _,
            } => {
                // The dither path waits on SettleDone explicitly (see
                // api_phd2_dither); this stream mapping is for UI/telemetry. A
                // failed settle (non-zero status) must not masquerade as a
                // clean "Settled" event.
                if status != 0 {
                    tracing::warn!(
                        "PHD2: settle failed (status {}): {}",
                        status,
                        if error.is_empty() { "no detail" } else { error }
                    );
                    GuidingEvent::LostStar
                } else {
                    GuidingEvent::Settled { rms: 0.0 }
                }
            }
            skotiq_imaging::Phd2Event::CalibrationComplete => {
                tracing::info!("PHD2: Calibration complete");
                GuidingEvent::CalibrationComplete
            }
            skotiq_imaging::Phd2Event::Disconnected => GuidingEvent::Disconnected,
            skotiq_imaging::Phd2Event::Alert {
                message,
                alert_type,
            } => {
                tracing::warn!("PHD2 Alert [{}]: {}", alert_type, message);
                return; // Alerts are not forwarded as GuidingEvent
            }
            skotiq_imaging::Phd2Event::Error(msg) => {
                tracing::error!("PHD2 Error: {}", msg);
                return; // Errors are not forwarded as GuidingEvent
            }
        };

        let severity = match &guiding_event {
            GuidingEvent::LostStar | GuidingEvent::Disconnected => EventSeverity::Warning,
            _ => EventSeverity::Info,
        };

        let event_id = get_state().publish_guiding_event(guiding_event.clone(), severity);
        tracing::debug!(
            "PHD2: Published {:?} to event bus (event_id={}, subscribers={})",
            guiding_event,
            event_id,
            subscriber_count
        );
    });

    client
        .connect()
        .map_err(|e| SkotiqError::connection_failed(PHD2_DEVICE_ID, format!("PHD2: {}", e)))?;

    client
        .wait_until_ready(Duration::from_secs(10))
        .map_err(|e| {
            client.disconnect();
            SkotiqError::connection_failed(PHD2_DEVICE_ID, format!("PHD2: {}", e))
        })?;

    // Store the client
    let mut storage = get_phd2_storage().write().await;
    *storage = Some(client);

    // Register the live PHD2 guider in BOTH device registries.
    //
    // AppState is the guider-state registry `get_active_guider_id_for_ops` and
    // the storage API read. DeviceManager is what `api_get_connected_devices` /
    // `api_is_device_connected` — the Dart-facing answers — actually read, and
    // PHD2 never wrote it: the app reported "no guider connected" on every
    // surface a user looks at while the sequencer guided through this very
    // client. PHD2 owns its own socket (opened above), so it registers as
    // already-connected rather than going through `connect_device`.
    let phd2_device_info = DeviceInfo {
        id: PHD2_DEVICE_ID.to_string(),
        name: "PHD2".to_string(),
        device_type: DeviceType::Guider,
        driver_type: DriverType::Native,
        description: format!("PHD2 Guiding at {}:{}", host, port),
        driver_version: String::new(),
        serial_number: None,
        unique_id: None,
        display_name: "PHD2 Guiding".to_string(),
    };
    get_state()
        .register_device(phd2_device_info.clone(), ConnectionState::Connected)
        .await;
    get_device_manager()
        .register_connected_device(phd2_device_info)
        .await;

    // Publish event
    get_state().publish_guiding_event(GuidingEvent::Connected, EventSeverity::Info);

    Ok(())
}

/// Disconnect from PHD2
pub async fn api_phd2_disconnect() -> Result<(), SkotiqError> {
    let mut storage = get_phd2_storage().write().await;
    if let Some(mut client) = storage.take() {
        client.disconnect();
    }

    // Remove PHD2 from BOTH registries it was registered in by
    // `api_phd2_connect`. `unregister_device` (a plain map removal) — never
    // `disconnect_device`, which routes PHD2 ids back here and would recurse.
    get_state()
        .remove_device(DeviceType::Guider, PHD2_DEVICE_ID)
        .await;
    get_device_manager().unregister_device(PHD2_DEVICE_ID).await;

    get_state().publish_guiding_event(GuidingEvent::Disconnected, EventSeverity::Info);

    Ok(())
}

/// Start guiding in PHD2
pub async fn api_phd2_start_guiding(
    settle_pixels: f64,
    settle_time: f64,
    settle_timeout: f64,
) -> Result<(), SkotiqError> {
    let mut client = phd2_client().await?;

    client
        .guide(settle_pixels, settle_time, settle_timeout)
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to start guiding: {}", e)))?;

    get_state().publish_guiding_event(GuidingEvent::GuidingStarted, EventSeverity::Info);

    Ok(())
}

/// Stop guiding in PHD2
pub async fn api_phd2_stop_guiding() -> Result<(), SkotiqError> {
    let mut client = phd2_client().await?;

    client
        .stop_capture()
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to stop guiding: {}", e)))?;

    get_state().publish_guiding_event(GuidingEvent::GuidingStopped, EventSeverity::Info);

    Ok(())
}

/// Dither in PHD2
pub async fn api_phd2_dither(
    amount: f64,
    ra_only: u8,
    settle_pixels: f64,
    settle_time: f64,
    settle_timeout: f64,
) -> Result<(), SkotiqError> {
    let mut client = phd2_client().await?;

    let ra_only_bool = ra_only != 0;

    // Issue the dither RPC and arm settle tracking while holding the storage
    // lock, but DO NOT block on the multi-second settle here — that would stall
    // every other PHD2 operation (status polls, stop, etc.) for the duration.
    // `dither_arm` returns a detached waiter that only clones the shared Arcs.
    let waiter = client
        .dither_arm(
            amount,
            ra_only_bool,
            settle_pixels,
            settle_time,
            settle_timeout,
        )
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to dither: {}", e)))?;

    // Release the storage write-lock before waiting for settle.
    drop(client);

    get_state().publish_guiding_event(
        GuidingEvent::DitherStarted { pixels: amount },
        EventSeverity::Info,
    );

    // Wait (off the async runtime) for PHD2's asynchronous SettleDone. This
    // fails CLOSED: a non-zero PHD2 settle status, a settle timeout, or a
    // disconnect all surface as an error so the sequencer never resumes
    // exposing mid-settle (which trailed every dithered sub).
    let wait = skotiq_imaging::Phd2Client::settle_wait_duration(settle_time, settle_timeout);
    let settle = tokio::task::spawn_blocking(move || waiter.wait(wait))
        .await
        .map_err(|e| SkotiqError::OperationFailed(format!("Dither settle task failed: {}", e)))?;

    settle.map_err(|e| SkotiqError::OperationFailed(format!("Dither did not settle: {}", e)))?;

    get_state().publish_guiding_event(GuidingEvent::Settled { rms: 0.0 }, EventSeverity::Info);

    Ok(())
}

/// Get PHD2 status
pub async fn api_phd2_get_status() -> Result<Phd2Status, SkotiqError> {
    let mut client = phd2_client().await?;

    let state = client
        .get_app_state()
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to get PHD2 state: {}", e)))?;

    // Why: pixel scale is reported only after PHD2 has
    // selected a star and run a calibration; before that, the RPC errors.
    // 0.0 communicates "not yet calibrated" to the UI guiding panel, which
    // hides the arc-sec/pixel readout when the value is non-positive.
    let pixel_scale = client.get_pixel_scale().unwrap_or(0.0);

    // Why: forward the raw PHD2 state name when unrecognised so the desktop
    // UI can render "PHD2 says: GuidingPaused" instead of pretending
    // everything is fine. Known variants stay as &'static str literals;
    // Unknown owns its String, so we convert to String at the join point.
    let state_str: String = match state {
        skotiq_imaging::Phd2State::Disconnected => "Disconnected".to_string(),
        skotiq_imaging::Phd2State::Connected => "Connected".to_string(),
        skotiq_imaging::Phd2State::Calibrating => "Calibrating".to_string(),
        skotiq_imaging::Phd2State::Guiding => "Guiding".to_string(),
        skotiq_imaging::Phd2State::Looping => "Looping".to_string(),
        skotiq_imaging::Phd2State::Paused => "Paused".to_string(),
        skotiq_imaging::Phd2State::Settling => "Settling".to_string(),
        skotiq_imaging::Phd2State::LostLock => "LostLock".to_string(),
        skotiq_imaging::Phd2State::Unknown(raw) => raw,
    };

    // Report the real rolling guide statistics accumulated from the PHD2
    // GuideStep event stream. Returning hardcoded 0.0 here is a silent
    // fallback that disables the sequencer's GuidingFailed safety trigger
    // (it fires only when sustained RMS exceeds a threshold, and 0.0 can
    // never exceed it) and blinds the per-exposure guiding-quality gate.
    // The Phd2Client already computes rms_total = sqrt(rms_ra^2 + rms_dec^2)
    // per guide frame; surface it.
    let stats = client.get_rolling_stats();

    Ok(Phd2Status {
        connected: client.is_connected(),
        state: state_str,
        rms_ra: stats.rms_ra,
        rms_dec: stats.rms_dec,
        rms_total: stats.rms_total,
        snr: stats.snr,
        star_mass: stats.star_mass,
        pixel_scale,
    })
}

/// Get PHD2 star image with metadata
pub async fn api_phd2_get_star_image(size: u32) -> Result<Phd2StarImage, SkotiqError> {
    let mut client = phd2_client().await?;

    let image_data = client
        .get_star_image_data(size)
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to get star image: {}", e)))?;

    Ok(Phd2StarImage {
        frame: image_data.frame,
        width: image_data.width,
        height: image_data.height,
        star_x: image_data.star_x,
        star_y: image_data.star_y,
        pixels: image_data.pixels,
    })
}

/// Get PHD2 algorithm parameter names for an axis
pub async fn api_phd2_get_algo_param_names(axis: String) -> Result<Vec<String>, SkotiqError> {
    let mut client = phd2_client().await?;

    client
        .get_algo_param_names(&axis)
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to get algo param names: {}", e)))
}

/// Get PHD2 algorithm parameter value
pub async fn api_phd2_get_algo_param(axis: String, name: String) -> Result<f64, SkotiqError> {
    let mut client = phd2_client().await?;

    client
        .get_algo_param(&axis, &name)
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to get algo param: {}", e)))
}

/// Set PHD2 algorithm parameter value
pub async fn api_phd2_set_algo_param(
    axis: String,
    name: String,
    value: f64,
) -> Result<(), SkotiqError> {
    let mut client = phd2_client().await?;

    client
        .set_algo_param(&axis, &name, value)
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to set algo param: {}", e)))
}

/// Get all PHD2 algorithm parameters for an axis
pub async fn api_phd2_get_all_algo_params(axis: String) -> Result<Vec<Phd2AlgoParam>, SkotiqError> {
    let mut client = phd2_client().await?;

    let params = client.get_all_algo_params(&axis).map_err(|e| {
        SkotiqError::OperationFailed(format!("Failed to get all algo params: {}", e))
    })?;

    Ok(params
        .into_iter()
        .map(|p| Phd2AlgoParam {
            name: p.name,
            value: p.value,
        })
        .collect())
}

/// Pause or resume PHD2 guiding
pub async fn api_phd2_set_paused(paused: bool) -> Result<(), SkotiqError> {
    let mut client = phd2_client().await?;

    client
        .set_paused(paused)
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to set paused: {}", e)))?;

    get_state().publish_guiding_event(
        if paused {
            GuidingEvent::Paused
        } else {
            GuidingEvent::Resumed
        },
        EventSeverity::Info,
    );

    Ok(())
}

/// Clear PHD2 calibration
pub async fn api_phd2_clear_calibration(which: String) -> Result<(), SkotiqError> {
    let mut client = phd2_client().await?;

    client
        .clear_calibration(&which)
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to clear calibration: {}", e)))
}

/// Flip PHD2 calibration (after meridian flip)
pub async fn api_phd2_flip_calibration() -> Result<(), SkotiqError> {
    let mut client = phd2_client().await?;

    client
        .flip_calibration()
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to flip calibration: {}", e)))
}

/// Get PHD2 calibration data
/// Returns calibration info including whether calibrated and calibration parameters
pub async fn api_phd2_get_calibration_data() -> Result<Phd2CalibrationData, SkotiqError> {
    let mut client = phd2_client().await?;

    // PHD2's get_calibration_data `which` param only accepts "Mount" or "AO"
    // (default "Mount") — there is no "both", and passing it makes PHD2 reject
    // the request with `invalid 'which' param`, spamming the log with calibration
    // fetch errors. Query the mount calibration (the guide-scope axes); AO is
    // only relevant to adaptive-optics rigs, which report through a separate
    // device.
    let result = client.get_calibration_data("Mount").map_err(|e| {
        SkotiqError::OperationFailed(format!("Failed to get calibration data: {}", e))
    })?;

    // PHD2's get_calibration_data returns a JSON object with a `calibrated`
    // boolean (and, when true, the xAngle/yAngle/xRate/yRate details). It does
    // NOT return null when the mount is uncalibrated — it returns
    // {"calibrated": false}. A `!result.is_null()` test is therefore ALWAYS
    // true on any successful RPC, which reports the mount as calibrated when
    // it is not. Read the actual flag.
    let is_calibrated = result
        .get("calibrated")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);

    // Extract calibration parameters if available
    let (ra_angle, dec_angle, ra_rate, dec_rate) = if is_calibrated {
        let xangle = result.get("xAngle").and_then(|v| v.as_f64());
        let yangle = result.get("yAngle").and_then(|v| v.as_f64());
        let xrate = result.get("xRate").and_then(|v| v.as_f64());
        let yrate = result.get("yRate").and_then(|v| v.as_f64());
        (xangle, yangle, xrate, yrate)
    } else {
        (None, None, None, None)
    };

    Ok(Phd2CalibrationData {
        is_calibrated,
        ra_angle,
        dec_angle,
        ra_rate,
        dec_rate,
    })
}

/// Find a guide star automatically
pub async fn api_phd2_find_star() -> Result<(f64, f64), SkotiqError> {
    let mut client = phd2_client().await?;

    client
        .find_star()
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to find star: {}", e)))
}

/// Set guide star lock position
pub async fn api_phd2_set_lock_position(x: f64, y: f64, exact: bool) -> Result<(), SkotiqError> {
    let mut client = phd2_client().await?;

    client
        .set_lock_position(x, y, exact)
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to set lock position: {}", e)))
}

/// Get current guide star lock position
pub async fn api_phd2_get_lock_position() -> Result<(f64, f64), SkotiqError> {
    let mut client = phd2_client().await?;

    client
        .get_lock_position()
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to get lock position: {}", e)))
}

/// Start looping exposures (without guiding)
pub async fn api_phd2_loop() -> Result<(), SkotiqError> {
    let mut client = phd2_client().await?;

    client
        .loop_exposures()
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to start looping: {}", e)))
}

/// Deselect the current guide star
pub async fn api_phd2_deselect_star() -> Result<(), SkotiqError> {
    let mut client = phd2_client().await?;

    client
        .deselect_star()
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to deselect star: {}", e)))
}

/// Get PHD2 guide exposure time (ms)
pub async fn api_phd2_get_exposure() -> Result<u32, SkotiqError> {
    let mut client = phd2_client().await?;

    client
        .get_exposure()
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to get exposure: {}", e)))
}

/// Set PHD2 guide exposure time (ms)
pub async fn api_phd2_set_exposure(exposure_ms: u32) -> Result<(), SkotiqError> {
    let mut client = phd2_client().await?;

    client
        .set_exposure(exposure_ms)
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to set exposure: {}", e)))
}

/// Get current PHD2 profile name
pub async fn api_phd2_get_profile() -> Result<String, SkotiqError> {
    let mut client = phd2_client().await?;

    client
        .get_profile()
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to get profile: {}", e)))
}

/// Launch PHD2 application
pub fn api_launch_phd2() -> Result<(), SkotiqError> {
    skotiq_imaging::launch_phd2()
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to launch PHD2: {}", e)))
}

pub async fn api_guider_start_guiding(
    device_id: String,
    settle_pixels: f64,
    settle_time: f64,
    settle_timeout: f64,
) -> Result<(), SkotiqError> {
    match resolve_guider_backend(&device_id)? {
        GuiderBackend::Phd2 => {
            api_phd2_start_guiding(settle_pixels, settle_time, settle_timeout).await
        }
        GuiderBackend::Builtin => {
            crate::builtin_guider::start_guiding(settle_pixels, settle_time, settle_timeout).await
        }
    }
}

pub async fn api_guider_stop(device_id: String) -> Result<(), SkotiqError> {
    match resolve_guider_backend(&device_id)? {
        GuiderBackend::Phd2 => api_phd2_stop_guiding().await,
        GuiderBackend::Builtin => crate::builtin_guider::stop().await,
    }
}

pub async fn api_guider_dither(
    device_id: String,
    amount: f64,
    ra_only: u8,
    settle_pixels: f64,
    settle_time: f64,
    settle_timeout: f64,
) -> Result<(), SkotiqError> {
    match resolve_guider_backend(&device_id)? {
        GuiderBackend::Phd2 => {
            api_phd2_dither(amount, ra_only, settle_pixels, settle_time, settle_timeout).await
        }
        GuiderBackend::Builtin => {
            crate::builtin_guider::dither(
                amount,
                ra_only != 0,
                settle_pixels,
                settle_time,
                settle_timeout,
            )
            .await
        }
    }
}

pub async fn api_guider_loop(device_id: String) -> Result<(), SkotiqError> {
    match resolve_guider_backend(&device_id)? {
        GuiderBackend::Phd2 => api_phd2_loop().await,
        GuiderBackend::Builtin => crate::builtin_guider::loop_exposures().await,
    }
}

pub async fn api_guider_find_star(device_id: String) -> Result<(f64, f64), SkotiqError> {
    // Which guider ran the command, and what it answered. Auto Select was
    // reported three waves running as a control that does nothing: the click
    // reached a guider, the guider picked a star, and the session log gained
    // no line naming either — only the exposure loop's own noise. Two backends
    // implement this call, so the line names the one that ran.
    let backend = resolve_guider_backend(&device_id)?;
    tracing::info!(
        "Auto Select: asking the {} guider '{}' to pick a guide star",
        match backend {
            GuiderBackend::Phd2 => "PHD2",
            GuiderBackend::Builtin => "built-in",
        },
        device_id
    );
    let result = match backend {
        GuiderBackend::Phd2 => api_phd2_find_star().await,
        GuiderBackend::Builtin => crate::builtin_guider::find_star().await,
    };
    match &result {
        Ok((x, y)) => tracing::info!("Auto Select: locked guide star at ({x:.1}, {y:.1}) px"),
        Err(e) => tracing::warn!("Auto Select: no guide star selected ({e})"),
    }
    result
}

/// How many guide frames a fresh star selection waits for before giving up.
const FRESH_STAR_ATTEMPTS: u32 = 3;

/// Make PHD2 pick a guide star afresh before the sequencer (re)starts guiding:
/// stop capture, loop, wait for a frame, then auto-select a star.
///
/// PHD2's `guide` RPC keeps the star it has selected. After a slew or a target
/// change that is the lock position from the previous field, and PHD2 then
/// "guides" on empty sky (owner report from the rig, 2026-10-06).
///
/// The built-in guider selects its star inside its own start, so it has
/// nothing to do here.
#[flutter_rust_bridge::frb(ignore)]
pub async fn select_fresh_guide_star(device_id: &str) -> Result<(f64, f64), SkotiqError> {
    if matches!(resolve_guider_backend(device_id)?, GuiderBackend::Builtin) {
        return Ok((0.0, 0.0));
    }
    let exposure = {
        let mut client = phd2_client().await?;
        client.stop_capture().map_err(|e| {
            SkotiqError::OperationFailed(format!("Failed to stop PHD2 capture: {}", e))
        })?;
        client.loop_exposures().map_err(|e| {
            SkotiqError::OperationFailed(format!("Failed to start PHD2 looping: {}", e))
        })?;
        // Why: a PHD2 that cannot report its exposure still loops; one second
        // per attempt covers the common guide exposures and the retries below
        // cover the rest.
        client
            .get_exposure()
            .map(|ms| std::time::Duration::from_millis(u64::from(ms)))
            .unwrap_or(std::time::Duration::from_secs(1))
    };
    tracing::info!(
        "[GUIDING] Selecting a fresh guide star: PHD2 looping, waiting for a {:.1} s frame",
        exposure.as_secs_f64()
    );
    let mut last_error = String::new();
    for attempt in 1..=FRESH_STAR_ATTEMPTS {
        // Give PHD2 a whole new frame (plus download time) before asking it to
        // find a star in it; the client lock is not held while waiting.
        tokio::time::sleep(exposure + std::time::Duration::from_millis(500)).await;
        let found = phd2_client().await?.find_star();
        match found {
            Ok((x, y)) => {
                tracing::info!(
                    "[GUIDING] Fresh guide star selected at ({x:.1}, {y:.1}) px \
                     (attempt {attempt}/{FRESH_STAR_ATTEMPTS})"
                );
                return Ok((x, y));
            }
            Err(e) => {
                tracing::warn!(
                    "[GUIDING] No guide star found in frame {attempt}/{FRESH_STAR_ATTEMPTS}: {e}"
                );
                last_error = e;
            }
        }
    }
    Err(SkotiqError::OperationFailed(format!(
        "PHD2 found no guide star in {FRESH_STAR_ATTEMPTS} fresh frames ({last_error})"
    )))
}

pub async fn api_guider_set_lock_position(
    device_id: String,
    x: f64,
    y: f64,
    exact: bool,
) -> Result<(), SkotiqError> {
    match resolve_guider_backend(&device_id)? {
        GuiderBackend::Phd2 => api_phd2_set_lock_position(x, y, exact).await,
        GuiderBackend::Builtin => crate::builtin_guider::set_lock_position(x, y).await,
    }
}

pub async fn api_guider_get_lock_position(device_id: String) -> Result<(f64, f64), SkotiqError> {
    match resolve_guider_backend(&device_id)? {
        GuiderBackend::Phd2 => api_phd2_get_lock_position().await,
        GuiderBackend::Builtin => crate::builtin_guider::get_lock_position().await,
    }
}

pub async fn api_guider_deselect_star(device_id: String) -> Result<(), SkotiqError> {
    match resolve_guider_backend(&device_id)? {
        GuiderBackend::Phd2 => api_phd2_deselect_star().await,
        GuiderBackend::Builtin => crate::builtin_guider::deselect_star().await,
    }
}

pub async fn api_guider_get_star_image(
    device_id: String,
    size: u32,
) -> Result<Phd2StarImage, SkotiqError> {
    match resolve_guider_backend(&device_id)? {
        GuiderBackend::Phd2 => api_phd2_get_star_image(size).await,
        GuiderBackend::Builtin => crate::builtin_guider::get_star_image(size).await,
    }
}

pub async fn api_guider_get_status(device_id: String) -> Result<Phd2Status, SkotiqError> {
    match resolve_guider_backend(&device_id)? {
        GuiderBackend::Phd2 => api_phd2_get_status().await,
        GuiderBackend::Builtin => crate::builtin_guider::get_status().await,
    }
}

/// Unified accessor for calibration data across all guider backends.
/// Used by the sequencer to validate calibration quality post-StartGuiding (P3-7).
pub async fn api_guider_get_calibration(
    device_id: String,
) -> Result<Phd2CalibrationData, SkotiqError> {
    match resolve_guider_backend(&device_id)? {
        GuiderBackend::Phd2 => api_phd2_get_calibration_data().await,
        GuiderBackend::Builtin => crate::builtin_guider::get_calibration_data().await,
    }
}

// Built-in guider configuration

/// Get the current built-in guider configuration.
/// Returns a flat struct with all configurable parameters.
pub async fn api_builtin_guider_get_config() -> Result<BuiltinGuiderConfig, SkotiqError> {
    let config = crate::builtin_guider::get_config().await;
    Ok(BuiltinGuiderConfig {
        exposure_secs: config.exposure_secs,
        gain: config.gain,
        offset: config.offset,
        binning: config.binning,
        calibration_ms: config.calibration_ms,
        settle_sleep_ms: config.settle_sleep_ms,
        min_pulse_ms: config.min_pulse_ms,
        max_pulse_ms: config.max_pulse_ms,
    })
}

/// Per-star tracked-star snapshot for the built-in multi-star guider, as a JSON
/// string (`{"count":N,"stars":[...]}`).
///
/// This is the bridged entry point for the `#[frb(ignore)]`
/// `builtin_guider::get_tracked_stars_json` DTO: the built-in guider tracks up
/// to `GUIDE_MAX_TRACKED_STARS` reference stars, and the PHD2-shaped aggregate
/// `Phd2Status` carries only rms/snr/star_mass, so the per-star list reaches the
/// Dart guider UI through this call. The host FFI backend calls it from
/// `phd2GetStatus()` and decodes the JSON into `Phd2Status.trackedStars`.
///
/// Returns `{"count":0,"stars":[]}` when the built-in guider is not the active
/// guider or is not tracking (e.g. PHD2/external guiders), so it is always safe
/// to call on the status path.
pub async fn api_builtin_guider_get_tracked_stars_json() -> String {
    crate::builtin_guider::get_tracked_stars_json().await
}

/// Set the built-in guider configuration.
/// Can be called while guiding is active; changes apply to subsequent frames.
pub async fn api_builtin_guider_set_config(
    exposure_secs: f64,
    gain: i32,
    offset: i32,
    binning: i32,
    calibration_ms: u32,
    settle_sleep_ms: u64,
    min_pulse_ms: f64,
    max_pulse_ms: f64,
) -> Result<(), SkotiqError> {
    let config = crate::builtin_guider::GuiderConfig {
        exposure_secs,
        gain,
        offset,
        binning,
        calibration_ms,
        settle_sleep_ms,
        min_pulse_ms,
        max_pulse_ms,
        // RA/Dec aggressiveness, min-move and Dec backlash compensation are
        // internal guiding-quality params with tuned defaults; they are not
        // surfaced through the FFI setter (the bridge struct stays stable) so we
        // keep the existing defaults here.
        ..crate::builtin_guider::GuiderConfig::default()
    };
    crate::builtin_guider::set_config(config).await;
    Ok(())
}

/// FRB-friendly struct for the built-in guider configuration.
#[derive(Clone, Debug)]
pub struct BuiltinGuiderConfig {
    pub exposure_secs: f64,
    pub gain: i32,
    pub offset: i32,
    pub binning: i32,
    pub calibration_ms: u32,
    pub settle_sleep_ms: u64,
    pub min_pulse_ms: f64,
    pub max_pulse_ms: f64,
}

// Parity tests for the PHD2 registry split
//
// These pin the exact outputs the retired inline copies produced, so the two
// registries cannot drift back together:
//
//   * `resolve_guider_backend` replaced eleven verbatim copies of the
//     phd2-then-builtin-then-error if-chain in the `api_guider_*` entry points.
//   * `phd2_client` replaced twenty-one verbatim copies of
//     `get_phd2_storage().write().await` + `.as_mut().ok_or_else(…)`.
//   * `PHD2_DEVICE_ID` replaced the `"phd2_guider"` literal in `api/phd2.rs`
//     (×5), `api/connection.rs` and `api/discovery.rs`.
/// Serializes every test that touches the process-global PHD2 client slot
/// (`PHD2_CLIENT`) or the global device registries.
///
/// `cargo test` runs the tests in this binary on parallel threads and the slot
/// is one static: a test that stores a live client would otherwise make
/// `client_registry_reports_not_connected_when_no_client_is_stored` fail at
/// random. Every test below takes this lock first.
#[cfg(test)]
static PHD2_TEST_SLOT: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

#[cfg(test)]
mod registry_split_tests {
    use super::*;

    fn backend_name(device_id: &str) -> Result<&'static str, String> {
        match resolve_guider_backend(device_id) {
            Ok(GuiderBackend::Phd2) => Ok("phd2"),
            Ok(GuiderBackend::Builtin) => Ok("builtin"),
            Err(SkotiqError::OperationFailed(msg)) => Err(msg),
            Err(other) => panic!("unexpected error variant: {:?}", other),
        }
    }

    #[test]
    fn phd2_device_id_is_the_canonical_wire_id() {
        // The Dart side hard-codes the same string as `kPhd2CanonicalId`; the
        // guider-state registry (AppState) and the client registry join on it.
        assert_eq!(PHD2_DEVICE_ID, "phd2_guider");
        assert!(is_phd2_device_id(PHD2_DEVICE_ID));
    }

    #[test]
    fn every_phd2_id_spelling_resolves_to_the_phd2_backend() {
        // Same four spellings `is_phd2_device_id` accepts and that
        // device_manager/tests.rs pins for the disconnect route.
        for id in [
            "phd2_guider",
            "phd2",
            "phd2:localhost:4400",
            "phd2://host",
            "phd2:", // degenerate prefix form — still PHD2, as before
        ] {
            assert_eq!(backend_name(id), Ok("phd2"), "id {id} must route to PHD2");
        }
    }

    #[test]
    fn builtin_guider_id_resolves_to_the_builtin_backend() {
        assert_eq!(
            backend_name(crate::builtin_guider::device_id()),
            Ok("builtin")
        );
    }

    #[test]
    fn unknown_ids_reproduce_the_retired_error_string_verbatim() {
        // The eleven retired copies all built this exact message. Edge cases:
        // the empty id, a near-miss that must NOT be treated as PHD2, and an
        // unrelated device id.
        assert_eq!(
            backend_name(""),
            Err("Unsupported guider device: ".to_string())
        );
        assert_eq!(
            backend_name("phd2x-not-really-phd2"),
            Err("Unsupported guider device: phd2x-not-really-phd2".to_string())
        );
        assert_eq!(
            backend_name("ascom:ASCOM.Simulator.Camera"),
            Err("Unsupported guider device: ascom:ASCOM.Simulator.Camera".to_string())
        );
        // Case matters exactly as it did before: the copies compared with `==`
        // and `starts_with`, never case-insensitively.
        assert_eq!(
            backend_name("PHD2_GUIDER"),
            Err("Unsupported guider device: PHD2_GUIDER".to_string())
        );
    }

    #[tokio::test]
    async fn client_registry_reports_not_connected_when_no_client_is_stored() {
        // No PHD2 server exists in the test process, so the client slot is
        // empty and the accessor must produce the identical error the twenty-one
        // inline copies produced: NotConnected("PHD2") — not the device id.
        let _slot = PHD2_TEST_SLOT.lock().await;
        assert!(get_phd2_storage().read().await.is_none());
        match phd2_client().await {
            Ok(_) => panic!("expected NotConnected with no PHD2 client stored"),
            Err(SkotiqError::NotConnected(who)) => assert_eq!(who, "PHD2"),
            Err(other) => panic!("unexpected error variant: {:?}", other),
        }
    }

    #[tokio::test]
    async fn client_registry_releases_the_write_lock_on_the_error_path() {
        // `try_map` hands the guard back inside its Err, which is dropped with
        // the error. If it leaked, this second acquisition would deadlock.
        let _slot = PHD2_TEST_SLOT.lock().await;
        let _ = phd2_client().await;
        let guard = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            get_phd2_storage().write(),
        )
        .await
        .expect("write lock must be free after a failed phd2_client()");
        assert!(guard.is_none());
    }
}

// A PHD2 connect must be visible to the connected-devices API.
//
// `api_get_connected_devices` / `api_is_device_connected` read the
// **DeviceManager** registry, so writing only the **AppState** mirror would have
// every surface that asks those two APIs report "no guider connected" while
// `get_active_guider_id_for_ops` resolves `phd2_guider` and the sequencer guides
// through it all night.
//
// These tests drive the real `api_phd2_connect` against a mock PHD2 socket, so
// they exercise the production connect path end to end rather than a helper.
#[cfg(test)]
mod connected_devices_registry_tests {
    use super::*;
    use std::io::{BufRead, BufReader, Write};
    use std::net::TcpListener;

    /// A PHD2 stand-in that answers `get_app_state` (all `wait_until_ready`
    /// needs) and hangs up when the client disconnects.
    fn spawn_mock_phd2() -> (u16, std::thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock PHD2");
        let port = listener.local_addr().expect("mock PHD2 addr").port();
        let handle = std::thread::spawn(move || {
            let (stream, _) = listener.accept().expect("accept the PHD2 client");
            let mut reader = BufReader::new(stream.try_clone().expect("clone mock stream"));
            let mut writer = stream;
            let mut line = String::new();
            loop {
                line.clear();
                match reader.read_line(&mut line) {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {}
                }
                let Ok(request) = serde_json::from_str::<serde_json::Value>(line.trim()) else {
                    continue;
                };
                let response = serde_json::json!({
                    "jsonrpc": "2.0",
                    "result": "Stopped",
                    "id": request["id"],
                });
                if writeln!(writer, "{}", response).is_err() || writer.flush().is_err() {
                    break;
                }
            }
        });
        (port, handle)
    }

    async fn phd2_in_connected_devices() -> bool {
        crate::api::connection::api_get_connected_devices()
            .await
            .iter()
            .any(|d| d.id == PHD2_DEVICE_ID && d.device_type == DeviceType::Guider)
    }

    #[tokio::test]
    async fn a_connected_phd2_is_visible_to_the_connected_devices_api() {
        let _slot = PHD2_TEST_SLOT.lock().await;
        let (port, server) = spawn_mock_phd2();

        api_phd2_connect(Some("127.0.0.1".to_string()), Some(port))
            .await
            .expect("mock PHD2 must accept the connect");

        // Sample every answer BEFORE asserting, then always disconnect: an
        // assertion that unwound here would leave a live client in the process-
        // global slot and fail the client-registry tests instead of this one.
        let listed = phd2_in_connected_devices().await;
        let listed_ids = crate::api::connection::api_get_connected_devices()
            .await
            .iter()
            .map(|d| d.id.clone())
            .collect::<Vec<_>>();
        let is_connected = crate::api::connection::api_is_device_connected(
            DeviceType::Guider,
            PHD2_DEVICE_ID.to_string(),
        )
        .await;
        let in_app_state = get_state()
            .is_device_connected(DeviceType::Guider, PHD2_DEVICE_ID)
            .await;

        api_phd2_disconnect().await.expect("disconnect PHD2");

        let listed_after = phd2_in_connected_devices().await;
        let is_connected_after = crate::api::connection::api_is_device_connected(
            DeviceType::Guider,
            PHD2_DEVICE_ID.to_string(),
        )
        .await;
        let in_app_state_after = get_state()
            .is_device_connected(DeviceType::Guider, PHD2_DEVICE_ID)
            .await;

        server.join().expect("mock PHD2 server thread finished");

        assert!(
            listed,
            "api_get_connected_devices must list the connected PHD2 guider; it listed {:?}",
            listed_ids
        );
        assert!(
            is_connected,
            "api_is_device_connected must agree that PHD2 is connected"
        );
        // The guider-state registry that `get_active_guider_id_for_ops` and the
        // storage API read must keep answering exactly as before.
        assert!(in_app_state, "the AppState mirror must still carry PHD2");

        assert!(
            !listed_after,
            "a disconnected PHD2 must leave the connected-devices list"
        );
        assert!(
            !is_connected_after,
            "api_is_device_connected must report a disconnected PHD2 as gone"
        );
        assert!(
            !in_app_state_after,
            "the AppState mirror must be cleared too"
        );
    }

    /// `device_manager/connection.rs:912` special-cases PHD2 ids so the generic
    /// disconnect route tears the PHD2 socket down. That branch was
    /// **unreachable**: `disconnect_device` bails with "Device not found"
    /// before it, because PHD2 was never in the DeviceManager registry. The
    /// existing `disconnect_phd2_via_generic_route_calls_phd2_disconnect` test
    /// pins the id list structurally; this one drives the route.
    #[tokio::test]
    async fn the_generic_disconnect_route_reaches_a_connected_phd2() {
        let _slot = PHD2_TEST_SLOT.lock().await;
        let (port, server) = spawn_mock_phd2();

        api_phd2_connect(Some("127.0.0.1".to_string()), Some(port))
            .await
            .expect("mock PHD2 must accept the connect");

        let result = get_device_manager().disconnect_device(PHD2_DEVICE_ID).await;

        // The client slot proves the socket was actually torn down, not just
        // the bookkeeping cleared.
        let client_slot_empty = get_phd2_storage().read().await.is_none();
        let still_listed = phd2_in_connected_devices().await;

        // Belt and braces: leave no client behind for the next test even if the
        // route failed to disconnect.
        let _ = api_phd2_disconnect().await;
        server.join().expect("mock PHD2 server thread finished");

        assert_eq!(
            result,
            Ok(()),
            "disconnect_device must find the registered PHD2 guider"
        );
        assert!(
            client_slot_empty,
            "the generic route must run api_phd2_disconnect and drop the client"
        );
        assert!(!still_listed, "PHD2 must leave the connected-devices list");
    }
}

#[cfg(test)]
mod fresh_guide_star_tests {
    use super::*;
    use std::io::{BufRead, BufReader, Write};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};

    type RecordedMethods = Arc<Mutex<Vec<String>>>;

    /// A PHD2 stand-in that records every method it is asked for. Its first
    /// `find_star` fails, as PHD2's does before a frame has arrived.
    fn spawn_recording_phd2() -> (u16, RecordedMethods, std::thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock PHD2");
        let port = listener.local_addr().expect("mock PHD2 addr").port();
        let methods = RecordedMethods::default();
        let recorded = methods.clone();
        let handle = std::thread::spawn(move || {
            let (stream, _) = listener.accept().expect("accept the PHD2 client");
            let mut reader = BufReader::new(stream.try_clone().expect("clone mock stream"));
            let mut writer = stream;
            let mut line = String::new();
            let mut find_star_calls = 0;
            loop {
                line.clear();
                match reader.read_line(&mut line) {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {}
                }
                let Ok(request) = serde_json::from_str::<serde_json::Value>(line.trim()) else {
                    continue;
                };
                let method = request["method"].as_str().unwrap_or_default().to_string();
                recorded.lock().unwrap().push(method.clone());
                let response = match method.as_str() {
                    "get_exposure" => serde_json::json!({
                        "jsonrpc": "2.0", "result": 10, "id": request["id"],
                    }),
                    "find_star" => {
                        find_star_calls += 1;
                        if find_star_calls == 1 {
                            serde_json::json!({
                                "jsonrpc": "2.0",
                                "error": {"code": 1, "message": "no star found"},
                                "id": request["id"],
                            })
                        } else {
                            serde_json::json!({
                                "jsonrpc": "2.0", "result": [12.5, 34.0], "id": request["id"],
                            })
                        }
                    }
                    _ => serde_json::json!({
                        "jsonrpc": "2.0", "result": "Stopped", "id": request["id"],
                    }),
                };
                if writeln!(writer, "{}", response).is_err() || writer.flush().is_err() {
                    break;
                }
            }
        });
        (port, methods, handle)
    }

    /// On the rig a StartGuiding after slew and center guided on the previous
    /// field's lock position. A fresh selection stops capture, loops, and asks
    /// PHD2 to find a star in a new frame, retrying until one has arrived.
    #[tokio::test]
    async fn a_fresh_star_is_found_in_a_new_frame_after_capture_restarts() {
        let _slot = PHD2_TEST_SLOT.lock().await;
        let (port, methods, server) = spawn_recording_phd2();
        api_phd2_connect(Some("127.0.0.1".to_string()), Some(port))
            .await
            .expect("mock PHD2 must accept the connect");
        methods.lock().unwrap().clear();

        let selected = select_fresh_guide_star(PHD2_DEVICE_ID).await;

        let _ = api_phd2_disconnect().await;
        server.join().expect("mock PHD2 server thread finished");
        let methods = methods.lock().unwrap().clone();
        let star = selected.expect("the second frame has a star");
        assert_eq!(star, (12.5, 34.0));
        let position = |name: &str| methods.iter().position(|m| m == name);
        let (stop, looping, find) = (
            position("stop_capture"),
            position("loop"),
            position("find_star"),
        );
        assert!(
            stop.is_some() && stop < looping && looping < find,
            "stop_capture, then loop, then find_star: {methods:?}"
        );
        assert_eq!(
            methods.iter().filter(|m| *m == "find_star").count(),
            2,
            "{methods:?}"
        );
        assert!(
            !methods.iter().any(|m| m == "guide"),
            "selecting a star must not start guiding: {methods:?}"
        );
    }
}
