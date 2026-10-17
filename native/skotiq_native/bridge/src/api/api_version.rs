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

/// Get the API version information for a connected device.
///
/// This queries the device's interface version, driver version, and supported actions.
/// For Alpaca devices, this uses the InterfaceVersion property.
/// For ASCOM devices, this uses the InterfaceVersion COM property.
/// For INDI devices, this returns the protocol version from the server greeting.
///
/// Returns cached version info if available and fresh (less than 5 minutes old),
/// otherwise queries the device directly.
pub async fn api_get_device_api_version(
    device_id: String,
) -> Result<DeviceApiVersion, SkotiqError> {
    // First check cached version
    if let Some(cached) = get_device_manager()
        .get_device_api_version(&device_id)
        .await
    {
        if cached.is_fresh() {
            return Ok(cached);
        }
    }

    // Query fresh version info
    get_device_manager()
        .query_device_api_version(&device_id)
        .await
        .map_err(|e| SkotiqError::DeviceNotFound(e))
}

/// Check if a device supports a specific interface version.
///
/// This is useful for checking if newer API methods are available before calling them.
/// Returns true if the device reports an interface version >= the required version,
/// and false when version information is unavailable.
pub async fn api_device_supports_version(
    device_id: String,
    required_version: u32,
) -> Result<bool, SkotiqError> {
    Ok(get_device_manager()
        .device_supports_version(&device_id, required_version)
        .await)
}

/// Check if a device supports a specific action.
///
/// For ASCOM/Alpaca devices, checks the SupportedActions list.
/// Returns true only when the action is explicitly reported as supported.
pub async fn api_device_supports_action(
    device_id: String,
    action: String,
) -> Result<bool, SkotiqError> {
    Ok(get_device_manager()
        .device_supports_action(&device_id, &action)
        .await)
}
