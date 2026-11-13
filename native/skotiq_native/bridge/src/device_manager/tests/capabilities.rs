//! A connected device's capabilities come from its handle, so what a device
//! says it supports is what its operations do.

use super::*;
use crate::device_capabilities::cache::invalidate_capability_cache_for_device;
use crate::device_capabilities::get_device_capabilities;
use crate::device_capabilities::types::DeviceCapabilities;
use crate::error::SkotiqError;

/// Registers and connects `id` on the app's device manager, the one the
/// capability API reads, with no capability cached for it.
async fn connect_sim(id: &str, device_type: DeviceType) -> &'static DeviceManager {
    let manager = crate::device_manager::get_device_manager();
    manager
        .register_device(build_sim_info(id, device_type), false)
        .await;
    manager.connect_device(id).await.expect("connect simulator");
    invalidate_capability_cache_for_device(id).await;
    manager
}

async fn release(manager: &DeviceManager, id: &str) {
    manager.disconnect_device(id).await.expect("disconnect simulator");
    manager.unregister_device(id).await;
}

#[tokio::test]
async fn a_simulated_focuser_reports_the_travel_it_moves_within() {
    let _guard = simulator_singleton_test_lock().lock().await;
    let id = "sim_focuser_41";
    let manager = connect_sim(id, DeviceType::Focuser).await;

    let caps = get_device_capabilities(id).await;
    let travel = manager.focuser_get_details(id).await;
    release(manager, id).await;

    let DeviceCapabilities::Focuser(caps) = caps.expect("focuser capabilities") else {
        panic!("a focuser answers with focuser capabilities");
    };
    let (max_position, step_size) = travel.expect("focuser travel");
    assert_eq!(caps.max_position, max_position);
    assert_eq!(caps.step_size, Some(step_size));
}

#[tokio::test]
async fn a_simulated_switch_box_lists_the_channels_it_switches() {
    let _guard = simulator_singleton_test_lock().lock().await;
    let id = "sim_switch_41";
    let manager = connect_sim(id, DeviceType::Switch).await;

    let caps = get_device_capabilities(id).await;
    let count = manager.switch_get_max(id).await.expect("switch count");
    let mut channels = Vec::new();
    for index in 0..count {
        channels.push((
            manager.switch_get_name(id, index).await.expect("name"),
            manager.switch_can_write(id, index).await.expect("can write"),
            manager.switch_get_min_value(id, index).await.expect("min"),
            manager.switch_get_max_value(id, index).await.expect("max"),
        ));
    }
    release(manager, id).await;

    let DeviceCapabilities::Switch(caps) = caps.expect("switch capabilities") else {
        panic!("a switch answers with switch capabilities");
    };
    assert_eq!(caps.switch_count, count);
    let reported: Vec<_> = caps
        .switches
        .iter()
        .map(|s| (s.name.clone(), s.can_write, s.min_value, s.max_value))
        .collect();
    assert_eq!(reported, channels);
}

#[tokio::test]
async fn a_simulated_wheel_reports_the_slots_it_turns_between() {
    let _guard = simulator_singleton_test_lock().lock().await;
    let id = "sim_filterwheel_41";
    let manager = connect_sim(id, DeviceType::FilterWheel).await;

    let caps = get_device_capabilities(id).await;
    let config = manager.filter_wheel_get_config(id).await;
    release(manager, id).await;

    let DeviceCapabilities::FilterWheel(caps) = caps.expect("wheel capabilities") else {
        panic!("a filter wheel answers with filter wheel capabilities");
    };
    let (count, names) = config.expect("wheel config");
    assert_eq!(caps.position_count, count);
    assert_eq!(caps.filter_names, names);
}

/// A device that is registered but not connected has no driver to ask. It
/// used to be answered from a fixed table (simulators) or by opening a
/// connection of the capability probe's own (Alpaca, ASCOM, INDI).
#[tokio::test]
async fn a_registered_accessory_that_is_not_connected_answers_not_connected() {
    let id = "sim_rotator_42";
    let manager = crate::device_manager::get_device_manager();
    manager
        .register_device(build_sim_info(id, DeviceType::Rotator), false)
        .await;

    let answer = get_device_capabilities(id).await;
    manager.unregister_device(id).await;

    assert!(
        matches!(answer, Err(SkotiqError::NotConnected(_))),
        "got {answer:?}"
    );
}

/// The camera and mount keep their per-protocol capability source until they
/// have a handle: a simulated one answers whether or not it is connected.
#[tokio::test]
async fn a_simulated_camera_and_mount_answer_without_a_handle() {
    let camera = get_device_capabilities("sim_camera_43").await;
    let mount = get_device_capabilities("sim_mount_43").await;
    assert!(matches!(camera, Ok(DeviceCapabilities::Camera(_))), "got {camera:?}");
    assert!(matches!(mount, Ok(DeviceCapabilities::Mount(_))), "got {mount:?}");
}

/// Every simulated accessory with a handle answers once connected, with the
/// capability set of its own type.
#[tokio::test]
async fn every_connected_simulated_accessory_answers_through_its_handle() {
    let _guard = simulator_singleton_test_lock().lock().await;
    let cases = [
        ("sim_dome_44", DeviceType::Dome),
        ("sim_rotator_44", DeviceType::Rotator),
        ("sim_weather_44", DeviceType::Weather),
        ("sim_safety_monitor_44", DeviceType::SafetyMonitor),
        ("sim_cover_calibrator_44", DeviceType::CoverCalibrator),
    ];
    for (id, device_type) in cases {
        let manager = connect_sim(id, device_type).await;
        let answer = get_device_capabilities(id).await;
        release(manager, id).await;
        let matches_type = matches!(
            (&answer, device_type),
            (Ok(DeviceCapabilities::Dome(_)), DeviceType::Dome)
                | (Ok(DeviceCapabilities::Rotator(_)), DeviceType::Rotator)
                | (Ok(DeviceCapabilities::Weather(_)), DeviceType::Weather)
                | (Ok(DeviceCapabilities::SafetyMonitor(_)), DeviceType::SafetyMonitor)
                | (Ok(DeviceCapabilities::CoverCalibrator(_)), DeviceType::CoverCalibrator)
        );
        assert!(matches_type, "{id}: got {answer:?}");
    }
}
