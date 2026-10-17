//! Gradient removal on linear data: fit a smooth sky surface, subtract it, keep
//! the pedestal.
//!
//! Light pollution, moonlight, vignetting residual and amp glow leave a
//! low-spatial-frequency ramp across a master. The ramp is additive and slowly
//! varying, so it is separable from signal by fitting the *sky* — everywhere the
//! frame is not an object — and subtracting the fitted surface.
//!
//! # The estimate
//!
//! 1. A `grid × grid` lattice of square sample boxes covers the frame. Each box
//!    contributes one **sigma-clipped median**: the median of the window, then
//!    the median of what survives a ±[`BOX_CLIP_SIGMA`]·σ cut around it. A star
//!    covering a minority of a box cannot move that number.
//! 2. Boxes reached by a detected star's disk drop out. Stars are found by
//!    [`detect_stars`] over a peak-across-channels luminance plane, which keeps a
//!    star bright in one channel only.
//! 3. A preliminary surface is fitted to what is left, and boxes whose
//!    **residual** against it sits above the `exclusionPercentile` quantile drop
//!    out as object-dominated. The cut is on the residual, not the raw level:
//!    the gradient is the thing being fitted, so a raw-level cut would throw
//!    away the genuinely brighter end of a steep ramp and pull the surface with
//!    it.
//! 4. The survivors feed the crate's iterative residual-clipped least-squares
//!    polynomial fit ([`iterative_residual_fit`]), the same surface solver the
//!    post-session background extractor uses.
//!
//! # Why a polynomial and not an RBF
//!
//! The crate's surface machinery is a 2-D polynomial least-squares solve over
//! normalised coordinates, capped at degree 6 because the normal equations lose
//! conditioning beyond that. There is no radial-basis or thin-plate solver in
//! the tree, and inventing a second surface family would leave two fits that
//! disagree about the same sky. `modelOrder` therefore selects a polynomial
//! degree: 1 is a tilted plane, 2 a bowl (vignetting residual), 4 a rich
//! light-pollution ramp. Sharp localised glow is not representable by any of
//! them and is out of this operation's scope.
//!
//! # Flux scale
//!
//! The surface is subtracted **relative to its own median over the frame**,
//! never to zero: the output keeps the sky pedestal the master was integrated
//! at, so faint extended signal riding on that pedestal survives and downstream
//! photometry still sees a sky level. The median is taken over a regular lattice
//! spanning the whole frame rather than over the surviving samples, because
//! rejection concentrates the survivors wherever the sky was cleanest and a
//! pedestal read from them would inherit that bias. At `modelOrder = 0` the
//! surface is a constant, its median equals it, and the operation is an exact
//! clone of its input.

use rayon::prelude::*;
use serde_json::Value;

use crate::background_extraction::{
    eval_poly, iterative_residual_fit, normalise_xy, poly_terms, solve_poly_fit, Sample,
};
use crate::recipe::{DarkroomOp, OpContext, OpError, OpImage, OpStage, Params};
use crate::robust_stats::{median_in_place, percentile_nearest_rank, MAD_TO_SIGMA};
use crate::{detect_stars, ImageData, StarDetectionConfig};

/// Tightest sample spacing the fit accepts, in pixels.
const SAMPLE_SPACING_MIN: f64 = 8.0;
/// Widest sample spacing the fit accepts, in pixels.
const SAMPLE_SPACING_MAX: f64 = 1024.0;
/// Sample spacing when the parameter is absent, in pixels.
const SAMPLE_SPACING_DEFAULT: f64 = 64.0;

/// Lowest exclusion quantile: keeping under 5% of the boxes cannot determine a
/// surface on any realistic frame.
const EXCLUSION_PERCENTILE_MIN: f64 = 0.05;
/// Highest exclusion quantile; `1.0` keeps every box.
const EXCLUSION_PERCENTILE_MAX: f64 = 1.0;
/// Exclusion quantile when the parameter is absent: the top quarter of the
/// residual distribution is treated as object contamination.
const EXCLUSION_PERCENTILE_DEFAULT: f64 = 0.75;

/// Lowest polynomial degree; `0` is a constant surface and an exact clone.
const MODEL_ORDER_MIN: u32 = 0;
/// Highest polynomial degree the normal equations stay conditioned for.
const MODEL_ORDER_MAX: u32 = 6;
/// Polynomial degree when the parameter is absent.
const MODEL_ORDER_DEFAULT: u32 = 2;

/// Fewest sample boxes per axis. Six per axis is 36 boxes, one more than the 28
/// terms of the highest supported degree.
const GRID_MIN: usize = 6;
/// Most sample boxes per axis.
const GRID_MAX: usize = 256;

/// Sample box side as a fraction of the sample spacing, so boxes sample the sky
/// without tiling over it.
const SAMPLE_BOX_FRACTION: f64 = 0.25;
/// Narrowest sample box, in pixels.
const SAMPLE_BOX_MIN: usize = 3;
/// Widest sample box, in pixels.
const SAMPLE_BOX_MAX: usize = 63;

/// Sigma cut applied inside one sample box before its median is taken.
const BOX_CLIP_SIGMA: f64 = 3.0;
/// Low-side residual clip of the surface fit. Looser than the high side: a real
/// background dip is not a contaminant.
const RESIDUAL_CLIP_SIGMA_LOW: f64 = 3.0;
/// High-side residual clip of the surface fit. Tighter than the low side: star
/// wings and faint nebulosity are the outliers that bias a sky fit.
const RESIDUAL_CLIP_SIGMA_HIGH: f64 = 2.0;

/// Mask radius as a multiple of a detected star's HFR; three HFR covers the
/// visible disk plus its wings for a Gaussian PSF.
const STAR_MASK_RADIUS_FACTOR: f64 = 3.0;
/// Smallest mask radius, in pixels, so even a marginal detection protects a few
/// pixels.
const STAR_MASK_RADIUS_MIN: f64 = 3.0;
/// Largest mask radius as a fraction of the shortest side, so a bloated
/// detection cannot mask out the frame.
const STAR_MASK_RADIUS_FRACTION: f64 = 0.1;

/// Value the luminance plane's high quantile maps to before star detection,
/// leaving headroom below the detector's saturation limit.
const LUMINANCE_FULL_SCALE: f64 = 60_000.0;
/// Quantile of the luminance plane mapped to zero.
const LUMINANCE_LOW_QUANTILE: f64 = 0.001;
/// Quantile of the luminance plane mapped to [`LUMINANCE_FULL_SCALE`].
const LUMINANCE_HIGH_QUANTILE: f64 = 0.999;

/// Pixels sampled when estimating the luminance quantiles. The stride follows
/// from the pixel count, so it never depends on how the work is scheduled.
const LUMINANCE_SAMPLE_BUDGET: usize = 262_144;

/// Lattice points per axis used to read the fitted surface's median level. Odd,
/// so the frame centre is one of them.
const PEDESTAL_LATTICE: usize = 65;

/// Removes a smooth background gradient from linear data while preserving the
/// sky pedestal.
pub struct BackgroundExtractV1;

/// One step's validated parameters.
struct Settings {
    /// Distance between sample-box centres, in pixels at the render level.
    sample_spacing: f64,
    /// Quantile of the preliminary-fit residual distribution above which a box
    /// is dropped as object-contaminated.
    exclusion_percentile: f64,
    /// Degree of the fitted polynomial surface.
    model_order: usize,
}

/// A detected star's masked disk, in pixels at the render level.
struct StarDisk {
    /// Centre, x.
    x: f64,
    /// Centre, y.
    y: f64,
    /// Masked radius.
    radius: f64,
}

impl DarkroomOp for BackgroundExtractV1 {
    fn id(&self) -> &'static str {
        "background_extract"
    }

    fn version(&self) -> u32 {
        1
    }

    fn stage(&self) -> OpStage {
        OpStage::Linear
    }

    fn validate_params(&self, params: &Value) -> Result<(), OpError> {
        self.read_settings(params).map(|_| ())
    }

    fn apply(&self, image: &OpImage, params: &Value, ctx: &OpContext) -> Result<OpImage, OpError> {
        let settings = self.read_settings(params)?;
        ctx.check_cancel()?;

        let width = image.width() as usize;
        let height = image.height() as usize;
        let channels = image.channels() as usize;

        let terms = poly_terms(settings.model_order);
        let n_terms = terms.len();
        let spacing = (settings.sample_spacing * ctx.scale()).max(1.0);
        let grid = grid_for(width, height, spacing);
        let half_box = sample_box_half(spacing);

        let stars = self.star_mask(image, ctx)?;

        let mut coefficients = Vec::with_capacity(channels);
        let mut pedestals = Vec::with_capacity(channels);
        for channel in 0..channels {
            ctx.check_cancel()?;
            let plane = channel_plane(image, channel);
            let mut samples = collect_samples(&plane, width, height, grid, half_box, ctx)?;
            retain_unmasked_samples(&mut samples, &stars, half_box);
            self.require_enough(
                &samples,
                n_terms,
                settings.model_order,
                channel,
                "star masking",
            )?;

            let preliminary = solve_poly_fit(&samples, width, height, settings.model_order, n_terms)
                .ok_or_else(|| OpError::Failed {
                    op_id: self.id(),
                    op_version: self.version(),
                    reason: format!(
                        "channel {channel} background samples are degenerate, so no degree-{} surface is determined",
                        settings.model_order
                    ),
                })?;
            retain_low_residual_samples(
                &mut samples,
                &preliminary,
                &terms,
                width,
                height,
                settings.exclusion_percentile,
            );
            self.require_enough(
                &samples,
                n_terms,
                settings.model_order,
                channel,
                "the exclusion cut",
            )?;

            let coeffs = iterative_residual_fit(
                &mut samples,
                width,
                height,
                settings.model_order,
                n_terms,
                RESIDUAL_CLIP_SIGMA_LOW,
                RESIDUAL_CLIP_SIGMA_HIGH,
                channel,
            )
            .map_err(|source| OpError::Failed {
                op_id: self.id(),
                op_version: self.version(),
                reason: source.to_string(),
            })?;
            pedestals.push(surface_median(&coeffs, &terms, width, height));
            coefficients.push(coeffs);
        }

        let row_len = width * channels;
        let source = image.data();
        let mut out = vec![0.0_f32; image.len()];
        out.par_chunks_exact_mut(row_len)
            .enumerate()
            .for_each(|(y, row)| {
                if ctx.cancel_requested() {
                    return;
                }
                let source_row = &source[y * row_len..y * row_len + row_len];
                for x in 0..width {
                    let (nx, ny) = normalise_xy(x as f64, y as f64, width as u32, height as u32);
                    for channel in 0..channels {
                        let correction =
                            eval_poly(&coefficients[channel], &terms, nx, ny) - pedestals[channel];
                        let index = x * channels + channel;
                        row[index] = (source_row[index] as f64 - correction) as f32;
                    }
                }
            });
        ctx.check_cancel()?;

        image.with_data(out)
    }
}

impl BackgroundExtractV1 {
    /// Read and range-check one step's payload. `validate_params` and `apply`
    /// share this, so the two can never disagree about a default.
    fn read_settings(&self, params: &Value) -> Result<Settings, OpError> {
        let p = Params::new(self, params)?;
        p.allow(&["sampleSpacing", "exclusionPercentile", "modelOrder"])?;
        Ok(Settings {
            sample_spacing: p.f64_or(
                "sampleSpacing",
                SAMPLE_SPACING_MIN..=SAMPLE_SPACING_MAX,
                SAMPLE_SPACING_DEFAULT,
            )?,
            exclusion_percentile: p.f64_or(
                "exclusionPercentile",
                EXCLUSION_PERCENTILE_MIN..=EXCLUSION_PERCENTILE_MAX,
                EXCLUSION_PERCENTILE_DEFAULT,
            )?,
            model_order: p.u32_or(
                "modelOrder",
                MODEL_ORDER_MIN..=MODEL_ORDER_MAX,
                MODEL_ORDER_DEFAULT,
            )? as usize,
        })
    }

    /// Reject a sample set too small to determine the surface, rather than
    /// fitting one the data does not support.
    ///
    /// `after` names the rejection stage that emptied the set, and the message
    /// names the two parameters that widen it: a denser lattice puts more boxes
    /// between the stars, and a lower degree needs fewer of them.
    fn require_enough(
        &self,
        samples: &[Sample],
        n_terms: usize,
        model_order: usize,
        channel: usize,
        after: &str,
    ) -> Result<(), OpError> {
        if samples.len() >= n_terms {
            return Ok(());
        }
        Err(OpError::Failed {
            op_id: self.id(),
            op_version: self.version(),
            reason: format!(
                "channel {channel} kept {} clean background sample{} after {after} but a degree-{model_order} surface needs {n_terms}; lower modelOrder or sampleSpacing",
                samples.len(),
                if samples.len() == 1 { "" } else { "s" }
            ),
        })
    }

    /// Detected stars as masked disks, in pixels at the render level.
    ///
    /// Detection runs over a peak-across-channels luminance plane quantised to
    /// 16 bits between the plane's own [`LUMINANCE_LOW_QUANTILE`] and
    /// [`LUMINANCE_HIGH_QUANTILE`] levels, because the detector reads `U16` and
    /// a linear master's ADU scale is not known in advance. Quantiles rather
    /// than the extremes, so one cosmic ray cannot compress the whole plane.
    fn star_mask(&self, image: &OpImage, ctx: &OpContext) -> Result<Vec<StarDisk>, OpError> {
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
        let mut quantile_samples: Vec<f64> = luminance.iter().step_by(stride).copied().collect();
        quantile_samples.sort_unstable_by(f64::total_cmp);
        let low = percentile_nearest_rank(&quantile_samples, LUMINANCE_LOW_QUANTILE);
        let high = percentile_nearest_rank(&quantile_samples, LUMINANCE_HIGH_QUANTILE);
        if !low.is_finite() || !high.is_finite() || high <= low {
            // A luminance plane with no measurable range carries no detectable
            // star, so nothing is masked and every box stays in the fit.
            return Ok(Vec::new());
        }

        let span = high - low;
        let quantised: Vec<u16> = luminance
            .iter()
            .map(|&value| {
                (((value - low) / span) * LUMINANCE_FULL_SCALE).clamp(0.0, u16::MAX as f64) as u16
            })
            .collect();
        ctx.check_cancel()?;

        let frame = ImageData::from_u16(width as u32, height as u32, 1, &quantised);
        // Masking, not photometry: a compact star must still be masked, so the
        // sharpness ceiling is open and the area/HFR floors are low; the SNR
        // floor stays high enough that faint nebulosity is not called a star,
        // because nebulosity is signal the fit must step around, not mask.
        let config = StarDetectionConfig {
            max_sharpness: 1.0,
            min_area: 3,
            min_hfr: 0.5,
            min_snr: 3.0,
            ..StarDetectionConfig::default()
        };
        let radius_ceiling = width.min(height) as f64 * STAR_MASK_RADIUS_FRACTION;
        Ok(detect_stars(&frame, &config)
            .into_iter()
            .map(|star| StarDisk {
                x: star.x,
                y: star.y,
                radius: (STAR_MASK_RADIUS_FACTOR * star.hfr).clamp(
                    STAR_MASK_RADIUS_MIN,
                    STAR_MASK_RADIUS_MIN.max(radius_ceiling),
                ),
            })
            .collect())
    }
}

/// Sample boxes per axis for a spacing in render-level pixels.
///
/// The count is `shortest side / spacing`, so a preview at level `n` — where
/// both the side and the spacing have shrunk by the same factor — lays the same
/// lattice over the same sky as the full render.
fn grid_for(width: usize, height: usize, spacing: f64) -> usize {
    let shortest = width.min(height).max(1);
    let count = (shortest as f64 / spacing).round() as i64;
    (count.clamp(GRID_MIN as i64, GRID_MAX as i64) as usize).min(shortest)
}

/// Half-width of a sample box for a spacing in render-level pixels.
fn sample_box_half(spacing: f64) -> usize {
    let side = ((spacing * SAMPLE_BOX_FRACTION).round() as i64)
        .clamp(SAMPLE_BOX_MIN as i64, SAMPLE_BOX_MAX as i64) as usize;
    (side / 2).max(1)
}

/// One channel of an interleaved image as an `f64` plane.
fn channel_plane(image: &OpImage, channel: usize) -> Vec<f64> {
    let channels = image.channels() as usize;
    image
        .data()
        .iter()
        .skip(channel)
        .step_by(channels)
        .map(|&value| value as f64)
        .collect()
}

/// Lay the sample lattice and take every box's sigma-clipped median.
///
/// Box centres sit at the `(i + 0.5) / grid` fractional positions of each axis,
/// so the lattice is symmetric about the frame and a `grid` of 1 would be one
/// centred box.
fn collect_samples(
    plane: &[f64],
    width: usize,
    height: usize,
    grid: usize,
    half_box: usize,
    ctx: &OpContext,
) -> Result<Vec<Sample>, OpError> {
    let rows: Vec<Vec<Sample>> = (0..grid)
        .into_par_iter()
        .map(|gy| {
            if ctx.cancel_requested() {
                return Vec::new();
            }
            let cy = ((gy as f64 + 0.5) / grid as f64) * (height as f64 - 1.0);
            let mut row = Vec::with_capacity(grid);
            for gx in 0..grid {
                let cx = ((gx as f64 + 0.5) / grid as f64) * (width as f64 - 1.0);
                if let Some(value) = clipped_box_median(plane, width, height, cx, cy, half_box) {
                    row.push(Sample {
                        x: cx,
                        y: cy,
                        value,
                    });
                }
            }
            row
        })
        .collect();
    ctx.check_cancel()?;
    Ok(rows.into_iter().flatten().collect())
}

/// Median of the window around `(cx, cy)` after a ±[`BOX_CLIP_SIGMA`]·σ cut
/// about the window's own median. `None` when the window is empty.
fn clipped_box_median(
    plane: &[f64],
    width: usize,
    height: usize,
    cx: f64,
    cy: f64,
    half: usize,
) -> Option<f64> {
    let half = half as isize;
    let centre_x = cx.round() as isize;
    let centre_y = cy.round() as isize;
    let x0 = (centre_x - half).max(0) as usize;
    let x1 = ((centre_x + half).max(0) as usize).min(width - 1);
    let y0 = (centre_y - half).max(0) as usize;
    let y1 = ((centre_y + half).max(0) as usize).min(height - 1);
    if x1 < x0 || y1 < y0 {
        return None;
    }

    let mut window = Vec::with_capacity((x1 - x0 + 1) * (y1 - y0 + 1));
    for y in y0..=y1 {
        let base = y * width;
        for x in x0..=x1 {
            window.push(plane[base + x]);
        }
    }
    let centre = median_in_place(&mut window);
    let mut deviations: Vec<f64> = window.iter().map(|value| (value - centre).abs()).collect();
    let sigma = median_in_place(&mut deviations) * MAD_TO_SIGMA;
    if sigma <= 0.0 {
        return Some(centre);
    }
    let low = centre - BOX_CLIP_SIGMA * sigma;
    let high = centre + BOX_CLIP_SIGMA * sigma;
    window.retain(|value| *value >= low && *value <= high);
    if window.is_empty() {
        return Some(centre);
    }
    Some(median_in_place(&mut window))
}

/// Drop boxes a detected star's disk reaches into, and boxes holding no
/// measurable level.
fn retain_unmasked_samples(samples: &mut Vec<Sample>, stars: &[StarDisk], half_box: usize) {
    let reach_of_box = half_box as f64;
    samples.retain(|sample| {
        if !sample.value.is_finite() {
            return false;
        }
        !stars.iter().any(|star| {
            let dx = sample.x - star.x;
            let dy = sample.y - star.y;
            let reach = star.radius + reach_of_box;
            dx * dx + dy * dy <= reach * reach
        })
    });
}

/// Drop boxes whose residual against a preliminary surface sits above the
/// `exclusion_percentile` quantile of the residual distribution.
///
/// The quantile is taken over every surviving box before any is removed, so the
/// threshold describes the field rather than the subset it produces. At
/// `exclusion_percentile = 1.0` the ceiling is the largest residual and nothing
/// is dropped.
fn retain_low_residual_samples(
    samples: &mut Vec<Sample>,
    coeffs: &[f64],
    terms: &[(u32, u32)],
    width: usize,
    height: usize,
    exclusion_percentile: f64,
) {
    if samples.is_empty() {
        return;
    }
    let residual_of = |sample: &Sample| {
        let (nx, ny) = normalise_xy(sample.x, sample.y, width as u32, height as u32);
        sample.value - eval_poly(coeffs, terms, nx, ny)
    };
    let mut residuals: Vec<f64> = samples.iter().map(residual_of).collect();
    residuals.sort_unstable_by(f64::total_cmp);
    let ceiling = percentile_nearest_rank(&residuals, exclusion_percentile);
    samples.retain(|sample| {
        let residual = residual_of(sample);
        !residual.is_nan() && residual <= ceiling
    });
}

/// Median level of the fitted surface over the frame — the pedestal the
/// subtraction leaves behind.
///
/// Read from a regular [`PEDESTAL_LATTICE`]-per-axis lattice spanning the whole
/// frame, so it describes the sky the frame covers rather than wherever the
/// surviving samples happened to concentrate.
fn surface_median(coeffs: &[f64], terms: &[(u32, u32)], width: usize, height: usize) -> f64 {
    let last = PEDESTAL_LATTICE as f64 - 1.0;
    let mut levels = Vec::with_capacity(PEDESTAL_LATTICE * PEDESTAL_LATTICE);
    for row in 0..PEDESTAL_LATTICE {
        let y = (row as f64 / last) * (height as f64 - 1.0);
        for column in 0..PEDESTAL_LATTICE {
            let x = (column as f64 / last) * (width as f64 - 1.0);
            let (nx, ny) = normalise_xy(x, y, width as u32, height as u32);
            levels.push(eval_poly(coeffs, terms, nx, ny));
        }
    }
    median_in_place(&mut levels)
}

#[cfg(test)]
#[path = "background_extract_tests.rs"]
mod background_extract_tests;
