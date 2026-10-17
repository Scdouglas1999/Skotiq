//! Player One Camera SDK Wrapper
//!
//! Provides native support for Player One cameras by wrapping the POA SDK.
//! Player One cameras feature low read noise and built-in anti-dew heaters.
//!
//! ## Thread Safety
//!
//! The POA SDK is NOT thread-safe. All SDK operations are protected by
//! `player_one_mutex()` from `crate::sync` to prevent concurrent access.
//!
//! ## Timeout Handling
//!
//! All SDK operations that can potentially hang (exposure polling, image download)
//! have configurable timeouts via `NativeTimeoutConfig`.
//!
//! ## `unwrap_or` policy
//!
//! POA SDK property reads (`get_control_int`, `get_control_bool`, etc.)
//! return `Result<T, NativeError>` and may fail with `POA_ERROR_OPERATION_FAILED`
//! when the camera is mid-exposure or the control hasn't been initialised
//! yet. The cooler/gain/offset paths here default to the same "fall back to
//! cached value or zero" semantics as the other vendor crates:
//!
//! * `get_control_int(GAIN/OFFSET).unwrap_or(self.current_gain/offset)` — a
//!   failed read reports the value this driver last applied: the same two
//!   numbers become the FITS GAIN/OFFSET cards in `download_image`. The status
//!   poll stays non-fatal; the next tick retries the live read. `connect` seeds
//!   both from the camera's own registers so the fallback is a real value, and
//!   logs a WARN naming the control when that seed read fails — in that one
//!   case the fallback is the 0 the struct was constructed with, and the WARN
//!   is what makes it distinguishable from a camera genuinely set to 0.
//! * `live_enabled.unwrap_or(cached.enabled)` / `live_target_c.unwrap_or(cached.target_c)`
//!   — when live cooler probe fails, return the LAST KNOWN cached value
//!   rather than zeroing-out, so the UI doesn't flicker during transient
//!   SDK errors. The cache is updated only on a successful read.
//! * `unwrap_or(false)` on cooler-supported boolean probes — undeclared
//!   capability means "not present", matching the other vendor crates.
//! * `unwrap_or_else(|e| *e.into_inner())` on mutex `into_inner()` —
//!   recovers the cached state from a poisoned mutex during shutdown so
//!   `Drop` can still write final coordinates; the poison signal is logged
//!   via the upstream caller.

// c_long is i32 on Windows and i64 on Linux (LP64), so the `as i32` casts on
// SDK control values are identity on one platform and a real (documented,
// range-checked-by-contract) narrowing on the other. clippy::unnecessary_cast
// fires on whichever platform the cast is the identity — allow it file-wide
// rather than decorating every site; each cast carries its own comment.
#![allow(clippy::unnecessary_cast)]
#![allow(dead_code)] // FFI types must match SDK headers even if not all variants are used

use crate::camera::*;
use crate::sync::player_one_mutex;
use crate::traits::*;
use crate::utils::{
    calculate_buffer_size_i32, safe_cstr_to_string, wait_for_exposure, CleanupGuard,
};
use crate::NativeVendor;
use async_trait::async_trait;
use skotiq_imaging::buffer_pool::global_u8_pool;
use std::ffi::{c_char, c_int, c_long, CStr};
use std::sync::Mutex;

mod camera;
mod camera_ops;
mod discovery;
mod ffi;
mod filter_wheel;
mod sdk;
#[cfg(test)]
mod tests;

pub use camera::*;
pub use discovery::*;
use ffi::*;
pub use filter_wheel::*;
pub use sdk::*;

// Cooler state tracking

/// Cooler state tracked at the driver level.
///
/// The POA SDK does not provide a guaranteed-to-succeed read-back for the
/// `POA_COOLER` register on every camera/firmware. We mirror the Atik pattern
/// (see `vendor/atik.rs`) and remember the last successfully written state so
/// `get_status` can report it accurately even when the SDK read-back path is
/// unavailable. When `POAGetConfig(POA_COOLER)` succeeds, that authoritative
/// value wins and the cached state is refreshed to match.
#[derive(Debug, Clone, Copy)]
pub(crate) struct CoolerState {
    pub(crate) enabled: bool,
    pub(crate) target_c: f64,
}

impl Default for CoolerState {
    fn default() -> Self {
        Self {
            enabled: false,
            target_c: 0.0,
        }
    }
}
