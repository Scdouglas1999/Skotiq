//! Run the app's star detector on FITS files and print what it found.
//!
//! ```text
//! cargo run --release -p skotiq_imaging --example star_detect_eval -- \
//!     [--csv-dir DIR] FILE.fits...
//! ```
//!
//! One JSON line per file goes to stdout: the counts, frame medians and
//! timing that `detect_stars_with_stats` reports. With `--csv-dir`, every
//! detection is also written to `DIR/<file stem>.csv` (`x,y,flux,hfr,snr,
//! eccentricity,sharpness,peak`, 0-based pixel coordinates) so an independent
//! reference can be compared against it.

use skotiq_imaging::{detect_stars, detect_stars_with_stats, read_fits, StarDetectionConfig};
use std::io::Write;
use std::path::PathBuf;
use std::time::Instant;

fn main() {
    let mut csv_dir: Option<PathBuf> = None;
    let mut files = Vec::new();
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        if arg == "--csv-dir" {
            csv_dir = args.next().map(PathBuf::from);
        } else {
            files.push(PathBuf::from(arg));
        }
    }
    if files.is_empty() {
        eprintln!("usage: star_detect_eval [--csv-dir DIR] FILE.fits...");
        std::process::exit(2);
    }
    if let Some(dir) = &csv_dir {
        std::fs::create_dir_all(dir).expect("create csv dir");
    }

    let config = StarDetectionConfig::default();
    for path in files {
        let (image, _) = match read_fits(&path) {
            Ok(v) => v,
            Err(e) => {
                eprintln!("{}: {e}", path.display());
                continue;
            }
        };
        let start = Instant::now();
        let result = detect_stars_with_stats(&image, &config);
        let elapsed_ms = start.elapsed().as_secs_f64() * 1000.0;
        let all = detect_stars(&image, &config);
        let hfr_all = {
            let mut v: Vec<f64> = all.iter().map(|s| s.hfr).collect();
            v.sort_by(f64::total_cmp);
            v.get(v.len() / 2)
                .map_or_else(|| "null".to_string(), |h| format!("{h:.3}"))
        };
        println!(
            "{{\"file\":\"{}\",\"width\":{},\"height\":{},\"detected\":{},\"usable\":{},\"median_hfr\":{:.3},\"median_hfr_all\":{},\"background\":{:.1},\"noise\":{:.2},\"ms\":{:.0}}}",
            path.display(),
            image.width,
            image.height,
            all.len(),
            result.star_count,
            result.median_hfr,
            hfr_all,
            result.background,
            result.noise,
            elapsed_ms
        );
        if let Some(dir) = &csv_dir {
            let stem = path
                .file_stem()
                .map_or_else(|| "frame".into(), |s| s.to_string_lossy());
            let mut f = std::fs::File::create(dir.join(format!("{stem}.csv"))).expect("create csv");
            writeln!(f, "x,y,flux,hfr,snr,eccentricity,sharpness,peak").unwrap();
            for s in &all {
                writeln!(
                    f,
                    "{:.3},{:.3},{:.1},{:.3},{:.2},{:.3},{:.3},{:.1}",
                    s.x, s.y, s.flux, s.hfr, s.snr, s.eccentricity, s.sharpness, s.peak
                )
                .unwrap();
            }
        }
    }
}
