//! What a failed operation says about the device behind it.
//!
//! Recovery asks three questions of a failure: does its kind say the device
//! is not connected, do its words say the device is gone, and is the device's
//! SDK session broken (it answers, but takes no exposure until it is closed
//! and opened again). The kind answers where the failure has one. Text that
//! reached recovery without a kind (a liveness probe's sentence, a protocol
//! server's message, a helper's `String`) is read by the words recovery has
//! always read in such text.

use crate::dispatch::error::DeviceOpError;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FailureKind {
    NotConnected,
    SessionLost,
    Other,
}

/// A failure as recovery reads it: its words and its kind.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct DeviceFailure {
    message: String,
    kind: FailureKind,
}

impl DeviceFailure {
    /// A failure known only by its words.
    pub(crate) fn words(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            kind: FailureKind::Other,
        }
    }

    pub(crate) fn message(&self) -> &str {
        &self.message
    }

    /// The same failure in other words.
    pub(crate) fn reworded(self, words: impl FnOnce(String) -> String) -> Self {
        Self {
            message: words(self.message),
            kind: self.kind,
        }
    }

    /// The failure's kind says the device is not connected.
    pub(crate) fn not_connected(&self) -> bool {
        self.kind == FailureKind::NotConnected
    }

    /// The failure's words say the device is disconnected or not connected.
    pub(crate) fn says_gone(&self) -> bool {
        let message = self.message.to_ascii_lowercase();
        message.contains("disconnected") || message.contains("not connected")
    }

    /// The camera's SDK session is broken and only a reopen brings it back:
    /// the failure is of that kind, or its words are ones a vendor SDK uses
    /// for it (`skotiq_native::camera_session_broken`).
    pub(crate) fn session_lost(&self) -> bool {
        self.kind == FailureKind::SessionLost || skotiq_native::camera_session_broken(&self.message)
    }
}

impl std::fmt::Display for DeviceFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl From<&str> for DeviceFailure {
    fn from(message: &str) -> Self {
        Self::words(message)
    }
}

impl From<&DeviceOpError> for DeviceFailure {
    fn from(error: &DeviceOpError) -> Self {
        let kind = match error {
            DeviceOpError::NotConnected { .. } => FailureKind::NotConnected,
            DeviceOpError::SessionLost { .. } => FailureKind::SessionLost,
            _ => FailureKind::Other,
        };
        Self {
            message: error.to_string(),
            kind,
        }
    }
}

impl From<&skotiq_sequencer::DeviceError> for DeviceFailure {
    fn from(error: &skotiq_sequencer::DeviceError) -> Self {
        use skotiq_sequencer::DeviceError;
        let kind = match error {
            DeviceError::NotConnected { .. } => FailureKind::NotConnected,
            DeviceError::SessionLost(_) => FailureKind::SessionLost,
            _ => FailureKind::Other,
        };
        Self {
            message: error.to_string(),
            kind,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use skotiq_device::DriverError;

    fn of_driver(error: DriverError) -> DeviceFailure {
        DeviceFailure::from(&DeviceOpError::caused_by(
            Some("native:zwo:1".to_string()),
            format!("Failed to start native SDK camera exposure on native:zwo:1: {error}"),
            error,
        ))
    }

    /// The ZWO camera's broken session is a kind that survives the device
    /// layer's rewording and the run's.
    #[test]
    fn a_session_lost_kind_survives_the_device_layer_and_the_run() {
        let lost = DeviceOpError::caused_by(
            None,
            "Failed to check exposure status: SDK error: x".to_string(),
            DriverError::SessionLost("x".to_string()),
        );
        assert!(matches!(lost, DeviceOpError::SessionLost { .. }));
        let failure = DeviceFailure::from(&lost);
        assert_eq!(failure.kind, FailureKind::SessionLost);
        assert!(failure.session_lost());

        let run =
            skotiq_sequencer::DeviceError::SessionLost(lost.to_string()).context("on frame 3/10");
        assert_eq!(DeviceFailure::from(&run).kind, FailureKind::SessionLost);
    }

    #[test]
    fn a_timeout_or_a_refused_value_is_not_a_broken_session() {
        assert!(!of_driver(DriverError::Timeout("ASI_ERROR_TIMEOUT".into())).session_lost());
        assert!(!of_driver(DriverError::InvalidParameter("gain".into())).session_lost());
    }

    #[test]
    fn text_without_a_kind_is_read_by_its_words() {
        assert!(
            DeviceFailure::words("SDK error: ZWO camera reported a failed exposure").session_lost()
        );
        assert!(DeviceFailure::words("Focuser said: Device disconnected").says_gone());
        assert!(DeviceFailure::words("EFW not connected").says_gone());
        assert!(!DeviceFailure::words("Device not responding").says_gone());
        assert!(!DeviceFailure::words("Device disconnected").not_connected());
    }

    #[test]
    fn a_not_connected_kind_is_read_apart_from_its_words() {
        let failure = DeviceFailure::from(&DeviceOpError::not_connected(None, "EAF gone"));
        assert!(failure.not_connected());
        assert!(!failure.says_gone());
    }
}
