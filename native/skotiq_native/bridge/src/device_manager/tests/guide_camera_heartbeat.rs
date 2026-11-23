//! P8-4: a vendor camera registered as another kind of device (a guide
//! camera as a guider) is heartbeated through the camera's own status probe,
//! not the driver's in-process connected flag, which stays true after the
//! camera is unplugged.

use super::*;
use skotiq_native::catalog::NativeHandle;

/// Unplugged: its flag still says connected, every status read fails.
#[derive(Debug)]
struct UnpluggedCamera;

#[async_trait::async_trait]
impl skotiq_device::DeviceDriver for UnpluggedCamera {
    fn id(&self) -> &str {
        "native:zwo:1"
    }
    fn name(&self) -> &str {
        "ZWO ASI120MM Mini"
    }
    fn vendor(&self) -> skotiq_device::Vendor {
        skotiq_device::Vendor::Zwo
    }
    fn is_connected(&self) -> bool {
        true
    }
    async fn connect(&mut self) -> Result<(), skotiq_device::DriverError> {
        Ok(())
    }
    async fn disconnect(&mut self) -> Result<(), skotiq_device::DriverError> {
        Ok(())
    }
}

#[async_trait::async_trait]
impl skotiq_device::CameraDriver for UnpluggedCamera {
    fn capabilities(&self) -> skotiq_device::CameraCapabilities {
        skotiq_device::CameraCapabilities {
            can_cool: true,
            ..Default::default()
        }
    }
    async fn get_status(&self) -> Result<skotiq_device::CameraStatus, skotiq_device::DriverError> {
        Err(skotiq_device::DriverError::Disconnected)
    }
    async fn start_exposure(
        &mut self,
        _params: skotiq_device::ExposureParams,
    ) -> Result<(), skotiq_device::DriverError> {
        Ok(())
    }
    async fn abort_exposure(&mut self) -> Result<(), skotiq_device::DriverError> {
        Ok(())
    }
    async fn is_exposure_complete(&self) -> Result<bool, skotiq_device::DriverError> {
        Ok(true)
    }
    async fn download_image(
        &mut self,
    ) -> Result<skotiq_device::ImageData, skotiq_device::DriverError> {
        Err(skotiq_device::DriverError::NotSupported)
    }
    async fn set_cooler(
        &mut self,
        _enabled: bool,
        _target_temp: Option<f64>,
    ) -> Result<(), skotiq_device::DriverError> {
        Ok(())
    }
    async fn get_temperature(&self) -> Result<f64, skotiq_device::DriverError> {
        Ok(-10.0)
    }
    async fn get_cooler_power(&self) -> Result<f64, skotiq_device::DriverError> {
        Ok(40.0)
    }
    async fn set_gain(&mut self, _gain: i32) -> Result<(), skotiq_device::DriverError> {
        Ok(())
    }
    async fn get_gain(&self) -> Result<i32, skotiq_device::DriverError> {
        Ok(0)
    }
    async fn set_offset(&mut self, _offset: i32) -> Result<(), skotiq_device::DriverError> {
        Ok(())
    }
    async fn get_offset(&self) -> Result<i32, skotiq_device::DriverError> {
        Ok(0)
    }
    async fn set_binning(
        &mut self,
        _bin_x: i32,
        _bin_y: i32,
    ) -> Result<(), skotiq_device::DriverError> {
        Ok(())
    }
    async fn get_binning(&self) -> Result<(i32, i32), skotiq_device::DriverError> {
        Ok((1, 1))
    }
    async fn set_subframe(
        &mut self,
        _subframe: Option<skotiq_device::SubFrame>,
    ) -> Result<(), skotiq_device::DriverError> {
        Ok(())
    }
    fn get_sensor_info(&self) -> skotiq_device::SensorInfo {
        skotiq_device::SensorInfo {
            width: 4656,
            height: 3520,
            pixel_size_x: 3.8,
            pixel_size_y: 3.8,
            max_adu: 65535,
            bit_depth: 16,
            color: false,
            bayer_pattern: None,
            saturation_adu: None,
        }
    }
    async fn get_readout_modes(
        &self,
    ) -> Result<Vec<skotiq_device::ReadoutMode>, skotiq_device::DriverError> {
        Ok(Vec::new())
    }
    async fn set_readout_mode(
        &mut self,
        _mode: &skotiq_device::ReadoutMode,
    ) -> Result<(), skotiq_device::DriverError> {
        Ok(())
    }
    async fn get_vendor_features(
        &self,
    ) -> Result<skotiq_device::VendorFeatures, skotiq_device::DriverError> {
        Ok(skotiq_device::VendorFeatures::default())
    }
    async fn get_gain_range(&self) -> Result<(i32, i32), skotiq_device::DriverError> {
        Ok((0, 500))
    }
    async fn get_offset_range(&self) -> Result<(i32, i32), skotiq_device::DriverError> {
        Ok((0, 100))
    }
}

#[tokio::test]
async fn an_unplugged_guide_camera_registered_as_a_guider_fails_its_heartbeat() {
    let manager = build_device_manager();
    let info = DeviceInfo {
        id: "native:zwo:1".to_string(),
        name: "ZWO ASI120MM Mini".to_string(),
        device_type: DeviceType::Guider,
        driver_type: DriverType::Native,
        description: String::new(),
        driver_version: String::new(),
        serial_number: None,
        unique_id: None,
        display_name: "ZWO ASI120MM Mini".to_string(),
    };
    manager.register_connected_device(info.clone()).await;
    manager
        .hold_native(&info, NativeHandle::Camera(Box::new(UnpluggedCamera)))
        .await
        .expect("connect");
    let probe = manager
        .perform_health_check_once(&info.id, &info.device_type, &info.driver_type)
        .await;
    assert!(
        !matches!(probe, Ok(true)),
        "an unplugged guide camera must not pass its heartbeat: {probe:?}"
    );
    let _ = manager.disconnect_device(&info.id).await;
}
