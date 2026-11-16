//! [`LightCalibration`] against PixInsight's ImageCalibration defaults:
//! `(light - bias - k·(dark - bias)) / (flat / mean(flat))` in floating
//! point, where `k` scales a dark of another exposure, a master flat is used
//! as it is and only a raw flat has the bias taken out first.

use super::{LightCalibration, CALIBRATION_PEDESTAL};
use skotiq_imaging::{write_fits, FitsHeader, ImageData};
use std::path::{Path, PathBuf};

const BIAS: u16 = 1000;
/// The flat's response, unit mean.
const RESPONSE: [f64; 4] = [0.8, 1.0, 1.2, 1.0];
/// Dark current plus bias.
const DARK: [u16; 4] = [1050, 1060, 1070, 1080];
/// What each calibrated pixel must read: a flat sky of 1000 ADU.
const SKY: f64 = 1000.0;

struct Dir(PathBuf);

impl Drop for Dir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn dir(name: &str) -> Dir {
    let path = std::env::temp_dir().join(format!("sk-light-cal-{name}-{}", std::process::id()));
    std::fs::create_dir_all(&path).expect("temp dir");
    Dir(path)
}

fn write(dir: &Path, name: &str, image: &ImageData, cards: &[(&str, &str)]) -> Option<String> {
    let mut header = FitsHeader::new();
    for (key, value) in cards {
        header.set_string(key, value);
    }
    let path = dir.join(name);
    write_fits(&path, image, &header).expect("frame written");
    Some(path.to_string_lossy().into_owned())
}

fn u16_frame(values: [f64; 4]) -> ImageData {
    let pixels: Vec<u16> = values.iter().map(|v| v.round() as u16).collect();
    ImageData::from_u16(4, 1, 1, &pixels)
}

/// A light of a flat `SKY` seen through `RESPONSE`, plus dark and bias.
fn light() -> ImageData {
    u16_frame(std::array::from_fn(|i| {
        f64::from(DARK[i]) + SKY * RESPONSE[i]
    }))
}

/// The calibrated samples with the pedestal taken out.
fn signal(calibration: &LightCalibration, light: &ImageData, exposure: Option<f64>) -> Vec<f64> {
    calibration
        .apply(light, exposure)
        .expect("calibrated")
        .image
        .samples_f64()
        .iter()
        .map(|v| v - f64::from(CALIBRATION_PEDESTAL))
        .collect()
}

fn calibrated(dir: &Dir, flat: Option<String>) -> Vec<f64> {
    let dark = write(&dir.0, "dark.fits", &u16_frame(DARK.map(f64::from)), &[]);
    let bias = write(&dir.0, "bias.fits", &u16_frame([f64::from(BIAS); 4]), &[]);
    let calibration = LightCalibration::load(&dark, &flat, &bias).expect("masters read");
    signal(&calibration, &light(), None)
}

fn assert_flat_sky(pixels: &[f64]) {
    for (i, &p) in pixels.iter().enumerate() {
        assert!(
            (p - SKY).abs() <= 0.5,
            "pixel {i} reads {p}, PixInsight gives {SKY}: {pixels:?}"
        );
    }
}

#[test]
fn a_float_master_flat_is_used_as_it_is() {
    let d = dir("float");
    let flat = ImageData::from_f32(4, 1, 1, &RESPONSE.map(|r| r as f32));
    let flat = write(&d.0, "flat.fits", &flat, &[("FRAMETYP", "MASTER")]);
    assert_flat_sky(&calibrated(&d, flat));
}

#[test]
fn an_integer_master_flat_is_not_bias_subtracted_again() {
    let d = dir("integer-master");
    let flat = u16_frame(RESPONSE.map(|r| 10_000.0 * r));
    let mut header = FitsHeader::new();
    header.set_int("NCOMBINE", 20);
    let path = d.0.join("flat.fits");
    write_fits(&path, &flat, &header).expect("flat written");
    assert_flat_sky(&calibrated(&d, Some(path.to_string_lossy().into_owned())));
}

#[test]
fn a_raw_flat_has_the_bias_taken_out_first() {
    let d = dir("raw");
    let flat = u16_frame(RESPONSE.map(|r| f64::from(BIAS) + 10_000.0 * r));
    let flat = write(&d.0, "flat.fits", &flat, &[("IMAGETYP", "FLAT")]);
    assert_flat_sky(&calibrated(&d, flat));
}

/// Sky that noise pulls below the dark keeps its value: the mean of a
/// background with no signal stays at zero instead of being lifted by
/// samples clipped at zero.
#[test]
fn noise_below_the_dark_is_kept() {
    let d = dir("below");
    let dark = write(&d.0, "dark.fits", &u16_frame([1050.0; 4]), &[]);
    let bias = write(&d.0, "bias.fits", &u16_frame([f64::from(BIAS); 4]), &[]);
    let calibration = LightCalibration::load(&dark, &None, &bias).expect("masters read");
    let light = u16_frame([1030.0, 1070.0, 1040.0, 1060.0]);
    let out = signal(&calibration, &light, None);
    assert_eq!(out, vec![-20.0, 20.0, -10.0, 10.0]);
    let sixteen_bit = calibration
        .apply(&light, None)
        .expect("calibrated")
        .sixteen_bit;
    assert_eq!(
        sixteen_bit.as_u16().expect("16-bit copy"),
        vec![80, 120, 90, 110],
        "the 16-bit copy keeps the samples below the dark through the pedestal"
    );
}

/// A dark of another exposure is scaled by the exposure ratio: its thermal
/// signal, not its bias, follows the light's exposure.
#[test]
fn a_dark_of_another_exposure_is_scaled_to_the_light() {
    let d = dir("scaled");
    let mut header = FitsHeader::new();
    header.set_float("EXPTIME", 300.0);
    let path = d.0.join("dark.fits");
    // 300 s of thermal signal over the bias: 10x what a 30 s light holds.
    let dark300 =
        u16_frame(DARK.map(|v| f64::from(BIAS) + 10.0 * (f64::from(v) - f64::from(BIAS))));
    write_fits(&path, &dark300, &header).expect("dark written");
    let dark = Some(path.to_string_lossy().into_owned());
    let bias = write(&d.0, "bias.fits", &u16_frame([f64::from(BIAS); 4]), &[]);
    let calibration = LightCalibration::load(&dark, &None, &bias).expect("masters read");
    let out = signal(&calibration, &light(), Some(30.0));
    for (i, v) in out.iter().enumerate() {
        assert!(
            (v - SKY * RESPONSE[i]).abs() <= 0.5,
            "pixel {i} reads {v}, the scaled dark leaves {}: {out:?}",
            SKY * RESPONSE[i]
        );
    }
    assert!(
        (calibration
            .apply(&light(), Some(30.0))
            .expect("calibrated")
            .dark_scale
            - 0.1)
            .abs()
            < 1e-9
    );
}

/// Without a bias the dark's thermal signal cannot be told from its pedestal,
/// so a dark of another exposure is refused rather than subtracted whole.
#[test]
fn a_dark_of_another_exposure_without_a_bias_is_refused() {
    let d = dir("unscalable");
    let mut header = FitsHeader::new();
    header.set_float("EXPTIME", 300.0);
    let path = d.0.join("dark.fits");
    write_fits(&path, &u16_frame(DARK.map(f64::from)), &header).expect("dark written");
    let dark = Some(path.to_string_lossy().into_owned());
    let calibration = LightCalibration::load(&dark, &None, &None).expect("masters read");
    let err = calibration
        .apply(&light(), Some(30.0))
        .err()
        .expect("refused");
    assert!(err.contains("master bias"), "{err}");
    assert!(calibration.apply(&light(), Some(300.0)).is_ok());
}
