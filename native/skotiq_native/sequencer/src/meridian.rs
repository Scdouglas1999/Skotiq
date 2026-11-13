//! Meridian Flip Calculations
//!
//! This module provides astronomical calculations for determining when a target
//! crosses the meridian and when a meridian flip should be performed.

use chrono::{DateTime, Datelike, Timelike, Utc};

pub use skotiq_device::PierSide;

/// Calculate the UTC time at which a target crosses the meridian for an
/// observer at `longitude` (west-negative).
pub fn calculate_meridian_crossing(
    ra_hours: f64,
    longitude: f64,
    current_time: DateTime<Utc>,
) -> DateTime<Utc> {
    let jd = julian_day(&current_time);

    let lst = local_sidereal_time(jd, longitude);

    // Target crosses meridian when LST = RA
    // Calculate time difference
    let mut time_to_crossing = ra_hours - lst;

    // Normalize to 0-24 hour range
    if time_to_crossing < 0.0 {
        time_to_crossing += 24.0;
    }
    if time_to_crossing > 24.0 {
        time_to_crossing -= 24.0;
    }

    let solar_hours = time_to_crossing / SIDEREAL_PER_SOLAR;
    // Why: `time_to_crossing` is normalized to [0, 24]
    // hours by the loop above; `solar_hours * 3600` is therefore ≤ ~86400.
    // Rust 1.45+ defines f64 → i64 as saturating-on-overflow / 0-on-NaN,
    // which for a bounded sidereal interval is the desired behavior.
    let seconds = (solar_hours * 3600.0).round() as i64;

    current_time + chrono::Duration::seconds(seconds)
}

/// Precess a J2000 target (RA hours, Dec degrees) to mean-of-date at `when`.
///
/// Hour angle is LST − RA, and LST is a time of date, so the RA it is taken
/// against must be of date too. Target coordinates in the sequencer are J2000
/// (catalogues, plate solves), and in 2026 the two frames are ~1.3 min of RA
/// apart: an hour angle from the J2000 RA puts the meridian that far off, and a
/// flip fired inside that window slews the mount without changing pier side.
/// Every hour angle or altitude taken from a target's coordinates goes through
/// here first. Same rotation as [`crate::axis_j2000_to_date`].
pub fn target_of_date(ra_hours: f64, dec_degrees: f64, when: DateTime<Utc>) -> (f64, f64) {
    let (ra_degrees, dec) = crate::axis_j2000_to_date(ra_hours * 15.0, dec_degrees, when);
    (ra_degrees / 15.0, dec)
}

/// Calculate a target's hour angle in hours from its RA and the Local Sidereal
/// Time, normalized to -12..+12: negative is east of the meridian
/// (approaching), positive is west of it (past the meridian).
pub fn hour_angle(ra_hours: f64, lst_hours: f64) -> f64 {
    wrap_hours(lst_hours - ra_hours)
}

/// A difference of two right ascensions or sidereal times, in hours, as the
/// shorter way round the sky: in (-12, 12]. Half a day either way is +12.
pub fn wrap_hours(delta: f64) -> f64 {
    let wrapped = delta.rem_euclid(24.0);
    if wrapped > 12.0 {
        wrapped - 24.0
    } else {
        wrapped
    }
}

/// Sidereal time elapsed per unit of solar (UTC) time: the rate a target's
/// hour angle grows and a stopped mount's right ascension falls behind.
pub const SIDEREAL_PER_SOLAR: f64 = 1.002_737_909_35;

/// Calculate the UTC time at which a meridian flip should be triggered, given
/// how many minutes past the meridian the flip waits for. Longitude is
/// west-negative.
pub fn calculate_flip_time(
    ra_hours: f64,
    longitude: f64,
    current_time: DateTime<Utc>,
    minutes_past_meridian: f64,
) -> DateTime<Utc> {
    let meridian_crossing = calculate_meridian_crossing(ra_hours, longitude, current_time);
    // Why: `minutes_past_meridian` is a configured
    // threshold in minutes (UI surfaces 0..~30 typically). f64 → i64 uses
    // Rust 1.45+ saturating semantics; for any sane threshold the result
    // is well inside i64 range.
    meridian_crossing + chrono::Duration::seconds((minutes_past_meridian * 60.0) as i64)
}

/// Check whether a mount needs to flip now, given the target, the observer's
/// longitude (west-negative) and how many minutes past the meridian the flip
/// waits for.
pub fn should_flip_now(
    ra_hours: f64,
    longitude: f64,
    current_time: DateTime<Utc>,
    minutes_past_meridian: f64,
) -> bool {
    let jd = julian_day(&current_time);
    let lst = local_sidereal_time(jd, longitude);
    let ha = hour_angle(ra_hours, lst);

    // Flip when hour angle exceeds the threshold (in hours)
    let threshold_hours = minutes_past_meridian / 60.0;
    ha >= threshold_hours
}

/// Determine which side of the pier a German equatorial should be on for a
/// given hour angle, following the ASCOM `SideOfPier` convention: `pierEast`
/// is the mount body on the EAST side of the pier looking WEST, `pierWest` is
/// the body on the WEST side looking EAST. Hour angle 0 counts as past the
/// meridian, which is the side a flip lands on.
pub fn expected_pier_side(hour_angle_hours: f64) -> PierSide {
    if hour_angle_hours < 0.0 {
        // Target has not reached the meridian yet: the mount is on the west
        // side of the pier looking east.
        PierSide::West
    } else {
        // Target is past the meridian: the mount is on the east side of the
        // pier looking west.
        PierSide::East
    }
}

/// Calculate a target's altitude in degrees above the horizon at a given time.
/// Longitude is west-negative.
pub fn calculate_altitude(
    ra_hours: f64,
    dec_degrees: f64,
    latitude: f64,
    longitude: f64,
    time: DateTime<Utc>,
) -> f64 {
    calculate_alt_az(ra_hours, dec_degrees, latitude, longitude, time).0
}

/// Convert equatorial coordinates to horizontal (altitude/azimuth) for an
/// observer at a given time. Longitude is west-negative; the returned azimuth
/// is measured from north through east, in `[0, 360)`.
pub fn calculate_alt_az(
    ra_hours: f64,
    dec_degrees: f64,
    latitude: f64,
    longitude: f64,
    time: DateTime<Utc>,
) -> (f64, f64) {
    let jd = julian_day(&time);
    let lst = local_sidereal_time(jd, longitude);
    let ha_rad = (hour_angle(ra_hours, lst) * 15.0).to_radians();
    let dec_rad = dec_degrees.to_radians();
    let lat_rad = latitude.to_radians();

    let sin_alt = lat_rad.sin() * dec_rad.sin() + lat_rad.cos() * dec_rad.cos() * ha_rad.cos();
    let altitude = sin_alt.clamp(-1.0, 1.0).asin();

    let azimuth = (-ha_rad.sin() * dec_rad.cos())
        .atan2(dec_rad.sin() * lat_rad.cos() - dec_rad.cos() * lat_rad.sin() * ha_rad.cos());

    let azimuth_degrees = azimuth.to_degrees().rem_euclid(360.0);
    (altitude.to_degrees(), azimuth_degrees)
}

/// Inverse of [`calculate_alt_az`]: convert horizontal coordinates back to
/// equatorial for an observer at a given time.
///
/// # Returns
/// `(ra_hours, dec_degrees)` with RA normalized to `[0, 24)`.
pub fn alt_az_to_ra_dec(
    altitude_degrees: f64,
    azimuth_degrees: f64,
    latitude: f64,
    longitude: f64,
    time: DateTime<Utc>,
) -> (f64, f64) {
    let alt_rad = altitude_degrees.to_radians();
    let az_rad = azimuth_degrees.to_radians();
    let lat_rad = latitude.to_radians();

    let sin_dec = alt_rad.sin() * lat_rad.sin() + alt_rad.cos() * lat_rad.cos() * az_rad.cos();
    let dec = sin_dec.clamp(-1.0, 1.0).asin();

    let ha = (-az_rad.sin() * alt_rad.cos())
        .atan2(alt_rad.sin() * lat_rad.cos() - alt_rad.cos() * lat_rad.sin() * az_rad.cos());

    let jd = julian_day(&time);
    let lst = local_sidereal_time(jd, longitude);
    let ra = (lst - ha.to_degrees() / 15.0).rem_euclid(24.0);
    (ra, dec.to_degrees())
}

/// Julian Day of a UTC instant (Meeus, Astronomical Algorithms, 7.1), to the
/// whole second. The one Julian Day the sequencer and the bridge use.
///
/// The second is kept whole on purpose: values computed from two reads of the
/// clock in the same second (a mount read-back and the frame header written
/// from it) come out identical.
pub fn julian_day(dt: &DateTime<Utc>) -> f64 {
    let year = dt.year();
    // Why: `month()` returns u32 in [1, 12]; u32 → i32
    // is SAFE narrowing (12 << i32::MAX). Subsequent arithmetic uses i32.
    let month = dt.month() as i32;
    // Why: `day()` returns u32 in [1, 31]; u32 → f64
    // exact widening.
    let day = f64::from(dt.day());
    // Why: hour/minute/second all u32 in small ranges;
    // u32 → f64 exact widening.
    let hour =
        f64::from(dt.hour()) + f64::from(dt.minute()) / 60.0 + f64::from(dt.second()) / 3600.0;

    let (y, m) = if month <= 2 {
        (year - 1, month + 12)
    } else {
        (year, month)
    };

    // Why: `y` is i32 calendar year (calendrically bounded
    // by chrono::DateTime to ~[-262_144, 262_143]); i32 → f64 exact.
    let a = (f64::from(y) / 100.0).floor();
    let b = 2.0 - a + (a / 4.0).floor();

    // Why: same i32 → f64 exact widening as `a` above.
    (365.25 * (f64::from(y) + 4716.0)).floor()
        + (30.6001 * (f64::from(m) + 1.0)).floor()
        + day
        + hour / 24.0
        + b
        - 1524.5
}

/// Local mean sidereal time in hours, in [0, 24), at Julian Day `jd` for an
/// observer at `longitude` degrees (east positive, west negative); Meeus 12.4.
pub fn local_sidereal_time(jd: f64, longitude: f64) -> f64 {
    let t = (jd - 2451545.0) / 36525.0;

    // Greenwich Mean Sidereal Time in degrees
    let gmst = 280.46061837 + 360.98564736629 * (jd - 2451545.0) + 0.000387933 * t * t
        - t * t * t / 38710000.0;

    // Add longitude to get Local Sidereal Time
    let lst = (gmst + longitude) % 360.0;

    // Convert to hours and normalize

    if lst < 0.0 {
        (lst + 360.0) / 15.0
    } else {
        lst / 15.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    #[test]
    fn test_hour_angle_calculation() {
        // When LST = 12h and RA = 12h, HA should be 0 (on meridian)
        assert!((hour_angle(12.0, 12.0) - 0.0).abs() < 0.001);

        // When LST = 13h and RA = 12h, HA should be +1h (1h past meridian)
        assert!((hour_angle(12.0, 13.0) - 1.0).abs() < 0.001);

        // When LST = 11h and RA = 12h, HA should be -1h (1h before meridian)
        assert!((hour_angle(12.0, 11.0) + 1.0).abs() < 0.001);

        // Test wraparound: LST = 23h and RA = 1h, HA should be -2h
        assert!((hour_angle(1.0, 23.0) + 2.0).abs() < 0.001);
    }

    #[test]
    fn test_hour_angle_normalization() {
        // Test that hour angle is normalized to -12 to +12 range
        let ha = hour_angle(0.0, 15.0);
        assert!((-12.0..=12.0).contains(&ha));

        let ha2 = hour_angle(20.0, 5.0);
        assert!((-12.0..=12.0).contains(&ha2));
    }

    /// ASCOM `pierEast` means the mount body is on the EAST side of the pier
    /// looking WEST, which is where a German equatorial sits once its target
    /// has crossed the meridian (hour angle > 0). The mapping was inverted, so
    /// the simulated mount reported the opposite side from the one a real GEM
    /// would be on for the same pointing.
    #[test]
    fn test_expected_pier_side() {
        // Target east of the meridian (HA < 0): the mount is on the WEST side
        // of the pier, looking east.
        assert_eq!(expected_pier_side(-1.0), PierSide::West);
        assert_eq!(expected_pier_side(-5.0), PierSide::West);

        // Target west of the meridian (HA > 0): the mount is on the EAST side
        // of the pier, looking west.
        assert_eq!(expected_pier_side(1.0), PierSide::East);
        assert_eq!(expected_pier_side(5.0), PierSide::East);

        // Exactly on the meridian counts as past it — the side a flip lands on.
        assert_eq!(expected_pier_side(0.0), PierSide::East);
    }

    #[test]
    fn test_should_flip_now() {
        let test_time = Utc.with_ymd_and_hms(2025, 3, 15, 0, 0, 0).unwrap();

        // For a target at RA = 12h, longitude = -75.0 (Eastern US)
        // Calculate LST at this time
        let jd = julian_day(&test_time);
        let lst = local_sidereal_time(jd, -75.0);

        // Set RA slightly behind LST (just past meridian)
        let ra_hours = lst - 0.1; // 6 minutes past meridian (0.1 hours)

        // Should flip if threshold is less than 6 minutes
        assert!(should_flip_now(ra_hours, -75.0, test_time, 5.0));

        // Should not flip if threshold is more than 6 minutes
        assert!(!should_flip_now(ra_hours, -75.0, test_time, 10.0));
    }

    #[test]
    fn test_meridian_crossing_in_future() {
        let test_time = Utc.with_ymd_and_hms(2025, 3, 15, 12, 0, 0).unwrap();

        // For any RA and longitude, crossing time should be within next 24 hours
        let crossing = calculate_meridian_crossing(10.0, -75.0, test_time);
        let duration = crossing.signed_duration_since(test_time);

        // Should be positive (in future) and less than 24 hours
        assert!(duration.num_seconds() > 0);
        assert!(duration.num_seconds() < 86400);
    }

    #[test]
    fn test_flip_time_calculation() {
        let test_time = Utc.with_ymd_and_hms(2025, 3, 15, 12, 0, 0).unwrap();

        // Calculate flip time for 5 minutes past meridian
        let crossing = calculate_meridian_crossing(10.0, -75.0, test_time);
        let flip_time = calculate_flip_time(10.0, -75.0, test_time, 5.0);

        // Flip time should be 5 minutes after crossing
        let diff = flip_time.signed_duration_since(crossing);
        assert_eq!(diff.num_seconds(), 300); // 5 minutes = 300 seconds
    }

    /// The stored meridian-crossing time is what the MeridianFlip trigger
    /// compares the clock against, so at that instant the target must actually
    /// be on the meridian. The existing tests only checked the answer was
    /// within the next day, which a crossing computed from the wrong sign, the
    /// wrong day length or no sidereal correction all satisfy.
    #[test]
    fn at_the_computed_crossing_the_target_is_on_the_meridian() {
        let longitude = -75.0;
        let start = Utc.with_ymd_and_hms(2026, 9, 14, 1, 30, 0).unwrap();
        let lst_now = local_sidereal_time(julian_day(&start), longitude);
        // Targets east of the meridian by 0.5 h, 6 h and 11.5 h, and one
        // 0.25 h past it (whose next crossing is almost a sidereal day away).
        for ahead in [0.5, 6.0, 11.5, -0.25] {
            let ra = (lst_now + ahead).rem_euclid(24.0);
            let crossing = calculate_meridian_crossing(ra, longitude, start);
            let ha = hour_angle(ra, local_sidereal_time(julian_day(&crossing), longitude));
            assert!(
                ha.abs() * 3600.0 < 2.0,
                "RA {ra:.3}h: hour angle at the computed crossing is {:.1}s",
                ha * 3600.0
            );
            let wait_hours = crossing.signed_duration_since(start).num_seconds() as f64 / 3600.0;
            let expected = ahead.rem_euclid(24.0) * 0.99726957;
            assert!(
                (wait_hours - expected).abs() < 0.001,
                "RA {ra:.3}h: crossing in {wait_hours:.4}h, expected {expected:.4}h"
            );
        }
    }

    /// `calculate_altitude` feeds the AltitudeLimit trigger; it must agree with
    /// the independently pinned `calculate_alt_az` everywhere, not only land in
    /// 0..90 (the only thing the test above checks).
    #[test]
    fn altitude_agrees_with_the_full_horizontal_transform() {
        let (latitude, longitude) = (40.0, -75.0);
        let time = Utc.with_ymd_and_hms(2026, 7, 28, 3, 17, 0).unwrap();
        let lst = local_sidereal_time(julian_day(&time), longitude);
        for (ha, dec) in [(0.0, 10.0), (2.5, 30.0), (-4.0, -20.0), (7.0, 60.0)] {
            let ra = (lst - ha).rem_euclid(24.0);
            let alt = calculate_altitude(ra, dec, latitude, longitude, time);
            let (expected, _) = calculate_alt_az(ra, dec, latitude, longitude, time);
            assert!(
                (alt - expected).abs() < 1e-6,
                "HA {ha}h Dec {dec}: altitude {alt} vs {expected}"
            );
        }
        // Transit of a southern target: 90 - lat + dec.
        let transit = calculate_altitude(lst, 10.0, latitude, longitude, time);
        assert!((transit - 60.0).abs() < 0.01, "transit altitude {transit}");
    }

    #[test]
    fn test_altitude_calculation() {
        // Test altitude for a known configuration
        // Object at RA=12h, Dec=45°, from latitude 45°N
        let test_time = Utc.with_ymd_and_hms(2025, 3, 21, 12, 0, 0).unwrap(); // Vernal equinox noon

        let alt = calculate_altitude(12.0, 45.0, 45.0, 0.0, test_time);

        // Altitude should be reasonable (between 0 and 90 degrees)
        assert!((0.0..=90.0).contains(&alt));
    }

    /// The celestial pole sits at altitude = latitude, due north, for every
    /// observer at every instant. Any error in the transform breaks this.
    #[test]
    fn pole_sits_at_latitude_due_north() {
        let time = Utc.with_ymd_and_hms(2026, 7, 28, 3, 17, 0).unwrap();
        for latitude in [10.0, 40.0, 65.0] {
            let (alt, az) = calculate_alt_az(6.0, 90.0, latitude, -75.0, time);
            assert!(
                (alt - latitude).abs() < 0.01,
                "pole altitude {alt} should equal latitude {latitude}"
            );
            let north_error = (az - 360.0).abs().min(az.abs());
            assert!(north_error < 0.01, "pole azimuth {az} should be due north");
        }
    }

    /// A target whose declination equals the observer's latitude passes through
    /// the zenith at transit, when LST equals its RA.
    #[test]
    fn target_at_transit_reaches_the_zenith() {
        let latitude = 40.0;
        let longitude = -75.0;
        let time = Utc.with_ymd_and_hms(2026, 7, 28, 3, 17, 0).unwrap();
        let lst = local_sidereal_time(julian_day(&time), longitude);

        let (alt, _) = calculate_alt_az(lst, latitude, latitude, longitude, time);
        assert!(
            (alt - 90.0).abs() < 0.01,
            "a target at Dec=latitude transiting overhead should read 90°, got {alt}"
        );
    }

    /// Transit altitude of a southern target from a northern site is
    /// `90 - lat + dec`, and it culminates due south.
    #[test]
    fn southern_target_transits_due_south_at_known_altitude() {
        let latitude = 40.0;
        let longitude = -75.0;
        let dec = 10.0;
        let time = Utc.with_ymd_and_hms(2026, 7, 28, 3, 17, 0).unwrap();
        let lst = local_sidereal_time(julian_day(&time), longitude);

        let (alt, az) = calculate_alt_az(lst, dec, latitude, longitude, time);
        assert!(
            (alt - (90.0 - latitude + dec)).abs() < 0.01,
            "transit altitude {alt} should be {}",
            90.0 - latitude + dec
        );
        assert!((az - 180.0).abs() < 0.01, "culmination azimuth {az} != 180");
    }

    /// Dec −80° from latitude +40° never rises: its maximum possible altitude
    /// is 90 − 40 − 80 = −30°. The mount telemetry has to say so at every hour
    /// angle, which is what makes a horizon limit testable.
    #[test]
    fn permanently_invisible_target_never_reads_above_the_horizon() {
        let base = Utc.with_ymd_and_hms(2026, 7, 28, 0, 0, 0).unwrap();
        for hour in 0..24 {
            let time = base + chrono::Duration::hours(hour);
            let (alt, _) = calculate_alt_az(5.5, -80.0, 40.0, -75.0, time);
            assert!(
                alt <= -29.99,
                "Dec -80 from lat +40 reported altitude {alt} at hour {hour}; it can never \
                 exceed -30"
            );
        }
    }

    /// The horizontal transform must be invertible, or an alt/az slew cannot be
    /// stored as the equatorial pointing it actually produced.
    #[test]
    fn alt_az_round_trips_through_ra_dec() {
        let latitude = 40.0;
        let longitude = -75.0;
        let time = Utc.with_ymd_and_hms(2026, 7, 28, 3, 17, 0).unwrap();

        for (ra, dec) in [(5.5, 30.0), (18.25, -12.0), (0.5, 65.0), (12.0, 0.0)] {
            let (alt, az) = calculate_alt_az(ra, dec, latitude, longitude, time);
            let (ra_back, dec_back) = alt_az_to_ra_dec(alt, az, latitude, longitude, time);
            assert!(
                (dec_back - dec).abs() < 1e-6,
                "Dec {dec} round-tripped to {dec_back}"
            );
            let ra_error = (ra_back - ra).abs().min(24.0 - (ra_back - ra).abs());
            assert!(ra_error < 1e-6, "RA {ra} round-tripped to {ra_back}");
        }
    }

    /// One second of right ascension or sidereal time is 15 arcseconds, so
    /// an arcsecond of sky is this many hours.
    const ARCSECOND_IN_HOURS: f64 = 1.0 / 15.0 / 3600.0;

    fn hms(h: f64, m: f64, s: f64) -> f64 {
        h + m / 60.0 + s / 3600.0
    }

    /// Meeus, Astronomical Algorithms (2nd ed.), examples 7.a and 12.a/12.b.
    #[test]
    fn julian_day_and_sidereal_time_match_published_values() {
        let j2000 = Utc.with_ymd_and_hms(2000, 1, 1, 12, 0, 0).unwrap();
        assert_eq!(julian_day(&j2000), 2_451_545.0);

        let sputnik = Utc.with_ymd_and_hms(1957, 10, 4, 19, 26, 24).unwrap();
        assert!((julian_day(&sputnik) - 2_436_116.31).abs() < 1e-9);

        let midnight = Utc.with_ymd_and_hms(1987, 4, 10, 0, 0, 0).unwrap();
        assert_eq!(julian_day(&midnight), 2_446_895.5);
        let gmst = local_sidereal_time(julian_day(&midnight), 0.0);
        assert!(
            (gmst - hms(13.0, 10.0, 46.3668)).abs() < ARCSECOND_IN_HOURS,
            "GMST {gmst} h"
        );

        let evening = Utc.with_ymd_and_hms(1987, 4, 10, 19, 21, 0).unwrap();
        let gmst = local_sidereal_time(julian_day(&evening), 0.0);
        assert!(
            (gmst - hms(8.0, 34.0, 57.0896)).abs() < ARCSECOND_IN_HOURS,
            "GMST {gmst} h"
        );
        // An observer 77.0656 deg west is that many degrees of sidereal time
        // behind Greenwich.
        let lst = local_sidereal_time(julian_day(&evening), -77.0656);
        assert!(
            (wrap_hours(lst - (gmst - 77.0656 / 15.0))).abs() < ARCSECOND_IN_HOURS,
            "LST {lst} h"
        );
    }

    /// Two reads of the clock inside one second give one Julian Day.
    #[test]
    fn julian_day_is_whole_seconds() {
        let j2000 = Utc.with_ymd_and_hms(2000, 1, 1, 12, 0, 0).unwrap();
        let later = j2000 + chrono::Duration::milliseconds(617);
        assert_eq!(julian_day(&later), julian_day(&j2000));
        let next = j2000 + chrono::Duration::seconds(1);
        let days = julian_day(&next) - julian_day(&j2000);
        assert!(
            (days * 86_400.0 - 1.0).abs() < 1e-4,
            "{} s",
            days * 86_400.0
        );
    }

    #[test]
    fn wrap_hours_takes_the_shorter_way_round() {
        for (delta, wrapped) in [
            (0.0, 0.0),
            (1.5, 1.5),
            (-1.5, -1.5),
            (23.0, -1.0),
            (-23.0, 1.0),
            (12.0, 12.0),
            (-12.0, 12.0),
            (36.0, 12.0),
            (24.0, 0.0),
            (-24.0, 0.0),
            (48.25, 0.25),
            (12.5, -11.5),
            (-12.5, 11.5),
        ] {
            assert!(
                (wrap_hours(delta) - wrapped).abs() < 1e-12,
                "{delta} h wrapped to {}, expected {wrapped}",
                wrap_hours(delta)
            );
        }
        assert_eq!(hour_angle(1.0, 23.0), -2.0);
        assert_eq!(hour_angle(23.0, 1.0), 2.0);
    }

    /// Instants walking the month-rollback branch, leap day, the century and
    /// 400-year Gregorian corrections, midnight, and both sides of J2000.
    fn range_instants() -> Vec<chrono::DateTime<Utc>> {
        vec![
            Utc.with_ymd_and_hms(2000, 1, 1, 12, 0, 0).unwrap(),
            Utc.with_ymd_and_hms(1999, 12, 31, 23, 59, 59).unwrap(),
            Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap(),
            Utc.with_ymd_and_hms(2026, 2, 28, 23, 59, 59).unwrap(),
            Utc.with_ymd_and_hms(2024, 2, 29, 6, 30, 15).unwrap(),
            Utc.with_ymd_and_hms(1900, 3, 1, 0, 0, 0).unwrap(),
            Utc.with_ymd_and_hms(2000, 3, 1, 0, 0, 0).unwrap(),
            Utc.with_ymd_and_hms(2100, 7, 4, 18, 45, 12).unwrap(),
            Utc.with_ymd_and_hms(2026, 8, 13, 3, 21, 44).unwrap(),
            Utc.with_ymd_and_hms(1957, 10, 4, 19, 28, 34).unwrap(),
        ]
    }

    #[test]
    fn local_sidereal_time_stays_in_range() {
        let longitudes = [0.0, -122.4194, 151.2093, 179.9999, -179.9999, -400.0];
        for dt in range_instants() {
            let jd = julian_day(&dt);
            for lon in longitudes {
                let lst = local_sidereal_time(jd, lon);
                assert!(
                    (0.0..24.0).contains(&lst),
                    "LST {lst} out of range at {dt} lon={lon}"
                );
            }
        }
    }
}
