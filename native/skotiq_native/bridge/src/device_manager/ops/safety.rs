//! Safety monitor operations.

use crate::device_manager::handle::device_error;
use crate::device_manager::DeviceManager;
use crate::dispatch::error::DeviceOpError;

impl DeviceManager {
    /// Whether the safety monitor says it is safe to observe. The outcome
    /// feeds the monitor's read health: its heartbeat only pings the link,
    /// so failing `IsSafe` reads are what get a stuck monitor reopened
    /// ([`DeviceManager::wants_reopen`]).
    pub async fn safety_is_safe(&self, device_id: &str) -> Result<bool, DeviceOpError> {
        let result = match self.safety_monitor(device_id).await {
            Ok(monitor) => monitor
                .is_safe()
                .await
                .map_err(|e| device_error(device_id, e)),
            Err(e) => Err(e),
        };
        self.note_status_read(device_id, &result);
        result
    }
}
