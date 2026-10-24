//! Darkroom build regressions: calibration, master flats, coverage,
//! rejection and the cost of a build on full-size frames.
use super::*;
use std::path::PathBuf;

struct Lcg(u64);
impl Lcg {
    fn unit(&mut self) -> f64 {
        self.0 = self
            .0
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        ((self.0 >> 11) as f64) / ((1u64 << 53) as f64)
    }
    fn normal(&mut self) -> f64 {
        let u1 = self.unit().max(1e-12);
        let u2 = self.unit();
        (-2.0 * u1.ln()).sqrt() * (2.0 * std::f64::consts::PI * u2).cos()
    }
}

fn scratch(name: &str) -> PathBuf {
    let n = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let dir = std::env::temp_dir().join(format!("sk_rv_{name}_{}_{n}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn star_list(w: u32, h: u32, n: usize) -> Vec<(f64, f64, f64)> {
    let mut rng = Lcg(0x5EED);
    (0..n)
        .map(|_| {
            (
                20.0 + rng.unit() * (w as f64 - 40.0),
                20.0 + rng.unit() * (h as f64 - 40.0),
                3_000.0 * 10f64.powf(rng.unit() * 1.3),
            )
        })
        .collect()
}

/// `color_seed` != 0 gives every star its own color factor (0.25..4), so the
/// brightness RANK of stars differs between filters, as in real L/R/G/B data.
fn render(
    w: u32,
    h: u32,
    nstars: usize,
    sky: f64,
    noise: f64,
    shift: (f64, f64),
    flipped: bool,
    seed: u64,
    color_seed: u64,
) -> Vec<f64> {
    let mut rng = Lcg(seed);
    let mut px: Vec<f64> = (0..w * h).map(|_| sky + noise * rng.normal()).collect();
    let mut color = Lcg(color_seed.max(1));
    let sigma = 1.7_f64;
    for (x, y, flux) in star_list(w, h, nstars) {
        let c = if color_seed == 0 {
            1.0
        } else {
            0.25 * 16f64.powf(color.unit())
        };
        let (mut sx, mut sy) = (x + shift.0, y + shift.1);
        if flipped {
            sx = w as f64 - 1.0 - sx;
            sy = h as f64 - 1.0 - sy;
        }
        let norm = c * flux / (2.0 * std::f64::consts::PI * sigma * sigma);
        for yy in (sy as i64 - 7)..=(sy as i64 + 7) {
            for xx in (sx as i64 - 7)..=(sx as i64 + 7) {
                if xx < 0 || yy < 0 || xx >= w as i64 || yy >= h as i64 {
                    continue;
                }
                let r2 = (xx as f64 - sx).powi(2) + (yy as f64 - sy).powi(2);
                px[yy as usize * w as usize + xx as usize] +=
                    norm * (-r2 / (2.0 * sigma * sigma)).exp();
            }
        }
    }
    px
}

fn write_u16(path: &Path, w: u32, h: u32, px: &[f64], hdr: &FitsHeader) -> String {
    let data: Vec<u16> = px
        .iter()
        .map(|v| v.round().clamp(0.0, 65535.0) as u16)
        .collect();
    write_fits(path, &ImageData::from_u16(w, h, 1, &data), hdr).unwrap();
    path.to_string_lossy().to_string()
}

fn light_header(filter: &str) -> FitsHeader {
    let mut h = FitsHeader::new();
    h.set_string("IMAGETYP", "LIGHT");
    h.set_string("FILTER", filter);
    h
}

/// A unit-mean float master flat with a master bias calibrates an integer
/// light, and the bias is not subtracted from the already-corrected flat.
#[test]
fn a_float_flat_with_a_bias_calibrates_an_integer_light() {
    let light = ImageData::from_u16(2, 2, 1, &[1300, 1300, 1300, 1300]);
    let bias = ImageData::from_u16(2, 2, 1, &[300; 4]);
    let flat = ImageData::from_f32(2, 2, 1, &[1.0; 4]);
    let out = skotiq_imaging::calibration::calibrate_frame(&light, None, Some(&flat), Some(&bias))
        .expect("a float flat and a bias calibrate together");
    assert_eq!(out.as_u16().unwrap(), vec![1000; 4]);
}

fn flat_header(exposure: f64, kind: &str) -> FitsHeader {
    let mut h = FitsHeader::new();
    h.set_string("INSTRUME", "ZWO ASI1600MM-Cool");
    h.set_string("FILTER", "B");
    h.set_string("IMAGETYP", kind);
    h.set_float("GAIN", 76.0);
    h.set_float("OFFSET", 15.0);
    h.set_float("EXPTIME", exposure);
    h
}

/// Skotiq's flat capture sets the exposure frame by frame. With a bias, each
/// flat is scaled to its own median, so flats of different exposure and level
/// make one unit-mean master that records the bias was removed.
#[test]
fn a_master_flat_combines_auto_exposed_flats() {
    let dir = scratch("autoexp");
    let (w, h) = (48u32, 48u32);
    let mut paths = Vec::new();
    for (i, (t, level)) in [(0.00978, 20000.0), (0.01077, 22000.0), (0.01129, 23000.0)]
        .iter()
        .enumerate()
    {
        // A vignetted response at a level that follows the exposure.
        let px: Vec<f64> = (0..w * h)
            .map(|k| {
                let (x, y) = ((k % w) as f64 - 24.0, (k / w) as f64 - 24.0);
                200.0 + level * (1.0 - 0.0002 * (x * x + y * y))
            })
            .collect();
        let p = dir.join(format!("f{i}.fits"));
        write_u16(&p, w, h, &px, &flat_header(*t, "FLAT"));
        paths.push(p);
    }
    let bp = dir.join("bias.fits");
    write_fits(
        &bp,
        &ImageData::from_u16(w, h, 1, &vec![200; (w * h) as usize]),
        &flat_header(0.001, "Bias"),
    )
    .unwrap();
    let out = dir.join("master.fits");
    let r = api_build_master_flat(
        serde_json::json!({"flatPaths":paths,"biasOrDarkFlat":bp,"outputPath":out}).to_string(),
    )
    .expect("auto-exposed flats with a bias build a master");
    let v: serde_json::Value = serde_json::from_str(&r).unwrap();
    assert_eq!(v["frameCount"], 3, "{v}");
    let (master, header) = read_fits(&out).unwrap();
    let px = image_to_f64(&master);
    let mean = px.iter().sum::<f64>() / px.len() as f64;
    assert!((mean - 1.0).abs() < 1e-3, "unit mean, got {mean}");
    // The vignetting shape survives: the corner is dimmer than the centre.
    assert!(px[0] < px[(24 * w + 24) as usize] * 0.9);
    assert_eq!(header.get_bool("PEDSUB"), Some(true));

    // Without a pedestal the flats' bias would scale with them: refused.
    let r = api_build_master_flat(
        serde_json::json!({"flatPaths":paths,"outputPath":dir.join("m2.fits")}).to_string(),
    );
    assert!(r.unwrap_err().contains("different exposures"));
    std::fs::remove_dir_all(dir).ok();
}

/// A raw flat whose bottom rows read at the bias level (a truncated readout)
/// is left out of the master and reported.
#[test]
fn a_banded_raw_flat_is_left_out_of_the_master() {
    let dir = scratch("banded");
    let (w, h) = (64u32, 64u32);
    let mut paths = Vec::new();
    for i in 0..3 {
        let px: Vec<f64> = (0..w * h)
            .map(|k| {
                if i == 1 && k / w >= 56 {
                    368.0
                } else {
                    30000.0
                }
            })
            .collect();
        let p = dir.join(format!("f{i}.fits"));
        write_u16(&p, w, h, &px, &flat_header(0.01, "FLAT"));
        paths.push(p);
    }
    let bp = dir.join("bias.fits");
    write_fits(
        &bp,
        &ImageData::from_u16(w, h, 1, &vec![300; (w * h) as usize]),
        &flat_header(0.001, "Bias"),
    )
    .unwrap();
    let r = api_build_master_flat(
        serde_json::json!({"flatPaths":paths,"biasOrDarkFlat":bp,"outputPath":dir.join("m.fits")})
            .to_string(),
    )
    .unwrap();
    let v: serde_json::Value = serde_json::from_str(&r).unwrap();
    assert_eq!(v["frameCount"], 2, "{v}");
    assert_eq!(
        v["excluded"][0]["path"],
        paths[1].to_string_lossy().as_ref()
    );
    assert!(v["excluded"][0]["reason"]
        .as_str()
        .unwrap()
        .contains("rows"));
    std::fs::remove_dir_all(dir).ok();
}

/// Cross-filter registration where star brightness ranks differ between
/// filters (each star has its own color), with a meridian flip and a dither.
#[test]
fn cross_filter_registration_with_shuffled_ranks() {
    let (w, h) = (640u32, 480u32);
    let dir = scratch("xfilter");
    let grid = write_u16(
        &dir.join("L.fits"),
        w,
        h,
        &render(w, h, 160, 900.0, 6.0, (0.0, 0.0), false, 1, 0),
        &light_header("L"),
    );
    let mut lights = Vec::new();
    for (i, (shift, flip)) in [
        ((3.0, -2.0), false),
        ((-4.5, 2.5), true),
        ((1.2, 5.3), true),
    ]
    .iter()
    .enumerate()
    {
        let p = write_u16(
            &dir.join(format!("R{i}.fits")),
            w,
            h,
            &render(w, h, 160, 700.0, 6.0, *shift, *flip, 10 + i as u64, 99),
            &light_header("R"),
        );
        lights.push(serde_json::json!({"path":p,"exposureSec":120}));
    }
    let r = api_master_accumulate(
        serde_json::json!({
            "op":"build","filter":"R","target":"T",
            "gridReference":{"path":grid,"calibration":{}},
            "normalizationReference":{"path":lights[0]["path"],"calibration":{}},
            "groups":[{"label":"n","calibration":{},"lights":lights}],
            "minOverlap":0.9,"maxEccentricity":0.7,
            "settings":{"align":{"model":"affine","resampler":"lanczos3"},
                        "weighting":{"enabled":true,"formula":"snrSquared"},
                        "normalization":{"enabled":true,"mode":"global"}},
            "masterFitsPath":dir.join("R.master.fits"),
            "coverageFitsPath":dir.join("R.cov.fits")
        })
        .to_string(),
    );
    std::fs::remove_dir_all(dir).ok();
    let v: serde_json::Value = serde_json::from_str(&r.unwrap()).unwrap();
    assert_eq!(v["frameCount"], 3, "{v}");
}

fn low_background_build(cosmetic: bool) {
    let (w, h) = (640u32, 480u32);
    let dir = scratch(if cosmetic { "lowsky_cc" } else { "lowsky" });
    let bias_v = 300.0;
    let bias = dir.join("bias.fits");
    write_fits(
        &bias,
        &ImageData::from_u16(w, h, 1, &vec![bias_v as u16; (w * h) as usize]),
        &FitsHeader::new(),
    )
    .unwrap();
    let cal = serde_json::json!({"bias":bias,"cosmeticCorrection":cosmetic});
    let sky_above_bias = 21.0; // 3.5 sigma with noise 6
    let grid = write_u16(
        &dir.join("Ha0.fits"),
        w,
        h,
        &render(
            w,
            h,
            160,
            bias_v + sky_above_bias,
            6.0,
            (0.0, 0.0),
            false,
            1,
            0,
        ),
        &light_header("Ha"),
    );
    let mut lights = vec![serde_json::json!({"path":grid,"exposureSec":300})];
    for i in 1..4 {
        let p = write_u16(
            &dir.join(format!("Ha{i}.fits")),
            w,
            h,
            &render(
                w,
                h,
                160,
                bias_v + sky_above_bias,
                6.0,
                (2.0 * i as f64, -1.5 * i as f64),
                false,
                10 + i,
                0,
            ),
            &light_header("Ha"),
        );
        lights.push(serde_json::json!({"path":p,"exposureSec":300}));
    }
    let build = api_master_accumulate(
        serde_json::json!({
            "op":"build","filter":"Ha","target":"T",
            "gridReference":{"path":grid,"calibration":cal},
            "normalizationReference":{"path":grid,"calibration":cal},
            "groups":[{"label":"n","calibration":cal,"lights":lights}],
            "minOverlap":0.9,"maxEccentricity":0.7,
            "settings":{"align":{"model":"affine","resampler":"lanczos3"},
                        "weighting":{"enabled":true,"formula":"snrSquared"},
                        "normalization":{"enabled":true,"mode":"global"}},
            "masterFitsPath":dir.join("Ha.master.fits"),
            "coverageFitsPath":dir.join("Ha.cov.fits")
        })
        .to_string(),
    )
    .unwrap();
    let v: serde_json::Value = serde_json::from_str(&build).unwrap();
    assert_eq!(v["frameCount"], 4, "{v}");
    let (cov, ch) = read_fits(&dir.join("Ha.cov.fits")).unwrap();
    let n = ch.get_int("NFRAMES").unwrap() as f64;
    let c = image_to_f64(&cov);
    let holes = (20..(h as usize - 20))
        .flat_map(|y| (20..(w as usize - 20)).map(move |x| (y, x)))
        .filter(|&(y, x)| c[y * w as usize + x] < n)
        .count();
    // The master keeps the faint sky: its median sits near the 21 ADU above
    // bias, neither clipped toward zero nor carrying the calibration pedestal.
    let (master, _) = read_fits(&dir.join("Ha.master.fits")).unwrap();
    let mut m = image_to_f64(&master);
    m.sort_by(f64::total_cmp);
    let sky = m[m.len() / 2];
    let r = api_master_accumulate(
        serde_json::json!({"op":"deliverUniform",
            "masters":[{"path":v["masterPath"],"coveragePath":v["coveragePath"],"filter":"Ha"}],
            "outputDir":dir.join("export")})
        .to_string(),
    );
    std::fs::remove_dir_all(dir).ok();
    assert_eq!(
        holes, 0,
        "coverage comes from the warp, not from pixel values"
    );
    assert!((sky - sky_above_bias).abs() < 1.5, "sky {sky}");
    let r: serde_json::Value =
        serde_json::from_str(&r.expect("the common crop keeps the field")).unwrap();
    assert!(r["retainedArea"].as_f64().unwrap() > 0.95, "{r}");
}

/// Narrowband-like frames whose calibrated sky sits a few sigma above zero.
/// Integer calibration clipped their noise at zero and the zero samples read
/// as coverage holes; float calibration and geometric coverage keep the field.
#[test]
fn a_low_background_build_keeps_full_coverage() {
    low_background_build(false);
}

#[test]
fn a_low_background_build_with_cosmetic_correction_keeps_full_coverage() {
    low_background_build(true);
}

/// Eight subs, the first with a satellite trail across row 120, integrated in
/// the given order.
fn satellite_build(dir: &Path, reversed: bool) -> Vec<f64> {
    let (w, h) = (320u32, 240u32);
    let mut lights = Vec::new();
    for i in 0..8 {
        let mut px = render(w, h, 80, 1000.0, 10.0, (0.0, 0.0), false, 50 + i as u64, 0);
        if i == 0 {
            for x in 0..w as usize {
                px[120 * w as usize + x] += 20000.0;
            }
        }
        lights.push(serde_json::json!({
            "path": write_u16(&dir.join(format!("s{i}.fits")), w, h, &px, &light_header("L")),
            "exposureSec": 60
        }));
    }
    let reference = lights[3].clone();
    if reversed {
        lights.reverse();
    }
    let master = dir.join(format!("m{reversed}.fits"));
    api_master_accumulate(
        serde_json::json!({
            "op":"build","filter":"L",
            "gridReference":{"path":reference["path"],"calibration":{}},
            "normalizationReference":{"path":reference["path"],"calibration":{}},
            "groups":[{"label":"n","calibration":{},"lights":lights}],
            "minOverlap":0.9,
            "settings":{"align":{"model":"similarity","resampler":"lanczos3"},
                        "weighting":{"enabled":false},
                        "normalization":{"enabled":true,"mode":"global"}},
            "masterFitsPath":master
        })
        .to_string(),
    )
    .unwrap();
    image_to_f64(&read_fits(&master).unwrap().0)
}

/// The batch rejection removes a satellite trail in the first sub, and the
/// result does not depend on the order of the subs.
#[test]
fn a_satellite_in_the_first_sub_is_rejected() {
    let dir = scratch("satellite");
    let first = satellite_build(&dir, false);
    let last = satellite_build(&dir, true);
    std::fs::remove_dir_all(&dir).ok();
    let mut row: Vec<f64> = first[120 * 320 + 10..120 * 320 + 310].to_vec();
    row.sort_by(f64::total_cmp);
    let trail = row[row.len() / 2];
    assert!(trail < 1000.0 + 50.0, "trail row median {trail}");
    let worst = first
        .iter()
        .zip(&last)
        .map(|(a, b)| (a - b).abs())
        .fold(0.0, f64::max);
    assert!(worst < 1e-2, "order changed a pixel by {worst}");
}

/// A build whose every sub fails reports the filter and every reason as a
/// typed outcome, so the caller can skip that filter and keep the others.
#[test]
fn a_filter_with_no_usable_sub_reports_a_typed_outcome() {
    let dir = scratch("nosubs");
    let (w, h) = (320u32, 240u32);
    let grid = write_u16(
        &dir.join("g.fits"),
        w,
        h,
        &render(w, h, 80, 1000.0, 10.0, (0.0, 0.0), false, 1, 0),
        &light_header("L"),
    );
    let small = write_u16(
        &dir.join("small.fits"),
        200,
        100,
        &render(200, 100, 30, 1000.0, 10.0, (0.0, 0.0), false, 2, 0),
        &light_header("R"),
    );
    let err = api_master_accumulate(
        serde_json::json!({
            "op":"build","filter":"R",
            "gridReference":{"path":grid,"calibration":{}},
            "normalizationReference":{"path":grid,"calibration":{}},
            "groups":[{"label":"n","calibration":{},"lights":[{"path":small,"exposureSec":60}]}],
            "masterFitsPath":dir.join("m.fits")
        })
        .to_string(),
    )
    .unwrap_err();
    std::fs::remove_dir_all(dir).ok();
    let v: serde_json::Value = serde_json::from_str(&err).expect(&err);
    assert_eq!(v["kind"], NO_SUBS_KIND);
    assert_eq!(v["filter"], "R");
    assert_eq!(v["skipped"][0]["stage"], "geometry");
}

/// Full-size ASI1600 frames through the build. Run explicitly in release mode
/// with `RV_FRAMES` set, under `/usr/bin/time -v` for the peak memory.
#[test]
#[ignore]
fn full_size_build_timing() {
    let (w, h) = (4656u32, 3520u32);
    let n: usize = std::env::var("RV_FRAMES")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(4);
    let dir = scratch("fullsize");
    let bias_v = 200.0;
    let bias = dir.join("bias.fits");
    write_fits(
        &bias,
        &ImageData::from_f32(w, h, 1, &vec![bias_v as f32; (w * h) as usize]),
        &FitsHeader::new(),
    )
    .unwrap();
    let flat = dir.join("flat.fits");
    write_fits(
        &flat,
        &ImageData::from_f32(w, h, 1, &vec![1.0f32; (w * h) as usize]),
        &FitsHeader::new(),
    )
    .unwrap();
    let cal = serde_json::json!({"bias":bias,"flat":flat,"cosmeticCorrection":true});
    let mut lights = Vec::new();
    for i in 0..n {
        let p = write_u16(
            &dir.join(format!("L{i}.fits")),
            w,
            h,
            &render(
                w,
                h,
                2500,
                bias_v + 3000.0,
                40.0,
                (3.0 * i as f64, -2.0 * i as f64),
                false,
                100 + i as u64,
                0,
            ),
            &light_header("L"),
        );
        lights.push(serde_json::json!({"path":p,"exposureSec":90}));
    }
    let formula = std::env::var("RV_FORMULA").unwrap_or_else(|_| "snrSquared".into());
    let t = std::time::Instant::now();
    let r = api_master_accumulate(
        serde_json::json!({
            "op":"build","filter":"L","target":"T",
            "gridReference":{"path":lights[0]["path"],"calibration":cal},
            "normalizationReference":{"path":lights[0]["path"],"calibration":cal},
            "groups":[{"label":"n","calibration":cal,"lights":lights}],
            "minOverlap":0.95,"maxEccentricity":0.65,"validateFlats":true,
            "settings":{"align":{"model":"affine","resampler":"lanczos3"},
                        "weighting":{"enabled":true,"formula":formula},
                        "normalization":{"enabled":true,"mode":"global"}},
            "masterFitsPath":dir.join("L.master.fits"),
            "coverageFitsPath":dir.join("L.cov.fits")
        })
        .to_string(),
    );
    let elapsed = t.elapsed();
    println!(
        "build of {n} full-size frames took {elapsed:?} ({:.2} s per frame)",
        elapsed.as_secs_f64() / n as f64
    );
    if let Err(e) = &r {
        println!("error {e}");
    }
    std::fs::remove_dir_all(dir).ok();
    assert!(r.is_ok());
}

/// The REST-style accumulating add, one full-size sub per call. Run
/// explicitly in release mode.
#[test]
#[ignore]
fn full_size_add_per_call_timing() {
    let (w, h) = (4656u32, 3520u32);
    let n: usize = std::env::var("RV_FRAMES")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(3);
    let dir = scratch("addcall");
    let mut lights = Vec::new();
    for i in 0..=n {
        lights.push(write_u16(
            &dir.join(format!("L{i}.fits")),
            w,
            h,
            &render(
                w,
                h,
                2500,
                3200.0,
                40.0,
                (3.0 * i as f64, -2.0 * i as f64),
                false,
                100 + i as u64,
                0,
            ),
            &light_header("L"),
        ));
    }
    let sidecar = dir.join("L.nsm");
    api_master_accumulate(
        serde_json::json!({"op":"create","referencePath":lights[0],"sidecarPath":sidecar})
            .to_string(),
    )
    .unwrap();
    for (i, p) in lights.iter().enumerate().skip(1) {
        let t = std::time::Instant::now();
        let r = api_master_accumulate(
            serde_json::json!({
                "op":"add","sidecarPath":sidecar,"lightPaths":[p],"exposuresSec":[90],"label":"n",
                "settings":{"align":{"model":"affine","resampler":"lanczos3"},
                            "weighting":{"enabled":true,"formula":"snrSquared"},
                            "normalization":{"enabled":true,"mode":"global"}}})
            .to_string(),
        );
        println!("add call {i} took {:?} ok={}", t.elapsed(), r.is_ok());
        if let Err(e) = &r {
            println!("error {e}");
        }
    }
    let t = std::time::Instant::now();
    let r = api_master_accumulate(
        serde_json::json!({"op":"finalize","sidecarPath":sidecar,"masterFitsPath":dir.join("m.fits")})
            .to_string(),
    );
    println!("finalize took {:?} ok={}", t.elapsed(), r.is_ok());
    std::fs::remove_dir_all(dir).ok();
}
