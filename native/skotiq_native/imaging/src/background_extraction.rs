//! Background / gradient extraction — a DBE/ABE analogue (Pillar 3c).
//!
//! Wide-field deep-sky frames almost never have a flat sky. Light pollution,
//! moonlight, amp glow, vignetting residual after flat-fielding, and gradient
//! from an uneven sky all leave a smooth, **low-spatial-frequency** ramp across
//! the frame. That ramp is not signal — it is an additive pedestal that varies
//! slowly with position — and if it is left in place it wrecks the stretch
//! (one corner clips to black while the other blows out) and biases every
//! downstream colour/contrast operation.
//!
//! PixInsight solves this with two tools: **Automatic Background Extractor**
//! (ABE) fits a low-order polynomial to automatically-chosen background samples,
//! and **DynamicBackgroundExtraction** (DBE) does the same with a user-placed
//! sample grid and a spline/poly model. Both share one core idea, which is what
//! this module implements:
//!
//! 1. Lay a regular **grid of small sample boxes** over each channel.
//! 2. In each box take a **robust low estimate** of the level (a median, which
//!    ignores the bright pixels of any star that happens to sit in the box).
//! 3. **Reject boxes that are contaminated** by stars or bright structure — a
//!    box whose robust level sits far above the field's low-percentile baseline,
//!    or that overlaps a detected star, is dropped so the model is never pulled
//!    up toward an object.
//! 4. **Iteratively sigma-clip** the surviving samples (`sigma_low`/`sigma_high`)
//!    so that the few remaining contaminated or faint-nebulosity samples do not
//!    bias the fit.
//! 5. Fit a **2-D polynomial** of the requested degree to the survivors by least
//!    squares (normal equations), with `x`/`y` normalised to `[-1, 1]` for
//!    conditioning, and store the coefficients.
//!
//! Subtracting the evaluated model flattens the frame. When `preserve_mean` is
//! set the model's own mean level is added back so the operation only removes
//! the *gradient* and not the overall sky pedestal — exactly DBE/ABE's
//! "Subtraction, normalise to target background" behaviour, which keeps faint
//! extended signal (nebulosity) intact instead of clipping it to black.
//!
//! ## Why star-masked + robust + clipped (and not a plain surface fit)
//!
//! The whole difficulty is that the thing we want to model (the background) is
//! *defined by the absence* of the thing that dominates the pixel values
//! (stars and nebulosity). A naive least-squares plane through every pixel
//! would chase the stars. Three independent defences make the estimate honest:
//! the per-box **median** is immune to a star covering a minority of the box;
//! the **baseline + star-overlap rejection** throws away whole boxes that are
//! object-dominated; and the **sigma clip** removes the residual high-side
//! samples (faint nebulosity, box edges catching a star wing). This is the same
//! layered-robustness strategy the rest of the crate uses for noise
//! ([`crate::frame_weighting`]) and pixel rejection ([`crate::integration`]).
//!
//! ## Limitations
//!
//! The defaults (`grid = 24`, `poly_degree = 4`, `sample_box = 15`,
//! `sigma_low = 3.0`, `sigma_high = 2.0`) are defensible DBE/ABE-spirit values,
//! **not** numbers tuned against a corpus of real frames — they are exposed as
//! knobs precisely so they can be revisited with data. The model is a global
//! polynomial, which captures smooth low-order gradients and vignetting
//! residual well but **cannot** represent sharp, localised glow (a bright amp
//! glow corner, a satellite-flare halo); those need the spline/DBE path and are
//! out of scope here. `poly_degree` is capped at 6: beyond that the normal
//! equations become ill-conditioned even after `[-1,1]` normalisation and the
//! model starts fitting noise, so we reject the request rather than return a
//! garbage surface. The least-squares solve is a straightforward Gauss-Jordan
//! on the normal-equation matrix — fine for the ≤28-term systems a degree-≤6 2-D
//! polynomial produces, and deterministic so the tests are reproducible.

use crate::robust_stats::{median_in_place as median_f64, percentile_nearest_rank, MAD_TO_SIGMA};
use crate::{detect_stars, DetectedStar, ImageData, PixelType, StarDetectionConfig};
use rayon::prelude::*;

/// Hard cap on `poly_degree`. Beyond degree 6 the 2-D Vandermonde normal
/// equations are ill-conditioned even after `[-1, 1]` normalisation and the
/// model fits noise rather than the smooth background (see module docs).
const MAX_POLY_DEGREE: usize = 6;

// Public configuration

/// Tunables for [`extract_background`].
///
/// [`Default`] is a quality-first DBE/ABE-spirit configuration: a 24×24 sample
/// grid, a degree-4 polynomial, 15-px sample boxes, an asymmetric sigma clip
/// (looser on the low side so genuine background dips are kept, tighter on the
/// high side so star wings and faint nebulosity are rejected), and mean
/// preservation on so subtraction removes only the *gradient*.
#[derive(Debug, Clone, PartialEq)]
pub struct BackgroundConfig {
    /// Number of sample boxes per axis (`grid × grid` boxes total). More boxes
    /// give the fit more support but cost more per-box robust estimates.
    pub grid: usize,
    /// Degree of the fitted 2-D polynomial (`0..=6`). 1 = a tilted plane,
    /// 2 = a quadratic bowl (typical vignetting residual), 4 = the default,
    /// rich enough for most light-pollution ramps without over-fitting.
    pub poly_degree: usize,
    /// Side length (px) of each square sample box. The per-box median is taken
    /// over this window; larger boxes give a more stable median but smear the
    /// model's spatial resolution.
    pub sample_box: usize,
    /// Lower sigma-clip threshold for selecting background samples: a sample is
    /// dropped if it lies more than `sigma_low`·σ **below** the running robust
    /// centre. Looser (larger) by default because a real background dip is not a
    /// contaminant.
    pub sigma_low: f64,
    /// Upper sigma-clip threshold: a sample is dropped if it lies more than
    /// `sigma_high`·σ **above** the running robust centre. Tighter (smaller) by
    /// default because high-side outliers are the ones we fear (star wings,
    /// faint nebulosity caught in a box).
    pub sigma_high: f64,
    /// When `true`, the model's mean level is recorded and added back on
    /// subtraction so only the gradient is removed (the sky pedestal — and the
    /// faint signal riding on it — is preserved). When `false`, the full model
    /// is subtracted (a true flatten-to-zero, used when the pedestal is itself
    /// the thing to remove).
    pub preserve_mean: bool,
}

impl Default for BackgroundConfig {
    fn default() -> Self {
        Self {
            grid: 24,
            poly_degree: 4,
            sample_box: 15,
            sigma_low: 3.0,
            sigma_high: 2.0,
            preserve_mean: true,
        }
    }
}

/// A fitted background model: per-channel polynomial coefficients plus the mean
/// level the polynomial represents over the frame.
///
/// The coefficients are for the **normalised** coordinate system: `x`/`y` are
/// mapped to `[-1, 1]` before evaluation (see [`BackgroundModel::evaluate`]),
/// which is essential for the conditioning of the least-squares solve. The
/// `mean_level` is the polynomial's average value over the frame and is what
/// [`subtract_background`] adds back when `preserve_mean` was set.
#[derive(Debug, Clone, PartialEq)]
pub struct BackgroundModel {
    /// Frame width the model was fitted for (px).
    pub width: u32,
    /// Frame height the model was fitted for (px).
    pub height: u32,
    /// Number of channels the model covers.
    pub channels: u32,
    /// Per-channel polynomial coefficients. `coeffs_per_channel[c]` is the
    /// coefficient vector for channel `c`, in the canonical term order produced
    /// by [`poly_terms`] (all monomials `xⁱ·yʲ` with `i + j ≤ degree`,
    /// ordered by total degree then by `i`).
    pub coeffs_per_channel: Vec<Vec<f64>>,
    /// Per-channel mean level of the fitted surface over the frame. Added back
    /// on subtraction when the model was built with `preserve_mean`.
    pub mean_level: Vec<f64>,
    /// Whether the mean level should be re-added on subtraction. Baked into the
    /// model so [`subtract_background`] needs no separate config.
    pub preserve_mean: bool,
    /// The polynomial degree, retained so [`BackgroundModel::evaluate`] can
    /// regenerate the matching term list.
    pub degree: usize,
}

impl BackgroundModel {
    /// Evaluate the fitted background surface for channel `ch` at pixel
    /// `(x, y)` in **pixel** coordinates (the method normalises internally).
    ///
    /// Returns `0.0` for an out-of-range channel rather than panicking — the
    /// model is a value object that may outlive a careless caller, and a zero
    /// background contribution is the safe no-op. For in-range channels the
    /// returned value is the raw polynomial level (it does **not** add back
    /// `mean_level`; that is [`subtract_background`]'s job).
    pub fn evaluate(&self, x: f64, y: f64, ch: usize) -> f64 {
        let Some(coeffs) = self.coeffs_per_channel.get(ch) else {
            return 0.0;
        };
        let (nx, ny) = normalise_xy(x, y, self.width, self.height);
        eval_poly(coeffs, &poly_terms(self.degree), nx, ny)
    }
}

/// Errors from [`extract_background`]. Every variant is a *caller* mistake the
/// module refuses to paper over (an empty frame, a degree we cannot fit, a grid
/// that yields too few clean samples to determine the surface) — never a silent
/// best-effort plane through contaminated data.
#[derive(Debug, thiserror::Error, PartialEq)]
pub enum BackgroundError {
    /// The image has zero width, height, or channels, or carries no pixel data.
    #[error("image is empty (zero width/height/channels or no pixel data)")]
    EmptyImage,
    /// `poly_degree` exceeds [`MAX_POLY_DEGREE`] (the model would fit noise).
    #[error("polynomial degree {got} exceeds the supported maximum of {max}")]
    BadDegree { got: usize, max: usize },
    /// `grid` was 0, so no sample boxes could be laid down.
    #[error("sample grid must be at least 1×1, got {0}×{0}")]
    BadGrid(usize),
    /// After star-masking and sigma clipping, fewer clean background samples
    /// survived than the number of polynomial terms — the surface is
    /// under-determined and any "fit" would be fabricated.
    #[error(
        "too few clean background samples for channel {channel}: {samples} survived but {needed} are required to fit a degree-{degree} surface"
    )]
    TooFewSamples {
        channel: usize,
        samples: usize,
        needed: usize,
        degree: usize,
    },
    /// The normal-equation system was singular even with enough samples (e.g.
    /// every surviving sample fell on a single line, so the surface is not
    /// determined transverse to it).
    #[error(
        "background fit for channel {channel} is singular (samples are degenerate / collinear)"
    )]
    SingularFit { channel: usize },
}

// Public entry points

/// Fit a star-masked, low-order polynomial background model to `image`.
///
/// The algorithm, per channel (run in parallel across channels):
///
/// 1. Convert the channel to an `f64` plane (any [`PixelType`] is accepted).
/// 2. Lay a `cfg.grid × cfg.grid` lattice of `cfg.sample_box`-wide boxes and
///    take each box's **median** as its candidate background level.
/// 3. Reject boxes that overlap a star detected by [`detect_stars`] **or** whose
///    median sits far above the field's low-percentile baseline (object
///    contamination).
/// 4. Iteratively sigma-clip the survivors with `cfg.sigma_low`/`sigma_high`
///    around a robust (median/MAD) centre.
/// 5. Solve the normalised-coordinate least-squares polynomial fit.
///
/// Returns [`BackgroundError`] (not a degraded model) if the frame is empty, the
/// degree is unsupported, or any channel cannot muster enough clean samples to
/// determine the surface.
pub fn extract_background(
    image: &ImageData,
    cfg: &BackgroundConfig,
) -> Result<BackgroundModel, BackgroundError> {
    if image.is_empty() || image.channels == 0 {
        return Err(BackgroundError::EmptyImage);
    }
    if cfg.poly_degree > MAX_POLY_DEGREE {
        return Err(BackgroundError::BadDegree {
            got: cfg.poly_degree,
            max: MAX_POLY_DEGREE,
        });
    }
    if cfg.grid == 0 {
        return Err(BackgroundError::BadGrid(cfg.grid));
    }

    let width = image.width as usize;
    let height = image.height as usize;
    let channels = image.channels as usize;

    if width == 0 || height == 0 {
        return Err(BackgroundError::EmptyImage);
    }

    // De-interleave every channel into its own f64 plane up front. The work is
    // linear in pixel count and lets the per-channel fits run independently.
    let planes = deinterleave_to_f64(image);

    // Star mask is computed once on a luminance plane: stars are at the same
    // location in every channel of an aligned frame, so masking per channel
    // would be redundant work. detect_stars wants a U16 frame, so we synthesise
    // one from the luminance plane (see star_mask_pixels).
    let star_centres = detect_star_centres(image, &planes, width, height);

    let degree = cfg.poly_degree;
    let n_terms = poly_terms(degree).len();

    // Fit every channel; collect either all coeff/mean pairs or the first error.
    let per_channel: Result<Vec<(Vec<f64>, f64)>, BackgroundError> = (0..channels)
        .into_par_iter()
        .map(|ch| {
            fit_channel(
                &planes[ch],
                width,
                height,
                &star_centres,
                cfg,
                degree,
                n_terms,
                ch,
            )
        })
        .collect();

    let per_channel = per_channel?;

    let mut coeffs_per_channel = Vec::with_capacity(channels);
    let mut mean_level = Vec::with_capacity(channels);
    for (coeffs, mean) in per_channel {
        coeffs_per_channel.push(coeffs);
        mean_level.push(mean);
    }

    Ok(BackgroundModel {
        width: image.width,
        height: image.height,
        channels: image.channels,
        coeffs_per_channel,
        mean_level,
        preserve_mean: cfg.preserve_mean,
        degree,
    })
}

/// Subtract a fitted [`BackgroundModel`] from `image` in place.
///
/// For every pixel of every channel the model value is subtracted; if the model
/// was built with `preserve_mean` the channel's `mean_level` is added back so
/// only the *gradient* is removed (the sky pedestal and the faint signal riding
/// on it survive). For unsigned pixel types the result is clamped at 0 (a
/// background slightly above a pixel must not wrap to a huge value); for every
/// type the result is clamped to the type's representable maximum.
///
/// A model whose dimensions do not match `image` is a no-op on the mismatched
/// channels (the per-channel coefficient lookup simply yields nothing); callers
/// that built the model from the same frame never hit that path.
pub fn subtract_background(image: &mut ImageData, model: &BackgroundModel) {
    if image.is_empty() {
        return;
    }
    let width = image.width as usize;
    let height = image.height as usize;
    let channels = image.channels as usize;
    let pt = image.pixel_type;
    let bpp = pt.byte_size();
    let stride = channels * bpp;

    // Precompute per-channel (coeffs, add-back) so the hot loop avoids the
    // Option lookup and the preserve_mean branch per pixel.
    let mut channel_params: Vec<Option<(&[f64], f64)>> = Vec::with_capacity(channels);
    for ch in 0..channels {
        let entry = model.coeffs_per_channel.get(ch).map(|c| {
            let add_back = if model.preserve_mean {
                model.mean_level.get(ch).copied().unwrap_or(0.0)
            } else {
                0.0
            };
            (c.as_slice(), add_back)
        });
        channel_params.push(entry);
    }
    let degree = model.degree;
    let w = model.width;
    let h = model.height;
    // Hoist the polynomial term list out of the per-pixel hot loop: one
    // allocation for the whole frame instead of one per pixel per channel.
    let terms = poly_terms(degree);

    // Per-row parallel: each row owns a disjoint byte range, so we split the
    // buffer into row chunks and process them independently.
    let row_bytes = width * stride;
    image
        .data
        .par_chunks_mut(row_bytes)
        .enumerate()
        .for_each(|(y, row)| {
            if y >= height {
                return;
            }
            for x in 0..width {
                let base = x * stride;
                for (ch, params) in channel_params.iter().enumerate() {
                    let Some((coeffs, add_back)) = *params else {
                        continue;
                    };
                    let off = base + ch * bpp;
                    if off + bpp > row.len() {
                        continue;
                    }
                    let (nx, ny) = normalise_xy(x as f64, y as f64, w, h);
                    let model_val = eval_poly(coeffs, &terms, nx, ny);
                    let orig = read_pixel(&row[off..off + bpp], pt);
                    let new_val = orig - model_val + add_back;
                    write_pixel(&mut row[off..off + bpp], pt, new_val);
                }
            }
        });
}

/// Convenience wrapper: fit a model on a clone of `image` and return both the
/// background-subtracted copy and the model used.
///
/// The original `image` is left untouched (the subtraction happens on the
/// clone), so the caller can keep the linear, un-flattened frame for archival
/// while handing the flattened copy to the stretch/display pipeline. The model
/// is returned so it can be inspected, logged, or re-applied to a sibling frame.
pub fn extract_and_subtract(
    image: &ImageData,
    cfg: &BackgroundConfig,
) -> Result<(ImageData, BackgroundModel), BackgroundError> {
    let model = extract_background(image, cfg)?;
    let mut out = image.clone();
    subtract_background(&mut out, &model);
    Ok((out, model))
}

// Per-channel fit

/// Fit one channel's background polynomial. Returns the coefficient vector (in
/// [`poly_terms`] order) and the surface's mean level over the frame.
#[allow(clippy::too_many_arguments)]
fn fit_channel(
    plane: &[f64],
    width: usize,
    height: usize,
    star_centres: &[StarBox],
    cfg: &BackgroundConfig,
    degree: usize,
    n_terms: usize,
    channel: usize,
) -> Result<(Vec<f64>, f64), BackgroundError> {
    // 1. Per-box robust median samples.
    let mut samples = collect_box_samples(plane, width, height, cfg);

    // 2. Reject star-overlapping boxes and object-contaminated boxes (median
    //    far above the field's low-percentile baseline).
    reject_contaminated(&mut samples, star_centres, cfg.sample_box);

    if samples.len() < n_terms {
        return Err(BackgroundError::TooFewSamples {
            channel,
            samples: samples.len(),
            needed: n_terms,
            degree,
        });
    }

    // 3 + 4. Iterative residual-clipped polynomial fit.
    //
    // Why clip on the *residual* and not the raw value: the gradient itself
    // inflates the spread of the raw sample values (a frame with a strong ramp
    // has a huge value range that is entirely legitimate background), so a
    // sigma clip on raw values cannot tell a real gradient from a contaminant.
    // By fitting first, subtracting the model, and clipping the residual, we
    // *detrend* the gradient before clipping — the residual then carries only
    // noise plus genuine contamination (star wings, a faint nebulosity patch),
    // which the high-side `sigma_high` clip rejects so the surface stays pure
    // sky. This is the standard ABE/DBE iterative-rejection scheme and is the
    // mechanism that keeps faint extended signal from being *eaten* by the
    // model. The patch is rejected from the FIT but preserved in the OUTPUT,
    // because the fitted surface never rises to meet it.
    let coeffs = iterative_residual_fit(
        &mut samples,
        width,
        height,
        degree,
        n_terms,
        cfg.sigma_low,
        cfg.sigma_high,
        channel,
    )?;

    // 5. Mean level of the fitted surface over the frame (sampled on the grid
    //    that produced the fit — a fair, cheap estimate of the surface average).
    let mean = surface_mean(&coeffs, degree, width, height);

    Ok((coeffs, mean))
}

/// One background sample: its pixel-space centre and its robust level.
///
/// Shared with the Darkroom recipe engine's `background_extract` operation,
/// which lays its own sample grid and then hands the survivors to
/// [`iterative_residual_fit`], so both paths fit the same surface from the same
/// representation.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Sample {
    /// Sample centre, x in pixels.
    pub(crate) x: f64,
    /// Sample centre, y in pixels.
    pub(crate) y: f64,
    /// The sample's robust background level.
    pub(crate) value: f64,
}

/// A detected star's centre and radius, in pixel space, used to reject sample
/// boxes that overlap a star.
#[derive(Debug, Clone, Copy)]
struct StarBox {
    x: f64,
    y: f64,
    radius: f64,
}

/// Lay the `grid × grid` lattice of sample boxes and take each box's median.
fn collect_box_samples(
    plane: &[f64],
    width: usize,
    height: usize,
    cfg: &BackgroundConfig,
) -> Vec<Sample> {
    let grid = cfg.grid;
    let half = (cfg.sample_box / 2).max(1);

    // Box centres are spread evenly across the frame interior. With grid boxes
    // per axis the centres sit at the (i + 0.5)/grid fractional positions, so
    // even grid == 1 yields a single centred box.
    (0..grid)
        .into_par_iter()
        .flat_map_iter(|gy| {
            let mut row = Vec::with_capacity(grid);
            let cy = ((gy as f64 + 0.5) / grid as f64) * (height as f64 - 1.0);
            for gx in 0..grid {
                let cx = ((gx as f64 + 0.5) / grid as f64) * (width as f64 - 1.0);
                if let Some(value) = box_median(plane, width, height, cx, cy, half) {
                    row.push(Sample {
                        x: cx,
                        y: cy,
                        value,
                    });
                }
            }
            row
        })
        .collect()
}

/// Median of the (clamped) square window of half-width `half` centred on
/// `(cx, cy)`. Returns `None` if the window is empty (impossible for an
/// in-bounds centre, but guarded).
fn box_median(
    plane: &[f64],
    width: usize,
    height: usize,
    cx: f64,
    cy: f64,
    half: usize,
) -> Option<f64> {
    let cxr = cx.round() as isize;
    let cyr = cy.round() as isize;
    let half = half as isize;
    let x0 = (cxr - half).max(0) as usize;
    let x1 = ((cxr + half) as usize).min(width - 1);
    let y0 = (cyr - half).max(0) as usize;
    let y1 = ((cyr + half) as usize).min(height - 1);
    if x1 < x0 || y1 < y0 {
        return None;
    }

    let mut win: Vec<f64> = Vec::with_capacity((x1 - x0 + 1) * (y1 - y0 + 1));
    for y in y0..=y1 {
        let row = y * width;
        for x in x0..=x1 {
            win.push(plane[row + x]);
        }
    }
    Some(median_f64(&mut win))
}

/// Reject boxes that overlap a detected star OR whose level sits far above the
/// field's low-percentile baseline (object-dominated boxes the median could not
/// rescue, e.g. a box mostly covered by a galaxy core).
fn reject_contaminated(samples: &mut Vec<Sample>, star_centres: &[StarBox], sample_box: usize) {
    if samples.is_empty() {
        return;
    }

    // Field baseline: the 25th percentile of the box medians is a robust "this
    // is what clean sky looks like" anchor that is itself immune to the
    // object-contaminated minority of boxes. The spread (MAD of the lower half)
    // sets how far above baseline we tolerate before calling a box contaminated.
    let mut values: Vec<f64> = samples.iter().map(|s| s.value).collect();
    let baseline = percentile_f64(&mut values, 0.25);
    let median = percentile_f64(&mut values, 0.5);
    let mad = {
        let mut dev: Vec<f64> = samples.iter().map(|s| (s.value - median).abs()).collect();
        median_f64(&mut dev)
    };
    let sigma = (mad * MAD_TO_SIGMA).max(f64::MIN_POSITIVE);

    // A box more than this far above baseline is object-dominated. The factor
    // (4σ) is deliberately generous: the high-side sigma clip later does the
    // fine rejection; this gate only removes the gross object boxes a median
    // could not save.
    let baseline_cut = baseline + 4.0 * sigma;

    let box_half = (sample_box as f64 / 2.0).max(1.0);

    samples.retain(|s| {
        if s.value > baseline_cut {
            return false;
        }
        // Reject if any star centre falls within (star radius + box half-width)
        // of the box centre — i.e. the star's disk reaches into the box.
        for star in star_centres {
            let dx = s.x - star.x;
            let dy = s.y - star.y;
            let reach = star.radius + box_half;
            if dx * dx + dy * dy <= reach * reach {
                return false;
            }
        }
        true
    });
}

/// Iteratively fit the polynomial, reject high/low **residual** outliers, and
/// refit — the standard ABE/DBE rejection loop.
///
/// On each pass we fit the surface to the current survivors, evaluate the
/// residual `value − surface` at every survivor, compute the residuals' robust
/// centre (median) and MAD-derived σ, and drop any survivor whose residual lies
/// below `−sigma_low·σ` or above `+sigma_high·σ`. Because the model has already
/// absorbed the gradient, the residual carries only noise plus contamination,
/// so the asymmetric clip removes star wings and faint-nebulosity samples
/// without touching the legitimate (possibly steep) background. The loop runs to
/// convergence (no sample removed) or a small iteration cap, then returns the
/// final coefficients.
///
/// `samples` is mutated to the surviving set. Returns
/// [`BackgroundError::TooFewSamples`] if rejection drops the survivors below the
/// term count, or [`BackgroundError::SingularFit`] if the system is degenerate.
#[allow(clippy::too_many_arguments)]
pub(crate) fn iterative_residual_fit(
    samples: &mut Vec<Sample>,
    width: usize,
    height: usize,
    degree: usize,
    n_terms: usize,
    sigma_low: f64,
    sigma_high: f64,
    channel: usize,
) -> Result<Vec<f64>, BackgroundError> {
    const MAX_ITER: usize = 6;
    let w = width as u32;
    let h = height as u32;
    // Term list hoisted once for every residual evaluation in the loop below.
    let terms = poly_terms(degree);

    let mut coeffs = solve_poly_fit(samples, width, height, degree, n_terms)
        .ok_or(BackgroundError::SingularFit { channel })?;

    for _ in 0..MAX_ITER {
        if samples.len() <= n_terms {
            break;
        }

        // Residual of every survivor against the current surface.
        let mut residuals: Vec<f64> = samples
            .iter()
            .map(|s| {
                let (nx, ny) = normalise_xy(s.x, s.y, w, h);
                s.value - eval_poly(&coeffs, &terms, nx, ny)
            })
            .collect();

        let median = median_f64(&mut residuals);
        let mut dev: Vec<f64> = residuals.iter().map(|&r| (r - median).abs()).collect();
        let mad = median_f64(&mut dev);
        let sigma = mad * MAD_TO_SIGMA;
        if sigma <= 0.0 {
            // Residuals are flat (a perfect fit, or too few distinct points) —
            // nothing more to reject.
            break;
        }
        let lower = median - sigma_low * sigma;
        let upper = median + sigma_high * sigma;

        let before = samples.len();
        let mut keep = Vec::with_capacity(before);
        for s in samples.iter() {
            let (nx, ny) = normalise_xy(s.x, s.y, w, h);
            let r = s.value - eval_poly(&coeffs, &terms, nx, ny);
            if r >= lower && r <= upper {
                keep.push(*s);
            }
        }

        if keep.len() < n_terms {
            return Err(BackgroundError::TooFewSamples {
                channel,
                samples: keep.len(),
                needed: n_terms,
                degree,
            });
        }
        let converged = keep.len() == before;
        *samples = keep;
        coeffs = solve_poly_fit(samples, width, height, degree, n_terms)
            .ok_or(BackgroundError::SingularFit { channel })?;
        if converged {
            break;
        }
    }

    Ok(coeffs)
}

// Polynomial machinery

/// The exponent pairs `(i, j)` of every monomial `xⁱ·yʲ` with `i + j ≤ degree`,
/// in a stable canonical order: ascending total degree, then **descending `i`**
/// (i.e. the x-power leads within each total-degree block).
///
/// For degree 2 this yields:
/// `[(0,0), (1,0), (0,1), (2,0), (1,1), (0,2)]` — a 6-term quadratic surface.
/// The count is `(degree+1)(degree+2)/2`. The exact ordering is an internal
/// detail; what matters is that [`eval_poly`] and [`solve_poly_fit`] both use
/// this single source of truth, so a coefficient and its monomial never drift.
pub(crate) fn poly_terms(degree: usize) -> Vec<(u32, u32)> {
    let mut terms = Vec::with_capacity((degree + 1) * (degree + 2) / 2);
    for total in 0..=degree {
        // i descends from `total` to 0 so the x-power leads: (total,0) … (0,total).
        for i in (0..=total).rev() {
            let j = total - i;
            terms.push((i as u32, j as u32));
        }
    }
    terms
}

/// Evaluate `Σ coeffs[k] · nxⁱ · nyʲ` for the canonical term order at the given
/// normalised coordinates.
///
/// `terms` is the precomputed [`poly_terms`] list for the model's degree, passed
/// in by the caller so the per-pixel hot path (`subtract_background`, the
/// residual loop in `iterative_residual_fit`) never re-allocates it. On a
/// 6000×4000×3 frame `subtract_background` calls this ~72M times; allocating the
/// ≤28-entry term Vec inside each call would defeat the rayon parallelism by
/// hammering the allocator and contradict the module's "cheaper hot path" intent
/// (see `powi_u32`). Hoisting the term list to one allocation per call site keeps
/// this zero-alloc. `terms` and `coeffs` must come from the same degree.
pub(crate) fn eval_poly(coeffs: &[f64], terms: &[(u32, u32)], nx: f64, ny: f64) -> f64 {
    let mut acc = 0.0;
    for (k, &(i, j)) in terms.iter().enumerate() {
        if k >= coeffs.len() {
            break;
        }
        acc += coeffs[k] * powi_u32(nx, i) * powi_u32(ny, j);
    }
    acc
}

/// Map pixel coordinates to `[-1, 1]` for fit conditioning. A frame with a
/// single column/row maps that axis to 0 (a degenerate axis is constant, which
/// the fit handles via the constant term).
#[inline]
pub(crate) fn normalise_xy(x: f64, y: f64, width: u32, height: u32) -> (f64, f64) {
    let nx = if width > 1 {
        2.0 * x / (width as f64 - 1.0) - 1.0
    } else {
        0.0
    };
    let ny = if height > 1 {
        2.0 * y / (height as f64 - 1.0) - 1.0
    } else {
        0.0
    };
    (nx, ny)
}

/// Integer power for small non-negative exponents (the polynomial degrees here
/// are ≤ 6, so this is cheaper and more accurate than `powf`).
#[inline]
fn powi_u32(base: f64, exp: u32) -> f64 {
    let mut acc = 1.0;
    for _ in 0..exp {
        acc *= base;
    }
    acc
}

/// Solve the normalised-coordinate least-squares polynomial fit by assembling
/// and solving the normal equations `(AᵀA) c = Aᵀb`.
///
/// `A` is the `n_samples × n_terms` design matrix of monomials evaluated at the
/// (normalised) sample positions; `b` is the sample values. We form the
/// symmetric `n_terms × n_terms` normal matrix and the `n_terms` right-hand
/// side, then solve by Gauss-Jordan elimination with partial pivoting. Returns
/// `None` if the system is singular (degenerate / collinear samples).
///
/// `needless_range_loop` is allowed for the normal-matrix accumulation: the
/// triangular `r..n_terms` inner loop indexes both `ata[r][c]` and the basis
/// row by the same running index, which is the natural and clearest form for a
/// symmetric outer product.
#[allow(clippy::needless_range_loop)]
pub(crate) fn solve_poly_fit(
    samples: &[Sample],
    width: usize,
    height: usize,
    degree: usize,
    n_terms: usize,
) -> Option<Vec<f64>> {
    let terms = poly_terms(degree);
    debug_assert_eq!(terms.len(), n_terms);

    // Precompute each sample's basis row in normalised coordinates.
    let w = width as u32;
    let h = height as u32;
    let basis: Vec<Vec<f64>> = samples
        .iter()
        .map(|s| {
            let (nx, ny) = normalise_xy(s.x, s.y, w, h);
            terms
                .iter()
                .map(|&(i, j)| powi_u32(nx, i) * powi_u32(ny, j))
                .collect()
        })
        .collect();

    // Normal matrix AᵀA (n_terms × n_terms) and RHS Aᵀb (n_terms).
    let mut ata = vec![vec![0.0_f64; n_terms]; n_terms];
    let mut atb = vec![0.0_f64; n_terms];
    for (row, s) in basis.iter().zip(samples.iter()) {
        for r in 0..n_terms {
            atb[r] += row[r] * s.value;
            for c in r..n_terms {
                ata[r][c] += row[r] * row[c];
            }
        }
    }
    // Mirror the symmetric lower triangle.
    for r in 0..n_terms {
        for c in 0..r {
            ata[r][c] = ata[c][r];
        }
    }

    solve_linear_system(ata, atb)
}

/// Solve `M x = b` for a square `M` by Gauss-Jordan elimination with partial
/// pivoting. Returns `None` if `M` is singular (a near-zero pivot).
///
/// `needless_range_loop` is allowed here for the same reason as
/// [`crate::registration`]'s solver: this is textbook elimination where the
/// inner loop reads the *pivot* row `m[col]` while mutating row `m[r]`, and the
/// outer loop swaps whole rows. Index arithmetic is the clearest and most
/// borrow-checker-friendly way to express the simultaneous cross-row access.
#[allow(clippy::needless_range_loop)]
fn solve_linear_system(mut m: Vec<Vec<f64>>, mut b: Vec<f64>) -> Option<Vec<f64>> {
    let n = b.len();
    if n == 0 || m.len() != n {
        return None;
    }

    // Scale-aware singularity threshold: relate the pivot tolerance to the
    // matrix magnitude so a well-scaled but large-valued system is not wrongly
    // flagged singular.
    let max_abs = m
        .iter()
        .flat_map(|row| row.iter())
        .fold(0.0_f64, |acc, &v| acc.max(v.abs()));
    let eps = (max_abs * 1e-12).max(1e-300);

    for col in 0..n {
        // Partial pivot: largest |value| in this column at or below the
        // diagonal.
        let mut pivot_row = col;
        let mut pivot_val = m[col][col].abs();
        for (r, row) in m.iter().enumerate().skip(col + 1) {
            let v = row[col].abs();
            if v > pivot_val {
                pivot_val = v;
                pivot_row = r;
            }
        }
        if pivot_val < eps {
            return None;
        }
        m.swap(col, pivot_row);
        b.swap(col, pivot_row);

        // Normalise the pivot row.
        let pivot = m[col][col];
        for c in col..n {
            m[col][c] /= pivot;
        }
        b[col] /= pivot;

        // Eliminate the column from every other row.
        for r in 0..n {
            if r == col {
                continue;
            }
            let factor = m[r][col];
            if factor == 0.0 {
                continue;
            }
            for c in col..n {
                m[r][c] -= factor * m[col][c];
            }
            b[r] -= factor * b[col];
        }
    }

    Some(b)
}

/// Mean level of the fitted surface over the frame, estimated by evaluating the
/// polynomial on a coarse regular grid. A grid average is an unbiased estimate
/// of the surface's spatial mean and is cheap (≤ 17×17 = 289 evaluations).
fn surface_mean(coeffs: &[f64], degree: usize, width: usize, height: usize) -> f64 {
    const N: usize = 17;
    let w = width as u32;
    let h = height as u32;
    let terms = poly_terms(degree);
    let mut acc = 0.0;
    let mut count = 0.0;
    for gy in 0..N {
        let y = if height > 1 {
            gy as f64 / (N as f64 - 1.0) * (height as f64 - 1.0)
        } else {
            0.0
        };
        for gx in 0..N {
            let x = if width > 1 {
                gx as f64 / (N as f64 - 1.0) * (width as f64 - 1.0)
            } else {
                0.0
            };
            let (nx, ny) = normalise_xy(x, y, w, h);
            acc += eval_poly(coeffs, &terms, nx, ny);
            count += 1.0;
        }
    }
    if count > 0.0 {
        acc / count
    } else {
        0.0
    }
}

// Star masking

/// Detect star centres/radii once, on a luminance proxy, so every channel's fit
/// can reject the same star-overlapping boxes.
///
/// [`detect_stars`] expects a `U16` mono frame. For a `U16` mono input we hand
/// it the frame directly; otherwise we synthesise a `U16` luminance frame from
/// the de-interleaved planes (channel mean) rescaled to fill the 16-bit range,
/// which preserves star positions (the only thing we use) regardless of the
/// source pixel type or channel count.
fn detect_star_centres(
    image: &ImageData,
    planes: &[Vec<f64>],
    width: usize,
    height: usize,
) -> Vec<StarBox> {
    // Build a U16 luminance frame for detection.
    let luminance_u16: Vec<u16> = if image.pixel_type == PixelType::U16 && image.channels == 1 {
        image.as_u16().unwrap_or_default()
    } else {
        synth_luminance_u16(planes, width, height)
    };

    if luminance_u16.len() != width * height {
        return Vec::new();
    }
    let frame = ImageData::from_u16(width as u32, height as u32, 1, &luminance_u16);

    // Detection config tuned for masking, not photometry: relax sharpness so
    // compact stars are kept (a star's whole point here is to be masked), and
    // keep a moderate sigma so faint nebulosity is NOT flagged as a star (we
    // want nebulosity *preserved*, hence excluded from the star mask).
    let cfg = StarDetectionConfig {
        max_sharpness: 1.0,
        min_area: 3,
        min_hfr: 0.5,
        min_snr: 3.0,
        ..StarDetectionConfig::default()
    };
    let stars = detect_stars(&frame, &cfg);

    stars
        .iter()
        .map(|s: &DetectedStar| {
            // Mask radius: 3× the HFR covers ~the full visible disk plus wings
            // for a Gaussian PSF, with a sane floor so even tiny detections
            // protect a few pixels. Capped so a bloated saturated detection
            // cannot mask out half the frame.
            let r = (3.0 * s.hfr).clamp(3.0, (width.min(height) as f64) * 0.1);
            StarBox {
                x: s.x,
                y: s.y,
                radius: r,
            }
        })
        .collect()
}

/// Synthesise a U16 luminance frame from f64 planes for star detection. Uses the
/// per-pixel channel mean rescaled to [0, 60000] so the detector's thresholds
/// behave regardless of the source's absolute scale.
fn synth_luminance_u16(planes: &[Vec<f64>], width: usize, height: usize) -> Vec<u16> {
    let n = width * height;
    if planes.is_empty() {
        return Vec::new();
    }
    let mut lum = vec![0.0_f64; n];
    for plane in planes {
        if plane.len() != n {
            return Vec::new();
        }
        for (l, &p) in lum.iter_mut().zip(plane.iter()) {
            *l += p;
        }
    }
    let inv_c = 1.0 / planes.len() as f64;
    for l in lum.iter_mut() {
        *l *= inv_c;
    }

    let (mut lo, mut hi) = (f64::INFINITY, f64::NEG_INFINITY);
    for &v in &lum {
        lo = lo.min(v);
        hi = hi.max(v);
    }
    let range = (hi - lo).max(f64::MIN_POSITIVE);
    lum.iter()
        .map(|&v| (((v - lo) / range) * 60000.0).clamp(0.0, 65535.0) as u16)
        .collect()
}

// Pixel <-> f64 conversion

/// De-interleave an [`ImageData`] into one `f64` plane per channel.
fn deinterleave_to_f64(image: &ImageData) -> Vec<Vec<f64>> {
    let width = image.width as usize;
    let height = image.height as usize;
    let channels = image.channels as usize;
    let pt = image.pixel_type;
    let bpp = pt.byte_size();
    let stride = channels * bpp;
    let n = width * height;

    (0..channels)
        .map(|ch| {
            let mut plane = vec![0.0_f64; n];
            for (idx, p) in plane.iter_mut().enumerate() {
                let off = idx * stride + ch * bpp;
                if off + bpp <= image.data.len() {
                    *p = read_pixel(&image.data[off..off + bpp], pt);
                }
            }
            plane
        })
        .collect()
}

/// Read a single pixel value of the given type from its little-endian bytes,
/// promoted to `f64`. Matches the crate's `from_le_bytes` conventions in
/// [`ImageData`] (`as_u16`/`as_f32`) and extends them to the remaining types.
#[inline]
fn read_pixel(bytes: &[u8], pt: PixelType) -> f64 {
    match pt {
        PixelType::U8 => bytes[0] as f64,
        PixelType::U16 => u16::from_le_bytes([bytes[0], bytes[1]]) as f64,
        PixelType::U32 => u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]) as f64,
        PixelType::F32 => f32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]) as f64,
        PixelType::F64 => f64::from_le_bytes([
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        ]),
    }
}

/// Write a single `f64` pixel value back into its little-endian bytes for the
/// given type. Unsigned types saturate at 0 and the type maximum (the standard
/// Rust `f64 as uN` saturating-cast semantics since 1.45); float types are
/// written verbatim.
#[inline]
fn write_pixel(bytes: &mut [u8], pt: PixelType, value: f64) {
    match pt {
        PixelType::U8 => {
            let v = value.clamp(0.0, u8::MAX as f64) as u8;
            bytes[0] = v;
        }
        PixelType::U16 => {
            let v = value.clamp(0.0, u16::MAX as f64) as u16;
            bytes[..2].copy_from_slice(&v.to_le_bytes());
        }
        PixelType::U32 => {
            let v = value.clamp(0.0, u32::MAX as f64) as u32;
            bytes[..4].copy_from_slice(&v.to_le_bytes());
        }
        PixelType::F32 => {
            bytes[..4].copy_from_slice(&(value as f32).to_le_bytes());
        }
        PixelType::F64 => {
            bytes[..8].copy_from_slice(&value.to_le_bytes());
        }
    }
}

// Small robust-statistics helpers

/// Nearest-rank percentile (`p` in `[0, 1]`) of a mutable slice, sorting it in
/// place. See [`crate::robust_stats`] for why the convention is named.
fn percentile_f64(v: &mut [f64], p: f64) -> f64 {
    v.sort_unstable_by(f64::total_cmp);
    percentile_nearest_rank(v, p)
}

// Tests

#[cfg(test)]
mod tests {
    use super::*;

    /// Tiny deterministic LCG (Numerical Recipes constants) → uniform `[0, 1)`.
    /// Used for reproducible pseudo-noise; no `rand` dependency, per the project
    /// idiom of fully deterministic synthetic-data tests.
    struct Lcg(u64);
    impl Lcg {
        fn next_unit(&mut self) -> f64 {
            self.0 = self
                .0
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            // Top 24 bits → [0, 1).
            ((self.0 >> 40) as f64) / ((1u64 << 24) as f64)
        }
        /// Approx-Gaussian deviate (mean 0, σ 1) via the sum-of-12-uniforms CLT
        /// trick — deterministic and dependency-free.
        fn next_gauss(&mut self) -> f64 {
            let mut s = 0.0;
            for _ in 0..12 {
                s += self.next_unit();
            }
            s - 6.0
        }
    }

    /// Add a round Gaussian "star" of the given peak/σ to an f64 plane.
    fn add_star(
        plane: &mut [f64],
        width: usize,
        height: usize,
        cx: f64,
        cy: f64,
        peak: f64,
        sigma: f64,
    ) {
        let r = (3.0 * sigma).ceil() as i32;
        let two_sig_sq = 2.0 * sigma * sigma;
        let cxr = cx.round() as i32;
        let cyr = cy.round() as i32;
        for dy in -r..=r {
            for dx in -r..=r {
                let x = cxr + dx;
                let y = cyr + dy;
                if x < 0 || y < 0 || x >= width as i32 || y >= height as i32 {
                    continue;
                }
                let rr = (dx * dx + dy * dy) as f64;
                plane[y as usize * width + x as usize] += peak * (-rr / two_sig_sq).exp();
            }
        }
    }

    /// A known planar gradient `a + b·x + c·y` evaluated at pixel coordinates.
    fn plane_gradient(x: f64, y: f64, a: f64, b: f64, c: f64) -> f64 {
        a + b * x + c * y
    }

    /// Build a U16 mono frame from an f64 plane (clamped to the 16-bit range).
    fn frame_from_plane(plane: &[f64], width: usize, height: usize) -> ImageData {
        let data: Vec<u16> = plane
            .iter()
            .map(|&v| v.clamp(0.0, 65535.0) as u16)
            .collect();
        ImageData::from_u16(width as u32, height as u32, 1, &data)
    }

    /// Sample standard deviation of a slice.
    fn std_dev(v: &[f64]) -> f64 {
        if v.len() < 2 {
            return 0.0;
        }
        let mean = v.iter().sum::<f64>() / v.len() as f64;
        let var = v.iter().map(|&x| (x - mean).powi(2)).sum::<f64>() / v.len() as f64;
        var.sqrt()
    }

    #[test]
    fn poly_terms_has_expected_count_and_order() {
        // (degree+1)(degree+2)/2 terms; canonical order = ascending total degree.
        assert_eq!(poly_terms(0), vec![(0, 0)]);
        assert_eq!(poly_terms(1), vec![(0, 0), (1, 0), (0, 1)]);
        assert_eq!(
            poly_terms(2),
            vec![(0, 0), (1, 0), (0, 1), (2, 0), (1, 1), (0, 2)]
        );
        assert_eq!(poly_terms(4).len(), 15);
        assert_eq!(poly_terms(6).len(), 28);
    }

    #[test]
    fn eval_poly_takes_hoisted_terms_and_matches_known_polynomial() {
        // eval_poly takes the term list by reference, hoisted out of the
        // per-pixel hot loop rather than allocated per call. Pin both the
        // signature and the arithmetic against a hand-computed value so a
        // change that mis-orders the terms or drops the hoist is caught.
        //
        // Degree-2 term order is [(0,0),(1,0),(0,1),(2,0),(1,1),(0,2)]; with
        // coeffs c and (nx,ny)=(0.5,-0.25):
        //   c0 + c1·nx + c2·ny + c3·nx² + c4·nx·ny + c5·ny²
        let terms = poly_terms(2);
        let coeffs = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0];
        let (nx, ny) = (0.5_f64, -0.25_f64);
        let expected = 1.0 + 2.0 * nx + 3.0 * ny + 4.0 * nx * nx + 5.0 * nx * ny + 6.0 * ny * ny;
        let got = eval_poly(&coeffs, &terms, nx, ny);
        assert!(
            (got - expected).abs() < 1e-12,
            "eval_poly {got} != hand-computed {expected}"
        );

        // The same coeffs+terms must be reusable across many calls without the
        // function needing to rebuild the list internally — exercise that the
        // borrowed slice path is what's evaluated (a stand-in for the hot loop).
        for k in 0..100 {
            let t = k as f64 / 99.0;
            let a = eval_poly(&coeffs, &terms, t, -t);
            let b = eval_poly(&coeffs, &poly_terms(2), t, -t);
            assert!(
                (a - b).abs() < 1e-12,
                "hoisted vs fresh terms disagree at t={t}"
            );
        }
    }

    #[test]
    fn linear_solver_recovers_known_solution() {
        // 2x + y = 5 ; x + 3y = 10  → x = 1, y = 3.
        let m = vec![vec![2.0, 1.0], vec![1.0, 3.0]];
        let b = vec![5.0, 10.0];
        let sol = solve_linear_system(m, b).expect("non-singular");
        assert!((sol[0] - 1.0).abs() < 1e-9, "x = {}", sol[0]);
        assert!((sol[1] - 3.0).abs() < 1e-9, "y = {}", sol[1]);
    }

    #[test]
    fn linear_solver_reports_singular() {
        // Rank-deficient (second row = 2× first) → no unique solution.
        let m = vec![vec![1.0, 2.0], vec![2.0, 4.0]];
        let b = vec![3.0, 6.0];
        assert!(solve_linear_system(m, b).is_none());
    }

    #[test]
    fn recovers_planted_degree_two_gradient() {
        // A pure degree-2 background, no stars, no noise. The fit must recover
        // the surface so closely that the model reproduces the frame to within
        // a tight tolerance everywhere (test #2 in the spec).
        let (w, h) = (200usize, 160usize);
        let mut plane = vec![0.0_f64; w * h];
        // background(x, y) = 1000 + 0.5x + 0.3y + 0.004x² - 0.003y² + 0.002xy
        let f = |x: f64, y: f64| {
            1000.0 + 0.5 * x + 0.3 * y + 0.004 * x * x - 0.003 * y * y + 0.002 * x * y
        };
        for y in 0..h {
            for x in 0..w {
                plane[y * w + x] = f(x as f64, y as f64);
            }
        }
        let image = frame_from_plane(&plane, w, h);
        let cfg = BackgroundConfig {
            poly_degree: 2,
            preserve_mean: false,
            ..BackgroundConfig::default()
        };
        let model = extract_background(&image, &cfg).expect("fit should succeed");

        // The model should reproduce the analytic surface at arbitrary points.
        let mut max_rel_err = 0.0_f64;
        for &(x, y) in &[(10.0, 10.0), (100.0, 80.0), (199.0, 159.0), (0.0, 159.0)] {
            let expected = f(x, y);
            let got = model.evaluate(x, y, 0);
            let rel = (got - expected).abs() / expected.abs();
            max_rel_err = max_rel_err.max(rel);
        }
        assert!(
            max_rel_err < 1e-3,
            "degree-2 gradient must be recovered within 0.1%, max rel err = {max_rel_err}"
        );
    }

    #[test]
    fn flattens_gradient_while_preserving_nebulosity_patch() {
        // Spec test #1: synthetic = known low-order gradient + injected stars +
        // a flat faint nebulosity patch. After extract_and_subtract:
        //   (a) the residual gradient std is greatly reduced, AND
        //   (b) the nebulosity patch mean is preserved (not eaten).
        let (w, h) = (256usize, 256usize);
        let (a, b, c) = (3000.0, 6.0, 4.5); // strong linear ramp across the frame
        let mut plane = vec![0.0_f64; w * h];
        for y in 0..h {
            for x in 0..w {
                plane[y * w + x] = plane_gradient(x as f64, y as f64, a, b, c);
            }
        }

        // A faint flat nebulosity patch (a low, broad pedestal) in a central
        // region — the thing we must NOT remove. Keep it faint (well under the
        // gradient amplitude and the star peaks) so it is a genuine "preserve
        // the faint extended signal" test.
        const NEB_LEVEL: f64 = 400.0;
        let (nx0, nx1, ny0, ny1) = (96usize, 160usize, 96usize, 160usize);
        for y in ny0..ny1 {
            for x in nx0..nx1 {
                plane[y * w + x] += NEB_LEVEL;
            }
        }

        // Inject a sprinkling of bright Gaussian stars on a coarse grid; these
        // are the contaminants the star mask + clip must reject.
        let mut star_centres: Vec<(usize, usize)> = Vec::new();
        let mut sy = 32;
        while sy < h - 32 {
            let mut sx = 32;
            while sx < w - 32 {
                add_star(&mut plane, w, h, sx as f64, sy as f64, 25000.0, 2.2);
                star_centres.push((sx, sy));
                sx += 48;
            }
            sy += 48;
        }
        assert!(!star_centres.is_empty());

        // A little deterministic pseudo-noise so medians/clipping have real work.
        let mut rng = Lcg(0xC0FFEE_u64);
        for px in plane.iter_mut() {
            *px += rng.next_gauss() * 8.0;
        }

        let image = frame_from_plane(&plane, w, h);

        // Measure the gradient std BEFORE, sampling clean-sky pixels only: we
        // exclude the nebulosity patch (we measure it separately) and a generous
        // disk around every injected star (a star's wings ride above the ramp and
        // would otherwise dominate the std — we are measuring *background*
        // flatness, not the stars). 14 px comfortably clears the 3σ ≈ 7 px
        // visible disk of the σ=2.2 stars plus their faint wings.
        let is_clean = |x: usize, y: usize| -> bool {
            if x >= nx0 && x < nx1 && y >= ny0 && y < ny1 {
                return false;
            }
            for &(sx, sy) in &star_centres {
                let dx = x as i64 - sx as i64;
                let dy = y as i64 - sy as i64;
                if dx * dx + dy * dy <= 14 * 14 {
                    return false;
                }
            }
            true
        };
        let mut before_vals: Vec<f64> = Vec::new();
        for y in (0..h).step_by(7) {
            for x in (0..w).step_by(7) {
                if !is_clean(x, y) {
                    continue;
                }
                let v = plane[y * w + x];
                // Reject the few star-core samples that survive the coarse stride.
                if v < 12000.0 {
                    before_vals.push(v);
                }
            }
        }
        let before_std = std_dev(&before_vals);
        assert!(
            before_std > 100.0,
            "the planted ramp must be substantial, got std {before_std}"
        );

        let cfg = BackgroundConfig {
            poly_degree: 2,
            preserve_mean: true,
            ..BackgroundConfig::default()
        };
        let (out, model) =
            extract_and_subtract(&image, &cfg).expect("extract_and_subtract should succeed");
        let out_pixels: Vec<f64> = out.as_u16().unwrap().iter().map(|&v| v as f64).collect();

        // (a) Residual clean-sky gradient std must be greatly reduced.
        let mut after_vals: Vec<f64> = Vec::new();
        for y in (0..h).step_by(7) {
            for x in (0..w).step_by(7) {
                if !is_clean(x, y) {
                    continue;
                }
                let v = out_pixels[y * w + x];
                if v < 12000.0 {
                    after_vals.push(v);
                }
            }
        }
        let after_std = std_dev(&after_vals);
        assert!(
            after_std < before_std * 0.25,
            "gradient std must drop by >4x: before {before_std:.1}, after {after_std:.1}"
        );

        // (b) The nebulosity patch must survive. With preserve_mean the global
        // sky pedestal is added back, so the patch should still sit ~NEB_LEVEL
        // above the surrounding flattened sky.
        // Sample the patch interior, excluding any pixel near an injected star
        // (a star sits at the patch centre; its wings would otherwise inflate
        // the patch mean — we are measuring the *nebulosity*, not the star).
        let near_star = |x: usize, y: usize| -> bool {
            star_centres.iter().any(|&(sx, sy)| {
                let dx = x as i64 - sx as i64;
                let dy = y as i64 - sy as i64;
                dx * dx + dy * dy <= 14 * 14
            })
        };
        let patch_inner =
            |x: usize, y: usize| x >= nx0 + 16 && x < nx1 - 16 && y >= ny0 + 16 && y < ny1 - 16;
        let mut patch_vals: Vec<f64> = Vec::new();
        for y in ny0..ny1 {
            for x in nx0..nx1 {
                if !patch_inner(x, y) || near_star(x, y) {
                    continue;
                }
                patch_vals.push(out_pixels[y * w + x]);
            }
        }
        assert!(
            !patch_vals.is_empty(),
            "patch sampling must retain some clean nebulosity pixels"
        );
        let patch_mean = patch_vals.iter().sum::<f64>() / patch_vals.len() as f64;

        // Surrounding (flattened) sky just outside the patch.
        let surround_vals: Vec<f64> = after_vals.clone();
        let surround_mean = surround_vals.iter().sum::<f64>() / surround_vals.len() as f64;

        let patch_excess = patch_mean - surround_mean;
        assert!(
            (patch_excess - NEB_LEVEL).abs() < NEB_LEVEL * 0.30,
            "nebulosity patch must be preserved at ~{NEB_LEVEL} above sky, got excess {patch_excess:.1}"
        );

        // Mean preservation must be reflected in the model too.
        assert!(model.preserve_mean);
        assert!(model.mean_level[0] > 0.0);
    }

    #[test]
    fn too_few_samples_is_an_error() {
        // Spec test #3: a frame that cannot yield enough clean samples to fit
        // the requested surface must return TooFewSamples, not a fabricated fit.
        // A 3×3 sample grid yields at most 9 box medians, but a degree-4 surface
        // needs 15 terms — under-determined, so the fit must be refused.
        let (w, h) = (128usize, 128usize);
        let plane = vec![1000.0_f64; w * h];
        let image = frame_from_plane(&plane, w, h);
        let cfg = BackgroundConfig {
            grid: 3,
            poly_degree: 4,
            sample_box: 7,
            ..BackgroundConfig::default()
        };
        let err = extract_background(&image, &cfg).expect_err("must fail with too few samples");
        match err {
            BackgroundError::TooFewSamples {
                channel,
                samples,
                needed,
                degree,
            } => {
                assert_eq!(channel, 0);
                assert_eq!(degree, 4);
                assert_eq!(needed, poly_terms(4).len());
                assert!(
                    samples <= 9,
                    "3x3 grid yields at most 9 samples, got {samples}"
                );
            }
            other => panic!("expected TooFewSamples, got {other:?}"),
        }
    }

    #[test]
    fn empty_image_is_an_error() {
        let empty = ImageData::new(0, 0, 1, PixelType::U16);
        assert_eq!(
            extract_background(&empty, &BackgroundConfig::default()),
            Err(BackgroundError::EmptyImage)
        );
    }

    #[test]
    fn excessive_degree_is_rejected() {
        let plane = vec![1000.0_f64; 64 * 64];
        let image = frame_from_plane(&plane, 64, 64);
        let cfg = BackgroundConfig {
            poly_degree: MAX_POLY_DEGREE + 1,
            ..BackgroundConfig::default()
        };
        assert_eq!(
            extract_background(&image, &cfg),
            Err(BackgroundError::BadDegree {
                got: MAX_POLY_DEGREE + 1,
                max: MAX_POLY_DEGREE,
            })
        );
    }

    #[test]
    fn zero_grid_is_rejected() {
        let plane = vec![1000.0_f64; 64 * 64];
        let image = frame_from_plane(&plane, 64, 64);
        let cfg = BackgroundConfig {
            grid: 0,
            ..BackgroundConfig::default()
        };
        assert_eq!(
            extract_background(&image, &cfg),
            Err(BackgroundError::BadGrid(0))
        );
    }

    #[test]
    fn evaluate_out_of_range_channel_is_zero_not_panic() {
        let plane = vec![1500.0_f64; 80 * 80];
        let image = frame_from_plane(&plane, 80, 80);
        let model =
            extract_background(&image, &BackgroundConfig::default()).expect("flat fit succeeds");
        // Channel 5 does not exist on a mono model → safe zero.
        assert_eq!(model.evaluate(40.0, 40.0, 5), 0.0);
    }

    #[test]
    fn subtract_clamps_unsigned_at_zero() {
        // A flat frame whose level is BELOW the fitted background (constructed
        // by fitting on a brighter frame and subtracting from a dimmer one)
        // must clamp to 0, never wrap around.
        let bright = frame_from_plane(&vec![5000.0_f64; 64 * 64], 64, 64);
        let cfg = BackgroundConfig {
            poly_degree: 1,
            preserve_mean: false, // full subtraction, so a dimmer frame goes negative
            ..BackgroundConfig::default()
        };
        let model = extract_background(&bright, &cfg).expect("fit");
        let mut dim = frame_from_plane(&vec![100.0_f64; 64 * 64], 64, 64);
        subtract_background(&mut dim, &model);
        let pixels = dim.as_u16().unwrap();
        assert!(
            pixels.iter().all(|&v| v == 0),
            "subtracting a brighter background must clamp to 0, found nonzero pixels"
        );
    }

    #[test]
    fn preserve_mean_flattens_to_the_pedestal_not_to_zero() {
        // With preserve_mean a pure flat frame must come back ~unchanged (the
        // model IS the pedestal and we add it straight back).
        let level = 2345.0_f64;
        let image = frame_from_plane(&vec![level; 96 * 96], 96, 96);
        let cfg = BackgroundConfig {
            poly_degree: 2,
            preserve_mean: true,
            ..BackgroundConfig::default()
        };
        let (out, _model) = extract_and_subtract(&image, &cfg).expect("fit");
        let pixels: Vec<f64> = out.as_u16().unwrap().iter().map(|&v| v as f64).collect();
        let mean = pixels.iter().sum::<f64>() / pixels.len() as f64;
        assert!(
            (mean - level).abs() < 2.0,
            "preserve_mean on a flat frame must reproduce the pedestal {level}, got {mean}"
        );
    }

    #[test]
    fn multichannel_fits_each_channel_independently() {
        // Build a 2-channel frame where each channel has a different linear ramp;
        // the model must carry one coefficient set per channel and flatten both.
        let (w, h) = (128usize, 128usize);
        let mut data = vec![0u16; w * h * 2];
        for y in 0..h {
            for x in 0..w {
                let r = plane_gradient(x as f64, y as f64, 2000.0, 4.0, 0.0);
                let g = plane_gradient(x as f64, y as f64, 1500.0, 0.0, 5.0);
                let idx = (y * w + x) * 2;
                data[idx] = r.clamp(0.0, 65535.0) as u16;
                data[idx + 1] = g.clamp(0.0, 65535.0) as u16;
            }
        }
        let image = ImageData::from_u16(w as u32, h as u32, 2, &data);
        let cfg = BackgroundConfig {
            poly_degree: 1,
            preserve_mean: false,
            ..BackgroundConfig::default()
        };
        let model = extract_background(&image, &cfg).expect("two-channel fit");
        assert_eq!(model.channels, 2);
        assert_eq!(model.coeffs_per_channel.len(), 2);

        // Channel 0 ramps in x (b=4), channel 1 ramps in y (c=5). For a degree-1
        // fit in normalised coords the x/y linear coefficients differ in sign and
        // magnitude per channel — confirm they are genuinely independent.
        let c0 = &model.coeffs_per_channel[0];
        let c1 = &model.coeffs_per_channel[1];
        // term order: (0,0), (1,0)=x, (0,1)=y
        assert!(c0[1].abs() > c0[2].abs(), "ch0 should be x-dominated");
        assert!(c1[2].abs() > c1[1].abs(), "ch1 should be y-dominated");

        // After subtraction both channels are flat (std greatly reduced).
        let mut out = image.clone();
        subtract_background(&mut out, &model);
        let pixels = out.as_u16().unwrap();
        let mut ch0 = Vec::new();
        let mut ch1 = Vec::new();
        for (i, &v) in pixels.iter().enumerate() {
            if i % 2 == 0 {
                ch0.push(v as f64);
            } else {
                ch1.push(v as f64);
            }
        }
        assert!(
            std_dev(&ch0) < 50.0,
            "channel 0 not flattened, std {}",
            std_dev(&ch0)
        );
        assert!(
            std_dev(&ch1) < 50.0,
            "channel 1 not flattened, std {}",
            std_dev(&ch1)
        );
    }

    #[test]
    fn percentile_and_median_helpers_are_correct() {
        let mut v = vec![3.0, 1.0, 2.0];
        assert_eq!(median_f64(&mut v), 2.0);
        let mut v2 = vec![4.0, 1.0, 3.0, 2.0];
        assert_eq!(median_f64(&mut v2), 2.5);
        let mut p = vec![10.0, 20.0, 30.0, 40.0, 50.0];
        assert_eq!(percentile_f64(&mut p, 0.0), 10.0);
        assert_eq!(percentile_f64(&mut p, 1.0), 50.0);
        // Nearest-rank p=0.5 over 5 elements → idx round(2.0)=2 → value 30.
        assert_eq!(percentile_f64(&mut p, 0.5), 30.0);
    }

    #[test]
    fn read_write_pixel_roundtrips_each_type() {
        // f64 read/write must be exact; unsigned types saturate correctly.
        let cases = [
            (PixelType::U8, 200.0_f64, 200.0_f64),
            (PixelType::U8, 300.0, 255.0), // saturates high
            (PixelType::U8, -5.0, 0.0),    // saturates low
            (PixelType::U16, 40000.0, 40000.0),
            (PixelType::U16, 70000.0, 65535.0),
            (PixelType::U32, 1_000_000.0, 1_000_000.0),
            (PixelType::F32, 1.25, 1.25),
            (PixelType::F64, -12345.678, -12345.678),
        ];
        for (pt, input, expected) in cases {
            let mut buf = vec![0u8; pt.byte_size()];
            write_pixel(&mut buf, pt, input);
            let got = read_pixel(&buf, pt);
            assert!(
                (got - expected).abs() < 1e-6,
                "{pt:?}: wrote {input}, expected {expected}, read {got}"
            );
        }
    }
}
