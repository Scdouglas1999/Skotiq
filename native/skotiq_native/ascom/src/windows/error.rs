//! ASCOM error types and result alias.

/// ASCOM-specific error types for better error handling and diagnostics
#[derive(Debug, Clone)]
pub enum AscomError {
    /// COM error with HRESULT code
    ComError { hresult: i32, message: String },
    /// Operation timed out
    Timeout { operation: String, duration_ms: u64 },
    /// Device is not connected
    NotConnected,
    /// Property is not available on this device
    PropertyNotAvailable { property: String, reason: String },
    /// Invalid value provided
    InvalidValue { value: String, reason: String },
    /// ASCOM exception from driver
    AscomException {
        code: i32,
        source: String,
        description: String,
    },
    /// Device communication error
    CommunicationError { message: String },
    /// Resource allocation error
    ResourceError { message: String },
    /// Generic error
    Other(String),
}

impl std::fmt::Display for AscomError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AscomError::ComError { hresult, message } => {
                write!(f, "COM error (HRESULT {:#X}): {}", hresult, message)
            }
            AscomError::Timeout {
                operation,
                duration_ms,
            } => {
                write!(
                    f,
                    "Operation '{}' timed out after {}ms",
                    operation, duration_ms
                )
            }
            AscomError::NotConnected => {
                write!(f, "Device is not connected")
            }
            AscomError::PropertyNotAvailable { property, reason } => {
                write!(f, "Property '{}' not available: {}", property, reason)
            }
            AscomError::InvalidValue { value, reason } => {
                write!(f, "Invalid value '{}': {}", value, reason)
            }
            AscomError::AscomException {
                code,
                source,
                description,
            } => {
                write!(
                    f,
                    "ASCOM exception (code {}): {} - {}",
                    code, source, description
                )
            }
            AscomError::CommunicationError { message } => {
                write!(f, "Communication error: {}", message)
            }
            AscomError::ResourceError { message } => {
                write!(f, "Resource error: {}", message)
            }
            AscomError::Other(msg) => {
                write!(f, "{}", msg)
            }
        }
    }
}

impl std::error::Error for AscomError {}

impl From<AscomError> for String {
    fn from(err: AscomError) -> String {
        err.to_string()
    }
}

impl From<String> for AscomError {
    fn from(s: String) -> Self {
        AscomError::Other(s)
    }
}

impl From<&str> for AscomError {
    fn from(s: &str) -> Self {
        AscomError::Other(s.to_string())
    }
}

/// Result type for ASCOM operations
pub type AscomResult<T> = Result<T, AscomError>;
