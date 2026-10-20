//! Meridian Flip Calculations
//!
//! This module provides astronomical calculations for determining when a target
//! crosses the meridian and when a meridian flip should be performed.

use chrono::{DateTime, Datelike, Timelike, Utc};

/// Pier side enumeration for German Equatorial Mounts
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PierSide {
    /// Mount is on the east side of the pier (pointing west)
    East,
    /// Mount is on the west side of the pier (pointing east)
    West,
    /// Unknown pier side (mount doesn't support reporting)
    Unknown,
}

/// Calculate the UTC time at which a target crosses the meridian for an
/// observer at `longitude` (west-negative).
pub fn calculate_meridian_crossing(
    ra_hours: f64,
    longitude: f64,
    current_time: DateTime<Utc>,
) -> DateTime<Utc> {
    // Calculate Julian Day for current time
    let jd = julian_day(&current_time);

    // Calculate Local Sidereal Time
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

    // Convert sidereal hours to solar seconds
    // 1 sidereal hour = 0.99726957 solar hours = 3589.77 solar seconds
    let sidereal_to_solar = 0.99726957;
    let solar_hours = time_to_crossing * sidereal_to_solar;
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
    let mut ha = lst_hours - ra_hours;

    // Normalize to -12 to +12 range
    while ha < -12.0 {
        ha += 24.0;
    }
    while ha > 12.0 {
        ha -= 24.0;
    }

    ha
}

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
    let jd = julian_day(&time);
    let lst = local_sidereal_time(jd, longitude);
    let ha = hour_angle(ra_hours, lst);

    // Convert to radians
    let ha_rad = (ha * 15.0).to_radians(); // Convert hours to degrees, then to radians
    let dec_rad = dec_degrees.to_radians();
    let lat_rad = latitude.to_radians();

    // Calculate altitude using the altitude formula
    let sin_alt = lat_rad.sin() * dec_rad.sin() + lat_rad.cos() * dec_rad.cos() * ha_rad.cos();

    sin_alt.asin().to_degrees()
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

/// Calculate Julian Day from UTC DateTime
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

/// Calculate Local Sidereal Time in hours
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
        // Create a test time
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

    #[test]
    fn test_julian_day_epoch() {
        // J2000 epoch: January 1, 2000, 12:00 TT (approximately 11:58:56 UTC)
        let j2000 = Utc.with_ymd_and_hms(2000, 1, 1, 12, 0, 0).unwrap();
        let jd = julian_day(&j2000);

        // Should be very close to 2451545.0
        assert!((jd - 2451545.0).abs() < 0.01);
    }

    // Consolidation parity (release pass, Wave C2)
    //
    // `bridge/src/unified_device_ops.rs` carried private `julian_day` /
    // `local_sidereal_time` copies and now imports these. The retired bodies
    // are transcribed verbatim below and compared with exact `==` on f64,
    // not an epsilon: a tolerance would pass even if the bridge's mount
    // altitude and AIRMASS fallback started disagreeing with the sequencer's.

    /// The body deleted from `unified_device_ops.rs:2133`. Note it cast
    /// `(y + 4716) as f64` after integer addition where this module widens
    /// first — exact either way for calendar years, which is the point.
    fn retired_bridge_julian_day(dt: chrono::DateTime<Utc>) -> f64 {
        use chrono::{Datelike, Timelike};

        let year = dt.year();
        let month = dt.month() as i32;
        let day = dt.day() as f64;
        let hour = dt.hour() as f64 + dt.minute() as f64 / 60.0 + dt.second() as f64 / 3600.0;

        let (y, m) = if month <= 2 {
            (year - 1, month + 12)
        } else {
            (year, month)
        };

        let a = (y as f64 / 100.0).floor();
        let b = 2.0 - a + (a / 4.0).floor();

        (365.25 * (y + 4716) as f64).floor()
            + (30.6001 * (m + 1) as f64).floor()
            + day
            + hour / 24.0
            + b
            - 1524.5
    }

    /// The body deleted from `unified_device_ops.rs:2159`.
    fn retired_bridge_local_sidereal_time(jd: f64, longitude: f64) -> f64 {
        let t = (jd - 2451545.0) / 36525.0;

        let gmst = 280.46061837 + 360.98564736629 * (jd - 2451545.0) + 0.000387933 * t * t
            - t * t * t / 38710000.0;

        let lst = (gmst + longitude) % 360.0;
        if lst < 0.0 {
            (lst + 360.0) / 15.0
        } else {
            lst / 15.0
        }
    }

    /// Instants walking the month-rollback branch, leap day, the century and
    /// 400-year Gregorian corrections, midnight, and both sides of J2000.
    fn parity_instants() -> Vec<chrono::DateTime<Utc>> {
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
    fn julian_day_is_bit_identical_to_the_retired_bridge_copy() {
        for dt in parity_instants() {
            assert_eq!(
                julian_day(&dt),
                retired_bridge_julian_day(dt),
                "julian_day diverged at {dt}"
            );
        }
    }

    #[test]
    fn local_sidereal_time_is_bit_identical_to_the_retired_bridge_copy() {
        // Longitudes east, west, on the prime meridian, and past the
        // antimeridian in both directions so the negative branch runs.
        let longitudes = [0.0, -122.4194, 151.2093, 179.9999, -179.9999, -400.0];
        for dt in parity_instants() {
            let jd = julian_day(&dt);
            for lon in longitudes {
                assert_eq!(
                    local_sidereal_time(jd, lon),
                    retired_bridge_local_sidereal_time(jd, lon),
                    "local_sidereal_time diverged at {dt} lon={lon}"
                );
            }
        }
    }

    #[test]
    fn local_sidereal_time_stays_in_range() {
        let longitudes = [0.0, -122.4194, 151.2093, 179.9999, -179.9999, -400.0];
        for dt in parity_instants() {
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

    #[test]
    fn scheduling_astronomy_is_a_deliberately_separate_julian_date() {
        // Pins the non-adoption note on `scheduling::astronomy::julian_date`.
        // That one is Fliegel-Van Flandern on a MILLISECOND day fraction, kept
        // byte-compatible with the Dart planetarium so `scoring` can assert
        // numeric parity against it. This module's is Meeus on a WHOLE-SECOND
        // day fraction.
        //
        // On a whole-second instant the two agree exactly — which is why this
        // consolidation could not simply pick one and be done: they are the
        // same number right up until they are not.
        for dt in parity_instants() {
            assert_eq!(
                julian_day(&dt),
                crate::scheduling::astronomy::julian_date(&dt),
                "whole-second Julian Dates should coincide at {dt}"
            );
        }

        // Add sub-second time and they part company, because `julian_day`
        // truncates at the second and `julian_date` does not. Merging them
        // would therefore move one caller's numbers.
        let sub_second = Utc
            .with_ymd_and_hms(2026, 8, 13, 3, 21, 44)
            .unwrap()
            .with_nanosecond(617_000_000)
            .unwrap();
        assert_ne!(
            julian_day(&sub_second),
            crate::scheduling::astronomy::julian_date(&sub_second),
            "the two forms must not silently agree on a sub-second instant"
        );
    }
}
