//! Atik SDK FFI types (from AtikDefs.h / AtikCameras.h).

use super::*;

// Types and constants from AtikDefs.h and AtikCameras.h.

/// Atik SDK handle type
pub(crate) type ArtemisHandle = *mut c_void;

/// Wrapper to make raw pointer Send + Sync
/// SAFETY: The Atik SDK requires that all calls to a given camera handle
/// be serialized, which we ensure through the Mutex wrapper in AtikCamera.
pub(crate) struct HandleWrapper(pub(crate) ArtemisHandle);
// SAFETY: HandleWrapper is only ever accessed while holding the per-camera
// `handle: Mutex<HandleWrapper>` AND the global `atik_mutex()` async lock, so
// no two threads ever touch the raw ArtemisHandle concurrently.
unsafe impl Send for HandleWrapper {}
// SAFETY: Same justification as `Send` above — the wrapped raw pointer is
// never dereferenced outside the global Atik SDK mutex, so shared references
// across threads cannot trigger concurrent FFI calls.
unsafe impl Sync for HandleWrapper {}

/// Atik error codes
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

    pub(crate) fn to_native_error(self, msg: &str) -> NativeError {
        tracing::error!(
            "Atik SDK error during '{}': {:?}. Check camera connection and SDK installation.",
            msg,
            self
        );
        NativeError::SdkError(format!(
            "Atik {}: {:?}. Ensure camera is connected and AtikCameras driver is installed.",
            msg, self
        ))
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

// Camera flags from ARTEMISPROPERTIESCAMERAFLAGS
pub(crate) const ARTEMIS_CAMERA_HAS_SHUTTER: c_int = 16;
pub(crate) const ARTEMIS_CAMERA_HAS_GUIDE_PORT: c_int = 32;

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

    pub(crate) fn bayer_pattern(self) -> Option<BayerPattern> {
        match self {
            AtikSensorColour::Mono => None,
            AtikSensorColour::Rggb => Some(BayerPattern::Rggb),
        }
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
