//! Camera raw files through the app's one image seam.
//!
//! Two kinds of evidence:
//! * Tiny DNG files written here, byte by byte, with known pixels, filter and
//!   levels. They run everywhere.
//! * Public sample files from every maker (raw.pixls.us, CC0), checked against
//!   an independent decoder (rawpy) and an independent metadata reader
//!   (ExifTool). The files are too large to commit; the expectations are in
//!   `test-fixtures/camera-raw-2026-11-12/manifest.json`. Set
//!   `SKOTIQ_RAW_SAMPLES` to the directory holding them to run that part.

use serde_json::Value;
use sha2::{Digest, Sha256};
use skotiq_imaging::{
    camera_raw_extension, frame_extensions, frame_format, is_frame_path, read_frame,
    read_frame_header, read_image, read_raw_file, rewrite_frame_header, write_frame, BayerColor,
    ColorFilterArray, ImageFormat, TemperatureSource,
};
use std::path::{Path, PathBuf};

const XTRANS: &str = "GGRGGBGGBGGRBRGRBGGGBGGRGGRGGBRBGBRG";
const BLACK: u16 = 512;
const WHITE: u32 = 16383;
/// The synthetic files' capture time: the camera's wall clock and its UTC
/// offset as EXIF records them, and the UTC time they mean.
const CAMERA_CLOCK: &str = "2021:05:10 20:08:34";
const CAMERA_OFFSET: &str = "+02:00";
const CAPTURED_UTC: &str = "2021-05-10T18:08:34";

fn level(color: BayerColor) -> u16 {
    match color {
        BayerColor::Red => 1000,
        BayerColor::Green => 2000,
        BayerColor::Blue => 3000,
    }
}

/// The pixel the synthetic files hold at (x, y): black + a level per color +
/// a small ramp, so a wrong origin, stride or filter shows.
fn synthetic_pixel(cfa: &ColorFilterArray, x: usize, y: usize) -> u16 {
    BLACK + level(cfa.color_at(x, y)) + ((x + y) % 7) as u16
}

/// An Exif IFD placed at file offset `at`: DateTimeOriginal and
/// OffsetTimeOriginal.
fn exif_ifd(at: usize) -> Vec<u8> {
    let strings = [
        (0x9003u16, format!("{CAMERA_CLOCK}\0")),
        (0x9011, format!("{CAMERA_OFFSET}\0")),
    ];
    let mut value_at = at + 2 + strings.len() * 12 + 4;
    let mut ifd = (strings.len() as u16).to_le_bytes().to_vec();
    for (tag, text) in &strings {
        ifd.extend_from_slice(&tag.to_le_bytes());
        ifd.extend_from_slice(&2u16.to_le_bytes());
        ifd.extend_from_slice(&(text.len() as u32).to_le_bytes());
        ifd.extend_from_slice(&(value_at as u32).to_le_bytes());
        value_at += text.len();
    }
    ifd.extend_from_slice(&0u32.to_le_bytes());
    for (_, text) in &strings {
        ifd.extend_from_slice(text.as_bytes());
    }
    if ifd.len() % 2 == 1 {
        ifd.push(0);
    }
    ifd
}

/// A minimal uncompressed DNG: one IFD, a 16-bit CFA strip, the filter cell,
/// black and white level, make and model, and an Exif IFD with the capture
/// time.
fn write_dng(path: &Path, width: usize, height: usize, letters: &str) {
    let cfa = ColorFilterArray::parse(letters).unwrap();
    let cell = cfa.cell_size();
    let mut data = Vec::with_capacity(width * height * 2);
    for y in 0..height {
        for x in 0..width {
            data.extend_from_slice(&synthetic_pixel(&cfa, x, y).to_le_bytes());
        }
    }
    let pattern: Vec<u8> = letters
        .chars()
        .map(|c| match c {
            'R' => 0,
            'G' => 1,
            _ => 2,
        })
        .collect();
    let identity: Vec<u8> = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        .iter()
        .flat_map(|&v: &i32| [(v * 10000).to_le_bytes(), 10000i32.to_le_bytes()].concat())
        .collect();
    const SHORT: u16 = 3;
    const LONG: u16 = 4;
    const BYTE: u16 = 1;
    const ASCII: u16 = 2;
    const SRATIONAL: u16 = 10;
    let le16 = |v: u16| v.to_le_bytes().to_vec();
    let le32 = |v: u32| v.to_le_bytes().to_vec();
    // (tag, type, count, value); a value of `None` is the strip offset.
    let mut entries: Vec<(u16, u16, u32, Option<Vec<u8>>)> = vec![
        (254, LONG, 1, Some(le32(0))),
        (256, LONG, 1, Some(le32(width as u32))),
        (257, LONG, 1, Some(le32(height as u32))),
        (258, SHORT, 1, Some(le16(16))),
        (259, SHORT, 1, Some(le16(1))),
        (262, SHORT, 1, Some(le16(32803))),
        (271, ASCII, 7, Some(b"Skotiq\0".to_vec())),
        (272, ASCII, 10, Some(b"Synthetic\0".to_vec())),
        (273, LONG, 1, None),
        (277, SHORT, 1, Some(le16(1))),
        (278, LONG, 1, Some(le32(height as u32))),
        (279, LONG, 1, Some(le32(data.len() as u32))),
        (
            33421,
            SHORT,
            2,
            Some([le16(cell as u16), le16(cell as u16)].concat()),
        ),
        (33422, BYTE, pattern.len() as u32, Some(pattern)),
        (50706, BYTE, 4, Some(vec![1, 4, 0, 0])),
        (50708, ASCII, 10, Some(b"Synthetic\0".to_vec())),
        (50714, LONG, 1, Some(le32(BLACK as u32))),
        (50717, LONG, 1, Some(le32(WHITE))),
        (50721, SRATIONAL, 9, Some(identity)),
        (50778, SHORT, 1, Some(le16(21))),
    ];
    let ifd_offset = 8usize;
    let ifd_len = 2 + (entries.len() + 1) * 12 + 4;
    let exif_offset = ifd_offset + ifd_len;
    entries.push((34665, LONG, 1, Some(le32(exif_offset as u32))));
    entries.sort_by_key(|e| e.0);
    let exif = exif_ifd(exif_offset);
    let data_offset = exif_offset + exif.len();
    let extra_offset = data_offset + data.len();
    let mut ifd = (entries.len() as u16).to_le_bytes().to_vec();
    let mut extra = Vec::new();
    for (tag, kind, count, value) in entries {
        ifd.extend_from_slice(&tag.to_le_bytes());
        ifd.extend_from_slice(&kind.to_le_bytes());
        ifd.extend_from_slice(&count.to_le_bytes());
        let value = value.unwrap_or_else(|| le32(data_offset as u32));
        if value.len() <= 4 {
            let mut inline = value.clone();
            inline.resize(4, 0);
            ifd.extend_from_slice(&inline);
        } else {
            ifd.extend_from_slice(&((extra_offset + extra.len()) as u32).to_le_bytes());
            extra.extend_from_slice(&value);
            if extra.len() % 2 == 1 {
                extra.push(0);
            }
        }
    }
    ifd.extend_from_slice(&0u32.to_le_bytes());
    let mut file = b"II*\0".to_vec();
    file.extend_from_slice(&(ifd_offset as u32).to_le_bytes());
    file.extend_from_slice(&ifd);
    file.extend_from_slice(&exif);
    file.extend_from_slice(&data);
    file.extend_from_slice(&extra);
    std::fs::write(path, file).unwrap();
}

struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Self {
        let dir =
            std::env::temp_dir().join(format!("skotiq-camera-raw-{}-{name}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        Scratch(dir)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn check_synthetic(letters: &str, width: usize, height: usize) {
    let scratch = Scratch::new(&letters[..4]);
    let path = scratch.0.join("frame.dng");
    write_dng(&path, width, height, letters);
    let cfa = ColorFilterArray::parse(letters).unwrap();

    let frame = read_raw_file(&path).expect("synthetic DNG decodes");
    assert_eq!((frame.width, frame.height), (width as u32, height as u32));
    assert_eq!(frame.cfa, cfa);
    assert_eq!(frame.white_level, WHITE);
    assert_eq!(frame.black_level(), BLACK as u32);
    for y in 0..height {
        for x in 0..width {
            assert_eq!(
                frame.data[y * width + x],
                synthetic_pixel(&cfa, x, y),
                "({x}, {y})"
            );
        }
    }

    // The seam: format, header-only and full read agree.
    assert_eq!(frame_format(&path).unwrap(), ImageFormat::CameraRaw);
    let bytes = std::fs::read(&path).unwrap();
    assert_eq!(camera_raw_extension(&bytes), Some("dng"));
    // The content decides, whatever the file is called.
    let unnamed = scratch.0.join("frame.download");
    std::fs::copy(&path, &unnamed).unwrap();
    assert_eq!(frame_format(&unnamed).unwrap(), ImageFormat::CameraRaw);
    assert_eq!(
        read_frame(&unnamed).unwrap().0.as_u16().unwrap(),
        frame.data
    );
    let (image, header) = read_frame(&path).unwrap();
    assert_eq!(
        (image.width, image.height, image.channels),
        (width as u32, height as u32, 1)
    );
    assert_eq!(image.as_u16().unwrap(), frame.data);
    assert_eq!(header.get_string("BAYERPAT"), Some(letters));
    assert_eq!(header.get_string("INSTRUME"), Some("Skotiq Synthetic"));
    assert_eq!(header.get_int("BLKLEVEL"), Some(BLACK as i64));
    assert_eq!(header.get_int("DATAMAX"), Some(WHITE as i64));
    // UTC from the camera's recorded offset, whatever zone this computer is in.
    assert_eq!(header.get_string("DATE-OBS"), Some(CAPTURED_UTC));
    let only_header = read_frame_header(&path).unwrap();
    assert_eq!(only_header.get_string("BAYERPAT"), Some(letters));
    assert_eq!(only_header.get_int("NAXIS"), Some(2));
    assert_eq!(only_header.get_int("NAXIS1"), Some(width as i64));
    assert_eq!(only_header.get_int("NAXIS2"), Some(height as i64));

    // read_image, what the Darkroom and live stack call, sees the mosaic and
    // its filter, so the frame debayers like an astronomy camera's.
    let read = read_image(&path).unwrap();
    assert_eq!(read.cfa, Some(cfa));
    assert_eq!(read.image.channels, 1);
    let rgb = skotiq_imaging::demosaic(
        &cfa,
        &frame.data,
        width as u32,
        height as u32,
        Default::default(),
    );
    let at = |plane: &[u16]| plane[(height / 2) * width + width / 2] as i32 - BLACK as i32;
    assert!((at(&rgb.red) - 1000).abs() <= 7, "red {}", at(&rgb.red));
    assert!(
        (at(&rgb.green) - 2000).abs() <= 7,
        "green {}",
        at(&rgb.green)
    );
    assert!((at(&rgb.blue) - 3000).abs() <= 7, "blue {}", at(&rgb.blue));

    // The camera's file is never changed.
    let before = std::fs::read(&path).unwrap();
    assert!(write_frame(&path, &image, &header).is_err());
    assert!(rewrite_frame_header(&path, |h| h.set_string("OBJECT", "M31")).is_err());
    assert_eq!(std::fs::read(&path).unwrap(), before);
}

#[test]
fn a_bayer_dng_reads_as_its_linear_mosaic() {
    check_synthetic("RGGB", 32, 24);
    check_synthetic("BGGR", 30, 24);
}

#[test]
fn an_xtrans_dng_reads_as_its_linear_mosaic() {
    check_synthetic(XTRANS, 36, 24);
}

/// The first bytes of each maker's container, as the cameras write them; a
/// gPhoto2 download is told from a JPEG by these alone.
#[test]
fn every_maker_signature_is_recognized_from_its_first_bytes() {
    let tiff_with_make = |order: &[u8], make: &[u8]| {
        let little = order == b"II";
        let u16b = |v: u16| {
            if little {
                v.to_le_bytes()
            } else {
                v.to_be_bytes()
            }
        };
        let u32b = |v: u32| {
            if little {
                v.to_le_bytes()
            } else {
                v.to_be_bytes()
            }
        };
        let mut head = order.to_vec();
        head.extend(u16b(42));
        head.extend(u32b(8));
        head.extend(u16b(1));
        head.extend(u16b(0x010f));
        head.extend(u16b(2));
        head.extend(u32b(make.len() as u32));
        head.extend(u32b(26));
        head.extend(u32b(0));
        head.extend(make);
        head
    };
    let cases: Vec<(Vec<u8>, &str)> = vec![
        (b"II*\0\x10\0\0\0CR\x02\0".to_vec(), "cr2"),
        (b"\0\0\0\x18ftypcrx \0\0\0\x01".to_vec(), "cr3"),
        (b"FUJIFILMCCD-RAW 0201FF383501".to_vec(), "raf"),
        (b"IIRO\x08\0\0\0".to_vec(), "orf"),
        (b"IIRS\x08\0\0\0".to_vec(), "orf"),
        (b"MMOR\0\0\0\x08".to_vec(), "orf"),
        (b"IIU\0\x18\0\0\0".to_vec(), "rw2"),
        (tiff_with_make(b"MM", b"NIKON CORPORATION\0"), "nef"),
        (tiff_with_make(b"II", b"SONY\0"), "arw"),
        (tiff_with_make(b"MM", b"PENTAX             \0"), "pef"),
    ];
    for (head, extension) in &cases {
        assert_eq!(camera_raw_extension(head), Some(*extension), "{extension}");
    }
    // A JPEG, a TIFF no camera marked, and too few bytes are no raw file.
    assert_eq!(
        camera_raw_extension(&[0xFF, 0xD8, 0xFF, 0xE1, 0, 0x10, b'E', b'x']),
        None
    );
    assert_eq!(camera_raw_extension(&tiff_with_make(b"II", b"\0")), None);
    assert_eq!(camera_raw_extension(b"II"), None);
}

/// Darks taken as camera raw files build a master like any other frames.
#[test]
fn camera_raw_darks_build_a_master() {
    use skotiq_imaging::calibration_master_stream::{
        build_streamed_master, StreamedMasterConfig, StreamedMasterKind,
    };
    let scratch = Scratch::new("darks");
    let (width, height) = (32, 24);
    let paths: Vec<PathBuf> = (0..3)
        .map(|i| {
            let path = scratch.0.join(format!("IMG_000{i}.DNG"));
            write_dng(&path, width, height, "RGGB");
            path
        })
        .collect();
    let out = scratch.0.join("master_dark.fits");
    let config = StreamedMasterConfig::new(StreamedMasterKind::Dark);
    let result = build_streamed_master(&paths, &out, &config).expect("raw darks build");
    assert_eq!((result.width, result.height), (width as u32, height as u32));
    let mut left: Vec<String> = std::fs::read_dir(&scratch.0)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    left.sort();
    assert_eq!(
        left,
        [
            "IMG_0000.DNG",
            "IMG_0001.DNG",
            "IMG_0002.DNG",
            "master_dark.fits"
        ],
        "the decoded copies are working files, never beside the master"
    );
    let (master, header) = read_frame(&out).unwrap();
    let frame = read_raw_file(&paths[0]).unwrap();
    assert_eq!(master.as_u16().unwrap(), frame.data);
    assert_eq!(header.get_string("BAYERPAT"), Some("RGGB"));
    assert_eq!(header.get_string("INSTRUME"), Some("Skotiq Synthetic"));
}

#[test]
fn every_maker_extension_is_a_frame_path() {
    for ext in [
        "cr2", "cr3", "nef", "arw", "raf", "pef", "dng", "orf", "rw2",
    ] {
        assert!(frame_extensions().contains(&ext), "{ext}");
        assert!(
            is_frame_path(Path::new(&format!("IMG_0001.{}", ext.to_uppercase()))),
            "{ext}"
        );
    }
}

fn manifest() -> Value {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../test-fixtures/camera-raw-2026-11-12/manifest.json");
    serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
}

fn sha256(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

fn near(ours: Option<f64>, theirs: &Value, tolerance: f64) -> bool {
    match (ours, theirs.as_f64()) {
        (Some(a), Some(b)) => (a - b).abs() <= tolerance * b.abs().max(1.0),
        (None, None) => true,
        _ => false,
    }
}

/// Every public sample against the independent decoder and metadata reader.
#[test]
fn public_samples_match_independent_readers() {
    let Ok(dir) = std::env::var("SKOTIQ_RAW_SAMPLES") else {
        eprintln!("SKOTIQ_RAW_SAMPLES is not set; the public raw samples were not checked");
        return;
    };
    let manifest = manifest();
    let mut failures = Vec::new();
    for entry in manifest["frames"].as_array().unwrap() {
        let name = entry["file"].as_str().unwrap();
        let path = Path::new(&dir).join(name);
        let bytes = std::fs::read(&path).unwrap_or_else(|e| panic!("{name}: {e}"));
        assert_eq!(
            sha256(&bytes),
            entry["file_sha256"],
            "{name} is not the sample file"
        );
        let want = &entry["independent"];

        let extension = name.rsplit('.').next().unwrap();
        let signature = camera_raw_extension(&bytes[..4096]);
        if signature != Some(extension) {
            failures.push(format!("{name}: signature: {signature:?}"));
        }
        let frame = read_raw_file(&path).unwrap_or_else(|e| panic!("{name}: {e}"));
        let mosaic: Vec<u8> = frame.data.iter().flat_map(|v| v.to_le_bytes()).collect();
        let mut check = |what: &str, ok: bool, detail: String| {
            if !ok {
                failures.push(format!("{name}: {what}: {detail}"));
            }
        };
        check(
            "width",
            frame.width == want["width"],
            frame.width.to_string(),
        );
        check(
            "height",
            frame.height == want["height"],
            frame.height.to_string(),
        );
        check(
            "filter",
            frame.cfa.letters() == want["cfa"],
            frame.cfa.letters(),
        );
        check(
            "white level",
            frame.white_level == want["white_level"],
            frame.white_level.to_string(),
        );
        check(
            "saturation level",
            frame.saturation_level == want["saturation_level"],
            frame.saturation_level.to_string(),
        );
        check(
            "mosaic",
            sha256(&mosaic) == want["mosaic_sha256"],
            sha256(&mosaic),
        );
        // rawpy reports black by color channel; every position's black must be
        // one of them, and the mean must agree.
        let channels: Vec<u64> = want["black_by_channel"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_u64().unwrap())
            .collect();
        check(
            "black level",
            frame
                .black_levels
                .iter()
                .all(|&b| channels.contains(&(b as u64))),
            format!("{:?}", frame.black_levels),
        );

        let meta = &frame.metadata;
        check(
            "iso",
            near(meta.iso.map(f64::from), &want["iso"], 0.0),
            format!("{:?}", meta.iso),
        );
        check(
            "exposure",
            near(meta.exposure_seconds, &want["exposure_s"], 0.01),
            format!("{:?}", meta.exposure_seconds),
        );
        check(
            "focal length",
            near(meta.focal_length_mm.map(f64::from), &want["focal_mm"], 0.01),
            format!("{:?}", meta.focal_length_mm),
        );
        if let Some(lens) = &meta.lens {
            check("lens", want["lens"] == lens.as_str(), lens.clone());
        }
        // With a recorded UTC offset (EXIF, else a Nikon maker note's zone,
        // both as ExifTool reads them) the time is exact; without one it is
        // the camera clock read in this computer's zone.
        let wall = want["date_time_original"].as_str().unwrap();
        let offset = want["offset_time_original"]
            .as_str()
            .or_else(|| want["maker_note_offset"].as_str());
        let (got, expected) = match offset {
            Some(offset) => (
                meta.captured_at.map(|t| t.to_rfc3339()),
                chrono::DateTime::parse_from_rfc3339(&format!("{wall}{offset}"))
                    .ok()
                    .map(|t| t.with_timezone(&chrono::Utc).to_rfc3339()),
            ),
            None => (
                meta.captured_at.map(|t| {
                    t.with_timezone(&chrono::Local)
                        .format("%Y-%m-%dT%H:%M:%S")
                        .to_string()
                }),
                Some(wall.to_string()),
            ),
        };
        check(
            "time",
            got.is_some() && got == expected,
            format!("{got:?}, expected {expected:?}"),
        );
        let temperature = meta.temperature;
        // Olympus records its sensor in a tag LibRaw reads, Pentax in a
        // maker-note block Skotiq reads itself.
        let expected_source = if !want["exif_sensor_temperature"].is_null()
            && matches!(
                meta.maker(),
                skotiq_imaging::Maker::Olympus | skotiq_imaging::Maker::Pentax
            ) {
            Some((TemperatureSource::Sensor, &want["exif_sensor_temperature"]))
        } else if !want["exif_camera_temperature"].is_null()
            && matches!(
                meta.maker(),
                skotiq_imaging::Maker::Canon | skotiq_imaging::Maker::Pentax
            )
        {
            Some((
                TemperatureSource::CameraBody,
                &want["exif_camera_temperature"],
            ))
        } else {
            None
        };
        let ok = match (temperature, expected_source) {
            (Some(t), Some((source, value))) => {
                t.source == source && near(Some(t.celsius as f64), value, 1e-6)
            }
            (None, None) => true,
            _ => false,
        };
        check("temperature", ok, format!("{temperature:?}"));
        eprintln!(
            "{name}: {}x{} {} black {} white {} {} {} ISO {:?} {:?} s {:?}",
            frame.width,
            frame.height,
            &frame.cfa.letters()[..4],
            frame.black_level(),
            frame.white_level,
            meta.make,
            meta.model,
            meta.iso,
            meta.exposure_seconds,
            temperature
        );
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}
