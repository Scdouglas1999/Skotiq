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

// Focuser control

/// Get focuser status
pub async fn api_get_focuser_status(device_id: String) -> Result<FocuserStatus, SkotiqError> {
    let mgr = get_device_manager();

    let position = mgr
        .focuser_get_position(&device_id)
        .await
        .map_err(SkotiqError::from)?;
    let moving = mgr
        .focuser_is_moving(&device_id)
        .await
        .map_err(SkotiqError::from)?;
    let temperature = mgr.focuser_get_temp(&device_id).await.unwrap_or(None);
    let (max_position, step_size) = match mgr.focuser_get_details(&device_id).await {
        Ok(details) => details,
        Err(e) => {
            tracing::warn!(
                "Failed to get focuser details for {}: {:?}. Returning unknown max/step values.",
                device_id,
                e
            );
            (0, 0.0)
        }
    };
    let is_absolute = mgr
        .focuser_is_absolute(&device_id)
        .await
        .map_err(SkotiqError::from)?;

    Ok(FocuserStatus {
        connected: true,
        position,
        moving,
        temperature,
        max_position,
        step_size,
        is_absolute,
        has_temperature: temperature.is_some(),
    })
}

/// Move focuser to position
pub async fn api_focuser_move_to(device_id: String, position: i32) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.focuser_move_abs(&device_id, position)
        .await
        .map_err(SkotiqError::from)
}

/// Move focuser by relative amount
pub async fn api_focuser_move_relative(device_id: String, delta: i32) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.focuser_move_rel(&device_id, delta)
        .await
        .map_err(SkotiqError::from)
}

/// Halt focuser
pub async fn api_focuser_halt(device_id: String) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.focuser_halt(&device_id)
        .await
        .map_err(SkotiqError::from)
}
