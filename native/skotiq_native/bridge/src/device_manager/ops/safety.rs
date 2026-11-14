//! Safety monitor operations.

use crate::device_manager::handle::device_error;
use crate::device_manager::DeviceManager;
use crate::dispatch::error::DeviceOpError;

impl DeviceManager {
    /// Whether the safety monitor says it is safe to observe.
    pub async fn safety_is_safe(&self, device_id: &str) -> Result<bool, DeviceOpError> {
        self.safety_monitor(device_id)
            .await?
            .is_safe()
            .await
            .map_err(|e| device_error(device_id, e))
    }
}
