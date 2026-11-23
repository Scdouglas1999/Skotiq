//! What a connect check concludes from what a device reported: pure
//! functions of the reads, so each rule is tested on its own. `Some(sentence)`
//! names what the device said and what the other source says.

use crate::device::{CameraStatus, MountSite, MountStatus, MountTimeInfo, PierSide};
use crate::device_manager::ops::backstop::Reading;
use std::time::Duration;

/// How far apart the two mount reads are. The owner asked for 3-5 s: long
/// enough that a mount not tracking moves 4 s of RA, short enough to finish
/// before a run's first command after a reconnect.
pub(crate) const RA_SAMPLE_GAP: Duration = Duration::from_secs(4);

/// How much longer a mount that says it is not tracking is watched when its
/// RA held still over [`RA_SAMPLE_GAP`]: an LX200 at low precision reports RA
/// in 6 s steps, so 4 s of drift can read as none. Over 10 s at least one
/// step shows.
pub(crate) const RA_SECOND_LOOK: Duration = Duration::from_secs(6);

/// RA seconds a mount that is not tracking moves per second of time: its
/// hour angle holds, so its RA follows sidereal time.
const SIDEREAL_RA_PER_SECOND: f64 = 1.002_737_909;

/// A tracking mount's RA holds still but for rounding and encoder noise,
/// well under a second; one that is not tracking moves the whole drift.
/// Moving more than this share of the drift is not tracking.
const MOVED_LIKE_NOT_TRACKING: f64 = 0.75;

/// Moving less than this share of the drift is tracking.
const HELD_LIKE_TRACKING: f64 = 0.25;

/// Hours from the meridian within which either pier side is plausible. A
/// German mount tracks past the meridian before its flip (the NYX's limit is
/// 0.55 h), and some drivers report the pointing state rather than the
/// physical side near it; 2 h is past any flip delay a run uses.
const PIER_SIDE_MARGIN_H: f64 = 2.0;

/// The mount's clock may be this far from the computer's: the app's own
/// site check uses the same (serial round trips and the mount's one-second
/// clock make anything tighter noise).
const CLOCK_TOLERANCE_S: i64 = 30;

/// Site coordinates closer than this agree: one arcminute, the LX200 wire
/// resolution, as in the app's site check.
const SITE_TOLERANCE_DEG: f64 = 1.0 / 60.0;

/// Steps a focuser's report may differ from the position Skotiq last
/// recorded: readback jitter and the overshoot a driver settles from after
/// backlash are a few steps; a focuser that was moved or reset differs by
/// far more.
const FOCUSER_SAME_STEPS: i32 = 10;

/// Degrees a rotator's report may differ from the angle Skotiq last
/// recorded (driver rounding is under 0.1 degree).
const ROTATOR_SAME_DEG: f64 = 0.5;

/// Degrees above its set-point a camera whose cooler is on may sit while it
/// is working: a cooler at its set-point regulates, and one cooling down
/// draws power.
const COOLER_FAR_ABOVE_C: f64 = 5.0;

/// Cooler power (%) at or below which a cooler is not working.
const COOLER_IDLE_POWER: f64 = 1.0;

/// Cooler power (%) above which a cooler said to be off is drawing current.
const COOLER_OFF_POWER: f64 = 5.0;

/// What two mount reads say about the tracking report.
#[derive(Debug, PartialEq)]
pub(crate) enum TrackingVerdict {
    Agrees,
    Disagrees(String),
    /// Not tracking and RA held still over a short gap: read again later.
    LookAgain,
    /// The reads cannot tell, and why.
    Skip(&'static str),
}

/// RA seconds from `a` to `b`, the short way round.
fn ra_seconds_moved(a: &MountStatus, b: &MountStatus) -> f64 {
    let hours = (b.right_ascension - a.right_ascension + 36.0).rem_euclid(24.0) - 12.0;
    hours * 3600.0
}

/// Whether the RA the mount reported over `elapsed` agrees with its tracking
/// report, and a parked mount says it is not tracking. `last_look` is the
/// second look: a mount that held still then is decided.
pub(crate) fn tracking(
    first: &MountStatus,
    second: &MountStatus,
    elapsed: Duration,
    last_look: bool,
) -> TrackingVerdict {
    if first.slewing || second.slewing {
        return TrackingVerdict::Skip("the mount was slewing");
    }
    if first.tracking != second.tracking || first.parked != second.parked {
        return TrackingVerdict::Skip("its tracking or park state changed between the reads");
    }
    if second.parked && second.tracking {
        return TrackingVerdict::Disagrees(
            "it reports parked and tracking at once (a parked mount does not track)".to_string(),
        );
    }
    if second.parked {
        // Where a parked mount points is its park position, which no driver
        // reports; its RA proves nothing about the park.
        return TrackingVerdict::Skip("it is parked");
    }
    let drift = elapsed.as_secs_f64() * SIDEREAL_RA_PER_SECOND;
    let moved = ra_seconds_moved(first, second).abs();
    if second.tracking {
        if moved > MOVED_LIKE_NOT_TRACKING * drift {
            return TrackingVerdict::Disagrees(format!(
                "it reports tracking, but its RA moved {moved:.1} s in {:.1} s, as a mount \
                 that is not tracking does",
                elapsed.as_secs_f64()
            ));
        }
        return TrackingVerdict::Agrees;
    }
    if moved < HELD_LIKE_TRACKING * drift {
        if !last_look {
            return TrackingVerdict::LookAgain;
        }
        return TrackingVerdict::Disagrees(format!(
            "it reports not tracking, but its RA held still for {:.0} s, as a tracking mount's \
             does (one that is not tracking moves {drift:.0} s)",
            elapsed.as_secs_f64()
        ));
    }
    TrackingVerdict::Agrees
}

/// Whether the reported pier side fits the hour angle.
pub(crate) fn pier_side(status: &MountStatus) -> Option<String> {
    if status.parked || status.at_home == Some(true) || status.slewing {
        return None;
    }
    let side = status.side_of_pier?;
    let lst = status.sidereal_time?;
    let hour_angle = (lst - status.right_ascension + 36.0).rem_euclid(24.0) - 12.0;
    let (expected, wrong) = match side {
        // On the east side of the pier the telescope looks west: a positive
        // hour angle.
        PierSide::East => ("west", hour_angle < -PIER_SIDE_MARGIN_H),
        PierSide::West => ("east", hour_angle > PIER_SIDE_MARGIN_H),
        PierSide::Unknown => return None,
    };
    wrong.then(|| {
        format!(
            "it reports pier side {side:?}, which looks {expected} of the meridian, but its \
             hour angle is {hour_angle:+.1} h"
        )
    })
}

/// Whether the mount's clock agrees with the computer's at `now_unix_s`.
pub(crate) fn clock(time: &MountTimeInfo, now_unix_s: i64) -> Option<String> {
    let off = time.utc_unix_seconds - now_unix_s;
    (off.abs() > CLOCK_TOLERANCE_S)
        .then(|| format!("its clock reads {off:+} s from this computer's (UTC)"))
}

/// Whether the mount's site agrees with the site Skotiq is set to.
pub(crate) fn site(mount: &MountSite, latitude_deg: f64, longitude_deg: f64) -> Option<String> {
    let latitude_off = (mount.latitude_deg - latitude_deg).abs();
    let longitude_off =
        ((mount.longitude_deg - longitude_deg + 540.0).rem_euclid(360.0) - 180.0).abs();
    (latitude_off > SITE_TOLERANCE_DEG || longitude_off > SITE_TOLERANCE_DEG).then(|| {
        format!(
            "its site is {:.4}, {:.4}, but Skotiq's site is {latitude_deg:.4}, {longitude_deg:.4}",
            mount.latitude_deg, mount.longitude_deg
        )
    })
}

/// Whether a focuser, wheel or rotator reports where Skotiq last recorded it.
pub(crate) fn position(reported: Reading, recorded: Reading) -> Option<String> {
    let disagrees = match (reported, recorded) {
        (Reading::Focuser(now), Reading::Focuser(then)) => (now - then).abs() > FOCUSER_SAME_STEPS,
        (Reading::Filter(now), Reading::Filter(then)) => now != then,
        (Reading::Rotator(now), Reading::Rotator(then)) => {
            let off = (now - then + 540.0).rem_euclid(360.0) - 180.0;
            off.abs() > ROTATOR_SAME_DEG
        }
        _ => return None,
    };
    disagrees.then(|| {
        format!(
            "it reports {}, but Skotiq last recorded {} for it (it may have been moved or reset \
             while it was disconnected)",
            describe(reported),
            describe(recorded)
        )
    })
}

fn describe(reading: Reading) -> String {
    match reading {
        Reading::Focuser(steps) => format!("position {steps}"),
        Reading::Filter(slot) => format!("slot {}", slot + 1),
        Reading::Rotator(angle) => format!("{angle:.1} degrees"),
    }
}

/// Whether a camera's cooler report holds together: on, idle and far above
/// its set-point is not cooling; off and drawing power is not off.
pub(crate) fn cooler(status: &CameraStatus) -> Option<String> {
    if !status.can_cool {
        return None;
    }
    let power = status.cooler_power?;
    match status.cooler_on? {
        true => {
            let (sensor, target) = (status.sensor_temp?, status.target_temp?);
            (power <= COOLER_IDLE_POWER && sensor > target + COOLER_FAR_ABOVE_C).then(|| {
                format!(
                    "it reports its cooler on, but at {power:.0} % power with the sensor at \
                     {sensor:.1} C against a {target:.1} C set-point"
                )
            })
        }
        false => (power > COOLER_OFF_POWER)
            .then(|| format!("it reports its cooler off, but at {power:.0} % power")),
    }
}
