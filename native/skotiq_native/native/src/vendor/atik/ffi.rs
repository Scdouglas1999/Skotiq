//! Atik SDK types and constants (from AtikDefs.h / AtikCameras.h), and what
//! the SDK's answers mean.

use super::*;

pub(crate) type ArtemisHandle = *mut c_void;

#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ArtemisError {
    Ok = 0,
    InvalidParameter = 1,
    NotConnected = 2,
    NotImplemented = 3,
    NoResponse = 4,
    InvalidFunction = 5,
    NotInitialized = 6,
    OperationFailed = 7,
    InvalidPassword = 8,
}

impl ArtemisError {
    pub(crate) fn from_i32(code: i32) -> Self {
        match code {
            0 => ArtemisError::Ok,
            1 => ArtemisError::InvalidParameter,
            2 => ArtemisError::NotConnected,
            3 => ArtemisError::NotImplemented,
            4 => ArtemisError::NoResponse,
            5 => ArtemisError::InvalidFunction,
            6 => ArtemisError::NotInitialized,
            7 => ArtemisError::OperationFailed,
            8 => ArtemisError::InvalidPassword,
            _ => ArtemisError::OperationFailed,
        }
    }

    /// The error a caller sees when `operation` failed with this code. The
    /// meanings are the ones the SDK Developer's Guide gives (section 5.10).
    pub(crate) fn to_native_error(self, operation: &str) -> DriverError {
        match self {
            ArtemisError::NotConnected => DriverError::Disconnected,
            ArtemisError::NoResponse => DriverError::Timeout(format!(
                "the Atik camera did not answer while trying to {operation}"
            )),
            ArtemisError::InvalidParameter => DriverError::InvalidParameter(format!(
                "the Atik camera refused to {operation}: a value is outside what it accepts"
            )),
            ArtemisError::InvalidFunction => DriverError::SdkError(format!(
                "could not {operation}: this Atik camera does not have that feature"
            )),
            other => DriverError::SdkError(format!(
                "could not {operation}: the Atik SDK answered {other:?}"
            )),
        }
    }
}

/// Camera properties structure (ARTEMISPROPERTIES)
#[repr(C)]
#[derive(Debug)]
pub(crate) struct ArtemisProperties {
    pub(crate) protocol: c_int,
    pub(crate) pixels_x: c_int,
    pub(crate) pixels_y: c_int,
    pub(crate) pixel_microns_x: c_float,
    pub(crate) pixel_microns_y: c_float,
    pub(crate) ccd_flags: c_int,
    pub(crate) camera_flags: c_int,
    pub(crate) description: [c_char; 40],
    pub(crate) manufacturer: [c_char; 40],
}

// ARTEMISPROPERTIESCAMERAFLAGS
pub(crate) const ARTEMIS_CAMERA_HAS_SHUTTER: c_int = 16;
pub(crate) const ARTEMIS_CAMERA_HAS_GUIDE_PORT: c_int = 32;
pub(crate) const ARTEMIS_CAMERA_HAS_EIGHT_BIT_MODE: c_int = 256;

// ARTEMISCOOLINGINFO
pub(crate) const ARTEMIS_COOLING_INFO_HASCOOLING: c_int = 1;
pub(crate) const ARTEMIS_COOLING_INFO_SETPOINTCONTROL: c_int = 16;
pub(crate) const ARTEMIS_COOLING_INFO_WARMINGUP: c_int = 32;
pub(crate) const ARTEMIS_COOLING_INFO_COOLINGON: c_int = 64;

// ARTEMISCAMERASTATE
pub(crate) const CAMERA_ERROR: c_int = -1;
pub(crate) const CAMERA_IDLE: c_int = 0;

// CameraSpecificOptionsIDs. Data layouts are in "CMOS Camera Specific
// Options" and the Apx60 Programmers Guide that ship with the SDK.
/// u16: 0 custom, 1 low, 2 medium, 3 high.
pub(crate) const ID_GO_PRESET_MODE: u16 = 1;
/// 5 bytes: present flag, gain u16, offset u16. Low; medium and high follow.
pub(crate) const ID_GO_PRESET_LOW: u16 = 2;
/// 6 bytes to read (min, max, current as u16), 2 bytes to set.
pub(crate) const ID_GO_CUSTOM_GAIN: u16 = 5;
pub(crate) const ID_GO_CUSTOM_OFFSET: u16 = 6;
/// bool: the 12-bit samples sit in the upper bits of the 16-bit word.
pub(crate) const ID_PAD_DATA: u16 = 13;
/// u16: 0 power save, 1 normal, 2 fast.
pub(crate) const ID_EXPOSURE_SPEED: u16 = 14;
pub(crate) const EXPOSURE_SPEED_POWER_SAVE: u16 = 0;
/// In fast mode frames arrive only through a callback, never through
/// ArtemisImageBuffer.
pub(crate) const EXPOSURE_SPEED_FAST: u16 = 2;

// ARTEMISCOLOURTYPE (AtikDefs.h:53-61). Note that 0 is NOT "monochrome":
// the vendor header documents it as "either the device is not a camera or the
// colour cannot be determined", and monochrome has its own value.
pub(crate) const ARTEMIS_COLOUR_UNKNOWN: c_int = 0;
pub(crate) const ARTEMIS_COLOUR_NONE: c_int = 1;
pub(crate) const ARTEMIS_COLOUR_RGGB: c_int = 2;

/// What the sensor's colour filter array is, as far as the SDK will commit.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum AtikSensorColour {
    Mono,
    Rggb,
}

impl AtikSensorColour {
    pub(crate) fn is_color(self) -> bool {
        matches!(self, AtikSensorColour::Rggb)
    }
}

/// The colour of the pixel at (x, y) of an RGGB mosaic, named as the 2x2 cell
/// that starts there. The SDK's "normal offset" of a colour camera and an odd
/// subframe origin both move the cell this way (INDI writes the offsets as
/// XBAYROFF/YBAYROFF over RGGB, NINA as BayerOffsetX/Y).
pub(crate) fn rggb_cell_at(x: i64, y: i64) -> BayerPattern {
    match (x.rem_euclid(2), y.rem_euclid(2)) {
        (0, 0) => BayerPattern::Rggb,
        (1, 0) => BayerPattern::Grbg,
        (0, _) => BayerPattern::Gbrg,
        _ => BayerPattern::Bggr,
    }
}

/// Classify an `ARTEMISCOLOURTYPE` value the SDK wrote into our out-parameter.
///
/// `None` means the SDK declined to say — `ARTEMIS_COLOUR_UNKNOWN`, or a value
/// this build does not recognise. It must NOT be collapsed into `Mono`: the
/// answer feeds `SensorInfo.color` / `bayer_pattern`, which decide whether the
/// session's frames carry a BAYERPAT card and are ever debayered, so guessing
/// mono for an undetermined sensor publishes a claim about the hardware that
/// the SDK explicitly refused to make.
pub(crate) fn atik_sensor_colour(colour_type: c_int) -> Option<AtikSensorColour> {
    match colour_type {
        ARTEMIS_COLOUR_NONE => Some(AtikSensorColour::Mono),
        ARTEMIS_COLOUR_RGGB => Some(AtikSensorColour::Rggb),
        _ => None,
    }
}

/// What `connect` does with the SDK's answer about the sensor's colour filter
/// array.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum AtikColourDecision {
    /// The SDK named the sensor; publish it.
    Publish(AtikSensorColour),
    /// The SDK has no answer to give for this body. Connect as monochrome —
    /// which is what the camera was before this call existed — and say so, with
    /// the reason.
    ConnectAsMono(String),
    /// The SDK named something, and it is not something this build can image
    /// with. Refuse, with the reason.
    Refuse(String),
}

/// Decide what an `ArtemisColourProperties` outcome means for the connect.
///
/// Three different answers hide behind "not RGGB", and collapsing them was a
/// defect in both directions. Reading a failed call's untouched `0` seed as
/// monochrome published a claim the SDK refused to make, and every frame of a
/// one-shot-colour night lost its BAYERPAT card. Refusing every one of them
/// instead made bodies that have no such property — older mono cameras and
/// older AtikCameras builds answer `NotImplemented` — impossible to connect at
/// all, where they had imaged as mono for years.
///
/// So: a body that cannot answer connects as mono and says why (mono is not a
/// guess there — a camera with no colour property is not a CFA sensor, and
/// `bayer_pattern: None` is already the "do not debayer" state). A body that
/// answers with a colour type this build cannot map is still refused: that is a
/// real CFA the SDK named and we would be guessing at its layout.
pub(crate) fn atik_colour_decision(
    outcome: ArtemisError,
    colour_type: c_int,
) -> AtikColourDecision {
    match outcome {
        ArtemisError::Ok => match atik_sensor_colour(colour_type) {
            Some(colour) => AtikColourDecision::Publish(colour),
            None if colour_type == ARTEMIS_COLOUR_UNKNOWN => AtikColourDecision::ConnectAsMono(
                "the SDK reported ARTEMIS_COLOUR_UNKNOWN: it could not determine the sensor's \
                 colour filter array"
                    .to_string(),
            ),
            None => AtikColourDecision::Refuse(format!(
                "the SDK reported colour type {colour_type}, a colour filter array this build \
                 does not recognise"
            )),
        },
        // The call itself is missing on this driver or this body. There is no
        // colour property to read, which is what a camera with no CFA looks
        // like; it is not a transport failure.
        ArtemisError::NotImplemented | ArtemisError::InvalidFunction => {
            AtikColourDecision::ConnectAsMono(format!(
                "this camera's driver does not implement ArtemisColourProperties ({outcome:?})"
            ))
        }
        other => AtikColourDecision::Refuse(format!("ArtemisColourProperties failed ({other:?})")),
    }
}
