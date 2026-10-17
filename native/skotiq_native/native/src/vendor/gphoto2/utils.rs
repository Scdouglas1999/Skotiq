//! Utility helpers shared by the gPhoto2 driver.

use super::*;

/// Convert a fixed-size c_char array to a Rust String.
pub(crate) fn cstr_from_array(arr: &[c_char]) -> String {
    let bytes: Vec<u8> = arr.iter().map(|&c| c as u8).collect();
    // Why: no NUL terminator → the whole fixed-size
    // array is the string (this happens for C arrays that are completely
    // full). `bytes.len()` is the correct upper bound for the slice.
    let null_pos = bytes.iter().position(|&b| b == 0).unwrap_or(bytes.len());
    String::from_utf8_lossy(&bytes[..null_pos]).to_string()
}

/// Sanitize a camera model name into a safe ID component.
pub(crate) fn sanitize_id(model: &str) -> String {
    model
        .chars()
        .map(|c| {
            if c.is_alphanumeric() || c == '-' || c == '_' {
                c.to_ascii_lowercase()
            } else {
                '_'
            }
        })
        .collect()
}

pub(crate) fn encode_port_component(port: &str) -> String {
    let mut encoded = String::with_capacity(port.len() * 2);
    for byte in port.as_bytes() {
        encoded.push_str(&format!("{:02x}", byte));
    }
    encoded
}

pub fn decode_port_component(encoded: &str) -> Option<String> {
    if !encoded.len().is_multiple_of(2) {
        return None;
    }

    let mut bytes = Vec::with_capacity(encoded.len() / 2);
    let mut idx = 0;
    while idx < encoded.len() {
        let next = idx + 2;
        let chunk = &encoded[idx..next];
        let byte = u8::from_str_radix(chunk, 16).ok()?;
        bytes.push(byte);
        idx = next;
    }

    String::from_utf8(bytes).ok()
}

pub fn build_device_id(index: usize, model: &str, port: &str) -> String {
    format!(
        "native:gphoto2:{}:{}:{}",
        index,
        encode_port_component(port),
        sanitize_id(model)
    )
}

/// Parse a shutter speed string (e.g., "1/250", "2.5", "30") to seconds.
pub(crate) fn parse_shutter_speed_to_secs(speed: &str) -> Option<f64> {
    let speed = speed.trim();

    // Handle "Bulb" or "bulb"
    if speed.eq_ignore_ascii_case("bulb") {
        return None;
    }

    // Handle fractional speeds like "1/250"
    if let Some(pos) = speed.find('/') {
        let num: f64 = speed[..pos].parse().ok()?;
        let den: f64 = speed[pos + 1..].parse().ok()?;
        if den != 0.0 {
            return Some(num / den);
        }
        return None;
    }

    // Handle decimal speeds like "2.5" or "30"
    speed.parse().ok()
}

/// Pick the Canon `eosremoterelease` Press / Release choice strings for bulb.
///
/// The choice ORDER varies between libgphoto2 versions, so we match by name
/// (mirroring gphoto_driver.cpp:1861-1874): Press prefers "Press Full MF",
/// then any "Press Full" variant; Release prefers plain "Release", then
/// "Release Full". Falls back to the canonical strings if nothing matches.
pub(crate) fn pick_eos_bulb_choices(choices: &[String]) -> (String, String) {
    let mut press: Option<String> = None;
    let mut release: Option<String> = None;

    for c in choices {
        // Press: exact "Press Full MF" wins; else first "Press Full" variant.
        if c == "Press Full MF" {
            press = Some(c.clone());
        } else if press.is_none() && c.contains("Press Full") {
            press = Some(c.clone());
        }

        // Release: plain "Release" wins; else "Release Full" if nothing yet.
        if c == "Release" {
            release = Some(c.clone());
        } else if release.is_none() && c == "Release Full" {
            release = Some(c.clone());
        }
    }

    (
        press.unwrap_or_else(|| "Press Full".to_string()),
        release.unwrap_or_else(|| "Release Full".to_string()),
    )
}

/// Pick the best RAW choice from an image-format widget's choices.
///
/// Prefers a PURE RAW choice so the downloaded NORMAL file is unambiguously the
/// RAW; falls back to any RAW-bearing choice (RAW+JPEG). Returns `None` if no
/// choice mentions RAW. A choice is treated as a RAW+JPEG COMBO if it contains
/// "+" (Canon "RAW + Large Fine JPEG", Nikon "NEF+Fine", Sony "RAW+JPEG") or an
/// explicit "jpeg"/"jpg" token — so pure "RAW" / "NEF (Raw)" win over combos.
pub(crate) fn pick_raw_format_choice(choices: &[String]) -> Option<String> {
    let is_raw = |c: &str| {
        let l = c.to_lowercase();
        l.contains("raw") || l.contains("nef")
    };
    let is_combo = |c: &str| {
        let l = c.to_lowercase();
        l.contains('+') || l.contains("jpeg") || l.contains("jpg")
    };

    // Pure RAW first.
    if let Some(c) = choices.iter().find(|c| is_raw(c) && !is_combo(c)) {
        return Some(c.clone());
    }
    // Then any RAW-bearing choice (e.g. RAW+JPEG).
    choices.iter().find(|c| is_raw(c)).cloned()
}

/// Resolve `SensorInfo::max_adu` — the largest value a pixel in the delivered
/// buffer can actually take — for a DSLR frame, in descending order of
/// authority:
///
/// 1. `measured_white_level`: LibRaw `color.maximum` for the last decoded
///    frame, surfaced as `skotiq_imaging::CfaImage::max_value`. Exact.
/// 2. `(1 << bit_depth) - 1` from the model table in
///    `detect_sensor_dimensions()`, used only before the first frame has been
///    decoded (and clamped to a sane 8..=16 so a corrupt depth cannot panic
///    the shift or publish an absurd ceiling).
///
/// The DSLR decode path is `libraw_unpack` + `libraw_raw2image` and
/// deliberately never `libraw_dcraw_process` (imaging/src/raw.rs:1097-1108;
/// contract comment in imaging/src/libraw_shim.c:98-102), so samples are
/// RIGHT-JUSTIFIED at the sensor's native depth. `(1 << bits) - 1` is therefore
/// the correct shape here, and this path must NEVER left-shift the value into a
/// 16-bit container the way a left-justifying astro-CMOS SDK requires — see the
/// `SensorInfo` type docs in `crate::camera`.
pub(crate) fn resolve_max_adu(measured_white_level: Option<u32>, bit_depth: u32) -> u32 {
    match measured_white_level {
        Some(white) if white > 0 => white,
        _ => (1u32 << bit_depth.clamp(8, 16)) - 1,
    }
}
