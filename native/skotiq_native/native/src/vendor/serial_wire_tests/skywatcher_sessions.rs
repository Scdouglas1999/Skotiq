//! Sky-Watcher sessions beyond the shared one: where gotos land, the passes
//! that finish them, the southern hemisphere, lost replies, and the mounts
//! and sites the driver refuses.

use super::fakes::{self, Knobs, SYNSCAN_COUNTS, SYNSCAN_POWER_ON};
use super::{check_transcript, FakeMount};
use crate::vendor::skywatcher::SkyWatcherMount;
use chrono::{DateTime, TimeZone, Utc};
use skotiq_device::*;
use std::sync::atomic::Ordering;
use std::sync::Arc;

/// The instant every session runs at, so the sidereal time and with it the
/// motor positions are the same on every run.
pub(super) fn session_clock() -> DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 11, 12, 3, 0, 0).unwrap()
}

pub(super) fn philadelphia() -> SiteSource {
    site(40.007714, -75.397448)
}

fn sydney() -> SiteSource {
    site(-33.86, 151.21)
}

fn site(latitude_deg: f64, longitude_deg: f64) -> SiteSource {
    Arc::new(move || {
        Some(MountSiteInfo {
            latitude_deg,
            longitude_deg,
            elevation_m: None,
        })
    })
}

async fn connected(fake: &FakeMount, site: SiteSource) -> SkyWatcherMount {
    let mut mount =
        SkyWatcherMount::new_serial(fake.path.clone(), None, site).with_clock(session_clock);
    mount
        .connect()
        .await
        .expect("connect to the fake motor controller");
    mount
}

async fn finish_goto(mount: &SkyWatcherMount) {
    for _ in 0..20 {
        if !mount.is_slewing().await.expect("slew state") {
            return;
        }
    }
    panic!("the goto never ended");
}

/// RA hours, Dec degrees, RA and Dec motor positions, side of the pier.
type Landing = (f64, f64, u32, u32, PierSide);

/// Targets on both sides of the meridian, beside the pole, near the
/// horizon and at the opposite pole, one after the other from the power-on
/// position. Each goto must leave the motors exactly where indi-eqmod's
/// formulas put that target (computed for the session's sidereal time,
/// 1.3910 h in Philadelphia and 16.4982 h in Sydney) and read back as the
/// target from the side of the pier indi-eqmod chose.
#[tokio::test]
async fn skywatcher_gotos_land_where_indi_eqmod_points() {
    #[rustfmt::skip]
    let cases: [(SiteSource, &[Landing]); 2] = [
        (philadelphia(), &[
            (1.411035909, 30.0, 10637088, 9140608, PierSide::West),   // just east of the meridian
            (1.371035909, 30.0, 6140128, 12148608, PierSide::East),   // just west of it: flipped
            (4.391035909, 89.95, 9516608, 10643355, PierSide::West),  // beside the pole, east
            (22.391035909, 89.95, 7260608, 10645861, PierSide::East), // beside the pole, west
            (6.891035909, -20.0, 8576608, 7887275, PierSide::West),   // low in the east
            (19.491035909, 0.0, 8351008, 12900608, PierSide::East),   // low in the west
            (1.401035909, -89.9, 10640848, 6135115, PierSide::West),  // the other pole
        ]),
        (sydney(), &[
            (16.518199109, 30.0, 6140128, 13652608, PierSide::West),
            (16.478199109, 30.0, 10637088, 7636608, PierSide::East),
            (19.498199109, 89.95, 7260608, 15155355, PierSide::West),
            (13.498199109, 89.95, 9516608, 6133861, PierSide::East),
            (21.998199109, -20.0, 8200608, 12399275, PierSide::West),
            (10.598199109, 0.0, 8426208, 8388608, PierSide::East),
            (16.508199109, -89.9, 6136368, 10647115, PierSide::West),
        ]),
    ];
    for (site, targets) in cases {
        let knobs = Arc::new(Knobs::default());
        let fake = FakeMount::spawn(b'\r', fakes::synscan(None, knobs.clone()));
        let mut mount = connected(&fake, site).await;
        assert_eq!(
            *knobs.positions.lock().unwrap(),
            [SYNSCAN_POWER_ON, SYNSCAN_POWER_ON + SYNSCAN_COUNTS / 4],
            "initialization puts the Dec counter at the pole"
        );
        for &(ra, dec, ra_step, dec_step, pier) in targets {
            mount.slew_to_coordinates(ra, dec).await.expect("goto");
            finish_goto(&mount).await;
            let [at_ra, at_dec] = *knobs.positions.lock().unwrap();
            assert!(
                at_ra.abs_diff(ra_step) <= 1 && at_dec.abs_diff(dec_step) <= 1,
                "RA {ra} Dec {dec}: motors at {at_ra}, {at_dec}; indi-eqmod puts them at {ra_step}, {dec_step}"
            );
            assert_eq!(
                mount.get_side_of_pier().await.unwrap(),
                pier,
                "RA {ra} Dec {dec}"
            );
            let (back_ra, back_dec) = mount.get_coordinates().await.unwrap();
            let ra_error = ((back_ra - ra + 12.0).rem_euclid(24.0) - 12.0).abs() * 54_000.0;
            assert!(
                ra_error < 1.0 && (back_dec - dec).abs() * 3600.0 < 1.0,
                "RA {ra} Dec {dec} read back as {back_ra}, {back_dec}"
            );
        }
        mount.disconnect().await.unwrap();
    }
}

/// A goto that stops short (the sky turned, or the gears slipped) gets a
/// second, low-speed pass, and tracking starts once it is done.
#[tokio::test]
async fn skywatcher_goto_takes_a_second_pass() {
    let knobs = Arc::new(Knobs::default());
    let fake = FakeMount::spawn(b'\r', fakes::synscan(None, knobs.clone()));
    let mut mount = connected(&fake, philadelphia()).await;
    let _ = step!(fake, "set_tracking(true)", mount.set_tracking(true).await);
    knobs.goto_shortfall.store(2000, Ordering::SeqCst);
    let _ = step!(
        fake,
        "slew_to_coordinates(4.0, 45.0) [lands 2000 steps short]",
        mount.slew_to_coordinates(4.0, 45.0).await
    );
    knobs.goto_shortfall.store(0, Ordering::SeqCst);
    for _ in 0..4 {
        let _ = step!(fake, "is_slewing", mount.is_slewing().await);
    }
    let _ = step!(fake, "get_tracking", mount.get_tracking().await);
    let _ = step!(fake, "get_coordinates", mount.get_coordinates().await);
    check_transcript("skywatcher_goto_second_pass", &fake.lines());
}

/// A controller another program initialized, in the southern hemisphere:
/// the counters are left alone, tracking and the RA guide pulses run
/// backward, and guiding without tracking moves the axis and stops it.
#[tokio::test]
async fn skywatcher_southern_session() {
    let knobs = Arc::new(Knobs::default());
    let fake = FakeMount::spawn(b'\r', fakes::synscan_initialized(knobs.clone()));
    let mut mount =
        SkyWatcherMount::new_serial(fake.path.clone(), None, sydney()).with_clock(session_clock);
    let _ = step!(fake, "connect", mount.connect().await);
    let _ = step!(fake, "get_coordinates", mount.get_coordinates().await);
    let _ = step!(fake, "set_tracking(true)", mount.set_tracking(true).await);
    for direction in [
        GuideDirection::East,
        GuideDirection::West,
        GuideDirection::North,
        GuideDirection::South,
    ] {
        let _ = step!(
            fake,
            format!("pulse_guide({direction:?}, 20)"),
            mount.pulse_guide(direction, 20).await
        );
    }
    let _ = step!(
        fake,
        "set_tracking_rate(Lunar)",
        mount.set_tracking_rate(TrackingRate::Lunar).await
    );
    let _ = step!(fake, "set_tracking(false)", mount.set_tracking(false).await);
    for direction in [GuideDirection::East, GuideDirection::West] {
        let _ = step!(
            fake,
            format!("pulse_guide({direction:?}, 20) [not tracking]"),
            mount.pulse_guide(direction, 20).await
        );
    }
    let _ = step!(
        fake,
        "slew_to_coordinates(18.0, -60.0)",
        mount.slew_to_coordinates(18.0, -60.0).await
    );
    let _ = step!(
        fake,
        "pulse_guide(North, 20) [during the goto]",
        mount.pulse_guide(GuideDirection::North, 20).await
    );
    let _ = step!(fake, "abort_slew", mount.abort_slew().await);
    let _ = step!(fake, "is_slewing", mount.is_slewing().await);
    let _ = step!(fake, "get_side_of_pier", mount.get_side_of_pier().await);
    let _ = step!(fake, "disconnect", mount.disconnect().await);
    check_transcript("skywatcher_southern_session", &fake.lines());
}

/// A reply that never comes is asked for again, and a controller that
/// echoes every command (the DC-motor boards) still reads right.
#[tokio::test]
async fn skywatcher_retries_a_lost_reply_and_skips_echoes() {
    let knobs = Arc::new(Knobs::default());
    knobs.echo.store(true, Ordering::SeqCst);
    let fake = FakeMount::spawn(b'\r', fakes::synscan(None, knobs.clone()));
    let mut mount = SkyWatcherMount::new_serial(fake.path.clone(), None, philadelphia())
        .with_clock(session_clock);
    let _ = step!(fake, "connect [echoing controller]", mount.connect().await);
    knobs.echo.store(false, Ordering::SeqCst);
    knobs.swallow_replies.store(1, Ordering::SeqCst);
    let _ = step!(
        fake,
        "get_coordinates [first reply lost]",
        mount.get_coordinates().await
    );
    knobs.swallow_replies.store(3, Ordering::SeqCst);
    let _ = step!(
        fake,
        "get_tracking [every reply lost]",
        mount.get_tracking().await
    );
    check_transcript("skywatcher_retry_and_echo", &fake.lines());
}

/// What the driver will not do: drive an alt-azimuth GoTo base, or point
/// without an observing site.
#[tokio::test]
async fn skywatcher_refuses_an_alt_azimuth_mount_and_a_missing_site() {
    let gt = FakeMount::spawn(
        b'\r',
        Box::new(|command, _| {
            if command.starts_with(b":e1") {
                b"=020780\r".to_vec()
            } else {
                b"!0\r".to_vec()
            }
        }),
    );
    let mut mount = SkyWatcherMount::new_serial(gt.path.clone(), None, philadelphia());
    let _ = step!(gt, "connect [GT alt-azimuth base]", mount.connect().await);
    gt.mark(&format!("  connected={}", mount.is_connected()));

    let knobs = Arc::new(Knobs::default());
    let fake = FakeMount::spawn(b'\r', fakes::synscan(None, knobs));
    let mut mount = SkyWatcherMount::new_serial(fake.path.clone(), None, Arc::new(|| None))
        .with_clock(session_clock);
    let _ = step!(fake, "connect [no site]", mount.connect().await);
    let _ = step!(fake, "get_coordinates", mount.get_coordinates().await);
    let _ = step!(
        fake,
        "slew_to_coordinates(5.5, 20.0)",
        mount.slew_to_coordinates(5.5, 20.0).await
    );
    let _ = step!(fake, "set_tracking(true)", mount.set_tracking(true).await);
    let _ = step!(fake, "get_tracking", mount.get_tracking().await);
    let _ = step!(fake, "park", mount.park().await);
    let _ = step!(fake, "is_parked", mount.is_parked().await);

    let mut lines = gt.lines();
    lines.push("== no site ==".to_string());
    lines.extend(fake.lines());
    check_transcript("skywatcher_refusals", &lines);
}

#[tokio::test]
async fn a_failed_initial_tracking_read_does_not_connect_as_tracking_off() {
    let mut base = fakes::synscan(None, Arc::new(Knobs::default()));
    let mut ra_reads = 0;
    let fake = FakeMount::spawn(
        b'\r',
        Box::new(move |command, baud| {
            if command == b":f1\r" {
                ra_reads += 1;
                if ra_reads >= 2 {
                    return b"!0\r".to_vec();
                }
            }
            base(command, baud)
        }),
    );
    let mut mount = SkyWatcherMount::new_serial(fake.path.clone(), None, philadelphia());
    assert!(mount.connect().await.is_err());
    assert!(!mount.is_connected());
}

#[tokio::test]
async fn a_park_timeout_reports_whether_both_axes_actually_stopped() {
    for refuse_stop in [false, true] {
        let mut base = fakes::synscan_initialized(Arc::new(Knobs::default()));
        let mut started = false;
        let fake = FakeMount::spawn(
            b'\r',
            Box::new(move |command, baud| {
                if command == b":J2\r" {
                    started = true;
                }
                if started && refuse_stop && command == b":K1\r" {
                    return b"!2\r".to_vec();
                }
                base(command, baud)
            }),
        );
        let mut mount = connected(&fake, philadelphia()).await;
        let error = mount
            .park_with_limit(std::time::Duration::ZERO)
            .await
            .unwrap_err();
        let text = error.to_string();
        if refuse_stop {
            assert!(
                text.contains("could not confirm the mount stopped"),
                "{text}"
            );
        } else {
            assert!(text.contains("both axes confirmed stopped"), "{text}");
        }
        assert!(!mount.is_parked().await.unwrap());
        let lines = fake.lines().join("\n");
        assert!(lines.contains(":K1") && lines.contains(":K2"), "{lines}");
        mount.disconnect().await.unwrap();
    }
}
