//! Reopening a device whose session broke (`device_manager::device_reopen`).
//!
//! Rig, 2026-11-16: the power box behind the ZWO camera, wheel and focuser
//! dropped for 4 s. The camera's status reads went on answering and every
//! exposure failed until it was disconnected and connected again, and the
//! reconnect left the cooler off (it had been on at -10 C). The wheel and
//! focuser answered "Device disconnected" until reconnected by hand.

use super::*;
use crate::device::DriverType;
use crate::device_manager::failure::DeviceFailure;
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
    let manager = build_device_manager();
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
    assert_eq!(
        cooler().await,
        (Some(true), Some(-10.0)),
        "manual reconnect"
    );

    cooler_off().await;
    let reopened = manager
        .reopen_after(
            id,
            &DeviceFailure::from(&crate::dispatch::error::DeviceOpError::caused_by(
                Some(id.to_string()),
                "Failed to check exposure status: SDK error: the exposure failed".to_string(),
                skotiq_device::DriverError::SessionLost("the exposure failed".to_string()),
            )),
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
            &DeviceFailure::words(
                "Failed to download image: Injected simulator fault: the driver reported a failure",
            ),
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
    for (id, device_type) in [
        (wheel, DeviceType::FilterWheel),
        (focuser, DeviceType::Focuser),
    ] {
        manager
            .register_device(build_sim_info(id, device_type), false)
            .await;
        manager.connect_device(id).await.expect("connect");
    }
    manager
        .focuser_move_abs(focuser, 5000)
        .await
        .expect("first move");
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

    assert!(
        moved.is_ok(),
        "the wheel move lands after the reopen: {moved:?}"
    );
    assert!(
        focused.is_ok(),
        "the focuser move lands after the reopen: {focused:?}"
    );
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

    manager
        .devices
        .write()
        .await
        .get_mut(id)
        .unwrap()
        .desired_cooler = Some((true, Some(-15.0)));
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
    let manager = build_device_manager();
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
    assert_eq!(
        cooler().await,
        (Some(true), Some(-10.0)),
        "manual reconnect"
    );

    camera.write().await.status.connected = false;
}

/// The operator's own cooler off, with the camera left connected, is kept:
/// the next reopen leaves the cooler off.
#[tokio::test]
async fn a_cooler_switched_off_while_connected_stays_off_after_a_reopen() {
    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = build_device_manager();
    let id = "sim_camera_reopen_off";
    manager
        .register_device(build_sim_info(id, DeviceType::Camera), false)
        .await;
    manager.connect_device(id).await.expect("connect");
    manager
        .camera_set_cooler(id, true, Some(-10.0))
        .await
        .unwrap();
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
    let manager = build_device_manager();
    let id = "sim_mount_parked_reconnect";
    manager
        .register_device(build_sim_info(id, DeviceType::Mount), false)
        .await;
    manager.connect_device(id).await.expect("connect");
    manager
        .mount_set_tracking(id, true)
        .await
        .expect("tracking");

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
    manager
        .devices
        .write()
        .await
        .get_mut(id)
        .unwrap()
        .reconnect_attempts = 10;

    manager.retry_lost_devices().await;

    assert_eq!(manager.devices.read().await[id].reconnect_attempts, 0);
}

/// Rig, 2026-11-17 after a restart: the motion guard's solve frame failed
/// with "ZWO camera reported a failed exposure" and only a manual reconnect
/// fixed it. Every exposure starts and is checked in the device manager, so
/// a broken session is reopened there whoever asked for the frame: a start
/// the camera refuses is sent again on the reopened camera, and an exposure
/// the camera reports failed leaves the camera reopened for the next one.
#[tokio::test]
async fn every_exposure_reopens_a_camera_whose_session_broke() {
    use crate::simulator::faults::{self, Effect, FaultSpec, Trigger};

    let _guard = simulator_singleton_test_lock().lock().await;
    crate::hotplug::forget_bus_change();
    let manager = build_device_manager();
    let id = "sim_camera_entry_reopen";
    manager
        .register_device(build_sim_info(id, DeviceType::Camera), false)
        .await;
    manager.connect_device(id).await.expect("connect");
    let light = skotiq_device::FrameType::Light;

    faults::arm(
        "camera.start",
        FaultSpec::new(
            Trigger::Times(1),
            Effect::Error(
                "ASI_ERROR_GENERAL_ERROR: General error - camera may be in use by another \
                 application"
                    .into(),
            ),
        ),
    );
    let started = manager
        .camera_start_exposure(id, 0.01, None, None, 1, 1, light)
        .await;
    assert!(
        started.is_ok(),
        "the start lands on the reopened camera: {started:?}"
    );
    assert_eq!(manager.reopen_count(id), 1);

    faults::arm(
        "camera.exposure_status",
        FaultSpec::new(
            Trigger::Times(1),
            Effect::Error("ZWO camera reported a failed exposure".into()),
        ),
    );
    let failed = manager.camera_is_exposure_complete(id).await;
    faults::clear_all();
    assert!(failed.is_err());
    assert_eq!(
        manager.reopen_count(id),
        2,
        "the failed exposure reopened the camera"
    );
    assert!(manager.is_connected(id).await);
    manager
        .camera_start_exposure(id, 0.01, None, None, 1, 1, light)
        .await
        .expect("the next exposure starts");

    let _ = manager.disconnect_device(id).await;
}

/// A flat panel that comes back from a reconnect puts its light back the
/// way the app last set it.
#[tokio::test]
async fn a_reconnected_flat_panel_gets_its_light_back() {
    use crate::simulator::cover_calibrator::get_sim_cover_calibrator;

    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = build_device_manager();
    let id = "sim_cover_reopen";
    manager
        .register_device(build_sim_info(id, DeviceType::CoverCalibrator), false)
        .await;
    manager.connect_device(id).await.expect("connect");
    manager
        .cover_calibrator_calibrator_on(id, 120)
        .await
        .expect("light on");
    {
        let mut panel = get_sim_cover_calibrator().write().await;
        panel.calibrator_on = false;
        panel.brightness = 0.0;
        panel.brightness_ramp = None;
    }

    manager.reopen_device(id).await.expect("reopen");

    assert!(get_sim_cover_calibrator().read().await.calibrator_on);
    let _ = manager.cover_calibrator_calibrator_off(id).await;
    let _ = manager.disconnect_device(id).await;
}

/// A device whose status reads answer while its operations fail as gone
/// counts as failing for its heartbeat: three such failures in a row are a
/// failed poll.
#[tokio::test]
async fn operations_that_fail_as_gone_count_against_the_devices_health() {
    let _guard = simulator_singleton_test_lock().lock().await;
    crate::hotplug::forget_bus_change();
    let manager = build_device_manager();
    let id = "sim_wheel_health";
    manager
        .register_device(build_sim_info(id, DeviceType::FilterWheel), false)
        .await;
    manager.connect_device(id).await.expect("connect");
    let gone = || async {
        Err::<(), _>(crate::dispatch::error::DeviceOpError::not_connected(
            None,
            "Device disconnected".to_string(),
        ))
    };
    for _ in 0..3 {
        let _ = manager.with_reopen(id, gone).await;
    }
    assert!(manager.failing_status_reads(id).is_some());
    let _ = manager.disconnect_device(id).await;
}

/// Rig, 2026-11-17 06:57: after the power box dropped, the EAF's status
/// said "Device not connected: Device disconnected" for minutes while the
/// device list still said connected and nothing reconnected it. A read that
/// says the device is gone records it lost at once, for the reconnection
/// loop, and the reconnect keeps its position.
#[tokio::test]
async fn a_focuser_whose_reads_say_it_is_gone_is_listed_lost_and_reconnected() {
    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = build_device_manager();
    let id = "sim_focuser_gone";
    let info = build_sim_info(id, DeviceType::Focuser);
    manager.register_device(info.clone(), false).await;
    manager.connect_device(id).await.expect("connect");
    manager.focuser_move_abs(id, 5200).await.expect("move");

    get_sim_focuser().write().await.status.connected = false;
    assert!(manager.focuser_get_position(id).await.is_err());

    let listed = manager.get_connected_device_infos().await;
    assert!(
        listed.iter().all(|d| d.id != id),
        "a focuser that says it is gone is not listed connected: {listed:?}"
    );
    let dev = manager.devices.read().await[id].clone();
    assert_eq!(dev.connection_state, ConnectionState::Error);
    assert!(dev.auto_reconnect, "the reconnection loop takes it");

    manager.attempt_reconnect(id, &info).await;
    assert!(manager.is_connected(id).await);
    assert_eq!(manager.focuser_get_position(id).await.ok(), Some(5200));
    let _ = manager.disconnect_device(id).await;
}

/// A wheel or focuser failure whose kind says it is not connected is gone
/// whatever its words: after a bus change it is reopened and the move runs
/// again, and it counts against the device's health.
#[tokio::test]
async fn a_not_connected_kind_without_the_words_is_gone_at_every_recovery_site() {
    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = build_device_manager();
    let focuser = "sim_focuser_kind";
    manager
        .register_device(build_sim_info(focuser, DeviceType::Focuser), false)
        .await;
    manager.connect_device(focuser).await.expect("connect");
    let lost = || crate::dispatch::error::DeviceOpError::not_connected(None, "EAF gone");
    assert!(!DeviceFailure::from(&lost()).says_gone());

    crate::hotplug::note_bus_change();
    let tries = std::sync::atomic::AtomicU32::new(0);
    let moved = manager
        .with_reopen(focuser, || async {
            if tries.fetch_add(1, std::sync::atomic::Ordering::SeqCst) == 0 {
                Err(lost())
            } else {
                Ok(())
            }
        })
        .await;
    crate::hotplug::forget_bus_change();
    assert!(
        moved.is_ok(),
        "the move runs again after the reopen: {moved:?}"
    );
    assert_eq!(manager.reopen_count(focuser), 1);

    for _ in 0..3 {
        let _ = manager
            .with_reopen(focuser, || async { Err::<(), _>(lost()) })
            .await;
    }
    assert!(manager.failing_status_reads(focuser).is_some());
    let _ = manager.disconnect_device(focuser).await;
}

/// The app's own wheel and focuser moves (the FFI calls the manager
/// directly) get the reopen the run's moves get after a bus drop.
#[tokio::test]
async fn a_manual_wheel_and_focuser_move_after_a_bus_drop_reopens_and_lands() {
    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = build_device_manager();
    let wheel = "sim_wheel_manual_reopen";
    let focuser = "sim_focuser_manual_reopen";
    for (id, device_type) in [
        (wheel, DeviceType::FilterWheel),
        (focuser, DeviceType::Focuser),
    ] {
        manager
            .register_device(build_sim_info(id, device_type), false)
            .await;
        manager.connect_device(id).await.expect("connect");
    }

    crate::hotplug::note_bus_change();
    get_sim_filterwheel().write().await.status.connected = false;
    get_sim_focuser().write().await.status.connected = false;
    let moved = manager.filter_wheel_set_position(wheel, 3).await;
    let focused = manager.focuser_move_abs(focuser, 5300).await;
    crate::hotplug::forget_bus_change();

    assert!(moved.is_ok(), "the manual wheel move lands: {moved:?}");
    assert!(
        focused.is_ok(),
        "the manual focuser move lands: {focused:?}"
    );
    assert_eq!(manager.filter_wheel_get_position(wheel).await.ok(), Some(3));
    assert_eq!(manager.focuser_get_position(focuser).await.ok(), Some(5300));
    assert_eq!(manager.reopen_count(wheel), 1);
    assert_eq!(manager.reopen_count(focuser), 1);
    for id in [wheel, focuser] {
        let _ = manager.disconnect_device(id).await;
    }
}

/// R1H2-1: a safety monitor whose IsSafe reads keep failing is reopened, and
/// never put in the error state (its policy does not escalate). The verdict
/// stays what failing reads give today, an error, before, during and after
/// the reopen while the reads still fail; only reads that answer again give
/// a verdict. So nothing parks sooner than it does today.
#[tokio::test]
async fn a_safety_monitor_whose_reads_keep_failing_is_reopened_and_its_verdict_is_unchanged() {
    use crate::simulator::environment::get_sim_safety_monitor;
    use crate::simulator::faults::{self, Effect, FaultSpec, Trigger};
    let _guard = simulator_singleton_test_lock().lock().await;
    crate::hotplug::forget_bus_change();
    let manager = build_device_manager();
    let id = "sim_safety_reopen";
    manager
        .register_device(build_sim_info(id, DeviceType::SafetyMonitor), false)
        .await;
    manager.connect_device(id).await.expect("connect");
    get_sim_safety_monitor().write().await.status.is_safe = true;

    faults::arm(
        "safetymonitor.status",
        FaultSpec::new(Trigger::Always, Effect::Error("IsSafe read failed".into())),
    );
    let one = DeviceFailure::words("IsSafe read failed");
    assert!(manager.safety_is_safe(id).await.is_err());
    assert!(
        !manager.wants_reopen(id, &one).await,
        "one failed read does not reopen the monitor"
    );
    for _ in 1..crate::device_manager::read_health::STATUS_READ_FAILURE_LIMIT {
        assert!(manager.safety_is_safe(id).await.is_err());
    }
    let failing = manager
        .failing_status_reads(id)
        .expect("failing IsSafe reads count against the monitor");
    assert_eq!(manager.reopen_after(id, &failing).await, Ok(true));
    assert_eq!(manager.reopen_count(id), 1);

    // Still failing after the reopen: the same verdict, and still connected.
    assert!(manager.safety_is_safe(id).await.is_err());
    let state = manager.devices.read().await[id].connection_state;
    assert_eq!(state, ConnectionState::Connected);

    // During a reopen the monitor is closed: an error, as failing reads are.
    manager.close_device(id, false).await.expect("close");
    assert!(manager.safety_is_safe(id).await.is_err());
    manager.connect_device(id).await.expect("connect");

    faults::clear_all();
    assert_eq!(manager.safety_is_safe(id).await.ok(), Some(true));
    let _ = manager.disconnect_device(id).await;
}

/// R1H2-1, through what a run reads (`SafetyOps::safety_is_safe(None)`):
/// while the monitor's reads fail the verdict is the same error before,
/// during and after its reopen, and it names the monitor, so the run's fail
/// mode decides it as it does today and the check never passes to another
/// source.
#[tokio::test]
async fn a_runs_safety_verdict_is_unchanged_through_a_monitor_reopen() {
    use crate::simulator::environment::get_sim_safety_monitor;
    use crate::simulator::faults::{self, Effect, FaultSpec, Trigger};
    let _guard = simulator_singleton_test_lock().lock().await;
    crate::hotplug::forget_bus_change();
    let manager = crate::device_manager::get_device_manager();
    let ops = crate::unified_device_ops::create_unified_device_ops();
    let id = "sim_safety_run_reopen";
    manager
        .register_device(build_sim_info(id, DeviceType::SafetyMonitor), false)
        .await;
    manager.connect_device(id).await.expect("connect");
    get_sim_safety_monitor().write().await.status.is_safe = true;
    faults::arm(
        "safetymonitor.status",
        FaultSpec::new(Trigger::Always, Effect::Error("IsSafe read failed".into())),
    );
    let names_the_monitor = |verdict: &skotiq_sequencer::DeviceResult<bool>| matches!(verdict, Err(e) if e.to_string().contains(id));

    for _ in 0..crate::device_manager::read_health::STATUS_READ_FAILURE_LIMIT {
        assert!(names_the_monitor(&ops.safety_is_safe(None).await));
    }
    let failing = manager.failing_status_reads(id).expect("the reads count");
    assert_eq!(manager.reopen_after(id, &failing).await, Ok(true));
    assert!(names_the_monitor(&ops.safety_is_safe(None).await));

    // Inside a reopen: the monitor is closed and being opened again.
    manager.mark_reopening(id, true);
    manager.close_device(id, false).await.expect("close");
    let during = ops.safety_is_safe(None).await;
    assert!(names_the_monitor(&during), "during the reopen: {during:?}");
    manager.connect_device(id).await.expect("connect");
    manager.mark_reopening(id, false);

    faults::clear_all();
    assert_eq!(ops.safety_is_safe(None).await.ok(), Some(true));
    manager.disconnect_device(id).await.expect("disconnect");
    manager.unregister_device(id).await;
}
