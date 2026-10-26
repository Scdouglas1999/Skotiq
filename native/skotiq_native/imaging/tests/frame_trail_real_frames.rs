//! Trail measurement on crops of the owner's real frames. A frame trailed by
//! a stalled mount must read as trailed even when its stars read round to the
//! detector; in-focus, defocused and wind-softened frames must not.

use skotiq_imaging::{measure_frame_trail, read_fits, FrameTrail, ImageData};
use std::path::{Path, PathBuf};

fn fixture(dir: &str, name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../test-fixtures")
        .join(dir)
        .join(name)
}

fn trail(path: &Path) -> FrameTrail {
    let (image, _) = read_fits(path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let data = image.as_u16().expect("16-bit frame");
    let image = ImageData::from_u16(image.width, image.height, 1, &data);
    let trail = measure_frame_trail(&image)
        .unwrap_or_else(|| panic!("{}: nothing measured", path.display()));
    println!(
        "{}: {trail:?} ratio {:.2}",
        path.display(),
        trail.axis_ratio()
    );
    trail
}

#[test]
fn frames_trailed_by_the_mount_read_as_trailed() {
    // trailed_round_G: NGC0891_G_0089 (2026-10-24), graded eccentricity 0.6
    // with 1,700 stars and accepted, though every star is a 25 px streak.
    for name in ["trailed_R.fits", "trailed_round_G.fits"] {
        let t = trail(&fixture("star-detect-2026-10-21", name));
        assert!(t.is_trailed(), "{name}: {t:?}");
    }
}

#[test]
fn round_and_defocused_stars_do_not_read_as_trailed() {
    for name in [
        "focused_L.fits",
        "defocus_R06.fits",
        "defocus_R12.fits",
        "defocus_R20.fits",
    ] {
        let t = trail(&fixture("star-detect-2026-10-21", name));
        assert!(!t.is_trailed(), "{name}: {t:?}");
    }
    for name in ["focused_L_0005.fits", "focused_L_0006.fits"] {
        let t = trail(&fixture("rig-2026-09-14", name));
        assert!(!t.is_trailed(), "{name}: {t:?}");
    }
}
