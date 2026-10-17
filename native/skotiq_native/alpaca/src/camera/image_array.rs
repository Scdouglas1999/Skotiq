//! Alpaca `imagearray` JSON decoder.

use super::*;

// Image-array JSON parser

/// Parse an Alpaca `imagearray` JSON response into `ImageArrayResult`.
///
/// Why this is a free function (not a method): isolating the pure parser
/// makes it directly unit-testable without spinning up an HTTP server.
///
/// # Error semantics
///
/// * Any pixel that is not a JSON number — or, for an integer `Type`, a
///   fractional number — yields `AlpacaError::PixelParseError` carrying the
///   linear pixel offset and the offending JSON token. **No silent
///   zero-substitution.**
/// * Unknown `Type` or unsupported `(Rank, Type)` combinations yield
///   `AlpacaError::UnsupportedImageArray` instead of guessing.
/// * Mismatched array shape vs. `(width, height)` is `AlpacaError::ParseError`.
pub(crate) fn parse_image_array_json(
    body: &str,
    width: u32,
    height: u32,
) -> Result<ImageArrayResult, AlpacaError> {
    let json: serde_json::Value = serde_json::from_str(body)
        .map_err(|e| AlpacaError::ParseError(format!("Failed to parse image array JSON: {}", e)))?;

    // Why: surface device-reported errors before attempting to parse Value;
    // the array may be absent or junk when ErrorNumber != 0.
    if let Some(error_num) = json.get("ErrorNumber").and_then(|v| v.as_i64()) {
        if error_num != 0 {
            // Why: the Alpaca spec requires ErrorMessage
            // alongside a non-zero ErrorNumber, but some pre-v3 servers omit
            // the message field. We already surface the *real* failure via
            // `code: error_num`; the textual fallback is a cosmetic label for
            // log/UI display and converting absence to a hard error here would
            // mask the actual device error code we're trying to report.
            let error_msg = json
                .get("ErrorMessage")
                .and_then(|v| v.as_str())
                .unwrap_or("Unknown error")
                .to_string();
            // Why: ASCOM ErrorNumber is defined as a
            // signed 32-bit value (see ASCOM Master Interfaces). JSON
            // parses to i64 so a wire bug could exceed i32 range; saturate
            // at i32 boundaries — the structured error string still carries
            // the full diagnostic via `message`.
            return Err(AlpacaError::DeviceError {
                code: i32::try_from(error_num).unwrap_or(i32::MIN),
                message: error_msg,
            });
        }
    }

    // Why: Type/Rank are required to pick a decoder. The Alpaca spec mandates
    // them; a missing field is a server bug we should report, not paper over.
    let element_type_raw = json
        .get("Type")
        .and_then(|v| v.as_i64())
        .ok_or_else(|| AlpacaError::ParseError("Missing or non-integer Type field".to_string()))?;
    let element_type = ImageArrayElementType::from_i64(element_type_raw);
    if matches!(element_type, ImageArrayElementType::Unknown) {
        // Why: we're already returning a hard
        // UnsupportedImageArray error; the `rank` field on this variant is a
        // diagnostic-only side input. If Rank is also missing/malformed we
        // report 0 to make that visible in the error payload — the real
        // failure (`unrecognised Type`) is already encoded in `reason`, and
        // converting Rank to `?` would hide the actual type-mismatch failure
        // behind a separate "Missing Rank" error.
        return Err(AlpacaError::UnsupportedImageArray {
            rank: json.get("Rank").and_then(|v| v.as_i64()).unwrap_or(0),
            image_type: element_type_raw,
            reason: format!("unrecognised Type {}", element_type_raw),
        });
    }

    let rank = json
        .get("Rank")
        .and_then(|v| v.as_i64())
        .ok_or_else(|| AlpacaError::ParseError("Missing or non-integer Rank field".to_string()))?;

    let value = json.get("Value").ok_or_else(|| {
        AlpacaError::ParseError("Missing Value field in image array response".to_string())
    })?;

    let outer = value
        .as_array()
        .ok_or_else(|| AlpacaError::ParseError("Image array Value is not an array".to_string()))?;

    match rank {
        2 => parse_rank2(outer, element_type, width, height),
        3 => parse_rank3(outer, element_type, width, height),
        other => Err(AlpacaError::UnsupportedImageArray {
            rank: other,
            image_type: element_type_raw,
            reason: "only rank 2 (mono) and rank 3 (color) are supported".to_string(),
        }),
    }
}

/// Parse a `[NumX][NumY]` rank-2 image into a single-plane `ImageArrayResult`.
fn parse_rank2(
    outer: &[serde_json::Value],
    element_type: ImageArrayElementType,
    width: u32,
    height: u32,
) -> Result<ImageArrayResult, AlpacaError> {
    // Why: u32 → usize is widening on every supported
    // target (≥ 32-bit usize); `checked_mul` then catches any overflow at
    // the product boundary on 32-bit-usize hosts.
    let expected = (width as usize)
        .checked_mul(height as usize)
        .ok_or_else(|| AlpacaError::ParseError("width*height overflow".to_string()))?;
    let mut pixels: Vec<u16> = Vec::with_capacity(expected);

    // Alpaca rank-2 layout is [NumX][NumY] (column-major). We iterate the
    // outer (X) dimension then the inner (Y) dimension; the resulting flat
    // vector is column-major in (x, y) — identical to the historical layout
    // produced by the buggy loop, so existing consumers keep working.
    let mut offset: usize = 0;
    for inner in outer.iter() {
        let inner_arr = inner.as_array().ok_or_else(|| {
            AlpacaError::ParseError(format!(
                "Image array row at offset {} is not an array",
                offset
            ))
        })?;
        for pixel in inner_arr.iter() {
            let v = decode_pixel(pixel, element_type, offset)?;
            pixels.push(v);
            offset += 1;
        }
    }

    if pixels.len() != expected {
        return Err(AlpacaError::ParseError(format!(
            "Image size mismatch: expected {} pixels ({}x{}), got {}",
            expected,
            width,
            height,
            pixels.len()
        )));
    }

    Ok(ImageArrayResult {
        width,
        height,
        planes: 1,
        pixels,
        element_type,
    })
}

/// Parse a `[NumX][NumY][NumPlanes]` rank-3 image into a planar
/// `ImageArrayResult`.
///
/// Why planar (not interleaved): keeps each channel a contiguous slice for
/// downstream debayer/demosaic consumers, and matches what the Alpaca spec
/// stores on the wire when `NumPlanes` is the innermost dimension.
fn parse_rank3(
    outer: &[serde_json::Value],
    element_type: ImageArrayElementType,
    width: u32,
    height: u32,
) -> Result<ImageArrayResult, AlpacaError> {
    if outer.is_empty() {
        return Err(AlpacaError::ParseError(
            "Rank-3 image array has zero columns".to_string(),
        ));
    }

    // Why: detect planes from the first innermost array; we validate every
    // pixel matches this width to catch truncation/corruption.
    let first_col = outer[0]
        .as_array()
        .ok_or_else(|| AlpacaError::ParseError("Rank-3 outer[0] is not an array".to_string()))?;
    if first_col.is_empty() {
        return Err(AlpacaError::ParseError(
            "Rank-3 image array has zero rows".to_string(),
        ));
    }
    let first_pixel = first_col[0]
        .as_array()
        .ok_or_else(|| AlpacaError::ParseError("Rank-3 outer[0][0] is not an array".to_string()))?;
    // Why: plane-count comes from a JSON array `.len()`;
    // real cameras produce 3 (RGB) or 4 (RGBA). usize → u32 saturating
    // try_from rejects an impossible-but-defined wire bug rather than
    // wrapping into a mismatched plane count downstream.
    let planes = u32::try_from(first_pixel.len()).map_err(|_| {
        AlpacaError::ParseError(format!(
            "Rank-3 plane count {} exceeds u32::MAX",
            first_pixel.len()
        ))
    })?;
    if planes == 0 {
        return Err(AlpacaError::ParseError(
            "Rank-3 image array has zero planes".to_string(),
        ));
    }

    // Why: scratch buffer in column-major (x, y) order per plane; we transpose
    // to planar at the end so each plane is contiguous.
    // Why: u32 → usize widening on every supported
    // target; `checked_mul` handles the product overflow on 32-bit-usize.
    let pixels_per_plane = (width as usize)
        .checked_mul(height as usize)
        .ok_or_else(|| AlpacaError::ParseError("width*height overflow".to_string()))?;
    // Why: `planes` was just validated u32; usize widening.
    let total = pixels_per_plane
        .checked_mul(planes as usize)
        .ok_or_else(|| AlpacaError::ParseError("width*height*planes overflow".to_string()))?;
    let mut planar: Vec<u16> = vec![0u16; total];

    let mut linear: usize = 0;
    for (xi, inner) in outer.iter().enumerate() {
        let inner_arr = inner.as_array().ok_or_else(|| {
            AlpacaError::ParseError(format!("Rank-3 outer[{}] is not an array", xi))
        })?;
        for (yi, pix) in inner_arr.iter().enumerate() {
            let pix_arr = pix.as_array().ok_or_else(|| {
                AlpacaError::ParseError(format!(
                    "Rank-3 outer[{}][{}] pixel is not an array",
                    xi, yi
                ))
            })?;
            // Why: each pixel's plane count is at most a
            // usize (capped by host memory); if it exceeds u32 it cannot
            // equal `planes` (a u32) anyway. The cast here only matters
            // for the inequality comparison and saturates to u32::MAX in
            // the impossibly-large case — which trips the mismatch check.
            if u32::try_from(pix_arr.len()).unwrap_or(u32::MAX) != planes {
                return Err(AlpacaError::ParseError(format!(
                    "Rank-3 plane-count mismatch at ({},{}): expected {}, got {}",
                    xi,
                    yi,
                    planes,
                    pix_arr.len()
                )));
            }
            for (pi, channel) in pix_arr.iter().enumerate() {
                let v = decode_pixel(channel, element_type, linear)?;
                // Place into planar layout: plane pi, then column-major (xi, yi)
                // Why: `height` is u32 → usize widening
                // (≥ 32-bit usize target). `dest` is bounded by `total`
                // which was computed via `checked_mul` above; index-out-of-
                // range would panic on the assignment below — but `linear`
                // is incremented in lockstep with the iteration so this
                // index is loop-bounded by construction.
                let dest = (pi * pixels_per_plane) + (xi * (height as usize)) + yi;
                planar[dest] = v;
                linear += 1;
            }
        }
    }

    // Why: cross-check geometry; mismatched array dimensions vs. NumX/NumY
    // would silently produce a partially-zero plane otherwise.
    // Why: u32 → usize widening; saturating_mul guards
    // overflow on 32-bit-usize targets.
    let expected_linear = pixels_per_plane.saturating_mul(planes as usize);
    if linear != expected_linear {
        return Err(AlpacaError::ParseError(format!(
            "Rank-3 image size mismatch: expected {} pixels ({}x{}x{}), got {}",
            expected_linear, width, height, planes, linear
        )));
    }

    Ok(ImageArrayResult {
        width,
        height,
        planes,
        pixels: planar,
        element_type,
    })
}

/// Decode a single JSON pixel into `u16`, dispatching on `element_type`.
///
/// Why this function exists: an unparseable JSON token must **never** silently
/// become `0`. Every failure path here returns a
/// `PixelParseError` carrying enough context to find the bad pixel.
fn decode_pixel(
    pixel: &serde_json::Value,
    element_type: ImageArrayElementType,
    offset: usize,
) -> Result<u16, AlpacaError> {
    let number = pixel
        .as_number()
        .ok_or_else(|| AlpacaError::PixelParseError {
            offset,
            found: shorten_json(pixel),
            reason: "pixel is not a JSON number".to_string(),
        })?;

    if element_type.is_floating() {
        let f = number
            .as_f64()
            .ok_or_else(|| AlpacaError::PixelParseError {
                offset,
                found: number.to_string(),
                reason: format!("pixel not representable as f64 (Type {:?})", element_type),
            })?;
        if !f.is_finite() {
            return Err(AlpacaError::PixelParseError {
                offset,
                found: number.to_string(),
                reason: "non-finite pixel value (NaN or infinity)".to_string(),
            });
        }
        Ok(clamp_f64_to_u16(f))
    } else {
        // Why: integer Types must arrive as integers — a fractional value is a
        // server bug or wire corruption, not something we should round away.
        let i = number
            .as_i64()
            .ok_or_else(|| AlpacaError::PixelParseError {
                offset,
                found: number.to_string(),
                reason: format!(
                    "pixel not representable as i64 (Type {:?}); fractional or out-of-range",
                    element_type
                ),
            })?;
        Ok(clamp_i64_to_u16(i))
    }
}

/// Clamp a 64-bit signed integer pixel to the `u16` range.
pub(super) fn clamp_i64_to_u16(v: i64) -> u16 {
    if v < 0 {
        0
    } else if v > i64::from(u16::MAX) {
        // Why: u16::MAX (65535) → i64 widening, exact.
        u16::MAX
    } else {
        // Why: the two branches above bound `v` to
        // [0, u16::MAX]; the cast is SAFE within those bounds.
        v as u16
    }
}

/// Round-and-clamp a finite `f64` to `u16`. Caller must reject non-finite.
pub(super) fn clamp_f64_to_u16(v: f64) -> u16 {
    let r = v.round();
    if r < 0.0 {
        0
    } else if r > f64::from(u16::MAX) {
        // Why: u16::MAX (65535) → f64 exact (within
        // f64 mantissa precision).
        u16::MAX
    } else {
        // Why: the two branches above bound `r` to
        // [0.0, u16::MAX]; Rust 1.45+ saturating f64 → u16 conversion is
        // exact within the bounded interval after the `.round()` call.
        r as u16
    }
}

/// Truncate a JSON value's string representation for inclusion in an error
/// message; we don't want to drag a 24 MP frame into a panic log.
fn shorten_json(v: &serde_json::Value) -> String {
    let mut s = v.to_string();
    const MAX: usize = 64;
    if s.len() > MAX {
        s.truncate(MAX);
        s.push_str("...");
    }
    s
}
// Tests

#[cfg(test)]
mod image_array_tests {
    use super::*;

    fn ok_response(rank: u32, type_code: i64, value: serde_json::Value) -> String {
        serde_json::json!({
            "Rank": rank,
            "Type": type_code,
            "Value": value,
            "ErrorNumber": 0,
            "ErrorMessage": "",
            "ClientTransactionID": 1,
            "ServerTransactionID": 1,
        })
        .to_string()
    }

    #[test]
    fn rank2_int32_parses_clean() {
        // 2x3 image, type 2 (Int32), column-major.
        let body = ok_response(2, 2, serde_json::json!([[1, 2, 3], [4, 5, 6],]));
        let r = parse_image_array_json(&body, 2, 3).expect("rank-2 parse");
        assert_eq!(r.width, 2);
        assert_eq!(r.height, 3);
        assert_eq!(r.planes, 1);
        assert_eq!(r.pixels, vec![1u16, 2, 3, 4, 5, 6]);
        assert_eq!(r.element_type, ImageArrayElementType::Int32);
    }

    #[test]
    fn malformed_pixel_string_yields_pixel_parse_error_not_zero() {
        // A pixel string instead of a number: an error, never 0.
        let body = ok_response(2, 2, serde_json::json!([[1, 2, "oops"], [4, 5, 6],]));
        let err = parse_image_array_json(&body, 2, 3).expect_err("must reject malformed pixel");
        match err {
            AlpacaError::PixelParseError {
                offset,
                found,
                reason,
            } => {
                // Why: offset 2 is the third pixel scanned in column-major order.
                assert_eq!(offset, 2, "offset should pinpoint the bad pixel");
                assert!(found.contains("oops"), "found token should echo input");
                assert!(
                    !reason.is_empty(),
                    "reason should describe why parse failed"
                );
            }
            other => panic!("expected PixelParseError, got {:?}", other),
        }
    }

    #[test]
    fn malformed_pixel_null_yields_pixel_parse_error_not_zero() {
        let body = ok_response(2, 2, serde_json::json!([[1, 2, null], [4, 5, 6],]));
        let err = parse_image_array_json(&body, 2, 3).expect_err("null pixel must error");
        assert!(matches!(err, AlpacaError::PixelParseError { .. }));
    }

    #[test]
    fn fractional_pixel_with_integer_type_errors() {
        // Type 2 = Int32; a fractional value is a server bug, not a rounding
        // opportunity — fail closed.
        let body = ok_response(2, 2, serde_json::json!([[1, 2, 3.5], [4, 5, 6],]));
        let err = parse_image_array_json(&body, 2, 3).expect_err("fractional Int32 must error");
        match err {
            AlpacaError::PixelParseError { offset, .. } => assert_eq!(offset, 2),
            other => panic!("expected PixelParseError, got {:?}", other),
        }
    }

    #[test]
    fn fractional_pixel_with_double_type_rounds() {
        // Type 3 = Double; fractional is legitimate and rounds to nearest.
        let body = ok_response(2, 3, serde_json::json!([[1.0, 2.4, 3.6], [4.5, 5.0, 6.0],]));
        let r = parse_image_array_json(&body, 2, 3).expect("Double rank-2 parse");
        // 2.4 -> 2, 3.6 -> 4, 4.5 -> 5 (banker's? no: f64::round() rounds half away from zero -> 5)
        assert_eq!(r.pixels, vec![1u16, 2, 4, 5, 5, 6]);
    }

    #[test]
    fn nan_pixel_with_double_type_errors() {
        // serde_json will encode NaN as null, but a server might serialize it
        // as a string; either way we must NOT silently emit 0.
        let body = ok_response(
            2,
            3,
            serde_json::json!([[1.0, 2.0, "NaN"], [4.0, 5.0, 6.0],]),
        );
        let err = parse_image_array_json(&body, 2, 3).expect_err("NaN must error");
        assert!(matches!(err, AlpacaError::PixelParseError { .. }));
    }

    #[test]
    fn rank3_color_image_preserves_channel_dimension() {
        // 2x2x3 RGB image. Column-major outer (x), then y, then plane.
        // Layout on the wire: outer[x][y][p]
        //   (0,0): [10, 20, 30]
        //   (0,1): [11, 21, 31]
        //   (1,0): [12, 22, 32]
        //   (1,1): [13, 23, 33]
        let body = ok_response(
            3,
            2,
            serde_json::json!([[[10, 20, 30], [11, 21, 31]], [[12, 22, 32], [13, 23, 33]],]),
        );
        let r = parse_image_array_json(&body, 2, 2).expect("rank-3 parse");
        assert_eq!(r.width, 2);
        assert_eq!(r.height, 2);
        assert_eq!(r.planes, 3, "channel dimension must NOT be flattened");
        // Plane 0 (R), planar layout, column-major (x, y): [10, 11, 12, 13]
        // Plane 1 (G):                                   [20, 21, 22, 23]
        // Plane 2 (B):                                   [30, 31, 32, 33]
        assert_eq!(
            r.pixels,
            vec![10u16, 11, 12, 13, 20, 21, 22, 23, 30, 31, 32, 33]
        );
    }

    #[test]
    fn rank3_plane_mismatch_errors() {
        let body = ok_response(
            3,
            2,
            serde_json::json!([
                [[10, 20, 30], [11, 21]], // second pixel only has 2 planes
                [[12, 22, 32], [13, 23, 33]],
            ]),
        );
        let err = parse_image_array_json(&body, 2, 2).expect_err("plane mismatch must error");
        assert!(matches!(err, AlpacaError::ParseError(_)));
    }

    #[test]
    fn unknown_type_errors() {
        let body = ok_response(2, 99, serde_json::json!([[1, 2], [3, 4]]));
        let err = parse_image_array_json(&body, 2, 2).expect_err("unknown type must error");
        match err {
            AlpacaError::UnsupportedImageArray {
                image_type, rank, ..
            } => {
                assert_eq!(image_type, 99);
                assert_eq!(rank, 2);
            }
            other => panic!("expected UnsupportedImageArray, got {:?}", other),
        }
    }

    #[test]
    fn unsupported_rank_errors() {
        let body = ok_response(4, 2, serde_json::json!([]));
        let err = parse_image_array_json(&body, 1, 1).expect_err("rank 4 must error");
        assert!(matches!(
            err,
            AlpacaError::UnsupportedImageArray { rank: 4, .. }
        ));
    }

    #[test]
    fn device_error_propagates() {
        let body = serde_json::json!({
            "Rank": 2,
            "Type": 2,
            "Value": [],
            "ErrorNumber": 1031,
            "ErrorMessage": "Method unavailable",
        })
        .to_string();
        let err = parse_image_array_json(&body, 2, 2).expect_err("device error must propagate");
        match err {
            AlpacaError::DeviceError { code, message } => {
                assert_eq!(code, 1031);
                assert!(message.contains("Method unavailable"));
            }
            other => panic!("expected DeviceError, got {:?}", other),
        }
    }

    #[test]
    fn negative_int_clamps_to_zero() {
        let body = ok_response(2, 2, serde_json::json!([[-5, 0], [70000, 12345]]));
        let r = parse_image_array_json(&body, 2, 2).expect("clamping parse");
        assert_eq!(r.pixels, vec![0u16, 0, u16::MAX, 12345]);
    }

    #[test]
    fn rank2_size_mismatch_errors() {
        // Only 2 pixels supplied for a 2x3 frame.
        let body = ok_response(2, 2, serde_json::json!([[1, 2]]));
        let err = parse_image_array_json(&body, 2, 3).expect_err("size mismatch must error");
        assert!(matches!(err, AlpacaError::ParseError(_)));
    }
}
