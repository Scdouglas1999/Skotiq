use super::*;

fn star(x: f64, y: f64, flux: f64) -> DetectedStar {
    DetectedStar {
        x,
        y,
        flux,
        hfr: 2.0,
        fwhm: 4.7,
        peak: flux,
        background: 100.0,
        snr: flux / 100.0,
        eccentricity: 0.1,
        sharpness: 0.4,
    }
}

#[test]
fn select_reference_stars_enforces_spacing() {
    let stars = vec![
        star(10.0, 10.0, 1000.0),
        star(12.0, 11.0, 900.0),
        star(40.0, 40.0, 800.0),
    ];
    let refs = select_reference_stars(&stars, 0, 0);
    assert_eq!(refs.len(), 2);
}

/// The reported RMS must be a genuine root-mean-square over the window, not
/// the newest sample. A single bad frame in an otherwise clean run barely
/// moves an RMS but would dominate an instantaneous readout.
#[test]
fn axis_rms_is_a_root_mean_square_not_the_latest_sample() {
    let samples = vec![
        Vec2 { x: 1.0, y: 0.0 },
        Vec2 { x: -1.0, y: 0.0 },
        Vec2 { x: 1.0, y: 0.0 },
        Vec2 { x: -1.0, y: 0.0 },
    ];
    let (ra, dec, total) = axis_rms(&samples);
    // Signs must not cancel: a mean would give 0.0 here, an RMS gives 1.0.
    assert!((ra - 1.0).abs() < 1e-9, "ra {ra}");
    assert!(dec.abs() < 1e-9, "dec {dec}");
    assert!((total - 1.0).abs() < 1e-9, "total {total}");
}

/// `rms_total` must be the quadrature sum of the axes, which is what PHD2
/// reports — otherwise the two guiders are not comparable.
#[test]
fn axis_rms_total_is_the_quadrature_sum() {
    let samples = vec![Vec2 { x: 3.0, y: 4.0 }];
    let (ra, dec, total) = axis_rms(&samples);
    assert!((ra - 3.0).abs() < 1e-9);
    assert!((dec - 4.0).abs() < 1e-9);
    assert!((total - 5.0).abs() < 1e-9, "total {total} should be 5.0");
}

/// No samples means no measurement, not a fabricated zero-error claim
/// dressed up as a reading. Zeros match `BuiltinGuideStatus::default`, which
/// the UI renders as "no data yet".
#[test]
fn axis_rms_of_an_empty_window_is_zero() {
    assert_eq!(axis_rms(&[]), (0.0, 0.0, 0.0));
}

/// One outlier must not dominate: this is the whole reason to report RMS
/// over a window rather than the current frame.
#[test]
fn a_single_spike_barely_moves_the_windowed_rms() {
    let mut samples = vec![Vec2 { x: 0.4, y: 0.4 }; 19];
    samples.push(Vec2 { x: 12.0, y: 12.0 });
    let (_, _, total) = axis_rms(&samples);
    let (_, _, instantaneous) = axis_rms(&samples[19..]);
    assert!(
        total < instantaneous / 3.0,
        "windowed RMS {total:.2} should be far below the spike's own {instantaneous:.2}"
    );
}

/// The window is bounded, and keeps the NEWEST samples — an RMS that never
/// forgets would keep reporting a bad patch long after guiding recovered.
#[test]
fn arcsec_window_is_capped_and_keeps_the_newest_samples() {
    let mut samples = Vec::new();
    for _ in 0..RMS_HISTORY_LEN * 2 {
        push_arcsec_sample(&mut samples, Vec2 { x: 5.0, y: 5.0 });
    }
    assert_eq!(samples.len(), RMS_HISTORY_LEN);
    for _ in 0..RMS_HISTORY_LEN {
        push_arcsec_sample(&mut samples, Vec2 { x: 0.1, y: 0.1 });
    }
    assert_eq!(samples.len(), RMS_HISTORY_LEN);
    let (_, _, total) = axis_rms(&samples);
    assert!(
        total < 0.2,
        "window should have forgotten the bad samples, got {total:.3}"
    );
}

/// A non-finite sample must be dropped rather than poisoning the window: one
/// NaN would make every subsequent RMS NaN and blank the readout for the
/// rest of the session.
#[test]
fn non_finite_samples_are_rejected() {
    let mut samples = Vec::new();
    push_arcsec_sample(
        &mut samples,
        Vec2 {
            x: f64::NAN,
            y: 0.0,
        },
    );
    push_arcsec_sample(
        &mut samples,
        Vec2 {
            x: 0.0,
            y: f64::INFINITY,
        },
    );
    assert!(samples.is_empty(), "non-finite samples must not be stored");
    push_arcsec_sample(&mut samples, Vec2 { x: 0.5, y: 0.5 });
    let (_, _, total) = axis_rms(&samples);
    assert!(total.is_finite() && total > 0.0);
}

#[test]
fn measure_offset_uses_matched_star_delta() {
    let refs = vec![
        GuideReferenceStar {
            x: 10.0,
            y: 10.0,
            flux: 1000.0,
            snr: 10.0,
            last_residual: None,
        },
        GuideReferenceStar {
            x: 30.0,
            y: 30.0,
            flux: 900.0,
            snr: 9.0,
            last_residual: None,
        },
    ];
    let stars = vec![star(11.5, 8.5, 1000.0), star(31.5, 28.5, 900.0)];
    let offset = measure_offset(&refs, &stars, Vec2::default()).expect("offset");
    assert!((offset.x - 1.5).abs() < 1e-6);
    assert!((offset.y + 1.5).abs() < 1e-6);
}

#[test]
fn guide_rms_conversion_reports_arcseconds() {
    // 3.76um pixels at 206.265mm give 3.76 arcsec/native pixel; 2x binning
    // therefore gives a known 7.52 arcsec/centroid-pixel scale.
    let pixel_scale = guide_pixel_scale_arcsec(3.76, 206.265, 2).expect("valid guide pixel scale");
    assert!((pixel_scale - 7.52).abs() < 1e-12);

    let offset =
        guide_offset_arcsec(Vec2 { x: 3.0, y: 4.0 }, pixel_scale).expect("valid angular offset");
    assert!((offset.x - 22.56).abs() < 1e-12);
    assert!((offset.y - 30.08).abs() < 1e-12);
    assert!((offset.magnitude() - 37.6).abs() < 1e-12);
}

#[test]
fn measure_offset_weights_higher_quality_reference_stars() {
    let refs = vec![
        GuideReferenceStar {
            x: 10.0,
            y: 10.0,
            flux: 10000.0,
            snr: 20.0,
            last_residual: None,
        },
        GuideReferenceStar {
            x: 30.0,
            y: 30.0,
            flux: 100.0,
            snr: 2.0,
            last_residual: None,
        },
    ];
    let stars = vec![star(12.0, 10.0, 10000.0), star(30.0, 40.0, 100.0)];
    let offset = measure_offset(&refs, &stars, Vec2::default()).expect("offset");

    assert!(offset.x > 1.8);
    assert!(offset.y < 1.0);
}

#[test]
fn record_per_star_residuals_sets_matched_star_delta() {
    let mut refs = vec![
        GuideReferenceStar {
            x: 10.0,
            y: 10.0,
            flux: 1000.0,
            snr: 10.0,
            last_residual: None,
        },
        GuideReferenceStar {
            x: 30.0,
            y: 30.0,
            flux: 900.0,
            snr: 9.0,
            last_residual: None,
        },
    ];
    // First reference drifts +1.5/-1.5; second has no nearby detection so it
    // retains its (None) residual.
    let stars = vec![star(11.5, 8.5, 1000.0), star(80.0, 80.0, 900.0)];
    record_per_star_residuals(&mut refs, &stars, Vec2::default());

    let r0 = refs[0].last_residual.expect("first star matched");
    assert!((r0.x - 1.5).abs() < 1e-6);
    assert!((r0.y + 1.5).abs() < 1e-6);
    assert!(refs[1].last_residual.is_none());
}

#[test]
fn build_tracked_stars_flags_lock_and_serializes() {
    let mut state = BuiltinGuiderState {
        reference_stars: vec![
            GuideReferenceStar {
                x: 10.0,
                y: 12.0,
                flux: 5000.0,
                snr: 18.0,
                last_residual: Some(Vec2 { x: 0.3, y: -0.4 }),
            },
            GuideReferenceStar {
                x: 60.0,
                y: 64.0,
                flux: 2000.0,
                snr: 9.0,
                last_residual: None,
            },
        ],
        ..Default::default()
    };
    // Lock sits on top of the second reference star.
    state.manual_lock = Some(Vec2 { x: 60.0, y: 64.0 });

    let dto = build_tracked_stars(&state);
    assert_eq!(dto.count, 2);
    assert_eq!(dto.stars[0].id, 0);
    assert!(!dto.stars[0].is_lock);
    assert!(
        dto.stars[1].is_lock,
        "nearest reference to lock is the lock"
    );
    // residual magnitude of (0.3,-0.4) is 0.5
    assert!((dto.stars[0].residual.expect("residual") - 0.5).abs() < 1e-6);
    assert!(dto.stars[1].residual.is_none());

    let json = serde_json::to_string(&dto).expect("serialize");
    assert!(json.contains("\"count\":2"));
    assert!(json.contains("\"is_lock\":true"));
}

#[test]
fn build_tracked_stars_empty_is_zero_count() {
    let state = BuiltinGuiderState::default();
    let dto = build_tracked_stars(&state);
    assert_eq!(dto.count, 0);
    assert!(dto.stars.is_empty());
}

#[test]
fn nearest_star_respects_max_distance() {
    let stars = vec![star(10.0, 10.0, 1000.0), star(30.0, 30.0, 900.0)];
    let near = nearest_star(&stars, Vec2 { x: 11.0, y: 11.0 }, 5.0).expect("near");
    assert_eq!(near.x, 10.0);
    assert!(nearest_star(&stars, Vec2 { x: 100.0, y: 100.0 }, 5.0).is_none());
}

/// One Auto Select click must not log two different positions for one star —
/// "chose a guide star at (967.8, 724.3) px" and then "locked guide star at
/// (24.8, 25.3) px" — with the operator-facing banner showing the second. The
/// two numbers are the same star in two coordinate spaces: the full guide
/// frame, and the 50 px crop cut around it. Only the first is a position
/// anyone can act on.
#[test]
fn reported_lock_position_is_in_frame_coordinates() {
    let image = ImageData::from_u16(200, 200, 1, &vec![0u16; 200 * 200]);
    let detected = star(120.0, 90.0, 1000.0);
    let crop = crop_raw_u16_image(&image, &detected, 50);
    let snapshot = GuideSnapshot {
        frame: 1,
        width: crop.width,
        height: crop.height,
        pixels: crop.pixels,
        crop_origin_x: crop.crop_origin_x,
        crop_origin_y: crop.crop_origin_y,
        star_x: crop.star_x,
        star_y: crop.star_y,
    };

    // The two spaces really do differ here, so the assertion below is not
    // passing by coincidence.
    assert!(
        (snapshot.star_x - detected.x).abs() > 10.0,
        "crop-local x {} should be nowhere near frame x {}",
        snapshot.star_x,
        detected.x
    );

    let (x, y) = snapshot.star_frame_position();
    assert!((x - detected.x).abs() < 1e-9, "frame x was {x}");
    assert!((y - detected.y).abs() < 1e-9, "frame y was {y}");
}

#[test]
fn crop_raw_image_returns_16bit_payload() {
    let image = ImageData::from_u16(4, 4, 1, &(0..16).collect::<Vec<u16>>());
    let crop = crop_raw_u16_image(&image, &star(1.0, 1.0, 1000.0), 2);
    assert_eq!(crop.width, 2);
    assert_eq!(crop.height, 2);
    assert_eq!(crop.pixels.len(), 8);
}

// Multi-star guider math (star selection, robust centroid, calibration,
// backlash, correction clamps, adaptive/spiral dither).
//
// These exercise the pure functions directly with synthetic star fields so
// the guiding-quality logic is validated without a mount or camera. Honest
// gap: none of this is a substitute for an on-sky calibration/guiding run,
// which belongs in the on-sky campaign.

/// Build a `DetectedStar` with explicit quality fields for selection tests.
fn star_q(x: f64, y: f64, flux: f64, snr: f64, peak: f64, ecc: f64) -> DetectedStar {
    DetectedStar {
        x,
        y,
        flux,
        hfr: 2.0,
        fwhm: 4.7,
        peak,
        background: 100.0,
        snr,
        eccentricity: ecc,
        sharpness: 0.4,
    }
}

/// A clean synthetic star field: a grid of well-separated, good-quality
/// stars away from the edges of a `w x h` frame.
fn synthetic_field(w: u32, h: u32, count: usize) -> Vec<DetectedStar> {
    let mut stars = Vec::new();
    let cols = (count as f64).sqrt().ceil() as usize;
    let mut i = 0;
    for r in 0..cols {
        for c in 0..cols {
            if i >= count {
                break;
            }
            let x = 40.0 + c as f64 * 40.0;
            let y = 40.0 + r as f64 * 40.0;
            // Brightest first is enforced by the caller's sort; vary flux a bit.
            let flux = 5000.0 - i as f64 * 50.0;
            stars.push(star_q(x, y, flux, 20.0, flux, 0.1));
            i += 1;
        }
    }
    let _ = (w, h);
    stars
}

/// Shift every star by `(dx, dy)` to simulate a known mount/field displacement.
fn shift_field(stars: &[DetectedStar], dx: f64, dy: f64) -> Vec<DetectedStar> {
    stars
        .iter()
        .map(|s| {
            let mut s = s.clone();
            s.x += dx;
            s.y += dy;
            s
        })
        .collect()
}

fn refs_from(stars: &[DetectedStar]) -> Vec<GuideReferenceStar> {
    select_reference_stars(stars, 800, 800)
}

// Star selection

#[test]
fn selection_rejects_saturated_faint_elongated_and_edge_stars() {
    let stars = vec![
        star_q(100.0, 100.0, 5000.0, 20.0, 5000.0, 0.1), // good
        star_q(200.0, 200.0, 5000.0, 20.0, 65000.0, 0.1), // saturated peak
        star_q(300.0, 300.0, 50.0, 3.0, 50.0, 0.1),      // too faint (SNR<6)
        star_q(400.0, 400.0, 5000.0, 20.0, 5000.0, 0.9), // too elongated
        star_q(2.0, 400.0, 5000.0, 20.0, 5000.0, 0.1),   // off left edge
        star_q(400.0, 799.0, 5000.0, 20.0, 5000.0, 0.1), // off bottom edge
    ];
    let refs = select_reference_stars(&stars, 800, 800);
    assert_eq!(refs.len(), 1, "only the one good star should be selected");
    assert_eq!(refs[0].x, 100.0);
}

#[test]
fn selection_caps_at_max_tracked_stars() {
    let mut stars = synthetic_field(800, 800, 30);
    stars.sort_by(|a, b| b.flux.partial_cmp(&a.flux).unwrap());
    let refs = select_reference_stars(&stars, 800, 800);
    assert_eq!(refs.len(), GUIDE_MAX_TRACKED_STARS);
}

// Robust weighted centroid

#[test]
fn weighted_centroid_recovers_known_displacement() {
    let field = synthetic_field(800, 800, 9);
    let refs = refs_from(&field);
    let moved = shift_field(&field, 2.3, -1.1);
    let offset = measure_offset(&refs, &moved, Vec2::default()).expect("offset");
    assert!((offset.x - 2.3).abs() < 1e-6, "x={}", offset.x);
    assert!((offset.y + 1.1).abs() < 1e-6, "y={}", offset.y);
}

#[test]
fn one_star_jump_does_not_move_robust_offset() {
    // All stars shifted by a true (1.0, 0.5); one star additionally "jumps"
    // by a large spurious amount. The sigma-clipped offset must reject it.
    let field = synthetic_field(800, 800, 9);
    let refs = refs_from(&field);
    let mut moved = shift_field(&field, 1.0, 0.5);
    // Make the first detection jump far (within match distance of its ref+true
    // shift so it still associates, but as an outlier displacement).
    moved[0].x += 8.0;
    moved[0].y += 8.0;

    let robust = measure_offset(&refs, &moved, Vec2::default()).expect("offset");
    assert!(
        (robust.x - 1.0).abs() < 0.15 && (robust.y - 0.5).abs() < 0.15,
        "robust offset should reject the jumped star: got ({}, {})",
        robust.x,
        robust.y
    );

    // A naive (non-clipped) mean would be visibly pulled by the outlier.
    let naive = {
        let disps = matched_displacements(&refs, &moved, Vec2::default());
        let mut sx = 0.0;
        let mut sy = 0.0;
        for d in &disps {
            sx += d.delta.x;
            sy += d.delta.y;
        }
        Vec2 {
            x: sx / disps.len() as f64,
            y: sy / disps.len() as f64,
        }
    };
    assert!(
        naive.x > robust.x + 0.3,
        "naive mean should be pulled by the outlier (naive={}, robust={})",
        naive.x,
        robust.x
    );
}

#[test]
fn star_loss_continuity_keeps_guiding_with_two_stars() {
    let field = synthetic_field(800, 800, 9);
    let refs = refs_from(&field);
    // Only two of the nine stars are still detectable (clouds ate the rest).
    let moved_full = shift_field(&field, 1.5, -2.0);
    let surviving: Vec<DetectedStar> = moved_full.into_iter().take(2).collect();
    let offset = measure_offset(&refs, &surviving, Vec2::default())
        .expect("offset should survive on two stars");
    assert!((offset.x - 1.5).abs() < 1e-6);
    assert!((offset.y + 2.0).abs() < 1e-6);
}

#[test]
fn no_matched_stars_yields_no_offset() {
    let field = synthetic_field(800, 800, 9);
    let refs = refs_from(&field);
    // Detections far from every reference: nothing matches.
    let far = vec![star_q(2000.0, 2000.0, 5000.0, 20.0, 5000.0, 0.1)];
    assert!(measure_offset(&refs, &far, Vec2::default()).is_none());
}

#[test]
fn single_star_falls_back_to_plain_weighted_mean() {
    // Below the clip threshold, a single matched star is used directly.
    let refs = vec![GuideReferenceStar {
        x: 100.0,
        y: 100.0,
        flux: 5000.0,
        snr: 20.0,
        last_residual: None,
    }];
    let moved = vec![star_q(103.0, 98.0, 5000.0, 20.0, 5000.0, 0.1)];
    let offset = measure_offset(&refs, &moved, Vec2::default()).expect("offset");
    assert!((offset.x - 3.0).abs() < 1e-6);
    assert!((offset.y + 2.0).abs() < 1e-6);
}

// Calibration math

#[test]
fn calibration_recovers_angles_rates_and_orthogonality() {
    // RA along +x at 4 px/pulse, Dec along +y at 3 px/pulse: orthogonal.
    let east = Vec2 { x: 4.0, y: 0.0 };
    let north = Vec2 { x: 0.0, y: 3.0 };
    let calib = build_calibration(east, north, 250.0, 0.0).expect("calib");
    assert!((calib.ra_rate() - 4.0 / 250.0).abs() < 1e-9);
    assert!((calib.dec_rate() - 3.0 / 250.0).abs() < 1e-9);
    assert!((calib.orthogonality_deg - 90.0).abs() < 1e-6);
}

#[test]
fn calibration_measures_non_orthogonal_axes() {
    // RA along +x, Dec at 60° from RA.
    let east = Vec2 { x: 4.0, y: 0.0 };
    let north = Vec2 {
        x: 3.0 * 60f64.to_radians().cos(),
        y: 3.0 * 60f64.to_radians().sin(),
    };
    let calib = build_calibration(east, north, 250.0, 0.0).expect("calib");
    assert!((calib.orthogonality_deg - 60.0).abs() < 1e-6);
}

#[test]
fn calibration_rejects_singular_axes() {
    // Both axes parallel -> singular -> error.
    let east = Vec2 { x: 4.0, y: 0.0 };
    let north = Vec2 { x: 2.0, y: 0.0 };
    assert!(build_calibration(east, north, 250.0, 0.0).is_err());
}

#[test]
fn dec_backlash_recovered_from_short_first_reversal() {
    // Forward 3 px/pulse; the first reverse pulse only travelled 2.1 px, i.e.
    // 0.9 px short. At 3 px / 250 ms = 0.012 px/ms, that is 75 ms of backlash.
    let fwd = Vec2 { x: 0.0, y: 3.0 };
    let rev_first = Vec2 { x: 0.0, y: -2.1 };
    let backlash = estimate_dec_backlash_ms(fwd, rev_first, 250.0);
    assert!((backlash - 75.0).abs() < 1.0, "backlash={backlash}");
}

#[test]
fn no_backlash_when_reversal_is_full() {
    let fwd = Vec2 { x: 0.0, y: 3.0 };
    let rev_first = Vec2 { x: 0.0, y: -3.0 };
    assert_eq!(estimate_dec_backlash_ms(fwd, rev_first, 250.0), 0.0);
}

/// Pins WHY the reverse leg must not swallow a failed star match into
/// `Vec2::default()`: a zero reverse offset makes the estimator return
/// exactly one full calibration pulse — the maximum plausible backlash —
/// which was then added to every Dec reversal for the session. The caller
/// now reports "unmeasured" (0.0) instead of feeding this in.
#[test]
fn zero_reverse_offset_would_infer_a_full_pulse_of_backlash() {
    let fwd = Vec2 { x: 0.0, y: 3.0 };
    let lost_star = Vec2::default();
    assert_eq!(estimate_dec_backlash_ms(fwd, lost_star, 250.0), 250.0);
    // ...and it scales with the pulse, so a 2 s calibration would inject 2 s.
    assert_eq!(estimate_dec_backlash_ms(fwd, lost_star, 2000.0), 2000.0);
}

// Corrections: aggressiveness, clamps, backlash compensation

fn ortho_calib(backlash_ms: f64) -> GuideCalibration {
    // RA +x, Dec +y, 1 px/pulse on each, pulse = 100 ms.
    build_calibration(
        Vec2 { x: 1.0, y: 0.0 },
        Vec2 { x: 0.0, y: 1.0 },
        100.0,
        backlash_ms,
    )
    .expect("calib")
}

#[test]
fn correction_applies_aggressiveness() {
    let calib = ortho_calib(0.0);
    let mut config = GuiderConfig {
        ra_aggressiveness: 0.5,
        dec_aggressiveness: 0.5,
        min_move_px: 0.0,
        min_pulse_ms: 0.0,
        ..GuiderConfig::default()
    };
    config.max_pulse_ms = 100000.0;
    // Offset of (10, 10) px -> to null it, pulse -10 px each axis = -1000 ms
    // raw; at 0.5 aggressiveness => -500 ms.
    let plan = compute_pulse_durations(
        calib,
        Vec2 { x: 10.0, y: 10.0 },
        &config,
        None,
        PulseDebt::default(),
    );
    let ra = plan.ra_ms.expect("ra");
    // First Dec pulse pays backlash, but backlash=0 here.
    let dec = plan.dec_ms.expect("dec");
    assert!((ra + 500.0).abs() < 1e-6, "ra={ra}");
    assert!((dec + 500.0).abs() < 1e-6, "dec={dec}");
}

#[test]
fn correction_min_move_suppresses_tiny_offset() {
    let calib = ortho_calib(0.0);
    let config = GuiderConfig {
        min_move_px: 0.5,
        ..GuiderConfig::default()
    };
    // 0.1 px offset is below min_move -> no pulses.
    let plan = compute_pulse_durations(
        calib,
        Vec2 { x: 0.1, y: 0.1 },
        &config,
        None,
        PulseDebt::default(),
    );
    assert!(plan.ra_ms.is_none());
    assert!(plan.dec_ms.is_none());
}

#[test]
fn correction_clamps_to_max_pulse() {
    let calib = ortho_calib(0.0);
    let config = GuiderConfig {
        ra_aggressiveness: 1.0,
        dec_aggressiveness: 1.0,
        min_move_px: 0.0,
        max_pulse_ms: 300.0,
        ..GuiderConfig::default()
    };
    // 50 px offset -> 5000 ms raw, clamped to 300 ms.
    let plan = compute_pulse_durations(
        calib,
        Vec2 { x: 50.0, y: 0.0 },
        &config,
        None,
        PulseDebt::default(),
    );
    assert!((plan.ra_ms.expect("ra").abs() - 300.0).abs() < 1e-6);
}

#[test]
fn dec_backlash_added_only_on_reversal() {
    let calib = ortho_calib(120.0); // 120 ms backlash
    let config = GuiderConfig {
        ra_aggressiveness: 1.0,
        dec_aggressiveness: 1.0,
        min_move_px: 0.0,
        min_pulse_ms: 0.0,
        max_pulse_ms: 100000.0,
        ..GuiderConfig::default()
    };
    // Offset (0, 5) -> null with Dec -500 ms (South). Coming from North => reversal.
    let reversal = compute_pulse_durations(
        calib,
        Vec2 { x: 0.0, y: 5.0 },
        &config,
        Some(DecDirection::North),
        PulseDebt::default(),
    );
    let dec_rev = reversal.dec_ms.expect("dec");
    assert!(
        (dec_rev + 620.0).abs() < 1e-6,
        "reversal should add 120ms backlash: {dec_rev}"
    );
    assert_eq!(reversal.new_dec_direction, Some(DecDirection::South));

    // Same correction but already moving South => no backlash added.
    let same_dir = compute_pulse_durations(
        calib,
        Vec2 { x: 0.0, y: 5.0 },
        &config,
        Some(DecDirection::South),
        PulseDebt::default(),
    );
    assert!((same_dir.dec_ms.expect("dec") + 500.0).abs() < 1e-6);
}

// Sub-minimum pulse carry (standing-offset defect)

/// A realistic rig: 1.5 px per 250 ms pulse (what the simulator produces and
/// the same order as a real short guide scope), stock aggressiveness and the
/// stock 75 ms mount minimum.
fn realistic_calib() -> GuideCalibration {
    build_calibration(Vec2 { x: 1.5, y: 0.0 }, Vec2 { x: 0.0, y: 1.5 }, 250.0, 0.0).expect("calib")
}

/// The defect this carry exists to fix: with the pulse floor applied to each
/// frame in isolation, a real error well above the configured 0.15 px noise
/// floor produces no correction at all, forever.
#[test]
fn small_but_real_error_is_below_the_mount_pulse_floor() {
    let calib = realistic_calib();
    let config = GuiderConfig::default();
    // 0.3 px is twice the configured min-move, so the guider considers it a
    // real error and not noise...
    let offset = Vec2 { x: 0.3, y: 0.0 };
    assert!(offset.x > config.min_move_px);

    // ...yet a single frame in isolation still issues nothing, because the
    // pulse that would null it is shorter than the mount's minimum. Asserted
    // through `compute_pulse_durations` rather than by recomputing the
    // arithmetic here: a test that re-derives the formula it is checking
    // passes even if the function stops using it.
    let plan = compute_pulse_durations(calib, offset, &config, None, PulseDebt::default());
    assert!(
        plan.ra_ms.is_none(),
        "one isolated frame cannot correct a sub-minimum error (got {:?}ms); \
         that is precisely why the demand has to be carried across frames",
        plan.ra_ms
    );
    // The demand must be REMEMBERED rather than dropped — dropping it is the
    // defect, and it is invisible from the pulse alone.
    assert!(
        plan.debt.ra_ms != 0.0,
        "the uncorrected demand was discarded instead of carried, so a \
         standing error can never be worked off"
    );
}

#[test]
fn sustained_sub_minimum_error_accumulates_into_one_honourable_pulse() {
    let calib = realistic_calib();
    let config = GuiderConfig::default();
    let offset = Vec2 { x: 0.3, y: 0.0 };

    let mut debt = PulseDebt::default();
    let mut issued: Vec<f64> = Vec::new();
    for _ in 0..8 {
        let plan = compute_pulse_durations(calib, offset, &config, None, debt);
        debt = plan.debt;
        if let Some(ra) = plan.ra_ms {
            issued.push(ra);
        }
    }

    assert!(
        !issued.is_empty(),
        "a sustained 0.3px error must eventually be corrected; it was silently \
         ignored on every frame, which is what parks the guide graph off zero"
    );
    for ms in &issued {
        assert!(
            ms.abs() >= config.min_pulse_ms,
            "issued pulse {ms}ms is shorter than the mount minimum"
        );
        assert!(ms < &0.0, "a +x offset must be corrected westward: {ms}");
    }
}

#[test]
fn carried_demand_never_exceeds_one_minimum_pulse_of_overshoot() {
    let calib = realistic_calib();
    let config = GuiderConfig::default();
    let offset = Vec2 { x: 0.3, y: 0.0 };

    let mut debt = PulseDebt::default();
    for _ in 0..40 {
        let plan = compute_pulse_durations(calib, offset, &config, None, debt);
        debt = plan.debt;
        assert!(
            debt.ra_ms.abs() < config.min_pulse_ms,
            "carried demand {}ms must stay under one minimum pulse",
            debt.ra_ms
        );
    }
}

#[test]
fn symmetric_noise_cancels_instead_of_accumulating() {
    let calib = realistic_calib();
    let config = GuiderConfig {
        // Treat the wobble as real so it reaches the carry logic at all.
        min_move_px: 0.0,
        ..GuiderConfig::default()
    };

    let mut debt = PulseDebt::default();
    let mut pulses = 0;
    for i in 0..40 {
        let x = if i % 2 == 0 { 0.2 } else { -0.2 };
        let plan = compute_pulse_durations(calib, Vec2 { x, y: 0.0 }, &config, None, debt);
        debt = plan.debt;
        if plan.ra_ms.is_some() {
            pulses += 1;
        }
    }
    assert_eq!(
        pulses, 0,
        "zero-mean noise must not integrate into a correction"
    );
}

#[test]
fn quiet_axis_forgets_carried_demand() {
    let calib = realistic_calib();
    let config = GuiderConfig::default();

    // Build up some demand from a real error...
    let plan = compute_pulse_durations(
        calib,
        Vec2 { x: 0.3, y: 0.0 },
        &config,
        None,
        PulseDebt::default(),
    );
    assert!(plan.ra_ms.is_none());
    assert!(plan.debt.ra_ms.abs() > 0.0);

    // ...then drop inside the noise floor: the demand is abandoned, so a
    // settled star can never be nudged by history.
    let quiet = compute_pulse_durations(calib, Vec2 { x: 0.01, y: 0.0 }, &config, None, plan.debt);
    assert!(quiet.ra_ms.is_none());
    assert_eq!(quiet.debt.ra_ms, 0.0);
}

#[test]
fn a_pulse_that_fires_clears_its_debt() {
    let calib = ortho_calib(0.0);
    let config = GuiderConfig {
        ra_aggressiveness: 1.0,
        dec_aggressiveness: 1.0,
        min_move_px: 0.0,
        ..GuiderConfig::default()
    };
    // 10 px on a 1 px/100 ms rig is a 1000 ms correction: issued outright,
    // and nothing is owed afterwards.
    let plan = compute_pulse_durations(
        calib,
        Vec2 { x: 10.0, y: 0.0 },
        &config,
        None,
        PulseDebt {
            ra_ms: 40.0,
            dec_ms: 0.0,
        },
    );
    let ra = plan.ra_ms.expect("ra");
    // The carried 40 ms is spent on this pulse rather than lost.
    assert!((ra + 960.0).abs() < 1e-6, "ra={ra}");
    assert_eq!(plan.debt.ra_ms, 0.0);
}

#[test]
fn dec_backlash_is_not_re_added_while_the_pulse_is_still_being_carried() {
    let calib = realistic_calib_with_backlash(500.0);
    let config = GuiderConfig::default();
    let offset = Vec2 { x: 0.0, y: 0.3 };

    let mut debt = PulseDebt::default();
    let mut fired = 0;
    for _ in 0..6 {
        let plan = compute_pulse_durations(calib, offset, &config, None, debt);
        debt = plan.debt;
        if plan.dec_ms.is_some() {
            fired += 1;
        }
        // The 500 ms backlash term must never leak into the carried demand,
        // which would fabricate a huge correction after a few quiet frames.
        assert!(
            debt.dec_ms.abs() < config.min_pulse_ms,
            "carried Dec demand {}ms shows backlash leaking into the debt",
            debt.dec_ms
        );
    }
    assert!(
        fired > 0,
        "a reversal-eligible Dec error plus backlash should still correct"
    );
}

fn realistic_calib_with_backlash(backlash_ms: f64) -> GuideCalibration {
    build_calibration(
        Vec2 { x: 1.5, y: 0.0 },
        Vec2 { x: 0.0, y: 1.5 },
        250.0,
        backlash_ms,
    )
    .expect("calib")
}

// Adaptive / spiral dither

#[test]
fn dither_spiral_walks_to_fresh_pixels() {
    let p0 = dither_offset(5.0, false, 0, None);
    let p1 = dither_offset(5.0, false, 1, None);
    let p2 = dither_offset(5.0, false, 2, None);
    // Successive steps are well separated (not re-treading one spot).
    let d01 = (Vec2 {
        x: p0.x - p1.x,
        y: p0.y - p1.y,
    })
    .magnitude();
    let d12 = (Vec2 {
        x: p1.x - p2.x,
        y: p1.y - p2.y,
    })
    .magnitude();
    assert!(d01 > 1.0 && d12 > 1.0, "steps too close: {d01}, {d12}");
    // Radius grows with step (sunflower spiral expands).
    assert!(p2.magnitude() > p0.magnitude());
}

#[test]
fn dither_adapts_to_poor_seeing() {
    let good = dither_offset(5.0, false, 3, Some(0.0));
    let poor = dither_offset(5.0, false, 3, Some(10.0));
    assert!(
        poor.magnitude() > good.magnitude(),
        "poor seeing should dither larger: good={}, poor={}",
        good.magnitude(),
        poor.magnitude()
    );
}

/// A night's worth of dithers must stay inside the requested amplitude and
/// must never command a jump the star matcher cannot follow.
///
/// The shipped 6.0.0 build derived the offset from an ever-increasing step
/// (`radius = amount * sqrt(n+1)`) and ADDED it to the standing offset, so
/// the commanded move grew every dither: with the default 5 px the 8th
/// dither already exceeded GUIDE_MAX_MATCH_DISTANCE_PX and the next frame
/// matched no stars, killing guiding for the night.
#[test]
fn dither_offsets_stay_bounded_over_a_whole_night() {
    for &(amount, ra_only, rms) in &[
        (5.0, false, None),
        (5.0, false, Some(10.0)),
        (2.0, false, Some(4.0)),
        (15.0, false, None),
        (4.0, true, None),
        (4.0, true, Some(8.0)),
    ] {
        let mut current = Vec2::default();
        for step in 0..200u32 {
            let target =
                dither_target_within_jump(current, dither_offset(amount, ra_only, step, rms));
            let jump = (Vec2 {
                x: target.x - current.x,
                y: target.y - current.y,
            })
            .magnitude();
            assert!(
                jump <= DITHER_MAX_JUMP_PX + 1e-9,
                "dither {step} jumped {jump} px (amount={amount}, ra_only={ra_only})"
            );
            assert!(
                jump < GUIDE_MAX_MATCH_DISTANCE_PX,
                "dither {step} jumped past the star-match window: {jump} px"
            );
            current = target;
            assert!(
                current.magnitude() <= amount + 1e-9,
                "dither {step} left the target: |offset|={} px exceeds the configured {amount} px \
                 (amount={amount}, ra_only={ra_only})",
                current.magnitude()
            );
        }
    }
}

#[test]
fn dither_pattern_wraps_instead_of_growing() {
    let first = dither_offset(5.0, false, 3, None);
    let wrapped = dither_offset(5.0, false, 3 + DITHER_PATTERN_POINTS, None);
    assert!((first.x - wrapped.x).abs() < 1e-9);
    assert!((first.y - wrapped.y).abs() < 1e-9);
}

#[tokio::test]
async fn dither_step_resets_when_guiding_stops() {
    let _serial = test_serial().lock().await;
    reset_guider_state().await;
    state().write().await.dither_step = 11;

    {
        let _op = op_lock().lock().await;
        stop_locked().await.expect("stop");
    }

    assert_eq!(state().read().await.dither_step, 0);
    reset_guider_state().await;
}

/// An unsatisfiable dither must roll back and leave guiding running: the
/// shipped build failed the loop task, which stopped guiding AND reported
/// the guider disconnected, so recovery had to reconnect it first.
#[test]
fn abandoned_dither_rolls_back_and_leaves_guiding_running() {
    let mut guard = BuiltinGuiderState {
        guiding: true,
        desired_offset: Vec2 { x: 4.0, y: -3.0 },
        dither_origin: Vec2 { x: 1.0, y: 1.0 },
        dither_pending: true,
        dither_misses: DITHER_MATCH_GRACE_FRAMES,
        settle_deadline: Some(Instant::now()),
        settle_timeout_deadline: Some(Instant::now()),
        ..BuiltinGuiderState::default()
    };

    abandon_dither(&mut guard);

    assert!(guard.guiding, "guiding must survive an abandoned dither");
    assert!((guard.desired_offset.x - 1.0).abs() < 1e-9);
    assert!((guard.desired_offset.y - 1.0).abs() < 1e-9);
    assert!(!guard.dither_pending);
    assert!(guard.dither_abandoned);
    assert_eq!(guard.dither_misses, 0);
    assert!(guard.settle_deadline.is_none());
    assert!(guard.settle_timeout_deadline.is_none());
}

/// A settle is an episode with an end. Once it completes, ordinary guiding
/// frames must not open a new one.
///
/// Re-arming the settle on the first in-tolerance frame AFTER each settle
/// completes publishes `Settling` again within a frame of every `Settled` —
/// perpetually "about to be guiding". Observed as the Guiding screen reading
/// `Settling` for 127 frames (2.5 minutes) at 0.26px total RMS while the
/// status bar of the same screen read `Guiding`. Automated flows gate on
/// settled, and the re-armed timeout can also fail the loop task (stopping
/// guiding) over a session that is guiding fine.
#[tokio::test]
async fn a_completed_settle_does_not_re_arm_on_the_next_guiding_frame() {
    let controller = Arc::new(RwLock::new(BuiltinGuiderState {
        guiding: true,
        settling: true,
        settle_spec: SettleSpec {
            pixels: 1.0,
            time: 0.0,
            timeout: 30.0,
        },
        settle_timeout_deadline: Some(Instant::now() + Duration::from_secs(30)),
        ..BuiltinGuiderState::default()
    }));
    // settle_time 0 collapses to the 0.1s floor, so one sleep spans it.
    let settle = |offset: f64| {
        let controller = controller.clone();
        async move { apply_settle_state(controller, offset).await }
    };

    settle(0.1).await.expect("arm the settle");
    assert!(
        controller.read().await.settle_deadline.is_some(),
        "the first in-tolerance frame starts the settle timer"
    );

    tokio::time::sleep(Duration::from_millis(150)).await;
    settle(0.1).await.expect("complete the settle");
    assert!(controller.read().await.settle_deadline.is_none());
    assert!(!controller.read().await.settling, "the episode is over");

    settle(0.1).await.expect("keep guiding");
    let guard = controller.read().await;
    assert!(
        guard.settle_deadline.is_none(),
        "a settled guider re-entered settling on the next ordinary frame"
    );
    assert!(
        guard.settle_timeout_deadline.is_none(),
        "a settle timeout was re-armed over a guider that is already settled"
    );
}

/// A looping frame must announce its star measurement. The guide-star badge
/// and Star Statistics' `SNR` / `Star Mass` / `Frame Count` are all fed by the
/// `GuideStats` event, so a looping path that stores its measurement without
/// emitting one leaves the badge reading `SNR: 0.0` and the statistics blank
/// through a whole Loop Exposures run over a plainly bright star.
#[tokio::test]
async fn a_looping_frame_announces_its_star_measurement() {
    let mut events = get_state().event_bus.subscribe();
    let mut guard = BuiltinGuiderState {
        looping: true,
        ..BuiltinGuiderState::default()
    };

    publish_star_measurement(&mut guard, Some(&star(10.0, 10.0, 4200.0)));

    assert!((guard.last_status.star_mass - 4200.0).abs() < 1e-9);
    let announced = loop {
        let event = tokio::time::timeout(Duration::from_secs(2), events.recv())
            .await
            .expect("no guiding event published for a looping frame")
            .expect("event bus closed");
        if let crate::event::EventPayload::Guiding(crate::event::GuidingEvent::GuideStats {
            snr,
            star_mass,
        }) = event.payload
        {
            break (snr, star_mass);
        }
    };
    assert!((announced.0 - 42.0).abs() < 1e-9, "SNR must reach the UI");
    assert!((announced.1 - 4200.0).abs() < 1e-9);
}

/// The counterpart: a dither opens a fresh episode, and the loop settles it.
#[tokio::test]
async fn a_dither_opens_a_new_settle_episode() {
    let controller = Arc::new(RwLock::new(BuiltinGuiderState {
        guiding: true,
        settling: true,
        dither_pending: true,
        settle_spec: SettleSpec {
            pixels: 1.0,
            time: 0.0,
            timeout: 30.0,
        },
        settle_timeout_deadline: Some(Instant::now() + Duration::from_secs(30)),
        ..BuiltinGuiderState::default()
    }));

    apply_settle_state(controller.clone(), 0.1)
        .await
        .expect("arm");
    tokio::time::sleep(Duration::from_millis(150)).await;
    apply_settle_state(controller.clone(), 0.1)
        .await
        .expect("settle");

    let guard = controller.read().await;
    assert!(!guard.dither_pending, "the dither settled");
    assert!(!guard.settling);
}

/// The dither's OWN settle tolerance is the one the loop applies.
///
/// `dither(amount, ra_only, settle_pixels, settle_time, settle_timeout)` is how
/// the sequencer's Dither instruction states how tightly this dither must
/// settle. The loop used to judge every settle by the tolerance captured back at
/// `start_guiding` and discarded the dither's own pair outright, so a sequence
/// asking to settle inside 0.2px
/// was told it had settled at 1.5px — with `guider_dither` logging the 0.2px it
/// never enforced.
#[tokio::test]
async fn a_dither_settles_on_its_own_tolerance_not_the_sessions() {
    let controller = Arc::new(RwLock::new(BuiltinGuiderState {
        guiding: true,
        settling: true,
        dither_pending: true,
        // What `start_guiding` left behind: a loose session tolerance.
        settle_spec: SettleSpec {
            pixels: 1.5,
            time: 0.0,
            timeout: 30.0,
        },
        settle_timeout_deadline: Some(Instant::now() + Duration::from_secs(30)),
        ..BuiltinGuiderState::default()
    }));

    // What this dither asked for: settle inside 0.2px.
    controller.write().await.settle_spec = SettleSpec {
        pixels: 0.2,
        time: 0.0,
        timeout: 30.0,
    };

    // 0.9px is inside the SESSION tolerance and outside the DITHER's.
    apply_settle_state(controller.clone(), 0.9)
        .await
        .expect("frame accepted");
    assert!(
        controller.read().await.settle_deadline.is_none(),
        "0.9px opened a settle the dither's 0.2px tolerance forbids"
    );
    assert!(
        controller.read().await.dither_pending,
        "the dither cannot be complete while RMS is above its own tolerance"
    );

    // Inside the dither's own tolerance the settle proceeds normally.
    apply_settle_state(controller.clone(), 0.1)
        .await
        .expect("arm");
    tokio::time::sleep(Duration::from_millis(150)).await;
    apply_settle_state(controller.clone(), 0.1)
        .await
        .expect("settle");
    let guard = controller.read().await;
    assert!(!guard.dither_pending, "the dither settled on its own spec");
    assert!(!guard.settling);
}

#[test]
fn dither_ra_only_stays_on_ra_axis_and_alternates() {
    let s0 = dither_offset(4.0, true, 0, None);
    let s1 = dither_offset(4.0, true, 1, None);
    assert_eq!(s0.y, 0.0);
    assert_eq!(s1.y, 0.0);
    assert!(
        s0.x.signum() != s1.x.signum(),
        "RA-only should alternate sign"
    );
}

// start/stop lifecycle race
//
// Storing the loop's `stop_flag`/`task` AFTER spawning the loop leaves a window
// where a concurrent `stop()` finds `None`, signals nothing, and orphans a
// mount-pulsing loop. The stop flag is stored in the same write-lock critical
// section that flips the run-state (before the spawn) and every lifecycle entry
// point serializes on `op_lock`, so a stop can never interleave a start and
// lose the cancel. These tests use a synthetic loop (no hardware) that reports
// liveness so an orphan is directly observable.

use std::sync::atomic::{AtomicUsize, Ordering};

/// Serializes the lifecycle race tests, which all mutate the same
/// process-global guider singleton. Cargo runs tests in parallel by default;
/// without this, one test's `reset_guider_state` would wipe another's loop
/// mid-flight. (Distinct from the production `op_lock`, which serializes
/// lifecycle ops but does not stop one test from resetting another's state.)
static TEST_SERIAL: OnceLock<Arc<Mutex<()>>> = OnceLock::new();

fn test_serial() -> &'static Arc<Mutex<()>> {
    TEST_SERIAL.get_or_init(|| Arc::new(Mutex::new(())))
}

/// Reset the shared guider state between race tests (they all touch the same
/// process-global singleton).
async fn reset_guider_state() {
    let _op = op_lock().lock().await;
    let _ = stop_locked().await;
    *state().write().await = BuiltinGuiderState::default();
}

/// Spin until `cond()` is true or the deadline elapses; returns whether the
/// condition held.
async fn wait_until<F: Fn() -> bool>(cond: F, max: Duration) -> bool {
    let deadline = Instant::now() + max;
    while Instant::now() < deadline {
        if cond() {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(1)).await;
    }
    cond()
}

#[tokio::test]
async fn start_then_immediate_stop_cancels_loop() {
    let _serial = test_serial().lock().await;
    reset_guider_state().await;
    let live = Arc::new(AtomicUsize::new(0));

    start_synthetic_loop(live.clone()).await;
    // The loop is live (or about to be); `stop()` must cancel it regardless of
    // exactly where it is between spawn and handle-record.
    stop().await.expect("stop");

    // After stop returns, the loop must be gone: its handle was joined, so the
    // spinning task observed the flag and exited.
    assert_eq!(
        live.load(Ordering::SeqCst),
        0,
        "loop still alive after stop — orphaned mount-pulsing task"
    );
    let guard = state().read().await;
    assert!(!guard.guiding, "guiding must be cleared by stop");
    assert!(
        guard.stop_flag.is_none(),
        "stop must consume the stop_flag (no dead handle left behind)"
    );
    assert!(guard.task.is_none(), "stop must consume the task handle");
}

#[tokio::test]
async fn active_loop_always_has_a_live_stop_flag() {
    let _serial = test_serial().lock().await;
    // Whenever the run-state says a loop is active, a `stop_flag` must be present
    // for `stop()` to signal. Flipping `guiding=true`, releasing the lock,
    // spawning, and only then storing the flag leaves a window where
    // `guiding==true && stop_flag==None`.
    reset_guider_state().await;
    let live = Arc::new(AtomicUsize::new(0));
    start_synthetic_loop(live.clone()).await;

    {
        let guard = state().read().await;
        assert!(guard.guiding || guard.looping || guard.calibrating);
        assert!(
            guard.stop_flag.is_some(),
            "active loop must always carry a live stop_flag"
        );
        assert!(
            guard.task.is_some(),
            "active loop must have its JoinHandle recorded"
        );
    }

    stop().await.expect("stop");
    assert_eq!(live.load(Ordering::SeqCst), 0, "loop must be cancelled");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn concurrent_start_stop_start_never_orphans_loop() {
    let _serial = test_serial().lock().await;
    // Two starts and a stop fired concurrently. Without the op-lock a stop
    // landing in start1's spawn→record window drops start1's cancel and start2
    // then overwrites the stored flag/handle, stranding loop1 forever — its flag
    // clone is no longer reachable from any future stop. `live` (loops currently
    // running) must return to 0 after a final stop; a non-zero count is a leaked
    // mount-pulsing loop. The op-lock makes start1/stop/start2 atomic, so each
    // start's `stop_locked()` joins the prior loop and nothing leaks.
    for round in 0..150 {
        reset_guider_state().await;
        let live = Arc::new(AtomicUsize::new(0));

        let l1 = live.clone();
        let l2 = live.clone();
        let start1 = tokio::spawn(async move { start_synthetic_loop(l1).await });
        let stopper = tokio::spawn(async move {
            let _ = stop().await;
        });
        let start2 = tokio::spawn(async move { start_synthetic_loop(l2).await });
        let _ = tokio::join!(start1, stopper, start2);

        // A final stop must guarantee no loop is left running.
        stop().await.expect("final stop");

        let settled = wait_until(|| live.load(Ordering::SeqCst) == 0, Duration::from_secs(2)).await;
        assert!(
            settled,
            "round {round}: {} loop(s) survived a final stop() — orphaned mount-pulsing task",
            live.load(Ordering::SeqCst)
        );

        let guard = state().read().await;
        assert!(
            !guard.guiding && !guard.looping && !guard.calibrating,
            "round {round}: run-state still active after final stop"
        );
        assert!(
            guard.stop_flag.is_none() && guard.task.is_none(),
            "round {round}: dead handle/flag left in state after final stop"
        );
    }
}
