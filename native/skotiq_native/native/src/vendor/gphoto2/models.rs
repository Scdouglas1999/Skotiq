//! Sensor geometry of the bodies libgphoto2 reaches, by model name.
//!
//! A body does not report its pixel pitch over PTP, and plate solving and
//! XPIXSZ need it, so it comes from this table (manufacturer specifications).
//! The frame size is replaced by the decoded frame's own size after the first
//! exposure. A body that is not listed has no pitch: Skotiq writes none rather
//! than a guess.

/// Effective raw size in pixels, pixel pitch in micrometers, and the raw
/// files' bit depth (an estimate until a frame is decoded).
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct SensorSpec {
    pub(crate) width: u32,
    pub(crate) height: u32,
    pub(crate) pixel_um: f64,
    pub(crate) bits: u32,
}

const fn spec(width: u32, height: u32, pixel_um: f64) -> SensorSpec {
    SensorSpec {
        width,
        height,
        pixel_um,
        bits: 14,
    }
}

const fn twelve_bit(spec: SensorSpec) -> SensorSpec {
    SensorSpec { bits: 12, ..spec }
}

const CANON_APSC_18MP: SensorSpec = spec(5184, 3456, 4.3);
const CANON_APSC_24MP: SensorSpec = spec(6000, 4000, 3.72);
const NIKON_DX_16MP: SensorSpec = spec(4928, 3264, 4.78);
const NIKON_DX_24MP: SensorSpec = spec(6000, 4000, 3.92);
const NIKON_DX_21MP: SensorSpec = spec(5568, 3712, 4.22);
const FX_24MP: SensorSpec = spec(6016, 4016, 5.95);
const FX_45MP: SensorSpec = spec(8256, 5504, 4.35);
const SONY_APSC_24MP: SensorSpec = spec(6000, 4000, 3.92);
const MFT_16MP: SensorSpec = twelve_bit(spec(4608, 3456, 3.74));
const MFT_20MP: SensorSpec = twelve_bit(spec(5184, 3888, 3.32));

/// Keys are [`model_key`] of libgphoto2's model names ("Canon EOS 6d Mark II"
/// -> "canon6dm2", "Nikon Z6_2" -> "nikonz6m2", "Sony Alpha-A7III (Control)"
/// -> "sonya7m3").
const BODIES: &[(&[&str], SensorSpec)] = &[
    // Canon full frame
    (&["canon6d"], spec(5472, 3648, 6.54)),
    (&["canon6dm2"], spec(6240, 4160, 5.67)),
    (&["canon5dm2"], spec(5616, 3744, 6.41)),
    (&["canon5dm3"], spec(5760, 3840, 6.25)),
    (&["canon5dm4", "canonr", "canonra"], spec(6720, 4480, 5.36)),
    (&["canon5ds", "canon5dsr"], spec(8688, 5792, 4.14)),
    (&["canonrp"], spec(6240, 4160, 5.75)),
    (&["canonr5"], spec(8192, 5464, 4.39)),
    (&["canonr6"], spec(5472, 3648, 6.56)),
    (&["canonr6m2", "canonr8", "canonr3"], spec(6000, 4000, 5.98)),
    // Canon APS-C
    (
        &["canon1000d", "canonrebelxs"],
        twelve_bit(spec(3888, 2592, 5.71)),
    ),
    (
        &["canon450d", "canonrebelxsi", "canon1100d", "canonrebelt3"],
        spec(4272, 2848, 5.19),
    ),
    (&["canon500d", "canonrebelt1i"], spec(4752, 3168, 4.69)),
    (
        &[
            "canon550d",
            "canonrebelt2i",
            "canon600d",
            "canonrebelt3i",
            "canon650d",
            "canonrebelt4i",
            "canon700d",
            "canonrebelt5i",
            "canon100d",
            "canonrebelsl1",
            "canon1200d",
            "canonrebelt5",
            "canon1300d",
            "canonrebelt6",
            "canon4000d",
            "canon60d",
            "canon60da",
            "canon7d",
        ],
        CANON_APSC_18MP,
    ),
    (&["canon7dm2"], spec(5472, 3648, 4.09)),
    (
        &[
            "canon750d",
            "canonrebelt6i",
            "canon760d",
            "canonrebelt6s",
            "canon800d",
            "canonrebelt7i",
            "canon77d",
            "canon80d",
            "canon200d",
            "canonrebelsl2",
            "canon250d",
            "canonrebelsl3",
            "canon850d",
            "canonrebelt8i",
            "canon2000d",
            "canonrebelt7",
            "canonm50",
            "canonm50m2",
            "canonr10",
            "canonr50",
            "canonr100",
        ],
        CANON_APSC_24MP,
    ),
    (&["canon90d", "canonr7"], spec(6960, 4640, 3.21)),
    // Nikon
    (&["nikond850", "nikonz7", "nikonz7m2"], FX_45MP),
    (
        &["nikond800", "nikond800e", "nikond810", "nikond810a"],
        spec(7360, 4912, 4.88),
    ),
    (&["nikond600", "nikond610", "nikond750", "nikonz5"], FX_24MP),
    (
        &["nikonz6", "nikonz6m2", "nikond780"],
        spec(6048, 4024, 5.94),
    ),
    (
        &["nikond90", "nikond5000"],
        twelve_bit(spec(4288, 2848, 5.5)),
    ),
    (&["nikond7000", "nikond5100"], NIKON_DX_16MP),
    (
        &[
            "nikond7100",
            "nikond7200",
            "nikond5200",
            "nikond5300",
            "nikond5500",
            "nikond5600",
            "nikond3200",
            "nikond3300",
            "nikond3400",
            "nikond3500",
        ],
        NIKON_DX_24MP,
    ),
    (
        &[
            "nikond7500",
            "nikond500",
            "nikonz50",
            "nikonz50m2",
            "nikonzfc",
            "nikonz30",
        ],
        NIKON_DX_21MP,
    ),
    // Sony
    (&["sonya7"], spec(6000, 4000, 5.98)),
    (&["sonya7m2", "sonya7m3"], spec(6000, 4000, 5.93)),
    (&["sonya7m4"], spec(7008, 4672, 5.12)),
    (
        &["sonya7r", "sonya7rm2", "sonya7rm3"],
        spec(7952, 5304, 4.51),
    ),
    (&["sonya7rm4"], spec(9504, 6336, 3.76)),
    (
        &["sonya7s", "sonya7sm2", "sonya7sm3"],
        spec(4240, 2832, 8.4),
    ),
    (
        &[
            "sonya6000",
            "sonya6100",
            "sonya6300",
            "sonya6400",
            "sonya6500",
            "sonya6600",
        ],
        SONY_APSC_24MP,
    ),
    // Pentax
    (&["pentaxk10d"], twelve_bit(spec(3872, 2592, 6.05))),
    (
        &[
            "pentaxk5",
            "pentaxk5m2",
            "pentaxk5m2s",
            "pentaxk30",
            "pentaxk50",
            "pentaxk01",
        ],
        NIKON_DX_16MP,
    ),
    (
        &[
            "pentaxk3",
            "pentaxk3m2",
            "pentaxk3m3",
            "pentaxk70",
            "pentaxkp",
        ],
        spec(6000, 4000, 3.9),
    ),
    (&["pentaxk1", "pentaxk1m2"], spec(7360, 4912, 4.88)),
    // Olympus / OM System
    (
        &[
            "olympusem1",
            "olympusem5m2",
            "olympusem10",
            "olympusem10m2",
            "olympusem10m3",
        ],
        MFT_16MP,
    ),
    (
        &[
            "olympusem1m2",
            "olympusem1m3",
            "olympusem5m3",
            "olympusem10m4",
            "olympusom1",
        ],
        MFT_20MP,
    ),
    // Panasonic
    (&["panasonicdmcgh4", "panasonicgh4"], MFT_16MP),
    (
        &[
            "panasonicdcg9",
            "panasonicdcgh5",
            "panasonicg9",
            "panasonicgh5",
        ],
        MFT_20MP,
    ),
    (
        &[
            "panasonicdcs1",
            "panasonicdcs5",
            "panasonics1",
            "panasonics5",
        ],
        spec(6000, 4000, 5.95),
    ),
];

/// A model name reduced to maker and body: lowercase, the parenthesized
/// connection mode and the "EOS"/"DSC"/"Alpha"/"Fujifilm" family words gone,
/// generation marks ("Mark II", "II", "MII", "_2", "m2") written "m2".
pub(crate) fn model_key(model: &str) -> String {
    let lower = model.to_lowercase();
    let without_mode = lower.split('(').next().unwrap_or_default();
    let mut key = String::new();
    for token in without_mode.split(|c: char| c.is_whitespace() || c == '_') {
        let token = token.trim_matches('-');
        match token {
            "" | "eos" | "dsc" | "fujifilm" | "mark" | "inc." => {}
            t if t.starts_with("alpha") => {
                key.push_str(&roman_suffix(&t["alpha".len()..].replace('-', "")))
            }
            t => match generation(t) {
                Some(n) => key.push_str(&format!("m{n}")),
                None => key.push_str(&roman_suffix(&t.replace('-', ""))),
            },
        }
    }
    key
}

/// "ii" -> 2 for a token that is only a generation mark.
fn generation(token: &str) -> Option<u32> {
    match token {
        "ii" | "mii" | "m2" | "2" => Some(2),
        "iii" | "miii" | "m3" | "3" => Some(3),
        "iv" | "miv" | "m4" | "4" => Some(4),
        _ => None,
    }
}

/// "a7iii" -> "a7m3": a generation written onto the model number.
fn roman_suffix(token: &str) -> String {
    for (roman, n) in [("iii", 3), ("ii", 2), ("iv", 4)] {
        if let Some(stem) = token.strip_suffix(roman) {
            if stem.ends_with(|c: char| c.is_ascii_digit()) {
                return format!("{stem}m{n}");
            }
        }
    }
    token.to_string()
}

/// The sensor of a body named by libgphoto2, when Skotiq knows it.
pub(crate) fn sensor_spec(model: &str) -> Option<SensorSpec> {
    let key = model_key(model);
    if let Some(fuji) = key.strip_prefix("fuji") {
        let body = crate::vendor::fujifilm::FujifilmModel::from_product_name(fuji);
        if body == crate::vendor::fujifilm::FujifilmModel::Unknown {
            return None;
        }
        let (width, height, pixel_um, bits) = body.sensor_specs();
        return Some(SensorSpec {
            width,
            height,
            pixel_um,
            bits,
        });
    }
    BODIES
        .iter()
        .find(|(keys, _)| keys.contains(&key.as_str()))
        .map(|(_, spec)| *spec)
}
