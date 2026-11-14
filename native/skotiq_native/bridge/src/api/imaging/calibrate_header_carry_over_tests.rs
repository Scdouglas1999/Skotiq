use super::api_calibrate_image_file;
use skotiq_imaging::{read_frame, write_fits, FitsHeader, ImageData, PixelType};
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

    let (_, out_header) = read_frame(&out).unwrap();
    assert_eq!(out_header.get_float("EXPTIME"), Some(120.0));
    assert_eq!(out_header.get_int("GAIN"), Some(100));
}

/// The calibrated frame keeps the light's cards in order, with their comments
/// and its COMMENT and HISTORY lines, and adds its own after them.
#[test]
fn calibrated_save_keeps_card_order_comments_and_history() {
    let light = scratch("ordered_light.fits");
    let out = scratch("ordered_calibrated.fits");

    let mut header = FitsHeader::new();
    header.set_string("OBJECT", "61");
    header.set_float("EXPTIME", 120.0);
    header.set_comment("EXPTIME", "exposure time (s)");
    header.set_string("FILTER", "Ha");
    header.add_comment("taken with Skotiq");
    header.add_history("dark subtracted on the camera");
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

    let (_, out_header) = read_frame(&out).unwrap();
    assert_eq!(out_header.get_string("OBJECT"), Some("61"));
    assert_eq!(out_header.get_comment("EXPTIME"), Some("exposure time (s)"));
    assert_eq!(out_header.comments, vec!["taken with Skotiq".to_string()]);
    assert_eq!(
        out_header.history,
        vec!["dark subtracted on the camera".to_string()]
    );
    let order: Vec<&str> = out_header
        .cards()
        .map(|(key, _, _)| key)
        .filter(|key| ["OBJECT", "EXPTIME", "FILTER", "CALSTAT"].contains(key))
        .collect();
    assert_eq!(order, ["OBJECT", "EXPTIME", "FILTER", "CALSTAT"]);
}

/// A camera's raw file cannot be written, so a calibrated copy named like one
/// is refused instead of being FITS bytes under a raw file's name.
#[test]
fn a_calibrated_copy_named_as_camera_raw_is_refused() {
    let light = scratch("raw_named_light.fits");
    let out = scratch("raw_named_calibrated.CR2");
    let _ = std::fs::remove_file(&out);
    write_fits(
        &light,
        &ImageData::new(4, 4, 1, PixelType::U16),
        &FitsHeader::new(),
    )
    .unwrap();

    let err = api_calibrate_image_file(
        light.to_string_lossy().into_owned(),
        None,
        None,
        None,
        out.to_string_lossy().into_owned(),
    )
    .unwrap_err();
    assert!(err.to_string().contains("camera raw"), "{err}");
    assert!(!out.exists());
}

/// A real library path is longer than one FITS card holds; the calibrated
/// frame is still written and names every master in full.
#[test]
fn calibrated_save_names_long_master_paths_in_full() {
    let library = std::env::temp_dir()
        .join("sk_calibrate_carry_over_test")
        .join("Calibration Library")
        .join("ZWO ASI2600MM Pro")
        .join("gain 100 offset 50 at -10 C")
        .join("2026-11-13 masters built from the full set of 40 subframes");
    std::fs::create_dir_all(&library).unwrap();
    let light = scratch("long_paths_light.fits");
    let out = scratch("long_paths_calibrated.fits");
    let dark = library.join("master_dark_300s_gain100_offset50_-10C.fits");
    let flat = library.join("master_flat_Ha_gain100_offset50.fits");
    let bias = library.join("master_bias_gain100_offset50_-10C.fits");
    let image = ImageData::from_u16(4, 4, 1, &[1000; 16]);
    write_fits(&light, &image, &FitsHeader::new()).unwrap();
    for master in [&dark, &flat, &bias] {
        assert!(master.to_string_lossy().len() > 150, "{}", master.display());
        let level = if master == &flat { 30000 } else { 100 };
        write_fits(
            master,
            &ImageData::from_u16(4, 4, 1, &[level; 16]),
            &FitsHeader::new(),
        )
        .unwrap();
    }
    let name = |p: &PathBuf| Some(p.to_string_lossy().into_owned());

    api_calibrate_image_file(
        light.to_string_lossy().into_owned(),
        name(&dark),
        name(&flat),
        name(&bias),
        out.to_string_lossy().into_owned(),
    )
    .expect("long master paths never fail the calibrated save");

    let (_, out_header) = read_frame(&out).unwrap();
    assert_eq!(
        out_header.get_string("CALSTAT"),
        Some("calibrated by Skotiq")
    );
    assert_eq!(out_header.get_string("DARKFILE"), name(&dark).as_deref());
    assert_eq!(out_header.get_string("FLATFILE"), name(&flat).as_deref());
    assert_eq!(out_header.get_string("BIASFILE"), name(&bias).as_deref());
}
