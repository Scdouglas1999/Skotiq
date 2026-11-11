use super::*;

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

    async fn device_is_connected(&self, device_id: &str) -> DeviceResult<bool> {
        Ok(get_device_manager().is_connected(device_id).await)
    }

    async fn connect_device(&self, device_id: &str) -> DeviceResult<()> {
        // Mark the device auto-reconnectable so the background reconnection
        // loop keeps retrying it too (camera/focuser/filter-wheel default to
        // false), then drive an immediate connect attempt. Both together make
        // recovery actively reconnect instead of waiting out the budget.
        get_device_manager()
            .set_auto_reconnect(device_id, true)
            .await;
        get_device_manager()
            .connect_device(device_id)
            .await
            .map_err(Into::into)
    }
}
