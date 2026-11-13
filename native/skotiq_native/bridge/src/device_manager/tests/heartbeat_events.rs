use super::*;
use crate::device::DriverType;

// stop_heartbeat must not emit HeartbeatStopped when there was
// no heartbeat task to stop. Otherwise every connect (which defensively
// calls stop_heartbeat first) emits a spurious stop event.
#[tokio::test]
async fn stop_heartbeat_on_unknown_device_emits_no_event() {
    use crate::event::bus::EventPayload;
    use crate::event::equipment::EquipmentEvent;
    use tokio::sync::broadcast::error::TryRecvError;

    let manager = build_device_manager();
    // Subscribe BEFORE the call so we'd catch any published event.
    let mut rx = manager.app_state.event_bus.subscribe();

    // Device id that was never registered and never had a heartbeat.
    manager
        .stop_heartbeat("nonexistent-device-id")
        .await
        .expect("stop_heartbeat on unknown device should succeed");

    // Drain any events and assert NONE of them are HeartbeatStopped for
    // our device id. Other events from background tasks are tolerated.
    loop {
        match rx.try_recv() {
            Ok(event) => {
                if let EventPayload::Equipment(EquipmentEvent::HeartbeatStopped {
                    device_id, ..
                }) = &event.payload
                {
                    panic!(
                        "stop_heartbeat on unknown device unexpectedly published \
                             HeartbeatStopped for {}",
                        device_id
                    );
                }
            }
            Err(TryRecvError::Empty) | Err(TryRecvError::Closed) => break,
            Err(TryRecvError::Lagged(_)) => continue,
        }
    }
}

// Same protection for a registered device that simply never had a heartbeat
// started — `start_heartbeat_with_config` calls `stop_heartbeat` defensively
// first, so the very first connect would otherwise publish a stop event.
#[tokio::test]
async fn stop_heartbeat_on_registered_but_inactive_device_emits_no_event() {
    use crate::event::bus::EventPayload;
    use crate::event::equipment::EquipmentEvent;
    use tokio::sync::broadcast::error::TryRecvError;

    let manager = build_device_manager();
    let device_id = "alpaca:test-mount";
    let info = build_mount_info(device_id, DriverType::Alpaca);
    manager.register_device(info, false).await;

    let mut rx = manager.app_state.event_bus.subscribe();

    manager
        .stop_heartbeat(device_id)
        .await
        .expect("stop_heartbeat on registered-but-inactive device should succeed");

    loop {
        match rx.try_recv() {
            Ok(event) => {
                if let EventPayload::Equipment(EquipmentEvent::HeartbeatStopped {
                    device_id: published_id,
                    ..
                }) = &event.payload
                {
                    assert_ne!(
                        published_id, device_id,
                        "stop_heartbeat on registered-but-inactive device must not \
                             publish HeartbeatStopped"
                    );
                }
            }
            Err(TryRecvError::Empty) | Err(TryRecvError::Closed) => break,
            Err(TryRecvError::Lagged(_)) => continue,
        }
    }
}

// `disconnect_device` must route PHD2 device ids through the
// PHD2-specific disconnect helper (mirroring the built-in-guider check),
// otherwise the PHD2 client is leaked on disconnect.
//
// We can't run the real PHD2 dispatch in a unit test (no server), but we
// can at least lock down the contract that:
//   - the helper name we depend on exists and has the expected signature
//     (this is a compile-time check: a typo would break the build)
//   - `guider::phd2::is_device_id` recognizes the canonical PHD2 ids the
//     `disconnect_device` arm dispatches on.
#[tokio::test]
async fn disconnect_phd2_via_generic_route_calls_phd2_disconnect() {
    // Compile-time check: ensure both helpers referenced by
    // `disconnect_device` exist with the expected signatures. If either
    // changes name or shape, this test stops compiling — which is the
    // signal we want, because the dispatch arm in connection.rs depends
    // on them. The `let _ = ...` pattern with explicit return-type
    // bindings forces the compiler to resolve the symbols without
    // actually invoking them.
    let _is_id_fn: fn(&str) -> bool = crate::guider::phd2::is_device_id;
    // `guider::phd2::disconnect` is async; binding the call (not the await)
    // produces a future we discard. This both proves the symbol exists
    // AND that its return type unifies with `Result<(), _>` shape.
    let _disconnect_fut = async {
        let _: Result<(), crate::error::SkotiqError> =
            crate::guider::phd2::disconnect().await;
    };

    // Behavioral check: the id-recognition helper must accept every form
    // a PHD2 device id can take, so the dispatch arm fires for all of
    // them. If a new id format is added, both this list and
    // `guider::phd2::is_device_id` need to be updated together.
    for id in ["phd2", "phd2_guider", "phd2:localhost:4400", "phd2://host"] {
        assert!(
            crate::guider::phd2::is_device_id(id),
            "guider::phd2::is_device_id must recognize {} so disconnect_device dispatches \
                 PHD2-specific cleanup",
            id
        );
    }

    // And a non-PHD2 id must NOT trigger the dispatch arm.
    assert!(!crate::guider::phd2::is_device_id(
        "alpaca:test-guider"
    ));
    assert!(!crate::guider::phd2::is_device_id(
        "phd2x-not-really-phd2"
    ));
}

// a manual `disconnect_device` arriving while a reconnect attempt
// is between backoff and dispatch (i.e. inside `connect_device_internal`)
// must trip the per-device cancel token so the connect attempt bails with
// `RECONNECT_CANCELED_MSG` instead of overwriting the user's Disconnected
// state with Connected.
//
// This test exercises the contract directly:
//   1. Install the cancel token (mirrors what `reconnection_loop` does
//      after backoff begins).
//   2. Run `disconnect_device`, which must call `trip_reconnect_cancel_
//      token` AFTER releasing the devices write lock.
//   3. A subsequent `connect_device_internal` call (mirrors the dispatch
//      the loop would issue after backoff) must short-circuit with
//      `RECONNECT_CANCELED_MSG` and must NOT flip the device back to
//      `Connected`.
#[tokio::test]
async fn manual_disconnect_trips_in_flight_reconnect_cancel_token() {
    use crate::device_manager::connection::RECONNECT_CANCELED_MSG;

    let manager = build_device_manager();
    let device_id = "simulator:test-reconnect-cancel";
    let info = DeviceInfo {
        id: device_id.to_string(),
        name: "Sim Cancel Mount".to_string(),
        device_type: DeviceType::Mount,
        driver_type: DriverType::Simulator,
        description: "Test mount for cancel token wiring".to_string(),
        driver_version: "1.0".to_string(),
        serial_number: None,
        unique_id: None,
        display_name: "Sim Cancel Mount".to_string(),
    };

    // Step 1: register and mark the device as in the Error state, which is
    // what reconnection_loop sees when it picks it up. Auto-reconnect ON.
    manager.register_device(info.clone(), true).await;
    {
        let mut devices = manager.devices.write().await;
        let dev = devices
            .get_mut(device_id)
            .expect("device should be registered");
        dev.connection_state = ConnectionState::Error;
        dev.last_error = Some("simulated transient failure".to_string());
    }

    // Step 2: install the cancel token (mirrors reconnection_loop before
    // its backoff sleep). We hold a receiver to assert the trip below.
    let mut cancel_rx = manager.install_reconnect_cancel_token(device_id).await;
    assert!(!*cancel_rx.borrow(), "token must start un-tripped");

    // Step 3: user calls disconnect_device. This must trip the token.
    manager
        .disconnect_device(device_id)
        .await
        .expect("disconnect_device should succeed for registered simulator device");

    // The cancel token must now be tripped. `changed()` resolves
    // immediately because `send_replace(true)` woke the watcher.
    cancel_rx
        .changed()
        .await
        .expect("trip_reconnect_cancel_token must signal watchers");
    assert!(
        *cancel_rx.borrow(),
        "disconnect_device must trip the in-flight reconnect cancel token"
    );

    // Auto-reconnect must also be off so the loop wouldn't re-pick this
    // device on its next tick (defense-in-depth: even if the dispatch
    // call below somehow ignored the token, the loop's filter would).
    {
        let devices = manager.devices.read().await;
        let dev = devices.get(device_id).expect("device still registered");
        assert!(
            !dev.auto_reconnect,
            "disconnect_device must clear auto_reconnect"
        );
        assert_eq!(
            dev.connection_state,
            ConnectionState::Disconnected,
            "disconnect_device must leave state Disconnected"
        );
    }

    // Step 4: the reconnection loop, unaware of the disconnect, now
    // dispatches `connect_device_internal`. Because the token is tripped,
    // this must return RECONNECT_CANCELED_MSG and must NOT mutate the
    // device's state back to Connected.
    let result = manager.connect_device_internal(&info).await;
    match result {
        Err(e) if e == RECONNECT_CANCELED_MSG => {}
        other => panic!(
            "connect_device_internal with tripped token must return \
                 RECONNECT_CANCELED_MSG, got {:?}",
            other
        ),
    }

    // The device state must remain Disconnected — the reconnect attempt
    // is not allowed to silently re-Connect a device the user released.
    let devices = manager.devices.read().await;
    let dev = devices.get(device_id).expect("device still registered");
    assert_eq!(
        dev.connection_state,
        ConnectionState::Disconnected,
        "canceled reconnect must NOT flip state back to Connected"
    );
}

// The rig repro (Nov 8 2026): the mount sat in Error with the reconnection
// loop holding a cancel token, the user disconnected it, then every
// `POST /api/devices/connect` failed with "reconnect canceled by manual
// disconnect" until the app restarted, because the requested connect borrowed
// the token the disconnect had tripped.
#[tokio::test]
async fn requested_connect_after_manual_disconnect_is_not_canceled() {
    use crate::simulator::mount::get_sim_mount;

    let _guard = super::simulator_singleton_test_lock().lock().await;
    let manager = build_device_manager();
    let device_id = "sim_mount_1";
    let info = DeviceInfo {
        id: device_id.to_string(),
        name: "Simulated Mount".to_string(),
        device_type: DeviceType::Mount,
        driver_type: DriverType::Simulator,
        description: "Simulator device".to_string(),
        driver_version: "Simulator".to_string(),
        serial_number: None,
        unique_id: None,
        display_name: "Simulated Mount".to_string(),
    };
    manager.register_device(info.clone(), true).await;
    {
        let mut devices = manager.devices.write().await;
        devices.get_mut(device_id).unwrap().connection_state = ConnectionState::Error;
    }
    // What the reconnection loop does for a device in Error.
    let _loop_rx = manager.install_reconnect_cancel_token(device_id).await;

    manager.disconnect_device(device_id).await.unwrap();

    for attempt in 1..=2 {
        manager
            .connect_device(device_id)
            .await
            .unwrap_or_else(|e| panic!("requested connect {attempt} failed: {e}"));
        assert!(
            manager
                .is_device_connected(DeviceType::Mount, device_id)
                .await
        );
        manager.disconnect_device(device_id).await.unwrap();
    }
    get_sim_mount().write().await.status.connected = false;
}

// A disconnect that lands while a requested connect is in flight still
// cancels it: the fresh token the connect installs is the one the disconnect
// trips.
#[tokio::test]
async fn disconnect_during_requested_connect_still_cancels_it() {
    use crate::device_manager::connection::RECONNECT_CANCELED_MSG;
    use crate::simulator::faults::{self, Effect, FaultSpec, Trigger};

    let _guard = super::simulator_singleton_test_lock().lock().await;
    let manager = std::sync::Arc::new(build_device_manager());
    let device_id = "sim_mount_1";
    let info = DeviceInfo {
        id: device_id.to_string(),
        name: "Simulated Mount".to_string(),
        device_type: DeviceType::Mount,
        driver_type: DriverType::Simulator,
        description: "Simulator device".to_string(),
        driver_version: "Simulator".to_string(),
        serial_number: None,
        unique_id: None,
        display_name: "Simulated Mount".to_string(),
    };
    manager.register_device(info.clone(), false).await;
    faults::arm(
        "mount.connect",
        FaultSpec::new(Trigger::Times(1), Effect::Delay(300)),
    );

    let connecting = {
        let manager = manager.clone();
        tokio::spawn(async move { manager.connect_device(device_id).await })
    };
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    manager.disconnect_device(device_id).await.unwrap();

    let result = connecting.await.unwrap();
    faults::clear_all();
    crate::simulator::mount::get_sim_mount()
        .write()
        .await
        .status
        .connected = false;
    assert_eq!(result, Err(RECONNECT_CANCELED_MSG.to_string()));
}

// The NYX-101 night: a mount whose status reads fail while its heartbeat
// probe passes. The failed reads must be what the heartbeat sees.
#[tokio::test]
async fn failing_mount_status_reads_are_recorded_for_the_heartbeat() {
    use crate::simulator::mount::get_sim_mount;
    use crate::simulator::faults::{self, Effect, FaultSpec, Trigger};

    let _guard = super::simulator_singleton_test_lock().lock().await;
    let manager = build_device_manager();
    let device_id = "sim_mount_1";
    manager
        .register_device(super::build_sim_info(device_id, DeviceType::Mount), false)
        .await;
    manager.connect_device(device_id).await.unwrap();
    faults::arm(
        "mount.status",
        FaultSpec::new(
            Trigger::Always,
            Effect::Error("Failed to get RA: Starting the driver is required 0x80040401".into()),
        ),
    );

    for _ in 0..3 {
        assert!(manager.mount_get_status(device_id).await.is_err());
    }
    let reason = manager
        .failing_status_reads(device_id)
        .expect("three failed reads must count");
    assert!(reason.contains("0x80040401"), "{reason}");

    faults::clear_all();
    manager.mount_get_status(device_id).await.unwrap();
    assert_eq!(manager.failing_status_reads(device_id), None);

    manager.disconnect_device(device_id).await.unwrap();
    get_sim_mount().write().await.status.connected = false;
}

// A lost mount whose reconnect keeps failing told the operator twice per
// attempt: the failed connect's Error with the reason, and a second
// "Reconnection attempt N failed" event for the same failure.
#[tokio::test]
async fn a_failed_reconnect_attempt_publishes_one_event() {
    use crate::simulator::mount::get_sim_mount;
    use crate::simulator::faults::{self, Effect, FaultSpec, Trigger};
    use crate::event::bus::EventPayload;
    use crate::event::equipment::EquipmentEvent;
    use tokio::sync::broadcast::error::TryRecvError;

    let _guard = super::simulator_singleton_test_lock().lock().await;
    let manager = build_device_manager();
    let device_id = "sim_mount_1";
    let info = super::build_sim_info(device_id, DeviceType::Mount);
    manager.register_device(info.clone(), true).await;
    faults::arm(
        "mount.connect",
        FaultSpec::new(Trigger::Always, Effect::Error("unplugged".into())),
    );
    let mut rx = manager.app_state.event_bus.subscribe();

    manager.attempt_reconnect(device_id, &info).await;
    faults::clear_all();

    let mut errors = Vec::new();
    loop {
        match rx.try_recv() {
            Ok(event) => {
                if let EventPayload::Equipment(EquipmentEvent::Error {
                    device_id: id,
                    message,
                    ..
                }) = &event.payload
                {
                    if id == device_id {
                        errors.push(message.clone());
                    }
                }
            }
            Err(TryRecvError::Lagged(_)) => continue,
            Err(_) => break,
        }
    }
    assert_eq!(errors.len(), 1, "{errors:?}");
    assert!(errors[0].contains("unplugged"), "{errors:?}");
    let devices = manager.devices.read().await;
    assert_eq!(devices.get(device_id).unwrap().reconnect_attempts, 1);
    drop(devices);
    get_sim_mount().write().await.status.connected = false;
}
