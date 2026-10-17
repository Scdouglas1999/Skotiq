//! QHY SDK FFI type definitions.

use super::*;

/// QHY Camera handle type
pub(crate) type QhyCamHandle = *mut c_void;

/// QHY Bayer patterns
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub enum QhyBayer {
    Mono = 0,
    Rggb = 1,
    Grbg = 2,
    Gbrg = 3,
    Bggr = 4,
}

/// QHY Control IDs - matches CONTROL_ID enum from qhyccdstruct.h
#[repr(C)]
#[derive(Debug, Clone, Copy)]
#[allow(non_camel_case_types)]
pub enum QhyControl {
    CONTROL_BRIGHTNESS = 0,
    CONTROL_CONTRAST = 1,
    CONTROL_WBR = 2,
    CONTROL_WBB = 3,
    CONTROL_WBG = 4,
    CONTROL_GAMMA = 5,
    CONTROL_GAIN = 6,
    CONTROL_OFFSET = 7,
    CONTROL_EXPOSURE = 8,
    CONTROL_SPEED = 9,
    CONTROL_TRANSFERBIT = 10,
    CONTROL_CHANNELS = 11,
    CONTROL_USBTRAFFIC = 12,
    CONTROL_ROWNOISERE = 13,
    CONTROL_CURTEMP = 14,
    CONTROL_CURPWM = 15,
    CONTROL_MANULPWM = 16,
    CONTROL_CFWPORT = 17,
    CONTROL_COOLER = 18,
    CONTROL_ST4PORT = 19,
    CAM_COLOR = 20,
    CAM_BIN1X1MODE = 21,
    CAM_BIN2X2MODE = 22,
    CAM_BIN3X3MODE = 23,
    CAM_BIN4X4MODE = 24,
    CAM_MECHANICALSHUTTER = 25,
    CAM_TRIGER_INTERFACE = 26,
    CAM_TECOVERPROTECT_INTERFACE = 27,
    CAM_SINGNALCLAMP_INTERFACE = 28,
    CAM_FINETONE_INTERFACE = 29,
    CAM_SHUTTERMOTORHEATING_INTERFACE = 30,
    CAM_CALIBRATEFPN_INTERFACE = 31,
    CAM_CHIPTEMPERATURESENSOR_INTERFACE = 32,
    CAM_USBREADOUTSLOWEST_INTERFACE = 33,
    CAM_8BITS = 34,
    CAM_16BITS = 35,
    CAM_GPS = 36,
    CAM_IGNOREOVERSCAN_INTERFACE = 37,
    QHYCCD_3A_AUTOEXPOSURE = 39,
    QHYCCD_3A_AUTOFOCUS = 40,
    CONTROL_AMPV = 41,
    CONTROL_VCAM = 42,
    CAM_VIEW_MODE = 43,
    CONTROL_CFWSLOTSNUM = 44,
    IS_EXPOSING_DONE = 45,
    ScreenStretchB = 46,
    ScreenStretchW = 47,
    CONTROL_DDR = 48,
    CAM_LIGHT_PERFORMANCE_MODE = 49,
    CAM_QHY5II_GUIDE_MODE = 50,
    DDR_BUFFER_CAPACITY = 51,
    DDR_BUFFER_READ_THRESHOLD = 52,
    DefaultGain = 53,
    DefaultOffset = 54,
    OutputDataActualBits = 55,
    OutputDataAlignment = 56,
    CAM_SINGLEFRAMEMODE = 57,
    CAM_LIVEVIDEOMODE = 58,
    CAM_IS_COLOR = 59,
    hasHardwareFrameCounter = 60,
    CAM_HUMIDITY = 62,
    CAM_PRESSURE = 63,
}
