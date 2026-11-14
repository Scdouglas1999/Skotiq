//! QHY camera discovery and SDK status.

use super::*;

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

pub fn is_sdk_available() -> bool {
    QhySdk::is_available()
}

/// The cameras the SDK lists, with model and serial parsed from their ids.
pub(crate) fn discover_devices_internal(sdk: &QhySdk) -> Vec<QhyCameraInfo> {
    let sdk_version = sdk_version_from_sdk(sdk);
    let cameras: Vec<QhyCameraInfo> = session::scan(sdk)
        .into_iter()
        .map(|camera_id| {
            let (name, serial_number) = QhyCameraInfo::parse_id(&camera_id);
            QhyCameraInfo {
                camera_id,
                name,
                serial_number,
                sdk_version: sdk_version.clone(),
            }
        })
        .collect();
    tracing::info!("Found {} QHY cameras", cameras.len());
    cameras
}

pub(crate) fn panic_text(panic: &Box<dyn std::any::Any + Send>) -> String {
    if let Some(s) = panic.downcast_ref::<&str>() {
        s.to_string()
    } else if let Some(s) = panic.downcast_ref::<String>() {
        s.clone()
    } else {
        "Unknown panic".to_string()
    }
}

/// Discover QHY cameras with safety measures.
///
/// 1. **Enable/Disable Check**: Returns empty if discovery is disabled via
///    `set_qhy_discovery_enabled(false)`
/// 2. **Panic Protection**: the scan is wrapped in `catch_unwind`
/// 3. **Timeout**: Discovery has a configurable timeout (default 10s, can be
///    overridden via quirks database); a scan that times out keeps the SDK
///    lock on its blocking thread until the SDK returns, so no other call
///    enters the SDK while it is still scanning
///
/// # Returns
/// * `Ok(cameras)` - List of discovered cameras (may be empty)
/// * `Err(DriverError::Timeout)` - Discovery timed out
/// * `Err(DriverError::SdkError)` - SDK panicked during discovery
pub async fn discover_devices() -> Result<Vec<QhyCameraInfo>, DriverError> {
    let config = get_discovery_config();

    if !config.enabled {
        tracing::debug!("QHY discovery is disabled, returning empty list");
        return Ok(Vec::new());
    }

    QhySdk::ensure_initialized()?;
    let sdk = QhySdk::lock().await?;
    let scan = tokio::task::spawn_blocking(move || {
        catch_unwind(AssertUnwindSafe(|| discover_devices_internal(&sdk)))
    });
    let result = match tokio::time::timeout(Duration::from_millis(config.timeout_ms), scan).await {
        Ok(Ok(Ok(cameras))) => return Ok(cameras),
        Ok(Ok(Err(panic))) => {
            let panic_msg = panic_text(&panic);
            tracing::error!("QHY SDK panicked during discovery: {}", panic_msg);
            DriverError::SdkError(format!(
                "QHY SDK crashed during discovery: {}. Discovery has been disabled. \
                 Re-enable with api_set_qhy_discovery_enabled(true) if you want to try again.",
                panic_msg
            ))
        }
        Ok(Err(e)) => DriverError::SdkError(format!("QHY discovery task failed: {:?}", e)),
        Err(_) => {
            tracing::error!(
                "QHY discovery timed out after {}ms. Disabling QHY discovery.",
                config.timeout_ms
            );
            DriverError::Timeout(format!(
                "QHY discovery timed out after {}ms. Discovery has been disabled. \
                 Re-enable with api_set_qhy_discovery_enabled(true) if you want to try again.",
                config.timeout_ms
            ))
        }
    };
    // Disable discovery so a crashing or hanging SDK is not entered again.
    tracing::warn!("QHY discovery failed: {}", result);
    set_qhy_discovery_enabled(false);
    Err(result)
}
