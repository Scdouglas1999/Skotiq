//! Exact-output pins for the numerical paths of the crate.
//!
//! Each pin is a 64-bit digest of what a public entry point returns for a
//! fixed input: real rig frames from `test-fixtures/` and frames derived from
//! them. The digests live in `tests/pins/output_pins.txt`. A structural change
//! that is meant to leave results alone must leave every digest alone; a
//! change that moves one is a behavior change and has to be explained where
//! the pin file is edited.
//!
//! `SKOTIQ_UPDATE_PINS=1 cargo test --release -p skotiq_imaging --test output_pins`
//! rewrites the file from the current build.

use skotiq_imaging::stacking::{
    combine_master_frames, CombineMethod, LiveStackConfig, LiveStacker, MasterFrameKind,
    MasterOutputType,
};
use skotiq_imaging::*;
use std::collections::BTreeMap;
use std::fmt::Debug;
use std::path::{Path, PathBuf};
use std::sync::Arc;

fn fixtures(dir: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../test-fixtures")
        .join(dir)
}

fn load(dir: &str, file: &str) -> ImageData {
    read_fits(&fixtures(dir).join(file))
        .unwrap_or_else(|e| panic!("{file}: {e}"))
        .0
}

fn fnv(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for &b in bytes {
        h ^= b as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    h
}

fn image_digest(image: &ImageData) -> u64 {
    let mut bytes = format!(
        "{}x{}x{}:{:?}:",
        image.width, image.height, image.channels, image.pixel_type
    )
    .into_bytes();
    bytes.extend_from_slice(&image.data);
    fnv(&bytes)
}

fn debug_digest<T: Debug>(value: &T) -> u64 {
    fnv(format!("{value:?}").as_bytes())
}

fn f64_digest(values: &[f64]) -> u64 {
    let bytes: Vec<u8> = values.iter().flat_map(|v| v.to_le_bytes()).collect();
    fnv(&bytes)
}

fn f32_digest(values: &[f32]) -> u64 {
    let bytes: Vec<u8> = values.iter().flat_map(|v| v.to_le_bytes()).collect();
    fnv(&bytes)
}

/// A float to ten significant digits, for values summed in parallel whose
/// last bits depend on how the work was split.
fn rounded(value: f64) -> String {
    format!("{value:.9e}")
}

/// Header cards in key order: the header keeps them in a hash map.
fn header_digest(header: &FitsHeader) -> u64 {
    let mut cards: Vec<String> = header
        .keywords
        .iter()
        .map(|(key, value)| format!("{key}={value:?}/{:?}", header.get_comment(key)))
        .collect();
    cards.sort();
    debug_digest(&(cards, &header.comments, &header.history))
}

struct Lcg(u64);

impl Lcg {
    fn next_f64(&mut self) -> f64 {
        self.0 = self
            .0
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        ((self.0 >> 11) as f64) / ((1u64 << 53) as f64)
    }

    /// Roughly normal, from the sum of four uniforms.
    fn gauss(&mut self) -> f64 {
        let s: f64 = (0..4).map(|_| self.next_f64()).sum();
        (s - 2.0) * 1.732
    }
}

/// A centre crop of a mono U16 frame.
fn crop(image: &ImageData, size: u32) -> ImageData {
    let px = image.as_u16().expect("u16 frame");
    let x0 = (image.width - size) / 2;
    let y0 = (image.height - size) / 2;
    let mut out = Vec::with_capacity((size * size) as usize);
    for y in 0..size {
        let row = ((y0 + y) * image.width + x0) as usize;
        out.extend_from_slice(&px[row..row + size as usize]);
    }
    ImageData::from_u16(size, size, 1, &out)
}

/// The frame with deterministic noise added and a gain/offset applied: a
/// stand-in for another sub of the same field.
fn perturbed(image: &ImageData, seed: u64, gain: f64, offset: f64, noise: f64) -> ImageData {
    let mut rng = Lcg(seed);
    let px: Vec<u16> = image
        .as_u16()
        .expect("u16 frame")
        .iter()
        .map(|&v| {
            (v as f64 * gain + offset + rng.gauss() * noise)
                .round()
                .clamp(0.0, 65535.0) as u16
        })
        .collect();
    ImageData::from_u16(image.width, image.height, image.channels, &px)
}

/// Interleaved RGB built from one mono frame with per-channel gains.
fn as_rgb(image: &ImageData, gains: [f64; 3]) -> ImageData {
    let px = image.as_u16().expect("u16 frame");
    let mut out = Vec::with_capacity(px.len() * 3);
    for &v in &px {
        for g in gains {
            out.push((v as f64 * g).round().clamp(0.0, 65535.0) as u16);
        }
    }
    ImageData::from_u16(image.width, image.height, 3, &out)
}

fn to_f32_unit(image: &ImageData) -> ImageData {
    let px: Vec<f32> = image
        .as_u16()
        .expect("u16 frame")
        .iter()
        .map(|&v| v as f32 / 65535.0)
        .collect();
    ImageData::from_f32(image.width, image.height, image.channels, &px)
}

fn synthetic_flat(width: u32, height: u32, seed: u64, level: f64) -> ImageData {
    let mut rng = Lcg(seed);
    let (cx, cy) = (width as f64 / 2.0, height as f64 / 2.0);
    let rmax = (cx * cx + cy * cy).sqrt();
    let mut px = Vec::with_capacity((width * height) as usize);
    for y in 0..height {
        for x in 0..width {
            let r = ((x as f64 - cx).powi(2) + (y as f64 - cy).powi(2)).sqrt() / rmax;
            let v = level * (1.0 - 0.3 * r * r) + rng.gauss() * level.sqrt();
            px.push(v.round().clamp(0.0, 65535.0) as u16);
        }
    }
    ImageData::from_u16(width, height, 1, &px)
}

fn synthetic_dark(width: u32, height: u32, seed: u64, level: f64) -> ImageData {
    let mut rng = Lcg(seed);
    let px: Vec<u16> = (0..(width * height) as usize)
        .map(|i| {
            let hot = if i % 4099 == 17 { 9000.0 } else { 0.0 };
            (level + hot + rng.gauss() * 6.0).round().clamp(0.0, 65535.0) as u16
        })
        .collect();
    ImageData::from_u16(width, height, 1, &px)
}

struct Pins(BTreeMap<String, u64>);

impl Pins {
    fn add(&mut self, name: &str, digest: u64) {
        assert!(
            self.0.insert(name.to_string(), digest).is_none(),
            "duplicate pin {name}"
        );
    }
}

const RIG: &str = "rig-2026-09-14";
const STAR: &str = "star-detect-2026-10-21";

fn pin_fixture_measurements(pins: &mut Pins) {
    let frames: &[(&str, &str)] = &[
        (RIG, "focused_L_0005.fits"),
        (RIG, "focused_L_0006.fits"),
        (RIG, "landed_from_above_L_0003.fits"),
        (RIG, "trailed_Ha_0001_001.fits"),
        (RIG, "trailed_OIII_0001.fits"),
        (RIG, "trailed_SII_0001_001.fits"),
        (STAR, "dark_240s.fits"),
        (STAR, "defocus_R06.fits"),
        (STAR, "defocus_R12.fits"),
        (STAR, "defocus_R20.fits"),
        (STAR, "focused_L.fits"),
        (STAR, "no_stars_L.fits"),
        (STAR, "trailed_R.fits"),
        (STAR, "trailed_round_G.fits"),
    ];
    for (dir, file) in frames {
        let (image, header) = read_fits(&fixtures(dir).join(file)).expect("fixture reads");
        let p = |what: &str| format!("{file}/{what}");
        pins.add(&p("read_fits.pixels"), image_digest(&image));
        pins.add(&p("read_fits.header"), header_digest(&header));
        pins.add(
            &p("detect_stars"),
            debug_digest(&detect_stars(&image, &StarDetectionConfig::default())),
        );
        pins.add(
            &p("detect_stars_for_selection"),
            debug_digest(&detect_stars_for_selection(
                &image,
                &StarDetectionConfig::default(),
            )),
        );
        pins.add(
            &p("detect_stars_with_stats"),
            debug_digest(&detect_stars_with_stats(
                &image,
                &StarDetectionConfig::default(),
            )),
        );
        let stats = calculate_stats_u16(&image);
        pins.add(
            &p("stats"),
            debug_digest(&(
                stats.min,
                stats.max,
                rounded(stats.mean),
                stats.median,
                rounded(stats.std_dev),
                stats.mad,
            )),
        );
        pins.add(&p("median_hfr"), debug_digest(&calculate_median_hfr(&image)));
        pins.add(&p("histogram"), debug_digest(&calculate_histogram(&image, 256)));
        pins.add(
            &p("display_histogram"),
            debug_digest(&calculate_display_histogram(&image, true)),
        );
        pins.add(&p("frame_shape"), debug_digest(&measure_frame_shape(&image)));
        pins.add(&p("frame_trail"), debug_digest(&measure_frame_trail(&image)));
        pins.add(
            &p("frame_quality"),
            debug_digest(&analyze_frame_quality(&image, &FrameQualityConfig::default())),
        );
        pins.add(&p("stf"), debug_digest(&auto_stretch_stf(&image)));
        pins.add(&p("display_u8"), fnv(&image.to_display_u8()));
        pins.add(
            &p("rgba"),
            fnv(&image.to_rgba().expect("mono frame displays")),
        );
        pins.add(
            &p("registrable_star_count"),
            registrable_star_count(&image, &RegistrationConfig::default()) as u64,
        );
        pins.add(
            &p("star_crops"),
            debug_digest(&extract_top_star_crops(
                &image,
                &detect_stars(&image, &StarDetectionConfig::default()),
                5,
                32,
            )),
        );
    }
}

fn pin_display(pins: &mut Pins) {
    let mono = crop(&load(RIG, "focused_L_0005.fits"), 512);
    let rgb = as_rgb(&mono, [0.8, 1.0, 0.65]);
    pins.add("display/rgb.display_u8", fnv(&rgb.to_display_u8()));
    pins.add("display/rgb.rgba", fnv(&rgb.to_rgba().expect("rgb displays")));
    let rgb16 = rgb.as_u16().expect("u16");
    for (name, mode) in [
        ("linked", RgbStretchMode::Linked),
        ("unlinked", RgbStretchMode::Unlinked),
    ] {
        pins.add(
            &format!("display/rgb.auto_stretch.{name}"),
            debug_digest(&auto_stretch_rgb_with_mode(&rgb16, 512, 512, mode)),
        );
    }
    let f32_image = to_f32_unit(&mono);
    pins.add("display/f32.display_u8", fnv(&f32_image.to_display_u8()));
    pins.add("display/f32.stf", debug_digest(&auto_stretch_stf(&f32_image)));
}

fn pin_registration(pins: &mut Pins) {
    let reference = load(RIG, "focused_L_0005.fits");
    let frame = load(RIG, "focused_L_0006.fits");
    for (name, kind, interp) in [
        ("similarity.lanczos", TransformKind::Similarity, Interpolator::Lanczos3),
        ("affine.catmull", TransformKind::Affine, Interpolator::CatmullRom),
        ("homography.bilinear", TransformKind::Homography, Interpolator::Bilinear),
    ] {
        let cfg = RegistrationConfig {
            transform_kind: kind,
            interpolator: interp,
            ..RegistrationConfig::default()
        };
        match register_frame(&reference, &frame, &cfg) {
            Ok(r) => {
                pins.add(
                    &format!("registration/{name}.transform"),
                    debug_digest(&(r.transform, &r.stats)),
                );
                pins.add(
                    &format!("registration/{name}.aligned"),
                    image_digest(&r.aligned),
                );
                let warped = warp_to_grid(&frame, frame.width, frame.height, &r.transform, interp);
                pins.add(
                    &format!("registration/{name}.warp_to_grid"),
                    f32_digest(&warped.pixels) ^ debug_digest(&warped.covered),
                );
            }
            Err(e) => pins.add(&format!("registration/{name}.error"), debug_digest(&e)),
        }
    }

    let rgb_ref = as_rgb(&reference, [0.8, 1.0, 0.65]);
    let rgb_frame = as_rgb(&frame, [0.8, 1.0, 0.65]);
    match register_frame(&rgb_ref, &rgb_frame, &RegistrationConfig::default()) {
        Ok(r) => {
            pins.add(
                "registration/rgb.transform",
                debug_digest(&(r.transform, &r.stats)),
            );
            pins.add("registration/rgb.aligned", image_digest(&r.aligned));
        }
        Err(e) => pins.add("registration/rgb.error", debug_digest(&e)),
    }
}

fn pin_live_stack(pins: &mut Pins) {
    let reference = load(RIG, "focused_L_0005.fits");
    let second = load(RIG, "focused_L_0006.fits");
    let third = load(RIG, "landed_from_above_L_0003.fits");

    let mut stacker = LiveStacker::new(&reference, LiveStackConfig::default()).expect("stacker");
    for (i, frame) in [&second, &third, &perturbed(&second, 7, 1.0, 12.0, 9.0)]
        .into_iter()
        .enumerate()
    {
        let outcome = stacker.add_frame(frame);
        pins.add(
            &format!("live_stack/mono.add{i}"),
            match &outcome {
                Ok(image) => image_digest(image),
                Err(e) => fnv(e.as_bytes()),
            },
        );
    }
    pins.add("live_stack/mono.stats", debug_digest(&stacker.get_stats()));
    pins.add(
        "live_stack/mono.stack",
        image_digest(&stacker.get_current_stack()),
    );

    let gains = [0.8, 1.0, 0.65];
    let mut rgb = LiveStacker::new(&as_rgb(&reference, gains), LiveStackConfig::default())
        .expect("rgb stacker");
    for (i, frame) in [&second, &third].into_iter().enumerate() {
        let outcome = rgb.add_frame(&as_rgb(frame, gains));
        pins.add(
            &format!("live_stack/rgb.add{i}"),
            match &outcome {
                Ok(image) => image_digest(image),
                Err(e) => fnv(e.as_bytes()),
            },
        );
    }
    pins.add("live_stack/rgb.stats", debug_digest(&rgb.get_stats()));
    pins.add("live_stack/rgb.stack", image_digest(&rgb.get_current_stack()));
}

fn pin_calibration(pins: &mut Pins) {
    let light = crop(&load(RIG, "focused_L_0005.fits"), 512);
    let dark = synthetic_dark(512, 512, 11, 510.0);
    let bias = synthetic_dark(512, 512, 12, 500.0);
    let flat = synthetic_flat(512, 512, 13, 30000.0);

    let calibrated =
        calibrate_frame(&light, Some(&dark), Some(&flat), Some(&bias)).expect("calibrates");
    pins.add("calibration/u16.dark_flat_bias", image_digest(&calibrated));
    pins.add(
        "calibration/u16.dark_only",
        image_digest(&calibrate_frame(&light, Some(&dark), None, None).expect("calibrates")),
    );
    pins.add(
        "calibration/u16.divide_flat",
        image_digest(&divide_flat(&light, &flat).expect("divides")),
    );
    let float_cal = FloatCalibration {
        bias: Some(&bias),
        dark: Some(&dark),
        dark_scale: 1.5,
        flat: Some(&flat),
        flat_pedestal: FlatPedestal::Included,
        output_pedestal: 100.0,
    };
    pins.add(
        "calibration/f32.full",
        image_digest(&calibrate_frame_f32(&light, &float_cal).expect("calibrates")),
    );
    pins.add(
        "calibration/samples_f64",
        f64_digest(&calibrated.samples_f64()),
    );

    let flats: Vec<ImageData> = (0..7)
        .map(|i| synthetic_flat(256, 256, 100 + i, 28000.0 + 400.0 * i as f64))
        .collect();
    let flat_bias = synthetic_dark(256, 256, 14, 500.0);
    for (name, cfg) in [
        ("default", MasterFlatConfig::default()),
        (
            "median_u16",
            MasterFlatConfig {
                method: CombineMethod::Median,
                output_type: MasterOutputType::U16,
            },
        ),
    ] {
        let master = build_master_flat(&flats, Some(&flat_bias), cfg).expect("master flat");
        pins.add(
            &format!("calibration/master_flat.{name}"),
            image_digest(&master.image)
                ^ debug_digest(&(
                    master.frame_count,
                    rounded(master.input_mean),
                    rounded(master.output_mean),
                )),
        );
    }
    pins.add(
        "calibration/normalize_raw_flat",
        match normalize_raw_flat(&flats[0], Some(&flat_bias)) {
            Ok((image, level)) => image_digest(&image) ^ debug_digest(&level),
            Err(e) => debug_digest(&e),
        },
    );

    let darks: Vec<ImageData> = (0..9)
        .map(|i| synthetic_dark(256, 256, 200 + i, 510.0))
        .collect();
    for (name, kind, method, out) in [
        ("dark.mean.u16", MasterFrameKind::Dark, CombineMethod::Mean, MasterOutputType::U16),
        ("dark.median.f32", MasterFrameKind::Dark, CombineMethod::Median, MasterOutputType::F32),
        (
            "bias.sigma.f32",
            MasterFrameKind::Bias,
            CombineMethod::SigmaClip {
                kappa: 3.0,
                iterations: 5,
            },
            MasterOutputType::F32,
        ),
        (
            "flat.sigma.u16",
            MasterFrameKind::Flat,
            CombineMethod::SigmaClip {
                kappa: 2.5,
                iterations: 3,
            },
            MasterOutputType::U16,
        ),
    ] {
        let source = if kind == MasterFrameKind::Flat { &flats } else { &darks };
        let master = combine_master_frames(source, kind, method, out).expect("combines");
        pins.add(
            &format!("calibration/combine.{name}"),
            image_digest(&master.image)
                ^ debug_digest(&(rounded(master.input_mean), rounded(master.output_mean))),
        );
    }

    let mut cosmetic = perturbed(&light, 5, 1.0, 0.0, 0.0);
    let report =
        cosmetic_correct_transient(&mut cosmetic, CosmeticConfig::default()).expect("cosmetic");
    pins.add(
        "calibration/cosmetic.u16",
        image_digest(&cosmetic) ^ debug_digest(&report),
    );
    pins.add(
        "calibration/defect_map_from_dark",
        debug_digest(&build_defect_map_from_master_dark(&dark, -100).map(|m| m.defective_count())),
    );
}

fn pin_streamed_master(pins: &mut Pins) {
    let dir = std::env::temp_dir().join(format!("skotiq-pins-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("scratch dir");
    let mut paths = Vec::new();
    for i in 0..8u64 {
        let frame = synthetic_dark(300, 200, 300 + i, 512.0);
        let mut header = FitsHeader::new();
        header.set_float("EXPTIME", 120.0);
        header.set_int("GAIN", 100);
        header.set_int("OFFSET", 50);
        header.set_int("XBINNING", 1);
        header.set_int("YBINNING", 1);
        header.set_float("CCD-TEMP", -10.0 + 0.01 * i as f64);
        header.set_float("SET-TEMP", -10.0);
        let path = dir.join(format!("dark_{i}.fits"));
        write_fits(&path, &frame, &header).expect("writes");
        paths.push(path);
    }
    let output = dir.join("master_dark.fits");
    let result = calibration_master_stream::build_streamed_master(
        &paths,
        &output,
        &calibration_master_stream::StreamedMasterConfig::new(
            calibration_master_stream::StreamedMasterKind::Dark,
        ),
    )
    .expect("streamed master");
    let (image, header) = read_fits(&output).expect("master reads");
    pins.add("streamed_master/pixels", image_digest(&image));
    pins.add(
        "streamed_master/result",
        debug_digest(&(
            result.frame_count,
            result.frame_levels.iter().map(|l| (l.level, l.noise)).collect::<Vec<_>>(),
            &result.leak,
            result.master_mean,
            result.rejection_fraction,
            result.ccd_temp_mean,
        )),
    );
    pins.add(
        "streamed_master/header.cards",
        debug_digest(&(
            header.get_float("EXPTIME"),
            header.get_int("GAIN"),
            header.get_int("NCOMBINE"),
            header.get_string("IMAGETYP").map(str::to_owned),
        )),
    );
    let _ = std::fs::remove_dir_all(&dir);
}

fn stack_of_subs(base: &ImageData, count: u64) -> Vec<Vec<f64>> {
    (0..count)
        .map(|i| {
            let sub = perturbed(
                base,
                900 + i,
                1.0 + 0.03 * i as f64,
                20.0 * i as f64,
                14.0 + i as f64,
            );
            let mut px = sub.samples_f64();
            if i == 3 {
                // A satellite trail on one sub.
                let w = base.width as usize;
                for x in 0..w {
                    px[(w / 3) * w + x] += 4000.0;
                }
            }
            px
        })
        .collect()
}

fn pin_normalization_and_integration(pins: &mut Pins) {
    let base = crop(&load(RIG, "focused_L_0005.fits"), 384);
    let (w, h) = (384usize, 384usize);
    let subs = stack_of_subs(&base, 9);
    let mask = CoverageMask::full(w, h);

    for mode in [NormMode::Global, NormMode::Local { rows: 4, cols: 4 }] {
        for estimator in [
            NormEstimator::AdditiveWithScaling,
            NormEstimator::CoLocatedPairFit,
        ] {
            let cfg = NormalizationConfig {
                mode,
                estimator,
                ..NormalizationConfig::default()
            };
            let name = format!("normalization/{mode:?}.{estimator:?}");
            let coeffs = estimate_normalization(&subs[5], &subs[0], &mask, w, h, &cfg);
            pins.add(&format!("{name}.coeffs"), debug_digest(&coeffs));
            if let Ok(coeffs) = coeffs {
                let mut frame = subs[5].clone();
                apply_normalization(&mut frame, &coeffs, w, h);
                pins.add(&format!("{name}.applied"), f64_digest(&frame));
            }
        }
    }

    let frames: Vec<IntegrationFrame<'_>> = subs
        .iter()
        .enumerate()
        .map(|(i, px)| IntegrationFrame {
            pixels: px,
            weight: 1.0 + 0.1 * i as f64,
            coverage: None,
        })
        .collect();
    let rejections: Vec<(&str, Reject)> = vec![
        ("none", Reject::None),
        ("sigma", Reject::SigmaClip { low: 3.0, high: 3.0 }),
        ("winsor", Reject::WinsorizedSigmaClip { low: 3.0, high: 3.0 }),
        ("linear_fit", Reject::LinearFitClip { low: 5.0, high: 2.5 }),
        ("percentile", Reject::PercentileClip { low: 0.2, high: 0.1 }),
        ("minmax", Reject::MinMax { n_low: 1, n_high: 1 }),
        (
            "esd",
            Reject::GeneralizedEsd {
                outliers: 0.3,
                alpha: 0.05,
                low_relaxation: 1.5,
            },
        ),
        ("auto", Reject::pixinsight_auto(frames.len())),
    ];
    for (name, reject) in rejections {
        for combine in [Combine::Mean, Combine::Median] {
            let cfg = IntegrationConfig {
                combine,
                reject,
                ..IntegrationConfig::default()
            };
            let name = format!("integration/{name}.{combine:?}");
            match integrate_frames(&frames, w as u32, h as u32, 1, &cfg) {
                Ok(out) => {
                    pins.add(&format!("{name}.master"), image_digest(&out.master));
                    pins.add(&format!("{name}.stats"), debug_digest(&out.stats));
                    pins.add(
                        &format!("{name}.maps"),
                        out.rejection_map.as_ref().map(image_digest).unwrap_or(0)
                            ^ out.weight_map.as_ref().map(image_digest).unwrap_or(1),
                    );
                }
                Err(e) => pins.add(&format!("{name}.error"), debug_digest(&e)),
            }
        }
    }

    let reference = perturbed(&base, 900, 1.0, 0.0, 14.0);
    for (name, mode) in [
        ("clip", AccumulationMode::default()),
        ("noclip", AccumulationMode::RunningWeightedMean { clip: None }),
    ] {
        let mut master = IntegratedMaster::create(
            &reference,
            &MasterCreateConfig {
                mode,
                filter: Some("L".into()),
                target: Some("pin".into()),
            },
        )
        .expect("master");
        let exposures = vec![120.0; frames.len()];
        for night in 0..2 {
            let report = master
                .add_frames(&frames, &exposures, &format!("night{night}"))
                .expect("adds");
            pins.add(
                &format!("accumulating_master/{name}.report{night}"),
                debug_digest(&report),
            );
        }
        pins.add(
            &format!("accumulating_master/{name}.final"),
            image_digest(&master.finalize()),
        );
        pins.add(
            &format!("accumulating_master/{name}.maps"),
            image_digest(&master.coverage_map()) ^ image_digest(&master.rejection_map()),
        );
        pins.add(
            &format!("accumulating_master/{name}.sidecar"),
            fnv(&master.serialize()),
        );
    }

    let identity = TransformModel::identity();
    let drizzle_frames: Vec<DrizzleFrame<'_>> = subs
        .iter()
        .take(4)
        .map(|px| DrizzleFrame {
            pixels: px,
            width: w as u32,
            height: h as u32,
            channels: 1,
            transform: &identity,
            weight: 1.0,
        })
        .collect();
    match drizzle_integrate(&drizzle_frames, w as u32, h as u32, &DrizzleConfig::default()) {
        Ok(out) => pins.add(
            "drizzle/default",
            image_digest(&out.master) ^ image_digest(&out.coverage),
        ),
        Err(e) => pins.add("drizzle/default.error", debug_digest(&e)),
    }
}

fn pin_atlas_and_difference(pins: &mut Pins) {
    let frame = load(RIG, "focused_L_0005.fits");
    let scale = 1.9 / 3600.0;
    let (ra, dec) = (83.8, 22.0);
    let wcs = SipWcs::tan_only(
        ra,
        dec,
        (frame.width as f64 + 1.0) / 2.0,
        (frame.height as f64 + 1.0) / 2.0,
        -scale,
        0.0,
        0.0,
        scale,
    );
    let order = ATLAS_HEALPIX_ORDER;
    let tile_id = radec_to_tile(ra, dec, order);
    pins.add("atlas/tile_id", tile_id);
    pins.add(
        "atlas/tiles_for_frame",
        debug_digest(&tile_ids_for_frame(&wcs, frame.width, frame.height, order)),
    );
    let mut tile = SkyTileAccumulator::create(tile_id, order, 1, AccumulationMode::default());
    for i in 0..6u64 {
        let sub = perturbed(&frame, 40 + i, 1.0 + 0.02 * i as f64, 15.0 * i as f64, 10.0);
        let record = tile.fold_frame(
            &sub,
            &wcs,
            1.0,
            120.0,
            Interpolator::Lanczos3,
            &format!("sub{i}"),
            "pin",
        );
        pins.add(&format!("atlas/fold{i}"), debug_digest(&record));
    }
    pins.add("atlas/final", image_digest(&tile.finalize()));
    pins.add(
        "atlas/maps",
        image_digest(&tile.coverage_map()) ^ image_digest(&tile.rejection_map()),
    );
    pins.add("atlas/norm_reference", debug_digest(tile.norm_reference()));
    pins.add("atlas/sidecar", fnv(&tile.serialize()));

    let mut science = perturbed(&frame, 77, 1.04, 30.0, 10.0);
    {
        // A new point source in the science frame.
        let w = science.width as usize;
        let mut px = science.as_u16().expect("u16");
        let (cx, cy) = (w / 2 + 37, science.height as usize / 2 - 21);
        for dy in -6i32..=6 {
            for dx in -6i32..=6 {
                let r2 = (dx * dx + dy * dy) as f64;
                let add = 6000.0 * (-r2 / (2.0 * 1.6 * 1.6)).exp();
                let i = (cy as i32 + dy) as usize * w + (cx as i32 + dx) as usize;
                px[i] = (px[i] as f64 + add).min(65535.0) as u16;
            }
        }
        science = ImageData::from_u16(science.width, science.height, 1, &px);
    }
    match difference_against_template(
        &tile,
        &science,
        &wcs,
        Interpolator::Lanczos3,
        &StarDetectionConfig::default(),
        &DifferenceOptions::default(),
    ) {
        Ok(result) => {
            pins.add("difference/candidates", debug_digest(&result.candidates));
            pins.add(
                "difference/match",
                debug_digest(&(
                    result.matched_scale,
                    result.matched_offset,
                    result.normalization_stars,
                )),
            );
            pins.add("difference/residual", image_digest(&result.residual));
            pins.add(
                "difference/planes",
                image_digest(&result.science) ^ image_digest(&result.template_image),
            );
        }
        Err(e) => pins.add("difference/error", debug_digest(&e)),
    }
}

fn pin_mosaic(pins: &mut Pins) {
    let left = crop(&load(RIG, "focused_L_0005.fits"), 400);
    let right = perturbed(&crop(&load(RIG, "focused_L_0006.fits"), 400), 3, 1.1, 40.0, 5.0);
    let scale = 1.9;
    let panels = vec![
        MosaicPanel {
            image: left,
            wcs: WcsInfo::from_plate_solve(5.5, 22.0, 0.0, scale, 400, 400),
        },
        MosaicPanel {
            image: right,
            wcs: WcsInfo::from_plate_solve(5.5 - 0.01, 22.02, 1.5, scale, 400, 400),
        },
    ];
    match stitch_mosaic(&panels, &MosaicStitchConfig::default()) {
        Ok(out) => {
            pins.add("mosaic/master", image_digest(&out.master));
            pins.add("mosaic/coverage", image_digest(&out.coverage));
            pins.add("mosaic/wcs_stats", debug_digest(&(&out.wcs, &out.stats)));
        }
        Err(e) => pins.add("mosaic/error", debug_digest(&e)),
    }
}

fn pin_finishing(pins: &mut Pins) {
    let mono = crop(&load(RIG, "focused_L_0005.fits"), 384);
    let rgb = as_rgb(&mono, [0.8, 1.0, 0.65]);
    let mono_f32 = to_f32_unit(&mono);
    let rgb_f32 = to_f32_unit(&rgb);

    for (name, image) in [
        ("mono_u16", &mono),
        ("rgb_u16", &rgb),
        ("mono_f32", &mono_f32),
        ("rgb_f32", &rgb_f32),
    ] {
        match extract_and_subtract(image, &BackgroundConfig::default()) {
            Ok((out, model)) => {
                pins.add(&format!("finishing/background.{name}"), image_digest(&out));
                pins.add(
                    &format!("finishing/background.{name}.model"),
                    debug_digest(&model),
                );
            }
            Err(e) => pins.add(&format!("finishing/background.{name}.error"), debug_digest(&e)),
        }
        pins.add(
            &format!("finishing/star_reduction.{name}"),
            match reduce_stars(image, &StarReductionConfig::default()) {
                Ok(out) => image_digest(&out),
                Err(e) => debug_digest(&e),
            },
        );
    }

    let round = load(STAR, "focused_L.fits");
    for (name, image) in [
        ("focused_L.u16", round.clone()),
        ("focused_L.f32", to_f32_unit(&round)),
        ("rig_0005.u16", load(RIG, "focused_L_0005.fits")),
    ] {
        for kind in [PsfKind::Moffat, PsfKind::Gaussian, PsfKind::Empirical] {
            let cfg = PsfEstimateConfig {
                kind,
                ..PsfEstimateConfig::default()
            };
            let name = format!("{name}.{kind:?}");
            match estimate_psf(&image, &cfg) {
                Ok(psf) => {
                    pins.add(&format!("finishing/psf.{name}"), debug_digest(&psf));
                    if kind == PsfKind::Moffat {
                        pins.add(
                            &format!("finishing/deconvolution.{name}"),
                            match richardson_lucy(&image, &psf, &DeconvConfig::default()) {
                                Ok(out) => image_digest(&out),
                                Err(e) => debug_digest(&e),
                            },
                        );
                    }
                }
                Err(e) => {
                    eprintln!("psf {name}: {e:?}");
                    pins.add(&format!("finishing/psf.{name}.error"), debug_digest(&e))
                }
            }
        }
    }

    let ha = &mono;
    let oiii = perturbed(&mono, 21, 0.7, 10.0, 6.0);
    let sii = perturbed(&mono, 22, 0.5, 5.0, 6.0);
    pins.add(
        "finishing/channel_combine.sho",
        match combine_channels(&[&sii, ha, &oiii], &sho_palette()) {
            Ok(out) => image_digest(&out),
            Err(e) => debug_digest(&e),
        },
    );
    pins.add(
        "finishing/channel_combine.hoo",
        match combine_channels(&[ha, &oiii], &hoo_palette()) {
            Ok(out) => image_digest(&out),
            Err(e) => debug_digest(&e),
        },
    );

    let stars: Vec<ColorStar> = (0..40)
        .map(|i| {
            let bv = -0.2 + 0.04 * i as f64;
            ColorStar {
                channel_flux: vec![
                    1000.0 * (1.0 + 0.5 * bv),
                    1100.0,
                    900.0 * (1.0 - 0.4 * bv) + (i % 3) as f64,
                ],
                catalog_bv: bv,
            }
        })
        .collect();
    match solve_color_calibration(&stars, 3, 0.65) {
        Ok(cal) => {
            pins.add("finishing/color_calibration.solve", debug_digest(&cal));
            let mut image = rgb.clone();
            apply_color_calibration(&mut image, &cal);
            pins.add("finishing/color_calibration.apply_u16", image_digest(&image));
            let mut image = rgb_f32.clone();
            apply_color_calibration(&mut image, &cal);
            pins.add("finishing/color_calibration.apply_f32", image_digest(&image));
        }
        Err(e) => pins.add("finishing/color_calibration.error", debug_digest(&e)),
    }
}

fn pin_recipe(pins: &mut Pins) {
    use recipe::*;
    let mono = to_f32_unit(&crop(&load(RIG, "focused_L_0005.fits"), 384));
    let rgb = to_f32_unit(&as_rgb(
        &crop(&load(RIG, "focused_L_0005.fits"), 384),
        [0.8, 1.0, 0.65],
    ));
    let registry = OpRegistry::builtin().expect("builtin ops");
    pins.add("recipe/op_keys", debug_digest(&registry.keys()));

    let step = |id: &str, params: serde_json::Value| {
        let version = registry.latest_version(id).unwrap_or_else(|| panic!("op {id}"));
        RecipeStep::new(id, version).with_params(params)
    };
    let cases: Vec<(&str, &ImageData, Vec<RecipeStep>)> = vec![
        (
            "mono.background",
            &mono,
            vec![step("background_extract", serde_json::json!({}))],
        ),
        (
            "mono.star_reduce",
            &mono,
            vec![
                step(
                    "stretch",
                    serde_json::json!({"blackPoint": 0.01, "whitePoint": 0.9}),
                ),
                step("star_reduce", serde_json::json!({})),
            ],
        ),
        ("mono.denoise", &mono, vec![step("denoise", serde_json::json!({}))]),
        (
            "mono.stretch",
            &mono,
            vec![step(
                "stretch",
                serde_json::json!({"blackPoint": 0.01, "whitePoint": 0.9}),
            )],
        ),
        (
            "rgb.chain",
            &rgb,
            vec![
                step("background_extract", serde_json::json!({})),
                step("denoise", serde_json::json!({})),
                step("scnr", serde_json::json!({})),
                step("chroma_denoise", serde_json::json!({})),
                step(
                    "stretch",
                    serde_json::json!({"blackPoint": 0.01, "whitePoint": 0.9}),
                ),
                step("star_reduce", serde_json::json!({})),
                step("curves", serde_json::json!({})),
                step("saturation", serde_json::json!({})),
            ],
        ),
    ];
    for (name, image, steps) in cases {
        let base = Arc::new(
            OpImage::from_image_data(image, FitsHeader::new()).expect("float base image"),
        );
        let mut recipe = Recipe::new("pin", "master", RecipeAuthor::User);
        recipe.steps = steps;
        let mut cache = RenderCache::new(DEFAULT_CACHE_CAPACITY_BYTES);
        match render_full(&recipe, &base, &registry, &mut cache, &OpContext::new()) {
            Ok(out) => {
                pins.add(&format!("recipe/{name}.pixels"), f32_digest(out.image.data()));
                pins.add(
                    &format!("recipe/{name}.outcomes"),
                    debug_digest(
                        &out.report
                            .steps
                            .iter()
                            .map(|s| (s.op_id.clone(), s.outcome.as_wire()))
                            .collect::<Vec<_>>(),
                    ),
                );
            }
            Err(e) => {
                eprintln!("recipe {name}: {e:?}");
                pins.add(&format!("recipe/{name}.error"), debug_digest(&e))
            }
        }
    }
}

fn pin_wcs(pins: &mut Pins) {
    let info = WcsInfo::from_plate_solve(5.5, 22.0, 33.0, 1.9, 4656, 3520);
    pins.add("wcs/info.from_plate_solve", debug_digest(&info));
    let mut header = FitsHeader::new();
    add_wcs_headers(&mut header, &info);
    pins.add("wcs/info.header", header_digest(&header));
    pins.add(
        "wcs/header.sip_wcs",
        debug_digest(&recipe::wcs_from_header(&header)),
    );
    let projection = WcsProjection::new(&info).expect("projection");
    let sip = SipWcs::tan_only(
        info.crval1,
        info.crval2,
        info.crpix1,
        info.crpix2,
        info.cd1_1,
        info.cd1_2,
        info.cd2_1,
        info.cd2_2,
    );
    let mut samples = Vec::new();
    for &(x, y) in &[(0.0, 0.0), (2327.5, 1759.5), (4655.0, 3519.0), (100.25, 3300.75)] {
        let a = projection.pixel_to_world(x, y);
        let b = sip.pixel_to_world(x, y);
        samples.push((a, b, projection.world_to_pixel(a.0, a.1), sip.world_to_pixel(b.0, b.1)));
    }
    pins.add("wcs/projection.samples", debug_digest(&samples));
    pins.add(
        "wcs/pixel_scale",
        debug_digest(&(projection.pixel_scale_arcsec(), sip.pixel_scale_arcsec())),
    );
}

#[test]
fn outputs_match_the_pinned_digests() {
    let mut pins = Pins(BTreeMap::new());
    pin_fixture_measurements(&mut pins);
    pin_display(&mut pins);
    pin_registration(&mut pins);
    pin_live_stack(&mut pins);
    pin_calibration(&mut pins);
    pin_streamed_master(&mut pins);
    pin_normalization_and_integration(&mut pins);
    pin_atlas_and_difference(&mut pins);
    pin_mosaic(&mut pins);
    pin_finishing(&mut pins);
    pin_recipe(&mut pins);
    pin_wcs(&mut pins);

    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/pins/output_pins.txt");
    let rendered: String = pins
        .0
        .iter()
        .map(|(name, digest)| format!("{name} {digest:016x}\n"))
        .collect();

    if std::env::var("SKOTIQ_UPDATE_PINS").as_deref() == Ok("1") {
        std::fs::create_dir_all(path.parent().expect("pins dir")).expect("pins dir");
        std::fs::write(&path, rendered).expect("pin file writes");
        return;
    }

    let pinned = std::fs::read_to_string(&path).expect("tests/pins/output_pins.txt");
    let pinned: BTreeMap<&str, &str> = pinned
        .lines()
        .filter_map(|line| line.rsplit_once(' '))
        .collect();
    let mut moved = Vec::new();
    for (name, digest) in &pins.0 {
        let now = format!("{digest:016x}");
        match pinned.get(name.as_str()) {
            Some(&was) if was == now => {}
            Some(&was) => moved.push(format!("{name}: pinned {was}, now {now}")),
            None => moved.push(format!("{name}: not pinned, now {now}")),
        }
    }
    for name in pinned.keys() {
        if !pins.0.contains_key(*name) {
            moved.push(format!("{name}: pinned but no longer produced"));
        }
    }
    assert!(
        moved.is_empty(),
        "{} output(s) moved:\n{}",
        moved.len(),
        moved.join("\n")
    );
}
