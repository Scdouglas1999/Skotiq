//! Where a German equatorial mount points for a pair of motor positions, and
//! the reverse.
//!
//! The motor controller only counts microsteps. The frame below is the one
//! indi-eqmod and EQMOD use, so a mount handed from one of them to Skotiq
//! without a power cycle reads the same: at power-on both axes stand at
//! encoder `zero` with the counterweight down and the telescope at the
//! celestial pole, and initialization rewrites the Dec axis to
//! `zero + counts / 4` there, so that Dec encoder `zero` is the equator on the
//! normal side of the pier. A forward step turns the RA axis with the sky in
//! the northern hemisphere and against it in the southern.

use chrono::{DateTime, Utc};
use skotiq_device::PierSide;

/// Encoder value of the power-on position. A controller that was initialized
/// before Skotiq connected is taken to be in this frame too.
pub(super) const POWER_ON_STEP: u32 = 0x80_0000;

/// One axis: where its zero is and how many microsteps make a turn.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(super) struct AxisScale {
    pub zero: u32,
    pub counts: u32,
}

impl AxisScale {
    /// Signed turns from zero.
    fn turns(&self, step: u32) -> f64 {
        (i64::from(step) - i64::from(self.zero)) as f64 / f64::from(self.counts)
    }

    fn step(&self, turns: f64) -> u32 {
        (f64::from(self.zero) + turns * f64::from(self.counts)).round() as u32
    }

    /// Microsteps in `arcseconds` of axis rotation, at least one.
    pub(super) fn steps_in_arcseconds(&self, arcseconds: f64) -> u32 {
        ((arcseconds / 1_296_000.0) * f64::from(self.counts))
            .ceil()
            .max(1.0) as u32
    }
}

/// Both axes and the hemisphere, which decides the sense of every rotation.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(super) struct MountFrame {
    pub ra: AxisScale,
    pub dec: AxisScale,
    pub southern: bool,
}

/// A position on the sky in the mount's own frame (no sync offset applied).
#[derive(Debug, Clone, Copy, PartialEq)]
pub(super) struct Pointing {
    pub ra_hours: f64,
    pub dec_degrees: f64,
    pub pier_side: PierSide,
}

/// Motor positions for a pointing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct AxisSteps {
    pub ra: u32,
    pub dec: u32,
}

/// Counterweight down, telescope at the pole: the power-on position, in
/// either hemisphere.
pub(super) fn home(ra: &AxisScale, dec: &AxisScale) -> AxisSteps {
    AxisSteps {
        ra: ra.zero,
        dec: dec.step(0.25),
    }
}

impl MountFrame {
    pub(super) fn pointing(&self, steps: AxisSteps, lst_hours: f64) -> Pointing {
        let ra_turns = self.ra.turns(steps.ra);
        let axis_hours = if self.southern {
            6.0 + 24.0 * ra_turns
        } else {
            6.0 - 24.0 * ra_turns
        };
        let degrees = self.dec_axis_degrees(steps.dec);
        // Past the pole the tube is on the other side of the pier and looks
        // at the opposite hour.
        let past_pole = beyond_pole(degrees);
        let mut ra = axis_hours + lst_hours;
        if past_pole {
            ra -= 12.0;
        }
        if self.southern {
            ra += 12.0;
        }
        Pointing {
            ra_hours: ra.rem_euclid(24.0),
            dec_degrees: fold_declination(degrees),
            pier_side: self.pier_side_at(degrees),
        }
    }

    /// Dec axis angle in [0, 360), increasing northward on the normal side.
    fn dec_axis_degrees(&self, dec_step: u32) -> f64 {
        let raw = (360.0 * self.dec.turns(dec_step)).rem_euclid(360.0);
        if self.southern {
            (360.0 - raw).rem_euclid(360.0)
        } else {
            raw
        }
    }

    fn pier_side_at(&self, dec_axis_degrees: f64) -> PierSide {
        if beyond_pole(dec_axis_degrees) != self.southern {
            PierSide::East
        } else {
            PierSide::West
        }
    }

    /// Motor positions that point at `ra_hours`, `dec_degrees` from
    /// `pier_side`.
    pub(super) fn steps(
        &self,
        ra_hours: f64,
        dec_degrees: f64,
        pier_side: PierSide,
        lst_hours: f64,
    ) -> AxisSteps {
        let pier_east = pier_side == PierSide::East;
        let hour = if pier_east {
            ra_hours - lst_hours + 12.0
        } else {
            ra_hours - lst_hours
        };
        // Hours turned from the counterweight-down position, in [-12, 12).
        let mut from_down = (hour - 6.0).rem_euclid(24.0);
        if from_down >= 12.0 {
            from_down -= 24.0;
        }
        let ra_turns = if self.southern {
            from_down / 24.0
        } else {
            -from_down / 24.0
        };

        let beyond_pole = pier_east != self.southern;
        let degrees = if beyond_pole {
            180.0 - dec_degrees
        } else {
            dec_degrees
        };
        let mut degrees = degrees.rem_euclid(360.0);
        if self.southern {
            degrees = 360.0 - degrees;
        }
        if degrees > 270.0 {
            degrees -= 360.0;
        }
        AxisSteps {
            ra: self.ra.step(ra_turns),
            dec: self.dec.step(degrees / 360.0),
        }
    }

    /// Whether a forward Dec step moves the telescope north from `dec_step`.
    /// It does from the west side of the pier, in either hemisphere.
    pub(super) fn dec_forward_is_north(&self, dec_step: u32) -> bool {
        self.pier_side_at(self.dec_axis_degrees(dec_step)) == PierSide::West
    }
}

/// The side a goto takes: the counterweight stays below the polar axis,
/// so a target west of the meridian is reached from the east side.
pub(super) fn pier_side_for(ra_hours: f64, lst_hours: f64) -> PierSide {
    let mut hours_west_of_target = (ra_hours - lst_hours).rem_euclid(24.0);
    if hours_west_of_target >= 12.0 {
        hours_west_of_target -= 24.0;
    }
    if hours_west_of_target < 0.0 {
        PierSide::East
    } else {
        PierSide::West
    }
}

fn beyond_pole(dec_axis_degrees: f64) -> bool {
    dec_axis_degrees > 90.0 && dec_axis_degrees <= 270.0
}

/// Dec axis angle (0..360) as a declination.
fn fold_declination(degrees: f64) -> f64 {
    if degrees >= 270.0 {
        degrees - 360.0
    } else if degrees >= 90.0 {
        180.0 - degrees
    } else {
        degrees
    }
}

/// Mean local sidereal time, hours. `longitude_east_deg` is east-positive.
pub(super) fn local_sidereal_hours(utc: DateTime<Utc>, longitude_east_deg: f64) -> f64 {
    let julian_days = utc.timestamp_millis() as f64 / 86_400_000.0 + 2_440_587.5;
    let days = julian_days - 2_451_545.0;
    let centuries = days / 36_525.0;
    // IAU 1982 mean sidereal time (Meeus, Astronomical Algorithms, 12.4).
    let gmst_deg =
        280.460_618_37 + 360.985_647_366_29 * days + 0.000_387_933 * centuries * centuries
            - centuries * centuries * centuries / 38_710_000.0;
    ((gmst_deg + longitude_east_deg) / 15.0).rem_euclid(24.0)
}

/// Altitude and azimuth (north through east), degrees.
pub(super) fn alt_az(
    ra_hours: f64,
    dec_degrees: f64,
    latitude_deg: f64,
    lst_hours: f64,
) -> (f64, f64) {
    let hour_angle = ((lst_hours - ra_hours) * 15.0).to_radians();
    let dec = dec_degrees.to_radians();
    let lat = latitude_deg.to_radians();
    let sin_alt = dec.sin() * lat.sin() + dec.cos() * lat.cos() * hour_angle.cos();
    let alt = sin_alt.clamp(-1.0, 1.0).asin();
    let az = (-hour_angle.sin() * dec.cos())
        .atan2(dec.sin() * lat.cos() - dec.cos() * lat.sin() * hour_angle.cos());
    (alt.to_degrees(), az.to_degrees().rem_euclid(360.0))
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn frame(latitude: f64, counts: u32) -> MountFrame {
        let axis = AxisScale {
            zero: POWER_ON_STEP,
            counts,
        };
        MountFrame {
            ra: axis,
            dec: axis,
            southern: latitude < 0.0,
        }
    }

    fn parse_pier(text: &str) -> PierSide {
        match text {
            "East" => PierSide::East,
            "West" => PierSide::West,
            other => panic!("pier side {other:?}"),
        }
    }

    fn hours_apart(a: f64, b: f64) -> f64 {
        let d = (a - b).rem_euclid(24.0);
        d.min(24.0 - d)
    }

    /// Every goto target (pier side and both motor positions) and every
    /// read-back agrees with indi-eqmod's formulas, on both sides of the
    /// meridian, at the poles, at the equator, in both hemispheres and for
    /// two gear trains. One microstep of difference is rounding.
    #[test]
    fn goto_targets_and_read_backs_match_indi_eqmod() {
        let table = include_str!("../../../tests/fixtures/skywatcher_eqmod_pointing.txt");
        let mut rows = 0;
        for line in table.lines().filter(|l| !l.starts_with('#')) {
            let f: Vec<&str> = line.split_whitespace().collect();
            let num = |i: usize| f[i].parse::<f64>().unwrap();
            let (lat, counts, lst, ra, dec) = (num(0), num(1) as u32, num(2), num(3), num(4));
            let frame = frame(lat, counts);
            let pier = pier_side_for(ra, lst);
            assert_eq!(pier, parse_pier(f[7]), "pier side for {line}");
            let steps = frame.steps(ra, dec, pier, lst);
            let want_ra = num(5) as i64;
            let want_dec = num(6) as i64;
            assert!(
                (i64::from(steps.ra) - want_ra).abs() <= 1
                    && (i64::from(steps.dec) - want_dec).abs() <= 1,
                "steps {steps:?} for {line}"
            );
            let back = frame.pointing(
                AxisSteps {
                    ra: want_ra as u32,
                    dec: want_dec as u32,
                },
                lst,
            );
            assert!(
                hours_apart(back.ra_hours, num(8)) < 1e-6,
                "read-back RA {back:?} for {line}"
            );
            assert!(
                (back.dec_degrees - num(9)).abs() < 1e-6,
                "read-back Dec {back:?} for {line}"
            );
            assert_eq!(
                back.pier_side,
                parse_pier(f[10]),
                "read-back pier for {line}"
            );
            rows += 1;
        }
        assert_eq!(rows, 360);
    }

    /// A target just east of the meridian is reached from the west side of
    /// the pier and one just west of it from the east side; the RA axis ends
    /// up on either side of counterweight-horizontal and the Dec axis on
    /// either side of the pole, never more than a quarter turn from the
    /// counterweight-down position.
    #[test]
    fn a_target_crossing_the_meridian_flips_the_pier_side() {
        let frame = frame(40.0, 9_024_000);
        let lst = 10.0;
        let quarter = 9_024_000 / 4;
        let before = frame.steps(10.01, 30.0, pier_side_for(10.01, lst), lst);
        let after = frame.steps(9.99, 30.0, pier_side_for(9.99, lst), lst);
        assert_eq!(pier_side_for(10.01, lst), PierSide::West);
        assert_eq!(pier_side_for(9.99, lst), PierSide::East);
        for steps in [before, after] {
            assert!(steps.ra.abs_diff(POWER_ON_STEP) <= quarter);
        }
        // Dec 30 on the west side sits below the pole step, on the east side above.
        let pole = home(&frame.ra, &frame.dec).dec;
        assert!(before.dec < pole && after.dec > pole);
        // Both read back as the same sky position.
        let a = frame.pointing(before, lst);
        let b = frame.pointing(after, lst);
        assert!((a.dec_degrees - 30.0).abs() < 1e-4 && (b.dec_degrees - 30.0).abs() < 1e-4);
        assert!(hours_apart(a.ra_hours, 10.01) < 1e-5 && hours_apart(b.ra_hours, 9.99) < 1e-5);
    }

    /// The power-on position reads as the pole, and a forward RA step at the
    /// sidereal rate keeps the telescope on the same RA: tracking runs
    /// forward in the north and backward in the south.
    #[test]
    fn tracking_direction_holds_the_target_in_both_hemispheres() {
        for (lat, forward) in [(52.0, true), (-33.0, false)] {
            let frame = frame(lat, 9_024_000);
            let home = frame.pointing(home(&frame.ra, &frame.dec), 3.0);
            assert!((home.dec_degrees.abs() - 90.0).abs() < 1e-9);
            assert_eq!(home.dec_degrees > 0.0, lat > 0.0);

            let lst = 3.0;
            let steps = frame.steps(1.0, 20.0, pier_side_for(1.0, lst), lst);
            // One sidereal hour later the axis has turned 1/24 turn.
            let turn = 9_024_000 / 24;
            let moved = AxisSteps {
                ra: if forward {
                    steps.ra + turn
                } else {
                    steps.ra - turn
                },
                dec: steps.dec,
            };
            let later = frame.pointing(moved, lst + 1.0);
            assert!(hours_apart(later.ra_hours, 1.0) < 1e-6, "{lat}: {later:?}");
        }
    }

    #[test]
    fn a_forward_dec_step_moves_north_from_the_west_side_of_the_pier() {
        let lst = 6.0;
        for (lat, ra, forward_north) in [
            (40.0, 8.0, true),  // east of the meridian: west side of the pier
            (40.0, 4.0, false), // west of it: east side
            (-30.0, 8.0, true),
            (-30.0, 4.0, false),
        ] {
            let frame = frame(lat, 9_024_000);
            let steps = frame.steps(ra, 10.0, pier_side_for(ra, lst), lst);
            assert_eq!(
                frame.dec_forward_is_north(steps.dec),
                forward_north,
                "lat {lat} ra {ra}"
            );
            let north = frame.pointing(
                AxisSteps {
                    ra: steps.ra,
                    dec: if forward_north {
                        steps.dec + 1000
                    } else {
                        steps.dec - 1000
                    },
                },
                lst,
            );
            assert!(north.dec_degrees > 10.0, "lat {lat} ra {ra}: {north:?}");
        }
    }

    /// Meeus, Astronomical Algorithms, example 12.a: 1987 April 10, 0h UT,
    /// mean sidereal time at Greenwich 13h10m46.3668s.
    #[test]
    fn sidereal_time_matches_the_almanac() {
        let utc = Utc.with_ymd_and_hms(1987, 4, 10, 0, 0, 0).unwrap();
        let expected = 13.0 + 10.0 / 60.0 + 46.3668 / 3600.0;
        assert!((local_sidereal_hours(utc, 0.0) - expected).abs() < 0.01 / 3600.0);
        // 75 degrees west is five hours earlier.
        let west = local_sidereal_hours(utc, -75.0);
        assert!((west - (expected - 5.0)).abs() < 0.01 / 3600.0);
    }

    #[test]
    fn alt_az_of_the_meridian_and_the_pole() {
        // On the meridian, south of the zenith.
        let (alt, az) = alt_az(5.0, 10.0, 40.0, 5.0);
        assert!((alt - 60.0).abs() < 1e-9 && (az - 180.0).abs() < 1e-9);
        // Six hours east of the meridian on the equator: due east, on the horizon.
        let (alt, az) = alt_az(11.0, 0.0, 40.0, 5.0);
        assert!(alt.abs() < 1e-9 && (az - 90.0).abs() < 1e-9);
        let (alt, _) = alt_az(0.0, 90.0, 40.0, 5.0);
        assert!((alt - 40.0).abs() < 1e-9);
    }
}
