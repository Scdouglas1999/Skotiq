use super::*;

#[async_trait]
impl RotatorOps for UnifiedDeviceOps {
    async fn rotator_move_to(&self, rotator_id: &str, angle: f64) -> DeviceResult<()> {
        tracing::info!("Moving rotator {} to {}°", rotator_id, angle);

        // `DeviceManager::rotator_move_absolute` publishes the move's start and
        // end.
        get_device_manager()
            .rotator_move_absolute(rotator_id, angle)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::Rotator))
    }

    async fn rotator_move_relative(&self, rotator_id: &str, delta: f64) -> DeviceResult<()> {
        tracing::info!("Moving rotator {} by {}°", rotator_id, delta);

        get_device_manager()
            .rotator_move_relative(rotator_id, delta)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::Rotator))
    }

    async fn rotator_get_angle(&self, rotator_id: &str) -> DeviceResult<f64> {
        get_device_manager()
            .rotator_get_position(rotator_id)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::Rotator))
    }

    async fn rotator_halt(&self, rotator_id: &str) -> DeviceResult<()> {
        tracing::info!("Halting rotator {}", rotator_id);

        get_device_manager()
            .rotator_halt(rotator_id)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::Rotator))
    }
}
