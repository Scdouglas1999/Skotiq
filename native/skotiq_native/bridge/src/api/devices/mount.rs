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

// Mount control

/// Slew mount to coordinates
pub async fn mount_slew(device_id: String, ra: f64, dec: f64) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_slew(&device_id, ra, dec)
        .await
        .map_err(SkotiqError::from)
}

/// Sync mount to coordinates
pub async fn mount_sync(device_id: String, ra: f64, dec: f64) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_sync(&device_id, ra, dec)
        .await
        .map_err(SkotiqError::from)
}

/// Park mount
pub async fn mount_park(device_id: String) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_park(&device_id).await.map_err(SkotiqError::from)
}

/// Unpark mount
pub async fn mount_unpark(device_id: String) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_unpark(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Get mount coordinates
pub async fn mount_get_coordinates(device_id: String) -> Result<(f64, f64), SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_get_coordinates(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Abort mount slew
pub async fn mount_abort(device_id: String) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_abort(&device_id).await.map_err(SkotiqError::from)
}

/// Stop mount motion (abort slew without disconnecting)
pub async fn mount_stop(device_id: String) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_stop(&device_id).await.map_err(SkotiqError::from)
}

/// Query whether a mount supports parking
pub async fn mount_can_park(device_id: String) -> Result<bool, SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_can_park(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Set mount tracking
pub async fn mount_set_tracking(device_id: String, enabled: u8) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_set_tracking(&device_id, enabled != 0)
        .await
        .map_err(SkotiqError::from)
}

/// Set mount tracking rate (0=Sidereal, 1=Lunar, 2=Solar, 3=King)
pub async fn mount_set_tracking_rate(device_id: String, rate: i32) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_set_tracking_rate(&device_id, rate)
        .await
        .map_err(SkotiqError::from)
}

/// Pulse guide mount
pub async fn mount_pulse_guide(
    device_id: String,
    direction: String,
    duration_ms: u32,
) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_pulse_guide(&device_id, direction, duration_ms)
        .await
        .map_err(SkotiqError::from)
}

/// Get mount status
pub async fn mount_get_status(device_id: String) -> Result<MountStatus, SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_get_status(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Get mount tracking rate (0=Sidereal, 1=Lunar, 2=Solar, 3=King)
pub async fn mount_get_tracking_rate(device_id: String) -> Result<i32, SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_get_tracking_rate(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Move mount axis at specified rate (degrees/second)
/// axis: 0=RA/Azimuth (primary), 1=Dec/Altitude (secondary)
/// rate: degrees per second (positive = N/E, negative = S/W), 0 to stop
pub async fn mount_move_axis(device_id: String, axis: i32, rate: f64) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_move_axis(&device_id, axis, rate)
        .await
        .map_err(SkotiqError::from)
}

/// Slew mount to alt/az coordinates (altitude in degrees, azimuth in degrees)
pub async fn mount_slew_alt_az(
    device_id: String,
    altitude: f64,
    azimuth: f64,
) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_slew_alt_az(&device_id, altitude, azimuth)
        .await
        .map_err(SkotiqError::from)
}

/// Find mount home position
pub async fn mount_find_home(device_id: String) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_find_home(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Which site/time directions this mount can honour.
///
/// The reconciliation card asks the operator which way to copy; asking about a
/// direction the driver will refuse wastes their decision.
pub async fn mount_site_capabilities(
    device_id: String,
) -> Result<MountSiteCapabilities, SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_site_capabilities(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Read the site the mount itself is configured for.
pub async fn mount_get_site(device_id: String) -> Result<MountSite, SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_get_site(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Write a site into the mount. Longitude is EAST-positive.
pub async fn mount_set_site(
    device_id: String,
    latitude_deg: f64,
    longitude_deg: f64,
    elevation_m: Option<f64>,
) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_set_site(
        &device_id,
        MountSite {
            latitude_deg,
            longitude_deg,
            elevation_m,
        },
    )
    .await
    .map_err(SkotiqError::from)
}

/// Read the mount's clock.
pub async fn mount_get_time(device_id: String) -> Result<MountTimeInfo, SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_get_time(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Write a clock into the mount. `utc_offset_hours` is east of UTC in the
/// ordinary sense (US Eastern Standard is -5.0).
pub async fn mount_set_time(
    device_id: String,
    utc_unix_seconds: i64,
    utc_offset_hours: f64,
) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_set_time(
        &device_id,
        MountTimeInfo {
            utc_unix_seconds,
            utc_offset_hours,
        },
    )
    .await
    .map_err(SkotiqError::from)
}
