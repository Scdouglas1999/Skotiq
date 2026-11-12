//! Cross-checks the XISF codec against an independent implementation.
//!
//! `xisf_interop write <dir>` writes one file per sample format × codec ×
//! shuffle into `<dir>`, each with a `.raw` file of its interleaved
//! little-endian pixels and a `.json` description of its geometry and cards.
//! `xisf_interop read <file>...` prints, per file, a JSON line with the
//! geometry, the pixels as hex-free summary (sha256 of the interleaved
//! little-endian bytes) and the cards the app reads.
//! `xisf_interop bench <file.fits>` times reading and writing a frame as FITS
//! and as XISF with every codec.

use sha2::{Digest, Sha256};
use skotiq_imaging::xisf::read_xisf_unit;
use skotiq_imaging::{
    read_frame, write_frame_with, ChecksumAlgorithm, FitsHeader, FrameWriteOptions, ImageData,
    PixelType, XisfCodec, XisfCompression, XisfWriteOptions,
};
use std::path::Path;
use std::time::Instant;

fn image(w: u32, h: u32, channels: u32, pixel_type: PixelType) -> ImageData {
    let mut image = ImageData::new(w, h, channels, pixel_type);
    let size = pixel_type.byte_size();
    for i in 0..(w * h * channels) as usize {
        let x = (i / channels as usize) % w as usize;
        let v = match pixel_type {
            PixelType::U8 => ((x * 3 + i) % 256) as f64,
            PixelType::U16 => (1000 + x * 7 + (i * 31) % 97) as f64,
            PixelType::U32 => (100_000 + x * 7919 + (i * 31) % 997) as f64,
            PixelType::F32 | PixelType::F64 => (x as f64 / w as f64) * 0.5 + (i % 13) as f64 * 1e-3,
        };
        skotiq_imaging::samples::sample_to_le(&mut image.data[i * size..(i + 1) * size], pixel_type, v);
    }
    image
}

fn header() -> FitsHeader {
    let mut h = FitsHeader::new();
    h.set_float("EXPTIME", 300.0);
    h.set_comment("EXPTIME", "Exposure time in seconds");
    h.set_string("DATE-OBS", "2026-11-11T07:12:06.250");
    h.set_string("IMAGETYP", "Light");
    h.set_string("OBJECT", "NGC 891");
    h.set_string("FILTER", "Ha");
    h.set_int("GAIN", 139);
    h.set_float("CCD-TEMP", -10.5);
    h.set_float("FOCALLEN", 1016.0);
    h.set_string("CTYPE1", "RA---TAN");
    h.set_string("CTYPE2", "DEC--TAN");
    h.set_float("CRVAL1", 35.6391);
    h.set_float("CRVAL2", 42.3491);
    h.set_float("CRPIX1", 32.5);
    h.set_float("CRPIX2", 24.5);
    h.set_float("CD1_1", -2.1e-4);
    h.set_float("CD1_2", 1.5e-6);
    h.set_float("CD2_1", -1.5e-6);
    h.set_float("CD2_2", -2.1e-4);
    h.add_history("Written by xisf_interop");
    h
}

fn cards_json(h: &FitsHeader) -> String {
    let cards: Vec<String> = h
        .cards()
        .map(|(k, v, c)| {
            format!(
                "[{:?},{:?},{:?}]",
                k,
                v.to_header_string(),
                c.unwrap_or_default()
            )
        })
        .collect();
    format!("[{}]", cards.join(","))
}

fn summary(image: &ImageData, header: &FitsHeader) -> String {
    format!(
        "{{\"width\":{},\"height\":{},\"channels\":{},\"type\":\"{:?}\",\"sha256\":\"{:x}\",\"cards\":{},\"history\":{:?}}}",
        image.width,
        image.height,
        image.channels,
        image.pixel_type,
        Sha256::digest(&image.data),
        cards_json(header),
        header.history
    )
}

fn write(dir: &Path) {
    std::fs::create_dir_all(dir).unwrap();
    let mut codecs: Vec<(String, Option<XisfCompression>)> = vec![("none".into(), None)];
    for codec in XisfCodec::ALL {
        for shuffle in [false, true] {
            codecs.push((
                format!("{}{}", codec.name(), if shuffle { "+sh" } else { "" }),
                Some(XisfCompression {
                    codec,
                    shuffle,
                    level: None,
                }),
            ));
        }
    }
    let header = header();
    for pixel_type in [PixelType::U8, PixelType::U16, PixelType::U32, PixelType::F32, PixelType::F64] {
        for channels in [1u32, 3] {
            let img = image(64, 48, channels, pixel_type);
            for (name, compression) in &codecs {
                let stem = format!("sk_{pixel_type:?}_{channels}_{name}").replace('+', "p");
                let path = dir.join(format!("{stem}.xisf"));
                let options = FrameWriteOptions {
                    xisf: XisfWriteOptions {
                        compression: *compression,
                        checksum: Some(ChecksumAlgorithm::Sha1),
                        thumbnail: true,
                    },
                };
                write_frame_with(&path, &img, &header, &options).unwrap();
                std::fs::write(dir.join(format!("{stem}.raw")), &img.data).unwrap();
                std::fs::write(dir.join(format!("{stem}.json")), summary(&img, &header)).unwrap();
            }
        }
    }
}

fn read(paths: &[String]) {
    for p in paths {
        match read_frame(Path::new(p)) {
            Ok((image, header)) => {
                let unit = read_xisf_unit(Path::new(p)).unwrap();
                let props: Vec<String> = unit.images[0]
                    .properties
                    .iter()
                    .map(|p| format!("[{:?},{:?}]", p.id, p.value.display_text()))
                    .collect();
                println!(
                    "{{\"file\":{:?},\"ok\":true,\"frame\":{},\"properties\":[{}]}}",
                    p,
                    summary(&image, &header),
                    props.join(",")
                );
            }
            Err(e) => println!("{{\"file\":{:?},\"ok\":false,\"error\":{:?}}}", p, e.to_string()),
        }
    }
}

fn time<T>(f: impl FnOnce() -> T) -> (T, f64) {
    let start = Instant::now();
    let value = f();
    (value, start.elapsed().as_secs_f64() * 1000.0)
}

/// Grow a frame to at least `pixels` by placing it 2×2 with its copies
/// mirrored (left-right, top-bottom), so the result keeps the real sky's noise
/// and no row repeats inside a compression window.
fn tile_to(img: ImageData, pixels: u64) -> ImageData {
    let mut img = img;
    while (img.width as u64) * (img.height as u64) < pixels {
        let size = img.pixel_type.byte_size() * img.channels as usize;
        let row = img.width as usize * size;
        let rows: Vec<&[u8]> = img.data.chunks_exact(row).collect();
        let mut data = Vec::with_capacity(img.data.len() * 4);
        for r in rows.iter().chain(rows.iter().rev()) {
            data.extend_from_slice(r);
            for pixel in r.chunks_exact(size).rev() {
                data.extend_from_slice(pixel);
            }
        }
        img = ImageData {
            width: img.width * 2,
            height: img.height * 2,
            data,
            ..img
        };
    }
    img
}

fn bench(source: &Path, min_pixels: u64) {
    let (img, header) = read_frame(source).unwrap();
    let img = tile_to(img, min_pixels);
    let dir = std::env::temp_dir().join("sk-xisf-bench");
    std::fs::create_dir_all(&dir).unwrap();
    println!(
        "frame {}x{}x{} {:?} ({} MB)",
        img.width,
        img.height,
        img.channels,
        img.pixel_type,
        img.data.len() >> 20
    );
    let fits = dir.join("bench.fits");
    let (_, w) = time(|| skotiq_imaging::write_frame(&fits, &img, &header).unwrap());
    let (_, r) = time(|| read_frame(&fits).unwrap());
    let size = std::fs::metadata(&fits).unwrap().len();
    println!("| FITS | {w:.0} | {r:.0} | {} |", size >> 20);
    let mut codecs: Vec<(String, Option<XisfCompression>)> = vec![("XISF uncompressed".into(), None)];
    for codec in XisfCodec::ALL {
        for shuffle in [false, true] {
            codecs.push((
                format!("XISF {}{}", codec.name(), if shuffle { "+sh" } else { "" }),
                Some(XisfCompression {
                    codec,
                    shuffle,
                    level: None,
                }),
            ));
        }
    }
    for (name, compression) in codecs {
        let path = dir.join("bench.xisf");
        let options = FrameWriteOptions {
            xisf: XisfWriteOptions {
                compression,
                checksum: None,
                thumbnail: true,
            },
        };
        let (_, w) = time(|| write_frame_with(&path, &img, &header, &options).unwrap());
        let ((back, _), r) = time(|| read_frame(&path).unwrap());
        assert_eq!(back.data, img.data, "{name}");
        let size = std::fs::metadata(&path).unwrap().len();
        println!("| {name} | {w:.0} | {r:.0} | {} |", size >> 20);
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("write") => write(Path::new(&args[1])),
        Some("read") => read(&args[1..]),
        Some("bench") => bench(
            Path::new(&args[1]),
            args.get(2).and_then(|p| p.parse().ok()).unwrap_or(60_000_000),
        ),
        _ => eprintln!("usage: xisf_interop write <dir> | read <file>... | bench <frame> [min pixels]"),
    }
}
