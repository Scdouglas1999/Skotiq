//! libgphoto2 DSLR/Mirrorless Camera Driver
//!
//! Provides native support for DSLR and mirrorless cameras via the libgphoto2 library.
//! Supports Canon, Nikon, Sony, Pentax, and many other camera brands.
//!
//! ## Thread Safety
//!
//! libgphoto2 is NOT thread-safe. All library operations are protected by
//! `gphoto2_mutex()` from `crate::sync`.
//!
//! ## Important Behaviors
//!
//! 1. **Bulb mode**: For exposures > 30s, the camera must be set to Bulb mode.
//!    The driver holds the shutter open via `gp_camera_trigger_capture` + timed release.
//! 2. **ISO mapping**: ISO values are mapped to/from the gain parameter.
//!    ISO 100 = gain 0, ISO 200 = gain 1, etc. (index into available ISO list).
//! 3. **Image download**: After capture, the image is downloaded from camera storage
//!    as a RAW file and decoded to 16-bit pixel data via the raw pixel extraction path.
//! 4. **Live view**: Some cameras support live view preview via `gp_camera_capture_preview`.
//!
//! ## Library Requirements
//!
//! - libgphoto2 (libgphoto2.so / libgphoto2.dylib / libgphoto2.dll)
//! - libgphoto2_port (loaded automatically by libgphoto2)
//!
//! On Linux: `apt install libgphoto2-dev`
//! On macOS: `brew install libgphoto2`
//! On Windows: Install from https://github.com/gphoto/libgphoto2/releases

#![allow(dead_code)] // FFI types must match library headers even if not all are used

use crate::camera::*;
use crate::sync::gphoto2_mutex;
use crate::traits::*;
use crate::NativeVendor;
use async_trait::async_trait;
use std::ffi::{c_char, c_float, c_int, c_void, CStr, CString};
use std::time::{Duration, Instant};

mod camera;
mod camera_ops;
mod discovery;
mod ffi;
mod sdk;
#[cfg(test)]
mod tests;
mod utils;

pub use camera::*;
pub use discovery::*;
use ffi::*;
use sdk::*;
pub use utils::*;
