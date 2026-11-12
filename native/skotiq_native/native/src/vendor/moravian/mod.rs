//! Moravian Instruments camera driver.
//!
//! Two vendor APIs reach the same cameras: `libgxccd` (gxccd.h) on Linux and
//! macOS, and the SIPS driver DLLs `cXusb.dll` / `gXusb.dll` (cxusb.h,
//! gxusb.h, MoravianCameraDriver.pdf) on Windows. [`sdk`] puts both behind one
//! [`sdk::Api`]; the camera code in [`camera`] is written once against it.
//!
//! Reference drivers: INDI `indi-mi/mi_ccd.cpp` (libgxccd, maintained by
//! Moravian) and NINA `MoravianCamera.cs` (the Windows DLLs).

use crate::camera_core::{CameraCore, Frame, SdkHandle};
use async_trait::async_trait;
use skotiq_device::camera::{
    BayerPattern, CameraCapabilities, CameraState, CameraStatus, ExposureParams, ImageData,
    ReadoutMode, SensorInfo, SubFrame, VendorFeatures,
};
use skotiq_device::Vendor;
use skotiq_device::{CameraDriver, DeviceDriver, DriverError};
use std::ffi::{c_char, c_double, c_float, c_int, c_void};

mod camera;
mod camera_ops;
mod discovery;
#[cfg(test)]
mod documented_tests;
mod ffi;
mod helpers;
mod sdk;

pub use camera::*;
pub use discovery::*;
use ffi::*;
use helpers::*;
pub use sdk::Library;
use sdk::*;
