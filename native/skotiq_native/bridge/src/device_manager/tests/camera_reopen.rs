//! Reopening a camera restores what it held, cooler first
//! (`device_manager::camera_reopen`).
//!
//! Rig, 2026-11-16: the ZWO camera's USB path dropped for 4 s; status reads
//! went on answering and every exposure failed until the camera was
//! disconnected and connected again, and the reconnect left the cooler off
//! (it had been on at -10 C).

use super::*;
use crate::device::DriverType;
use crate::simulator::camera::get_sim_camera_for;

/// The cooler the camera read back before the reopen is on again after it,
/// at the same set-point, through the manual Disconnect and Connect and
/// through the run's reopen after the rig's error. Nothing commanded the
/// cooler through this manager: the last good status read is the record.
#[tokio::test]
async fn the_cooler_set_point_survives_a_reopen() {
    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = Arc::new(build_device_manager());
    let id = "sim_camera_reopen";
    manager
        .register_device(build_sim_info(id, DeviceType::Camera), false)
        .await;
    manager.connect_device(id).await.expect("connect");
    let camera = get_sim_camera_for(id);
    {
        let mut cam = camera.write().await;
        cam.status.cooler_on = Some(true);
        cam.status.target_temp = Some(-10.0);
    }
    manager.camera_get_status(id).await.expect("status read");

    // The camera comes back from a reopen with its cooler off.
    let cooler_off = || async {
        let mut cam = camera.write().await;
        cam.status.cooler_on = Some(false);
        cam.status.target_temp = None;
    };
    let cooler = || async {
        let cam = camera.read().await;
        (cam.status.cooler_on, cam.status.target_temp)
    };

    manager.disconnect_device(id).await.expect("disconnect");
    cooler_off().await;
    manager.connect_device(id).await.expect("manual reconnect");
    assert_eq!(cooler().await, (Some(true), Some(-10.0)), "manual reconnect");

    cooler_off().await;
    let reopened = manager
        .reopen_camera_after(
            id,
            "Failed to check exposure status: SDK error: ZWO camera reported a failed exposure",
        )
        .await
        .expect("reopen");
    assert!(reopened);
    assert_eq!(cooler().await, (Some(true), Some(-10.0)), "run's reopen");
    assert!(manager.is_connected(id).await);

    camera.write().await.status.connected = false;
}

/// A failure that does not mean a broken session leaves the camera open.
#[tokio::test]
async fn a_plain_failure_does_not_reopen_the_camera() {
    let manager = build_device_manager();
    let reopened = manager
        .reopen_camera_after(
            "native:zwo:1",
            "Failed to download image: Injected simulator fault: the driver reported a failure",
        )
        .await;
    assert_eq!(reopened, Ok(false));
}

/// What a camera is told, in order.
#[derive(Debug, Clone, Default)]
struct OrderCamera {
    calls: Arc<std::sync::Mutex<Vec<String>>>,
}

impl OrderCamera {
    fn log(&self, call: String) {
        self.calls.lock().unwrap().push(call);
    }
}

#[async_trait::async_trait]
impl skotiq_device::DeviceDriver for OrderCamera {
    fn id(&self) -> &str {
        "native:test:order"
    }
    fn name(&self) -> &str {
        "Order Camera"
    }
    fn vendor(&self) -> skotiq_device::Vendor {
        skotiq_device::Vendor::Other("Test".to_string())
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
impl skotiq_device::CameraDriver for OrderCamera {
    fn capabilities(&self) -> skotiq_device::CameraCapabilities {
        skotiq_device::CameraCapabilities {
            can_cool: true,
            ..Default::default()
        }
    }
    async fn get_status(&self) -> Result<skotiq_device::CameraStatus, skotiq_device::DriverError> {
        Err(skotiq_device::DriverError::NotSupported)
    }
    async fn start_exposure(
        &mut self,
        _params: skotiq_device::ExposureParams,
    ) -> Result<(), skotiq_device::DriverError> {
        self.log("exposure".into());
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
        enabled: bool,
        target_temp: Option<f64>,
    ) -> Result<(), skotiq_device::DriverError> {
        self.log(format!("cooler {enabled} {target_temp:?}"));
        Ok(())
    }
    async fn get_temperature(&self) -> Result<f64, skotiq_device::DriverError> {
        Ok(-10.0)
    }
    async fn get_cooler_power(&self) -> Result<f64, skotiq_device::DriverError> {
        Ok(40.0)
    }
    async fn set_gain(&mut self, gain: i32) -> Result<(), skotiq_device::DriverError> {
        self.log(format!("gain {gain}"));
        Ok(())
    }
    async fn get_gain(&self) -> Result<i32, skotiq_device::DriverError> {
        Ok(0)
    }
    async fn set_offset(&mut self, offset: i32) -> Result<(), skotiq_device::DriverError> {
        self.log(format!("offset {offset}"));
        Ok(())
    }
    async fn get_offset(&self) -> Result<i32, skotiq_device::DriverError> {
        Ok(0)
    }
    async fn set_binning(&mut self, _bin_x: i32, _bin_y: i32) -> Result<(), skotiq_device::DriverError> {
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

fn order_camera_info(id: &str) -> DeviceInfo {
    DeviceInfo {
        id: id.to_string(),
        name: "Order Camera".to_string(),
        device_type: DeviceType::Camera,
        driver_type: DriverType::Native,
        description: "Native camera under test".to_string(),
        driver_version: "1.0".to_string(),
        serial_number: None,
        unique_id: None,
        display_name: "Order Camera".to_string(),
    }
}

async fn hold(manager: &DeviceManager, id: &str, held: HeldCameraState) -> OrderCamera {
    let info = order_camera_info(id);
    manager.register_connected_device(info).await;
    let camera = OrderCamera::default();
    manager.hold_vendor_camera(id, Box::new(camera.clone()));
    manager
        .devices
        .write()
        .await
        .get_mut(id)
        .unwrap()
        .held_camera_state = Some(held);
    camera
}

/// The cooler is the first thing the camera is told, at its set-point, then
/// gain and offset. The power it ran at is not sent: no driver takes one.
#[tokio::test]
async fn the_cooler_is_restored_before_anything_else() {
    let manager = build_device_manager();
    let id = "native:test:order";
    let camera = hold(
        &manager,
        id,
        HeldCameraState {
            cooler_on: Some(true),
            target_temp: Some(-10.0),
            cooler_power: Some(41.0),
            gain: Some(139),
            offset: Some(21),
        },
    )
    .await;

    manager.restore_camera_state(&order_camera_info(id)).await;

    assert_eq!(
        *camera.calls.lock().unwrap(),
        ["cooler true Some(-10.0)", "gain 139", "offset 21"]
    );
}

/// A cooler that was off stays off, and nothing the camera did not hold is
/// set; a cooler commanded through Skotiq wins over a later read of it off.
#[tokio::test]
async fn only_what_the_camera_held_is_restored() {
    let manager = build_device_manager();
    let id = "native:test:order_off";
    let camera = hold(
        &manager,
        id,
        HeldCameraState {
            cooler_on: Some(false),
            target_temp: Some(-10.0),
            ..Default::default()
        },
    )
    .await;
    manager.restore_camera_state(&order_camera_info(id)).await;
    assert!(camera.calls.lock().unwrap().is_empty());

    manager.devices.write().await.get_mut(id).unwrap().desired_cooler = Some((true, Some(-15.0)));
    manager.restore_camera_state(&order_camera_info(id)).await;
    assert_eq!(*camera.calls.lock().unwrap(), ["cooler true Some(-15.0)"]);
}
