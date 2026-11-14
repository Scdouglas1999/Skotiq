//! Wall-clock timings of the per-frame paths on a full-size sensor frame
//! (4656×3520, 16-bit): `cargo run --release -p skotiq_imaging --example frame_timing`.
//!
//! Each line is the best of five runs, in milliseconds.

use skotiq_imaging::stacking::{LiveStackConfig, LiveStacker};
use skotiq_imaging::*;
use std::time::Instant;

const W: u32 = 4656;
const H: u32 = 3520;

struct Lcg(u64);

impl Lcg {
    fn next_f64(&mut self) -> f64 {
        self.0 = self
            .0
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        ((self.0 >> 11) as f64) / ((1u64 << 53) as f64)
    }
}

fn star_field(seed: u64, dx: f64, dy: f64) -> ImageData {
    let (w, h) = (W as usize, H as usize);
    let mut rng = Lcg(seed);
    let mut px = vec![0f32; w * h];
    for v in px.iter_mut() {
        let n: f64 = (0..4).map(|_| rng.next_f64()).sum::<f64>() - 2.0;
        *v = (800.0 + n * 35.0) as f32;
    }
    let mut stars = Lcg(99);
    for _ in 0..1800 {
        let cx = stars.next_f64() * (w as f64 - 40.0) + 20.0 + dx;
        let cy = stars.next_f64() * (h as f64 - 40.0) + 20.0 + dy;
        let amp = 300.0 + 30000.0 * stars.next_f64().powi(4);
        let sigma = 1.6;
        for y in (cy as i64 - 9).max(0)..(cy as i64 + 10).min(h as i64) {
            for x in (cx as i64 - 9).max(0)..(cx as i64 + 10).min(w as i64) {
                let r2 = (x as f64 - cx).powi(2) + (y as f64 - cy).powi(2);
                px[y as usize * w + x as usize] +=
                    (amp * (-r2 / (2.0 * sigma * sigma)).exp()) as f32;
            }
        }
    }
    let px: Vec<u16> = px
        .iter()
        .map(|&v| v.round().clamp(0.0, 65535.0) as u16)
        .collect();
    ImageData::from_u16(W, H, 1, &px)
}

fn best_of<T>(runs: usize, mut f: impl FnMut() -> T) -> f64 {
    let mut best = f64::INFINITY;
    for _ in 0..runs {
        let t = Instant::now();
        std::hint::black_box(f());
        best = best.min(t.elapsed().as_secs_f64() * 1000.0);
    }
    best
}

fn main() {
    let frame = star_field(1, 0.0, 0.0);
    let shifted = star_field(2, 3.4, -2.2);
    let dark = {
        let mut rng = Lcg(5);
        let px: Vec<u16> = (0..(W * H) as usize)
            .map(|_| (500.0 + rng.next_f64() * 12.0) as u16)
            .collect();
        ImageData::from_u16(W, H, 1, &px)
    };
    let flat = {
        let px: Vec<u16> = (0..(W * H) as usize)
            .map(|i| 28000 + ((i % 4656) as u16) / 4)
            .collect();
        ImageData::from_u16(W, H, 1, &px)
    };
    let rgb = {
        let px = frame.as_u16().unwrap();
        let mut out = Vec::with_capacity(px.len() * 3);
        for v in px {
            out.extend_from_slice(&[v, (v as f32 * 0.9) as u16, (v as f32 * 0.7) as u16]);
        }
        ImageData::from_u16(W, H, 3, &out)
    };
    let dir = std::env::temp_dir().join(format!("skotiq-timing-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("frame.fits");
    write_fits(&path, &frame, &FitsHeader::new()).unwrap();

    let line = |name: &str, ms: f64| println!("{name:<44} {ms:>9.1} ms");
    let cfg = StarDetectionConfig::default();

    line("read_fits", best_of(5, || read_fits(&path).unwrap()));
    line(
        "write_fits",
        best_of(5, || write_fits(&path, &frame, &FitsHeader::new()).unwrap()),
    );
    line("detect_stars", best_of(5, || detect_stars(&frame, &cfg)));
    line(
        "detect_stars_with_stats",
        best_of(5, || detect_stars_with_stats(&frame, &cfg)),
    );
    line("calculate_stats", best_of(5, || calculate_stats(&frame)));
    line(
        "calculate_histogram(256)",
        best_of(5, || calculate_histogram(&frame, 256)),
    );
    line("auto_stretch_stf", best_of(5, || auto_stretch_stf(&frame)));
    line("to_display_u8 mono", best_of(5, || frame.to_display_u8()));
    line(
        "thumbnail 512",
        best_of(5, || skotiq_imaging::thumbnail(&frame, 1, 512)),
    );
    let unit: Vec<f32> = frame.samples_f32().iter().map(|v| v / 65535.0).collect();
    let unit = ImageData::from_f32(frame.width, frame.height, 1, &unit)
        .with_range(skotiq_imaging::SampleRange::UNIT);
    line("samples_f32 [0,1] float", best_of(5, || unit.samples_f32()));
    line(
        "detect_stars [0,1] float",
        best_of(5, || detect_stars(&unit, &cfg)),
    );
    line(
        "measure_frame_shape",
        best_of(5, || measure_frame_shape(&frame)),
    );
    line(
        "measure_frame_trail",
        best_of(5, || measure_frame_trail(&frame)),
    );
    line(
        "analyze_frame_quality",
        best_of(5, || {
            analyze_frame_quality(&frame, &FrameQualityConfig::default())
        }),
    );
    line(
        "calibrate_frame (dark+flat, u16)",
        best_of(5, || {
            calibrate_frame(&frame, Some(&dark), Some(&flat), None).unwrap()
        }),
    );
    line(
        "calibrate_frame_f32 (dark+flat)",
        best_of(5, || {
            calibrate_frame_f32(
                &frame,
                &FloatCalibration {
                    dark: Some(&dark),
                    flat: Some(&flat),
                    ..Default::default()
                },
            )
            .unwrap()
        }),
    );
    line("samples_f64", best_of(5, || frame.samples_f64()));
    line(
        "register_frame (similarity, lanczos3)",
        best_of(3, || {
            register_frame(&frame, &shifted, &RegistrationConfig::default()).unwrap()
        }),
    );
    line(
        "register_frame rgb",
        best_of(3, || {
            register_frame(&rgb, &rgb, &RegistrationConfig::default()).unwrap()
        }),
    );
    let turned = {
        let (s, c) = 0.3f64.to_radians().sin_cos();
        TransformModel {
            matrix: [[c, -s, 3.4], [s, c, -2.2], [0.0, 0.0, 1.0]],
            kind: TransformKind::Similarity,
        }
    };
    for (name, image, interp) in [
        ("warp_to_grid mono lanczos3", &frame, Interpolator::Lanczos3),
        ("warp_to_grid mono bilinear", &frame, Interpolator::Bilinear),
        ("warp_to_grid rgb lanczos3", &rgb, Interpolator::Lanczos3),
    ] {
        line(
            name,
            best_of(3, || warp_to_grid(image, W, H, &turned, interp)),
        );
    }
    let panel = |x0: usize, ra: f64| {
        let (pw, ph) = (1600usize, 1200usize);
        let src = frame.samples_f32();
        let px: Vec<f32> = (0..ph)
            .flat_map(|y| src[y * W as usize + x0..y * W as usize + x0 + pw].to_vec())
            .collect();
        MosaicPanel {
            image: ImageData::from_f32(pw as u32, ph as u32, 1, &px),
            wcs: skotiq_imaging::SipWcs::from_pointing(ra, 22.0, 0.0, 1.9, pw as u32, ph as u32)
                .cd_only(),
        }
    };
    let panels = vec![
        panel(0, 83.8),
        panel(
            1200,
            83.8 + 1200.0 * 1.9 / 3600.0 / 22f64.to_radians().cos(),
        ),
    ];
    line(
        "stitch_mosaic 2 x 1600x1200 lanczos3",
        best_of(3, || {
            stitch_mosaic(&panels, &MosaicStitchConfig::default()).unwrap()
        }),
    );
    let plane = frame.samples_f32();
    line(
        "gaussian_blur sigma 2",
        best_of(5, || {
            color_composite::mix::gaussian_blur(&plane, W as usize, H as usize, 2.0)
        }),
    );
    let mut stacker = LiveStacker::new(&frame, LiveStackConfig::default()).unwrap();
    line(
        "LiveStacker::add_frame mono",
        best_of(3, || stacker.add_frame(&shifted).unwrap()),
    );
    let mut rgb_stacker = LiveStacker::new(&rgb, LiveStackConfig::default()).unwrap();
    line(
        "LiveStacker::add_frame rgb",
        best_of(3, || rgb_stacker.add_frame(&rgb).unwrap()),
    );
    line(
        "extract_and_subtract (background)",
        best_of(3, || {
            extract_and_subtract(&frame, &BackgroundConfig::default()).unwrap()
        }),
    );
    let a = frame.samples_f64();
    let b = shifted.samples_f64();
    let mask = CoverageMask::full(W as usize, H as usize);
    line(
        "estimate_normalization",
        best_of(3, || {
            estimate_normalization(
                &b,
                &a,
                &mask,
                W as usize,
                H as usize,
                &NormalizationConfig::default(),
            )
        }),
    );
    let _ = std::fs::remove_dir_all(&dir);
}
