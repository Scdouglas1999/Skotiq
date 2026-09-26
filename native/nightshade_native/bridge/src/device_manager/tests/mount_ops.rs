use super::*;

/// Register a simulator mount so the simulator ops can be driven the same
/// way a real driver is.
async fn register_sim_mount(manager: &DeviceManager, device_id: &str) {
    manager.devices.write().await.insert(
        device_id.to_string(),
        ManagedDevice {
            info: build_mount_info(device_id, DriverType::Simulator),
            connection_state: ConnectionState::Connected,
            last_error: None,
            reconnect_attempts: 0,
            auto_reconnect: false,
            last_successful_comm: None,
            heartbeat_active: false,
            api_version: None,
            desired_cooler: None,
            desired_tracking: None,
        },
    );
}

/// A DISCONNECTED simulated mount must refuse motion commands and refuse to
/// report a status, exactly as a real driver that lost its handle does.
///
/// Nothing may short-circuit `sim_` ids ahead of this gate: a disconnected
/// mount that accepts slews goes on to report itself simultaneously tracking
/// and parked, at coordinates it took while disconnected, which makes every
/// "device disconnected mid-run" assertion on that surface vacuous.
#[tokio::test]
async fn disconnected_simulated_mount_refuses_motion_and_status() {
    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = build_device_manager();
    let device_id = "sim_mount_disconnect_gate";
    register_sim_mount(&manager, device_id).await;

    {
        let mount = crate::api::devices::simulation::get_sim_mount();
        let mut mount = mount.write().await;
        mount.status.connected = false;
        mount.status.right_ascension = 0.0;
        mount.status.declination = 0.0;
        mount.status.parked = true;
        mount.status.tracking = false;
    }

    let slew = manager.mount_slew(device_id, 12.34, -5.6).await;
    assert!(
        slew.is_err(),
        "a disconnected simulated mount accepted a slew: {slew:?}"
    );
    assert!(manager.mount_park(device_id).await.is_err());
    assert!(manager.mount_unpark(device_id).await.is_err());
    assert!(manager.mount_set_tracking(device_id, true).await.is_err());
    assert!(
        manager.mount_get_status(device_id).await.is_err(),
        "a disconnected simulated mount answered a status read"
    );

    // And the refused slew must not have moved it.
    let mount = crate::api::devices::simulation::get_sim_mount()
        .read()
        .await
        .status
        .clone();
    assert_eq!(mount.right_ascension, 0.0);
    assert_eq!(mount.declination, 0.0);
    assert!(
        mount.parked,
        "a refused slew must leave the mount parked, not unparked"
    );
}

/// Once connected the same commands are accepted, so the refusal above is a
/// gate rather than a permanently broken op.
#[tokio::test]
async fn connected_simulated_mount_accepts_a_slew() {
    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = build_device_manager();
    let device_id = "sim_mount_connect_gate";
    register_sim_mount(&manager, device_id).await;

    {
        let mount = crate::api::devices::simulation::get_sim_mount();
        let mut mount = mount.write().await;
        mount.status.connected = true;
        mount.status.parked = true;
    }

    manager
        .mount_slew(device_id, 5.5, 30.0)
        .await
        .expect("a connected simulated mount should accept a slew");

    // The simulated mount travels rather than teleporting, so read through
    // `mount_get_status` (which advances the motion) until it arrives.
    let mut mount = manager.mount_get_status(device_id).await.unwrap();
    for _ in 0..200 {
        if !mount.slewing {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
        mount = manager.mount_get_status(device_id).await.unwrap();
    }
    assert!(!mount.slewing, "the simulated slew never finished");
    // On the target of date: the simulator is a JNow mount.
    let (ra_now, dec_now) = crate::device_manager::epoch::j2000_to_jnow(5.5, 30.0);
    assert!((mount.right_ascension - ra_now).abs() < 1e-6);
    assert!((mount.declination - dec_now).abs() < 1e-6);
    assert!(!mount.parked);

    crate::api::devices::simulation::get_sim_mount()
        .write()
        .await
        .status
        .connected = false;
}

#[cfg(windows)]
#[tokio::test]
async fn test_mount_get_status_uses_ascom_can_park() {
    let manager = build_device_manager();
    let device_id = "ascom:test-mount";
    let info = build_mount_info(device_id, DriverType::Ascom);

    manager.devices.write().await.insert(
        device_id.to_string(),
        ManagedDevice {
            info,
            connection_state: ConnectionState::Connected,
            last_error: None,
            reconnect_attempts: 0,
            auto_reconnect: false,
            last_successful_comm: None,
            heartbeat_active: false,
            api_version: None,
            desired_cooler: None,
            desired_tracking: None,
        },
    );

    let responses = TestMountResponses {
        coordinates: (1.0, 2.0),
        alt_az: (3.0, 4.0),
        tracking: true,
        slewing: false,
        parked: false,
        side_of_pier: nightshade_native::traits::PierSide::East,
        sidereal_time: 5.0,
        can_park: false,
    };
    manager.ascom_mounts.write().await.insert(
        device_id.to_string(),
        Arc::new(RwLock::new(build_test_mount_wrapper(responses))),
    );

    let status = manager
        .mount_get_status(device_id)
        .await
        .expect("mount_get_status");
    assert!(!status.can_park);
}
