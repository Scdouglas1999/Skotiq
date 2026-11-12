//! SVBony SDK FFI types (from SVBCameraSDK.h).

use super::*;

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

    /// The error for a failed call; `action` says what was being done
    /// ("set the readout region").
    pub(crate) fn to_native_error(self, action: &str) -> DriverError {
        match self {
            SvbError::Success => DriverError::SdkError(format!(
                "SVBony: could not {} (the SDK reported success as a failure)",
                action
            )),
            SvbError::InvalidIndex | SvbError::InvalidId => DriverError::InvalidDevice(format!(
                "SVBony: could not {}: the camera is not in the SDK's camera list (unplugged or listed under another number)",
                action
            )),
            SvbError::CameraClosed => DriverError::NotConnected,
            SvbError::CameraRemoved => DriverError::Disconnected,
            SvbError::Timeout => {
                DriverError::Timeout(format!("SVBony: could not {}: the camera did not answer", action))
            }
            SvbError::InvalidControlType
            | SvbError::InvalidSize
            | SvbError::InvalidImgType
            | SvbError::OutOfBoundary
            | SvbError::InvalidMode
            | SvbError::InvalidDirection
            | SvbError::InvalidPath
            | SvbError::InvalidFileFormat
            | SvbError::BufferTooSmall => DriverError::InvalidParameter(format!(
                "SVBony: could not {}: the camera refused it ({:?})",
                action, self
            )),
            SvbError::InvalidSequence | SvbError::VideoModeActive | SvbError::ExposureInProgress => {
                DriverError::SdkError(format!(
                    "SVBony: could not {}: the camera is busy capturing ({:?})",
                    action, self
                ))
            }
            SvbError::GeneralError => DriverError::SdkError(format!(
                "SVBony: could not {}: the camera reported a general error (a value out of range, or the camera did not respond)",
                action
            )),
            SvbError::UnknownSensorType | SvbError::End => {
                DriverError::SdkError(format!("SVBony: could not {} ({:?})", action, self))
            }
        }
    }
}

/// The output formats Skotiq reads frames in (SVB_IMG_TYPE). RAW is the
/// sensor mosaic; Y is luma, which is what the monochrome models offer
/// ("in most cases, monochrome cameras will be Y16 and color cameras will be
/// RAW16", indi-svbony svbony_base.cpp:472).
#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SvbImgType {
    Raw8 = 0,
    Raw16 = 4,
    Y8 = 5,
    Y16 = 9,
}

/// SVB_IMG_END: the end of `SVB_CAMERA_PROPERTY.SupportedVideoFormat`.
const SVB_IMG_END: c_int = -1;

impl SvbImgType {
    pub(crate) fn from_code(code: c_int) -> Option<Self> {
        match code {
            0 => Some(Self::Raw8),
            4 => Some(Self::Raw16),
            5 => Some(Self::Y8),
            9 => Some(Self::Y16),
            _ => None,
        }
    }

    /// The deepest format the camera lists, the raw mosaic before luma at
    /// equal depth (NINA SVBonySDK.cs:125-157 orders them the same way). The
    /// list ends at SVB_IMG_END; RAW10/12/14, Y10/12/14 and RGB are skipped.
    pub(crate) fn preferred(supported: &[c_int]) -> Option<Self> {
        let listed: Vec<Self> = supported
            .iter()
            .take_while(|&&code| code != SVB_IMG_END)
            .filter_map(|&code| Self::from_code(code))
            .collect();
        [Self::Raw16, Self::Y16, Self::Raw8, Self::Y8]
            .into_iter()
            .find(|format| listed.contains(format))
    }

    pub(crate) fn bytes_per_sample(self) -> i32 {
        match self {
            Self::Raw8 | Self::Y8 => 1,
            Self::Raw16 | Self::Y16 => 2,
        }
    }

    /// RAW frames carry the sensor's color filter; luma frames do not.
    pub(crate) fn is_mosaic(self) -> bool {
        matches!(self, Self::Raw8 | Self::Raw16)
    }

    /// 8-bit samples keep their own value (no scaling to 16 bits).
    pub(crate) fn sample_layout(self) -> SampleLayout {
        match self.bytes_per_sample() {
            1 => SampleLayout::U8Unscaled,
            _ => SampleLayout::U16Little,
        }
    }
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
/// With a 16-bit format selected the SDK left-justifies those sensor bits into
/// the 16-bit buffer, exactly like ZWO. Measured on an SV305 (12-bit sensor):
/// every RAW16 pixel value is a multiple of 16 and saturation sits at 65536 ADU
/// rather than 4096 — the left-justification signature — so the reachable ceiling
/// is `4095 << 4 = 65520`, not 4095
/// (<https://forums.sharpcap.co.uk/viewtopic.php?t=4837>, posts #3 and #6).
/// Reporting `(1 << MaxBitDepth) - 1` understates it 16x and puts every
/// percent-of-full-scale consumer — flat-frame targets above all — out of reach.
/// Y16 is taken to be justified the same way; that has not been measured.
///
/// An 8-bit format is a genuine 8-bit container (the SDK takes the high bits),
/// so its ceiling is 255 regardless of sensor bit depth.
///
/// `bit_depth == 0` or `>= 16` means either an unpopulated property or a
/// genuinely 16-bit ADC; both take the container's own ceiling rather than
/// underflowing to 0, which would report "this camera cannot produce any signal".
pub(crate) fn container_max_adu(image_type: SvbImgType, bit_depth: u32) -> u32 {
    const CONTAINER_BITS: u32 = 16;
    const CONTAINER_MAX: u32 = u16::MAX as u32;
    if image_type.bytes_per_sample() == 1 {
        return u32::from(u8::MAX);
    }
    if bit_depth == 0 || bit_depth >= CONTAINER_BITS {
        return CONTAINER_MAX;
    }
    (((1u32 << bit_depth) - 1) << (CONTAINER_BITS - bit_depth)) & CONTAINER_MAX
}

/// SVB_CAMERA_MODE values Skotiq uses.
#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SvbCameraMode {
    /// Free-running video: the camera exposes frame after frame.
    Normal = 0,
    /// One frame per SVBSendSoftTrigger.
    SoftTrigger = 1,
}

/// SVB_CONTROL_TYPE values Skotiq reads or sets by name. The others
/// (gamma, contrast, white balance, flip, sharpness, saturation, frame speed,
/// bad-pixel correction...) are only ever put back to their defaults.
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

/// The SVB_CONTROL_TYPE name for log and error text.
pub(crate) fn control_name(control_type: c_int) -> &'static str {
    const NAMES: [&str; 20] = [
        "gain",
        "exposure",
        "gamma",
        "gamma contrast",
        "red white balance",
        "green white balance",
        "blue white balance",
        "flip",
        "frame speed",
        "contrast",
        "sharpness",
        "saturation",
        "auto target brightness",
        "offset",
        "cooler switch",
        "cooler target temperature",
        "sensor temperature",
        "cooler power",
        "bad pixel correction",
        "bad pixel correction threshold",
    ];
    usize::try_from(control_type)
        .ok()
        .and_then(|i| NAMES.get(i))
        .copied()
        .unwrap_or("an unknown control")
}

impl SvbControlType {
    /// Controls Skotiq sets for each exposure or that belong to the cooler.
    /// Connect leaves these alone; a cooler that is running keeps running
    /// across a reconnect.
    pub(crate) const OWNED: [SvbControlType; 7] = [
        Self::Gain,
        Self::Exposure,
        Self::BlackLevel,
        Self::CoolerEnable,
        Self::TargetTemperature,
        Self::CurrentTemperature,
        Self::CoolerPower,
    ];
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
    pub(crate) unused: [c_char; 32],
}
