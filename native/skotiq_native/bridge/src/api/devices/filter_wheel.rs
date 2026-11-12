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
use crate::device_manager::get_device_manager;

/// Get filter wheel status
pub async fn api_get_filterwheel_status(
    device_id: String,
) -> Result<FilterWheelStatus, SkotiqError> {
    let mgr = get_device_manager();
    let position = mgr
        .filter_wheel_poll_position(&device_id)
        .await
        .map_err(SkotiqError::from)?;
    let is_moving = mgr
        .filter_wheel_poll_is_moving(&device_id, position)
        .await
        .map_err(SkotiqError::from)?;
    // debug, not info: this whole status path is polled every few seconds by
    // the dashboard/companions — at INFO it dominated the log volume.
    tracing::debug!(
        target: "skotiq_bridge::api::devices::filter_wheel",
        "[api_get_filterwheel_status] device={}, raw position from SDK={}",
        device_id,
        position
    );
    let (filter_count, filter_names) = mgr
        .filter_wheel_get_config(&device_id)
        .await
        .map_err(SkotiqError::from)?;

    tracing::debug!(
        target: "skotiq_bridge::api::devices::filter_wheel",
        "[api_get_filterwheel_status] Returning: position={}, moving={}, filter_count={}, names={:?}",
        position,
        is_moving,
        filter_count,
        filter_names
    );

    Ok(FilterWheelStatus {
        connected: true,
        position,
        moving: is_moving,
        filter_count,
        filter_names,
    })
}

/// Set filter wheel position
pub async fn api_filterwheel_set_position(
    device_id: String,
    position: i32,
) -> Result<(), SkotiqError> {
    tracing::info!(
        target: "skotiq_bridge::api::devices::filter_wheel",
        "[API] api_filterwheel_set_position called: device_id={}, position={}",
        device_id,
        position
    );
    tracing::info!(target: "skotiq_bridge::api::devices::filter_wheel", "[API] Using real device via DeviceManager");
    let mgr = get_device_manager();
    let result = mgr
        .filter_wheel_set_position(&device_id, position)
        .await
        .map_err(SkotiqError::from);
    match &result {
        Ok(_) => {
            tracing::info!(target: "skotiq_bridge::api::devices::filter_wheel", "[API] Filter wheel position set successfully")
        }
        Err(e) => {
            tracing::error!(target: "skotiq_bridge::api::devices::filter_wheel", "[API] Filter wheel set position failed: {:?}", e)
        }
    }
    result
}

/// Get filter names
pub async fn api_filterwheel_get_names(device_id: String) -> Result<Vec<String>, SkotiqError> {
    let mgr = get_device_manager();
    let (_, filter_names) = mgr
        .filter_wheel_get_config(&device_id)
        .await
        .map_err(SkotiqError::from)?;
    Ok(filter_names)
}

/// Set filter names on a filter wheel
/// This pushes user-defined filter names from the equipment profile to the hardware driver.
pub async fn api_filterwheel_set_filter_names(
    device_id: String,
    names: Vec<String>,
) -> Result<(), SkotiqError> {
    tracing::info!(target: "skotiq_bridge::api::devices::filter_wheel", "API: Setting filter names for '{}': {:?}", device_id, names);

    let mgr = get_device_manager();
    mgr.filter_wheel_set_filter_names(&device_id, names)
        .await
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to set filter names: {}", e)))?;
    Ok(())
}
