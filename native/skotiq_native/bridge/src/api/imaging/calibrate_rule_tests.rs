//! Calibrating a file and calibrating pixels in memory follow one rule: with a
//! master bias, a master flat is used as it is (PixInsight's default), so a
//! light of a flat sky comes out flat, and sky below the bias keeps its value
//! over the calibration pedestal.

use super::{api_calibrate_image_data, api_calibrate_image_file};
use skotiq_imaging::{read_frame, write_fits, FitsHeader, ImageData};
use skotiq_processing::post_session::CALIBRATION_PEDESTAL;

/// A flat sky of 1000 ADU seen through a 0.8 / 1.0 / 1.2 / 1.0 response.
const LIGHT: [u16; 4] = [1800, 2000, 2200, 2000];

fn path_of(dir: &std::path::Path, name: &str, pixels: [u16; 4], header: FitsHeader) -> String {
    let path = dir.join(name);
    write_fits(&path, &ImageData::from_u16(4, 1, 1, &pixels), &header).expect("frame written");
    path.to_string_lossy().into_owned()
}

fn assert_flat_sky(pixels: &[u16], how: &str) {
    let sky = 1000 + CALIBRATION_PEDESTAL as u16;
    assert!(
        pixels.iter().all(|&p| p.abs_diff(sky) <= 1),
        "{how}: {pixels:?}, PixInsight gives 1000 everywhere, here over the pedestal"
    );
}

#[test]
fn file_and_memory_calibration_use_a_master_flat_as_it_is() {
    let dir = std::env::temp_dir().join(format!("sk-calibrate-rule-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("temp dir");
    let bias = path_of(&dir, "bias.fits", [1000; 4], FitsHeader::new());
    let mut master = FitsHeader::new();
    master.set_int("NCOMBINE", 20);
    let flat = path_of(&dir, "flat.fits", [8000, 10000, 12000, 10000], master);
    let light = path_of(&dir, "light.fits", LIGHT, FitsHeader::new());
    let out = dir.join("calibrated.fits");

    let in_memory = api_calibrate_image_data(
        4,
        1,
        LIGHT.to_vec(),
        None,
        Some(flat.clone()),
        Some(bias.clone()),
    )
    .expect("calibrated in memory");
    api_calibrate_image_file(
        light,
        None,
        Some(flat),
        Some(bias),
        out.to_string_lossy().into_owned(),
    )
    .expect("calibrated file");
    let (written, _) = read_frame(&out).expect("calibrated file reads");

    assert_flat_sky(&in_memory, "in memory");
    assert_flat_sky(&written.as_u16().expect("u16"), "file");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn sky_below_the_bias_is_kept_and_the_pedestal_stated() {
    let dir = std::env::temp_dir().join(format!("sk-calibrate-below-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("temp dir");
    let bias = path_of(&dir, "bias.fits", [1000; 4], FitsHeader::new());
    let below = [990, 1010, 995, 1005];
    let light = path_of(&dir, "light.fits", below, FitsHeader::new());
    let out = dir.join("calibrated.fits");

    let in_memory = api_calibrate_image_data(4, 1, below.to_vec(), None, None, Some(bias.clone()))
        .expect("calibrated in memory");
    api_calibrate_image_file(
        light,
        None,
        None,
        Some(bias),
        out.to_string_lossy().into_owned(),
    )
    .expect("calibrated file");
    let (written, header) = read_frame(&out).expect("calibrated file reads");

    assert_eq!(in_memory, vec![90, 110, 95, 105]);
    assert_eq!(written.as_u16().expect("u16"), vec![90, 110, 95, 105]);
    assert_eq!(
        header.get_float("PEDESTAL"),
        Some(f64::from(CALIBRATION_PEDESTAL))
    );
    let _ = std::fs::remove_dir_all(&dir);
}
