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

// Switch control

/// Get the number of switches exposed by a switch device
pub async fn api_switch_get_max(device_id: String) -> Result<i32, SkotiqError> {
    let mgr = get_device_manager();
    mgr.switch_get_max(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Get the boolean state of a switch
pub async fn api_switch_get_state(
    device_id: String,
    switch_id: i32,
) -> Result<bool, SkotiqError> {
    let mgr = get_device_manager();
    mgr.switch_get_state(&device_id, switch_id)
        .await
        .map_err(SkotiqError::from)
}

/// Set the boolean state of a switch
pub async fn api_switch_set_state(
    device_id: String,
    switch_id: i32,
    state: bool,
) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.switch_set_state(&device_id, switch_id, state)
        .await
        .map_err(SkotiqError::from)
}

/// Get the name of a switch
pub async fn api_switch_get_name(
    device_id: String,
    switch_id: i32,
) -> Result<String, SkotiqError> {
    let mgr = get_device_manager();
    mgr.switch_get_name(&device_id, switch_id)
        .await
        .map_err(SkotiqError::from)
}

/// Get the description of a switch
pub async fn api_switch_get_description(
    device_id: String,
    switch_id: i32,
) -> Result<String, SkotiqError> {
    let mgr = get_device_manager();
    mgr.switch_get_description(&device_id, switch_id)
        .await
        .map_err(SkotiqError::from)
}

/// Get the numeric value of a switch
pub async fn api_switch_get_value(
    device_id: String,
    switch_id: i32,
) -> Result<f64, SkotiqError> {
    let mgr = get_device_manager();
    mgr.switch_get_value(&device_id, switch_id)
        .await
        .map_err(SkotiqError::from)
}

/// Set the numeric value of a switch
pub async fn api_switch_set_value(
    device_id: String,
    switch_id: i32,
    value: f64,
) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.switch_set_value(&device_id, switch_id, value)
        .await
        .map_err(SkotiqError::from)
}

/// Get the minimum value for a switch
pub async fn api_switch_get_min_value(
    device_id: String,
    switch_id: i32,
) -> Result<f64, SkotiqError> {
    let mgr = get_device_manager();
    mgr.switch_get_min_value(&device_id, switch_id)
        .await
        .map_err(SkotiqError::from)
}

/// Get the maximum value for a switch
pub async fn api_switch_get_max_value(
    device_id: String,
    switch_id: i32,
) -> Result<f64, SkotiqError> {
    let mgr = get_device_manager();
    mgr.switch_get_max_value(&device_id, switch_id)
        .await
        .map_err(SkotiqError::from)
}

/// Check if a switch can be written to
pub async fn api_switch_can_write(
    device_id: String,
    switch_id: i32,
) -> Result<bool, SkotiqError> {
    let mgr = get_device_manager();
    mgr.switch_can_write(&device_id, switch_id)
        .await
        .map_err(SkotiqError::from)
}
