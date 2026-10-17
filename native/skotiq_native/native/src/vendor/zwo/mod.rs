//! ZWO ASI Camera SDK Wrapper
//!
//! Provides native support for ZWO ASI cameras by wrapping the ASI SDK.
//! The SDK is typically provided as a DLL (Windows) or shared library (macOS/Linux).
//!
//! ## Thread Safety
//!
//! The ASI SDK is NOT thread-safe. All SDK operations are protected by per-SDK
//! mutexes from `crate::sync`:
//! - `zwo_camera_mutex()` - ASI Camera SDK (ASICamera2.dll)
//! - `zwo_eaf_mutex()` - EAF Focuser SDK (EAF_focuser.dll)
//! - `zwo_efw_mutex()` - EFW Filter Wheel SDK (EFW_filter.dll)
//!
//! ## Timeout Handling
//!
//! All SDK operations that can potentially hang (exposure polling, image download,
//! focuser moves, filter wheel moves) have configurable timeouts via `NativeTimeoutConfig`.
//! Use the helper methods like `wait_for_exposure_complete`, `move_focuser_with_timeout`,
//! and `move_filterwheel_with_timeout` to ensure operations don't block indefinitely.

// c_long is i32 on Windows and i64 on Linux (LP64), so the `as i32` casts on
// SDK control values are identity on one platform and a real (documented,
// range-checked-by-contract) narrowing on the other. clippy::unnecessary_cast
// fires on whichever platform the cast is the identity — allow it file-wide
// rather than decorating every site; each cast carries its own comment.
#![allow(clippy::unnecessary_cast)]
#![allow(dead_code)] // FFI types must match SDK headers even if not all variants are used

use crate::camera::*;
use crate::sync::{zwo_camera_mutex, zwo_eaf_mutex, zwo_efw_mutex};
use crate::traits::*;
use crate::utils::{
    calculate_buffer_size_i32, safe_cstr_to_string, wait_for_exposure, wait_for_filterwheel_move,
    wait_for_focuser_move, CleanupGuard,
};
use crate::NativeVendor;
use async_trait::async_trait;
use skotiq_imaging::buffer_pool::global_u8_pool;
use std::collections::HashMap;
use std::ffi::{c_char, c_int, c_long, c_uchar, CStr};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};

mod camera;
mod camera_ops;
mod discovery;
mod ffi;
mod filter_wheel;
mod focuser;
mod sdk;
#[cfg(test)]
mod tests;

pub use camera::*;
pub use discovery::*;
use ffi::*;
pub use filter_wheel::*;
pub use focuser::*;
use sdk::*;

// Connected-device registries (EAF + EFW)
//
// Purpose: prevent hot-plug discovery polls from calling EAFOpen/EAFClose (or
// EFWOpen/EFWClose) on device IDs that are already held open by a live session.
// The ZWO SDKs share a single OS-level handle per device ID; calling Close on
// a connected device's ID closes the session's handle, causing the next SDK
// call from the session to return EAF_ERROR_CLOSED (9) / EFW_ERROR_CLOSED (9),
// which surfaces as spurious "Heartbeat failure" warnings in the UI.
//
// Lock ordering rule (must be respected everywhere to prevent deadlock):
//   Registry lock  MUST NOT be held while acquiring the SDK mutex.
//   Acquire registry lock → read/copy entry → RELEASE registry lock → then
//   acquire SDK mutex if needed. Discovery acquires the SDK mutex first (before
//   reading the registry), so inside the discovery loop the SDK mutex is
//   already held; acquiring the registry lock there (briefly, no SDK call
//   while holding it) is safe because the registry lock is never taken in the
//   other direction (registry → then SDK mutex).
//
// Both registries use std::sync::Mutex (not tokio::sync::Mutex) because all
// accesses are brief, synchronous, non-blocking, and must not span await points.

/// Cached EAF discovery metadata stored for a connected focuser.
/// Mirrors the fields of `ZwoFocuserDiscoveryInfo` exactly so discovery can
/// reconstruct a complete entry without opening the device.
#[derive(Clone)]
struct ConnectedEafEntry {
    focuser_id: i32,
    name: String,
    serial_number: Option<String>,
    sdk_version: Option<String>,
}

/// Cached EFW discovery metadata stored for a connected filter wheel.
/// Mirrors the fields of `ZwoFilterWheelDiscoveryInfo` exactly.
#[derive(Clone)]
struct ConnectedEfwEntry {
    filterwheel_id: i32,
    name: String,
    slot_count: i32,
    serial_number: Option<String>,
    sdk_version: Option<String>,
}

/// Registry of currently-connected EAF focusers keyed by SDK device ID.
/// Key is the `c_int` SDK id (same value as `ZwoFocuser::focuser_id`).
static CONNECTED_EAF: OnceLock<Mutex<HashMap<i32, ConnectedEafEntry>>> = OnceLock::new();

fn connected_eaf() -> &'static Mutex<HashMap<i32, ConnectedEafEntry>> {
    CONNECTED_EAF.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Registry of currently-connected EFW filter wheels keyed by SDK device ID.
/// Key is the `c_int` SDK id (same value as `ZwoFilterWheel::filterwheel_id`).
static CONNECTED_EFW: OnceLock<Mutex<HashMap<i32, ConnectedEfwEntry>>> = OnceLock::new();

fn connected_efw() -> &'static Mutex<HashMap<i32, ConnectedEfwEntry>> {
    CONNECTED_EFW.get_or_init(|| Mutex::new(HashMap::new()))
}
