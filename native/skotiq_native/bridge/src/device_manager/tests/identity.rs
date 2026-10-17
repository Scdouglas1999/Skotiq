use super::*;

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
        manager.get_device_display_name(&info.id).await.as_deref(),
        Some("ZWO ASI1600MM-Cool"),
        "the driver's own name must replace the id-derived placeholder"
    );

    crate::api::devices::simulation::get_sim_camera()
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
        .expect_err("a swapped camera must not connect");

    assert!(
        err.contains("no longer the same hardware"),
        "error should name the cause, got: {err}"
    );
    assert!(
        err.contains("ZWO ASI1600MM-Cool") && err.contains("ZWO ASI178MM"),
        "error should name both cameras so the operator can see the swap, got: {err}"
    );

    crate::api::devices::simulation::get_sim_camera()
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

    crate::api::devices::simulation::get_sim_camera()
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
        .expect_err("a swapped camera must not connect");

    assert_ne!(
        err,
        crate::device_manager::connection::RECONNECT_CANCELED_MSG,
        "nobody canceled anything; the swap must not be reported as a user disconnect"
    );
    assert!(
        err.contains("ZWO ASI1600MM-Cool") && err.contains("ZWO ASI178MM"),
        "the reconnect error must still name both cameras, got: {err}"
    );

    crate::api::devices::simulation::get_sim_camera()
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
        manager.get_device_display_name(&info.id).await.as_deref(),
        Some("ZWO 1"),
        "the placeholder must survive a driver that only echoed the device id"
    );

    crate::api::devices::simulation::get_sim_camera()
        .write()
        .await
        .status
        .connected = false;
}
