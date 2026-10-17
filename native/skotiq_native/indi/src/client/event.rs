//! `IndiEvent` and the broadcast helper.

use super::*;

/// INDI client event
#[derive(Debug, Clone)]
pub enum IndiEvent {
    /// Device defined
    DeviceDefined(String),
    /// Property defined
    PropertyDefined(String, String, IndiPropertyType),
    /// Property updated
    PropertyUpdated(String, String),
    /// Property deleted
    PropertyDeleted(String, String),
    /// BLOB received with format information
    BlobReceived {
        device: String,
        property: String,
        element: String,
        data: Vec<u8>,
        format: String,
        size: usize,
    },
    /// Connection state changed
    ConnectionStateChanged(bool),
    /// Error occurred
    Error(String),
    /// Reader task died (for supervision) - includes error message
    ReaderDied(String),
    /// Reader task is restarting - includes attempt number and delay
    ReaderRestarting {
        attempt: u32,
        max_attempts: u32,
        delay_secs: f64,
    },
    /// Reader task restarted successfully after failure
    ReaderRestarted { attempts_used: u32 },
    /// Reader task restart failed after max attempts
    ReaderRestartFailed { attempts: u32, last_error: String },
    /// Reader task health changed
    ReaderHealthChanged {
        healthy: bool,
        status: ReaderStatus,
        consecutive_failures: u32,
    },
    /// Protocol version detected
    ProtocolVersionDetected(String),
}

pub(super) fn send_indi_event(
    event_tx: &broadcast::Sender<IndiEvent>,
    event: IndiEvent,
    context: &'static str,
) {
    if event_tx.send(event).is_err() {
        tracing::debug!(
            "INDI event dropped in {} because there are no active event subscribers",
            context
        );
    }
}
