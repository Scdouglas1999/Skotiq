//! QHY Camera SDK Wrapper
//!
//! Provides native support for QHY cameras by wrapping the QHY SDK.
//! QHY cameras support advanced features like readout modes and sensor chamber readings.
//!
//! ## Thread Safety
//!
//! The QHY SDK is NOT thread-safe. Its function table is only reachable through
//! the guard from `QhySdk::lock()`, which holds the SDK's lock. QHY filter wheels
//! (CFW) are controlled through the camera SDK, so they share that lock.
//!
//! ## Safety Measures for Discovery
//!
//! The QHY SDK has been known to crash or hang during device enumeration on certain
//! systems. This module includes several safety measures:
//!
//! 1. **Enable/Disable Flag**: Discovery can be globally disabled if it causes issues
//! 2. **Panic Protection**: Discovery is wrapped in `catch_unwind` to prevent crashes
//! 3. **Timeout**: Discovery has a configurable timeout (default 10 seconds)
//! 4. **Lock Serialization**: All discovery calls are serialized by the `QhySdk` lock
//! 5. **Quirks Integration**: Discovery respects quirks from the vendor database

#![allow(dead_code)] // FFI types must match SDK headers even if not all variants are used

use async_trait::async_trait;
use skotiq_device::camera::*;
use skotiq_device::Vendor;
use skotiq_device::*;
use skotiq_imaging::buffer_pool::global_u8_pool;
use std::ffi::{c_char, c_double, c_int, c_uint, c_void, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

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
pub use ffi::*;
pub use filter_wheel::*;
pub use sdk::*;
