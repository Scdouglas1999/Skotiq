//! Every `ITelescopeV4` member Skotiq's Alpaca client carries, driven against
//! the ASCOM Alpaca simulator (OmniSim), an independent device server, with
//! the ConformU rules for each member as the assertions.
//!
//! Ignored by default: it needs a running OmniSim. Point
//! `SKOTIQ_OMNISIM_URL` at it (`http://127.0.0.1:32330`) and run
//! `cargo test -p skotiq_alpaca --test omnisim_telescope -- --ignored --nocapture`
//! from a process that can reach that address. The test moves the simulated
//! mount and restores its site, park and tracking state as far as it can.

use skotiq_alpaca::{AlignmentMode, AlpacaError, AlpacaTelescope, DriveRate, PierSide, TelescopeAxis};
use std::future::Future;
use std::time::{Duration, Instant};

const SLEW_LIMIT: Duration = Duration::from_secs(120);

fn telescope() -> Option<AlpacaTelescope> {
    let url = std::env::var("SKOTIQ_OMNISIM_URL").ok()?;
    Some(AlpacaTelescope::from_server(&url, 0))
}

fn ascom_number(error: &AlpacaError) -> Option<i32> {
    match error {
        AlpacaError::DeviceError { code, .. } => Some(*code),
        _ => None,
    }
}

async fn wait_until<F, Fut>(what: &str, limit: Duration, mut done: F)
where
    F: FnMut() -> Fut,
    Fut: Future<Output = bool>,
{
    let start = Instant::now();
    while !done().await {
        assert!(start.elapsed() < limit, "{what} did not happen within {limit:?}");
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    println!("  {what} after {:.1} s", start.elapsed().as_secs_f64());
}

async fn wait_for_slew_end(t: &AlpacaTelescope, what: &str) {
    wait_until(what, SLEW_LIMIT, || async {
        !t.slewing().await.expect("Slewing")
    })
    .await;
}

fn hours_apart(a: f64, b: f64) -> f64 {
    let d = (a - b).rem_euclid(24.0);
    d.min(24.0 - d)
}

#[tokio::test]
#[ignore = "needs OmniSim at SKOTIQ_OMNISIM_URL"]
async fn every_telescope_member_against_omnisim() {
    let Some(t) = telescope() else {
        panic!("set SKOTIQ_OMNISIM_URL to the OmniSim base URL");
    };

    println!("connect");
    t.connect().await.expect("Connected=true");
    assert!(t.is_connected().await.expect("Connected"));
    assert!(t.validate_connection().await.expect("quick Connected read"));
    t.heartbeat().await.expect("heartbeat");

    println!("common members");
    let version = t.interface_version().await.expect("InterfaceVersion");
    assert!(version >= 3, "OmniSim is ITelescopeV3 or later, got {version}");
    assert!(!t.name().await.expect("Name").is_empty());
    t.description().await.expect("Description");
    t.driver_info().await.expect("DriverInfo");
    t.driver_version().await.expect("DriverVersion");
    t.supported_actions().await.expect("SupportedActions");

    println!("frame and optics");
    let system = t.equatorial_system().await.expect("EquatorialSystem");
    assert!((0..=4).contains(&system), "EquatorialSystem {system}");
    let alignment = AlignmentMode::from(t.alignment_mode().await.expect("AlignmentMode"));
    println!("  EquatorialSystem {system}, AlignmentMode {alignment:?}");
    let optics = t.get_optics_info().await.expect("optics aggregate");
    assert_eq!(optics.alignment_mode, alignment);
    t.focal_length().await.expect("FocalLength");
    t.aperture_diameter().await.expect("ApertureDiameter");
    t.aperture_area().await.expect("ApertureArea");

    let caps = t.get_capabilities().await.expect("capability aggregate");
    let can_set_pier_side = t.can_set_pier_side().await.expect("CanSetPierSide");
    println!("  {caps:?}");
    for axis in 0..=2 {
        let can = t.can_move_axis(axis).await.expect("CanMoveAxis");
        if can && axis < 2 {
            let rates = t
                .axis_rates(if axis == 0 { TelescopeAxis::Primary } else { TelescopeAxis::Secondary })
                .await
                .expect("AxisRates");
            assert!(!rates.is_empty(), "a movable axis lists its rates");
            assert!(rates.iter().all(|r| r.minimum <= r.maximum && r.minimum >= 0.0));
        }
    }
    t.can_set_right_ascension_rate().await.expect("CanSetRightAscensionRate");
    t.can_set_declination_rate().await.expect("CanSetDeclinationRate");

    println!("unpark");
    if t.at_park().await.expect("AtPark") {
        t.unpark().await.expect("Unpark");
        wait_until("unparked", SLEW_LIMIT, || async {
            !t.at_park().await.expect("AtPark") && !t.slewing().await.expect("Slewing")
        })
        .await;
    }

    println!("site and clock");
    let site = t.get_site_info().await.expect("site aggregate");
    t.set_site_latitude(site.site_latitude).await.expect("SiteLatitude=");
    t.set_site_longitude(site.site_longitude).await.expect("SiteLongitude=");
    t.set_site_elevation(site.site_elevation).await.expect("SiteElevation=");
    assert!((t.site_latitude().await.expect("SiteLatitude") - site.site_latitude).abs() < 1e-9);
    let err = t
        .set_site_latitude(91.0)
        .await
        .expect_err("a latitude past the pole is refused");
    assert_eq!(ascom_number(&err), Some(0x401), "InvalidValue: {err}");
    let clock = t.utc_date().await.expect("UTCDate");
    let parsed = chrono::DateTime::parse_from_rfc3339(&clock).expect("UTCDate is ISO 8601");
    assert!((parsed.timestamp() - chrono::Utc::now().timestamp()).abs() < 120);
    let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
    t.set_utc_date(&now).await.expect("UTCDate=");
    let sidereal = t.sidereal_time().await.expect("SiderealTime");
    assert!((0.0..24.0).contains(&sidereal));
    let refraction = t.does_refraction().await.expect("DoesRefraction");
    t.set_does_refraction(refraction).await.expect("DoesRefraction=");

    println!("tracking");
    t.set_tracking(true).await.expect("Tracking=true");
    assert!(t.tracking().await.expect("Tracking"));
    let rates = t.tracking_rates().await.expect("TrackingRates");
    assert!(rates.contains(&DriveRate::Sidereal), "{rates:?}");
    for rate in &rates {
        t.set_tracking_rate(*rate).await.expect("TrackingRate=");
        assert_eq!(t.tracking_rate().await.expect("TrackingRate"), *rate);
    }
    t.set_tracking_rate(DriveRate::Sidereal).await.expect("TrackingRate=Sidereal");

    println!("guide rates");
    let ra_rate = t.guide_rate_right_ascension().await.expect("GuideRateRightAscension");
    let dec_rate = t.guide_rate_declination().await.expect("GuideRateDeclination");
    assert!(ra_rate > 0.0 && ra_rate < 0.05, "degrees per second: {ra_rate}");
    if caps.can_set_guide_rates {
        t.set_guide_rate_right_ascension(ra_rate).await.expect("GuideRateRightAscension=");
        t.set_guide_rate_declination(dec_rate).await.expect("GuideRateDeclination=");
    }

    println!("slew to coordinates (async)");
    let ra = (sidereal - 2.0).rem_euclid(24.0);
    let dec = 40.0;
    let predicted = t.destination_side_of_pier(ra, dec).await.expect("DestinationSideOfPier");
    t.slew_to_coordinates_async(ra, dec).await.expect("SlewToCoordinatesAsync");
    assert!(t.slewing().await.expect("Slewing"), "Slewing is true at once after an async slew");
    wait_for_slew_end(&t, "slew finished").await;
    let (got_ra, got_dec) = (
        t.right_ascension().await.expect("RightAscension"),
        t.declination().await.expect("Declination"),
    );
    assert!(hours_apart(got_ra, ra) * 15.0 * 60.0 < 1.0, "RA {got_ra} vs {ra}");
    assert!((got_dec - dec).abs() * 60.0 < 1.0, "Dec {got_dec} vs {dec}");
    assert!((t.target_right_ascension().await.expect("TargetRightAscension") - ra).abs() < 1e-6);
    assert!((t.target_declination().await.expect("TargetDeclination") - dec).abs() < 1e-6);
    let side = t.side_of_pier().await.expect("SideOfPier");
    assert_ne!(side, PierSide::Unknown);
    assert_eq!(side, predicted, "DestinationSideOfPier predicted the side the slew landed on");
    let status = t.get_full_status().await.expect("full status aggregate");
    assert!(status.tracking && !status.slewing);
    t.get_status().await.expect("status aggregate");
    t.altitude().await.expect("Altitude");
    t.azimuth().await.expect("Azimuth");
    assert!(!t.at_home().await.expect("AtHome"), "a slew clears AtHome");

    println!("synchronous slew");
    t.slew_to_coordinates((ra + 0.2).rem_euclid(24.0), dec)
        .await
        .expect("SlewToCoordinates");
    assert!(!t.slewing().await.expect("Slewing"), "a synchronous slew returns when done");

    println!("slew to target and abort");
    t.set_target_right_ascension((ra + 1.0).rem_euclid(24.0))
        .await
        .expect("TargetRightAscension=");
    t.set_target_declination(10.0).await.expect("TargetDeclination=");
    t.slew_to_target_async().await.expect("SlewToTargetAsync");
    tokio::time::sleep(Duration::from_millis(500)).await;
    t.abort_slew().await.expect("AbortSlew");
    wait_for_slew_end(&t, "abort stopped the slew").await;
    t.slew_to_target().await.expect("SlewToTarget");

    println!("sync");
    t.sync_to_coordinates(ra, dec).await.expect("SyncToCoordinates");
    assert!(hours_apart(t.right_ascension().await.expect("RightAscension"), ra) * 15.0 * 60.0 < 1.0);
    t.set_target_right_ascension(ra).await.expect("TargetRightAscension=");
    t.set_target_declination(dec).await.expect("TargetDeclination=");
    t.sync_to_target().await.expect("SyncToTarget");
    t.set_tracking(false).await.expect("Tracking=false");
    let err = t
        .sync_to_coordinates(ra, dec)
        .await
        .expect_err("ConformU: SyncToCoordinates needs tracking on");
    assert_eq!(ascom_number(&err), Some(0x40B), "InvalidOperation: {err}");
    let err = t
        .slew_to_coordinates_async(ra, dec)
        .await
        .expect_err("ConformU: SlewToCoordinatesAsync needs tracking on");
    assert_eq!(ascom_number(&err), Some(0x40B), "InvalidOperation: {err}");
    let err = t
        .slew_to_coordinates_async(ra, 95.0)
        .await
        .expect_err("a declination past the pole is refused");
    assert!(matches!(ascom_number(&err), Some(0x401) | Some(0x40B)), "{err}");

    println!("alt/az");
    if caps.can_slew_alt_az_async {
        t.slew_to_alt_az_async(45.0, 120.0).await.expect("SlewToAltAzAsync");
        wait_for_slew_end(&t, "alt/az slew finished").await;
        assert!((t.altitude().await.expect("Altitude") - 45.0).abs() < 0.1);
        assert!((t.azimuth().await.expect("Azimuth") - 120.0).abs() < 0.1);
    }
    if caps.can_slew_alt_az {
        t.slew_to_alt_az(50.0, 130.0).await.expect("SlewToAltAz");
    }
    if caps.can_sync_alt_az {
        t.sync_to_alt_az(50.0, 130.0).await.expect("SyncToAltAz");
    }

    println!("move axis");
    t.set_tracking(true).await.expect("Tracking=true");
    let rate = t.axis_rates(TelescopeAxis::Primary).await.expect("AxisRates")[0].maximum.min(1.0);
    t.move_axis(0, rate).await.expect("MoveAxis(Primary)");
    assert!(t.slewing().await.expect("Slewing"), "Slewing is true while an axis moves");
    tokio::time::sleep(Duration::from_millis(500)).await;
    t.move_axis(0, 0.0).await.expect("MoveAxis(Primary, 0)");
    wait_for_slew_end(&t, "axis stopped").await;
    assert!(t.tracking().await.expect("Tracking"), "tracking resumes after MoveAxis(0)");
    let err = t.move_axis(1, 1.0e6).await.expect_err("a rate outside AxisRates is refused");
    assert_eq!(ascom_number(&err), Some(0x401), "InvalidValue: {err}");

    println!("pulse guide");
    t.pulse_guide(0, 1000).await.expect("PulseGuide North");
    let started = Instant::now();
    assert!(
        t.is_pulse_guiding().await.expect("IsPulseGuiding"),
        "ITelescopeV4 PulseGuide is asynchronous"
    );
    wait_until("pulse ended", Duration::from_secs(5), || async {
        !t.is_pulse_guiding().await.expect("IsPulseGuiding")
    })
    .await;
    assert!(started.elapsed() >= Duration::from_millis(700), "the pulse ran for its length");
    t.pulse_guide(2, 300).await.expect("PulseGuide East");
    t.pulse_guide(1, 300).await.expect("PulseGuide South, both axes at once");

    println!("side of pier");
    if can_set_pier_side {
        let before = t.side_of_pier().await.expect("SideOfPier");
        let other = if before == PierSide::East { PierSide::West } else { PierSide::East };
        // Whether the mount can reach the other side from here depends on its
        // meridian limits; the write is accepted and the mount comes to rest.
        t.set_side_of_pier(other).await.expect("SideOfPier=");
        tokio::time::sleep(Duration::from_millis(500)).await;
        wait_for_slew_end(&t, "pier flip settled").await;
        let after = t.side_of_pier().await.expect("SideOfPier");
        assert_ne!(after, PierSide::Unknown);
        println!("  SideOfPier {before:?} -> asked {other:?} -> {after:?}");
    }

    println!("home");
    if caps.can_find_home {
        t.find_home().await.expect("FindHome");
        wait_until("homed", SLEW_LIMIT, || async {
            !t.slewing().await.expect("Slewing") && t.at_home().await.expect("AtHome")
        })
        .await;
        assert!(!t.at_park().await.expect("AtPark"), "FindHome does not park");
    }

    println!("park");
    if caps.can_set_park {
        t.set_park().await.expect("SetPark");
    }
    t.park().await.expect("Park");
    wait_until("parked", SLEW_LIMIT, || async {
        t.at_park().await.expect("AtPark") && !t.slewing().await.expect("Slewing")
    })
    .await;
    assert!(!t.tracking().await.expect("Tracking"), "a parked mount does not track");
    t.park().await.expect("a second Park is harmless");
    let err = t
        .slew_to_coordinates_async(ra, dec)
        .await
        .expect_err("a parked mount refuses a slew");
    assert_eq!(ascom_number(&err), Some(0x408), "Parked: {err}");
    let err = t.abort_slew().await.expect_err("AbortSlew while parked");
    assert_eq!(ascom_number(&err), Some(0x408), "Parked: {err}");
    let err = t.pulse_guide(0, 100).await.expect_err("PulseGuide while parked");
    assert_eq!(ascom_number(&err), Some(0x408), "Parked: {err}");
    t.unpark().await.expect("Unpark");
    wait_until("unparked", SLEW_LIMIT, || async {
        !t.at_park().await.expect("AtPark") && !t.slewing().await.expect("Slewing")
    })
    .await;
    t.unpark().await.expect("a second Unpark is harmless");

    println!("disconnect");
    t.disconnect().await.expect("Connected=false");
    assert!(!t.is_connected().await.expect("Connected"));
    // OmniSim keeps answering reads while disconnected; a driver that refuses
    // them must say NotConnected.
    if let Err(err) = t.right_ascension().await {
        assert_eq!(ascom_number(&err), Some(0x407), "NotConnected: {err}");
    }
}
