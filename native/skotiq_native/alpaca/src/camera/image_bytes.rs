//! Alpaca ImageBytes binary decoder.

use super::*;

// ImageBytes binary parser

/// Fixed-size of the Alpaca v3 ImageBytes metadata header in bytes.
///
/// Layout (all little-endian; see ASCOM Alpaca v3 spec):
/// ```text
/// offset  0  i32  MetadataVersion
/// offset  4  i32  ErrorNumber
/// offset  8  u32  ClientTransactionID
/// offset 12  u32  ServerTransactionID
/// offset 16  i32  DataStart (byte offset to pixel payload)
/// offset 20  i32  ImageElementType (what the client requested)
/// offset 24  i32  TransmissionElementType (what is actually on the wire)
/// offset 28  i32  Rank (2 = mono, 3 = color)
/// offset 32  i32  Dimension1
/// offset 36  i32  Dimension2
/// offset 40  i32  Dimension3 (ignored when Rank == 2)
/// ```
const IMAGE_BYTES_HEADER_SIZE: usize = 44;

/// Parsed Alpaca ImageBytes metadata header.
///
/// Why a struct (not inline parsing): the unit tests build these
/// fields synthetically, so a named layout is much easier to reason about than
/// raw byte slicing in two places.
///
/// Why `#[allow(dead_code)]`: every field is part of the canonical Alpaca v3
/// header layout and the unit tests construct/inspect them. The fields that
/// the production decode path does not yet branch on (metadata_version,
/// client/server transaction IDs) are kept so callers can diagnose mismatched
/// transaction IDs or future-versioned wire formats without re-parsing.
#[allow(dead_code)]
#[derive(Debug, Clone, Copy)]
pub(crate) struct ImageBytesHeader {
    pub metadata_version: i32,
    pub error_number: i32,
    pub client_transaction_id: u32,
    pub server_transaction_id: u32,
    pub data_start: i32,
    pub image_element_type: i32,
    pub transmission_element_type: i32,
    pub rank: i32,
    pub dim1: i32,
    pub dim2: i32,
    pub dim3: i32,
}

/// Read a little-endian `i32` from `buf` at `offset`. Returns a structured
/// error (not a panic) when the buffer is too short: a truncated payload is a
/// propagatable failure, not a crash.
fn read_i32_le(buf: &[u8], offset: usize) -> Result<i32, AlpacaError> {
    let end = offset
        .checked_add(4)
        .ok_or_else(|| AlpacaError::ParseError(format!("i32 offset overflow at {}", offset)))?;
    if end > buf.len() {
        return Err(AlpacaError::BinaryHeaderTruncated {
            offset,
            needed: 4,
            got: buf.len(),
        });
    }
    // Why unwrap is sound: we just bounds-checked the slice length above.
    let arr: [u8; 4] = buf[offset..end].try_into().unwrap();
    Ok(i32::from_le_bytes(arr))
}

/// Read a little-endian `u32` from `buf` at `offset`.
fn read_u32_le(buf: &[u8], offset: usize) -> Result<u32, AlpacaError> {
    let end = offset
        .checked_add(4)
        .ok_or_else(|| AlpacaError::ParseError(format!("u32 offset overflow at {}", offset)))?;
    if end > buf.len() {
        return Err(AlpacaError::BinaryHeaderTruncated {
            offset,
            needed: 4,
            got: buf.len(),
        });
    }
    let arr: [u8; 4] = buf[offset..end].try_into().unwrap();
    Ok(u32::from_le_bytes(arr))
}

/// Parse the 44-byte Alpaca ImageBytes header.
pub(crate) fn parse_image_bytes_header(buf: &[u8]) -> Result<ImageBytesHeader, AlpacaError> {
    if buf.len() < IMAGE_BYTES_HEADER_SIZE {
        return Err(AlpacaError::BinaryHeaderTruncated {
            offset: 0,
            needed: IMAGE_BYTES_HEADER_SIZE,
            got: buf.len(),
        });
    }
    Ok(ImageBytesHeader {
        metadata_version: read_i32_le(buf, 0)?,
        error_number: read_i32_le(buf, 4)?,
        client_transaction_id: read_u32_le(buf, 8)?,
        server_transaction_id: read_u32_le(buf, 12)?,
        data_start: read_i32_le(buf, 16)?,
        image_element_type: read_i32_le(buf, 20)?,
        transmission_element_type: read_i32_le(buf, 24)?,
        rank: read_i32_le(buf, 28)?,
        dim1: read_i32_le(buf, 32)?,
        dim2: read_i32_le(buf, 36)?,
        dim3: read_i32_le(buf, 40)?,
    })
}

/// Convert the transmission element type code into the `ImageArrayElementType`
/// enum we already use for the JSON path. The on-the-wire enum is the canonical
/// ASCOM `ImageArrayElementTypes`: Unknown=0, Int16=1, Int32=2, Double=3,
/// Single=4, UInt64=5, Byte=6, Int64=7, UInt16=8 — same numbering as JSON
/// `Type`, so we can share the mapping.
fn transmission_type_from_code(code: i32) -> Result<ImageArrayElementType, AlpacaError> {
    match code {
        1 => Ok(ImageArrayElementType::Int16),
        2 => Ok(ImageArrayElementType::Int32),
        3 => Ok(ImageArrayElementType::Double),
        4 => Ok(ImageArrayElementType::Single),
        5 => Ok(ImageArrayElementType::UInt64),
        6 => Ok(ImageArrayElementType::Byte),
        7 => Ok(ImageArrayElementType::Int64),
        8 => Ok(ImageArrayElementType::UInt16),
        // Why: Type 0 (Unknown) is only valid for `image_element_type` (client
        // request semantics). For *transmission* it means the server did not
        // populate the field — we cannot decode payload bytes safely.
        _ => Err(AlpacaError::UnsupportedTransmissionType { code }),
    }
}

/// Size, in bytes, of one wire-encoded sample for the given transmission type.
fn transmission_element_size(t: ImageArrayElementType) -> Result<usize, AlpacaError> {
    match t {
        ImageArrayElementType::Byte => Ok(1),
        ImageArrayElementType::Int16 | ImageArrayElementType::UInt16 => Ok(2),
        ImageArrayElementType::Int32 | ImageArrayElementType::Single => Ok(4),
        ImageArrayElementType::Int64
        | ImageArrayElementType::UInt64
        | ImageArrayElementType::Double => Ok(8),
        // Why: caught earlier by `transmission_type_from_code`, but defense in
        // depth — we never want to silently treat Unknown as a 0-byte sample.
        ImageArrayElementType::Unknown => Err(AlpacaError::UnsupportedTransmissionType { code: 0 }),
    }
}

/// Decode a single wire sample at `payload[offset]` to `u16`.
///
/// Why centralized: identical clamping/rounding semantics to the JSON
/// `decode_pixel` path keep both wire formats producing the same output for
/// the same camera frame. Out-of-range integer samples clamp to `u16::MAX`;
/// non-finite floats produce a structured error (no silent zero).
fn decode_wire_sample(
    payload: &[u8],
    offset: usize,
    elem: ImageArrayElementType,
    linear_pixel: usize,
) -> Result<u16, AlpacaError> {
    let size = transmission_element_size(elem)?;
    let end = offset
        .checked_add(size)
        .ok_or_else(|| AlpacaError::ParseError(format!("payload offset overflow at {}", offset)))?;
    if end > payload.len() {
        return Err(AlpacaError::BinaryHeaderTruncated {
            offset,
            needed: size,
            got: payload.len(),
        });
    }
    let bytes = &payload[offset..end];
    match elem {
        // Why: u8 → u16 widening, exact.
        ImageArrayElementType::Byte => Ok(u16::from(bytes[0])),
        ImageArrayElementType::Int16 => {
            let v = i16::from_le_bytes([bytes[0], bytes[1]]);
            // Why: i16 → i64 widening, exact.
            Ok(clamp_i64_to_u16(i64::from(v)))
        }
        ImageArrayElementType::UInt16 => {
            let v = u16::from_le_bytes([bytes[0], bytes[1]]);
            Ok(v)
        }
        ImageArrayElementType::Int32 => {
            let v = i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
            // Why: i32 → i64 widening, exact.
            Ok(clamp_i64_to_u16(i64::from(v)))
        }
        ImageArrayElementType::UInt64 => {
            let v = u64::from_le_bytes([
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            ]);
            // Why: u64 max exceeds i64 range, so route through saturating cast.
            // Why: u16::MAX (65535) → u64 widening exact;
            // the branch above guarantees `v ≤ u16::MAX` so `as u16` is SAFE.
            Ok(if v > u64::from(u16::MAX) {
                u16::MAX
            } else {
                v as u16
            })
        }
        ImageArrayElementType::Int64 => {
            let v = i64::from_le_bytes([
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            ]);
            Ok(clamp_i64_to_u16(v))
        }
        ImageArrayElementType::Single => {
            let v = f32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
            if !v.is_finite() {
                return Err(AlpacaError::PixelParseError {
                    offset: linear_pixel,
                    found: format!("{}", v),
                    reason: "non-finite ImageBytes sample (NaN or infinity)".to_string(),
                });
            }
            // Why: f32 → f64 widening, exact.
            Ok(clamp_f64_to_u16(f64::from(v)))
        }
        ImageArrayElementType::Double => {
            let v = f64::from_le_bytes([
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            ]);
            if !v.is_finite() {
                return Err(AlpacaError::PixelParseError {
                    offset: linear_pixel,
                    found: format!("{}", v),
                    reason: "non-finite ImageBytes sample (NaN or infinity)".to_string(),
                });
            }
            Ok(clamp_f64_to_u16(v))
        }
        // Why: filtered out by `transmission_element_size`, but defense in depth.
        ImageArrayElementType::Unknown => Err(AlpacaError::UnsupportedTransmissionType { code: 0 }),
    }
}

/// Parse a complete Alpaca v3 ImageBytes payload (header + pixel bytes).
///
/// Wire-side layout (after the 44-byte header) is column-major to match the
/// JSON `imagearrayvariant` semantics: pixels are stored as `[NumX][NumY]`
/// (rank 2) or `[NumX][NumY][NumPlanes]` (rank 3) flattened in that iteration
/// order. We materialize the output into the same column-major flat layout
/// already produced by `parse_image_array_json`, so downstream consumers see
/// identical pixel ordering regardless of which transport returned the frame.
pub(crate) fn parse_image_bytes(
    payload: &[u8],
    expected_width: u32,
    expected_height: u32,
) -> Result<ImageArrayResult, AlpacaError> {
    let header = parse_image_bytes_header(payload)?;

    // Why: device-side errors flow in-band on the ImageBytes wire too — the
    // ErrorNumber field replaces the JSON ErrorNumber/ErrorMessage pair. The
    // optional UTF-8 error message lives between offset 44 and `data_start`.
    if header.error_number != 0 {
        let msg_start = IMAGE_BYTES_HEADER_SIZE;
        // Why: `data_start` is i32 clamped to [0, ..) via
        // `.max(0)`; the resulting non-negative i32 widens to usize on every
        // supported target (≥ 32-bit). Subsequent bounds-checks below.
        let msg_end = header.data_start.max(0) as usize;
        let message = if msg_end > msg_start && msg_end <= payload.len() {
            String::from_utf8_lossy(&payload[msg_start..msg_end]).into_owned()
        } else {
            String::new()
        };
        return Err(AlpacaError::DeviceError {
            code: header.error_number,
            message: if message.is_empty() {
                format!("Alpaca ImageBytes error {}", header.error_number)
            } else {
                message
            },
        });
    }

    let element_type = transmission_type_from_code(header.transmission_element_type)?;
    let image_element_type = match header.image_element_type {
        // Why: when the server has not filled image_element_type, fall back to
        // transmission so callers still get a useful type tag on the result.
        0 => element_type,
        // Why: all three i32 → i64 casts below are
        // widening, exact.
        other => match ImageArrayElementType::from_i64(i64::from(other)) {
            ImageArrayElementType::Unknown => {
                return Err(AlpacaError::UnsupportedImageArray {
                    rank: i64::from(header.rank),
                    image_type: i64::from(other),
                    reason: format!(
                        "unrecognised ImageBytes ImageElementType {}",
                        header.image_element_type
                    ),
                })
            }
            t => t,
        },
    };

    let (width_from_header, height_from_header, planes) = match header.rank {
        2 => {
            // Why: dim3 must be 0 (or 1) for rank-2; a non-trivial dim3 means
            // the rank/dims pair is inconsistent.
            if header.dim3 > 1 {
                return Err(AlpacaError::MalformedDimensions {
                    rank: header.rank,
                    dim1: header.dim1,
                    dim2: header.dim2,
                    dim3: header.dim3,
                    expected_width,
                    expected_height,
                    reason: "rank=2 but dim3 > 1".to_string(),
                });
            }
            (header.dim1, header.dim2, 1i32)
        }
        3 => (header.dim1, header.dim2, header.dim3),
        other => {
            return Err(AlpacaError::UnsupportedImageArray {
                // Why: i32 → i64 widening, exact.
                rank: i64::from(other),
                image_type: i64::from(header.image_element_type),
                reason: "only rank 2 (mono) and rank 3 (color) are supported".to_string(),
            });
        }
    };

    // Why: the four `<= 0` checks above guarantee
    // `width_from_header > 0` and `height_from_header > 0`, so the
    // subsequent `as u32` casts on i32 cannot wrap into a large negative.
    // The equality comparison with `expected_width` (a u32) then catches
    // any pathological i32 value > i32::MAX (impossible per the type).
    if width_from_header <= 0
        || height_from_header <= 0
        || planes <= 0
        || width_from_header as u32 != expected_width
        || height_from_header as u32 != expected_height
    {
        return Err(AlpacaError::MalformedDimensions {
            rank: header.rank,
            dim1: header.dim1,
            dim2: header.dim2,
            dim3: header.dim3,
            expected_width,
            expected_height,
            reason: "dimensions inconsistent with subframe (NumX, NumY)".to_string(),
        });
    }

    let data_start = header.data_start;
    // Why: IMAGE_BYTES_HEADER_SIZE is the literal 44 constant;
    // 44 → i32 widening, exact. Comparison guards `data_start < 44` (which
    // would underflow the subsequent cast) and `data_start > payload.len()`
    // (caught after widening to usize).
    if data_start < IMAGE_BYTES_HEADER_SIZE as i32 || (data_start as usize) > payload.len() {
        return Err(AlpacaError::ParseError(format!(
            "ImageBytes DataStart {} outside payload (header={}, payload={} bytes)",
            data_start,
            IMAGE_BYTES_HEADER_SIZE,
            payload.len()
        )));
    }
    // Why: the check above guarantees `data_start ≥ 44`
    // (non-negative i32) and `data_start ≤ payload.len()` (fits in usize
    // because payload is a host-memory-bounded slice).
    let data_start = data_start as usize;
    let pixel_bytes = &payload[data_start..];

    let elem_size = transmission_element_size(element_type)?;
    // Why: u32 → usize widening on every supported target
    // (≥32-bit usize); subsequent `checked_mul`s catch the product overflow.
    let width = expected_width as usize;
    let height = expected_height as usize;
    // Why: `planes > 0` validated above; non-negative i32
    // → usize widens on every supported target.
    let planes_us = planes as usize;
    let pixels_per_plane = width
        .checked_mul(height)
        .ok_or_else(|| AlpacaError::ParseError("width*height overflow".to_string()))?;
    let total_samples = pixels_per_plane
        .checked_mul(planes_us)
        .ok_or_else(|| AlpacaError::ParseError("width*height*planes overflow".to_string()))?;
    let total_bytes = total_samples
        .checked_mul(elem_size)
        .ok_or_else(|| AlpacaError::ParseError("payload byte total overflow".to_string()))?;

    if pixel_bytes.len() < total_bytes {
        return Err(AlpacaError::BinaryHeaderTruncated {
            offset: data_start,
            needed: total_bytes,
            got: pixel_bytes.len(),
        });
    }

    let mut planar: Vec<u16> = vec![0u16; total_samples];
    let mut linear: usize = 0;

    // Wire ordering for `imagearrayvariant` matches JSON: column-major over
    // (x, y), and for rank 3 the innermost varies plane index. We decode in
    // that order and reshuffle into our planar output layout so plane p is a
    // contiguous slice of `pixels_per_plane` samples starting at
    // `p * pixels_per_plane`.
    if planes_us == 1 {
        // Why fast path: rank-2 does not need per-pixel plane indexing; the
        // sample sequence directly fills the single output plane in order.
        for (sample_idx, slot) in planar.iter_mut().enumerate().take(total_samples) {
            let byte_off = sample_idx * elem_size;
            *slot = decode_wire_sample(pixel_bytes, byte_off, element_type, sample_idx)?;
            linear += 1;
        }
    } else {
        for x in 0..width {
            for y in 0..height {
                for p in 0..planes_us {
                    let byte_off = linear * elem_size;
                    let v = decode_wire_sample(pixel_bytes, byte_off, element_type, linear)?;
                    let dest = (p * pixels_per_plane) + (x * height) + y;
                    planar[dest] = v;
                    linear += 1;
                }
            }
        }
    }

    if linear != total_samples {
        return Err(AlpacaError::ParseError(format!(
            "ImageBytes sample count mismatch: expected {}, decoded {}",
            total_samples, linear
        )));
    }

    Ok(ImageArrayResult {
        width: expected_width,
        height: expected_height,
        // Why: `planes` is i32 already validated `> 0`
        // and bounded by rank (≤ a handful for any real camera); i32 → u32
        // narrowing is SAFE for positive values up to i32::MAX. Saturate
        // for defensive symmetry — an i32::MAX planes count is fictional
        // but would already have failed allocation above.
        planes: u32::try_from(planes).unwrap_or(u32::MAX),
        pixels: planar,
        element_type: image_element_type,
    })
}
// ImageBytes binary protocol tests

#[cfg(test)]
mod image_bytes_tests {
    // Why: all `IMAGE_BYTES_HEADER_SIZE as i32` casts in
    // this test module are SAFE: `IMAGE_BYTES_HEADER_SIZE` is the literal
    // constant 44; `(IMAGE_BYTES_HEADER_SIZE + msg.len()) as i32` is bounded
    // by the synthetic short messages built in-test. All test casts on
    // `data_start = X as i32` are constant-bounded.
    use super::*;

    /// Build a synthetic ImageBytes payload from a header description plus
    /// raw pixel bytes. Returns the wire bytes a server would emit.
    #[allow(clippy::too_many_arguments)]
    fn build_payload(
        error_number: i32,
        data_start: i32,
        image_element_type: i32,
        transmission_element_type: i32,
        rank: i32,
        dim1: i32,
        dim2: i32,
        dim3: i32,
        between_header_and_data: &[u8],
        pixel_bytes: &[u8],
    ) -> Vec<u8> {
        let mut buf = Vec::with_capacity(
            IMAGE_BYTES_HEADER_SIZE + between_header_and_data.len() + pixel_bytes.len(),
        );
        // MetadataVersion = 1
        buf.extend_from_slice(&1i32.to_le_bytes());
        // ErrorNumber
        buf.extend_from_slice(&error_number.to_le_bytes());
        // ClientTransactionID = 42, ServerTransactionID = 4242
        buf.extend_from_slice(&42u32.to_le_bytes());
        buf.extend_from_slice(&4242u32.to_le_bytes());
        // DataStart
        buf.extend_from_slice(&data_start.to_le_bytes());
        // ImageElementType
        buf.extend_from_slice(&image_element_type.to_le_bytes());
        // TransmissionElementType
        buf.extend_from_slice(&transmission_element_type.to_le_bytes());
        // Rank
        buf.extend_from_slice(&rank.to_le_bytes());
        // Dim1, Dim2, Dim3
        buf.extend_from_slice(&dim1.to_le_bytes());
        buf.extend_from_slice(&dim2.to_le_bytes());
        buf.extend_from_slice(&dim3.to_le_bytes());
        assert_eq!(buf.len(), IMAGE_BYTES_HEADER_SIZE);
        // Optional bytes (error message) between header and DataStart
        buf.extend_from_slice(between_header_and_data);
        // Pad to DataStart if there is a gap
        if (buf.len() as i32) < data_start {
            buf.resize(data_start as usize, 0);
        }
        buf.extend_from_slice(pixel_bytes);
        buf
    }

    #[test]
    fn rank2_uint16_decodes_clean() {
        // 2x3 mono UInt16 image. Wire order is column-major: x outer, y inner.
        // Pixel values: (0,0)=10 (0,1)=20 (0,2)=30 (1,0)=40 (1,1)=50 (1,2)=60
        let pixels: [u16; 6] = [10, 20, 30, 40, 50, 60];
        let mut pixel_bytes: Vec<u8> = Vec::with_capacity(12);
        for p in &pixels {
            pixel_bytes.extend_from_slice(&p.to_le_bytes());
        }
        let payload = build_payload(
            0,
            IMAGE_BYTES_HEADER_SIZE as i32,
            8, // ImageElementType = UInt16
            8, // TransmissionElementType = UInt16
            2,
            2,
            3,
            0,
            &[],
            &pixel_bytes,
        );

        let r = parse_image_bytes(&payload, 2, 3).expect("rank-2 UInt16 parse");
        assert_eq!(r.width, 2);
        assert_eq!(r.height, 3);
        assert_eq!(r.planes, 1);
        assert_eq!(r.pixels, vec![10u16, 20, 30, 40, 50, 60]);
        assert_eq!(r.element_type, ImageArrayElementType::UInt16);
    }

    #[test]
    fn rank2_int32_clamps_to_u16() {
        // Int32 sample stream containing negative + overflow values.
        let samples: [i32; 4] = [-5, 0, 70_000, 12_345];
        let mut pixel_bytes: Vec<u8> = Vec::with_capacity(16);
        for v in &samples {
            pixel_bytes.extend_from_slice(&v.to_le_bytes());
        }
        let payload = build_payload(
            0,
            IMAGE_BYTES_HEADER_SIZE as i32,
            2, // Int32
            2,
            2,
            2,
            2,
            0,
            &[],
            &pixel_bytes,
        );

        let r = parse_image_bytes(&payload, 2, 2).expect("rank-2 Int32 parse");
        assert_eq!(r.pixels, vec![0u16, 0, u16::MAX, 12_345]);
        assert_eq!(r.element_type, ImageArrayElementType::Int32);
    }

    #[test]
    fn rank3_color_image_planar_layout() {
        // 2x2x3 image, UInt16 wire. Column-major over (x, y, p):
        // (0,0,0..2)=10,20,30  (0,1,0..2)=11,21,31
        // (1,0,0..2)=12,22,32  (1,1,0..2)=13,23,33
        let samples: [u16; 12] = [10, 20, 30, 11, 21, 31, 12, 22, 32, 13, 23, 33];
        let mut pixel_bytes: Vec<u8> = Vec::with_capacity(24);
        for s in &samples {
            pixel_bytes.extend_from_slice(&s.to_le_bytes());
        }
        let payload = build_payload(
            0,
            IMAGE_BYTES_HEADER_SIZE as i32,
            8,
            8,
            3,
            2,
            2,
            3,
            &[],
            &pixel_bytes,
        );

        let r = parse_image_bytes(&payload, 2, 2).expect("rank-3 UInt16 parse");
        assert_eq!(r.width, 2);
        assert_eq!(r.height, 2);
        assert_eq!(r.planes, 3);
        // Plane 0: [10, 11, 12, 13] (column-major over x,y)
        // Plane 1: [20, 21, 22, 23]
        // Plane 2: [30, 31, 32, 33]
        assert_eq!(
            r.pixels,
            vec![10u16, 11, 12, 13, 20, 21, 22, 23, 30, 31, 32, 33]
        );
    }

    #[test]
    fn header_truncated_payload_returns_structured_error() {
        // Only 20 bytes — far short of the 44-byte header.
        let payload = vec![0u8; 20];
        let err = parse_image_bytes(&payload, 1, 1).expect_err("must reject truncated header");
        match err {
            AlpacaError::BinaryHeaderTruncated {
                needed,
                got,
                offset,
            } => {
                assert_eq!(needed, IMAGE_BYTES_HEADER_SIZE);
                assert_eq!(got, 20);
                assert_eq!(offset, 0);
            }
            other => panic!("expected BinaryHeaderTruncated, got {:?}", other),
        }
    }

    #[test]
    fn payload_shorter_than_declared_pixels_errors() {
        // Header says 2x2 UInt16 = 8 bytes pixels, but we provide only 4.
        let payload = build_payload(
            0,
            IMAGE_BYTES_HEADER_SIZE as i32,
            8,
            8,
            2,
            2,
            2,
            0,
            &[],
            &[0u8, 0, 0, 0],
        );
        let err = parse_image_bytes(&payload, 2, 2).expect_err("must reject short pixel payload");
        assert!(matches!(err, AlpacaError::BinaryHeaderTruncated { .. }));
    }

    #[test]
    fn unsupported_transmission_type_errors() {
        let payload = build_payload(
            0,
            IMAGE_BYTES_HEADER_SIZE as i32,
            2,
            99, // unknown transmission type
            2,
            1,
            1,
            0,
            &[],
            &[0u8, 0, 0, 0],
        );
        let err =
            parse_image_bytes(&payload, 1, 1).expect_err("must reject unknown transmission type");
        match err {
            AlpacaError::UnsupportedTransmissionType { code } => assert_eq!(code, 99),
            other => panic!("expected UnsupportedTransmissionType, got {:?}", other),
        }
    }

    #[test]
    fn malformed_dimensions_rank2_with_dim3_errors() {
        let payload = build_payload(
            0,
            IMAGE_BYTES_HEADER_SIZE as i32,
            8,
            8,
            2, // rank 2
            2, // dim1
            2, // dim2
            3, // dim3 > 1 — inconsistent with rank=2
            &[],
            &[0u8; 8],
        );
        let err = parse_image_bytes(&payload, 2, 2).expect_err("rank-2 with dim3 must error");
        match err {
            AlpacaError::MalformedDimensions {
                rank,
                dim3,
                expected_width,
                expected_height,
                ..
            } => {
                assert_eq!(rank, 2);
                assert_eq!(dim3, 3);
                assert_eq!(expected_width, 2);
                assert_eq!(expected_height, 2);
            }
            other => panic!("expected MalformedDimensions, got {:?}", other),
        }
    }

    #[test]
    fn dimension_mismatch_with_subframe_errors() {
        // Header says 3x3, but caller expects 2x2 — must error, not silently
        // truncate.
        let payload = build_payload(
            0,
            IMAGE_BYTES_HEADER_SIZE as i32,
            8,
            8,
            2,
            3,
            3,
            0,
            &[],
            &[0u8; 18],
        );
        let err = parse_image_bytes(&payload, 2, 2).expect_err("dim mismatch must error");
        assert!(matches!(err, AlpacaError::MalformedDimensions { .. }));
    }

    #[test]
    fn device_error_number_propagates_with_message() {
        // ErrorNumber != 0, with a UTF-8 message between header and DataStart.
        let msg = b"camera not connected";
        let data_start = (IMAGE_BYTES_HEADER_SIZE + msg.len()) as i32;
        let payload = build_payload(
            1031, // device error code
            data_start,
            2,
            2,
            2,
            0,
            0,
            0,
            msg,
            &[], // no pixel payload when reporting an error
        );
        let err = parse_image_bytes(&payload, 1, 1).expect_err("device error must propagate");
        match err {
            AlpacaError::DeviceError { code, message } => {
                assert_eq!(code, 1031);
                assert!(
                    message.contains("camera not connected"),
                    "got message: {}",
                    message
                );
            }
            other => panic!("expected DeviceError, got {:?}", other),
        }
    }

    #[test]
    fn nan_float_sample_errors_not_zero() {
        // Single (f32) NaN must propagate, not silently emit 0.
        let nan: f32 = f32::NAN;
        let mut pixel_bytes: Vec<u8> = Vec::new();
        pixel_bytes.extend_from_slice(&0.0f32.to_le_bytes());
        pixel_bytes.extend_from_slice(&nan.to_le_bytes());
        let payload = build_payload(
            0,
            IMAGE_BYTES_HEADER_SIZE as i32,
            4,
            4,
            2,
            1,
            2,
            0,
            &[],
            &pixel_bytes,
        );
        let err = parse_image_bytes(&payload, 1, 2).expect_err("NaN must error");
        assert!(matches!(err, AlpacaError::PixelParseError { .. }));
    }

    #[test]
    fn data_start_inside_header_errors() {
        // DataStart < 44 is a protocol violation.
        let payload = build_payload(0, 10, 8, 8, 2, 1, 1, 0, &[], &[0u8, 0]);
        let err = parse_image_bytes(&payload, 1, 1).expect_err("DataStart < header must error");
        assert!(matches!(err, AlpacaError::ParseError(_)));
    }
}
