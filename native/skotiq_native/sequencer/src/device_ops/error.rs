//! Why a device operation did not happen.

use std::fmt;

/// Result type for device operations
pub type DeviceResult<T> = Result<T, DeviceError>;

/// The kinds of device a rig can have.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DeviceKind {
    Mount,
    Camera,
    Focuser,
    FilterWheel,
    Rotator,
    Guider,
    Dome,
    CoverCalibrator,
    /// A safety monitor, or the weather station that stands in for one.
    SafetyMonitor,
}

impl fmt::Display for DeviceKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Mount => "mount",
            Self::Camera => "camera",
            Self::Focuser => "focuser",
            Self::FilterWheel => "filter wheel",
            Self::Rotator => "rotator",
            Self::Guider => "guider",
            Self::Dome => "dome",
            Self::CoverCalibrator => "cover calibrator",
            Self::SafetyMonitor => "safety monitor",
        })
    }
}

/// Why a device operation did not happen.
///
/// The text each variant displays is what the operator, the event stream and
/// the logs see.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum DeviceError {
    /// The rig has no such device. This is a configuration, not a fault: a
    /// rig imaging unguided or without a safety monitor is normal, and
    /// reporting it as a failure buries the real problem under noise.
    #[error("{}", not_configured_text(*.device))]
    NotConfigured { device: DeviceKind },

    /// The device is configured but not connected, or its connection was
    /// lost. `message` is the driver's own account.
    #[error("The {device} is not connected ({message})")]
    NotConnected { device: DeviceKind, message: String },

    /// The device layer or the driver behind it cannot do this.
    #[error("{0}")]
    Unsupported(String),

    /// The device refused the request as it was asked: a value out of range,
    /// an unknown device, a state that forbids it (a parked mount). Asking
    /// again unchanged gets the same answer.
    #[error("{0}")]
    Rejected(String),

    /// The operation was stopped on request before it finished.
    #[error("{0}")]
    Cancelled(String),

    /// The device did not finish in the time allowed.
    #[error("{0}")]
    Timeout(String),

    /// The camera returned a frame that failed validation. The camera worked;
    /// the frame is unusable (fully saturated, for example).
    #[error("{IMAGE_VALIDATION_FAILED_PREFIX}{0}")]
    InvalidFrame(String),

    /// The driver or the device layer reported a failure, in its own words.
    #[error("{0}")]
    Failed(String),
}

/// What an [`DeviceError::InvalidFrame`] message starts with.
pub const IMAGE_VALIDATION_FAILED_PREFIX: &str = "Image validation failed: ";

const NO_GUIDER_CONFIGURED: &str = "No active guider configured";
const NO_SAFETY_DEVICE_CONFIGURED: &str =
    "No safety monitor or weather device configured for sequencer safety checks";

fn not_configured_text(device: DeviceKind) -> String {
    match device {
        DeviceKind::Guider => NO_GUIDER_CONFIGURED.to_string(),
        DeviceKind::SafetyMonitor => NO_SAFETY_DEVICE_CONFIGURED.to_string(),
        other => format!("No {other} configured"),
    }
}

impl DeviceError {
    /// The rig has no guider.
    pub const NO_GUIDER: Self = Self::NotConfigured {
        device: DeviceKind::Guider,
    };

    /// The rig has no safety monitor or weather device.
    pub const NO_SAFETY_DEVICE: Self = Self::NotConfigured {
        device: DeviceKind::SafetyMonitor,
    };

    pub fn unsupported(message: impl Into<String>) -> Self {
        Self::Unsupported(message.into())
    }

    /// The same failure, its words prefixed with `what` was being done.
    pub fn context(self, what: &str) -> Self {
        self.reworded(|message| format!("{what}: {message}"))
    }

    /// The same kind of failure in other words. A missing device keeps its
    /// fixed sentence.
    pub fn reworded(self, words: impl FnOnce(String) -> String) -> Self {
        match self {
            Self::NotConfigured { device } => Self::NotConfigured { device },
            Self::NotConnected { device, message } => Self::NotConnected {
                device,
                message: words(message),
            },
            Self::Unsupported(message) => Self::Unsupported(words(message)),
            Self::Rejected(message) => Self::Rejected(words(message)),
            Self::Cancelled(message) => Self::Cancelled(words(message)),
            Self::Timeout(message) => Self::Timeout(words(message)),
            Self::InvalidFrame(message) => Self::InvalidFrame(words(message)),
            Self::Failed(message) => Self::Failed(words(message)),
        }
    }

    /// Whether this says the rig has no `device`, rather than that one failed.
    pub fn is_not_configured(&self, device: DeviceKind) -> bool {
        matches!(self, Self::NotConfigured { device: missing } if *missing == device)
    }
}

impl From<String> for DeviceError {
    fn from(message: String) -> Self {
        Self::Failed(message)
    }
}

impl From<&str> for DeviceError {
    fn from(message: &str) -> Self {
        Self::Failed(message.to_string())
    }
}

impl From<DeviceError> for String {
    fn from(error: DeviceError) -> Self {
        error.to_string()
    }
}

/// Whether a failure message that has already been flattened to text says the
/// rig has no guider.
///
/// Only for a message that left the device layer as an instruction result or
/// an event. Code that still holds the [`DeviceError`] matches on
/// [`DeviceError::NotConfigured`] instead.
pub fn message_says_no_guider_configured(message: &str) -> bool {
    message.contains(NO_GUIDER_CONFIGURED)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// These texts reach the operator, the event stream and the Dart side,
    /// and the flattened-message predicate depends on the first.
    #[test]
    fn not_configured_keeps_the_text_operators_and_events_see() {
        assert_eq!(
            DeviceError::NO_GUIDER.to_string(),
            "No active guider configured"
        );
        assert_eq!(
            DeviceError::NO_SAFETY_DEVICE.to_string(),
            "No safety monitor or weather device configured for sequencer safety checks"
        );
        assert_eq!(
            DeviceError::InvalidFrame("fully saturated".to_string()).to_string(),
            "Image validation failed: fully saturated"
        );
    }

    #[test]
    fn only_a_missing_device_of_that_kind_is_not_configured() {
        assert!(DeviceError::NO_GUIDER.is_not_configured(DeviceKind::Guider));
        assert!(!DeviceError::NO_GUIDER.is_not_configured(DeviceKind::SafetyMonitor));
        // Real guider failures must stay loud, whatever their text says.
        for text in [
            "Guide star lost",
            "PHD2 connection refused",
            "Settle timed out after 120s",
            "No active guider configured",
        ] {
            assert!(!DeviceError::from(text).is_not_configured(DeviceKind::Guider));
        }
    }

    #[test]
    fn a_flattened_message_is_recognized_by_its_text() {
        let flattened = format!("Dither failed after frame 3/8: {}", DeviceError::NO_GUIDER);
        assert!(message_says_no_guider_configured(&flattened));
        assert!(!message_says_no_guider_configured("Guide star lost"));
        assert!(!message_says_no_guider_configured(
            "PHD2 connection refused"
        ));
    }
}
