//! `SipWcs::from_header` against astropy on every form a FITS header writes
//! its linear WCS in: a CD matrix, PC with CDELT, CDELT with CROTA2, the
//! precedence when a header carries more than one (PC, then CD, then CROTA2,
//! as wcslib reads them), and SIP distortion on top of CD and of PC.
//!
//! The expected sky positions in `test-fixtures/wcs-header-forms/astropy.json`
//! come from `astropy.wcs` (`all_pix2world`, origin 0) on the same cards;
//! `generate.py` beside it regenerates them.

use serde_json::Value;
use skotiq_imaging::{FitsHeader, SipWcs};
use std::path::Path;

/// Far below a pixel at any plate scale an amateur rig has (1e-9° is 4 µas).
const TOLERANCE_DEG: f64 = 1e-9;

fn fixture() -> Value {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../test-fixtures/wcs-header-forms/astropy.json");
    serde_json::from_str(&std::fs::read_to_string(&path).expect("fixture")).expect("json")
}

fn header_of(cards: &serde_json::Map<String, Value>) -> FitsHeader {
    let mut header = FitsHeader::new();
    for (key, value) in cards {
        match value {
            Value::String(text) => header.set_string(key, text),
            Value::Number(n) if n.is_i64() => header.set_int(key, n.as_i64().unwrap()),
            Value::Number(n) => header.set_float(key, n.as_f64().unwrap()),
            other => panic!("{key}: unexpected card value {other}"),
        }
    }
    header
}

#[test]
fn every_header_form_maps_pixels_to_the_sky_astropy_does() {
    let fixture = fixture();
    let forms = fixture["forms"].as_array().expect("forms");
    assert!(forms.len() >= 10);
    let mut wrong = Vec::new();
    for form in forms {
        let name = form["name"].as_str().unwrap();
        let header = header_of(form["cards"].as_object().unwrap());
        let Some(wcs) = SipWcs::from_header(&header) else {
            wrong.push(format!("{name}: no WCS"));
            continue;
        };
        for sample in form["sky"].as_array().unwrap() {
            let [x, y, ra, dec] = [0, 1, 2, 3].map(|i| sample[i].as_f64().unwrap());
            let (got_ra, got_dec) = wcs.pixel_to_world(x, y);
            let d_ra = ((got_ra - ra + 540.0) % 360.0 - 180.0) * dec.to_radians().cos();
            if d_ra.abs() >= TOLERANCE_DEG || (got_dec - dec).abs() >= TOLERANCE_DEG {
                wrong.push(format!(
                    "{name} at ({x}, {y}): ({got_ra}, {got_dec}), astropy ({ra}, {dec})"
                ));
            }
        }
    }
    assert!(wrong.is_empty(), "{}", wrong.join("\n"));
}
