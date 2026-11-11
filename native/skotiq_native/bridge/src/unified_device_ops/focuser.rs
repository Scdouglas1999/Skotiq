use super::*;

#[async_trait]
impl FocuserOps for UnifiedDeviceOps {
    async fn focuser_move_to(&self, focuser_id: &str, position: i32) -> DeviceResult<()> {
        tracing::info!("Moving focuser {} to position {}", focuser_id, position);

        // `DeviceManager::focuser_move_abs` publishes the move's start and end.
        api_focuser_move_to(focuser_id.to_string(), position)
            .await
            .map_err(|e| format!("Focuser move failed: {}", e))
    }

    async fn focuser_get_position(&self, focuser_id: &str) -> DeviceResult<i32> {
        get_device_manager()
            .focuser_get_position(focuser_id)
            .await
            .map_err(|e| format!("Get position failed: {}", e))
    }

    async fn focuser_is_moving(&self, focuser_id: &str) -> DeviceResult<bool> {
        get_device_manager()
            .focuser_is_moving(focuser_id)
            .await
            .map_err(|e| format!("Is moving failed: {}", e))
    }

    async fn focuser_get_temperature(&self, focuser_id: &str) -> DeviceResult<Option<f64>> {
        get_device_manager()
            .focuser_get_temp(focuser_id)
            .await
            .map_err(|e| format!("Get temperature failed: {}", e))
    }

    async fn focuser_halt(&self, focuser_id: &str) -> DeviceResult<()> {
        get_device_manager()
            .focuser_halt(focuser_id)
            .await
            .map_err(|e| format!("Halt failed: {}", e))
    }
}
