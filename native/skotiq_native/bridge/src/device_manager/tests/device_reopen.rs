//! Reopening a device whose session broke (`device_manager::device_reopen`).
//!
//! Rig, 2026-11-16: the power box behind the ZWO camera, wheel and focuser
//! dropped for 4 s. The camera's status reads went on answering and every
//! exposure failed until it was disconnected and connected again, and the
//! reconnect left the cooler off (it had been on at -10 C). The wheel and
//! focuser answered "Device disconnected" until reconnected by hand.

use super::*;
use crate::device::DriverType;
use crate::event::bus::{EventPayload, SkotiqEvent};
use crate::event::equipment::EquipmentEvent;
use crate::simulator::camera::get_sim_camera_for;
use crate::simulator::filter_wheel::get_sim_filterwheel;
use crate::simulator::focuser::get_sim_focuser;
use tokio::sync::broadcast::error::TryRecvError;

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
        .reopen_after(
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

/// On a quiet bus, a failure that does not mean a broken session leaves the
/// camera open.
#[tokio::test]
async fn a_plain_failure_does_not_reopen_the_camera() {
    let _guard = simulator_singleton_test_lock().lock().await;
    crate::hotplug::forget_bus_change();
    let manager = build_device_manager();
    let id = "sim_camera_plain_failure";
    manager
        .register_device(build_sim_info(id, DeviceType::Camera), false)
        .await;
    manager.connect_device(id).await.expect("connect");
    let reopened = manager
        .reopen_after(
            id,
            "Failed to download image: Injected simulator fault: the driver reported a failure",
        )
        .await;
    assert_eq!(reopened, Ok(false));
    get_sim_camera_for(id).write().await.status.connected = false;
}

/// The connection events a stretch of work published for each of
/// `device_ids`, in order.
fn connection_events_of(
    rx: &mut tokio::sync::broadcast::Receiver<SkotiqEvent>,
    device_ids: &[&str],
) -> Vec<Vec<&'static str>> {
    let mut seen = vec![Vec::new(); device_ids.len()];
    loop {
        match rx.try_recv() {
            Ok(event) => {
                let (id, kind) = match &event.payload {
                    EventPayload::Equipment(EquipmentEvent::Disconnected { device_id, .. }) => {
                        (device_id, "disconnected")
                    }
                    EventPayload::Equipment(EquipmentEvent::Connected { device_id, .. }) => {
                        (device_id, "connected")
                    }
                    _ => continue,
                };
                if let Some(i) = device_ids.iter().position(|d| d == id) {
                    seen[i].push(kind);
                }
            }
            Err(TryRecvError::Empty) | Err(TryRecvError::Closed) => break,
            Err(TryRecvError::Lagged(_)) => continue,
        }
    }
    seen
}

/// The connection events a stretch of work published for `device_id`.
fn connection_events(
    rx: &mut tokio::sync::broadcast::Receiver<SkotiqEvent>,
    device_id: &str,
) -> Vec<&'static str> {
    connection_events_of(rx, &[device_id]).remove(0)
}

/// Rig, 2026-11-16 03:31: the run's reopen of the camera was announced as
/// a disconnect, the app took it for a lost camera and paused the run. A
/// reopen announces only the connect.
#[tokio::test]
async fn a_reopen_is_not_announced_as_a_lost_device() {
    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = build_device_manager();
    let id = "sim_camera_reopen_events";
    manager
        .register_device(build_sim_info(id, DeviceType::Camera), false)
        .await;
    manager.connect_device(id).await.expect("connect");
    let mut rx = manager.app_state.event_bus.subscribe();

    manager.reopen_device(id).await.expect("reopen");

    assert_eq!(connection_events(&mut rx, id), ["connected"]);
    assert!(manager.is_connected(id).await);
    get_sim_camera_for(id).write().await.status.connected = false;
}

/// Rig, 2026-11-16: the wheel and focuser behind the power box answered
/// "disconnected" after it came back. The run's next move reopens each
/// through the connection path and lands, and the focuser keeps its
/// position.
#[tokio::test]
async fn a_wheel_and_focuser_lost_to_a_bus_drop_are_reopened_and_the_move_lands() {
    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = build_device_manager();
    let wheel = "sim_wheel_reopen";
    let focuser = "sim_focuser_reopen";
    for (id, device_type) in [(wheel, DeviceType::FilterWheel), (focuser, DeviceType::Focuser)] {
        manager
            .register_device(build_sim_info(id, device_type), false)
            .await;
        manager.connect_device(id).await.expect("connect");
    }
    manager.focuser_move_abs(focuser, 5000).await.expect("first move");
    let mut rx = manager.app_state.event_bus.subscribe();

    // The power box drops: both devices answer "not connected".
    crate::hotplug::note_bus_change();
    get_sim_filterwheel().write().await.status.connected = false;
    get_sim_focuser().write().await.status.connected = false;

    let moved = manager
        .with_reopen(wheel, || manager.filter_wheel_set_position(wheel, 2))
        .await;
    let focused = manager
        .with_reopen(focuser, || manager.focuser_move_abs(focuser, 5100))
        .await;
    crate::hotplug::forget_bus_change();

    assert!(moved.is_ok(), "the wheel move lands after the reopen: {moved:?}");
    assert!(focused.is_ok(), "the focuser move lands after the reopen: {focused:?}");
    assert_eq!(manager.filter_wheel_get_position(wheel).await.ok(), Some(2));
    assert_eq!(manager.focuser_get_position(focuser).await.ok(), Some(5100));
    assert_eq!(
        connection_events_of(&mut rx, &[wheel, focuser]),
        [["connected"], ["connected"]]
    );

    // A reopen reads the focuser's position again and never sets it.
    get_sim_focuser().write().await.status.connected = false;
    manager.reopen_device(focuser).await.expect("reopen");
    assert_eq!(manager.focuser_get_position(focuser).await.ok(), Some(5100));
    for id in [wheel, focuser] {
        let _ = manager.disconnect_device(id).await;
    }
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
            cooler_off: None,
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

/// Rig, 2026-11-16 03:36: a manual Disconnect and Connect about five
/// minutes after the run's reopen left the cooler off. The app switches the
/// cooler off as part of a disconnect, and that off was kept as what the
/// camera held. What the camera held, cooler on at -10, now survives any
/// number of reopens and that manual reconnect.
#[tokio::test]
async fn the_cooler_survives_two_reopens_and_then_a_manual_reconnect() {
    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = Arc::new(build_device_manager());
    let id = "sim_camera_reopen_twice";
    manager
        .register_device(build_sim_info(id, DeviceType::Camera), false)
        .await;
    manager.connect_device(id).await.expect("connect");
    manager
        .camera_set_cooler(id, true, Some(-10.0))
        .await
        .expect("cooler on");
    let camera = get_sim_camera_for(id);
    let cooler_off = || async {
        let mut cam = camera.write().await;
        cam.status.cooler_on = Some(false);
        cam.status.target_temp = None;
    };
    let cooler = || async {
        let cam = camera.read().await;
        (cam.status.cooler_on, cam.status.target_temp)
    };

    for reopen in 1..=2 {
        cooler_off().await;
        // The camera reads its cooler off between the drop and the reopen.
        manager.camera_get_status(id).await.expect("status read");
        manager.reopen_device(id).await.expect("reopen");
        assert_eq!(cooler().await, (Some(true), Some(-10.0)), "reopen {reopen}");
    }

    // The app's manual disconnect: the cooler off, then the disconnect.
    manager
        .camera_set_cooler(id, false, None)
        .await
        .expect("cooler off for the disconnect");
    manager.disconnect_device(id).await.expect("disconnect");
    manager.connect_device(id).await.expect("manual reconnect");
    assert_eq!(cooler().await, (Some(true), Some(-10.0)), "manual reconnect");

    camera.write().await.status.connected = false;
}

/// The operator's own cooler off, with the camera left connected, is kept:
/// the next reopen leaves the cooler off.
#[tokio::test]
async fn a_cooler_switched_off_while_connected_stays_off_after_a_reopen() {
    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = Arc::new(build_device_manager());
    let id = "sim_camera_reopen_off";
    manager
        .register_device(build_sim_info(id, DeviceType::Camera), false)
        .await;
    manager.connect_device(id).await.expect("connect");
    manager.camera_set_cooler(id, true, Some(-10.0)).await.unwrap();
    manager.camera_set_cooler(id, false, None).await.unwrap();

    manager.reopen_device(id).await.expect("reopen");

    let camera = get_sim_camera_for(id);
    assert_eq!(camera.read().await.status.cooler_on, Some(false));
    camera.write().await.status.connected = false;
}

/// A mount that was tracking and is parked when it comes back stays parked:
/// the reconnect does not switch tracking on and leave the park.
#[tokio::test]
async fn a_reconnected_parked_mount_is_not_set_tracking() {
    use crate::simulator::mount::get_sim_mount;

    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = Arc::new(build_device_manager());
    let id = "sim_mount_parked_reconnect";
    manager
        .register_device(build_sim_info(id, DeviceType::Mount), false)
        .await;
    manager.connect_device(id).await.expect("connect");
    manager.mount_set_tracking(id, true).await.expect("tracking");

    manager.mark_lost(id, true, "simulated drop").await;
    {
        let mut mount = get_sim_mount().write().await;
        mount.status.parked = true;
        mount.status.tracking = false;
    }
    manager.connect_device(id).await.expect("reconnect");

    let mount = get_sim_mount().read().await.status.clone();
    assert!(mount.parked);
    assert!(!mount.tracking, "a parked mount is not set tracking");
    drop(mount);
    let mut mount = get_sim_mount().write().await;
    mount.status.parked = false;
    mount.status.connected = false;
}

/// A device the reconnection loop gave up on is tried again after the bus
/// changes: a hub that takes minutes to power up outlasts the attempts.
#[tokio::test]
async fn a_bus_change_gives_a_lost_device_its_attempts_back() {
    let manager = build_device_manager();
    let id = "native:zwo_efw:0";
    manager
        .register_device(build_sim_info(id, DeviceType::FilterWheel), true)
        .await;
    manager.mark_lost(id, true, "gone").await;
    manager.devices.write().await.get_mut(id).unwrap().reconnect_attempts = 10;

    manager.retry_lost_devices().await;

    assert_eq!(manager.devices.read().await[id].reconnect_attempts, 0);
}
