//! Calibrating a file and calibrating pixels in memory follow one rule: with a
//! master bias, a master flat is used as it is (PixInsight's default), so a
//! light of a flat sky comes out flat, and sky below the bias keeps its value
//! over the frame's automatic output pedestal, which a file states.

use super::{api_calibrate_image_file, api_calibrated_light_pixels};
use skotiq_imaging::{read_frame, write_fits, FitsHeader, ImageData};

/// A flat sky of 1000 ADU seen through a 0.8 / 1.0 / 1.2 / 1.0 response.
const LIGHT: [u16; 4] = [1800, 2000, 2200, 2000];

fn path_of(dir: &std::path::Path, name: &str, pixels: [u16; 4], header: FitsHeader) -> String {
    let path = dir.join(name);
    write_fits(&path, &ImageData::from_u16(4, 1, 1, &pixels), &header).expect("frame written");
    path.to_string_lossy().into_owned()
}

fn assert_flat_sky(pixels: &[u16], how: &str) {
    assert!(
        pixels.iter().all(|&p| p.abs_diff(1000) <= 1),
        "{how}: {pixels:?}, PixInsight gives 1000 everywhere and no pedestal"
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

    let in_memory =
        api_calibrated_light_pixels(light.clone(), None, Some(flat.clone()), Some(bias.clone()))
            .expect("calibrated pixels");
    api_calibrate_image_file(
        light,
        None,
        Some(flat),
        Some(bias),
        out.to_string_lossy().into_owned(),
    )
    .expect("calibrated file");
    let (written, header) = read_frame(&out).expect("calibrated file reads");

    assert_eq!(in_memory.pedestal, 0.0);
    assert_flat_sky(&in_memory.data, "in memory");
    assert_flat_sky(&written.as_u16().expect("u16"), "file");
    assert!(
        header.get("PEDESTAL").is_none(),
        "a frame with no pedestal states none"
    );
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

    let in_memory = api_calibrated_light_pixels(light.clone(), None, None, Some(bias.clone()))
        .expect("calibrated pixels");
    api_calibrate_image_file(
        light,
        None,
        None,
        Some(bias),
        out.to_string_lossy().into_owned(),
    )
    .expect("calibrated file");
    let (written, header) = read_frame(&out).expect("calibrated file reads");

    // Samples -10, 10, -5, 5 over the bias: the smallest whole pedestal that
    // lifts -10 off zero is 11.
    assert_eq!(in_memory.pedestal, 11.0);
    assert_eq!(in_memory.data, vec![1, 21, 6, 16]);
    assert_eq!(written.as_u16().expect("u16"), vec![1, 21, 6, 16]);
    assert_eq!(header.get_float("PEDESTAL"), Some(11.0));
    let _ = std::fs::remove_dir_all(&dir);
}

/// A light whose header says it is calibrated (Skotiq's and MaxIm DL's
/// `CALSTAT`, PixInsight's ImageCalibration HISTORY) is not calibrated again.
#[test]
fn a_calibrated_light_is_not_calibrated_again() {
    let dir = std::env::temp_dir().join(format!("sk-calibrate-twice-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("temp dir");
    let bias = path_of(&dir, "bias.fits", [1000; 4], FitsHeader::new());
    let mut skotiq = FitsHeader::new();
    skotiq.set_string("CALSTAT", "calibrated by Skotiq");
    let mut pixinsight = FitsHeader::new();
    pixinsight.add_history("Calibration with ImageCalibration process");
    for (name, header) in [("skotiq_cal.fits", skotiq), ("pi_c.fits", pixinsight)] {
        let light = path_of(&dir, name, LIGHT, header);
        // Stack & Share's path: the calibrated light is used as it is.
        let pixels = api_calibrated_light_pixels(light.clone(), None, None, Some(bias.clone()))
            .expect("calibrated pixels");
        assert_eq!(
            pixels.data,
            LIGHT.to_vec(),
            "{name}: the bias is not taken out twice"
        );
        let out = dir.join(format!("again_{name}"));
        let result = api_calibrate_image_file(
            light,
            None,
            None,
            Some(bias.clone()),
            out.to_string_lossy().into_owned(),
        );
        let err = result.expect_err("a calibrated light is refused");
        assert!(format!("{err:?}").contains("already calibrated"), "{err:?}");
        assert!(
            !out.exists(),
            "{name}: no second calibrated copy is written"
        );
    }
    let _ = std::fs::remove_dir_all(&dir);
}

/// The light's stated pedestal leaves before calibration, as PixInsight's
/// ImageCalibration does by default.
#[test]
fn a_light_pedestal_leaves_before_calibration() {
    let dir = std::env::temp_dir().join(format!(
        "sk-calibrate-input-pedestal-{}",
        std::process::id()
    ));
    std::fs::create_dir_all(&dir).expect("temp dir");
    let bias = path_of(&dir, "bias.fits", [1000; 4], FitsHeader::new());
    let mut header = FitsHeader::new();
    header.set_float("PEDESTAL", 100.0);
    let light = path_of(&dir, "light.fits", LIGHT.map(|v| v + 100), header);
    let out = dir.join("calibrated.fits");
    api_calibrate_image_file(
        light,
        None,
        None,
        Some(bias),
        out.to_string_lossy().into_owned(),
    )
    .expect("calibrated");
    let (written, header) = read_frame(&out).expect("calibrated file reads");
    assert_eq!(written.as_u16().expect("u16"), vec![800, 1000, 1200, 1000]);
    assert!(header.get("PEDESTAL").is_none());
    let _ = std::fs::remove_dir_all(&dir);
}
