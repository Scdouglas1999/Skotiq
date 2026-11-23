use super::{sequencer_error, UnifiedDeviceOps};
use crate::device_manager::get_device_manager;
use crate::unified_device_ops::pointing::connected_camera_label;
use async_trait::async_trait;
use skotiq_sequencer::{CameraOps, DeviceResult, ExposureRequest, ImageData};

/// Each call goes to the id the run's camera is at now
/// ([`crate::device_manager::DeviceManager::current_id`]): a camera that came
/// back at another id is followed there.
#[async_trait]
impl CameraOps for UnifiedDeviceOps {
    /// One frame, through [`crate::device_manager::DeviceManager::capture`].
    async fn camera_start_exposure(&self, request: ExposureRequest<'_>) -> DeviceResult<ImageData> {
        let mgr = get_device_manager();
        let camera_id = mgr.current_id(request.camera_id);
        mgr.capture(ExposureRequest {
            camera_id: &camera_id,
            ..request
        })
        .await
    }

    async fn camera_abort_exposure(&self, camera_id: &str) -> DeviceResult<()> {
        let camera_id = &get_device_manager().current_id(camera_id);
        tracing::info!("Aborting exposure on camera {}", camera_id);

        get_device_manager()
            .abort_capture(camera_id)
            .await
            .map_err(sequencer_error(skotiq_sequencer::DeviceKind::Camera))
    }

    async fn camera_set_cooler(
        &self,
        camera_id: &str,
        enabled: bool,
        target_temp: f64,
    ) -> DeviceResult<()> {
        let camera_id = &get_device_manager().current_id(camera_id);
        tracing::info!(
            "Camera {} cooler: enabled={}, target={}°C",
            camera_id,
            enabled,
            target_temp
        );

        // `DeviceManager::camera_set_cooler` publishes the cooling event.
        get_device_manager()
            .camera_set_cooler(camera_id, enabled, Some(target_temp))
            .await
            .map_err(sequencer_error(skotiq_sequencer::DeviceKind::Camera))
    }

    async fn camera_get_temperature(&self, camera_id: &str) -> DeviceResult<f64> {
        let camera_id = &get_device_manager().current_id(camera_id);
        let status = get_device_manager()
            .camera_get_status(camera_id)
            .await
            .map_err(sequencer_error(skotiq_sequencer::DeviceKind::Camera))?;

        status
            .sensor_temp
            .ok_or_else(|| "Temperature not available".into())
    }

    async fn camera_get_cooler_power(&self, camera_id: &str) -> DeviceResult<f64> {
        let camera_id = &get_device_manager().current_id(camera_id);
        let status = get_device_manager()
            .camera_get_status(camera_id)
            .await
            .map_err(sequencer_error(skotiq_sequencer::DeviceKind::Camera))?;

        status
            .cooler_power
            .ok_or_else(|| "Cooler power not available".into())
    }

    async fn camera_get_cooler_on(&self, camera_id: &str) -> DeviceResult<Option<bool>> {
        let camera_id = &get_device_manager().current_id(camera_id);
        let status = get_device_manager()
            .camera_get_status(camera_id)
            .await
            .map_err(sequencer_error(skotiq_sequencer::DeviceKind::Camera))?;
        Ok(status.cooler_on)
    }

    async fn camera_get_cooler_setpoint(&self, camera_id: &str) -> DeviceResult<Option<f64>> {
        let camera_id = &get_device_manager().current_id(camera_id);
        let status = get_device_manager()
            .camera_get_status(camera_id)
            .await
            .map_err(sequencer_error(skotiq_sequencer::DeviceKind::Camera))?;
        Ok(status
            .target_temp
            .filter(|_| status.cooler_on == Some(true)))
    }

    async fn camera_get_pixel_size_um(&self, camera_id: &str) -> DeviceResult<Option<(f64, f64)>> {
        let camera_id = &get_device_manager().current_id(camera_id);
        let status = get_device_manager()
            .camera_get_status(camera_id)
            .await
            .map_err(sequencer_error(skotiq_sequencer::DeviceKind::Camera))?;

        // A driver with nothing to say reports 0.0 here, which is not a pitch —
        // writing it would tell a solver the sensor has zero-sized pixels.
        Ok(match (status.pixel_size_x, status.pixel_size_y) {
            (x, y) if x > 0.0 && y > 0.0 => Some((x, y)),
            _ => None,
        })
    }

    async fn camera_get_model(&self, camera_id: &str) -> DeviceResult<Option<String>> {
        let camera_id = &get_device_manager().current_id(camera_id);
        Ok(connected_camera_label(camera_id).await)
    }

    async fn camera_get_iso_speeds(&self, camera_id: &str) -> DeviceResult<Vec<i32>> {
        let camera_id = &get_device_manager().current_id(camera_id);
        match crate::device_capabilities::get_device_capabilities(camera_id).await {
            Ok(crate::device_capabilities::types::DeviceCapabilities::Camera(caps)) => {
                Ok(caps.iso_speeds)
            }
            Ok(_) => Ok(Vec::new()),
            Err(e) => Err(format!("Failed to read camera capabilities: {}", e).into()),
        }
    }
}
