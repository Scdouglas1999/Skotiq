//! Low-precision sun + moon ephemeris and twilight brackets for the scheduler.
//!
//! the `TargetScheduler` built its live [`ObserverContext`] with
//! `moon: None, moon_illumination: 0.0, twilight: None`, so moon-avoidance and
//! darkness scoring (together ~40% of the scoring weight) were fed dead inputs
//! — the "self-driving" scheduler never actually considered the moon or the
//! sky darkness. The scoring math was fully built to consume these; it just
//! never received them. This module provides them.
//!
//! Precision: the formulae here are the standard low-precision sun position
//! (Astronomical Almanac, ~0.01°) and low-precision moon position (Astronomical
//! Almanac abbreviated series, ~0.3° in longitude / ~0.2° in latitude). That is
//! far more than enough for the scheduler, whose moon-distance score is bucketed
//! over tens of degrees and whose darkness score only asks "is the sun below
//! −6 / −12 / −18°". We deliberately avoid a full ELP/VSOP implementation.

use super::astronomy::{angular_separation, julian_date, object_alt_az};
use super::scoring::TwilightBracket;
use chrono::{DateTime, Duration, Utc};

/// Equatorial position of the Sun (RA, Dec) in degrees for `dt`.
///
/// Astronomical-Almanac low-precision formula (good to ~0.01°).
pub fn sun_equatorial(dt: &DateTime<Utc>) -> (f64, f64) {
    let n = julian_date(dt) - 2_451_545.0;
    // Mean longitude and mean anomaly of the Sun (degrees).
    let l = (280.460 + 0.985_647_4 * n).rem_euclid(360.0);
    let g = (357.528 + 0.985_600_3 * n).rem_euclid(360.0).to_radians();
    // Ecliptic longitude (equation of centre applied).
    let lambda = (l + 1.915 * g.sin() + 0.020 * (2.0 * g).sin()).to_radians();
    // Obliquity of the ecliptic.
    let eps = (23.439 - 0.000_000_4 * n).to_radians();

    let ra = (eps.cos() * lambda.sin())
        .atan2(lambda.cos())
        .to_degrees()
        .rem_euclid(360.0);
    let dec = (eps.sin() * lambda.sin()).asin().to_degrees();
    (ra, dec)
}

/// Geocentric ecliptic longitude/latitude of the Moon (degrees), low precision.
fn moon_ecliptic(t: f64) -> (f64, f64) {
    // `t` = Julian centuries since J2000.0. Angles below are in degrees; the
    // arguments of each sine term are reduced mod 360 implicitly by sin().
    let d2r = std::f64::consts::PI / 180.0;
    let s = |deg: f64| (deg * d2r).sin();

    let longitude = 218.32 + 481_267.881 * t + 6.29 * s(135.0 + 477_198.87 * t)
        - 1.27 * s(259.3 - 413_335.36 * t)
        + 0.66 * s(235.7 + 890_534.22 * t)
        + 0.21 * s(269.9 + 954_397.74 * t)
        - 0.19 * s(357.5 + 35_999.05 * t)
        - 0.11 * s(186.5 + 966_404.03 * t);

    let latitude = 5.13 * s(93.3 + 483_202.02 * t) + 0.28 * s(228.2 + 960_400.89 * t)
        - 0.28 * s(318.3 + 6_003.15 * t)
        - 0.17 * s(217.6 - 407_332.21 * t);

    (longitude.rem_euclid(360.0), latitude)
}

/// Equatorial position of the Moon (RA, Dec) in degrees for `dt`.
pub fn moon_equatorial(dt: &DateTime<Utc>) -> (f64, f64) {
    let jd = julian_date(dt);
    let t = (jd - 2_451_545.0) / 36_525.0;
    let (lon_deg, lat_deg) = moon_ecliptic(t);
    let eps = (23.439 - 0.000_000_4 * (jd - 2_451_545.0)).to_radians();
    let lam = lon_deg.to_radians();
    let bet = lat_deg.to_radians();

    let ra = (lam.sin() * eps.cos() - bet.tan() * eps.sin())
        .atan2(lam.cos())
        .to_degrees()
        .rem_euclid(360.0);
    let dec = (bet.sin() * eps.cos() + bet.cos() * eps.sin() * lam.sin())
        .asin()
        .to_degrees();
    (ra, dec)
}

/// Illuminated fraction of the Moon's disc as a percentage (0..=100).
///
/// Derived from the geocentric Sun–Moon elongation: `k = (1 − cos e) / 2`,
/// which is 100% at opposition (full) and 0% at conjunction (new). The
/// Moon's finite distance makes this a hair approximate, but well within the
/// scheduler's needs.
pub fn moon_illumination_percent(dt: &DateTime<Utc>) -> f64 {
    let (sun_ra, sun_dec) = sun_equatorial(dt);
    let (moon_ra, moon_dec) = moon_equatorial(dt);
    let elongation = angular_separation(sun_ra, sun_dec, moon_ra, moon_dec).to_radians();
    ((1.0 - elongation.cos()) / 2.0 * 100.0).clamp(0.0, 100.0)
}

/// Compute the twilight bracket (civil/nautical/astronomical dusk & dawn
/// timestamps) around `dt` for the observer.
///
/// Returns `None` only when the observer location is degenerate. Individual
/// crossings are `None` when the Sun never reaches that depression angle on
/// this date (polar day / polar twilight), which `score_darkness` already
/// handles gracefully.
pub fn twilight_bracket(
    dt: &DateTime<Utc>,
    latitude_deg: f64,
    longitude_deg: f64,
) -> TwilightBracket {
    let (civil_dusk, civil_dawn) = sun_depression_crossings(dt, latitude_deg, longitude_deg, -6.0);
    let (nautical_dusk, nautical_dawn) =
        sun_depression_crossings(dt, latitude_deg, longitude_deg, -12.0);
    let (astronomical_dusk, astronomical_dawn) =
        sun_depression_crossings(dt, latitude_deg, longitude_deg, -18.0);
    TwilightBracket {
        civil_dusk,
        civil_dawn,
        nautical_dusk,
        nautical_dawn,
        astronomical_dusk,
        astronomical_dawn,
    }
}

/// Find the dusk (Sun descending past `level_deg`) and dawn (Sun ascending past
/// `level_deg`) timestamps that bracket the night `dt` falls in.
///
/// Strategy (robust, no transit/sidereal bookkeeping): sample the Sun's
/// altitude across ±24 h at 5-minute steps and detect altitude crossings of
/// `level_deg`. If the Sun is currently below the level (it is that-dark now),
/// return the most recent descending crossing ≤ now and the next ascending
/// crossing ≥ now — `now` then sits inside the bracket. Otherwise (currently
/// brighter than the level) return the NEXT dusk and the dawn after it, both in
/// the future, so `score_darkness`'s `now > dusk && now < dawn` test correctly
/// reports "not yet that dark".
fn sun_depression_crossings(
    dt: &DateTime<Utc>,
    latitude_deg: f64,
    longitude_deg: f64,
    level_deg: f64,
) -> (Option<i64>, Option<i64>) {
    const STEP_MINS: i64 = 5;
    const SPAN_MINS: i64 = 24 * 60;

    let sun_alt = |t: &DateTime<Utc>| -> f64 {
        let (ra, dec) = sun_equatorial(t);
        object_alt_az(ra, dec, t, latitude_deg, longitude_deg).0
    };

    // Descending crossings (above → below) and ascending crossings
    // (below → above), with linearly-interpolated timestamps.
    let mut descending: Vec<i64> = Vec::new();
    let mut ascending: Vec<i64> = Vec::new();

    let start = *dt - Duration::minutes(SPAN_MINS);
    let mut prev_t = start;
    let mut prev_alt = sun_alt(&start) - level_deg;
    let steps = (2 * SPAN_MINS) / STEP_MINS;
    for i in 1..=steps {
        let t = start + Duration::minutes(i * STEP_MINS);
        let alt = sun_alt(&t) - level_deg;
        if prev_alt > 0.0 && alt <= 0.0 {
            descending.push(interpolate_zero(&prev_t, prev_alt, &t, alt));
        } else if prev_alt < 0.0 && alt >= 0.0 {
            ascending.push(interpolate_zero(&prev_t, prev_alt, &t, alt));
        }
        prev_t = t;
        prev_alt = alt;
    }

    let now_ts = dt.timestamp();
    let currently_below = sun_alt(dt) < level_deg;

    let (dusk, dawn) = if currently_below {
        let dusk = descending.iter().copied().filter(|&ts| ts <= now_ts).max();
        let dawn = ascending.iter().copied().filter(|&ts| ts >= now_ts).min();
        (dusk, dawn)
    } else {
        let dusk = descending.iter().copied().filter(|&ts| ts >= now_ts).min();
        let dawn = dusk.and_then(|d| ascending.iter().copied().filter(|&ts| ts > d).min());
        (dusk, dawn)
    };

    (dusk, dawn)
}

/// Linear interpolation of the zero crossing between two (time, value) samples.
fn interpolate_zero(t0: &DateTime<Utc>, v0: f64, t1: &DateTime<Utc>, v1: f64) -> i64 {
    let denom = v0 - v1;
    if denom.abs() < f64::EPSILON {
        return t0.timestamp();
    }
    let frac = v0 / denom; // in [0,1] for a genuine sign change
    let secs = (t1.timestamp() - t0.timestamp()) as f64 * frac;
    t0.timestamp() + secs.round() as i64
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn utc(y: i32, mo: u32, d: u32, h: u32, mi: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(y, mo, d, h, mi, 0).single().unwrap()
    }

    #[test]
    fn sun_declination_tracks_the_solstices_and_equinox() {
        // Summer solstice: Sun declination ≈ +23.44°.
        let (_, dec_jun) = sun_equatorial(&utc(2024, 6, 21, 0, 0));
        assert!(dec_jun > 23.0, "June solstice dec was {dec_jun}");

        // Winter solstice: ≈ −23.44°.
        let (_, dec_dec) = sun_equatorial(&utc(2024, 12, 21, 12, 0));
        assert!(dec_dec < -23.0, "December solstice dec was {dec_dec}");

        // March equinox: declination near 0.
        let (_, dec_mar) = sun_equatorial(&utc(2024, 3, 20, 3, 0));
        assert!(dec_mar.abs() < 1.0, "March equinox dec was {dec_mar}");
    }

    #[test]
    fn moon_illumination_matches_known_phases() {
        // 2024-01-11 11:57 UTC was a NEW moon.
        let new_moon = moon_illumination_percent(&utc(2024, 1, 11, 12, 0));
        assert!(new_moon < 4.0, "new moon illumination was {new_moon}%");

        // 2024-01-25 17:54 UTC was a FULL moon.
        let full_moon = moon_illumination_percent(&utc(2024, 1, 25, 18, 0));
        assert!(full_moon > 96.0, "full moon illumination was {full_moon}%");

        // First quarter (~2024-01-18) should be roughly half lit.
        let quarter = moon_illumination_percent(&utc(2024, 1, 18, 3, 0));
        assert!(
            (30.0..70.0).contains(&quarter),
            "first-quarter illumination was {quarter}%"
        );
    }

    #[test]
    fn moon_position_is_finite_and_in_range() {
        let (ra, dec) = moon_equatorial(&utc(2024, 1, 25, 18, 0));
        assert!(ra.is_finite() && (0.0..360.0).contains(&ra), "moon ra {ra}");
        assert!(dec.is_finite() && dec.abs() <= 90.0, "moon dec {dec}");
    }

    #[test]
    fn twilight_bracket_has_evening_dusk_before_morning_dawn() {
        // Mid-northern latitude, midwinter night: a full astronomical night
        // exists. Sample at local midnight-ish (≈ 05:00 UTC at lon −75°, i.e.
        // ~midnight EST) so the Sun is well below −18°.
        let tw = twilight_bracket(&utc(2024, 1, 1, 5, 0), 40.0, -75.0);
        let dusk = tw.astronomical_dusk.expect("astro dusk");
        let dawn = tw.astronomical_dawn.expect("astro dawn");
        assert!(dusk < dawn, "dusk {dusk} should precede dawn {dawn}");
        // Civil twilight brackets nautical brackets astronomical.
        assert!(tw.civil_dusk.unwrap() < tw.nautical_dusk.unwrap());
        assert!(tw.nautical_dusk.unwrap() < dusk);
        assert!(dawn < tw.nautical_dawn.unwrap());
        assert!(tw.nautical_dawn.unwrap() < tw.civil_dawn.unwrap());
    }
}
