use super::api_calibrate_image_file;
use skotiq_imaging::{read_fits, write_fits, FitsHeader, ImageData, PixelType};
use std::path::PathBuf;

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("sk_calibrate_carry_over_test");
    std::fs::create_dir_all(&dir).unwrap();
    dir.join(name)
}

/// The read path flattens header values to text; carrying them back with
/// set_string shipped EXPTIME = '120.0' — a string card that get_float
/// (and every stacker) reads as nothing.
#[test]
fn calibrated_save_keeps_numeric_exptime_and_gain() {
    let light = scratch("light.fits");
    let out = scratch("calibrated.fits");

    let mut header = FitsHeader::new();
    header.set_float("EXPTIME", 120.0);
    header.set_int("GAIN", 100);
    let image = ImageData::new(4, 4, 1, PixelType::U16);
    write_fits(&light, &image, &header).unwrap();

    api_calibrate_image_file(
        light.to_string_lossy().into_owned(),
        None,
        None,
        None,
        out.to_string_lossy().into_owned(),
    )
    .unwrap();

    let (_, out_header) = read_fits(&out).unwrap();
    assert_eq!(out_header.get_float("EXPTIME"), Some(120.0));
    assert_eq!(out_header.get_int("GAIN"), Some(100));
}
