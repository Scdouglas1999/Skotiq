use super::{device_error, UnifiedDeviceOps};
use crate::device::DeviceType;
use crate::device_manager::get_device_manager;
use async_trait::async_trait;
use skotiq_sequencer::{CoverCalibratorOps, DeviceResult};

#[async_trait]
impl CoverCalibratorOps for UnifiedDeviceOps {
    async fn active_cover_calibrator_id(&self) -> Option<String> {
        get_device_manager()
            .first_connected_device_id(DeviceType::CoverCalibrator)
            .await
    }

    async fn cover_calibrator_open_cover(&self, device_id: &str) -> DeviceResult<()> {
        get_device_manager()
            .cover_calibrator_open_cover(device_id)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::CoverCalibrator))
    }

    async fn cover_calibrator_close_cover(&self, device_id: &str) -> DeviceResult<()> {
        get_device_manager()
            .cover_calibrator_close_cover(device_id)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::CoverCalibrator))
    }

    async fn cover_calibrator_halt_cover(&self, device_id: &str) -> DeviceResult<()> {
        get_device_manager()
            .cover_calibrator_halt_cover(device_id)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::CoverCalibrator))
    }

    async fn cover_calibrator_calibrator_on(
        &self,
        device_id: &str,
        brightness: i32,
    ) -> DeviceResult<()> {
        get_device_manager()
            .cover_calibrator_calibrator_on(device_id, brightness)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::CoverCalibrator))
    }

    async fn cover_calibrator_calibrator_off(&self, device_id: &str) -> DeviceResult<()> {
        get_device_manager()
            .cover_calibrator_calibrator_off(device_id)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::CoverCalibrator))
    }

    async fn cover_calibrator_get_cover_state(&self, device_id: &str) -> DeviceResult<i32> {
        get_device_manager()
            .cover_calibrator_get_cover_state(device_id)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::CoverCalibrator))
    }

    async fn cover_calibrator_get_calibrator_state(&self, device_id: &str) -> DeviceResult<i32> {
        get_device_manager()
            .cover_calibrator_get_calibrator_state(device_id)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::CoverCalibrator))
    }

    async fn cover_calibrator_get_brightness(&self, device_id: &str) -> DeviceResult<i32> {
        get_device_manager()
            .cover_calibrator_get_brightness(device_id)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::CoverCalibrator))
    }

    async fn cover_calibrator_get_max_brightness(&self, device_id: &str) -> DeviceResult<i32> {
        get_device_manager()
            .cover_calibrator_get_max_brightness(device_id)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::CoverCalibrator))
    }
}
