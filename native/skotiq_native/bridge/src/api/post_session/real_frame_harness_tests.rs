//! An opt-in driver that runs the production stacking path over real frames.
//!
//! This is not a CI assertion — it is a validation harness. It calls
//! [`api_integrate_session`], the *same* entry point the Dart bridge calls, so
//! the run exercises real reference selection, registration, normalization,
//! rejection and weighting rather than a reimplementation of them. It exists so
//! the normalization estimator can be checked against genuine sub-frames
//! without building the Flutter app or occupying the D1 harness.
//!
//! `#[ignore]`d by default: it needs input frames that are not in the repo, and
//! it is far too slow for the normal suite.
//!
//! ```text
//! NORMFIX_CAPTURES=/path/to/captures \
//! NORMFIX_OUT=/path/to/workdir \
//! NORMFIX_FILTERS=L,R,G,B \
//!   cargo test -p skotiq_bridge --release -- --ignored --nocapture normfix
//! ```

use super::*;

/// Stack every requested filter's lights through the production entry point.
#[test]
#[ignore = "needs real frames; set NORMFIX_CAPTURES and NORMFIX_OUT"]
fn normfix_stack_real_frames() {
    let captures = std::env::var("NORMFIX_CAPTURES")
        .expect("set NORMFIX_CAPTURES to the directory holding the light frames");
    let out_dir =
        std::env::var("NORMFIX_OUT").expect("set NORMFIX_OUT to a writable output directory");
    let filters = std::env::var("NORMFIX_FILTERS").unwrap_or_else(|_| "L".to_string());

    std::fs::create_dir_all(&out_dir).expect("create output directory");

    for filter in filters.split(',').map(str::trim).filter(|f| !f.is_empty()) {
        let mut lights: Vec<String> = std::fs::read_dir(&captures)
            .expect("read captures directory")
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| {
                let name = p.file_name().and_then(|n| n.to_str()).unwrap_or("");
                p.extension().and_then(|e| e.to_str()) == Some("fits")
                    && name.contains(&format!("_{filter}_"))
            })
            .map(|p| p.to_string_lossy().into_owned())
            .collect();
        lights.sort();
        assert!(
            !lights.is_empty(),
            "no '{filter}' lights found under {captures}"
        );

        let master = format!("{out_dir}/normfix_{filter}_master.fits");
        let rejmap = format!("{out_dir}/normfix_{filter}_rejmap.fits");
        // Every setting is left at its production default on purpose: this run
        // must exercise the shipping configuration, not a favourable one.
        let request = serde_json::json!({
            "runId": format!("normfix-{filter}"),
            "lightPaths": lights,
            "reference": "auto",
            "exposuresSec": vec![60.0f64; lights.len()],
            "output": {
                "masterFitsPath": master,
                "rejectionMapPath": rejmap,
            }
        });

        eprintln!("[normfix] {filter}: stacking {} lights", lights.len());
        match api_integrate_session(request.to_string()) {
            Ok(result) => eprintln!("[normfix] {filter}: {result}"),
            Err(e) => panic!("[normfix] {filter}: integrate_session failed: {e}"),
        }
    }
}

#[test]
#[ignore = "needs real files; SKOTIQ_BUILD_REQUEST and SKOTIQ_BUILD_RESULT"]
fn guided_build_request() {
    let request = std::fs::read_to_string(std::env::var("SKOTIQ_BUILD_REQUEST").unwrap()).unwrap();
    let result = api_master_accumulate(request);
    std::fs::write(
        std::env::var("SKOTIQ_BUILD_RESULT").unwrap(),
        serde_json::to_string_pretty(&result).unwrap(),
    )
    .unwrap();
    assert!(result.is_ok(), "{result:?}");
}

/// Real NGC 891 subs of one night (ASI1600MM, 1016 mm): the R master and the L
/// master are built onto the same L sub, R with the 90 s dark scaled to its
/// 120 s exposure, using subs from both sides of the meridian flip. The two
/// masters must then share their star positions to a fraction of a pixel.
///
/// Run with `cargo test -p skotiq_bridge --release -- --ignored --nocapture
/// ngc891`. `SKOTIQ_NGC891_DIR` points at a folder holding `lights/n2` and
/// `cal/masters` (default `~/.cache/eon`).
#[test]
#[ignore = "needs the NGC 891 frames; SKOTIQ_NGC891_DIR"]
fn ngc891_cross_filter_registration_across_the_flip() {
    let root = std::env::var("SKOTIQ_NGC891_DIR")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| {
            std::path::PathBuf::from(std::env::var("HOME").unwrap()).join(".cache/eon")
        });
    let light = |name: &str| root.join("lights/n2").join(name);
    let masters = root.join("cal/masters");
    let calibration = serde_json::json!({
        "dark": masters.join("MasterDark_90s_g76_o15.fits"),
        "bias": masters.join("MasterBias_g76_o15.fits"),
    });
    let out = std::env::temp_dir().join(format!("sk_ngc891_{}", std::process::id()));
    std::fs::create_dir_all(&out).unwrap();
    let grid = light("NGC0891_L_0001.fits");
    let build = |filter: &str, subs: &[&str], exposure: f64| -> serde_json::Value {
        let lights: Vec<serde_json::Value> = subs
            .iter()
            .map(|s| serde_json::json!({"path": light(s), "exposureSec": exposure}))
            .collect();
        let started = std::time::Instant::now();
        let result = api_master_accumulate(
            serde_json::json!({
                "op": "build", "filter": filter, "target": "NGC 891",
                "gridReference": {"path": grid, "calibration": calibration},
                "normalizationReference": {"path": lights[0]["path"], "calibration": calibration},
                "groups": [{"label": "2026-10-21", "calibration": calibration, "lights": lights}],
                "minOverlap": 0.8,
                "settings": {"align": {"model": "affine", "resampler": "lanczos3"},
                             "weighting": {"enabled": true, "formula": "starSignal"},
                             "normalization": {"enabled": true, "mode": "global"}},
                "masterFitsPath": out.join(format!("{filter}.fits")),
                "coverageFitsPath": out.join(format!("{filter}.cov.fits")),
            })
            .to_string(),
        )
        .unwrap_or_else(|e| panic!("{filter} build failed: {e}"));
        eprintln!("[ngc891] {filter} built in {:?}", started.elapsed());
        serde_json::from_str(&result).unwrap()
    };
    let l = build(
        "L",
        &[
            "NGC0891_L_0001.fits",
            "NGC0891_L_0002.fits",
            "NGC0891_L_0034.fits",
            "NGC0891_L_0035.fits",
        ],
        90.0,
    );
    let r = build(
        "R",
        &[
            "NGC0891_R_0001.fits",
            "NGC0891_R_0002.fits",
            "NGC0891_R_0034.fits",
            "NGC0891_R_0035.fits",
        ],
        120.0,
    );
    for (name, result) in [("L", &l), ("R", &r)] {
        eprintln!(
            "[ngc891] {name}: {} folded, skipped {}, rotations {:?}",
            result["frameCount"],
            result["skipped"],
            result["folded"]
                .as_array()
                .unwrap()
                .iter()
                .map(|f| f["rotationDeg"].as_f64().unwrap().round())
                .collect::<Vec<_>>()
        );
        assert_eq!(result["frameCount"], 4, "{name}: {result}");
    }
    let scale = r["groups"][0]["darkScale"].as_f64().unwrap();
    assert!((scale - 120.0 / 90.0).abs() < 1e-6, "dark scale {scale}");

    let detection = |path: &std::path::Path| {
        let (image, _) = read_fits(path).unwrap();
        let data: Vec<u16> = image_to_f64(&image)
            .iter()
            .map(|v| (v + 100.0).round().clamp(0.0, 65535.0) as u16)
            .collect();
        ImageData::from_u16(image.width, image.height, 1, &data)
    };
    let (lm, rm) = (
        detection(&out.join("L.fits")),
        detection(&out.join("R.fits")),
    );
    let cfg = RegistrationConfig {
        transform_kind: TransformKind::Affine,
        ..RegistrationConfig::default()
    };
    let (t, stats) = skotiq_imaging::registration::solve_registration(&lm, &rm, &cfg).unwrap();
    let worst = [(0.0, 0.0), (4655.0, 0.0), (0.0, 3519.0), (4655.0, 3519.0)]
        .iter()
        .map(|&(x, y)| {
            let (mx, my) = t.apply(x, y);
            (mx - x).hypot(my - y)
        })
        .fold(0.0, f64::max);
    eprintln!(
        "[ngc891] R master onto L master: {} stars, rms {:.3} px, largest corner offset {worst:.3} px",
        stats.inlier_count, stats.rms_residual_px
    );
    std::fs::remove_dir_all(&out).ok();
    assert!(worst < 0.5, "R and L masters disagree by {worst:.3} px");
}
