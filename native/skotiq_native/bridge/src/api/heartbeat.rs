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
        .map_err(SkotiqError::from)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A device the host has not registered yet (a client polling right after
    /// a host restart) is a lookup miss the HTTP layer answers 404, not a
    /// failed operation it answers 500.
    #[tokio::test]
    async fn an_unregistered_device_is_not_found() {
        let id = "health_probe_never_registered";
        let err = api_get_device_health(id.to_string()).await.unwrap_err();
        assert!(
            matches!(&err, SkotiqError::DeviceNotFound(found) if found == id),
            "{err:?}"
        );
    }
}
