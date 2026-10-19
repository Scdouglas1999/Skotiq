//! Set park through the device manager: the simulator stores the pose and
//! parks on it, a moving mount is refused, and a mount whose protocol has no
//! set-park command answers unsupported.

use super::mount_home::{
    connect_sim_mount_away_from_home, disconnect_sim_mount, register_mount, wait_until_idle,
    with_site_latitude,
};
use super::*;
use crate::dispatch::error::DeviceOpError;

/// Set park stores where the mount is pointing; a later park goes there, not
/// to the default pole pose, and home stays on the pole.
#[tokio::test]
async fn simulated_set_park_moves_the_park_position_but_not_home() {
    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = build_device_manager();
    let device_id = "sim_mount_set_park";
    register_mount(&manager, device_id, DriverType::Simulator).await;

    with_site_latitude(40.0, || async {
        connect_sim_mount_away_from_home().await;
        assert!(manager.mount_can_set_park(device_id).await.unwrap());

        manager
            .mount_set_park(device_id)
            .await
            .expect("an idle simulated mount should accept Set park");
        let stored = manager.mount_get_status(device_id).await.unwrap();
        assert!(!stored.parked, "setting park must not park the mount");
        assert!(!stored.slewing, "setting park must not move the mount");

        manager.mount_slew(device_id, 12.0, -10.0).await.unwrap();
        wait_until_idle(&manager, device_id).await;
        manager.mount_park(device_id).await.unwrap();
        let parked = manager.mount_get_status(device_id).await.unwrap();
        assert!(parked.parked);
        assert!(
            (parked.declination - 20.0).abs() < 1e-9,
            "park must land on the stored declination, got {}",
            parked.declination
        );
        // Stored as an hour angle, so the RA follows the sky by the seconds
        // the test took, never by hours.
        let ra_drift = ((parked.right_ascension - 5.0 + 12.0).rem_euclid(24.0) - 12.0).abs();
        assert!(ra_drift < 0.01, "park RA drifted by {ra_drift} h");

        manager.mount_unpark(device_id).await.unwrap();
        manager.mount_find_home(device_id).await.unwrap();
        let homed = wait_until_idle(&manager, device_id).await;
        assert!(
            (homed.declination - 90.0).abs() < 1e-9,
            "Set park must not move home"
        );
    })
    .await;

    crate::api::devices::simulation::clear_sim_park_position();
    disconnect_sim_mount().await;
}

/// A position read mid-slew is not one the operator chose.
#[tokio::test]
async fn set_park_is_refused_while_the_mount_moves() {
    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = build_device_manager();
    let device_id = "sim_mount_set_park_moving";
    register_mount(&manager, device_id, DriverType::Simulator).await;

    with_site_latitude(40.0, || async {
        connect_sim_mount_away_from_home().await;
        manager.mount_slew(device_id, 15.0, 60.0).await.unwrap();
        let err = manager
            .mount_set_park(device_id)
            .await
            .expect_err("a slewing mount must not set park");
        assert!(
            matches!(err, DeviceOpError::InvalidState { .. }),
            "moving is a state conflict: {err:?}"
        );
        wait_until_idle(&manager, device_id).await;
    })
    .await;

    crate::api::devices::simulation::clear_sim_park_position();
    disconnect_sim_mount().await;
}

/// A Meade mount has no set-park command and says so before anything is sent.
#[tokio::test]
async fn a_mount_without_set_park_is_unsupported() {
    let manager = build_device_manager();
    let device_id = "native:meade:TEST_PORT_SETPARK";
    register_mount(&manager, device_id, DriverType::Native).await;
    manager.native_mounts.write().await.insert(
        device_id.to_string(),
        Box::new(skotiq_native::vendor::lx200::Lx200Mount::new_meade(
            "TEST_PORT_SETPARK".to_string(),
        )),
    );

    assert!(!manager.mount_can_set_park(device_id).await.unwrap());
    let err = manager
        .mount_set_park(device_id)
        .await
        .expect_err("a Meade mount cannot set park");
    assert!(
        matches!(err, DeviceOpError::Unsupported { .. }),
        "expected an unsupported refusal, got {err:?}"
    );
    assert!(err.to_string().contains("cannot set its park"), "{err}");
}
