//! Per-sub frame quality weighting for batch integration.
//!
//! When many subs are integrated into a single master, the optimal estimator
//! is a *weighted* mean: subs with higher signal-to-noise and tighter,
//! rounder stars should pull the master toward themselves, while noisy,
//! bloated, or trailed subs should contribute less. This is the role of
//! PixInsight's "image weighting" (its *PSF Signal Weight* in particular) and
//! it is the difference between a flat average — where one bad sub drags the
//! whole stack down — and a quality-aware integration.
//!
//! This module turns the cheap, already-available per-frame primitives
//! ([`crate::detect_stars_with_stats`], [`crate::calculate_stats_u16`], the
//! star moments in [`crate::stats`]) into:
//!
//! 1. A robust per-frame quality descriptor ([`FrameQuality`]) — noise,
//!    background, SNR, FWHM, eccentricity, and star count.
//! 2. A scalar integration weight ([`frame_weight`]) under a configurable
//!    [`WeightFormula`], expressed *relative to a reference frame* so the
//!    numbers are dimensionless and comparable across sessions.
//! 3. A batch helper ([`weight_frames`]) that normalizes the population so the
//!    best sub = 1.0 and emits an auto-cull *recommendation* (never silently
//!    dropping subs — the caller decides).
//!
//! ## Noise estimation
//!
//! Robust per-frame noise is estimated as the MAD of the residual after a 3×3
//! median filter, scaled by 1.4826 to put it on a Gaussian-σ footing (this is
//! the standard MAD→σ consistency constant). A median filter removes stars and
//! the smooth sky gradient, leaving (to first order) the pixel-to-pixel noise;
//! the MAD of that residual is insensitive to the bright outliers (stars, hot
//! pixels, cosmic rays) that would wreck a plain standard deviation. This is
//! the same intent as PixInsight's k-sigma noise evaluator, implemented with
//! the project's existing robust-statistics idiom.
//!
//! ## Limitations
//!
//! The default weight *exponents* (`snr_pow`, `fwhm_pow`, `ecc_pow`) and the
//! auto-cull percentile are defensible PixInsight-spirit defaults, **not**
//! values tuned against a corpus of real sub sets. They are exposed as knobs
//! precisely so they can be revisited with real data. The algorithm itself —
//! robust noise, SNR², FWHM and roundness penalties, population normalization
//! — is deterministic and unit-tested on synthetic frames here.

use crate::robust_stats::{median_in_place_par, nearest_rank_index, MAD_TO_SIGMA};
use crate::{calculate_stats_u16, detect_stars_with_stats, ImageData, StarDetectionConfig};
use rayon::prelude::*;

/// Robust per-frame quality descriptor.
///
/// Every field is derived from primitives already computed elsewhere in the
/// crate, so building one is cheap relative to reading and calibrating the
/// frame. Values are in the frame's native ADU domain except the dimensionless
/// `snr`/`eccentricity`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FrameQuality {
    /// Robust per-pixel noise σ (ADU), MAD of the 3×3-median residual × 1.4826.
    pub noise: f64,
    /// Sky-background level (ADU), the robust frame median (proxy for skyglow /
    /// transparency: brighter background ⇒ worse sub, all else equal).
    pub background: f64,
    /// Frame signal-to-noise proxy: `(median_signal − background) / noise`,
    /// where `median_signal` is the bright-tail signal estimate (see
    /// [`analyze_frame_quality`]). Floored at 0.
    pub snr: f64,
    /// Median full-width-half-maximum of detected stars (px); `0.0` when no
    /// stars were detected (a frame with no measurable stars is treated as
    /// having the worst possible focus by the FWHM penalty).
    pub fwhm: f64,
    /// Median star eccentricity (0 = round, →1 = trailed). `None` when too few
    /// reliable stars were available to measure it honestly — the roundness
    /// penalty then defaults to neutral (1.0) rather than fabricating a value.
    pub eccentricity: Option<f64>,
    /// Number of stars detected (transparency / depth proxy).
    pub star_count: u32,
}

impl FrameQuality {
    /// A neutral, finite descriptor used as a fallback reference when no real
    /// reference frame is available. All multiplicative ratios against it
    /// reduce to the frame's own absolute terms.
    pub fn neutral() -> Self {
        Self {
            noise: 1.0,
            background: 0.0,
            snr: 1.0,
            fwhm: 1.0,
            eccentricity: Some(0.0),
            star_count: 0,
        }
    }
}

/// Selects how a [`FrameQuality`] is collapsed into a scalar integration
/// weight (relative to a reference frame).
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum WeightFormula {
    /// Weight ∝ SNR. Conservative; appropriate when star-shape metrics are
    /// unreliable (very sparse fields).
    Snr,
    /// Weight ∝ SNR². The variance-optimal weighting for combining independent
    /// Gaussian estimates is inverse-variance, i.e. ∝ SNR² for fixed signal —
    /// the sensible default for most stacks.
    SnrSquared,
    /// Weight ∝ (fwhm_ref / fwhm)². Pure sharpness weighting, ignoring SNR;
    /// useful when all subs share the same exposure/sky and you only want to
    /// favour the best-seeing frames.
    FwhmInverse,
    /// Fully configurable PSF-signal-weight-style product:
    /// `w ∝ (snr/snr_ref)^snr_pow · (fwhm_ref/fwhm)^fwhm_pow · (1−ecc)^ecc_pow`.
    Custom {
        /// Exponent on the SNR ratio.
        snr_pow: f64,
        /// Exponent on the inverse-FWHM (sharpness) ratio.
        fwhm_pow: f64,
        /// Exponent on the roundness factor `(1 − eccentricity)`.
        ecc_pow: f64,
    },
}

impl Default for WeightFormula {
    fn default() -> Self {
        // Mirrors PixInsight's PSF Signal Weight spirit: SNR² dominated, with a
        // sharpness and a mild roundness penalty. These exponents are
        // defensible defaults, not corpus-tuned (see module docs).
        WeightFormula::Custom {
            snr_pow: 2.0,
            fwhm_pow: 1.0,
            ecc_pow: 1.0,
        }
    }
}

/// Configuration for [`analyze_frame_quality`].
#[derive(Debug, Clone)]
pub struct FrameQualityConfig {
    /// Star-detection configuration used to derive FWHM / eccentricity / star
    /// count. Defaults to [`StarDetectionConfig::default`].
    pub detection: StarDetectionConfig,
    /// Upper percentile (0..1) used as the bright-tail "signal" level for the
    /// SNR proxy. The median is the background; a high percentile captures the
    /// nebulosity/star signal the integration cares about. Default 0.95.
    pub signal_percentile: f64,
}

impl Default for FrameQualityConfig {
    fn default() -> Self {
        Self {
            detection: StarDetectionConfig::default(),
            signal_percentile: 0.95,
        }
    }
}

/// Compute a [`FrameQuality`] for a single (mono, 16-bit) frame.
///
/// `image` must be a `U16` frame. For multi-channel/RGB frames the caller
/// should pass a luminance plane (the integration pipeline derives one for
/// detection already); this keeps the weighting metric channel-agnostic.
///
/// Returns `None` for an empty/zero-sized image (no honest metric exists).
pub fn analyze_frame_quality(image: &ImageData, cfg: &FrameQualityConfig) -> Option<FrameQuality> {
    if image.is_empty() {
        return None;
    }
    let pixels = image.as_u16()?;
    if pixels.is_empty() {
        return None;
    }

    let noise = robust_noise_u16(&pixels, image.width as usize, image.height as usize);

    // Background = robust frame median; signal = a high percentile of the
    // pixel distribution. Both come from one sort.
    let stats = calculate_stats_u16(image);
    let background = stats.median;
    let signal = percentile_u16(&pixels, cfg.signal_percentile);
    let snr = ((signal - background) / noise.max(f64::MIN_POSITIVE)).max(0.0);

    // Star-shape metrics. detect_stars_with_stats already computes the robust
    // medians and the honest `None` eccentricity for sparse fields.
    let det = detect_stars_with_stats(image, &cfg.detection);

    Some(FrameQuality {
        noise: noise.max(0.0),
        background,
        snr,
        fwhm: det.median_fwhm.max(0.0),
        eccentricity: det.median_eccentricity,
        star_count: det.star_count,
    })
}

/// Robust per-pixel noise σ (ADU) via MAD of the 3×3-median residual.
///
/// The 3×3 median is computed in parallel over rows; edge pixels reuse the
/// nearest in-bounds neighbourhood (clamped window) so every pixel yields a
/// residual. The MAD of the residual is then scaled by [`MAD_TO_SIGMA`].
///
/// Exposed (crate-public) so the integration pipeline can reuse the exact same
/// estimator when it needs a noise figure outside of [`analyze_frame_quality`].
pub fn robust_noise_u16(pixels: &[u16], width: usize, height: usize) -> f64 {
    if width == 0 || height == 0 || pixels.len() < width * height {
        return 0.0;
    }

    // Per-row parallel 3×3 median residual: |pixel − median(3×3 window)|.
    let residuals: Vec<f64> = (0..height)
        .into_par_iter()
        .flat_map_iter(|y| {
            let mut row_res = Vec::with_capacity(width);
            for x in 0..width {
                let center = pixels[y * width + x] as f64;
                let med = median_3x3(pixels, width, height, x, y);
                row_res.push((center - med).abs());
            }
            row_res
        })
        .collect();

    if residuals.is_empty() {
        return 0.0;
    }

    let mad = median_f64(residuals);
    mad * MAD_TO_SIGMA
}

/// Median of the (clamped) 3×3 neighbourhood centred on `(x, y)`.
#[inline]
fn median_3x3(pixels: &[u16], width: usize, height: usize, x: usize, y: usize) -> f64 {
    let mut win = [0u16; 9];
    let mut n = 0usize;
    let x0 = x.saturating_sub(1);
    let x1 = (x + 1).min(width - 1);
    let y0 = y.saturating_sub(1);
    let y1 = (y + 1).min(height - 1);
    for yy in y0..=y1 {
        let row = yy * width;
        for win_pixel in pixels[row + x0..=row + x1].iter() {
            win[n] = *win_pixel;
            n += 1;
        }
    }
    // n is between 4 (corner) and 9 (interior); small insertion sort.
    let w = &mut win[..n];
    w.sort_unstable();
    if n.is_multiple_of(2) {
        (w[n / 2 - 1] as f64 + w[n / 2] as f64) / 2.0
    } else {
        w[n / 2] as f64
    }
}

/// Median of an owned `f64` vector (consumes it; parallel sort — these are
/// megapixel-scale residual buffers).
fn median_f64(mut v: Vec<f64>) -> f64 {
    median_in_place_par(&mut v)
}

/// Nearest-rank percentile (0..1) of the `u16` pixel distribution. Shares its
/// rank convention with [`crate::robust_stats::percentile_nearest_rank`]; the
/// samples stay `u16` so a megapixel frame is not widened to `f64` first.
fn percentile_u16(pixels: &[u16], p: f64) -> f64 {
    if pixels.is_empty() {
        return 0.0;
    }
    let mut v: Vec<u16> = pixels.to_vec();
    v.par_sort_unstable();
    v[nearest_rank_index(v.len(), p)] as f64
}

/// Compute the *unnormalized* integration weight of `q` relative to `ref_q`.
///
/// The weight is always finite and non-negative. A frame strictly better than
/// the reference on every axis gets a weight > 1; strictly worse gets < 1.
/// Degenerate inputs (zero/NaN noise, FWHM, etc.) are handled so the result is
/// never NaN/∞ — a degenerate frame collapses toward weight 0, never poisons
/// the population.
pub fn frame_weight(q: &FrameQuality, ref_q: &FrameQuality, formula: &WeightFormula) -> f64 {
    let w = match formula {
        WeightFormula::Snr => snr_ratio(q, ref_q),
        WeightFormula::SnrSquared => snr_ratio(q, ref_q).powi(2),
        WeightFormula::FwhmInverse => fwhm_ratio(q, ref_q).powi(2),
        WeightFormula::Custom {
            snr_pow,
            fwhm_pow,
            ecc_pow,
        } => {
            let s = safe_pow(snr_ratio(q, ref_q), *snr_pow);
            let f = safe_pow(fwhm_ratio(q, ref_q), *fwhm_pow);
            let e = safe_pow(roundness(q), *ecc_pow);
            s * f * e
        }
    };
    if w.is_finite() && w > 0.0 {
        w
    } else {
        0.0
    }
}

/// SNR of `q` relative to the reference (≥ 0).
#[inline]
fn snr_ratio(q: &FrameQuality, ref_q: &FrameQuality) -> f64 {
    let denom = ref_q.snr.max(f64::MIN_POSITIVE);
    (q.snr.max(0.0) / denom).max(0.0)
}

/// Sharpness ratio `fwhm_ref / fwhm` (≥ 0). A frame with no measurable stars
/// (`fwhm == 0`) is treated as the worst possible focus (ratio 0), so it cannot
/// win on sharpness.
#[inline]
fn fwhm_ratio(q: &FrameQuality, ref_q: &FrameQuality) -> f64 {
    if q.fwhm <= 0.0 {
        return 0.0;
    }
    let ref_fwhm = if ref_q.fwhm > 0.0 { ref_q.fwhm } else { q.fwhm };
    (ref_fwhm / q.fwhm).max(0.0)
}

/// Roundness factor `(1 − eccentricity)` clamped to (0, 1]. Neutral (1.0) when
/// eccentricity is unknown so a sparse field is neither rewarded nor punished
/// on shape.
#[inline]
fn roundness(q: &FrameQuality) -> f64 {
    match q.eccentricity {
        Some(e) => (1.0 - e.clamp(0.0, 1.0)).max(f64::MIN_POSITIVE),
        None => 1.0,
    }
}

/// `base^exp` with degenerate bases mapped to 0 (never NaN/∞).
#[inline]
fn safe_pow(base: f64, exp: f64) -> f64 {
    if !base.is_finite() || base < 0.0 {
        return 0.0;
    }
    if base == 0.0 {
        // 0^0 is mathematically contentious; for weighting, exp==0 means the
        // factor is disabled and must contribute neutrally (1.0).
        return if exp == 0.0 { 1.0 } else { 0.0 };
    }
    let r = base.powf(exp);
    if r.is_finite() {
        r
    } else {
        0.0
    }
}

/// Per-frame result of [`weight_frames`].
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct WeightedFrame {
    /// Index of the frame in the input slice.
    pub index: usize,
    /// The frame's quality descriptor.
    pub quality: FrameQuality,
    /// Weight normalized so the best frame in the population = 1.0.
    pub weight: f64,
    /// Whether this frame is *recommended* for culling (below the cull
    /// threshold). The caller decides whether to honour it.
    pub recommend_cull: bool,
}

/// Auto-cull policy for [`weight_frames`].
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CullPolicy {
    /// Cull frames whose normalized weight is below this fraction of the median
    /// weight. `0.5` ⇒ recommend dropping anything weaker than half the median.
    pub min_weight_fraction_of_median: f64,
    /// Always keep at least this many frames regardless of the threshold (a
    /// thin night should not be culled to nothing).
    pub min_keep: usize,
}

impl Default for CullPolicy {
    fn default() -> Self {
        Self {
            min_weight_fraction_of_median: 0.5,
            min_keep: 3,
        }
    }
}

/// Result of [`weight_frames`]: normalized per-frame weights + a cull
/// recommendation summary.
#[derive(Debug, Clone)]
pub struct WeightingReport {
    /// Per-frame weights, in input order.
    pub frames: Vec<WeightedFrame>,
    /// Index of the reference frame chosen as the normalization anchor.
    pub reference_index: usize,
    /// Number of frames the policy recommends culling.
    pub recommended_cull_count: usize,
}

/// Weight a population of pre-computed [`FrameQuality`] descriptors.
///
/// The reference frame is chosen automatically as the best frame under the
/// formula (the one all others are normalized against), so the output weights
/// are in (0, 1] with the best frame = 1.0. The cull recommendation flags
/// frames below `policy`'s threshold without ever dropping them — culling is
/// always the caller's explicit choice.
///
/// Returns `None` for an empty population.
pub fn weight_frames(
    qualities: &[FrameQuality],
    formula: &WeightFormula,
    policy: &CullPolicy,
) -> Option<WeightingReport> {
    if qualities.is_empty() {
        return None;
    }

    // Pick the reference as the frame with the highest SNR·roundness·sharpness
    // composite — a stable, formula-independent anchor (we want the *physically*
    // best frame to anchor at 1.0, not whichever the formula happens to favour
    // at extreme exponents). Ties resolve to the lowest index.
    let neutral = FrameQuality::neutral();
    let reference_index = qualities
        .iter()
        .enumerate()
        .max_by(|(_, a), (_, b)| {
            let ka = a.snr.max(0.0) * fwhm_ratio(a, &neutral) * roundness(a);
            let kb = b.snr.max(0.0) * fwhm_ratio(b, &neutral) * roundness(b);
            ka.total_cmp(&kb)
        })
        .map(|(i, _)| i)?;
    let ref_q = qualities[reference_index];

    // Raw weights relative to the reference.
    let raw: Vec<f64> = qualities
        .iter()
        .map(|q| frame_weight(q, &ref_q, formula))
        .collect();

    // Normalize so the maximum weight = 1.0. If every frame is degenerate
    // (all-zero), fall back to a uniform weight so integration still runs.
    let max_w = raw.iter().copied().fold(0.0_f64, f64::max);
    let normalized: Vec<f64> = if max_w > 0.0 {
        raw.iter().map(|&w| w / max_w).collect()
    } else {
        vec![1.0; raw.len()]
    };

    // Cull recommendation: relative to the median of the *positive* weights.
    let median_w = {
        let mut pos: Vec<f64> = normalized.iter().copied().filter(|&w| w > 0.0).collect();
        if pos.is_empty() {
            0.0
        } else {
            pos.sort_by(f64::total_cmp);
            pos[pos.len() / 2]
        }
    };
    let cull_threshold = median_w * policy.min_weight_fraction_of_median;

    // Determine which frames *would* be culled, honouring min_keep: keep the
    // strongest `min_keep` frames no matter what.
    let mut order: Vec<usize> = (0..normalized.len()).collect();
    order.sort_by(|&a, &b| normalized[b].total_cmp(&normalized[a]));
    let protected: std::collections::HashSet<usize> =
        order.iter().copied().take(policy.min_keep).collect();

    let mut recommended_cull_count = 0;
    let frames: Vec<WeightedFrame> = qualities
        .iter()
        .enumerate()
        .map(|(i, q)| {
            let weight = normalized[i];
            let recommend_cull =
                !protected.contains(&i) && weight < cull_threshold && cull_threshold > 0.0;
            if recommend_cull {
                recommended_cull_count += 1;
            }
            WeightedFrame {
                index: i,
                quality: *q,
                weight,
                recommend_cull,
            }
        })
        .collect();

    Some(WeightingReport {
        frames,
        reference_index,
        recommended_cull_count,
    })
}

/// Weight a population on an **absolute, population-independent** scale for the
/// multi-night accumulating master.
///
/// Unlike [`weight_frames`], which renormalizes each population so its *own*
/// best frame is `1.0`, this weights every frame against the fixed
/// [`FrameQuality::neutral`] anchor. Because the anchor never changes from one
/// fold (night) to the next, the resulting weights are directly comparable
/// **across folds**: a uniformly lower-SNR night yields strictly smaller
/// weights and therefore contributes proportionally less to the running
/// weighted mean — the bias the per-fold max-normalization would otherwise
/// erase (see `master_accumulation` module docs).
///
/// Within a single fold the weights are exactly proportional to those of
/// [`weight_frames`] (both derive from [`frame_weight`], which factors as
/// `weight(q, ref) = C(ref) · g(q)` for any reference with positive FWHM/SNR),
/// so anchoring on `neutral` instead of the fold's best frame does not change a
/// single-night master: a weighted mean is invariant to a global weight scale.
///
/// If every frame is degenerate (all weights `0`), falls back to a uniform
/// weight so the fold still integrates, matching [`weight_frames`].
///
/// Returns an empty vector for an empty population.
pub fn accumulation_weights(qualities: &[FrameQuality], formula: &WeightFormula) -> Vec<f64> {
    let anchor = FrameQuality::neutral();
    let raw: Vec<f64> = qualities
        .iter()
        .map(|q| frame_weight(q, &anchor, formula))
        .collect();
    if !raw.is_empty() && raw.iter().all(|&w| w <= 0.0) {
        vec![1.0; raw.len()]
    } else {
        raw
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ImageData;

    /// Render a synthetic mono u16 frame: flat background + Gaussian-noise +
    /// a grid of round Gaussian stars. Noise is deterministic (seeded LCG) so
    /// the tests are reproducible.
    fn synth_frame(
        width: u32,
        height: u32,
        background: f64,
        noise_sigma: f64,
        star_peak: f64,
        star_sigma: f64,
        seed: u64,
    ) -> ImageData {
        let w = width as usize;
        let h = height as usize;
        let mut data = vec![0u16; w * h];
        let mut state = seed | 1;
        let mut next = || {
            // xorshift64* → uniform in [0,1)
            state ^= state >> 12;
            state ^= state << 25;
            state ^= state >> 27;
            let r = state.wrapping_mul(0x2545F4914F6CDD1D);
            (r >> 11) as f64 / (1u64 << 53) as f64
        };
        // Box-Muller for Gaussian noise.
        for px in data.iter_mut() {
            let u1 = next().max(1e-12);
            let u2 = next();
            let g = (-2.0 * u1.ln()).sqrt() * (std::f64::consts::TAU * u2).cos();
            let v = background + g * noise_sigma;
            *px = v.clamp(0.0, 65535.0) as u16;
        }
        // Stars on a coarse grid, away from edges.
        let step = 24usize;
        let two_sig_sq = 2.0 * star_sigma * star_sigma;
        let r = (3.0 * star_sigma).ceil() as i32;
        let mut sy = step;
        while sy + step < h {
            let mut sx = step;
            while sx + step < w {
                for dy in -r..=r {
                    for dx in -r..=r {
                        let x = sx as i32 + dx;
                        let y = sy as i32 + dy;
                        if x < 0 || y < 0 || x >= w as i32 || y >= h as i32 {
                            continue;
                        }
                        let rr = (dx * dx + dy * dy) as f64;
                        let add = star_peak * (-rr / two_sig_sq).exp();
                        let idx = y as usize * w + x as usize;
                        data[idx] = (data[idx] as f64 + add).clamp(0.0, 65535.0) as u16;
                    }
                }
                sx += step;
            }
            sy += step;
        }
        ImageData::from_u16(width, height, 1, &data)
    }

    #[test]
    fn robust_noise_tracks_injected_sigma() {
        // A pure-noise frame's robust noise estimate should land near the
        // injected sigma. The 3×3-median residual of i.i.d. Gaussian noise has
        // a smaller spread than the raw noise (the median subtracts a local
        // estimate), so we assert order-of-magnitude tracking, not equality:
        // doubling the injected sigma must roughly double the estimate.
        let low = synth_frame(128, 128, 2000.0, 10.0, 0.0, 2.0, 0xABCDEF);
        let high = synth_frame(128, 128, 2000.0, 20.0, 0.0, 2.0, 0xABCDEF);
        let n_low = robust_noise_u16(&low.as_u16().unwrap(), 128, 128);
        let n_high = robust_noise_u16(&high.as_u16().unwrap(), 128, 128);
        assert!(n_low > 0.0, "noise estimate must be positive, got {n_low}");
        assert!(
            n_high > n_low,
            "higher injected noise must yield higher estimate: low={n_low} high={n_high}"
        );
        let ratio = n_high / n_low;
        assert!(
            (1.5..=2.5).contains(&ratio),
            "doubling sigma should ~double the estimate, ratio={ratio}"
        );
    }

    /// A [`FrameQualityConfig`] tuned for the synthetic Gaussian PSFs the tests
    /// render. The default `StarDetectionConfig` rejects any compact Gaussian on
    /// the `sharpness` gate (a noise-free synthetic peak concentrates flux so
    /// `peak/avg_flux_per_pixel` saturates to 1.0 > 0.95) — the same reason the
    /// crate's existing PSF tests in `stats.rs` relax `max_sharpness`. Detection
    /// tuning is the caller's domain; the weighting algorithm under test is
    /// independent of it.
    fn synth_quality_cfg() -> FrameQualityConfig {
        FrameQualityConfig {
            detection: StarDetectionConfig {
                max_sharpness: 1.0,
                min_area: 5,
                ..StarDetectionConfig::default()
            },
            ..FrameQualityConfig::default()
        }
    }

    #[test]
    fn lower_noise_frame_gets_higher_weight() {
        let cfg = synth_quality_cfg();
        // Same signal, same stars; only the background noise differs.
        let clean = synth_frame(192, 192, 2000.0, 8.0, 20000.0, 3.0, 1);
        let noisy = synth_frame(192, 192, 2000.0, 40.0, 20000.0, 3.0, 1);

        let q_clean = analyze_frame_quality(&clean, &cfg).expect("quality for clean frame");
        let q_noisy = analyze_frame_quality(&noisy, &cfg).expect("quality for noisy frame");

        assert!(
            q_clean.noise < q_noisy.noise,
            "clean frame must measure lower noise: {} vs {}",
            q_clean.noise,
            q_noisy.noise
        );
        assert!(
            q_clean.snr > q_noisy.snr,
            "clean frame must measure higher SNR: {} vs {}",
            q_clean.snr,
            q_noisy.snr
        );

        let report = weight_frames(
            &[q_clean, q_noisy],
            &WeightFormula::default(),
            &CullPolicy::default(),
        )
        .expect("report");
        assert!(
            report.frames[0].weight > report.frames[1].weight,
            "lower-noise frame must get the higher weight: {} vs {}",
            report.frames[0].weight,
            report.frames[1].weight
        );
        // The best (clean) frame anchors the normalization at 1.0.
        assert_eq!(report.reference_index, 0);
        assert!((report.frames[0].weight - 1.0).abs() < 1e-9);
    }

    #[test]
    fn weight_is_monotonic_in_snr() {
        // Synthetic FrameQuality descriptors (no image needed): hold FWHM and
        // eccentricity fixed, vary SNR; weight must increase strictly.
        let mk = |snr: f64| FrameQuality {
            noise: 10.0,
            background: 1000.0,
            snr,
            fwhm: 3.0,
            eccentricity: Some(0.1),
            star_count: 50,
        };
        let qs: Vec<FrameQuality> = [5.0, 10.0, 20.0, 40.0].iter().map(|&s| mk(s)).collect();
        let report =
            weight_frames(&qs, &WeightFormula::SnrSquared, &CullPolicy::default()).expect("report");
        let w: Vec<f64> = report.frames.iter().map(|f| f.weight).collect();
        for pair in w.windows(2) {
            assert!(pair[1] > pair[0], "weight must increase with SNR: {:?}", w);
        }
        // SNR² ⇒ weight ratio = (snr ratio)². Doubling SNR (20→40 i.e. 0.25→1.0
        // of the max-SNR frame) quadruples the weight contribution.
        let ref_q = qs[report.reference_index];
        let direct = frame_weight(&mk(40.0), &ref_q, &WeightFormula::SnrSquared)
            / frame_weight(&mk(20.0), &ref_q, &WeightFormula::SnrSquared);
        assert!(
            (direct - 4.0).abs() < 1e-6,
            "SnrSquared should give 4× for 2× SNR, got {direct}"
        );
    }

    #[test]
    fn tighter_stars_and_roundness_increase_weight() {
        let ref_q = FrameQuality {
            noise: 10.0,
            background: 1000.0,
            snr: 30.0,
            fwhm: 3.0,
            eccentricity: Some(0.1),
            star_count: 60,
        };
        // Same SNR; sharper FWHM and rounder stars.
        let sharp_round = FrameQuality {
            fwhm: 2.0,
            eccentricity: Some(0.05),
            ..ref_q
        };
        let bloated_trailed = FrameQuality {
            fwhm: 5.0,
            eccentricity: Some(0.6),
            ..ref_q
        };
        let f = WeightFormula::default();
        let w_good = frame_weight(&sharp_round, &ref_q, &f);
        let w_bad = frame_weight(&bloated_trailed, &ref_q, &f);
        assert!(
            w_good > w_bad,
            "sharper+rounder frame must outweigh bloated+trailed: {w_good} vs {w_bad}"
        );
    }

    #[test]
    fn degenerate_frame_collapses_to_zero_weight_without_poisoning_population() {
        let good = FrameQuality {
            noise: 10.0,
            background: 1000.0,
            snr: 30.0,
            fwhm: 3.0,
            eccentricity: Some(0.1),
            star_count: 60,
        };
        // No signal, no stars: SNR 0, FWHM 0 → must yield a finite zero weight.
        let dead = FrameQuality {
            noise: 0.0,
            background: 0.0,
            snr: 0.0,
            fwhm: 0.0,
            eccentricity: None,
            star_count: 0,
        };
        let w = frame_weight(&dead, &good, &WeightFormula::default());
        assert_eq!(w, 0.0, "dead frame must get exactly zero weight, got {w}");
        assert!(w.is_finite());

        let report = weight_frames(
            &[good, dead, good],
            &WeightFormula::default(),
            &CullPolicy::default(),
        )
        .expect("report");
        // The reference must be a good frame, weights finite, dead frame = 0.
        assert!(report.frames.iter().all(|f| f.weight.is_finite()));
        assert_eq!(report.frames[1].weight, 0.0);
        assert!(report.frames[0].weight > 0.0);
    }

    #[test]
    fn unknown_eccentricity_is_neutral_not_punitive() {
        let ref_q = FrameQuality {
            noise: 10.0,
            background: 1000.0,
            snr: 30.0,
            fwhm: 3.0,
            eccentricity: Some(0.0),
            star_count: 60,
        };
        let with_ecc = FrameQuality {
            eccentricity: Some(0.0),
            ..ref_q
        };
        let no_ecc = FrameQuality {
            eccentricity: None,
            ..ref_q
        };
        let f = WeightFormula::default();
        // A round (ecc=0) frame and an unknown-ecc frame both get the roundness
        // factor 1.0, so identical everything-else ⇒ identical weight.
        let w1 = frame_weight(&with_ecc, &ref_q, &f);
        let w2 = frame_weight(&no_ecc, &ref_q, &f);
        assert!(
            (w1 - w2).abs() < 1e-12,
            "unknown eccentricity must be neutral: {w1} vs {w2}"
        );
    }

    #[test]
    fn auto_cull_flags_weak_frames_but_respects_min_keep() {
        let mk = |snr: f64| FrameQuality {
            noise: 10.0,
            background: 1000.0,
            snr,
            fwhm: 3.0,
            eccentricity: Some(0.1),
            star_count: 50,
        };
        // Three strong frames + one very weak one.
        let qs = vec![mk(40.0), mk(38.0), mk(36.0), mk(2.0)];
        let policy = CullPolicy {
            min_weight_fraction_of_median: 0.5,
            min_keep: 3,
        };
        let report = weight_frames(&qs, &WeightFormula::SnrSquared, &policy).expect("report");
        // The weak frame is far below half the median weight → recommended.
        assert!(
            report.frames[3].recommend_cull,
            "weak frame should be culled"
        );
        assert_eq!(report.recommended_cull_count, 1);

        // With min_keep == 4 (== population size) nothing may be culled.
        let policy_keep_all = CullPolicy {
            min_weight_fraction_of_median: 0.5,
            min_keep: 4,
        };
        let report2 =
            weight_frames(&qs, &WeightFormula::SnrSquared, &policy_keep_all).expect("report");
        assert_eq!(report2.recommended_cull_count, 0);
    }

    #[test]
    fn empty_population_and_empty_image_are_handled() {
        assert!(weight_frames(&[], &WeightFormula::default(), &CullPolicy::default()).is_none());
        let empty = ImageData::new(0, 0, 1, crate::PixelType::U16);
        assert!(analyze_frame_quality(&empty, &FrameQualityConfig::default()).is_none());
        assert!(accumulation_weights(&[], &WeightFormula::default()).is_empty());
    }

    /// The accumulating master's per-fold weights must sit on a fixed,
    /// population-independent scale so a uniformly worse night contributes
    /// strictly less weight across folds — the property `weight_frames`'
    /// per-fold max-normalization erases.
    #[test]
    fn accumulation_weights_are_population_independent_and_cross_fold_comparable() {
        let mk = |snr: f64| FrameQuality {
            noise: 10.0,
            background: 1000.0,
            snr,
            fwhm: 3.0,
            eccentricity: Some(0.1),
            star_count: 50,
        };
        let f = WeightFormula::SnrSquared;

        // "Night A": two good subs. "Night B": two uniformly lower-SNR subs.
        let night_a = [mk(40.0), mk(38.0)];
        let night_b = [mk(20.0), mk(19.0)];

        let wa = accumulation_weights(&night_a, &f);
        let wb = accumulation_weights(&night_b, &f);

        // Anchor stability: a frame's weight does NOT depend on which other
        // frames share its fold. Re-weighting frame A0 alone, or alongside a
        // different population, yields the identical weight.
        let wa0_alone = accumulation_weights(&[mk(40.0)], &f);
        assert_eq!(
            wa[0], wa0_alone[0],
            "weight must be population-independent (stable anchor)"
        );
        let mixed = accumulation_weights(&[mk(40.0), mk(20.0), mk(19.0)], &f);
        assert_eq!(
            wa[0], mixed[0],
            "frame weight must not change when folded with a worse population"
        );
        assert_eq!(wb[0], mixed[1]);

        // Cross-fold comparability: the better night contributes strictly more
        // total weight. With SnrSquared, ~2× SNR ⇒ ~4× weight per frame.
        let sum_a: f64 = wa.iter().sum();
        let sum_b: f64 = wb.iter().sum();
        assert!(
            sum_a > sum_b * 3.0,
            "the higher-SNR night must carry far more total weight: A={sum_a} B={sum_b}"
        );

        // Contrast with weight_frames, which renormalizes each night to max 1.0
        // and so makes the two nights' total weights near-equal (the bug).
        let nb_norm = weight_frames(&night_b, &f, &CullPolicy::default()).unwrap();
        let sum_b_norm: f64 = nb_norm.frames.iter().map(|x| x.weight).sum();
        let na_norm = weight_frames(&night_a, &f, &CullPolicy::default()).unwrap();
        let sum_a_norm: f64 = na_norm.frames.iter().map(|x| x.weight).sum();
        assert!(
            (sum_a_norm - sum_b_norm).abs() < 0.1,
            "per-fold normalization erases the cross-night difference: A={sum_a_norm} B={sum_b_norm}"
        );
    }

    /// Anchoring on `neutral` instead of the fold's best
    /// frame is a pure global rescale within a single fold, so the implied
    /// weighted mean is unchanged. Pin that the two weightings are proportional.
    #[test]
    fn accumulation_weights_are_proportional_to_weight_frames_within_a_fold() {
        let mk = |snr: f64, fwhm: f64, ecc: f64| FrameQuality {
            noise: 10.0,
            background: 1000.0,
            snr,
            fwhm,
            eccentricity: Some(ecc),
            star_count: 50,
        };
        let f = WeightFormula::default();
        let qs = [
            mk(40.0, 2.0, 0.05),
            mk(30.0, 3.0, 0.10),
            mk(22.0, 4.0, 0.20),
        ];
        let abs = accumulation_weights(&qs, &f);
        let norm: Vec<f64> = weight_frames(&qs, &f, &CullPolicy::default())
            .unwrap()
            .frames
            .iter()
            .map(|x| x.weight)
            .collect();
        // ratio abs/norm must be the same constant for every frame.
        let c0 = abs[0] / norm[0];
        for i in 1..qs.len() {
            let ci = abs[i] / norm[i];
            assert!(
                (ci - c0).abs() < 1e-9 * c0,
                "within a fold the two weightings must be a pure rescale: c0={c0} c{i}={ci}"
            );
        }
    }

    #[test]
    fn percentile_and_median_helpers_are_correct() {
        let v = [1u16, 2, 3, 4, 5, 6, 7, 8, 9, 10];
        assert_eq!(percentile_u16(&v, 0.0), 1.0);
        assert_eq!(percentile_u16(&v, 1.0), 10.0);
        // Nearest-rank p=0.5 over 10 elements → idx round(4.5)=5 → value 6.
        assert_eq!(percentile_u16(&v, 0.5), 6.0);
        assert_eq!(median_f64(vec![3.0, 1.0, 2.0]), 2.0);
        assert_eq!(median_f64(vec![4.0, 1.0, 3.0, 2.0]), 2.5);
        assert_eq!(median_f64(vec![]), 0.0);
    }
}
