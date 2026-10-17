//! Math helpers for three-point polar alignment.
//!
//! Separate from the state machine so the celestial-mechanics formulas can
//! be tested independently.

/// The mount's mechanical rotation axis, fitted from the measurement points,
/// together with what that fit is worth.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RotationAxisFit {
    /// Right ascension of the axis, degrees in `[0, 360)`.
    pub ra_degrees: f64,
    /// Declination of the axis, degrees. Always in the hemisphere the operator
    /// declared.
    pub dec_degrees: f64,
    /// Angular radius of the small circle the points lie on, degrees. With the
    /// axis near the pole this is the points' own pole distance.
    pub radius_degrees: f64,
    /// Arc the points span about the axis, degrees. This is the measurement's
    /// lever arm, and it is `2 x step_size` for a three-point run.
    pub arc_degrees: f64,
    /// How far the fitted axis moves for one arcminute of error in one point,
    /// in degrees.
    ///
    /// A circle through three points is exactly determined — there is no
    /// residual to inspect and no averaging — so this is the only honest
    /// statement about the fit's worth. It is measured, not modelled: each
    /// point is nudged by an arcminute in each direction and the axis refitted.
    ///
    /// It is dominated by the arc, because the measurement IS the arc's
    /// curvature and a short arc has almost none. Two 10° steps give about
    /// 1.7°/arcmin; two 30° steps give about a tenth of that.
    pub axis_degrees_per_arcmin: f64,
}

/// Fit the mount's rotation axis to the solved measurement points.
///
/// The points lie on a small circle about the mount's mechanical polar axis,
/// so the axis is the normal of the plane through them. Returns `None` for
/// points that do not define a plane — a mount that never rotated, or three
/// solves of the same field — because the old `(0, 90)` answer for that case
/// claimed a perfectly aligned mount out of no measurement at all.
///
/// `is_north` picks which end of the normal is the axis. It must: a plane
/// normal has two ends, the cross product's sign follows the DIRECTION the
/// mount was stepped, and nothing about the sky distinguishes them. Rotating
/// west instead of east therefore used to hand back the antipode — a run on
/// the owner's rig fitted a correct axis and reported it as "Dec=-80.64,
/// 170.6 deg away from expected pole", then aborted with "poor plate solves or
/// insufficient mount rotation". The mount turns about the pole of the
/// hemisphere the operator is standing in, whichever way it was stepped.
pub fn fit_rotation_axis(points: &[(f64, f64)], is_north: bool) -> Option<RotationAxisFit> {
    let axis = fit_axis_vector(points, is_north)?;
    let p1 = radec_to_vec(points[0].0, points[0].1);
    let p3 = radec_to_vec(points[2].0, points[2].1);

    let (ra_degrees, dec_degrees) = unit_to_radec((axis[0], axis[1], axis[2]));
    Some(RotationAxisFit {
        ra_degrees,
        dec_degrees,
        radius_degrees: dot(axis, p1).clamp(-1.0, 1.0).acos().to_degrees(),
        arc_degrees: arc_about_axis(axis, p1, p3).to_degrees(),
        axis_degrees_per_arcmin: axis_sensitivity_degrees_per_arcmin(points, is_north, axis),
    })
}

/// The plane normal, in the hemisphere the operator declared.
fn fit_axis_vector(points: &[(f64, f64)], is_north: bool) -> Option<[f64; 3]> {
    if points.len() < 3 {
        return None;
    }
    let p1 = radec_to_vec(points[0].0, points[0].1);
    let p2 = radec_to_vec(points[1].0, points[1].1);
    let p3 = radec_to_vec(points[2].0, points[2].1);
    let axis = normalise(cross(sub(p2, p1), sub(p3, p1)))?;
    Some(if (axis[2] > 0.0) == is_north {
        axis
    } else {
        [-axis[0], -axis[1], -axis[2]]
    })
}

/// Measure the fit's sensitivity by doing to the points what the sky does to
/// them: nudge each one by an arcminute, in declination and along the parallel,
/// and refit.
///
/// Measured rather than modelled because the closed form (the sagitta of the
/// arc) is only the leading term — the same nudge also shrinks the triangle
/// the normal is built from, and at the arcs a 10° step produces that second
/// effect is half the answer.
fn axis_sensitivity_degrees_per_arcmin(
    points: &[(f64, f64)],
    is_north: bool,
    axis: [f64; 3],
) -> f64 {
    const ONE_ARCMIN_DEG: f64 = 1.0 / 60.0;
    let mut worst: f64 = 0.0;
    for index in 0..3 {
        for (d_ra, d_dec) in [(0.0, ONE_ARCMIN_DEG), (ONE_ARCMIN_DEG, 0.0)] {
            let mut nudged = points[..3].to_vec();
            let (ra, dec) = nudged[index];
            // A minute of RA is a minute of arc only at the equator.
            let cos_dec = dec.to_radians().cos();
            nudged[index] = (
                ra + if cos_dec.abs() > 1e-6 {
                    d_ra / cos_dec
                } else {
                    0.0
                },
                dec + d_dec,
            );
            let Some(moved) = fit_axis_vector(&nudged, is_north) else {
                return f64::INFINITY;
            };
            worst = worst.max(dot(axis, moved).clamp(-1.0, 1.0).acos().to_degrees());
        }
    }
    worst
}

/// Angle between two points measured about `axis`, radians in `[0, pi]`.
fn arc_about_axis(axis: [f64; 3], from: [f64; 3], to: [f64; 3]) -> f64 {
    let project = |p: [f64; 3]| {
        let along = dot(axis, p);
        [
            p[0] - axis[0] * along,
            p[1] - axis[1] * along,
            p[2] - axis[2] * along,
        ]
    };
    let (a, b) = (project(from), project(to));
    let (Some(a), Some(b)) = (normalise(a), normalise(b)) else {
        return 0.0;
    };
    dot(a, b).clamp(-1.0, 1.0).acos()
}

fn radec_to_vec(ra_degrees: f64, dec_degrees: f64) -> [f64; 3] {
    let (ra, dec) = (ra_degrees.to_radians(), dec_degrees.to_radians());
    [dec.cos() * ra.cos(), dec.cos() * ra.sin(), dec.sin()]
}

fn sub(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

fn cross(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}

fn dot(a: [f64; 3], b: [f64; 3]) -> f64 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

fn normalise(v: [f64; 3]) -> Option<[f64; 3]> {
    let mag = dot(v, v).sqrt();
    (mag > 1e-9).then(|| [v[0] / mag, v[1] / mag, v[2] / mag])
}

/// Compute (Δaz, Δalt, total) alignment error in arcminutes from the
/// mechanical axis coordinates and observer location.
pub fn calculate_alignment_error_arcmin(
    axis_ra_degrees: f64,
    axis_dec_degrees: f64,
    is_north: bool,
    observer_latitude: f64,
    observer_longitude: f64,
    when: chrono::DateTime<chrono::Utc>,
) -> (f64, f64, f64) {
    let (axis_altitude, axis_azimuth) = equatorial_to_horizontal(
        axis_ra_degrees,
        axis_dec_degrees,
        observer_latitude,
        observer_longitude,
        when,
    );

    let pole_altitude = if is_north {
        observer_latitude
    } else {
        -observer_latitude
    };
    let pole_azimuth = if is_north { 0.0 } else { 180.0 };

    // Report where the mechanical axis sits relative to the true pole. This
    // matches the public/Dart convention: positive altitude = axis above the
    // pole; positive azimuth = axis east of the pole. UI guidance then tells
    // the operator to move in the opposite direction to correct it.
    let altitude_error_arcmin = (axis_altitude - pole_altitude) * 60.0;
    let azimuth_error_arcmin = normalize_signed_angle_degrees(axis_azimuth - pole_azimuth) * 60.0;
    let total_error_arcmin = (altitude_error_arcmin.powi(2) + azimuth_error_arcmin.powi(2)).sqrt();

    (
        azimuth_error_arcmin,
        altitude_error_arcmin,
        total_error_arcmin,
    )
}

fn equatorial_to_horizontal(
    ra_degrees: f64,
    dec_degrees: f64,
    observer_latitude: f64,
    observer_longitude: f64,
    when: chrono::DateTime<chrono::Utc>,
) -> (f64, f64) {
    let lst_hours = crate::local_sidereal_time(crate::julian_day(&when), observer_longitude);
    let hour_angle_rad = ((lst_hours * 15.0) - ra_degrees).to_radians();
    let dec_rad = dec_degrees.to_radians();
    let lat_rad = observer_latitude.to_radians();

    let altitude = (lat_rad.sin() * dec_rad.sin()
        + lat_rad.cos() * dec_rad.cos() * hour_angle_rad.cos())
    .asin();

    let azimuth = (-hour_angle_rad.sin() * dec_rad.cos())
        .atan2(dec_rad.sin() * lat_rad.cos() - dec_rad.cos() * lat_rad.sin() * hour_angle_rad.cos())
        .to_degrees()
        .rem_euclid(360.0);

    (altitude.to_degrees(), azimuth)
}

fn normalize_signed_angle_degrees(angle_degrees: f64) -> f64 {
    let wrapped = angle_degrees.rem_euclid(360.0);
    if wrapped > 180.0 {
        wrapped - 360.0
    } else {
        wrapped
    }
}

/// (RA, Dec) in degrees → Cartesian unit vector (same convention as
/// `fit_rotation_axis`).
fn radec_to_unit(ra_deg: f64, dec_deg: f64) -> (f64, f64, f64) {
    let ra = ra_deg.to_radians();
    let dec = dec_deg.to_radians();
    (dec.cos() * ra.cos(), dec.cos() * ra.sin(), dec.sin())
}

/// Cartesian unit vector → (RA, Dec) in degrees, RA normalised to [0, 360).
fn unit_to_radec(v: (f64, f64, f64)) -> (f64, f64) {
    let dec = v.2.clamp(-1.0, 1.0).asin();
    let mut ra = v.1.atan2(v.0);
    if ra < 0.0 {
        ra += 2.0 * std::f64::consts::PI;
    }
    (ra.to_degrees(), dec.to_degrees())
}

/// Track the mount's mechanical axis through a live adjustment.
///
/// During the adjustment phase the operator turns the alt/az bolts, which
/// moves the whole mount head — both the optics and the mechanical rotation
/// axis — rigidly. The geodesic (minimal) rotation that carried the reference
/// star from its INITIAL solved position to its CURRENT solved position is
/// therefore the same rigid rotation that moved the axis (exact in the
/// small-angle limit, and convergent: the displayed error reaches zero exactly
/// when the live axis reaches the pole). Applying it to the measured initial
/// axis yields the LIVE axis, which is what makes the displayed error respond
/// to the bolts instead of leaving the operator aligning blind. Returns the
/// live axis (RA, Dec) in degrees.
pub fn rotate_axis_by_star_motion(
    axis: (f64, f64),
    star_initial: (f64, f64),
    star_current: (f64, f64),
) -> (f64, f64) {
    let a = radec_to_unit(star_initial.0, star_initial.1);
    let b = radec_to_unit(star_current.0, star_current.1);
    let v = radec_to_unit(axis.0, axis.1);

    // Rotation taking a → b: axis k = (a × b) normalised, angle = atan2(|a×b|, a·b).
    let cross = (
        a.1 * b.2 - a.2 * b.1,
        a.2 * b.0 - a.0 * b.2,
        a.0 * b.1 - a.1 * b.0,
    );
    let cross_mag = (cross.0 * cross.0 + cross.1 * cross.1 + cross.2 * cross.2).sqrt();
    let dot = a.0 * b.0 + a.1 * b.1 + a.2 * b.2;

    // No appreciable motion (a ≈ b), or the degenerate antipodal case that
    // cannot arise from a small adjustment → leave the axis unchanged.
    if cross_mag < 1e-12 {
        return axis;
    }
    let k = (
        cross.0 / cross_mag,
        cross.1 / cross_mag,
        cross.2 / cross_mag,
    );
    let angle = cross_mag.atan2(dot);
    let (sin_t, cos_t) = (angle.sin(), angle.cos());

    // Rodrigues' rotation: v_rot = v cosθ + (k × v) sinθ + k (k·v)(1 − cosθ).
    let kv = k.0 * v.0 + k.1 * v.1 + k.2 * v.2;
    let kxv = (
        k.1 * v.2 - k.2 * v.1,
        k.2 * v.0 - k.0 * v.2,
        k.0 * v.1 - k.1 * v.0,
    );
    let rotated = (
        v.0 * cos_t + kxv.0 * sin_t + k.0 * kv * (1.0 - cos_t),
        v.1 * cos_t + kxv.1 * sin_t + k.1 * kv * (1.0 - cos_t),
        v.2 * cos_t + kxv.2 * sin_t + k.2 * kv * (1.0 - cos_t),
    );
    unit_to_radec(rotated)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    /// Sample a small circle of `radius` about `axis`, `count` points spaced
    /// `step` apart. `east` steps the way the mount's RA increases.
    fn sample_circle(
        axis: (f64, f64),
        radius_deg: f64,
        start_phase_deg: f64,
        step_deg: f64,
        count: usize,
        east: bool,
    ) -> Vec<(f64, f64)> {
        let a = radec_to_vec(axis.0, axis.1);
        // Any pair of directions perpendicular to the axis spans the circle.
        let seed = if a[2].abs() < 0.9 {
            [0.0, 0.0, 1.0]
        } else {
            [1.0, 0.0, 0.0]
        };
        let u = normalise(cross(a, seed)).expect("axis is not parallel to the seed");
        let v = cross(a, u);
        (0..count)
            .map(|i| {
                let phase = (start_phase_deg + if east { 1.0 } else { -1.0 } * step_deg * i as f64)
                    .to_radians();
                let r = radius_deg.to_radians();
                let p = [
                    a[0] * r.cos() + (u[0] * phase.cos() + v[0] * phase.sin()) * r.sin(),
                    a[1] * r.cos() + (u[1] * phase.cos() + v[1] * phase.sin()) * r.sin(),
                    a[2] * r.cos() + (u[2] * phase.cos() + v[2] * phase.sin()) * r.sin(),
                ];
                unit_to_radec((p[0], p[1], p[2]))
            })
            .collect()
    }

    fn angle_between(a: (f64, f64), b: (f64, f64)) -> f64 {
        dot(radec_to_vec(a.0, a.1), radec_to_vec(b.0, b.1))
            .clamp(-1.0, 1.0)
            .acos()
            .to_degrees()
    }

    #[test]
    fn a_circle_about_the_pole_fits_the_pole() {
        // Perfect rotation around pole (0, 90).
        let points = vec![(0.0, 89.0), (20.0, 89.0), (40.0, 89.0)];
        let fit =
            fit_rotation_axis(&points, true).expect("three points on a circle define an axis");
        assert!((fit.dec_degrees - 90.0).abs() < 0.1);
    }

    /// The owner's rig, 2026-09-13 01:59 UTC: northern hemisphere, stepped
    /// WEST, three points solved and the run then aborted with "Calculated
    /// rotation center (Dec=-80.64°) is 170.6° away from expected pole".
    ///
    /// Nothing was wrong with the plate solves or the rotation. The cross
    /// product's sign follows the direction the mount was stepped, and a
    /// westward run hands back the antipode of the axis. The fit must return
    /// the axis in the hemisphere the operator declared.
    #[test]
    fn a_westward_run_reports_the_northern_axis_not_its_antipode() {
        let rig = [
            (340.5123, 58.3799),
            (328.4230, 58.6924),
            (316.2923, 58.6741),
        ];

        let north = fit_rotation_axis(&rig, true).expect("fit");
        assert!(
            north.dec_degrees > 0.0,
            "a northern run must not report a southern axis: {north:?}"
        );
        // What these three points actually determine — see the test below for
        // why it is not the arcminute-accurate answer the operator wanted.
        assert!((north.dec_degrees - 80.6418).abs() < 1e-3, "{north:?}");
        assert!((north.ra_degrees - 143.0247).abs() < 1e-3, "{north:?}");

        // The southern hemisphere reads the same plane from the other side.
        let south = fit_rotation_axis(&rig, false).expect("fit");
        assert!((south.dec_degrees + 80.6418).abs() < 1e-3, "{south:?}");
    }

    /// The regression for the abort itself: the same circle, walked in either
    /// direction, is one axis. Before the hemisphere fix, `rotate_east: false`
    /// — which is what the meridian guard leaves an operator with on half the
    /// sky — flipped the answer to the south pole and failed every run.
    #[test]
    fn stepping_east_or_west_fits_the_same_axis() {
        let axis = (12.0, 89.4);
        let east =
            fit_rotation_axis(&sample_circle(axis, 31.7, 0.0, 10.0, 3, true), true).expect("fit");
        let west =
            fit_rotation_axis(&sample_circle(axis, 31.7, 0.0, 10.0, 3, false), true).expect("fit");
        assert!(angle_between((east.ra_degrees, east.dec_degrees), axis) < 1e-6);
        assert!(angle_between((west.ra_degrees, west.dec_degrees), axis) < 1e-6);
    }

    /// The fit is a plane through three unit vectors, so it never assumes the
    /// points share a declination — and it must not, because a misaligned
    /// mount rotating about its own axis moves its boresight in declination by
    /// up to twice the misalignment.
    #[test]
    fn an_axis_off_the_pole_is_recovered_from_points_whose_declination_varies() {
        let axis = (100.0, 85.0);
        let points = sample_circle(axis, 32.0, 20.0, 15.0, 3, true);
        let dec_spread = points.iter().map(|p| p.1).fold(f64::MIN, f64::max)
            - points.iter().map(|p| p.1).fold(f64::MAX, f64::min);
        assert!(
            dec_spread > 0.5,
            "a 5° misalignment must move Dec between points: {dec_spread}"
        );

        let fit = fit_rotation_axis(&points, true).expect("fit");
        assert!(
            angle_between((fit.ra_degrees, fit.dec_degrees), axis) < 1e-6,
            "{fit:?}"
        );
        assert!((fit.radius_degrees - 32.0).abs() < 1e-6, "{fit:?}");
        assert!((fit.arc_degrees - 30.0).abs() < 1e-6, "{fit:?}");
    }

    /// Why the owner's run produced an axis 9° from the pole from three good
    /// plate solves: three points determine a circle exactly, so the whole
    /// measurement is the arc's curvature, and a short arc has almost none.
    /// The reported sensitivity has to predict that, and a longer arc has to
    /// fix it — this is what the operator is told to change.
    #[test]
    fn a_short_arc_multiplies_one_points_error_into_the_axis() {
        let axis = (0.0, 90.0);
        let perturb_middle = |mut points: Vec<(f64, f64)>| {
            points[1].1 += 0.2; // 12 arcmin, in declination
            points
        };

        for step in [10.0_f64, 30.0] {
            let clean = sample_circle(axis, 31.7, 0.0, step, 3, false);
            let fit = fit_rotation_axis(&clean, true).expect("fit");
            let moved = fit_rotation_axis(&perturb_middle(clean), true).expect("fit");
            let shift = angle_between((moved.ra_degrees, moved.dec_degrees), axis);
            let predicted = fit.axis_degrees_per_arcmin * 12.0;
            // 12 arcmin is far outside the linear regime the metric is
            // measured in (it moves the 10°-step axis by twenty degrees), so
            // the claim is order-of-magnitude: the number on the log line has
            // to be recognisably the size of the damage.
            assert!(
                shift > 0.5 * predicted && shift < 2.0 * predicted,
                "step {step}: axis moved {shift}°, sensitivity predicted {predicted}°"
            );
        }

        let short =
            fit_rotation_axis(&sample_circle(axis, 31.7, 0.0, 10.0, 3, false), true).expect("fit");
        let long =
            fit_rotation_axis(&sample_circle(axis, 31.7, 0.0, 30.0, 3, false), true).expect("fit");
        // The numbers the bridge's "your arc is too short" threshold is set
        // against. A 10° step is nine times worse than a 30° one.
        for (step, expected) in [(10.0_f64, 1.132), (15.0, 0.496), (30.0, 0.125)] {
            let fit = fit_rotation_axis(&sample_circle(axis, 31.7, 0.0, step, 3, false), true)
                .expect("fit");
            assert!(
                (fit.axis_degrees_per_arcmin - expected).abs() < 0.01,
                "{step}° step: {} °/arcmin, expected {expected}",
                fit.axis_degrees_per_arcmin
            );
        }

        assert!((short.arc_degrees - 20.0).abs() < 1e-6);
        assert!(
            short.axis_degrees_per_arcmin > 5.0 * long.axis_degrees_per_arcmin,
            "a 10° step is far worse conditioned than a 30° one: {short:?} vs {long:?}"
        );

        // The measured sensitivity has to be right in the regime it is
        // measured in: one arcmin of error, one axis movement of that size.
        let clean = sample_circle(axis, 31.7, 0.0, 10.0, 3, false);
        let mut nudged = clean.clone();
        nudged[1].1 += 1.0 / 60.0;
        let fit = fit_rotation_axis(&clean, true).expect("fit");
        let moved = fit_rotation_axis(&nudged, true).expect("fit");
        let shift = angle_between((moved.ra_degrees, moved.dec_degrees), axis);
        assert!(
            (shift - fit.axis_degrees_per_arcmin).abs() < 0.02 * fit.axis_degrees_per_arcmin,
            "measured {} vs reported {}",
            shift,
            fit.axis_degrees_per_arcmin
        );
    }

    /// A mount that never moved measures nothing. Returning "(0, 90) — you are
    /// perfectly aligned" for that case is the worst possible answer.
    #[test]
    fn points_that_do_not_define_a_circle_have_no_axis() {
        assert!(fit_rotation_axis(&[(10.0, 60.0), (10.0, 60.0), (10.0, 60.0)], true).is_none());
        // Three points on one great circle: the "small circle" is the circle
        // itself and its axis is 90° away from every point, which is not a
        // rotation measurement.
        assert!(fit_rotation_axis(&[(0.0, 0.0), (30.0, 0.0), (60.0, 0.0)], true).is_some());
        assert!(fit_rotation_axis(&[(0.0, 0.0), (30.0, 0.0)], true).is_none());
    }

    #[test]
    fn test_alignment_error_zero_at_true_pole() {
        let when = chrono::Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap();
        let (az_error, alt_error, total_error) =
            calculate_alignment_error_arcmin(123.0, 90.0, true, 45.0, -122.0, when);
        assert!(az_error.abs() < 1e-6);
        assert!(alt_error.abs() < 1e-6);
        assert!(total_error.abs() < 1e-6);
    }

    #[test]
    fn horizontal_components_follow_axis_offset_signs() {
        let when = chrono::Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap();
        let lon = -122.0;
        let lst_deg = crate::local_sidereal_time(crate::julian_day(&when), lon) * 15.0;

        // On the meridian, an axis one degree below the NCP appears one degree
        // above the true pole in altitude for a mid-northern observer.
        let (_, alt, _) = calculate_alignment_error_arcmin(lst_deg, 89.0, true, 45.0, lon, when);
        assert!(alt > 59.0, "axis above pole should be positive: {alt}");

        // RA east of the meridian produces an eastward horizontal offset.
        let (az, _, _) =
            calculate_alignment_error_arcmin(lst_deg + 1.0, 89.0, true, 45.0, lon, when);
        assert!(az > 0.0, "axis east of pole should be positive: {az}");
    }

    /// Horizontal → equatorial, written independently of the production
    /// `equatorial_to_horizontal` so the pair is a real round trip and not the
    /// same algebra agreeing with itself.
    fn horizontal_to_equatorial(
        altitude: f64,
        azimuth: f64,
        latitude: f64,
        longitude: f64,
        when: chrono::DateTime<chrono::Utc>,
    ) -> (f64, f64) {
        let (alt, az, lat) = (
            altitude.to_radians(),
            azimuth.to_radians(),
            latitude.to_radians(),
        );
        let dec = (lat.sin() * alt.sin() + lat.cos() * alt.cos() * az.cos()).asin();
        let hour_angle = (-az.sin() * alt.cos() / dec.cos())
            .atan2((alt.sin() - lat.sin() * dec.sin()) / (lat.cos() * dec.cos()));
        let lst_deg = crate::local_sidereal_time(crate::julian_day(&when), longitude) * 15.0;
        (
            (lst_deg - hour_angle.to_degrees()).rem_euclid(360.0),
            dec.to_degrees(),
        )
    }

    /// The number the operator turns a bolt by. An axis one degree east of the
    /// pole must read as one degree of azimuth error, eastward — not a degree
    /// of altitude, not the other way round, and not scaled by the latitude.
    #[test]
    fn an_axis_one_degree_east_of_the_pole_reads_as_one_degree_of_azimuth() {
        let when = chrono::Utc.with_ymd_and_hms(2026, 9, 13, 2, 0, 0).unwrap();
        let (lat, lon) = (40.0, -75.0);

        // The true north celestial pole sits at altitude = latitude, azimuth 0.
        let (ra, dec) = horizontal_to_equatorial(lat, 1.0, lat, lon, when);
        let (az_err, alt_err, total) =
            calculate_alignment_error_arcmin(ra, dec, true, lat, lon, when);
        assert!(
            (az_err - 60.0).abs() < 0.5,
            "one degree east must read +60 arcmin of azimuth, got {az_err}"
        );
        assert!(
            alt_err.abs() < 0.5,
            "no altitude error was introduced: {alt_err}"
        );
        assert!((total - 60.0).abs() < 1.0, "{total}");

        // ...and the other way is negative, so the bolt guidance reverses.
        let (ra, dec) = horizontal_to_equatorial(lat, -1.0, lat, lon, when);
        let (az_err, _, _) = calculate_alignment_error_arcmin(ra, dec, true, lat, lon, when);
        assert!(
            (az_err + 60.0).abs() < 0.5,
            "one degree west must read -60 arcmin, got {az_err}"
        );
    }

    /// An axis a degree BELOW the pole is a degree of altitude error, and the
    /// sign says which way the bolt goes.
    #[test]
    fn an_axis_one_degree_below_the_pole_reads_as_one_degree_of_altitude() {
        let when = chrono::Utc.with_ymd_and_hms(2026, 9, 13, 2, 0, 0).unwrap();
        let (lat, lon) = (40.0, -75.0);
        let (ra, dec) = horizontal_to_equatorial(lat - 1.0, 0.0, lat, lon, when);
        let (az_err, alt_err, _) = calculate_alignment_error_arcmin(ra, dec, true, lat, lon, when);
        assert!(
            (alt_err + 60.0).abs() < 0.5,
            "an axis below the pole must read -60 arcmin, got {alt_err}"
        );
        assert!(az_err.abs() < 0.5, "{az_err}");
    }

    /// End to end: a mount whose axis is a degree off, measured by three
    /// points the way a run measures them, reports that degree.
    #[test]
    fn a_measured_circle_from_a_one_degree_error_reports_one_degree() {
        let when = chrono::Utc.with_ymd_and_hms(2026, 9, 13, 2, 0, 0).unwrap();
        let (lat, lon) = (40.0, -75.0);
        let axis = horizontal_to_equatorial(lat, 1.0, lat, lon, when);

        let points = sample_circle(axis, 31.7, 0.0, 15.0, 3, false);
        let fit = fit_rotation_axis(&points, true).expect("fit");
        let (az_err, alt_err, _) =
            calculate_alignment_error_arcmin(fit.ra_degrees, fit.dec_degrees, true, lat, lon, when);
        assert!((az_err - 60.0).abs() < 0.5, "{az_err}");
        assert!(alt_err.abs() < 0.5, "{alt_err}");
    }

    #[test]
    fn rotate_axis_no_star_motion_leaves_axis_unchanged() {
        let axis = (10.0, 89.0);
        let (ra, dec) = rotate_axis_by_star_motion(axis, (5.0, 45.0), (5.0, 45.0));
        assert!((ra - axis.0).abs() < 1e-9, "ra {ra}");
        assert!((dec - axis.1).abs() < 1e-9, "dec {dec}");
    }

    #[test]
    fn rotate_axis_tracks_a_pure_polar_rotation() {
        // A reference star on the equator rotated 30° about the celestial pole
        // (Z axis) moves along a great circle, so the recovered geodesic
        // rotation IS the +30° Z-rotation. Applied to an axis at (50°, 80°) it
        // must add 30° of RA and leave Dec fixed.
        let (ra, dec) = rotate_axis_by_star_motion((50.0, 80.0), (0.0, 0.0), (30.0, 0.0));
        assert!((ra - 80.0).abs() < 1e-6, "ra {ra}");
        assert!((dec - 80.0).abs() < 1e-6, "dec {dec}");
    }
}
