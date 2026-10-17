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

// Device capability reporting API

/// Get capabilities for any device by its device ID.
///
/// This function queries the actual device to determine what features it supports.
/// The result varies by device type (camera, mount, focuser, filter wheel).
pub async fn api_get_device_capabilities(
    device_id: String,
) -> Result<crate::device_capabilities::DeviceCapabilities, SkotiqError> {
    crate::device_capabilities::get_device_capabilities(&device_id).await
}

/// Get camera capabilities for a specific camera device.
pub async fn api_get_camera_capabilities(
    device_id: String,
) -> Result<crate::device_capabilities::CameraCapabilities, SkotiqError> {
    let caps = crate::device_capabilities::get_device_capabilities(&device_id).await?;
    match caps {
        crate::device_capabilities::DeviceCapabilities::Camera(c) => Ok(c),
        _ => Err(SkotiqError::not_supported(
            &device_id,
            "Device is not a camera",
        )),
    }
}

/// Get mount capabilities for a specific mount device.
pub async fn api_get_mount_capabilities(
    device_id: String,
) -> Result<crate::device_capabilities::MountCapabilities, SkotiqError> {
    let caps = crate::device_capabilities::get_device_capabilities(&device_id).await?;
    match caps {
        crate::device_capabilities::DeviceCapabilities::Mount(m) => Ok(m),
        _ => Err(SkotiqError::not_supported(
            &device_id,
            "Device is not a mount",
        )),
    }
}

/// Get focuser capabilities for a specific focuser device.
pub async fn api_get_focuser_capabilities(
    device_id: String,
) -> Result<crate::device_capabilities::FocuserCapabilities, SkotiqError> {
    let caps = crate::device_capabilities::get_device_capabilities(&device_id).await?;
    match caps {
        crate::device_capabilities::DeviceCapabilities::Focuser(f) => Ok(f),
        _ => Err(SkotiqError::not_supported(
            &device_id,
            "Device is not a focuser",
        )),
    }
}

/// Get filter wheel capabilities for a specific filter wheel device.
pub async fn api_get_filterwheel_capabilities(
    device_id: String,
) -> Result<crate::device_capabilities::FilterWheelCapabilities, SkotiqError> {
    let caps = crate::device_capabilities::get_device_capabilities(&device_id).await?;
    match caps {
        crate::device_capabilities::DeviceCapabilities::FilterWheel(fw) => Ok(fw),
        _ => Err(SkotiqError::not_supported(
            &device_id,
            "Device is not a filter wheel",
        )),
    }
}

/// Get rotator capabilities for a specific rotator device.
pub async fn api_get_rotator_capabilities(
    device_id: String,
) -> Result<crate::device_capabilities::RotatorCapabilities, SkotiqError> {
    let caps = crate::device_capabilities::get_device_capabilities(&device_id).await?;
    match caps {
        crate::device_capabilities::DeviceCapabilities::Rotator(r) => Ok(r),
        _ => Err(SkotiqError::not_supported(
            &device_id,
            "Device is not a rotator",
        )),
    }
}

/// Get dome capabilities for a specific dome device.
pub async fn api_get_dome_capabilities(
    device_id: String,
) -> Result<crate::device_capabilities::DomeCapabilities, SkotiqError> {
    let caps = crate::device_capabilities::get_device_capabilities(&device_id).await?;
    match caps {
        crate::device_capabilities::DeviceCapabilities::Dome(d) => Ok(d),
        _ => Err(SkotiqError::not_supported(
            &device_id,
            "Device is not a dome",
        )),
    }
}

/// Get cover calibrator capabilities for a specific cover calibrator device.
pub async fn api_get_cover_calibrator_capabilities(
    device_id: String,
) -> Result<crate::device_capabilities::CoverCalibratorCapabilities, SkotiqError> {
    let caps = crate::device_capabilities::get_device_capabilities(&device_id).await?;
    match caps {
        crate::device_capabilities::DeviceCapabilities::CoverCalibrator(cc) => Ok(cc),
        _ => Err(SkotiqError::not_supported(
            &device_id,
            "Device is not a cover calibrator",
        )),
    }
}

/// Get weather capabilities for a specific weather/observing conditions device.
pub async fn api_get_weather_capabilities(
    device_id: String,
) -> Result<crate::device_capabilities::WeatherCapabilities, SkotiqError> {
    let caps = crate::device_capabilities::get_device_capabilities(&device_id).await?;
    match caps {
        crate::device_capabilities::DeviceCapabilities::Weather(w) => Ok(w),
        _ => Err(SkotiqError::not_supported(
            &device_id,
            "Device is not a weather station",
        )),
    }
}

/// Get safety monitor capabilities for a specific safety monitor device.
pub async fn api_get_safety_monitor_capabilities(
    device_id: String,
) -> Result<crate::device_capabilities::SafetyMonitorCapabilities, SkotiqError> {
    let caps = crate::device_capabilities::get_device_capabilities(&device_id).await?;
    match caps {
        crate::device_capabilities::DeviceCapabilities::SafetyMonitor(sm) => Ok(sm),
        _ => Err(SkotiqError::not_supported(
            &device_id,
            "Device is not a safety monitor",
        )),
    }
}

/// Get switch capabilities for a specific switch device.
pub async fn api_get_switch_capabilities(
    device_id: String,
) -> Result<crate::device_capabilities::SwitchCapabilities, SkotiqError> {
    let caps = crate::device_capabilities::get_device_capabilities(&device_id).await?;
    match caps {
        crate::device_capabilities::DeviceCapabilities::Switch(s) => Ok(s),
        _ => Err(SkotiqError::not_supported(
            &device_id,
            "Device is not a switch",
        )),
    }
}

// Device quirks

/// Information about a known device quirk, suitable for UI display.
pub struct QuirkInfo {
    /// Quirk category (e.g. "Temperature", "Timing", "Discovery")
    pub category: String,
    /// Human-readable description of the quirk
    pub description: String,
}

/// Get known quirks for a connected device.
///
/// Returns a list of known device characteristics and workarounds that are
/// automatically applied. This information can be displayed in the equipment
/// screen to inform users about device-specific behaviors.
#[flutter_rust_bridge::frb(sync)]
pub fn api_get_device_quirks(device_id: String) -> Vec<QuirkInfo> {
    let quirks = skotiq_native::quirks::get_quirks_for_device(&device_id);
    quirks
        .into_iter()
        .map(|q| QuirkInfo {
            category: q.category().to_string(),
            description: q.description(),
        })
        .collect()
}

// QHY discovery control

/// Check if QHY camera discovery is enabled.
///
/// QHY discovery can be disabled if the QHY SDK causes crashes or hangs on the
/// user's system. When disabled, QHY cameras will not appear in device discovery.
#[flutter_rust_bridge::frb(sync)]
pub fn api_is_qhy_discovery_enabled() -> bool {
    skotiq_native::vendor::qhy::is_qhy_discovery_enabled()
}

/// Enable or disable QHY camera discovery, for systems where the QHY SDK crashes
/// or hangs during enumeration. While disabled, `discover_devices()` returns no
/// QHY cameras or filter wheels; existing QHY connections are unaffected. The
/// setting lasts for the session and resets on restart.
#[flutter_rust_bridge::frb(sync)]
pub fn api_set_qhy_discovery_enabled(enabled: bool) {
    skotiq_native::vendor::qhy::set_qhy_discovery_enabled(enabled);
}

/// Get information about QHY SDK availability and discovery status.
#[flutter_rust_bridge::frb(sync)]
pub fn api_get_qhy_discovery_status() -> QhyDiscoveryStatus {
    QhyDiscoveryStatus {
        sdk_available: skotiq_native::vendor::qhy::is_sdk_available(),
        discovery_enabled: skotiq_native::vendor::qhy::is_qhy_discovery_enabled(),
        timeout_ms: get_qhy_discovery_timeout_ms(),
    }
}

/// Helper to get the QHY discovery timeout from quirks
pub(crate) fn get_qhy_discovery_timeout_ms() -> u64 {
    use skotiq_native::quirks::{get_quirks_for_vendor, DiscoveryQuirk, Quirk};
    use skotiq_native::NativeVendor;

    let quirks = get_quirks_for_vendor(&NativeVendor::Qhy);
    for quirk in quirks {
        if let Quirk::Discovery(DiscoveryQuirk::DiscoveryTimeoutMs(timeout)) = quirk {
            return timeout;
        }
    }
    10000 // Default timeout
}

/// Status information about QHY discovery
#[derive(Debug, Clone)]
pub struct QhyDiscoveryStatus {
    /// Whether the QHY SDK DLL/SO was loaded successfully
    pub sdk_available: bool,
    /// Whether QHY discovery is currently enabled
    pub discovery_enabled: bool,
    /// The timeout for discovery operations in milliseconds
    pub timeout_ms: u64,
}
