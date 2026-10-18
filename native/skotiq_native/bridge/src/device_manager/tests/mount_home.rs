//! Mount FindHome through the device manager: the simulator's home motion, the
//! parked refusal every driver shares, and the unsupported answer for a mount
//! with no home command.

use super::*;
use crate::dispatch::error::DeviceOpError;
use crate::storage::ObserverLocation;

async fn register_mount(manager: &DeviceManager, device_id: &str, driver_type: DriverType) {
    manager.devices.write().await.insert(
        device_id.to_string(),
        ManagedDevice {
            info: build_mount_info(device_id, driver_type),
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

/// Put the simulated mount somewhere that is plainly not home: unparked,
/// tracking, pointing well away from either pole.
async fn connect_sim_mount_away_from_home() {
    crate::api::devices::simulation::cancel_sim_slew().await;
    let mount = crate::api::devices::simulation::get_sim_mount();
    let mut mount = mount.write().await;
    *mount = crate::api::devices::simulation::SimulatedMount::default();
    mount.status.connected = true;
    mount.status.parked = false;
    mount.status.tracking = true;
    mount.status.right_ascension = 5.0;
    mount.status.declination = 20.0;
}

async fn disconnect_sim_mount() {
    crate::api::devices::simulation::cancel_sim_slew().await;
    crate::api::devices::simulation::get_sim_mount()
        .write()
        .await
        .status
        .connected = false;
}

/// Run `body` with the observing site at `latitude`, then put the previous
/// site back so the hemisphere does not leak into other simulator tests.
async fn with_site_latitude<F, Fut>(latitude: f64, body: F)
where
    F: FnOnce() -> Fut,
    Fut: std::future::Future<Output = ()>,
{
    let state = crate::api::get_state();
    let previous = state.get_observer_location().ok().flatten();
    state
        .set_observer_location(Some(ObserverLocation {
            latitude,
            longitude: -75.0,
            elevation: 100.0,
        }))
        .expect("test site should be settable");
    body().await;
    state
        .set_observer_location(previous)
        .expect("previous site should be restorable");
}

/// Poll status (which is what advances the simulated motion) until the mount
/// reports idle.
async fn wait_until_idle(manager: &DeviceManager, device_id: &str) -> MountStatus {
    let mut status = manager.mount_get_status(device_id).await.unwrap();
    for _ in 0..200 {
        if !status.slewing {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
        status = manager.mount_get_status(device_id).await.unwrap();
    }
    assert!(!status.slewing, "the simulated home never finished");
    status
}

/// Home is a motion onto the pole with the counterweights down, it reports
/// AtHome only once it has arrived, it switches tracking off, and it leaves the
/// mount unparked and free to slew.
#[tokio::test]
async fn simulated_home_travels_to_the_pole_and_does_not_park() {
    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = build_device_manager();
    let device_id = "sim_mount_home_north";
    register_mount(&manager, device_id, DriverType::Simulator).await;

    with_site_latitude(40.0, || async {
        connect_sim_mount_away_from_home().await;

        manager
            .mount_find_home(device_id)
            .await
            .expect("an unparked simulated mount should accept FindHome");

        let moving = manager.mount_get_status(device_id).await.unwrap();
        assert!(moving.slewing, "home must be observable as motion");
        assert_eq!(
            moving.at_home,
            Some(false),
            "AtHome must not be claimed before the mount arrives"
        );
        assert!(!moving.tracking, "FindHome leaves tracking off");

        let homed = wait_until_idle(&manager, device_id).await;
        assert!((homed.declination - 90.0).abs() < 1e-9);
        assert_eq!(homed.at_home, Some(true));
        assert!(!homed.parked, "homing must never park the mount");
        assert!(!homed.tracking, "tracking stays off after homing");

        // Not parked means still commandable.
        manager
            .mount_slew(device_id, 6.0, 30.0)
            .await
            .expect("a homed mount must still accept a slew");
        let left_home = manager.mount_get_status(device_id).await.unwrap();
        assert_eq!(
            left_home.at_home,
            Some(false),
            "a slew carries the mount off its home position"
        );
        wait_until_idle(&manager, device_id).await;
    })
    .await;

    disconnect_sim_mount().await;
}

/// Counterweights down points the tube at the pole of the site's own
/// hemisphere.
#[tokio::test]
async fn simulated_home_uses_the_south_pole_for_a_southern_site() {
    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = build_device_manager();
    let device_id = "sim_mount_home_south";
    register_mount(&manager, device_id, DriverType::Simulator).await;

    with_site_latitude(-33.9, || async {
        connect_sim_mount_away_from_home().await;
        manager.mount_find_home(device_id).await.unwrap();
        let homed = wait_until_idle(&manager, device_id).await;
        assert!((homed.declination + 90.0).abs() < 1e-9);
        assert_eq!(homed.at_home, Some(true));
    })
    .await;

    disconnect_sim_mount().await;
}

/// A parked mount is refused, not silently unparked, and the refusal says what
/// to do.
#[tokio::test]
async fn a_parked_mount_is_refused_and_stays_parked() {
    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = build_device_manager();
    let device_id = "sim_mount_home_parked";
    register_mount(&manager, device_id, DriverType::Simulator).await;

    connect_sim_mount_away_from_home().await;
    crate::api::devices::simulation::get_sim_mount()
        .write()
        .await
        .status
        .parked = true;

    let err = manager
        .mount_find_home(device_id)
        .await
        .expect_err("a parked mount must not home");
    assert!(
        matches!(err, DeviceOpError::InvalidState { .. }),
        "parked is a state conflict, not a fault: {err:?}"
    );
    assert!(err.to_string().contains("Unpark it"), "{err}");

    let status = manager.mount_get_status(device_id).await.unwrap();
    assert!(status.parked, "the refusal must not unpark the mount");
    assert!(!status.slewing);
    assert_eq!(status.at_home, Some(false));

    // Over the FFI edge the refusal becomes `DeviceBusy`, which the headless
    // API answers with 409.
    assert!(matches!(
        crate::error::SkotiqError::from(err),
        crate::error::SkotiqError::DeviceBusy { .. }
    ));

    disconnect_sim_mount().await;
}

/// Abort slew stops a home part-way, and a home that never arrived does not
/// report AtHome.
#[tokio::test]
async fn abort_stops_a_home_in_progress() {
    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = build_device_manager();
    let device_id = "sim_mount_home_abort";
    register_mount(&manager, device_id, DriverType::Simulator).await;

    with_site_latitude(40.0, || async {
        connect_sim_mount_away_from_home().await;
        manager.mount_find_home(device_id).await.unwrap();
        manager
            .mount_abort(device_id)
            .await
            .expect("abort must reach a home in progress");

        let stopped = manager.mount_get_status(device_id).await.unwrap();
        assert!(!stopped.slewing);
        assert_eq!(stopped.at_home, Some(false));
        assert!(
            stopped.declination < 90.0,
            "an aborted home must stop short of the pole"
        );

        // And it stays stopped: the abandoned motion does not resume.
        tokio::time::sleep(std::time::Duration::from_millis(1200)).await;
        let later = manager.mount_get_status(device_id).await.unwrap();
        assert_eq!(later.at_home, Some(false));
        assert!((later.declination - stopped.declination).abs() < 1e-9);
    })
    .await;

    disconnect_sim_mount().await;
}

#[tokio::test]
async fn the_simulator_reports_that_it_can_home() {
    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = build_device_manager();
    let device_id = "sim_mount_home_capability";
    register_mount(&manager, device_id, DriverType::Simulator).await;
    connect_sim_mount_away_from_home().await;

    assert!(manager.mount_can_find_home(device_id).await.unwrap());

    disconnect_sim_mount().await;
}

/// A serial mount whose protocol has no home command answers "unsupported"
/// before anything is sent to it.
#[tokio::test]
async fn a_mount_without_a_home_command_is_unsupported() {
    let manager = build_device_manager();
    let device_id = "native:meade:TEST_PORT";
    register_mount(&manager, device_id, DriverType::Native).await;
    manager.native_mounts.write().await.insert(
        device_id.to_string(),
        Box::new(skotiq_native::vendor::lx200::Lx200Mount::new_meade(
            "TEST_PORT".to_string(),
        )),
    );

    assert!(!manager.mount_can_find_home(device_id).await.unwrap());
    let err = manager
        .mount_find_home(device_id)
        .await
        .expect_err("a Meade mount has no home");
    assert!(
        matches!(err, DeviceOpError::Unsupported { .. }),
        "expected an unsupported refusal, got {err:?}"
    );
    assert!(err.to_string().contains("cannot find home"), "{err}");
}
