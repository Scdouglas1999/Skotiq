use super::*;

/// Alpaca-specific error types
#[derive(Debug, Error)]
pub enum AlpacaError {
    #[error("Connection timeout after {duration_ms}ms during {operation}")]
    Timeout { operation: String, duration_ms: u64 },

    #[error("Connection refused: {url} - {cause}")]
    ConnectionRefused { url: String, cause: String },

    #[error("HTTP error {status}: {message}")]
    HttpError {
        status: u16,
        message: String,
        retry_after: Option<Duration>,
    },

    #[error("Device error {code}: {message}")]
    DeviceError { code: i32, message: String },

    #[error("Parse error: {0}")]
    ParseError(String),

    // Why: surface the exact JSON pixel that failed to parse instead of
    // silently zero-filling. `offset` is the linear pixel index into the array,
    // `found` is the JSON token (e.g., `"NaN"`, `null`) we couldn't coerce.
    #[error("Image array pixel parse failure at offset {offset}: {reason} (found: {found})")]
    PixelParseError {
        offset: usize,
        found: String,
        reason: String,
    },

    // Why: color (rank 3) image arrays carry a channel dimension that
    // `download_image_data_typed` flattens away. Until a typed multi-plane
    // consumer exists, surface the situation explicitly rather than silently
    // dropping data.
    #[error(
        "Color image array (rank 3, {width}x{height}x{planes}) requires multi-plane consumer; \
         use `download_image_array_full_typed` instead"
    )]
    ColorImageUnsupported {
        width: u32,
        height: u32,
        planes: u32,
    },

    // Why: when the JSON `Type` field is unknown or the (Rank, Type)
    // pair has no parser, we must reject the frame instead of guessing.
    #[error("Unsupported image array (rank={rank}, type={image_type}): {reason}")]
    UnsupportedImageArray {
        rank: i64,
        image_type: i64,
        reason: String,
    },

    // Why: the Alpaca v3 `application/imagebytes` payload begins with a
    // 44-byte fixed header. Anything shorter than the field we're trying to
    // read is wire truncation, never a recoverable condition — fail closed.
    #[error(
        "Alpaca ImageBytes header truncated: needed {needed} bytes at offset {offset}, payload is {got} bytes total"
    )]
    BinaryHeaderTruncated {
        offset: usize,
        needed: usize,
        got: usize,
    },

    // Why: the wire-side `transmission element type` is constrained to
    // the ASCOM `ImageArrayElementTypes` enum; an unknown value means we have
    // no way to interpret payload bytes safely.
    #[error("Alpaca ImageBytes unsupported transmission element type {code}")]
    UnsupportedTransmissionType { code: i32 },

    // Why: dimensions and rank must agree; a rank-2 frame with a non-zero
    // `dimension 3`, or a dim that doesn't match the requested NumX/NumY, is
    // either a server bug or wire corruption.
    #[error(
        "Alpaca ImageBytes malformed dimensions: rank={rank} dims=[{dim1},{dim2},{dim3}] (expected {expected_width}x{expected_height}): {reason}"
    )]
    MalformedDimensions {
        rank: i32,
        dim1: i32,
        dim2: i32,
        dim3: i32,
        expected_width: u32,
        expected_height: u32,
        reason: String,
    },

    #[error("Not connected")]
    NotConnected,

    #[error("Operation failed: {0}")]
    OperationFailed(String),

    #[error("Request failed: {0}")]
    RequestFailed(String),

    #[error("API version not supported: {0}")]
    UnsupportedApiVersion(String),

    #[error("Connection validation failed: {0}")]
    ValidationFailed(String),

    #[error("Retry exhausted after {attempts} attempts: {last_error}")]
    RetryExhausted { attempts: u32, last_error: String },

    #[error("HTTP client initialization failed: {0}")]
    ClientInitializationFailed(String),
}

impl AlpacaError {
    /// Create a timeout error with operation context
    pub fn timeout(operation: impl Into<String>, duration_ms: u64) -> Self {
        AlpacaError::Timeout {
            operation: operation.into(),
            duration_ms,
        }
    }

    /// Create a connection refused error
    pub fn connection_refused(url: impl Into<String>, cause: impl Into<String>) -> Self {
        AlpacaError::ConnectionRefused {
            url: url.into(),
            cause: cause.into(),
        }
    }

    /// Check if this error is retryable
    pub fn is_retryable(&self) -> bool {
        match self {
            AlpacaError::Timeout { .. } => true,
            AlpacaError::ConnectionRefused { .. } => true,
            AlpacaError::HttpError { status, .. } => {
                // Retry on 5xx server errors and 429 rate limiting
                *status >= 500 || *status == 429
            }
            AlpacaError::RequestFailed(_) => true,
            // Don't retry device errors, parse errors, validation failures
            AlpacaError::DeviceError { .. } => false,
            AlpacaError::ParseError(_) => false,
            AlpacaError::PixelParseError { .. } => false,
            AlpacaError::ColorImageUnsupported { .. } => false,
            AlpacaError::UnsupportedImageArray { .. } => false,
            AlpacaError::BinaryHeaderTruncated { .. } => false,
            AlpacaError::UnsupportedTransmissionType { .. } => false,
            AlpacaError::MalformedDimensions { .. } => false,
            AlpacaError::NotConnected => false,
            AlpacaError::OperationFailed(_) => false,
            AlpacaError::UnsupportedApiVersion(_) => false,
            AlpacaError::ValidationFailed(_) => false,
            AlpacaError::RetryExhausted { .. } => false,
            AlpacaError::ClientInitializationFailed(_) => false,
        }
    }

    pub fn retry_after(&self) -> Option<Duration> {
        match self {
            AlpacaError::HttpError { retry_after, .. } => *retry_after,
            _ => None,
        }
    }
}

impl From<reqwest::Error> for AlpacaError {
    fn from(err: reqwest::Error) -> Self {
        if err.is_timeout() {
            AlpacaError::Timeout {
                operation: "HTTP request".to_string(),
                duration_ms: 30000, // Default timeout - actual tracked in specific methods
            }
        } else if err.is_connect() {
            // Why: we are inside `From<reqwest::Error>` and
            // *already* producing an error variant (ConnectionRefused). reqwest
            // sometimes elides the URL on connect failures that originate
            // before name resolution (e.g. invalid scheme); the textual "unknown"
            // is a cosmetic placeholder inside the error payload so logs stay
            // readable. The actual connection-refused signal is preserved via
            // the variant + `cause: err.to_string()`.
            let url = err
                .url()
                .map(|u| u.to_string())
                .unwrap_or_else(|| "unknown".to_string());
            AlpacaError::ConnectionRefused {
                url,
                cause: err.to_string(),
            }
        } else if let Some(status) = err.status() {
            AlpacaError::HttpError {
                status: status.as_u16(),
                message: err.to_string(),
                retry_after: None,
            }
        } else {
            AlpacaError::RequestFailed(err.to_string())
        }
    }
}

impl From<serde_json::Error> for AlpacaError {
    fn from(err: serde_json::Error) -> Self {
        AlpacaError::ParseError(err.to_string())
    }
}

// Backward compatibility: convert AlpacaError to String for existing code
impl From<AlpacaError> for String {
    fn from(err: AlpacaError) -> Self {
        err.to_string()
    }
}
