//! Dump what Skotiq reads from camera raw files, for comparison with other
//! decoders.
//!
//! ```text
//! cargo run --release -p skotiq-imaging --example raw_dump -- [--rgb] <out_dir> <raw file>...
//! ```
//!
//! For each file, one JSON line on stdout (size, filter cell, black levels per
//! cell position, white level, bit depth, what the camera recorded) and, in
//! `<out_dir>`:
//! * `<file>.u16`: the visible mosaic exactly as read, row-major little-endian
//!   u16, black level not subtracted;
//! * `<file>.fits`: the frame converted to FITS through the image seam
//!   (`read_frame` then `write_fits`, what a plate solve hands the solver); its
//!   header cards are also in the JSON line;
//! * with `--rgb`, `<file>.rgb`: Skotiq's own demosaic (bilinear for Bayer, the
//!   one X-Trans method), planar red, green, blue u16 little-endian.

use serde_json::{json, Value};
use skotiq_imaging::{read_frame, read_raw_file, write_fits, DebayerAlgorithm};
use std::path::{Path, PathBuf};

fn le_bytes(samples: &[u16]) -> Vec<u8> {
    samples.iter().flat_map(|v| v.to_le_bytes()).collect()
}

fn dump(path: &Path, out_dir: &Path, rgb: bool) -> Result<Value, String> {
    let name = path
        .file_name()
        .ok_or("no file name")?
        .to_string_lossy()
        .to_string();
    let frame = read_raw_file(path).map_err(|e| e.to_string())?;
    std::fs::write(out_dir.join(format!("{name}.u16")), le_bytes(&frame.data))
        .map_err(|e| e.to_string())?;
    if rgb {
        let planes = frame.cfa.demosaic(
            &frame.data,
            frame.width,
            frame.height,
            DebayerAlgorithm::Bilinear,
        );
        let mut bytes = le_bytes(&planes.red);
        bytes.extend(le_bytes(&planes.green));
        bytes.extend(le_bytes(&planes.blue));
        std::fs::write(out_dir.join(format!("{name}.rgb")), bytes).map_err(|e| e.to_string())?;
    }

    let (image, header) = read_frame(path).map_err(|e| e.to_string())?;
    let fits_path = out_dir.join(format!("{name}.fits"));
    write_fits(&fits_path, &image, &header).map_err(|e| e.to_string())?;
    let cards: serde_json::Map<String, Value> = header
        .cards()
        .map(|(key, value, comment)| {
            (
                key.to_string(),
                json!({"value": format!("{value:?}"), "comment": comment}),
            )
        })
        .collect();

    let meta = &frame.metadata;
    Ok(json!({
        "file": name,
        "width": frame.width,
        "height": frame.height,
        "cfa": frame.cfa.letters(),
        "black_levels": frame.black_levels,
        "white_level": frame.white_level,
        "bits_per_pixel": frame.bits_per_pixel,
        "metadata": {
            "make": meta.make,
            "model": meta.model,
            "lens": meta.lens,
            "iso": meta.iso,
            "exposure_seconds": meta.exposure_seconds,
            "f_number": meta.f_number,
            "focal_length_mm": meta.focal_length_mm,
            "captured_at": meta.captured_at.map(|t| t.to_rfc3339()),
            "temperature": meta.temperature.map(|t| json!({
                "celsius": t.celsius,
                "source": format!("{:?}", t.source),
            })),
        },
        "fits_cards": cards,
    }))
}

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let rgb = args.first().is_some_and(|a| a == "--rgb");
    if rgb {
        args.remove(0);
    }
    if args.len() < 2 {
        eprintln!("usage: raw_dump [--rgb] <out_dir> <raw file>...");
        std::process::exit(2);
    }
    let out_dir = PathBuf::from(&args[0]);
    std::fs::create_dir_all(&out_dir).expect("output directory");
    for file in &args[1..] {
        let path = Path::new(file);
        let line = dump(path, &out_dir, rgb).unwrap_or_else(|e| {
            json!({"file": path.file_name().map(|n| n.to_string_lossy().to_string()), "error": e})
        });
        println!("{line}");
    }
}
