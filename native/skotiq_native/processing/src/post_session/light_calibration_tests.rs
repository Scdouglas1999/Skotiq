//! [`LightCalibration`] against PixInsight's ImageCalibration defaults:
//! `(light - bias - (dark - bias)) / (flat / mean(flat))`, where a master flat
//! is used as it is and only a raw flat has the bias taken out first.

use super::LightCalibration;
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

fn calibrated(dir: &Dir, flat: Option<String>) -> Vec<u16> {
    let dark = write(&dir.0, "dark.fits", &u16_frame(DARK.map(f64::from)), &[]);
    let bias = write(&dir.0, "bias.fits", &u16_frame([f64::from(BIAS); 4]), &[]);
    LightCalibration::load(&dark, &flat, &bias)
        .expect("masters read")
        .apply(&light())
        .expect("calibrated")
        .as_u16()
        .expect("u16 light stays u16")
}

fn assert_flat_sky(pixels: &[u16]) {
    for (i, &p) in pixels.iter().enumerate() {
        assert!(
            (f64::from(p) - SKY).abs() <= 1.0,
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
