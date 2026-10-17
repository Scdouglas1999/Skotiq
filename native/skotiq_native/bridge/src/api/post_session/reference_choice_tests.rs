use super::*;
use skotiq_imaging::{detect_stars, StarDetectionConfig};

/// Synthetic 256×256 mono frame: a noisy background plus Gaussian blobs
/// `(cx, cy, amplitude, sigma)`.
fn frame(stars: &[(f64, f64, f64, f64)], seed: u64) -> ImageData {
    let (w, h) = (256usize, 256usize);
    let mut px = vec![440u16; w * h];
    let mut st = seed | 1;
    for p in px.iter_mut() {
        st ^= st << 13;
        st ^= st >> 7;
        st ^= st << 17;
        *p = p.saturating_add((st % 41) as u16);
    }
    for &(cx, cy, amp, sigma) in stars {
        for y in 0..h {
            for x in 0..w {
                let dx = x as f64 - cx;
                let dy = y as f64 - cy;
                let r2 = dx * dx + dy * dy;
                if r2 > (6.0 * sigma) * (6.0 * sigma) {
                    continue;
                }
                let v = amp * (-r2 / (2.0 * sigma * sigma)).exp();
                let idx = y * w + x;
                px[idx] = (px[idx] as f64 + v).min(65535.0) as u16;
            }
        }
    }
    ImageData::from_u16(w as u32, h as u32, 1, &px)
}

/// A frame that WINS the SNR·sharpness·roundness composite while offering
/// only two centroids the registration detector can use — one short of the
/// three it needs. This is the shape of the reproduced defect: a candidate
/// whose brightest features are blown out scores superbly and registers
/// nothing.
fn unregistrable_but_top_scoring() -> ImageData {
    let mut blobs = vec![(60.0, 60.0, 12000.0, 2.6), (190.0, 70.0, 12000.0, 2.6)];
    for i in 0..12 {
        let x = 25.0 + ((i % 4) as f64) * 60.0;
        let y = 150.0 + ((i / 4) as f64) * 34.0;
        blobs.push((x, y, 90000.0, 6.0));
    }
    frame(&blobs, 12345)
}

/// An ordinary 24-star field: modest SNR, plenty of centroids.
fn ordinary_star_field(seed: u64) -> ImageData {
    let mut blobs = Vec::new();
    for i in 0..24 {
        let x = 20.0 + ((i % 6) as f64) * 40.0;
        let y = 20.0 + ((i / 6) as f64) * 55.0;
        blobs.push((x, y, 9000.0, 2.6));
    }
    frame(&blobs, seed)
}

fn light(path: &str, image: ImageData) -> LoadedLight {
    LoadedLight {
        path: path.to_string(),
        image,
        exposure_sec: 300.0,
        // Reference choice never consults the source header.
        header: std::collections::HashMap::new(),
    }
}

fn quality_score(image: &ImageData) -> f64 {
    let q = aligned_quality(image, &FrameQualityConfig::default()).unwrap();
    let round = q.eccentricity.map(|e| (1.0 - e).max(0.0)).unwrap_or(1.0);
    let sharp = if q.fwhm > 0.0 { 1.0 / q.fwhm } else { 0.0 };
    q.snr.max(0.0) * sharp * round
}

#[test]
fn the_trap_frame_really_does_out_score_a_usable_one() {
    // Guards the fixture itself: if this stops holding, the tests below
    // would pass for the wrong reason.
    let trap = unregistrable_but_top_scoring();
    let good = ordinary_star_field(999);
    let cfg = RegistrationConfig::default();

    assert!(
        quality_score(&trap) > quality_score(&good),
        "trap {} must out-score good {}",
        quality_score(&trap),
        quality_score(&good)
    );
    assert_eq!(
        detect_stars(&trap, &StarDetectionConfig::default()).len(),
        2
    );
    assert!(registrable_star_count(&trap, &cfg) < min_registration_stars(cfg.transform_kind));
    assert!(registrable_star_count(&good, &cfg) >= min_registration_stars(cfg.transform_kind));
}

#[test]
fn auto_skips_the_top_scoring_frame_when_it_cannot_be_registered_against() {
    let loaded = vec![
        light("/lights/trap.fits", unregistrable_but_top_scoring()),
        light("/lights/a.fits", ordinary_star_field(999)),
        light("/lights/b.fits", ordinary_star_field(4242)),
    ];
    let idx = choose_reference(
        &Some("auto".to_string()),
        &loaded,
        &FrameQualityConfig::default(),
        &RegistrationConfig::default(),
    )
    .expect("a usable reference exists");

    assert_ne!(
        idx, 0,
        "the highest-scoring sub yields only 2 centroids; choosing it fails \
         EVERY other sub against it and silently discards the night"
    );
    assert!(loaded[idx].path.starts_with("/lights/"));
    assert!(
        registrable_star_count(&loaded[idx].image, &RegistrationConfig::default())
            >= min_registration_stars(TransformKind::Similarity)
    );
}

#[test]
fn auto_reports_when_no_frame_can_serve_as_a_reference() {
    let loaded = vec![
        light("/lights/trap1.fits", unregistrable_but_top_scoring()),
        light("/lights/trap2.fits", unregistrable_but_top_scoring()),
    ];
    let err = choose_reference(
        &None,
        &loaded,
        &FrameQualityConfig::default(),
        &RegistrationConfig::default(),
    )
    .expect_err("nothing here can be a reference");

    assert!(
        err.contains("could not find a usable reference frame"),
        "unhelpful error: {err}"
    );
    assert!(
        err.contains("2 subs"),
        "error should say how many were tried: {err}"
    );
}

#[test]
fn an_explicit_unregistrable_reference_fails_loudly_instead_of_per_frame() {
    let loaded = vec![
        light("/lights/trap.fits", unregistrable_but_top_scoring()),
        light("/lights/a.fits", ordinary_star_field(999)),
    ];
    let err = choose_reference(
        &Some("/lights/trap.fits".to_string()),
        &loaded,
        &FrameQualityConfig::default(),
        &RegistrationConfig::default(),
    )
    .expect_err("an unusable explicit reference must be rejected up front");

    assert!(
        err.contains("only 2 detectable stars"),
        "unhelpful error: {err}"
    );
}

#[test]
fn an_explicit_usable_reference_is_still_honoured() {
    let loaded = vec![
        light("/lights/a.fits", ordinary_star_field(999)),
        light("/lights/b.fits", ordinary_star_field(4242)),
    ];
    let idx = choose_reference(
        &Some("/lights/b.fits".to_string()),
        &loaded,
        &FrameQualityConfig::default(),
        &RegistrationConfig::default(),
    )
    .unwrap();
    assert_eq!(idx, 1);
}

#[test]
fn a_starless_frame_whose_score_is_nan_never_wins() {
    // A perfectly flat background makes the noise estimate collapse, so the
    // composite becomes ∞ · 0 = NaN. `total_cmp` ranks a positive NaN above
    // +∞, which would hand the reference to the one frame with no stars at
    // all; it must rank last instead.
    let mut px = vec![440u16; 256 * 256];
    for y in 90..170 {
        for x in 90..170 {
            px[y * 256 + x] = 65535;
        }
    }
    let flat = ImageData::from_u16(256, 256, 1, &px);
    assert!(
        quality_score(&flat).is_nan(),
        "fixture must produce the NaN score, got {}",
        quality_score(&flat)
    );

    let loaded = vec![
        light("/lights/flat.fits", flat),
        light("/lights/a.fits", ordinary_star_field(999)),
    ];
    let idx = choose_reference(
        &None,
        &loaded,
        &FrameQualityConfig::default(),
        &RegistrationConfig::default(),
    )
    .unwrap();
    assert_eq!(idx, 1);
}
