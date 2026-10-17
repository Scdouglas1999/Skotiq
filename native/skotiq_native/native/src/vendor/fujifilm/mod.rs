//! Fujifilm X Acquire SDK Wrapper
//!
//! Provides native support for Fujifilm cameras (GFX and X-series) via the X Acquire SDK.
//! The SDK is Windows-only and provided as XAPI.dll plus model-specific DLLs.
//!
//! ## Thread Safety
//!
//! The Fujifilm SDK is NOT thread-safe. All SDK operations are protected by
//! `fujifilm_mutex()` from `crate::sync`.
//!
//! ## Important SDK Behaviors
//!
//! 1. **Dynamic Range First**: Must set DR to 100 before querying ISO values
//! 2. **100ms Delays**: Required between operations for hardware settling
//! 3. **Retry Detection**: Camera detection may need 3 attempts with exponential backoff
//! 4. **Bulb Sequence**: Must follow exact S1ON → BULBS2_ON → wait → N_BULBS1OFF sequence
//!
//! ## SDK Requirements
//!
//! - XAPI.dll (main SDK)
//! - FF0000API.dll through FF0020API.dll (model-specific modules)
//!
//! Based on the Nina Fujifilm plugin: https://github.com/Scdouglas1999/NINA-Fujifilm-Native-Plugin

#![cfg(target_os = "windows")]
#![allow(dead_code)] // FFI types must match SDK headers even if not all variants are used

use crate::camera::*;
use crate::sync::fujifilm_mutex;
use crate::traits::*;
use crate::NativeVendor;
use async_trait::async_trait;
use std::ffi::{c_char, c_long, c_ulong, c_void, CString};
use std::path::PathBuf;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

mod camera;
mod camera_ops;
mod discovery;
mod ffi;
mod models;
mod raw;
mod sdk;
#[cfg(test)]
mod tests;

pub use camera::*;
pub use discovery::*;
use ffi::*;
pub use models::*;
use raw::*;
use sdk::*;
