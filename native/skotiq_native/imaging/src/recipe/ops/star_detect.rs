//! The star detection the operations share. Not a registered operation.
//!
//! A linear master's ADU scale is not known in advance: a float master may
//! live in `[0, 1]`, a 16-bit one in `[0, 65535]`, and a stretched one in
//! `[0, 1]` again. The plane is therefore rescaled between its own
//! [`LUMINANCE_LOW_QUANTILE`] level and its brightest finite sample.
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

use crate::recipe::{OpContext, OpError, OpImage};
use crate::robust_stats::percentile_nearest_rank;
use crate::detection_plane::{collapse_channels, ChannelCollapse, DetectionPlane, Quantize};
use crate::{detect_stars_in_plane, DetectedStar, StarDetectionConfig};

/// Quantile of the luminance plane mapped to level 0.
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
    Ok(match detection_plane(image, ctx)? {
        Some(plane) => detect_stars_in_plane(plane, config),
        None => Vec::new(),
    })
}

/// The plane [`detect`] runs the detector over, or `None` when the image
/// carries no measurable range.
pub(crate) fn detection_plane(
    image: &OpImage,
    ctx: &OpContext,
) -> Result<Option<DetectionPlane>, OpError> {
    let width = image.width() as usize;
    let height = image.height() as usize;
    let pixels = width * height;

    ctx.check_cancel()?;
    let luminance = collapse_channels(
        image.data(),
        image.channels() as usize,
        ChannelCollapse::Max,
    );
    ctx.check_cancel()?;

    let stride = (pixels / LUMINANCE_SAMPLE_BUDGET).max(1);
    let mut samples: Vec<f64> = luminance
        .iter()
        .step_by(stride)
        .copied()
        .filter(|value| value.is_finite())
        .collect();
    if samples.is_empty() {
        return Ok(None);
    }
    samples.sort_unstable_by(f64::total_cmp);
    let low = percentile_nearest_rank(&samples, LUMINANCE_LOW_QUANTILE);
    let high = luminance
        .iter()
        .copied()
        .filter(|value| value.is_finite())
        .fold(f64::NEG_INFINITY, f64::max);
    ctx.check_cancel()?;

    Ok(DetectionPlane::from_range(
        width,
        height,
        &luminance,
        low,
        high,
        Quantize::Truncate,
    ))
}
