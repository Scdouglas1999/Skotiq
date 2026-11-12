use super::*;

#[async_trait]
impl RotatorOps for UnifiedDeviceOps {
    async fn rotator_move_to(&self, rotator_id: &str, angle: f64) -> DeviceResult<()> {
        tracing::info!("Moving rotator {} to {}°", rotator_id, angle);

        // `DeviceManager::rotator_move_absolute` publishes the move's start and
        // end.
        api_rotator_move_to(rotator_id.to_string(), angle)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::Rotator))
    }

    async fn rotator_move_relative(&self, rotator_id: &str, delta: f64) -> DeviceResult<()> {
        tracing::info!("Moving rotator {} by {}°", rotator_id, delta);

        api_rotator_move_relative(rotator_id.to_string(), delta)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::Rotator))
    }

    async fn rotator_get_angle(&self, rotator_id: &str) -> DeviceResult<f64> {
        let status = api_get_rotator_status(rotator_id.to_string())
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::Rotator))?;

        Ok(status.position)
    }

    async fn rotator_halt(&self, rotator_id: &str) -> DeviceResult<()> {
        tracing::info!("Halting rotator {}", rotator_id);

        api_rotator_halt(rotator_id.to_string())
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::Rotator))
    }
}
