//! Whether a device is connected, and reconnecting one.

use super::{DeviceError, DeviceResult};
use async_trait::async_trait;

#[async_trait]
pub trait ConnectionOps: Send + Sync {
    /// Whether the device answers when asked now. The device layer probes
    /// the device itself: a camera that left the bus a second ago is still
    /// "connected" in every record kept from the last poll, and recovery that
    /// trusted the record would report a dead device recovered.
    async fn device_answers(&self, device_id: &str) -> DeviceResult<bool> {
        let _ = device_id;
        Err(DeviceError::unsupported(
            "device_answers not supported by this driver",
        ))
    }

    /// Actively (re)connect a device by id.
    ///
    /// The recovery loop calls this for each device that did not answer on a
    /// device-disconnect cause, rather than only polling `device_answers`.
    /// Camera/focuser/filter-wheel default to `auto_reconnect = false`, so the
    /// background reconnection loop never retries them — without an active
    /// connect the recovery budget would be burned reporting "still
    /// disconnected". Default impl is a no-op error so drivers that do not
    /// support reconnection fall back to passive polling.
    async fn connect_device(&self, device_id: &str) -> DeviceResult<()> {
        let _ = device_id;
        Err(DeviceError::unsupported(
            "connect_device not supported by this driver",
        ))
    }

    /// Close and reopen a camera whose exposure just failed with `error`,
    /// when the failure means the camera's session is broken: it still
    /// answers status reads but takes no exposure until it is reopened. The
    /// reopen goes through the normal connection path, which restores the
    /// cooler, gain and offset the camera had.
    ///
    /// `Ok(true)` when the camera was reopened, `Ok(false)` when the failure
    /// does not call for a reopen, and an error when the reopen failed.
    async fn reopen_camera_after(
        &self,
        camera_id: &str,
        error: &DeviceError,
    ) -> DeviceResult<bool> {
        let _ = (camera_id, error);
        Ok(false)
    }
}
