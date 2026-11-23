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
    // `DeviceManager` primitives, at the id the device is at now
    // (`DeviceManager::current_id`).

    async fn device_answers(&self, device_id: &str) -> DeviceResult<bool> {
        let mgr = get_device_manager();
        Ok(mgr.answers_now(&mgr.current_id(device_id)).await)
    }

    async fn connect_device(&self, device_id: &str) -> DeviceResult<()> {
        let mgr = get_device_manager();
        mgr.connect_device_automatically(&mgr.current_id(device_id))
            .await
            .map_err(Into::into)
    }

    async fn reopen_camera_after(
        &self,
        camera_id: &str,
        error: &DeviceError,
    ) -> DeviceResult<bool> {
        let mgr = get_device_manager();
        mgr.reopen_after(
            &mgr.current_id(camera_id),
            &crate::device_manager::failure::DeviceFailure::from(error),
        )
        .await
        .map_err(|message| DeviceError::NotConnected {
            device: DeviceKind::Camera,
            message,
        })
    }
}
