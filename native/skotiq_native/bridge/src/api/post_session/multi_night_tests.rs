//! The multi-night master build and the PixInsight delivery, over synthetic
//! star fields written to disk.

use super::*;
use std::path::PathBuf;

const W: u32 = 384;
const H: u32 = 288;

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

/// Star positions and fluxes shared by every frame of the scene.
fn stars() -> Vec<(f64, f64, f64)> {
    let mut rng = Lcg(0x5EED);
    (0..120)
        .map(|_| {
            (
                20.0 + rng.unit() * (W as f64 - 40.0),
                20.0 + rng.unit() * (H as f64 - 40.0),
                3_000.0 * 10f64.powf(rng.unit() * 1.3),
            )
        })
        .collect()
}

/// The scene seen through one filter: star flux × `gain`, over `sky`, with
/// the field moved by `shift` and turned 180° when `flipped`.
fn render(gain: f64, sky: f64, shift: (f64, f64), flipped: bool, seed: u64) -> Vec<f64> {
    let mut rng = Lcg(seed);
    let mut px: Vec<f64> = (0..W * H).map(|_| sky + 6.0 * rng.normal()).collect();
    let sigma = 1.7_f64;
    for (x, y, flux) in stars() {
        let (mut sx, mut sy) = (x + shift.0, y + shift.1);
        if flipped {
            sx = W as f64 - 1.0 - sx;
            sy = H as f64 - 1.0 - sy;
        }
        let norm = gain * flux / (2.0 * std::f64::consts::PI * sigma * sigma);
        for yy in (sy as i64 - 7)..=(sy as i64 + 7) {
            for xx in (sx as i64 - 7)..=(sx as i64 + 7) {
                if xx < 0 || yy < 0 || xx >= W as i64 || yy >= H as i64 {
                    continue;
                }
                let r2 = (xx as f64 - sx).powi(2) + (yy as f64 - sy).powi(2);
                px[yy as usize * W as usize + xx as usize] +=
                    norm * (-r2 / (2.0 * sigma * sigma)).exp();
            }
        }
    }
    px
}

fn write_u16(path: &Path, px: &[f64]) -> String {
    let data: Vec<u16> = px
        .iter()
        .map(|v| v.round().clamp(0.0, 65535.0) as u16)
        .collect();
    let mut h = FitsHeader::new();
    h.set_string("IMAGETYP", "LIGHT");
    write_fits(path, &ImageData::from_u16(W, H, 1, &data), &h).unwrap();
    path.to_string_lossy().to_string()
}

fn write_master(path: &Path, filter: &str, px: &[f64]) -> String {
    let data: Vec<f32> = px.iter().map(|v| *v as f32).collect();
    let mut h = FitsHeader::new();
    h.set_string("IMAGETYP", "MASTER_LIGHT");
    h.set_string("FILTER", filter);
    h.set_float("EXPTIME", 3600.0);
    write_fits(path, &ImageData::from_f32(W, H, 1, &data), &h).unwrap();
    path.to_string_lossy().to_string()
}

fn scratch(name: &str) -> PathBuf {
    let n = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let dir = std::env::temp_dir().join(format!("sk_mn_{name}_{}_{n}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn median(mut v: Vec<f64>) -> f64 {
    v.sort_by(f64::total_cmp);
    v[v.len() / 2]
}

#[test]
fn a_build_folds_every_night_and_reports_what_it_skipped() {
    let dir = scratch("build");
    // The grid is an L sub; the master is R, so it normalizes to an R sub.
    let grid = write_u16(
        &dir.join("L_ref.fits"),
        &render(1.0, 900.0, (0.0, 0.0), false, 1),
    );
    let r_ref = write_u16(
        &dir.join("R_ref.fits"),
        &render(0.5, 400.0, (3.0, -2.0), false, 2),
    );
    let night1: Vec<String> = (0..3)
        .map(|i| {
            let sky = 400.0 + 30.0 * i as f64;
            let px = render(0.5, sky, (i as f64 * 4.0, 1.0), false, 10 + i);
            write_u16(&dir.join(format!("n1_R_{i}.fits")), &px)
        })
        .collect();
    let mut night2: Vec<String> = (0..2)
        .map(|i| {
            let px = render(0.5, 420.0, (-5.0, 2.0 * i as f64), true, 20 + i);
            write_u16(&dir.join(format!("n2_R_{i}.fits")), &px)
        })
        .collect();
    let cloud: Vec<f64> = (0..W * H).map(|i| 400.0 + (i % 7) as f64).collect();
    night2.push(write_u16(&dir.join("n2_R_cloud.fits"), &cloud));
    night2.push(dir.join("missing.fits").to_string_lossy().to_string());

    let lights = |paths: &[String], exposure: f64| -> Vec<serde_json::Value> {
        paths
            .iter()
            .map(|p| serde_json::json!({"path": p, "exposureSec": exposure}))
            .collect()
    };
    let master = dir.join("R_master.fits");
    let request = serde_json::json!({
        "op": "build",
        "gridReference": {"path": grid},
        "normalizationReference": {"path": r_ref},
        "groups": [
            {"label": "2026-10-20", "lights": lights(&night1, 120.0)},
            {"label": "2026-10-21", "lights": lights(&night2, 120.0)},
        ],
        "filter": "R",
        "target": "NGC0891",
        "masterFitsPath": master.to_string_lossy(),
    });
    let result: serde_json::Value =
        serde_json::from_str(&api_master_accumulate(request.to_string()).expect("build")).unwrap();

    assert_eq!(result["frameCount"], 5, "{result:#}");
    assert_eq!(result["totalIntegrationSec"], 600.0);
    let skipped = result["skipped"].as_array().unwrap();
    let stage = |name: &str| {
        skipped
            .iter()
            .find(|s| s["path"].as_str().unwrap().ends_with(name))
            .map(|s| s["stage"].as_str().unwrap().to_string())
    };
    assert_eq!(stage("n2_R_cloud.fits").as_deref(), Some("registration"));
    assert_eq!(stage("missing.fits").as_deref(), Some("read"));
    let groups = result["groups"].as_array().unwrap();
    assert_eq!(
        (groups[0]["folded"].as_u64(), groups[0]["skipped"].as_u64()),
        (Some(3), Some(0))
    );
    assert_eq!(
        (groups[1]["folded"].as_u64(), groups[1]["skipped"].as_u64()),
        (Some(2), Some(2))
    );
    let flipped = result["folded"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|f| f["rotationDeg"].as_f64().unwrap().abs() > 179.0)
        .count();
    assert_eq!(flipped, 2, "the meridian-flipped night registers");

    let (image, header) = read_fits(&master).unwrap();
    assert_eq!((image.width, image.height), (W, H));
    assert_eq!(header.get_int("NFRAMES"), Some(5));
    assert_eq!(header.get_string("FILTER"), Some("R"));
    // Normalized within the filter: the sky sits at the R reference's level,
    // not the L grid's.
    let sky = median(image.as_f32().unwrap().iter().map(|v| *v as f64).collect());
    assert!((sky - 400.0).abs() < 25.0, "master sky {sky}");
}

#[test]
fn a_build_with_no_registrable_sub_fails_with_the_reasons() {
    let dir = scratch("build_none");
    let grid = write_u16(
        &dir.join("ref.fits"),
        &render(1.0, 900.0, (0.0, 0.0), false, 1),
    );
    let blank = write_u16(&dir.join("blank.fits"), &vec![500.0; (W * H) as usize]);
    let request = serde_json::json!({
        "op": "build",
        "gridReference": {"path": grid},
        "groups": [{"label": "n", "lights": [{"path": blank, "exposureSec": 60.0}]}],
        "masterFitsPath": dir.join("m.fits").to_string_lossy(),
    });
    let err = api_master_accumulate(request.to_string()).unwrap_err();
    let outcome: serde_json::Value = serde_json::from_str(&err).expect(&err);
    assert_eq!(outcome["kind"], NO_SUBS_KIND, "{err}");
    assert_eq!(outcome["offered"], 1, "{err}");
    assert_eq!(outcome["skipped"][0]["stage"], "registration", "{err}");
    assert!(!dir.join("m.fits").exists());
}

#[test]
fn delivery_puts_every_master_on_the_luminance_grid_and_writes_planar_rgb() {
    let dir = scratch("deliver");
    let l = write_master(
        &dir.join("L.fits"),
        "L",
        &render(1.0, 900.0, (0.0, 0.0), false, 1),
    );
    // R sits on the grid already; G and B are shifted and B is flipped.
    let r = write_master(
        &dir.join("R.fits"),
        "R",
        &render(0.6, 300.0, (0.0, 0.0), false, 2),
    );
    let g = write_master(
        &dir.join("G.fits"),
        "G",
        &render(0.4, 350.0, (2.6, -4.2), false, 3),
    );
    let b = write_master(
        &dir.join("B.fits"),
        "B",
        &render(0.3, 250.0, (-1.5, 3.1), true, 4),
    );
    let out = dir.join("PixInsight");
    let request = serde_json::json!({
        "op": "deliver",
        "masters": [{"path": r}, {"path": g}, {"path": b}, {"path": l}],
        "outputDir": out.to_string_lossy(),
        "target": "NGC 891",
    });
    let result: serde_json::Value =
        serde_json::from_str(&api_master_accumulate(request.to_string()).expect("deliver"))
            .unwrap();

    assert_eq!(result["referenceFilter"], "L");
    let entry = |filter: &str| {
        result["masters"]
            .as_array()
            .unwrap()
            .iter()
            .find(|m| m["filter"] == filter)
            .unwrap()
            .clone()
    };
    assert_eq!(entry("L")["reference"], true);
    assert_eq!(entry("R")["onGrid"], true);
    for filter in ["G", "B"] {
        let m = entry(filter);
        assert_eq!(m["onGrid"], false, "{m:#}");
        assert!(m["checkMedianOffsetPx"].as_f64().unwrap() < 0.1, "{m:#}");
        assert!(m["coverage"].as_f64().unwrap() > 0.95, "{m:#}");
    }
    assert!((entry("B")["rotationDeg"].as_f64().unwrap().abs() - 180.0).abs() < 0.05);

    let rgb_path = result["rgbPath"].as_str().unwrap();
    assert!(rgb_path.ends_with("NGC_891_RGB_linear.fits"), "{rgb_path}");
    let (rgb, _) = read_fits(Path::new(rgb_path)).unwrap();
    assert_eq!(rgb.channels, 3);
    let header = read_fits_header(Path::new(rgb_path)).unwrap();
    assert_eq!(header.get_string("SKLAYOUT"), Some("PLANAR"));
    // The brightest star of the scene, at its L-grid position, is brightest in
    // every plane: the planes are registered and in R, G, B order.
    let (sx, sy, _) = stars()
        .into_iter()
        .max_by(|a, b| a.2.total_cmp(&b.2))
        .unwrap();
    let samples = rgb.as_f32().unwrap();
    let at = |x: f64, y: f64, c: usize| {
        samples[((y.round() as usize) * W as usize + x.round() as usize) * 3 + c] as f64
    };
    let sky = |c: usize| at(5.0, 5.0, c);
    for c in 0..3 {
        assert!(
            at(sx, sy, c) > sky(c) + 0.01,
            "channel {c} has no star at the L position"
        );
    }
    // Linear scale preserved: the sky levels keep the masters' R:G:B ratio.
    assert!(
        (sky(0) * 65535.0 - 300.0).abs() < 30.0,
        "R sky {}",
        sky(0) * 65535.0
    );
    assert!(
        (sky(2) * 65535.0 - 250.0).abs() < 30.0,
        "B sky {}",
        sky(2) * 65535.0
    );
}

#[test]
fn star_signal_weighting_follows_the_stars_not_the_background() {
    let dir = scratch("weights");
    let reference = write_u16(
        &dir.join("ref.fits"),
        &render(1.0, 900.0, (0.0, 0.0), false, 1),
    );
    let clear = write_u16(
        &dir.join("clear.fits"),
        &render(1.0, 900.0, (2.0, 1.0), false, 2),
    );
    // Thin cloud: every star at a third of its flux.
    let cloud = write_u16(
        &dir.join("cloud.fits"),
        &render(0.33, 900.0, (1.0, 2.0), false, 3),
    );
    // A dark silhouette rising over the lower third: the frame-statistics SNR
    // reads the spread between dark and bright sky as signal.
    let mut tree_px = render(1.0, 900.0, (-1.0, 1.0), false, 4);
    for (i, v) in tree_px.iter_mut().enumerate() {
        if i / W as usize > (2 * H / 3) as usize {
            *v = 150.0 + (*v - 900.0) * 0.05;
        }
    }
    let tree = write_u16(&dir.join("tree.fits"), &tree_px);
    let weights = |formula: &str| -> std::collections::HashMap<String, f64> {
        let request = serde_json::json!({
            "op": "build",
            "gridReference": {"path": reference},
            "groups": [{"label": "n", "lights": [
                {"path": clear, "exposureSec": 60.0},
                {"path": cloud, "exposureSec": 60.0},
                {"path": tree, "exposureSec": 60.0},
            ]}],
            "settings": {"weighting": {"formula": formula}},
            "masterFitsPath": dir.join(format!("{formula}.fits")).to_string_lossy(),
        });
        let result: serde_json::Value =
            serde_json::from_str(&api_master_accumulate(request.to_string()).unwrap()).unwrap();
        result["folded"]
            .as_array()
            .unwrap()
            .iter()
            .map(|f| {
                let name = Path::new(f["path"].as_str().unwrap())
                    .file_stem()
                    .unwrap()
                    .to_string_lossy()
                    .to_string();
                (name, f["weight"].as_f64().unwrap())
            })
            .collect()
    };
    let star = weights(STAR_SIGNAL_FORMULA);
    assert!((star["clear"] - 1.0).abs() < 0.2, "{star:?}");
    assert!(star["cloud"] < 0.2 * star["clear"], "{star:?}");
    assert!(star["tree"] < 1.2 * star["clear"], "{star:?}");
    // The frame-statistics weighting rates the silhouette above the clear sky.
    let snr = weights("snrSquared");
    assert!(snr["tree"] > snr["clear"], "{snr:?}");
}

/// Run `api_master_accumulate` on the JSON request in `$MN_REQUEST` and print
/// the result, for checking a build or a delivery against real frames.
#[test]
#[ignore = "needs real frames; set MN_REQUEST to a request JSON file"]
fn multi_night_request_from_file() {
    let path = std::env::var("MN_REQUEST").expect("set MN_REQUEST");
    let request = std::fs::read_to_string(&path).expect("read MN_REQUEST");
    let started = std::time::Instant::now();
    let result = api_master_accumulate(request);
    eprintln!("[mn] {:.1} s", started.elapsed().as_secs_f64());
    match result {
        Ok(json) => println!("{json}"),
        Err(e) => panic!("[mn] failed: {e}"),
    }
}

#[test]
fn guided_build_handles_bias_float_flat_bad_first_frame_and_common_export() {
    let dir = scratch("guided_reference_path_longer_than_one_fits_header_card");
    let grid = write_u16(
        &dir.join("L.fits"),
        &render(1.0, 900.0, (0.0, 0.0), false, 70),
    );
    let red = write_u16(
        &dir.join("R.fits"),
        &render(0.6, 700.0, (2.0, 1.0), false, 71),
    );
    let shifted = write_u16(
        &dir.join("shifted.fits"),
        &render(0.6, 700.0, (60.0, 0.0), false, 72),
    );
    let bias = write_u16(&dir.join("bias.fits"), &vec![100.0; (W * H) as usize]);
    let flat = dir.join("flat.fits");
    write_fits(
        &flat,
        &ImageData::from_f32(W, H, 1, &vec![1.0; (W * H) as usize]),
        &FitsHeader::new(),
    )
    .unwrap();
    let calibration = serde_json::json!({"bias":bias,"flat":flat});
    let checked = api_master_accumulate(
        serde_json::json!({"op":"checkCalibration","path":grid,"calibration":calibration})
            .to_string(),
    );
    assert!(checked.is_ok(), "{checked:?}");
    let mut outputs = Vec::new();
    for (filter, good) in [("L", &grid), ("R", &red)] {
        let result: serde_json::Value = serde_json::from_str(&api_master_accumulate(serde_json::json!({
            "op":"build","filter":filter,"target":"Test","gridReference":{"path":grid,"calibration":calibration},
            "normalizationReference":{"path":shifted,"calibration":calibration},
            "groups":[{"label":"night","calibration":calibration,"lights":[{"path":shifted,"exposureSec":90},{"path":good,"exposureSec":90}]}],
            "minOverlap":0.95,"maxEccentricity":0.7,"validateFlats":true,
            "masterFitsPath":dir.join(format!("{filter}.master.fits")),"coverageFitsPath":dir.join(format!("{filter}.coverage.fits"))
        }).to_string()).unwrap()).unwrap();
        assert_eq!(result["frameCount"], 1, "{result}");
        assert_eq!(result["skipped"][0]["stage"], "framing", "{result}");
        outputs.push(serde_json::json!({"filter":filter,"path":result["masterPath"],"coveragePath":result["coveragePath"]}));
    }
    let exported: serde_json::Value = serde_json::from_str(&api_master_accumulate(serde_json::json!({"op":"deliverUniform","masters":outputs,"outputDir":dir.join("export")}).to_string()).unwrap()).unwrap();
    let width = exported["width"].as_u64().unwrap();
    assert!(width < W as u64 && width > W as u64 * 9 / 10);
    assert_eq!(exported["masters"].as_array().unwrap().len(), 2);
    for master in exported["masters"].as_array().unwrap() {
        let (image, _) = read_fits(Path::new(master["path"].as_str().unwrap())).unwrap();
        assert_eq!(image.width as u64, width);
        assert!(image_to_f64(&image)
            .iter()
            .all(|v| v.is_finite() && (0.0..=1.0).contains(v)));
    }
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn guided_preflight_blocks_obstructed_flat_but_accepts_advisory_gain() {
    let dir = scratch("flat_check");
    let light = dir.join("light.fits");
    let flat = dir.join("flat.fits");
    let mut h = FitsHeader::new();
    h.set_int("GAIN", 76);
    write_fits(
        &light,
        &ImageData::from_u16(W, H, 1, &vec![1000; (W * H) as usize]),
        &h,
    )
    .unwrap();
    h.set_int("GAIN", 100);
    write_fits(
        &flat,
        &ImageData::from_f32(W, H, 1, &vec![1.0; (W * H) as usize]),
        &h,
    )
    .unwrap();
    let args =
        serde_json::json!({"op":"checkCalibration","path":light,"calibration":{"flat":flat}})
            .to_string();
    assert!(api_master_accumulate(args.clone()).is_ok());
    let mut pixels = vec![1.0; (W * H) as usize];
    pixels[..(W * H / 10) as usize].fill(0.01);
    write_fits(&flat, &ImageData::from_f32(W, H, 1, &pixels), &h).unwrap();
    assert!(api_master_accumulate(args)
        .unwrap_err()
        .contains("possible obstruction"));
    std::fs::remove_dir_all(dir).unwrap();
}
