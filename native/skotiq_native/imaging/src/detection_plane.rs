//! The plane the star detector reads.
//!
//! The detector works on one channel of floating-point samples in 16-bit ADU:
//! its noise floors are 1 ADU and `saturation_limit` is a 0–65535 level. An
//! image that is not already a single 16-bit channel is turned into such a
//! plane here, by a stated rule, so the features that detect stars differ only
//! in the rule they name.

use crate::{ImageData, PixelType};
use rayon::prelude::*;

/// Level the brightest sample of a rescaled plane maps to. It equals the
/// detector's default `saturation_limit`, so rescaling never manufactures a
/// saturated star.
pub const RESCALED_FULL_SCALE: f64 = 60_000.0;

/// A plane whose finite peak is below this is normalized float data (`[0, 1]`
/// or so), not ADU: no real 16-bit frame has every star under 256 ADU.
pub const ADU_SCALE_MIN_PEAK: f64 = 256.0;

/// How several channels become one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChannelCollapse {
    /// Rec. 601 luma, `0.299 R + 0.587 G + 0.114 B`: a stable plane for
    /// matching stars between frames. Needs exactly three channels.
    Rec601,
    Mean,
    /// Brightest channel at each pixel: a star bright in any one channel is
    /// kept, which is what a star mask needs.
    Max,
}

/// How a computed level becomes a plane sample.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Quantize {
    /// Nearest whole ADU.
    Round,
    /// Whole ADU toward zero.
    Truncate,
}

impl Quantize {
    #[inline]
    fn apply(self, value: f64) -> f32 {
        match self {
            Quantize::Round => value.round() as f32,
            Quantize::Truncate => value.trunc() as f32,
        }
    }
}

/// One channel of samples in 16-bit ADU, ready for the detector.
#[derive(Debug, Clone)]
pub struct DetectionPlane {
    pub(crate) width: usize,
    pub(crate) height: usize,
    pub(crate) samples: Vec<f32>,
}

impl DetectionPlane {
    /// A plane from samples already in ADU. `None` when the sample count does
    /// not match the dimensions.
    pub fn new(width: usize, height: usize, samples: Vec<f32>) -> Option<Self> {
        (samples.len() == width * height).then_some(Self {
            width,
            height,
            samples,
        })
    }

    pub fn width(&self) -> usize {
        self.width
    }

    pub fn height(&self) -> usize {
        self.height
    }

    pub fn samples(&self) -> &[f32] {
        &self.samples
    }

    /// The plane of `image` at its own scale: the samples of a one-channel
    /// image, the Rec. 601 luma of a three-channel one. Luma of an integer
    /// image is rounded to whole ADU and kept within the 16-bit range; a float
    /// image is taken as it is, so it must already be in ADU.
    ///
    /// `None` for any other channel count or a buffer shorter than the
    /// dimensions call for.
    pub fn from_image(image: &ImageData) -> Option<Self> {
        let width = image.width as usize;
        let height = image.height as usize;
        if !image.holds_all_samples() {
            return None;
        }
        let samples: Vec<f32> = match image.channels {
            1 => image.samples_f32(),
            3 => {
                let integer = !matches!(image.pixel_type, PixelType::F32 | PixelType::F64);
                let size = image.bytes_per_pixel();
                let pixel_type = image.pixel_type;
                image.data[..width * height * 3 * size]
                    .par_chunks_exact(3 * size)
                    .map(|pixel| {
                        let r = crate::samples::sample_from_le(pixel, pixel_type);
                        let g = crate::samples::sample_from_le(&pixel[size..], pixel_type);
                        let b = crate::samples::sample_from_le(&pixel[2 * size..], pixel_type);
                        let luma = 0.299 * r + 0.587 * g + 0.114 * b;
                        if integer {
                            luma.round().clamp(0.0, 65535.0) as f32
                        } else {
                            luma as f32
                        }
                    })
                    .collect()
            }
            _ => return None,
        };
        Self::new(width, height, samples)
    }

    /// A plane from levels already in ADU, quantized and kept within the
    /// 16-bit range. Non-finite levels become 0.
    pub fn from_adu(
        width: usize,
        height: usize,
        levels: &[f64],
        quantize: Quantize,
    ) -> Option<Self> {
        let samples = levels
            .par_iter()
            .map(|&v| {
                if v.is_nan() {
                    0.0
                } else {
                    quantize.apply(v.clamp(0.0, 65535.0))
                }
            })
            .collect();
        Self::new(width, height, samples)
    }

    /// A plane from levels of unknown scale: `low` maps to 0 and `high` to
    /// [`RESCALED_FULL_SCALE`]. Levels below `low` are held at 0, levels above
    /// `high` run on to the top of the 16-bit range (where the detector reads
    /// them as saturated), and non-finite levels become 0.
    ///
    /// `None` when `high` does not exceed `low`: the plane has no range to
    /// detect in.
    pub fn from_range(
        width: usize,
        height: usize,
        levels: &[f64],
        low: f64,
        high: f64,
        quantize: Quantize,
    ) -> Option<Self> {
        if !low.is_finite() || !high.is_finite() || high <= low {
            return None;
        }
        let span = high - low;
        let samples = levels
            .par_iter()
            .map(|&v| {
                if v.is_finite() {
                    quantize.apply((((v - low) / span) * RESCALED_FULL_SCALE).clamp(0.0, 65535.0))
                } else {
                    0.0
                }
            })
            .collect();
        Self::new(width, height, samples)
    }
}

/// Collapse channel-interleaved samples to one level per pixel.
///
/// `Rec601` needs three channels; with any other count it falls back to the
/// mean.
pub fn collapse_channels<T>(interleaved: &[T], channels: usize, rule: ChannelCollapse) -> Vec<f64>
where
    T: Copy + Into<f64> + Sync,
{
    let channels = channels.max(1);
    interleaved
        .par_chunks_exact(channels)
        .map(|pixel| match rule {
            ChannelCollapse::Rec601 if channels == 3 => {
                0.299 * pixel[0].into() + 0.587 * pixel[1].into() + 0.114 * pixel[2].into()
            }
            ChannelCollapse::Max => {
                pixel
                    .iter()
                    .map(|&v| v.into())
                    .fold(
                        f64::NEG_INFINITY,
                        |peak: f64, v: f64| if v > peak { v } else { peak },
                    )
            }
            ChannelCollapse::Rec601 | ChannelCollapse::Mean => {
                pixel.iter().map(|&v| v.into()).sum::<f64>() * (1.0 / channels as f64)
            }
        })
        .collect()
}

/// Smallest and largest finite level, or `None` when there is none.
pub fn finite_range(levels: &[f64]) -> Option<(f64, f64)> {
    let (low, high) = levels
        .iter()
        .filter(|v| v.is_finite())
        .fold((f64::INFINITY, f64::NEG_INFINITY), |(lo, hi), &v| {
            (lo.min(v), hi.max(v))
        });
    (low <= high).then_some((low, high))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_mono_u16_frame_is_read_unchanged() {
        let image = ImageData::from_u16(2, 2, 1, &[0, 500, 65535, 7]);
        let plane = DetectionPlane::from_image(&image).unwrap();
        assert_eq!(plane.samples(), [0.0, 500.0, 65535.0, 7.0]);
    }

    #[test]
    fn integer_rgb_becomes_rounded_luma_and_float_rgb_keeps_its_fraction() {
        let rgb = ImageData::from_u16(1, 1, 3, &[1000, 2001, 3000]);
        let plane = DetectionPlane::from_image(&rgb).unwrap();
        assert_eq!(
            plane.samples(),
            [(299.0f64 + 1174.587 + 342.0).round() as f32]
        );

        let rgb = ImageData::from_u16(3, 1, 3, &[10000, 20000, 30000, 255, 255, 255, 0, 100, 0]);
        let plane = DetectionPlane::from_image(&rgb).unwrap();
        assert_eq!(plane.samples(), [18150.0, 255.0, 59.0]);

        let float = ImageData::from_f32(1, 1, 3, &[1000.0, 2001.0, 3000.0]);
        let plane = DetectionPlane::from_image(&float).unwrap();
        assert!((plane.samples()[0] - 1815.587).abs() < 1e-3);
    }

    #[test]
    fn other_channel_counts_and_short_buffers_have_no_plane() {
        assert!(DetectionPlane::from_image(&ImageData::from_u16(1, 1, 2, &[1, 2])).is_none());
        let mut short = ImageData::from_u16(2, 2, 1, &[1, 2, 3, 4]);
        short.data.truncate(6);
        assert!(DetectionPlane::from_image(&short).is_none());
    }

    #[test]
    fn a_range_maps_onto_the_rescaled_scale() {
        let levels = [0.0, 0.5, 1.0, 2.0, -1.0, f64::NAN];
        let plane = DetectionPlane::from_range(6, 1, &levels, 0.0, 1.0, Quantize::Round).unwrap();
        assert_eq!(plane.samples(), [0.0, 30000.0, 60000.0, 65535.0, 0.0, 0.0]);
        assert!(DetectionPlane::from_range(6, 1, &levels, 1.0, 1.0, Quantize::Round).is_none());
    }

    #[test]
    fn adu_levels_are_quantized_as_asked() {
        let levels = [10.6, 70000.0, -3.0, f64::NAN];
        let round = DetectionPlane::from_adu(4, 1, &levels, Quantize::Round).unwrap();
        assert_eq!(round.samples(), [11.0, 65535.0, 0.0, 0.0]);
        let truncate = DetectionPlane::from_adu(4, 1, &levels, Quantize::Truncate).unwrap();
        assert_eq!(truncate.samples(), [10.0, 65535.0, 0.0, 0.0]);
    }

    #[test]
    fn channels_collapse_by_the_named_rule() {
        let rgb = [1.0f32, 5.0, 3.0, 2.0, 2.0, 8.0];
        assert_eq!(collapse_channels(&rgb, 3, ChannelCollapse::Max), [5.0, 8.0]);
        assert_eq!(
            collapse_channels(&rgb, 3, ChannelCollapse::Mean),
            [3.0, 4.0]
        );
        let luma = collapse_channels(&rgb, 3, ChannelCollapse::Rec601);
        assert!((luma[0] - (0.299 + 2.935 + 0.342)).abs() < 1e-12);
        assert_eq!(finite_range(&[f64::NAN, 2.0, -1.0]), Some((-1.0, 2.0)));
        assert_eq!(finite_range(&[f64::NAN]), None);
    }
}
