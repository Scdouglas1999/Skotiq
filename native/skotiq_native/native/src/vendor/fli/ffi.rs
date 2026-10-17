//! FLI SDK FFI types (from libfli.h).

use super::*;

// Types and constants from libfli.h.

/// FLI device handle
pub(crate) type FliDev = c_long;

pub(crate) const FLI_INVALID_DEVICE: FliDev = -1;

// Domain flags
pub(crate) const FLIDOMAIN_USB: c_long = 0x02;
pub(crate) const FLIDEVICE_CAMERA: c_long = 0x100;
pub(crate) const FLIDEVICE_FILTERWHEEL: c_long = 0x200;
pub(crate) const FLIDEVICE_FOCUSER: c_long = 0x300;

// Frame types
pub(crate) const FLI_FRAME_TYPE_NORMAL: c_long = 0;
// FLI_FRAME_TYPE_DARK keeps the mechanical shutter closed for dark/bias frames.
pub(crate) const FLI_FRAME_TYPE_DARK: c_long = 1;

// Bit depth
pub(crate) const FLI_MODE_16BIT: c_long = 1;

// Camera status
pub(crate) const FLI_CAMERA_DATA_READY: c_long = 0x80000000u32 as c_long;

/// Convert a c_long returned by libfli into i32, surfacing SDK corruption as
/// `NativeError::SdkError` rather than wrapping. On Windows (LLP64) c_long is
/// already i32 and the cast is identity; on LP64 *nix this trims to i32 and
/// rejects values outside i32's range.
#[inline]
pub(crate) fn fli_c_long_to_i32(value: c_long, what: &str) -> Result<i32, NativeError> {
    // Why: when c_long == i32 this is identity. When c_long == i64 (LP64), we
    // need a real range check. Round-trip through i64 to handle both shapes via
    // a single i64::try_from / i32::try_from pair without triggering useless
    // -conversion lints on either platform.
    #[allow(clippy::unnecessary_cast)] // identity on Linux, real widening on Windows
    let widened: i64 = value as i64;
    i32::try_from(widened)
        .map_err(|_| NativeError::SdkError(format!("FLI {} out of i32 range: {}", what, value)))
}
