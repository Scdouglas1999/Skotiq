//! FUJIFILM X SDK FFI types and constants (from XAPI.h).

use super::*;

// Type definitions from XAPI.h.

/// Camera handle type
pub(crate) type XsdkHandle = *mut c_void;

/// Camera list for device detection (XAPI.h lines 52-60)
#[repr(C, packed)]
#[derive(Clone)]
pub(crate) struct XsdkCameraList {
    pub(crate) str_product: [c_char; 256], // Model name (e.g., "X-T5")
    pub(crate) str_serial_no: [c_char; 256], // Serial number (USB only)
    pub(crate) str_ip_address: [c_char; 256], // IPv4 address (network only)
    pub(crate) str_framework: [c_char; 256], // "USB" / "ETHER" / "IP"
    pub(crate) b_valid: bool,              // true if entry is valid
}

impl Default for XsdkCameraList {
    fn default() -> Self {
        Self {
            str_product: [0; 256],
            str_serial_no: [0; 256],
            str_ip_address: [0; 256],
            str_framework: [0; 256],
            b_valid: false,
        }
    }
}

/// Device information (XAPI.h lines 63-76)
#[repr(C, packed)]
#[derive(Clone)]
pub(crate) struct XsdkDeviceInformation {
    pub(crate) str_vendor: [c_char; 256],
    pub(crate) str_manufacturer: [c_char; 256],
    pub(crate) str_product: [c_char; 256],
    pub(crate) str_firmware: [c_char; 256],
    pub(crate) str_device_type: [c_char; 256],
    pub(crate) str_serial_no: [c_char; 256],
    pub(crate) str_framework: [c_char; 256],
    pub(crate) b_device_id: u8,
    pub(crate) str_device_name: [c_char; 32],
    pub(crate) str_y_no: [c_char; 32],
}

impl Default for XsdkDeviceInformation {
    fn default() -> Self {
        Self {
            str_vendor: [0; 256],
            str_manufacturer: [0; 256],
            str_product: [0; 256],
            str_firmware: [0; 256],
            str_device_type: [0; 256],
            str_serial_no: [0; 256],
            str_framework: [0; 256],
            b_device_id: 0,
            str_device_name: [0; 32],
            str_y_no: [0; 32],
        }
    }
}

/// Image information from camera buffer (XAPI.h lines 115-127)
#[repr(C, packed)]
#[derive(Clone)]
pub(crate) struct XsdkImageInformation {
    pub(crate) str_internal_name: [c_char; 32],
    pub(crate) l_format: c_long, // XSDK_IMAGEFORMAT_RAW = 1, XSDK_IMAGEFORMAT_JPEG = 7
    pub(crate) l_data_size: c_long, // Size of image data in bytes
    pub(crate) l_image_pix_height: c_long,
    pub(crate) l_image_pix_width: c_long,
    pub(crate) l_image_bit_depth: c_long,
    pub(crate) l_preview_size: c_long,
    pub(crate) h_image: *mut c_void, // XSDK_HANDLE
}

impl Default for XsdkImageInformation {
    fn default() -> Self {
        Self {
            str_internal_name: [0; 32],
            l_format: 0,
            l_data_size: 0,
            l_image_pix_height: 0,
            l_image_pix_width: 0,
            l_image_bit_depth: 0,
            l_preview_size: 0,
            h_image: std::ptr::null_mut(),
        }
    }
}

// SDK constants from XAPI.h.

// Return values (XAPI.h lines 2264-2267)
pub(crate) const XSDK_COMPLETE: c_long = 0;
#[allow(dead_code)]
pub(crate) const XSDK_ERROR: c_long = -1;

// Connection interface (XAPI.h lines 259-261)
pub(crate) const XSDK_DSC_IF_USB: c_long = 0x00000001;
#[allow(dead_code)]
pub(crate) const XSDK_DSC_IF_WIFI_LOCAL: c_long = 0x00000010;
#[allow(dead_code)]
pub(crate) const XSDK_DSC_IF_WIFI_IP: c_long = 0x00000020;

// Priority mode (XAPI.h lines 270-271)
#[allow(dead_code)]
pub(crate) const XSDK_PRIORITY_CAMERA: c_long = 0x0001;
pub(crate) const XSDK_PRIORITY_PC: c_long = 0x0002;

// Release mode - ON modes (XAPI.h lines 276-290)
#[allow(dead_code)]
pub(crate) const XSDK_RELEASE_SHOOT: c_long = 0x0100;
pub(crate) const XSDK_RELEASE_S1ON: c_long = 0x0200;
#[allow(dead_code)]
pub(crate) const XSDK_RELEASE_S2: c_long = 0x0300;
#[allow(dead_code)]
pub(crate) const XSDK_RELEASE_BULB_ON: c_long = 0x0400;
pub(crate) const XSDK_RELEASE_BULBS2_ON: c_long = 0x0500;

// Release mode - OFF modes (XAPI.h lines 292-310)
#[allow(dead_code)]
pub(crate) const XSDK_RELEASE_N_S1OFF: c_long = 0x0004;
#[allow(dead_code)]
pub(crate) const XSDK_RELEASE_N_BULBOFF: c_long = 0x0008;
pub(crate) const XSDK_RELEASE_N_BULBS1OFF: c_long = 0x000C; // BULBS2OFF | S1OFF
#[allow(dead_code)]
pub(crate) const XSDK_RELEASE_CANCEL: c_long = 0x000F;

// Combined release modes (XAPI.h lines 313-324)
pub(crate) const XSDK_RELEASE_SHOOT_S1OFF: c_long = 0x0104; // Normal single shot

// Image format (XAPI.h lines 376-393)
pub(crate) const XSDK_IMAGEFORMAT_RAW: c_long = 1;
pub(crate) const XSDK_IMAGEFORMAT_LIVE: c_long = 4;
#[allow(dead_code)]
pub(crate) const XSDK_IMAGEFORMAT_NONE: c_long = 5;
#[allow(dead_code)]
pub(crate) const XSDK_IMAGEFORMAT_JPEG: c_long = 7;

// Live View control (XAPIOpt.h lines 366-384)
pub(crate) const API_CODE_START_LIVE_VIEW: c_long = 0x3301;
pub(crate) const API_CODE_STOP_LIVE_VIEW: c_long = 0x3302;
pub(crate) const API_CODE_SET_LIVE_VIEW_IMAGE_QUALITY: c_long = 0x3323;
pub(crate) const API_CODE_SET_LIVE_VIEW_IMAGE_SIZE: c_long = 0x3325;
#[allow(dead_code)]
pub(crate) const API_CODE_GET_LIVE_VIEW_STATUS: c_long = 0x332D;

// Live view quality (XAPIOpt.h lines 574-579)
pub(crate) const SDK_LIVEVIEW_QUALITY_FINE: c_long = 0x0001;
pub(crate) const SDK_LIVEVIEW_QUALITY_NORMAL: c_long = 0x0002;
pub(crate) const SDK_LIVEVIEW_QUALITY_BASIC: c_long = 0x0003;

// Live view size (XAPIOpt.h lines 582-590)
pub(crate) const SDK_LIVEVIEW_SIZE_L: c_long = 0x0001; // 1280px
#[allow(dead_code)]
pub(crate) const SDK_LIVEVIEW_SIZE_M: c_long = 0x0002; // 800px
#[allow(dead_code)]
pub(crate) const SDK_LIVEVIEW_SIZE_S: c_long = 0x0003; // 640px

// Focus control API codes (XAPIOpt.h lines 265-275, 316)
pub(crate) const API_CODE_SET_FOCUS_POS: c_long = 0x2207;
pub(crate) const API_CODE_GET_FOCUS_POS: c_long = 0x2208;
pub(crate) const API_CODE_CAP_FOCUS_POS: c_long = 0x2259;
#[allow(dead_code)]
pub(crate) const API_CODE_SET_FOCUS_MODE: c_long = 0x2201;
#[allow(dead_code)]
pub(crate) const API_CODE_GET_FOCUS_MODE: c_long = 0x2202;

// RAW output depth (XAPIOpt.H lines 228-229 for the Set/Get API codes, line 263
// for the capability code). GFX-class bodies can be switched between 14-bit and
// 16-bit RAW output, which changes the container full scale of every delivered
// frame from 16383 to 65535.
pub(crate) const API_CODE_GET_RAW_OUTPUT_DEPTH: c_long = 0x2161;
#[allow(dead_code)]
pub(crate) const API_CODE_SET_RAW_OUTPUT_DEPTH: c_long = 0x2160;
#[allow(dead_code)]
pub(crate) const API_CODE_CAP_RAW_OUTPUT_DEPTH: c_long = 0x2193;

// RAW output depth values (XAPIOpt.H lines 584-585)
pub(crate) const SDK_RAWOUTPUTDEPTH_14BIT: c_long = 0x0001;
pub(crate) const SDK_RAWOUTPUTDEPTH_16BIT: c_long = 0x0002;

// Focus mode constants
#[allow(dead_code)]
pub(crate) const SDK_FOCUS_MODE_MF: c_long = 0x0001;
#[allow(dead_code)]
pub(crate) const SDK_FOCUS_MODE_AFS: c_long = 0x0002;
#[allow(dead_code)]
pub(crate) const SDK_FOCUS_MODE_AFC: c_long = 0x0003;

// Dynamic range (XAPI.h lines 2087-2090)
pub(crate) const XSDK_DR_100: c_long = 100;
#[allow(dead_code)]
pub(crate) const XSDK_DR_200: c_long = 200;
#[allow(dead_code)]
pub(crate) const XSDK_DR_400: c_long = 400;

// Shutter speed codes (XAPI.h lines 405-533)
pub(crate) const XSDK_SHUTTER_BULB: c_long = -1;

// Error codes (XAPI.h lines 2233-2261)
pub(crate) const XSDK_ERRCODE_NOERR: c_long = 0x00000000;
pub(crate) const XSDK_ERRCODE_SEQUENCE: c_long = 0x00001001;
pub(crate) const XSDK_ERRCODE_PARAM: c_long = 0x00001002;
pub(crate) const XSDK_ERRCODE_INVALID_CAMERA: c_long = 0x00001003;
pub(crate) const XSDK_ERRCODE_LOADLIB: c_long = 0x00001004;
pub(crate) const XSDK_ERRCODE_UNSUPPORTED: c_long = 0x00001005;
pub(crate) const XSDK_ERRCODE_BUSY: c_long = 0x00001006;
pub(crate) const XSDK_ERRCODE_AF_TIMEOUT: c_long = 0x00001007;
pub(crate) const XSDK_ERRCODE_SHOOT_ERROR: c_long = 0x00001008;
pub(crate) const XSDK_ERRCODE_FRAME_FULL: c_long = 0x00001009;
pub(crate) const XSDK_ERRCODE_STANDBY: c_long = 0x00001010;
pub(crate) const XSDK_ERRCODE_NODRIVER: c_long = 0x00001011;
pub(crate) const XSDK_ERRCODE_NO_MODEL_MODULE: c_long = 0x00001012;
pub(crate) const XSDK_ERRCODE_API_NOTFOUND: c_long = 0x00001013;
pub(crate) const XSDK_ERRCODE_API_MISMATCH: c_long = 0x00001014;
pub(crate) const XSDK_ERRCODE_INVALID_USBMODE: c_long = 0x00001015;
pub(crate) const XSDK_ERRCODE_FORCEMODE_BUSY: c_long = 0x00001016;
pub(crate) const XSDK_ERRCODE_RUNNING_OTHER_FUNCTION: c_long = 0x00001017;
pub(crate) const XSDK_ERRCODE_COMMUNICATION: c_long = 0x00002001;
pub(crate) const XSDK_ERRCODE_TIMEOUT: c_long = 0x00002002;
pub(crate) const XSDK_ERRCODE_COMBINATION: c_long = 0x00002003;
pub(crate) const XSDK_ERRCODE_WRITEERROR: c_long = 0x00002004;
pub(crate) const XSDK_ERRCODE_CARDFULL: c_long = 0x00002005;
pub(crate) const XSDK_ERRCODE_HARDWARE: c_long = 0x00003001;
pub(crate) const XSDK_ERRCODE_INTERNAL: c_long = 0x00009001;
pub(crate) const XSDK_ERRCODE_MEMFULL: c_long = 0x00009002;
pub(crate) const XSDK_ERRCODE_UNKNOWN: c_long = 0x00009100;
