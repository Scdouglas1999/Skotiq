//! Drift-pair math for all-sky polar alignment.
//!
//! Solves for the mount's polar-axis misalignment `(Δaz, Δalt)` from
//! the apparent drift of a tracked star between two solved frames.
//! See [`compute_polar_misalignment_from_drift`] for the full
//! derivation.

use chrono::{DateTime, Utc};

/// Earth's sidereal rotation rate in radians per second.
/// 360° per sidereal day = 360° / 86164.0905s.
pub(super) const SIDEREAL_RATE_RAD_PER_SEC: f64 = 7.292115146706979e-5;

/// Solved frame snapshot used by the drift calculation.
#[derive(Debug, Clone, Copy)]
pub struct SolvedFrame {
    pub ra_deg: f64,
    pub dec_deg: f64,
    pub when: DateTime<Utc>,
}

/// Polar misalignment vector decomposed into azimuth and altitude
/// components, expressed in arcseconds.
///
/// Sign conventions:
///   * `azimuth_error_arcsec` > 0: the mechanical polar axis sits
///     east of the true pole. The user should adjust the azimuth bolt
///     to move it westward.
///   * `altitude_error_arcsec` > 0: the mechanical polar axis sits
///     above the true pole (too high). The user should lower the
///     altitude bolt.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PolarMisalignment {
    pub azimuth_error_arcsec: f64,
    pub altitude_error_arcsec: f64,
}

/// Compute the polar-axis misalignment from a drift pair.
///
/// # Inputs
///
/// * `baseline` — solved coordinates and time of the anchor frame.
/// * `current` — solved coordinates and time of the most recent frame.
/// * `observer_lat_deg`, `observer_lon_deg` — geographic location.
/// * `is_north` — northern hemisphere flag (selects pole direction).
///
/// # Math
///
/// The mount rotates around `p_mech` at sidereal rate `Omega`. In the celestial
/// frame this means the camera vector `v` traces an angular velocity:
///
/// ```text
/// omega_drift = Omega * (p_mech - p_true)
/// ```
///
/// over the elapsed time. The drift of the camera pointing direction in the
/// celestial frame is then:
///
/// ```text
/// dv/dt = omega_drift cross v
/// ```
///
/// We observe `Delta_v = v_current - v_baseline` over elapsed time `T`.
/// Therefore:
///
/// ```text
/// omega_drift cross v_baseline ~= Delta_v / T
/// ```
///
/// We can recover the two components of `omega_drift` perpendicular to
/// `v_baseline` (the component along `v_baseline` is unobservable from a
/// single drift sample). Projecting those two components onto the
/// horizontal (alt, az) basis at the celestial pole yields the (Delta_az,
/// Delta_alt) misalignment vector in radians, which we scale to arcseconds.
///
/// Note that this technique works for **any** pointing direction in the
/// sky, satisfying the "all-sky" requirement. The only configuration that
/// produces poor results is when the optical axis points directly at the
/// celestial pole (in which case the drift signal vanishes for any
/// misalignment direction).
pub fn compute_polar_misalignment_from_drift(
    baseline: &SolvedFrame,
    current: &SolvedFrame,
    observer_lat_deg: f64,
    observer_lon_deg: f64,
    is_north: bool,
) -> PolarMisalignment {
    // Why: i64 milliseconds -> f64 only loses precision above 2^53 ms (~285k
    // years); baseline/current frames are seconds-scale apart in a single session.
    let dt_secs = (current.when - baseline.when).num_milliseconds() as f64 / 1000.0;
    if dt_secs <= 0.0 {
        // Same frame or clock skew — no information yet.
        return PolarMisalignment {
            azimuth_error_arcsec: 0.0,
            altitude_error_arcsec: 0.0,
        };
    }

    let v_baseline = radec_to_unit_vector(baseline.ra_deg, baseline.dec_deg);
    let v_current = radec_to_unit_vector(current.ra_deg, current.dec_deg);

    let dv = (
        v_current.0 - v_baseline.0,
        v_current.1 - v_baseline.1,
        v_current.2 - v_baseline.2,
    );

    // Drift angular-velocity vector (in celestial frame, units rad/s):
    //   ω_perp = v × (Δv / T)
    // BAC-CAB identity: v × (ω × v) = ω(v·v) − v(v·ω) = ω − v(v·ω). For unit v
    // this is the component of ω orthogonal to v.
    let dv_over_t = (dv.0 / dt_secs, dv.1 / dt_secs, dv.2 / dt_secs);
    let omega_perp = (
        v_baseline.1 * dv_over_t.2 - v_baseline.2 * dv_over_t.1,
        v_baseline.2 * dv_over_t.0 - v_baseline.0 * dv_over_t.2,
        v_baseline.0 * dv_over_t.1 - v_baseline.1 * dv_over_t.0,
    );

    // ω_drift = Ω · (p̂_mech − p̂_true) ⇒ p̂_mech − p̂_true = ω_drift / Ω. The
    // perpendicular component we recovered is the same equation projected
    // perpendicular to v. Divide by the sidereal rate to convert from
    // angular velocity to a small unit-vector displacement.
    let delta_unit_perp = (
        omega_perp.0 / SIDEREAL_RATE_RAD_PER_SEC,
        omega_perp.1 / SIDEREAL_RATE_RAD_PER_SEC,
        omega_perp.2 / SIDEREAL_RATE_RAD_PER_SEC,
    );

    // Project the misalignment vector onto the horizontal (alt, az) basis at
    // the celestial pole. With phi = observer latitude and LST in radians:
    //
    //     p̂_true   = (cos(LST)·cos(phi), sin(LST)·cos(phi), sin(phi))   [N]
    //     alt_axis = (cos(LST)·(-sin(phi)), sin(LST)·(-sin(phi)), cos(phi))
    //     az_axis  = (-sin(LST), cos(LST), 0)
    //
    // For the southern hemisphere we flip the pole and altitude axis.
    let lst_hours = crate::local_sidereal_time(crate::julian_day(&current.when), observer_lon_deg);
    let lst_rad = (lst_hours * 15.0).to_radians();
    let phi_rad = observer_lat_deg.to_radians();

    let (alt_axis, az_axis) = if is_north {
        let alt_axis = (
            lst_rad.cos() * (-phi_rad.sin()),
            lst_rad.sin() * (-phi_rad.sin()),
            phi_rad.cos(),
        );
        let az_axis = (-lst_rad.sin(), lst_rad.cos(), 0.0);
        (alt_axis, az_axis)
    } else {
        let alt_axis = (
            lst_rad.cos() * phi_rad.sin(),
            lst_rad.sin() * phi_rad.sin(),
            -phi_rad.cos(),
        );
        let az_axis = (lst_rad.sin(), -lst_rad.cos(), 0.0);
        (alt_axis, az_axis)
    };

    let alt_component = delta_unit_perp.0 * alt_axis.0
        + delta_unit_perp.1 * alt_axis.1
        + delta_unit_perp.2 * alt_axis.2;
    let az_component = delta_unit_perp.0 * az_axis.0
        + delta_unit_perp.1 * az_axis.1
        + delta_unit_perp.2 * az_axis.2;

    const RAD_TO_ARCSEC: f64 = 206264.80624709636;

    PolarMisalignment {
        azimuth_error_arcsec: az_component * RAD_TO_ARCSEC,
        altitude_error_arcsec: alt_component * RAD_TO_ARCSEC,
    }
}

/// Convert (RA degrees, Dec degrees) to a unit vector on the celestial sphere.
pub(super) fn radec_to_unit_vector(ra_deg: f64, dec_deg: f64) -> (f64, f64, f64) {
    let ra = ra_deg.to_radians();
    let dec = dec_deg.to_radians();
    (dec.cos() * ra.cos(), dec.cos() * ra.sin(), dec.sin())
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{Duration as ChronoDuration, TimeZone};

    fn epoch() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap()
    }

    /// Simulate an imperfectly aligned mount tracking a star for `dt_secs`.
    /// Uses an exact rotation matrix so the simulator faithfully exercises
    /// the algorithm.
    #[allow(clippy::too_many_arguments)]
    fn simulate_tracking_drift(
        baseline_ra_deg: f64,
        baseline_dec_deg: f64,
        observer_lat_deg: f64,
        observer_lon_deg: f64,
        is_north: bool,
        when: DateTime<Utc>,
        dt_secs: f64,
        pole_az_offset_arcsec: f64,
        pole_alt_offset_arcsec: f64,
    ) -> SolvedFrame {
        let lst_hours = crate::local_sidereal_time(crate::julian_day(&when), observer_lon_deg);
        let lst_rad = (lst_hours * 15.0).to_radians();
        let phi_rad = observer_lat_deg.to_radians();

        let (p_true, alt_axis, az_axis) = if is_north {
            (
                (
                    lst_rad.cos() * phi_rad.cos(),
                    lst_rad.sin() * phi_rad.cos(),
                    phi_rad.sin(),
                ),
                (
                    lst_rad.cos() * (-phi_rad.sin()),
                    lst_rad.sin() * (-phi_rad.sin()),
                    phi_rad.cos(),
                ),
                (-lst_rad.sin(), lst_rad.cos(), 0.0),
            )
        } else {
            (
                (
                    -lst_rad.cos() * phi_rad.cos(),
                    -lst_rad.sin() * phi_rad.cos(),
                    -phi_rad.sin(),
                ),
                (
                    lst_rad.cos() * phi_rad.sin(),
                    lst_rad.sin() * phi_rad.sin(),
                    -phi_rad.cos(),
                ),
                (lst_rad.sin(), -lst_rad.cos(), 0.0),
            )
        };

        const ARCSEC_TO_RAD: f64 = 4.84813681109536e-6;
        let dalt = pole_alt_offset_arcsec * ARCSEC_TO_RAD;
        let daz = pole_az_offset_arcsec * ARCSEC_TO_RAD;

        let p_mech_raw = (
            p_true.0 + dalt * alt_axis.0 + daz * az_axis.0,
            p_true.1 + dalt * alt_axis.1 + daz * az_axis.1,
            p_true.2 + dalt * alt_axis.2 + daz * az_axis.2,
        );
        let pm_mag = (p_mech_raw.0.powi(2) + p_mech_raw.1.powi(2) + p_mech_raw.2.powi(2)).sqrt();
        let p_mech = (
            p_mech_raw.0 / pm_mag,
            p_mech_raw.1 / pm_mag,
            p_mech_raw.2 / pm_mag,
        );

        let theta = SIDEREAL_RATE_RAD_PER_SEC * dt_secs;
        let v0 = radec_to_unit_vector(baseline_ra_deg, baseline_dec_deg);
        let v_after_mount = rotate_around_axis(v0, p_mech, theta);
        let v1 = rotate_around_axis(v_after_mount, p_true, -theta);

        let dec = v1.2.clamp(-1.0, 1.0).asin().to_degrees();
        let mut ra = v1.1.atan2(v1.0).to_degrees();
        if ra < 0.0 {
            ra += 360.0;
        }

        SolvedFrame {
            ra_deg: ra,
            dec_deg: dec,
            // Why: test helper; dt_secs is bounded by single-session durations
            // (< 1 day = 86_400_000 ms, far below i64::MAX).
            when: when + ChronoDuration::milliseconds((dt_secs * 1000.0) as i64),
        }
    }

    /// Rodrigues' rotation formula: rotate `v` around unit `axis` by
    /// `theta` radians (right-hand rule).
    fn rotate_around_axis(
        v: (f64, f64, f64),
        axis: (f64, f64, f64),
        theta: f64,
    ) -> (f64, f64, f64) {
        let cos_t = theta.cos();
        let sin_t = theta.sin();
        let dot = axis.0 * v.0 + axis.1 * v.1 + axis.2 * v.2;
        let cross = (
            axis.1 * v.2 - axis.2 * v.1,
            axis.2 * v.0 - axis.0 * v.2,
            axis.0 * v.1 - axis.1 * v.0,
        );
        (
            v.0 * cos_t + cross.0 * sin_t + axis.0 * dot * (1.0 - cos_t),
            v.1 * cos_t + cross.1 * sin_t + axis.1 * dot * (1.0 - cos_t),
            v.2 * cos_t + cross.2 * sin_t + axis.2 * dot * (1.0 - cos_t),
        )
    }

    fn lst_deg(when: DateTime<Utc>, observer_lon_deg: f64) -> f64 {
        let lst_hours = crate::local_sidereal_time(crate::julian_day(&when), observer_lon_deg);
        let mut lst = lst_hours * 15.0;
        lst = lst.rem_euclid(360.0);
        lst
    }

    #[test]
    fn perfect_alignment_reports_zero_drift_error() {
        let when = epoch();
        let baseline = SolvedFrame {
            ra_deg: 83.633,
            dec_deg: 22.014,
            when,
        };
        let current = simulate_tracking_drift(
            baseline.ra_deg,
            baseline.dec_deg,
            45.0,
            -122.0,
            true,
            when,
            60.0,
            0.0,
            0.0,
        );
        let mis = compute_polar_misalignment_from_drift(&baseline, &current, 45.0, -122.0, true);
        assert!(
            mis.azimuth_error_arcsec.abs() < 1e-6,
            "az error should be zero for perfect alignment, got {}",
            mis.azimuth_error_arcsec
        );
        assert!(
            mis.altitude_error_arcsec.abs() < 1e-6,
            "alt error should be zero for perfect alignment, got {}",
            mis.altitude_error_arcsec
        );
    }

    #[test]
    fn one_degree_east_azimuth_error_recovered_as_one_degree_azimuth() {
        // Recovery is exact when v_baseline is perpendicular to the
        // misalignment vector (meridian + Dec=lat).
        let when = epoch();
        let lat = 45.0;
        let lon = -122.0;
        let baseline = SolvedFrame {
            ra_deg: lst_deg(when, lon),
            dec_deg: lat,
            when,
        };
        let current = simulate_tracking_drift(
            baseline.ra_deg,
            baseline.dec_deg,
            lat,
            lon,
            true,
            when,
            60.0,
            3600.0,
            0.0,
        );
        let mis = compute_polar_misalignment_from_drift(&baseline, &current, lat, lon, true);
        assert!(
            (mis.azimuth_error_arcsec - 3600.0).abs() < 25.0,
            "expected az ≈ 3600″, got az={:.2}\", alt={:.2}\"",
            mis.azimuth_error_arcsec,
            mis.altitude_error_arcsec
        );
        assert!(
            mis.altitude_error_arcsec.abs() < 25.0,
            "expected alt ≈ 0, got alt={:.2}\"",
            mis.altitude_error_arcsec
        );
    }

    #[test]
    fn one_degree_altitude_error_recovered_as_one_degree_altitude() {
        let when = epoch();
        let lat = 45.0;
        let lon = -122.0;
        let baseline = SolvedFrame {
            ra_deg: lst_deg(when, lon),
            dec_deg: lat,
            when,
        };
        let current = simulate_tracking_drift(
            baseline.ra_deg,
            baseline.dec_deg,
            lat,
            lon,
            true,
            when,
            60.0,
            0.0,
            3600.0,
        );
        let mis = compute_polar_misalignment_from_drift(&baseline, &current, lat, lon, true);
        assert!(
            (mis.altitude_error_arcsec - 3600.0).abs() < 25.0,
            "expected alt ≈ 3600″, got alt={:.2}\", az={:.2}\"",
            mis.altitude_error_arcsec,
            mis.azimuth_error_arcsec
        );
        assert!(
            mis.azimuth_error_arcsec.abs() < 25.0,
            "expected az ≈ 0, got az={:.2}\"",
            mis.azimuth_error_arcsec
        );
    }

    #[test]
    fn combined_misalignment_recovered_in_both_components() {
        let when = epoch();
        let lat = 45.0;
        let lon = -122.0;
        let baseline = SolvedFrame {
            ra_deg: lst_deg(when, lon),
            dec_deg: lat,
            when,
        };
        let current = simulate_tracking_drift(
            baseline.ra_deg,
            baseline.dec_deg,
            lat,
            lon,
            true,
            when,
            60.0,
            1800.0,
            -2400.0,
        );
        let mis = compute_polar_misalignment_from_drift(&baseline, &current, lat, lon, true);
        assert!(
            (mis.azimuth_error_arcsec - 1800.0).abs() < 25.0,
            "az expected ≈ 1800″, got {:.2}\"",
            mis.azimuth_error_arcsec
        );
        assert!(
            (mis.altitude_error_arcsec - (-2400.0)).abs() < 25.0,
            "alt expected ≈ -2400″, got {:.2}\"",
            mis.altitude_error_arcsec
        );
    }

    #[test]
    fn southern_hemisphere_combined_misalignment_recovered() {
        let when = epoch();
        let lat = -33.0;
        let lon = 151.0;
        let baseline = SolvedFrame {
            ra_deg: lst_deg(when, lon),
            dec_deg: lat,
            when,
        };
        let current = simulate_tracking_drift(
            baseline.ra_deg,
            baseline.dec_deg,
            lat,
            lon,
            false,
            when,
            60.0,
            1500.0,
            900.0,
        );
        let mis = compute_polar_misalignment_from_drift(&baseline, &current, lat, lon, false);
        assert!(
            (mis.azimuth_error_arcsec - 1500.0).abs() < 25.0,
            "south az expected ≈ 1500″, got {:.2}\"",
            mis.azimuth_error_arcsec
        );
        assert!(
            (mis.altitude_error_arcsec - 900.0).abs() < 25.0,
            "south alt expected ≈ 900″, got {:.2}\"",
            mis.altitude_error_arcsec
        );
    }

    #[test]
    fn off_meridian_target_has_bounded_recovery_error() {
        let when = epoch();
        let lat = 45.0;
        let lon = -122.0;
        let baseline = SolvedFrame {
            ra_deg: 200.0,
            dec_deg: 20.0,
            when,
        };
        let current = simulate_tracking_drift(
            baseline.ra_deg,
            baseline.dec_deg,
            lat,
            lon,
            true,
            when,
            60.0,
            3600.0,
            0.0,
        );
        let mis = compute_polar_misalignment_from_drift(&baseline, &current, lat, lon, true);
        let total = (mis.azimuth_error_arcsec.powi(2) + mis.altitude_error_arcsec.powi(2)).sqrt();
        assert!(
            total <= 3600.1,
            "off-meridian recovery should not exceed true misalignment, got {:.2}\"",
            total
        );
        assert!(
            total >= 1080.0,
            "off-meridian recovery should be at least 30% of truth, got {:.2}\"",
            total
        );
    }

    #[test]
    fn zero_elapsed_time_returns_zero_error_without_panic() {
        let frame = SolvedFrame {
            ra_deg: 100.0,
            dec_deg: 30.0,
            when: epoch(),
        };
        let mis = compute_polar_misalignment_from_drift(&frame, &frame, 45.0, -122.0, true);
        assert_eq!(mis.azimuth_error_arcsec, 0.0);
        assert_eq!(mis.altitude_error_arcsec, 0.0);
    }

    #[test]
    fn unit_vector_recovers_known_directions() {
        let v = radec_to_unit_vector(0.0, 0.0);
        assert!((v.0 - 1.0).abs() < 1e-12);
        assert!(v.1.abs() < 1e-12);
        assert!(v.2.abs() < 1e-12);

        let v = radec_to_unit_vector(0.0, 90.0);
        assert!(v.0.abs() < 1e-12);
        assert!(v.1.abs() < 1e-12);
        assert!((v.2 - 1.0).abs() < 1e-12);

        let v = radec_to_unit_vector(90.0, 0.0);
        assert!(v.0.abs() < 1e-12);
        assert!((v.1 - 1.0).abs() < 1e-12);
        assert!(v.2.abs() < 1e-12);
    }
}
