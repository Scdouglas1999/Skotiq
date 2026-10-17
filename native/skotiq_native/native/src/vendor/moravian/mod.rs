//! Moravian Instruments Camera Native Driver
//!
//! Provides FFI bindings to the current Moravian gxccd SDK (`libgxccd.so` /
//! `gxccd.dll`) used by G2/G3/G4/C-series cameras.
//!
//! ABI ground truth is the vendor header `gxccd.h`. The snake_case `gxccd_*`
//! API is handle-based: `gxccd_enumerate_usb(callback)` yields integer camera
//! IDs, `gxccd_initialize_usb(id)` returns an opaque `camera_t*` (NULL on
//! error), and `gxccd_release(cam)` tears it down. Every other call takes the
//! handle and returns `0` on success / `-1` on error (NOT a boolean TRUE); on
//! `-1` the human-readable reason is fetched with `gxccd_get_last_error()`.
//!
//! Capture model (gxccd.h:365-435): the ROI is supplied to
//! `gxccd_start_exposure(cam, seconds, use_shutter, x, y, w, h)` in *binned*
//! coordinates, the exposure is polled with `gxccd_image_ready(cam, &ready)`,
//! and the digitized frame is copied out with `gxccd_read_image(cam, buf, size)`
//! where `size = binned_w * binned_h * 2` bytes. The returned buffer is
//! bottom-up (pixel [0,0] at bottom-left, gxccd.h:416-434); we vertically mirror
//! it to the top-down orientation the rest of the pipeline expects, mirroring
//! the reference driver (indi-mi/mi_ccd.cpp `mirror_image`, lines 609-627,657).

use crate::camera::{
    BayerPattern, CameraCapabilities, CameraState, CameraStatus, ExposureParams, ImageData,
    ImageMetadata, ReadoutMode, SensorInfo, SubFrame, VendorFeatures,
};
use crate::sync::moravian_mutex;
use crate::traits::{NativeCamera, NativeDevice, NativeError};
use crate::utils::CleanupGuard;
use crate::NativeVendor;
use async_trait::async_trait;
use std::ffi::{c_char, c_double, c_float, c_int, c_void};
use std::sync::{Arc, Mutex};

mod camera;
mod camera_ops;
mod discovery;
mod ffi;
mod helpers;
mod sdk;
#[cfg(test)]
mod tests;

pub use camera::*;
pub use discovery::*;
use ffi::*;
use helpers::*;
use sdk::*;
