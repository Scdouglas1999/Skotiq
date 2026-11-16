use crate::device::{CameraState, CameraStatus};
use crate::device_manager::get_device_manager;
use crate::error::SkotiqError;

/// Get camera status
pub async fn get_camera_status(device_id: String) -> Result<CameraStatus, SkotiqError> {
    let mgr = get_device_manager();
    let mut status = mgr
        .camera_get_status(&device_id)
        .await
        .map_err(SkotiqError::from)?;
    // Some drivers report Idle once the sensor is done, while its buffer is
    // still owned by the acquisition/download task.
    if crate::unified_device_ops::exposure_wait::camera_acquisition_in_progress(&device_id).await
        && status.state == CameraState::Idle
    {
        status.state = CameraState::Download;
    }
    Ok(status)
}

/// Set camera cooler
pub async fn set_camera_cooler(
    device_id: String,
    enabled: u8,
    target_temp: Option<f64>,
) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.camera_set_cooler(&device_id, enabled != 0, target_temp)
        .await
        .map_err(SkotiqError::from)
}

/// Set camera gain
pub async fn set_camera_gain(device_id: String, gain: i32) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.camera_set_gain(&device_id, gain)
        .await
        .map_err(SkotiqError::from)
}

/// Set camera offset
pub async fn set_camera_offset(device_id: String, offset: i32) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.camera_set_offset(&device_id, offset)
        .await
        .map_err(SkotiqError::from)
}

/// State what a camera takes its frames at when a frame does not name it:
/// its equipment profile's default gain, offset and read mode (by the name
/// the camera lists). Nothing is written to the camera now; each exposure
/// sets them. `None` is for a value the profile does not state or a control
/// the camera does not have; the camera then keeps its own.
#[flutter_rust_bridge::frb(sync)]
pub fn api_camera_state_frame_defaults(
    device_id: String,
    gain: Option<i32>,
    offset: Option<i32>,
    readout_mode: Option<String>,
) {
    get_device_manager().camera_state_frame_defaults(
        &device_id,
        crate::device_manager::ops::camera::CameraFrameDefaults {
            gain,
            offset,
            readout_mode,
        },
    );
}

/// One capture a camera is keeping because its download failed.
pub struct RetainedCaptureInfo {
    pub device_id: String,
    pub camera_name: String,
    /// Where the file is on the camera.
    pub location: String,
    /// In the camera's memory rather than on its card.
    pub in_camera_memory: bool,
    /// Why the capture did not become a frame.
    pub reason: String,
    /// Milliseconds since the Unix epoch (UTC).
    pub retained_at_ms: i64,
}

/// The captures cameras are keeping, oldest first.
#[flutter_rust_bridge::frb(sync)]
pub fn api_camera_retained_captures() -> Vec<RetainedCaptureInfo> {
    get_device_manager()
        .camera_retained_captures()
        .into_iter()
        .map(|kept| RetainedCaptureInfo {
            device_id: kept.device_id,
            camera_name: kept.camera_name,
            location: kept.location,
            in_camera_memory: kept.in_camera_memory,
            reason: kept.reason,
            retained_at_ms: kept.retained_at_ms,
        })
        .collect()
}

/// Read a retained capture off its camera and save the camera's file.
/// Answers the path it was saved to.
pub async fn api_camera_retrieve_retained_capture(
    device_id: String,
    location: String,
) -> Result<String, SkotiqError> {
    get_device_manager()
        .camera_retrieve_retained_capture(&device_id, &location)
        .await
        .map_err(SkotiqError::from)
}

/// Capture a live-view / preview JPEG frame when the driver supports it.
pub async fn api_camera_capture_preview(device_id: String) -> Result<Vec<u8>, SkotiqError> {
    let mgr = get_device_manager();
    mgr.camera_capture_preview(&device_id)
        .await
        .map_err(SkotiqError::from)
}

// Camera auto-detect recommended settings

/// Query the camera SDK for manufacturer-recommended gain/offset values.
///
/// Returns a [`CameraRecommendedSettings`] with whatever the vendor SDK
/// actually reports:
/// - ZWO: `default_value` from `ASIGetControlCaps` for gain and offset.
/// - QHY: `DefaultGain` / `DefaultOffset` dedicated control IDs (probed
///   via `IsQHYCCDControlAvailable`).
/// - SVBony: `default_value` from `SVBGetControlCaps` for Gain and BlackLevel.
/// - All other drivers: empty struct (every field `None`) — the vendor SDK
///   does not expose this and we will NEVER fabricate a recommendation.
///
/// On the Dart side this is called right after camera connect; the active
/// equipment profile's `defaultGain` / `defaultOffset` are populated from
/// the result IFF they are currently `null` (user-set values are never
/// overwritten).
pub async fn api_camera_get_recommended_settings(
    device_id: String,
) -> Result<crate::device_capabilities::types::CameraRecommendedSettings, SkotiqError> {
    let mgr = get_device_manager();
    let raw = mgr
        .camera_get_recommended_settings(&device_id)
        .await
        .map_err(SkotiqError::from)?;
    Ok(raw.into())
}
