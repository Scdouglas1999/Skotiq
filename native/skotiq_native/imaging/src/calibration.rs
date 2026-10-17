//! Image Calibration Pipeline
//!
//! Provides dark subtraction, flat field division, and bias correction
//! for astrophotography image calibration. All pixel operations use rayon
//! for parallel processing.
//!
//! ## Calibration Order
//!
//! The standard calibration pipeline applies corrections in this order:
//! 1. Subtract bias from the master dark (if both provided)
//! 2. Subtract bias from the master flat (if both provided)
//! 3. Subtract the (bias-corrected) dark from the light frame
//! 4. Divide the light frame by the normalized (bias-corrected) flat

use crate::{ImageData, PixelType};
use rayon::prelude::*;

/// Errors that can occur during calibration
#[derive(Debug, Clone)]
pub enum CalibrationError {
    /// Frame dimensions do not match
    DimensionMismatch {
        expected_width: u32,
        expected_height: u32,
        actual_width: u32,
        actual_height: u32,
        frame_name: String,
    },
    /// Channel counts do not match
    ChannelMismatch {
        expected: u32,
        actual: u32,
        frame_name: String,
    },
    /// Pixel types do not match
    PixelTypeMismatch {
        expected: PixelType,
        actual: PixelType,
        frame_name: String,
    },
    /// The input frame has no data
    EmptyFrame { frame_name: String },
    /// The raw data buffer length does not match the expected size for the
    /// frame's dimensions and pixel type (e.g. odd byte count for U16 pixels)
    BufferLengthMismatch {
        expected_bytes: usize,
        actual_bytes: usize,
        frame_name: String,
    },
}

impl std::fmt::Display for CalibrationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CalibrationError::DimensionMismatch {
                expected_width,
                expected_height,
                actual_width,
                actual_height,
                frame_name,
            } => write!(
                f,
                "Dimension mismatch for {}: expected {}x{}, got {}x{}",
                frame_name, expected_width, expected_height, actual_width, actual_height
            ),
            CalibrationError::ChannelMismatch {
                expected,
                actual,
                frame_name,
            } => write!(
                f,
                "Channel count mismatch for {}: expected {}, got {}",
                frame_name, expected, actual
            ),
            CalibrationError::PixelTypeMismatch {
                expected,
                actual,
                frame_name,
            } => write!(
                f,
                "Pixel type mismatch for {}: expected {:?}, got {:?}",
                frame_name, expected, actual
            ),
            CalibrationError::EmptyFrame { frame_name } => {
                write!(f, "Empty frame: {}", frame_name)
            }
            CalibrationError::BufferLengthMismatch {
                expected_bytes,
                actual_bytes,
                frame_name,
            } => write!(
                f,
                "Buffer length mismatch for {}: expected {} bytes, got {} bytes",
                frame_name, expected_bytes, actual_bytes
            ),
        }
    }
}

impl std::error::Error for CalibrationError {}

/// Validate that a single frame's raw data buffer has the correct length
/// for its declared dimensions and pixel type.
fn validate_buffer_length(frame: &ImageData, frame_name: &str) -> Result<(), CalibrationError> {
    let pixel_count = frame.width as usize * frame.height as usize * frame.channels as usize;
    let bytes_per_pixel = frame.pixel_type.byte_size();
    let expected_len = pixel_count * bytes_per_pixel;
    if frame.data.len() != expected_len {
        return Err(CalibrationError::BufferLengthMismatch {
            expected_bytes: expected_len,
            actual_bytes: frame.data.len(),
            frame_name: frame_name.to_string(),
        });
    }
    Ok(())
}

/// Validate that two frames have matching dimensions, channels, and pixel type
fn validate_frames(
    reference: &ImageData,
    other: &ImageData,
    other_name: &str,
) -> Result<(), CalibrationError> {
    if reference.is_empty() {
        return Err(CalibrationError::EmptyFrame {
            frame_name: "light frame".to_string(),
        });
    }
    if other.is_empty() {
        return Err(CalibrationError::EmptyFrame {
            frame_name: other_name.to_string(),
        });
    }
    if reference.width != other.width || reference.height != other.height {
        return Err(CalibrationError::DimensionMismatch {
            expected_width: reference.width,
            expected_height: reference.height,
            actual_width: other.width,
            actual_height: other.height,
            frame_name: other_name.to_string(),
        });
    }
    if reference.channels != other.channels {
        return Err(CalibrationError::ChannelMismatch {
            expected: reference.channels,
            actual: other.channels,
            frame_name: other_name.to_string(),
        });
    }
    if reference.pixel_type != other.pixel_type {
        return Err(CalibrationError::PixelTypeMismatch {
            expected: reference.pixel_type,
            actual: other.pixel_type,
            frame_name: other_name.to_string(),
        });
    }
    // Validate that raw buffers are correctly sized for their pixel types
    validate_buffer_length(reference, "light frame")?;
    validate_buffer_length(other, other_name)?;
    Ok(())
}

/// Subtract a dark frame from a light frame, pixel by pixel.
///
/// For each pixel: result = max(0, light - dark)
///
/// Underflow is clamped to 0 (no negative pixel values).
/// Both frames must have matching dimensions, channels, and pixel type.
pub fn subtract_dark(light: &ImageData, dark: &ImageData) -> Result<ImageData, CalibrationError> {
    validate_frames(light, dark, "dark frame")?;

    let result_data = match light.pixel_type {
        PixelType::U8 => subtract_u8(&light.data, &dark.data),
        PixelType::U16 => subtract_u16(&light.data, &dark.data),
        PixelType::U32 => subtract_u32(&light.data, &dark.data),
        PixelType::F32 => subtract_f32(&light.data, &dark.data),
        PixelType::F64 => subtract_f64(&light.data, &dark.data),
    };

    Ok(ImageData {
        width: light.width,
        height: light.height,
        channels: light.channels,
        pixel_type: light.pixel_type,
        data: result_data,
    })
}

/// Subtract a bias frame from an image. Functionally identical to dark subtraction
/// since a bias is a zero-length dark exposure.
///
/// For each pixel: result = max(0, frame - bias)
pub fn subtract_bias(frame: &ImageData, bias: &ImageData) -> Result<ImageData, CalibrationError> {
    validate_frames(frame, bias, "bias frame")?;

    let result_data = match frame.pixel_type {
        PixelType::U8 => subtract_u8(&frame.data, &bias.data),
        PixelType::U16 => subtract_u16(&frame.data, &bias.data),
        PixelType::U32 => subtract_u32(&frame.data, &bias.data),
        PixelType::F32 => subtract_f32(&frame.data, &bias.data),
        PixelType::F64 => subtract_f64(&frame.data, &bias.data),
    };

    Ok(ImageData {
        width: frame.width,
        height: frame.height,
        channels: frame.channels,
        pixel_type: frame.pixel_type,
        data: result_data,
    })
}

/// Divide a light frame by a normalized flat field.
///
/// The flat is first normalized by dividing all pixels by the flat's mean value,
/// producing a flat where the average pixel equals 1.0. Then each light pixel is
/// divided by the corresponding normalized flat pixel.
///
/// For integer types, the computation is done in f64 and the result is clamped
/// back to the valid range. Division by zero (dead pixels in flat) produces 0.
pub fn divide_flat(light: &ImageData, flat: &ImageData) -> Result<ImageData, CalibrationError> {
    validate_frames(light, flat, "flat frame")?;

    let channels = (light.channels as usize).max(1);
    let result_data = match light.pixel_type {
        PixelType::U8 => divide_flat_u8(&light.data, &flat.data, channels),
        PixelType::U16 => divide_flat_u16(&light.data, &flat.data, channels),
        PixelType::U32 => divide_flat_u32(&light.data, &flat.data, channels),
        PixelType::F32 => divide_flat_f32(&light.data, &flat.data, channels),
        PixelType::F64 => divide_flat_f64(&light.data, &flat.data, channels),
    };

    Ok(ImageData {
        width: light.width,
        height: light.height,
        channels: light.channels,
        pixel_type: light.pixel_type,
        data: result_data,
    })
}

/// Full calibration pipeline: apply bias, dark, and flat corrections.
///
/// The order of operations:
/// 1. If bias is provided: subtract bias from the dark (if dark provided)
/// 2. If bias is provided: subtract bias from the flat (if flat provided)
/// 3. If bias is provided: subtract bias from the light (always — see below)
/// 4. If dark is provided: subtract (bias-corrected) dark from the light
/// 5. If flat is provided: divide light by normalized (bias-corrected) flat
///
/// Bias must be removed from the light whenever it is provided; because step 1
/// already removed bias from the dark, subtracting bias from the light too makes
/// the pedestal cancel: `(light - bias) - (dark - bias) = light - dark`.
///
/// Any combination of calibration frames can be None. If all are None,
/// the light frame is returned unchanged (cloned).
pub fn calibrate_frame(
    light: &ImageData,
    dark: Option<&ImageData>,
    flat: Option<&ImageData>,
    bias: Option<&ImageData>,
) -> Result<ImageData, CalibrationError> {
    if light.is_empty() {
        return Err(CalibrationError::EmptyFrame {
            frame_name: "light frame".to_string(),
        });
    }
    validate_buffer_length(light, "light frame")?;

    // Validate all provided frames against the light
    if let Some(d) = dark {
        validate_frames(light, d, "dark frame")?;
    }
    if let Some(f) = flat {
        validate_frames(light, f, "flat frame")?;
    }
    if let Some(b) = bias {
        validate_frames(light, b, "bias frame")?;
    }

    // Step 1: Prepare the dark frame (subtract bias from dark if both provided)
    let corrected_dark: Option<ImageData> = match (dark, bias) {
        (Some(d), Some(b)) => Some(subtract_bias(d, b)?),
        (Some(d), None) => Some(d.clone()),
        _ => None,
    };

    // Step 2: Prepare the flat frame (subtract bias from flat if both provided)
    let corrected_flat: Option<ImageData> = match (flat, bias) {
        (Some(f), Some(b)) => Some(subtract_bias(f, b)?),
        (Some(f), None) => Some(f.clone()),
        _ => None,
    };

    // Step 3: Start with the light frame. When a bias frame is provided we must
    // subtract it from the light as well — step 1 already removed the bias from
    // the dark, so subtracting only the bias-corrected dark would leave a full
    // bias pedestal in the result:
    //   light - (dark - bias) = signal + bias   (WRONG)
    // Removing bias from BOTH light and dark cancels it correctly:
    //   (light - bias) - (dark - bias) = light - dark = signal
    // The previous `if dark.is_none()` guard skipped the light bias-subtraction
    // whenever a dark was present, which is exactly the pedestal-leaking case.
    let mut result = match bias {
        Some(b) => subtract_bias(light, b)?,
        None => light.clone(),
    };

    // Step 4: Subtract dark from light
    if let Some(ref d) = corrected_dark {
        result = subtract_dark(&result, d)?;
    }

    // Step 5: Divide by normalized flat
    if let Some(ref f) = corrected_flat {
        result = divide_flat(&result, f)?;
    }

    Ok(result)
}

/// Per-channel mean of interleaved samples, where `values[i]` belongs to
/// channel `i % channels`. Flat-field normalisation must be done per channel:
/// a colour (interleaved RGB) flat with different per-channel levels would
/// otherwise be normalised by one global mean, injecting a colour cast into
/// otherwise-uniform light. For `channels == 1` this collapses to a single
/// global mean.
fn per_channel_means(values: &[f64], channels: usize) -> Vec<f64> {
    let channels = channels.max(1);
    let mut sums = vec![0.0f64; channels];
    let mut counts = vec![0u64; channels];
    for (i, &v) in values.iter().enumerate() {
        let c = i % channels;
        sums[c] += v;
        counts[c] += 1;
    }
    (0..channels)
        .map(|c| {
            if counts[c] == 0 {
                0.0
            } else {
                sums[c] / counts[c] as f64
            }
        })
        .collect()
}

// U8 pixel operations

fn subtract_u8(light: &[u8], dark: &[u8]) -> Vec<u8> {
    light
        .par_iter()
        .zip(dark.par_iter())
        .map(|(&l, &d)| l.saturating_sub(d))
        .collect()
}

fn divide_flat_u8(light: &[u8], flat: &[u8], channels: usize) -> Vec<u8> {
    if flat.is_empty() {
        return light.to_vec();
    }
    let flat_f64: Vec<f64> = flat.iter().map(|&v| v as f64).collect();
    let means = per_channel_means(&flat_f64, channels);
    if means.iter().all(|&m| m == 0.0) {
        return vec![0u8; light.len()];
    }

    light
        .par_iter()
        .enumerate()
        .map(|(i, &l)| {
            let mean = means[i % channels];
            if mean == 0.0 {
                return 0u8;
            }
            let normalized_flat = flat[i] as f64 / mean;
            if normalized_flat <= 0.0 {
                0u8
            } else {
                let result = l as f64 / normalized_flat;
                result.round().clamp(0.0, 255.0) as u8
            }
        })
        .collect()
}

// U16 pixel operations

fn subtract_u16(light: &[u8], dark: &[u8]) -> Vec<u8> {
    let light_pixels: Vec<u16> = light
        .as_chunks::<2>()
        .0
        .iter()
        .map(|c| u16::from_le_bytes([c[0], c[1]]))
        .collect();
    let dark_pixels: Vec<u16> = dark
        .as_chunks::<2>()
        .0
        .iter()
        .map(|c| u16::from_le_bytes([c[0], c[1]]))
        .collect();

    let result: Vec<u16> = light_pixels
        .par_iter()
        .zip(dark_pixels.par_iter())
        .map(|(&l, &d)| l.saturating_sub(d))
        .collect();

    result.iter().flat_map(|&v| v.to_le_bytes()).collect()
}

fn divide_flat_u16(light: &[u8], flat: &[u8], channels: usize) -> Vec<u8> {
    let light_pixels: Vec<u16> = light
        .as_chunks::<2>()
        .0
        .iter()
        .map(|c| u16::from_le_bytes([c[0], c[1]]))
        .collect();
    let flat_pixels: Vec<u16> = flat
        .as_chunks::<2>()
        .0
        .iter()
        .map(|c| u16::from_le_bytes([c[0], c[1]]))
        .collect();

    if flat_pixels.is_empty() {
        return light.to_vec();
    }
    let flat_f64: Vec<f64> = flat_pixels.iter().map(|&v| v as f64).collect();
    let means = per_channel_means(&flat_f64, channels);
    if means.iter().all(|&m| m == 0.0) {
        return vec![0u8; light.len()];
    }

    let result: Vec<u16> = light_pixels
        .par_iter()
        .enumerate()
        .map(|(i, &l)| {
            let mean = means[i % channels];
            if mean == 0.0 {
                return 0u16;
            }
            let normalized_flat = flat_pixels[i] as f64 / mean;
            if normalized_flat <= 0.0 {
                0u16
            } else {
                let val = l as f64 / normalized_flat;
                val.round().clamp(0.0, 65535.0) as u16
            }
        })
        .collect();

    result.iter().flat_map(|&v| v.to_le_bytes()).collect()
}

// U32 pixel operations

fn subtract_u32(light: &[u8], dark: &[u8]) -> Vec<u8> {
    let light_pixels: Vec<u32> = light
        .as_chunks::<4>()
        .0
        .iter()
        .map(|c| u32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect();
    let dark_pixels: Vec<u32> = dark
        .as_chunks::<4>()
        .0
        .iter()
        .map(|c| u32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect();

    let result: Vec<u32> = light_pixels
        .par_iter()
        .zip(dark_pixels.par_iter())
        .map(|(&l, &d)| l.saturating_sub(d))
        .collect();

    result.iter().flat_map(|&v| v.to_le_bytes()).collect()
}

fn divide_flat_u32(light: &[u8], flat: &[u8], channels: usize) -> Vec<u8> {
    let light_pixels: Vec<u32> = light
        .as_chunks::<4>()
        .0
        .iter()
        .map(|c| u32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect();
    let flat_pixels: Vec<u32> = flat
        .as_chunks::<4>()
        .0
        .iter()
        .map(|c| u32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect();

    if flat_pixels.is_empty() {
        return light.to_vec();
    }
    let flat_f64: Vec<f64> = flat_pixels.iter().map(|&v| v as f64).collect();
    let means = per_channel_means(&flat_f64, channels);
    if means.iter().all(|&m| m == 0.0) {
        return vec![0u8; light.len()];
    }

    let result: Vec<u32> = light_pixels
        .par_iter()
        .enumerate()
        .map(|(i, &l)| {
            let mean = means[i % channels];
            if mean == 0.0 {
                return 0u32;
            }
            let normalized_flat = flat_pixels[i] as f64 / mean;
            if normalized_flat <= 0.0 {
                0u32
            } else {
                let val = l as f64 / normalized_flat;
                val.round().clamp(0.0, u32::MAX as f64) as u32
            }
        })
        .collect();

    result.iter().flat_map(|&v| v.to_le_bytes()).collect()
}

// F32 pixel operations

fn subtract_f32(light: &[u8], dark: &[u8]) -> Vec<u8> {
    let light_pixels: Vec<f32> = light
        .as_chunks::<4>()
        .0
        .iter()
        .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect();
    let dark_pixels: Vec<f32> = dark
        .as_chunks::<4>()
        .0
        .iter()
        .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect();

    let result: Vec<f32> = light_pixels
        .par_iter()
        .zip(dark_pixels.par_iter())
        .map(|(&l, &d)| {
            let val = l - d;
            if val < 0.0 {
                0.0f32
            } else {
                val
            }
        })
        .collect();

    result.iter().flat_map(|&v| v.to_le_bytes()).collect()
}

fn divide_flat_f32(light: &[u8], flat: &[u8], channels: usize) -> Vec<u8> {
    let light_pixels: Vec<f32> = light
        .as_chunks::<4>()
        .0
        .iter()
        .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect();
    let flat_pixels: Vec<f32> = flat
        .as_chunks::<4>()
        .0
        .iter()
        .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect();

    if flat_pixels.is_empty() {
        return light.to_vec();
    }
    let flat_f64: Vec<f64> = flat_pixels.iter().map(|&v| v as f64).collect();
    let means = per_channel_means(&flat_f64, channels);
    if means.iter().all(|&m| m == 0.0) {
        return vec![0u8; light.len()];
    }

    let result: Vec<f32> = light_pixels
        .par_iter()
        .enumerate()
        .map(|(i, &l)| {
            let mean = means[i % channels];
            if mean == 0.0 {
                return 0.0f32;
            }
            let normalized_flat = flat_pixels[i] as f64 / mean;
            if normalized_flat <= 0.0 {
                0.0f32
            } else {
                let val = l as f64 / normalized_flat;
                // Clamp to non-negative; F32 images typically use [0, 1] range
                // but we don't impose an upper bound since the data may use other scales
                if val < 0.0 {
                    0.0f32
                } else {
                    val as f32
                }
            }
        })
        .collect();

    result.iter().flat_map(|&v| v.to_le_bytes()).collect()
}

// F64 pixel operations

fn subtract_f64(light: &[u8], dark: &[u8]) -> Vec<u8> {
    let light_pixels: Vec<f64> = light
        .as_chunks::<8>()
        .0
        .iter()
        .map(|c| f64::from_le_bytes([c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7]]))
        .collect();
    let dark_pixels: Vec<f64> = dark
        .as_chunks::<8>()
        .0
        .iter()
        .map(|c| f64::from_le_bytes([c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7]]))
        .collect();

    let result: Vec<f64> = light_pixels
        .par_iter()
        .zip(dark_pixels.par_iter())
        .map(|(&l, &d)| {
            let val = l - d;
            if val < 0.0 {
                0.0f64
            } else {
                val
            }
        })
        .collect();

    result.iter().flat_map(|&v| v.to_le_bytes()).collect()
}

fn divide_flat_f64(light: &[u8], flat: &[u8], channels: usize) -> Vec<u8> {
    let light_pixels: Vec<f64> = light
        .as_chunks::<8>()
        .0
        .iter()
        .map(|c| f64::from_le_bytes([c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7]]))
        .collect();
    let flat_pixels: Vec<f64> = flat
        .as_chunks::<8>()
        .0
        .iter()
        .map(|c| f64::from_le_bytes([c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7]]))
        .collect();

    if flat_pixels.is_empty() {
        return light.to_vec();
    }
    let means = per_channel_means(&flat_pixels, channels);
    if means.iter().all(|&m| m == 0.0) {
        return vec![0u8; light.len()];
    }

    let result: Vec<f64> = light_pixels
        .par_iter()
        .enumerate()
        .map(|(i, &l)| {
            let mean = means[i % channels];
            if mean == 0.0 {
                return 0.0f64;
            }
            let normalized_flat = flat_pixels[i] / mean;
            if normalized_flat <= 0.0 {
                0.0f64
            } else {
                let val = l / normalized_flat;
                if val < 0.0 {
                    0.0f64
                } else {
                    val
                }
            }
        })
        .collect();

    result.iter().flat_map(|&v| v.to_le_bytes()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_u16_image(width: u32, height: u32, values: &[u16]) -> ImageData {
        ImageData::from_u16(width, height, 1, values)
    }

    fn read_u16_pixels(image: &ImageData) -> Vec<u16> {
        image.as_u16().unwrap()
    }

    #[test]
    fn test_subtract_dark_basic() {
        let light = make_u16_image(2, 2, &[1000, 2000, 3000, 4000]);
        let dark = make_u16_image(2, 2, &[100, 200, 300, 400]);
        let result = subtract_dark(&light, &dark).unwrap();
        let pixels = read_u16_pixels(&result);
        assert_eq!(pixels, vec![900, 1800, 2700, 3600]);
    }

    #[test]
    fn test_subtract_dark_underflow_clamps() {
        let light = make_u16_image(2, 2, &[100, 200, 50, 0]);
        let dark = make_u16_image(2, 2, &[200, 200, 100, 50]);
        let result = subtract_dark(&light, &dark).unwrap();
        let pixels = read_u16_pixels(&result);
        assert_eq!(pixels, vec![0, 0, 0, 0]);
    }

    #[test]
    fn test_subtract_bias_same_as_dark() {
        let frame = make_u16_image(2, 2, &[500, 600, 700, 800]);
        let bias = make_u16_image(2, 2, &[100, 100, 100, 100]);
        let result = subtract_bias(&frame, &bias).unwrap();
        let pixels = read_u16_pixels(&result);
        assert_eq!(pixels, vec![400, 500, 600, 700]);
    }

    #[test]
    fn test_divide_flat_uniform() {
        // A uniform flat should produce the same light values
        let light = make_u16_image(2, 2, &[1000, 2000, 3000, 4000]);
        let flat = make_u16_image(2, 2, &[5000, 5000, 5000, 5000]);
        let result = divide_flat(&light, &flat).unwrap();
        let pixels = read_u16_pixels(&result);
        // flat/mean = 5000/5000 = 1.0 for all pixels, so light/1.0 = light
        assert_eq!(pixels, vec![1000, 2000, 3000, 4000]);
    }

    #[test]
    fn test_divide_flat_vignette() {
        // Simulate vignetting: corners are dimmer in flat
        let light = make_u16_image(2, 2, &[3000, 5000, 5000, 3000]);
        let flat = make_u16_image(2, 2, &[3000, 5000, 5000, 3000]);
        let result = divide_flat(&light, &flat).unwrap();
        let pixels = read_u16_pixels(&result);
        // Mean of flat = (3000+5000+5000+3000)/4 = 4000
        // Pixel 0: 3000 / (3000/4000) = 3000 / 0.75 = 4000
        // Pixel 1: 5000 / (5000/4000) = 5000 / 1.25 = 4000
        // Pixel 2: 5000 / (5000/4000) = 5000 / 1.25 = 4000
        // Pixel 3: 3000 / (3000/4000) = 3000 / 0.75 = 4000
        assert_eq!(pixels, vec![4000, 4000, 4000, 4000]);
    }

    #[test]
    fn test_divide_flat_dead_pixel() {
        // A dead pixel (0) in the flat should produce 0 in the result
        let light = make_u16_image(2, 2, &[1000, 2000, 3000, 4000]);
        let flat = make_u16_image(2, 2, &[0, 5000, 5000, 5000]);
        let result = divide_flat(&light, &flat).unwrap();
        let pixels = read_u16_pixels(&result);
        assert_eq!(pixels[0], 0); // dead pixel produces 0
    }

    #[test]
    fn test_divide_flat_overflow_clamp() {
        // Very dim flat pixel should boost light but clamp to 65535
        let light = make_u16_image(1, 1, &[60000]);
        let flat = make_u16_image(1, 1, &[100]);
        let result = divide_flat(&light, &flat).unwrap();
        let pixels = read_u16_pixels(&result);
        // Mean = 100, normalized = 100/100 = 1.0, result = 60000/1.0 = 60000
        // With only one pixel, normalized flat IS 1.0, so result = light
        assert_eq!(pixels[0], 60000);
    }

    #[test]
    fn test_divide_flat_per_channel_no_color_cast() {
        // An interleaved RGB flat with different per-channel
        // levels but no spatial variation must not tint uniform RGB light. A
        // single global mean would scale the three channels differently and
        // inject a colour cast; per-channel means leave uniform light unchanged.
        let light = ImageData::from_u16(2, 2, 3, &[10000; 12]);
        let flat = ImageData::from_u16(
            2,
            2,
            3,
            &[
                30000, 40000, 50000, 30000, 40000, 50000, 30000, 40000, 50000, 30000, 40000, 50000,
            ],
        );
        let result = divide_flat(&light, &flat).unwrap();
        let px = read_u16_pixels(&result);
        for (i, &v) in px.iter().enumerate() {
            assert_eq!(
                v,
                10000,
                "channel {} pixel {} tinted to {}",
                i % 3,
                i / 3,
                v
            );
        }
    }

    #[test]
    fn test_dimension_mismatch() {
        let light = make_u16_image(4, 4, &[0; 16]);
        let dark = make_u16_image(2, 2, &[0; 4]);
        let result = subtract_dark(&light, &dark);
        assert!(result.is_err());
        let err = result.unwrap_err();
        match err {
            CalibrationError::DimensionMismatch { .. } => {}
            _ => panic!("Expected DimensionMismatch, got {:?}", err),
        }
    }

    #[test]
    fn test_calibrate_frame_full_pipeline() {
        // Light with signal + thermal noise + readout bias + vignetting
        let light = make_u16_image(2, 2, &[5100, 7200, 7200, 5100]);
        let dark = make_u16_image(2, 2, &[200, 200, 200, 200]); // thermal signal + bias
        let flat = make_u16_image(2, 2, &[3100, 5100, 5100, 3100]); // vignette + bias
        let bias = make_u16_image(2, 2, &[100, 100, 100, 100]); // readout bias

        let result = calibrate_frame(&light, Some(&dark), Some(&flat), Some(&bias)).unwrap();
        let pixels = read_u16_pixels(&result);

        // Corrected dark = dark - bias = [100, 100, 100, 100]  (thermal only)
        // Corrected flat = flat - bias = [3000, 5000, 5000, 3000]
        // Bias IS subtracted from the light too (so the pedestal cancels):
        //   light - bias        = [5000, 7100, 7100, 5000]
        //   - corrected_dark    = [4900, 7000, 7000, 4900]  (== pure signal;
        //     signal = light - thermal(100) - bias(100) = 5100-200 = 4900)
        // Flat mean = (3000+5000+5000+3000)/4 = 4000
        // After flat division (restores vignetting):
        //   4900 / (3000/4000) = 4900/0.75 = 6533
        //   7000 / (5000/4000) = 7000/1.25 = 5600
        //   7000 / (5000/4000) = 7000/1.25 = 5600
        //   4900 / (3000/4000) = 4900/0.75 = 6533
        assert_eq!(pixels, vec![6533, 5600, 5600, 6533]);
    }

    #[test]
    fn test_calibrate_frame_dark_only() {
        let light = make_u16_image(2, 2, &[1000, 2000, 3000, 4000]);
        let dark = make_u16_image(2, 2, &[100, 100, 100, 100]);
        let result = calibrate_frame(&light, Some(&dark), None, None).unwrap();
        let pixels = read_u16_pixels(&result);
        assert_eq!(pixels, vec![900, 1900, 2900, 3900]);
    }

    #[test]
    fn test_calibrate_frame_bias_dark_pedestal_cancels() {
        // With bias + dark (no flat) the bias pedestal must cancel, so the
        // result equals (light - bias) - (dark - bias) = light - dark. Skipping
        // the bias subtraction on the light whenever a dark is present leaves
        // `light - (dark - bias) = signal + bias`.
        let light = make_u16_image(2, 2, &[1000, 2000, 3000, 4000]);
        let dark = make_u16_image(2, 2, &[100, 100, 100, 100]); // thermal + bias
        let bias = make_u16_image(2, 2, &[50, 50, 50, 50]);
        let result = calibrate_frame(&light, Some(&dark), None, Some(&bias)).unwrap();
        let pixels = read_u16_pixels(&result);
        // == light - dark, identical to the dark-only case above (bias cancels).
        assert_eq!(pixels, vec![900, 1900, 2900, 3900]);
    }

    #[test]
    fn test_calibrate_frame_flat_only() {
        let light = make_u16_image(2, 2, &[3000, 5000, 5000, 3000]);
        let flat = make_u16_image(2, 2, &[3000, 5000, 5000, 3000]);
        let result = calibrate_frame(&light, None, Some(&flat), None).unwrap();
        let pixels = read_u16_pixels(&result);
        assert_eq!(pixels, vec![4000, 4000, 4000, 4000]);
    }

    #[test]
    fn test_calibrate_frame_bias_only() {
        let light = make_u16_image(2, 2, &[500, 600, 700, 800]);
        let bias = make_u16_image(2, 2, &[100, 100, 100, 100]);
        let result = calibrate_frame(&light, None, None, Some(&bias)).unwrap();
        let pixels = read_u16_pixels(&result);
        assert_eq!(pixels, vec![400, 500, 600, 700]);
    }

    #[test]
    fn test_calibrate_frame_none() {
        let light = make_u16_image(2, 2, &[1000, 2000, 3000, 4000]);
        let result = calibrate_frame(&light, None, None, None).unwrap();
        let pixels = read_u16_pixels(&result);
        assert_eq!(pixels, vec![1000, 2000, 3000, 4000]);
    }

    #[test]
    fn test_f32_subtract() {
        let light = ImageData::from_f32(2, 2, 1, &[0.5, 0.8, 0.3, 1.0]);
        let dark = ImageData::from_f32(2, 2, 1, &[0.1, 0.1, 0.5, 0.1]);
        let result = subtract_dark(&light, &dark).unwrap();
        let pixels = result.as_f32().unwrap();
        // 0.5-0.1=0.4, 0.8-0.1=0.7, 0.3-0.5=clamp to 0.0, 1.0-0.1=0.9
        assert!((pixels[0] - 0.4).abs() < 1e-6);
        assert!((pixels[1] - 0.7).abs() < 1e-6);
        assert!((pixels[2] - 0.0).abs() < 1e-6);
        assert!((pixels[3] - 0.9).abs() < 1e-6);
    }

    #[test]
    fn test_empty_frame_error() {
        let light = ImageData::default();
        let dark = make_u16_image(2, 2, &[0; 4]);
        let result = subtract_dark(&light, &dark);
        assert!(result.is_err());
    }
}
