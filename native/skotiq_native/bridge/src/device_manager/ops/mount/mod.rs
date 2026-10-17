//! Mount operations dispatcher.
//!
//! Methods in this module are an additional impl block on `DeviceManager`
//! using Rust's split-impl-block feature. Behavior is identical to the
//! previous monolithic `devices.rs`.
//!
//! # `unwrap_or` policy
//!
//! Two patterns:
//!
//! * `availability.get(field).cloned().unwrap_or(FieldAvailability::Available)`
//!   — when ALTITUDE was probed earlier in the function, we mirror its
//!   availability onto AZIMUTH (they share a single ASCOM round-trip).
//!   `Available` is the safe default — both fields ARE available if the
//!   underlying probe succeeded; the only way the lookup misses is if
//!   the upstream code raced, in which case AZIMUTH appearing as
//!   "Available" matches the actual mount state.
//! * `mount.can_set_tracking().await.unwrap_or(false)` — ASCOM optional
//!   `CanSetTracking` probe; absence means "cannot set tracking rate",
//!   the safe assumption (UI hides the tracking-rate dropdown).

use crate::device::*;
use crate::device_manager::DeviceManager;
use crate::dispatch::DeviceOpError;
use crate::error::SkotiqError;
use crate::timeout_ops::{mount_slew_with_timeout, with_timeout_str, Timeouts};
#[cfg(windows)]
use skotiq_native::traits::NativeMount;
use std::collections::HashMap;
use tracing::warn;

pub(crate) mod park;
pub(crate) mod site;
pub(crate) mod slew;
pub(crate) mod status;
pub(crate) mod tracking;
#[cfg(test)]
mod sim_mount_tests {
    use crate::api::devices::simulation::{get_sim_mount, sim_singleton_test_lock, SimulatedMount};
    use crate::api::{get_device_manager, get_state};
    use crate::device::{DeviceInfo, DeviceType, DriverType, PierSide};
    use crate::storage::ObserverLocation;

    const TEST_LATITUDE: f64 = 40.0;

    async fn attach_sim_mount(device_id: &str) {
        let info = DeviceInfo {
            id: device_id.to_string(),
            name: "Simulated Mount".to_string(),
            device_type: DeviceType::Mount,
            driver_type: DriverType::Simulator,
            description: "Simulated mount".to_string(),
            driver_version: "1.0".to_string(),
            serial_number: None,
            unique_id: None,
            display_name: "Simulated Mount".to_string(),
        };
        get_device_manager().register_device(info, false).await;
        // The interpolation cell lives outside `SimulatedMount`, so resetting
        // the struct alone would leave the previous test's slew in flight and
        // this one's first command would be refused as "still moving".
        crate::api::devices::simulation::cancel_sim_slew().await;
        let mut mount = get_sim_mount().write().await;
        *mount = SimulatedMount::default();
        mount.status.connected = true;
    }

    fn set_site(longitude: f64) {
        get_state()
            .set_observer_location(Some(ObserverLocation {
                latitude: TEST_LATITUDE,
                longitude,
                elevation: 100.0,
            }))
            .expect("test site should be settable");
    }

    /// Longitude that puts `ra_hours` at the requested hour angle right now, so
    /// a test can place a target either side of the meridian without waiting for
    /// the sky to turn.
    fn longitude_for_hour_angle(ra_hours: f64, hour_angle_hours: f64) -> f64 {
        let now = chrono::Utc::now();
        let jd = skotiq_sequencer::meridian::julian_day(&now);
        let lst_at_greenwich = skotiq_sequencer::meridian::local_sidereal_time(jd, 0.0);
        let wanted_lst = ra_hours + hour_angle_hours;
        (((wanted_lst - lst_at_greenwich) * 15.0 + 180.0).rem_euclid(360.0)) - 180.0
    }

    async fn wait_for_slew_to_finish(device_id: &str) {
        let mgr = get_device_manager();
        for _ in 0..200 {
            if !mgr.mount_get_status(device_id).await.unwrap().slewing {
                return;
            }
            tokio::time::sleep(std::time::Duration::from_millis(25)).await;
        }
        panic!("simulated slew never finished");
    }

    /// The simulator set RA/Dec instantly and never raised `slewing`, so every
    /// wait-for-motion path in the app completed before the mount had
    /// "moved" — none of them could be exercised without hardware.
    #[tokio::test]
    async fn a_slew_reports_motion_and_converges_over_time() {
        let _serialized = sim_singleton_test_lock().lock().await;
        let device_id = "sim_mount_slewing";
        attach_sim_mount(device_id).await;
        set_site(-75.0);
        let mgr = get_device_manager();

        mgr.mount_slew(device_id, 6.0, 45.0).await.unwrap();
        let moving = mgr.mount_get_status(device_id).await.unwrap();
        assert!(
            moving.slewing,
            "the mount reported it was not slewing the instant a 45-degree slew was commanded"
        );
        assert!(
            (moving.declination - 45.0).abs() > 1e-6,
            "the mount teleported to the target declination instead of travelling to it"
        );

        wait_for_slew_to_finish(device_id).await;
        let arrived = mgr.mount_get_status(device_id).await.unwrap();
        // Arrives on the target of date: the simulator is a JNow mount.
        let (ra_now, dec_now) = crate::device_manager::epoch::j2000_to_jnow(6.0, 45.0);
        assert!((arrived.right_ascension - ra_now).abs() < 1e-6);
        assert!((arrived.declination - dec_now).abs() < 1e-6);
        assert!(!arrived.slewing);
    }

    /// Aborting has to stop the motion where it is, not let the interpolation
    /// carry on to the commanded target.
    #[tokio::test]
    async fn aborting_a_slew_stops_the_mount_short() {
        let _serialized = sim_singleton_test_lock().lock().await;
        let device_id = "sim_mount_abort_slew";
        attach_sim_mount(device_id).await;
        set_site(-75.0);
        let mgr = get_device_manager();

        mgr.mount_slew(device_id, 12.0, 80.0).await.unwrap();
        mgr.mount_abort(device_id).await.unwrap();
        let stopped = mgr.mount_get_status(device_id).await.unwrap();
        assert!(!stopped.slewing);

        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        let later = mgr.mount_get_status(device_id).await.unwrap();
        assert!(!later.slewing, "an aborted slew resumed on its own");
        assert!(
            (later.declination - 80.0).abs() > 1e-6,
            "an aborted slew still arrived at its target"
        );
    }

    /// Pier side is mechanical state. Tracking across the meridian does NOT
    /// flip a German equatorial, so the reported side must not change just
    /// because the sky moved — it was derived from RA and the clock, which made
    /// it change without the mount moving and made a real flip undetectable.
    #[tokio::test]
    async fn pier_side_is_mechanical_state_not_a_function_of_pointing() {
        let _serialized = sim_singleton_test_lock().lock().await;
        let device_id = "sim_mount_pier_side";
        attach_sim_mount(device_id).await;
        let mgr = get_device_manager();

        let target_ra = 5.5;
        set_site(longitude_for_hour_angle(target_ra, -1.0));
        mgr.mount_slew(device_id, target_ra, 30.0).await.unwrap();
        wait_for_slew_to_finish(device_id).await;
        let before = mgr
            .mount_get_status(device_id)
            .await
            .unwrap()
            .side_of_pier
            .unwrap();
        assert_ne!(before, PierSide::Unknown, "a slewed mount knows its side");

        // Two hours of sky rotation, expressed as longitude so the test does not
        // have to wait for it. The mount has not been commanded to move.
        set_site(longitude_for_hour_angle(target_ra, 1.0));
        let after_tracking = mgr
            .mount_get_status(device_id)
            .await
            .unwrap()
            .side_of_pier
            .unwrap();
        assert_eq!(
            after_tracking, before,
            "the mount changed pier side without being commanded to move"
        );

        // The flip: re-slew to the SAME coordinates, now past the meridian.
        mgr.mount_slew(device_id, target_ra, 30.0).await.unwrap();
        wait_for_slew_to_finish(device_id).await;
        let after_flip = mgr
            .mount_get_status(device_id)
            .await
            .unwrap()
            .side_of_pier
            .unwrap();
        assert_ne!(
            after_flip, before,
            "re-slewing past the meridian did not change the pier side, so \
             every simulated meridian flip fails its own verification"
        );
    }

    /// A parked mount points at the pole, so its altitude equals the site
    /// latitude and stays put. Leaving RA/Dec at the previous target reports
    /// the altitude of whatever it was last imaging, still tracking the sky.
    #[tokio::test]
    async fn parking_moves_the_mount_to_a_park_position() {
        let _serialized = sim_singleton_test_lock().lock().await;
        let device_id = "sim_mount_park";
        attach_sim_mount(device_id).await;
        set_site(-75.0);
        let mgr = get_device_manager();

        mgr.mount_slew(device_id, 5.5, 30.0).await.unwrap();
        wait_for_slew_to_finish(device_id).await;
        mgr.mount_park(device_id).await.unwrap();

        let parked = mgr.mount_get_status(device_id).await.unwrap();
        assert!(parked.parked && !parked.tracking && !parked.slewing);
        assert!(
            (parked.right_ascension - 5.5).abs() > 1e-6 || (parked.declination - 30.0).abs() > 1e-6,
            "park left the mount pointing at the target it had been imaging \
             (RA {:.4}h Dec {:.4})",
            parked.right_ascension,
            parked.declination
        );
        let altitude = parked.altitude.expect("a parked mount reports an altitude");
        assert!(
            (altitude - TEST_LATITUDE).abs() < 1e-6,
            "a parked German equatorial points at the pole, so its altitude is \
             the site latitude; got {altitude}"
        );

        tokio::time::sleep(std::time::Duration::from_millis(150)).await;
        let later = mgr
            .mount_get_status(device_id)
            .await
            .unwrap()
            .altitude
            .unwrap();
        assert!(
            (later - altitude).abs() < 1e-9,
            "a parked mount's altitude drifted with the sky ({altitude} -> {later})"
        );
    }

    /// The simulator advertised `can_set_tracking_rate: true` and reported a
    /// rate, then rejected every attempt to set one.
    #[tokio::test]
    async fn an_advertised_tracking_rate_can_actually_be_set() {
        let _serialized = sim_singleton_test_lock().lock().await;
        let device_id = "sim_mount_tracking_rate";
        attach_sim_mount(device_id).await;
        let mgr = get_device_manager();

        assert!(
            mgr.mount_get_status(device_id)
                .await
                .unwrap()
                .can_set_tracking_rate,
            "the simulator advertises the capability"
        );

        mgr.mount_set_tracking_rate(device_id, 1)
            .await
            .expect("a mount that advertises can_set_tracking_rate must accept one");
        assert_eq!(mgr.mount_get_tracking_rate(device_id).await.unwrap(), 1);
        assert_eq!(
            mgr.mount_get_status(device_id).await.unwrap().tracking_rate,
            Some(crate::device::TrackingRate::Lunar)
        );

        let err = mgr
            .mount_set_tracking_rate(device_id, 99)
            .await
            .expect_err("an out-of-range rate is a caller error");
        assert!(err.to_string().contains("Invalid tracking rate"));
    }
}
