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
}
