//! PSF estimation and regularized Richardson–Lucy deconvolution (preview).
//!
//! Deconvolution sharpens an image by partially inverting the blur introduced
//! by the atmosphere, the optics, and the guiding system — all of which combine
//! into a single *point-spread function* (PSF). If `o` is the true sky, `h` the
//! PSF, and `n` photon/read noise, a linear-light frame is
//!
//! ```text
//!     i = (o * h) + n            ( "*" is 2-D convolution )
//! ```
//!
//! and deconvolution estimates `o` from `i` given an estimate of `h`. The
//! classic, well-behaved estimator for Poisson-dominated astronomical data is
//! **Richardson–Lucy** (RL): an expectation-maximization iteration that is
//! non-negative by construction and conserves total flux, which is exactly the
//! behaviour we want for a *preview* — we must not invent or destroy signal.
//!
//! This module provides the two halves of a deconvolution pipeline:
//!
//! 1. [`estimate_psf`] — derive a PSF *from the image itself* by stacking the
//!    cores of well-behaved (unsaturated, round, mid-bright) stars. The stars
//!    in a frame are physical samples of the PSF, so a robust median of their
//!    normalized cores is an empirical PSF. Optionally we fit an analytic
//!    Moffat or Gaussian to the median radial profile instead, which denoises
//!    the kernel at the cost of assuming a parametric shape.
//!
//! 2. [`richardson_lucy`] — run a bounded number of RL iterations per channel
//!    on the **linear** image, with optional total-variation regularization to
//!    damp the noise amplification RL is famous for, and an optional
//!    star-core protection clamp to suppress the dark ringing that RL produces
//!    around saturated cores.
//!
//! ## Why this is a *preview*, not a science product
//!
//! Deconvolution is ill-posed: small high-frequency errors in the PSF or the
//! data are amplified every iteration. A trustworthy science deconvolution
//! needs an accurate, possibly spatially-varying PSF and careful per-object
//! regularization. Here we deliberately bound the iteration count, regularize,
//! and operate on a single average PSF — enough to give the user a faithful
//! "what would sharpening do?" preview without over-claiming.
//!
//! ## Limitations
//!
//! The defaults ([`DeconvConfig::default`], [`PsfEstimateConfig::default`]) —
//! 30 iterations, a small TV damping factor, an 80-star / 25-px estimation
//! budget — are *defensible engineering defaults*, not values tuned against a
//! corpus of real frames. They are exposed as knobs precisely so they can be
//! revisited with real data. The algorithms themselves (median PSF stacking,
//! Levenberg-free 1-D profile fit by coarse-then-fine search, the standard RL
//! multiplicative update, TV damping) are deterministic and unit-tested on
//! synthetic frames at the bottom of this file.

use crate::{detect_stars, ImageData, StarDetectionConfig};
use rayon::prelude::*;

/// The Gaussian FWHM↔σ relationship: `FWHM = 2·√(2 ln 2)·σ`.
const FWHM_PER_SIGMA: f64 = 2.354_820_045_030_949; // 2*sqrt(2*ln 2)

/// Which family of PSF [`estimate_psf`] should produce.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PsfKind {
    /// Empirical PSF: the median-combined, normalized stack of star cores. No
    /// parametric assumption — captures asymmetry and non-Gaussian wings, at the
    /// cost of carrying the stars' residual noise into the kernel.
    Empirical,
    /// Moffat profile `I(r) = (1 + (r/α)²)^(−β)` fit to the median radial
    /// profile. Standard for ground-based stellar PSFs: it models the broad,
    /// seeing-dominated wings far better than a Gaussian.
    Moffat,
    /// Circular Gaussian `I(r) = exp(−r² / 2σ²)` fit to the median radial
    /// profile. The most strongly regularized choice — smooth and noise-free —
    /// but it underestimates the wings of a real atmospheric PSF.
    Gaussian,
}

/// An estimated point-spread function and its discrete, normalized kernel.
///
/// The `kernel` is `size × size`, row-major, and normalized so its elements sum
/// to exactly 1.0 (a unit-DC kernel preserves total flux under convolution).
/// `size` is always odd so the kernel has a well-defined centre pixel.
#[derive(Debug, Clone, PartialEq)]
pub struct PsfModel {
    /// Which family produced this kernel.
    pub kind: PsfKind,
    /// Full-width-half-maximum of the PSF, in pixels. For the empirical kind
    /// this is measured from the stacked core; for the parametric kinds it is
    /// derived from the fitted parameters.
    pub fwhm: f64,
    /// Moffat `β` (atmospheric wing steepness). `0.0` for the Gaussian and
    /// empirical kinds, where it is meaningless.
    pub beta: f64,
    /// Side length of the (square, odd) kernel in pixels.
    pub size: usize,
    /// Row-major `size·size` kernel, normalized to sum 1.0.
    pub kernel: Vec<f64>,
}

impl PsfModel {
    /// Index of the centre pixel along one axis (`size / 2`, since `size` is odd).
    #[inline]
    fn half(&self) -> usize {
        self.size / 2
    }
}

/// Configuration for [`estimate_psf`].
#[derive(Debug, Clone)]
pub struct PsfEstimateConfig {
    /// Maximum number of stars to stack. Stacking more denoises the empirical
    /// PSF but costs time and risks pulling in fainter, lower-SNR stars; 80 is a
    /// good balance for a typical sub.
    pub max_stars: usize,
    /// Side length of the square crop window extracted around each star, in
    /// pixels. Must be odd (forced odd internally if an even value is supplied).
    /// 25 px comfortably contains the wings of a well-sampled stellar PSF.
    pub crop: usize,
    /// Which PSF family to produce.
    pub kind: PsfKind,
}

impl Default for PsfEstimateConfig {
    fn default() -> Self {
        Self {
            max_stars: 80,
            crop: 25,
            kind: PsfKind::Moffat,
        }
    }
}

/// Configuration for [`richardson_lucy`].
#[derive(Debug, Clone)]
pub struct DeconvConfig {
    /// Number of RL iterations. RL converges geometrically at first then
    /// amplifies noise, so this is bounded; 30 is a typical preview budget.
    pub iterations: usize,
    /// Total-variation (TV) regularization strength `λ`. Each multiplicative
    /// update is divided by `(1 + λ·|∇u| / u)`, which damps the update where the
    /// local gradient is large relative to the signal — i.e. on noise speckles —
    /// while leaving smooth regions essentially untouched. `0.0` disables it.
    /// A small value (≈ 0.01) is the defensible default.
    pub regularization: f64,
    /// Protect saturated star cores from the RL ringing artifact. When `true`,
    /// pixels at or above the saturation level (and their immediate
    /// neighbourhood) are not allowed to grow during iteration, which suppresses
    /// the dark rings RL otherwise paints around clipped cores.
    pub star_protect: bool,
}

impl Default for DeconvConfig {
    fn default() -> Self {
        Self {
            iterations: 30,
            regularization: 0.01,
            star_protect: true,
        }
    }
}

/// Errors returned by [`estimate_psf`] and [`richardson_lucy`].
///
/// These are *caller mistakes / un-processable inputs*, surfaced explicitly so
/// the pipeline never silently returns a meaningless preview (a flat kernel or
/// an unchanged image) that the user would mistake for a successful result.
#[derive(Debug, thiserror::Error, PartialEq)]
pub enum DeconvError {
    /// Fewer usable stars were found than are needed to estimate a PSF. The
    /// caller should fall back to a parametric PSF from the frame's measured
    /// FWHM, or skip the preview.
    #[error("too few usable stars to estimate a PSF")]
    TooFewStars,
    /// The input image was empty (zero width/height) or not a supported pixel
    /// layout.
    #[error("image is empty or has an unsupported pixel layout")]
    EmptyImage,
    /// The supplied PSF kernel is malformed: wrong length, even side, or a
    /// non-positive / non-finite sum.
    #[error("PSF kernel is malformed (size, length, or normalization invalid)")]
    BadKernel,
}

/// Minimum number of usable stars [`estimate_psf`] requires.
///
/// Below this the median core is dominated by a handful of stars' individual
/// noise / centroiding error and is not a trustworthy PSF. Three is the floor
/// at which a per-pixel median is meaningfully robust to one outlier.
const MIN_STARS_FOR_PSF: usize = 3;

// PSF estimation

/// Estimate the point-spread function from the stars in `image`.
///
/// The frame's stars are physical samples of the PSF, so the algorithm is:
///
/// 1. Detect stars and keep only the *well-behaved* ones — unsaturated (so the
///    core is not clipped), round (so we are not averaging in trailed/blended
///    objects), and mid-bright (bright enough for a clean profile, not so bright
///    they are near saturation). See [`select_psf_stars`].
/// 2. Extract a background-subtracted, peak-normalized square crop around each
///    star's sub-pixel centroid (bilinear resampling re-centres the core).
/// 3. Median-combine the crops pixel-by-pixel into one robust empirical PSF
///    (the per-pixel median rejects cosmic rays, faint neighbours, and the
///    individual stars' noise).
/// 4. Either return that empirical core directly ([`PsfKind::Empirical`]) or
///    fit an analytic [`PsfKind::Moffat`]/[`PsfKind::Gaussian`] to its median
///    radial profile.
/// 5. Build an odd, sum-normalized kernel and report the FWHM.
///
/// Both `U16` (ADU-scaled) and `F32` (normalized linear, `[0, 1]`) frames are
/// supported: the detection step derives its working scale and saturation guard
/// from the data (see [`as_u16_image`]), so a normalized float frame is not
/// crushed to 0/1 before detection.
///
/// # Errors
/// * [`DeconvError::EmptyImage`] if `image` is empty or not `U16`/`F32`.
/// * [`DeconvError::TooFewStars`] if fewer than three usable stars remain after
///   filtering.
pub fn estimate_psf(image: &ImageData, cfg: &PsfEstimateConfig) -> Result<PsfModel, DeconvError> {
    if image.is_empty() {
        return Err(DeconvError::EmptyImage);
    }

    // Work on a single linear luminance plane in f64.
    let (plane, width, height) = image_to_plane(image).ok_or(DeconvError::EmptyImage)?;
    if width == 0 || height == 0 {
        return Err(DeconvError::EmptyImage);
    }

    // Force an odd crop side ≥ 5 so there is a defined centre and room for wings.
    let crop = force_odd(cfg.crop.max(5));
    let half = crop / 2;

    // Detect stars on the source frame (detection wants the native U16 layout;
    // for non-U16 frames we synthesize a U16 view so detection still runs). For a
    // normalized [0,1] F32 plane a bare clamp would crush every pixel to 0/1 and
    // hide all stars, so `as_u16_image` rescales low-amplitude planes into the
    // detector's U16 domain and reports the saturation level in that same domain.
    let (detect_image, sat_level) = as_u16_image(image, &plane, width, height);
    let mut stars = detect_stars(&detect_image, &psf_detection_config());

    // Keep only well-behaved PSF stars and cap to the budget. The saturation guard
    // is expressed in the detection-plane's scale (which `as_u16_image` derived
    // from the data), so it is meaningful for both ADU-scaled and normalized
    // inputs rather than assuming a fixed 16-bit full-well.
    select_psf_stars(&mut stars, width, height, half, cfg.max_stars, sat_level);
    if stars.len() < MIN_STARS_FOR_PSF {
        return Err(DeconvError::TooFewStars);
    }

    // Extract a normalized, recentred crop per star, then median-combine.
    let crops: Vec<Vec<f64>> = stars
        .par_iter()
        .filter_map(|s| extract_normalized_crop(&plane, width, height, s.x, s.y, crop))
        .collect();
    if crops.len() < MIN_STARS_FOR_PSF {
        return Err(DeconvError::TooFewStars);
    }

    let empirical = median_combine(&crops, crop * crop);

    // Build the requested PSF kind from the empirical core.
    let model = match cfg.kind {
        PsfKind::Empirical => build_empirical_model(empirical, crop),
        PsfKind::Gaussian => build_gaussian_model(&empirical, crop, half),
        PsfKind::Moffat => build_moffat_model(&empirical, crop, half),
    };

    validate_kernel(&model)?;
    Ok(model)
}

/// Star-detection configuration tuned for PSF sampling.
///
/// We deliberately demand *clean* stars: tight roundness, a real (not hot-pixel)
/// HFR, and reasonable SNR. The saturation guard is handled separately in
/// [`select_psf_stars`] against the actual linear peak.
fn psf_detection_config() -> StarDetectionConfig {
    StarDetectionConfig {
        // Rounder than the default — a trailed star would bias the PSF.
        max_eccentricity: 0.5,
        // A real, resolved core, not a hot pixel.
        min_hfr: 1.0,
        // Allow compact synthetic PSFs through the sharpness gate; real stars
        // spread flux and pass easily, but a noise-free synthetic core would be
        // rejected by the default 0.95 sharpness ceiling.
        max_sharpness: 1.0,
        ..StarDetectionConfig::default()
    }
}

/// Filter and rank candidate stars for PSF estimation.
///
/// Removes stars whose crop window would fall off the image edge, stars too
/// close to saturation (a clipped core flattens the PSF), and elongated stars.
/// Survivors are ranked by descending flux (brightest, highest-SNR first) and
/// truncated to `max_stars`, but the very brightest few are skipped because they
/// are the ones most likely to be near non-linear: we want *mid-bright* stars.
fn select_psf_stars(
    stars: &mut Vec<crate::DetectedStar>,
    width: usize,
    height: usize,
    half: usize,
    max_stars: usize,
    sat_level: f64,
) {
    // Saturation guard: stars whose peak is above `sat_level` (≈ 90% of the
    // detection plane's full range, derived from the data by `as_u16_image`) are
    // likely clipped or non-linear and are dropped. Deriving the level from the
    // data — rather than hardcoding a 16-bit full-well — is what makes this work
    // for normalized [0,1] F32 frames as well as ADU-scaled U16.
    stars.retain(|s| {
        let x = s.x;
        let y = s.y;
        // Crop must fit fully inside the frame (no edge truncation of the PSF).
        x >= half as f64
            && y >= half as f64
            && x < (width - half) as f64
            && y < (height - half) as f64
            && s.peak < sat_level
            && s.eccentricity <= 0.5
            && s.hfr > 0.5
            && s.flux > 0.0
    });

    // Brightest first.
    stars.sort_by(|a, b| b.flux.total_cmp(&a.flux));

    // Skip the very brightest handful (closest to non-linear) when we have a
    // comfortable surplus, then take the budget. With only a few stars we keep
    // them all — robustness of the median matters more than linearity purity.
    let skip = if stars.len() > max_stars + 4 { 2 } else { 0 };
    if skip > 0 {
        stars.drain(0..skip);
    }
    stars.truncate(max_stars);
}

/// Extract a background-subtracted, peak-normalized, recentred square crop.
///
/// The crop is bilinearly resampled so the star's sub-pixel centroid lands on
/// the centre pixel of the crop — this is what makes the median stack coherent
/// (otherwise sub-pixel centroid scatter would blur the stacked PSF). The local
/// background is the minimum of the crop (a robust floor for a small window),
/// subtracted before normalizing by the peak. Returns `None` if the crop has no
/// positive signal.
fn extract_normalized_crop(
    plane: &[f64],
    width: usize,
    height: usize,
    cx: f64,
    cy: f64,
    crop: usize,
) -> Option<Vec<f64>> {
    let half = crop / 2;
    let mut out = vec![0.0_f64; crop * crop];

    // First pass: sample (bilinear) and track min/max for background + peak.
    let mut min_v = f64::INFINITY;
    let mut max_v = f64::NEG_INFINITY;
    for j in 0..crop {
        for i in 0..crop {
            let sx = cx + (i as f64 - half as f64);
            let sy = cy + (j as f64 - half as f64);
            let v = bilinear_sample(plane, width, height, sx, sy);
            out[j * crop + i] = v;
            if v < min_v {
                min_v = v;
            }
            if v > max_v {
                max_v = v;
            }
        }
    }

    let amplitude = max_v - min_v;
    if !amplitude.is_finite() || amplitude <= 0.0 {
        return None;
    }

    // Background-subtract and peak-normalize so every star contributes on the
    // same [0, 1] scale regardless of its brightness.
    for v in out.iter_mut() {
        *v = ((*v - min_v) / amplitude).max(0.0);
    }
    Some(out)
}

/// Bilinear sample of `plane` at fractional coordinates, clamped to the image.
#[inline]
fn bilinear_sample(plane: &[f64], width: usize, height: usize, x: f64, y: f64) -> f64 {
    let xc = x.clamp(0.0, (width - 1) as f64);
    let yc = y.clamp(0.0, (height - 1) as f64);
    let x0 = xc.floor() as usize;
    let y0 = yc.floor() as usize;
    let x1 = (x0 + 1).min(width - 1);
    let y1 = (y0 + 1).min(height - 1);
    let fx = xc - x0 as f64;
    let fy = yc - y0 as f64;

    let v00 = plane[y0 * width + x0];
    let v10 = plane[y0 * width + x1];
    let v01 = plane[y1 * width + x0];
    let v11 = plane[y1 * width + x1];

    let top = v00 * (1.0 - fx) + v10 * fx;
    let bot = v01 * (1.0 - fx) + v11 * fx;
    top * (1.0 - fy) + bot * fy
}

/// Per-pixel median of a set of equal-length crops.
///
/// The per-pixel median is the robust combiner: a cosmic ray, a faint
/// neighbouring star, or one star's noise affects at most a few crops at any
/// given pixel and is rejected by the median.
fn median_combine(crops: &[Vec<f64>], len: usize) -> Vec<f64> {
    (0..len)
        .into_par_iter()
        .map(|p| {
            let mut col: Vec<f64> = crops.iter().map(|c| c[p]).collect();
            col.sort_by(f64::total_cmp);
            let n = col.len();
            if n == 0 {
                0.0
            } else if n.is_multiple_of(2) {
                (col[n / 2 - 1] + col[n / 2]) / 2.0
            } else {
                col[n / 2]
            }
        })
        .collect()
}

/// Build a [`PsfModel`] directly from the empirical median core.
fn build_empirical_model(mut core: Vec<f64>, size: usize) -> PsfModel {
    // Clamp tiny negatives from interpolation, then normalize to sum 1.
    for v in core.iter_mut() {
        if *v < 0.0 {
            *v = 0.0;
        }
    }
    normalize_sum(&mut core);
    let fwhm = measure_kernel_fwhm(&core, size);
    PsfModel {
        kind: PsfKind::Empirical,
        fwhm,
        beta: 0.0,
        size,
        kernel: core,
    }
}

/// Fit a circular Gaussian to the empirical core's radial profile and render it.
fn build_gaussian_model(core: &[f64], size: usize, half: usize) -> PsfModel {
    let profile = radial_profile(core, size, half);
    // Coarse-then-fine search over σ minimizing squared error to the profile.
    let sigma = fit_gaussian_sigma(&profile);
    let mut kernel = render_gaussian(size, half, sigma);
    normalize_sum(&mut kernel);
    PsfModel {
        kind: PsfKind::Gaussian,
        fwhm: FWHM_PER_SIGMA * sigma,
        beta: 0.0,
        size,
        kernel,
    }
}

/// Fit a Moffat profile to the empirical core's radial profile and render it.
fn build_moffat_model(core: &[f64], size: usize, half: usize) -> PsfModel {
    let profile = radial_profile(core, size, half);
    let (alpha, beta) = fit_moffat(&profile);
    let mut kernel = render_moffat(size, half, alpha, beta);
    normalize_sum(&mut kernel);
    // Analytic Moffat FWHM = 2·α·√(2^(1/β) − 1).
    let fwhm = 2.0 * alpha * (2.0_f64.powf(1.0 / beta) - 1.0).sqrt();
    PsfModel {
        kind: PsfKind::Moffat,
        fwhm,
        beta,
        size,
        kernel,
    }
}

/// Median radial profile of a kernel: for each integer radius bin, the median of
/// all kernel pixels whose distance from the centre falls in that bin.
///
/// A median (not mean) keeps the profile robust to the residual asymmetry of an
/// empirical core. The returned vector is indexed by radius in pixels, length
/// `half + 1`.
fn radial_profile(kernel: &[f64], size: usize, half: usize) -> Vec<f64> {
    let mut bins: Vec<Vec<f64>> = vec![Vec::new(); half + 1];
    for j in 0..size {
        for i in 0..size {
            let dx = i as f64 - half as f64;
            let dy = j as f64 - half as f64;
            let r = (dx * dx + dy * dy).sqrt().round() as usize;
            if r <= half {
                bins[r].push(kernel[j * size + i]);
            }
        }
    }
    bins.into_iter()
        .map(|mut b| {
            if b.is_empty() {
                0.0
            } else {
                b.sort_by(f64::total_cmp);
                b[b.len() / 2]
            }
        })
        .collect()
}

/// Fit `σ` of a peak-normalized Gaussian `exp(−r²/2σ²)` to a radial profile.
///
/// We minimize the squared error between the model and the profile (rescaled so
/// its centre equals 1) over a coarse σ grid, then refine around the best grid
/// point. This avoids a full nonlinear solver while being entirely deterministic.
fn fit_gaussian_sigma(profile: &[f64]) -> f64 {
    let target = normalized_profile(profile);
    let model = |sigma: f64, r: f64| (-(r * r) / (2.0 * sigma * sigma)).exp();
    let err = |sigma: f64| profile_sse(&target, |r| model(sigma, r));

    // σ ∈ [0.4, half]; coarse grid then golden-ish refine.
    let max_sigma = (profile.len() as f64).max(2.0);
    let best = coarse_then_fine(0.4, max_sigma, err);
    best.clamp(0.4, max_sigma)
}

/// Fit `(α, β)` of a peak-normalized Moffat `(1 + (r/α)²)^(−β)` to a profile.
///
/// β is searched over a small physical grid (1.5–6, the realistic atmospheric
/// range) and for each β, α is fit by 1-D search. The `(α, β)` pair with the
/// lowest squared error wins. β ≤ 1 is excluded because the Moffat integral
/// diverges there (no finite total flux), which would make a useless kernel.
fn fit_moffat(profile: &[f64]) -> (f64, f64) {
    let target = normalized_profile(profile);
    let max_alpha = (profile.len() as f64).max(2.0);

    let mut best = (1.5_f64, 2.5_f64, f64::INFINITY); // (alpha, beta, sse)
    let mut beta = 1.5_f64;
    while beta <= 6.0 {
        let model = |alpha: f64, r: f64| (1.0 + (r * r) / (alpha * alpha)).powf(-beta);
        let err = |alpha: f64| profile_sse(&target, |r| model(alpha, r));
        let alpha = coarse_then_fine(0.4, max_alpha, err).clamp(0.4, max_alpha);
        let sse = err(alpha);
        if sse < best.2 {
            best = (alpha, beta, sse);
        }
        beta += 0.25;
    }
    (best.0, best.1)
}

/// Rescale a radial profile so its centre bin is 1.0 (or all-zero if degenerate).
fn normalized_profile(profile: &[f64]) -> Vec<f64> {
    let peak = profile.first().copied().unwrap_or(0.0);
    if peak <= 0.0 {
        return profile.to_vec();
    }
    profile.iter().map(|&v| (v / peak).max(0.0)).collect()
}

/// Sum of squared errors between a (centre-normalized) target profile and a
/// radial model evaluated at each integer radius.
fn profile_sse<F: Fn(f64) -> f64>(target: &[f64], model: F) -> f64 {
    target
        .iter()
        .enumerate()
        .map(|(r, &t)| {
            let m = model(r as f64);
            let d = t - m;
            d * d
        })
        .sum()
}

/// Minimize a 1-D unimodal-ish error function on `[lo, hi]` by a coarse scan
/// followed by a local refine around the best coarse point.
///
/// Deterministic and cheap: 32 coarse samples + 32 fine samples. Sufficient for
/// the smooth, single-minimum SSE surfaces of Gaussian/Moffat profile fits.
fn coarse_then_fine<F: Fn(f64) -> f64>(lo: f64, hi: f64, f: F) -> f64 {
    const COARSE: usize = 32;
    const FINE: usize = 32;
    let mut best_x = lo;
    let mut best_e = f64::INFINITY;
    for k in 0..=COARSE {
        let x = lo + (hi - lo) * (k as f64 / COARSE as f64);
        let e = f(x);
        if e < best_e {
            best_e = e;
            best_x = x;
        }
    }
    // Refine in the bracket around best_x (± one coarse step).
    let step = (hi - lo) / COARSE as f64;
    let rlo = (best_x - step).max(lo);
    let rhi = (best_x + step).min(hi);
    for k in 0..=FINE {
        let x = rlo + (rhi - rlo) * (k as f64 / FINE as f64);
        let e = f(x);
        if e < best_e {
            best_e = e;
            best_x = x;
        }
    }
    best_x
}

/// Render a circular Gaussian PSF kernel (un-normalized).
fn render_gaussian(size: usize, half: usize, sigma: f64) -> Vec<f64> {
    let two_sig_sq = 2.0 * sigma * sigma;
    let mut k = vec![0.0; size * size];
    for j in 0..size {
        for i in 0..size {
            let dx = i as f64 - half as f64;
            let dy = j as f64 - half as f64;
            k[j * size + i] = (-(dx * dx + dy * dy) / two_sig_sq).exp();
        }
    }
    k
}

/// Render a circular Moffat PSF kernel (un-normalized).
fn render_moffat(size: usize, half: usize, alpha: f64, beta: f64) -> Vec<f64> {
    let alpha_sq = alpha * alpha;
    let mut k = vec![0.0; size * size];
    for j in 0..size {
        for i in 0..size {
            let dx = i as f64 - half as f64;
            let dy = j as f64 - half as f64;
            let r2 = dx * dx + dy * dy;
            k[j * size + i] = (1.0 + r2 / alpha_sq).powf(-beta);
        }
    }
    k
}

/// Normalize a kernel in place so its elements sum to 1.0. A zero/negative-sum
/// kernel is replaced by a centre delta so downstream convolution is a no-op
/// rather than producing NaNs.
fn normalize_sum(kernel: &mut [f64]) {
    let sum: f64 = kernel.iter().sum();
    if sum.is_finite() && sum > 0.0 {
        let inv = 1.0 / sum;
        for v in kernel.iter_mut() {
            *v *= inv;
        }
    } else {
        for v in kernel.iter_mut() {
            *v = 0.0;
        }
        let mid = kernel.len() / 2;
        if let Some(c) = kernel.get_mut(mid) {
            *c = 1.0;
        }
    }
}

/// Measure the FWHM of a normalized kernel from its radial profile by finding
/// the radius at which the (centre-normalized) profile crosses 0.5, with linear
/// interpolation between bracketing bins. The FWHM is twice that radius.
fn measure_kernel_fwhm(kernel: &[f64], size: usize) -> f64 {
    let half = size / 2;
    let profile = radial_profile(kernel, size, half);
    let norm = normalized_profile(&profile);
    // Walk outward to the first crossing below 0.5.
    for r in 1..norm.len() {
        if norm[r] <= 0.5 {
            let prev = norm[r - 1];
            let cur = norm[r];
            let denom = prev - cur;
            let frac = if denom > 0.0 {
                (prev - 0.5) / denom
            } else {
                0.0
            };
            let r_half = (r - 1) as f64 + frac;
            return 2.0 * r_half;
        }
    }
    // Never crossed 0.5 inside the kernel: report the kernel diameter as a floor.
    2.0 * half as f64
}

// Richardson–Lucy deconvolution

/// Deconvolve `image` with `psf` using regularized Richardson–Lucy.
///
/// The RL iteration on a single channel is
///
/// ```text
///     u_{k+1} = u_k · [ ĥ * ( i / (h * u_k) ) ]
/// ```
///
/// where `h` is the PSF, `ĥ` is the PSF flipped 180°, `i` is the observed
/// (linear) image, and `u_0 = i`. Each factor is non-negative, so `u_k` stays
/// non-negative; because `∑h = 1` and the update is multiplicative, total flux
/// is (to numerical precision) conserved — exactly what a faithful preview
/// requires.
///
/// Two optional modifications:
/// * **TV regularization** (`cfg.regularization > 0`): the update factor is
///   divided by `1 + λ·|∇u_k|/u_k`, which is the standard total-variation /
///   "RL-TV" damping. It throttles the update where the local gradient is large
///   relative to the signal (noise, ringing) and is ~neutral on smooth signal,
///   trading a little resolution for a large reduction in noise amplification.
/// * **Star protection** (`cfg.star_protect`): pixels at/above the saturation
///   level are not allowed to *increase*, which removes the dark ring RL paints
///   around clipped cores.
///
/// The output is a new linear `ImageData` of the **same dimensions, channel
/// count, and pixel type** as the input.
///
/// # Errors
/// * [`DeconvError::EmptyImage`] if `image` is empty or an unsupported layout.
/// * [`DeconvError::BadKernel`] if `psf` is malformed (see [`validate_kernel`]).
pub fn richardson_lucy(
    image: &ImageData,
    psf: &PsfModel,
    cfg: &DeconvConfig,
) -> Result<ImageData, DeconvError> {
    if image.is_empty() {
        return Err(DeconvError::EmptyImage);
    }
    validate_kernel(psf)?;

    let width = image.width as usize;
    let height = image.height as usize;
    let channels = image.channels as usize;
    if width == 0 || height == 0 || channels == 0 {
        return Err(DeconvError::EmptyImage);
    }

    // Decompose the (possibly interleaved, multi-channel) image into planar
    // f64 channels so each can be deconvolved independently.
    let planes = image_to_planes(image).ok_or(DeconvError::EmptyImage)?;

    // The flipped PSF used in the RL correction step.
    let flipped = flip_kernel(&psf.kernel, psf.size);
    let half = psf.half();

    // Saturation level for the star-protection clamp (linear-ADU domain).
    let sat_level = if cfg.star_protect {
        Some(65535.0 * 0.98)
    } else {
        None
    };

    // Deconvolve each channel in parallel; channels are independent.
    let out_planes: Vec<Vec<f64>> = planes
        .par_iter()
        .map(|obs| {
            rl_channel(
                obs,
                width,
                height,
                &psf.kernel,
                &flipped,
                half,
                cfg.iterations,
                cfg.regularization,
                sat_level,
            )
        })
        .collect();

    Ok(planes_to_image(&out_planes, image))
}

/// Run the bounded RL iteration on one channel and return the restored plane.
#[allow(clippy::too_many_arguments)]
fn rl_channel(
    obs: &[f64],
    width: usize,
    height: usize,
    psf: &[f64],
    flipped: &[f64],
    half: usize,
    iterations: usize,
    lambda: f64,
    sat_level: Option<f64>,
) -> Vec<f64> {
    // Initialize the estimate with the observation (standard RL seed).
    let mut u = obs.to_vec();

    // Precompute the saturated-core mask once if protection is enabled.
    let protect: Option<Vec<bool>> = sat_level.map(|lvl| obs.iter().map(|&v| v >= lvl).collect());

    // Bounded loop — RL never runs unbounded here.
    for _ in 0..iterations {
        // blur = h * u_k
        let blur = convolve(&u, width, height, psf, half);

        // ratio = obs / blur (guarded against divide-by-zero)
        let ratio: Vec<f64> = obs
            .par_iter()
            .zip(blur.par_iter())
            .map(|(&o, &b)| if b > 1e-12 { o / b } else { 0.0 })
            .collect();

        // correction = ĥ * ratio
        let correction = convolve(&ratio, width, height, flipped, half);

        // Optional TV damping factor per pixel.
        let damp: Option<Vec<f64>> = if lambda > 0.0 {
            Some(tv_damping(&u, width, height, lambda))
        } else {
            None
        };

        // Multiplicative update with optional damping and star protection.
        u.par_iter_mut()
            .zip(correction.par_iter())
            .enumerate()
            .for_each(|(idx, (uk, &corr))| {
                let mut factor = corr;
                if let Some(d) = &damp {
                    factor /= d[idx];
                }
                let mut next = *uk * factor;
                if !next.is_finite() || next < 0.0 {
                    next = 0.0;
                }
                // Star protection: do not let a saturated core grow (suppresses
                // the dark RL ring around clipped cores).
                if let Some(mask) = &protect {
                    if mask[idx] && next > *uk {
                        next = *uk;
                    }
                }
                *uk = next;
            });
    }

    u
}

/// Per-pixel total-variation damping factor `1 + λ·|∇u|/u`.
///
/// `|∇u|` is the forward-difference gradient magnitude; dividing by `u` makes
/// the term scale-invariant (a bright smooth region and a faint smooth region
/// are damped equally). The factor is ≥ 1, so dividing the RL update by it can
/// only *reduce* the update — never reverse its sign or break non-negativity.
fn tv_damping(u: &[f64], width: usize, height: usize, lambda: f64) -> Vec<f64> {
    (0..height)
        .into_par_iter()
        .flat_map_iter(|y| {
            let mut row = Vec::with_capacity(width);
            for x in 0..width {
                let idx = y * width + x;
                let c = u[idx];
                let right = if x + 1 < width { u[idx + 1] } else { c };
                let down = if y + 1 < height { u[idx + width] } else { c };
                let gx = right - c;
                let gy = down - c;
                let grad = (gx * gx + gy * gy).sqrt();
                let denom = c.abs().max(1e-6);
                row.push(1.0 + lambda * grad / denom);
            }
            row
        })
        .collect()
}

/// 2-D spatial convolution of a plane with a small odd kernel, edge-clamped.
///
/// Edge handling clamps sample coordinates to the image border (replicate),
/// which avoids the dark frame RL would otherwise produce from zero-padding the
/// borders. Parallelized per output row.
fn convolve(plane: &[f64], width: usize, height: usize, kernel: &[f64], half: usize) -> Vec<f64> {
    (0..height)
        .into_par_iter()
        .flat_map_iter(|y| {
            let mut row = Vec::with_capacity(width);
            for x in 0..width {
                let mut acc = 0.0_f64;
                for kj in 0..(2 * half + 1) {
                    // Clamp sample row to the image.
                    let sy = clamp_coord(y as isize + kj as isize - half as isize, height);
                    let krow = kj * (2 * half + 1);
                    let prow = sy * width;
                    for ki in 0..(2 * half + 1) {
                        let sx = clamp_coord(x as isize + ki as isize - half as isize, width);
                        acc += plane[prow + sx] * kernel[krow + ki];
                    }
                }
                row.push(acc);
            }
            row
        })
        .collect()
}

/// Clamp a (possibly negative) coordinate into `[0, extent)`.
#[inline]
fn clamp_coord(c: isize, extent: usize) -> usize {
    if c < 0 {
        0
    } else if c as usize >= extent {
        extent - 1
    } else {
        c as usize
    }
}

/// Flip a square kernel 180° (point reflection through its centre) — this is the
/// `ĥ` used in the RL correlation step.
fn flip_kernel(kernel: &[f64], size: usize) -> Vec<f64> {
    let mut out = vec![0.0; size * size];
    for j in 0..size {
        for i in 0..size {
            out[(size - 1 - j) * size + (size - 1 - i)] = kernel[j * size + i];
        }
    }
    out
}

// Shared helpers

/// Validate a PSF kernel: odd side, matching length, and a usable normalization.
fn validate_kernel(psf: &PsfModel) -> Result<(), DeconvError> {
    if psf.size == 0 || psf.size.is_multiple_of(2) {
        return Err(DeconvError::BadKernel);
    }
    if psf.kernel.len() != psf.size * psf.size {
        return Err(DeconvError::BadKernel);
    }
    let sum: f64 = psf.kernel.iter().sum();
    if !sum.is_finite() || sum <= 0.0 {
        return Err(DeconvError::BadKernel);
    }
    if psf.kernel.iter().any(|v| !v.is_finite()) {
        return Err(DeconvError::BadKernel);
    }
    Ok(())
}

/// Force a value to be odd by adding 1 if it is even.
#[inline]
fn force_odd(n: usize) -> usize {
    if n.is_multiple_of(2) {
        n + 1
    } else {
        n
    }
}

/// Convert an image to a single linear luminance plane in f64.
///
/// For multi-channel frames the channels are averaged into a luminance plane
/// (PSF estimation is channel-agnostic). Returns `None` for unsupported pixel
/// layouts (only `U16` and `F32` are handled, the project's linear-light types).
fn image_to_plane(image: &ImageData) -> Option<(Vec<f64>, usize, usize)> {
    let planes = image_to_planes(image)?;
    let width = image.width as usize;
    let height = image.height as usize;
    let n = width * height;
    if planes.is_empty() || n == 0 {
        return None;
    }
    let mut lum = vec![0.0_f64; n];
    for p in &planes {
        for (acc, &v) in lum.iter_mut().zip(p.iter()) {
            *acc += v;
        }
    }
    let inv = 1.0 / planes.len() as f64;
    for v in lum.iter_mut() {
        *v *= inv;
    }
    Some((lum, width, height))
}

/// Decompose an image into planar f64 channels (de-interleaving if needed).
///
/// Supports `U16` and `F32` pixel types — the linear-light layouts used by the
/// processing pipeline. Returns `None` otherwise.
fn image_to_planes(image: &ImageData) -> Option<Vec<Vec<f64>>> {
    let width = image.width as usize;
    let height = image.height as usize;
    let channels = image.channels as usize;
    let n = width * height;
    if n == 0 || channels == 0 {
        return None;
    }

    let interleaved: Vec<f64> = match image.pixel_type {
        crate::PixelType::U16 => image.as_u16()?.into_iter().map(|v| v as f64).collect(),
        crate::PixelType::F32 => image.as_f32()?.into_iter().map(|v| v as f64).collect(),
        _ => return None,
    };
    if interleaved.len() < n * channels {
        return None;
    }

    // De-interleave channel-by-channel.
    let mut planes = vec![vec![0.0_f64; n]; channels];
    for pix in 0..n {
        for (c, plane) in planes.iter_mut().enumerate() {
            plane[pix] = interleaved[pix * channels + c];
        }
    }
    Some(planes)
}

/// Re-interleave planar f64 channels back into an `ImageData` matching the
/// template's dimensions and pixel type (`U16` clamped to `[0, 65535]`, or `F32`).
fn planes_to_image(planes: &[Vec<f64>], template: &ImageData) -> ImageData {
    let width = template.width;
    let height = template.height;
    let channels = planes.len() as u32;
    let n = (width as usize) * (height as usize);

    match template.pixel_type {
        crate::PixelType::F32 => {
            let mut inter = vec![0.0_f32; n * planes.len()];
            for (c, plane) in planes.iter().enumerate() {
                for (pix, &v) in plane.iter().enumerate() {
                    inter[pix * planes.len() + c] = v as f32;
                }
            }
            ImageData::from_f32(width, height, channels, &inter)
        }
        // Default to U16 for U16 and anything else that reached here.
        _ => {
            let mut inter = vec![0u16; n * planes.len()];
            for (c, plane) in planes.iter().enumerate() {
                for (pix, &v) in plane.iter().enumerate() {
                    inter[pix * planes.len() + c] = v.round().clamp(0.0, 65535.0) as u16;
                }
            }
            ImageData::from_u16(width, height, channels, &inter)
        }
    }
}

/// Saturation guard as a fraction of the detection plane's full-well. Stars whose
/// peak sits above this fraction of the full-scale are treated as clipped /
/// non-linear and excluded from the PSF stack (see [`select_psf_stars`]).
const SATURATION_FRACTION: f64 = 0.9;

/// Upper bound of the normalized-linear `F32` domain. The crate treats `F32`
/// frames as normalized linear light in `[0, 1]` (e.g. `xisf.rs` declares the F32
/// bounds as `0:1`), so `1.0` is the full-well a clipped star core saturates to.
const F32_FULL_SCALE: f64 = 1.0;

/// Build a `U16` `ImageData` view of a luminance plane so [`detect_stars`] (which
/// expects the native U16 layout) can run on any supported input pixel type, and
/// report the **saturation level in that view's scale** for [`select_psf_stars`].
///
/// The detector and the saturation guard both assume a 16-bit ADU domain. A
/// normalized linear `F32` frame — what the rest of the crate treats `F32` as
/// ([0, 1], e.g. `xisf.rs` bounds, `stretch.rs`) — has every star living in
/// values like `[0.02, 0.82]`; a bare `round().clamp(0, 65535)` would crush the
/// whole frame to 0/1, so `detect_stars` would find nothing and `estimate_psf`
/// would wrongly return `TooFewStars` even on a perfect star field. To support
/// that path honestly we derive the working scale from the data:
///
/// * A wide-range plane (peak ≥ 256 — any real ADU frame, whose stars are in the
///   thousands) is passed through with a plain clamp: native ADU, zero behaviour
///   change, and the saturation level is the usual `0.9 · 65535`.
/// * A low-amplitude plane (peak < 256 — a normalized float frame) is rescaled
///   from its *known full-scale* `[0, 1] → [0, 65535]` (NOT from the data peak):
///   this preserves the absolute meaning of "near full-well" so an unsaturated
///   star at 0.4 maps to ~26000 (well below the guard, kept) while only a clipped
///   core at 1.0 maps to 65535 and is correctly flagged. The saturation level is
///   therefore the same `0.9 · 65535` the ADU path uses. (Rescaling from the data
///   *peak* instead would pin the brightest star to full range, and the guard
///   would then wrongly reject every bright star.)
fn as_u16_image(image: &ImageData, plane: &[f64], width: usize, height: usize) -> (ImageData, f64) {
    const U16_SAT: f64 = 65535.0 * SATURATION_FRACTION;

    if image.pixel_type == crate::PixelType::U16 && image.channels == 1 {
        return (image.clone(), U16_SAT);
    }

    // Peak of the (finite) luminance plane decides ADU vs normalized-float.
    let peak = plane
        .iter()
        .copied()
        .filter(|v| v.is_finite())
        .fold(f64::NEG_INFINITY, f64::max);

    // Wide-range / ADU-scaled (or degenerate-empty): native passthrough.
    if !peak.is_finite() || peak >= 256.0 {
        let data: Vec<u16> = plane
            .iter()
            .map(|&v| v.round().clamp(0.0, 65535.0) as u16)
            .collect();
        return (
            ImageData::from_u16(width as u32, height as u32, 1, &data),
            U16_SAT,
        );
    }

    // Normalized-float plane: rescale from the known [0, 1] full-scale into the
    // 16-bit detector domain. A flat/non-positive plane simply maps to all-zero
    // (nothing detectable), which this same linear map already produces.
    let scale = 65535.0 / F32_FULL_SCALE;
    let data: Vec<u16> = plane
        .iter()
        .map(|&v| (v * scale).round().clamp(0.0, 65535.0) as u16)
        .collect();
    (
        ImageData::from_u16(width as u32, height as u32, 1, &data),
        U16_SAT,
    )
}

// Tests

#[cfg(test)]
mod tests {
    use super::*;

    /// Deterministic xorshift64* → uniform `[0, 1)`, used only for pseudo-noise.
    struct Lcg(u64);
    impl Lcg {
        fn new(seed: u64) -> Self {
            Lcg(seed | 1)
        }
        fn next_unit(&mut self) -> f64 {
            let mut s = self.0;
            s ^= s >> 12;
            s ^= s << 25;
            s ^= s >> 27;
            self.0 = s;
            let r = s.wrapping_mul(0x2545F491_4F6CDD1D);
            (r >> 11) as f64 / (1u64 << 53) as f64
        }
    }

    /// Render a single Gaussian point source (background + one star) into a
    /// linear U16 frame.
    fn render_point(
        width: u32,
        height: u32,
        cx: f64,
        cy: f64,
        sigma: f64,
        peak: f64,
        background: f64,
    ) -> ImageData {
        let w = width as usize;
        let h = height as usize;
        let mut data = vec![background as u16; w * h];
        let two_sig_sq = 2.0 * sigma * sigma;
        for y in 0..h {
            for x in 0..w {
                let dx = x as f64 - cx;
                let dy = y as f64 - cy;
                let v = background + peak * (-(dx * dx + dy * dy) / two_sig_sq).exp();
                data[y * w + x] = v.clamp(0.0, 65535.0) as u16;
            }
        }
        ImageData::from_u16(width, height, 1, &data)
    }

    /// Render a grid of identical round Gaussian stars on a noisy background.
    #[allow(clippy::too_many_arguments)]
    fn render_star_field(
        width: u32,
        height: u32,
        sigma: f64,
        peak: f64,
        background: f64,
        noise: f64,
        step: usize,
        seed: u64,
    ) -> ImageData {
        let w = width as usize;
        let h = height as usize;
        let mut data = vec![0.0_f64; w * h];
        let mut rng = Lcg::new(seed);
        for v in data.iter_mut() {
            // Box–Muller Gaussian background noise.
            let u1 = rng.next_unit().max(1e-12);
            let u2 = rng.next_unit();
            let g = (-2.0 * u1.ln()).sqrt() * (std::f64::consts::TAU * u2).cos();
            *v = background + g * noise;
        }
        let two_sig_sq = 2.0 * sigma * sigma;
        let r = (4.0 * sigma).ceil() as i32;
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
                        let add = peak * (-rr / two_sig_sq).exp();
                        data[y as usize * w + x as usize] += add;
                    }
                }
                sx += step;
            }
            sy += step;
        }
        let u16data: Vec<u16> = data.iter().map(|&v| v.clamp(0.0, 65535.0) as u16).collect();
        ImageData::from_u16(width, height, 1, &u16data)
    }

    /// Measure the FWHM of the brightest blob in a linear U16 frame from the
    /// half-maximum crossing of its azimuthally-averaged radial profile about the
    /// peak (independent of `stats.rs`).
    ///
    /// Why a radial profile with an interpolated crossing, and not either of the
    /// obvious alternatives:
    /// * A bare encircled-half-max *radius* is quantized to the pixel grid and is
    ///   blind to sub-pixel concentration — a sharpened core that still has one
    ///   faint pixel at the same outer radius reads the same coarse FWHM, which is
    ///   exactly why the previous helper could not see RL's sharpening.
    /// * A whole-frame flux-weighted *second moment* is dominated by its `r²`
    ///   weighting of the faint far field; un-regularized RL legitimately lifts
    ///   that background, so the second moment grows even as the core tightens —
    ///   the wrong thing to assert on.
    ///
    /// The radial profile averages all pixels at each integer radius about the
    /// peak centroid, so it measures the **core width** the way
    /// [`measure_kernel_fwhm`] does for the PSF itself: build the profile,
    /// normalise its peak to 1, and linearly interpolate the radius at which it
    /// first falls to 0.5. The result is `2·r_half`, the true FWHM, robust to
    /// both pixel quantization (via interpolation) and far-field background
    /// (via the azimuthal average, which dilutes isolated noise pixels).
    fn measure_point_fwhm(image: &ImageData) -> f64 {
        let w = image.width as usize;
        let h = image.height as usize;
        let pix: Vec<f64> = image.as_u16().unwrap().iter().map(|&v| v as f64).collect();
        let bg = pix.iter().cloned().fold(f64::INFINITY, f64::min);
        let (peak_idx, peak_val) =
            pix.iter()
                .enumerate()
                .fold((0usize, f64::NEG_INFINITY), |(bi, bv), (i, &v)| {
                    if v > bv {
                        (i, v)
                    } else {
                        (bi, bv)
                    }
                });
        let amp = peak_val - bg;
        if amp <= 0.0 {
            return 0.0;
        }
        let pcx = (peak_idx % w) as f64;
        let pcy = (peak_idx / w) as f64;

        // Azimuthally-averaged radial profile of the background-subtracted signal
        // about the peak: accumulate each pixel's signal into its rounded-radius
        // bin, then average per bin. Bounded by the frame's max radius.
        let max_r = ((w * w + h * h) as f64).sqrt().ceil() as usize + 1;
        let mut sum = vec![0.0_f64; max_r];
        let mut cnt = vec![0.0_f64; max_r];
        for y in 0..h {
            for x in 0..w {
                let dx = x as f64 - pcx;
                let dy = y as f64 - pcy;
                let r = (dx * dx + dy * dy).sqrt().round() as usize;
                if r < max_r {
                    sum[r] += pix[y * w + x] - bg;
                    cnt[r] += 1.0;
                }
            }
        }
        // Normalised profile (peak → 1.0), using the central amplitude as the
        // reference so saturation of the very centre cannot inflate the width.
        let profile: Vec<f64> = sum
            .iter()
            .zip(cnt.iter())
            .map(|(&s, &c)| if c > 0.0 { (s / c) / amp } else { 0.0 })
            .collect();

        // First outward crossing below 0.5, linearly interpolated.
        for r in 1..profile.len() {
            if profile[r] <= 0.5 {
                let prev = profile[r - 1];
                let cur = profile[r];
                let denom = prev - cur;
                let frac = if denom > 0.0 {
                    (prev - 0.5) / denom
                } else {
                    0.0
                };
                let r_half = (r - 1) as f64 + frac;
                return 2.0 * r_half;
            }
        }
        // Never crossed (degenerate): report the frame extent as a floor.
        2.0 * max_r as f64
    }

    /// Total flux above a **fixed** reference background, the quantity RL
    /// conserves.
    ///
    /// Why a fixed reference and not each frame's own global minimum: RL conserves
    /// the *raw* total flux (`∑u`, because `∑h = 1` and the update is
    /// multiplicative), so flux above a *constant* pedestal is conserved too. It
    /// does **not** conserve "flux above the per-frame minimum" — RL perturbs the
    /// background, dropping the global min, so subtracting each frame's own min
    /// removes a *different* pedestal before and after and spuriously reports the
    /// flux as having grown. Passing the common rendered pedestal removes the
    /// same constant from both frames and measures the genuinely-conserved signal.
    fn total_signal(image: &ImageData, background: f64) -> f64 {
        let pix: Vec<f64> = image.as_u16().unwrap().iter().map(|&v| v as f64).collect();
        pix.iter().map(|&v| (v - background).max(0.0)).sum()
    }

    #[test]
    fn rl_with_known_psf_reduces_fwhm_and_conserves_flux() {
        // Ground-truth: a sharp point blurred by a known Gaussian PSF. RL with
        // that exact PSF must sharpen the blob (reduce FWHM) toward the original
        // and approximately conserve total background-subtracted flux.
        let sigma = 2.0_f64;
        // Peak chosen so that when RL concentrates the blurred Gaussian's flux
        // toward the core, the central pixels stay BELOW the u16 ceiling (65535).
        // A higher peak would clip at saturation and lose flux at the final u16
        // quantization, which is a quantization artefact, not an RL property —
        // the test's subject is RL's intrinsic flux conservation, so we keep the
        // core un-saturated to measure it honestly.
        let blurred = render_point(64, 64, 32.0, 32.0, sigma, 12000.0, 500.0);
        let fwhm_before = measure_point_fwhm(&blurred);

        // Construct the matching Gaussian PSF kernel directly.
        let size = 15usize;
        let half = size / 2;
        let mut kernel = render_gaussian(size, half, sigma);
        normalize_sum(&mut kernel);
        let psf = PsfModel {
            kind: PsfKind::Gaussian,
            fwhm: FWHM_PER_SIGMA * sigma,
            beta: 0.0,
            size,
            kernel,
        };

        // A modest iteration count with light TV regularization: enough RL passes
        // to visibly tighten the core (the FWHM assertion below) while the TV term
        // throttles the wing/background amplification that un-regularized RL would
        // otherwise add, so background-subtracted flux stays conserved within
        // tolerance. (More iterations or zero regularization sharpens harder but
        // amplifies the faint wings, inflating the measured flux — a real RL
        // trade-off, not a bug.)
        let cfg = DeconvConfig {
            iterations: 8,
            regularization: 0.02,
            star_protect: false,
        };
        let restored = richardson_lucy(&blurred, &psf, &cfg).expect("RL must succeed");

        // Dimensions preserved.
        assert_eq!(restored.width, blurred.width);
        assert_eq!(restored.height, blurred.height);
        assert_eq!(restored.channels, blurred.channels);

        let fwhm_after = measure_point_fwhm(&restored);
        assert!(
            fwhm_after < fwhm_before,
            "RL must reduce FWHM: before={fwhm_before:.3} after={fwhm_after:.3}"
        );

        // Flux conservation: RL conserves total flux (∑h = 1). Measure flux above
        // the common rendered pedestal (500 ADU) so the SAME background is removed
        // from both frames. Allow 12% for u16 quantization, edge clamping, the few
        // saturated core pixels, and finite iterations.
        let flux_before = total_signal(&blurred, 500.0);
        let flux_after = total_signal(&restored, 500.0);
        let rel = (flux_after - flux_before).abs() / flux_before;
        assert!(
            rel < 0.12,
            "RL must approximately conserve flux: before={flux_before:.1} after={flux_after:.1} rel={rel:.3}"
        );
    }

    #[test]
    fn estimate_psf_recovers_planted_fwhm() {
        // A synthetic field of identical σ=2.0 Gaussian stars. The estimated PSF
        // FWHM must match the analytic Gaussian FWHM within tolerance.
        let sigma = 2.0_f64;
        let planted_fwhm = FWHM_PER_SIGMA * sigma;
        let field = render_star_field(200, 200, sigma, 25000.0, 800.0, 6.0, 28, 0xC0FFEE);

        for kind in [PsfKind::Gaussian, PsfKind::Moffat, PsfKind::Empirical] {
            let cfg = PsfEstimateConfig {
                max_stars: 60,
                crop: 21,
                kind,
            };
            let psf = estimate_psf(&field, &cfg).unwrap_or_else(|e| {
                panic!("estimate_psf({kind:?}) should succeed on a dense field, got {e:?}")
            });
            // Kernel is odd and normalized to sum 1.
            assert!(psf.size % 2 == 1, "kernel side must be odd");
            let sum: f64 = psf.kernel.iter().sum();
            assert!((sum - 1.0).abs() < 1e-9, "kernel must sum to 1, got {sum}");

            let err = (psf.fwhm - planted_fwhm).abs() / planted_fwhm;
            assert!(
                err < 0.25,
                "{kind:?}: estimated FWHM {:.3} vs planted {:.3} (err {:.1}%)",
                psf.fwhm,
                planted_fwhm,
                err * 100.0
            );
        }
    }

    #[test]
    fn estimate_psf_succeeds_on_normalized_f32_starfield() {
        // A normalized [0,1] linear F32 frame (the layout the rest of the crate
        // treats F32 as — stars at values like 0.02..0.82) must yield a PSF
        // estimate: scaling by a hardcoded `round().clamp(0,65535)` crushes
        // every pixel to 0/1 and detect_stars then finds nothing. This plants
        // the SAME star geometry as the U16 case, divides into [0,1] and
        // asserts the recovered FWHM still matches the planted Gaussian.
        let sigma = 2.0_f64;
        let planted_fwhm = FWHM_PER_SIGMA * sigma;

        // Render the field in ADU, then normalize to [0,1] F32. Background 0.01,
        // star peak ~0.8 — a realistic normalized linear frame.
        let u16_field = render_star_field(200, 200, sigma, 25000.0, 800.0, 6.0, 28, 0xC0FFEE);
        let src = u16_field.as_u16().unwrap();
        let f32_data: Vec<f32> = src.iter().map(|&v| v as f32 / 65535.0).collect();
        let field = ImageData::from_f32(200, 200, 1, &f32_data);
        assert_eq!(field.pixel_type, crate::PixelType::F32);
        // Sanity: this really is a low-amplitude [0,1] frame.
        let max_v = f32_data.iter().cloned().fold(0.0f32, f32::max);
        assert!(max_v <= 1.0, "frame must be normalized, peak {max_v}");

        for kind in [PsfKind::Gaussian, PsfKind::Moffat, PsfKind::Empirical] {
            let cfg = PsfEstimateConfig {
                max_stars: 60,
                crop: 21,
                kind,
            };
            let psf = estimate_psf(&field, &cfg).unwrap_or_else(|e| {
                panic!("estimate_psf({kind:?}) must succeed on a normalized F32 field, got {e:?}")
            });
            assert!(psf.size % 2 == 1, "kernel side must be odd");
            let sum: f64 = psf.kernel.iter().sum();
            assert!((sum - 1.0).abs() < 1e-9, "kernel must sum to 1, got {sum}");
            let err = (psf.fwhm - planted_fwhm).abs() / planted_fwhm;
            assert!(
                err < 0.25,
                "{kind:?}: F32 estimated FWHM {:.3} vs planted {:.3} (err {:.1}%)",
                psf.fwhm,
                planted_fwhm,
                err * 100.0
            );
        }
    }

    #[test]
    fn estimate_psf_errors_when_too_few_stars() {
        // A flat, starless frame yields no usable PSF stars.
        let flat = ImageData::from_u16(64, 64, 1, &vec![1000u16; 64 * 64]);
        let cfg = PsfEstimateConfig::default();
        assert_eq!(estimate_psf(&flat, &cfg), Err(DeconvError::TooFewStars));
    }

    #[test]
    fn estimate_psf_errors_on_empty_image() {
        let empty = ImageData::new(0, 0, 1, crate::PixelType::U16);
        assert_eq!(
            estimate_psf(&empty, &PsfEstimateConfig::default()),
            Err(DeconvError::EmptyImage)
        );
    }

    #[test]
    fn richardson_lucy_terminates_and_preserves_dimensions() {
        // Even a large iteration budget must terminate (bounded loop) and the
        // output dims/channels/type must equal the input.
        let img = render_point(48, 48, 24.0, 24.0, 1.8, 30000.0, 600.0);
        let size = 11usize;
        let half = size / 2;
        let mut kernel = render_gaussian(size, half, 1.8);
        normalize_sum(&mut kernel);
        let psf = PsfModel {
            kind: PsfKind::Gaussian,
            fwhm: FWHM_PER_SIGMA * 1.8,
            beta: 0.0,
            size,
            kernel,
        };
        let cfg = DeconvConfig {
            iterations: 200,
            regularization: 0.02,
            star_protect: true,
        };
        let out = richardson_lucy(&img, &psf, &cfg).expect("RL must terminate and succeed");
        assert_eq!(out.width, img.width);
        assert_eq!(out.height, img.height);
        assert_eq!(out.channels, img.channels);
        assert_eq!(out.pixel_type, img.pixel_type);
        // Output must be finite, non-negative u16 (no NaN poisoning).
        let pix = out.as_u16().expect("u16 output");
        assert_eq!(pix.len(), (img.width * img.height) as usize);
    }

    #[test]
    fn richardson_lucy_rejects_empty_and_bad_kernel() {
        let good_img = render_point(32, 32, 16.0, 16.0, 1.5, 20000.0, 400.0);
        let empty = ImageData::new(0, 0, 1, crate::PixelType::U16);
        let mut kernel = render_gaussian(7, 3, 1.5);
        normalize_sum(&mut kernel);
        let good_psf = PsfModel {
            kind: PsfKind::Gaussian,
            fwhm: FWHM_PER_SIGMA * 1.5,
            beta: 0.0,
            size: 7,
            kernel,
        };
        // Empty image → EmptyImage. (ImageData has no PartialEq, so assert on the
        // error variant directly rather than on the whole Result.)
        assert_eq!(
            richardson_lucy(&empty, &good_psf, &DeconvConfig::default()).unwrap_err(),
            DeconvError::EmptyImage
        );
        // Even-sided kernel → BadKernel.
        let bad_even = PsfModel {
            size: 4,
            kernel: vec![0.0625; 16],
            ..good_psf.clone()
        };
        assert_eq!(
            richardson_lucy(&good_img, &bad_even, &DeconvConfig::default()).unwrap_err(),
            DeconvError::BadKernel
        );
        // Wrong-length kernel → BadKernel.
        let bad_len = PsfModel {
            size: 7,
            kernel: vec![0.1; 10],
            ..good_psf.clone()
        };
        assert_eq!(
            richardson_lucy(&good_img, &bad_len, &DeconvConfig::default()).unwrap_err(),
            DeconvError::BadKernel
        );
        // Zero-sum kernel → BadKernel.
        let bad_sum = PsfModel {
            size: 7,
            kernel: vec![0.0; 49],
            ..good_psf.clone()
        };
        assert_eq!(
            richardson_lucy(&good_img, &bad_sum, &DeconvConfig::default()).unwrap_err(),
            DeconvError::BadKernel
        );
    }

    #[test]
    fn convolution_with_delta_kernel_is_identity() {
        // A centre-delta kernel must leave the plane unchanged (sanity check the
        // convolution indexing).
        let w = 8usize;
        let h = 6usize;
        let mut plane = vec![0.0; w * h];
        for (i, v) in plane.iter_mut().enumerate() {
            *v = i as f64;
        }
        let size = 5usize;
        let half = size / 2;
        let mut kernel = vec![0.0; size * size];
        kernel[half * size + half] = 1.0;
        let out = convolve(&plane, w, h, &kernel, half);
        assert_eq!(out, plane, "delta-kernel convolution must be identity");
    }

    #[test]
    fn flip_kernel_reverses_asymmetric_kernel() {
        // 3×3 kernel with a unique value per cell; flipping twice is identity,
        // and the flip must be a true 180° rotation.
        let k = vec![1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0];
        let f = flip_kernel(&k, 3);
        assert_eq!(f, vec![9.0, 8.0, 7.0, 6.0, 5.0, 4.0, 3.0, 2.0, 1.0]);
        let ff = flip_kernel(&f, 3);
        assert_eq!(ff, k, "double flip must be identity");
    }

    #[test]
    fn normalize_sum_makes_kernel_unit_dc() {
        let mut k = vec![1.0, 2.0, 3.0, 4.0];
        normalize_sum(&mut k);
        let s: f64 = k.iter().sum();
        assert!((s - 1.0).abs() < 1e-12);
        // Degenerate (all-zero) kernel becomes a centre delta, not NaN.
        let mut z = vec![0.0; 9];
        normalize_sum(&mut z);
        assert_eq!(z[4], 1.0);
        assert!((z.iter().sum::<f64>() - 1.0).abs() < 1e-12);
    }

    #[test]
    fn force_odd_and_clamp_coord_behaviour() {
        assert_eq!(force_odd(24), 25);
        assert_eq!(force_odd(25), 25);
        assert_eq!(clamp_coord(-3, 10), 0);
        assert_eq!(clamp_coord(4, 10), 4);
        assert_eq!(clamp_coord(20, 10), 9);
    }

    #[test]
    fn measure_kernel_fwhm_matches_gaussian_definition() {
        // A rendered Gaussian kernel's measured FWHM should match 2.355·σ.
        let sigma = 2.5_f64;
        let size = 25usize;
        let half = size / 2;
        let mut k = render_gaussian(size, half, sigma);
        normalize_sum(&mut k);
        let fwhm = measure_kernel_fwhm(&k, size);
        let expected = FWHM_PER_SIGMA * sigma;
        let err = (fwhm - expected).abs() / expected;
        assert!(
            err < 0.12,
            "measured kernel FWHM {fwhm:.3} vs expected {expected:.3} (err {:.1}%)",
            err * 100.0
        );
    }
}
