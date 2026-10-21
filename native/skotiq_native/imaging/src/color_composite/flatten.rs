//! Flattening each registered master before its channels are combined.
//!
//! A color composite reads every pixel's color from the ratio of its channels,
//! so anything that varies across the field differently in each filter becomes a
//! color that varies across the field. Three things do, on masters integrated
//! without flat fields:
//!
//! * **Throughput.** A filter whose transmission falls toward one edge (its own
//!   vignetting, haze through part of that filter's subframes) dims every star
//!   there in that filter alone, and the stars change color across the field.
//!   The sky does not show it: the sky's own gradient is dominated by light
//!   pollution, which is additive. The throughput is therefore read from the
//!   stars: aperture photometry of the same isolated, unsaturated stars in each
//!   plane and in the reference plane (the luminance master, or the mean of the
//!   color planes), and a low-degree polynomial fitted to `log10(plane / reference)`
//!   across the field. Each plane is divided by the fitted surface, normalised
//!   to its own median so the field's overall balance is left to color
//!   calibration. The degree (0, 1 or 2) is chosen by the Bayesian information
//!   criterion, so a plane whose stars show no trend gets no correction.
//! * **Sky gradient.** Each plane's sky is fitted with the polynomial surface
//!   `background_extract@1` fits ([`fit_plane`]), its degree chosen per plane
//!   among [`BACKGROUND_DEGREES`], and subtracted relative to its own median so
//!   the plane keeps its sky pedestal.
//! * **Color mottle.** Per-filter dust shadows and vignetting residue are
//!   smaller than any polynomial can follow, and the RGB masters carry each at a
//!   different place. [`flatten_chroma`] measures every color plane's sky on a
//!   lattice of boxes and removes, from each plane, only the part of its
//!   box-scale structure that differs from the planes' common structure. The
//!   lightness of the sky is untouched; its color is made uniform. Boxes that
//!   hold the target, a bright halo or anything else brighter than the sky
//!   around it are rejected and filled from their neighbors, so an object's own
//!   color is never measured as sky.
//!
//! The throughput and sky surfaces are measured once and pinned in the step's
//! parameters (see `channel_combine@1`); the chroma lattice is re-measured at
//! every render, because it follows the sky at the scale the render sees.

use rayon::prelude::*;
use serde_json::{json, Value};

use crate::background_extraction::{eval_poly, normalise_xy, poly_terms};
use crate::recipe::ops::background_extract::{fit_plane, star_disks, Settings, StarDisk};
use crate::recipe::{OpContext, OpError, OpImage};
use crate::robust_stats::{median_in_place, MAD_TO_SIGMA};
use crate::{detect_stars, StarDetectionConfig};

/// Highest polynomial degree a pinned surface may carry.
pub const SURFACE_DEGREE_MAX: usize = 6;

/// Degrees the throughput surface is chosen among.
const THROUGHPUT_DEGREES: [usize; 3] = [0, 1, 2];
/// How much lower a higher degree's Bayesian information criterion must be for
/// it to be preferred: strong evidence on the conventional scale.
const THROUGHPUT_BIC_MARGIN: f64 = 10.0;
/// Fewest stars a throughput term is fitted from, per polynomial term.
const THROUGHPUT_STARS_PER_TERM: usize = 15;
/// Iterations of the throughput fit's residual clip.
const THROUGHPUT_CLIP_ITERATIONS: usize = 8;
/// Residual clip of the throughput fit, in robust sigmas: a star's own color
/// is the scatter, and a blend or a variable is the outlier.
const THROUGHPUT_CLIP_SIGMA: f64 = 3.0;

/// Degrees the sky surface is chosen among. Vignetting without a flat field is
/// a radial bowl with a steep rim, which degree 2 cannot follow.
pub const BACKGROUND_DEGREES: [usize; 4] = [2, 3, 4, 5];
/// The lowest degree whose sky residual is within this factor of the best
/// degree's residual is kept: a surface that bends more must earn it.
const BACKGROUND_DEGREE_GAIN: f64 = 0.8;
/// Sample-box spacing of the sky fit, in full-resolution pixels.
const BACKGROUND_SPACING_PX: f64 = 64.0;
/// Quantile of the preliminary-fit residuals above which a sky box is treated
/// as object; the operation's own default.
const BACKGROUND_EXCLUSION: f64 = 0.75;

/// Default side of a chroma lattice box, in full-resolution pixels.
pub const CHROMA_BOX_DEFAULT: f64 = 64.0;
/// Smallest chroma box side at the render level, in pixels.
const CHROMA_BOX_MIN_PX: usize = 4;
/// Fewest boxes per axis the chroma lattice needs to separate the sky's
/// structure from its trend.
const CHROMA_GRID_MIN: usize = 8;
/// Side, in boxes, of the median filter that gives the lattice's trend.
const CHROMA_TREND_BOXES: usize = 9;
/// A box brighter than the trend by this many robust sigmas holds an object.
const CHROMA_OBJECT_SIGMA: f64 = 5.0;
/// Boxes an object box's rejection grows by, so a halo's edge goes with it.
const CHROMA_OBJECT_GROW: usize = 2;
/// Sigma clip inside one chroma box before its median is taken.
const CHROMA_BOX_CLIP_SIGMA: f64 = 3.0;

/// Aperture radius as a multiple of a star's HFR.
const APERTURE_HFR: f64 = 2.5;
/// Inner and outer radius of a star's sky annulus, as multiples of its HFR.
const ANNULUS_HFR: (f64, f64) = (4.0, 6.0);
/// Smallest aperture radius, in render pixels.
const APERTURE_MIN_PX: f64 = 2.0;
/// A star whose detected peak exceeds this fraction of the brightest star's
/// peak may be saturated in some plane and is left out of photometry.
const PHOTOMETRY_PEAK_FRACTION: f64 = 0.5;
/// Lowest detection SNR of a photometry star.
const PHOTOMETRY_MIN_SNR: f64 = 30.0;
/// A photometry star has no other detection within this many of its HFRs.
const ISOLATION_HFR: f64 = 8.0;

/// A polynomial over normalised frame coordinates.
#[derive(Debug, Clone, PartialEq)]
pub struct Surface {
    /// Total degree.
    pub degree: usize,
    /// Coefficients in [`poly_terms`] order.
    pub coefficients: Vec<f64>,
}

impl Surface {
    /// The surface as step-parameter JSON.
    pub fn to_json(&self) -> Value {
        json!({"degree": self.degree, "coefficients": self.coefficients})
    }

    /// Read a surface a step carries.
    pub fn from_json(value: &Value) -> Result<Self, String> {
        let degree = value
            .get("degree")
            .and_then(Value::as_u64)
            .ok_or("a surface needs an integer degree")? as usize;
        if degree > SURFACE_DEGREE_MAX {
            return Err(format!(
                "a surface degree of {degree} is above the highest supported, {SURFACE_DEGREE_MAX}"
            ));
        }
        let coefficients: Vec<f64> = value
            .get("coefficients")
            .and_then(Value::as_array)
            .ok_or("a surface needs a coefficient list")?
            .iter()
            .map(|c| c.as_f64().filter(|c| c.is_finite()))
            .collect::<Option<_>>()
            .ok_or("every surface coefficient must be a finite number")?;
        let expected = (degree + 1) * (degree + 2) / 2;
        if coefficients.len() != expected {
            return Err(format!(
                "a degree-{degree} surface has {expected} coefficients, not {}",
                coefficients.len()
            ));
        }
        Ok(Self {
            degree,
            coefficients,
        })
    }

    /// The surface's value at every pixel of a `width x height` plane, row by
    /// row, handed to `apply` with the plane's row.
    fn for_each_row(
        &self,
        plane: &mut [f32],
        width: usize,
        height: usize,
        apply: impl Fn(&mut f32, f64) + Sync,
    ) {
        let terms = poly_terms(self.degree);
        plane
            .par_chunks_exact_mut(width)
            .enumerate()
            .for_each(|(y, row)| {
                for (x, value) in row.iter_mut().enumerate() {
                    let (nx, ny) = normalise_xy(x as f64, y as f64, width as u32, height as u32);
                    apply(value, eval_poly(&self.coefficients, &terms, nx, ny));
                }
            });
    }

    /// Median of the surface over a regular lattice spanning the frame.
    fn median(&self, width: usize, height: usize) -> f64 {
        crate::recipe::ops::background_extract::surface_median(
            &self.coefficients,
            &poly_terms(self.degree),
            width,
            height,
        )
    }
}

/// Divide `plane` by the throughput `surface` (a `log10` gain).
pub fn apply_throughput(plane: &mut [f32], width: usize, height: usize, surface: &Surface) {
    if surface.degree == 0 && surface.coefficients[0] == 0.0 {
        return;
    }
    surface.for_each_row(plane, width, height, |value, gain| {
        *value = (*value as f64 / 10f64.powf(gain)) as f32;
    });
}

/// Subtract the sky `surface` from `plane`, keeping its median as the pedestal.
pub fn apply_background(plane: &mut [f32], width: usize, height: usize, surface: &Surface) {
    let pedestal = surface.median(width, height);
    surface.for_each_row(plane, width, height, |value, level| {
        *value = (*value as f64 - (level - pedestal)) as f32;
    });
}

/// Stars every plane is measured at: the reference plane's detections, the
/// ones bright, unsaturated and isolated enough to photometer, and every
/// detection as a mask disk for the sky fit.
pub struct FieldStars {
    photometry: Vec<PhotometryStar>,
    disks: Vec<StarDisk>,
}

#[derive(Debug, Clone, Copy)]
struct PhotometryStar {
    x: f64,
    y: f64,
    hfr: f64,
}

impl FieldStars {
    /// Detect the field's stars in `reference`, a single-plane image.
    pub fn detect(reference: &OpImage, ctx: &OpContext) -> Result<Self, OpError> {
        let disks = star_disks(reference, ctx)?;
        let photometry = match crate::recipe::ops::star_detect::detection_frame(reference, ctx)? {
            Some(frame) => select_photometry(detect_stars(&frame, &StarDetectionConfig::default())),
            None => Vec::new(),
        };
        Ok(Self { photometry, disks })
    }

    /// Stars the throughput fit can use.
    pub fn photometry_count(&self) -> usize {
        self.photometry.len()
    }
}

fn select_photometry(stars: Vec<crate::DetectedStar>) -> Vec<PhotometryStar> {
    let brightest = stars.iter().map(|s| s.peak).fold(0.0_f64, f64::max);
    let points: Vec<(f64, f64, f64)> = stars.iter().map(|s| (s.x, s.y, s.hfr)).collect();
    stars
        .iter()
        .filter(|s| {
            s.snr >= PHOTOMETRY_MIN_SNR
                && s.peak <= PHOTOMETRY_PEAK_FRACTION * brightest
                && s.hfr.is_finite()
                && s.hfr > 0.0
        })
        .filter(|s| {
            let reach = ISOLATION_HFR * s.hfr;
            !points.iter().any(|(x, y, _)| {
                let d2 = (x - s.x).powi(2) + (y - s.y).powi(2);
                d2 > 0.0 && d2 <= reach * reach
            })
        })
        .map(|s| PhotometryStar {
            x: s.x,
            y: s.y,
            hfr: s.hfr,
        })
        .collect()
}

/// Background-subtracted aperture flux of `star` in `plane`, or `None` near an
/// edge or without enough annulus.
fn aperture_flux(plane: &[f32], width: usize, height: usize, star: &PhotometryStar) -> Option<f64> {
    let aperture = (APERTURE_HFR * star.hfr).max(APERTURE_MIN_PX);
    let inner = (ANNULUS_HFR.0 * star.hfr).max(aperture + 1.0);
    let outer = (ANNULUS_HFR.1 * star.hfr).max(inner + 2.0);
    let reach = outer.ceil() as i64;
    let (cx, cy) = (star.x.round() as i64, star.y.round() as i64);
    if cx - reach < 0 || cy - reach < 0 || cx + reach >= width as i64 || cy + reach >= height as i64
    {
        return None;
    }
    let mut sum = 0.0;
    let mut count = 0.0;
    let mut annulus = Vec::new();
    for y in cy - reach..=cy + reach {
        for x in cx - reach..=cx + reach {
            let d2 = (x as f64 - star.x).powi(2) + (y as f64 - star.y).powi(2);
            let v = plane[y as usize * width + x as usize] as f64;
            if !v.is_finite() {
                return None;
            }
            if d2 <= aperture * aperture {
                sum += v;
                count += 1.0;
            } else if d2 >= inner * inner && d2 <= outer * outer {
                annulus.push(v);
            }
        }
    }
    if annulus.len() < 8 || count == 0.0 {
        return None;
    }
    let sky = median_in_place(&mut annulus);
    Some(sum - sky * count)
}

/// The throughput fit of one plane.
#[derive(Debug, Clone)]
pub struct ThroughputFit {
    /// `log10(plane / reference)` across the field, normalised to median zero.
    pub surface: Surface,
    /// Stars the final fit kept.
    pub stars: usize,
    /// Robust scatter of the stars about the surface, in dex.
    pub scatter_dex: f64,
    /// Peak-to-peak range of the surface over the frame, in dex.
    pub range_dex: f64,
}

impl ThroughputFit {
    /// The fit as a step measurement.
    pub fn report(&self) -> Value {
        json!({
            "degree": self.surface.degree,
            "coefficients": self.surface.coefficients,
            "stars": self.stars,
            "scatterDex": self.scatter_dex,
            "rangeDex": self.range_dex,
        })
    }
}

/// Fit the throughput of `plane` relative to `reference` from the field's
/// stars. `None` when too few stars measure in both to fit even a constant.
pub fn measure_throughput(
    plane: &[f32],
    reference: &[f32],
    width: usize,
    height: usize,
    stars: &FieldStars,
) -> Option<ThroughputFit> {
    let samples: Vec<(f64, f64, f64)> = stars
        .photometry
        .iter()
        .filter_map(|star| {
            let f = aperture_flux(plane, width, height, star)?;
            let r = aperture_flux(reference, width, height, star)?;
            (f > 0.0 && r > 0.0).then(|| {
                let (nx, ny) = normalise_xy(star.x, star.y, width as u32, height as u32);
                (nx, ny, (f / r).log10())
            })
        })
        .collect();
    let mut best: Option<(f64, Vec<f64>, usize, usize, f64)> = None;
    for degree in THROUGHPUT_DEGREES {
        let terms = poly_terms(degree);
        if samples.len() < THROUGHPUT_STARS_PER_TERM * terms.len() {
            break;
        }
        let Some((coefficients, kept, sigma)) = clipped_fit(&samples, &terms) else {
            continue;
        };
        let n = kept as f64;
        let bic = n * (sigma * sigma).max(1e-30).ln() + terms.len() as f64 * n.ln();
        let better = match &best {
            None => true,
            Some((best_bic, ..)) => bic < best_bic - THROUGHPUT_BIC_MARGIN,
        };
        if better {
            best = Some((bic, coefficients, degree, kept, sigma));
        }
    }
    let (_, mut coefficients, degree, kept, sigma) = best?;
    let mut surface = Surface {
        degree,
        coefficients: coefficients.clone(),
    };
    let median = surface.median(width, height);
    coefficients[0] -= median;
    surface.coefficients = coefficients;
    let (lo, hi) = surface_range(&surface, width, height);
    Some(ThroughputFit {
        surface,
        stars: kept,
        scatter_dex: sigma,
        range_dex: hi - lo,
    })
}

/// Least squares of `v` on the terms, refitted after a symmetric residual clip
/// until the kept set stops changing.
fn clipped_fit(
    samples: &[(f64, f64, f64)],
    terms: &[(u32, u32)],
) -> Option<(Vec<f64>, usize, f64)> {
    let mut keep = vec![true; samples.len()];
    let mut result = None;
    for _ in 0..THROUGHPUT_CLIP_ITERATIONS {
        let kept: Vec<&(f64, f64, f64)> = samples
            .iter()
            .zip(&keep)
            .filter_map(|(s, k)| k.then_some(s))
            .collect();
        if kept.len() < terms.len() {
            return result;
        }
        let coefficients = least_squares(&kept, terms)?;
        let residuals: Vec<f64> = samples
            .iter()
            .map(|(x, y, v)| v - eval_poly(&coefficients, terms, *x, *y))
            .collect();
        let mut kept_residuals: Vec<f64> = residuals
            .iter()
            .zip(&keep)
            .filter_map(|(r, k)| k.then_some(*r))
            .collect();
        let centre = median_in_place(&mut kept_residuals.clone());
        let mut deviations: Vec<f64> = kept_residuals
            .iter_mut()
            .map(|r| (*r - centre).abs())
            .collect();
        let sigma = median_in_place(&mut deviations) * MAD_TO_SIGMA;
        let next: Vec<bool> = residuals
            .iter()
            .map(|r| (r - centre).abs() <= THROUGHPUT_CLIP_SIGMA * sigma.max(1e-12))
            .collect();
        let count = next.iter().filter(|k| **k).count();
        let stable = next == keep;
        result = Some((coefficients, keep.iter().filter(|k| **k).count(), sigma));
        if stable || count < terms.len() {
            break;
        }
        keep = next;
    }
    result
}

/// Normal-equation least squares over normalised coordinates.
fn least_squares(samples: &[&(f64, f64, f64)], terms: &[(u32, u32)]) -> Option<Vec<f64>> {
    let n = terms.len();
    let mut ata = vec![0.0; n * n];
    let mut atb = vec![0.0; n];
    for (x, y, v) in samples {
        let row: Vec<f64> = terms
            .iter()
            .map(|&(i, j)| x.powi(i as i32) * y.powi(j as i32))
            .collect();
        for a in 0..n {
            atb[a] += row[a] * v;
            for b in 0..n {
                ata[a * n + b] += row[a] * row[b];
            }
        }
    }
    solve_dense(ata, atb)
}

/// Gaussian elimination with partial pivoting; `None` for a singular system.
fn solve_dense(mut a: Vec<f64>, mut b: Vec<f64>) -> Option<Vec<f64>> {
    let n = b.len();
    for col in 0..n {
        let pivot =
            (col..n).max_by(|&p, &q| a[p * n + col].abs().total_cmp(&a[q * n + col].abs()))?;
        if a[pivot * n + col].abs() < 1e-12 {
            return None;
        }
        if pivot != col {
            for k in 0..n {
                a.swap(col * n + k, pivot * n + k);
            }
            b.swap(col, pivot);
        }
        for row in col + 1..n {
            let factor = a[row * n + col] / a[col * n + col];
            for k in col..n {
                a[row * n + k] -= factor * a[col * n + k];
            }
            b[row] -= factor * b[col];
        }
    }
    let mut x = vec![0.0; n];
    for row in (0..n).rev() {
        let mut acc = b[row];
        for k in row + 1..n {
            acc -= a[row * n + k] * x[k];
        }
        x[row] = acc / a[row * n + row];
    }
    x.iter().all(|v| v.is_finite()).then_some(x)
}

fn surface_range(surface: &Surface, width: usize, height: usize) -> (f64, f64) {
    let terms = poly_terms(surface.degree);
    let mut lo = f64::INFINITY;
    let mut hi = f64::NEG_INFINITY;
    const STEPS: usize = 33;
    for row in 0..STEPS {
        for col in 0..STEPS {
            let x = col as f64 / (STEPS - 1) as f64 * (width as f64 - 1.0);
            let y = row as f64 / (STEPS - 1) as f64 * (height as f64 - 1.0);
            let (nx, ny) = normalise_xy(x, y, width as u32, height as u32);
            let v = eval_poly(&surface.coefficients, &terms, nx, ny);
            lo = lo.min(v);
            hi = hi.max(v);
        }
    }
    (lo, hi)
}

/// The sky fit of one plane, with the residual every candidate degree left.
#[derive(Debug, Clone)]
pub struct BackgroundFit {
    /// The chosen surface.
    pub surface: Surface,
    /// `(degree, residual sigma)` for every degree tried.
    pub residual_by_degree: Vec<(usize, f64)>,
}

impl BackgroundFit {
    /// The fit as a step measurement.
    pub fn report(&self) -> Value {
        json!({
            "degree": self.surface.degree,
            "coefficients": self.surface.coefficients,
            "residualByDegree": self
                .residual_by_degree
                .iter()
                .map(|(d, s)| json!({"degree": d, "residualSigma": s}))
                .collect::<Vec<_>>(),
        })
    }
}

/// Fit the sky of `plane` at every degree in [`BACKGROUND_DEGREES`] and keep
/// the lowest whose residual is within [`BACKGROUND_DEGREE_GAIN`] of the best,
/// or already at the floor the sample boxes' own noise sets: below that floor a
/// lower residual is the fit following noise, not sky.
///
/// `Ok(None)` when no degree could be fitted, which leaves the plane as it is.
pub fn measure_background(
    plane: &[f32],
    width: usize,
    height: usize,
    stars: &FieldStars,
    ctx: &OpContext,
) -> Result<Option<BackgroundFit>, OpError> {
    let values: Vec<f64> = plane.iter().map(|v| *v as f64).collect();
    let mut fits = Vec::new();
    for degree in BACKGROUND_DEGREES {
        let settings = Settings {
            sample_spacing: BACKGROUND_SPACING_PX,
            exclusion_percentile: BACKGROUND_EXCLUSION,
            model_order: degree,
        };
        if let Ok(fit) = fit_plane(
            &values,
            width,
            height,
            &settings,
            &stars.disks,
            "plane",
            ctx,
        )? {
            // A surface with barely more samples than terms passes through
            // them, and its residual says nothing about the sky between them.
            if fit.samples_used >= 2 * (degree + 1) * (degree + 2) / 2 {
                fits.push((degree, fit));
            }
        }
    }
    let best = fits
        .iter()
        .map(|(_, f)| f.residual_sigma)
        .fold(f64::INFINITY, f64::min);
    let good_enough = (best / BACKGROUND_DEGREE_GAIN).max(sample_noise_floor(plane, width, ctx));
    let Some((degree, fit)) = fits.iter().find(|(_, f)| f.residual_sigma <= good_enough) else {
        return Ok(None);
    };
    Ok(Some(BackgroundFit {
        surface: Surface {
            degree: *degree,
            coefficients: fit.coefficients.clone(),
        },
        residual_by_degree: fits.iter().map(|(d, f)| (*d, f.residual_sigma)).collect(),
    }))
}

/// Twice the noise of one sky sample box's median: the residual a surface that
/// follows the sky exactly still shows.
///
/// The pixel noise is read from differences of horizontally adjacent pixels,
/// which a gradient or vignetting barely moves, rather than from the plane's
/// own spread, which they dominate.
fn sample_noise_floor(plane: &[f32], width: usize, ctx: &OpContext) -> f64 {
    let stride = (plane.len() / 262_144).max(1);
    let mut differences: Vec<f64> = (0..plane.len().saturating_sub(1))
        .step_by(stride)
        .filter(|i| (i + 1) % width != 0)
        .map(|i| plane[i + 1] as f64 - plane[i] as f64)
        .filter(|v| v.is_finite())
        .collect();
    if differences.is_empty() {
        return 0.0;
    }
    let centre = median_in_place(&mut differences.clone());
    let mut deviations: Vec<f64> = differences
        .iter_mut()
        .map(|v| (*v - centre).abs())
        .collect();
    let sigma = median_in_place(&mut deviations) * MAD_TO_SIGMA / std::f64::consts::SQRT_2;
    let side = crate::recipe::ops::background_extract::sample_box_side(
        (BACKGROUND_SPACING_PX * ctx.scale()).max(1.0),
    ) as f64;
    // The median of n Gaussian samples has a standard error of 1.2533 sigma/sqrt(n).
    2.0 * 1.2533 * sigma / side
}

/// What [`flatten_chroma`] did.
#[derive(Debug, Clone, PartialEq)]
pub struct ChromaFlatten {
    /// Box side at the render level, in pixels.
    pub box_px: usize,
    /// Boxes per axis.
    pub grid: (usize, usize),
    /// Boxes rejected as object and filled from their neighbors.
    pub object_boxes: usize,
    /// Robust spread, per plane, of the structure removed, in the plane's units.
    pub removed_sigma: [f64; 3],
}

impl ChromaFlatten {
    /// The pass as a step measurement.
    pub fn report(&self) -> Value {
        json!({
            "boxPx": self.box_px,
            "grid": [self.grid.0, self.grid.1],
            "objectBoxes": self.object_boxes,
            "removedSigma": self.removed_sigma,
        })
    }
}

/// Make the sky's color uniform across three registered planes.
///
/// Each plane's sky is read as the sigma-clipped median of every `box_px`
/// square. With `m̄` the planes' mean lattice and `k_c` each plane's median
/// over `m̄`'s median, plane `c` loses `m_c − k_c·m̄` — its structure beyond
/// what it shares, in proportion, with the other two — so the sky's lightness
/// keeps its shape and only its color is flattened. Boxes brighter than the
/// lattice's own trend (a 9-box median) by [`CHROMA_OBJECT_SIGMA`] are object
/// and are filled from their neighbors before the correction is interpolated
/// back to pixels. Each box's median is already a robust average of thousands
/// of pixels, so the lattice is not smoothed further: a dust shadow two boxes
/// wide is exactly the structure being removed.
///
/// `None` when the frame is too small for a lattice of [`CHROMA_GRID_MIN`]
/// boxes per axis.
pub fn flatten_chroma(
    planes: [&mut [f32]; 3],
    width: usize,
    height: usize,
    box_px: usize,
) -> Option<ChromaFlatten> {
    let box_px = box_px.max(CHROMA_BOX_MIN_PX);
    let (gw, gh) = (width / box_px, height / box_px);
    if gw < CHROMA_GRID_MIN || gh < CHROMA_GRID_MIN {
        return None;
    }
    let lattices: Vec<Vec<f64>> = planes
        .iter()
        .map(|plane| box_medians(plane, width, box_px, gw, gh))
        .collect();
    let mean: Vec<f64> = (0..gw * gh)
        .map(|i| (lattices[0][i] + lattices[1][i] + lattices[2][i]) / 3.0)
        .collect();
    let objects = object_boxes(&mean, gw, gh);
    let object_count = objects.iter().filter(|o| **o).count();
    let mean_level = median_in_place(&mut mean.clone());

    let mut removed_sigma = [0.0; 3];
    for (c, plane) in planes.into_iter().enumerate() {
        let level = median_in_place(&mut lattices[c].clone());
        let k = if mean_level.abs() > 0.0 {
            level / mean_level
        } else {
            1.0
        };
        let mut delta: Vec<Option<f64>> = (0..gw * gh)
            .map(|i| {
                let d = lattices[c][i] - k * mean[i];
                (!objects[i] && d.is_finite()).then_some(d)
            })
            .collect();
        fill_from_neighbors(&mut delta, gw, gh);
        // Every box is filled now, so flattening keeps one value per box.
        let mut delta: Vec<f64> = delta.into_iter().flatten().collect();
        let centre = median_in_place(&mut delta.clone());
        delta.iter_mut().for_each(|d| *d -= centre);
        let mut deviations: Vec<f64> = delta.iter().map(|d| d.abs()).collect();
        removed_sigma[c] = median_in_place(&mut deviations) * MAD_TO_SIGMA;
        plane
            .par_chunks_exact_mut(width)
            .enumerate()
            .for_each(|(y, row)| {
                let gy = (y as f64 + 0.5) / box_px as f64 - 0.5;
                for (x, value) in row.iter_mut().enumerate() {
                    let gx = (x as f64 + 0.5) / box_px as f64 - 0.5;
                    *value = (*value as f64 - bilinear(&delta, gw, gh, gx, gy)) as f32;
                }
            });
    }
    Some(ChromaFlatten {
        box_px,
        grid: (gw, gh),
        object_boxes: object_count,
        removed_sigma,
    })
}

fn box_medians(plane: &[f32], width: usize, box_px: usize, gw: usize, gh: usize) -> Vec<f64> {
    (0..gw * gh)
        .into_par_iter()
        .map(|i| {
            let (bx, by) = (i % gw, i / gw);
            let mut window: Vec<f64> = Vec::with_capacity(box_px * box_px);
            for y in by * box_px..(by + 1) * box_px {
                let row = &plane[y * width + bx * box_px..y * width + (bx + 1) * box_px];
                window.extend(row.iter().map(|v| *v as f64).filter(|v| v.is_finite()));
            }
            if window.is_empty() {
                return f64::NAN;
            }
            let centre = median_in_place(&mut window.clone());
            let mut deviations: Vec<f64> = window.iter().map(|v| (v - centre).abs()).collect();
            let sigma = median_in_place(&mut deviations) * MAD_TO_SIGMA;
            if sigma > 0.0 {
                window.retain(|v| (v - centre).abs() <= CHROMA_BOX_CLIP_SIGMA * sigma);
            }
            if window.is_empty() {
                centre
            } else {
                median_in_place(&mut window)
            }
        })
        .collect()
}

fn object_boxes(mean: &[f64], gw: usize, gh: usize) -> Vec<bool> {
    let trend = median_filter(mean, gw, gh, CHROMA_TREND_BOXES);
    let excess: Vec<f64> = mean.iter().zip(&trend).map(|(m, t)| m - t).collect();
    let mut finite: Vec<f64> = excess.iter().copied().filter(|v| v.is_finite()).collect();
    if finite.is_empty() {
        return vec![false; mean.len()];
    }
    let centre = median_in_place(&mut finite.clone());
    let mut deviations: Vec<f64> = finite.iter_mut().map(|v| (*v - centre).abs()).collect();
    let sigma = median_in_place(&mut deviations) * MAD_TO_SIGMA;
    let seed: Vec<bool> = excess
        .iter()
        .map(|e| !e.is_finite() || e - centre > CHROMA_OBJECT_SIGMA * sigma)
        .collect();
    let grow = CHROMA_OBJECT_GROW as i64;
    (0..mean.len())
        .map(|i| {
            let (x, y) = ((i % gw) as i64, (i / gw) as i64);
            (-grow..=grow).any(|dy| {
                (-grow..=grow).any(|dx| {
                    let (nx, ny) = (x + dx, y + dy);
                    nx >= 0
                        && ny >= 0
                        && nx < gw as i64
                        && ny < gh as i64
                        && seed[ny as usize * gw + nx as usize]
                })
            })
        })
        .collect()
}

/// Fill every empty box with the mean of its filled neighbors, growing inward
/// until none is empty.
fn fill_from_neighbors(values: &mut [Option<f64>], gw: usize, gh: usize) {
    if values.iter().all(Option::is_none) {
        values.iter_mut().for_each(|v| *v = Some(0.0));
        return;
    }
    while values.iter().any(Option::is_none) {
        let snapshot = values.to_vec();
        for i in 0..values.len() {
            if snapshot[i].is_some() {
                continue;
            }
            let (x, y) = ((i % gw) as i64, (i / gw) as i64);
            let mut sum = 0.0;
            let mut count = 0.0;
            for dy in -1..=1_i64 {
                for dx in -1..=1_i64 {
                    let (nx, ny) = (x + dx, y + dy);
                    if nx < 0 || ny < 0 || nx >= gw as i64 || ny >= gh as i64 {
                        continue;
                    }
                    if let Some(v) = snapshot[ny as usize * gw + nx as usize] {
                        sum += v;
                        count += 1.0;
                    }
                }
            }
            if count > 0.0 {
                values[i] = Some(sum / count);
            }
        }
    }
}

/// Median over a `size x size` window, clamped at the lattice edges; non-finite
/// entries are skipped.
fn median_filter(values: &[f64], gw: usize, gh: usize, size: usize) -> Vec<f64> {
    let half = (size / 2) as i64;
    (0..values.len())
        .map(|i| {
            let (x, y) = ((i % gw) as i64, (i / gw) as i64);
            let mut window = Vec::with_capacity(size * size);
            for dy in -half..=half {
                for dx in -half..=half {
                    let nx = (x + dx).clamp(0, gw as i64 - 1) as usize;
                    let ny = (y + dy).clamp(0, gh as i64 - 1) as usize;
                    let v = values[ny * gw + nx];
                    if v.is_finite() {
                        window.push(v);
                    }
                }
            }
            if window.is_empty() {
                f64::NAN
            } else {
                median_in_place(&mut window)
            }
        })
        .collect()
}

/// Bilinear interpolation of a lattice at fractional box coordinates, held
/// constant beyond the outermost box centres.
fn bilinear(values: &[f64], gw: usize, gh: usize, gx: f64, gy: f64) -> f64 {
    let gx = gx.clamp(0.0, (gw - 1) as f64);
    let gy = gy.clamp(0.0, (gh - 1) as f64);
    let (x0, y0) = (gx.floor() as usize, gy.floor() as usize);
    let (x1, y1) = ((x0 + 1).min(gw - 1), (y0 + 1).min(gh - 1));
    let (fx, fy) = (gx - x0 as f64, gy - y0 as f64);
    let top = values[y0 * gw + x0] * (1.0 - fx) + values[y0 * gw + x1] * fx;
    let bottom = values[y1 * gw + x0] * (1.0 - fx) + values[y1 * gw + x1] * fx;
    top * (1.0 - fy) + bottom * fy
}

#[cfg(test)]
#[path = "flatten_tests.rs"]
mod flatten_tests;
