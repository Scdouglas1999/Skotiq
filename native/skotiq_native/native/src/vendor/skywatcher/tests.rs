//! Driver logic that needs no wire. The sessions against a scripted motor
//! controller are in `serial_wire_tests`.

use super::*;

fn no_site() -> SiteSource {
    Arc::new(|| None)
}

fn eq6() -> Controller {
    let axis = AxisScale {
        zero: POWER_ON_STEP,
        counts: 9_024_000,
    };
    Controller {
        version: BoardVersion::parse("030700").unwrap(),
        ra: axis,
        dec: axis,
        timer_hz: [64_935, 64_935],
    }
}

/// indi-eqmod's step period for an EQ6 (64935 Hz timer, 9,024,000 steps per
/// turn) at the sidereal rate, and the guide rates on either side of it.
#[test]
fn step_periods_follow_the_gear_train() {
    let eq6 = eq6();
    assert_eq!(eq6.step_period(Axis::Ra, 1.0), 620);
    assert_eq!(eq6.step_period(Axis::Ra, -1.0), 620);
    assert_eq!(eq6.step_period(Axis::Ra, 1.5), 413);
    assert_eq!(eq6.step_period(Axis::Ra, 0.5), 1240);
    let lunar = eq6.step_period(Axis::Ra, sidereal_multiple(TrackingRate::Lunar));
    assert_eq!(lunar, 642);
    assert!((sidereal_multiple(TrackingRate::Sidereal) - 1.0).abs() < 1e-12);
}

#[test]
fn the_firmware_timer_corrections_of_indi_eqmod_apply() {
    let heq5_106 = BoardVersion::parse("010601").unwrap();
    assert_eq!(firmware_timer_hz(&heq5_106, 64_935), 0xFC80);
    let gt114 = BoardVersion::parse("020082").unwrap();
    assert_eq!(firmware_timer_hz(&gt114, 1), 0x20_5318);
    assert_eq!(
        firmware_timer_hz(&BoardVersion::parse("030723").unwrap(), 64_935),
        64_935
    );
}

#[test]
fn a_sync_offset_past_the_pole_folds_back() {
    let (ra, dec) = offset(23.5, 89.0, 1.0, 2.0);
    assert!((ra - 12.5).abs() < 1e-12 && (dec - 89.0).abs() < 1e-12);
    let (ra, dec) = offset(1.0, -10.0, -1.5, 0.5);
    assert!((ra - 23.5).abs() < 1e-12 && (dec + 9.5).abs() < 1e-12);
    assert!((hours_between(0.1, 23.9) - 0.2).abs() < 1e-12);
    assert!((hours_between(23.9, 0.1) + 0.2).abs() < 1e-12);
}

/// The UDP transport is declared but not implemented: connecting says so
/// and opens nothing. (A pseudo-terminal cannot stand in for it, so the
/// wire transcripts do not cover it.)
#[tokio::test]
async fn a_udp_mount_reports_not_supported_on_connect() {
    let mut mount = SkyWatcherMount::new_udp(None, None, no_site());
    assert_eq!(mount.id(), "native:skywatcher:192.168.4.1:11880");
    assert_eq!(mount.name(), "Sky-Watcher WiFi (192.168.4.1:11880)");
    assert!(matches!(
        mount.connect().await,
        Err(DriverError::NotSupported)
    ));
    assert!(!mount.is_connected());
    assert!(matches!(
        mount.get_coordinates().await,
        Err(DriverError::NotConnected)
    ));
    assert!(matches!(
        mount.get_tracking().await,
        Err(DriverError::NotConnected)
    ));
}
