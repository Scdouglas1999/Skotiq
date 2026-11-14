//! The heartbeat's liveness probe of a native camera.

use super::*;
use crate::device::DriverType;
use skotiq_device::{
    CameraCapabilities, CameraDriver, CameraState, CameraStatus, DeviceDriver, DriverError,
    ExposureParams, ImageData, ReadoutMode, SensorInfo, SubFrame, Vendor, VendorFeatures,
};

/// A camera without a thermometer, as every mirrorless and DSLR body is:
/// `get_temperature` is unsupported and `get_status` answers with `status`.
#[derive(Debug)]
struct ThermometerlessCamera {
    status: fn() -> Result<CameraStatus, DriverError>,
}

fn idle() -> Result<CameraStatus, DriverError> {
    Ok(CameraStatus {
        state: CameraState::Idle,
        sensor_temp: None,
        cooler_power: None,
        target_temp: None,
        cooler_on: Some(false),
        gain: 800,
        offset: 0,
        bin_x: 1,
        bin_y: 1,
        exposure_remaining: None,
    })
}

fn unplugged() -> Result<CameraStatus, DriverError> {
    Err(DriverError::Disconnected)
}

#[async_trait::async_trait]
impl DeviceDriver for ThermometerlessCamera {
    fn id(&self) -> &str {
        "native:test:mirrorless"
    }
    fn name(&self) -> &str {
        "Mirrorless body"
    }
    fn vendor(&self) -> Vendor {
        Vendor::Fujifilm
    }
    fn is_connected(&self) -> bool {
        true
    }
    async fn connect(&mut self) -> Result<(), DriverError> {
        Ok(())
    }
    async fn disconnect(&mut self) -> Result<(), DriverError> {
        Ok(())
    }
}

#[async_trait::async_trait]
impl CameraDriver for ThermometerlessCamera {
    fn capabilities(&self) -> CameraCapabilities {
        CameraCapabilities::default()
    }
    async fn get_status(&self) -> Result<CameraStatus, DriverError> {
        (self.status)()
    }
    async fn start_exposure(&mut self, _params: ExposureParams) -> Result<(), DriverError> {
        Ok(())
    }
    async fn abort_exposure(&mut self) -> Result<(), DriverError> {
        Ok(())
    }
    async fn is_exposure_complete(&self) -> Result<bool, DriverError> {
        Ok(true)
    }
    async fn download_image(&mut self) -> Result<ImageData, DriverError> {
        Err(DriverError::NotSupported)
    }
    async fn set_cooler(
        &mut self,
        _enabled: bool,
        _target_temp: Option<f64>,
    ) -> Result<(), DriverError> {
        Err(DriverError::NotSupported)
    }
    async fn get_temperature(&self) -> Result<f64, DriverError> {
        Err(DriverError::NotSupported)
    }
    async fn get_cooler_power(&self) -> Result<f64, DriverError> {
        Err(DriverError::NotSupported)
    }
    async fn set_gain(&mut self, _gain: i32) -> Result<(), DriverError> {
        Ok(())
    }
    async fn get_gain(&self) -> Result<i32, DriverError> {
        Ok(800)
    }
    async fn set_offset(&mut self, _offset: i32) -> Result<(), DriverError> {
        Err(DriverError::NotSupported)
    }
    async fn get_offset(&self) -> Result<i32, DriverError> {
        Ok(0)
    }
    async fn set_binning(&mut self, _bin_x: i32, _bin_y: i32) -> Result<(), DriverError> {
        Err(DriverError::NotSupported)
    }
    async fn get_binning(&self) -> Result<(i32, i32), DriverError> {
        Ok((1, 1))
    }
    async fn set_subframe(&mut self, _subframe: Option<SubFrame>) -> Result<(), DriverError> {
        Err(DriverError::NotSupported)
    }
    fn get_sensor_info(&self) -> SensorInfo {
        SensorInfo {
            width: 6240,
            height: 4160,
            pixel_size_x: 3.76,
            pixel_size_y: 3.76,
            max_adu: 16383,
            bit_depth: 14,
            color: true,
            bayer_pattern: None,
            saturation_adu: None,
        }
    }
    async fn get_readout_modes(&self) -> Result<Vec<ReadoutMode>, DriverError> {
        Ok(Vec::new())
    }
    async fn set_readout_mode(&mut self, _mode: &ReadoutMode) -> Result<(), DriverError> {
        Err(DriverError::NotSupported)
    }
    async fn get_vendor_features(&self) -> Result<VendorFeatures, DriverError> {
        Ok(VendorFeatures::default())
    }
    async fn get_gain_range(&self) -> Result<(i32, i32), DriverError> {
        Ok((160, 12800))
    }
    async fn get_offset_range(&self) -> Result<(i32, i32), DriverError> {
        Err(DriverError::NotSupported)
    }
}

async fn manager_with(device_id: &str, camera: ThermometerlessCamera) -> Arc<DeviceManager> {
    let manager = Arc::new(build_device_manager());
    manager
        .register_device(
            DeviceInfo {
                id: device_id.to_string(),
                name: "Mirrorless body".to_string(),
                device_type: DeviceType::Camera,
                driver_type: DriverType::Native,
                description: "Native camera without a thermometer".to_string(),
                driver_version: "1.0".to_string(),
                serial_number: None,
                unique_id: None,
                display_name: "Mirrorless body".to_string(),
            },
            false,
        )
        .await;
    manager.hold_vendor_camera(device_id, Box::new(camera));
    manager
}

/// The probe used to be `get_temperature`, which a Fujifilm or gPhoto2 body
/// answers "not supported": every poll failed, and three failures tore a
/// working camera down about 30 seconds after it connected.
#[tokio::test]
async fn a_connected_camera_without_a_thermometer_is_healthy() {
    let device_id = "native:test:mirrorless_ok";
    let manager = manager_with(device_id, ThermometerlessCamera { status: idle }).await;
    let healthy = manager
        .perform_health_check(device_id, &DeviceType::Camera, &DriverType::Native)
        .await;
    assert_eq!(healthy, Ok(true));
}

#[tokio::test]
async fn a_camera_whose_status_read_finds_it_gone_fails_the_probe() {
    let device_id = "native:test:mirrorless_gone";
    let manager = manager_with(device_id, ThermometerlessCamera { status: unplugged }).await;
    let result = manager
        .perform_health_check(device_id, &DeviceType::Camera, &DriverType::Native)
        .await;
    assert!(
        matches!(&result, Err(e) if e.contains("disconnected")),
        "{result:?}"
    );
}
