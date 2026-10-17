//! `write_fits` transcodes pixel data to big-endian FITS order in 64 KiB
//! blocks rather than one `write_all` per sample. These tests pin the output
//! byte-for-byte against an independent per-sample reference so the block loop
//! — including its boundary handling and the record padding — cannot drift.

use skotiq_imaging::{write_fits, FitsHeader, ImageData, PixelType};

const RECORD: usize = 2880;

fn temp_dir(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "sk-write-fits-parity-{}-{}",
        std::process::id(),
        tag
    ));
    std::fs::create_dir_all(&dir).expect("create temp dir");
    dir
}

/// Split a written FITS file into (header records, data section) using the
/// file's own END card position.
fn split_header_and_data(bytes: &[u8]) -> (&[u8], &[u8]) {
    let mut record = 0;
    loop {
        let start = record * RECORD;
        let block = &bytes[start..start + RECORD];
        if block
            .as_chunks::<80>()
            .0
            .iter()
            .any(|card| card.starts_with(b"END") && card[3..].iter().all(|&b| b == b' '))
        {
            let split = start + RECORD;
            return (&bytes[..split], &bytes[split..]);
        }
        record += 1;
        assert!(record * RECORD < bytes.len(), "no END card in written file");
    }
}

fn image_of(pixel_type: PixelType, width: u32, height: u32, data: Vec<u8>) -> ImageData {
    ImageData {
        width,
        height,
        channels: 1,
        pixel_type,
        data,
    }
}

fn assert_data_section_matches(image: &ImageData, expected: &[u8], tag: &str) {
    let dir = temp_dir(tag);
    let path = dir.join("out.fits");

    let mut header = FitsHeader::new();
    header.set_string("FILTER", "Ha");
    header.set_float("EXPTIME", 120.0);
    write_fits(&path, image, &header).expect("write_fits");

    let bytes = std::fs::read(&path).expect("read back");
    assert_eq!(bytes.len() % RECORD, 0, "{tag}: file is not whole records");

    let (header_bytes, data) = split_header_and_data(&bytes);
    let header_padding_start = header_bytes
        .windows(3)
        .rposition(|w| w == b"END")
        .expect("END card");
    assert!(
        header_bytes[header_padding_start + 3..]
            .iter()
            .all(|&b| b == b' '),
        "{tag}: header padding must be spaces"
    );

    assert_eq!(
        &data[..expected.len()],
        expected,
        "{tag}: data section diverged from the per-sample reference"
    );
    assert!(
        data[expected.len()..].iter().all(|&b| b == 0),
        "{tag}: data padding must be zeros"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn u16_data_matches_per_sample_reference() {
    // 37x23 = 851 samples: not a multiple of the 2880-byte record, so the
    // padding branch runs.
    let (w, h) = (37u32, 23u32);
    let pixels: Vec<u16> = (0..(w * h) as usize)
        .map(|i| (i * 79 % 65535) as u16)
        .collect();
    let expected: Vec<u8> = pixels
        .iter()
        .flat_map(|&v| ((v as i32 - 32768) as i16).to_be_bytes())
        .collect();

    assert_data_section_matches(&ImageData::from_u16(w, h, 1, &pixels), &expected, "u16");
}

#[test]
fn u32_data_matches_per_sample_reference() {
    let (w, h) = (37u32, 23u32);
    let values: Vec<u32> = (0..(w * h) as usize)
        .map(|i| (i as u32).wrapping_mul(2_863_311_530))
        .collect();
    let le: Vec<u8> = values.iter().flat_map(|v| v.to_le_bytes()).collect();
    let expected: Vec<u8> = values
        .iter()
        .flat_map(|&v| ((v as i64 - 2_147_483_648) as i32).to_be_bytes())
        .collect();

    assert_data_section_matches(&image_of(PixelType::U32, w, h, le), &expected, "u32");
}

#[test]
fn f32_data_matches_per_sample_reference() {
    let (w, h) = (37u32, 23u32);
    let values: Vec<f32> = (0..(w * h) as usize)
        .map(|i| i as f32 * 0.5 - 3.25)
        .collect();
    let le: Vec<u8> = values.iter().flat_map(|v| v.to_le_bytes()).collect();
    let expected: Vec<u8> = values.iter().flat_map(|v| v.to_be_bytes()).collect();

    assert_data_section_matches(&image_of(PixelType::F32, w, h, le), &expected, "f32");
}

#[test]
fn f64_data_matches_per_sample_reference() {
    let (w, h) = (37u32, 23u32);
    let values: Vec<f64> = (0..(w * h) as usize)
        .map(|i| i as f64 * 0.125 - 7.5)
        .collect();
    let le: Vec<u8> = values.iter().flat_map(|v| v.to_le_bytes()).collect();
    let expected: Vec<u8> = values.iter().flat_map(|v| v.to_be_bytes()).collect();

    assert_data_section_matches(&image_of(PixelType::F64, w, h, le), &expected, "f64");
}

/// The block loop must be seamless across its 64 KiB boundary: this image is
/// 320 KB of f64 samples, so it spans five whole blocks plus a partial one.
#[test]
fn multi_block_image_has_no_seam_at_the_block_boundary() {
    let (w, h) = (211u32, 199u32);
    let values: Vec<f64> = (0..(w * h) as usize)
        .map(|i| (i as f64).sin() * 1_000.0)
        .collect();
    assert!(values.len() * 8 > 5 * 64 * 1024);

    let le: Vec<u8> = values.iter().flat_map(|v| v.to_le_bytes()).collect();
    let expected: Vec<u8> = values.iter().flat_map(|v| v.to_be_bytes()).collect();

    assert_data_section_matches(&image_of(PixelType::F64, w, h, le), &expected, "f64-blocks");
}

/// A trailing byte that cannot form a whole sample is dropped, exactly as the
/// per-sample `chunks_exact` loop did.
///
/// Checked on its own rather than through `assert_data_section_matches`: with a
/// malformed `ImageData` whose length is not a whole number of samples, the
/// record padding is derived from `data.len()` rather than from the bytes
/// actually written, so the file does not end on a record boundary. That is
/// pre-existing `write_fits` behaviour, preserved here byte-for-byte.
#[test]
fn trailing_partial_sample_is_dropped() {
    let dir = temp_dir("partial");
    let path = dir.join("out.fits");

    let mut data: Vec<u8> = (0..16u16).flat_map(|i| i.to_le_bytes()).collect();
    data.push(0xAB);
    let image = image_of(PixelType::U16, 4, 4, data);

    write_fits(&path, &image, &FitsHeader::new()).expect("write_fits");
    let bytes = std::fs::read(&path).expect("read back");
    let (_, written) = split_header_and_data(&bytes);

    let expected: Vec<u8> = (0..16u16)
        .flat_map(|v| ((v as i32 - 32768) as i16).to_be_bytes())
        .collect();
    assert_eq!(&written[..expected.len()], &expected[..]);
    assert!(written[expected.len()..].iter().all(|&b| b == 0));

    let _ = std::fs::remove_dir_all(&dir);
}
