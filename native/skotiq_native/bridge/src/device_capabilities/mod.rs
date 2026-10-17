//! Device Capability Reporting
//!
//! This module provides standardized capability reporting for all device types.
//! Capabilities describe what operations a device supports, allowing the UI
//! and sequencer to adapt to device limitations.
//!
//! # Connect/Disconnect-probe guard
//!
//! A capability probe for an Alpaca or ASCOM device probes `is_connected()`
//! before it touches the connection, because a blind
//! `connect → read properties → disconnect` cycle drops a session the user
//! already has open in the UI.
//!
//! * `Ok(true)` — the device is already up: read the properties and issue no
//!   connect/disconnect.
//! * `Ok(false)` — run the full connect/probe/disconnect cycle.
//! * `Err` (the driver does not implement `Connected`, or the call failed
//!   mid-transition) — treat the device as already connected.
//!
//! `Err` resolves that way because the two mistakes are not symmetric:
//! skipping a disconnect leaves a short-lived connection the device manager
//! cleans up on its normal lifecycle, while issuing one against a driver
//! mid-operation can corrupt a live exposure or slew.
//!
//! # `as`-cast policy
//!
//! All `as` casts in this file are capability-probe widenings:
//! - **Sensor i32 → u32** (ASCOM `CameraXSize` / `CameraYSize`): int per spec
//!   and ≥ 1 physically; `unwrap_or(0)` on the optional probe maps a
//!   missing/failed read to 0, which the UI renders as "unknown".
//! - **usize → i32 filter count**: physical filter wheels have ≤ 16 slots, so
//!   saturation at `i32::MAX` is unreachable.
//! - **i32 → i32 filter position**: a no-op widening kept for clarity around
//!   the `.map(|p| p as i32)` Option-mapping idiom.
//!
//! # Example
//!
//! ```rust
//! let caps = api_get_mount_capabilities(mount_id).await?;
//! if caps.can_pulse_guide {
//!     // Enable PHD2-style guiding
//! }
//! ```

use crate::device_id::parse_device_id_cached;
use crate::error::SkotiqError;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};
use tokio::sync::{Mutex, RwLock};
// Re-use enums from device module to avoid FRB conflicts
use crate::device::{CalibratorState, CoverState, TrackingRate};

// Import native traits for connect/disconnect and live filter-wheel queries.
#[cfg(windows)]
use skotiq_native::traits::{NativeDevice, NativeFilterWheel};

pub(crate) mod alpaca;
pub(crate) use alpaca::*;
pub(crate) mod ascom;
pub(crate) use ascom::*;
pub(crate) mod cache;
pub(crate) use cache::*;
pub(crate) mod indi;
pub(crate) use indi::*;
pub(crate) mod native;
pub(crate) use native::*;
pub(crate) mod simulator;
pub(crate) use simulator::*;
#[cfg(test)]
mod tests;
pub(crate) mod types;
pub use types::*;

/// Re-read the LIVE readings that share the capability structs, overwriting
/// whatever the cache is holding for them.
///
/// # Why this exists
///
/// The capability structs mix two very different kinds of value: static
/// feature flags (`can_park`, `max_bin_x`, `position_count`) that only change
/// when hardware is swapped, and live readings (`ccd_temperature`,
/// `cooler_on`, `current_position`, `is_moving`, `is_safe`) that change every
/// second. [`CAPABILITY_CACHE_TTL`] is 5 minutes, so the live readings were
/// being served up to 5 minutes stale — as a confident, unqualified value.
///
/// Measured on the live rig against a real ZWO ASI1600MM-Cool and ZWO EFW:
/// after `POST /api/camera/cooling {"enabled":true,"targetTemp":10}`,
/// `GET /api/equipment/camera/capabilities` kept reporting
/// `coolerOn: false, setCcdTemperature: -10, ccdTemperature: 14.8,
/// coolerPower: 0` for **259 seconds** while `GET /api/camera/cooling`
/// correctly showed the cooler on, the setpoint at 10 °C, the sensor falling
/// 14.8 → 10.1 °C and the cooler drawing up to 11 %. It flipped to the truth
/// at t=275 s, matching the TTL. Identically, the filter wheel reported
/// `currentPosition: 0` across four consecutive polls while the wheel was
/// physically at slot 7 and both `/api/filter-wheel/position` and
/// `/api/equipment/filter-wheel/status` correctly said 7.
///
/// The cache is still worth keeping: for ASCOM/Alpaca the *static* probe can
/// connect and disconnect the driver (see the module header), which is what
/// must not run on every poll. Re-reading a single live value uses the same
/// always-live device-manager accessors the `/api/equipment/*/status`
/// endpoints already poll at 500 ms, so it adds no new access pattern.
///
/// Failures leave the cached value untouched: this exists to remove stale
/// readings, not to introduce a new way for a capability read to fail.
///
/// Not covered: [`DeviceCapabilities::Switch`] — refreshing it needs one
/// round trip per switch, and [`WeatherCapabilities`] has no live fields.
async fn refresh_volatile_state(device_id: &str, capabilities: &mut DeviceCapabilities) {
    let mgr = crate::api::get_device_manager();
    match capabilities {
        DeviceCapabilities::Camera(caps) => {
            if let Ok(status) = mgr.camera_get_status(device_id).await {
                caps.ccd_temperature = status.sensor_temp;
                caps.set_ccd_temperature = status.target_temp;
                caps.cooler_power = status.cooler_power;
                caps.cooler_on = Some(status.cooler_on);
            }
        }
        DeviceCapabilities::FilterWheel(caps) => {
            if let Ok(position) = mgr.filter_wheel_get_position(device_id).await {
                // The vendor SDKs report -1 while the wheel is in motion;
                // publishing that as a slot index would be a different lie.
                caps.current_position = if position >= 0 { Some(position) } else { None };
            }
            if let Ok(is_moving) = mgr.filter_wheel_is_moving(device_id).await {
                caps.is_moving = is_moving;
            }
            if let Ok((_, names)) = mgr.filter_wheel_get_config(device_id).await {
                if !names.is_empty() {
                    caps.filter_names = names;
                }
            }
        }
        DeviceCapabilities::Focuser(caps) => {
            if let Ok(position) = mgr.focuser_get_position(device_id).await {
                caps.position = Some(position);
            }
            if let Ok(is_moving) = mgr.focuser_is_moving(device_id).await {
                caps.is_moving = is_moving;
            }
            if let Ok(temperature) = mgr.focuser_get_temp(device_id).await {
                caps.temperature = temperature;
            }
        }
        DeviceCapabilities::Rotator(caps) => {
            if let Ok(position) = mgr.rotator_get_position(device_id).await {
                caps.position = Some(position);
            }
            if let Ok(is_moving) = mgr.rotator_is_moving(device_id).await {
                caps.is_moving = is_moving;
            }
        }
        DeviceCapabilities::Mount(caps) => {
            if let Ok(status) = mgr.mount_get_status(device_id).await {
                caps.tracking = Some(status.tracking);
                if let Some(rate) = status.tracking_rate {
                    caps.tracking_rate = Some(rate);
                }
            }
        }
        DeviceCapabilities::Dome(caps) => {
            if let Ok(status) = mgr.dome_get_status(device_id).await {
                caps.azimuth = Some(status.azimuth);
                caps.slewing = status.slewing;
                caps.at_home = status.at_home;
                caps.at_park = status.at_park;
                caps.slaved = status.is_slaved;
                caps.shutter_status = Some(match status.shutter_status {
                    crate::device::ShutterState::Open => ShutterStatus::Open,
                    crate::device::ShutterState::Closed => ShutterStatus::Closed,
                    crate::device::ShutterState::Opening => ShutterStatus::Opening,
                    crate::device::ShutterState::Closing => ShutterStatus::Closing,
                    crate::device::ShutterState::Error | crate::device::ShutterState::Unknown => {
                        ShutterStatus::Unknown
                    }
                });
            }
        }
        DeviceCapabilities::CoverCalibrator(caps) => {
            if let Ok(status) = mgr.cover_calibrator_get_status(device_id).await {
                caps.cover_state = Some(status.cover_state);
                caps.calibrator_state = Some(status.calibrator_state);
                caps.brightness = Some(status.brightness);
            }
        }
        DeviceCapabilities::SafetyMonitor(caps) => {
            // A 5-minute-stale `is_safe` is the worst case in this file: it is
            // the value a run consults before deciding to keep imaging.
            if let Ok(is_safe) = mgr.safety_is_safe(device_id).await {
                caps.is_safe = is_safe;
            }
        }
        DeviceCapabilities::Switch(caps) => {
            // A switch is precisely the thing an operator toggles and then
            // re-reads — dew heaters, flat panels, power ports — so a value
            // held for the 5-minute TTL is the same defect as the cooler that
            // reported `coolerOn: false` while it was running.
            //
            // This is the one device class that needs a round trip PER switch;
            // the enumeration itself (names, descriptions, ranges, writability)
            // is genuinely static and stays cached, so only the values are
            // re-read. A switch whose read fails keeps its cached value rather
            // than reporting a fabricated 0.
            for switch in caps.switches.iter_mut() {
                if let Ok(value) = mgr.switch_get_value(device_id, switch.index).await {
                    switch.value = value;
                }
            }
        }
        // WeatherCapabilities is entirely static `has_*` feature flags — the
        // live readings live on the weather status surface, not here.
        DeviceCapabilities::Weather(_) => {}
    }
}

/// Get capabilities for any device type
pub async fn get_device_capabilities(device_id: &str) -> Result<DeviceCapabilities, SkotiqError> {
    // Use cached parsing for better performance
    let parsed = parse_device_id_cached(device_id)?;

    {
        let cached = {
            let mut cache = capability_cache().lock().await;
            match cache.get(device_id) {
                Some(entry) if entry.timestamp.elapsed() < CAPABILITY_CACHE_TTL => {
                    Some(entry.capabilities.clone())
                }
                Some(_) => {
                    cache.remove(device_id);
                    None
                }
                None => None,
            }
        };
        if let Some(mut capabilities) = cached {
            // The cache exists to avoid re-running the EXPENSIVE static probe
            // (for ASCOM/Alpaca that probe may connect and disconnect the
            // driver — see the module header). It must not also freeze the
            // handful of LIVE readings that share these structs.
            refresh_volatile_state(device_id, &mut capabilities).await;
            return Ok(capabilities);
        }
    }

    // Return capability data from the backend-specific capability providers.
    let capabilities = match parsed.driver_type {
        crate::device::DriverType::Alpaca => get_alpaca_capabilities(device_id).await,
        crate::device::DriverType::Ascom => get_ascom_capabilities(device_id).await,
        crate::device::DriverType::Indi => get_indi_capabilities(device_id).await,
        crate::device::DriverType::Native => get_native_capabilities(device_id).await,
        crate::device::DriverType::Simulator => get_simulator_capabilities(&parsed).await,
    }?;

    let mut cache = capability_cache().lock().await;
    cache.insert(
        device_id.to_string(),
        CapabilityCacheEntry {
            capabilities: capabilities.clone(),
            timestamp: Instant::now(),
        },
    );

    Ok(capabilities)
}
