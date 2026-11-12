//! One state-change event per command, whichever path sent it.
//!
//! Each command is sent three ways where the path exists: straight to the
//! `DeviceManager` op, through the bridge API function the host GUI and the
//! embedded API server call, and through `UnifiedDeviceOps`, the sequencer's
//! path. Every one must publish its event exactly once: zero leaves a UI stale
//! (the 2026-11-07 rig report: a slave moved the wheel and the host still
//! showed the old filter), two would double-log and double-toast.

use super::property;
use crate::device::{DeviceInfo, DeviceType, DriverType};
use crate::device_manager::get_device_manager;
use crate::event::{EquipmentEvent, EventPayload, SkotiqEvent};
use crate::simulator as sim;
use crate::state::get_state;
use tokio::sync::broadcast::error::TryRecvError;
use tokio::sync::broadcast::Receiver;

const WHEEL: &str = "sim_filterwheel_1";
const FOCUSER: &str = "sim_focuser_1";
const CAMERA: &str = "sim_camera_1";
const ROTATOR: &str = "sim_rotator_1";
const MOUNT: &str = "sim_mount_1";
const SWITCH: &str = "sim_switch_1";
const COVER: &str = "sim_cover_calibrator_1";

async fn attach(id: &str, device_type: DeviceType) {
    let info = DeviceInfo {
        id: id.to_string(),
        name: format!("Simulated {}", device_type.as_str()),
        device_type,
        driver_type: DriverType::Simulator,
        description: "Simulator under test".to_string(),
        driver_version: "1.0".to_string(),
        serial_number: None,
        unique_id: None,
        display_name: format!("Simulated {}", device_type.as_str()),
    };
    let manager = get_device_manager();
    manager.register_device(info.clone(), false).await;
    manager
        .connect_simulator(&info)
        .await
        .expect("the simulator connects");
}

/// Everything published since the last drain, equipment events only.
fn drain(rx: &mut Receiver<SkotiqEvent>) -> Vec<EquipmentEvent> {
    let mut events = Vec::new();
    loop {
        match rx.try_recv() {
            Ok(event) => {
                if let EventPayload::Equipment(e) = event.payload {
                    events.push(e);
                }
            }
            Err(TryRecvError::Lagged(_)) => continue,
            Err(TryRecvError::Empty) | Err(TryRecvError::Closed) => break,
        }
    }
    events
}

fn count(events: &[EquipmentEvent], pred: impl Fn(&EquipmentEvent) -> bool) -> usize {
    events.iter().filter(|e| pred(e)).count()
}

/// `PropertyChanged` events for `device_id` and `prop`, as their values.
fn property_values(events: &[EquipmentEvent], device_id: &str, prop: &str) -> Vec<String> {
    events
        .iter()
        .filter_map(|e| match e {
            EquipmentEvent::PropertyChanged {
                device_id: id,
                property: p,
                value,
                ..
            } if id == device_id && p == prop => Some(value.clone()),
            _ => None,
        })
        .collect()
}

fn assert_one_filter_move(events: &[EquipmentEvent], to: i32, path: &str) {
    let changing = count(
        events,
        |e| matches!(e, EquipmentEvent::FilterChanging { to_position, .. } if *to_position == to),
    );
    let changed = count(
        events,
        |e| matches!(e, EquipmentEvent::FilterChanged { position, .. } if *position == to),
    );
    assert_eq!(
        (changing, changed),
        (1, 1),
        "{path}: expected one FilterChanging and one FilterChanged to slot {to}, got {events:?}"
    );
}

#[tokio::test]
async fn every_filter_wheel_path_publishes_one_move() {
    let _serialized = sim::sim_singleton_test_lock().lock().await;
    attach(WHEEL, DeviceType::FilterWheel).await;
    let mut rx = get_state().event_bus.subscribe();
    let ops = crate::unified_device_ops::create_unified_device_ops();

    get_device_manager()
        .filter_wheel_set_position(WHEEL, 2)
        .await
        .unwrap();
    assert_one_filter_move(&drain(&mut rx), 2, "DeviceManager");

    crate::api::devices::filter_wheel::api_filterwheel_set_position(WHEEL.to_string(), 3)
        .await
        .unwrap();
    assert_one_filter_move(&drain(&mut rx), 3, "api_filterwheel_set_position");
    assert_eq!(sim::get_sim_filterwheel().read().await.status.position, 3);

    ops.filterwheel_set_position(WHEEL, 5).await.unwrap();
    assert_one_filter_move(&drain(&mut rx), 5, "UnifiedDeviceOps");

    let names = sim::get_sim_filterwheel()
        .read()
        .await
        .status
        .filter_names
        .clone();
    ops.filterwheel_set_filter_by_name(WHEEL, &names[0])
        .await
        .unwrap();
    assert_one_filter_move(&drain(&mut rx), 0, "UnifiedDeviceOps by name");
}

#[tokio::test]
async fn the_filter_move_events_name_the_slots() {
    let _serialized = sim::sim_singleton_test_lock().lock().await;
    attach(WHEEL, DeviceType::FilterWheel).await;
    get_device_manager()
        .filter_wheel_set_position(WHEEL, 0)
        .await
        .unwrap();
    let names = sim::get_sim_filterwheel()
        .read()
        .await
        .status
        .filter_names
        .clone();
    let mut rx = get_state().event_bus.subscribe();

    get_device_manager()
        .filter_wheel_set_position(WHEEL, 1)
        .await
        .unwrap();

    let events = drain(&mut rx);
    assert!(events.iter().any(|e| matches!(
        e,
        EquipmentEvent::FilterChanging { device_id, from_position: 0, to_position: 1, filter_name, from_filter_name }
            if device_id == WHEEL && filter_name.as_deref() == Some(names[1].as_str())
                && from_filter_name.as_deref() == Some(names[0].as_str())
    )), "{events:?}");
}

/// A move that fails still ends: `FilterChanged` reports the slot the wheel
/// reads back, so no UI is left showing it as moving.
#[tokio::test]
async fn a_failed_filter_move_reports_where_the_wheel_is() {
    let _serialized = sim::sim_singleton_test_lock().lock().await;
    attach(WHEEL, DeviceType::FilterWheel).await;
    get_device_manager()
        .filter_wheel_set_position(WHEEL, 2)
        .await
        .unwrap();
    let mut rx = get_state().event_bus.subscribe();

    crate::simulator::faults::arm(
        "filterwheel.set_position",
        crate::simulator::faults::FaultSpec::transient("the wheel jammed"),
    );
    let result = get_device_manager()
        .filter_wheel_set_position(WHEEL, 5)
        .await;
    crate::simulator::faults::clear("filterwheel.set_position");

    assert!(result.is_err(), "the armed fault must fail the move");
    let events = drain(&mut rx);
    let changed: Vec<i32> = events
        .iter()
        .filter_map(|e| match e {
            EquipmentEvent::FilterChanged { position, .. } => Some(*position),
            _ => None,
        })
        .collect();
    assert_eq!(changed, vec![2], "{events:?}");
}

#[tokio::test]
async fn an_unknown_device_publishes_nothing() {
    let mut rx = get_state().event_bus.subscribe();
    let manager = get_device_manager();
    assert!(manager
        .filter_wheel_set_position("no_such_wheel", 1)
        .await
        .is_err());
    assert!(manager
        .focuser_move_abs("no_such_focuser", 10)
        .await
        .is_err());
    assert!(manager
        .rotator_move_absolute("no_such_rotator", 10.0)
        .await
        .is_err());
    assert!(manager.mount_park("no_such_mount").await.is_err());
    let events = drain(&mut rx);
    assert!(
        !events.iter().any(|e| matches!(
            e,
            EquipmentEvent::FilterChanging { to_position: 1, .. }
                | EquipmentEvent::FocuserMoveStarted {
                    target_position: 10,
                    ..
                }
                | EquipmentEvent::RotatorMoveStarted { .. }
                | EquipmentEvent::MountParkStarted { .. }
        )),
        "{events:?}"
    );
}

#[tokio::test]
async fn filter_names_publish_once() {
    let _serialized = sim::sim_singleton_test_lock().lock().await;
    attach(WHEEL, DeviceType::FilterWheel).await;
    let before = sim::get_sim_filterwheel()
        .read()
        .await
        .status
        .filter_names
        .clone();
    let mut renamed = before.clone();
    renamed[0] = "Lum".to_string();
    let mut rx = get_state().event_bus.subscribe();

    crate::api::devices::filter_wheel::api_filterwheel_set_filter_names(
        WHEEL.to_string(),
        renamed.clone(),
    )
    .await
    .unwrap();

    let values = property_values(&drain(&mut rx), WHEEL, property::FILTER_NAMES);
    assert_eq!(values.len(), 1, "{values:?}");
    let published: Vec<String> = serde_json::from_str(&values[0]).unwrap();
    assert_eq!(published, renamed);

    crate::api::devices::filter_wheel::api_filterwheel_set_filter_names(WHEEL.to_string(), before)
        .await
        .unwrap();
}

fn assert_one_focuser_move(events: &[EquipmentEvent], to: i32, path: &str) {
    let started = count(
        events,
        |e| matches!(e, EquipmentEvent::FocuserMoveStarted { device_id, target_position } if device_id == FOCUSER && *target_position == to),
    );
    let completed = count(
        events,
        |e| matches!(e, EquipmentEvent::FocuserMoveCompleted { device_id, position } if device_id == FOCUSER && *position == to),
    );
    assert_eq!(
        (started, completed),
        (1, 1),
        "{path}: expected one FocuserMoveStarted and one FocuserMoveCompleted at {to}, got {events:?}"
    );
}

#[tokio::test]
async fn every_focuser_path_publishes_one_move() {
    let _serialized = sim::sim_singleton_test_lock().lock().await;
    attach(FOCUSER, DeviceType::Focuser).await;
    get_device_manager()
        .focuser_move_abs(FOCUSER, 20_000)
        .await
        .unwrap();
    let mut rx = get_state().event_bus.subscribe();
    let ops = crate::unified_device_ops::create_unified_device_ops();

    get_device_manager()
        .focuser_move_abs(FOCUSER, 20_100)
        .await
        .unwrap();
    assert_one_focuser_move(&drain(&mut rx), 20_100, "DeviceManager");

    crate::api::devices::focuser::api_focuser_move_to(FOCUSER.to_string(), 20_200)
        .await
        .unwrap();
    assert_one_focuser_move(&drain(&mut rx), 20_200, "api_focuser_move_to");

    crate::api::devices::focuser::api_focuser_move_relative(FOCUSER.to_string(), 50)
        .await
        .unwrap();
    assert_one_focuser_move(&drain(&mut rx), 20_250, "api_focuser_move_relative");

    get_device_manager()
        .focuser_move_rel(FOCUSER, -50)
        .await
        .unwrap();
    assert_one_focuser_move(&drain(&mut rx), 20_200, "DeviceManager::focuser_move_rel");

    ops.focuser_move_to(FOCUSER, 20_300).await.unwrap();
    assert_one_focuser_move(&drain(&mut rx), 20_300, "UnifiedDeviceOps");

    crate::api::devices::focuser::api_focuser_halt(FOCUSER.to_string())
        .await
        .unwrap();
    let events = drain(&mut rx);
    assert_eq!(
        count(&events, |e| matches!(
            e,
            EquipmentEvent::FocuserMoveCompleted {
                position: 20_300,
                ..
            }
        )),
        1,
        "halt: {events:?}"
    );
}

#[tokio::test]
async fn camera_settings_publish_once_per_change() {
    let _serialized = sim::sim_singleton_test_lock().lock().await;
    attach(CAMERA, DeviceType::Camera).await;
    let mut rx = get_state().event_bus.subscribe();

    crate::api::devices::camera::set_camera_gain(CAMERA.to_string(), 139)
        .await
        .unwrap();
    crate::api::devices::camera::set_camera_gain(CAMERA.to_string(), 140)
        .await
        .unwrap();
    crate::api::devices::camera::set_camera_offset(CAMERA.to_string(), 21)
        .await
        .unwrap();
    get_device_manager()
        .camera_set_binning(CAMERA, 2, 2)
        .await
        .unwrap();

    // One event per change, each carrying the camera's full settings.
    let settings: Vec<(i32, i32, i32, i32)> = drain(&mut rx)
        .into_iter()
        .filter_map(|e| match e {
            EquipmentEvent::CameraSettingsChanged {
                device_id,
                gain,
                offset,
                bin_x,
                bin_y,
            } if device_id == CAMERA => Some((gain, offset, bin_x, bin_y)),
            _ => None,
        })
        .collect();
    assert_eq!(settings.len(), 4, "{settings:?}");
    assert_eq!(settings[0].0, 139);
    assert_eq!(settings[1].0, 140);
    assert_eq!((settings[2].0, settings[2].1), (140, 21));
    assert_eq!(settings[3], (140, 21, 2, 2));
    // Binning used to be written straight into the simulator, past the manager.
    let status = sim::get_sim_camera_for(CAMERA).read().await.status.clone();
    assert_eq!((status.bin_x, status.bin_y), (2, 2));

    get_device_manager()
        .camera_set_binning(CAMERA, 1, 1)
        .await
        .unwrap();
}

/// A setting the camera refuses changes nothing, so it publishes nothing.
#[tokio::test]
async fn a_refused_setting_publishes_nothing() {
    let _serialized = sim::sim_singleton_test_lock().lock().await;
    attach(CAMERA, DeviceType::Camera).await;
    let mut rx = get_state().event_bus.subscribe();

    // The simulator has no readout modes.
    assert!(
        crate::api::devices::camera::api_camera_set_readout_mode(CAMERA.to_string(), 1)
            .await
            .is_err()
    );

    assert!(property_values(&drain(&mut rx), CAMERA, property::READOUT_MODE).is_empty());
}

#[tokio::test]
async fn every_cooler_path_publishes_once() {
    let _serialized = sim::sim_singleton_test_lock().lock().await;
    attach(CAMERA, DeviceType::Camera).await;
    let mut rx = get_state().event_bus.subscribe();
    let ops = crate::unified_device_ops::create_unified_device_ops();
    let cooling = |events: &[EquipmentEvent], target: f64| {
        count(
            events,
            |e| matches!(e, EquipmentEvent::CameraCoolingStarted { device_id, target_temp } if device_id == CAMERA && *target_temp == target),
        )
    };
    let warming = |events: &[EquipmentEvent]| {
        count(
            events,
            |e| matches!(e, EquipmentEvent::CameraWarmingStarted { device_id } if device_id == CAMERA),
        )
    };

    crate::api::devices::camera::set_camera_cooler(CAMERA.to_string(), 1, Some(-10.0))
        .await
        .unwrap();
    assert_eq!(
        cooling(&drain(&mut rx), -10.0),
        1,
        "api_set_camera_cooler on"
    );

    crate::api::devices::camera::set_camera_cooler(CAMERA.to_string(), 1, Some(-12.0))
        .await
        .unwrap();
    assert_eq!(cooling(&drain(&mut rx), -12.0), 1, "set_camera_cooler on");

    ops.camera_set_cooler(CAMERA, true, -15.0).await.unwrap();
    assert_eq!(cooling(&drain(&mut rx), -15.0), 1, "UnifiedDeviceOps on");

    ops.camera_set_cooler(CAMERA, false, 0.0).await.unwrap();
    assert_eq!(warming(&drain(&mut rx)), 1, "UnifiedDeviceOps off");

    crate::api::devices::camera::set_camera_cooler(CAMERA.to_string(), 0, None)
        .await
        .unwrap();
    assert_eq!(warming(&drain(&mut rx)), 1, "api_set_camera_cooler off");
}

fn assert_one_rotator_move(events: &[EquipmentEvent], to: f64, path: &str) {
    let started = count(
        events,
        |e| matches!(e, EquipmentEvent::RotatorMoveStarted { device_id, target_angle } if device_id == ROTATOR && (*target_angle - to).abs() < 1e-6),
    );
    let completed = count(events, |e| {
        matches!(e, EquipmentEvent::RotatorMoveCompleted { .. })
    });
    assert_eq!(
        (started, completed),
        (1, 1),
        "{path}: expected one RotatorMoveStarted to {to} and one RotatorMoveCompleted, got {events:?}"
    );
}

#[tokio::test]
async fn every_rotator_path_publishes_once() {
    let _serialized = sim::sim_singleton_test_lock().lock().await;
    attach(ROTATOR, DeviceType::Rotator).await;
    let mut rx = get_state().event_bus.subscribe();
    let ops = crate::unified_device_ops::create_unified_device_ops();

    crate::api::devices::rotator::api_rotator_move_to(ROTATOR.to_string(), 30.0)
        .await
        .unwrap();
    assert_one_rotator_move(&drain(&mut rx), 30.0, "api_rotator_move_to");

    crate::api::devices::rotator::api_rotator_move_relative(ROTATOR.to_string(), 10.0)
        .await
        .unwrap();
    assert_one_rotator_move(&drain(&mut rx), 40.0, "api_rotator_move_relative");

    ops.rotator_move_to(ROTATOR, 50.0).await.unwrap();
    assert_one_rotator_move(&drain(&mut rx), 50.0, "UnifiedDeviceOps");

    crate::api::devices::rotator::api_rotator_set_reverse(ROTATOR.to_string(), true)
        .await
        .unwrap();
    crate::api::devices::rotator::api_rotator_set_reverse(ROTATOR.to_string(), false)
        .await
        .unwrap();
    let events = drain(&mut rx);
    assert_eq!(
        property_values(&events, ROTATOR, property::ROTATOR_REVERSE),
        vec!["true", "false"]
    );
}

async fn stop_sim_slew() {
    sim::cancel_sim_slew().await;
    sim::get_sim_mount().write().await.status.slewing = false;
}

#[tokio::test]
async fn every_mount_path_publishes_once() {
    let _serialized = sim::sim_singleton_test_lock().lock().await;
    attach(MOUNT, DeviceType::Mount).await;
    stop_sim_slew().await;
    {
        let mut mount = sim::get_sim_mount().write().await;
        mount.status.parked = false;
        mount.status.tracking = true;
        mount.status.slewing = false;
    }
    let mut rx = get_state().event_bus.subscribe();
    let ops = crate::unified_device_ops::create_unified_device_ops();
    let one = |events: &[EquipmentEvent], pred: &dyn Fn(&EquipmentEvent) -> bool| {
        events.iter().filter(|e| pred(e)).count()
    };

    crate::api::devices::mount::api_mount_set_tracking(MOUNT.to_string(), 0)
        .await
        .unwrap();
    let events = drain(&mut rx);
    assert_eq!(
        one(&events, &|e| matches!(
            e,
            EquipmentEvent::MountTrackingStopped { device_id } if device_id == MOUNT
        )),
        1,
        "{events:?}"
    );

    crate::api::devices::mount::api_mount_set_tracking(MOUNT.to_string(), 1)
        .await
        .unwrap();
    let events = drain(&mut rx);
    assert_eq!(
        one(&events, &|e| matches!(
            e,
            EquipmentEvent::MountTrackingStarted { device_id } if device_id == MOUNT
        )),
        1,
        "{events:?}"
    );

    crate::api::devices::mount::api_mount_slew_to_coordinates(MOUNT.to_string(), 5.5, 20.0)
        .await
        .unwrap();
    let events = drain(&mut rx);
    assert_eq!(
        one(
            &events,
            &|e| matches!(e, EquipmentEvent::MountSlewStarted { device_id, ra, dec } if device_id == MOUNT && *ra == 5.5 && *dec == 20.0)
        ),
        1,
        "api slew: {events:?}"
    );
    stop_sim_slew().await;

    ops.mount_slew_to_coordinates(MOUNT, 6.5, 21.0)
        .await
        .unwrap();
    let events = drain(&mut rx);
    assert_eq!(
        one(
            &events,
            &|e| matches!(e, EquipmentEvent::MountSlewStarted { ra, .. } if *ra == 6.5)
        ),
        1,
        "UnifiedDeviceOps slew: {events:?}"
    );
    stop_sim_slew().await;

    crate::api::devices::mount::api_mount_sync_to_coordinates(MOUNT.to_string(), 6.5, 21.0)
        .await
        .unwrap();
    assert_eq!(
        property_values(&drain(&mut rx), MOUNT, property::MOUNT_SYNCED),
        vec!["6.5 21"]
    );

    ops.mount_park(MOUNT).await.unwrap();
    let events = drain(&mut rx);
    assert_eq!(
        (
            one(
                &events,
                &|e| matches!(e, EquipmentEvent::MountParkStarted { device_id } if device_id == MOUNT)
            ),
            one(&events, &|e| matches!(
                e,
                EquipmentEvent::MountParkCompleted { device_id } if device_id == MOUNT
            )),
        ),
        (1, 1),
        "UnifiedDeviceOps park: {events:?}"
    );

    crate::api::devices::mount::api_mount_unpark(MOUNT.to_string())
        .await
        .unwrap();
    let events = drain(&mut rx);
    assert_eq!(
        one(
            &events,
            &|e| matches!(e, EquipmentEvent::MountUnparked { device_id } if device_id == MOUNT)
        ),
        1,
        "{events:?}"
    );

    crate::api::devices::mount::api_mount_park(MOUNT.to_string())
        .await
        .unwrap();
    let events = drain(&mut rx);
    assert_eq!(
        (
            one(
                &events,
                &|e| matches!(e, EquipmentEvent::MountParkStarted { device_id } if device_id == MOUNT)
            ),
            one(&events, &|e| matches!(
                e,
                EquipmentEvent::MountParkCompleted { device_id } if device_id == MOUNT
            )),
        ),
        (1, 1),
        "api park: {events:?}"
    );

    ops.mount_unpark(MOUNT).await.unwrap();
    let events = drain(&mut rx);
    assert_eq!(
        one(
            &events,
            &|e| matches!(e, EquipmentEvent::MountUnparked { device_id } if device_id == MOUNT)
        ),
        1,
        "{events:?}"
    );
}

#[tokio::test]
async fn switch_and_cover_commands_publish_once() {
    let _serialized = sim::sim_singleton_test_lock().lock().await;
    attach(SWITCH, DeviceType::Switch).await;
    attach(COVER, DeviceType::CoverCalibrator).await;
    let mut rx = get_state().event_bus.subscribe();

    crate::api::devices::switch::api_switch_set_state(SWITCH.to_string(), 0, true)
        .await
        .unwrap();
    crate::api::devices::cover_calibrator::api_cover_calibrator_calibrator_on(COVER.to_string(), 1)
        .await
        .unwrap();
    crate::api::devices::cover_calibrator::api_cover_calibrator_calibrator_off(COVER.to_string())
        .await
        .unwrap();

    let events = drain(&mut rx);
    assert_eq!(
        property_values(&events, SWITCH, property::SWITCH_STATE),
        vec!["0 true"]
    );
    assert_eq!(
        property_values(&events, COVER, property::CALIBRATOR),
        vec!["on 1", "off"]
    );

    crate::api::devices::switch::api_switch_set_state(SWITCH.to_string(), 0, false)
        .await
        .unwrap();
}

/// `Connected` names the device, and a camera publishes its settings on
/// connect, so a client that links later shows them without a poll.
#[tokio::test]
async fn a_camera_connect_names_it_and_publishes_its_settings() {
    let _serialized = sim::sim_singleton_test_lock().lock().await;
    let mut rx = get_state().event_bus.subscribe();
    let info = DeviceInfo {
        id: CAMERA.to_string(),
        name: "Simulated Camera".to_string(),
        device_type: DeviceType::Camera,
        driver_type: DriverType::Simulator,
        description: String::new(),
        driver_version: String::new(),
        serial_number: None,
        unique_id: None,
        display_name: String::new(),
    };
    get_device_manager().register_device(info, false).await;

    get_device_manager().connect_device(CAMERA).await.unwrap();

    let events = drain(&mut rx);
    assert!(
        events.iter().any(|e| matches!(
            e,
            EquipmentEvent::Connected { device_id, device_name, .. }
                if device_id == CAMERA && device_name == "Simulated Camera"
        )),
        "{events:?}"
    );
    assert_eq!(
        count(&events, |e| matches!(
            e,
            EquipmentEvent::CameraSettingsChanged { device_id, .. } if device_id == CAMERA
        )),
        1,
        "{events:?}"
    );
}

/// A camera with no pitch (0.0) is told about it in words that say what is
/// lost and where planning takes the value from; one with a pitch is not.
#[test]
fn a_camera_without_a_pixel_size_gets_a_notice_and_one_with_it_does_not() {
    let text = super::unknown_pixel_size_notice("CCD47-10", 0.0, 0.0).expect("notice");
    assert!(
        text.starts_with("CCD47-10 does not report its pixel size"),
        "{text}"
    );
    assert!(text.contains("without a pixel-scale hint"), "{text}");
    assert!(!text.contains("  "), "{text}");
    assert_eq!(
        super::unknown_pixel_size_notice("PL09000", 12.0, 12.0),
        None
    );
    assert!(super::unknown_pixel_size_notice("half", 12.0, 0.0).is_some());
}
