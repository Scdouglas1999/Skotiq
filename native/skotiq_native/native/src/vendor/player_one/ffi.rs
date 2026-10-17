//! Player One POA SDK FFI type definitions.

use super::*;

/// POA Camera handle (index-based)
pub(crate) type PoaCameraIdx = c_int;

/// POA Camera Properties structure - matches actual SDK struct from PlayerOneCamera.h
#[repr(C)]
#[derive(Debug, Clone)]
pub(crate) struct POACameraProperties {
    pub(crate) camera_model_name: [c_char; 256], // cameraModelName
    pub(crate) user_custom_id: [c_char; 16],     // userCustomID
    pub(crate) camera_id: c_int,                 // cameraID
    pub(crate) max_width: c_int, // maxWidth (NOTE: width comes before height in SDK)
    pub(crate) max_height: c_int, // maxHeight
    pub(crate) bit_depth: c_int, // bitDepth
    pub(crate) is_color_camera: c_int, // isColorCamera (POABool)
    pub(crate) is_has_st4_port: c_int, // isHasST4Port (POABool)
    pub(crate) is_has_cooler: c_int, // isHasCooler (POABool)
    pub(crate) is_usb3_speed: c_int, // isUSB3Speed (POABool)
    pub(crate) bayer_pattern: c_int, // bayerPattern (POABayerPattern)
    pub(crate) pixel_size: f64,  // pixelSize (double)
    pub(crate) sn: [c_char; 64], // SN
    pub(crate) sensor_model_name: [c_char; 32], // sensorModelName
    pub(crate) local_path: [c_char; 256], // localPath
    pub(crate) bins: [c_int; 8], // bins - supported bin modes
    pub(crate) img_formats: [c_int; 8], // imgFormats - supported image formats
    pub(crate) is_support_hard_bin: c_int, // isSupportHardBin (POABool)
    pub(crate) p_id: c_int,      // pID
    pub(crate) reserved: [c_char; 248], // reserved
}

/// Player One Phoenix filter-wheel properties from PlayerOnePW.h.
#[repr(C)]
#[derive(Debug, Clone)]
pub(crate) struct PWProperties {
    pub(crate) name: [c_char; 64],
    pub(crate) handle: c_int,
    pub(crate) position_count: c_int,
    pub(crate) sn: [c_char; 32],
    pub(crate) reserved: [c_char; 32],
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PWState {
    Closed = 0,
    Opened = 1,
    Moving = 2,
}

/// POA Exposure Status
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum POAExposureStatus {
    Idle = 0,
    Working = 1,
    Success = 2,
    Failed = 3,
}

/// POA Bool type
pub(crate) type POABool = c_int;
pub(crate) const POA_FALSE: POABool = 0;
pub(crate) const POA_TRUE: POABool = 1;

/// POA Error codes
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq)]
#[allow(dead_code)]
pub(crate) enum POAErrors {
    Success = 0,
    InvalidIndex = 1,
    InvalidId = 2,
    InvalidConfig = 3,
    InvalidArg = 4,
    NotOpened = 5,
    DeviceNotFound = 6,
    OutOfLimit = 7,
    ExposureFailed = 8,
    Timeout = 9,
    SizeTooSmall = 10,
    NotSupported = 11,
    ConfigError = 12,
    Unknown = 13,
}

/// POA Config IDs (controls) - matches POAConfig enum from PlayerOneCamera.h
#[repr(C)]
#[derive(Debug, Clone, Copy)]
#[allow(non_camel_case_types)]
pub(crate) enum POAConfig {
    POA_EXPOSURE = 0,              // exposure time (us), VAL_INT
    POA_GAIN = 1,                  // gain, VAL_INT
    POA_HARDWARE_BIN = 2,          // hardware bin, VAL_BOOL
    POA_TEMPERATURE = 3,           // temperature (C), VAL_FLOAT, read-only
    POA_WB_R = 4,                  // white balance red, VAL_INT
    POA_WB_G = 5,                  // white balance green, VAL_INT
    POA_WB_B = 6,                  // white balance blue, VAL_INT
    POA_OFFSET = 7,                // offset, VAL_INT
    POA_AUTOEXPO_MAX_GAIN = 8,     // max gain for auto exposure, VAL_INT
    POA_AUTOEXPO_MAX_EXPOSURE = 9, // max exposure for auto (ms), VAL_INT
    POA_AUTOEXPO_BRIGHTNESS = 10,  // target brightness for auto, VAL_INT
    POA_GUIDE_NORTH = 11,          // ST4 guide north, VAL_BOOL
    POA_GUIDE_SOUTH = 12,          // ST4 guide south, VAL_BOOL
    POA_GUIDE_EAST = 13,           // ST4 guide east, VAL_BOOL
    POA_GUIDE_WEST = 14,           // ST4 guide west, VAL_BOOL
    POA_EGAIN = 15,                // e/ADU, VAL_FLOAT, read-only
    POA_COOLER_POWER = 16,         // cooler power %, VAL_INT, read-only
    POA_TARGET_TEMP = 17,          // target temperature (C), VAL_INT
    POA_COOLER = 18,               // cooler on/off, VAL_BOOL
    POA_HEATER = 19,               // lens heater state (deprecated), VAL_BOOL
    POA_HEATER_POWER = 20,         // lens heater power %, VAL_INT
    POA_FAN_POWER = 21,            // fan power %, VAL_INT
    POA_FLIP_NONE = 22,            // no flip, VAL_BOOL
    POA_FLIP_HORI = 23,            // horizontal flip, VAL_BOOL
    POA_FLIP_VERT = 24,            // vertical flip, VAL_BOOL
    POA_FLIP_BOTH = 25,            // both flip, VAL_BOOL
    POA_FRAME_LIMIT = 26,          // frame rate limit, VAL_INT
    POA_HQI = 27,                  // high quality image mode, VAL_BOOL
    POA_USB_BANDWIDTH_LIMIT = 28,  // USB bandwidth limit, VAL_INT
    POA_PIXEL_BIN_SUM = 29,        // pixel bin sum mode, VAL_BOOL
    POA_MONO_BIN = 30,             // mono bin mode, VAL_BOOL
}

/// POA Image Format
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub(crate) enum POAImgFormat {
    Raw8 = 0,
    Raw16 = 1,
    Rgb24 = 2,
    Mono8 = 3,
}

/// POA Bayer Pattern - matches POABayerPattern from PlayerOneCamera.h
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub(crate) enum POABayerPattern {
    Rg = 0,
    Bg = 1,
    Gr = 2,
    Gb = 3,
    Mono = -1,
}

/// POA Config Value union - used for get/set config values
#[repr(C)]
#[derive(Clone, Copy)]
pub(crate) union POAConfigValue {
    pub(crate) int_value: c_long,
    pub(crate) float_value: f64,
    pub(crate) bool_value: c_int,
}

impl Default for POAConfigValue {
    fn default() -> Self {
        Self { int_value: 0 }
    }
}

/// POA value type, matching `POAValueType` from PlayerOneCamera.h. Selects which
/// variant of a [`POAConfigValue`] union the SDK wrote.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum POAValueType {
    Int = 0,
    Float = 1,
    Bool = 2,
}

/// Per-control attributes, matching `POAConfigAttributes` from PlayerOneCamera.h.
/// Every [`POAConfig`] has one; this is where the SDK publishes a control's real
/// min/max/default and whether it can be written at all.
///
/// `config_id` and `value_type` are held as `c_int` rather than the Rust enums they
/// mirror: the SDK is free to report a discriminant this build does not know, and
/// materialising that as a Rust enum would be undefined behaviour.
#[repr(C)]
#[derive(Clone, Copy)]
pub(crate) struct POAConfigAttributes {
    pub(crate) is_support_auto: POABool,
    pub(crate) is_writable: POABool,
    pub(crate) is_readable: POABool,
    pub(crate) config_id: c_int,
    pub(crate) value_type: c_int,
    pub(crate) max_value: POAConfigValue,
    pub(crate) min_value: POAConfigValue,
    pub(crate) default_value: POAConfigValue,
    pub(crate) conf_name: [c_char; 64],
    pub(crate) description: [c_char; 128],
    pub(crate) reserved: [c_char; 64],
}

impl std::fmt::Debug for POAConfigValue {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Default to showing as int
        // SAFETY: POAConfigValue is a `#[repr(C)]` union of three POD types (c_long/f64/c_int) all stored at the same offset; reading the `int_value` variant is always defined regardless of which variant was last written (the bytes are interpreted as i64 — same width as f64) and only used for Debug formatting.
        write!(f, "POAConfigValue({})", unsafe { self.int_value })
    }
}
