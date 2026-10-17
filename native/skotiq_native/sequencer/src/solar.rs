//! Single source of truth for "where is the Sun".
//!
//! Every consumer derives from here — the daylight start gate, the `WaitTime`
//! twilight instruction and the `DawnApproaching` trigger — so "wait until
//! astronomical dark" and "stop at dawn" are calibrated against one Sun.
//! Separate implementations drift: one omitting the equation of time puts the
//! two up to ±16 minutes apart over the year.
//!
//! Everything here derives from one low-precision series (mean longitude /
//! mean anomaly / ecliptic longitude), accurate to roughly a minute of arc,
//! which is far finer than any scheduling decision the sequencer makes.

use chrono::{DateTime, NaiveTime, Utc};

/// Which side of solar noon the caller wants: the morning crossing of the
/// altitude threshold (dawn / sunrise) or the evening one (dusk / sunset).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SunCrossing {
    Rising,
    Setting,
}

/// The Sun never RISES to the requested altitude on the reference date: its
/// daily maximum stays below the threshold. For a −18° twilight threshold that
/// is polar night — it never stops being astronomically dark, so dawn never
/// comes. [`time_of_sun_altitude`] returns this rather than fabricating a time.
pub const SUN_ALTITUDE_NEVER_REACHED: i64 = i64::MAX;

/// Apparent equatorial coordinates of the Sun for a Julian Day.
///
/// Returns `(right ascension in hours [0, 24), declination in degrees)`.
pub fn sun_equatorial(jd: f64) -> (f64, f64) {
    let n = jd - 2451545.0;
    let ecliptic_longitude_rad = sun_ecliptic_longitude_rad(n);
    let obliquity_rad = obliquity_rad(n);

    let declination = (obliquity_rad.sin() * ecliptic_longitude_rad.sin())
        .asin()
        .to_degrees();
    let right_ascension_hours = (ecliptic_longitude_rad.sin() * obliquity_rad.cos())
        .atan2(ecliptic_longitude_rad.cos())
        .to_degrees()
        .rem_euclid(360.0)
        / 15.0;

    (right_ascension_hours, declination)
}

/// Equation of time in minutes: apparent solar time minus mean solar time.
/// Solar noon at longitude `lon` is `12h - lon/15 - eot/60` UTC.
pub fn equation_of_time_minutes(jd: f64) -> f64 {
    let n = jd - 2451545.0;
    let mean_longitude_rad = mean_longitude_degrees(n).to_radians();
    let mean_anomaly_rad = mean_anomaly_degrees(n).to_radians();
    let y = (obliquity_rad(n) / 2.0).tan().powi(2);

    4.0 * (y * (2.0 * mean_longitude_rad).sin()
        - 2.0 * EARTH_ORBIT_ECCENTRICITY * mean_anomaly_rad.sin()
        + 4.0
            * EARTH_ORBIT_ECCENTRICITY
            * y
            * mean_anomaly_rad.sin()
            * (2.0 * mean_longitude_rad).cos()
        - 0.5 * y * y * (4.0 * mean_longitude_rad).sin()
        - 1.25
            * EARTH_ORBIT_ECCENTRICITY
            * EARTH_ORBIT_ECCENTRICITY
            * (2.0 * mean_anomaly_rad).sin())
    .to_degrees()
}

/// The Sun's altitude in degrees above the horizon at `at`, for an observer at
/// `latitude` / `longitude` (degrees). Positive = above the horizon.
pub fn sun_altitude_degrees(latitude: f64, longitude: f64, at: &DateTime<Utc>) -> f64 {
    let jd = crate::meridian::julian_day(at);
    let (sun_ra_hours, sun_dec) = sun_equatorial(jd);

    let lst = crate::meridian::local_sidereal_time(jd, longitude);
    let ha_rad = ((lst - sun_ra_hours) * 15.0).to_radians();
    let dec_rad = sun_dec.to_radians();
    let lat_rad = latitude.to_radians();

    (lat_rad.sin() * dec_rad.sin() + lat_rad.cos() * dec_rad.cos() * ha_rad.cos())
        .asin()
        .to_degrees()
}

/// Unix timestamp of the next time the Sun crosses `altitude_degrees` on the
/// requested side of solar noon.
///
/// Two sentinels, both of which mean "do not invent a time". They preserve the
/// dispositions the twilight instruction and the dawn trigger already had (the
/// legacy comments labelled the two polar cases the wrong way round, but the
/// branches themselves were right):
/// * [`SUN_ALTITUDE_NEVER_REACHED`] — the Sun's daily maximum is below the
///   threshold, so it never rises to it. Polar night for a −18° threshold:
///   dawn never comes and a dawn trigger must stay inert.
/// * `now` — the Sun's daily minimum is above the threshold, so it never
///   descends to it. Polar day for a −18° threshold: it never gets
///   astronomically dark, and the caller is told the crossing is already
///   behind it rather than being made to wait forever.
pub fn time_of_sun_altitude(
    latitude: f64,
    longitude: f64,
    altitude_degrees: f64,
    crossing: SunCrossing,
) -> i64 {
    time_of_sun_altitude_at(latitude, longitude, altitude_degrees, crossing, &Utc::now())
}

/// [`time_of_sun_altitude`] against an explicit reference instant, so the
/// result is reproducible in tests.
pub fn time_of_sun_altitude_at(
    latitude: f64,
    longitude: f64,
    altitude_degrees: f64,
    crossing: SunCrossing,
    now: &DateTime<Utc>,
) -> i64 {
    let jd = crate::meridian::julian_day(now);
    let (_, declination) = sun_equatorial(jd);
    let equation_of_time = equation_of_time_minutes(jd);

    let lat_rad = latitude.to_radians();
    let dec_rad = declination.to_radians();
    let alt_rad = altitude_degrees.to_radians();

    // cos(H) = (sin(alt) - sin(lat)·sin(dec)) / (cos(lat)·cos(dec))
    let cos_h = (alt_rad.sin() - lat_rad.sin() * dec_rad.sin()) / (lat_rad.cos() * dec_rad.cos());
    if cos_h > 1.0 {
        return SUN_ALTITUDE_NEVER_REACHED;
    }
    if cos_h < -1.0 {
        return now.timestamp();
    }

    let hours_from_noon = cos_h.acos().to_degrees() / 15.0;
    let solar_noon_utc = 12.0 - longitude / 15.0 - equation_of_time / 60.0;
    let crossing_hour_utc = match crossing {
        SunCrossing::Rising => solar_noon_utc - hours_from_noon,
        SunCrossing::Setting => solar_noon_utc + hours_from_noon,
    };

    let seconds_from_midnight = (crossing_hour_utc.rem_euclid(24.0) * 3600.0).round();
    // rem_euclid(24.0) bounds the hour to [0, 24), so the rounded second count
    // can only reach 86400 when it lands exactly on midnight; clamp so
    // `from_num_seconds_from_midnight_opt` always has a valid argument.
    let seconds_from_midnight = seconds_from_midnight.clamp(0.0, 86_399.0) as u32;
    let time = NaiveTime::from_num_seconds_from_midnight_opt(seconds_from_midnight, 0)
        .unwrap_or(NaiveTime::MIN);

    let timestamp =
        DateTime::<Utc>::from_naive_utc_and_offset(now.date_naive().and_time(time), Utc)
            .timestamp();

    // Today's crossing has already happened — the caller always wants the next
    // one. The declination is a day-scale quantity, so reusing today's is
    // accurate to well under a minute.
    if timestamp < now.timestamp() {
        timestamp + 86_400
    } else {
        timestamp
    }
}

const EARTH_ORBIT_ECCENTRICITY: f64 = 0.0167;

fn mean_longitude_degrees(days_since_j2000: f64) -> f64 {
    (280.46 + 0.9856474 * days_since_j2000).rem_euclid(360.0)
}

fn mean_anomaly_degrees(days_since_j2000: f64) -> f64 {
    (357.528 + 0.9856003 * days_since_j2000).rem_euclid(360.0)
}

fn sun_ecliptic_longitude_rad(days_since_j2000: f64) -> f64 {
    let mean_anomaly_rad = mean_anomaly_degrees(days_since_j2000).to_radians();
    (mean_longitude_degrees(days_since_j2000)
        + 1.915 * mean_anomaly_rad.sin()
        + 0.020 * (2.0 * mean_anomaly_rad).sin())
    .to_radians()
}

fn obliquity_rad(days_since_j2000: f64) -> f64 {
    (23.439 - 0.0000004 * days_since_j2000).to_radians()
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    // The three implementations this module replaced, kept verbatim as test
    // references. Parity against the first two is required; the third is here
    // to prove the equation-of-time error it carried is gone.

    /// `node::context::approximate_sun_equatorial_coords`, verbatim.
    fn legacy_context_sun_coords(days_since_j2000: f64) -> (f64, f64) {
        let mean_longitude = (280.46 + 0.9856474 * days_since_j2000).rem_euclid(360.0);
        let mean_anomaly = (357.528 + 0.9856003 * days_since_j2000).rem_euclid(360.0);
        let ecliptic_longitude = mean_longitude
            + 1.915 * mean_anomaly.to_radians().sin()
            + 0.020 * (2.0 * mean_anomaly.to_radians()).sin();
        let obliquity = 23.439 - 0.0000004 * days_since_j2000;
        let ecliptic_longitude_rad = ecliptic_longitude.to_radians();
        let obliquity_rad = obliquity.to_radians();
        let sun_dec = (obliquity_rad.sin() * ecliptic_longitude_rad.sin())
            .asin()
            .to_degrees();
        let sun_ra = (ecliptic_longitude_rad.sin() * obliquity_rad.cos())
            .atan2(ecliptic_longitude_rad.cos())
            .to_degrees()
            .rem_euclid(360.0)
            / 15.0;
        (sun_ra, sun_dec)
    }

    /// `instructions::calculate_solar_position`, verbatim.
    fn legacy_instruction_solar_position(jd: f64) -> (f64, f64) {
        let n = jd - 2451545.0;
        let l = (280.460 + 0.9856474 * n) % 360.0;
        let g = (357.528 + 0.9856003 * n) % 360.0;
        let g_rad = g.to_radians();
        let lambda = l + 1.915 * g_rad.sin() + 0.020 * (2.0 * g_rad).sin();
        let lambda_rad = lambda.to_radians();
        let epsilon = 23.439 - 0.0000004 * n;
        let epsilon_rad = epsilon.to_radians();
        let declination = (epsilon_rad.sin() * lambda_rad.sin()).asin().to_degrees();
        let y = (epsilon_rad / 2.0).tan().powi(2);
        let l_rad = l.to_radians();
        let eot = 4.0
            * (y * (2.0 * l_rad).sin() - 2.0 * 0.0167 * g_rad.sin()
                + 4.0 * 0.0167 * y * g_rad.sin() * (2.0 * l_rad).cos()
                - 0.5 * y * y * (4.0 * l_rad).sin()
                - 1.25 * 0.0167 * 0.0167 * (2.0 * g_rad).sin())
            .to_degrees();
        (declination, eot)
    }

    /// `triggers::calculate_dawn_time`, verbatim — Cooper's declination and no
    /// equation-of-time term.
    fn legacy_cooper_dawn(latitude: f64, longitude: f64, now: &DateTime<Utc>) -> i64 {
        use chrono::Datelike;
        let today = now.date_naive();
        let day_of_year = f64::from(today.ordinal());
        let declination: f64 = 23.45
            * (360.0_f64 * (284.0 + day_of_year) / 365.0)
                .to_radians()
                .sin();
        let dec_rad = declination.to_radians();
        let lat_rad = latitude.to_radians();
        let alt_rad = (-18.0_f64).to_radians();
        let cos_h =
            (alt_rad.sin() - lat_rad.sin() * dec_rad.sin()) / (lat_rad.cos() * dec_rad.cos());
        if cos_h > 1.0 {
            return i64::MAX;
        }
        if cos_h < -1.0 {
            return now.timestamp();
        }
        let hour_angle = cos_h.acos().to_degrees();
        let solar_noon_utc = 12.0 - longitude / 15.0;
        let dawn_hour_utc = solar_noon_utc - hour_angle / 15.0;
        let dawn_hour = dawn_hour_utc.rem_euclid(24.0);
        let dawn_minutes = (dawn_hour.fract() * 60.0) as u32;
        let dawn_hour = dawn_hour as u32;
        let dawn_datetime = today
            .and_hms_opt(dawn_hour, dawn_minutes, 0)
            .or_else(|| today.and_hms_opt(6, 0, 0))
            .unwrap_or_else(|| today.and_time(NaiveTime::MIN));
        let ts = DateTime::<Utc>::from_naive_utc_and_offset(dawn_datetime, Utc).timestamp();
        if ts < now.timestamp() {
            ts + 86_400
        } else {
            ts
        }
    }

    fn at(y: i32, m: u32, d: u32, h: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(y, m, d, h, 0, 0).unwrap()
    }

    /// Sample sites spanning the latitudes the app supports, plus both
    /// longitude signs so an equation-of-time sign error cannot hide.
    const SITES: [(&str, f64, f64); 5] = [
        ("New York", 40.71, -74.01),
        ("Sydney", -33.87, 151.21),
        ("Reykjavik", 64.13, -21.90),
        ("Nairobi", -1.29, 36.82),
        ("Santiago", -33.45, -70.67),
    ];

    const DATES: [(i32, u32, u32); 4] = [
        (2026, 2, 11), // equation of time near its -14 min extreme
        (2026, 5, 14), // near its +4 min extreme
        (2026, 7, 26), // near its -6 min extreme
        (2026, 11, 3), // near its +16 min extreme
    ];

    #[test]
    fn sun_equatorial_matches_the_daylight_gate_implementation_bit_for_bit() {
        for days in (-3650..=3650).step_by(97) {
            let days = f64::from(days);
            let jd = 2451545.0 + days;
            assert_eq!(
                sun_equatorial(jd),
                legacy_context_sun_coords(days),
                "unified sun_equatorial must reproduce the daylight gate's math exactly"
            );
        }
    }

    #[test]
    fn declination_and_equation_of_time_match_the_twilight_implementation() {
        for days in (-3650..=3650).step_by(97) {
            let jd = 2451545.0 + f64::from(days);
            let (legacy_dec, legacy_eot) = legacy_instruction_solar_position(jd);
            let (_, dec) = sun_equatorial(jd);
            assert!(
                (dec - legacy_dec).abs() < 1e-9,
                "declination drifted from the twilight implementation at jd {jd}: \
                 {dec} vs {legacy_dec}"
            );
            assert!(
                (equation_of_time_minutes(jd) - legacy_eot).abs() < 1e-9,
                "equation of time drifted from the twilight implementation at jd {jd}"
            );
        }
    }

    /// The property that matters: at the instant we report as the -18°
    /// crossing, the Sun really is at -18°.
    #[test]
    fn reported_crossings_land_on_the_requested_altitude() {
        for (name, lat, lon) in SITES {
            for (y, m, d) in DATES {
                let now = at(y, m, d, 0);
                for crossing in [SunCrossing::Rising, SunCrossing::Setting] {
                    let ts = time_of_sun_altitude_at(lat, lon, -18.0, crossing, &now);
                    if ts == SUN_ALTITUDE_NEVER_REACHED || ts == now.timestamp() {
                        continue;
                    }
                    let when = DateTime::from_timestamp(ts, 0).expect("in range");
                    let altitude = sun_altitude_degrees(lat, lon, &when);
                    assert!(
                        (altitude + 18.0).abs() < 0.5,
                        "{name} {y}-{m}-{d} {crossing:?}: reported crossing has the Sun at \
                         {altitude:.2}°, not -18°"
                    );
                }
            }
        }
    }

    /// A Cooper / no-equation-of-time dawn puts the Sun as much as several
    /// degrees away from -18°, so "stop at dawn" and "wait for astronomical
    /// dark" end up calibrated against different suns.
    #[test]
    fn the_unified_dawn_is_closer_to_true_astronomical_twilight_than_cooper_was() {
        let mut worst_legacy_error = 0.0_f64;
        for (name, lat, lon) in SITES {
            for (y, m, d) in DATES {
                let now = at(y, m, d, 0);
                let unified = time_of_sun_altitude_at(lat, lon, -18.0, SunCrossing::Rising, &now);
                let legacy = legacy_cooper_dawn(lat, lon, &now);
                if unified == SUN_ALTITUDE_NEVER_REACHED || legacy == i64::MAX {
                    continue;
                }

                let unified_error = (sun_altitude_degrees(
                    lat,
                    lon,
                    &DateTime::from_timestamp(unified, 0).expect("in range"),
                ) + 18.0)
                    .abs();
                let legacy_error = (sun_altitude_degrees(
                    lat,
                    lon,
                    &DateTime::from_timestamp(legacy, 0).expect("in range"),
                ) + 18.0)
                    .abs();
                worst_legacy_error = worst_legacy_error.max(legacy_error);
                assert!(
                    unified_error <= legacy_error + 1e-6,
                    "{name} {y}-{m}-{d}: unified dawn is {unified_error:.3}° off -18° \
                     while the Cooper dawn was {legacy_error:.3}° off"
                );
            }
        }
        assert!(
            worst_legacy_error > 1.0,
            "the Cooper dawn was supposed to be materially wrong somewhere in this \
             sample; if it no longer is, this regression test proves nothing"
        );
    }

    /// Dawn and dusk are the same computation mirrored about solar noon; if
    /// they ever stop agreeing, one of the two callers has drifted again.
    #[test]
    fn dawn_and_dusk_are_symmetric_about_solar_noon() {
        for (name, lat, lon) in SITES {
            for (y, m, d) in DATES {
                let now = at(y, m, d, 0);
                let dawn = time_of_sun_altitude_at(lat, lon, -18.0, SunCrossing::Rising, &now);
                let dusk = time_of_sun_altitude_at(lat, lon, -18.0, SunCrossing::Setting, &now);
                let sentinel = |t: i64| t == SUN_ALTITUDE_NEVER_REACHED || t == now.timestamp();
                if sentinel(dawn) || sentinel(dusk) {
                    continue;
                }
                let jd = crate::meridian::julian_day(&now);
                let solar_noon_hour = 12.0 - lon / 15.0 - equation_of_time_minutes(jd) / 60.0;
                let noon_secs = (solar_noon_hour.rem_euclid(24.0) * 3600.0).round() as i64;
                let day = 86_400;
                let dawn_offset = (noon_secs - dawn.rem_euclid(day)).rem_euclid(day);
                let dusk_offset = (dusk.rem_euclid(day) - noon_secs).rem_euclid(day);
                assert!(
                    (dawn_offset - dusk_offset).abs() <= 2,
                    "{name} {y}-{m}-{d}: dawn is {dawn_offset}s before solar noon but dusk \
                     is {dusk_offset}s after it"
                );
            }
        }
    }

    #[test]
    fn polar_day_and_polar_night_return_their_sentinels() {
        // Longyearbyen at midsummer: the Sun's daily MINIMUM is about +11.6°,
        // so it never descends to -18°. Polar day — the crossing is reported as
        // already behind us so nothing waits forever for a dark that never comes.
        let midsummer = at(2026, 6, 21, 0);
        assert_eq!(
            time_of_sun_altitude_at(78.22, 15.63, -18.0, SunCrossing::Rising, &midsummer),
            midsummer.timestamp()
        );
        // 86°N in midwinter: the Sun's daily MAXIMUM is about -19.4°, so it
        // never rises to -18°. Polar night — dawn never comes and the dawn
        // trigger must stay inert rather than firing on an invented time.
        assert_eq!(
            time_of_sun_altitude_at(86.0, 0.0, -18.0, SunCrossing::Rising, &at(2026, 12, 21, 0)),
            SUN_ALTITUDE_NEVER_REACHED
        );
    }

    #[test]
    fn a_crossing_already_past_today_rolls_to_tomorrow() {
        // 23:00 UTC in New York is well after that day's dusk.
        let late = at(2026, 2, 11, 23);
        let dusk = time_of_sun_altitude_at(40.71, -74.01, -18.0, SunCrossing::Setting, &late);
        assert!(
            dusk > late.timestamp(),
            "the next crossing must always be in the future"
        );
        assert!(
            dusk - late.timestamp() < 86_400,
            "and it must be the very next one, not a day later"
        );
    }
}
