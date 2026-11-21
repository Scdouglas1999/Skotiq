//! The star detector against independent measurements on real frames.
//!
//! Fixtures and the numbers they are checked against live in
//! `test-fixtures/star-detect-2026-10-21/manifest.json`. The expected values
//! come from SEP (Source Extractor) and from a deep stack of twelve subs of
//! the same field, never from this crate.
//!
//! What must hold:
//! * on a focused frame, nearly every detection is a star the deep stack
//!   confirms, the count is at least what SEP finds, and the frame HFR agrees
//!   with SEP's half-flux radius;
//! * on defocused frames, each star is one detection (never fragments of a
//!   donut), every detection sits on a real star, the count falls and the HFR
//!   rises with defocus, and the HFR is the whole donut's;
//! * frames with no stars (a dark, a starless light, pure noise, shuffled
//!   pixels, smooth blobs) report none, and a trailed frame reports no round
//!   stars.

use serde_json::Value;
use skotiq_imaging::{
    detect_stars, detect_stars_with_stats, read_fits, DetectedStar, ImageData, StarDetectionConfig,
};
use std::path::{Path, PathBuf};

fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../test-fixtures/star-detect-2026-10-21")
}

fn manifest() -> Value {
    let text = std::fs::read_to_string(fixtures().join("manifest.json")).expect("manifest");
    serde_json::from_str(&text).expect("manifest parses")
}

fn independent(file: &str) -> Value {
    manifest()["frames"]
        .as_array()
        .expect("frames")
        .iter()
        .find(|f| f["file"] == file)
        .unwrap_or_else(|| panic!("{file} is not in the manifest"))["independent"]
        .clone()
}

fn load(file: &str) -> ImageData {
    read_fits(&fixtures().join(file))
        .unwrap_or_else(|e| panic!("{file}: {e}"))
        .0
}

fn deep_stack_sources() -> Vec<(f64, f64)> {
    std::fs::read_to_string(fixtures().join("focused_L_deep_stack_sources.csv"))
        .expect("deep stack sources")
        .lines()
        .skip(1)
        .map(|line| {
            let mut v = line.split(',').map(|s| s.trim().parse::<f64>().unwrap());
            (v.next().unwrap(), v.next().unwrap())
        })
        .collect()
}

fn nearest(sources: &[(f64, f64)], star: &DetectedStar) -> f64 {
    sources
        .iter()
        .map(|&(x, y)| (star.x - x).hypot(star.y - y))
        .fold(f64::INFINITY, f64::min)
}

fn config() -> StarDetectionConfig {
    StarDetectionConfig::default()
}

#[test]
fn a_focused_frame_finds_the_stars_a_deep_stack_confirms() {
    let image = load("focused_L.fits");
    let truth = independent("focused_L.fits");
    let deep = deep_stack_sources();

    let stars = detect_stars(&image, &config());
    let confirmed = stars.iter().filter(|s| nearest(&deep, s) <= 2.0).count();
    let sep_count = truth["sep_5sigma_count"].as_u64().unwrap() as usize;
    println!(
        "focused: {} detections, {confirmed} in the deep stack, SEP finds {sep_count}",
        stars.len()
    );
    assert!(
        stars.len() >= sep_count * 9 / 10,
        "{} detections where SEP finds {sep_count}",
        stars.len()
    );
    assert!(
        confirmed * 100 >= stars.len() * 90,
        "only {confirmed} of {} detections are stars the deep stack confirms",
        stars.len()
    );

    let result = detect_stars_with_stats(&image, &config());
    let sep_hfr = truth["sep_hfr_px"].as_f64().unwrap();
    println!(
        "focused: HFR {:.3} against SEP {sep_hfr:.3}",
        result.median_hfr
    );
    assert!(
        (result.median_hfr / sep_hfr - 1.0).abs() < 0.10,
        "HFR {:.3} against SEP {sep_hfr:.3}",
        result.median_hfr
    );
}

#[test]
fn a_defocused_star_is_one_detection_measured_whole() {
    let deep = deep_stack_sources();
    let focused_count = detect_stars(&load("focused_L.fits"), &config()).len();
    let mut previous = (focused_count, 0.0);

    for (file, radius) in [
        ("defocus_R06.fits", 6.0),
        ("defocus_R12.fits", 12.0),
        ("defocus_R20.fits", 20.0),
    ] {
        let image = load(file);
        let stars = detect_stars(&image, &config());
        let result = detect_stars_with_stats(&image, &config());
        let sep_hfr = independent(file)["sep_hfr_px"].as_f64().unwrap();
        println!(
            "{file}: {} detections, HFR {:.3} against SEP {sep_hfr:.3}",
            stars.len(),
            result.median_hfr
        );
        assert!(
            !stars.is_empty(),
            "{file}: a defocused field still has stars"
        );

        for s in &stars {
            let d = nearest(&deep, s);
            assert!(
                d <= radius + 3.0,
                "{file}: detection at ({:.1}, {:.1}) is {d:.1} px from any real star",
                s.x,
                s.y
            );
        }
        for (i, a) in stars.iter().enumerate() {
            for b in &stars[i + 1..] {
                let d = (a.x - b.x).hypot(a.y - b.y);
                assert!(
                    d >= radius,
                    "{file}: detections at ({:.1}, {:.1}) and ({:.1}, {:.1}) are {d:.1} px apart, inside one {radius} px donut",
                    a.x,
                    a.y,
                    b.x,
                    b.y
                );
            }
        }
        assert!(
            (result.median_hfr / sep_hfr - 1.0).abs() < 0.10,
            "{file}: HFR {:.3} against SEP {sep_hfr:.3}",
            result.median_hfr
        );
        assert!(
            stars.len() <= previous.0,
            "{file}: {} detections, more than the {} of the sharper frame",
            stars.len(),
            previous.0
        );
        assert!(
            result.median_hfr > previous.1,
            "{file}: HFR {:.3} does not grow with defocus (was {:.3})",
            result.median_hfr,
            previous.1
        );
        previous = (stars.len(), result.median_hfr);
    }
}

#[test]
fn frames_without_stars_report_none() {
    for file in ["dark_240s.fits", "no_stars_L.fits"] {
        let stars = detect_stars(&load(file), &config());
        assert!(
            stars.is_empty(),
            "{file}: {} stars on a frame without any: {:?}",
            stars.len(),
            stars
                .iter()
                .take(5)
                .map(|s| (s.x, s.y, s.hfr))
                .collect::<Vec<_>>()
        );
    }
}

#[test]
fn a_trailed_frame_reports_no_round_stars() {
    let result = detect_stars_with_stats(&load("trailed_R.fits"), &config());
    assert_eq!(
        result.star_count, 0,
        "a frame of trails has no star round enough to focus or guide on"
    );
}

/// Deterministic xorshift for the synthetic frames.
struct Rng(u64);

impl Rng {
    fn unit(&mut self) -> f64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        (self.0.wrapping_mul(0x2545_F491_4F6C_DD1D) >> 11) as f64 / (1u64 << 53) as f64
    }

    fn gauss(&mut self) -> f64 {
        let u1 = self.unit().max(1e-12);
        let u2 = self.unit();
        (-2.0 * u1.ln()).sqrt() * (std::f64::consts::TAU * u2).cos()
    }
}

#[test]
fn shuffled_pixels_of_a_real_frame_are_not_stars() {
    // Same pixel values, hot pixels and star cores included, with every
    // spatial structure destroyed.
    let image = load("focused_L.fits");
    let mut pixels: Vec<u16> = image.as_u16().expect("u16");
    let mut rng = Rng(0x5EED);
    for i in (1..pixels.len()).rev() {
        let j = (rng.unit() * (i + 1) as f64) as usize;
        pixels.swap(i, j.min(i));
    }
    let shuffled = ImageData::from_u16(image.width, image.height, 1, &pixels);
    let stars = detect_stars(&shuffled, &config());
    assert!(stars.is_empty(), "{} stars in shuffled pixels", stars.len());
}

#[test]
fn gaussian_noise_is_not_stars() {
    let (w, h) = (1024u32, 1024u32);
    let mut rng = Rng(0xA11CE);
    let pixels: Vec<u16> = (0..w * h)
        .map(|_| (1000.0 + 40.0 * rng.gauss()).round().clamp(0.0, 65535.0) as u16)
        .collect();
    let stars = detect_stars(&ImageData::from_u16(w, h, 1, &pixels), &config());
    assert!(stars.is_empty(), "{} stars in pure noise", stars.len());
}

#[test]
fn smooth_blobs_on_a_starless_frame_are_not_stars() {
    // Out-of-focus foreground (branches, leaves) or cloud lumps: bright,
    // smooth and large, with the soft Gaussian edge no defocused star has.
    // The blobs span 28-63 px FWHM: smaller ones are as compact as a badly
    // seeing-blurred focused star and cannot be told apart from one, and
    // blobs wider than the 64 px background mesh are partly taken into the
    // background instead.
    let (w, h) = (768usize, 768usize);
    let mut rng = Rng(0xB10B);
    let mut data: Vec<f64> = (0..w * h).map(|_| 1000.0 + 40.0 * rng.gauss()).collect();
    for k in 0..12 {
        let cx = 80.0 + (k % 4) as f64 * 200.0;
        let cy = 120.0 + (k / 4) as f64 * 250.0;
        let sigma = 12.0 + 1.25 * k as f64;
        let amp = 300.0 + 50.0 * k as f64;
        for (i, v) in data.iter_mut().enumerate() {
            let dx = (i % w) as f64 - cx;
            let dy = (i / w) as f64 - cy;
            *v += amp * (-(dx * dx + dy * dy) / (2.0 * sigma * sigma)).exp();
        }
    }
    let pixels: Vec<u16> = data.iter().map(|v| v.round() as u16).collect();
    let stars = detect_stars(
        &ImageData::from_u16(w as u32, h as u32, 1, &pixels),
        &config(),
    );
    assert!(
        stars.is_empty(),
        "{} blobs reported as stars: {:?}",
        stars.len(),
        stars.iter().map(|s| (s.x, s.y, s.hfr)).collect::<Vec<_>>()
    );
}

#[test]
fn quantized_narrowband_donuts_do_not_hallucinate_sky_noise() {
    // 12-bit left-shifted (16-ADU step) narrowband frame whose sky mean (324)
    // sits 4 ADU above the quantized median (320): a wide matched filter that
    // drops its level or underestimates correlated noise floods empty sky with
    // hundreds of false detections and drags HFR down.
    let (w, h) = (1024usize, 1024usize);
    let mut rng = Rng(0x1600_BEEF);
    let mut data: Vec<f64> = (0..w * h).map(|_| 324.0 + 30.0 * rng.gauss()).collect();

    let outer = 15.0f64;
    let inner = 0.5 * outer;
    let ring_area = std::f64::consts::PI * (outer * outer - inner * inner);
    let expected_hfr = (0.5 * (outer * outer + inner * inner)).sqrt();
    let mut truth = Vec::new();
    for row in 0..3 {
        for col in 0..4 {
            let cx = 140.0 + col as f64 * 240.0 + 0.3;
            let cy = 180.0 + row as f64 * 320.0 + 0.6;
            truth.push((cx, cy));
            let flux = 90_000.0 + (row * 4 + col) as f64 * 8_000.0;
            for y in (cy as i64 - 24)..=(cy as i64 + 24) {
                for x in (cx as i64 - 24)..=(cx as i64 + 24) {
                    let dx = x as f64 - cx;
                    let dy = y as f64 - cy;
                    let r = dx.hypot(dy);
                    if (inner..=outer).contains(&r) {
                        data[y as usize * w + x as usize] += flux / ring_area;
                    }
                }
            }
        }
    }
    let pixels: Vec<u16> = data
        .iter()
        .map(|v| ((v / 16.0).round() * 16.0).clamp(0.0, 65535.0) as u16)
        .collect();
    let image = ImageData::from_u16(w as u32, h as u32, 1, &pixels);
    let stars = detect_stars(&image, &config());
    let result = detect_stars_with_stats(&image, &config());

    assert!(
        (10..=14).contains(&stars.len()),
        "expected ~12 real donuts, got {} detections ({} usable)",
        stars.len(),
        result.star_count
    );
    for s in &stars {
        assert!(
            nearest(&truth, s) <= 4.0,
            "false sky detection at ({:.1}, {:.1}) hfr={:.2}",
            s.x,
            s.y,
            s.hfr
        );
    }
    assert!(
        (result.median_hfr / expected_hfr - 1.0).abs() < 0.12,
        "HFR {:.2} against expected {expected_hfr:.2}",
        result.median_hfr
    );
}

#[test]
fn dim_asymmetric_spider_donuts_measure_whole_not_as_knots() {
    // Low-SNR narrowband Newtonian donuts with 4 spider shadows, collimation
    // asymmetry and mild coma ellipticity: a narrow pass alone shatters each
    // ring into elongated arcs and tiny 2-3 px rim knots.
    let (w, h) = (1024usize, 1024usize);
    let mut rng = Rng(0xD040_7777);
    let mut data: Vec<f64> = (0..w * h).map(|_| 320.0 + 30.0 * rng.gauss()).collect();

    let outer = 14.0f64;
    let inner = 0.5 * outer;
    let ellip = 1.25f64;
    let mut truth = Vec::new();
    for row in 0..3 {
        for col in 0..4 {
            let cx = 140.0 + col as f64 * 240.0 + 0.4;
            let cy = 180.0 + row as f64 * 320.0 + 0.2;
            truth.push((cx, cy));
            let mut weights = Vec::new();
            let mut sum = 0.0;
            for y in (cy as i64 - 24)..=(cy as i64 + 24) {
                for x in (cx as i64 - 24)..=(cx as i64 + 24) {
                    let dx = x as f64 - cx;
                    let dy = y as f64 - cy;
                    let r = (dx / ellip).hypot(dy);
                    if (inner..=outer).contains(&r) {
                        let vane = if dx.abs() < 1.3 || dy.abs() < 1.3 {
                            0.15
                        } else {
                            1.0
                        };
                        let asym = (1.0 + 0.55 * (dx / (outer * ellip))).max(0.1);
                        let wt = vane * asym;
                        weights.push((y as usize * w + x as usize, wt));
                        sum += wt;
                    }
                }
            }
            // Dim: peak pixel in the ring sits near the 1.5-px detection edge,
            // so the narrow pass alone only catches rim arcs/knots.
            let flux = 13_000.0 + (row * 4 + col) as f64 * 800.0;
            for (idx, wt) in weights {
                data[idx] += flux * wt / sum;
            }
        }
    }
    let pixels: Vec<u16> = data
        .iter()
        .map(|v| ((v / 16.0).round() * 16.0).clamp(0.0, 65535.0) as u16)
        .collect();
    let image = ImageData::from_u16(w as u32, h as u32, 1, &pixels);
    let stars = detect_stars(&image, &config());

    assert!(
        stars.len() >= 8 && stars.len() <= 14,
        "expected 8..=14 whole donuts, got {}: {:?}",
        stars.len(),
        stars
            .iter()
            .map(|s| (
                s.x.round(),
                s.y.round(),
                (s.hfr * 10.0).round() / 10.0,
                (s.snr * 10.0).round() / 10.0
            ))
            .collect::<Vec<_>>()
    );
    for (i, a) in stars.iter().enumerate() {
        for b in &stars[i + 1..] {
            let d = (a.x - b.x).hypot(a.y - b.y);
            assert!(
                d >= outer,
                "donut shattered into detections {d:.1} px apart at ({:.1},{:.1}) and ({:.1},{:.1})",
                a.x,
                a.y,
                b.x,
                b.y
            );
        }
    }
    let mut hfrs: Vec<f64> = stars.iter().map(|s| s.hfr).collect();
    hfrs.sort_by(f64::total_cmp);
    let median_hfr = hfrs[hfrs.len() / 2];
    assert!(
        median_hfr > 9.5 && median_hfr < 14.5,
        "dim defocused donuts measured HFR {median_hfr:.2}, expected ~11-12 px"
    );
}
