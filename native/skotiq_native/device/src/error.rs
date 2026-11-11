//! The error every driver returns.

#[derive(Debug, thiserror::Error)]
pub enum DriverError {
    #[error("Device not connected")]
    NotConnected,

    #[error("Device disconnected")]
    Disconnected,

    #[error("Device not found: {0}")]
    DeviceNotFound(String),

    #[error("Invalid device: {0}")]
    InvalidDevice(String),

    #[error("SDK error: {0}")]
    SdkError(String),

    #[error("SDK not loaded")]
    SdkNotLoaded,

    #[error("SDK not installed: {0}")]
    SdkNotInstalled(String),

    #[error("Invalid parameter: {0}")]
    InvalidParameter(String),

    #[error("Operation not supported")]
    NotSupported,

    #[error("Operation timeout: {0}")]
    Timeout(String),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Unknown error: {0}")]
    Unknown(String),
}
