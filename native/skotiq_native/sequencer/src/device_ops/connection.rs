//! Whether a device is connected, and reconnecting one.

use super::{DeviceError, DeviceResult};
use async_trait::async_trait;

#[async_trait]
pub trait ConnectionOps: Send + Sync {
    /// Query whether a specific device id is currently connected.
    ///
    /// The sequencer recovery loop uses this after a device-disconnect
    /// failure to wait for the bridge/device-manager reconnect path before
    /// resuming the failed instruction.
    async fn device_is_connected(&self, device_id: &str) -> DeviceResult<bool> {
        let _ = device_id;
        Err(DeviceError::unsupported(
            "device_is_connected",
            "device_is_connected not supported by this driver",
        ))
    }

    /// Actively (re)connect a device by id.
    ///
    /// The recovery loop calls this on a device-disconnect cause so it
    /// initiates a reconnect rather than only polling `device_is_connected`.
    /// Camera/focuser/filter-wheel default to `auto_reconnect = false`, so the
    /// background reconnection loop never retries them — without an active
    /// connect the recovery budget would be burned reporting "still
    /// disconnected". Default impl is a no-op error so drivers that do not
    /// support reconnection fall back to passive polling.
    async fn connect_device(&self, device_id: &str) -> DeviceResult<()> {
        let _ = device_id;
        Err(DeviceError::unsupported(
            "connect_device",
            "connect_device not supported by this driver",
        ))
    }
}
