use super::{
    get_polar_align_cancel, get_polar_align_flag, normalize_hour_angle, plate_solve_ra_degrees,
    polar_generation, polar_loop_control, pole_region_target, release_polar_run_if_current,
    rotation_step_target, step_crosses_meridian, try_admit_polar_run, PolarLoopControl,
    PolarOrdering, POLE_REGION_OFFSET_DEG,
};

/// The rotation between measurement points is a step about the polar axis in
/// the MOUNT's frame: mount RA moves by the step, mount Dec does not move at
/// all. Nothing about the plate solution enters the target — that is what made
/// the rig swing toward the pole in two axes instead of stepping in RA.
#[test]
fn rotation_step_holds_mount_dec_and_steps_mount_ra_only() {
    let (ra, dec) = rotation_step_target(2.0, 61.2259, 10.0, true);
    assert!(
        (ra - (2.0 + 10.0 / 15.0)).abs() < 1e-12,
        "east step adds 10°/15 h: {ra}"
    );
    assert_eq!(dec, 61.2259, "declination must be exactly the mount's own");

    let (ra, dec) = rotation_step_target(2.0, 61.2259, 10.0, false);
    assert!(
        (ra - (2.0 - 10.0 / 15.0)).abs() < 1e-12,
        "west step subtracts: {ra}"
    );
    assert_eq!(dec, 61.2259);
}

#[test]
fn rotation_step_wraps_ra_into_a_day() {
    let (ra, _) = rotation_step_target(23.8, 50.0, 10.0, true);
    assert!(
        (ra - (23.8 + 10.0 / 15.0 - 24.0)).abs() < 1e-12,
        "wraps past 24h: {ra}"
    );
    let (ra, _) = rotation_step_target(0.2, 50.0, 10.0, false);
    assert!(
        (ra - (0.2 - 10.0 / 15.0 + 24.0)).abs() < 1e-12,
        "wraps below 0h: {ra}"
    );
}

#[test]
fn hour_angle_normalizes_into_half_open_half_day() {
    assert_eq!(normalize_hour_angle(0.0), 0.0);
    assert!((normalize_hour_angle(13.0) - (-11.0)).abs() < 1e-12);
    assert!((normalize_hour_angle(-13.0) - 11.0).abs() < 1e-12);
    assert!((normalize_hour_angle(25.5) - 1.5).abs() < 1e-12);
    assert_eq!(normalize_hour_angle(12.0), -12.0);
}

/// A German equatorial flips at the meridian and at the anti-meridian; a step
/// that lands on the other side of either is refused rather than performed,
/// because the flip is a two-axis move that neither the geometry nor the
/// operator standing beside the mount wants.
#[test]
fn meridian_guard_flags_crossings_and_only_crossings() {
    // East of the meridian stepping further east: fine.
    assert!(!step_crosses_meridian(-4.3, -4.97));
    // Stepping across the meridian itself.
    assert!(step_crosses_meridian(-0.3, 0.37));
    assert!(step_crosses_meridian(0.3, -0.37));
    // Stepping across the anti-meridian (below the pole), both directions.
    assert!(step_crosses_meridian(11.8, -11.53));
    assert!(step_crosses_meridian(-11.8, 11.53));
    // Same side, near but not over either boundary.
    assert!(!step_crosses_meridian(11.0, 11.6));
    assert!(!step_crosses_meridian(-11.6, -11.0));
    // No motion is not a crossing.
    assert!(!step_crosses_meridian(0.0, 0.0));
}

#[test]
fn plate_solve_ra_is_already_degrees_for_polar_geometry() {
    assert_eq!(plate_solve_ra_degrees(10.0), 10.0);
}

/// The frame polar alignment hands the solver must carry the field scale the
/// operator already configured. Without `FOCALLEN` and the
/// binned pixel pitch, ASTAP has no scale to work from and sweeps its
/// field-of-view ladder — the slow path that fails on fields it would
/// otherwise solve, three times per alignment run.
#[test]
fn polar_solve_frame_carries_the_field_scale_hints() {
    use super::{write_temp_fits_for_solve, SolveHints};
    use crate::api::imaging::{CapturedImageResult, ImageStatsResult};

    let width = 8u32;
    let height = 6u32;
    let image = CapturedImageResult {
        width,
        height,
        display_data: vec![32u8; (width * height * 4) as usize],
        histogram: vec![0; 256],
        stats: ImageStatsResult {
            min: 0.0,
            max: 1.0,
            mean: 0.5,
            median: 0.5,
            std_dev: 0.1,
            hfr: None,
            eccentricity: None,
            fwhm: None,
            star_count: 0,
        },
        exposure_time: 2.0,
        timestamp: "2026-08-13T00:00:00Z".to_string(),
        is_color: false,
    };

    let path = crate::api::create_unique_temp_fits_path("polar_hint_test");
    let path_str = path.to_string_lossy().to_string();
    // A 416 mm scope and a 3.76 um sensor binned 2x2 — the operator's own
    // profile entry and what the camera reports.
    let hints = SolveHints {
        focal_length_mm: Some(416.0),
        pixel_size_um: Some((3.76, 3.76)),
        binning: (2, 2),
    };
    write_temp_fits_for_solve(&image, &path_str, &hints).expect("temp FITS write");

    let (_data, header) = skotiq_imaging::read_fits(&path).expect("read back temp FITS");
    assert_eq!(header.get_float("FOCALLEN"), Some(416.0));
    let xpixsz = header.get_float("XPIXSZ").expect("XPIXSZ card");
    let ypixsz = header.get_float("YPIXSZ").expect("YPIXSZ card");
    assert!(
        (xpixsz - 7.52).abs() < 1e-6 && (ypixsz - 7.52).abs() < 1e-6,
        "a 3.76 um sensor binned 2x2 has 7.52 um effective pixels, got {xpixsz} x {ypixsz}"
    );

    let _ = std::fs::remove_file(&path);
}

/// A rig that reports neither optic nor pitch contributes no card, and the
/// solver behaves exactly as it did before — no invented numbers.
#[test]
fn polar_solve_frame_omits_scale_cards_when_nothing_is_known() {
    use super::{write_temp_fits_for_solve, SolveHints};
    use crate::api::imaging::{CapturedImageResult, ImageStatsResult};

    let image = CapturedImageResult {
        width: 4,
        height: 4,
        display_data: vec![0u8; 4 * 4 * 4],
        histogram: vec![0; 256],
        stats: ImageStatsResult {
            min: 0.0,
            max: 0.0,
            mean: 0.0,
            median: 0.0,
            std_dev: 0.0,
            hfr: None,
            eccentricity: None,
            fwhm: None,
            star_count: 0,
        },
        exposure_time: 1.0,
        timestamp: "2026-08-13T00:00:00Z".to_string(),
        is_color: false,
    };

    let path = crate::api::create_unique_temp_fits_path("polar_hint_absent_test");
    let path_str = path.to_string_lossy().to_string();
    write_temp_fits_for_solve(&image, &path_str, &SolveHints::default()).expect("write");

    let (_data, header) = skotiq_imaging::read_fits(&path).expect("read back temp FITS");
    assert_eq!(header.get_float("FOCALLEN"), None);
    assert_eq!(header.get_float("XPIXSZ"), None);

    let _ = std::fs::remove_file(&path);
}

/// The pole-region slew target sits on the meridian (RA == LST, wrapped into
/// [0,24)) and `POLE_REGION_OFFSET_DEG` from the pole toward the equator,
/// with the correct sign per hemisphere.
#[test]
fn pole_region_target_on_meridian_and_offset_from_pole() {
    let (ra, dec) = pole_region_target(6.5, true);
    assert!((ra - 6.5).abs() < 1e-9, "north RA should equal LST");
    assert!(
        (dec - (90.0 - POLE_REGION_OFFSET_DEG)).abs() < 1e-9,
        "north dec should be 90 - offset, got {dec}"
    );

    let (_, dec_s) = pole_region_target(6.5, false);
    assert!(
        (dec_s - (-90.0 + POLE_REGION_OFFSET_DEG)).abs() < 1e-9,
        "south dec should be -90 + offset, got {dec_s}"
    );

    // LST wraps into [0, 24) both above 24 and below 0.
    assert!((pole_region_target(25.0, true).0 - 1.0).abs() < 1e-9);
    assert!((pole_region_target(-1.0, true).0 - 23.0).abs() < 1e-9);

    // The offset keeps the target within the ≈30° pole region but off the
    // degenerate pole itself.
    let (_, dec_n) = pole_region_target(0.0, true);
    assert!(
        (60.0..90.0).contains(&dec_n),
        "north dec in pole region: {dec_n}"
    );
}

/// The generation + owned-run primitives that back the no-overlap guarantee:
/// admitting a run bumps the generation and sets the flag; a superseding run
/// makes the old generation stale; and a *stale* release must never clear a
/// newer run's flag (which would let a third Start overlap the live run).
///
/// All the global-state assertions live in ONE test so they can't race with
/// each other over the process-wide statics.
#[test]
fn generation_admission_and_release_no_overlap() {
    // Clean baseline.
    get_polar_align_flag().store(false, PolarOrdering::Relaxed);
    get_polar_align_cancel().store(false, PolarOrdering::Relaxed);

    // Admitting a run flips the flag and clears cancel.
    let g1 = try_admit_polar_run().expect("first run admitted");
    assert!(get_polar_align_flag().load(PolarOrdering::Relaxed));
    assert!(!get_polar_align_cancel().load(PolarOrdering::Relaxed));
    assert!(matches!(polar_loop_control(g1), PolarLoopControl::Continue));

    // Atomic admission rejects a concurrent second owner.
    assert!(try_admit_polar_run().is_none());

    // Once the first run releases, a new generation can be admitted.
    release_polar_run_if_current(g1);
    let g2 = try_admit_polar_run().expect("second run admitted after release");
    assert!(g2 > g1, "generation must be monotonic: {g1} -> {g2}");
    assert!(matches!(
        polar_loop_control(g1),
        PolarLoopControl::Superseded
    ));
    assert!(matches!(polar_loop_control(g2), PolarLoopControl::Continue));

    // Cancellation only cancels the *current* generation; a stale gen still
    // reports Superseded (generation is checked before cancel).
    get_polar_align_cancel().store(true, PolarOrdering::Relaxed);
    assert!(matches!(
        polar_loop_control(g2),
        PolarLoopControl::Cancelled
    ));
    assert!(matches!(
        polar_loop_control(g1),
        PolarLoopControl::Superseded
    ));

    // A stale-generation release must NOT clear the live run's flag —
    // otherwise a superseded/aborted task could unblock a third Start while
    // the current run still owns the hardware.
    release_polar_run_if_current(g1);
    assert!(
        get_polar_align_flag().load(PolarOrdering::Relaxed),
        "stale release cleared the live run's flag"
    );

    // The current generation's release clears the flag.
    release_polar_run_if_current(g2);
    assert!(!get_polar_align_flag().load(PolarOrdering::Relaxed));

    // Leave globals clean for any other test.
    get_polar_align_cancel().store(false, PolarOrdering::Relaxed);
    // Nudge the generation so a later admission is still strictly greater.
    let _ = polar_generation().load(PolarOrdering::Relaxed);
}
