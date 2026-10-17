use super::*;

// stop_heartbeat must not emit HeartbeatStopped when there was
// no heartbeat task to stop. Otherwise every connect (which defensively
// calls stop_heartbeat first) emits a spurious stop event.
#[tokio::test]
async fn stop_heartbeat_on_unknown_device_emits_no_event() {
    use crate::event::{EquipmentEvent, EventPayload};
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
    use crate::event::{EquipmentEvent, EventPayload};
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
//   - `is_phd2_device_id` recognizes the canonical PHD2 ids the
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
    let _is_id_fn: fn(&str) -> bool = crate::api::connection::is_phd2_device_id;
    // `api_phd2_disconnect` is async; binding the call (not the await)
    // produces a future we discard. This both proves the symbol exists
    // AND that its return type unifies with `Result<(), _>` shape.
    let _disconnect_fut = async {
        let _: Result<(), crate::error::SkotiqError> =
            crate::api::phd2::api_phd2_disconnect().await;
    };

    // Behavioral check: the id-recognition helper must accept every form
    // a PHD2 device id can take, so the dispatch arm fires for all of
    // them. If a new id format is added, both this list and
    // `is_phd2_device_id` need to be updated together.
    for id in ["phd2", "phd2_guider", "phd2:localhost:4400", "phd2://host"] {
        assert!(
            crate::api::connection::is_phd2_device_id(id),
            "is_phd2_device_id must recognize {} so disconnect_device dispatches \
                 PHD2-specific cleanup",
            id
        );
    }

    // And a non-PHD2 id must NOT trigger the dispatch arm.
    assert!(!crate::api::connection::is_phd2_device_id(
        "alpaca:test-guider"
    ));
    assert!(!crate::api::connection::is_phd2_device_id(
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
