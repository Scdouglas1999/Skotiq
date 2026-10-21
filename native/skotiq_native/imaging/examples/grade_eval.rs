//! Print the per-frame measurements the sequencer's image grader works from.
//!
//! ```text
//! cargo run --release -p skotiq_imaging --example grade_eval -- FILE.fits...
//! ```
//!
//! One tab-separated line per file: every detection, how many are round
//! enough to work with (eccentricity at most 0.7), the median eccentricity of
//! the detections, and the `measure_frame_shape` HFR and eccentricity the
//! grader uses.

use skotiq_imaging::{
    detect_stars, frame_eccentricity, measure_frame_shape_from, read_fits, StarDetectionConfig,
    SELECTION_MAX_ECCENTRICITY,
};
use std::time::Instant;

fn main() {
    let files: Vec<String> = std::env::args().skip(1).collect();
    if files.is_empty() {
        eprintln!("usage: grade_eval FILE.fits...");
        std::process::exit(2);
    }
    let config = StarDetectionConfig::default();
    println!("file\tdetected\tround\tround_frac\tdet_ecc\tshape_hfr\tshape_ecc\tshape_n\tms");
    for path in files {
        let (image, _) = match read_fits(std::path::Path::new(&path)) {
            Ok(v) => v,
            Err(e) => {
                eprintln!("{path}: {e}");
                continue;
            }
        };
        let start = Instant::now();
        let stars = detect_stars(&image, &config);
        let round = stars
            .iter()
            .filter(|s| s.eccentricity <= SELECTION_MAX_ECCENTRICITY)
            .count();
        let shape = measure_frame_shape_from(&image, &stars, f64::from(config.saturation_limit));
        let ms = start.elapsed().as_secs_f64() * 1000.0;
        let fmt = |v: Option<f64>| v.map_or_else(|| "-".to_string(), |v| format!("{v:.3}"));
        println!(
            "{}\t{}\t{}\t{:.3}\t{}\t{}\t{}\t{}\t{:.0}",
            std::path::Path::new(&path)
                .file_name()
                .map_or_else(|| path.clone(), |n| n.to_string_lossy().into_owned()),
            stars.len(),
            round,
            if stars.is_empty() {
                0.0
            } else {
                round as f64 / stars.len() as f64
            },
            fmt(frame_eccentricity(&stars)),
            fmt(shape.map(|s| s.hfr)),
            fmt(shape.map(|s| s.eccentricity)),
            shape.map_or(0, |s| s.stars_measured),
            ms
        );
    }
}
