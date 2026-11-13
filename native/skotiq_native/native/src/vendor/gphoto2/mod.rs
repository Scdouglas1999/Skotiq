//! libgphoto2 DSLR/Mirrorless Camera Driver
//!
//! Provides native support for DSLR and mirrorless cameras via the libgphoto2 library.
//! Supports Canon, Nikon, Sony, Pentax, and many other camera brands.
//!
//! ## Thread Safety
//!
//! libgphoto2 is NOT thread-safe. Camera operations reach its function table
//! only through an `SdkGuard`, which holds the gphoto2 SDK lock. Two paths run
//! without it and say so where they do: device discovery's autodetect scan and
//! the best-effort teardown in `Drop`.
//!
//! ## Important Behaviors
//!
//! 1. **Opening a body**: by its model and USB port, so each of several
//!    attached bodies opens as itself; a body that came back on a new port
//!    after a replug is found by its model.
//! 2. **Exposure**: one of the body's timed shutter speeds when it has the
//!    requested duration, else bulb held open for the request with the body's
//!    bulb control (Canon `eosremoterelease`, or the `bulb` toggle). A timed
//!    capture runs on a blocking thread until the camera has written it. The
//!    frame records what the camera did: the timed speed (or the camera's own
//!    record of it in the raw file), the measured bulb time, and the ISO the
//!    raw file records.
//! 3. **ISO as gain**: the gain the driver takes and reports is the ISO number
//!    itself; a request between the body's speeds goes to the nearest one, and
//!    Auto ISO is never offered.
//! 4. **Long exposure noise reduction** is switched off at connect where the
//!    body shows the setting.
//! 5. **Files**: of the files a capture writes (two for RAW+JPEG) the raw one
//!    is read and decoded to the 16-bit sensor mosaic. Files in the camera's
//!    memory are deleted once read, and before the next exposure when an
//!    earlier capture left any; files on the memory card stay there unless
//!    the exposure was aborted.
//! 6. **Live view**: Some cameras support live view preview via `gp_camera_capture_preview`.
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

use async_trait::async_trait;
use skotiq_device::camera::*;
use skotiq_device::Vendor;
use skotiq_device::*;
use std::ffi::{c_char, c_float, c_int, c_ulong, c_void, CStr, CString};
use std::time::{Duration, Instant};

mod camera;
mod camera_ops;
mod discovery;
mod exposure;
mod ffi;
mod models;
mod sdk;
mod settings;
#[cfg(test)]
mod tests;
mod utils;

pub use camera::*;
pub use discovery::*;
use ffi::*;
// libgphoto2's file handle; the device layer's `CameraFile` is named by path.
use ffi::CameraFile;
use sdk::*;
use settings::*;
pub use utils::*;
