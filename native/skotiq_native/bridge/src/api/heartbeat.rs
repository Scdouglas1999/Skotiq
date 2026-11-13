use crate::device::DeviceType;
use crate::device_manager::get_device_manager;
use crate::error::SkotiqError;

/// The device types the native side reconnects by itself once their
/// heartbeat is lost. A caller that reconnects devices leaves these alone.
#[flutter_rust_bridge::frb(sync)]
pub fn api_native_reconnected_device_types() -> Vec<DeviceType> {
    crate::device_manager::policy::reconnected_by_heartbeat()
}

/// Device health as `(last_successful_comm_ms, is_healthy)`: when the device last
/// answered, and whether it is still responding to heartbeat checks.
pub async fn api_get_device_health(device_id: String) -> Result<(i64, bool), SkotiqError> {
    get_device_manager()
        .get_device_health(&device_id)
        .await
        .map_err(|e| SkotiqError::OperationFailed(e))
}
