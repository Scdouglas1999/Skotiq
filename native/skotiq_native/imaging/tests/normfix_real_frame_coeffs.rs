//! Opt-in: print the normalization coefficients fitted for real sub-frames.
//!
//! Registration and resampling sit between the estimator and the final master,
//! so comparing a master against an independent reimplementation conflates the
//! two. This reads the raw frames, fits frame-onto-reference directly, and
//! prints the coefficients — the level at which an independent implementation
//! can be compared exactly.
//!
//! ```text
//! NORMFIX_CAPTURES=/path/to/captures NORMFIX_FILTERS=L,R,G,B \
//!   cargo test -p skotiq_imaging --release --test normfix_real_frame_coeffs \
//!   -- --ignored --nocapture
//! ```

use skotiq_imaging::normalization::{estimate_normalization, CoverageMask, NormalizationConfig};
use skotiq_imaging::read_fits;

#[test]
#[ignore = "needs real frames; set NORMFIX_CAPTURES"]
fn normfix_coefficients_on_real_frames() {
    let captures = std::env::var("NORMFIX_CAPTURES")
        .expect("set NORMFIX_CAPTURES to the directory holding the light frames");
    let filters = std::env::var("NORMFIX_FILTERS").unwrap_or_else(|_| "L".to_string());

    for filter in filters.split(',').map(str::trim).filter(|f| !f.is_empty()) {
        let mut paths: Vec<_> = std::fs::read_dir(&captures)
            .expect("read captures directory")
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| {
                let name = p.file_name().and_then(|n| n.to_str()).unwrap_or("");
                p.extension().and_then(|e| e.to_str()) == Some("fits")
                    && name.contains(&format!("_{filter}_"))
            })
            .collect();
        paths.sort();
        assert!(!paths.is_empty(), "no '{filter}' frames under {captures}");

        let planes: Vec<Vec<f64>> = paths
            .iter()
            .map(|p| {
                let (image, _) = read_fits(p).expect("read frame");
                image
                    .as_u16()
                    .map(|v| v.into_iter().map(|x| x as f64).collect::<Vec<f64>>())
                    .expect("frames are U16")
            })
            .collect();
        let (image, _) = read_fits(&paths[0]).expect("read frame");
        let (w, h) = (image.width as usize, image.height as usize);
        let mask = CoverageMask::full(w, h);
        let cfg = NormalizationConfig::default();

        // Frame 0 is the reference, matching the numpy cross-check.
        for (i, plane) in planes.iter().enumerate() {
            let c = estimate_normalization(plane, &planes[0], &mask, w, h, &cfg).unwrap();
            println!(
                "COEFF {filter} frame={i} scale={:.9} offset={:.6} samples={} warning={:?}",
                c.scale, c.offset, c.samples_used, c.warning
            );
        }
    }
}
