//! Fujifilm X Acquire SDK Wrapper
//!
//! Provides native support for Fujifilm cameras (GFX and X-series) via the X Acquire SDK.
//! The SDK is Windows-only and provided as XAPI.dll plus model-specific DLLs. The rules
//! that turn a request into camera settings (`exposure`, `errors`, `models`), lens
//! positions into focus pulses (`focus`) and decide when live view runs (`live_view`)
//! build on every platform so they are tested everywhere.
//!
//! ## Thread Safety
//!
//! The Fujifilm SDK is NOT thread-safe. Its function table is reached through
//! the guard from `FujifilmSdk::lock()`, which holds the SDK's lock.
//!
//! ## SDK behavior this driver depends on
//!
//! From the SDK Programming Reference and the owner's FujiCOM driver and NINA plugin,
//! both proven on real bodies:
//!
//! 1. **Dynamic range first**: set DR to 100 before querying ISO values.
//! 2. **Open by enumeration index**: `XSDK_OpenEx` takes "ENUM:<n>" (n from the
//!    last `XSDK_Detect`), not a serial number.
//! 3. **600 ms after close**: the reference requires it before the SDK is used again.
//! 4. **Bulb**: `XSDK_SetShutterSpeed(BULB, lBulb = 1)`, then S1ON, a 500 ms pause,
//!    BULBS2_ON, wait, N_BULBS1OFF.
//! 5. **The buffer**: `XSDK_ReadImage` removes the frame it returns; a cancelled
//!    exposure still leaves a frame behind, which must be discarded.
//! 6. **Detection may need retries** with backoff.
//! 7. **One open per body**: a second `XSDK_OpenEx` of an open body fails until it
//!    is power-cycled, so the camera and its lens focuser share one session
//!    (`session.rs`).
//!
//! ## SDK Requirements
//!
//! - XAPI.dll (main SDK)
//! - FF0000API.dll through FF0020API.dll (model-specific modules)

// FFI types mirror the SDK headers in full, and off Windows only tests use the rules.
#![allow(dead_code)]

mod errors;
mod exposure;
mod focus;
mod live_view;
mod models;

#[cfg(target_os = "windows")]
mod camera;
#[cfg(target_os = "windows")]
mod camera_ops;
#[cfg(target_os = "windows")]
mod discovery;
#[cfg(target_os = "windows")]
mod ffi;
#[cfg(target_os = "windows")]
mod lens;
#[cfg(target_os = "windows")]
mod raw;
#[cfg(target_os = "windows")]
mod sdk;
#[cfg(target_os = "windows")]
mod session;
#[cfg(test)]
mod tests;

pub use models::*;

#[cfg(target_os = "windows")]
use errors::*;
#[cfg(target_os = "windows")]
use exposure::*;
#[cfg(target_os = "windows")]
use focus::*;
#[cfg(target_os = "windows")]
use live_view::LiveViewDemand;

#[cfg(target_os = "windows")]
use async_trait::async_trait;
#[cfg(target_os = "windows")]
pub use camera::*;
#[cfg(target_os = "windows")]
pub use discovery::*;
#[cfg(target_os = "windows")]
use ffi::*;
#[cfg(target_os = "windows")]
pub use lens::FujifilmLens;
#[cfg(target_os = "windows")]
use raw::*;
#[cfg(target_os = "windows")]
use sdk::*;
#[cfg(target_os = "windows")]
use session::Session;
#[cfg(target_os = "windows")]
use skotiq_device::camera::*;
#[cfg(target_os = "windows")]
use skotiq_device::Vendor;
#[cfg(target_os = "windows")]
use skotiq_device::*;
#[cfg(target_os = "windows")]
use std::ffi::{c_char, c_long, c_ulong, c_void, CString};
#[cfg(target_os = "windows")]
use std::path::PathBuf;
#[cfg(target_os = "windows")]
use std::sync::{Arc, Mutex};
#[cfg(target_os = "windows")]
use std::time::{Duration, Instant};
