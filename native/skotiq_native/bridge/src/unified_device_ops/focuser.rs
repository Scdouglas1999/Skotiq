use super::{device_error, UnifiedDeviceOps};
use crate::device_manager::get_device_manager;
use async_trait::async_trait;
use skotiq_sequencer::{DeviceResult, FocuserOps};

#[async_trait]
impl FocuserOps for UnifiedDeviceOps {
    async fn focuser_move_to(&self, focuser_id: &str, position: i32) -> DeviceResult<()> {
        tracing::info!("Moving focuser {} to position {}", focuser_id, position);

        // `DeviceManager::focuser_move_abs` publishes the move's start and end.
        get_device_manager()
            .focuser_move_abs(focuser_id, position)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::Focuser))
    }

    async fn focuser_get_position(&self, focuser_id: &str) -> DeviceResult<i32> {
        get_device_manager()
            .focuser_get_position(focuser_id)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::Focuser))
    }

    async fn focuser_is_moving(&self, focuser_id: &str) -> DeviceResult<bool> {
        get_device_manager()
            .focuser_is_moving(focuser_id)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::Focuser))
    }

    async fn focuser_get_temperature(&self, focuser_id: &str) -> DeviceResult<Option<f64>> {
        get_device_manager()
            .focuser_get_temp(focuser_id)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::Focuser))
    }

    async fn focuser_halt(&self, focuser_id: &str) -> DeviceResult<()> {
        get_device_manager()
            .focuser_halt(focuser_id)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::Focuser))
    }
}
