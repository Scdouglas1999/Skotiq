//! Moravian camera driver types and parameter indexes.
//!
//! The indexes are the same in the Linux/macOS `gxccd.h` and the Windows
//! `cxusb.h` / `gxusb.h` headers.

use super::*;

/// Camera handle (opaque `camera_t` in gxccd.h:66, `CCamera` in cxusb.h).
pub(crate) type CCamera = c_void;
pub(crate) type PCCamera = *mut CCamera;

/// C `bool` (gxccd) and `BOOLEAN` (the Windows drivers) are one byte. Bound
/// as `u8` so an out-parameter the library fills with any byte is read as
/// `!= 0`, never as an invalid Rust `bool`.
pub(crate) type GxBool = u8;

// Boolean parameter indexes (gxccd.h:221-257, cxusb.h).
pub(crate) const GBP_CONNECTED: c_int = 0;
pub(crate) const GBP_SUB_FRAME: c_int = 1;
pub(crate) const GBP_SHUTTER: c_int = 3;
pub(crate) const GBP_COOLER: c_int = 4;
pub(crate) const GBP_GUIDE: c_int = 7;
pub(crate) const GBP_ASYMMETRIC_BINNING: c_int = 10;
pub(crate) const GBP_RGB: c_int = 128;
pub(crate) const GBP_CMY: c_int = 129;
pub(crate) const GBP_CMYG: c_int = 130;
pub(crate) const GBP_DEBAYER_X_ODD: c_int = 131;
pub(crate) const GBP_DEBAYER_Y_ODD: c_int = 132;

// Integer parameter indexes (gxccd.h:262-293, cxusb.h).
pub(crate) const GIP_CHIP_W: c_int = 1;
pub(crate) const GIP_CHIP_D: c_int = 2;
pub(crate) const GIP_PIXEL_W: c_int = 3;
pub(crate) const GIP_PIXEL_D: c_int = 4;
pub(crate) const GIP_MAX_BINNING_X: c_int = 5;
pub(crate) const GIP_MAX_BINNING_Y: c_int = 6;
/// Microseconds.
pub(crate) const GIP_MINIMAL_EXPOSURE: c_int = 9;
pub(crate) const GIP_DEFAULT_READ_MODE: c_int = 12;
pub(crate) const GIP_MAX_GAIN: c_int = 16;
/// Depends on the read mode and binning: read only after both are set.
pub(crate) const GIP_MAX_PIXEL_VALUE: c_int = 17;

// String parameter indexes (gxccd.h:298-304, cxusb.h).
pub(crate) const GSP_CAMERA_DESCRIPTION: c_int = 0;
pub(crate) const GSP_CAMERA_SERIAL: c_int = 2;

// Value indexes (gxccd.h:313-326, cxusb.h).
pub(crate) const GV_CHIP_TEMPERATURE: c_int = 0;
/// A fraction from 0 to 1.
pub(crate) const GV_POWER_UTILIZATION: c_int = 11;

/// Warm-up target (deg C) high enough for the cooler to turn fully off
/// (mi_ccd.cpp:35 `TEMP_COOLER_OFF`).
pub(crate) const TEMP_COOLER_OFF: c_float = 100.0;

/// Upper bound on the readout after the exposure time has passed (large CCDs
/// take many seconds to digitize).
pub(crate) const READOUT_TIMEOUT_SECS: u64 = 120;
/// Poll interval for "image ready" during readout; the headers ask callers not
/// to spin on it (gxccd.h:393-404).
pub(crate) const READOUT_POLL_MS: u64 = 200;
