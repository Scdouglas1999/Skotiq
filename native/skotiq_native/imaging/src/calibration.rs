//! Light-frame calibration in floating point: bias, scaled dark and flat, as
//! PixInsight's ImageCalibration applies them ([`calibrate_frame_f32`]).

use crate::ImageData;
use rayon::prelude::*;

#[derive(Debug, Clone)]
pub enum CalibrationError {
    DimensionMismatch {
        expected_width: u32,
        expected_height: u32,
        actual_width: u32,
        actual_height: u32,
        frame_name: String,
    },
    ChannelMismatch {
        expected: u32,
        actual: u32,
        frame_name: String,
    },
    EmptyFrame {
        frame_name: String,
    },
    /// A dark scale that is negative or not finite, or a scaled dark without
    /// a bias to separate its thermal signal from its pedestal.
    InvalidDarkScale {
        scale: f64,
    },
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
    validate_buffer_length(reference, "light frame")?;
    validate_buffer_length(other, other_name)?;
    Ok(())
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
    let mut out = light.samples_f64();
    let bias = cal.bias.map(ImageData::samples_f64);
    if let Some(bias) = &bias {
        out.par_iter_mut()
            .zip(bias.par_iter())
            .for_each(|(v, b)| *v -= b);
    }
    if let Some(dark) = cal.dark {
        let dark = dark.samples_f64();
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
        let mut response = flat.samples_f64();
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

    /// An interleaved RGB flat with different per-channel levels but no
    /// spatial variation leaves uniform RGB light untinted: each channel is
    /// normalized by its own mean.
    #[test]
    fn a_color_flat_is_normalized_per_channel() {
        let light = ImageData::from_u16(2, 2, 3, &[10000; 12]);
        let flat = ImageData::from_u16(2, 2, 3, &[30000, 40000, 50000].repeat(4));
        let cal = FloatCalibration {
            flat: Some(&flat),
            ..Default::default()
        };
        let out = calibrate_frame_f32(&light, &cal).unwrap().as_f32().unwrap();
        for (i, v) in out.iter().enumerate() {
            assert!((v - 10000.0).abs() < 1e-3, "channel {} reads {v}", i % 3);
        }
    }

    /// A flat sample at or below zero yields the pedestal instead of a
    /// division by zero.
    #[test]
    fn a_dead_flat_pixel_yields_the_pedestal() {
        let light = ImageData::from_u16(2, 1, 1, &[1000, 1000]);
        let flat = ImageData::from_f32(2, 1, 1, &[0.0, 2.0]);
        let cal = FloatCalibration {
            flat: Some(&flat),
            output_pedestal: 100.0,
            ..Default::default()
        };
        let out = calibrate_frame_f32(&light, &cal).unwrap().as_f32().unwrap();
        assert_eq!(out, vec![100.0, 1100.0]);
    }

    #[test]
    fn masters_of_another_size_or_an_empty_light_are_refused() {
        let light = ImageData::from_u16(4, 4, 1, &[0; 16]);
        let dark = ImageData::from_u16(2, 2, 1, &[0; 4]);
        let cal = FloatCalibration {
            dark: Some(&dark),
            ..Default::default()
        };
        assert!(matches!(
            calibrate_frame_f32(&light, &cal),
            Err(CalibrationError::DimensionMismatch { .. })
        ));
        assert!(matches!(
            calibrate_frame_f32(&ImageData::default(), &cal),
            Err(CalibrationError::EmptyFrame { .. })
        ));
    }
}
