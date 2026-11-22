use super::*;

async fn display_name(manager: &DeviceManager, device_id: &str) -> Option<String> {
    manager
        .get_device(device_id)
        .await
        .map(|device| device.info.display_name)
}

/// A connect must read identity back off the driver and replace the
/// id-derived placeholder name with it.
///
/// Before this, `GET /api/devices/connected` reported `native:zwo:1` as
/// `"ZWO 1"` on the live rig while discovery for the same id said
/// `"ZWO ASI178MM"` — the connected-device name was a pure function of the
/// id string and the driver was never asked.
#[tokio::test]
async fn connect_replaces_the_id_derived_name_with_the_drivers_own() {
    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = build_device_manager();
    let info = build_identity_camera_info();

    manager.register_device(info.clone(), false).await;
    install_fake_device(&manager, &info.id, "ZWO ASI1600MM-Cool", None).await;

    manager
        .connect_device_internal(&info)
        .await
        .expect("connect should succeed");

    assert_eq!(
        display_name(&manager, &info.id).await.as_deref(),
        Some("ZWO ASI1600MM-Cool"),
        "the driver's own name must replace the id-derived placeholder"
    );

    crate::simulator::camera::get_sim_camera()
        .write()
        .await
        .status
        .connected = false;
}

/// The headline case: the id survives a replug but the hardware behind it
/// does not. The connect must fail rather than image the wrong sensor.
#[tokio::test]
async fn connect_refuses_an_id_that_re_bound_to_different_hardware() {
    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = build_device_manager();
    let info = build_identity_camera_info();

    manager.register_device(info.clone(), false).await;

    // First connect: this id is the 1600, and that is recorded.
    install_fake_device(&manager, &info.id, "ZWO ASI1600MM-Cool", None).await;
    manager
        .connect_device_internal(&info)
        .await
        .expect("first connect should succeed");

    // Replug. The SDK re-enumerates and the same id is now the other body.
    install_fake_device(&manager, &info.id, "ZWO ASI178MM", Some("3520810329000900")).await;

    let err = manager
        .connect_device_internal(&info)
        .await
        .expect_err("a swapped camera must not connect")
        .to_string();

    assert!(
        err.contains("no longer the same hardware"),
        "error should name the cause, got: {err}"
    );
    assert!(
        err.contains("ZWO ASI1600MM-Cool") && err.contains("ZWO ASI178MM"),
        "error should name both cameras so the operator can see the swap, got: {err}"
    );

    crate::simulator::camera::get_sim_camera()
        .write()
        .await
        .status
        .connected = false;
}

/// Reconnecting to the SAME hardware must stay routine — the gate must not
/// turn an ordinary USB blip into a night-ending failure.
#[tokio::test]
async fn reconnecting_the_same_camera_is_not_treated_as_a_swap() {
    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = build_device_manager();
    let info = build_identity_camera_info();

    manager.register_device(info.clone(), false).await;
    install_fake_device(&manager, &info.id, "ZWO ASI178MM", Some("3520810329000900")).await;

    manager
        .connect_device_internal(&info)
        .await
        .expect("first connect should succeed");
    manager
        .connect_device_internal(&info)
        .await
        .expect("reconnecting the same camera must succeed");

    crate::simulator::camera::get_sim_camera()
        .write()
        .await
        .status
        .connected = false;
}

/// The swap has to be reported on the path it actually happens on.
///
/// A mid-night USB dropout marks the device `Error`, and the reconnection
/// loop installs a cancel token before retrying. Releasing the wrong camera
/// trips that same token, so an identity error rewritten as
/// `RECONNECT_CANCELED_MSG` — which the reconnection loop then suppresses on
/// purpose, because it means "the user disconnected" — tells the operator
/// nothing at all about the swap on the one path the check exists for.
#[tokio::test]
async fn a_swap_found_during_auto_reconnect_is_not_reported_as_a_user_cancel() {
    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = build_device_manager();
    let info = build_identity_camera_info();

    manager.register_device(info.clone(), false).await;
    install_fake_device(&manager, &info.id, "ZWO ASI1600MM-Cool", None).await;
    manager
        .connect_device_internal(&info)
        .await
        .expect("first connect should succeed");

    // What the reconnection loop does before every retry.
    let _cancel_rx = manager.install_reconnect_cancel_token(&info.id).await;

    install_fake_device(&manager, &info.id, "ZWO ASI178MM", Some("3520810329000900")).await;
    let err = manager
        .connect_device_internal(&info)
        .await
        .expect_err("a swapped camera must not connect")
        .to_string();

    assert_ne!(
        err,
        crate::device_manager::connection::RECONNECT_CANCELED_MSG,
        "nobody canceled anything; the swap must not be reported as a user disconnect"
    );
    assert!(
        err.contains("ZWO ASI1600MM-Cool") && err.contains("ZWO ASI178MM"),
        "the reconnect error must still name both cameras, got: {err}"
    );

    crate::simulator::camera::get_sim_camera()
        .write()
        .await
        .status
        .connected = false;
}

/// A driver that answers its own id when asked for its name has told us
/// nothing, and must not be allowed to overwrite the name with it.
///
/// `ZwoCamera::name()` returned `native:zwo:1` until the model cache landed,
/// and `PlayerOneCamera` still returns its `device_id`. Accepting that as
/// the model swaps one id-derived placeholder for another — and it reaches
/// further than the device list, because the FITS `INSTRUME` keyword is
/// written from the same string.
#[tokio::test]
async fn a_driver_echoing_its_own_id_does_not_become_the_name() {
    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = build_device_manager();
    let info = build_identity_camera_info();

    manager.register_device(info.clone(), false).await;
    install_fake_device(&manager, &info.id, &info.id, None).await;

    manager
        .connect_device_internal(&info)
        .await
        .expect("connect should succeed");

    assert_eq!(
        display_name(&manager, &info.id).await.as_deref(),
        Some("ZWO 1"),
        "the placeholder must survive a driver that only echoed the device id"
    );

    crate::simulator::camera::get_sim_camera()
        .write()
        .await
        .status
        .connected = false;
}

/// The rig's hub dropout, on the simulators: both cameras come back at each
/// other's ids. The profile's camera must be found at its new id even though
/// that id last answered as the guide camera, and the guide camera must never
/// be accepted as the main camera.
#[tokio::test]
async fn expected_model_follows_a_camera_that_moved_ids() {
    use crate::simulator::camera::{
        reset_sim_camera_bus, unplug_sim_camera, SIM_GUIDE_CAMERA_ID, SIM_IMAGING_CAMERA_ID,
    };

    let _guard = simulator_singleton_test_lock().lock().await;
    reset_sim_camera_bus();
    let manager = build_device_manager();
    for id in [SIM_IMAGING_CAMERA_ID, SIM_GUIDE_CAMERA_ID] {
        manager
            .register_device(build_sim_info(id, DeviceType::Camera), false)
            .await;
    }
    manager
        .connect_device_expecting(SIM_IMAGING_CAMERA_ID, Some("Simulated Camera"))
        .await
        .expect("main camera connects");
    manager
        .connect_device_expecting(SIM_GUIDE_CAMERA_ID, Some("Simulated Guide Camera"))
        .await
        .expect("guide camera connects");

    unplug_sim_camera(SIM_IMAGING_CAMERA_ID, true).await;

    // The main camera's old id is now the guide camera: refused, by the
    // expectation the id carries from its first connect.
    let err = manager
        .connect_device(SIM_IMAGING_CAMERA_ID)
        .await
        .expect_err("the guide camera must not connect as the main camera");
    assert!(
        err.contains(crate::device_manager::identity::IDENTITY_CONFLICT_MARKER),
        "{err}"
    );
    assert!(err.contains("expected Simulated Camera"), "{err}");

    // Where the main camera went: the id last observed as the guide camera.
    manager
        .connect_device_expecting(SIM_GUIDE_CAMERA_ID, Some("Simulated Camera #1"))
        .await
        .expect("the main camera connects at its new id");
    assert_eq!(
        display_name(&manager, SIM_GUIDE_CAMERA_ID).await.as_deref(),
        Some("Simulated Camera")
    );

    // And the guide camera at the main camera's old id, once a caller asks
    // for the guide camera there.
    manager
        .connect_device_expecting(SIM_IMAGING_CAMERA_ID, Some("Simulated Guide Camera"))
        .await
        .expect("the guide camera connects at its new id");

    for id in [SIM_IMAGING_CAMERA_ID, SIM_GUIDE_CAMERA_ID] {
        let _ = manager.disconnect_device(id).await;
    }
    reset_sim_camera_bus();
}

/// Without an expectation, the id's last observation still guards it.
#[tokio::test]
async fn a_moved_camera_is_still_refused_without_an_expectation() {
    use crate::simulator::camera::{
        reset_sim_camera_bus, unplug_sim_camera, SIM_IMAGING_CAMERA_ID,
    };

    let _guard = simulator_singleton_test_lock().lock().await;
    reset_sim_camera_bus();
    let manager = build_device_manager();
    manager
        .register_device(
            build_sim_info(SIM_IMAGING_CAMERA_ID, DeviceType::Camera),
            false,
        )
        .await;
    manager
        .connect_device(SIM_IMAGING_CAMERA_ID)
        .await
        .expect("connects");
    unplug_sim_camera(SIM_IMAGING_CAMERA_ID, true).await;
    let err = manager
        .connect_device(SIM_IMAGING_CAMERA_ID)
        .await
        .expect_err("a different sensor at the id is refused");
    assert!(
        err.contains(crate::device_manager::identity::IDENTITY_CONFLICT_MARKER),
        "{err}"
    );
    let _ = manager.disconnect_device(SIM_IMAGING_CAMERA_ID).await;
    reset_sim_camera_bus();
}

#[tokio::test]
async fn a_vendor_filter_wheel_behind_its_handle_reports_model_and_serial() {
    use crate::device_manager::handle::DeviceHandle;
    use crate::device_manager::rig::filter_wheel::DriverFilterWheel;

    let manager = build_device_manager();
    let info = DeviceInfo {
        id: "native:zwo_efw:0".to_string(),
        name: "ZWO EFW 0".to_string(),
        device_type: DeviceType::FilterWheel,
        driver_type: DriverType::Native,
        description: "Native zwo driver".to_string(),
        driver_version: "Native".to_string(),
        serial_number: None,
        unique_id: None,
        display_name: "ZWO EFW 0".to_string(),
    };
    manager.register_device(info.clone(), false).await;
    manager.handles.insert(
        &info.id,
        DeviceHandle::FilterWheel(Arc::new(DriverFilterWheel::vendor(
            &info.id,
            Box::new(FakeIdentityDevice {
                id: info.id.clone(),
                model: "EFW".to_string(),
                serial: Some("0E0F0A01".to_string()),
            }),
        ))),
    );

    let identity = manager.probe_device_identity(&info).await;
    assert_eq!(identity.model.as_deref(), Some("EFW"));
    assert_eq!(identity.serial_number.as_deref(), Some("0E0F0A01"));
}

/// R1H2-2 (rig, Nov 8 2026: the camera came back at `native:zwo:0` after it
/// had been `native:zwo:1`): a reconnect refused at the old id finds the
/// device where it went, by serial or model, connects it there, and carries
/// what it held (the cooler) with it.
#[tokio::test]
async fn a_reconnect_refused_at_the_old_id_follows_the_camera_to_its_new_id() {
    use crate::simulator::camera::{
        reset_sim_camera_bus, unplug_sim_camera, SIM_GUIDE_CAMERA_ID, SIM_IMAGING_CAMERA_ID,
    };

    let _guard = simulator_singleton_test_lock().lock().await;
    reset_sim_camera_bus();
    crate::discovery::forget().await;
    let manager = build_device_manager();
    let info = build_sim_info(SIM_IMAGING_CAMERA_ID, DeviceType::Camera);
    manager.register_device(info.clone(), true).await;
    manager
        .connect_device_expecting(SIM_IMAGING_CAMERA_ID, Some("Simulated Camera"))
        .await
        .expect("the camera connects");
    manager
        .camera_set_cooler(SIM_IMAGING_CAMERA_ID, true, Some(-10.0))
        .await
        .expect("cooler on");

    unplug_sim_camera(SIM_IMAGING_CAMERA_ID, true).await;
    manager
        .mark_lost(SIM_IMAGING_CAMERA_ID, true, "the camera left the bus")
        .await;
    manager
        .attempt_reconnect(SIM_IMAGING_CAMERA_ID, &info)
        .await;

    assert!(
        manager.is_connected(SIM_GUIDE_CAMERA_ID).await,
        "the camera is reconnected at the id it moved to"
    );
    assert_eq!(
        display_name(&manager, SIM_GUIDE_CAMERA_ID).await.as_deref(),
        Some("Simulated Camera")
    );
    {
        let devices = manager.devices.read().await;
        assert!(
            !devices[SIM_IMAGING_CAMERA_ID].auto_reconnect,
            "the old id is not retried for the camera that left it"
        );
        assert_eq!(
            devices[SIM_GUIDE_CAMERA_ID].desired_cooler,
            Some((true, Some(-10.0)))
        );
    }

    for id in [SIM_IMAGING_CAMERA_ID, SIM_GUIDE_CAMERA_ID] {
        let _ = manager.disconnect_device(id).await;
    }
    reset_sim_camera_bus();
    crate::discovery::forget().await;
}

/// R1H2-2: two cameras behind one hub trade places. The main camera's body
/// now sits at the guide camera's id, which Skotiq knows as the guide
/// camera: that id is not reused for the main camera (its record, held
/// state and slot are the guide camera's). The main camera stays lost and
/// the operator is told where it is.
#[tokio::test]
async fn a_camera_that_traded_places_with_another_is_not_connected_at_its_id() {
    use crate::simulator::camera::{
        reset_sim_camera_bus, unplug_sim_camera, SIM_GUIDE_CAMERA_ID, SIM_IMAGING_CAMERA_ID,
    };

    let _guard = simulator_singleton_test_lock().lock().await;
    reset_sim_camera_bus();
    crate::discovery::forget().await;
    let manager = build_device_manager();
    for (id, model) in [
        (SIM_IMAGING_CAMERA_ID, "Simulated Camera"),
        (SIM_GUIDE_CAMERA_ID, "Simulated Guide Camera"),
    ] {
        manager
            .register_device(build_sim_info(id, DeviceType::Camera), true)
            .await;
        manager
            .connect_device_expecting(id, Some(model))
            .await
            .expect("connect");
    }
    unplug_sim_camera(SIM_IMAGING_CAMERA_ID, true).await;
    for id in [SIM_IMAGING_CAMERA_ID, SIM_GUIDE_CAMERA_ID] {
        manager.mark_lost(id, true, "the hub dropped").await;
    }
    let mut rx = manager.app_state.event_bus.subscribe();
    let info = build_sim_info(SIM_IMAGING_CAMERA_ID, DeviceType::Camera);
    manager
        .attempt_reconnect(SIM_IMAGING_CAMERA_ID, &info)
        .await;

    assert!(!manager.is_connected(SIM_IMAGING_CAMERA_ID).await);
    assert!(
        !manager.is_connected(SIM_GUIDE_CAMERA_ID).await,
        "the guide camera's id is not taken over by the main camera"
    );
    let mut told = false;
    while let Ok(event) = rx.try_recv() {
        if let crate::event::bus::EventPayload::System(
            crate::event::system::SystemEvent::Notification { message, .. },
        ) = &event.payload
        {
            told |= message.contains(SIM_GUIDE_CAMERA_ID);
        }
    }
    assert!(told, "the operator is told where the camera is");

    for id in [SIM_IMAGING_CAMERA_ID, SIM_GUIDE_CAMERA_ID] {
        let _ = manager.disconnect_device(id).await;
    }
    reset_sim_camera_bus();
    crate::discovery::forget().await;
}
