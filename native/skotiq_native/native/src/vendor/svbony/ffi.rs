//! SVBony SDK FFI types (from SVBCameraSDK.h).

use super::*;

// Types and constants from SVBCameraSDK.h.

/// SVBony error codes
#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SvbError {
    Success = 0,
    InvalidIndex = 1,
    InvalidId = 2,
    InvalidControlType = 3,
    CameraClosed = 4,
    CameraRemoved = 5,
    InvalidPath = 6,
    InvalidFileFormat = 7,
    InvalidSize = 8,
    InvalidImgType = 9,
    OutOfBoundary = 10,
    Timeout = 11,
    InvalidSequence = 12,
    BufferTooSmall = 13,
    VideoModeActive = 14,
    ExposureInProgress = 15,
    GeneralError = 16,
    InvalidMode = 17,
    InvalidDirection = 18,
    UnknownSensorType = 19,
    End = 20,
}

impl SvbError {
    pub(crate) fn from_i32(code: i32) -> Self {
        match code {
            0 => SvbError::Success,
            1 => SvbError::InvalidIndex,
            2 => SvbError::InvalidId,
            3 => SvbError::InvalidControlType,
            4 => SvbError::CameraClosed,
            5 => SvbError::CameraRemoved,
            6 => SvbError::InvalidPath,
            7 => SvbError::InvalidFileFormat,
            8 => SvbError::InvalidSize,
            9 => SvbError::InvalidImgType,
            10 => SvbError::OutOfBoundary,
            11 => SvbError::Timeout,
            12 => SvbError::InvalidSequence,
            13 => SvbError::BufferTooSmall,
            14 => SvbError::VideoModeActive,
            15 => SvbError::ExposureInProgress,
            16 => SvbError::GeneralError,
            17 => SvbError::InvalidMode,
            18 => SvbError::InvalidDirection,
            19 => SvbError::UnknownSensorType,
            _ => SvbError::End,
        }
    }

    pub(crate) fn to_native_error(self, msg: &str) -> NativeError {
        match self {
            SvbError::Success => {
                NativeError::SdkError(format!("SVBony {} called to_native_error on Success", msg))
            }
            SvbError::InvalidIndex | SvbError::InvalidId => {
                NativeError::InvalidDevice(format!("SVBony {}: {:?}", msg, self))
            }
            SvbError::CameraClosed => NativeError::NotConnected,
            SvbError::CameraRemoved => NativeError::Disconnected,
            SvbError::Timeout => {
                NativeError::Timeout(format!("SVBony {}: operation timed out", msg))
            }
            SvbError::InvalidControlType
            | SvbError::InvalidSize
            | SvbError::InvalidImgType
            | SvbError::OutOfBoundary
            | SvbError::InvalidSequence
            | SvbError::InvalidMode
            | SvbError::InvalidDirection
            | SvbError::InvalidPath
            | SvbError::InvalidFileFormat => {
                NativeError::InvalidParameter(format!("SVBony {}: {:?}", msg, self))
            }
            SvbError::BufferTooSmall => {
                NativeError::InvalidParameter(format!("SVBony {}: buffer too small", msg))
            }
            SvbError::VideoModeActive | SvbError::ExposureInProgress => {
                NativeError::SdkError(format!("SVBony {}: camera busy ({:?})", msg, self))
            }
            SvbError::GeneralError => NativeError::SdkError(format!(
                "SVBony {}: general error - camera may be in use by another application",
                msg
            )),
            SvbError::UnknownSensorType | SvbError::End => {
                NativeError::SdkError(format!("SVBony {}: {:?}", msg, self))
            }
        }
    }
}

/// SVBony image types
#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SvbImgType {
    Raw8 = 0,
    Raw16 = 4,
}

/// Full-scale ADU of the delivered pixel container for an SVBony camera whose
/// sensor is `bit_depth` bits, given the output image type actually negotiated
/// with the SDK.
///
/// `SVB_CAMERA_PROPERTY.MaxBitDepth` is the **sensor's** bit width, not the
/// container's — SVBony say so in their own changelog for SDK v1.12.7
/// (2024-05-06): "MaxBitDepth in SVB_CAMERA_PROPERTY returns the actual bit
/// width of the sensor" (`SDKs/SVBony/SVBONY/ReadMe.txt:424,430`).
///
/// With `SVB_IMG_RAW16` selected the SDK left-justifies those sensor bits into
/// the 16-bit buffer, exactly like ZWO. Measured on an SV305 (12-bit sensor):
/// every RAW16 pixel value is a multiple of 16 and saturation sits at 65536 ADU
/// rather than 4096 — the left-justification signature — so the reachable ceiling
/// is `4095 << 4 = 65520`, not 4095
/// (<https://forums.sharpcap.co.uk/viewtopic.php?t=4837>, posts #3 and #6).
/// Reporting `(1 << MaxBitDepth) - 1` understates it 16x and puts every
/// percent-of-full-scale consumer — flat-frame targets above all — out of reach.
///
/// `SVB_IMG_RAW8` is a genuine 8-bit container (the SDK takes the high bits), so
/// its ceiling is 255 regardless of sensor bit depth. `connect()` falls back to
/// RAW8 when a model does not offer RAW16, and a sensor-derived ceiling there
/// overstates an 8-bit frame by up to 16x in the other direction.
///
/// `bit_depth == 0` or `>= 16` means either an unpopulated property or a
/// genuinely 16-bit ADC; both take the container's own ceiling rather than
/// underflowing to 0, which would report "this camera cannot produce any signal".
pub(crate) fn container_max_adu(image_type: SvbImgType, bit_depth: u32) -> u32 {
    const CONTAINER_BITS: u32 = 16;
    const CONTAINER_MAX: u32 = u16::MAX as u32;
    match image_type {
        SvbImgType::Raw8 => u32::from(u8::MAX),
        SvbImgType::Raw16 => {
            if bit_depth == 0 || bit_depth >= CONTAINER_BITS {
                return CONTAINER_MAX;
            }
            (((1u32 << bit_depth) - 1) << (CONTAINER_BITS - bit_depth)) & CONTAINER_MAX
        }
    }
}

/// SVBony control types for camera settings
#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SvbControlType {
    Gain = 0,
    Exposure = 1,
    BlackLevel = 13,
    CoolerEnable = 14,
    TargetTemperature = 15,
    CurrentTemperature = 16,
    CoolerPower = 17,
}

/// Camera info structure (SVB_CAMERA_INFO)
#[repr(C)]
#[derive(Debug)]
pub(crate) struct SvbCameraInfo {
    pub(crate) friendly_name: [c_char; 32],
    pub(crate) camera_sn: [c_char; 32],
    pub(crate) port_type: [c_char; 32],
    pub(crate) device_id: c_int,
    pub(crate) camera_id: c_int,
}

/// Camera property structure (SVB_CAMERA_PROPERTY)
#[repr(C)]
#[derive(Debug)]
pub(crate) struct SvbCameraProperty {
    pub(crate) max_height: c_long,
    pub(crate) max_width: c_long,
    pub(crate) is_color_cam: c_int,
    pub(crate) bayer_pattern: c_int,
    pub(crate) supported_bins: [c_int; 16],
    pub(crate) supported_video_format: [c_int; 8],
    // SVB_CAMERA_PROPERTY ends here per SVBCameraSDK.h — ONLY MaxBitDepth +
    // IsTriggerCam follow the format array. The previous definition appended
    // ZWO's ASICameraInfo tail (pixel_size/mechanical_shutter/st4_port/
    // is_cooler_cam/is_usb3_*/elec_per_adu), which the SDK never writes: every
    // field past the format array was read from uninitialized stack, so
    // bit_depth came out 0 (→ max_adu=0 on every frame) and cooling read false.
    // Cooling support comes from SVB_CAMERA_PROPERTY_EX.bSupportControlTemp and
    // pixel size from SVBGetSensorPixelSize(), NOT from this struct.
    pub(crate) max_bit_depth: c_int,
    pub(crate) is_trigger_cam: c_int,
}

/// Camera property extended structure (SVB_CAMERA_PROPERTY_EX)
#[repr(C)]
#[derive(Debug)]
pub(crate) struct SvbCameraPropertyEx {
    pub(crate) b_support_pulse_guide: c_int,
    pub(crate) b_support_control_temp: c_int,
    // SVB_CAMERA_PROPERTY_EX has `int Unused[64]` here (SVBCameraSDK.h). A
    // `[c_int; 8]` under-sizes the struct by 224 bytes, so
    // SVBGetCameraPropertyEx writes past the stack buffer on every connect
    // (UB / stack corruption).
    pub(crate) unused: [c_int; 64],
}

/// Control caps structure
#[repr(C)]
#[derive(Debug)]
pub(crate) struct SvbControlCaps {
    pub(crate) name: [c_char; 64],
    pub(crate) description: [c_char; 128],
    pub(crate) max_value: c_long,
    pub(crate) min_value: c_long,
    pub(crate) default_value: c_long,
    pub(crate) is_auto_supported: c_int,
    pub(crate) is_writable: c_int,
    pub(crate) control_type: c_int,
}
