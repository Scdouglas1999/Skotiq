//! Astronomy primitives mirrored from `astronomy_calculations.dart`.
//!
//! Only the calls the scheduler needs are ported: `objectAltAz`,
//! `angularSeparation`, `airmass`, `calculateObjectVisibility`. The formulae,
//! constants, and conventions are byte-for-byte copies of the Dart source so
//! the parity test in `scoring::tests` can assert numeric equality.
//!
//! [`airmass`] is the one deliberate exception: it delegates to
//! `skotiq_imaging::calculate_airmass` rather than carrying its own copy,
//! so the atmosphere the scheduler ranks targets under and the atmosphere
//! written into the `AIRMASS` card of the resulting frames are the same one.
//! See its doc comment for why the Dart parity survives that.

use chrono::{DateTime, Datelike, Timelike, Utc};

const DEG2RAD: f64 = std::f64::consts::PI / 180.0;
const RAD2DEG: f64 = 180.0 / std::f64::consts::PI;
const EPSILON: f64 = 1e-12;
const J2000: f64 = 2_451_545.0;

/// Julian Date for the given UTC instant.
///
/// Mirrors `AstronomyCalculations.julianDate` from `astronomy_calculations.dart`.
///
/// This is deliberately NOT `crate::meridian::julian_day`, and the two are not
/// merged. `meridian::julian_day` is Meeus' Gregorian form on a whole-second
/// day fraction; this is Fliegel–Van Flandern on a millisecond day fraction,
/// because its whole job is to return the same doubles the Dart planetarium
/// returns so `scoring`'s parity test can assert numeric equality against it.
///
/// On a whole-second instant the two produce the identical f64 — verified by
/// `meridian::tests::scheduling_astronomy_is_a_deliberately_separate_julian_date`,
/// which also shows them parting company as soon as sub-second time is
/// present. So they cannot be collapsed by inspection: picking either one
/// would silently change the other's callers on any instant carrying
/// milliseconds, and here that would break the only thing keeping the Rust
/// scheduler and the Dart planner ranking targets the same way. What the rest
/// of the crate shares is `meridian::julian_day`: every non-parity caller
/// (executor, instructions, solar, polar-align, flat-wizard, the bridge)
/// already goes through it.
pub fn julian_date(dt: &DateTime<Utc>) -> f64 {
    let y = dt.year() as f64;
    let m = dt.month() as f64;
    let day = dt.day() as f64
        + (dt.hour() as f64) / 24.0
        + (dt.minute() as f64) / 1440.0
        + (dt.second() as f64) / 86_400.0
        + (dt.timestamp_subsec_millis() as f64) / 86_400_000.0;

    let a = ((14.0 - m) / 12.0).floor();
    let y2 = y + 4800.0 - a;
    let m2 = m + 12.0 * a - 3.0;

    day + ((153.0 * m2 + 2.0) / 5.0).floor() + 365.0 * y2 + (y2 / 4.0).floor()
        - (y2 / 100.0).floor()
        + (y2 / 400.0).floor()
        - 32_045.0
        - 0.5
}

/// Greenwich Mean Sidereal Time in decimal hours.
pub fn greenwich_mean_sidereal_time(dt: &DateTime<Utc>) -> f64 {
    let jd = julian_date(dt);
    let t = (jd - J2000) / 36_525.0;
    let mut gmst = 280.460_618_37 + 360.985_647_366_29 * (jd - J2000) + 0.000_387_933 * t * t
        - t * t * t / 38_710_000.0;

    gmst = gmst.rem_euclid(360.0);
    gmst / 15.0
}

/// Local Sidereal Time in decimal hours.
pub fn local_sidereal_time(dt: &DateTime<Utc>, longitude_deg: f64) -> f64 {
    let gmst = greenwich_mean_sidereal_time(dt);
    let lst = gmst + longitude_deg / 15.0;
    lst.rem_euclid(24.0)
}

/// Convert equatorial RA/Dec to horizontal Alt/Az using the given latitude
/// and LST. Returns `(altitude_deg, azimuth_deg)`.
pub fn equatorial_to_horizontal(
    ra_deg: f64,
    dec_deg: f64,
    latitude_deg: f64,
    lst_hours: f64,
) -> (f64, f64) {
    let ha = (lst_hours * 15.0 - ra_deg) * DEG2RAD;
    let dec = dec_deg * DEG2RAD;
    let lat = latitude_deg * DEG2RAD;

    let sin_alt = dec.sin() * lat.sin() + dec.cos() * lat.cos() * ha.cos();
    let alt = sin_alt.clamp(-1.0, 1.0).asin();

    let y = -ha.sin() * dec.cos();
    let x = dec.sin() * lat.cos() - dec.cos() * lat.sin() * ha.cos();
    let mut az = y.atan2(x);
    if az < 0.0 {
        az += 2.0 * std::f64::consts::PI;
    }

    (alt * RAD2DEG, az * RAD2DEG)
}

/// `objectAltAz` — RA in DEGREES (consistent with Dart). Returns
/// `(altitude_deg, azimuth_deg)`.
pub fn object_alt_az(
    ra_deg: f64,
    dec_deg: f64,
    dt: &DateTime<Utc>,
    latitude_deg: f64,
    longitude_deg: f64,
) -> (f64, f64) {
    let lst = local_sidereal_time(dt, longitude_deg);
    equatorial_to_horizontal(ra_deg, dec_deg, latitude_deg, lst)
}

/// Airmass at a true altitude, for target scoring.
///
/// The formula is not here: it is `skotiq_imaging::calculate_airmass`, the
/// same function that fills the `AIRMASS` card of every frame this scheduler's
/// decisions produce. A scheduler ranking targets under a different atmosphere
/// than the one recorded in the files can rank a target above a rival that its
/// own headers then describe as the worse observation, and there is no way to
/// tell from either surface which number was meant.
///
/// What stays here is the scheduler's own convention, which is a policy and
/// not a formula: `f64::INFINITY` for `altitude_deg <= 0`, which
/// [`super::scoring::score_airmass`] maps to a zero score. Note `<= 0`, not
/// `< 0` — a target exactly on the horizon is unobservable and must not be
/// scheduled, even though its airmass is finite (~31.7) and the FITS writer
/// records it for a frame somehow taken there.
pub fn airmass(altitude_deg: f64) -> f64 {
    if altitude_deg <= 0.0 {
        return f64::INFINITY;
    }
    skotiq_imaging::calculate_airmass(altitude_deg).unwrap_or(f64::INFINITY)
}

/// Angular separation between two sky positions (degrees).
pub fn angular_separation(ra1_deg: f64, dec1_deg: f64, ra2_deg: f64, dec2_deg: f64) -> f64 {
    let ra1 = ra1_deg * DEG2RAD;
    let dec1 = dec1_deg * DEG2RAD;
    let ra2 = ra2_deg * DEG2RAD;
    let dec2 = dec2_deg * DEG2RAD;

    let cos_sep = dec1.sin() * dec2.sin() + dec1.cos() * dec2.cos() * (ra1 - ra2).cos();
    cos_sep.clamp(-1.0, 1.0).acos() * RAD2DEG
}

/// Rise/transit/set times + transit altitude for a target.
///
/// Mirrors `AstronomyCalculations.calculateObjectVisibility`. Returns
/// `None` for fields that don't apply (circumpolar → no rise/set; never-rises
/// → no transit either).
#[derive(Debug, Clone)]
pub struct ObjectVisibility {
    pub rise_time: Option<DateTime<Utc>>,
    pub transit_time: Option<DateTime<Utc>>,
    pub set_time: Option<DateTime<Utc>>,
    pub transit_altitude: f64,
    pub is_circumpolar: bool,
    pub never_rises: bool,
}

pub fn calculate_object_visibility(
    ra_deg: f64,
    dec_deg: f64,
    date: &DateTime<Utc>,
    latitude_deg: f64,
    longitude_deg: f64,
    min_altitude: f64,
) -> ObjectVisibility {
    let local_noon = chrono::NaiveDate::from_ymd_opt(date.year(), date.month(), date.day())
        .and_then(|d| d.and_hms_opt(12, 0, 0))
        .map(|naive| DateTime::<Utc>::from_naive_utc_and_offset(naive, Utc))
        .unwrap_or(*date);

    let cos_dec = (dec_deg * DEG2RAD).cos();
    let sin_dec = (dec_deg * DEG2RAD).sin();
    let cos_lat = (latitude_deg * DEG2RAD).cos();
    let sin_lat = (latitude_deg * DEG2RAD).sin();
    let denominator = cos_dec * cos_lat;

    let transit_altitude = (90.0 - (latitude_deg - dec_deg).abs()).clamp(-90.0, 90.0);

    if denominator.abs() < EPSILON {
        let above_min = transit_altitude >= min_altitude;
        return ObjectVisibility {
            rise_time: None,
            transit_time: None,
            set_time: None,
            transit_altitude,
            is_circumpolar: above_min,
            never_rises: !above_min,
        };
    }

    let cos_h0 = ((min_altitude * DEG2RAD).sin() - sin_dec * sin_lat) / denominator;

    let mut is_circumpolar = false;
    let mut never_rises = false;
    if cos_h0 < -1.0 {
        is_circumpolar = true;
    } else if cos_h0 > 1.0 {
        never_rises = true;
    }

    let lst0 = local_sidereal_time(&local_noon, longitude_deg);
    let mut hours_till_transit = (ra_deg / 15.0) - lst0;
    if hours_till_transit < -12.0 {
        hours_till_transit += 24.0;
    }
    if hours_till_transit > 12.0 {
        hours_till_transit -= 24.0;
    }

    let transit_time =
        local_noon + chrono::Duration::seconds((hours_till_transit * 3600.0).round() as i64);

    let (rise_time, set_time) = if !is_circumpolar && !never_rises {
        let h0 = cos_h0.acos() * RAD2DEG / 15.0; // in hours
        let half = chrono::Duration::seconds((h0 * 3600.0).round() as i64);
        (Some(transit_time - half), Some(transit_time + half))
    } else {
        (None, None)
    };

    ObjectVisibility {
        rise_time,
        transit_time: Some(transit_time),
        set_time,
        transit_altitude,
        is_circumpolar,
        never_rises,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn airmass_zenith_is_one() {
        // Within 0.5% at zenith (formula is empirical, not a pure secant).
        let am = airmass(90.0);
        assert!((am - 1.0).abs() < 0.005, "got {am}");
    }

    #[test]
    fn airmass_below_horizon_is_infinity() {
        assert!(airmass(-1.0).is_infinite());
        assert!(airmass(0.0).is_infinite());
    }

    /// The scheduler and the FITS writer must be describing one atmosphere. A
    /// private Pickering copy here agrees with the writer's `calculate_airmass`
    /// above 10° and diverges below it — by 7 airmass at the horizon, where the
    /// writer switches to Young 1994 — so the scheduler ranks a target on one
    /// airmass while every frame it produces records another.
    ///
    /// Equality is asserted exactly, not to a tolerance: the point is that there
    /// is one function, not two that currently happen to be close.
    #[test]
    fn airmass_is_the_same_function_the_fits_writer_uses() {
        let mut h = 0.25_f64;
        while h <= 90.0 {
            let written = skotiq_imaging::calculate_airmass(h)
                .expect("above the horizon, so the writer computes a card");
            let scheduled = airmass(h);
            assert_eq!(
                scheduled, written,
                "at {h}° the scheduler scores airmass {scheduled} while the frame it \
                 produces would record {written}"
            );
            h += 0.25;
        }
    }

    #[test]
    fn angular_separation_self_is_zero() {
        let sep = angular_separation(15.0, 30.0, 15.0, 30.0);
        assert!(sep < 1e-6);
    }

    #[test]
    fn angular_separation_pole_to_equator_is_ninety() {
        let sep = angular_separation(0.0, 90.0, 0.0, 0.0);
        assert!((sep - 90.0).abs() < 1e-6, "got {sep}");
    }
}
