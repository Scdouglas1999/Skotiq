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
use skotiq_imaging::{
    calculate_airmass, validate_fits_header, validate_image, write_fits, BayerPattern,
    DebayerAlgorithm, FitsHeader, ImageData,
};
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
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

// Filter wheel control

/// Set filter wheel position
pub async fn filter_wheel_set_position(
    device_id: String,
    position: i32,
) -> Result<(), SkotiqError> {
    if device_id.starts_with("sim_") {
        let mut fw = get_sim_filterwheel().write().await;
        fw.status.position = position;
        Ok(())
    } else {
        let mgr = get_device_manager();
        mgr.filter_wheel_set_position(&device_id, position)
            .await
            .map_err(SkotiqError::from)
    }
}

/// Get filter wheel position
pub async fn filter_wheel_get_position(device_id: String) -> Result<i32, SkotiqError> {
    if device_id.starts_with("sim_") {
        let fw = get_sim_filterwheel().read().await;
        Ok(fw.status.position)
    } else {
        let mgr = get_device_manager();
        mgr.filter_wheel_get_position(&device_id)
            .await
            .map_err(SkotiqError::from)
    }
}

/// Get filter wheel configuration (count, names)
pub async fn filter_wheel_get_config(
    device_id: String,
) -> Result<(i32, Vec<String>), SkotiqError> {
    if device_id.starts_with("sim_") {
        let fw = get_sim_filterwheel().read().await;
        Ok((fw.status.filter_count, fw.status.filter_names.clone()))
    } else {
        let mgr = get_device_manager();
        mgr.filter_wheel_get_config(&device_id)
            .await
            .map_err(SkotiqError::from)
    }
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
