//! Frame star size and shape on the owner's real frames from 2026-09-14.
//!
//! The expected values are not this crate's own output: they come from an
//! independent measurement (elliptical Gaussian fits with scipy, recorded in
//! `test-fixtures/rig-2026-09-14/manifest.json`). Before `measure_frame_shape`
//! the frame HFR the grader used was the mean over every detection, which
//! read 10.8–15.6 px on these crops and 12.7–16.1 px on the full frames,
//! in focus or not.
//!
//! The committed fixtures are 1024×1024 crops copied pixel-for-pixel from the
//! frame centers. The full frames are checked too when they are present under
//! `~/.cache/ns-rig-data/2026-09-14` (or `$NIGHTSHADE_RIG_DATA/2026-09-14`);
//! without them those tests say so and return.

use nightshade_imaging::{measure_frame_shape, read_fits, FrameShape};
use std::path::{Path, PathBuf};

fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../test-fixtures/rig-2026-09-14")
}

fn rig_data() -> Option<PathBuf> {
    let root = std::env::var_os("NIGHTSHADE_RIG_DATA")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| Path::new(&h).join(".cache/ns-rig-data")))?
        .join("2026-09-14");
    root.is_dir().then_some(root)
}

fn shape(path: &Path) -> FrameShape {
    let (image, _) = read_fits(path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    measure_frame_shape(&image).unwrap_or_else(|| panic!("{}: no measurable stars", path.display()))
}

/// `(file, independent HFR, independent eccentricity)`.
fn assert_matches(dir: &Path, cases: &[(&str, f64, f64)]) {
    for &(file, hfr, eccentricity) in cases {
        let got = shape(&dir.join(file));
        println!(
            "{file}: hfr {:.2} (fit {hfr:.2}), e {:.2} (fit {eccentricity:.2}), {} stars",
            got.hfr, got.eccentricity, got.stars_measured
        );
        // Encircled energy includes the wings a Gaussian core fit leaves out,
        // so HFR may read up to half a pixel above the fit's.
        assert!(
            got.hfr > hfr - 0.3 && got.hfr < hfr + 0.6,
            "{file}: HFR {:.2} against an independent {hfr:.2}",
            got.hfr
        );
        assert!(
            (got.eccentricity - eccentricity).abs() <= 0.05,
            "{file}: eccentricity {:.2} against an independent {eccentricity:.2}",
            got.eccentricity
        );
    }
}

#[test]
fn crops_measure_what_an_independent_psf_fit_measures() {
    assert_matches(
        &fixtures(),
        &[
            ("focused_L_0005.fits", 2.12, 0.76),
            ("focused_L_0006.fits", 2.46, 0.65),
            ("trailed_SII_0001_001.fits", 2.77, 0.82),
            ("trailed_OIII_0001.fits", 3.26, 0.83),
        ],
    );
}

#[test]
fn crops_the_fit_could_barely_sample_still_read_on_the_right_side() {
    // The independent fit kept only two stars in each of these crops, too few
    // to compare medians; the full frames are compared below.
    let trailed = shape(&fixtures().join("trailed_Ha_0001_001.fits"));
    assert!(trailed.eccentricity > 0.9, "{trailed:?}");
    let defocused = shape(&fixtures().join("landed_from_above_L_0003.fits"));
    let focused = shape(&fixtures().join("focused_L_0005.fits"));
    assert!(
        defocused.hfr > 2.0 * focused.hfr,
        "landing from above ({:.2}) must read well out of focus against the run-up ({:.2})",
        defocused.hfr,
        focused.hfr
    );
}

#[test]
fn full_frames_measure_what_an_independent_psf_fit_measures() {
    let Some(dir) = rig_data() else {
        eprintln!("SKIPPED: ~/.cache/ns-rig-data/2026-09-14 is not on this machine");
        return;
    };
    assert_matches(
        &dir,
        &[
            ("good/Unknown_L_2026-09-15_0005.fits", 1.82, 0.68),
            ("good/Unknown_L_2026-09-15_0006.fits", 2.23, 0.52),
            ("good/Unknown_L_2026-09-14_0002.fits", 3.58, 0.61),
            ("good/Unknown_L_2026-09-14_0003.fits", 3.82, 0.74),
            ("good/Unknown_L_2026-09-15_0004.fits", 4.10, 0.75),
            ("reject/NGC7380_Ha_0001.fits", 3.21, 0.90),
            ("reject/NGC7380_SII_0001.fits", 2.35, 0.69),
            ("reject/NGC7380_Ha_0001_001.fits", 5.18, 0.98),
            ("reject/NGC7380_SII_0001_001.fits", 2.85, 0.83),
            ("reject/NGC7380_OIII_0001.fits", 3.28, 0.85),
            ("solve/solve-verify.fits", 1.82, 0.52),
        ],
    );
}
