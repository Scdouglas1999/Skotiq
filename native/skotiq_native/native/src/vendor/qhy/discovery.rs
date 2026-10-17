//! QHY camera discovery and SDK status.

use super::*;

/// QHY camera discovery info
pub struct QhyCameraInfo {
    /// Full camera ID string (e.g., "QHY183M-123456789")
    pub camera_id: String,
    /// Model name parsed from ID (e.g., "QHY183M")
    pub name: String,
    /// Serial number parsed from ID (e.g., "123456789")
    pub serial_number: Option<String>,
    /// QHY SDK version reported by the loaded native library, when available
    pub sdk_version: Option<String>,
}

impl QhyCameraInfo {
    /// Parse a QHY camera ID string into model name and serial number
    /// Format: "ModelName-SerialNumber" e.g., "QHY183M-123456789"
    pub(crate) fn parse_id(id: &str) -> (String, Option<String>) {
        if let Some(dash_pos) = id.rfind('-') {
            let model = id[..dash_pos].to_string();
            let serial = id[dash_pos + 1..].to_string();
            // Only treat as serial if it looks like a number/serial
            if !serial.is_empty() && serial.chars().all(|c| c.is_alphanumeric()) {
                return (model, Some(serial));
            }
        }
        // No serial number found, use full ID as name
        (id.to_string(), None)
    }
}

/// Check if QHY SDK is available
pub fn is_sdk_available() -> bool {
    QhySdk::get().is_some()
}

/// Internal function to perform the actual SDK discovery.
/// This is separated out to allow catch_unwind wrapping.
pub(crate) fn discover_devices_internal(sdk: &QhySdk) -> Result<Vec<QhyCameraInfo>, NativeError> {
    let sdk_version = sdk_version_from_sdk(sdk);

    // Scan for cameras
    // SAFETY: This helper is invoked only from discover_devices() (and the catch_unwind path it
    // dispatches), which acquires qhy_mutex() before calling. ScanQHYCCD takes no arguments and
    // returns a c_uint count.
    let num_cameras = unsafe { (sdk.scan_qhyccd)() };
    tracing::info!("Found {} QHY cameras", num_cameras);

    let mut cameras = Vec::new();
    for i in 0..num_cameras {
        let mut id_buf = [0 as c_char; 256];
        // SAFETY: caller (discover_devices) holds qhy_mutex(); `i` is in `0..num_cameras` so
        // ScanQHYCCD's reported index range; id_buf is a 256-byte stack array — qhyccd.h
        // documents the ID as fitting within 32 bytes.
        let result = unsafe { (sdk.get_qhyccd_id)(i, id_buf.as_mut_ptr()) };

        if result == 0 {
            // SAFETY: id_buf is 256 bytes; GetQHYCCDId guarantees NUL-termination on success
            // (result == 0).
            let id = unsafe { CStr::from_ptr(id_buf.as_ptr()) }
                .to_string_lossy()
                .to_string();

            // Parse model name and serial number from ID
            let (name, serial_number) = QhyCameraInfo::parse_id(&id);

            cameras.push(QhyCameraInfo {
                camera_id: id,
                name,
                serial_number,
                sdk_version: sdk_version.clone(),
            });
        }
    }

    Ok(cameras)
}

/// Discover QHY cameras with safety measures.
///
/// This function includes several safety measures to handle potential SDK issues:
///
/// 1. **Enable/Disable Check**: Returns empty if discovery is disabled via
///    `set_qhy_discovery_enabled(false)`
/// 2. **Panic Protection**: SDK calls are wrapped in `catch_unwind` to prevent
///    crashes from propagating
/// 3. **Timeout**: Discovery has a configurable timeout (default 10s, can be
///    overridden via quirks database)
/// 4. **Mutex Serialization**: All SDK calls are serialized via `qhy_mutex()`
///
/// # Returns
/// * `Ok(cameras)` - List of discovered cameras (may be empty)
/// * `Err(NativeError::SdkNotLoaded)` - SDK not available or discovery disabled
/// * `Err(NativeError::Timeout)` - Discovery timed out
/// * `Err(NativeError::SdkError)` - SDK panicked during discovery
pub async fn discover_devices() -> Result<Vec<QhyCameraInfo>, NativeError> {
    let config = get_discovery_config();

    // Check if discovery is enabled
    if !config.enabled {
        tracing::debug!("QHY discovery is disabled, returning empty list");
        return Ok(Vec::new());
    }

    // Ensure SDK is initialized first (before timeout starts)
    QhySdk::ensure_initialized()?;

    // Verify SDK is available before proceeding
    if QhySdk::get().is_none() {
        return Ok(Vec::new());
    }

    // Acquire mutex for SDK discovery operations
    let _lock = qhy_mutex().lock().await;

    // Create the timeout duration from config
    let timeout_duration = Duration::from_millis(config.timeout_ms);

    // Perform discovery with timeout
    let catch_panics = config.catch_panics;
    let discovery_future = async move {
        if catch_panics {
            // Wrap SDK calls in catch_unwind for crash protection
            // We use spawn_blocking because catch_unwind works best in sync context
            // We get the SDK inside the blocking task to avoid Send issues with raw pointers
            tokio::task::spawn_blocking(move || {
                // Get SDK inside the blocking task - this is safe because SDK is 'static
                let sdk = match QhySdk::get() {
                    Some(s) => s,
                    None => return Err(NativeError::SdkNotLoaded),
                };
                catch_unwind(AssertUnwindSafe(|| discover_devices_internal(sdk)))
                    .map_err(|panic_info| {
                        let panic_msg = if let Some(s) = panic_info.downcast_ref::<&str>() {
                            s.to_string()
                        } else if let Some(s) = panic_info.downcast_ref::<String>() {
                            s.clone()
                        } else {
                            "Unknown panic".to_string()
                        };
                        tracing::error!("QHY SDK panicked during discovery: {}", panic_msg);
                        NativeError::SdkError(format!(
                            "QHY SDK crashed during discovery: {}. Discovery has been disabled. \
                             Re-enable with api_set_qhy_discovery_enabled(true) if you want to try again.",
                            panic_msg
                        ))
                    })?
            })
            .await
            .map_err(|e| {
                NativeError::SdkError(format!("QHY discovery task failed: {:?}", e))
            })?
        } else {
            // No panic protection, just call directly (SDK is 'static, so we can get it again)
            let sdk = QhySdk::get().ok_or(NativeError::SdkNotLoaded)?;
            discover_devices_internal(sdk)
        }
    };

    // Apply timeout
    match tokio::time::timeout(timeout_duration, discovery_future).await {
        Ok(result) => {
            match &result {
                Ok(cameras) => {
                    tracing::debug!(
                        "QHY discovery completed successfully, found {} cameras",
                        cameras.len()
                    );
                }
                Err(e) => {
                    tracing::warn!("QHY discovery failed: {}", e);
                    // On failure, disable discovery to prevent repeated crashes
                    set_qhy_discovery_enabled(false);
                }
            }
            result
        }
        Err(_) => {
            tracing::error!(
                "QHY discovery timed out after {}ms. Disabling QHY discovery.",
                config.timeout_ms
            );
            // Disable discovery to prevent repeated timeouts
            set_qhy_discovery_enabled(false);
            Err(NativeError::Timeout(format!(
                "QHY discovery timed out after {}ms. Discovery has been disabled. \
                 Re-enable with api_set_qhy_discovery_enabled(true) if you want to try again.",
                config.timeout_ms
            )))
        }
    }
}
