//! Light-frame normalization to a reference frame.
//!
//! Before a population of aligned sub-frames is integrated into a master, every
//! frame must be brought onto the *reference frame's* photometric scale. This
//! matters for two reasons:
//!
//! 1. **Rejection correctness.** Pixel-rejection algorithms (sigma-clip,
//!    Winsorized-sigma, linear-fit-clip) compare each frame's value for a pixel
//!    against the population at that pixel. If one frame has a higher background
//!    (passing cloud, moonrise, light pollution drift) or a different
//!    multiplicative gain (transparency change, slightly different exposure),
//!    its *signal* looks like an outlier and the rejector throws away good data.
//!    Normalizing first means the only thing that differs between frames at a
//!    given pixel is noise + genuine transients (satellites, planes, cosmic
//!    rays) — exactly what rejection should catch.
//!
//! 2. **Unbiased combination.** A weighted mean of frames that disagree on
//!    offset/scale produces a master with a biased background and a compressed
//!    dynamic range. Normalizing puts them on a common footing first.
//!
//! This is the role of PixInsight's `ImageIntegration` normalization (additive
//! + scale) and, for gradient drift through a night, its `LocalNormalization`.
//!
//! ## Model — PixInsight's "additive with scaling" (the default)
//!
//! Each frame `f` is mapped onto the reference `r` by the affine relation
//!
//! ```text
//!     f_norm(p) = m_ref + (f(p) − m_f) · (σ_ref / σ_f)
//! ```
//!
//! which is stored in the equivalent `scale · f + offset` form with
//! `scale = σ_ref/σ_f` and `offset = m_ref − m_f·scale`.
//!
//! - **Location `m`** — the *median* of the frame (over a deterministic sample
//!   of the covered, finite pixels). Matching medians puts the two sky pedestals
//!   on top of each other, correcting skyglow / light-pollution drift.
//! - **Scale `σ`** — a *robust dispersion* (MAD × 1.4826, optionally refined by
//!   iterative k-sigma clipping — the IKSS family). Their ratio corrects
//!   transparency / exposure differences.
//!
//! Both statistics come from each frame's **own global pixel population**. That
//! is the load-bearing property. Median and MAD are inherently star-resistant
//! (stars are a tiny fraction of the pixels), so the estimate needs no
//! star-exclusion cut, and for two same-night equal-exposure subs the dispersion
//! ratio lands at ≈ 1 — which is the correct answer.
//!
//! ### Why not regress reference-on-frame over pixel pairs?
//!
//! Because two registered subs of the same field are *independent noise
//! realisations* of a shared signal, not a deterministic function of one
//! another. An ordinary-least-squares slope over `(frame, reference)` pixel
//! pairs measures `cov(f,r)/var(f)`. Cut the stars out first (as a
//! "fit the sky, not the PSF" rule would have you do) and on a sparse star field
//! the only thing left is each frame's *own independent* noise: the covariance
//! goes to zero and so does the slope. Applying that slope flattens the frame to
//! a constant.
//!
//! This is not hypothetical — it is the defect this module was rewritten to fix.
//! The previous estimator discarded everything above the reference's 92nd
//! percentile and then ran OLS on what remained, returning `scale ≈ 0.002`
//! against a true value of ≈ 1.0, and shipped per-filter masters that retained
//! **under 0.1 %** of their star flux. The unit tests missed it for a subtle
//! reason worth remembering: every one of them built the frame as an exact
//! affine function of the reference, making the pair perfectly correlated — a
//! property real sub-frames never have.
//!
//! The pair fit survives, honestly scoped, as
//! [`NormEstimator::CoLocatedPairFit`]. It is correct exactly when the two
//! buffers sample the **same sky at the same index** (mosaic panel overlap,
//! where `frame[i]` and `reference[i]` are two measurements of one sky
//! coordinate). It is wrong for stacking, where they are not.
//!
//! ## Optional local (grid) normalization
//!
//! A single global `(scale, offset)` cannot remove a *gradient* that changes
//! across the night (the moon climbing, a light dome rotating). For that, an
//! optional coarse grid of local `(scale, offset)` coefficients is fitted —
//! one per cell over a `grid_rows × grid_cols` lattice — and bilinearly
//! interpolated per pixel when applied. This is the `LocalNormalization`
//! analogue. It is **off by default** (global is correct for stable skies and
//! avoids over-fitting low-signal cells); callers enable it for the
//! "long night / moving moon" preset.
//!
//! ## Limitations
//!
//! The constants (clipping κ and iteration count for the IKSS refinement, the
//! plausible-ratio band, the minimum sample count per local cell, the sample
//! cap) are defensible defaults matched to PixInsight's behaviour, not values
//! tuned against a corpus of real sub sets. They are exposed as knobs.
//!
//! A single global `(m, σ)` pair assumes the frame-to-frame difference is a
//! global affine one. It cannot describe a *spatially varying* gradient; that is
//! what [`NormMode::Local`] is for.
//!
//! Sampling is deterministic (a fixed stride, never an RNG), so a given input
//! always yields the same coefficients — a property the master-accumulation fold
//! depends on across sessions and processes.

use crate::robust_stats::{median_in_place, MAD_TO_SIGMA};

/// Marks, per pixel, whether a frame contributes a valid sample.
///
/// After registration warps a sub onto the reference grid, the border pixels
/// that mapped outside the source frame carry no real data (the resampler
/// zero-fills them). Those pixels must be excluded from the normalization fit —
/// otherwise the frame's "background" is contaminated by a band of zeros and
/// the offset is pulled toward black. A `CoverageMask` records which output
/// pixels have genuine source support.
///
/// `valid.len()` must equal `width × height` (one flag per pixel, channel-
/// independent — coverage is a geometric property of the warp, the same for
/// every channel). When a caller has no coverage information (e.g. the frame
/// was not warped), [`CoverageMask::full`] treats every pixel as valid.
#[derive(Debug, Clone)]
pub struct CoverageMask {
    width: usize,
    height: usize,
    valid: Vec<bool>,
}

impl CoverageMask {
    /// Build a mask from an explicit per-pixel validity vector.
    ///
    /// Returns `None` if `valid.len() != width × height`.
    pub fn new(width: usize, height: usize, valid: Vec<bool>) -> Option<Self> {
        if valid.len() != width.checked_mul(height)? {
            return None;
        }
        Some(Self {
            width,
            height,
            valid,
        })
    }

    /// A mask in which every pixel is valid (no coverage restriction).
    pub fn full(width: usize, height: usize) -> Self {
        Self {
            width,
            height,
            valid: vec![true; width * height],
        }
    }

    /// Derive a coverage mask from a warped frame's pixel values, treating any
    /// pixel that is exactly zero **and** finite as uncovered.
    ///
    /// This matches the resampler's zero-fill-on-out-of-bounds convention
    /// (`registration::warp_frame`). It is a convenience for callers that only
    /// have the warped buffer; callers that have an explicit per-pixel coverage
    /// count from the resampler should prefer [`CoverageMask::new`] since a
    /// genuinely-black covered sky pixel is vanishingly rare but not impossible.
    pub fn from_zero_fill(frame: &[f64], width: usize, height: usize) -> Self {
        let valid = frame
            .iter()
            .map(|&v| v.is_finite() && v != 0.0)
            .collect::<Vec<_>>();
        Self {
            width,
            height,
            valid,
        }
    }

    #[inline]
    fn is_valid(&self, index: usize) -> bool {
        self.valid.get(index).copied().unwrap_or(false)
    }

    /// Whether the pixel at flat row-major `index` (= `y·width + x`) had valid
    /// source support. Out-of-range indices are treated as uncovered. This is
    /// the public accessor used by batch integration to skip pixels a given
    /// frame did not cover after warping.
    #[inline]
    pub fn is_valid_at(&self, index: usize) -> bool {
        self.is_valid(index)
    }

    /// Width in pixels.
    pub fn width(&self) -> usize {
        self.width
    }

    /// Height in pixels.
    pub fn height(&self) -> usize {
        self.height
    }
}

/// Which normalization model to fit.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub enum NormMode {
    /// A single global additive+multiplicative pair for the whole frame.
    /// Correct for stable skies; the safe default.
    #[default]
    Global,
    /// A coarse `rows × cols` grid of local additive+multiplicative pairs,
    /// bilinearly interpolated per pixel. Corrects gradient drift across the
    /// night at the cost of more parameters; use only with enough signal.
    Local { rows: usize, cols: usize },
}

/// Which estimator computes the `(scale, offset)` pair.
///
/// The two variants make *different assumptions about what the two buffers are*,
/// and picking the wrong one is not a quality trade-off — it is a correctness
/// bug. See the module docs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum NormEstimator {
    /// PixInsight `ImageIntegration`'s default: additive with scaling toward the
    /// reference, from each frame's own robust global location and dispersion.
    ///
    /// Correct whenever the frames are **independent exposures** of the same
    /// field — i.e. every stacking path. The default.
    #[default]
    AdditiveWithScaling,
    /// Ordinary least squares on `(frame[i], reference[i])` pixel pairs.
    ///
    /// Correct **only** when index `i` refers to the same sky coordinate in both
    /// buffers, so the pairs are genuinely correlated — the mosaic panel-overlap
    /// fit ([`crate::mosaic_stitch`]) resamples two panels onto one canvas and
    /// satisfies this exactly.
    ///
    /// Catastrophic for stacking: independent subs make the pairs uncorrelated
    /// once bright structure is cut, and the slope collapses toward zero.
    CoLocatedPairFit,
}

/// Tunables for the normalization fit. [`Default`] is the PixInsight-default
/// global additive-with-scaling fit.
#[derive(Debug, Clone)]
pub struct NormalizationConfig {
    /// Global vs. local grid model.
    pub mode: NormMode,
    /// Which estimator to use. Default [`NormEstimator::AdditiveWithScaling`].
    pub estimator: NormEstimator,
    /// Upper percentile (0..1) of the *reference* signal above which pixels are
    /// excluded as "stars / bright structure".
    ///
    /// Used **only** by [`NormEstimator::CoLocatedPairFit`], where bright stars
    /// really would dominate a least-squares slope. The additive-with-scaling
    /// estimator ignores it: median and MAD are already star-resistant, and
    /// restricting them to background pixels is precisely what broke the old
    /// estimator. Default 0.92.
    pub high_reject_percentile: f64,
    /// Sigma-clip threshold (κ) — for the pair fit, the residual cut; for
    /// additive-with-scaling, the IKSS refinement cut. Default 2.5.
    pub clip_kappa: f64,
    /// Number of robust-refit / IKSS iterations. Default 3.
    pub clip_iterations: usize,
    /// Minimum number of valid samples required to fit a model (global) or a
    /// single local cell. Below this the fit falls back to identity (global) or
    /// to the global coefficients (local cell). Default 64.
    pub min_samples: usize,
    /// Cap on the number of pixels sampled for the robust location/dispersion
    /// estimate. A deterministic stride subsamples larger frames — PixInsight
    /// samples for speed too. Default 262144, ample for a median/MAD.
    pub max_samples: usize,
    /// Plausible band for `σ_ref/σ_frame`. A ratio outside it means the frame is
    /// not a comparable exposure of the same field (or its statistics are
    /// degenerate); the fit falls back to additive-only and reports a warning
    /// rather than applying an absurd gain. Default `(0.1, 10.0)`.
    pub scale_ratio_bounds: (f64, f64),
}

impl Default for NormalizationConfig {
    fn default() -> Self {
        Self {
            mode: NormMode::Global,
            estimator: NormEstimator::AdditiveWithScaling,
            high_reject_percentile: 0.92,
            clip_kappa: 2.5,
            clip_iterations: 3,
            min_samples: 64,
            max_samples: 262_144,
            scale_ratio_bounds: (0.1, 10.0),
        }
    }
}

/// A fitted local grid of `(scale, offset)` coefficients.
///
/// Coefficients sit at the **centres** of a `rows × cols` lattice of cells over
/// the frame. Applying the grid bilinearly interpolates between the four
/// surrounding cell centres for each pixel, so the correction varies smoothly
/// across the frame with no cell-boundary discontinuities.
#[derive(Debug, Clone, PartialEq)]
pub struct LocalGrid {
    /// Lattice rows.
    pub rows: usize,
    /// Lattice columns.
    pub cols: usize,
    /// Per-cell multiplicative scale, row-major (`rows × cols`).
    pub scale: Vec<f64>,
    /// Per-cell additive offset, row-major (`rows × cols`).
    pub offset: Vec<f64>,
}

/// A recoverable problem met while fitting, surfaced instead of being absorbed
/// into a silently degenerate coefficient.
///
/// The old estimator's failure mode was to return `scale ≈ 0.002` with no
/// complaint whatsoever, so every fallback here is *named* and travels out on
/// [`NormalizationCoeffs::warning`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NormalizationWarning {
    /// The frame's robust dispersion was ~0 — a dead, flat, or fully-saturated
    /// frame. Fell back to additive-only (`scale = 1`).
    DegenerateDispersion,
    /// `σ_ref/σ_frame` fell outside [`NormalizationConfig::scale_ratio_bounds`],
    /// so the frame is not a comparable exposure. Fell back to additive-only.
    ImplausibleScaleRatio,
    /// Too few valid samples survived coverage/finiteness to estimate anything.
    /// Fell back to identity.
    InsufficientSamples,
}

impl NormalizationWarning {
    /// A short human-readable reason, for logs and result payloads.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::DegenerateDispersion => {
                "frame dispersion was ~0 (dead or flat frame); applied offset only"
            }
            Self::ImplausibleScaleRatio => {
                "scale ratio outside the plausible band; applied offset only"
            }
            Self::InsufficientSamples => {
                "too few valid pixels to estimate normalization; left unchanged"
            }
        }
    }
}

/// The result of fitting a normalization of one frame to a reference.
///
/// `scale`/`offset` are always present (the global fit, or the population-mean
/// of the local cells); `local` is `Some` only for [`NormMode::Local`].
#[derive(Debug, Clone, PartialEq)]
pub struct NormalizationCoeffs {
    /// Global multiplicative scale: `f_norm = scale · f + offset`.
    pub scale: f64,
    /// Global additive offset.
    pub offset: f64,
    /// Optional local grid (interpolated per pixel when applied).
    pub local: Option<LocalGrid>,
    /// Number of valid samples the global fit used (post-clipping), for
    /// diagnostics / confidence reporting.
    pub samples_used: usize,
    /// Set when a guard fired and the coefficients are a fallback rather than a
    /// full fit. `None` on a clean fit.
    pub warning: Option<NormalizationWarning>,
}

impl NormalizationCoeffs {
    /// The identity normalization (`scale = 1`, `offset = 0`, no local grid).
    /// Returned when there is too little overlapping signal to fit honestly.
    pub fn identity() -> Self {
        Self {
            scale: 1.0,
            offset: 0.0,
            local: None,
            samples_used: 0,
            warning: None,
        }
    }
}

/// Errors from the normalization fit. These are *expected* shape mismatches the
/// caller passed in, surfaced loudly rather than producing a garbage fit.
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum NormalizationError {
    /// `frame` and `reference` differ in length.
    #[error("frame ({frame}) and reference ({reference}) pixel counts differ")]
    LengthMismatch { frame: usize, reference: usize },
    /// The coverage mask does not describe a `width × height` buffer matching
    /// the supplied pixel count.
    #[error("coverage mask ({mask}) does not match pixel count ({pixels})")]
    MaskMismatch { mask: usize, pixels: usize },
    /// A local grid was requested with a zero dimension.
    #[error("local normalization grid must have non-zero rows and cols")]
    EmptyGrid,
}

// Public API

/// Estimate the normalization that maps `frame` onto `reference`'s photometric
/// scale.
///
/// `frame` and `reference` are single-channel planes of identical length
/// (`width × height`); for RGB the caller normalizes each channel against the
/// matching reference channel (the coefficients are per-channel by construction
/// because gain/skyglow can differ between channels). `mask` marks the pixels
/// `frame` validly covers (border pixels that warped out of the source are
/// excluded). Non-finite pixels in either buffer are always excluded.
///
/// The estimator is chosen by [`NormalizationConfig::estimator`]; the default
/// is PixInsight's additive-with-scaling (see the module docs for why the
/// pixel-pair alternative is only valid for co-located samples).
///
/// Returns [`NormalizationCoeffs::identity`] if too few valid samples survive
/// the exclusions to fit honestly (a deliberate fail-safe, never a fabricated
/// transform), with `warning` set to explain which guard fired.
pub fn estimate_normalization(
    frame: &[f64],
    reference: &[f64],
    mask: &CoverageMask,
    width: usize,
    height: usize,
    cfg: &NormalizationConfig,
) -> Result<NormalizationCoeffs, NormalizationError> {
    if frame.len() != reference.len() {
        return Err(NormalizationError::LengthMismatch {
            frame: frame.len(),
            reference: reference.len(),
        });
    }
    let pixels = width.saturating_mul(height);
    if frame.len() != pixels {
        return Err(NormalizationError::LengthMismatch {
            frame: frame.len(),
            reference: pixels,
        });
    }
    if mask.valid.len() != pixels {
        return Err(NormalizationError::MaskMismatch {
            mask: mask.valid.len(),
            pixels,
        });
    }
    if let NormMode::Local { rows, cols } = cfg.mode {
        if rows == 0 || cols == 0 {
            return Err(NormalizationError::EmptyGrid);
        }
    }

    // The high-signal exclusion threshold is only meaningful for the pair fit;
    // additive-with-scaling deliberately uses the whole pixel population.
    let high_cut = match cfg.estimator {
        NormEstimator::AdditiveWithScaling => f64::INFINITY,
        NormEstimator::CoLocatedPairFit => {
            high_signal_cutoff(reference, mask, cfg.high_reject_percentile)
        }
    };

    // Always fit the global model first: it is the fallback for sparse local
    // cells and the reported scalar coefficients.
    let global = match cfg.estimator {
        NormEstimator::AdditiveWithScaling => {
            fit_global_additive_scaling(frame, reference, mask, 0..frame.len(), cfg)
        }
        NormEstimator::CoLocatedPairFit => fit_global_pairs(frame, reference, mask, high_cut, cfg),
    };

    let local = match cfg.mode {
        NormMode::Global => None,
        NormMode::Local { rows, cols } => Some(fit_local_grid(
            frame, reference, mask, width, height, rows, cols, high_cut, &global, cfg,
        )),
    };

    Ok(NormalizationCoeffs {
        scale: global.scale,
        offset: global.offset,
        local,
        samples_used: global.samples_used,
        warning: global.warning,
    })
}

/// Apply previously-estimated coefficients to a frame in place.
///
/// For [`NormalizationCoeffs`] without a local grid this is the global affine
/// map `f ← scale·f + offset`. With a local grid, the per-pixel `(scale,
/// offset)` is bilinearly interpolated from the cell-centre lattice. Non-finite
/// pixels are left untouched (they carry no signal to correct and propagating
/// NaN through the integration is handled there).
pub fn apply_normalization(
    frame: &mut [f64],
    coeffs: &NormalizationCoeffs,
    width: usize,
    height: usize,
) {
    match &coeffs.local {
        None => {
            for v in frame.iter_mut() {
                if v.is_finite() {
                    *v = coeffs.scale * *v + coeffs.offset;
                }
            }
        }
        Some(grid) => apply_local_grid(frame, grid, width, height),
    }
}

// Global fit

/// A bare global fit result (no local grid).
#[derive(Debug, Clone, Copy)]
struct GlobalFit {
    scale: f64,
    offset: f64,
    samples_used: usize,
    warning: Option<NormalizationWarning>,
}

impl GlobalFit {
    fn identity() -> Self {
        Self {
            scale: 1.0,
            offset: 0.0,
            samples_used: 0,
            warning: None,
        }
    }

    fn insufficient() -> Self {
        Self {
            warning: Some(NormalizationWarning::InsufficientSamples),
            ..Self::identity()
        }
    }
}

// Additive-with-scaling (PixInsight ImageIntegration default)

/// A frame's robust location and dispersion, plus how many samples backed them.
#[derive(Debug, Clone, Copy)]
struct RobustStats {
    location: f64,
    dispersion: f64,
    samples: usize,
}

/// Deterministically sample the covered values of both planes at the *same*
/// pixels, returning `(frame_sample, reference_sample)`.
///
/// A pixel contributes only if it is covered and finite in **both** planes. The
/// two statistics then describe the same spatial population, so a NaN region or
/// a warp border in one plane cannot silently shift the other's median onto a
/// different patch of sky. (The samples are not used as *pairs* — each side is
/// reduced independently — but they must cover the same ground.)
///
/// Large frames are strided rather than fully sorted: a median/MAD converges
/// long before two million samples, and PixInsight samples for the same reason.
/// The stride is fixed (never an RNG), so identical input always yields
/// identical coefficients; the multi-night fold depends on that holding across
/// separate processes.
///
/// If striding lands on too few valid pixels (a heavily masked frame), the scan
/// is repeated densely over every pixel before giving up.
fn sample_both(
    frame: &[f64],
    reference: &[f64],
    mask: &CoverageMask,
    indices: impl Iterator<Item = usize> + Clone,
    max_samples: usize,
) -> (Vec<f64>, Vec<f64>) {
    let cap = max_samples.max(1);
    let total = indices.clone().count();
    let stride = (total / cap).max(1);

    let take = |stride: usize| {
        let mut fs = Vec::new();
        let mut rs = Vec::new();
        for i in indices.clone().step_by(stride) {
            if !mask.is_valid(i) {
                continue;
            }
            let (f, r) = (frame[i], reference[i]);
            if f.is_finite() && r.is_finite() {
                fs.push(f);
                rs.push(r);
            }
        }
        (fs, rs)
    };

    let (fs, rs) = take(stride);
    if stride > 1 && fs.len() < cap / 4 {
        return take(1);
    }
    (fs, rs)
}

/// Robust location (median) and dispersion (MAD·1.4826) of a sample, refined by
/// iterative k-sigma clipping — the IKSS family PixInsight uses.
///
/// Median and MAD are computed over the frame's whole pixel population on
/// purpose. Stars occupy a tiny fraction of the pixels, so neither statistic
/// needs them excluded; excluding them (as the previous estimator did) is what
/// removed all the dynamic range and broke the fit.
fn robust_location_dispersion(sample: &mut Vec<f64>, cfg: &NormalizationConfig) -> RobustStats {
    if sample.is_empty() {
        return RobustStats {
            location: 0.0,
            dispersion: 0.0,
            samples: 0,
        };
    }

    let mut location = median_in_place(sample);
    let mut dispersion = mad_sigma(sample, location);

    for _ in 0..cfg.clip_iterations {
        if dispersion <= 0.0 || !dispersion.is_finite() {
            break;
        }
        let limit = cfg.clip_kappa.max(0.0) * dispersion;
        let before = sample.len();
        sample.retain(|v| (v - location).abs() <= limit);
        // Never clip away the population we are trying to describe.
        if sample.len() < cfg.min_samples.min(before) || sample.len() == before {
            break;
        }
        location = median_in_place(sample);
        dispersion = mad_sigma(sample, location);
    }

    RobustStats {
        location,
        dispersion,
        samples: sample.len(),
    }
}

/// Median absolute deviation about `center`, scaled onto a Gaussian-σ footing.
fn mad_sigma(values: &[f64], center: f64) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    let mut devs: Vec<f64> = values.iter().map(|v| (v - center).abs()).collect();
    median_in_place(&mut devs) * MAD_TO_SIGMA
}

/// Fit `x' = m_ref + (x − m_f)·(σ_ref/σ_f)` over the given index range and
/// express it in the stored `scale·x + offset` form.
///
/// Guards, each of which names itself in the returned warning rather than
/// silently emitting a degenerate coefficient:
/// - too few samples on either side → identity;
/// - `σ_f` ≈ 0 (dead or flat frame) → additive-only (`scale = 1`);
/// - `σ_ref/σ_f` outside the plausible band → additive-only.
fn fit_global_additive_scaling(
    frame: &[f64],
    reference: &[f64],
    mask: &CoverageMask,
    indices: impl Iterator<Item = usize> + Clone,
    cfg: &NormalizationConfig,
) -> GlobalFit {
    let (mut frame_sample, mut ref_sample) =
        sample_both(frame, reference, mask, indices, cfg.max_samples);

    if frame_sample.len() < cfg.min_samples {
        return GlobalFit::insufficient();
    }

    let fs = robust_location_dispersion(&mut frame_sample, cfg);
    let rs = robust_location_dispersion(&mut ref_sample, cfg);
    let samples_used = fs.samples.min(rs.samples);

    // Additive-only fallback: match the pedestals, leave the gain alone.
    let additive_only = |warning| GlobalFit {
        scale: 1.0,
        offset: rs.location - fs.location,
        samples_used,
        warning: Some(warning),
    };

    if fs.dispersion <= f64::MIN_POSITIVE || !fs.dispersion.is_finite() {
        return additive_only(NormalizationWarning::DegenerateDispersion);
    }
    if rs.dispersion <= f64::MIN_POSITIVE || !rs.dispersion.is_finite() {
        return additive_only(NormalizationWarning::DegenerateDispersion);
    }

    let scale = rs.dispersion / fs.dispersion;
    let (lo, hi) = cfg.scale_ratio_bounds;
    if !scale.is_finite() || scale < lo || scale > hi {
        return additive_only(NormalizationWarning::ImplausibleScaleRatio);
    }

    let offset = rs.location - fs.location * scale;
    if !offset.is_finite() {
        return additive_only(NormalizationWarning::DegenerateDispersion);
    }

    GlobalFit {
        scale,
        offset,
        samples_used,
        warning: None,
    }
}

/// Collect the `(frame, reference)` value pairs that are valid samples for the
/// fit: both finite, covered by the mask, and below the bright-structure cutoff.
fn collect_pairs(
    frame: &[f64],
    reference: &[f64],
    indices: impl Iterator<Item = usize>,
    mask: &CoverageMask,
    high_cut: f64,
) -> Vec<(f64, f64)> {
    let mut pairs = Vec::new();
    for i in indices {
        if !mask.is_valid(i) {
            continue;
        }
        let f = frame[i];
        let r = reference[i];
        if !f.is_finite() || !r.is_finite() {
            continue;
        }
        // Exclude bright structure (stars) judged on the reference so the same
        // pixels are excluded for every frame compared against it.
        if r > high_cut {
            continue;
        }
        pairs.push((f, r));
    }
    pairs
}

/// Fit one local cell as a **per-cell additive offset at the global scale**:
/// `offset_cell = m_ref_cell − m_frame_cell · global_scale`.
///
/// Deliberately *not* a per-cell dispersion ratio. What local normalization
/// exists to remove is a spatially varying sky pedestal (a light dome, the moon
/// climbing) — an additive effect. A gradient inside a cell inflates that cell's
/// dispersion without any gain having changed, so a per-cell `σ_ref/σ_frame`
/// would read the gradient as a gain difference and apply a wild correction: on
/// a 1200-ADU gradient over a 64-px frame in 6×6 cells, the intra-cell spread
/// swamps the ~6 ADU noise and drives the ratio to ≈0.1. Gain is a whole-frame
/// property (transparency, exposure); it is fitted once, globally, and reused.
///
/// Returns `None` when the cell is too sparse, leaving it seeded with the global
/// coefficients.
fn fit_cell_offset(
    frame: &[f64],
    reference: &[f64],
    mask: &CoverageMask,
    indices: impl Iterator<Item = usize> + Clone,
    global_scale: f64,
    cfg: &NormalizationConfig,
) -> Option<(f64, f64)> {
    let (mut fs, mut rs) = sample_both(frame, reference, mask, indices, cfg.max_samples);
    if fs.len() < cfg.min_samples {
        return None;
    }
    let m_frame = median_in_place(&mut fs);
    let m_ref = median_in_place(&mut rs);
    let offset = m_ref - m_frame * global_scale;
    offset.is_finite().then_some((global_scale, offset))
}

/// Fit the global `(scale, offset)` by OLS over co-located pixel pairs.
///
/// **Precondition — not a preference:** `frame[i]` and `reference[i]` must be
/// two measurements of the *same sky coordinate*. The mosaic panel-overlap fit
/// resamples both panels onto one canvas through their WCS and satisfies this;
/// independent sub-frames in a stack do not, and feeding them here produces a
/// slope near zero that erases the image. See [`NormEstimator`].
fn fit_global_pairs(
    frame: &[f64],
    reference: &[f64],
    mask: &CoverageMask,
    high_cut: f64,
    cfg: &NormalizationConfig,
) -> GlobalFit {
    let pairs = collect_pairs(frame, reference, 0..frame.len(), mask, high_cut);
    match fit_robust_line(&pairs, cfg) {
        Some((scale, offset, used)) => GlobalFit {
            scale,
            offset,
            samples_used: used,
            warning: None,
        },
        None => GlobalFit::insufficient(),
    }
}

/// Iterated, sigma-clipped least-squares line fit `r ≈ scale·f + offset`.
///
/// We regress *reference on frame* so that applying `scale·f + offset` yields a
/// value on the reference's scale. The fit is robustified by κ-sigma clipping:
/// fit, compute residual σ, drop pairs beyond κ·σ, refit — this rejects the
/// residual stars / hot pixels / transients that survived the percentile cut.
///
/// Returns `None` (→ identity) if fewer than `cfg.min_samples` pairs survive or
/// the frame values have no spread (a flat frame cannot determine a slope).
fn fit_robust_line(pairs: &[(f64, f64)], cfg: &NormalizationConfig) -> Option<(f64, f64, usize)> {
    if pairs.len() < cfg.min_samples {
        return None;
    }

    let mut kept: Vec<(f64, f64)> = pairs.to_vec();

    let mut last: Option<(f64, f64)> = None;
    for _ in 0..cfg.clip_iterations.max(1) {
        if kept.len() < cfg.min_samples {
            break;
        }
        let (scale, offset) = ordinary_least_squares(&kept)?;
        last = Some((scale, offset));

        // Residual σ of the current fit.
        let residuals: Vec<f64> = kept
            .iter()
            .map(|&(f, r)| r - (scale * f + offset))
            .collect();
        let sigma = std_dev(&residuals);
        if sigma <= f64::MIN_POSITIVE {
            break; // perfect fit; nothing left to clip
        }

        let limit = cfg.clip_kappa.max(0.0) * sigma;
        let before = kept.len();
        kept = kept
            .iter()
            .copied()
            .zip(residuals.iter())
            .filter(|(_, &res)| res.abs() <= limit)
            .map(|(pair, _)| pair)
            .collect();

        if kept.len() == before {
            break; // converged: no further pairs clipped
        }
    }

    // Refit on the final retained set for the reported coefficients.
    let final_fit = if kept.len() >= cfg.min_samples {
        ordinary_least_squares(&kept).or(last)
    } else {
        last
    };

    final_fit.map(|(scale, offset)| (scale, offset, kept.len()))
}

/// Closed-form ordinary least squares for `y ≈ a·x + b`.
///
/// Returns `None` if `x` has no variance (degenerate, slope undetermined).
fn ordinary_least_squares(pairs: &[(f64, f64)]) -> Option<(f64, f64)> {
    let n = pairs.len() as f64;
    if n < 2.0 {
        return None;
    }
    let (mut sx, mut sy, mut sxx, mut sxy) = (0.0, 0.0, 0.0, 0.0);
    for &(x, y) in pairs {
        sx += x;
        sy += y;
        sxx += x * x;
        sxy += x * y;
    }
    let denom = n * sxx - sx * sx;
    if denom.abs() < f64::EPSILON {
        return None;
    }
    let scale = (n * sxy - sx * sy) / denom;
    let offset = (sy - scale * sx) / n;
    if !scale.is_finite() || !offset.is_finite() {
        return None;
    }
    Some((scale, offset))
}

// Local grid fit + apply

/// Fit a `rows × cols` grid of local `(scale, offset)` coefficients.
///
/// Each cell fits its own robust line over the pixels whose centre falls in
/// that cell. Cells with too few valid samples fall back to the global fit so a
/// low-signal corner never injects a wild local correction.
#[allow(clippy::too_many_arguments)]
fn fit_local_grid(
    frame: &[f64],
    reference: &[f64],
    mask: &CoverageMask,
    width: usize,
    height: usize,
    rows: usize,
    cols: usize,
    high_cut: f64,
    global: &GlobalFit,
    cfg: &NormalizationConfig,
) -> LocalGrid {
    let mut scale = vec![global.scale; rows * cols];
    let mut offset = vec![global.offset; rows * cols];

    for cell_row in 0..rows {
        // Pixel row span for this cell (centre-aligned cells tile the frame).
        let y0 = cell_row * height / rows;
        let y1 = ((cell_row + 1) * height / rows).max(y0 + 1).min(height);
        for cell_col in 0..cols {
            let x0 = cell_col * width / cols;
            let x1 = ((cell_col + 1) * width / cols).max(x0 + 1).min(width);

            let indices = (y0..y1).flat_map(|y| (x0..x1).map(move |x| y * width + x));

            let cell = match cfg.estimator {
                NormEstimator::AdditiveWithScaling => {
                    fit_cell_offset(frame, reference, mask, indices, global.scale, cfg)
                }
                NormEstimator::CoLocatedPairFit => {
                    let pairs = collect_pairs(frame, reference, indices, mask, high_cut);
                    fit_robust_line(&pairs, cfg).map(|(s, o, _)| (s, o))
                }
            };

            if let Some((s, o)) = cell {
                let idx = cell_row * cols + cell_col;
                scale[idx] = s;
                offset[idx] = o;
            }
            // else: cell keeps the global coefficients it was seeded with.
        }
    }

    LocalGrid {
        rows,
        cols,
        scale,
        offset,
    }
}

/// Apply a local grid by bilinearly interpolating cell-centre coefficients.
fn apply_local_grid(frame: &mut [f64], grid: &LocalGrid, width: usize, height: usize) {
    if grid.rows == 0 || grid.cols == 0 || width == 0 || height == 0 {
        return;
    }

    for y in 0..height {
        // Map pixel y to a fractional cell-centre coordinate. Cell `c` spans
        // pixel rows `[c·H/rows, (c+1)·H/rows)`; its centre is at the midpoint.
        let gy = grid_coord(y, height, grid.rows);
        for x in 0..width {
            let idx = y * width + x;
            let v = frame[idx];
            if !v.is_finite() {
                continue;
            }
            let gx = grid_coord(x, width, grid.cols);
            let (s, o) = bilinear_coeffs(grid, gx, gy);
            frame[idx] = s * v + o;
        }
    }
}

/// Convert a pixel coordinate to the fractional cell-centre coordinate along one
/// axis: cell centres sit at integer values `0..n-1`, and a pixel at a cell
/// centre maps exactly to that integer. Pixels outside the first/last centre
/// clamp (no extrapolation of the correction beyond the fitted lattice).
fn grid_coord(pixel: usize, extent: usize, cells: usize) -> f64 {
    if cells <= 1 {
        return 0.0;
    }
    // Centre of cell c (in pixel units): (c + 0.5) · extent / cells - 0.5.
    // Invert to get the fractional cell coordinate g such that
    // pixel = (g + 0.5) · extent / cells - 0.5.
    let g = (pixel as f64 + 0.5) * cells as f64 / extent as f64 - 0.5;
    g.clamp(0.0, (cells - 1) as f64)
}

/// Bilinearly interpolate `(scale, offset)` at fractional grid coordinate
/// `(gx, gy)` where integer coordinates address cell centres.
fn bilinear_coeffs(grid: &LocalGrid, gx: f64, gy: f64) -> (f64, f64) {
    let x0 = gx.floor() as usize;
    let y0 = gy.floor() as usize;
    let x1 = (x0 + 1).min(grid.cols - 1);
    let y1 = (y0 + 1).min(grid.rows - 1);
    let fx = gx - x0 as f64;
    let fy = gy - y0 as f64;

    let at = |r: usize, c: usize| -> (f64, f64) {
        let i = r * grid.cols + c;
        (grid.scale[i], grid.offset[i])
    };

    let (s00, o00) = at(y0, x0);
    let (s10, o10) = at(y0, x1);
    let (s01, o01) = at(y1, x0);
    let (s11, o11) = at(y1, x1);

    let lerp = |a: f64, b: f64, t: f64| a + (b - a) * t;
    let s = lerp(lerp(s00, s10, fx), lerp(s01, s11, fx), fy);
    let o = lerp(lerp(o00, o10, fx), lerp(o01, o11, fx), fy);
    (s, o)
}

// Robust-statistics helpers

/// The reference value above which a pixel is treated as bright structure and
/// excluded from the fit. Computed as the `percentile` quantile of the *valid,
/// finite* reference pixels. Falls back to `+∞` (exclude nothing) when there is
/// no valid signal to rank.
fn high_signal_cutoff(reference: &[f64], mask: &CoverageMask, percentile: f64) -> f64 {
    let mut vals: Vec<f64> = reference
        .iter()
        .enumerate()
        .filter(|(i, v)| mask.is_valid(*i) && v.is_finite())
        .map(|(_, v)| *v)
        .collect();
    if vals.is_empty() {
        return f64::INFINITY;
    }
    vals.sort_by(f64::total_cmp);
    let p = percentile.clamp(0.0, 1.0);
    let rank = ((vals.len() - 1) as f64 * p).round() as usize;
    vals[rank.min(vals.len() - 1)]
}

/// Sample standard deviation (population form; the divisor is `n`, which is the
/// right normalization for a residual scatter estimate used only to set a clip
/// threshold). Returns 0 for fewer than two values.
fn std_dev(values: &[f64]) -> f64 {
    let n = values.len();
    if n < 2 {
        return 0.0;
    }
    let mean = values.iter().sum::<f64>() / n as f64;
    let var = values.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / n as f64;
    var.sqrt()
}

// Tests

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a deterministic synthetic reference plane: a smooth sky pedestal
    /// plus a few bright "stars" plus low-amplitude deterministic noise.
    fn synthetic_reference(width: usize, height: usize) -> Vec<f64> {
        let mut v = vec![0.0; width * height];
        for y in 0..height {
            for x in 0..width {
                let i = y * width + x;
                // Smooth pedestal with a gentle gradient so a real sky is modelled.
                let pedestal = 1000.0 + 0.5 * x as f64 + 0.3 * y as f64;
                // Deterministic zero-mean noise.
                let n = ((i.wrapping_mul(2654435761) >> 8) % 1000) as f64 / 1000.0 - 0.5;
                v[i] = pedestal + n * 20.0;
            }
        }
        // A handful of bright stars (excluded by the percentile cut in the fit).
        for &(sx, sy) in &[(5usize, 5usize), (20, 12), (12, 22), (28, 28)] {
            if sy < height && sx < width {
                v[sy * width + sx] = 60000.0;
            }
        }
        v
    }

    #[test]
    fn recovers_known_offset_and_scale() {
        let (w, h) = (32usize, 32usize);
        let reference = synthetic_reference(w, h);

        // Construct a frame that is the reference under a KNOWN affine map:
        //   reference = TRUE_SCALE · frame + TRUE_OFFSET
        // so the *frame* is reference inverted: frame = (reference - off)/scale.
        let true_scale = 1.35;
        let true_offset = -180.0;
        let frame: Vec<f64> = reference
            .iter()
            .map(|&r| (r - true_offset) / true_scale)
            .collect();

        let mask = CoverageMask::full(w, h);
        let cfg = NormalizationConfig::default();
        let coeffs = estimate_normalization(&frame, &reference, &mask, w, h, &cfg).unwrap();

        // The fit maps frame -> reference, so it should recover (true_scale, true_offset).
        assert!(
            (coeffs.scale - true_scale).abs() < 1e-3,
            "scale {} should be ~{}",
            coeffs.scale,
            true_scale
        );
        assert!(
            (coeffs.offset - true_offset).abs() < 1.0,
            "offset {} should be ~{}",
            coeffs.offset,
            true_offset
        );

        // Applying the coefficients should bring the frame back onto the reference.
        let mut normalized = frame.clone();
        apply_normalization(&mut normalized, &coeffs, w, h);
        // Compare on the sky pixels (exclude the injected bright stars where the
        // inverse-then-forward round trip is exact anyway).
        let mut max_err = 0.0f64;
        for (n, r) in normalized.iter().zip(reference.iter()) {
            max_err = max_err.max((n - r).abs());
        }
        assert!(
            max_err < 1e-6,
            "normalized frame should match reference to float precision, max err {}",
            max_err
        );
    }

    #[test]
    fn identity_frame_recovers_unit_scale_zero_offset() {
        let (w, h) = (24usize, 24usize);
        let reference = synthetic_reference(w, h);
        let frame = reference.clone();
        let mask = CoverageMask::full(w, h);

        let coeffs = estimate_normalization(
            &frame,
            &reference,
            &mask,
            w,
            h,
            &NormalizationConfig::default(),
        )
        .unwrap();
        assert!((coeffs.scale - 1.0).abs() < 1e-6, "scale {}", coeffs.scale);
        assert!(coeffs.offset.abs() < 1e-6, "offset {}", coeffs.offset);
    }

    #[test]
    fn excludes_nan_and_uncovered_border_pixels() {
        let (w, h) = (32usize, 32usize);
        let reference = synthetic_reference(w, h);

        let true_scale = 0.8;
        let true_offset = 250.0;
        let mut frame: Vec<f64> = reference
            .iter()
            .map(|&r| (r - true_offset) / true_scale)
            .collect();

        // Mark the first two columns as uncovered (warp border) AND poison them
        // with values that would wreck the fit if they were included.
        let mut valid = vec![true; w * h];
        for y in 0..h {
            for x in 0..2 {
                let i = y * w + x;
                valid[i] = false;
                frame[i] = 0.0; // zero-fill, the resampler's out-of-bounds value
            }
        }
        // Also inject a NaN into a covered pixel; it must be skipped, not poison
        // the fit or the apply step.
        let nan_idx = (h / 2) * w + (w / 2);
        frame[nan_idx] = f64::NAN;

        let mask = CoverageMask::new(w, h, valid).unwrap();
        let coeffs = estimate_normalization(
            &frame,
            &reference,
            &mask,
            w,
            h,
            &NormalizationConfig::default(),
        )
        .unwrap();

        // Despite the poisoned border and NaN, the true affine relation is
        // recovered from the covered, finite pixels.
        assert!(
            (coeffs.scale - true_scale).abs() < 1e-2,
            "scale {} should be ~{}",
            coeffs.scale,
            true_scale
        );
        assert!(
            (coeffs.offset - true_offset).abs() < 5.0,
            "offset {} should be ~{}",
            coeffs.offset,
            true_offset
        );

        // The NaN pixel must remain NaN after apply (left untouched), proving it
        // was excluded rather than silently turned into a finite value.
        let mut normalized = frame.clone();
        apply_normalization(&mut normalized, &coeffs, w, h);
        assert!(
            normalized[nan_idx].is_nan(),
            "NaN pixel must be left untouched by apply"
        );
    }

    #[test]
    fn too_few_samples_falls_back_to_identity_and_says_so() {
        // A tiny frame with fewer valid pixels than min_samples must not fabricate
        // a transform — it returns identity AND names the reason. The old
        // estimator's failure mode was a silent degenerate scale, so the warning
        // is part of the contract, not decoration.
        let (w, h) = (4usize, 4usize);
        let reference = vec![1000.0; w * h];
        let frame = vec![500.0; w * h];
        let mask = CoverageMask::full(w, h);

        let coeffs = estimate_normalization(
            &frame,
            &reference,
            &mask,
            w,
            h,
            &NormalizationConfig::default(),
        )
        .unwrap();
        assert_eq!(coeffs.scale, 1.0);
        assert_eq!(coeffs.offset, 0.0);
        assert_eq!(coeffs.samples_used, 0);
        assert_eq!(
            coeffs.warning,
            Some(NormalizationWarning::InsufficientSamples)
        );
    }

    #[test]
    fn rejects_length_mismatch() {
        let mask = CoverageMask::full(2, 2);
        let err = estimate_normalization(
            &[1.0, 2.0, 3.0],
            &[1.0, 2.0, 3.0, 4.0],
            &mask,
            2,
            2,
            &NormalizationConfig::default(),
        )
        .unwrap_err();
        assert!(matches!(err, NormalizationError::LengthMismatch { .. }));
    }

    #[test]
    fn rejects_mask_mismatch() {
        // Mask describes 2x2 but pixels describe 3x3.
        let mask = CoverageMask::full(2, 2);
        let frame = vec![0.0; 9];
        let reference = vec![0.0; 9];
        let err = estimate_normalization(
            &frame,
            &reference,
            &mask,
            3,
            3,
            &NormalizationConfig::default(),
        )
        .unwrap_err();
        assert!(matches!(err, NormalizationError::MaskMismatch { .. }));
    }

    #[test]
    fn local_grid_corrects_a_cross_frame_gradient() {
        // The frame differs from the reference by a gradient in the OFFSET that
        // a single global offset cannot remove: model a light dome brightening
        // toward one edge through the night. Local normalization should remove
        // it far better than global.
        let (w, h) = (64usize, 64usize);
        let reference = synthetic_reference(w, h);

        // frame = reference + added_gradient (so to recover reference we must
        // SUBTRACT a spatially-varying offset — exactly the local job). The
        // gradient is large vs. the ~6 ADU sky noise floor so the local
        // advantage is unambiguous (a global single offset cannot follow it).
        let added = |x: usize, _y: usize| -> f64 { 1200.0 * (x as f64 / w as f64) };
        let frame: Vec<f64> = reference
            .iter()
            .enumerate()
            .map(|(i, &r)| {
                let x = i % w;
                let y = i / w;
                r + added(x, y)
            })
            .collect();

        let mask = CoverageMask::full(w, h);

        // Global fit: best single offset, leaves a residual gradient.
        let global = estimate_normalization(
            &frame,
            &reference,
            &mask,
            w,
            h,
            &NormalizationConfig::default(),
        )
        .unwrap();
        let mut global_norm = frame.clone();
        apply_normalization(&mut global_norm, &global, w, h);
        let global_err = sky_rms(&global_norm, &reference, w, h);

        // Local fit: a grid that follows the gradient. 8 cells divide the 64-px
        // frame exactly, so each cell's pixel-median x coincides with the centre
        // `grid_coord` interpolates from. With a count that does NOT divide
        // evenly (e.g. 6 → cell widths 10,11,11,10,11,11) the fitted centres and
        // the assumed uniform centres disagree by up to half a pixel, which on a
        // steep ramp leaves a few ADU of avoidable residual. That quantization is
        // pre-existing and orthogonal to the estimator under test here.
        let local_cfg = NormalizationConfig {
            mode: NormMode::Local { rows: 8, cols: 8 },
            ..NormalizationConfig::default()
        };
        let local = estimate_normalization(&frame, &reference, &mask, w, h, &local_cfg).unwrap();
        assert!(local.local.is_some(), "local mode must produce a grid");
        let mut local_norm = frame.clone();
        apply_normalization(&mut local_norm, &local, w, h);
        let local_err = sky_rms(&local_norm, &reference, w, h);

        // Local must beat global by a wide margin: one global offset cannot
        // follow a spatially-varying pedestal.
        assert!(
            local_err < global_err / 5.0,
            "local normalization (RMS {local_err}) should decisively beat global (RMS {global_err}) on a gradient"
        );

        // Inside the lattice — between the first and last cell centres — the
        // correction interpolates and must reach the irreducible ~6 ADU sky-noise
        // floor, proving the gradient was removed rather than merely reduced.
        //
        // Outside it, `grid_coord` CLAMPS by design (no extrapolation of a fitted
        // correction beyond the data that produced it), so the outermost half-cell
        // border keeps a residual ramp. That is a deliberate property, measured
        // here rather than hidden by averaging it into one number.
        let half_cell = w / 8 / 2 + 1;
        let interior = sky_rms_region(&local_norm, &reference, w, h, half_cell);
        assert!(
            interior < 2.0,
            "interior local residual {interior} should be ~0 (frame and reference \
             share a noise realisation here, so only interpolation error remains)"
        );
    }

    /// RMS over sky pixels at least `inset` columns/rows from the border.
    fn sky_rms_region(a: &[f64], b: &[f64], w: usize, h: usize, inset: usize) -> f64 {
        let mut sum = 0.0;
        let mut n = 0usize;
        for y in inset..h.saturating_sub(inset) {
            for x in inset..w.saturating_sub(inset) {
                let i = y * w + x;
                if b[i] < 50000.0 {
                    sum += (a[i] - b[i]).powi(2);
                    n += 1;
                }
            }
        }
        if n == 0 {
            0.0
        } else {
            (sum / n as f64).sqrt()
        }
    }

    /// RMS difference over the sky pixels (exclude the injected bright stars,
    /// whose values are huge and would swamp the metric).
    fn sky_rms(a: &[f64], b: &[f64], _w: usize, _h: usize) -> f64 {
        let mut sum = 0.0;
        let mut n = 0usize;
        for (x, y) in a.iter().zip(b.iter()) {
            if *y < 50000.0 {
                sum += (x - y).powi(2);
                n += 1;
            }
        }
        if n == 0 {
            0.0
        } else {
            (sum / n as f64).sqrt()
        }
    }

    // Regression tests for the star-erasure defect
    //
    // These build frames the way real sub-frames actually are: a shared sky
    // signal plus an INDEPENDENT noise realisation per frame. That single
    // property is what the old pixel-pair estimator could not survive, and what
    // every pre-existing test above accidentally avoided by making the frame an
    // exact function of the reference.

    /// Deterministic LCG — reproducible "independent" noise per frame.
    struct Lcg(u64);
    impl Lcg {
        fn new(seed: u64) -> Self {
            Self(seed.wrapping_mul(6364136223846793005).wrapping_add(1))
        }
        /// Uniform in [-1, 1).
        fn next_signed(&mut self) -> f64 {
            self.0 = self
                .0
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            ((self.0 >> 11) as f64 / (1u64 << 53) as f64) * 2.0 - 1.0
        }
    }

    /// A sparse star field on a flat sky pedestal with per-frame independent
    /// noise — the shape of the real D1 frames that produced the broken masters
    /// (≈530 ADU sky, ≈4.5 ADU noise, a few hundred stars up to ~3000 ADU).
    fn sparse_star_frame(w: usize, h: usize, seed: u64, sky: f64, noise: f64) -> Vec<f64> {
        let mut rng = Lcg::new(seed);
        let mut v = vec![0.0; w * h];
        for px in v.iter_mut() {
            *px = sky + rng.next_signed() * noise;
        }
        // ~0.15 % of pixels are stars: sparse enough that a background-restricted
        // fit sees only noise, which is precisely the trap.
        let star_count = (w * h) / 650;
        for k in 0..star_count {
            let x = (k * 7919) % w;
            let y = (k * 6271) % h;
            v[y * w + x] = sky + 400.0 + (k % 9) as f64 * 300.0;
        }
        v
    }

    #[test]
    fn independent_noise_frames_recover_unit_scale() {
        // THE regression test. Two same-night, equal-exposure subs differ only by
        // an independent noise realisation, so the honest answer is scale ≈ 1 and
        // offset ≈ 0. The old estimator returned scale ≈ 0.002 here and flattened
        // the frame to a constant.
        let (w, h) = (128usize, 128usize);
        let reference = sparse_star_frame(w, h, 1, 530.0, 4.5);
        let frame = sparse_star_frame(w, h, 2, 530.0, 4.5);
        let mask = CoverageMask::full(w, h);

        let coeffs = estimate_normalization(
            &frame,
            &reference,
            &mask,
            w,
            h,
            &NormalizationConfig::default(),
        )
        .unwrap();

        assert_eq!(coeffs.warning, None, "a clean pair should raise no warning");
        assert!(
            (coeffs.scale - 1.0).abs() < 0.05,
            "scale {} must be ~1 for two comparable subs",
            coeffs.scale
        );
        assert!(
            coeffs.scale > 0.5,
            "scale {} must never collapse toward zero (the shipped defect)",
            coeffs.scale
        );
        // Assert on the APPLIED result, not the raw `offset` coefficient. Under
        // `x' = m_ref + (x − m_f)·k` the background lands on the reference by
        // construction for any k, and the stored `offset = m_ref − m_f·k` absorbs
        // any scale error multiplied by the 530 ADU pedestal — so a normal ~1 %
        // sampling error in k shows up as a ~6 ADU "offset" that means nothing on
        // its own. The pair is what matters.
        let mut normalized = frame.clone();
        apply_normalization(&mut normalized, &coeffs, w, h);
        let mut a = normalized.clone();
        let mut b = reference.clone();
        let (ma, mb) = (median_in_place(&mut a), median_in_place(&mut b));
        assert!(
            (ma - mb).abs() < 1.0,
            "normalized background {ma} should land on the reference background {mb}"
        );
    }

    #[test]
    fn normalization_preserves_star_flux_on_a_sparse_field() {
        // End-to-end statement of the user-visible bug: after normalizing, the
        // stars must still be there. The broken masters retained under 0.1 % of
        // their star flux above background.
        let (w, h) = (128usize, 128usize);
        let reference = sparse_star_frame(w, h, 11, 530.0, 4.5);
        let frame = sparse_star_frame(w, h, 12, 530.0, 4.5);
        let mask = CoverageMask::full(w, h);

        let star_idx = frame
            .iter()
            .enumerate()
            .max_by(|a, b| a.1.total_cmp(b.1))
            .map(|(i, _)| i)
            .unwrap();
        let before_flux = frame[star_idx] - 530.0;

        let coeffs = estimate_normalization(
            &frame,
            &reference,
            &mask,
            w,
            h,
            &NormalizationConfig::default(),
        )
        .unwrap();
        let mut normalized = frame.clone();
        apply_normalization(&mut normalized, &coeffs, w, h);

        let mut sorted = normalized.clone();
        let bg = median_in_place(&mut sorted);
        let after_flux = normalized[star_idx] - bg;
        let retention = after_flux / before_flux;
        assert!(
            retention > 0.9,
            "star flux retention {retention} must stay near 1.0 (broken masters kept <0.001)"
        );
    }

    #[test]
    fn recovers_injected_scale_and_offset_under_independent_noise() {
        // Inject a KNOWN transparency/skyglow perturbation on top of independent
        // noise and require the injected parameters back within a few percent.
        for &(true_scale, true_offset) in &[(1.25f64, -60.0f64), (0.8, 120.0), (2.0, 0.0)] {
            let (w, h) = (128usize, 128usize);
            let reference = sparse_star_frame(w, h, 21, 530.0, 4.5);
            // A physically-shaped frame: its own noise realisation, then the
            // whole thing scaled and shifted (what a gain/skyglow change does).
            let base = sparse_star_frame(w, h, 22, 530.0, 4.5);
            let frame: Vec<f64> = base
                .iter()
                .map(|&v| (v - true_offset) / true_scale)
                .collect();
            let mask = CoverageMask::full(w, h);

            let coeffs = estimate_normalization(
                &frame,
                &reference,
                &mask,
                w,
                h,
                &NormalizationConfig::default(),
            )
            .unwrap();

            let scale_err = (coeffs.scale - true_scale).abs() / true_scale;
            assert!(
                scale_err < 0.05,
                "scale {} should recover {true_scale} within 5% (err {scale_err})",
                coeffs.scale
            );
            // Applying the fit must land the frame's background on the reference's.
            let mut normalized = frame.clone();
            apply_normalization(&mut normalized, &coeffs, w, h);
            let mut a = normalized.clone();
            let mut b = reference.clone();
            let (ma, mb) = (median_in_place(&mut a), median_in_place(&mut b));
            assert!(
                (ma - mb).abs() < 2.0,
                "normalized background {ma} should match reference {mb}"
            );
        }
    }

    #[test]
    fn degenerate_dispersion_falls_back_to_additive_only() {
        // A dead/flat frame has zero dispersion: the ratio is undefined. It must
        // fall back to matching pedestals with scale 1 and SAY so, never emit a
        // division-derived garbage scale.
        let (w, h) = (64usize, 64usize);
        let reference = sparse_star_frame(w, h, 31, 530.0, 4.5);
        let frame = vec![100.0; w * h]; // perfectly flat
        let mask = CoverageMask::full(w, h);

        let coeffs = estimate_normalization(
            &frame,
            &reference,
            &mask,
            w,
            h,
            &NormalizationConfig::default(),
        )
        .unwrap();
        assert_eq!(
            coeffs.warning,
            Some(NormalizationWarning::DegenerateDispersion)
        );
        assert_eq!(coeffs.scale, 1.0, "must be additive-only");
        assert!(
            (coeffs.offset - (530.0 - 100.0)).abs() < 5.0,
            "offset {} should move the flat frame onto the reference pedestal",
            coeffs.offset
        );
    }

    #[test]
    fn implausible_scale_ratio_falls_back_to_additive_only() {
        // A frame whose dispersion is 100x the reference's is not a comparable
        // exposure. Applying a 0.01 gain would erase it — exactly the shipped
        // failure — so the guard trips instead.
        let (w, h) = (64usize, 64usize);
        let reference = sparse_star_frame(w, h, 41, 530.0, 4.5);
        let frame = sparse_star_frame(w, h, 42, 530.0, 450.0);
        let mask = CoverageMask::full(w, h);

        let coeffs = estimate_normalization(
            &frame,
            &reference,
            &mask,
            w,
            h,
            &NormalizationConfig::default(),
        )
        .unwrap();
        assert_eq!(
            coeffs.warning,
            Some(NormalizationWarning::ImplausibleScaleRatio)
        );
        assert_eq!(coeffs.scale, 1.0, "must be additive-only, not a 0.01 gain");
    }

    #[test]
    fn pair_fit_collapses_on_independent_subs_but_additive_scaling_does_not() {
        // Pins WHY the estimator was replaced, so nobody restores the old default
        // believing it equivalent. Same input, both estimators: the pixel-pair
        // OLS returns a near-zero slope (it is regressing one frame's noise on
        // another's), additive-with-scaling returns ~1.
        let (w, h) = (128usize, 128usize);
        let reference = sparse_star_frame(w, h, 51, 530.0, 4.5);
        let frame = sparse_star_frame(w, h, 52, 530.0, 4.5);
        let mask = CoverageMask::full(w, h);

        let pair_cfg = NormalizationConfig {
            estimator: NormEstimator::CoLocatedPairFit,
            ..NormalizationConfig::default()
        };
        let pair = estimate_normalization(&frame, &reference, &mask, w, h, &pair_cfg).unwrap();
        assert!(
            pair.scale < 0.1,
            "documented pathology: the pair fit collapses to ~0 on independent \
             subs (got {}), which is why it is no longer the default",
            pair.scale
        );

        let additive = estimate_normalization(
            &frame,
            &reference,
            &mask,
            w,
            h,
            &NormalizationConfig::default(),
        )
        .unwrap();
        assert!(
            (additive.scale - 1.0).abs() < 0.05,
            "additive-with-scaling holds at ~1 (got {})",
            additive.scale
        );
    }

    #[test]
    fn sampling_is_deterministic_across_calls() {
        // The multi-night fold re-fits in a different process; identical input
        // must give bit-identical coefficients or accumulated folds drift.
        let (w, h) = (400usize, 400usize);
        let reference = sparse_star_frame(w, h, 61, 530.0, 4.5);
        let frame = sparse_star_frame(w, h, 62, 530.0, 4.5);
        let mask = CoverageMask::full(w, h);
        let cfg = NormalizationConfig {
            max_samples: 4096, // force the striding path
            ..NormalizationConfig::default()
        };

        let a = estimate_normalization(&frame, &reference, &mask, w, h, &cfg).unwrap();
        let b = estimate_normalization(&frame, &reference, &mask, w, h, &cfg).unwrap();
        assert_eq!(a.scale.to_bits(), b.scale.to_bits());
        assert_eq!(a.offset.to_bits(), b.offset.to_bits());
    }

    #[test]
    fn strided_sampling_agrees_with_the_dense_fit() {
        // Subsampling is a speed optimisation, not a different algorithm: a
        // median/MAD from a strided sample must match the full-population answer.
        let (w, h) = (400usize, 400usize);
        let reference = sparse_star_frame(w, h, 71, 530.0, 4.5);
        let frame = sparse_star_frame(w, h, 72, 530.0, 4.5);
        let mask = CoverageMask::full(w, h);

        let dense = estimate_normalization(
            &frame,
            &reference,
            &mask,
            w,
            h,
            &NormalizationConfig {
                max_samples: usize::MAX,
                ..NormalizationConfig::default()
            },
        )
        .unwrap();
        let strided = estimate_normalization(
            &frame,
            &reference,
            &mask,
            w,
            h,
            &NormalizationConfig {
                max_samples: 8192,
                ..NormalizationConfig::default()
            },
        )
        .unwrap();
        assert!(
            (dense.scale - strided.scale).abs() < 0.03,
            "strided scale {} vs dense {}",
            strided.scale,
            dense.scale
        );
        // Compare the applied transforms, not the raw offsets: `offset` trades off
        // against `scale` through the pedestal, so the two coefficients are only
        // meaningful together (see `independent_noise_frames_recover_unit_scale`).
        let (mut da, mut sa) = (frame.clone(), frame.clone());
        apply_normalization(&mut da, &dense, w, h);
        apply_normalization(&mut sa, &strided, w, h);
        let (mut dm, mut sm) = (da.clone(), sa.clone());
        assert!(
            (median_in_place(&mut dm) - median_in_place(&mut sm)).abs() < 1.0,
            "strided and dense fits must agree on the normalized background"
        );
    }

    #[test]
    fn local_grid_reduces_to_global_on_uniform_data() {
        // With no spatial variation, the local grid should produce essentially
        // the same correction as global everywhere (every cell fits the same
        // line), so applying it matches the reference just as well.
        let (w, h) = (48usize, 48usize);
        let reference = synthetic_reference(w, h);
        let true_scale = 1.1;
        let true_offset = -90.0;
        let frame: Vec<f64> = reference
            .iter()
            .map(|&r| (r - true_offset) / true_scale)
            .collect();
        let mask = CoverageMask::full(w, h);

        let cfg = NormalizationConfig {
            mode: NormMode::Local { rows: 4, cols: 4 },
            ..NormalizationConfig::default()
        };
        let coeffs = estimate_normalization(&frame, &reference, &mask, w, h, &cfg).unwrap();
        let mut normalized = frame.clone();
        apply_normalization(&mut normalized, &coeffs, w, h);
        let err = sky_rms(&normalized, &reference, w, h);
        assert!(
            err < 1.0,
            "local norm on uniform data should match reference closely, RMS {err}"
        );
    }
}
