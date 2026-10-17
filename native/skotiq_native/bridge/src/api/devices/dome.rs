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

// Dome control

/// Get dome status
pub async fn api_get_dome_status(device_id: String) -> Result<DomeStatus, SkotiqError> {
    let mgr = get_device_manager();
    mgr.dome_get_status(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Open dome shutter
pub async fn api_dome_open_shutter(device_id: String) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.dome_open_shutter(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Close dome shutter
pub async fn api_dome_close_shutter(device_id: String) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.dome_close_shutter(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Slew dome to azimuth
pub async fn api_dome_slew_to_azimuth(
    device_id: String,
    azimuth: f64,
) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.dome_slew_to_azimuth(&device_id, azimuth)
        .await
        .map_err(SkotiqError::from)
}

/// Park dome
pub async fn api_dome_park(device_id: String) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.dome_park(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Get dome azimuth
pub async fn api_dome_get_azimuth(device_id: String) -> Result<f64, SkotiqError> {
    let mgr = get_device_manager();
    mgr.dome_get_azimuth(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Get dome shutter status
pub async fn api_dome_get_shutter_status(device_id: String) -> Result<i32, SkotiqError> {
    let mgr = get_device_manager();
    mgr.dome_get_shutter_status(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Check if dome is slewing
pub async fn api_dome_is_slewing(device_id: String) -> Result<bool, SkotiqError> {
    let mgr = get_device_manager();
    mgr.dome_is_slewing(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Enable or disable dome slaving to the mount
pub async fn api_dome_set_slaved(device_id: String, slaved: bool) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.dome_set_slaved(&device_id, slaved)
        .await
        .map_err(SkotiqError::from)
}

/// Find the dome home position
pub async fn api_dome_find_home(device_id: String) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.dome_find_home(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Abort dome slew / shutter motion
pub async fn api_dome_abort_slew(device_id: String) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.dome_abort_slew(&device_id)
        .await
        .map_err(SkotiqError::from)
}
