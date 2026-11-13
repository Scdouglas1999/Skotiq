use crate::api::polar_alignment::events::plate_solve_ra_degrees;
use crate::api::polar_alignment::pole_slew::{
    normalize_hour_angle, pole_region_target, rotate_for_next_point, rotation_step_target,
    slew_to_pole_region, step_crosses_meridian, SlewOutcome, POLE_REGION_MERIDIAN_MARGIN_HOURS,
    POLE_REGION_OFFSET_DEG,
};
use crate::api::polar_alignment::run_control::{
    get_polar_align_cancel, get_polar_align_flag, polar_generation, polar_loop_control,
    release_polar_run_if_current, try_admit_polar_run, PolarLoopControl,
};
use std::sync::atomic::Ordering as PolarOrdering;

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

fn raw_frame(width: u32, height: u32, data: Vec<u16>) -> crate::last_frame::RawFrame {
    crate::last_frame::RawFrame {
        width,
        height,
        data,
        bayer_pattern: None,
        camera_file: None,
        exposure: crate::last_frame::ExposureRecord {
            started_at: chrono::Utc::now(),
            exposure_secs: 2.0,
            gain: Some(139),
            offset: Some(21),
            temperature: None,
            bits_per_pixel: 16,
            readout_mode: None,
        },
    }
}

/// The solver reads the frame the camera delivered, sample for sample, not
/// the stretched 8-bit preview the screen draws: a star 40 ADU above a 1000
/// ADU sky and the difference between two bright stars both survive.
#[tokio::test]
async fn polar_solve_frame_is_the_cameras_own_samples() {
    use crate::api::plate_solve::SolveHints;
    use crate::api::polar_alignment::run_loop::write_polar_solve_frame;

    let (width, height) = (16u32, 8u32);
    let mut data = vec![1000u16; (width * height) as usize];
    data[3 * width as usize + 4] = 1040;
    data[5 * width as usize + 10] = 52_000;
    data[5 * width as usize + 11] = 61_000;

    let path = crate::util::temp_fits::create_unique_temp_fits_path("polar_raw_solve_test");
    let path_str = path.to_string_lossy().to_string();
    write_polar_solve_frame(
        raw_frame(width, height, data.clone()),
        &path_str,
        &SolveHints::default(),
    )
    .await
    .expect("solve frame write");

    let (image, header) = skotiq_imaging::read_frame(&path).expect("read back the solve frame");
    let _ = std::fs::remove_file(&path);
    assert_eq!((image.width, image.height), (width, height));
    assert_eq!(image.as_u16(), Some(data));
    assert_eq!(header.get_float("EXPTIME"), Some(2.0));
    assert_eq!(header.get_int("GAIN"), Some(139));
}

/// The frame polar alignment hands the solver must carry the field scale the
/// operator already configured. Without `FOCALLEN` and the
/// binned pixel pitch, ASTAP has no scale to work from and sweeps its
/// field-of-view ladder — the slow path that fails on fields it would
/// otherwise solve, three times per alignment run.
#[tokio::test]
async fn polar_solve_frame_carries_the_field_scale_hints() {
    use crate::api::plate_solve::SolveHints;
    use crate::api::polar_alignment::run_loop::write_polar_solve_frame;

    let path = crate::util::temp_fits::create_unique_temp_fits_path("polar_hint_test");
    let path_str = path.to_string_lossy().to_string();
    // A 416 mm scope and a 3.76 um sensor binned 2x2 — the operator's own
    // profile entry and what the camera reports.
    let hints = SolveHints {
        focal_length_mm: Some(416.0),
        pixel_size_um: Some((3.76, 3.76)),
        binning: (2, 2),
    };
    write_polar_solve_frame(raw_frame(8, 6, vec![500; 48]), &path_str, &hints)
        .await
        .expect("solve frame write");

    let (_data, header) = skotiq_imaging::read_frame(&path).expect("read back the solve frame");
    let _ = std::fs::remove_file(&path);
    assert_eq!(header.get_float("FOCALLEN"), Some(416.0));
    let xpixsz = header.get_float("XPIXSZ").expect("XPIXSZ card");
    let ypixsz = header.get_float("YPIXSZ").expect("YPIXSZ card");
    assert!(
        (xpixsz - 7.52).abs() < 1e-6 && (ypixsz - 7.52).abs() < 1e-6,
        "a 3.76 um sensor binned 2x2 has 7.52 um effective pixels, got {xpixsz} x {ypixsz}"
    );
}

/// A rig that reports neither optic nor pitch contributes no card, and the
/// solver behaves exactly as it did before — no invented numbers.
#[tokio::test]
async fn polar_solve_frame_omits_scale_cards_when_nothing_is_known() {
    use crate::api::plate_solve::SolveHints;
    use crate::api::polar_alignment::run_loop::write_polar_solve_frame;

    let path = crate::util::temp_fits::create_unique_temp_fits_path("polar_hint_absent_test");
    let path_str = path.to_string_lossy().to_string();
    write_polar_solve_frame(
        raw_frame(4, 4, vec![0; 16]),
        &path_str,
        &SolveHints::default(),
    )
    .await
    .expect("solve frame write");

    let (_data, header) = skotiq_imaging::read_frame(&path).expect("read back the solve frame");
    let _ = std::fs::remove_file(&path);
    assert_eq!(header.get_float("FOCALLEN"), None);
    assert_eq!(header.get_float("XPIXSZ"), None);
}

/// The pole-region slew target sits just beside the meridian on the side the
/// rotation moves away from, and `POLE_REGION_OFFSET_DEG` from the pole
/// toward the equator, with the correct sign per hemisphere.
#[test]
fn pole_region_target_beside_meridian_and_offset_from_pole() {
    let m = POLE_REGION_MERIDIAN_MARGIN_HOURS;
    // Rotating east lowers the hour angle, so it starts east of the meridian
    // (RA above LST); rotating west starts west of it.
    let (ra_e, dec) = pole_region_target(6.5, true, true);
    assert!(
        (ra_e - (6.5 + m)).abs() < 1e-9,
        "east run starts at HA -margin"
    );
    let (ra_w, _) = pole_region_target(6.5, true, false);
    assert!(
        (ra_w - (6.5 - m)).abs() < 1e-9,
        "west run starts at HA +margin"
    );
    assert!(
        (dec - (90.0 - POLE_REGION_OFFSET_DEG)).abs() < 1e-9,
        "north dec should be 90 - offset, got {dec}"
    );

    // Two default steps from either start never cross the meridian.
    for rotate_east in [true, false] {
        let (ra, _) = pole_region_target(6.5, true, rotate_east);
        let step = if rotate_east {
            15.0 / 15.0
        } else {
            -15.0 / 15.0
        };
        let ha0 = normalize_hour_angle(6.5 - ra);
        let ha2 = normalize_hour_angle(6.5 - (ra + 2.0 * step));
        assert!(!step_crosses_meridian(ha0, ha2), "east={rotate_east}");
    }

    let (_, dec_s) = pole_region_target(6.5, false, true);
    assert!(
        (dec_s - (-90.0 + POLE_REGION_OFFSET_DEG)).abs() < 1e-9,
        "south dec should be -90 + offset, got {dec_s}"
    );

    // RA wraps into [0, 24) both above 24 and below 0.
    assert!((pole_region_target(25.0, true, false).0 - (1.0 - m)).abs() < 1e-9);
    assert!((pole_region_target(-1.0, true, true).0 - (23.0 + m)).abs() < 1e-9);

    // The offset keeps the target within the ≈30° pole region but off the
    // degenerate pole itself.
    let (_, dec_n) = pole_region_target(0.0, true, true);
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
    let _serialized = polar_globals_test_lock().blocking_lock();
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

/// Serializes the tests that touch the process-wide run generation and cancel
/// flag.
fn polar_globals_test_lock() -> &'static tokio::sync::Mutex<()> {
    static LOCK: std::sync::OnceLock<tokio::sync::Mutex<()>> = std::sync::OnceLock::new();
    LOCK.get_or_init(|| tokio::sync::Mutex::new(()))
}

/// A rotation step on an of-date mount turns the RA axis and leaves the
/// declination axis where it was.
///
/// This is the 2026-11-07 defect on the simulator, which keeps coordinates of
/// date like the rig's mount: the step was built from the mount's of-date
/// read-back and sent down the J2000 slew path, which precessed it a second
/// time, so the mount's declination moved by the precession in declination at
/// that RA (several arcminutes in 2026) on every step.
#[tokio::test]
async fn a_rotation_step_leaves_an_of_date_mounts_declination_alone() {
    use crate::device::{DeviceInfo, DeviceType, DriverType};
    use crate::device_manager::epoch::{SimFrameGuard, SimMountFrame};
    use crate::device_manager::get_device_manager;
    use crate::simulator::mount::get_sim_mount;
    use crate::simulator::sim_singleton_test_lock;

    let _serialized = sim_singleton_test_lock().lock().await;
    let _globals = polar_globals_test_lock().lock().await;
    let _frame = SimFrameGuard::pin(SimMountFrame::OfDate);
    let mount_id = "sim_mount_polar_rotation";
    crate::simulator::register_connected(get_device_manager(), DeviceInfo {
                id: mount_id.to_string(),
                name: "Simulated Mount".to_string(),
                device_type: DeviceType::Mount,
                driver_type: DriverType::Simulator,
                description: "Simulated mount".to_string(),
                driver_version: "1.0".to_string(),
                serial_number: None,
                unique_id: None,
                display_name: "Simulated Mount".to_string(),
            }).await;
    crate::simulator::mount::cancel_sim_slew().await;

    // Three hours west of the meridian at Dec 60 of date, like run 1.
    let longitude = -75.3576;
    let lst = {
        use skotiq_sequencer::meridian::{julian_day, local_sidereal_time};
        local_sidereal_time(julian_day(&chrono::Utc::now()), longitude)
    };
    let start_ra = (lst - 3.0).rem_euclid(24.0);
    let start_dec = 60.1105;
    {
        let mut mount = get_sim_mount().write().await;
        mount.status.connected = true;
        mount.status.parked = false;
        mount.status.tracking = true;
        mount.status.slewing = false;
        mount.status.right_ascension = start_ra;
        mount.status.declination = start_dec;
        mount.status.sidereal_time = Some(lst);
    }

    get_polar_align_cancel().store(false, PolarOrdering::Relaxed);
    let generation = polar_generation().load(PolarOrdering::Relaxed);
    for (point, expected_ra) in [(2, start_ra - 20.0 / 15.0), (3, start_ra - 40.0 / 15.0)] {
        let outcome = rotate_for_next_point(
            mount_id,
            point,
            20.0,
            false,
            longitude,
            generation,
            Some(start_dec),
        )
        .await
        .expect("rotation step");
        assert!(matches!(outcome, SlewOutcome::Settled));
        let status = get_device_manager()
            .mount_get_status(mount_id)
            .await
            .unwrap();
        let dec_moved_arcsec = (status.declination - start_dec) * 3600.0;
        let ra_error_arcsec =
            ((status.right_ascension - expected_ra.rem_euclid(24.0)) * 15.0 * 3600.0)
                * start_dec.to_radians().cos();
        assert!(
            dec_moved_arcsec.abs() < 1.0,
            "point {point}: the declination axis moved {dec_moved_arcsec:.0}\""
        );
        assert!(
            ra_error_arcsec.abs() < 1.0,
            "point {point}: RA landed {ra_error_arcsec:.0}\" off the step"
        );
    }
}

/// The pole-region slew lands beside the meridian of date at Dec 60 of date.
///
/// Its target is the local sidereal time, an hour angle of zero of date, and
/// sending it down the J2000 slew path unconverted landed it off the meridian
/// and off Dec 60 by the precession.
#[tokio::test]
async fn the_pole_region_slew_lands_on_the_meridian_of_date() {
    use crate::device::{DeviceInfo, DeviceType, DriverType};
    use crate::device_manager::epoch::{SimFrameGuard, SimMountFrame};
    use crate::device_manager::get_device_manager;
    use crate::simulator::mount::get_sim_mount;
    use crate::simulator::sim_singleton_test_lock;
    use skotiq_sequencer::meridian::{julian_day, local_sidereal_time};

    let _serialized = sim_singleton_test_lock().lock().await;
    let _globals = polar_globals_test_lock().lock().await;
    let _frame = SimFrameGuard::pin(SimMountFrame::OfDate);
    let mount_id = "sim_mount_polar_pole_region";
    crate::simulator::register_connected(get_device_manager(), DeviceInfo {
                id: mount_id.to_string(),
                name: "Simulated Mount".to_string(),
                device_type: DeviceType::Mount,
                driver_type: DriverType::Simulator,
                description: "Simulated mount".to_string(),
                driver_version: "1.0".to_string(),
                serial_number: None,
                unique_id: None,
                display_name: "Simulated Mount".to_string(),
            }).await;
    crate::simulator::mount::cancel_sim_slew().await;
    {
        let mut mount = get_sim_mount().write().await;
        mount.status.connected = true;
        mount.status.parked = false;
        mount.status.tracking = true;
        mount.status.slewing = false;
    }

    let longitude = -75.3576;
    get_polar_align_cancel().store(false, PolarOrdering::Relaxed);
    let generation = polar_generation().load(PolarOrdering::Relaxed);
    let lst = local_sidereal_time(julian_day(&chrono::Utc::now()), longitude);
    let outcome = slew_to_pole_region(mount_id, true, true, longitude, generation)
        .await
        .expect("pole-region slew");
    assert!(matches!(outcome, SlewOutcome::Settled));

    let status = get_device_manager()
        .mount_get_status(mount_id)
        .await
        .unwrap();
    let dec_off_arcsec = (status.declination - 60.0) * 3600.0;
    // A run rotating east starts just east of the meridian.
    let mut ra_off_hours =
        (status.right_ascension - (lst + POLE_REGION_MERIDIAN_MARGIN_HOURS)).rem_euclid(24.0);
    if ra_off_hours > 12.0 {
        ra_off_hours -= 24.0;
    }
    assert!(
        dec_off_arcsec.abs() < 1.0,
        "landed {dec_off_arcsec:.0}\" off Dec 60 of date"
    );
    // The target is the sidereal time when it was computed; a second of
    // clock between that and this test's reading is 15".
    assert!(
        (ra_off_hours * 15.0 * 3600.0).abs() < 60.0,
        "landed {:.0}\" of RA off its hour angle of date",
        ra_off_hours * 15.0 * 3600.0
    );
}
