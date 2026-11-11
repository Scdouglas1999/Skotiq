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

// Filter wheel control

/// Set filter wheel position. Simulators go through the `DeviceManager` like
/// every other driver, so the move publishes its events whoever asked.
pub async fn filter_wheel_set_position(
    device_id: String,
    position: i32,
) -> Result<(), SkotiqError> {
    get_device_manager()
        .filter_wheel_set_position(&device_id, position)
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
