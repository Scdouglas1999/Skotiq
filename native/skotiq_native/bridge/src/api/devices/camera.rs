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
use super::super::*;
use super::*;

/// Get camera status
pub async fn get_camera_status(device_id: String) -> Result<CameraStatus, SkotiqError> {
    let mgr = get_device_manager();
    let mut status = mgr
        .camera_get_status(&device_id)
        .await
        .map_err(SkotiqError::from)?;
    // Some drivers report Idle once the sensor is done, while its buffer is
    // still owned by the acquisition/download task.
    if crate::unified_device_ops::camera_acquisition_in_progress(&device_id).await
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

/// Set camera readout mode by index
///
/// mode_index: 0 = default/high quality, 1 = fast readout, etc.
/// The available modes are camera-dependent.
pub async fn api_camera_set_readout_mode(
    device_id: String,
    mode_index: i32,
) -> Result<(), SkotiqError> {
    tracing::info!(
        "Setting camera readout mode for {}: index={}",
        device_id,
        mode_index
    );
    let mgr = get_device_manager();
    mgr.camera_set_readout_mode(&device_id, mode_index)
        .await
        .map_err(SkotiqError::from)
}

/// Capture a live-view / preview JPEG frame when the driver supports it.
pub async fn api_camera_capture_preview(device_id: String) -> Result<Vec<u8>, SkotiqError> {
    if device_id.starts_with("sim_") {
        return Err(SkotiqError::OperationFailed(
            "Simulator cameras do not support live view preview".to_string(),
        ));
    }

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
) -> Result<crate::device_capabilities::CameraRecommendedSettings, SkotiqError> {
    if device_id.starts_with("sim_") {
        // Simulator cameras have no manufacturer to recommend anything.
        // Honest empty answer.
        return Ok(crate::device_capabilities::CameraRecommendedSettings::default());
    }

    let mgr = get_device_manager();
    let raw = mgr
        .camera_get_recommended_settings(&device_id)
        .await
        .map_err(SkotiqError::from)?;
    Ok(raw.into())
}
