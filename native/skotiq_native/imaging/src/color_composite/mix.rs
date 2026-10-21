//! The arithmetic of a color composite: matching one master's flux scale to
//! another's, averaging several sessions of one filter, and laying a luminance
//! master over RGB color.
//!
//! Every function here works on registered single planes of one size. They are
//! linear-domain operations: no clipping, no display transfer.

use rayon::prelude::*;

use crate::robust_stats::{median_in_place, MAD_TO_SIGMA};

/// `y ≈ scale · x + offset`: how one master's values map onto another's.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LinearFit {
    /// Multiplier.
    pub scale: f64,
    /// Additive term.
    pub offset: f64,
}

impl LinearFit {
    /// Apply the fit to one value.
    #[inline]
    pub fn apply(&self, x: f32) -> f32 {
        (self.scale * x as f64 + self.offset) as f32
    }
}

/// Samples a fit reads at most. The stride follows from the pixel count, so it
/// never depends on how the work is scheduled.
const FIT_SAMPLE_BUDGET: usize = 1 << 20;
/// Sigmas above the background a pixel must sit in both planes to count as
/// signal for the scale.
const FIT_SIGNAL_SIGMA: f64 = 10.0;
/// Fraction of a plane's brightest sample above which a pixel may be
/// saturated and is left out of the scale.
const FIT_SATURATION_FRACTION: f64 = 0.9;
/// Fewest signal pixels the scale is read from.
const FIT_MIN_SIGNAL: usize = 64;

/// Background level and noise of a plane: the median and `1.4826 · MAD`.
pub fn background_and_noise(plane: &[f32]) -> (f64, f64) {
    let stride = (plane.len() / FIT_SAMPLE_BUDGET).max(1);
    let mut samples: Vec<f64> = plane
        .iter()
        .step_by(stride)
        .map(|v| *v as f64)
        .filter(|v| v.is_finite())
        .collect();
    if samples.is_empty() {
        return (0.0, 0.0);
    }
    let median = median_in_place(&mut samples);
    let mut deviations: Vec<f64> = samples.iter().map(|v| (v - median).abs()).collect();
    (median, median_in_place(&mut deviations) * MAD_TO_SIGMA)
}

/// Fit `y ≈ scale · x + offset` between two registered planes.
///
/// A least-squares fit over every pixel is dominated by the sky, where the two
/// planes' noise is uncorrelated, and its slope collapses toward zero. The fit
/// here reads the two things that are actually comparable: the scale is the
/// median ratio of background-subtracted values over pixels that are well
/// above the sky in both planes and below saturation (stars and bright object
/// structure), and the offset then makes the two sky backgrounds agree. It is
/// the mapping PixInsight's LinearFit converges to when the signal, not the
/// sky, decides the slope.
///
/// `None` when the planes share too few signal pixels to read a scale from.
pub fn robust_fit(x: &[f32], y: &[f32]) -> Option<LinearFit> {
    if x.len() != y.len() || x.is_empty() {
        return None;
    }
    let (bx, sx) = background_and_noise(x);
    let (by, sy) = background_and_noise(y);
    if !(sx > 0.0 && sy > 0.0) {
        return None;
    }
    let max_x = x.iter().copied().fold(f32::NEG_INFINITY, f32::max) as f64;
    let max_y = y.iter().copied().fold(f32::NEG_INFINITY, f32::max) as f64;
    let sat_x = bx + (max_x - bx) * FIT_SATURATION_FRACTION;
    let sat_y = by + (max_y - by) * FIT_SATURATION_FRACTION;
    let lo_x = bx + FIT_SIGNAL_SIGMA * sx;
    let lo_y = by + FIT_SIGNAL_SIGMA * sy;
    let mut ratios: Vec<f64> = x
        .iter()
        .zip(y.iter())
        .filter_map(|(&xv, &yv)| {
            let (xv, yv) = (xv as f64, yv as f64);
            (xv > lo_x && yv > lo_y && xv < sat_x && yv < sat_y).then(|| (yv - by) / (xv - bx))
        })
        .filter(|r| r.is_finite() && *r > 0.0)
        .collect();
    if ratios.len() < FIT_MIN_SIGNAL {
        return None;
    }
    let scale = median_in_place(&mut ratios);
    Some(LinearFit {
        scale,
        offset: by - scale * bx,
    })
}

/// Average registered planes of one filter, each already mapped onto the first
/// one's scale, weighted by the inverse of its background noise variance.
///
/// Inverse-variance weighting is what an integration of the underlying subs
/// would have given each session's share; a short, noisy session adds what it
/// can without diluting a deep one.
pub fn weighted_mean(planes: &[Vec<f32>]) -> Vec<f32> {
    if planes.len() == 1 {
        return planes[0].clone();
    }
    let weights: Vec<f64> = planes
        .iter()
        .map(|p| {
            let (_, noise) = background_and_noise(p);
            if noise > 0.0 {
                1.0 / (noise * noise)
            } else {
                1.0
            }
        })
        .collect();
    let total: f64 = weights.iter().sum();
    let len = planes[0].len();
    let mut out = vec![0.0_f32; len];
    out.par_iter_mut().enumerate().for_each(|(i, slot)| {
        let mut acc = 0.0;
        for (plane, w) in planes.iter().zip(weights.iter()) {
            acc += plane[i] as f64 * w;
        }
        *slot = (acc / total) as f32;
    });
    out
}

/// `(1 − weight) · base + weight · added`, pixel by pixel.
pub fn blend(base: &[f32], added: &[f32], weight: f64) -> Vec<f32> {
    base.par_iter()
        .zip(added.par_iter())
        .map(|(&b, &a)| ((1.0 - weight) * b as f64 + weight * a as f64) as f32)
        .collect()
}

/// Separable Gaussian blur of one `width × height` plane, edges repeated.
pub fn gaussian_blur(plane: &[f32], width: usize, height: usize, sigma: f64) -> Vec<f32> {
    if sigma <= 0.0 || width == 0 || height == 0 {
        return plane.to_vec();
    }
    let radius = (3.0 * sigma).ceil() as i64;
    let taps: Vec<f64> = (-radius..=radius)
        .map(|i| (-(i * i) as f64 / (2.0 * sigma * sigma)).exp())
        .collect();
    let norm: f64 = taps.iter().sum();
    let taps: Vec<f64> = taps.iter().map(|t| t / norm).collect();
    let w = width as i64;
    let h = height as i64;
    let mut horizontal = vec![0.0_f32; plane.len()];
    horizontal
        .par_chunks_exact_mut(width)
        .enumerate()
        .for_each(|(y, row)| {
            let src = &plane[y * width..(y + 1) * width];
            for (x, slot) in row.iter_mut().enumerate() {
                let mut acc = 0.0;
                for (k, t) in taps.iter().enumerate() {
                    let sx = (x as i64 + k as i64 - radius).clamp(0, w - 1) as usize;
                    acc += t * src[sx] as f64;
                }
                *slot = acc as f32;
            }
        });
    let mut out = vec![0.0_f32; plane.len()];
    out.par_chunks_exact_mut(width)
        .enumerate()
        .for_each(|(y, row)| {
            for (x, slot) in row.iter_mut().enumerate() {
                let mut acc = 0.0;
                for (k, t) in taps.iter().enumerate() {
                    let sy = (y as i64 + k as i64 - radius).clamp(0, h - 1) as usize;
                    acc += t * horizontal[sy * width + x] as f64;
                }
                *slot = acc as f32;
            }
        });
    out
}

/// Lay `luminance` over the color of `rgb`, in linear space.
///
/// Each pixel keeps the chromaticity of `rgb` — its channel ratios, read from
/// `rgb` blurred by `chroma_sigma[c]` pixels so the color carries the RGB
/// masters' signal without their pixel-scale color noise; a channel whose
/// stars are sharper than another's is blurred further so all three share one
/// star profile — and takes its
/// brightness from `luminance`: `out_c = L · c / Y` with `Y` the channel mean.
/// The result's channel mean is exactly `L`, so the luminance master decides
/// every pixel's lightness and the RGB masters only its color. That is the
/// separation PixInsight's LRGBCombination makes with CIE L* over the RGB
/// chrominance; doing it before the stretch, and stretching with a
/// color-preserving transfer, gives the same split of lightness and color.
///
/// Where `Y` sits within `floor` of zero the ratio is unstable, so the color
/// differences are scaled by `L / floor` instead; the two forms agree at
/// `Y = floor`.
pub fn apply_luminance(
    rgb: [&[f32]; 3],
    luminance: &[f32],
    width: usize,
    height: usize,
    chroma_sigma: [f64; 3],
) -> [Vec<f32>; 3] {
    let smoothed: Vec<Vec<f32>> = rgb
        .iter()
        .zip(chroma_sigma)
        .map(|(plane, sigma)| gaussian_blur(plane, width, height, sigma))
        .collect();
    let mean: Vec<f32> = (0..luminance.len())
        .into_par_iter()
        .map(|i| {
            ((smoothed[0][i] as f64 + smoothed[1][i] as f64 + smoothed[2][i] as f64) / 3.0) as f32
        })
        .collect();
    let (_, noise) = background_and_noise(&mean);
    let floor = (3.0 * noise).max(1e-9);
    let channel = |c: usize| -> Vec<f32> {
        (0..luminance.len())
            .into_par_iter()
            .map(|i| {
                let l = luminance[i] as f64;
                let y = mean[i] as f64;
                let value = smoothed[c][i] as f64;
                if y >= floor {
                    (l * value / y) as f32
                } else {
                    (l + (value - y) * l / floor) as f32
                }
            })
            .collect()
    };
    [channel(0), channel(1), channel(2)]
}

/// The extra Gaussian blur, per channel, that brings each of three star
/// profiles of Gaussian sigma `sigmas` to the widest of them.
pub fn psf_match_sigmas(sigmas: [f64; 3]) -> [f64; 3] {
    let widest = sigmas.iter().copied().fold(0.0_f64, f64::max);
    sigmas.map(|s| (widest * widest - s * s).max(0.0).sqrt())
}

#[cfg(test)]
#[path = "mix_tests.rs"]
mod mix_tests;
