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
