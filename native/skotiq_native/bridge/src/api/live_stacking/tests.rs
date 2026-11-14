use super::*;

/// Serialises every test that touches the process-global `LIVE_STACKER`
/// singleton so they don't clobber each other's session under `cargo test`'s
/// parallel harness. Tests that only exercise pure parsing don't need it.
static SINGLETON_TEST_LOCK: Mutex<()> = Mutex::new(());

fn singleton_guard() -> std::sync::MutexGuard<'static, ()> {
    SINGLETON_TEST_LOCK
        .lock()
        .unwrap_or_else(|p| p.into_inner())
}

const IMG_W: u32 = 512;
const IMG_H: u32 = 512;

/// A mono session with the settings the app starts from.
fn config() -> ApiLiveStackingConfig {
    ApiLiveStackingConfig {
        sigma_clip_enabled: true,
        sigma_clip_threshold: 2.5,
        max_match_stars: 100,
        match_radius_px: 50.0,
        match_flux_tolerance: 0.7,
        min_matched_pairs: 5,
        sensor_mode: "mono".to_string(),
        bayer_pattern: None,
        demosaic_quality: "bilinear".to_string(),
    }
}

/// Config for the end-to-end ingest tests.
///
/// `min_matched_pairs: 0` makes [`LiveStacker::new`]/`add_frame` accept a
/// frame regardless of how many stars its detector finds. This deliberately
/// decouples these *bridge-wiring* tests (which verify config parsing, the
/// CFA→RGB debayer-on-ingest path, and channel propagation) from the
/// imaging crate's star-detection tuning — alignment quality is exercised by
/// the imaging crate's own stacker tests, not here. It is a legitimate
/// public-API value (the field is `u32`), not a test-only backdoor.
fn base_config() -> ApiLiveStackingConfig {
    ApiLiveStackingConfig {
        min_matched_pairs: 0,
        ..config()
    }
}

/// Build a synthetic single-channel U16 frame: a low-noise background with
/// a few bright, well-separated bright blobs. The blobs make the frame
/// non-uniform (so a CFA mosaic of it debayers to a non-trivial RGB image)
/// without depending on the detector accepting them.
fn make_star_plane(width: u32, height: u32) -> Vec<u16> {
    let w = width as usize;
    let h = height as usize;
    let bg = 1000u16;
    let mut data = vec![bg; w * h];

    // Deterministic low-amplitude background texture.
    for (i, pixel) in data.iter_mut().enumerate() {
        let n = ((i as u64).wrapping_mul(1103515245).wrapping_add(12345) >> 16) & 0xFF;
        let noise = (n as i32 - 128) / 8; // ~[-16, 16] ADU
        *pixel = (bg as i32 + noise).clamp(0, 65535) as u16;
    }

    // A handful of bright Gaussian blobs.
    let blobs = [
        (40.0, 40.0, 40000.0),
        (120.0, 60.0, 35000.0),
        (200.0, 50.0, 38000.0),
        (60.0, 140.0, 30000.0),
        (160.0, 150.0, 36000.0),
    ];
    for &(sx, sy, brightness) in &blobs {
        let radius = 8i32;
        let sigma = 2.5;
        for dy in -radius..=radius {
            for dx in -radius..=radius {
                let px = sx as i32 + dx;
                let py = sy as i32 + dy;
                if px < 0 || px >= width as i32 || py < 0 || py >= height as i32 {
                    continue;
                }
                let dist_sq = (dx * dx + dy * dy) as f64;
                let gauss = (-dist_sq / (2.0 * sigma * sigma)).exp();
                let idx = py as usize * w + px as usize;
                data[idx] = (data[idx] as u32 + (brightness * gauss) as u32).min(65535) as u16;
            }
        }
    }

    data
}

#[test]
fn config_parses_valid_demosaic_qualities() {
    for (q, expected) in [
        ("bilinear", DebayerAlgorithm::Bilinear),
        ("VNG", DebayerAlgorithm::VNG),
        ("superpixel", DebayerAlgorithm::SuperPixel),
    ] {
        let cfg = ApiLiveStackingConfig {
            demosaic_quality: q.to_string(),
            ..config()
        };
        let native: LiveStackConfig = stacker_config(&cfg).expect("valid quality parses");
        assert_eq!(native.demosaic_algorithm, expected, "quality {q}");
    }
}

#[test]
fn config_parses_sensor_modes_and_patterns() {
    let cfg = ApiLiveStackingConfig {
        sensor_mode: "OSC".to_string(),
        bayer_pattern: Some("grbg".to_string()),
        ..config()
    };
    let native: LiveStackConfig = stacker_config(&cfg).expect("valid osc config parses");
    assert_eq!(native.sensor_mode, SensorMode::Osc);
    assert_eq!(native.bayer_pattern, Some(BayerPattern::Grbg));

    // "auto" is its own first-class mode (debayer only when a pattern
    // resolves), distinct from OSC (which requires one).
    let auto = ApiLiveStackingConfig {
        sensor_mode: "auto".to_string(),
        ..config()
    };
    let native: LiveStackConfig = stacker_config(&auto).expect("auto parses");
    assert_eq!(native.sensor_mode, SensorMode::Auto);
    assert_eq!(native.bayer_pattern, None);
}

#[test]
fn config_invalid_demosaic_quality_is_error() {
    let cfg = ApiLiveStackingConfig {
        demosaic_quality: "lanczos".to_string(),
        ..config()
    };
    let err = stacker_config(&cfg).expect_err("invalid quality must error");
    assert!(err.to_string().contains("demosaic quality"), "got: {err}");
    assert!(
        err.to_string().contains("lanczos"),
        "error names the bad value: {err}"
    );
}

#[test]
fn config_invalid_bayer_pattern_is_error() {
    let cfg = ApiLiveStackingConfig {
        bayer_pattern: Some("xyzw".to_string()),
        ..config()
    };
    let err = stacker_config(&cfg).expect_err("invalid pattern must error");
    assert!(err.to_string().contains("Bayer pattern"), "got: {err}");
}

#[test]
fn config_invalid_sensor_mode_is_error() {
    let cfg = ApiLiveStackingConfig {
        sensor_mode: "rgbw".to_string(),
        ..config()
    };
    let err = stacker_config(&cfg).expect_err("invalid sensor mode must error");
    assert!(err.to_string().contains("sensor mode"), "got: {err}");
}

// OSC-without-pattern (in-memory ingest)

#[test]
fn osc_start_from_data_without_pattern_is_error() {
    let _g = singleton_guard();
    let _ = api_stacking_stop(); // ensure clean slate

    let cfg = ApiLiveStackingConfig {
        sensor_mode: "osc".to_string(),
        bayer_pattern: None,
        ..base_config()
    };
    let data = make_star_plane(IMG_W, IMG_H);
    let err = api_stacking_start_from_data(IMG_W, IMG_H, data, cfg)
        .expect_err("OSC without resolvable pattern must error");
    assert!(
        err.to_string()
            .contains("OSC declared but no Bayer pattern resolvable"),
        "got: {err}"
    );
    // Nothing should have been installed.
    assert!(
        !api_stacking_is_active(),
        "failed start must not leave a session"
    );
}

// RGB round-trip

/// A small, fully-specified RGGB CFA where each colour site holds a distinct
/// ADU so we can predict the demosaiced RGB at a known pixel exactly.
/// Layout (RGGB): row0 = R G R G, row1 = G B G B, ...
/// R sites = 1000, G sites = 500, B sites = 100.
fn uniform_rggb_cfa(width: usize, height: usize) -> Vec<u16> {
    let mut pixels = vec![0u16; width * height];
    for y in 0..height {
        for x in 0..width {
            pixels[y * width + x] = match BayerPattern::Rggb.color_at(x, y) {
                skotiq_imaging::BayerColor::Red => 1000,
                skotiq_imaging::BayerColor::Green => 500,
                skotiq_imaging::BayerColor::Blue => 100,
            };
        }
    }
    pixels
}

#[test]
fn osc_start_from_data_produces_three_channel_result() {
    let _g = singleton_guard();
    let _ = api_stacking_stop();

    let cfg = ApiLiveStackingConfig {
        sensor_mode: "osc".to_string(),
        bayer_pattern: Some("RGGB".to_string()),
        demosaic_quality: "bilinear".to_string(),
        ..base_config()
    };

    // A CFA star field: the underlying scene is a mono star plane sampled
    // through an RGGB mosaic, which still yields detectable stars in the
    // luminance proxy after debayering.
    let cfa = make_star_plane(IMG_W, IMG_H);
    api_stacking_start_from_data(IMG_W, IMG_H, cfa.clone(), cfg).expect("osc start succeeds");

    // The current stack is the debayered reference: 3 channels, same dims.
    let result = api_stacking_get_result().expect("result available");
    assert_eq!(result.channels, 3, "OSC stack must be 3-channel RGB");
    assert_eq!(result.width, IMG_W);
    assert_eq!(result.height, IMG_H);
    assert_eq!(result.data.len(), (IMG_W * IMG_H * 3) as usize);

    // The stack must equal the canonical debayer of the same CFA exactly —
    // the ingest path debayers with no extra processing on the first frame.
    let reference_rgb = debayer_cfa_to_rgb(
        &ImageData::from_u16(IMG_W, IMG_H, 1, &cfa),
        ColorFilterArray::Bayer(BayerPattern::Rggb),
        DebayerAlgorithm::Bilinear,
    )
    .expect("reference debayer")
    .as_u16()
    .expect("rgb u16");
    assert_eq!(
        result.data, reference_rgb,
        "OSC stack reference must be the canonical debayer of the CFA"
    );

    let _ = api_stacking_stop();
}

/// Known-pixel RGB check: a uniform RGGB CFA (R=1000, G=500, B=100)
/// debayers to predictable interior values. At an interior *red* site the
/// red channel keeps 1000, green is the cross-average of four 500s (=500),
/// and blue is the diagonal-average of four 100s (=100).
#[test]
fn rggb_known_pixel_debayers_to_expected_rgb() {
    let cfa = uniform_rggb_cfa(8, 8);
    let rgb = debayer_cfa_to_rgb(
        &ImageData::from_u16(8, 8, 1, &cfa),
        ColorFilterArray::Bayer(BayerPattern::Rggb),
        DebayerAlgorithm::Bilinear,
    )
    .expect("debayer")
    .as_u16()
    .expect("u16");

    // Interior red site at (x=2, y=2) — fully surrounded, no edge clamping.
    let site = (2 * 8 + 2) * 3;
    assert_eq!(rgb[site], 1000, "R at red site");
    assert_eq!(
        rgb[site + 1],
        500,
        "G interpolated from four green neighbours"
    );
    assert_eq!(
        rgb[site + 2],
        100,
        "B interpolated from four blue neighbours"
    );
}

#[test]
fn osc_add_frame_from_data_keeps_three_channels() {
    let _g = singleton_guard();
    let _ = api_stacking_stop();

    let cfg = ApiLiveStackingConfig {
        sensor_mode: "osc".to_string(),
        bayer_pattern: Some("RGGB".to_string()),
        ..base_config()
    };
    let cfa = make_star_plane(IMG_W, IMG_H);
    api_stacking_start_from_data(IMG_W, IMG_H, cfa.clone(), cfg).expect("osc start");

    // Feeding the identical CFA plane debayers and accumulates as RGB.
    let added = api_stacking_add_frame_from_data(IMG_W, IMG_H, cfa).expect("add frame");
    assert_eq!(added.channels, 3, "added OSC frame stays 3-channel");
    assert_eq!(added.data.len(), (IMG_W * IMG_H * 3) as usize);
    assert_eq!(
        added.stats.stacked_frame_count, 2,
        "identical frame aligns and stacks"
    );

    let _ = api_stacking_stop();
}

// Mono path is unchanged

#[test]
fn mono_start_from_data_is_single_channel() {
    let _g = singleton_guard();
    let _ = api_stacking_stop();

    let data = make_star_plane(IMG_W, IMG_H);
    api_stacking_start_from_data(IMG_W, IMG_H, data.clone(), base_config()).expect("mono start");

    let result = api_stacking_get_result().expect("result");
    assert_eq!(result.channels, 1, "mono stack stays single-channel");
    assert_eq!(result.width, IMG_W);
    assert_eq!(result.height, IMG_H);
    assert_eq!(result.data.len(), (IMG_W * IMG_H) as usize);
    // The single-frame stack is the reference frame itself, byte-for-byte.
    assert_eq!(result.data, data);

    let _ = api_stacking_stop();
}

// AUTO with no pattern resolves to mono (regression guard)

#[test]
fn auto_start_from_data_without_pattern_is_mono() {
    // The default Stack-and-Share config is `sensor_mode = "auto"`. On a
    // monochrome session (a raw u16 buffer carries no BAYERPAT and the
    // config has no override) AUTO must stack as MONO, not error. This is
    // the default mono Stack-and-Share path; collapsing auto into osc
    // bricks it.
    let _g = singleton_guard();
    let _ = api_stacking_stop();

    let cfg = ApiLiveStackingConfig {
        sensor_mode: "auto".to_string(),
        bayer_pattern: None,
        ..base_config()
    };
    let data = make_star_plane(IMG_W, IMG_H);
    api_stacking_start_from_data(IMG_W, IMG_H, data.clone(), cfg)
        .expect("auto without pattern must stack as mono, not error");

    let result = api_stacking_get_result().expect("result");
    assert_eq!(result.channels, 1, "auto+no-pattern stacks as mono");
    assert_eq!(result.data.len(), (IMG_W * IMG_H) as usize);
    assert_eq!(result.data, data, "mono reference is byte-for-byte");

    let _ = api_stacking_stop();
}

#[test]
fn auto_start_from_data_with_pattern_debayers_to_color() {
    // The complement: AUTO *with* an explicit override does debayer.
    let _g = singleton_guard();
    let _ = api_stacking_stop();

    let cfg = ApiLiveStackingConfig {
        sensor_mode: "auto".to_string(),
        bayer_pattern: Some("RGGB".to_string()),
        ..base_config()
    };
    let cfa = make_star_plane(IMG_W, IMG_H);
    api_stacking_start_from_data(IMG_W, IMG_H, cfa, cfg).expect("auto+pattern start");

    let result = api_stacking_get_result().expect("result");
    assert_eq!(result.channels, 3, "auto+pattern debayers to RGB");
    assert_eq!(result.data.len(), (IMG_W * IMG_H * 3) as usize);

    let _ = api_stacking_stop();
}

// Every demosaic algorithm ingests end-to-end (geometry guard)

/// SuperPixel halves resolution; Bilinear/VNG keep it. Each must produce an
/// integrated result whose declared dimensions and buffer length are
/// self-consistent — guarding against assuming the input CFA size for an
/// algorithm that changes geometry.
#[test]
fn every_demosaic_quality_ingests_with_consistent_geometry() {
    for quality in ["bilinear", "vng", "superpixel"] {
        let _g = singleton_guard();
        let _ = api_stacking_stop();

        let cfg = ApiLiveStackingConfig {
            sensor_mode: "osc".to_string(),
            bayer_pattern: Some("RGGB".to_string()),
            demosaic_quality: quality.to_string(),
            ..base_config()
        };
        let cfa = make_star_plane(IMG_W, IMG_H);
        api_stacking_start_from_data(IMG_W, IMG_H, cfa, cfg)
            .unwrap_or_else(|e| panic!("osc start with {quality} failed: {e}"));

        let result = api_stacking_get_result().expect("result");
        assert_eq!(result.channels, 3, "{quality}: OSC result is 3-channel");

        // The declared dims must match the demosaiced output (half for
        // superpixel, full otherwise) and the buffer must be exactly
        // width*height*3 — never the short buffer that the old
        // input-dims-assumption produced for superpixel.
        let (expect_w, expect_h) = if quality == "superpixel" {
            (IMG_W / 2, IMG_H / 2)
        } else {
            (IMG_W, IMG_H)
        };
        assert_eq!(result.width, expect_w, "{quality}: width");
        assert_eq!(result.height, expect_h, "{quality}: height");
        assert_eq!(
            result.data.len(),
            (result.width * result.height * 3) as usize,
            "{quality}: buffer length matches declared 3-channel dims"
        );

        let _ = api_stacking_stop();
    }
}

// FITS master

/// Write a single-channel FITS light frame carrying the two keywords the
/// master's header is built from.
fn write_light_frame(path: &std::path::Path, exposure_secs: f64, date_obs: &str) {
    let image = ImageData::from_u16(IMG_W, IMG_H, 1, &make_star_plane(IMG_W, IMG_H));
    let mut header = skotiq_imaging::FitsHeader::new();
    header.set_float("EXPTIME", exposure_secs);
    header.set_string("DATE-OBS", date_obs);
    header.set_string("IMAGETYP", "LIGHT");
    skotiq_imaging::write_fits(path, &image, &header).expect("light frame written");
}

/// Owner decision 8: the master saves as FITS, and its `EXPTIME` /
/// `DATE-OBS` come from the frames the stacker really folded — including
/// the reference frame, which contributes pixels like any other.
#[test]
fn saved_master_sums_the_integration_of_the_frames_it_stacked() {
    let _g = singleton_guard();
    let _ = api_stacking_stop();

    let dir = std::env::temp_dir().join("sk-bridge-stack-master");
    std::fs::create_dir_all(&dir).expect("temp dir");
    let reference = dir.join("reference.fits");
    let second = dir.join("second.fits");
    let master = dir.join("master.fits");
    write_light_frame(&reference, 120.0, "2026-08-14T03:25:00");
    // Earlier than the reference: DATE-OBS must follow the clock, not the
    // order the frames were handed to the stacker.
    write_light_frame(&second, 120.0, "2026-08-14T03:22:30");

    api_stacking_start(reference.to_string_lossy().to_string(), base_config())
        .expect("reference started the stack");
    api_stacking_add_frame(second.to_string_lossy().to_string()).expect("second frame stacked");

    let saved = save_master_fits(master.to_string_lossy().to_string()).expect("master written");
    assert_eq!(saved.stacked_frame_count, 2);
    assert_eq!(saved.total_integration_secs, 240.0);
    assert_eq!(saved.date_obs, "2026-08-14T03:22:30.000");

    let (image, header) = skotiq_imaging::read_frame(&master).expect("master reads back");
    assert_eq!(image.width, IMG_W);
    assert_eq!(header.get_float("EXPTIME"), Some(240.0));
    assert_eq!(
        header.get_string("DATE-OBS"),
        Some("2026-08-14T03:22:30.000")
    );
    assert_eq!(header.get_int("NFRAMES"), Some(2));

    let _ = api_stacking_stop();
    let _ = std::fs::remove_dir_all(&dir);
}

/// The file path is how every capture reaches the live stack (a snapshot,
/// a sequence frame, the host's own feed), so the frame's `FILTER` header
/// is what keeps a frame of another filter out of it.
#[test]
fn a_frame_file_of_another_filter_does_not_enter_the_stack() {
    let _g = singleton_guard();
    let _ = api_stacking_stop();

    let dir = std::env::temp_dir().join("sk-bridge-stack-filter");
    std::fs::create_dir_all(&dir).expect("temp dir");
    let write = |name: &str, filter: &str| {
        let path = dir.join(name);
        let image = ImageData::from_u16(IMG_W, IMG_H, 1, &make_star_plane(IMG_W, IMG_H));
        let mut header = skotiq_imaging::FitsHeader::new();
        header.set_float("EXPTIME", 60.0);
        header.set_string("FILTER", filter);
        skotiq_imaging::write_fits(&path, &image, &header).expect("light frame written");
        path.to_string_lossy().to_string()
    };
    let reference = write("l1.fits", "L");
    let same = write("l2.fits", "L");
    let other = write("r1.fits", "R");

    let started = api_stacking_start(reference, base_config()).expect("stack started");
    assert_eq!(started.filter.as_deref(), Some("L"));
    api_stacking_add_frame(same).expect("an L frame stacks");

    let refusal = api_stacking_add_frame(other).expect_err("an R frame is left out");
    assert!(
        matches!(&refusal, SkotiqError::ImageError(m)
            if m.starts_with(skotiq_imaging::stacking::OTHER_FILTER_REFUSAL)),
        "unexpected refusal: {refusal}"
    );
    let stats = api_stacking_get_stats().expect("stats");
    assert_eq!(stats.stacked_frame_count, 2);
    assert_eq!(stats.total_frames_attempted, 2);
    assert_eq!(stats.rejected_alignment_failures, 0);
    assert_eq!(stats.other_filter_frames, 1);
    assert_eq!(stats.last_other_filter.as_deref(), Some("R"));

    let _ = api_stacking_stop();
    let _ = std::fs::remove_dir_all(&dir);
}

/// Saving with no stack running fails loudly rather than writing an empty
/// file the operator would mistake for their integration.
#[test]
fn saving_a_master_without_a_stacker_is_an_error() {
    let _g = singleton_guard();
    let _ = api_stacking_stop();

    let err = save_master_fits(
        std::env::temp_dir()
            .join("sk-no-stack-master.fits")
            .to_string_lossy()
            .to_string(),
    )
    .expect_err("no stacker means no master");
    assert!(
        err.to_string().contains("not initialized"),
        "unexpected error: {err}"
    );
}
