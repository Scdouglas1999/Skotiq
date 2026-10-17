//! The star detection two operations share. Not a registered operation.
//!
//! [`crate::detect_stars`] reads `U16`, and a linear master's ADU scale is not
//! known in advance — a float master may live in `[0, 1]`, a 16-bit one in
//! `[0, 65535]`, and a stretched one in `[0, 1]` again. The plane is therefore
//! quantised between its own [`LUMINANCE_LOW_QUANTILE`] level and its brightest
//! finite sample, onto `[0, `[`LUMINANCE_FULL_SCALE`]`]`.
//!
//! Both anchors matter. A low anchor at a quantile rather than the minimum keeps
//! one dead pixel from setting the floor. A high anchor at the brightest sample
//! rather than a quantile is what keeps star cores *below* the detector's
//! saturation limit: a quantile high anchor puts every core above it, and the
//! detector discards a source whose peak reads saturated, so a star-rich frame
//! would come back with no stars at all.
//!
//! Detection runs over a **peak across channels**, not one channel: a star
//! bright only in blue would fall under the detector's gate on a red plane and
//! be missed everywhere, which is the failure both callers exist to avoid.

use rayon::prelude::*;

use crate::recipe::{OpContext, OpError, OpImage};
use crate::robust_stats::percentile_nearest_rank;
use crate::{detect_stars, DetectedStar, ImageData, StarDetectionConfig};

/// Code the brightest finite sample maps to. It equals the detector's default
/// saturation limit and is also the clamp ceiling, so the quantisation never
/// manufactures a saturated code.
const LUMINANCE_FULL_SCALE: f64 = 60_000.0;

/// Quantile of the luminance plane mapped to code `0`.
const LUMINANCE_LOW_QUANTILE: f64 = 0.001;

/// Samples the low anchor is measured from. The stride follows from the sample
/// count, so it never depends on how the work is scheduled.
const LUMINANCE_SAMPLE_BUDGET: usize = 262_144;

/// Stars detected in `image` under `config`, in the detector's own order.
///
/// An empty result means the plane carried no measurable range or the detector
/// found nothing; both are ordinary outcomes and neither is an error here.
pub(super) fn detect(
    image: &OpImage,
    config: &StarDetectionConfig,
    ctx: &OpContext,
) -> Result<Vec<DetectedStar>, OpError> {
    let width = image.width() as usize;
    let height = image.height() as usize;
    let channels = image.channels() as usize;
    let pixels = width * height;

    let source = image.data();
    let mut luminance = vec![0.0_f64; pixels];
    luminance
        .par_chunks_exact_mut(width)
        .enumerate()
        .for_each(|(y, row)| {
            if ctx.cancel_requested() {
                return;
            }
            let base = y * width * channels;
            for (x, slot) in row.iter_mut().enumerate() {
                let pixel = base + x * channels;
                let mut peak = f64::NEG_INFINITY;
                for channel in 0..channels {
                    let value = source[pixel + channel] as f64;
                    if value > peak {
                        peak = value;
                    }
                }
                *slot = peak;
            }
        });
    ctx.check_cancel()?;

    let stride = (pixels / LUMINANCE_SAMPLE_BUDGET).max(1);
    let mut samples: Vec<f64> = luminance
        .iter()
        .step_by(stride)
        .copied()
        .filter(|value| value.is_finite())
        .collect();
    if samples.is_empty() {
        return Ok(Vec::new());
    }
    samples.sort_unstable_by(f64::total_cmp);
    let low = percentile_nearest_rank(&samples, LUMINANCE_LOW_QUANTILE);
    let high = luminance
        .iter()
        .copied()
        .filter(|value| value.is_finite())
        .fold(f64::NEG_INFINITY, f64::max);
    if !low.is_finite() || !high.is_finite() || high <= low {
        return Ok(Vec::new());
    }

    let span = high - low;
    let quantised: Vec<u16> = luminance
        .iter()
        .map(|&value| {
            if value.is_finite() {
                (((value - low) / span) * LUMINANCE_FULL_SCALE).clamp(0.0, LUMINANCE_FULL_SCALE)
                    as u16
            } else {
                0
            }
        })
        .collect();
    ctx.check_cancel()?;

    let frame = ImageData::from_u16(width as u32, height as u32, 1, &quantised);
    Ok(detect_stars(&frame, config))
}
