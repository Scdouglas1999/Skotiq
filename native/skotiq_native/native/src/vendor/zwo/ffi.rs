//! ASI SDK FFI type definitions.

use super::*;

/// ASI Camera Info structure from SDK - matches ASI_CAMERA_INFO from ASICamera2.h
#[repr(C)]
#[derive(Debug, Clone)]
pub(crate) struct ASICameraInfo {
    pub(crate) name: [c_char; 64],                 // Name[64] - camera name
    pub(crate) camera_id: c_int,                   // CameraID - unique camera ID
    pub(crate) max_height: c_long,                 // MaxHeight - max height
    pub(crate) max_width: c_long,                  // MaxWidth - max width
    pub(crate) is_color_cam: c_int,                // IsColorCam (ASI_BOOL)
    pub(crate) bayer_pattern: c_int,               // BayerPattern (ASI_BAYER_PATTERN)
    pub(crate) supported_bins: [c_int; 16],        // SupportedBins[16] - ends with 0
    pub(crate) supported_video_format: [c_int; 8], // SupportedVideoFormat[8] - ends with ASI_IMG_END
    pub(crate) pixel_size: f64,                    // PixelSize (double) - in um
    pub(crate) mechanical_shutter: c_int,          // MechanicalShutter (ASI_BOOL)
    pub(crate) st4_port: c_int,                    // ST4Port (ASI_BOOL)
    pub(crate) is_cooler_cam: c_int,               // IsCoolerCam (ASI_BOOL)
    pub(crate) is_usb3_host: c_int,                // IsUSB3Host (ASI_BOOL)
    pub(crate) is_usb3_camera: c_int,              // IsUSB3Camera (ASI_BOOL)
    pub(crate) elec_per_adu: f32,                  // ElecPerADU (float)
    pub(crate) bit_depth: c_int,                   // BitDepth (int)
    pub(crate) is_trigger_cam: c_int,              // IsTriggerCam (ASI_BOOL)
    pub(crate) unused: [c_char; 16],               // Unused[16] - padding
}

/// ZWO serial-number payload — `typedef struct _ASI_SN { unsigned char id[8]; } ASI_SN;`
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct AsiSerialNumber {
    pub(crate) id: [c_uchar; 8],
}

/// `ASI_ERROR_CODE ASIGetSerialNumber(int iCameraID, ASI_SN *pSN)`
pub(crate) type AsiGetSerialNumberFn = unsafe extern "C" fn(c_int, *mut AsiSerialNumber) -> c_int;

/// ASI Exposure Status
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum ASIExposureStatus {
    Idle = 0,
    Working = 1,
    Success = 2,
    Failed = 3,
}

/// ASI Bool type
pub(crate) type ASIBool = c_int;
pub(crate) const ASI_FALSE: ASIBool = 0;
pub(crate) const ASI_TRUE: ASIBool = 1;

/// ASI Error codes - matches ASI_ERROR_CODE from ASICamera2.h
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq)]
#[allow(non_camel_case_types, dead_code)]
pub(crate) enum ASIError {
    ASI_SUCCESS = 0,
    ASI_ERROR_INVALID_INDEX = 1, // no camera connected or index value out of boundary
    ASI_ERROR_INVALID_ID = 2,    // invalid ID
    ASI_ERROR_INVALID_CONTROL_TYPE = 3, // invalid control type
    ASI_ERROR_CAMERA_CLOSED = 4, // camera didn't open
    ASI_ERROR_CAMERA_REMOVED = 5, // failed to find the camera, maybe removed
    ASI_ERROR_INVALID_PATH = 6,  // cannot find the path of the file
    ASI_ERROR_INVALID_FILEFORMAT = 7,
    ASI_ERROR_INVALID_SIZE = 8,      // wrong video format size
    ASI_ERROR_INVALID_IMGTYPE = 9,   // unsupported image format
    ASI_ERROR_OUTOF_BOUNDARY = 10,   // the startpos is out of boundary
    ASI_ERROR_TIMEOUT = 11,          // timeout
    ASI_ERROR_INVALID_SEQUENCE = 12, // stop capture first
    ASI_ERROR_BUFFER_TOO_SMALL = 13, // buffer size is not big enough
    ASI_ERROR_VIDEO_MODE_ACTIVE = 14,
    ASI_ERROR_EXPOSURE_IN_PROGRESS = 15,
    ASI_ERROR_GENERAL_ERROR = 16, // general error, eg: value is out of valid range
    ASI_ERROR_INVALID_MODE = 17,  // the current mode is wrong
    ASI_ERROR_GPS_NOT_SUPPORTED = 18, // camera does not support GPS
    ASI_ERROR_GPS_VER_ERR = 19,   // FPGA GPS ver is too low
    ASI_ERROR_GPS_FPGA_ERR = 20,  // failed to read or write data to FPGA
    ASI_ERROR_GPS_PARAM_OUT_OF_RANGE = 21, // start line or end line out of range
    ASI_ERROR_GPS_DATA_INVALID = 22, // GPS has not yet found satellite
    ASI_ERROR_END = 23,
}

/// ASI Control types - matches ASI_CONTROL_TYPE enum from ASICamera2.h
#[repr(C)]
#[derive(Debug, Clone, Copy)]
#[allow(non_camel_case_types)]
pub(crate) enum ASIControlType {
    ASI_GAIN = 0,
    ASI_EXPOSURE = 1,
    ASI_GAMMA = 2,
    ASI_WB_R = 3,
    ASI_WB_B = 4,
    ASI_OFFSET = 5,
    ASI_BANDWIDTHOVERLOAD = 6,
    ASI_OVERCLOCK = 7,
    ASI_TEMPERATURE = 8, // returns 10*temperature
    ASI_FLIP = 9,
    ASI_AUTO_MAX_GAIN = 10,
    ASI_AUTO_MAX_EXP = 11, // micro second
    ASI_AUTO_TARGET_BRIGHTNESS = 12,
    ASI_HARDWARE_BIN = 13,
    ASI_HIGH_SPEED_MODE = 14,
    ASI_COOLER_POWER_PERC = 15,
    ASI_TARGET_TEMP = 16, // NOT multiplied by 10 (direct degrees C)
    ASI_COOLER_ON = 17,
    ASI_MONO_BIN = 18, // reduces grid at software bin for color camera
    ASI_FAN_ON = 19,
    ASI_PATTERN_ADJUST = 20,
    ASI_ANTI_DEW_HEATER = 21,
    ASI_FAN_ADJUST = 22,
    ASI_PWRLED_BRIGNT = 23,
    ASI_USBHUB_RESET = 24,
    ASI_GPS_SUPPORT = 25,
    ASI_GPS_START_LINE = 26,
    ASI_GPS_END_LINE = 27,
    ASI_ROLLING_INTERVAL = 28, // microsecond
}

/// ASI Image type
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub(crate) enum ASIImgType {
    Raw8 = 0,
    Rgb24 = 1,
    Raw16 = 2,
    Y8 = 3,
    End = -1,
}

/// ASI Flip Status
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum ASIFlipStatus {
    None = 0,
    Horiz = 1,
    Vert = 2,
    Both = 3,
}

/// ASI Control Capabilities
#[repr(C)]
#[derive(Debug, Clone)]
pub(crate) struct ASIControlCaps {
    pub(crate) name: [c_char; 64],
    pub(crate) description: [c_char; 128],
    pub(crate) max_value: c_long,
    pub(crate) min_value: c_long,
    pub(crate) default_value: c_long,
    pub(crate) is_auto_supported: ASIBool,
    pub(crate) is_writable: ASIBool,
    pub(crate) control_type: ASIControlType,
    pub(crate) unused: [c_char; 32],
}

/// ASI Bayer pattern
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub(crate) enum ASIBayerPattern {
    Rg = 0,
    Bg = 1,
    Gr = 2,
    Gb = 3,
}
