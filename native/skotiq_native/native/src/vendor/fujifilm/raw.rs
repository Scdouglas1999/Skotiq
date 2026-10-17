//! Raw sample depth resolution and RAF processing.

use super::*;

// Raw sample depth

/// A bit depth this driver is willing to believe. LibRaw clamps its own derived
/// depth to 8..=16 and `SensorInfo` pixels are `u16`, so anything outside that
/// range is a bad read rather than a real sensor.
pub(crate) fn is_plausible_bit_depth(bits: &u32) -> bool {
    (8..=16).contains(bits)
}

/// Map an `XSDK` RAW-output-depth code to a bit count.
///
/// XAPIOpt.H:584-585: `SDK_RAWOUTPUTDEPTH_14BIT = 0x0001`,
/// `SDK_RAWOUTPUTDEPTH_16BIT = 0x0002`. Anything else means the body did not
/// answer the query (X-series bodies declare `CapRAWOutputDepth = -1`).
pub(crate) fn raw_output_depth_to_bits(code: c_long) -> Option<u32> {
    match code {
        SDK_RAWOUTPUTDEPTH_14BIT => Some(14),
        SDK_RAWOUTPUTDEPTH_16BIT => Some(16),
        _ => None,
    }
}

/// Resolve `SensorInfo::bit_depth` from the three sources this driver has, in
/// descending order of authority: measured from the decoded frame
/// (`CfaImage::bits_per_pixel`), reported by the camera
/// (`XSDK_ImageInformation::lImageBitDepth`, XAPI.H:123, or
/// `XSDK_GetProp(API_CODE_GetRAWOutputDepth)`, XAPIOpt.H:229), then the
/// `FujifilmModel::sensor_specs` table.
pub(crate) fn resolve_bit_depth(
    measured_bits: Option<u32>,
    sdk_reported_bits: Option<u32>,
    model_table_bits: u32,
) -> u32 {
    measured_bits
        .filter(is_plausible_bit_depth)
        .or_else(|| sdk_reported_bits.filter(is_plausible_bit_depth))
        .unwrap_or(model_table_bits)
        .clamp(8, 16)
}

/// Resolve `SensorInfo::max_adu` — the largest value a pixel in the delivered
/// buffer can actually take.
///
/// A measured white level (`CfaImage::max_value`, LibRaw `color.maximum`) is
/// exact and wins; otherwise the resolved `bit_depth` gives `(1 << bits) - 1`.
///
/// That formula is correct HERE because the RAF decode is `unpack` +
/// `raw2image` with no `dcraw_process` (imaging/src/raw.rs:1097-1108; contract
/// in imaging/src/libraw_shim.c:98-102), so samples are RIGHT-JUSTIFIED at the
/// sensor's native depth. This path must NEVER left-shift the value into a
/// 16-bit container the way a left-justifying astro-CMOS SDK requires — see the
/// `SensorInfo` type docs in `crate::camera`.
pub(crate) fn resolve_max_adu(measured_white_level: Option<u32>, bit_depth: u32) -> u32 {
    match measured_white_level {
        Some(white) if white > 0 => white,
        _ => (1u32 << bit_depth.clamp(8, 16)) - 1,
    }
}

// RAF processing

/// Decode a RAF buffer into its native single-channel LINEAR CFA mosaic.
///
/// Decodes straight from the buffer (no temp file → no filename collision
/// between concurrent captures) via `read_cfa_mosaic_from_bytes`, which does
/// `unpack` + `raw2image` with NO `dcraw_process` — so the result is the
/// sensor's raw linear mosaic, one u16 per pixel, NOT a demosaiced/white-
/// balanced/gamma-encoded 3-channel sRGB image. Feeding processed RGB into the
/// mono-mosaic contract corrupts every frame (3× oversize, non-linear, and —
/// for the Bayer GFX bodies — double-debayered).
pub(crate) fn process_raf_buffer(
    buffer: &[u8],
    _is_xtrans: bool,
) -> Result<skotiq_imaging::CfaImage, NativeError> {
    let (cfa, _metadata) = skotiq_imaging::read_cfa_mosaic_from_bytes(buffer, "raf")
        .map_err(|e| NativeError::SdkError(format!("LibRaw processing failed: {}", e)))?;

    // Contract guard: the mono mosaic MUST be exactly width*height samples.
    let expected = (cfa.width as usize) * (cfa.height as usize);
    if cfa.data.len() != expected {
        return Err(NativeError::SdkError(format!(
            "Fujifilm: CFA decode produced {} samples for a {}x{} frame (expected {}) — \
             refusing to emit a corrupt frame",
            cfa.data.len(),
            cfa.width,
            cfa.height,
            expected
        )));
    }

    Ok(cfa)
}
