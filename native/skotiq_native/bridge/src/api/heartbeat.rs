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

/// Device health as `(last_successful_comm_ms, is_healthy)`: when the device last
/// answered, and whether it is still responding to heartbeat checks.
pub async fn api_get_device_health(device_id: String) -> Result<(i64, bool), SkotiqError> {
    get_device_manager()
        .get_device_health(&device_id)
        .await
        .map_err(|e| SkotiqError::OperationFailed(e))
}
