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
    /// A dark scale that is negative or not finite, or a scaled dark without
    /// a bias to separate its thermal signal from its pedestal.
    InvalidDarkScale { scale: f64 },
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
            CalibrationError::InvalidDarkScale { scale } => write!(
                f,
                "Dark scale {scale} is invalid; a scaled dark needs a master bias and a finite scale >= 0"
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

/// Validate dimensions and buffers without imposing a sample representation.
fn validate_frame_geometry(
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
    // Validate that raw buffers are correctly sized for their pixel types
    validate_buffer_length(reference, "light frame")?;
    validate_buffer_length(other, other_name)?;
    Ok(())
}

/// Additive calibration requires matching sample representations.
fn validate_frames(
    reference: &ImageData,
    other: &ImageData,
    other_name: &str,
) -> Result<(), CalibrationError> {
    validate_frame_geometry(reference, other, other_name)?;
    if reference.pixel_type != other.pixel_type {
        return Err(CalibrationError::PixelTypeMismatch {
            expected: reference.pixel_type,
            actual: other.pixel_type,
            frame_name: other_name.to_string(),
        });
    }
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
    validate_frame_geometry(light, flat, "flat frame")?;
    if light.pixel_type != flat.pixel_type {
        // Keep a unit-mean float flat fractional: converting it to integer
        // samples before division would turn its response into 0, 1, or 2.
        let float_light = convert_sample_type(light, PixelType::F64);
        let float_flat = convert_sample_type(flat, PixelType::F64);
        let corrected = divide_flat(&float_light, &float_flat)?;
        return Ok(convert_sample_type(&corrected, light.pixel_type).into_owned());
    }

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

    // Dark and bias masters are additive and in ADU. Flats retain their own
    // sample type so normalized float responses stay fractional during division.
    let conformed_dark = dark.map(|d| convert_sample_type(d, light.pixel_type));
    let conformed_bias = bias.map(|b| convert_sample_type(b, light.pixel_type));
    let dark = conformed_dark.as_deref();
    let bias = conformed_bias.as_deref();

    // Validate all provided frames against the light
    if let Some(d) = dark {
        validate_frames(light, d, "dark frame")?;
    }
    if let Some(f) = flat {
        validate_frame_geometry(light, f, "flat frame")?;
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

    // Step 2: Prepare the flat frame. Only an integer flat can still carry the
    // bias pedestal; a floating-point flat is a normalized response map whose
    // pedestal was removed when it was built, so subtracting ADU from it would
    // corrupt it.
    let corrected_flat: Option<ImageData> = match (flat, bias) {
        (Some(f), Some(b)) if !is_float(f.pixel_type) => {
            Some(subtract_bias(f, &convert_sample_type(b, f.pixel_type))?)
        }
        (Some(f), _) => Some(f.clone()),
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

fn is_float(pixel_type: PixelType) -> bool {
    matches!(pixel_type, PixelType::F32 | PixelType::F64)
}

/// Whether a flat master still contains the bias pedestal of its raw frames.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FlatPedestal {
    /// A raw or uncorrected flat: the bias is subtracted before normalizing.
    Included,
    /// A bias- or dark-flat-corrected master: used as it is.
    Removed,
}

/// Masters and options for [`calibrate_frame_f32`].
#[derive(Debug, Clone, Copy)]
pub struct FloatCalibration<'a> {
    pub bias: Option<&'a ImageData>,
    /// A master dark. With a bias it is treated as bias plus thermal signal and
    /// only its thermal part is scaled by `dark_scale`; without one it is
    /// subtracted as it is and `dark_scale` must be 1.
    pub dark: Option<&'a ImageData>,
    /// Multiplier on the dark's thermal signal: the light's exposure over the
    /// dark's when no exposure-matched dark exists, otherwise 1.
    pub dark_scale: f64,
    pub flat: Option<&'a ImageData>,
    pub flat_pedestal: FlatPedestal,
    /// Constant added to every calibrated sample so that sky pixels pulled
    /// below zero by noise keep their value instead of being clipped.
    pub output_pedestal: f32,
}

impl Default for FloatCalibration<'_> {
    fn default() -> Self {
        Self {
            bias: None,
            dark: None,
            dark_scale: 1.0,
            flat: None,
            flat_pedestal: FlatPedestal::Removed,
            output_pedestal: 0.0,
        }
    }
}

/// Calibrate `light` in floating point and return an `F32` frame:
/// `(light - bias - k·(dark - bias)) / flat + pedestal`, never clamped.
///
/// Integer arithmetic clamps every sample that noise pulls below the bias to
/// zero, which biases faint sky upward and leaves isolated zero samples; the
/// float result keeps the full noise distribution as PixInsight's
/// ImageCalibration does. The flat is normalized to unit mean per channel; flat
/// samples at or below zero yield the pedestal.
pub fn calibrate_frame_f32(
    light: &ImageData,
    cal: &FloatCalibration<'_>,
) -> Result<ImageData, CalibrationError> {
    if light.is_empty() {
        return Err(CalibrationError::EmptyFrame {
            frame_name: "light frame".to_string(),
        });
    }
    validate_buffer_length(light, "light frame")?;
    for (frame, name) in [
        (cal.bias, "bias frame"),
        (cal.dark, "dark frame"),
        (cal.flat, "flat frame"),
    ] {
        if let Some(frame) = frame {
            validate_frame_geometry(light, frame, name)?;
        }
    }
    if !cal.dark_scale.is_finite()
        || cal.dark_scale < 0.0
        || (cal.bias.is_none() && cal.dark.is_some() && (cal.dark_scale - 1.0).abs() > 1e-9)
    {
        return Err(CalibrationError::InvalidDarkScale {
            scale: cal.dark_scale,
        });
    }
    let channels = (light.channels as usize).max(1);
    let mut out = samples_f64(light);
    let bias = cal.bias.map(samples_f64);
    if let Some(bias) = &bias {
        out.par_iter_mut()
            .zip(bias.par_iter())
            .for_each(|(v, b)| *v -= b);
    }
    if let Some(dark) = cal.dark {
        let dark = samples_f64(dark);
        let k = cal.dark_scale;
        match &bias {
            Some(bias) => out
                .par_iter_mut()
                .zip(dark.par_iter().zip(bias.par_iter()))
                .for_each(|(v, (d, b))| *v -= k * (d - b)),
            None => out
                .par_iter_mut()
                .zip(dark.par_iter())
                .for_each(|(v, d)| *v -= d),
        }
    }
    if let Some(flat) = cal.flat {
        let mut response = samples_f64(flat);
        if let (FlatPedestal::Included, Some(bias)) = (cal.flat_pedestal, &bias) {
            response
                .par_iter_mut()
                .zip(bias.par_iter())
                .for_each(|(f, b)| *f -= b);
        }
        let means = per_channel_means(&response, channels);
        out.par_iter_mut().enumerate().for_each(|(i, v)| {
            let mean = means[i % channels];
            let normalized = if mean > 0.0 { response[i] / mean } else { 0.0 };
            *v = if normalized > 0.0 {
                *v / normalized
            } else {
                0.0
            };
        });
    }
    let pedestal = f64::from(cal.output_pedestal);
    let data: Vec<f32> = out.par_iter().map(|&v| (v + pedestal) as f32).collect();
    Ok(ImageData::from_f32(
        light.width,
        light.height,
        light.channels,
        &data,
    ))
}

/// Every sample of `image` as `f64`, in buffer order.
pub fn samples_f64(image: &ImageData) -> Vec<f64> {
    match image.pixel_type {
        PixelType::U8 => image.data.par_iter().map(|&v| f64::from(v)).collect(),
        PixelType::U16 => image
            .data
            .par_chunks_exact(2)
            .map(|c| f64::from(u16::from_le_bytes([c[0], c[1]])))
            .collect(),
        PixelType::U32 => image
            .data
            .par_chunks_exact(4)
            .map(|c| f64::from(u32::from_le_bytes([c[0], c[1], c[2], c[3]])))
            .collect(),
        PixelType::F32 => image
            .data
            .par_chunks_exact(4)
            .map(|c| f64::from(f32::from_le_bytes([c[0], c[1], c[2], c[3]])))
            .collect(),
        PixelType::F64 => image
            .data
            .par_chunks_exact(8)
            .map(|c| f64::from_le_bytes(c.try_into().expect("8-byte chunk")))
            .collect(),
    }
}

/// `master` re-encoded as `target` samples, or borrowed unchanged when it
/// already is. Integer targets round and clamp to their range; NaN becomes 0.
fn convert_sample_type(master: &ImageData, target: PixelType) -> std::borrow::Cow<'_, ImageData> {
    if master.pixel_type == target || master.is_empty() {
        return std::borrow::Cow::Borrowed(master);
    }
    let values: Vec<f64> = match master.pixel_type {
        PixelType::U8 => master.data.iter().map(|&v| f64::from(v)).collect(),
        PixelType::U16 => master
            .data
            .as_chunks::<2>()
            .0
            .iter()
            .map(|c| f64::from(u16::from_le_bytes(*c)))
            .collect(),
        PixelType::U32 => master
            .data
            .as_chunks::<4>()
            .0
            .iter()
            .map(|c| f64::from(u32::from_le_bytes(*c)))
            .collect(),
        PixelType::F32 => master
            .data
            .as_chunks::<4>()
            .0
            .iter()
            .map(|c| f64::from(f32::from_le_bytes(*c)))
            .collect(),
        PixelType::F64 => master
            .data
            .as_chunks::<8>()
            .0
            .iter()
            .map(|c| f64::from_le_bytes(*c))
            .collect(),
    };
    let clean = |v: f64| if v.is_nan() { 0.0 } else { v };
    let data: Vec<u8> = match target {
        PixelType::U8 => values
            .iter()
            .map(|&v| clean(v).round().clamp(0.0, 255.0) as u8)
            .collect(),
        PixelType::U16 => values
            .iter()
            .flat_map(|&v| (clean(v).round().clamp(0.0, 65535.0) as u16).to_le_bytes())
            .collect(),
        PixelType::U32 => values
            .iter()
            .flat_map(|&v| (clean(v).round().clamp(0.0, f64::from(u32::MAX)) as u32).to_le_bytes())
            .collect(),
        PixelType::F32 => values
            .iter()
            .flat_map(|&v| (clean(v) as f32).to_le_bytes())
            .collect(),
        PixelType::F64 => values
            .iter()
            .flat_map(|&v| clean(v).to_le_bytes())
            .collect(),
    };
    std::borrow::Cow::Owned(ImageData {
        width: master.width,
        height: master.height,
        channels: master.channels,
        pixel_type: target,
        data,
    })
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

    /// Float calibration keeps samples below the bias, scales the dark's
    /// thermal part by the exposure ratio, adds the pedestal, and only
    /// subtracts the bias from a flat that still carries it.
    #[test]
    fn float_calibration_scales_darks_and_keeps_negative_sky() {
        let light = ImageData::from_u16(2, 1, 1, &[295, 1300]);
        let bias = ImageData::from_u16(2, 1, 1, &[300, 300]);
        let dark = ImageData::from_u16(2, 1, 1, &[310, 310]); // 10 ADU thermal
        let cal = FloatCalibration {
            bias: Some(&bias),
            dark: Some(&dark),
            dark_scale: 2.0,
            output_pedestal: 100.0,
            ..Default::default()
        };
        let out = calibrate_frame_f32(&light, &cal).unwrap().as_f32().unwrap();
        assert_eq!(
            out,
            vec![295.0 - 300.0 - 20.0 + 100.0, 1300.0 - 300.0 - 20.0 + 100.0]
        );

        let raw_flat = ImageData::from_u16(2, 1, 1, &[2300, 4300]);
        let cal = FloatCalibration {
            bias: Some(&bias),
            flat: Some(&raw_flat),
            flat_pedestal: FlatPedestal::Included,
            ..Default::default()
        };
        let light = ImageData::from_u16(2, 1, 1, &[1300, 1300]);
        let out = calibrate_frame_f32(&light, &cal).unwrap().as_f32().unwrap();
        // Bias-corrected flat 2000 / 4000 normalizes to 2/3 and 4/3.
        assert!(
            (out[0] - 1500.0).abs() < 1e-3 && (out[1] - 750.0).abs() < 1e-3,
            "{out:?}"
        );

        let scaled_without_bias = FloatCalibration {
            dark: Some(&dark),
            dark_scale: 2.0,
            ..Default::default()
        };
        assert!(calibrate_frame_f32(&light, &scaled_without_bias).is_err());
    }

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

    #[test]
    fn a_float_dark_master_calibrates_a_u16_light() {
        let light = ImageData::from_u16(2, 2, 1, &[1000, 1200, 900, 65535]);
        let dark = ImageData::from_f32(2, 2, 1, &[100.4, 200.6, 950.0, f32::NAN]);
        let out = calibrate_frame(&light, Some(&dark), None, None).expect("calibrated");
        assert_eq!(out.pixel_type, PixelType::U16);
        assert_eq!(out.as_u16().unwrap(), vec![900, 999, 0, 65535]);
    }

    #[test]
    fn a_float_bias_master_calibrates_a_u16_light() {
        let light = ImageData::from_u16(1, 2, 1, &[500, 600]);
        let bias = ImageData::from_f32(1, 2, 1, &[99.6, 100.2]);
        let out = calibrate_frame(&light, None, None, Some(&bias)).expect("calibrated");
        assert_eq!(out.as_u16().unwrap(), vec![400, 500]);
    }

    #[test]
    fn a_unit_mean_float_flat_calibrates_u16_lights_without_quantizing_the_flat() {
        let light = ImageData::from_u16(2, 2, 1, &[600, 1100, 1600, 100]);
        let dark = ImageData::from_u16(2, 2, 1, &[100; 4]);
        let flat = ImageData::from_f32(2, 2, 1, &[0.5, 1.0, 1.5, 1.0]);
        let out = calibrate_frame(&light, Some(&dark), Some(&flat), None)
            .expect("Darkroom's default float flat must calibrate camera U16 lights");
        assert_eq!(out.pixel_type, PixelType::U16);
        assert_eq!(out.as_u16().unwrap(), vec![1000, 1000, 1000, 0]);
    }

    #[test]
    fn mixed_type_flat_preserves_channel_normalization_and_zero_pixel_behavior() {
        let light = ImageData::from_u16(2, 1, 3, &[100, 200, 300, 100, 200, 300]);
        let flat = ImageData::from_f32(2, 1, 3, &[0.5, 2.0, 0.0, 1.5, 2.0, 6.0]);
        let out = divide_flat(&light, &flat).expect("mixed-type flat");
        assert_eq!(out.as_u16().unwrap(), vec![200, 200, 0, 67, 200, 150]);
    }
}
