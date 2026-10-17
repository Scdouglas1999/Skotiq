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

// Cover calibrator control (flat panel / dust cover)

/// Open cover calibrator dust cover
pub async fn api_cover_calibrator_open_cover(device_id: String) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.cover_calibrator_open_cover(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Close cover calibrator dust cover
pub async fn api_cover_calibrator_close_cover(device_id: String) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.cover_calibrator_close_cover(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Halt cover calibrator cover movement
pub async fn api_cover_calibrator_halt_cover(device_id: String) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.cover_calibrator_halt_cover(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Turn on cover calibrator light at specified brightness
pub async fn api_cover_calibrator_calibrator_on(
    device_id: String,
    brightness: i32,
) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.cover_calibrator_calibrator_on(&device_id, brightness)
        .await
        .map_err(SkotiqError::from)
}

/// Turn off cover calibrator light
pub async fn api_cover_calibrator_calibrator_off(device_id: String) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.cover_calibrator_calibrator_off(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Get cover calibrator cover state (0=NotPresent, 1=Closed, 2=Moving, 3=Open, 4=Unknown, 5=Error)
pub async fn api_cover_calibrator_get_cover_state(device_id: String) -> Result<i32, SkotiqError> {
    let mgr = get_device_manager();
    mgr.cover_calibrator_get_cover_state(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Get cover calibrator calibrator state (0=NotPresent, 1=Off, 2=NotReady, 3=Ready, 4=Unknown, 5=Error)
pub async fn api_cover_calibrator_get_calibrator_state(
    device_id: String,
) -> Result<i32, SkotiqError> {
    let mgr = get_device_manager();
    mgr.cover_calibrator_get_calibrator_state(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Get cover calibrator current brightness
pub async fn api_cover_calibrator_get_brightness(device_id: String) -> Result<i32, SkotiqError> {
    let mgr = get_device_manager();
    mgr.cover_calibrator_get_brightness(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Get cover calibrator maximum brightness
pub async fn api_cover_calibrator_get_max_brightness(
    device_id: String,
) -> Result<i32, SkotiqError> {
    let mgr = get_device_manager();
    mgr.cover_calibrator_get_max_brightness(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Get cover calibrator full status
pub async fn api_cover_calibrator_get_status(
    device_id: String,
) -> Result<crate::device::CoverCalibratorStatus, SkotiqError> {
    let mgr = get_device_manager();
    mgr.cover_calibrator_get_status(&device_id)
        .await
        .map_err(SkotiqError::from)
}
