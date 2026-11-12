//! Touptek/OGMA Camera Native Driver
//!
//! Provides FFI bindings to the Touptek OGMA SDK (ogmacam.dll).
//! This SDK is used by many camera brands including:
//! - Touptek
//! - Altair Astro
//! - OGMA
//! - Mallincam
//! - And many other white-label brands

use crate::camera_core::{CameraCore, SdkHandle};
use crate::vendor::sdk_loader::{SdkLock, SdkLockHeld, SdkUnavailable};
use async_trait::async_trait;
use libloading::Library;
use skotiq_device::camera::{
    BayerPattern, CameraCapabilities, CameraState, CameraStatus, ExposureParams, ImageData,
    ReadoutMode, SensorInfo, SubFrame, VendorFeatures,
};
use skotiq_device::Vendor;
use skotiq_device::{CameraDriver, DeviceDriver, DriverError};
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
