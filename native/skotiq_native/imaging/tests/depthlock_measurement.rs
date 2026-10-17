use skotiq_imaging::depthlock::{
    evaluate, ApertureFrame, Candidate, DepthState, MeasurementSpec, SkyRectangle,
};

fn spec() -> MeasurementSpec {
    MeasurementSpec {
        version: 1,
        region: SkyRectangle {
            ra_deg: 90.0,
            dec_deg: 30.0,
            width_arcsec: 40.0,
            height_arcsec: 40.0,
            rotation_deg: 0.0,
        },
        background: SkyRectangle {
            ra_deg: 90.03,
            dec_deg: 30.0,
            width_arcsec: 40.0,
            height_arcsec: 40.0,
            rotation_deg: 0.0,
        },
        scale_arcsec: 10.0,
        threshold: 5.0,
        min_coverage: 0.9,
        systematic_floor_adu: 0.5,
        systematic_floor_source: "Synthetic fixed 0.5 ADU calibration bound".into(),
    }
}

struct Noise(u64);
impl Noise {
    fn uniform(&mut self) -> f64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        ((self.0 >> 11) as f64 + 0.5) / ((1u64 << 53) as f64)
    }
    fn normal(&mut self) -> f64 {
        (-2.0 * self.uniform().ln()).sqrt() * (std::f64::consts::TAU * self.uniform()).cos()
    }
}

fn frame(i: usize, strength: f64, rng: &mut Noise) -> ApertureFrame {
    ApertureFrame {
        frame_id: format!("sensor-exposure-{i:08}"),
        acquired_at_ms: i as i64 + 1,
        source_path: format!("fixture-{i}.fits"),
        provenance_digest: "synthetic-matched-profile".into(),
        signal: (0..16)
            .map(|_| Some(100.0 + strength + 4.0 * rng.normal()))
            .collect(),
        background: (0..16).map(|_| Some(100.0 + 4.0 * rng.normal())).collect(),
    }
}

#[test]
fn repeated_looks_blank_and_bright_contaminants_never_complete() {
    let s = spec();
    let mut successes = 0;
    for trial in 1..=100 {
        let mut rng = Noise(trial);
        let mut frames = Vec::new();
        let mut candidate = None;
        for i in 0..160 {
            let mut f = frame(i, 0.0, &mut rng);
            if trial % 2 == 0 {
                f.signal[0] = Some(10000.0);
                f.signal[1] = Some(5000.0);
            }
            frames.push(f);
            let (report, next) = evaluate(&s, &frames, 0, candidate.as_ref());
            successes += usize::from(report.state == DepthState::Achieved);
            candidate = next;
        }
    }
    assert_eq!(
        successes, 0,
        "100 blank/contaminated trials, 160 repeated looks each"
    );
}

#[test]
fn independent_faint_signal_progresses_and_requires_future_confirmation() {
    let s = spec();
    let mut rng = Noise(941);
    let mut frames = Vec::new();
    let mut candidate: Option<Candidate> = None;
    let mut first_score = None;
    let mut last_score = None;
    let mut achieved = false;
    for i in 0..160 {
        frames.push(frame(i, 12.0, &mut rng));
        let (report, next) = evaluate(&s, &frames, 0, candidate.as_ref());
        if let Some(score) = report.score {
            first_score.get_or_insert(score);
            last_score = Some(score);
        }
        if report.state == DepthState::Achieved {
            assert!(candidate.is_some());
            assert!(report.confirmation_frames >= 16);
            assert!(report.conservative_score.unwrap() >= s.threshold);
            achieved = true;
            break;
        }
        candidate = next;
    }
    assert!(achieved);
    assert!(last_score.unwrap() > first_score.unwrap());
}

#[test]
fn discovery_duplicate_nonfinite_and_missing_coverage_are_not_success() {
    let s = spec();
    let mut rng = Noise(345);
    let mut frames: Vec<_> = (0..64).map(|i| frame(i, 50.0, &mut rng)).collect();
    assert_eq!(
        evaluate(&s, &frames, 100, None).0.state,
        DepthState::InsufficientEvidence
    );
    let original_id = frames[1].frame_id.clone();
    frames[1].frame_id = frames[0].frame_id.clone();
    assert_eq!(
        evaluate(&s, &frames, 0, None).0.state,
        DepthState::Unreliable
    );
    frames[1].frame_id = original_id;
    frames[0].signal[0] = Some(f64::NAN);
    assert_eq!(
        evaluate(&s, &frames, 0, None).0.state,
        DepthState::Unreliable
    );
    // One hit in one frame costs nothing: the cell keeps its other 63
    // measurements. The same two cells missing in more than a tenth of the
    // frames are invalid and take coverage below the goal's 90%.
    frames[0].signal[0] = None;
    frames[0].signal[1] = None;
    let (report, _) = evaluate(&s, &frames, 0, None);
    assert_ne!(report.state, DepthState::Unreliable, "{}", report.reason);
    assert_eq!(report.coverage, 1.0);
    for frame in frames.iter_mut().take(8) {
        frame.signal[0] = None;
        frame.signal[1] = None;
    }
    let (report, _) = evaluate(&s, &frames, 0, None);
    assert_eq!(report.state, DepthState::Unreliable);
    assert!(report.reason.contains("measurable"), "{}", report.reason);
}

/// A frame whose background is mostly unmeasurable (a trail or a hit
/// through the reference region) is set aside and counted, not pooled and
/// not fatal; a frame with a few missing background cells is still used.
#[test]
fn a_frame_with_an_unmeasurable_background_is_excluded_not_fatal() {
    let s = spec();
    let mut rng = Noise(777);
    let mut frames: Vec<_> = (0..40).map(|i| frame(i, 50.0, &mut rng)).collect();
    let (baseline, _) = evaluate(&s, &frames, 0, None);
    assert_ne!(
        baseline.state,
        DepthState::Unreliable,
        "{}",
        baseline.reason
    );
    assert_eq!(baseline.evidence_frames, 40);
    assert_eq!(baseline.excluded_frames, 0);

    for cell in 0..3 {
        frames[5].background[cell] = None;
    }
    let (tolerated, _) = evaluate(&s, &frames, 0, None);
    assert_eq!(tolerated.evidence_frames, 40, "{}", tolerated.reason);
    assert_eq!(tolerated.excluded_frames, 0);

    for cell in 0..8 {
        frames[5].background[cell] = None;
    }
    let (excluded, _) = evaluate(&s, &frames, 0, None);
    assert_ne!(
        excluded.state,
        DepthState::Unreliable,
        "{}",
        excluded.reason
    );
    assert_eq!(excluded.evidence_frames, 39);
    assert_eq!(excluded.excluded_frames, 1);
}

#[test]
fn gradients_and_shared_calibration_floor_do_not_average_away() {
    let mut s = spec();
    let mut rng = Noise(456);
    let mut frames: Vec<_> = (0..128).map(|i| frame(i, 12.0, &mut rng)).collect();
    for f in &mut frames {
        for (j, v) in f.background.iter_mut().enumerate() {
            *v = Some(v.unwrap() + (j % 4) as f64 * 10.0);
        }
    }
    assert_eq!(
        evaluate(&s, &frames, 0, None).0.state,
        DepthState::Unreliable
    );
    let frames: Vec<_> = (0..128).map(|i| frame(i, 12.0, &mut rng)).collect();
    s.systematic_floor_adu = 5.0;
    let report = evaluate(&s, &frames, 0, None).0;
    assert_ne!(report.state, DepthState::Achieved);
    assert!(report.score.unwrap() < 3.0);
}

#[test]
fn temporally_correlated_residuals_are_unreliable_at_repeated_looks() {
    let s = spec();
    let mut rng = Noise(582);
    let mut frames = Vec::new();
    let mut candidate = None;
    for i in 0..160 {
        let mut f = frame(i, 0.0, &mut rng);
        for v in &mut f.signal {
            *v = Some(112.0 + 10.0 * (i as f64 / 12.0).sin() + 0.1 * rng.normal());
        }
        frames.push(f);
        let (report, next) = evaluate(&s, &frames, 0, candidate.as_ref());
        assert_ne!(report.state, DepthState::Achieved);
        if i >= 31 {
            assert_eq!(report.state, DepthState::Unreliable);
            assert!(report.reason.contains("Temporal correlation"));
        }
        candidate = next;
    }
}

#[test]
fn out_of_order_evidence_does_not_change_measurement() {
    let s = spec();
    let mut rng = Noise(872);
    let mut frames: Vec<_> = (0..64).map(|i| frame(i, 12.0, &mut rng)).collect();
    let before = evaluate(&s, &frames, 0, None).0;
    frames.reverse();
    let after = evaluate(&s, &frames, 0, None).0;
    assert_eq!(before.score, after.score);
    assert_eq!(before.conservative_score, after.conservative_score);
    assert_eq!(before.state, after.state);
}

#[test]
fn later_blank_frames_do_not_confirm_a_selected_feature() {
    let s = spec();
    let mut rng = Noise(733);
    let mut frames = Vec::new();
    let mut candidate = None;
    for i in 0..128 {
        frames.push(frame(i, 30.0, &mut rng));
        let (report, next) = evaluate(&s, &frames, 0, candidate.as_ref());
        candidate = next;
        assert_ne!(report.state, DepthState::Achieved);
        if candidate.is_some() {
            break;
        }
    }
    assert!(candidate.is_some());
    let start = frames.len();
    for i in start..start + 16 {
        frames.push(frame(i, 0.0, &mut rng));
    }
    let (report, _) = evaluate(&s, &frames, 0, candidate.as_ref());
    assert_ne!(report.state, DepthState::Achieved);
}

#[test]
fn confirmation_roundtrip_replay_and_definition_changes_fail_closed() {
    let s = spec();
    let mut rng = Noise(733);
    let mut frames = Vec::new();
    let mut candidate = None;
    for i in 0..128 {
        frames.push(frame(i, 30.0, &mut rng));
        candidate = evaluate(&s, &frames, 0, None).1;
        if candidate.is_some() {
            break;
        }
    }
    let candidate: Candidate =
        serde_json::from_str(&serde_json::to_string(&candidate.unwrap()).unwrap()).unwrap();
    for _ in 0..20 {
        let (report, _) = evaluate(&s, &frames, 0, Some(&candidate));
        assert_eq!(report.state, DepthState::ConfirmationPending);
        assert_eq!(report.confirmation_frames, 0);
    }
    let mut changed = s.clone();
    changed.threshold = 3.0;
    assert_eq!(
        evaluate(&changed, &frames, 0, Some(&candidate)).0.state,
        DepthState::Unreliable
    );
    assert_eq!(
        evaluate(&s, &frames, -1, Some(&candidate)).0.state,
        DepthState::Unreliable
    );
    let mut missing = candidate.clone();
    missing.frame_ids.insert("missing-source".into());
    assert_eq!(
        evaluate(&s, &frames, 0, Some(&missing)).0.state,
        DepthState::Unreliable
    );
    frames[0].provenance_digest = "different-calibration".into();
    assert_eq!(
        evaluate(&s, &frames, 0, Some(&candidate)).0.state,
        DepthState::Unreliable
    );
}

#[test]
fn even_background_population_does_not_bias_blank_signal_positive() {
    let mut s = spec();
    s.systematic_floor_adu = 0.01;
    let mut rng = Noise(733);
    let frames: Vec<_> = (0..64)
        .map(|i| {
            let mut f = frame(i, 0.0, &mut rng);
            f.signal = vec![Some(100.0); 16];
            f.background = (0..16)
                .map(|j| {
                    let k = (i + j) % 16;
                    Some(
                        100.0
                            + if k < 8 {
                                k as f64 - 8.0
                            } else {
                                k as f64 - 7.0
                            },
                    )
                })
                .collect();
            f
        })
        .collect();
    let (report, _) = evaluate(&s, &frames, 0, None);
    assert_eq!(report.state, DepthState::Collecting);
    assert_eq!(report.score, Some(0.0));
}

#[test]
fn overflowing_score_is_unreliable_not_achieved() {
    let s = spec();
    let mut rng = Noise(733);
    let frames: Vec<_> = (0..64)
        .map(|i| {
            let mut f = frame(i, 0.0, &mut rng);
            f.signal = vec![Some(1.0e308); 16];
            f.background = vec![Some(100.0); 16];
            f
        })
        .collect();
    let (report, _) = evaluate(&s, &frames, 0, None);
    assert_eq!(report.state, DepthState::Unreliable);
    assert_eq!(report.score, None);
}

#[test]
fn malformed_calibration_dimensions_do_not_panic() {
    use skotiq_imaging::{depthlock::input::calibrate_signed, ImageData, PixelType};
    let image = ImageData {
        width: u32::MAX,
        height: u32::MAX,
        channels: 1,
        pixel_type: PixelType::U16,
        data: Vec::new(),
    };
    assert!(calibrate_signed(&image, &image, &image).is_err());
}

#[test]
fn masks_and_invalid_wcs_cannot_supply_aperture_measurements() {
    use skotiq_imaging::{depthlock::sample_apertures, SipWcs};
    let s = spec();
    let pixels = vec![12.0; 256 * 256];
    let masks = vec![true; pixels.len()];
    let wcs = SipWcs::tan_only(
        90.0,
        30.0,
        160.5,
        128.5,
        -1.0 / 3600.0,
        0.0,
        0.0,
        1.0 / 3600.0,
    );
    let (region, background) = sample_apertures(&s, &pixels, &masks, 256, 256, &wcs).unwrap();
    assert!(region.iter().chain(&background).all(Option::is_none));
    let mut bad = wcs.clone();
    bad.cd1_1 = 0.0;
    assert!(sample_apertures(&s, &pixels, &masks, 256, 256, &bad).is_err());
    bad = wcs.clone();
    bad.cd1_1 *= 2.0;
    assert!(sample_apertures(&s, &pixels, &masks, 256, 256, &bad).is_err());
    bad = wcs;
    bad.a_order = 2;
    assert!(sample_apertures(&s, &pixels, &masks, 256, 256, &bad).is_err());
}

#[test]
fn invalid_geometry_is_rejected() {
    let mut s = spec();
    s.region.width_arcsec = 0.0;
    assert!(s.validate().is_err());
    let mut s = spec();
    s.background = s.region.clone();
    assert!(s.validate().is_err());
    let mut s = spec();
    s.systematic_floor_adu = 0.0;
    assert!(s.validate().is_err());
}

#[test]
fn sky_apertures_follow_dither_flip_and_reframe() {
    use skotiq_imaging::{depthlock::sample_apertures, SipWcs};
    let s = spec();
    let width = 256;
    let height = 256;
    let wcs = SipWcs::tan_only(
        90.0,
        30.0,
        160.5,
        128.5,
        -1.0 / 3600.0,
        0.0,
        0.0,
        1.0 / 3600.0,
    );
    let render = |projection: &SipWcs| -> Vec<f64> {
        (0..width * height)
            .map(|i| {
                let (ra, dec) = projection.pixel_to_world((i % width) as f64, (i / width) as f64);
                let x = (ra - 90.0) * 3600.0 * 30.0f64.to_radians().cos();
                let y = (dec - 30.0) * 3600.0;
                100.0 + 12.0 * (-(x * x / 800.0 + y * y / 1800.0)).exp()
            })
            .collect()
    };
    let pixels = render(&wcs);
    let masks = vec![false; width * height];
    let (before, _) = sample_apertures(&s, &pixels, &masks, width, height, &wcs).unwrap();
    for transformed in [
        SipWcs::tan_only(
            90.0,
            30.0,
            165.5,
            124.5,
            -1.0 / 3600.0,
            0.0,
            0.0,
            1.0 / 3600.0,
        ),
        SipWcs::tan_only(
            90.0,
            30.0,
            96.5,
            128.5,
            1.0 / 3600.0,
            0.0,
            0.0,
            -1.0 / 3600.0,
        ),
        SipWcs::tan_only(
            90.003,
            30.002,
            150.5,
            130.5,
            -1.0 / 3600.0,
            0.0,
            0.0,
            1.0 / 3600.0,
        ),
    ] {
        let transformed_pixels = render(&transformed);
        let (after, _) =
            sample_apertures(&s, &transformed_pixels, &masks, width, height, &transformed).unwrap();
        for (a, b) in before.iter().zip(after) {
            assert!((a.unwrap() - b.unwrap()).abs() < 0.015);
        }
        let (wrong, _) =
            sample_apertures(&s, &pixels, &masks, width, height, &transformed).unwrap();
        assert!(before
            .iter()
            .zip(wrong)
            .any(|(a, b)| b.is_none() || (a.unwrap() - b.unwrap()).abs() > 0.1));
    }
}

#[test]
fn signed_calibration_preserves_negative_samples() {
    use skotiq_imaging::{depthlock::input::calibrate_signed, ImageData, PixelType};
    // 16x16 is the smallest frame the input layer accepts; the first four
    // pixels carry the values under test and the rest are flat sky.
    let image = |values: &[u16], fill: u16| ImageData {
        width: 16,
        height: 16,
        channels: 1,
        pixel_type: PixelType::U16,
        data: values
            .iter()
            .copied()
            .chain(std::iter::repeat(fill))
            .take(256)
            .flat_map(|v| v.to_le_bytes())
            .collect(),
    };
    let light = image(&[10, 30, 40, 50], 25);
    let dark = image(&[], 20);
    let flat = image(&[], 100);
    let calibrated = calibrate_signed(&light, &dark, &flat).unwrap();
    assert_eq!(&calibrated[..4], &[-10.0, 10.0, 20.0, 30.0]);
    assert!(calibrated[4..].iter().all(|v| *v == 5.0));
}

/// The forecast is the noise model run forward: a growing goal projects a
/// finite cost that shrinks as frames arrive, a floor-limited goal is
/// called unreachable with the ceiling it stops at, and the yield reflects
/// noisier recent frames.
#[test]
fn forecast_projects_cost_ceiling_and_yield() {
    use skotiq_imaging::depthlock::progress_curve;
    let s = spec();
    let mut rng = Noise(99);
    let frames: Vec<_> = (0..40).map(|i| frame(i, 50.0, &mut rng)).collect();
    let (early, _) = evaluate(&s, &frames[..32], 0, None);
    let early_forecast = early.forecast.clone().expect("a measurable goal forecasts");
    assert!(early_forecast.reachable, "{early_forecast:?}");
    assert!(early_forecast.ceiling_score > s.threshold);
    assert!(early_forecast.per_frame_noise_adu > 0.0);
    let (later, _) = evaluate(&s, &frames, 0, None);
    let later_forecast = later.forecast.clone().unwrap();
    assert!(
        later_forecast.frames_to_threshold <= early_forecast.frames_to_threshold,
        "more evidence cannot raise the remaining cost: {early_forecast:?} -> {later_forecast:?}"
    );
    assert!(
        (later_forecast.recent_frame_noise_adu - later_forecast.best_frame_noise_adu).abs()
            < 0.5 * later_forecast.best_frame_noise_adu,
        "uniform synthetic noise yields evenly: {later_forecast:?}"
    );

    // A calibration floor far above the signal: the quartile can never clear
    // the threshold, whatever the exposure count.
    let mut floored = s.clone();
    floored.systematic_floor_adu = 40.0;
    let (capped, _) = evaluate(&floored, &frames, 0, None);
    let capped_forecast = capped.forecast.clone().unwrap();
    assert!(!capped_forecast.reachable, "{capped_forecast:?}");
    assert!(capped_forecast.ceiling_score < floored.threshold);
    assert_eq!(capped_forecast.frames_to_threshold, 0);

    // The curve: measured points over the evidence, then a projection that
    // continues the trend without ever stepping backwards in frames.
    let curve = progress_curve(&s, &frames, 0, 8);
    let measured: Vec<_> = curve.iter().filter(|p| !p.projected).collect();
    let projected: Vec<_> = curve.iter().filter(|p| p.projected).collect();
    assert!(measured.first().unwrap().frames == 32);
    assert!(measured.last().unwrap().frames == 40);
    assert!(!projected.is_empty());
    assert!(projected.iter().all(|p| p.frames > 40));
    assert!(curve.windows(2).all(|w| w[0].frames < w[1].frames));
    assert!(projected.last().unwrap().conservative_score >= s.threshold - 1e-9);
    assert!(progress_curve(&s, &frames[..10], 0, 8).is_empty());
}
