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

/// Start heartbeat monitoring for a device: poll its status every `interval_ms`
/// (10000 is the usual cadence) and emit a Disconnected event once it stops
/// answering.
pub async fn api_start_device_heartbeat(
    device_type: DeviceType,
    device_id: String,
    interval_ms: u64,
) -> Result<(), SkotiqError> {
    tracing::info!(
        "Starting heartbeat monitoring for {} device: {} (interval: {}ms)",
        device_type.as_str(),
        device_id,
        interval_ms
    );

    // Validate device type matches
    if let Some(device) = get_device_manager().get_device(&device_id).await {
        if device.info.device_type != device_type {
            return Err(SkotiqError::InvalidParameter(format!(
                "Device {} is type {:?}, not {:?}",
                device_id, device.info.device_type, device_type
            )));
        }
    }

    get_device_manager()
        .start_heartbeat(&device_id, std::time::Duration::from_millis(interval_ms))
        .await
        .map_err(|e| SkotiqError::OperationFailed(e))
}

/// Stop heartbeat monitoring for a device.
pub async fn api_stop_device_heartbeat(device_id: String) -> Result<(), SkotiqError> {
    tracing::info!("Stopping heartbeat monitoring for device: {}", device_id);

    get_device_manager()
        .stop_heartbeat(&device_id)
        .await
        .map_err(|e| SkotiqError::OperationFailed(e))
}

/// Start heartbeat monitoring with a caller-supplied interval, failure threshold,
/// and auto-reconnect policy. `max_reconnect_attempts` of 0 means unlimited.
pub async fn api_start_device_heartbeat_with_config(
    device_id: String,
    interval_secs: u64,
    failure_threshold: u32,
    auto_reconnect: bool,
    max_reconnect_attempts: u32,
) -> Result<(), SkotiqError> {
    tracing::info!(
        "Starting heartbeat with config for device: {} (interval={}s, threshold={}, auto_reconnect={}, max_attempts={})",
        device_id,
        interval_secs,
        failure_threshold,
        auto_reconnect,
        max_reconnect_attempts
    );

    let config = crate::device_manager::HeartbeatConfig {
        base_interval_secs: interval_secs,
        max_interval_secs: interval_secs * 6, // 6x base for max backoff
        failure_threshold,
        backoff_multiplier: 2.0,
        auto_reconnect,
        max_reconnect_attempts,
        reconnect_delay_secs: 5,
        // This FFI surface lets the caller hand-tune timing but not the
        // escalation policy; inherit the fail-loud default (escalate on loss).
        // The per-device-type opt-outs (focuser/filter wheel/rotator) are
        // applied by `get_heartbeat_config`, which is the path device connects
        // actually use.
        ..crate::device_manager::HeartbeatConfig::default()
    };

    get_device_manager()
        .start_heartbeat_with_config(&device_id, config)
        .await
        .map_err(|e| SkotiqError::OperationFailed(e))
}

/// The default heartbeat settings for a device type, as
/// `(interval_secs, max_interval_secs, failure_threshold, auto_reconnect)`.
pub fn api_get_heartbeat_config_for_type(device_type: DeviceType) -> (u64, u64, u32, bool) {
    let config = match device_type {
        DeviceType::Camera => crate::device_manager::HeartbeatConfig::for_camera(),
        DeviceType::Mount => crate::device_manager::HeartbeatConfig::for_mount(),
        DeviceType::Focuser => crate::device_manager::HeartbeatConfig::for_focuser(),
        DeviceType::FilterWheel => crate::device_manager::HeartbeatConfig::for_filter_wheel(),
        DeviceType::Dome => crate::device_manager::HeartbeatConfig::for_dome(),
        DeviceType::Rotator => crate::device_manager::HeartbeatConfig::for_rotator(),
        DeviceType::Weather => crate::device_manager::HeartbeatConfig::for_weather(),
        DeviceType::SafetyMonitor => crate::device_manager::HeartbeatConfig::for_safety_monitor(),
        _ => crate::device_manager::HeartbeatConfig::default(),
    };

    (
        config.base_interval_secs,
        config.max_interval_secs,
        config.failure_threshold,
        config.auto_reconnect,
    )
}

/// Device health as `(last_successful_comm_ms, is_healthy)`: when the device last
/// answered, and whether it is still responding to heartbeat checks.
pub async fn api_get_device_health(device_id: String) -> Result<(i64, bool), SkotiqError> {
    get_device_manager()
        .get_device_health(&device_id)
        .await
        .map_err(|e| SkotiqError::OperationFailed(e))
}

/// Detailed heartbeat status for a device
#[derive(Debug, Clone)]
#[flutter_rust_bridge::frb]
pub struct DeviceHeartbeatInfo {
    /// Device ID
    pub device_id: String,
    /// Device type (e.g., "Camera", "Mount")
    pub device_type: String,
    /// Whether heartbeat monitoring is currently active
    pub heartbeat_active: bool,
    /// Last successful communication timestamp (milliseconds since epoch)
    pub last_successful_comm_ms: Option<i64>,
    /// Current heartbeat interval in seconds
    pub interval_secs: u64,
    /// Maximum interval after backoff in seconds
    pub max_interval_secs: u64,
    /// Number of failures before marking disconnected
    pub failure_threshold: u32,
    /// Whether auto-reconnect is enabled
    pub auto_reconnect: bool,
    /// Maximum reconnection attempts (0 = unlimited)
    pub max_reconnect_attempts: u32,
}

/// Heartbeat status for a device: its configuration, last successful
/// communication, and whether monitoring is active.
pub async fn api_get_device_heartbeat_info(
    device_id: String,
) -> Result<DeviceHeartbeatInfo, SkotiqError> {
    let manager = get_device_manager();

    // Check if device exists and get its info using the public API
    let device = manager
        .get_device(&device_id)
        .await
        .ok_or_else(|| SkotiqError::DeviceNotFound(device_id.clone()))?;

    let device_type_enum = device.info.device_type.clone();

    // Get device-type specific configuration
    let config = crate::device_manager::HeartbeatConfig::for_device_type(&device_type_enum);

    Ok(DeviceHeartbeatInfo {
        device_id,
        device_type: device_type_enum.as_str().to_string(),
        heartbeat_active: device.heartbeat_active,
        last_successful_comm_ms: device.last_successful_comm,
        interval_secs: config.base_interval_secs,
        max_interval_secs: config.max_interval_secs,
        failure_threshold: config.failure_threshold,
        auto_reconnect: config.auto_reconnect,
        max_reconnect_attempts: config.max_reconnect_attempts,
    })
}

/// Check if heartbeat monitoring is active for a device
pub async fn api_is_heartbeat_active(device_id: String) -> Result<bool, SkotiqError> {
    Ok(get_device_manager().is_heartbeat_active(&device_id).await)
}
