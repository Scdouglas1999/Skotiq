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

    /// The vendor SDK no longer lists the device, so a cached device list
    /// that offers it is out of date. Worded as an invalid device.
    #[error("Invalid device: {0}")]
    NotEnumerated(String),

    #[error("SDK error: {0}")]
    SdkError(String),

    /// The device still answers, but its SDK session is broken: it takes no
    /// exposure until it is closed and opened again. Worded as an SDK error.
    #[error("SDK error: {0}")]
    SessionLost(String),

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

    /// A failure in the words of the protocol client or layer that produced
    /// it. Callers that know that layer's error type can downcast it.
    #[error(transparent)]
    Backend(Box<dyn std::error::Error + Send + Sync>),
}
