use super::*;

#[tokio::test]
async fn connect_simulator_marks_singleton_connected() {
    use crate::api::devices::simulation::get_sim_focuser;

    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = build_device_manager();
    let info = build_sim_info("sim_focuser_1", DeviceType::Focuser);

    // Reset the singleton to disconnected so this test is independent of
    // any earlier test that may have left state behind.
    {
        let mut focuser = get_sim_focuser().write().await;
        focuser.status.connected = false;
    }

    manager
        .connect_simulator(&info)
        .await
        .expect("connect_simulator should succeed for a valid sim focuser id");

    let connected = get_sim_focuser().read().await.status.connected;
    assert!(
        connected,
        "connect_simulator must set the focuser singleton's connected flag to true"
    );

    // Idempotency: a second connect must succeed and leave connected=true.
    manager
        .connect_simulator(&info)
        .await
        .expect("connect_simulator must be idempotent");
    assert!(get_sim_focuser().read().await.status.connected);

    // Unrecognized id (no `sim_` prefix) must surface a descriptive error.
    let bogus = build_sim_info("not_a_sim", DeviceType::Focuser);
    let err = manager
        .connect_simulator(&bogus)
        .await
        .expect_err("non-sim id must fail loudly");
    assert!(
        err.contains("not a simulator id"),
        "error message must call out the prefix mismatch: {}",
        err
    );

    // Unsupported device type (no simulation.rs singleton) must error.
    // Guider is the remaining one; switch and cover calibrator now have
    // simulators and are covered by their own test below.
    let guider = build_sim_info("sim_guider_1", DeviceType::Guider);
    let err = manager
        .connect_simulator(&guider)
        .await
        .expect_err("unsupported sim device type must fail loudly");
    assert!(
        err.contains("no simulator implementation"),
        "error message must call out the missing implementation: {}",
        err
    );

    // Cleanup: restore the singleton to the default disconnected state so
    // other tests that touch SIM_FOCUSER aren't affected.
    get_sim_focuser().write().await.status.connected = false;
}

#[tokio::test]
async fn observatory_accessory_simulators_support_status_and_safe_controls() {
    use crate::api::devices::simulation::{get_sim_dome, get_sim_safety_monitor, get_sim_weather};

    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = build_device_manager();
    let devices = [
        build_sim_info("sim_dome_1", DeviceType::Dome),
        build_sim_info("sim_weather_1", DeviceType::Weather),
        build_sim_info("sim_safety_monitor_1", DeviceType::SafetyMonitor),
    ];

    for info in &devices {
        manager.register_device(info.clone(), false).await;
        manager
            .connect_simulator(info)
            .await
            .expect("accessory simulator should connect");
    }

    let initial = manager
        .dome_get_status("sim_dome_1")
        .await
        .expect("read initial dome status");
    assert!(initial.connected);
    assert_eq!(initial.shutter_status, ShutterState::Closed);

    manager
        .dome_open_shutter("sim_dome_1")
        .await
        .expect("open simulated shutter");
    manager
        .dome_slew_to_azimuth("sim_dome_1", 42.5)
        .await
        .expect("slew simulated dome");
    manager
        .dome_set_slaved("sim_dome_1", true)
        .await
        .expect("slave simulated dome");
    let changed = manager
        .dome_get_status("sim_dome_1")
        .await
        .expect("read changed dome status");
    assert_eq!(changed.shutter_status, ShutterState::Open);
    assert!((changed.azimuth - 42.5).abs() < f64::EPSILON);
    assert!(changed.is_slaved);

    manager
        .dome_close_shutter("sim_dome_1")
        .await
        .expect("close simulated shutter");
    manager
        .dome_park("sim_dome_1")
        .await
        .expect("park simulated dome");
    let parked = manager
        .dome_get_status("sim_dome_1")
        .await
        .expect("read parked dome status");
    assert_eq!(parked.shutter_status, ShutterState::Closed);
    assert!(parked.at_park);

    let weather = manager
        .weather_get_conditions("sim_weather_1")
        .await
        .expect("read simulated weather");
    assert_eq!(weather.rain_rate, Some(0.0));
    assert!(weather.temperature.is_some());

    assert!(manager
        .safety_is_safe("sim_safety_monitor_1")
        .await
        .expect("read simulated safety state"));

    for info in &devices {
        assert!(manager
            .perform_health_check(&info.id, &info.device_type, &DriverType::Simulator)
            .await
            .expect("accessory simulator heartbeat"));
        manager
            .disconnect_simulator(info)
            .await
            .expect("accessory simulator should disconnect");
    }

    assert!(!get_sim_dome().read().await.status.connected);
    assert!(!get_sim_weather().read().await.connected);
    assert!(!get_sim_safety_monitor().read().await.status.connected);
}

#[tokio::test]
async fn disconnect_simulator_marks_singleton_disconnected() {
    use crate::api::devices::simulation::get_sim_filterwheel;

    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = build_device_manager();
    let info = build_sim_info("sim_filterwheel_1", DeviceType::FilterWheel);

    // Pre-condition: bring the singleton to connected.
    manager
        .connect_simulator(&info)
        .await
        .expect("connect_simulator setup should succeed");
    assert!(get_sim_filterwheel().read().await.status.connected);

    manager
        .disconnect_simulator(&info)
        .await
        .expect("disconnect_simulator should succeed for a valid sim fw id");

    let connected = get_sim_filterwheel().read().await.status.connected;
    assert!(
        !connected,
        "disconnect_simulator must clear the filter wheel singleton's connected flag"
    );

    // Idempotency: a second disconnect must succeed and leave it false.
    manager
        .disconnect_simulator(&info)
        .await
        .expect("disconnect_simulator must be idempotent");
    assert!(!get_sim_filterwheel().read().await.status.connected);

    // Non-sim id surfaces an error.
    let bogus = build_sim_info("ascom:foo", DeviceType::FilterWheel);
    let err = manager
        .disconnect_simulator(&bogus)
        .await
        .expect_err("non-sim id must fail loudly");
    assert!(
        err.contains("not a simulator id"),
        "error message must call out the prefix mismatch: {}",
        err
    );
}

#[tokio::test]
async fn heartbeat_reflects_simulator_singleton_state() {
    use crate::api::devices::simulation::get_sim_mount;

    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = build_device_manager();
    let device_id = "sim_mount_1";
    let info = build_sim_info(device_id, DeviceType::Mount);

    // Register and connect the simulator so the heartbeat target exists.
    manager.register_device(info.clone(), false).await;
    manager
        .connect_simulator(&info)
        .await
        .expect("connect_simulator should succeed");

    // Health check uses the private `perform_health_check`; exercise it
    // through `perform_simulator_health_check` directly via the public
    // surface that exists. Because `perform_health_check` is private to
    // the device_manager module we can call it from this in-module test.
    let healthy = manager
        .perform_health_check(device_id, &DeviceType::Mount, &DriverType::Simulator)
        .await
        .expect("simulator health check should not error for a valid sim mount");
    assert!(
        healthy,
        "heartbeat must report healthy while the mount singleton is connected"
    );

    // Flip the singleton state out-of-band — this mirrors what a future
    // user-triggered disconnect (or a forced state change) would do.
    get_sim_mount().write().await.status.connected = false;

    let unhealthy = manager
        .perform_health_check(device_id, &DeviceType::Mount, &DriverType::Simulator)
        .await
        .expect("simulator health check should not error when the singleton is disconnected");
    assert!(
        !unhealthy,
        "heartbeat must report unhealthy after the mount singleton is flipped to disconnected"
    );

    // Restoring the flag must restore healthy reporting.
    get_sim_mount().write().await.status.connected = true;
    let healthy_again = manager
        .perform_health_check(device_id, &DeviceType::Mount, &DriverType::Simulator)
        .await
        .expect("simulator health check should succeed after re-connect");
    assert!(
        healthy_again,
        "heartbeat must report healthy again once the mount singleton is reconnected"
    );

    // Cleanup so we leave the global singleton in a deterministic state
    // for any tests that run after us.
    get_sim_mount().write().await.status.connected = false;
}

// The INDI heartbeat must invoke the client's own recovery path: a
// disconnected INDI client attempts reader recovery, and if recovery cannot
// reconnect it surfaces a real error rather than a passive "not healthy"
// result that leaves `recover_reader` never called.
#[tokio::test]
async fn indi_health_check_attempts_reader_recovery_when_server_disconnected() {
    let manager = build_device_manager();

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind ephemeral localhost port");
    let port = listener.local_addr().expect("read listener address").port();
    drop(listener);

    let device_id = format!("indi:127.0.0.1:{}:Test Mount", port);
    let info = build_mount_info(&device_id, DriverType::Indi);
    manager.register_device(info, false).await;

    let timeout_config = skotiq_indi::IndiTimeoutConfig {
        connection_timeout_secs: 1,
        ..Default::default()
    };
    let client =
        skotiq_indi::IndiClient::with_timeout_config("127.0.0.1", Some(port), timeout_config);

    manager
        .indi_clients
        .write()
        .await
        .insert(format!("127.0.0.1:{}", port), Arc::new(RwLock::new(client)));

    let err = manager
        .perform_health_check(&device_id, &DeviceType::Mount, &DriverType::Indi)
        .await
        .expect_err("disconnected INDI client must attempt recovery and surface failure");

    assert!(
        err.contains("reader recovery failed"),
        "INDI health check must call recover_reader instead of returning Ok(false): {}",
        err
    );
    assert!(
        err.contains("Failed to connect") || err.contains("timeout"),
        "recovery failure should include the underlying connect error: {}",
        err
    );
}

#[tokio::test]
async fn indi_health_check_reissues_device_connect_after_server_recovery() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    let manager = build_device_manager();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind fake INDI server");
    let port = listener.local_addr().expect("read listener address").port();
    let device_name = "Test Mount";
    let device_id = format!("indi:127.0.0.1:{}:{}", port, device_name);

    let (connect_seen_tx, connect_seen_rx) = tokio::sync::oneshot::channel::<String>();
    let server = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.expect("accept INDI client");
        let mut buf = vec![0_u8; 4096];

        let _ = socket
            .read(&mut buf)
            .await
            .expect("read initial getProperties");
        socket
            .write_all(
                br#"
<defSwitchVector device="Test Mount" name="CONNECTION" state="Idle" perm="rw">
  <defSwitch name="CONNECT">Off</defSwitch>
  <defSwitch name="DISCONNECT">On</defSwitch>
</defSwitchVector>
<setSwitchVector device="Test Mount" name="CONNECTION" state="Ok">
  <oneSwitch name="CONNECT">Off</oneSwitch>
  <oneSwitch name="DISCONNECT">On</oneSwitch>
</setSwitchVector>
"#,
            )
            .await
            .expect("write disconnected device state");

        loop {
            buf.fill(0);
            let n = socket.read(&mut buf).await.expect("read reconnect command");
            if n == 0 {
                break;
            }
            let command = String::from_utf8_lossy(&buf[..n]).to_string();
            if command.contains("<newSwitchVector")
                && command.contains("name=\"CONNECTION\"")
                && command.contains("name=\"CONNECT\">On")
            {
                let _ = connect_seen_tx.send(command);
                break;
            }
        }
    });

    let info = build_mount_info(&device_id, DriverType::Indi);
    manager.register_device(info, false).await;

    let timeout_config = skotiq_indi::IndiTimeoutConfig {
        connection_timeout_secs: 1,
        ..Default::default()
    };
    let mut client =
        skotiq_indi::IndiClient::with_timeout_config("127.0.0.1", Some(port), timeout_config);
    client.connect().await.expect("connect fake INDI client");

    let property_deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(2);
    while client
        .get_property(device_name, "CONNECTION")
        .await
        .is_none()
    {
        assert!(
            tokio::time::Instant::now() < property_deadline,
            "fake INDI CONNECTION property was not parsed in time"
        );
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    assert!(
        !client.is_device_connected(device_name).await,
        "test setup expects the fake server to report the device disconnected"
    );

    manager
        .indi_clients
        .write()
        .await
        .insert(format!("127.0.0.1:{}", port), Arc::new(RwLock::new(client)));

    let healthy = manager
        .perform_health_check(&device_id, &DeviceType::Mount, &DriverType::Indi)
        .await
        .expect("INDI health check should send device reconnect command");
    assert!(
        !healthy,
        "health stays false until the INDI driver confirms CONNECT=On"
    );

    let command = tokio::time::timeout(std::time::Duration::from_secs(2), connect_seen_rx)
        .await
        .expect("fake INDI server should receive CONNECT command")
        .expect("server task should send observed command");
    assert!(
        command.contains("Test Mount"),
        "CONNECT command must target the managed INDI device: {}",
        command
    );

    server.await.expect("fake INDI server task should finish");
}

// ops/* simulator arms must consult the singleton rather than return
// hardcoded `Ok(value)` constants. These exercise the connect → read →
// disconnect → read cycle for a read-side and a write-side shape, plus one
// device type with no singleton (switch).
//
// The simulation.rs singletons are process-wide, so these tests hold
// `simulator_singleton_test_lock` while they run and reset singleton state
// before returning.

#[tokio::test]
async fn camera_ops_simulator_gates_on_singleton_connected() {
    use crate::api::devices::simulation::get_sim_camera;

    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = Arc::new(build_device_manager());
    let device_id = "sim_camera_ops_1";
    let info = build_sim_info(device_id, DeviceType::Camera);
    manager.register_device(info.clone(), false).await;

    // Pre-condition: singleton starts disconnected.
    get_sim_camera().write().await.status.connected = false;

    // Read before connect → loud error.
    let err = manager
        .camera_get_status(device_id)
        .await
        .expect_err("disconnected sim camera must surface an error");
    assert!(
        err.to_string().contains("not connected"),
        "error must call out missing connection: {}",
        err
    );

    // Connect flips the singleton; ops reads now succeed and reflect
    // the singleton's defaults.
    manager
        .connect_simulator(&info)
        .await
        .expect("connect_simulator should succeed");

    let status = manager
        .camera_get_status(device_id)
        .await
        .expect("connected sim camera status read must succeed");
    assert!(status.connected, "status must reflect connected singleton");
    let default_gain = status.gain;

    // Write-side: setting gain mutates the singleton (singleton-as-state)
    // and the next read returns the new value — no silent drop.
    manager
        .camera_set_gain(device_id, default_gain + 25)
        .await
        .expect("connected sim camera set_gain must succeed");
    let status_after = manager
        .camera_get_status(device_id)
        .await
        .expect("re-read connected sim camera status");
    assert_eq!(status_after.gain, default_gain + 25);

    // Disconnect flips the singleton back; reads and writes both fail loud.
    manager
        .disconnect_simulator(&info)
        .await
        .expect("disconnect_simulator should succeed");
    let err = manager
        .camera_get_status(device_id)
        .await
        .expect_err("disconnected sim camera must surface an error");
    assert!(err.to_string().contains("not connected"));
    let err = manager
        .camera_set_gain(device_id, 999)
        .await
        .expect_err("disconnected sim camera set_gain must surface an error");
    assert!(err.to_string().contains("not connected"));

    // Cleanup so any later tests using SIM_CAMERA see a clean slate.
    get_sim_camera().write().await.status.connected = false;
}

#[tokio::test]
async fn focuser_ops_simulator_gates_on_singleton_connected() {
    use crate::api::devices::simulation::get_sim_focuser;

    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = Arc::new(build_device_manager());
    let device_id = "sim_focuser_ops_1";
    let info = build_sim_info(device_id, DeviceType::Focuser);
    manager.register_device(info.clone(), false).await;

    get_sim_focuser().write().await.status.connected = false;

    // Disconnected read fails loud.
    let err = manager
        .focuser_get_position(device_id)
        .await
        .expect_err("disconnected sim focuser must surface an error");
    assert!(err.to_string().contains("not connected"));

    // Connect, then read the singleton's default position.
    manager
        .connect_simulator(&info)
        .await
        .expect("connect_simulator should succeed");
    let default_pos = manager
        .focuser_get_position(device_id)
        .await
        .expect("connected sim focuser position read must succeed");

    // Move absolute mutates the singleton.
    manager
        .focuser_move_abs(device_id, default_pos + 100)
        .await
        .expect("connected sim focuser move_abs must succeed");
    let new_pos = manager
        .focuser_get_position(device_id)
        .await
        .expect("re-read connected sim focuser position");
    assert_eq!(new_pos, default_pos + 100);

    // Disconnect → write fails loud (no silent acceptance).
    manager
        .disconnect_simulator(&info)
        .await
        .expect("disconnect_simulator should succeed");
    let err = manager
        .focuser_move_abs(device_id, 12345)
        .await
        .expect_err("disconnected sim focuser move_abs must surface an error");
    assert!(err.to_string().contains("not connected"));

    get_sim_focuser().write().await.status.connected = false;
}

/// The simulated switch and cover calibrator obey the same connection gate
/// as every other simulator: they answer once connected and refuse before.
///
/// This replaces an assertion that both device types loud-errored
/// unconditionally, which was true only because neither had a simulator at
/// all — the reason the app logged "Discovery complete for Switch: 0
/// devices" every launch and flat-panel flows could not be run without
/// hardware. Answering while disconnected would be the opposite failure and
/// is what the second half of this test pins down.
#[tokio::test]
async fn switch_and_cover_simulators_answer_only_while_connected() {
    let _guard = simulator_singleton_test_lock().lock().await;
    // The singletons are process-global; start from the power-on state so
    // an earlier test's open cover cannot masquerade as this one's.
    crate::api::devices::simulation::reset_sim_cover_calibrator().await;
    crate::api::devices::simulation::reset_sim_switch().await;
    let manager = Arc::new(build_device_manager());

    let switch_info = build_sim_info("sim_switch_1", DeviceType::Switch);
    let cover_info = build_sim_info("sim_cover_calibrator_1", DeviceType::CoverCalibrator);
    manager.register_device(switch_info.clone(), false).await;
    manager.register_device(cover_info.clone(), false).await;

    for info in [&switch_info, &cover_info] {
        manager
            .disconnect_simulator(info)
            .await
            .expect("disconnect_simulator should succeed for a supported sim type");
    }

    for err in [
        manager
            .switch_get_max("sim_switch_1")
            .await
            .expect_err("a disconnected sim switch must not report a channel count")
            .to_string(),
        manager
            .cover_calibrator_get_cover_state("sim_cover_calibrator_1")
            .await
            .expect_err("a disconnected sim panel must not report a cover state")
            .to_string(),
    ] {
        assert!(
            err.contains("not connected"),
            "the refusal must name the disconnection: {err}"
        );
    }

    for info in [&switch_info, &cover_info] {
        manager
            .connect_simulator(info)
            .await
            .expect("connect_simulator should succeed for a supported sim type");
    }

    assert!(
        manager
            .switch_get_max("sim_switch_1")
            .await
            .expect("a connected sim switch reports its channels")
            > 0
    );
    assert_eq!(
        manager
            .cover_calibrator_get_cover_state("sim_cover_calibrator_1")
            .await
            .expect("a connected sim panel reports its cover state"),
        CoverState::Closed.to_i32(),
        "a freshly connected flat panel must report its cover closed"
    );

    for info in [&switch_info, &cover_info] {
        manager
            .disconnect_simulator(info)
            .await
            .expect("disconnect_simulator should succeed");
    }
}
