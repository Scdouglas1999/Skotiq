//! Star de-emphasis on stretched data: a grayscale morphological erosion
//! confined to a soft star mask.
//!
//! Once faint structure is stretched up, oversized stellar cores compete with
//! the subject. Eroding a bright blob — replacing each sample by the minimum
//! over a small structuring disk — shrinks it from its edge inward, which is the
//! geometric operation that makes a star smaller. Confining that erosion to a
//! feathered mask built from detected stars is what keeps it off the background,
//! the nebulosity and the galaxy the frame was taken for.
//!
//! # The mask
//!
//! [`crate::detect_stars`] runs over a peak-across-channels luminance plane at
//! `maskThresholdSigma` above the measured background. Each detection
//! contributes a disk: weight `1` out to a core radius of twice its measured
//! HFR plus `maskDilatePx`, then a raised-cosine feather to zero over
//! [`FEATHER_PX`]. Disks combine with a maximum, so overlapping stars merge
//! without summing past `1`. A hard-edged mask would leave a visible ring where
//! the reduction stops; the feather is what hides that seam.
//!
//! # Scope
//!
//! A sample whose mask weight is `0` is copied verbatim — no arithmetic, no
//! float round trip — so the background is provably byte-identical to the input.
//! `amount = 0` is an exact clone of the whole frame. Inside the mask the output
//! is a convex combination of the input and its own local minimum, so it never
//! leaves the range the input already occupied.
//!
//! # Preview scale
//!
//! `maskDilatePx` is in pixels at full resolution and is multiplied by
//! [`OpContext::scale`], as are the feather width and the erosion radius. The
//! core radius is derived from each star's own measured HFR, which is already in
//! render-level pixels. `amount` and `maskThresholdSigma` are in value units.

use rayon::prelude::*;
use serde_json::Value;

use crate::recipe::ops::star_detect;
use crate::recipe::{DarkroomOp, OpContext, OpError, OpImage, OpStage, Params};
use crate::{DetectedStar, StarDetectionConfig};

/// Registry id.
const OP_ID: &str = "star_reduce";
/// Registry version.
const OP_VERSION: u32 = 1;

/// Lowest reduction weight; `0` is an exact clone.
const AMOUNT_MIN: f64 = 0.0;
/// Highest reduction weight; `1` replaces a fully masked sample by its local
/// minimum.
const AMOUNT_MAX: f64 = 1.0;
/// Reduction weight when the parameter is absent.
const AMOUNT_DEFAULT: f64 = 0.5;

/// Lowest detection threshold a source must clear to enter the mask, in sigmas
/// above the measured background.
const MASK_THRESHOLD_SIGMA_MIN: f64 = 1.0;
/// Highest detection threshold accepted.
const MASK_THRESHOLD_SIGMA_MAX: f64 = 20.0;
/// Detection threshold when the parameter is absent, in sigmas.
const MASK_THRESHOLD_SIGMA_DEFAULT: f64 = 5.0;

/// Smallest mask dilation, in pixels at full resolution.
const MASK_DILATE_MIN: f64 = 0.0;
/// Largest mask dilation, in pixels at full resolution.
const MASK_DILATE_MAX: f64 = 32.0;
/// Mask dilation when the parameter is absent, in pixels at full resolution.
/// Reaches the halo just outside the photometric core.
const MASK_DILATE_DEFAULT: f64 = 2.0;

/// Core radius of a star's mask disk as a multiple of its measured HFR. HFR is
/// the half-flux radius, so twice it covers roughly 95% of a Gaussian PSF's
/// encircled energy.
const HFR_CORE_MULTIPLE: f64 = 2.0;
/// Raised-cosine feather width outside the dilated core, in pixels at full
/// resolution.
const FEATHER_PX: f64 = 3.0;
/// Smallest mask core radius, in render-level pixels, so a tight star still has
/// a neighbourhood the erosion can act on.
const MIN_CORE_RADIUS_PX: f64 = 1.0;
/// Largest mask core radius as a fraction of the frame's shorter side, so one
/// mismeasured HFR cannot mask the frame.
const MAX_CORE_RADIUS_FRACTION: f64 = 0.1;
/// Structuring-disk radius of the erosion, in pixels at full resolution.
const EROSION_RADIUS_PX: f64 = 2.0;

/// Shrinks detected stars and leaves everything outside the mask byte-identical.
pub struct StarReduceV1;

/// One step's validated parameters.
struct Settings {
    /// Weight the erosion is blended in at inside the mask.
    amount: f64,
    /// Detection threshold a source clears to enter the mask, in sigmas.
    mask_threshold_sigma: f64,
    /// Mask dilation, in pixels at full resolution.
    mask_dilate_px: f64,
}

/// One masked star, in render-level pixels.
struct Disk {
    /// Centre column.
    x: f64,
    /// Centre row.
    y: f64,
    /// Radius the weight is flat `1` inside.
    core: f64,
    /// Radius the weight has fallen to `0` at.
    outer: f64,
}

impl DarkroomOp for StarReduceV1 {
    fn id(&self) -> &'static str {
        OP_ID
    }

    fn version(&self) -> u32 {
        OP_VERSION
    }

    fn stage(&self) -> OpStage {
        OpStage::Stretched
    }

    fn validate_params(&self, params: &Value) -> Result<(), OpError> {
        read_settings(params).map(|_| ())
    }

    fn apply(&self, image: &OpImage, params: &Value, ctx: &OpContext) -> Result<OpImage, OpError> {
        let settings = read_settings(params)?;
        if settings.amount == AMOUNT_MIN {
            // The documented identity: nothing is blended in anywhere.
            return Ok(image.clone());
        }
        ctx.check_cancel()?;

        let width = image.width() as usize;
        let height = image.height() as usize;
        let channels = image.channels() as usize;
        let scale = ctx.scale();

        // Masking, not photometry: the sharpness ceiling is open and the area
        // and shape floors are low, because a star left out of the mask keeps
        // its full size while an over-inclusive mask is feathered and
        // attenuated.
        let config = StarDetectionConfig {
            detection_sigma: settings.mask_threshold_sigma,
            max_sharpness: 1.0,
            min_area: 3,
            min_hfr: 0.5,
            max_eccentricity: 1.0,
            ..StarDetectionConfig::default()
        };
        let detected = star_detect::detect(image, &config, ctx)?;
        let mask = build_mask(
            &detected,
            width,
            height,
            settings.mask_dilate_px * scale,
            FEATHER_PX * scale,
            ctx,
        )?;

        let radius = ((EROSION_RADIUS_PX * scale).round() as i64).max(1);
        let source = image.data();
        let mut out = source.to_vec();
        for channel in 0..channels {
            let plane: Vec<f64> = source
                .iter()
                .skip(channel)
                .step_by(channels)
                .map(|&value| value as f64)
                .collect();
            let eroded = erode(&plane, width, height, radius, ctx)?;
            out.par_chunks_exact_mut(width * channels)
                .enumerate()
                .for_each(|(y, row)| {
                    if ctx.cancel_requested() {
                        return;
                    }
                    for x in 0..width {
                        let index = y * width + x;
                        let weight = mask[index] as f64 * settings.amount;
                        if weight <= 0.0 {
                            // Outside the mask the input sample is kept
                            // verbatim, so the background is byte-identical.
                            continue;
                        }
                        row[x * channels + channel] =
                            (plane[index] * (1.0 - weight) + eroded[index] * weight) as f32;
                    }
                });
            ctx.check_cancel()?;
        }

        image.with_data(out)
    }
}

/// Read and range-check one step's payload. `validate_params` and `apply` share
/// this, so the two can never disagree about a default.
fn read_settings(params: &Value) -> Result<Settings, OpError> {
    let p = Params::new(&StarReduceV1, params)?;
    p.allow(&["amount", "maskThresholdSigma", "maskDilatePx"])?;
    Ok(Settings {
        amount: p.f64_or("amount", AMOUNT_MIN..=AMOUNT_MAX, AMOUNT_DEFAULT)?,
        mask_threshold_sigma: p.f64_or(
            "maskThresholdSigma",
            MASK_THRESHOLD_SIGMA_MIN..=MASK_THRESHOLD_SIGMA_MAX,
            MASK_THRESHOLD_SIGMA_DEFAULT,
        )?,
        mask_dilate_px: p.f64_or(
            "maskDilatePx",
            MASK_DILATE_MIN..=MASK_DILATE_MAX,
            MASK_DILATE_DEFAULT,
        )?,
    })
}

/// The soft star mask, one weight in `[0, 1]` per pixel.
///
/// Disks combine with a maximum, which is order-independent and exact, so the
/// mask does not depend on how the rows are scheduled.
fn build_mask(
    stars: &[DetectedStar],
    width: usize,
    height: usize,
    dilate: f64,
    feather: f64,
    ctx: &OpContext,
) -> Result<Vec<f32>, OpError> {
    let mut mask = vec![0.0_f32; width * height];
    if stars.is_empty() {
        return Ok(mask);
    }
    let core_ceiling =
        (width.min(height) as f64 * MAX_CORE_RADIUS_FRACTION).max(MIN_CORE_RADIUS_PX);
    let disks: Vec<Disk> = stars
        .iter()
        .filter(|star| star.x.is_finite() && star.y.is_finite() && star.hfr.is_finite())
        .map(|star| {
            let core =
                (star.hfr * HFR_CORE_MULTIPLE + dilate).clamp(MIN_CORE_RADIUS_PX, core_ceiling);
            Disk {
                x: star.x,
                y: star.y,
                core,
                outer: core + feather.max(0.0),
            }
        })
        .collect();

    mask.par_chunks_exact_mut(width)
        .enumerate()
        .for_each(|(y, row)| {
            if ctx.cancel_requested() {
                return;
            }
            let row_y = y as f64;
            for disk in &disks {
                let dy = row_y - disk.y;
                if dy.abs() > disk.outer {
                    continue;
                }
                let half = (disk.outer * disk.outer - dy * dy).max(0.0).sqrt();
                let first = (disk.x - half).floor().max(0.0) as usize;
                let last = ((disk.x + half).ceil().max(0.0) as usize).min(width - 1);
                for (x, slot) in row.iter_mut().enumerate().take(last + 1).skip(first) {
                    let dx = x as f64 - disk.x;
                    let weight = disk_weight((dx * dx + dy * dy).sqrt(), disk.core, disk.outer);
                    if weight > *slot {
                        *slot = weight;
                    }
                }
            }
        });
    ctx.check_cancel()?;

    Ok(mask)
}

/// Raised-cosine feather weight at radius `r`: `1` inside `core`, `0` at and
/// beyond `outer`, and a cosine ramp with zero slope at both ends between them.
fn disk_weight(r: f64, core: f64, outer: f64) -> f32 {
    if r <= core {
        1.0
    } else if r >= outer || outer <= core {
        0.0
    } else {
        let t = (r - core) / (outer - core);
        (0.5 * (1.0 + (std::f64::consts::PI * t).cos())) as f32
    }
}

/// Grayscale morphological erosion: each sample becomes the minimum over a disk
/// of `radius` pixels centred on it, clamped at the frame edges.
fn erode(
    plane: &[f64],
    width: usize,
    height: usize,
    radius: i64,
    ctx: &OpContext,
) -> Result<Vec<f64>, OpError> {
    let radius_sq = (radius * radius) as f64;
    let mut out = vec![0.0_f64; plane.len()];
    out.par_chunks_exact_mut(width)
        .enumerate()
        .for_each(|(y, row)| {
            if ctx.cancel_requested() {
                return;
            }
            for (x, slot) in row.iter_mut().enumerate() {
                let mut lowest = f64::INFINITY;
                for dy in -radius..=radius {
                    let sample_y = y as i64 + dy;
                    if sample_y < 0 || sample_y >= height as i64 {
                        continue;
                    }
                    let dy_sq = (dy * dy) as f64;
                    if dy_sq > radius_sq {
                        continue;
                    }
                    let span = (radius_sq - dy_sq).sqrt().floor() as i64;
                    let base = sample_y as usize * width;
                    for dx in -span..=span {
                        let sample_x = x as i64 + dx;
                        if sample_x < 0 || sample_x >= width as i64 {
                            continue;
                        }
                        let value = plane[base + sample_x as usize];
                        if value < lowest {
                            lowest = value;
                        }
                    }
                }
                *slot = if lowest.is_finite() {
                    lowest
                } else {
                    plane[y * width + x]
                };
            }
        });
    ctx.check_cancel()?;
    Ok(out)
}

#[cfg(test)]
#[path = "star_reduce_tests.rs"]
mod star_reduce_tests;
