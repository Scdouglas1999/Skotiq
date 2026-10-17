//! Moravian gxccd SDK types and constants.

use super::*;

/// Camera handle type (opaque `camera_t`, gxccd.h:66).
pub(crate) type CCamera = c_void;
pub(crate) type PCCamera = *mut CCamera;

/// C `bool` (stdbool.h) is a single byte. We bind it as `u8` rather than Rust
/// `bool` so that reading an out-parameter the SDK may have written with any
/// non-`{0,1}` byte is never undefined behaviour; we treat `!= 0` as true and
/// pass `1`/`0` for in-parameters (ABI-identical 1-byte value).
pub(crate) type GxBool = u8;

// gxccd_get_boolean_parameter() indexes (gxccd.h:221-257).
pub(crate) const GBP_SUB_FRAME: c_int = 1;
pub(crate) const GBP_SHUTTER: c_int = 3;
pub(crate) const GBP_COOLER: c_int = 4;
pub(crate) const GBP_GUIDE: c_int = 7;
pub(crate) const GBP_GAIN: c_int = 13;
pub(crate) const GBP_RGB: c_int = 128;
pub(crate) const GBP_CMY: c_int = 129;
pub(crate) const GBP_CMYG: c_int = 130;
pub(crate) const GBP_DEBAYER_X_ODD: c_int = 131;
pub(crate) const GBP_DEBAYER_Y_ODD: c_int = 132;

// gxccd_get_integer_parameter() indexes (gxccd.h:262-293).
pub(crate) const GIP_CHIP_W: c_int = 1;
pub(crate) const GIP_CHIP_D: c_int = 2;
pub(crate) const GIP_PIXEL_W: c_int = 3;
pub(crate) const GIP_PIXEL_D: c_int = 4;
pub(crate) const GIP_MAX_BINNING_X: c_int = 5;
pub(crate) const GIP_MAX_BINNING_Y: c_int = 6;
pub(crate) const GIP_READ_MODES: c_int = 7;
pub(crate) const GIP_MAX_PIXEL_VALUE: c_int = 17;

// gxccd_get_string_parameter() indexes (gxccd.h:298-304).
pub(crate) const GSP_CAMERA_DESCRIPTION: c_int = 0;
pub(crate) const GSP_CAMERA_SERIAL: c_int = 2;

// gxccd_get_value() indexes (gxccd.h:313-326).
pub(crate) const GV_CHIP_TEMPERATURE: c_int = 0;
pub(crate) const GV_POWER_UTILIZATION: c_int = 11;

/// Warm-up target (deg C) high enough for the cooler to turn fully off.
/// Matches the reference driver's `TEMP_COOLER_OFF` (mi_ccd.cpp:35).
pub(crate) const TEMP_COOLER_OFF: c_float = 100.0;

/// Upper bound on how long we wait for the chip to finish digitizing after the
/// exposure integration elapses (readout can take many seconds on large CCDs).
pub(crate) const READOUT_TIMEOUT_SECS: u64 = 120;
/// Poll interval for `gxccd_image_ready` during readout. Kept coarse per the
/// header's admonition against busy-spinning (gxccd.h:400-404).
pub(crate) const READOUT_POLL_MS: u64 = 200;

/// Candidate shared-library names, tried in order. The reference driver links
/// `libgxccd`; Windows ships `gxccd.dll`.
pub(crate) const LIB_CANDIDATES: &[&str] = &[
    "gxccd.dll",
    "libgxccd.so",
    "libgxccd.so.2",
    "libgxccd.so.1",
    "libgxccd.dylib",
];
