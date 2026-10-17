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

use std::time::Duration;
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

    // Imaging errors
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

    // Sequence errors
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

impl SkotiqError {
    // Constructor helpers

    /// Create a device timeout error
    pub fn device_timeout(
        device_id: impl Into<String>,
        operation: impl Into<String>,
        timeout: Duration,
    ) -> Self {
        SkotiqError::DeviceTimeout {
            device_id: device_id.into(),
            operation: operation.into(),
            timeout_secs: timeout.as_secs_f64(),
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

    /// Create an ASCOM error
    #[cfg(windows)]
    pub fn ascom_error(
        prog_id: impl Into<String>,
        message: impl Into<String>,
        error_code: i32,
    ) -> Self {
        SkotiqError::AscomError {
            prog_id: prog_id.into(),
            message: message.into(),
            error_code,
        }
    }

    /// Create an Alpaca error
    pub fn alpaca_error(
        base_url: impl Into<String>,
        device_number: u32,
        message: impl Into<String>,
        error_code: i32,
    ) -> Self {
        SkotiqError::AlpacaError {
            base_url: base_url.into(),
            device_number,
            message: message.into(),
            error_code,
        }
    }

    /// Create an INDI error
    pub fn indi_error(
        server: impl Into<String>,
        port: u16,
        device_name: impl Into<String>,
        message: impl Into<String>,
    ) -> Self {
        SkotiqError::IndiError {
            server: server.into(),
            port,
            device_name: device_name.into(),
            message: message.into(),
        }
    }

    /// Create a native SDK error
    pub fn native_error(
        vendor: impl Into<String>,
        message: impl Into<String>,
        error_code: i32,
    ) -> Self {
        SkotiqError::NativeError {
            vendor: vendor.into(),
            message: message.into(),
            error_code,
        }
    }

    /// Create a hardware error
    pub fn hardware_error(device_id: impl Into<String>, message: impl Into<String>) -> Self {
        SkotiqError::HardwareError {
            device_id: device_id.into(),
            message: message.into(),
            error_code: None,
        }
    }

    /// Create a hardware error with vendor-specific error code
    pub fn hardware_error_with_code(
        device_id: impl Into<String>,
        message: impl Into<String>,
        error_code: i32,
    ) -> Self {
        SkotiqError::HardwareError {
            device_id: device_id.into(),
            message: message.into(),
            error_code: Some(error_code),
        }
    }

    /// Create a communication error
    pub fn communication_error(device_id: impl Into<String>, message: impl Into<String>) -> Self {
        SkotiqError::CommunicationError {
            device_id: device_id.into(),
            message: message.into(),
        }
    }

    /// Create a disconnected error
    pub fn device_disconnected(device_id: impl Into<String>, reason: impl Into<String>) -> Self {
        SkotiqError::DeviceDisconnected {
            device_id: device_id.into(),
            reason: reason.into(),
        }
    }

    /// Create an operation not supported error
    pub fn operation_not_supported(
        device_id: impl Into<String>,
        operation: impl Into<String>,
    ) -> Self {
        SkotiqError::NotSupported {
            device_id: device_id.into(),
            operation: operation.into(),
        }
    }

    /// Create a parameter out of range error
    pub fn parameter_out_of_range<T: std::fmt::Display>(
        param_name: impl Into<String>,
        value: T,
        min: T,
        max: T,
    ) -> Self {
        SkotiqError::ParameterOutOfRange {
            param_name: param_name.into(),
            value: value.to_string(),
            min: min.to_string(),
            max: max.to_string(),
        }
    }

    // Error classification

    /// Returns true if this error is recoverable by retrying the same operation.
    ///
    /// Recoverable errors include:
    /// - Timeouts (operation may succeed with more time or on retry)
    /// - Device busy (wait and retry)
    /// - Connection errors that could be transient
    ///
    /// Non-recoverable errors include:
    /// - Invalid parameters (same input will always fail)
    /// - Unsupported operations (device doesn't support this)
    /// - Permanent hardware failures
    pub fn is_recoverable(&self) -> bool {
        matches!(
            self,
            // Timeout errors - operation may succeed on retry
            SkotiqError::Timeout(_) |
            SkotiqError::DeviceTimeout { .. } |
            SkotiqError::ConnectionTimeout { .. } |
            // Device busy - wait and retry
            SkotiqError::DeviceBusy { .. } |
            // Connection issues - may be transient
            SkotiqError::ConnectionFailed { .. } |
            SkotiqError::DeviceDisconnected { .. } |
            SkotiqError::CommunicationError { .. } |
            // Some hardware errors may be transient
            SkotiqError::HardwareError { .. } |
            // Resource exhausted - may clear up
            SkotiqError::ResourceExhausted { .. }
        )
    }

    /// Returns true if this error is recoverable by retrying
    /// (Alias for backward compatibility, use `is_recoverable()` for new code)
    pub fn is_retryable(&self) -> bool {
        self.is_recoverable()
    }

    /// Returns true if this error is a timeout
    ///
    /// Use this to decide whether to:
    /// - Increase timeout and retry
    /// - Prompt user to wait longer
    /// - Check if device is responsive
    pub fn is_timeout(&self) -> bool {
        matches!(
            self,
            SkotiqError::Timeout(_)
                | SkotiqError::DeviceTimeout { .. }
                | SkotiqError::ConnectionTimeout { .. }
        )
    }

    /// Returns true if this error indicates the device needs reconnection
    ///
    /// Use this to automatically attempt reconnection before retrying the operation.
    pub fn needs_reconnect(&self) -> bool {
        matches!(
            self,
            SkotiqError::NotConnected(_)
                | SkotiqError::DeviceDisconnected { .. }
                | SkotiqError::CommunicationError { .. }
                | SkotiqError::ComError { .. }
        )
    }

    /// Returns true if we should try to reconnect to the device
    /// (Alias for `needs_reconnect()` for API clarity)
    pub fn should_reconnect(&self) -> bool {
        self.needs_reconnect()
    }

    /// Returns true if this is a hardware-level error
    ///
    /// Hardware errors typically require user attention:
    /// - Check physical connections
    /// - Restart device
    /// - Check device health/status
    pub fn is_hardware_error(&self) -> bool {
        matches!(
            self,
            SkotiqError::HardwareError { .. }
                | SkotiqError::CommunicationError { .. }
                | SkotiqError::ExposureFailed { .. }
                | SkotiqError::DownloadFailed { .. }
        )
    }

    /// Returns true if this error indicates the operation is not supported
    ///
    /// Use this to disable UI elements or avoid retrying operations
    /// that will never succeed on this device.
    pub fn is_not_supported(&self) -> bool {
        matches!(self, SkotiqError::NotSupported { .. })
    }

    /// Returns true if this error is due to invalid user input
    ///
    /// Use this to prompt user to correct their input.
    pub fn is_invalid_input(&self) -> bool {
        matches!(
            self,
            SkotiqError::InvalidParameter(_)
                | SkotiqError::InvalidInput(_)
                | SkotiqError::InvalidDeviceId { .. }
                | SkotiqError::ParameterOutOfRange { .. }
        )
    }

    /// Returns true if this is a user-initiated cancellation (not an error)
    pub fn is_cancellation(&self) -> bool {
        matches!(
            self,
            SkotiqError::Cancelled | SkotiqError::ExposureCancelled
        )
    }

    /// Get the device ID if this error is device-related
    pub fn device_id(&self) -> Option<&str> {
        match self {
            SkotiqError::DeviceNotFound(id) => Some(id),
            SkotiqError::ConnectionFailed { device_id, .. } => Some(device_id),
            SkotiqError::AlreadyConnected(id) => Some(id),
            SkotiqError::NotConnected(id) => Some(id),
            SkotiqError::DeviceDisconnected { device_id, .. } => Some(device_id),
            SkotiqError::HardwareError { device_id, .. } => Some(device_id),
            SkotiqError::CommunicationError { device_id, .. } => Some(device_id),
            SkotiqError::DeviceTimeout { device_id, .. } => Some(device_id),
            SkotiqError::ConnectionTimeout { device_id, .. } => Some(device_id),
            SkotiqError::InvalidDeviceId { device_id, .. } => Some(device_id),
            SkotiqError::NotSupported { device_id, .. } => Some(device_id),
            SkotiqError::DeviceBusy { device_id, .. } => Some(device_id),
            SkotiqError::ExposureFailed { camera_id, .. } => Some(camera_id),
            SkotiqError::DownloadFailed { camera_id, .. } => Some(camera_id),
            _ => None,
        }
    }

    /// Get the vendor-specific error code if available
    ///
    /// Returns error codes from ASCOM, Alpaca, INDI, native SDKs, etc.
    pub fn error_code(&self) -> Option<i32> {
        match self {
            SkotiqError::HardwareError { error_code, .. } => *error_code,
            SkotiqError::AscomError { error_code, .. } => Some(*error_code),
            SkotiqError::AlpacaError { error_code, .. } => Some(*error_code),
            SkotiqError::NativeError { error_code, .. } => Some(*error_code),
            // Why: HRESULT is canonically a signed
            // 32-bit value (Win32 `HRESULT` typedef). We store it as u32
            // (Windows-crate convention) and reinterpret here — this is
            // the standard COM error-code idiom; bit pattern is preserved.
            SkotiqError::ComError { hresult, .. } => Some(*hresult as i32),
            _ => None,
        }
    }

    /// Get a user-friendly error message suitable for display in UI
    ///
    /// This provides a shorter, less technical message than the full error.
    pub fn user_message(&self) -> String {
        match self {
            SkotiqError::DeviceNotFound(id) => format!("Device '{}' not found", id),
            SkotiqError::ConnectionFailed { device_id, .. } => {
                format!("Could not connect to '{}'", device_id)
            }
            SkotiqError::NotConnected(id) => format!("'{}' is not connected", id),
            SkotiqError::DeviceDisconnected { device_id, .. } => {
                format!("'{}' disconnected unexpectedly", device_id)
            }
            SkotiqError::HardwareError {
                device_id, message, ..
            } => {
                format!("Hardware error on '{}': {}", device_id, message)
            }
            SkotiqError::Timeout(msg)
            | SkotiqError::DeviceTimeout { operation: msg, .. } => {
                format!("Operation timed out: {}", msg)
            }
            SkotiqError::ConnectionTimeout {
                device_id,
                timeout_secs,
            } => {
                format!(
                    "Connection to '{}' timed out after {:.0}s",
                    device_id, timeout_secs
                )
            }
            SkotiqError::NotSupported {
                device_id,
                operation,
            } => {
                format!("'{}' does not support: {}", device_id, operation)
            }
            SkotiqError::InvalidParameter(msg) | SkotiqError::InvalidInput(msg) => {
                format!("Invalid input: {}", msg)
            }
            SkotiqError::ParameterOutOfRange {
                param_name,
                value,
                min,
                max,
            } => {
                format!(
                    "{} value {} is out of range ({} to {})",
                    param_name, value, min, max
                )
            }
            SkotiqError::ExposureCancelled | SkotiqError::Cancelled => {
                "Operation cancelled".to_string()
            }
            SkotiqError::DeviceBusy {
                device_id,
                current_operation,
            } => {
                format!("'{}' is busy: {}", device_id, current_operation)
            }
            // For other errors, use the Display implementation
            other => other.to_string(),
        }
    }

    /// Get a classification of the error for telemetry/logging
    pub fn error_category(&self) -> &'static str {
        match self {
            SkotiqError::DeviceNotFound(_)
            | SkotiqError::ConnectionFailed { .. }
            | SkotiqError::AlreadyConnected(_)
            | SkotiqError::NotConnected(_)
            | SkotiqError::DeviceDisconnected { .. } => "connection",

            SkotiqError::HardwareError { .. } | SkotiqError::CommunicationError { .. } => {
                "hardware"
            }

            SkotiqError::Timeout(_)
            | SkotiqError::DeviceTimeout { .. }
            | SkotiqError::ConnectionTimeout { .. } => "timeout",

            SkotiqError::InvalidParameter(_)
            | SkotiqError::InvalidInput(_)
            | SkotiqError::InvalidDeviceId { .. }
            | SkotiqError::ParameterOutOfRange { .. } => "validation",

            SkotiqError::NotSupported { .. } => "unsupported",

            SkotiqError::DeviceBusy { .. } => "busy",

            SkotiqError::ImageError(_)
            | SkotiqError::CameraError(_)
            | SkotiqError::NoImageAvailable
            | SkotiqError::ExposureCancelled
            | SkotiqError::ExposureFailed { .. }
            | SkotiqError::DownloadFailed { .. } => "imaging",

            SkotiqError::IoError(_) | SkotiqError::PlateSolveError(_) => "io",

            SkotiqError::SequenceError(_) => "sequence",

            SkotiqError::AscomError { .. }
            | SkotiqError::AlpacaError { .. }
            | SkotiqError::IndiError { .. }
            | SkotiqError::NativeError { .. }
            | SkotiqError::ComError { .. } => "driver",

            SkotiqError::Internal(_)
            | SkotiqError::Cancelled
            | SkotiqError::RuntimeInitFailed(_)
            | SkotiqError::ResourceExhausted { .. }
            | SkotiqError::SerializationError(_)
            | SkotiqError::OperationFailed(_) => "system",
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

// Backward compatibility - conversion to string for legacy APIs

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

// FFI serialization support

/// Structured error information for FFI transfer
///
/// This struct provides a flat representation of the error that can be
/// easily serialized and transferred across the FFI boundary to Dart.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ErrorInfo {
    /// Error category (timeout, connection, hardware, validation, etc.)
    pub category: String,
    /// Human-readable error message
    pub message: String,
    /// User-friendly message for UI display
    pub user_message: String,
    /// Whether the operation can be retried
    pub is_recoverable: bool,
    /// Whether reconnection should be attempted
    pub should_reconnect: bool,
    /// Whether this was a timeout
    pub is_timeout: bool,
    /// Device ID if error is device-related
    pub device_id: Option<String>,
    /// Vendor-specific error code if available
    pub error_code: Option<i32>,
}

impl From<&SkotiqError> for ErrorInfo {
    fn from(e: &SkotiqError) -> Self {
        ErrorInfo {
            category: e.error_category().to_string(),
            message: e.to_string(),
            user_message: e.user_message(),
            is_recoverable: e.is_recoverable(),
            should_reconnect: e.should_reconnect(),
            is_timeout: e.is_timeout(),
            device_id: e.device_id().map(|s| s.to_string()),
            error_code: e.error_code(),
        }
    }
}

impl From<SkotiqError> for ErrorInfo {
    fn from(e: SkotiqError) -> Self {
        ErrorInfo::from(&e)
    }
}

impl SkotiqError {
    /// Convert to ErrorInfo for FFI serialization
    pub fn to_error_info(&self) -> ErrorInfo {
        ErrorInfo::from(self)
    }

    /// Serialize the error to JSON for FFI transfer
    pub fn to_json(&self) -> String {
        serde_json::to_string(&self.to_error_info()).unwrap_or_else(|_| self.to_string())
    }
}

// Backward compatibility - legacy error conversion

// Allow converting legacy string-based InvalidDeviceId to new format
impl SkotiqError {
    /// Convert from legacy InvalidDeviceId(String) format
    pub fn from_legacy_invalid_device_id(msg: String) -> Self {
        SkotiqError::InvalidDeviceId {
            device_id: "unknown".to_string(),
            reason: msg,
        }
    }

    /// Convert from legacy ConnectionFailed(String) format
    pub fn from_legacy_connection_failed(msg: String) -> Self {
        SkotiqError::ConnectionFailed {
            device_id: "unknown".to_string(),
            reason: msg,
        }
    }
}

/// Result type alias for Skotiq operations
pub type SkotiqResult<T> = Result<T, SkotiqError>;

// Safe conversion traits

/// Extension trait for safely converting Results with context
pub trait ResultExt<T> {
    /// Add context to an error
    fn with_context<C: FnOnce() -> String>(self, context: C) -> SkotiqResult<T>;

    /// Convert to SkotiqError with device context
    fn with_device_context(self, device_id: &str, operation: &str) -> SkotiqResult<T>;
}

impl<T, E: std::fmt::Display> ResultExt<T> for Result<T, E> {
    fn with_context<C: FnOnce() -> String>(self, context: C) -> SkotiqResult<T> {
        self.map_err(|e| SkotiqError::Internal(format!("{}: {}", context(), e)))
    }

    fn with_device_context(self, device_id: &str, operation: &str) -> SkotiqResult<T> {
        self.map_err(|e| {
            SkotiqError::OperationFailed(format!("{} on {}: {}", operation, device_id, e))
        })
    }
}

/// Extension trait for safely converting Options
pub trait OptionExt<T> {
    /// Convert None to a device not found error
    fn or_device_not_found(self, device_id: &str) -> SkotiqResult<T>;

    /// Convert None to an internal error
    fn or_internal(self, message: &str) -> SkotiqResult<T>;
}

impl<T> OptionExt<T> for Option<T> {
    fn or_device_not_found(self, device_id: &str) -> SkotiqResult<T> {
        self.ok_or_else(|| SkotiqError::DeviceNotFound(device_id.to_string()))
    }

    fn or_internal(self, message: &str) -> SkotiqResult<T> {
        self.ok_or_else(|| SkotiqError::Internal(message.to_string()))
    }
}
