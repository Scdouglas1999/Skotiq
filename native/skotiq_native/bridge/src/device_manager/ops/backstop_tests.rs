//! The backstop poll reports a change made outside Skotiq once, and never a
//! change a Skotiq command made (that command published it already).
//!
//! "Outside Skotiq" is a write straight into the simulator's state, which is
//! what a hand controller or the vendor's app does to a real device: the
//! device moves and the `DeviceManager` hears nothing.

use crate::api::devices::simulation as sim;
use crate::device::{DeviceInfo, DeviceType, DriverType};
use crate::device_manager::get_device_manager;
use crate::event::{EquipmentEvent, EventPayload, SkotiqEvent};
use crate::state::get_state;
use tokio::sync::broadcast::error::TryRecvError;
use tokio::sync::broadcast::Receiver;

const WHEEL: &str = "sim_filterwheel_1";
const FOCUSER: &str = "sim_focuser_1";
const ROTATOR: &str = "sim_rotator_1";
const CAMERA: &str = "sim_camera_1";

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

fn focuser_completions(events: &[EquipmentEvent]) -> Vec<(String, i32)> {
    events
        .iter()
        .filter_map(|e| match e {
            EquipmentEvent::FocuserMoveCompleted {
                device_id,
                position,
            } => Some((device_id.clone(), *position)),
            _ => None,
        })
        .collect()
}

#[tokio::test]
async fn a_focuser_moved_outside_skotiq_is_published_once() {
    let _serialized = sim::sim_singleton_test_lock().lock().await;
    attach(FOCUSER, DeviceType::Focuser).await;
    let manager = get_device_manager();
    manager.focuser_move_abs(FOCUSER, 24_000).await.unwrap();
    let mut rx = get_state().event_bus.subscribe();

    // The command's own result is not announced again.
    manager.backstop_check(FOCUSER, DeviceType::Focuser).await;
    assert!(focuser_completions(&drain(&mut rx)).is_empty());

    // The hand controller turns it.
    sim::get_sim_focuser().write().await.status.position = 24_350;
    manager.backstop_check(FOCUSER, DeviceType::Focuser).await;
    assert_eq!(
        focuser_completions(&drain(&mut rx)),
        vec![(FOCUSER.to_string(), 24_350)]
    );

    // Once announced, the same reading is quiet.
    manager.backstop_check(FOCUSER, DeviceType::Focuser).await;
    assert!(focuser_completions(&drain(&mut rx)).is_empty());
}

#[tokio::test]
async fn a_device_with_a_command_in_flight_is_skipped() {
    let _serialized = sim::sim_singleton_test_lock().lock().await;
    attach(FOCUSER, DeviceType::Focuser).await;
    let manager = get_device_manager();
    manager.focuser_move_abs(FOCUSER, 25_000).await.unwrap();
    let mut rx = get_state().event_bus.subscribe();

    let command = manager.command_activity.begin(FOCUSER);
    sim::get_sim_focuser().write().await.status.position = 25_400;
    manager.backstop_check(FOCUSER, DeviceType::Focuser).await;
    assert!(
        focuser_completions(&drain(&mut rx)).is_empty(),
        "a reading taken while a command runs belongs to that command"
    );
    drop(command);

    // The command ended without announcing the new position (it was not
    // its doing), so the next round does.
    manager.backstop_check(FOCUSER, DeviceType::Focuser).await;
    assert_eq!(
        focuser_completions(&drain(&mut rx)),
        vec![(FOCUSER.to_string(), 25_400)]
    );
}

#[tokio::test]
async fn a_moving_focuser_is_left_alone_until_it_stops() {
    let _serialized = sim::sim_singleton_test_lock().lock().await;
    attach(FOCUSER, DeviceType::Focuser).await;
    let manager = get_device_manager();
    manager.focuser_move_abs(FOCUSER, 26_000).await.unwrap();
    let mut rx = get_state().event_bus.subscribe();

    {
        let focuser = sim::get_sim_focuser();
        let mut focuser = focuser.write().await;
        focuser.status.position = 26_200;
        focuser.status.moving = true;
    }
    manager.backstop_check(FOCUSER, DeviceType::Focuser).await;
    assert!(focuser_completions(&drain(&mut rx)).is_empty());

    sim::get_sim_focuser().write().await.status.moving = false;
    manager.backstop_check(FOCUSER, DeviceType::Focuser).await;
    assert_eq!(
        focuser_completions(&drain(&mut rx)),
        vec![(FOCUSER.to_string(), 26_200)]
    );
}

#[tokio::test]
async fn a_wheel_moved_outside_skotiq_publishes_filter_changed_with_its_name() {
    let _serialized = sim::sim_singleton_test_lock().lock().await;
    attach(WHEEL, DeviceType::FilterWheel).await;
    let manager = get_device_manager();
    manager.filter_wheel_set_position(WHEEL, 1).await.unwrap();
    let mut rx = get_state().event_bus.subscribe();

    manager.backstop_check(WHEEL, DeviceType::FilterWheel).await;
    sim::get_sim_filterwheel().write().await.status.position = 3;
    manager.backstop_check(WHEEL, DeviceType::FilterWheel).await;

    let names = manager
        .filter_wheel_get_config(WHEEL)
        .await
        .map(|(_, names)| names)
        .unwrap_or_default();
    let changed: Vec<_> = drain(&mut rx)
        .into_iter()
        .filter_map(|e| match e {
            EquipmentEvent::FilterChanged {
                device_id,
                position,
                filter_name,
            } => Some((device_id, position, filter_name)),
            _ => None,
        })
        .collect();
    assert_eq!(
        changed,
        vec![(
            WHEEL.to_string(),
            3,
            crate::filter_matching::filter_slot_name(&names, 3)
        )]
    );
}

#[tokio::test]
async fn a_rotator_synced_by_skotiq_is_not_reannounced() {
    let _serialized = sim::sim_singleton_test_lock().lock().await;
    attach(ROTATOR, DeviceType::Rotator).await;
    let manager = get_device_manager();
    manager.rotator_move_absolute(ROTATOR, 10.0).await.unwrap();
    manager.rotator_sync(ROTATOR, 42.0).await.unwrap();
    let mut rx = get_state().event_bus.subscribe();

    manager.backstop_check(ROTATOR, DeviceType::Rotator).await;
    let events = drain(&mut rx);
    assert!(
        !events
            .iter()
            .any(|e| matches!(e, EquipmentEvent::RotatorMoveCompleted { .. })),
        "{events:?}"
    );
}

#[tokio::test]
async fn camera_temperature_is_published_when_the_reading_changes() {
    let _serialized = sim::sim_singleton_test_lock().lock().await;
    attach(CAMERA, DeviceType::Camera).await;
    let manager = get_device_manager();
    // A known starting point for this camera, whatever earlier tests read.
    manager.publish_camera_temperature(CAMERA, 50.0, None);
    let mut rx = get_state().event_bus.subscribe();

    let temperatures = |events: Vec<EquipmentEvent>| -> Vec<(String, f64, Option<f64>)> {
        events
            .into_iter()
            .filter_map(|e| match e {
                EquipmentEvent::CameraTemperatureChanged {
                    device_id,
                    temperature,
                    cooler_power,
                } => Some((device_id, temperature, cooler_power)),
                _ => None,
            })
            .collect()
    };

    manager.publish_camera_temperature(CAMERA, -10.0, Some(35.0));
    // Below the resolution: nothing.
    manager.publish_camera_temperature(CAMERA, -10.04, Some(35.4));
    // A flicker of the last digit within 2 s of the last event: nothing.
    manager.publish_camera_temperature(CAMERA, -10.2, Some(35.4));
    // A real step, and power going away, always go out.
    manager.publish_camera_temperature(CAMERA, -11.0, Some(35.4));
    manager.publish_camera_temperature(CAMERA, -11.0, None);
    manager.publish_camera_temperature(CAMERA, f64::NAN, None);
    assert_eq!(
        temperatures(drain(&mut rx)),
        vec![
            (CAMERA.to_string(), -10.0, Some(35.0)),
            (CAMERA.to_string(), -11.0, Some(35.4)),
            (CAMERA.to_string(), -11.0, None),
        ]
    );

    // Past the 2 s window a 0.1 C change goes out.
    {
        let mut published = manager.published_temperatures.lock().unwrap();
        let entry = published.get_mut(CAMERA).unwrap();
        entry.2 -= std::time::Duration::from_secs(3);
    }
    manager.publish_camera_temperature(CAMERA, -11.2, None);
    assert_eq!(
        temperatures(drain(&mut rx)),
        vec![(CAMERA.to_string(), -11.2, None)]
    );

    // Far from anything the sim camera reads, so the read below publishes.
    manager.publish_camera_temperature(CAMERA, 99.0, None);
    drain(&mut rx);

    // A status read is what produces it.
    let status = manager.camera_get_status(CAMERA).await.unwrap();
    let t = status
        .sensor_temp
        .expect("the sim camera reports a temperature");
    assert_eq!(
        temperatures(drain(&mut rx)),
        vec![(CAMERA.to_string(), t, status.cooler_power)]
    );
}
