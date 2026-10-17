//! Touptek/OGMA Camera Native Driver
//!
//! Provides FFI bindings to the Touptek OGMA SDK (ogmacam.dll).
//! This SDK is used by many camera brands including:
//! - Touptek
//! - Altair Astro
//! - OGMA
//! - Mallincam
//! - And many other white-label brands

use crate::camera::{
    BayerPattern, CameraCapabilities, CameraState, CameraStatus, ExposureParams, ImageData,
    ImageMetadata, ReadoutMode, SensorInfo, SubFrame, VendorFeatures,
};
use crate::sync::touptek_mutex;
use crate::traits::{NativeCamera, NativeDevice, NativeError};
use crate::NativeVendor;
use async_trait::async_trait;
use libloading::Library;
use std::collections::HashMap;
#[cfg(not(windows))]
use std::ffi::CString;
use std::ffi::{c_char, c_int, c_uint, c_ushort, c_void, CStr};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};

mod camera;
mod camera_ops;
mod discovery;
mod ffi;
mod sdk;
#[cfg(test)]
mod tests;

pub use camera::*;
pub use discovery::*;
pub use ffi::*;
use sdk::*;
