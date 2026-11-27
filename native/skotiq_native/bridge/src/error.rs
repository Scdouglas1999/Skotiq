//! Error types for the Skotiq bridge
//!
//! This module provides comprehensive error types for the FFI bridge layer.
//! All errors are designed to be:
//! - Informative: Include context about what failed
//! - Recoverable: Where possible, indicate how to recover
//! - Safe: Never panic - this is the FFI boundary
//!
//! # Error Categories
//!
//! - Device errors: Connection, communication, timeout issues
//! - Driver errors: ASCOM, Alpaca, INDI, Native SDK specific errors
//! - Operation errors: Invalid parameters, unsupported operations
//! - System errors: I/O, internal failures

use thiserror::Error;

/// Main error type for the Skotiq native library
///
/// This enum covers all error cases that can occur at the FFI boundary.
/// Each variant includes enough context for meaningful error messages
/// and potential recovery actions.
#[derive(Error, Debug, Clone)]
pub enum SkotiqError {
    // Device discovery & connection errors
    #[error("Device not found: {0}")]
    DeviceNotFound(String),

    #[error("Device connection failed: {device_id} - {reason}")]
    ConnectionFailed { device_id: String, reason: String },

    #[error("Device already connected: {0}")]
    AlreadyConnected(String),

    #[error("Device not connected: {0}")]
    NotConnected(String),

    #[error("Device disconnected unexpectedly: {device_id} - {reason}")]
    DeviceDisconnected { device_id: String, reason: String },

    // Hardware errors
    /// General hardware error from device
    #[error("Hardware error: {device_id} - {message}")]
    HardwareError {
        device_id: String,
        message: String,
        /// Optional vendor-specific error code
        error_code: Option<i32>,
    },

    /// Hardware communication error
    #[error("Communication error: {device_id} - {message}")]
    CommunicationError { device_id: String, message: String },

    // Timeout errors
    /// Generic timeout error (for backwards compatibility)
    #[error("Operation timed out: {0}")]
    Timeout(String),

    /// Device-specific timeout with details
    #[error("Device timeout: {device_id} operation '{operation}' after {timeout_secs:.1}s")]
    DeviceTimeout {
        device_id: String,
        operation: String,
        timeout_secs: f64,
    },

    /// Connection timeout
    #[error("Connection timeout: {device_id} after {timeout_secs:.1}s")]
    ConnectionTimeout {
        device_id: String,
        timeout_secs: f64,
    },

    // Parameter validation errors
    #[error("Invalid parameter: {0}")]
    InvalidParameter(String),

    #[error("Invalid input: {0}")]
    InvalidInput(String),

    #[error("Invalid device ID: {device_id} - {reason}")]
    InvalidDeviceId { device_id: String, reason: String },

    #[error("Parameter out of range: {param_name} = {value} (valid: {min} to {max})")]
    ParameterOutOfRange {
        param_name: String,
        value: String,
        min: String,
        max: String,
    },

    // Operation errors
    #[error("Operation failed: {0}")]
    OperationFailed(String),

    #[error("Operation not supported: {operation} on device {device_id}")]
    NotSupported {
        device_id: String,
        operation: String,
    },

    #[error("Device busy: {device_id} - {current_operation}")]
    DeviceBusy {
        device_id: String,
        current_operation: String,
    },

    /// A refusal a caller answers by its kind (the host's HTTP status, a
    /// report's sentence) rather than by its words. It displays as the
    /// variant these refusals were raised as before they had a kind.
    #[error("{}{}", .kind.display_prefix(), .message)]
    Refused { kind: Refusal, message: String },

    /// The device cannot do this in the state it is in (a dither while
    /// guiding is paused, say). The message is the whole sentence a person
    /// reads, including what to do instead.
    #[error("{0}")]
    InvalidState(String),

    #[error("Image processing error: {0}")]
    ImageError(String),

    #[error("Camera error: {0}")]
    CameraError(String),

    #[error("No image available")]
    NoImageAvailable,

    #[error("Exposure cancelled")]
    ExposureCancelled,

    #[error("Exposure failed: {camera_id} - {reason}")]
    ExposureFailed { camera_id: String, reason: String },

    #[error("Image download failed: {camera_id} - {reason}")]
    DownloadFailed { camera_id: String, reason: String },

    // I/O errors
    #[error("File I/O error: {0}")]
    IoError(String),

    #[error("Serialization error: {0}")]
    SerializationError(String),

    #[error("Plate solving failed: {0}")]
    PlateSolveError(String),

    #[error("Sequence error: {0}")]
    SequenceError(String),

    // Driver-specific errors
    /// ASCOM driver error (Windows only)
    #[error("ASCOM error: {prog_id} - {message} (code: {error_code})")]
    AscomError {
        prog_id: String,
        message: String,
        error_code: i32,
    },

    /// Alpaca REST API error
    #[error("Alpaca error: {base_url} device {device_number} - {message} (code: {error_code})")]
    AlpacaError {
        base_url: String,
        device_number: u32,
        message: String,
        error_code: i32,
    },

    /// INDI protocol error
    #[error("INDI error: {server}:{port} device '{device_name}' - {message}")]
    IndiError {
        server: String,
        port: u16,
        device_name: String,
        message: String,
    },

    /// Native SDK error
    #[error("Native SDK error: {vendor} - {message} (code: {error_code})")]
    NativeError {
        vendor: String,
        message: String,
        error_code: i32,
    },

    /// COM/OLE error (Windows ASCOM)
    #[error("COM error: {message} (HRESULT: 0x{hresult:08X})")]
    ComError { message: String, hresult: u32 },

    // System errors
    #[error("Internal error: {0}")]
    Internal(String),

    #[error("Operation cancelled")]
    Cancelled,

    #[error("Runtime initialization failed: {0}")]
    RuntimeInitFailed(String),

    #[error("Resource exhausted: {resource} - {message}")]
    ResourceExhausted { resource: String, message: String },
}

/// Why a request was refused, for a caller that answers each reason its own
/// way.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    /// PHD2 answered `get_lock_position` without a numeric x and y.
    NoLockPosition,
    /// PHD2 has no guide star selected.
    NoStarSelected,
    /// The guide frame holds no star fit to guide on.
    NoGuideStarFound,
    /// The sequencer is running, paused, stopping or recovering.
    ExecutorNotIdle,
    /// The sequencer has no sequence loaded.
    NoSequenceLoaded,
    /// A manual action holds the run paused, and the command was not its
    /// release.
    RunHeldByAction,
    /// No DepthLock goal has the id. Named so its rendering holds none of the
    /// words error text is classified by ("not found", "busy", ...).
    DepthLockNoSuchGoal,
    /// The caller's DepthLock goal revision is not the current one.
    DepthLockStaleRevision,
    /// DepthLock storage is not initialized.
    DepthLockUnavailable,
    /// Calibration frames brightened during the set: a light leak.
    LightLeak,
    /// The live stacker left a frame out because it did not align to the
    /// reference.
    LiveStackMisaligned,
    /// The live stacker left a frame out because it was taken through another
    /// filter than the stack's.
    LiveStackOtherFilter,
    /// The frame file handed to the live stacker could not be read.
    LiveStackUnreadable,
    /// The live stacker did not start: the reference frame holds fewer stars
    /// than alignment needs. The message ends with both counts, in the form
    /// `test_fixtures/ffi_replies/live_stack_too_few_reference_stars.json`
    /// holds.
    LiveStackTooFewReferenceStars,
}

impl Refusal {
    fn display_prefix(self) -> &'static str {
        match self {
            Refusal::LightLeak => "Invalid input: ",
            Refusal::LiveStackMisaligned
            | Refusal::LiveStackOtherFilter
            | Refusal::LiveStackUnreadable
            | Refusal::LiveStackTooFewReferenceStars => "Image error: ",
            _ => "Operation failed: ",
        }
    }
}

impl SkotiqError {
    // Constructor helpers

    pub fn refused(kind: Refusal, message: impl Into<String>) -> Self {
        SkotiqError::Refused {
            kind,
            message: message.into(),
        }
    }

    /// Create a connection failed error
    pub fn connection_failed(device_id: impl Into<String>, reason: impl Into<String>) -> Self {
        SkotiqError::ConnectionFailed {
            device_id: device_id.into(),
            reason: reason.into(),
        }
    }

    /// Create an invalid device ID error
    pub fn invalid_device_id(device_id: impl Into<String>, reason: impl Into<String>) -> Self {
        SkotiqError::InvalidDeviceId {
            device_id: device_id.into(),
            reason: reason.into(),
        }
    }

    /// Create a not supported error
    pub fn not_supported(device_id: impl Into<String>, operation: impl Into<String>) -> Self {
        SkotiqError::NotSupported {
            device_id: device_id.into(),
            operation: operation.into(),
        }
    }

    pub fn hardware_error(device_id: impl Into<String>, message: impl Into<String>) -> Self {
        SkotiqError::HardwareError {
            device_id: device_id.into(),
            message: message.into(),
            error_code: None,
        }
    }

    pub fn device_disconnected(device_id: impl Into<String>, reason: impl Into<String>) -> Self {
        SkotiqError::DeviceDisconnected {
            device_id: device_id.into(),
            reason: reason.into(),
        }
    }
}

// From implementations for standard library types

impl From<std::io::Error> for SkotiqError {
    fn from(e: std::io::Error) -> Self {
        SkotiqError::IoError(e.to_string())
    }
}

impl From<anyhow::Error> for SkotiqError {
    fn from(e: anyhow::Error) -> Self {
        SkotiqError::Internal(e.to_string())
    }
}

impl From<tokio::time::error::Elapsed> for SkotiqError {
    fn from(_: tokio::time::error::Elapsed) -> Self {
        SkotiqError::Timeout("Operation timed out".to_string())
    }
}

impl From<tokio::task::JoinError> for SkotiqError {
    fn from(e: tokio::task::JoinError) -> Self {
        if e.is_cancelled() {
            SkotiqError::Cancelled
        } else if e.is_panic() {
            SkotiqError::Internal("Task panicked".to_string())
        } else {
            SkotiqError::Internal(format!("Task join error: {}", e))
        }
    }
}

impl From<String> for SkotiqError {
    fn from(s: String) -> Self {
        SkotiqError::Internal(s)
    }
}

impl From<&str> for SkotiqError {
    fn from(s: &str) -> Self {
        SkotiqError::Internal(s.to_string())
    }
}

/// Convert SkotiqError to String for backward compatibility with APIs
/// that return Result<T, String>
impl From<SkotiqError> for String {
    fn from(e: SkotiqError) -> Self {
        e.to_string()
    }
}

/// Also support reference conversion
impl From<&SkotiqError> for String {
    fn from(e: &SkotiqError) -> Self {
        e.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_refusal_displays_as_the_variant_it_was_raised_as() {
        assert_eq!(
            SkotiqError::refused(Refusal::NoLockPosition, "no lock").to_string(),
            SkotiqError::OperationFailed("no lock".into()).to_string()
        );
        assert_eq!(
            SkotiqError::refused(Refusal::LightLeak, "light leak: 3 of 9").to_string(),
            SkotiqError::InvalidInput("light leak: 3 of 9".into()).to_string()
        );
    }
}
