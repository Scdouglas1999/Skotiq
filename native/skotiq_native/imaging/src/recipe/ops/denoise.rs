//! Noise reduction on linear data: à trous (starlet) wavelet thresholding on
//! luminance, with the chroma planes smoothed separately.
//!
//! # The transform
//!
//! The à trous ("with holes") transform convolves a plane with the separable
//! B3-spline kernel `[1, 4, 6, 4, 1] / 16`, spreading the taps by `2^j` at scale
//! `j` instead of decimating. Every scale therefore stays the size of the frame
//! and the decomposition is shift-invariant, which is what keeps a star from
//! growing a ringing halo when a coefficient is shrunk. With `c₀` the plane,
//!
//! ```text
//! c_{j+1} = B3 ⊛ c_j        (taps spread by 2^j)
//! w_{j+1} = c_j − c_{j+1}   (the detail at that scale)
//! ```
//!
//! so `c₀ = c_J + Σ w_j` by construction: the reconstruction is a sum, not an
//! inverse filter.
//!
//! # Thresholding
//!
//! Each detail plane is soft-thresholded at `thresholdSigma · σ_j`, where `σ_j`
//! is that scale's own noise level measured as `MAD(|w_j|) · 1.4826`. The
//! per-scale MAD is what makes the operation adapt to a master's own noise
//! instead of an assumed ADU scale. Soft (not hard) thresholding shrinks a
//! surviving coefficient by the threshold rather than passing it through, which
//! is why the result has no step discontinuity at the threshold.
//!
//! The operation accumulates the *correction* `soft(w) − w` rather than
//! rebuilding the plane from its scales, so a zero threshold contributes exactly
//! zero and the arithmetic that would otherwise perturb every pixel never
//! happens.
//!
//! # Luminance and chroma
//!
//! Luminance is the mean across channels and carries the detail thresholding.
//! Chroma — each channel's departure from that mean — is replaced by its own
//! low-pass residual in proportion to `chromaStrength`, because colour noise
//! lives at higher spatial frequencies than any real colour structure. A
//! one-channel master has no chroma by construction (its departure from the mean
//! is identically zero), so `chromaStrength` has nothing to act on there.
//!
//! # Preview scale
//!
//! `scaleCount` is a count of octaves of render-level pixels, not a length, so
//! it is not multiplied by [`OpContext::scale`]. Noise is a per-pixel quantity
//! and a preview level has already averaged it down, so the scales a preview
//! thresholds are the scales its own noise occupies. `thresholdSigma`,
//! `strength` and `chromaStrength` are in value units.

use rayon::prelude::*;
use serde_json::Value;

use crate::recipe::{DarkroomOp, OpContext, OpError, OpImage, OpStage, Params, CANCEL_POLL_PIXELS};
use crate::robust_stats::{median_in_place, MAD_TO_SIGMA};

/// Registry id.
const OP_ID: &str = "denoise";
/// Registry version.
const OP_VERSION: u32 = 1;

/// The B3-spline à trous kernel, `[1, 4, 6, 4, 1] / 16`.
const KERNEL: [f64; 5] = [1.0 / 16.0, 4.0 / 16.0, 6.0 / 16.0, 4.0 / 16.0, 1.0 / 16.0];

/// Fewest wavelet scales; one scale thresholds pixel-to-pixel noise alone.
const SCALE_COUNT_MIN: u32 = 1;
/// Most wavelet scales. The coarsest tap spread is `2^(n−1)`, and beyond this
/// the "detail" is structure a denoiser has no business shrinking.
const SCALE_COUNT_MAX: u32 = 6;
/// Wavelet scales when the parameter is absent.
const SCALE_COUNT_DEFAULT: u32 = 4;

/// Lowest detail threshold; `0` shrinks nothing and leaves the luminance exact.
const THRESHOLD_SIGMA_MIN: f64 = 0.0;
/// Highest detail threshold.
const THRESHOLD_SIGMA_MAX: f64 = 10.0;
/// Detail threshold when the parameter is absent, in per-scale noise sigmas.
const THRESHOLD_SIGMA_DEFAULT: f64 = 3.0;

/// Lowest correction weight; `0` is the identity.
const STRENGTH_MIN: f64 = 0.0;
/// Highest correction weight.
const STRENGTH_MAX: f64 = 1.0;
/// Correction weight when the parameter is absent.
const STRENGTH_DEFAULT: f64 = 1.0;

/// Lowest chroma smoothing weight; `0` leaves chroma untouched.
const CHROMA_STRENGTH_MIN: f64 = 0.0;
/// Highest chroma smoothing weight; `1` replaces chroma by its low-pass
/// residual.
const CHROMA_STRENGTH_MAX: f64 = 1.0;
/// Chroma smoothing weight when the parameter is absent.
const CHROMA_STRENGTH_DEFAULT: f64 = 0.5;

/// Samples a per-scale noise level is measured from. The stride follows from
/// the sample count, so it never depends on how the work is scheduled.
const NOISE_SAMPLE_BUDGET: usize = 262_144;

/// Shrinks noise while leaving a flat frame and a zero-strength step exact.
pub struct DenoiseV1;

/// One step's validated parameters.
struct Settings {
    /// Wavelet scales thresholded.
    scale_count: u32,
    /// Detail threshold, in per-scale noise sigmas.
    threshold_sigma: f64,
    /// Weight the whole correction is applied at.
    strength: f64,
    /// Weight the chroma low-pass is applied at.
    chroma_strength: f64,
}

impl DarkroomOp for DenoiseV1 {
    fn id(&self) -> &'static str {
        OP_ID
    }

    fn version(&self) -> u32 {
        OP_VERSION
    }

    fn stage(&self) -> OpStage {
        OpStage::Linear
    }

    fn validate_params(&self, params: &Value) -> Result<(), OpError> {
        read_settings(params).map(|_| ())
    }

    fn apply(&self, image: &OpImage, params: &Value, ctx: &OpContext) -> Result<OpImage, OpError> {
        let settings = read_settings(params)?;
        if settings.strength == STRENGTH_MIN {
            // The documented identity: no correction is applied at all.
            return Ok(image.clone());
        }
        ctx.check_cancel()?;

        let width = image.width() as usize;
        let height = image.height() as usize;
        let channels = image.channels() as usize;
        let pixels = image.pixel_count();
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
                    let mut total = 0.0_f64;
                    for channel in 0..channels {
                        total += source[pixel + channel] as f64;
                    }
                    *slot = total / channels as f64;
                }
            });
        ctx.check_cancel()?;

        let (correction, low_pass) = threshold_scales(&luminance, width, height, &settings, ctx)?;

        // Chroma is a departure from the mean across channels, so a one-channel
        // master has none and the low-pass of its single plane would be
        // subtracted from itself.
        let smooth_chroma = channels > 1 && settings.chroma_strength > CHROMA_STRENGTH_MIN;

        let mut out = vec![0.0_f32; image.len()];
        for channel in 0..channels {
            let plane: Vec<f64> = source
                .iter()
                .skip(channel)
                .step_by(channels)
                .map(|&value| value as f64)
                .collect();
            let chroma_low_pass = if smooth_chroma {
                Some(low_pass_plane(
                    &plane,
                    width,
                    height,
                    settings.scale_count,
                    ctx,
                )?)
            } else {
                None
            };
            for (index, slot) in out.iter_mut().skip(channel).step_by(channels).enumerate() {
                if index % CANCEL_POLL_PIXELS == 0 && ctx.cancel_requested() {
                    break;
                }
                let value = plane[index];
                let mut delta = correction[index];
                if let Some(chroma) = &chroma_low_pass {
                    let chroma_now = value - luminance[index];
                    let chroma_smoothed = chroma[index] - low_pass[index];
                    delta += settings.chroma_strength * (chroma_smoothed - chroma_now);
                }
                *slot = (value + settings.strength * delta) as f32;
            }
            ctx.check_cancel()?;
        }

        image.with_data(out)
    }
}

/// Read and range-check one step's payload. `validate_params` and `apply` share
/// this, so the two can never disagree about a default.
fn read_settings(params: &Value) -> Result<Settings, OpError> {
    let p = Params::new(&DenoiseV1, params)?;
    p.allow(&["scaleCount", "thresholdSigma", "strength", "chromaStrength"])?;
    Ok(Settings {
        scale_count: p.u32_or(
            "scaleCount",
            SCALE_COUNT_MIN..=SCALE_COUNT_MAX,
            SCALE_COUNT_DEFAULT,
        )?,
        threshold_sigma: p.f64_or(
            "thresholdSigma",
            THRESHOLD_SIGMA_MIN..=THRESHOLD_SIGMA_MAX,
            THRESHOLD_SIGMA_DEFAULT,
        )?,
        strength: p.f64_or("strength", STRENGTH_MIN..=STRENGTH_MAX, STRENGTH_DEFAULT)?,
        chroma_strength: p.f64_or(
            "chromaStrength",
            CHROMA_STRENGTH_MIN..=CHROMA_STRENGTH_MAX,
            CHROMA_STRENGTH_DEFAULT,
        )?,
    })
}

/// Walk the wavelet scales of `plane`, returning the accumulated correction
/// `Σ (soft(w_j) − w_j)` and the low-pass residual `c_J`.
///
/// A zero threshold contributes exactly zero to the correction at every scale,
/// so a plane the operation has nothing to shrink comes back untouched.
fn threshold_scales(
    plane: &[f64],
    width: usize,
    height: usize,
    settings: &Settings,
    ctx: &OpContext,
) -> Result<(Vec<f64>, Vec<f64>), OpError> {
    let mut correction = vec![0.0_f64; plane.len()];
    let mut current = plane.to_vec();
    for scale in 0..settings.scale_count {
        let next = low_pass(&current, width, height, 1usize << scale, ctx)?;
        let detail: Vec<f64> = current
            .iter()
            .zip(next.iter())
            .map(|(coarse, fine)| coarse - fine)
            .collect();
        let threshold = settings.threshold_sigma * detail_sigma(&detail);
        for (slot, value) in correction.iter_mut().zip(detail.iter()) {
            let shrink = value.abs().min(threshold);
            *slot += if *value > 0.0 { -shrink } else { shrink };
        }
        current = next;
        ctx.check_cancel()?;
    }
    Ok((correction, current))
}

/// The low-pass residual of `plane` after `scales` à trous scales.
fn low_pass_plane(
    plane: &[f64],
    width: usize,
    height: usize,
    scales: u32,
    ctx: &OpContext,
) -> Result<Vec<f64>, OpError> {
    let mut current = plane.to_vec();
    for scale in 0..scales {
        current = low_pass(&current, width, height, 1usize << scale, ctx)?;
    }
    Ok(current)
}

/// One à trous low-pass pass: the separable B3-spline kernel with its taps
/// spread by `spacing`, mirrored at the frame edges.
fn low_pass(
    plane: &[f64],
    width: usize,
    height: usize,
    spacing: usize,
    ctx: &OpContext,
) -> Result<Vec<f64>, OpError> {
    let step = spacing as i64;
    let mut horizontal = vec![0.0_f64; plane.len()];
    horizontal
        .par_chunks_exact_mut(width)
        .enumerate()
        .for_each(|(y, row)| {
            if ctx.cancel_requested() {
                return;
            }
            let base = y * width;
            for (x, slot) in row.iter_mut().enumerate() {
                let mut total = 0.0_f64;
                for (tap, weight) in KERNEL.iter().enumerate() {
                    let offset = (tap as i64 - 2) * step;
                    let sample = mirror(x as i64 + offset, width as i64);
                    total += weight * plane[base + sample];
                }
                *slot = total;
            }
        });
    ctx.check_cancel()?;

    let mut out = vec![0.0_f64; plane.len()];
    out.par_chunks_exact_mut(width)
        .enumerate()
        .for_each(|(y, row)| {
            if ctx.cancel_requested() {
                return;
            }
            for (x, slot) in row.iter_mut().enumerate() {
                let mut total = 0.0_f64;
                for (tap, weight) in KERNEL.iter().enumerate() {
                    let offset = (tap as i64 - 2) * step;
                    let sample = mirror(y as i64 + offset, height as i64);
                    total += weight * horizontal[sample * width + x];
                }
                *slot = total;
            }
        });
    ctx.check_cancel()?;

    Ok(out)
}

/// Whole-sample symmetric reflection of `index` into `[0, length)`, the border
/// convention that leaves a flat frame flat.
fn mirror(index: i64, length: i64) -> usize {
    if length <= 1 {
        return 0;
    }
    let period = 2 * (length - 1);
    let mut folded = index.rem_euclid(period);
    if folded >= length {
        folded = period - folded;
    }
    folded as usize
}

/// Noise level of one detail plane: the MAD of its coefficients about zero,
/// scaled onto a standard-deviation footing.
///
/// A wavelet detail plane has zero mean by construction, so the median absolute
/// coefficient *is* the MAD.
fn detail_sigma(detail: &[f64]) -> f64 {
    let stride = (detail.len() / NOISE_SAMPLE_BUDGET).max(1);
    let mut samples: Vec<f64> = detail
        .iter()
        .step_by(stride)
        .map(|value| value.abs())
        .filter(|value| value.is_finite())
        .collect();
    if samples.is_empty() {
        return 0.0;
    }
    median_in_place(&mut samples) * MAD_TO_SIGMA
}

#[cfg(test)]
#[path = "denoise_tests.rs"]
mod denoise_tests;
