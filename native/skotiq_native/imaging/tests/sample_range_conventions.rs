//! One scene, every sample convention.
//!
//! `test-fixtures/sample-range-2026-11-12` holds one synthetic star field as a
//! 16-bit FITS, as the float and integer files PixInsight 1.9.4 saved from it
//! (float samples in `[0, 1]`), and as a float FITS in ADU with no range
//! cards. The float masters the app writes (ADU, range declared) are made
//! here. Whatever the file, the app must see the same frame: the same stars
//! and HFR, statistics, histogram, stretch and thumbnail, and calibration and
//! registration that mix conventions must work.

use skotiq_imaging::calibration::{calibrate_frame_f32, FloatCalibration};
use skotiq_imaging::{
    analyze_frame_quality, apply_stretch, auto_stretch_stf, calculate_histogram, calculate_stats,
    detect_stars, read_frame, solve_registration_against, thumbnail, write_fits, write_frame,
    FitsHeader, FrameQualityConfig, ImageData, PixelType, ReferenceStars, RegistrationConfig,
    SampleRange, StarDetectionConfig,
};
use std::path::{Path, PathBuf};

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../test-fixtures/sample-range-2026-11-12")
        .join(name)
}

fn load(name: &str) -> ImageData {
    read_frame(&fixture(name))
        .unwrap_or_else(|e| panic!("{name}: {e}"))
        .0
}

fn scratch(name: &str) -> PathBuf {
    // One directory per test thread: the tests write the same file names.
    let dir = std::env::temp_dir().join(format!(
        "skotiq-sample-range-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir.join(name)
}

/// The scene written by the app and read back: `(name, frame)`.
fn written_by_the_app(scene: &ImageData) -> Vec<(String, ImageData)> {
    let adu: Vec<f32> = scene.samples_f32();
    let master = ImageData::from_f32(scene.width, scene.height, 1, &adu);
    let mut out = Vec::new();
    for extension in ["fits", "xisf"] {
        let path = scratch(&format!("master_f32_adu.{extension}"));
        write_frame(&path, &master, &FitsHeader::new()).unwrap();
        out.push((
            format!("app float master, ADU ({extension})"),
            read_frame(&path).unwrap().0,
        ));
    }
    out
}

fn mono_twins() -> Vec<(String, ImageData, SampleRange)> {
    let scene = load("scene_u16.fits");
    let mut twins = vec![
        ("pi_scene_f32.xisf", SampleRange::UNIT),
        ("pi_scene_f64.xisf", SampleRange::UNIT),
        ("pi_scene_f32.fits", SampleRange::UNIT),
        ("pi_scene_u16.xisf", SampleRange::ADU),
        ("pi_scene_u32.xisf", SampleRange::of(PixelType::U32)),
        ("unmarked_f32_adu.fits", SampleRange::ADU),
    ]
    .into_iter()
    .map(|(name, range)| (name.to_string(), load(name), range))
    .collect::<Vec<_>>();
    twins.extend(
        written_by_the_app(&scene)
            .into_iter()
            .map(|(name, image)| (name, image, SampleRange::ADU)),
    );
    twins
}

fn median_hfr(image: &ImageData) -> (usize, f64) {
    let stars = detect_stars(image, &StarDetectionConfig::default());
    let mut hfr: Vec<f64> = stars.iter().map(|s| s.hfr).collect();
    hfr.sort_by(f64::total_cmp);
    (stars.len(), hfr.get(hfr.len() / 2).copied().unwrap_or(0.0))
}

#[test]
fn the_reader_declares_each_files_range_and_the_samples_agree() {
    let scene = load("scene_u16.fits");
    assert_eq!(scene.range, SampleRange::ADU);
    let reference = scene.samples_f64();
    for (name, twin, range) in mono_twins() {
        assert_eq!(twin.range, range, "{name}: range");
        assert_eq!((twin.width, twin.height, twin.channels), (400, 300, 1), "{name}");
        let worst = twin
            .samples_f64()
            .iter()
            .zip(&reference)
            .map(|(a, b)| (a - b).abs())
            .fold(0.0, f64::max);
        // A 16-bit level in a Float32 in [0, 1] is good to 65535 * 2^-24 ADU.
        assert!(worst < 0.01, "{name}: samples differ by {worst} ADU");
    }
}

#[test]
fn stars_hfr_statistics_and_histogram_agree_across_conventions() {
    let scene = load("scene_u16.fits");
    let (count, hfr) = median_hfr(&scene);
    assert!(count >= 30, "the scene has 45 stars, found {count}");
    let stats = calculate_stats(&scene);
    let histogram = calculate_histogram(&scene, 256);
    let quality = analyze_frame_quality(&scene, &FrameQualityConfig::default()).unwrap();
    println!("16-bit: {count} stars, HFR {hfr:.4}, median {} mad {}", stats.median, stats.mad);

    for (name, twin, _) in mono_twins() {
        let (twin_count, twin_hfr) = median_hfr(&twin);
        let twin_stats = calculate_stats(&twin);
        println!(
            "{name}: {twin_count} stars, HFR {twin_hfr:.4}, median {:.3} mad {:.3}",
            twin_stats.median, twin_stats.mad
        );
        assert_eq!(twin_count, count, "{name}: star count");
        assert!((twin_hfr - hfr).abs() < 0.005 * hfr, "{name}: HFR {twin_hfr} vs {hfr}");
        for (what, a, b) in [
            ("min", twin_stats.min, stats.min),
            ("max", twin_stats.max, stats.max),
            ("mean", twin_stats.mean, stats.mean),
            ("median", twin_stats.median, stats.median),
            ("std dev", twin_stats.std_dev, stats.std_dev),
            ("MAD", twin_stats.mad, stats.mad),
        ] {
            assert!((a - b).abs() < 0.02, "{name}: {what} {a} vs {b}");
        }
        assert_eq!(calculate_histogram(&twin, 256), histogram, "{name}: histogram");
        let twin_quality = analyze_frame_quality(&twin, &FrameQualityConfig::default())
            .unwrap_or_else(|| panic!("{name}: no frame quality"));
        assert!(
            (twin_quality.background - quality.background).abs() < 0.5
                && (twin_quality.noise - quality.noise).abs() < 0.01 * quality.noise,
            "{name}: quality {twin_quality:?} vs {quality:?}"
        );
    }
}

#[test]
fn stretch_and_thumbnail_agree_across_conventions() {
    let scene = load("scene_u16.fits");
    let params = auto_stretch_stf(&scene);
    let display = apply_stretch(&scene, &params);
    let preview = thumbnail(&scene, 1, 200);
    assert_eq!((preview.width, preview.height), (200, 150));
    for (name, twin, _) in mono_twins() {
        let twin_params = auto_stretch_stf(&twin);
        assert!(
            (twin_params.shadows - params.shadows).abs() < 1e-6
                && (twin_params.midtones - params.midtones).abs() < 1e-6
                && (twin_params.highlights - params.highlights).abs() < 1e-6,
            "{name}: stretch {twin_params:?} vs {params:?}"
        );
        assert_eq!(apply_stretch(&twin, &twin_params), display, "{name}: stretched frame");
        let twin_preview = thumbnail(&twin, 1, 200);
        let worst = twin_preview
            .data
            .iter()
            .zip(&preview.data)
            .map(|(a, b)| a.abs_diff(*b))
            .max()
            .unwrap();
        assert!(worst <= 1, "{name}: thumbnail differs by {worst} levels");
    }
}

#[test]
fn a_color_float_frame_reads_as_its_16_bit_twin() {
    let float = load("pi_scene_rgb_f32.xisf");
    let sixteen = load("pi_scene_rgb_u16.xisf");
    assert_eq!((float.channels, float.range), (3, SampleRange::UNIT));
    assert_eq!((sixteen.channels, sixteen.range), (3, SampleRange::ADU));
    let (count, hfr) = median_hfr(&sixteen);
    let (float_count, float_hfr) = median_hfr(&float);
    assert!(count >= 30);
    assert_eq!(float_count, count);
    assert!((float_hfr - hfr).abs() < 0.005 * hfr);
    let (a, b) = (float.to_display_u8(), sixteen.to_display_u8());
    let worst = a.iter().zip(&b).map(|(a, b)| a.abs_diff(*b)).max().unwrap();
    assert!(worst <= 1, "displayed color frames differ by {worst} levels");
}

#[test]
fn calibration_mixes_conventions() {
    let scene = load("scene_u16.fits");
    // A dark of 200 ADU as the app writes a float master, and the same dark
    // as PixInsight would hold it.
    let dark_adu = ImageData::from_f32(400, 300, 1, &vec![200.0; 400 * 300]);
    let dark_unit = ImageData::from_f32(400, 300, 1, &vec![200.0 / 65535.0; 400 * 300])
        .with_range(SampleRange::UNIT);
    let calibrate = |light: &ImageData, dark: &ImageData| {
        calibrate_frame_f32(
            light,
            &FloatCalibration {
                dark: Some(dark),
                ..FloatCalibration::default()
            },
        )
        .unwrap()
    };
    let reference = calibrate(&scene, &dark_adu).samples_f64();
    for (name, twin, _) in mono_twins() {
        for (dark_name, dark) in [("ADU dark", &dark_adu), ("[0, 1] dark", &dark_unit)] {
            let calibrated = calibrate(&twin, dark);
            assert_eq!(calibrated.range, SampleRange::ADU);
            let worst = calibrated
                .samples_f64()
                .iter()
                .zip(&reference)
                .map(|(a, b)| (a - b).abs())
                .fold(0.0, f64::max);
            assert!(worst < 0.02, "{name} with {dark_name}: off by {worst} ADU");
        }
    }
}

#[test]
fn a_float_frame_registers_against_a_16_bit_reference() {
    let scene = load("scene_u16.fits");
    let config = RegistrationConfig::default();
    let reference = ReferenceStars::detect(&scene, &config).unwrap();
    for name in ["pi_scene_f32.xisf", "pi_scene_f32.fits", "unmarked_f32_adu.fits"] {
        let (model, stats) = solve_registration_against(&reference, &load(name), &config)
            .unwrap_or_else(|e| panic!("{name}: {e:?}"));
        let (x, y) = model.apply(200.0, 150.0);
        assert!(
            (x - 200.0).abs() < 0.05 && (y - 150.0).abs() < 0.05,
            "{name}: the same scene should register onto itself, got ({x}, {y}), {stats:?}"
        );
    }
    // The other way round: a PixInsight float reference, a 16-bit frame.
    let reference = ReferenceStars::detect(&load("pi_scene_f32.xisf"), &config).unwrap();
    assert!(solve_registration_against(&reference, &scene, &config).is_ok());
}

#[test]
fn a_file_keeps_its_range_through_the_app() {
    let unit = load("pi_scene_f32.xisf");
    for extension in ["xisf", "fits"] {
        let path = scratch(&format!("resaved_unit.{extension}"));
        write_frame(&path, &unit, &FitsHeader::new()).unwrap();
        let (back, header) = read_frame(&path).unwrap();
        assert_eq!(back.range, SampleRange::UNIT, "{extension}");
        assert_eq!(back.data, unit.data, "{extension}: samples changed");
        assert!(
            header.get("RANGELOW").is_none() && header.get("RANGEHI").is_none(),
            "{extension}: the range cards describe the encoding and stay out of the header"
        );
    }

    // A float master with samples outside its range (a background-subtracted
    // one goes below zero): XISF `bounds` is widened so PixInsight does not
    // truncate them, and the app still reads its own range back.
    let mut samples = load("scene_u16.fits").samples_f32();
    samples[0] = -250.0;
    samples[1] = 70_000.0;
    let master = ImageData::from_f32(400, 300, 1, &samples);
    for extension in ["xisf", "fits"] {
        let path = scratch(&format!("master_out_of_range.{extension}"));
        write_frame(&path, &master, &FitsHeader::new()).unwrap();
        let back = read_frame(&path).unwrap().0;
        assert_eq!(back.range, SampleRange::ADU, "{extension}");
        assert_eq!(back.data, master.data, "{extension}");
    }
    let unit = skotiq_imaging::read_xisf_unit(&scratch("master_out_of_range.xisf")).unwrap();
    assert_eq!(unit.image(0).unwrap().bounds, Some((-250.0, 70_000.0)));
    // A master within its range states exactly that range.
    written_by_the_app(&load("scene_u16.fits"));
    let unit = skotiq_imaging::read_xisf_unit(&scratch("master_f32_adu.xisf")).unwrap();
    assert_eq!(unit.image(0).unwrap().bounds, Some((0.0, 65535.0)));

    // An unmarked float FITS holding ADU is declared when the app writes it.
    let path = scratch("legacy_rewritten.fits");
    write_fits(&path, &load("unmarked_f32_adu.fits"), &FitsHeader::new()).unwrap();
    let text = String::from_utf8_lossy(&std::fs::read(&path).unwrap()[..2880]).to_string();
    assert!(text.contains("RANGELOW=") && text.contains("RANGEHI ="), "{text}");
}
