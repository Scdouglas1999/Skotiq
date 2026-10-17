//! Advanced weighted **batch** image integration with pixel rejection.
//!
//! This is the post-session (offline, archival-quality) counterpart to the
//! online, single-pass combiner baked into [`crate::stacking::LiveStacker`].
//! Where the live stacker must commit to each sub the moment it arrives — and
//! therefore can only do an *online* sigma clip against a running mean — this
//! module sees the **entire aligned population at once** and can run rejection
//! algorithms that need the full per-pixel distribution: Winsorized sigma
//! clipping, linear-fit clipping, percentile clipping, classic sigma clipping,
//! and min/max clipping. That batch view is what makes the result
//! order-independent and lets the strongest rejectors (linear-fit, Winsorized)
//! work at all.
//!
//! ## What this module assumes about its input
//!
//! Integration is the *last* stage of the post-session pipeline. By the time a
//! frame reaches here it must already be:
//!
//! 1. **Aligned** onto the common reference grid (see
//!    [`crate::registration::register_frame`]) — every input frame has the same
//!    `width × height × channels`.
//! 2. **Normalized** onto the reference's photometric scale (see
//!    [`crate::normalization::apply_normalization`]) — otherwise sigma rejection
//!    would clip real signal away as if it were an outlier.
//! 3. **Weighted** with a scalar quality weight (see
//!    [`crate::frame_weighting::weight_frames`]) — better subs pull the master
//!    toward themselves.
//!
//! This module does **none** of those steps; it consumes their output. Each
//! input frame is an `f64` buffer (in whatever ADU domain the normalizer left
//! it in) plus a scalar weight and an optional per-pixel
//! [`crate::normalization::CoverageMask`] describing which pixels actually had
//! valid source support after the warp (edges that only some frames cover).
//!
//! ## Outputs
//!
//! [`integrate_frames`] returns:
//!
//! - the integrated **master** ([`ImageData`], `F32` linear by default, the
//!   archival format, or `U16` when a caller wants the legacy 16-bit path);
//! - a per-pixel **rejection-count map** (how many samples were rejected at
//!   each output pixel — this is where satellite trails, planes, and cosmic
//!   rays light up);
//! - a per-pixel **effective-weight map** (the sum of the weights that actually
//!   contributed to each output pixel — a coverage/SNR diagnostic);
//! - aggregate [`IntegrationStats`].
//!
//! All maps and the master are computed **per channel** so OSC (3-channel)
//! masters reject and weight each channel independently — a hot red pixel must
//! not drag the green and blue channels with it.
//!
//! ## Limitations
//!
//! The *algorithms* here are deterministic, order-independent, and unit-tested
//! against synthetic data with injected outliers. The default sigma thresholds
//! (`low`/`high`) are defensible PixInsight-spirit defaults but are exposed as
//! knobs precisely because their sweet spot depends on sub count and data; the
//! caller (and ultimately the UI) picks the rejector and thresholds. Linear-fit
//! clipping here is the standard "fit a line to the *sorted* samples, reject by
//! residual" formulation; like every batch rejector it degrades gracefully to
//! the plain weighted mean when there are too few samples to estimate scatter.

use crate::normalization::CoverageMask;
use crate::robust_stats::{median_sorted as median_of_sorted, MAD_TO_SIGMA};
use crate::{ImageData, PixelType};
use rayon::prelude::*;

// Public configuration types

/// How the surviving (non-rejected) samples are combined into the output pixel.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Combine {
    /// Weighted arithmetic mean of the survivors. The maximum-likelihood
    /// estimator for Gaussian noise and the highest-SNR choice once outliers
    /// have been rejected — the default for stacks.
    #[default]
    Mean,
    /// Unweighted median of the survivors. Maximally robust but ~25% noisier
    /// than the mean for Gaussian data; useful as a sanity reference or for
    /// tiny stacks where rejection is not yet reliable.
    Median,
}

/// Which pixel-rejection algorithm runs over each per-pixel sample column
/// *before* combination. Every variant operates on the **full batch** of
/// samples for a pixel (not online), which is the whole point of this module.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Reject {
    /// No rejection — straight weighted combine of every covered sample.
    None,
    /// Classic iterated sigma clipping: drop samples more than `low`·σ below or
    /// `high`·σ above the (weighted) mean, recompute, repeat to convergence.
    /// The batch analogue of the live stacker's online clip.
    SigmaClip { low: f64, high: f64 },
    /// Winsorized sigma clipping: instead of *dropping* outliers when measuring
    /// scatter, *clamp* them to the current `±kσ` bound, then measure σ on the
    /// Winsorized set. This stabilises the σ estimate against the very outliers
    /// it is trying to find, so it does not need as many iterations and does not
    /// over-reject the wings. A robust default for ≳15 subs.
    WinsorizedSigmaClip { low: f64, high: f64 },
    /// Linear-fit clipping: sort the samples, fit a straight line to
    /// (rank, value), and reject samples whose residual from that line exceeds
    /// `low`/`high` × the residual scatter. On a clean pixel the sorted samples
    /// lie on a gentle line, so genuine outliers (which break the monotone trend
    /// at the ends) are rejected hard while the bulk is kept — PixInsight's
    /// best-for-many-subs algorithm.
    LinearFitClip { low: f64, high: f64 },
    /// Percentile clipping: reject samples below the `low` or above the `high`
    /// fractional percentile of the column (relative to the median). Best for
    /// few subs (<8) where σ is too poorly determined for sigma clipping.
    /// `low`/`high` are fractions in `(0, 1)` (e.g. `0.2` = trim the lowest
    /// 20% deviation band).
    PercentileClip { low: f64, high: f64 },
    /// Min/max clipping: unconditionally drop the `n_low` smallest and `n_high`
    /// largest samples. Crude but predictable; handy when exactly one hot frame
    /// is known to exist.
    MinMax { n_low: usize, n_high: usize },
}

impl Default for Reject {
    fn default() -> Self {
        Reject::WinsorizedSigmaClip {
            low: 3.0,
            high: 3.0,
        }
    }
}

impl Reject {
    /// Maximum iterations for the iterated rejectors. Kept small because all of
    /// them converge fast (each iteration only removes the extreme tails).
    const MAX_ITERATIONS: usize = 8;
}

/// Tunables for [`integrate_frames`]. [`Default`] is a quality-first archival
/// integration: F32 master, weighted mean, Winsorized-σ rejection, all maps on.
#[derive(Debug, Clone)]
pub struct IntegrationConfig {
    /// How survivors are combined.
    pub combine: Combine,
    /// Which rejection algorithm runs per pixel.
    pub reject: Reject,
    /// Output pixel type. `F32` keeps the master linear and unquantised (the
    /// archival default); `U16` rescales into 16-bit for the legacy viewer path.
    pub output_type: PixelType,
    /// Emit the per-pixel rejection-count map.
    pub generate_rejection_map: bool,
    /// Emit the per-pixel effective-weight (coverage) map.
    pub generate_weight_map: bool,
    /// A pixel must have at least this many covered samples to be integrated;
    /// below it the output pixel is set to 0 (uncovered). 1 = integrate
    /// anything covered by even a single frame.
    pub min_coverage: usize,
}

impl Default for IntegrationConfig {
    fn default() -> Self {
        Self {
            combine: Combine::Mean,
            reject: Reject::default(),
            output_type: PixelType::F32,
            generate_rejection_map: true,
            generate_weight_map: true,
            min_coverage: 1,
        }
    }
}

/// One frame's contribution to the integration: its pixel buffer, scalar
/// weight, and which pixels it actually covers.
///
/// `pixels` is row-major, channel-interleaved exactly like [`ImageData`] (i.e.
/// for a 3-channel frame the layout is `[r,g,b, r,g,b, …]`), in `f64`. The
/// coverage mask is **per pixel location** (one entry per `width × height`,
/// *not* per channel) because warp coverage is a geometric property shared by
/// all channels of a frame.
#[derive(Debug, Clone)]
pub struct IntegrationFrame<'a> {
    /// Aligned, normalized pixel buffer (`width × height × channels`, f64).
    pub pixels: &'a [f64],
    /// Scalar quality weight (> 0). Frames with weight ≤ 0 are ignored.
    pub weight: f64,
    /// Optional per-location coverage mask. `None` ⇒ every pixel is covered.
    pub coverage: Option<&'a CoverageMask>,
}

/// Aggregate statistics for an integration run.
#[derive(Debug, Clone, PartialEq)]
pub struct IntegrationStats {
    /// Number of input frames that actually contributed (weight > 0).
    pub frames_integrated: usize,
    /// Mean of the contributing frames' weights.
    pub mean_weight: f64,
    /// Total samples considered across every covered pixel (Σ coverage).
    pub total_samples: u64,
    /// Total samples rejected across every pixel.
    pub total_rejected: u64,
    /// Fraction of considered samples that were rejected, in `[0, 1]`.
    pub rejection_fraction: f64,
    /// Output pixel locations that ended up below `min_coverage` (set to 0).
    pub uncovered_pixels: u64,
}

/// The complete result of [`integrate_frames`].
#[derive(Debug, Clone)]
pub struct IntegrationOutput {
    /// The integrated master, `output_type` from the config.
    pub master: ImageData,
    /// Per-pixel rejection-count map (`F32`, one channel per master channel),
    /// or `None` when `generate_rejection_map` was false. Each value is the
    /// number of samples rejected at that pixel/channel.
    pub rejection_map: Option<ImageData>,
    /// Per-pixel effective-weight map (`F32`, one channel per master channel),
    /// or `None` when `generate_weight_map` was false. Each value is the sum of
    /// the weights that survived rejection at that pixel/channel.
    pub weight_map: Option<ImageData>,
    /// Aggregate statistics.
    pub stats: IntegrationStats,
}

/// Errors from [`integrate_frames`]. Every variant is a *caller* mistake the
/// module refuses to paper over (an empty population, mismatched frame
/// dimensions, an oversized coverage mask) — never a silent best-effort stack
/// on inconsistent input.
#[derive(Debug, thiserror::Error, PartialEq)]
pub enum IntegrationError {
    #[error("no frames to integrate")]
    NoFrames,
    #[error("no frame had a positive weight")]
    NoWeightedFrames,
    #[error("frame dimensions must be > 0")]
    ZeroDimension,
    #[error(
        "frame {index} has {got} pixels but the integration expects {expected} (= width × height × channels)"
    )]
    FrameSizeMismatch {
        index: usize,
        got: usize,
        expected: usize,
    },
    #[error("frame {index} coverage mask is {mask} px but the frame is {expected} px")]
    CoverageSizeMismatch {
        index: usize,
        mask: usize,
        expected: usize,
    },
    #[error("output pixel type {0:?} is not supported; use F32 or U16")]
    UnsupportedOutputType(PixelType),
}

// Public entry point

/// Integrate a population of aligned, normalized, weighted frames into a single
/// master with per-pixel rejection.
///
/// `width`/`height`/`channels` describe the common reference grid that every
/// `frame.pixels` buffer must conform to. The combination runs **per channel**
/// over the full per-pixel sample column, applies the configured [`Reject`]
/// algorithm, then the configured [`Combine`] over the survivors, weighting by
/// each frame's scalar weight.
///
/// Returns an error (rather than a degraded stack) if the population is empty,
/// no frame has positive weight, or any frame's buffer / coverage mask does not
/// match the declared grid.
pub fn integrate_frames(
    frames: &[IntegrationFrame<'_>],
    width: u32,
    height: u32,
    channels: u32,
    config: &IntegrationConfig,
) -> Result<IntegrationOutput, IntegrationError> {
    let columns = integrate_columns(
        frames,
        width,
        height,
        channels,
        config,
        Reject::MAX_ITERATIONS,
    )?;

    let master = finalize_master(&columns.master, width, height, channels, config.output_type);
    let rejection_map = columns
        .rejection
        .map(|r| ImageData::from_f32(width, height, channels, &r));
    let weight_map = columns
        .weight_map
        .map(|r| ImageData::from_f32(width, height, channels, &r));

    Ok(IntegrationOutput {
        master,
        rejection_map,
        weight_map,
        stats: columns.stats,
    })
}

/// The integration result before it is quantised into an [`ImageData`].
///
/// Why this exists: [`crate::stacking::combine_master_frames`] normalises a
/// master flat by its own mean and must do that in `f64`, before any rounding.
/// Handing it the finalised `F32`/`U16` master would make it normalise
/// already-quantised values.
pub(crate) struct IntegratedColumns {
    /// Integrated pixel values, interleaved like [`ImageData`], in `f64`.
    pub(crate) master: Vec<f64>,
    pub(crate) rejection: Option<Vec<f32>>,
    pub(crate) weight_map: Option<Vec<f32>>,
    pub(crate) stats: IntegrationStats,
}

/// Integrate into raw `f64` columns.
///
/// `iteration_limit` bounds the iterated rejectors. [`integrate_frames`] passes
/// [`Reject::MAX_ITERATIONS`]; `combine_master_frames` passes the iteration
/// count its caller configured, which is part of its public contract.
pub(crate) fn integrate_columns(
    frames: &[IntegrationFrame<'_>],
    width: u32,
    height: u32,
    channels: u32,
    config: &IntegrationConfig,
    iteration_limit: usize,
) -> Result<IntegratedColumns, IntegrationError> {
    if frames.is_empty() {
        return Err(IntegrationError::NoFrames);
    }
    if width == 0 || height == 0 || channels == 0 {
        return Err(IntegrationError::ZeroDimension);
    }
    if !matches!(config.output_type, PixelType::F32 | PixelType::U16) {
        return Err(IntegrationError::UnsupportedOutputType(config.output_type));
    }

    let w = width as usize;
    let h = height as usize;
    let c = channels as usize;
    let locations = w * h;
    let expected_len = locations * c;

    // Validate every frame's geometry up front so the per-pixel loop can index
    // without bounds anxiety (and so the caller gets a precise error, not a
    // panic deep inside rayon).
    for (i, f) in frames.iter().enumerate() {
        if f.pixels.len() != expected_len {
            return Err(IntegrationError::FrameSizeMismatch {
                index: i,
                got: f.pixels.len(),
                expected: expected_len,
            });
        }
        if let Some(mask) = f.coverage {
            let mask_len = mask.width() * mask.height();
            if mask_len != locations {
                return Err(IntegrationError::CoverageSizeMismatch {
                    index: i,
                    mask: mask_len,
                    expected: locations,
                });
            }
        }
    }

    // Keep only the frames that can contribute. A non-positive weight means the
    // weighting stage already decided the frame is worthless; including it with
    // weight 0 would just add coverage noise.
    let contributing: Vec<&IntegrationFrame<'_>> =
        frames.iter().filter(|f| f.weight > 0.0).collect();
    if contributing.is_empty() {
        return Err(IntegrationError::NoWeightedFrames);
    }

    let frames_integrated = contributing.len();
    let mean_weight = contributing.iter().map(|f| f.weight).sum::<f64>() / frames_integrated as f64;

    // Output buffers (per channel interleaved, matching ImageData layout).
    let mut master = vec![0.0f64; expected_len];
    let mut rejection = if config.generate_rejection_map {
        Some(vec![0.0f32; expected_len])
    } else {
        None
    };
    let mut weight_map = if config.generate_weight_map {
        Some(vec![0.0f32; expected_len])
    } else {
        None
    };

    // The work is embarrassingly parallel over output rows. Each row-task
    // gathers, for every pixel/channel it owns, the column of samples across all
    // contributing frames and runs the full rejector + combiner. We parallelise
    // over rows (not pixels) so the reusable sample scratch buffer is amortised
    // across a whole row, and each task writes a contiguous, disjoint output
    // slice — no locking. Output order is (y, x, channel), interleaved exactly
    // like the final `ImageData` buffer.
    let row_stride = w * c;
    let mut outcomes: Vec<ColumnOutcome> = vec![ColumnOutcome::default(); expected_len];
    outcomes
        .par_chunks_mut(row_stride)
        .enumerate()
        .for_each(|(y, row_out)| {
            let mut samples: Vec<Sample> = Vec::with_capacity(frames_integrated);
            // Holds the pre-rejection column so a rejector that rejects
            // *everything* can be undone; see `combine_column`.
            let mut intact: Vec<Sample> = Vec::with_capacity(frames_integrated);
            for x in 0..w {
                let loc = y * w + x;
                for ch in 0..c {
                    samples.clear();
                    for f in &contributing {
                        // Coverage is per location, shared across all channels.
                        let covered = f.coverage.map(|m| m.is_valid_at(loc)).unwrap_or(true);
                        if !covered {
                            continue;
                        }
                        let v = f.pixels[loc * c + ch];
                        if !v.is_finite() {
                            continue;
                        }
                        samples.push(Sample {
                            value: v,
                            weight: f.weight,
                        });
                    }
                    row_out[x * c + ch] =
                        combine_column(&mut samples, &mut intact, config, iteration_limit);
                }
            }
        });

    // `outcomes` is in (y, x, channel) order: for each location, `c` entries.
    // Scatter into the interleaved output buffers.
    let mut total_samples: u64 = 0;
    let mut total_rejected: u64 = 0;
    let mut uncovered_pixels: u64 = 0;
    for loc in 0..locations {
        let mut any_covered = false;
        for ch in 0..c {
            let o = outcomes[loc * c + ch];
            master[loc * c + ch] = o.value;
            if let Some(r) = rejection.as_mut() {
                r[loc * c + ch] = o.rejected as f32;
            }
            if let Some(wm) = weight_map.as_mut() {
                wm[loc * c + ch] = o.survived_weight as f32;
            }
            total_samples += o.considered as u64;
            total_rejected += o.rejected as u64;
            any_covered |= o.covered;
        }
        if !any_covered {
            uncovered_pixels += 1;
        }
    }

    let rejection_fraction = if total_samples == 0 {
        0.0
    } else {
        total_rejected as f64 / total_samples as f64
    };

    let stats = IntegrationStats {
        frames_integrated,
        mean_weight,
        total_samples,
        total_rejected,
        rejection_fraction,
        uncovered_pixels,
    };

    Ok(IntegratedColumns {
        master,
        rejection,
        weight_map,
        stats,
    })
}

// Per-pixel column combination

/// One weighted sample for a single output pixel/channel.
#[derive(Debug, Clone, Copy)]
struct Sample {
    value: f64,
    weight: f64,
}

/// Outcome of combining one pixel/channel column: the integrated value plus the
/// bookkeeping that feeds the rejection/weight maps and the aggregate stats.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
struct ColumnOutcome {
    /// Integrated pixel value (0 when the pixel was below `min_coverage`).
    value: f64,
    /// Number of samples rejected by the rejection algorithm.
    rejected: u32,
    /// Number of covered, finite samples the column started with.
    considered: u32,
    /// Sum of the weights that survived rejection (the effective-weight map).
    survived_weight: f64,
    /// Whether the pixel had enough coverage to be integrated at all.
    covered: bool,
}

/// Run the configured rejection + combination over one pixel's sample column.
///
/// `samples` and `intact` are scratch owned by the caller (reused across
/// pixels). Both are left in an unspecified order on return.
///
/// Total rejection: a threshold tighter than 1σ (or a percentile band that
/// excludes the median) can reject *every* sample in a column. Combining an
/// empty column yields 0.0 — a black pixel in the middle of the master, which
/// is worse than any estimate the column could have given. When that happens
/// the column is restored from `intact` and reduced with the median, the
/// robust estimator that suits a column where everything looked like an
/// outlier, and the pixel is reported as having rejected nothing.
fn combine_column(
    samples: &mut Vec<Sample>,
    intact: &mut Vec<Sample>,
    config: &IntegrationConfig,
    iteration_limit: usize,
) -> ColumnOutcome {
    let considered = samples.len() as u32;
    if samples.is_empty() || samples.len() < config.min_coverage {
        return ColumnOutcome {
            value: 0.0,
            rejected: 0,
            considered,
            survived_weight: 0.0,
            covered: false,
        };
    }

    let rejects = !matches!(config.reject, Reject::None);
    if rejects {
        intact.clear();
        intact.extend_from_slice(samples);
    }

    let mut rejected_count = apply_rejection(samples, config.reject, iteration_limit);
    if samples.is_empty() {
        samples.extend_from_slice(intact);
        rejected_count = 0;
        let value = median(samples);
        let survived_weight: f64 = samples.iter().map(|s| s.weight).sum();
        return ColumnOutcome {
            value,
            rejected: rejected_count,
            considered,
            survived_weight,
            covered: true,
        };
    }

    let value = match config.combine {
        Combine::Mean => weighted_mean(samples),
        Combine::Median => median(samples),
    };
    let survived_weight: f64 = samples.iter().map(|s| s.weight).sum();

    ColumnOutcome {
        value,
        rejected: rejected_count,
        considered,
        survived_weight,
        covered: true,
    }
}

/// Apply the rejection algorithm in place, retaining only survivors in
/// `samples`. Returns the number of samples rejected.
fn apply_rejection(samples: &mut Vec<Sample>, reject: Reject, iteration_limit: usize) -> u32 {
    let before = samples.len();
    match reject {
        Reject::None => {}
        Reject::SigmaClip { low, high } => sigma_clip(samples, low, high, false, iteration_limit),
        Reject::WinsorizedSigmaClip { low, high } => {
            sigma_clip(samples, low, high, true, iteration_limit)
        }
        Reject::LinearFitClip { low, high } => linear_fit_clip(samples, low, high, iteration_limit),
        Reject::PercentileClip { low, high } => percentile_clip(samples, low, high),
        Reject::MinMax { n_low, n_high } => min_max_clip(samples, n_low, n_high),
    }
    (before - samples.len()) as u32
}

// Rejection algorithms (batch, order-independent)

/// Iterated sigma clipping. When `winsorize` is true the σ estimate is computed
/// on the *Winsorized* set (outliers clamped to the current bound) rather than
/// the raw set, which stabilises σ against the very outliers it is hunting.
///
/// The mean used for the clip is **weighted** so a high-weight sub's value is
/// trusted more when deciding where the population centre lies. Variance is
/// likewise weighted (reliability-weighted unbiased variance) so the σ
/// threshold scales with the trusted scatter.
fn sigma_clip(
    samples: &mut Vec<Sample>,
    low: f64,
    high: f64,
    winsorize: bool,
    iteration_limit: usize,
) {
    for _ in 0..iteration_limit {
        if samples.len() < 3 {
            // Cannot estimate scatter meaningfully; stop clipping.
            break;
        }
        let (mean, sigma) = if winsorize {
            winsorized_mean_sigma(samples, low, high)
        } else {
            weighted_mean_sigma(samples)
        };
        if sigma <= 0.0 {
            // Degenerate (all equal); nothing to clip.
            break;
        }
        let lo = mean - low * sigma;
        let hi = mean + high * sigma;
        let before = samples.len();
        samples.retain(|s| s.value >= lo && s.value <= hi);
        if samples.len() == before || samples.len() < 3 {
            break;
        }
    }
}

/// Linear-fit clipping. Sort the samples ascending, fit `value ≈ a·rank + b`
/// by ordinary least squares, then reject samples whose residual from the line
/// is below `−low·σ_resid` or above `+high·σ_resid`, iterating until stable.
///
/// On a clean Gaussian column the order statistics increase smoothly, so the
/// line fit captures the bulk and the residual scatter is small; a single bright
/// outlier sits far off the line at the top rank and is rejected without
/// dragging the threshold the way it would in a plain mean/σ. This is the batch
/// rejector that performs best with many subs.
fn linear_fit_clip(samples: &mut Vec<Sample>, low: f64, high: f64, iteration_limit: usize) {
    for _ in 0..iteration_limit {
        let n = samples.len();
        if n < 4 {
            break;
        }
        samples.sort_by(|a, b| {
            a.value
                .partial_cmp(&b.value)
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        // OLS fit of value against rank index (0..n-1).
        let nf = n as f64;
        let sum_x = (0..n).map(|i| i as f64).sum::<f64>();
        let sum_y = samples.iter().map(|s| s.value).sum::<f64>();
        let mean_x = sum_x / nf;
        let mean_y = sum_y / nf;
        let mut sxx = 0.0;
        let mut sxy = 0.0;
        for (i, s) in samples.iter().enumerate() {
            let dx = i as f64 - mean_x;
            sxx += dx * dx;
            sxy += dx * (s.value - mean_y);
        }
        if sxx <= 0.0 {
            break;
        }
        let slope = sxy / sxx;
        let intercept = mean_y - slope * mean_x;

        // Residual scatter (RMS) of the fit.
        let mut sum_r2 = 0.0;
        for (i, s) in samples.iter().enumerate() {
            let pred = slope * i as f64 + intercept;
            let r = s.value - pred;
            sum_r2 += r * r;
        }
        let sigma = (sum_r2 / nf).sqrt();
        if sigma <= 0.0 {
            break;
        }

        let before = samples.len();
        // Re-derive predictions during retain via an index counter; samples are
        // still sorted so ranks correspond to position.
        let mut idx = 0usize;
        samples.retain(|s| {
            let pred = slope * idx as f64 + intercept;
            let r = s.value - pred;
            idx += 1;
            r >= -low * sigma && r <= high * sigma
        });
        if samples.len() == before || samples.len() < 4 {
            break;
        }
    }
}

/// Percentile clipping. Reject samples whose deviation from the median exceeds
/// the `low`/`high` fractional band of the median (relative deviation). Best for
/// small stacks where σ is unreliable. `low`/`high` are fractions in `(0, 1]`.
fn percentile_clip(samples: &mut Vec<Sample>, low: f64, high: f64) {
    if samples.len() < 3 {
        return;
    }
    let med = median(samples);
    // Guard against a zero median (e.g. a pure-zero background column): fall
    // back to an absolute band derived from the sample spread so we still
    // reject the obvious outliers instead of dividing by zero.
    let scale = if med.abs() > f64::EPSILON {
        med.abs()
    } else {
        let max = samples.iter().map(|s| s.value.abs()).fold(0.0f64, f64::max);
        if max <= 0.0 {
            return;
        }
        max
    };
    let lo = med - low * scale;
    let hi = med + high * scale;
    samples.retain(|s| s.value >= lo && s.value <= hi);
}

/// Min/max clipping: drop the `n_low` smallest and `n_high` largest samples.
fn min_max_clip(samples: &mut Vec<Sample>, n_low: usize, n_high: usize) {
    let n = samples.len();
    if n_low + n_high >= n {
        // Would reject everything; fall through keeping the full column intact
        // (reject nothing) so the pixel is not left empty. Rejecting nothing is
        // the honest choice over emptying the column on a misconfigured
        // n_low/n_high.
        return;
    }
    samples.sort_by(|a, b| {
        a.value
            .partial_cmp(&b.value)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    // Retain the middle window [n_low, n - n_high).
    let keep: Vec<Sample> = samples[n_low..n - n_high].to_vec();
    *samples = keep;
}

// Estimators

/// Reliability-weighted mean of the samples. Returns 0 for an empty set.
fn weighted_mean(samples: &[Sample]) -> f64 {
    let mut sw = 0.0;
    let mut swx = 0.0;
    for s in samples {
        sw += s.weight;
        swx += s.weight * s.value;
    }
    if sw <= 0.0 {
        // All-zero weights shouldn't reach here (filtered earlier), but be safe.
        if samples.is_empty() {
            0.0
        } else {
            samples.iter().map(|s| s.value).sum::<f64>() / samples.len() as f64
        }
    } else {
        swx / sw
    }
}

/// Unweighted median (mutates order). Used by [`Combine::Median`] and by the
/// percentile rejector.
fn median(samples: &mut [Sample]) -> f64 {
    let n = samples.len();
    if n == 0 {
        return 0.0;
    }
    samples.sort_by(|a, b| {
        a.value
            .partial_cmp(&b.value)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    if n % 2 == 1 {
        samples[n / 2].value
    } else {
        (samples[n / 2 - 1].value + samples[n / 2].value) * 0.5
    }
}

/// Reliability-weighted mean and standard deviation of the samples. The
/// variance is the weighted unbiased (reliability-weights) estimator:
/// `σ² = Σwᵢ(xᵢ−μ)² / (Σwᵢ − Σwᵢ²/Σwᵢ)`. Falls back to the plain mean/σ when the
/// effective sample size is too small.
fn weighted_mean_sigma(samples: &[Sample]) -> (f64, f64) {
    let mut sw = 0.0;
    let mut sw2 = 0.0;
    let mut swx = 0.0;
    for s in samples {
        sw += s.weight;
        sw2 += s.weight * s.weight;
        swx += s.weight * s.value;
    }
    if sw <= 0.0 {
        return (0.0, 0.0);
    }
    let mean = swx / sw;
    let denom = sw - sw2 / sw;
    if denom <= 0.0 {
        // Effective sample size ~1; report mean with zero scatter (no clip).
        return (mean, 0.0);
    }
    let mut num = 0.0;
    for s in samples {
        let d = s.value - mean;
        num += s.weight * d * d;
    }
    let var = num / denom;
    (mean, var.max(0.0).sqrt())
}

/// Winsorized weighted mean/σ: clamp every sample into `[μ − low·σ, μ + high·σ]`
/// (using a robust MAD-based initial σ around the median) and recompute the
/// weighted mean/σ on the clamped set. This yields a scatter estimate that is
/// not inflated by the outliers, so the subsequent clip threshold is honest.
fn winsorized_mean_sigma(samples: &[Sample], low: f64, high: f64) -> (f64, f64) {
    // Robust initial centre/scale from the median + MAD so the Winsorizing
    // bounds are not themselves corrupted by the outliers.
    let mut vals: Vec<f64> = samples.iter().map(|s| s.value).collect();
    vals.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let med = median_of_sorted(&vals);
    let mut devs: Vec<f64> = vals.iter().map(|v| (v - med).abs()).collect();
    devs.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let mad = median_of_sorted(&devs);
    let mut robust_sigma = mad * MAD_TO_SIGMA;
    if robust_sigma <= 0.0 {
        // The MAD collapses to zero whenever more than half the samples share
        // the median value — the classic "flat bulk + a few spikes" cosmic-ray
        // column. A *plain* σ would be inflated by those very spikes (so they
        // survive their own clip), which is exactly what Winsorizing exists to
        // avoid. Fall back instead to the **mean** absolute deviation, which is
        // non-zero as long as any sample differs from the median, giving a
        // small-but-honest scale that lets the spikes be clipped. Only when the
        // column is *truly* degenerate (every sample equal ⇒ mean dev 0) do we
        // report zero scatter and clip nothing.
        let mean_abs_dev = devs.iter().sum::<f64>() / devs.len().max(1) as f64;
        robust_sigma = mean_abs_dev * MAD_TO_SIGMA;
        if robust_sigma <= 0.0 {
            return weighted_mean_sigma(samples);
        }
    }

    let lo = med - low * robust_sigma;
    let hi = med + high * robust_sigma;
    let winsorized: Vec<Sample> = samples
        .iter()
        .map(|s| Sample {
            value: s.value.clamp(lo, hi),
            weight: s.weight,
        })
        .collect();
    weighted_mean_sigma(&winsorized)
}

// Output finalization

/// Pack the f64 accumulator into the requested output [`ImageData`]. For `F32`
/// the linear values are stored verbatim (archival, no quantisation). For `U16`
/// the values are clamped into `[0, 65535]` (the caller is responsible for
/// having normalized into ADU range; we do not auto-stretch here).
fn finalize_master(
    master: &[f64],
    width: u32,
    height: u32,
    channels: u32,
    output_type: PixelType,
) -> ImageData {
    match output_type {
        PixelType::F32 => {
            let data: Vec<f32> = master.par_iter().map(|&v| v as f32).collect();
            ImageData::from_f32(width, height, channels, &data)
        }
        PixelType::U16 => {
            let data: Vec<u16> = master
                .par_iter()
                .map(|&v| v.round().clamp(0.0, 65535.0) as u16)
                .collect();
            ImageData::from_u16(width, height, channels, &data)
        }
        // integrate_frames already rejected anything else; unreachable in
        // practice but mapped to F32 to keep the function total.
        _ => {
            let data: Vec<f32> = master.iter().map(|&v| v as f32).collect();
            ImageData::from_f32(width, height, channels, &data)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build an [`IntegrationFrame`] borrowing a buffer, full coverage.
    fn frame<'a>(pixels: &'a [f64], weight: f64) -> IntegrationFrame<'a> {
        IntegrationFrame {
            pixels,
            weight,
            coverage: None,
        }
    }

    /// A tiny deterministic LCG so noise injection is reproducible in tests
    /// (mirrors the crate's existing test-noise idiom in `stacking.rs`).
    struct Lcg(u64);
    impl Lcg {
        fn next_f64(&mut self) -> f64 {
            self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1);
            // top 53 bits → [0, 1)
            (self.0 >> 11) as f64 / (1u64 << 53) as f64
        }
        /// Approximately-Gaussian deviate via the central-limit sum of 12
        /// uniforms (mean 0, σ ≈ 1).
        fn next_gauss(&mut self) -> f64 {
            let s: f64 = (0..12).map(|_| self.next_f64()).sum();
            s - 6.0
        }
    }

    // Weighted-mean correctness vs. analytic

    #[test]
    fn weighted_mean_matches_analytic_with_no_rejection() {
        // Single 1x1 mono pixel, three frames with distinct values + weights.
        // Analytic weighted mean = Σwx / Σw.
        let f0 = [10.0];
        let f1 = [20.0];
        let f2 = [30.0];
        let frames = [frame(&f0, 1.0), frame(&f1, 2.0), frame(&f2, 3.0)];
        let cfg = IntegrationConfig {
            reject: Reject::None,
            ..Default::default()
        };
        let out = integrate_frames(&frames, 1, 1, 1, &cfg).unwrap();
        let master = out.master.as_f32().unwrap();
        let analytic = (1.0 * 10.0 + 2.0 * 20.0 + 3.0 * 30.0) / (1.0 + 2.0 + 3.0);
        assert!(
            (master[0] as f64 - analytic).abs() < 1e-4,
            "weighted mean {} != analytic {}",
            master[0],
            analytic
        );
        assert_eq!(out.stats.frames_integrated, 3);
        assert_eq!(out.stats.total_rejected, 0);
    }

    #[test]
    fn equal_weights_reduce_to_arithmetic_mean() {
        let f0 = [4.0];
        let f1 = [8.0];
        let f2 = [12.0];
        let frames = [frame(&f0, 1.0), frame(&f1, 1.0), frame(&f2, 1.0)];
        let cfg = IntegrationConfig {
            reject: Reject::None,
            ..Default::default()
        };
        let out = integrate_frames(&frames, 1, 1, 1, &cfg).unwrap();
        let master = out.master.as_f32().unwrap();
        assert!((master[0] as f64 - 8.0).abs() < 1e-4);
    }

    // Outlier rejection (each algorithm) + rejection-map correctness

    /// Build a column of `n` frames all equal to `base` except one spike, for a
    /// single 1x1 mono pixel. Returns the owned per-frame buffers.
    fn spiked_column(n: usize, base: f64, spike: f64) -> Vec<Vec<f64>> {
        let mut v: Vec<Vec<f64>> = (0..n).map(|_| vec![base]).collect();
        v[n / 2][0] = spike;
        v
    }

    #[test]
    fn sigma_clip_rejects_single_bright_outlier() {
        let bufs = spiked_column(20, 100.0, 5000.0);
        let frames: Vec<_> = bufs.iter().map(|b| frame(b, 1.0)).collect();
        let cfg = IntegrationConfig {
            reject: Reject::SigmaClip {
                low: 3.0,
                high: 3.0,
            },
            ..Default::default()
        };
        let out = integrate_frames(&frames, 1, 1, 1, &cfg).unwrap();
        let master = out.master.as_f32().unwrap();
        assert!(
            (master[0] as f64 - 100.0).abs() < 1e-3,
            "spike should be clipped, got {}",
            master[0]
        );
        // Rejection map must record exactly one rejected sample at this pixel.
        let rej = out.rejection_map.unwrap().as_f32().unwrap();
        assert_eq!(rej[0] as u32, 1);
        assert_eq!(out.stats.total_rejected, 1);
    }

    #[test]
    fn winsorized_sigma_clip_rejects_outlier_and_is_default() {
        let bufs = spiked_column(20, 200.0, 9000.0);
        let frames: Vec<_> = bufs.iter().map(|b| frame(b, 1.0)).collect();
        // Use the Default config (Winsorized-σ) to also pin the default.
        let cfg = IntegrationConfig::default();
        assert!(matches!(cfg.reject, Reject::WinsorizedSigmaClip { .. }));
        let out = integrate_frames(&frames, 1, 1, 1, &cfg).unwrap();
        let master = out.master.as_f32().unwrap();
        assert!(
            (master[0] as f64 - 200.0).abs() < 1e-3,
            "winsorized clip should reject spike, got {}",
            master[0]
        );
        let rej = out.rejection_map.unwrap().as_f32().unwrap();
        assert_eq!(rej[0] as u32, 1);
    }

    #[test]
    fn linear_fit_clip_rejects_outlier() {
        let bufs = spiked_column(30, 500.0, 20000.0);
        let frames: Vec<_> = bufs.iter().map(|b| frame(b, 1.0)).collect();
        let cfg = IntegrationConfig {
            reject: Reject::LinearFitClip {
                low: 3.0,
                high: 3.0,
            },
            ..Default::default()
        };
        let out = integrate_frames(&frames, 1, 1, 1, &cfg).unwrap();
        let master = out.master.as_f32().unwrap();
        assert!(
            (master[0] as f64 - 500.0).abs() < 1e-3,
            "linear-fit clip should reject spike, got {}",
            master[0]
        );
        let rej = out.rejection_map.unwrap().as_f32().unwrap();
        assert_eq!(rej[0] as u32, 1);
    }

    #[test]
    fn percentile_clip_rejects_extremes_in_small_stack() {
        // 6 subs: 4 near 100, one low, one high. Percentile clip is the
        // recommended rejector for few subs.
        let b: Vec<Vec<f64>> = vec![
            vec![100.0],
            vec![102.0],
            vec![98.0],
            vec![101.0],
            vec![10.0],  // low outlier
            vec![400.0], // high outlier
        ];
        let frames: Vec<_> = b.iter().map(|x| frame(x, 1.0)).collect();
        let cfg = IntegrationConfig {
            reject: Reject::PercentileClip {
                low: 0.3,
                high: 0.3,
            },
            ..Default::default()
        };
        let out = integrate_frames(&frames, 1, 1, 1, &cfg).unwrap();
        let master = out.master.as_f32().unwrap();
        // After rejecting 10 and 400, the mean of the survivors is ~100.
        assert!(
            (master[0] as f64 - 100.0).abs() < 5.0,
            "percentile clip should drop both extremes, got {}",
            master[0]
        );
        assert!(out.stats.total_rejected >= 2);
    }

    #[test]
    fn min_max_clip_drops_exact_counts() {
        // 10 samples 1..=10; drop 1 low + 2 high → keep 2..=8, mean = 5.0.
        let bufs: Vec<Vec<f64>> = (1..=10).map(|i| vec![i as f64]).collect();
        let frames: Vec<_> = bufs.iter().map(|b| frame(b, 1.0)).collect();
        let cfg = IntegrationConfig {
            reject: Reject::MinMax {
                n_low: 1,
                n_high: 2,
            },
            ..Default::default()
        };
        let out = integrate_frames(&frames, 1, 1, 1, &cfg).unwrap();
        let master = out.master.as_f32().unwrap();
        // survivors = 2,3,4,5,6,7,8 → mean 5.0
        assert!((master[0] as f64 - 5.0).abs() < 1e-4, "got {}", master[0]);
        let rej = out.rejection_map.unwrap().as_f32().unwrap();
        assert_eq!(rej[0] as u32, 3);
    }

    #[test]
    fn min_max_clip_refuses_to_empty_a_column() {
        // n_low + n_high >= n must keep the column rather than emptying it.
        let bufs: Vec<Vec<f64>> = (1..=4).map(|i| vec![i as f64]).collect();
        let frames: Vec<_> = bufs.iter().map(|b| frame(b, 1.0)).collect();
        let cfg = IntegrationConfig {
            reject: Reject::MinMax {
                n_low: 2,
                n_high: 2,
            },
            ..Default::default()
        };
        let out = integrate_frames(&frames, 1, 1, 1, &cfg).unwrap();
        // Nothing rejected (safety floor), so the value is the full mean = 2.5.
        let master = out.master.as_f32().unwrap();
        assert!((master[0] as f64 - 2.5).abs() < 1e-4, "got {}", master[0]);
        assert_eq!(out.stats.total_rejected, 0);
    }

    // Rejection map localises the outlier to the right pixel

    #[test]
    fn rejection_map_localises_a_satellite_trail_pixel() {
        // 2x1 mono image, 10 frames. Pixel 0 is clean; pixel 1 has a trail hit
        // in one frame. Only pixel 1 should show a rejection.
        let w = 2u32;
        let h = 1u32;
        let n = 10;
        let mut bufs: Vec<Vec<f64>> = (0..n).map(|_| vec![300.0, 300.0]).collect();
        bufs[4][1] = 60000.0; // trail clips pixel 1 in frame 4
        let frames: Vec<_> = bufs.iter().map(|b| frame(b, 1.0)).collect();
        // Winsorized-σ is the realistic rejector here: a single extreme outlier
        // in a small (n=10) column inflates a *plain* σ so much it can survive
        // its own 3σ bound, whereas the Winsorized estimator measures scatter
        // from the robust MAD and catches the trail. This is exactly why
        // Winsorized-σ is the module default.
        let cfg = IntegrationConfig {
            reject: Reject::WinsorizedSigmaClip {
                low: 3.0,
                high: 3.0,
            },
            ..Default::default()
        };
        let out = integrate_frames(&frames, w, h, 1, &cfg).unwrap();
        let rej = out.rejection_map.unwrap().as_f32().unwrap();
        assert_eq!(rej[0] as u32, 0, "clean pixel must show no rejection");
        assert_eq!(rej[1] as u32, 1, "trail pixel must show one rejection");
        let master = out.master.as_f32().unwrap();
        assert!((master[1] as f64 - 300.0).abs() < 1e-2);
    }

    // Per-channel independence (OSC)

    #[test]
    fn channels_are_rejected_independently() {
        // 1x1 RGB. A hot RED sample in one frame must not perturb G/B.
        let n = 15;
        let mut bufs: Vec<Vec<f64>> = (0..n).map(|_| vec![100.0, 200.0, 300.0]).collect();
        bufs[7][0] = 30000.0; // hot red only
        let frames: Vec<_> = bufs.iter().map(|b| frame(b, 1.0)).collect();
        let cfg = IntegrationConfig {
            reject: Reject::SigmaClip {
                low: 3.0,
                high: 3.0,
            },
            ..Default::default()
        };
        let out = integrate_frames(&frames, 1, 1, 3, &cfg).unwrap();
        let master = out.master.as_f32().unwrap();
        assert!((master[0] as f64 - 100.0).abs() < 1e-2, "R = {}", master[0]);
        assert!((master[1] as f64 - 200.0).abs() < 1e-2, "G = {}", master[1]);
        assert!((master[2] as f64 - 300.0).abs() < 1e-2, "B = {}", master[2]);
        let rej = out.rejection_map.unwrap().as_f32().unwrap();
        assert_eq!(rej[0] as u32, 1, "only R should reject");
        assert_eq!(rej[1] as u32, 0);
        assert_eq!(rej[2] as u32, 0);
    }

    // Coverage handling

    #[test]
    fn coverage_mask_excludes_uncovered_samples() {
        // 2x1 mono, 3 frames. Frame 0 does not cover pixel 1 (edge). The
        // weight/coverage map at pixel 1 should reflect only 2 contributors.
        let w = 2u32;
        let h = 1u32;
        let f0 = [10.0, 999.0]; // pixel-1 value is junk but masked out
        let f1 = [10.0, 20.0];
        let f2 = [10.0, 20.0];
        let mask0 = CoverageMask::new(2, 1, vec![true, false]).unwrap();
        let frames = [
            IntegrationFrame {
                pixels: &f0,
                weight: 1.0,
                coverage: Some(&mask0),
            },
            frame(&f1, 1.0),
            frame(&f2, 1.0),
        ];
        let cfg = IntegrationConfig {
            reject: Reject::None,
            ..Default::default()
        };
        let out = integrate_frames(&frames, w, h, 1, &cfg).unwrap();
        let master = out.master.as_f32().unwrap();
        // Pixel 0: all three contribute (10). Pixel 1: only f1,f2 (20), the
        // masked junk must not leak in.
        assert!((master[0] as f64 - 10.0).abs() < 1e-4);
        assert!((master[1] as f64 - 20.0).abs() < 1e-4, "got {}", master[1]);
        let wmap = out.weight_map.unwrap().as_f32().unwrap();
        assert!(
            (wmap[0] as f64 - 3.0).abs() < 1e-4,
            "pixel0 weight {}",
            wmap[0]
        );
        assert!(
            (wmap[1] as f64 - 2.0).abs() < 1e-4,
            "pixel1 weight {}",
            wmap[1]
        );
    }

    #[test]
    fn min_coverage_marks_thin_pixels_uncovered() {
        // 2x1 mono, 2 frames, but pixel 1 covered by only one frame while
        // min_coverage = 2 → pixel 1 is set to 0 and counted uncovered.
        let f0 = [50.0, 50.0];
        let f1 = [50.0, 999.0];
        let mask1 = CoverageMask::new(2, 1, vec![true, false]).unwrap();
        let frames = [
            frame(&f0, 1.0),
            IntegrationFrame {
                pixels: &f1,
                weight: 1.0,
                coverage: Some(&mask1),
            },
        ];
        let cfg = IntegrationConfig {
            reject: Reject::None,
            min_coverage: 2,
            ..Default::default()
        };
        let out = integrate_frames(&frames, 2, 1, 1, &cfg).unwrap();
        let master = out.master.as_f32().unwrap();
        assert!((master[0] as f64 - 50.0).abs() < 1e-4);
        assert_eq!(master[1], 0.0, "thin pixel below min_coverage must be 0");
        assert_eq!(out.stats.uncovered_pixels, 1);
    }

    // SNR improvement vs. a naive single frame and naive mean-with-outlier

    #[test]
    fn integration_improves_snr_over_single_frame() {
        // Constant signal + Gaussian noise. The integrated master's residual
        // RMS about the true signal must drop ~sqrt(N) vs a single frame.
        let w = 64u32;
        let h = 64u32;
        let n = 16usize;
        let signal = 1000.0;
        let mut lcg = Lcg(0x1234_5678);
        let noise_sigma = 50.0;
        let px = (w * h) as usize;

        let mut bufs: Vec<Vec<f64>> = Vec::with_capacity(n);
        for _ in 0..n {
            let mut b = vec![0.0; px];
            for v in &mut b {
                *v = signal + lcg.next_gauss() * noise_sigma;
            }
            bufs.push(b);
        }
        // Single-frame residual RMS.
        let single_rms = {
            let mut s = 0.0;
            for &v in &bufs[0] {
                s += (v - signal) * (v - signal);
            }
            (s / px as f64).sqrt()
        };

        let frames: Vec<_> = bufs.iter().map(|b| frame(b, 1.0)).collect();
        let cfg = IntegrationConfig {
            reject: Reject::None, // pure mean: cleanest SNR test
            ..Default::default()
        };
        let out = integrate_frames(&frames, w, h, 1, &cfg).unwrap();
        let master = out.master.as_f32().unwrap();
        let stacked_rms = {
            let mut s = 0.0;
            for &v in &master {
                s += (v as f64 - signal) * (v as f64 - signal);
            }
            (s / px as f64).sqrt()
        };
        // Expected √N improvement = 4×; allow generous slack for finite stats.
        assert!(
            stacked_rms < single_rms / 2.5,
            "stacked RMS {} should be well below single-frame RMS {}",
            stacked_rms,
            single_rms
        );
    }

    #[test]
    fn rejection_beats_naive_mean_on_contaminated_data() {
        // A column contaminated by a few cosmic-ray hits: a rejecting integrate
        // must land closer to the true signal than a plain (Reject::None) mean.
        let n = 25;
        let signal = 800.0;
        let mut lcg = Lcg(0x00C0_FFEE);
        let mut bufs: Vec<Vec<f64>> = (0..n)
            .map(|_| vec![signal + lcg.next_gauss() * 20.0])
            .collect();
        // Inject 3 cosmic-ray spikes.
        bufs[3][0] = 40000.0;
        bufs[11][0] = 35000.0;
        bufs[19][0] = 50000.0;
        let frames: Vec<_> = bufs.iter().map(|b| frame(b, 1.0)).collect();

        let naive = integrate_frames(
            &frames,
            1,
            1,
            1,
            &IntegrationConfig {
                reject: Reject::None,
                ..Default::default()
            },
        )
        .unwrap()
        .master
        .as_f32()
        .unwrap()[0] as f64;

        let cleaned = integrate_frames(
            &frames,
            1,
            1,
            1,
            &IntegrationConfig {
                reject: Reject::WinsorizedSigmaClip {
                    low: 3.0,
                    high: 3.0,
                },
                ..Default::default()
            },
        )
        .unwrap()
        .master
        .as_f32()
        .unwrap()[0] as f64;

        assert!(
            (cleaned - signal).abs() < (naive - signal).abs(),
            "rejected mean {} should beat naive mean {} (signal {})",
            cleaned,
            naive,
            signal
        );
        // And it should be quite close to the truth.
        assert!(
            (cleaned - signal).abs() < 30.0,
            "rejected mean {} should be near signal {}",
            cleaned,
            signal
        );
    }

    // Order independence (batch, not online)

    #[test]
    fn result_is_independent_of_frame_order() {
        let mut lcg = Lcg(42);
        let n = 12;
        let mut bufs: Vec<Vec<f64>> = (0..n)
            .map(|_| vec![1000.0 + lcg.next_gauss() * 40.0])
            .collect();
        bufs[5][0] = 25000.0; // one outlier

        let cfg = IntegrationConfig {
            reject: Reject::WinsorizedSigmaClip {
                low: 3.0,
                high: 3.0,
            },
            ..Default::default()
        };

        let forward: Vec<_> = bufs.iter().map(|b| frame(b, 1.0)).collect();
        let a = integrate_frames(&forward, 1, 1, 1, &cfg).unwrap();

        let mut reversed = bufs.clone();
        reversed.reverse();
        let back: Vec<_> = reversed.iter().map(|b| frame(b, 1.0)).collect();
        let bres = integrate_frames(&back, 1, 1, 1, &cfg).unwrap();

        let va = a.master.as_f32().unwrap()[0] as f64;
        let vb = bres.master.as_f32().unwrap()[0] as f64;
        assert!(
            (va - vb).abs() < 1e-6,
            "batch integration must be order-independent: {} vs {}",
            va,
            vb
        );
        assert_eq!(a.stats.total_rejected, bres.stats.total_rejected);
    }

    // U16 output path + median combine

    #[test]
    fn u16_output_clamps_and_rounds() {
        let f0 = [100.6];
        let f1 = [100.6];
        let f2 = [70000.0]; // above u16 max; with no rejection averages high
        let frames = [frame(&f0, 1.0), frame(&f1, 1.0), frame(&f2, 1.0)];
        let cfg = IntegrationConfig {
            reject: Reject::None,
            output_type: PixelType::U16,
            ..Default::default()
        };
        let out = integrate_frames(&frames, 1, 1, 1, &cfg).unwrap();
        assert_eq!(out.master.pixel_type, PixelType::U16);
        let m = out.master.as_u16().unwrap();
        let mean: f64 = (100.6 + 100.6 + 70000.0) / 3.0;
        assert_eq!(m[0], mean.round().clamp(0.0, 65535.0) as u16);
    }

    #[test]
    fn median_combine_picks_middle() {
        let f0 = [10.0];
        let f1 = [1000.0];
        let f2 = [12.0];
        let frames = [frame(&f0, 5.0), frame(&f1, 5.0), frame(&f2, 5.0)];
        let cfg = IntegrationConfig {
            combine: Combine::Median,
            reject: Reject::None,
            ..Default::default()
        };
        let out = integrate_frames(&frames, 1, 1, 1, &cfg).unwrap();
        let m = out.master.as_f32().unwrap();
        // median of {10,12,1000} = 12 (weights ignored by median).
        assert!((m[0] as f64 - 12.0).abs() < 1e-4, "got {}", m[0]);
    }

    // Error paths

    #[test]
    fn empty_population_errors() {
        let cfg = IntegrationConfig::default();
        let err = integrate_frames(&[], 1, 1, 1, &cfg).unwrap_err();
        assert_eq!(err, IntegrationError::NoFrames);
    }

    #[test]
    fn all_zero_weight_errors() {
        let f0 = [1.0];
        let frames = [frame(&f0, 0.0)];
        let cfg = IntegrationConfig::default();
        let err = integrate_frames(&frames, 1, 1, 1, &cfg).unwrap_err();
        assert_eq!(err, IntegrationError::NoWeightedFrames);
    }

    #[test]
    fn frame_size_mismatch_errors() {
        let good = [1.0, 2.0]; // expects 2 px (2x1 mono)
        let bad = [1.0]; // wrong size
        let frames = [frame(&good, 1.0), frame(&bad, 1.0)];
        let cfg = IntegrationConfig::default();
        let err = integrate_frames(&frames, 2, 1, 1, &cfg).unwrap_err();
        assert_eq!(
            err,
            IntegrationError::FrameSizeMismatch {
                index: 1,
                got: 1,
                expected: 2,
            }
        );
    }

    #[test]
    fn coverage_size_mismatch_errors() {
        let f0 = [1.0, 2.0];
        let bad_mask = CoverageMask::new(1, 1, vec![true]).unwrap(); // 1 px, frame is 2
        let frames = [IntegrationFrame {
            pixels: &f0,
            weight: 1.0,
            coverage: Some(&bad_mask),
        }];
        let cfg = IntegrationConfig::default();
        let err = integrate_frames(&frames, 2, 1, 1, &cfg).unwrap_err();
        assert_eq!(
            err,
            IntegrationError::CoverageSizeMismatch {
                index: 0,
                mask: 1,
                expected: 2,
            }
        );
    }

    #[test]
    fn unsupported_output_type_errors() {
        let f0 = [1.0];
        let frames = [frame(&f0, 1.0)];
        let cfg = IntegrationConfig {
            output_type: PixelType::U8,
            ..Default::default()
        };
        let err = integrate_frames(&frames, 1, 1, 1, &cfg).unwrap_err();
        assert_eq!(err, IntegrationError::UnsupportedOutputType(PixelType::U8));
    }

    #[test]
    fn zero_dimension_errors() {
        let f0: [f64; 0] = [];
        let frames = [frame(&f0, 1.0)];
        let cfg = IntegrationConfig::default();
        let err = integrate_frames(&frames, 0, 1, 1, &cfg).unwrap_err();
        assert_eq!(err, IntegrationError::ZeroDimension);
    }

    #[test]
    fn non_finite_samples_are_ignored() {
        // A NaN sample must be dropped from the column, not poison the mean.
        let f0 = [100.0];
        let f1 = [f64::NAN];
        let f2 = [200.0];
        let frames = [frame(&f0, 1.0), frame(&f1, 1.0), frame(&f2, 1.0)];
        let cfg = IntegrationConfig {
            reject: Reject::None,
            ..Default::default()
        };
        let out = integrate_frames(&frames, 1, 1, 1, &cfg).unwrap();
        let m = out.master.as_f32().unwrap();
        assert!((m[0] as f64 - 150.0).abs() < 1e-4, "got {}", m[0]);
    }
}
