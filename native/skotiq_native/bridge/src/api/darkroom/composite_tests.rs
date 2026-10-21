//! The color composite through the Darkroom entry points: planning,
//! drafting, rendering and exporting over per-filter masters written to disk.

use std::path::{Path, PathBuf};

use serde_json::{json, Value};
use skotiq_imaging::{read_fits, write_fits, FitsHeader, ImageData};

use super::{api_darkroom_registry, api_darkroom_render_export, api_darkroom_render_preview};

const W: u32 = 512;
const H: u32 = 384;

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

/// One star of the scene: reference position and red, green, blue flux.
#[derive(Clone, Copy)]
struct Star {
    x: f64,
    y: f64,
    rgb: [f64; 3],
}

fn field() -> Vec<Star> {
    let mut rng = Lcg(0xC0_10_57);
    (0..140)
        .map(|_| {
            let flux = 4_000.0 * 10f64.powf(rng.unit() * 1.4);
            let t = rng.unit();
            Star {
                x: 24.0 + rng.unit() * (W as f64 - 48.0),
                y: 24.0 + rng.unit() * (H as f64 - 48.0),
                rgb: [flux * (1.3 - 0.6 * t), flux, flux * (0.6 + 0.7 * t)],
            }
        })
        .collect()
}

/// Write one filter's master: the field shifted by `(dx, dy)`, each star's
/// flux weighted by `weights`, over `pedestal`.
fn write_filter(
    dir: &Path,
    filter: &str,
    stars: &[Star],
    weights: [f64; 3],
    shift: (f64, f64),
    pedestal: f64,
    seed: u64,
) -> PathBuf {
    let mut rng = Lcg(seed);
    let mut data: Vec<f32> = (0..W * H)
        .map(|_| (pedestal + 8.0 * rng.normal()) as f32)
        .collect();
    let sigma = 1.6_f64;
    for star in stars {
        let (sx, sy) = (star.x - shift.0, star.y - shift.1);
        let flux = weights[0] * star.rgb[0] + weights[1] * star.rgb[1] + weights[2] * star.rgb[2];
        let norm = flux / (2.0 * std::f64::consts::PI * sigma * sigma);
        for y in (sy as i64 - 7)..=(sy as i64 + 7) {
            for x in (sx as i64 - 7)..=(sx as i64 + 7) {
                if x < 0 || y < 0 || x >= W as i64 || y >= H as i64 {
                    continue;
                }
                let r2 = (x as f64 - sx).powi(2) + (y as f64 - sy).powi(2);
                data[(y as u32 * W + x as u32) as usize] +=
                    (norm * (-r2 / (2.0 * sigma * sigma)).exp()) as f32;
            }
        }
    }
    let mut header = FitsHeader::new();
    header.set_string("OBJECT", "NGC 891");
    header.set_string("FILTER", filter);
    header.set_float("EXPTIME", 1800.0);
    let path = dir.join(format!("{filter}_master.fits"));
    write_fits(&path, &ImageData::from_f32(W, H, 1, &data), &header).expect("write master");
    path
}

/// L, R, G and B masters of one field, each on its own offset.
fn lrgb_masters(dir: &Path) -> (Vec<Star>, Vec<PathBuf>) {
    let stars = field();
    let paths = vec![
        write_filter(
            dir,
            "Luminance",
            &stars,
            [0.8, 0.8, 0.8],
            (0.0, 0.0),
            5500.0,
            1,
        ),
        write_filter(dir, "Red", &stars, [1.0, 0.0, 0.0], (18.4, 7.2), 2500.0, 2),
        write_filter(
            dir,
            "Green",
            &stars,
            [0.0, 1.0, 0.0],
            (2.3, -6.1),
            2300.0,
            3,
        ),
        write_filter(dir, "Blue", &stars, [0.0, 0.0, 1.0], (16.7, 9.6), 4000.0, 4),
    ];
    (stars, paths)
}

fn draft_composite(paths: &[PathBuf]) -> Value {
    let inputs: Vec<Value> = paths
        .iter()
        .map(|p| json!({"path": p.to_string_lossy()}))
        .collect();
    let reply = api_darkroom_registry(
        json!({"recipeId": "composite-test", "composite": {"inputs": inputs}}).to_string(),
    )
    .expect("the composite drafts");
    serde_json::from_str(&reply).expect("a JSON reply")
}

#[test]
fn an_lrgb_set_drafts_a_registered_color_composite() {
    let dir = tempfile::tempdir().expect("temp dir");
    let (_, paths) = lrgb_masters(dir.path());
    let reply = draft_composite(&paths);

    let composite = &reply["composite"];
    assert_eq!(composite["combined"], true, "{composite}");
    assert_eq!(composite["palette"], "lrgb");
    assert_eq!(composite["reference"]["filter"], "Luminance");
    assert_eq!(composite["alternatives"][0]["palette"], "rgb");
    assert_eq!(reply["masterPath"], json!(paths[0].to_string_lossy()));
    let inputs = composite["inputs"].as_array().expect("inputs");
    assert_eq!(inputs.len(), 3);
    for input in inputs {
        let check = &input["check"];
        assert!(
            check["medianOffsetPx"].as_f64().expect("a check") < 0.3,
            "{input}"
        );
    }
    let red = inputs
        .iter()
        .find(|i| i["filter"] == "Red")
        .expect("the red master");
    let shift = red["shiftPx"].as_array().unwrap();
    assert!((shift[0].as_f64().unwrap() - 18.4).abs() < 0.1, "{red}");
    assert!((shift[1].as_f64().unwrap() - 7.2).abs() < 0.1, "{red}");

    let steps: Vec<&str> = reply["draft"]["recipe"]["steps"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["opId"].as_str().unwrap())
        .collect();
    assert_eq!(
        steps,
        [
            "channel_combine",
            "color_calibrate",
            "chroma_denoise",
            "scnr",
            "denoise",
            "stretch",
            "saturation"
        ]
    );
    let combine = &reply["draft"]["recipe"]["steps"][0]["params"];
    assert!(combine["fits"]["luminanceToRgb"]["scale"].as_f64().unwrap() > 0.0);
    // Every master's surfaces were measured at full resolution and pinned, so a
    // preview replays them instead of fitting a coarse level.
    // This small scene leaves some planes too few clean sky boxes for a
    // surface, and those are left out rather than fitted to noise.
    let flatten = &combine["flatten"];
    assert!(
        flatten["background"]["luminance"]["coefficients"].is_array(),
        "{flatten}"
    );
    for (_, surface) in flatten["background"].as_object().unwrap() {
        assert!(surface["degree"].is_u64(), "{flatten}");
    }
    assert!(flatten["throughput"].is_object(), "{flatten}");
    assert_eq!(flatten["chromaBox"], 64.0);
    let stretch = &reply["draft"]["recipe"]["steps"][5]["params"];
    assert_eq!(stretch["colorMode"], "luminance");
    assert_eq!(stretch["b"], 1.0);
    assert_eq!(
        reply["draft"]["recipe"]["steps"][1]["params"]["neutralizeBackground"],
        true
    );
    assert_eq!(
        reply["draft"]["recipe"]["steps"][4]["params"]["chromaStrength"],
        0.0
    );
    let notes = reply["draft"]["notes"].as_array().unwrap();
    assert!(notes
        .iter()
        .any(|n| n["opId"] == "background_extract" && n["outcome"] == "omitted"));
}

#[test]
fn the_composite_renders_in_color_and_exports_its_master() {
    let dir = tempfile::tempdir().expect("temp dir");
    let (stars, paths) = lrgb_masters(dir.path());
    let reply = draft_composite(&paths);
    let recipe = reply["draft"]["recipe"].clone();
    let master = reply["masterPath"].as_str().unwrap().to_string();

    let preview = api_darkroom_render_preview(
        recipe.to_string(),
        json!({"masterPath": master, "maxDimension": 128, "encoding": "screen"}).to_string(),
    )
    .expect("the preview renders with the other masters loaded");
    assert!(preview.is_color);
    let report: Value = serde_json::from_str(&preview.report_json).unwrap();
    assert_eq!(report["report"]["steps"][0]["outcome"], "applied");

    // The linear composite, exported after the combination step: every
    // isolated bright star keeps the color it was given.
    let linear = dir.path().join("composite.fits");
    api_darkroom_render_export(
        recipe.to_string(),
        json!({
            "masterPath": master,
            "stage": {"kind": "afterStep", "index": 0},
            "outputs": [{"format": "fits", "path": linear.to_string_lossy()}],
            "writeSidecar": false,
        })
        .to_string(),
    )
    .expect("the linear composite exports");
    let (image, header) = read_fits(&linear).expect("read back");
    assert_eq!(image.channels, 3);
    assert_eq!(header.get_string("FILTER"), Some("LRGB"));
    let crop = &reply["composite"]["crop"];
    let (cx, cy) = (crop["x"].as_f64().unwrap(), crop["y"].as_f64().unwrap());
    let data = image.as_f32().expect("float pixels");
    let (w, h) = (image.width as i64, image.height as i64);
    let aperture = |c: usize, x: f64, y: f64| {
        let (mut inner, mut n, mut ring) = (0.0, 0.0, Vec::new());
        for py in (y as i64 - 12)..=(y as i64 + 12) {
            for px in (x as i64 - 12)..=(x as i64 + 12) {
                if px < 0 || py < 0 || px >= w || py >= h {
                    continue;
                }
                let r = ((px as f64 - x).powi(2) + (py as f64 - y).powi(2)).sqrt();
                let v = data[((py * w + px) * 3) as usize + c] as f64;
                if r <= 6.0 {
                    inner += v;
                    n += 1.0;
                } else if r >= 9.0 {
                    ring.push(v);
                }
            }
        }
        ring.sort_by(f64::total_cmp);
        inner - n * ring[ring.len() / 2]
    };
    let mut checked = 0;
    for star in &stars {
        let (x, y) = (star.x - cx, star.y - cy);
        let isolated = stars.iter().all(|o| {
            let d = ((o.x - star.x).powi(2) + (o.y - star.y).powi(2)).sqrt();
            d == 0.0 || d > 16.0
        });
        if !isolated || star.rgb[1] < 15_000.0 || x < 14.0 || y < 14.0 {
            continue;
        }
        if x > w as f64 - 14.0 || y > h as f64 - 14.0 {
            continue;
        }
        let (r, g, b) = (aperture(0, x, y), aperture(1, x, y), aperture(2, x, y));
        let want = (star.rgb[0] / star.rgb[1], star.rgb[2] / star.rgb[1]);
        assert!(
            ((r / g) / want.0 - 1.0).abs() < 0.06,
            "R/G {} vs {}",
            r / g,
            want.0
        );
        assert!(
            ((b / g) / want.1 - 1.0).abs() < 0.06,
            "B/G {} vs {}",
            b / g,
            want.1
        );
        checked += 1;
    }
    assert!(checked >= 8, "only {checked} stars checked");
}

#[test]
fn a_set_missing_a_primary_is_not_combined_and_says_why() {
    let dir = tempfile::tempdir().expect("temp dir");
    let stars = field();
    let paths = vec![
        write_filter(
            dir.path(),
            "L",
            &stars,
            [0.8, 0.8, 0.8],
            (0.0, 0.0),
            5500.0,
            1,
        ),
        write_filter(
            dir.path(),
            "R",
            &stars,
            [1.0, 0.0, 0.0],
            (3.0, 1.0),
            2500.0,
            2,
        ),
        write_filter(
            dir.path(),
            "G",
            &stars,
            [0.0, 1.0, 0.0],
            (1.0, 2.0),
            2300.0,
            3,
        ),
    ];
    let reply = draft_composite(&paths);
    assert_eq!(reply["composite"]["combined"], false);
    let reason = reply["composite"]["reason"].as_str().unwrap();
    assert!(reason.contains("no B master"), "{reason}");
    assert!(reply.get("draft").is_none() || reply["draft"].is_null());
}

/// A mono master whose sky is `sky(x, y)` under the scene's stars.
///
/// The frame is twice the scene's size on each axis, so the default sample
/// lattice holds enough sky boxes to tell a degree-4 surface from noise.
fn write_sky(dir: &Path, name: &str, sky: impl Fn(f64, f64) -> f64) -> PathBuf {
    const SW: u32 = 2 * W;
    const SH: u32 = 2 * H;
    let stars = field();
    let mut rng = Lcg(77);
    let mut data: Vec<f32> = (0..SW * SH)
        .map(|i| (sky((i % SW) as f64, (i / SW) as f64) + 8.0 * rng.normal()) as f32)
        .collect();
    for star in &stars {
        let norm = star.rgb[1] / (2.0 * std::f64::consts::PI * 2.56);
        for y in (star.y as i64 - 7)..=(star.y as i64 + 7) {
            for x in (star.x as i64 - 7)..=(star.x as i64 + 7) {
                let r2 = (x as f64 - star.x).powi(2) + (y as f64 - star.y).powi(2);
                data[(y as u32 * SW + x as u32) as usize] += (norm * (-r2 / 5.12).exp()) as f32;
            }
        }
    }
    let mut header = FitsHeader::new();
    header.set_string("FILTER", "L");
    let path = dir.join(name);
    write_fits(&path, &ImageData::from_f32(SW, SH, 1, &data), &header).expect("write master");
    path
}

fn drafted_background(path: &Path) -> (Value, String) {
    let reply: Value = serde_json::from_str(
        &api_darkroom_registry(json!({"masterPath": path.to_string_lossy()}).to_string())
            .expect("drafts"),
    )
    .unwrap();
    let step = reply["draft"]["recipe"]["steps"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["opId"] == "background_extract")
        .cloned()
        .expect("a background step");
    let note = reply["draft"]["notes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["opId"] == "background_extract")
        .map(|n| n["reason"].as_str().unwrap().to_string())
        .unwrap_or_default();
    (step["params"].clone(), note)
}

#[test]
fn vignetting_earns_a_higher_background_degree_and_a_tilt_does_not() {
    let dir = tempfile::tempdir().expect("temp dir");
    // Uncorrected vignetting: a cos^4-like falloff to 60% at the corners.
    let vignetted = write_sky(dir.path(), "vignetted.fits", |x, y| {
        let (w, h) = (2.0 * W as f64, 2.0 * H as f64);
        let r2 = ((x - w / 2.0).powi(2) + (y - h / 2.0).powi(2))
            / ((w / 2.0).powi(2) + (h / 2.0).powi(2));
        3000.0 * (1.0 + 0.6 * r2).powi(-2).max(0.0) + 300.0 * (x / w)
    });
    let (params, note) = drafted_background(&vignetted);
    let order = params["modelOrder"]
        .as_u64()
        .unwrap_or_else(|| panic!("no degree: {note}"));
    assert!(order > 2, "{params} {note}");
    assert!(note.contains("not the default 2"), "{note}");

    let tilted = write_sky(dir.path(), "tilted.fits", |x, y| {
        2000.0 + 0.25 * x + 0.125 * y
    });
    let (params, note) = drafted_background(&tilted);
    assert!(params.get("modelOrder").is_none(), "{params} {note}");
    assert!(note.contains("stays at its default degree 2"), "{note}");
}
