//! ToupTek-family cameras.
//!
//! ToupTek builds one camera SDK and ships it under each brand that sells its
//! cameras, with the brand's own library and function prefix (toupcam /
//! `Toupcam_`, ogmacam / `Ogmacam_`, altaircam / `Altaircam_`, ...). The
//! brands this driver loads are the rows of [`TOUPTEK_BRANDS`]; every brand
//! library is driven by the same code through one function table.

use crate::camera_core::{CameraCore, SdkHandle};
use crate::vendor::sdk_loader::{SdkLock, SdkLockHeld, SdkUnavailable};
use async_trait::async_trait;
use libloading::Library;
use skotiq_cfa::BayerPattern;
use skotiq_device::camera::{
    CameraCapabilities, CameraState, CameraStatus, ExposureParams, ImageData, ReadoutMode,
    SensorInfo, SubFrame, VendorFeatures,
};
use skotiq_device::Vendor;
use skotiq_device::{CameraDriver, DeviceDriver, DriverError};
use std::collections::HashMap;
#[cfg(not(windows))]
use std::ffi::CString;
use std::ffi::{c_char, c_int, c_uint, c_ushort, c_void, CStr};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
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
