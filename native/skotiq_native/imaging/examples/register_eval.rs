//! Register FITS frames onto a reference with the app's star registration and
//! print what it found.
//!
//! ```text
//! cargo run --release -p skotiq_imaging --example register_eval -- \
//!     [--dark DARK.fits] [--frame-dark DARK.fits] [--max-stars N] \
//!     REFERENCE.fits FRAME.fits...
//! ```
//!
//! One JSON line per frame goes to stdout: the fitted rotation, scale and
//! shift, the star and inlier counts and the inlier RMS, or the error text.
//! `--dark` subtracts a master dark from every frame first, as the
//! accumulating master does; `--frame-dark` gives the frames their own.

use skotiq_imaging::calibration::calibrate_frame;
use skotiq_imaging::registration::{solve_registration, RegistrationConfig};
use skotiq_imaging::{read_fits, ImageData};
use std::path::PathBuf;
use std::time::Instant;

fn load(path: &PathBuf, dark: Option<&ImageData>) -> ImageData {
    let (image, _) = read_fits(path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    match dark {
        Some(d) => calibrate_frame(&image, Some(d), None, None)
            .unwrap_or_else(|e| panic!("{}: {e}", path.display())),
        None => image,
    }
}

fn main() {
    let mut dark_path: Option<PathBuf> = None;
    let mut frame_dark_path: Option<PathBuf> = None;
    let mut max_stars: Option<usize> = None;
    let mut files = Vec::new();
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--dark" => dark_path = args.next().map(PathBuf::from),
            "--frame-dark" => frame_dark_path = args.next().map(PathBuf::from),
            "--max-stars" => max_stars = args.next().and_then(|v| v.parse().ok()),
            _ => files.push(PathBuf::from(arg)),
        }
    }
    if files.len() < 2 {
        eprintln!(
            "usage: register_eval [--dark DARK.fits] [--max-stars N] REFERENCE.fits FRAME.fits..."
        );
        std::process::exit(2);
    }
    let dark = dark_path.map(|p| read_fits(&p).expect("dark").0);
    let reference = load(&files[0], dark.as_ref());
    let frame_dark = frame_dark_path.map(|p| read_fits(&p).expect("frame dark").0);
    let frame_dark = frame_dark.as_ref().or(dark.as_ref());
    let mut config = RegistrationConfig::default();
    if let Some(n) = max_stars {
        config.max_stars_for_matching = n;
    }
    for path in &files[1..] {
        let frame = load(path, frame_dark);
        let start = Instant::now();
        let result = solve_registration(&reference, &frame, &config);
        let ms = start.elapsed().as_secs_f64() * 1000.0;
        match result {
            Ok((t, s)) => {
                let m = t.matrix;
                println!(
                    "{{\"frame\":\"{}\",\"rotationDeg\":{:.4},\"scale\":{:.5},\"dx\":{:.2},\"dy\":{:.2},\"refStars\":{},\"frameStars\":{},\"correspondences\":{},\"inliers\":{},\"rmsPx\":{:.3},\"ms\":{:.0}}}",
                    path.display(),
                    m[1][0].atan2(m[0][0]).to_degrees(),
                    t.scale(),
                    m[0][2],
                    m[1][2],
                    s.reference_star_count,
                    s.frame_star_count,
                    s.correspondence_count,
                    s.inlier_count,
                    s.rms_residual_px,
                    ms
                );
            }
            Err(e) => println!(
                "{{\"frame\":\"{}\",\"error\":\"{e}\",\"ms\":{ms:.0}}}",
                path.display()
            ),
        }
    }
}
