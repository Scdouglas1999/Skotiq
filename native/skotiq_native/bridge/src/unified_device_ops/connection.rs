use super::UnifiedDeviceOps;
use crate::device_manager::get_device_manager;
use async_trait::async_trait;
use skotiq_sequencer::{ConnectionOps, DeviceError, DeviceKind, DeviceResult};

#[async_trait]
impl ConnectionOps for UnifiedDeviceOps {
    // Connection / recovery
    //
    // These two overrides are what make device-disconnect recovery actually
    // work on the live path. Without them the trait defaults
    // return `Err("not supported")`, so the
    // `DeviceDisconnected` recovery loop fails instantly on every driver and a
    // USB/comms blip aborts the night. They delegate straight to the
    // `DeviceManager` primitives.

    async fn device_answers(&self, device_id: &str) -> DeviceResult<bool> {
        Ok(get_device_manager().answers_now(device_id).await)
    }

    async fn connect_device(&self, device_id: &str) -> DeviceResult<()> {
        get_device_manager()
            .connect_device_automatically(device_id)
            .await
            .map_err(Into::into)
    }

    async fn reopen_camera_after(
        &self,
        camera_id: &str,
        error: &DeviceError,
    ) -> DeviceResult<bool> {
        get_device_manager()
            .reopen_camera_after(camera_id, &error.to_string())
            .await
            .map_err(|message| DeviceError::NotConnected {
                device: DeviceKind::Camera,
                message,
            })
    }
}
