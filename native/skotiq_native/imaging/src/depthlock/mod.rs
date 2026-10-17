//! DepthLock's measurement and stopping policy.
//!
//! Pure, deterministic functions over already-admitted evidence. The
//! contract — what the depth score measures, its units and regime, the
//! confirmation policy and what it does *not* guarantee — is written out in
//! `docs/depthlock-design.md`; this file is the implementation of that note
//! and the doc comments here only orient. Getting evidence *to* this module
//! from files is [`input`]'s job; deciding what to do with a verdict is the
//! host's.
//!
//! Units: sky positions in ICRS degrees, sizes in arcseconds, intensities in
//! signed calibrated ADU per native pixel, scores dimensionless.

pub mod input;

use crate::SipWcs;
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

/// Bumped whenever the estimator's numbers would change for the same
/// inputs; a goal freezes the version it was defined against.
pub const ESTIMATOR_VERSION: u32 = 1;
/// Upper bound on apertures per region, so a selection stays a summary of a
/// structure rather than a per-pixel map.
pub const MAX_CELLS: usize = 256;
/// Fewest independent post-selection exposures before any score is reported.
pub const MIN_FRAMES: usize = 32;
/// Fewest exposures acquired after a provisional candidate that must agree
/// with it before the goal is achieved.
pub const CONFIRMATION_FRAMES: usize = 16;
/// One region's aperture means for one exposure; `None` is an aperture that
/// could not be measured (masked, saturated, off-frame or non-finite).
pub type ApertureSamples = Vec<Option<f64>>;

/// A tangent-plane rectangle on the sky: center in ICRS degrees, sides in
/// arcseconds, rotation in degrees east of north. The measurement grid it
/// yields is fixed by the goal's scale and does not depend on any image.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SkyRectangle {
    pub ra_deg: f64,
    pub dec_deg: f64,
    pub width_arcsec: f64,
    pub height_arcsec: f64,
    pub rotation_deg: f64,
}

impl SkyRectangle {
    /// Aperture centers (RA, Dec in degrees), row-major, for square cells of
    /// side `scale` arcseconds. Incomplete edge strips are not measured.
    pub fn grid(&self, scale: f64) -> Result<Vec<(f64, f64)>, String> {
        if ![
            self.ra_deg,
            self.dec_deg,
            self.width_arcsec,
            self.height_arcsec,
            self.rotation_deg,
            scale,
        ]
        .iter()
        .all(|v| v.is_finite())
            || !(0.0..360.0).contains(&self.ra_deg)
            || self.dec_deg.abs() > 85.0
            || scale < 2.0
            || self.width_arcsec < scale
            || self.height_arcsec < scale
            || self.width_arcsec > 3600.0
            || self.height_arcsec > 3600.0
        {
            return Err(
                "Invalid sky rectangle or scale (2 arcsec minimum; 1 degree maximum field)".into(),
            );
        }
        let nx = (self.width_arcsec / scale).floor() as usize;
        let ny = (self.height_arcsec / scale).floor() as usize;
        if nx * ny < 16 || nx * ny > MAX_CELLS {
            return Err("Select between 16 and 256 fixed-scale apertures in each region".into());
        }
        let angle = self.rotation_deg.to_radians();
        let s = scale / 3600.0;
        let wcs = SipWcs::tan_only(
            self.ra_deg,
            self.dec_deg,
            (nx as f64 + 1.0) / 2.0,
            (ny as f64 + 1.0) / 2.0,
            -s * angle.cos(),
            s * angle.sin(),
            s * angle.sin(),
            s * angle.cos(),
        );
        Ok((0..ny)
            .flat_map(|y| (0..nx).map(move |x| (x, y)))
            .map(|(x, y)| wcs.pixel_to_world(x as f64, y as f64))
            .collect())
    }
}

/// Everything a goal revision fixes about how depth is measured. Two specs
/// that differ in any field are different measurements; evidence gathered
/// under one is never pooled with the other.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct MeasurementSpec {
    pub version: u32,
    pub region: SkyRectangle,
    pub background: SkyRectangle,
    pub scale_arcsec: f64,
    pub threshold: f64,
    pub min_coverage: f64,
    pub systematic_floor_adu: f64,
    pub systematic_floor_source: String,
}

impl MeasurementSpec {
    pub fn validate(&self) -> Result<(), String> {
        if self.version != ESTIMATOR_VERSION
            || !self.threshold.is_finite()
            || !(3.0..=100.0).contains(&self.threshold)
            || !self.min_coverage.is_finite()
            || !(0.9..=1.0).contains(&self.min_coverage)
            || !self.systematic_floor_adu.is_finite()
            || self.systematic_floor_adu <= 0.0
            || self.systematic_floor_source.trim().is_empty()
        {
            return Err("Unsupported measurement definition, coverage, threshold or calibration error floor".into());
        }
        self.region.grid(self.scale_arcsec)?;
        self.background.grid(self.scale_arcsec)?;
        let a = &self.region;
        let b = &self.background;
        let separation = angular_separation(a.ra_deg, a.dec_deg, b.ra_deg, b.dec_deg);
        let radii =
            (a.width_arcsec.hypot(a.height_arcsec) + b.width_arcsec.hypot(b.height_arcsec)) / 2.0;
        if separation <= radii || separation > 5.0 * radii || separation > 3600.0 {
            return Err(
                "Background must be disjoint and nearby; select a separate local sky region".into(),
            );
        }
        Ok(())
    }
}

fn angular_separation(ra: f64, dec: f64, rb: f64, db: f64) -> f64 {
    let a = ((db - dec).to_radians() / 2.0).sin().powi(2)
        + dec.to_radians().cos()
            * db.to_radians().cos()
            * ((rb - ra).to_radians() / 2.0).sin().powi(2);
    2.0 * a.clamp(0.0, 1.0).sqrt().asin().to_degrees() * 3600.0
}

/// One exposure's contribution: aperture means for the signal and background
/// regions, plus the identity and provenance the stopping policy keys on.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ApertureFrame {
    pub frame_id: String,
    pub acquired_at_ms: i64,
    pub source_path: String,
    pub provenance_digest: String,
    pub signal: Vec<Option<f64>>,
    pub background: Vec<Option<f64>>,
}

/// Where a goal revision stands. `Unreliable` is a property of the current
/// evidence, not of the goal: more or cleaner data can move it back.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DepthState {
    InsufficientEvidence,
    Collecting,
    ConfirmationPending,
    Achieved,
    Unreliable,
}

/// The result of one evaluation. `score` is the lower-quartile depth score,
/// `conservative_score` the same minus the repeated-look margin, and
/// `uncertainty_adu` the median per-cell uncertainty (a summary, not an
/// interval on the score). `reason` is written for the operator.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DepthReport {
    pub state: DepthState,
    pub score: Option<f64>,
    pub conservative_score: Option<f64>,
    pub uncertainty_adu: Option<f64>,
    pub coverage: f64,
    /// Post-selection exposures the estimate rests on.
    pub evidence_frames: usize,
    /// Post-selection exposures set aside because their background was
    /// mostly unmeasurable; they are neither pooled nor counted.
    #[serde(default)]
    pub excluded_frames: usize,
    pub confirmation_frames: usize,
    pub reason: String,
    /// What reaching the goal is expected to cost, from the same per-cell
    /// noise model the score uses. `None` when nothing is measurable yet.
    #[serde(default)]
    pub forecast: Option<DepthForecast>,
}

/// The cost of the goal, projected from the noise model.
///
/// Signal-to-noise per cell grows as `s / sqrt(w/N + f²)`: the random term
/// falls with more exposures, the systematic floor `f` does not. The
/// forecast walks `N` forward until the lower-quartile score clears the
/// user threshold plus the repeated-look margin at that `N`, then adds the
/// confirmation window. When the floor keeps the quartile below the
/// threshold for any `N`, the goal is unreachable at this scale and the
/// `ceiling_score` says where it stops. Yield compares the noise the newest
/// frames add against the best the goal has seen, so a bright-moon night
/// reads as fewer effective frames rather than as a mystery. A projection,
/// not a promise: it assumes the sky stays as it has been.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DepthForecast {
    /// Exposures still needed to cross the threshold, at the goal's recent
    /// per-frame noise. Zero once crossed.
    pub frames_to_threshold: usize,
    /// Exposures still needed after the crossing for confirmation.
    pub frames_to_confirm: usize,
    /// False when the systematic floor caps the score below the threshold.
    pub reachable: bool,
    /// The lower-quartile score the floor allows with unlimited exposures.
    pub ceiling_score: f64,
    /// Median per-cell noise one exposure adds, ADU.
    pub per_frame_noise_adu: f64,
    /// Background scatter of the newest exposures (median of the last eight),
    /// ADU per cell.
    pub recent_frame_noise_adu: f64,
    /// The quietest eight-exposure stretch the goal has seen, ADU per cell.
    pub best_frame_noise_adu: f64,
}

/// One point of a goal's history: the score after its first `frames`
/// exposures, or a projection beyond them.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CurvePoint {
    pub frames: usize,
    pub score: f64,
    pub conservative_score: f64,
    pub projected: bool,
}

impl DepthReport {
    fn unavailable(reason: impl Into<String>, frames: usize) -> Self {
        Self {
            state: DepthState::Unreliable,
            score: None,
            conservative_score: None,
            uncertainty_adu: None,
            coverage: 0.0,
            evidence_frames: frames,
            excluded_frames: 0,
            confirmation_frames: 0,
            forecast: None,
            reason: reason.into(),
        }
    }
}

/// A provisional threshold crossing frozen for confirmation: the exact
/// exposures that produced it and the definition/context they were measured
/// under. Only later-acquired, disjoint exposures can confirm it.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Candidate {
    pub frame_ids: BTreeSet<String>,
    pub latest_acquired_at_ms: i64,
    pub measurement: MeasurementSpec,
    pub selected_at_ms: i64,
    pub provenance_digest: String,
}

fn quantile(values: &[f64], fraction: f64) -> f64 {
    let mut sorted = values.to_vec();
    sorted.sort_by(f64::total_cmp);
    sorted[((sorted.len() - 1) as f64 * fraction).floor() as usize]
}

pub(crate) fn median(values: &[f64]) -> f64 {
    let mut sorted = values.to_vec();
    sorted.sort_by(f64::total_cmp);
    let middle = sorted.len() / 2;
    if sorted.len().is_multiple_of(2) {
        sorted[middle - 1] / 2.0 + sorted[middle] / 2.0
    } else {
        sorted[middle]
    }
}

fn mean_variance(values: &[f64]) -> (f64, f64) {
    let mut mean = 0.0;
    let mut m2 = 0.0;
    for (i, value) in values.iter().enumerate() {
        let delta = value - mean;
        mean += delta / (i + 1) as f64;
        m2 += delta * (value - mean);
    }
    (mean, m2 / (values.len() - 1) as f64)
}

fn partition(id: &str) -> usize {
    let hash = id.bytes().fold(0xcbf29ce484222325u64, |h, b| {
        (h ^ u64::from(b)).wrapping_mul(0x100000001b3)
    });
    let hash = (hash ^ (hash >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
    let hash = (hash ^ (hash >> 27)).wrapping_mul(0x94d049bb133111eb);
    (hash ^ (hash >> 31)) as usize & 1
}

struct Summary {
    means: Vec<f64>,
    errors: Vec<f64>,
    scores: Vec<f64>,
    coverage: f64,
    /// Effective per-exposure variance of each valid cell (the larger of the
    /// sample variance and the block estimate), so a score at any exposure
    /// count can be projected.
    per_frame_variance: Vec<f64>,
    systematic: f64,
    /// The goal's declared calibration floor on its own — the part of
    /// `systematic` that no number of exposures reduces.
    declared_floor: f64,
    background_cells: usize,
    frames: usize,
    /// Each used exposure's background scatter about its own level, in
    /// acquisition order: the noise that exposure added per cell.
    frame_noise: Vec<f64>,
}

/// Fraction of a frame's background apertures that must be measurable for
/// the frame to be used at all. A cosmic ray or satellite through the
/// background region costs that frame, not the goal.
pub const MIN_BACKGROUND_FRACTION: f64 = 0.75;
/// Fraction of the used exposures in which an aperture must be measurable
/// for the cell to count; below it the cell is invalid and counts against
/// coverage. Keeps one masked hit from removing a cell for a whole night
/// while still refusing cells that are mostly unmeasurable.
pub const MIN_CELL_FRACTION: f64 = 0.9;
/// Fewest exposures a cell's temporal statistics may rest on.
pub const MIN_CELL_FRAMES: usize = 8;

/// Whether a frame can take part in any summary: its geometry matches the
/// spec and enough of its background is measurable to estimate the local
/// sky. Non-finite samples are a refusal, not an exclusion — they mean the
/// caller broke the contract.
fn frame_usable(spec: &MeasurementSpec, frame: &ApertureFrame) -> Result<bool, String> {
    let cells = spec.region.grid(spec.scale_arcsec)?.len();
    let bg_cells = spec.background.grid(spec.scale_arcsec)?.len();
    if frame.signal.len() != cells || frame.background.len() != bg_cells {
        return Err("The square layout changed; re-measure the goal".into());
    }
    if frame
        .signal
        .iter()
        .chain(&frame.background)
        .flatten()
        .any(|v| !v.is_finite())
    {
        return Err("Non-finite linear aperture data".into());
    }
    let valid = frame.background.iter().flatten().count();
    Ok(valid as f64 >= (MIN_BACKGROUND_FRACTION * bg_cells as f64).ceil())
}

fn summarize(spec: &MeasurementSpec, frames: &[&ApertureFrame]) -> Result<Summary, String> {
    let cells = spec.region.grid(spec.scale_arcsec)?.len();
    let bg_cells = spec.background.grid(spec.scale_arcsec)?.len();
    let n_frames = frames.len();
    if n_frames < MIN_CELL_FRAMES {
        return Err("Too few usable exposures".into());
    }
    let min_cell_frames =
        MIN_CELL_FRAMES.max((MIN_CELL_FRACTION * n_frames as f64).ceil() as usize);
    // Each frame's local sky level: the median of its measurable background
    // apertures (`frame_usable` guaranteed enough of them).
    let mut backgrounds = Vec::with_capacity(n_frames);
    for frame in frames {
        if !frame_usable(spec, frame)? {
            return Err("The background box is masked, saturated or off the frame".into());
        }
        let bg: Vec<f64> = frame.background.iter().copied().flatten().collect();
        backgrounds.push(median(&bg));
    }
    // Spatial background residuals: per background cell, the mean over the
    // frames that measured it, of (cell - frame sky level). Cells measured
    // in too few frames are left out of the floor and the gradient test.
    let mut bg_means = vec![f64::NAN; bg_cells];
    // Variance of each cell's mean (sample variance / n), for the gradient
    // gate's noise allowance.
    let mut bg_mean_variances = vec![f64::NAN; bg_cells];
    for cell in 0..bg_cells {
        let values: Vec<f64> = frames
            .iter()
            .enumerate()
            .filter_map(|(i, f)| f.background[cell].map(|v| v - backgrounds[i]))
            .collect();
        if values.len() >= min_cell_frames {
            let (mean, variance) = mean_variance(&values);
            bg_means[cell] = mean;
            bg_mean_variances[cell] = variance / values.len() as f64;
        }
    }
    let present: Vec<f64> = bg_means.iter().copied().filter(|v| v.is_finite()).collect();
    if (present.len() as f64) < (MIN_BACKGROUND_FRACTION * bg_cells as f64).ceil() {
        return Err("The background box is too small for its square size".into());
    }
    let bg_center = median(&present);
    let bg_residuals: Vec<f64> = present.iter().map(|v| (v - bg_center).abs()).collect();
    let bg_floor = quantile(&bg_residuals, 0.9);
    let systematic = spec.systematic_floor_adu.max(bg_floor);
    let nx = (spec.background.width_arcsec / spec.scale_arcsec).floor() as usize;
    let ny = bg_cells / nx;
    // Gradient gate: the four quadrant means of the background residuals
    // must agree to within twice the calibration floor — after allowing for
    // their own noise, or the gate would fire on every quiet night early on
    // and flip the goal between unreliable and collecting.
    let mut quadrant_means = Vec::new();
    let mut quadrant_sigma: f64 = 0.0;
    for q in 0..4 {
        let members: Vec<usize> = (0..bg_cells)
            .filter(|i| {
                bg_means[*i].is_finite()
                    && usize::from(i % nx >= nx / 2) + 2 * usize::from(i / nx >= ny / 2) == q
            })
            .collect();
        if members.is_empty() {
            return Err("The background box is too small for its square size".into());
        }
        let count = members.len() as f64;
        quadrant_means.push(members.iter().map(|i| bg_means[*i]).sum::<f64>() / count);
        let variance = members.iter().map(|i| bg_mean_variances[*i]).sum::<f64>() / (count * count);
        quadrant_sigma = quadrant_sigma.max(variance.max(0.0).sqrt());
    }
    let gradient = quadrant_means
        .iter()
        .copied()
        .fold(f64::NEG_INFINITY, f64::max)
        - quadrant_means.iter().copied().fold(f64::INFINITY, f64::min);
    if gradient > 2.0 * spec.systematic_floor_adu + 4.0 * quadrant_sigma * 2f64.sqrt() {
        return Err(
            "Local background has a persistent gradient; choose a cleaner reference region".into(),
        );
    }
    let frame_noise: Vec<f64> = frames
        .iter()
        .enumerate()
        .map(|(i, f)| {
            let residuals: Vec<f64> = f
                .background
                .iter()
                .flatten()
                .map(|v| v - backgrounds[i])
                .collect();
            mean_variance(&residuals).1.max(0.0).sqrt()
        })
        .collect();
    let mut result = Summary {
        means: Vec::new(),
        errors: Vec::new(),
        scores: Vec::new(),
        coverage: 0.0,
        per_frame_variance: Vec::new(),
        systematic,
        declared_floor: spec.systematic_floor_adu,
        background_cells: present.len(),
        frames: n_frames,
        frame_noise,
    };
    let mut correlated_cells = 0;
    for cell in 0..cells {
        // The cell's own time series: the frames that measured it, in
        // acquisition order (the caller sorted `frames`).
        let values: Vec<f64> = frames
            .iter()
            .enumerate()
            .filter_map(|(i, f)| f.signal[cell].map(|v| v - backgrounds[i]))
            .collect();
        if values.len() < min_cell_frames {
            result.means.push(f64::NAN);
            result.errors.push(f64::NAN);
            continue;
        }
        let (mean, variance) = mean_variance(&values);
        let n = values.len();
        if n >= MIN_FRAMES && variance > 0.0 {
            let covariance = values
                .windows(2)
                .map(|v| (v[0] - mean) * (v[1] - mean))
                .sum::<f64>()
                / (n - 1) as f64;
            correlated_cells += usize::from(covariance / variance > 0.35);
        }
        let block_means: Vec<f64> = values
            .as_chunks::<4>()
            .0
            .iter()
            .map(|c| c.iter().sum::<f64>() / 4.0)
            .collect();
        let block_error = mean_variance(&block_means).1 / block_means.len() as f64;
        let random = (variance / n as f64).max(block_error).max(0.0);
        let error = random
            .mul_add(1.0 + 1.0 / present.len() as f64, systematic * systematic)
            .sqrt();
        if !mean.is_finite() || !error.is_finite() || error <= 0.0 || !(mean / error).is_finite() {
            return Err("Noise estimate is invalid".into());
        }
        result.means.push(mean);
        result.errors.push(error);
        result.scores.push(mean / error);
        result.per_frame_variance.push(random * n as f64);
    }
    if correlated_cells as f64 > cells as f64 * 0.2 {
        return Err(
            "Temporal correlation exceeds the supported independent-exposure noise regime".into(),
        );
    }
    result.coverage = result.scores.len() as f64 / cells as f64;
    if result.coverage < spec.min_coverage || result.scores.len() < 16 {
        return Err("Too little of the structure box is measurable in enough exposures".into());
    }
    Ok(result)
}

/// The repeated-look margin at `n` exposures.
fn margin(n: usize) -> f64 {
    (2.0 * (2000.0 * n as f64 * (n + 1) as f64).ln()).sqrt()
}

/// The systematic floor expected after `frames` exposures. The measured
/// background spatial floor is mostly the noise of the background cells'
/// means, which falls as 1/√N; the declared calibration floor does not
/// fall at all. Projecting the measured excess down with √N and never below
/// the declared floor is the assumption that the residual is noise — an
/// assumption the gradient gate polices as the frames arrive.
fn projected_floor(summary: &Summary, frames: usize) -> f64 {
    let ratio = (summary.frames as f64 / frames.max(1) as f64).sqrt();
    (summary.systematic * ratio).max(summary.declared_floor)
}

/// Lower-quartile score the summary's cells would show after `frames`
/// exposures, holding signal and per-frame noise fixed.
fn projected_score(summary: &Summary, frames: usize) -> f64 {
    let factor = 1.0 + 1.0 / summary.background_cells as f64;
    let floor = projected_floor(summary, frames);
    let scores: Vec<f64> = summary
        .means
        .iter()
        .zip(&summary.per_frame_variance)
        .filter(|(m, w)| m.is_finite() && w.is_finite())
        .map(|(m, w)| m / (w / frames as f64).mul_add(factor, floor * floor).sqrt())
        .collect();
    if scores.is_empty() {
        return f64::NAN;
    }
    quantile(&scores, 0.25)
}

/// Widest exposure count the forecast will search before calling a goal
/// unreachable; ten thousand subs is several seasons of any single target.
const FORECAST_MAX_FRAMES: usize = 10_000;

fn forecast(summary: &Summary, threshold: f64, confirmation_frames: usize) -> DepthForecast {
    let n = summary.frames.max(MIN_FRAMES);
    // The declared floor alone: what the quartile tends to with unlimited
    // exposures once every noise term has averaged away.
    let ceiling: f64 = {
        let scores: Vec<f64> = summary
            .means
            .iter()
            .filter(|m| m.is_finite())
            .map(|m| m / summary.declared_floor)
            .collect();
        if scores.is_empty() {
            f64::NAN
        } else {
            quantile(&scores, 0.25)
        }
    };
    let mut crossing: Option<usize> = None;
    let mut frames = n;
    while frames <= FORECAST_MAX_FRAMES {
        if projected_score(summary, frames) - margin(frames) >= threshold {
            crossing = Some(frames);
            break;
        }
        // Geometric steps keep the scan cheap; the answer is quoted to the
        // nearest few percent, which is finer than the assumption behind it.
        frames = (frames + (frames / 32).max(1)).min(FORECAST_MAX_FRAMES + 1);
    }
    let per_frame_noise = {
        let mut noise: Vec<f64> = summary
            .per_frame_variance
            .iter()
            .filter(|w| w.is_finite())
            .map(|w| w.max(0.0).sqrt())
            .collect();
        if noise.is_empty() {
            f64::NAN
        } else {
            noise.sort_by(f64::total_cmp);
            noise[noise.len() / 2]
        }
    };
    let window = 8usize.min(summary.frame_noise.len().max(1));
    let recent = median(&summary.frame_noise[summary.frame_noise.len().saturating_sub(window)..]);
    let best = summary
        .frame_noise
        .windows(window)
        .map(median)
        .fold(f64::INFINITY, f64::min);
    let (frames_to_threshold, frames_to_confirm) = match crossing {
        Some(at) if at <= summary.frames => {
            (0, CONFIRMATION_FRAMES.saturating_sub(confirmation_frames))
        }
        Some(at) => (at - summary.frames, CONFIRMATION_FRAMES),
        None => (0, 0),
    };
    DepthForecast {
        frames_to_threshold,
        frames_to_confirm,
        reachable: crossing.is_some(),
        ceiling_score: ceiling,
        per_frame_noise_adu: per_frame_noise,
        recent_frame_noise_adu: recent,
        best_frame_noise_adu: if best.is_finite() { best } else { recent },
    }
}

/// The score after each prefix of the evidence, thinned to about
/// `max_points` measured points, followed by the projection of the current
/// model out to the forecast crossing (or twice the current count when the
/// goal is unreachable). Purely a display of history and expectation;
/// nothing here changes a verdict.
pub fn progress_curve(
    spec: &MeasurementSpec,
    evidence: &[ApertureFrame],
    selected_at_ms: i64,
    max_points: usize,
) -> Vec<CurvePoint> {
    let mut frames: Vec<&ApertureFrame> = evidence
        .iter()
        .filter(|f| f.acquired_at_ms > selected_at_ms)
        .filter(|f| frame_usable(spec, f).unwrap_or(false))
        .collect();
    frames.sort_by(|a, b| (a.acquired_at_ms, &a.frame_id).cmp(&(b.acquired_at_ms, &b.frame_id)));
    let n = frames.len();
    let mut points = Vec::new();
    if n < MIN_FRAMES {
        return points;
    }
    let step = ((n - MIN_FRAMES) / max_points.max(1)).max(1);
    let mut k = MIN_FRAMES;
    let mut last: Option<Summary> = None;
    while k <= n {
        if let Ok(summary) = summarize(spec, &frames[..k]) {
            let score = quantile(&summary.scores, 0.25);
            points.push(CurvePoint {
                frames: k,
                score,
                conservative_score: score - margin(k),
                projected: false,
            });
            last = Some(summary);
        }
        if k == n {
            break;
        }
        k = (k + step).min(n);
    }
    if let Some(summary) = last {
        let projection = forecast(&summary, spec.threshold, 0);
        let horizon = if projection.reachable {
            n + projection.frames_to_threshold + projection.frames_to_confirm
        } else {
            n * 2
        };
        let count = max_points.clamp(4, 64);
        for i in 1..=count {
            let frames = n + (horizon - n) * i / count;
            if frames <= n {
                continue;
            }
            let score = projected_score(&summary, frames);
            points.push(CurvePoint {
                frames,
                score,
                conservative_score: score - margin(frames),
                projected: true,
            });
        }
    }
    points
}

/// Evaluate a goal revision over its evidence. Returns the report and, when
/// a threshold crossing is provisional or achieved, the candidate the host
/// must persist alongside it. Never panics on caller data; every refusal is a
/// report with `DepthState::Unreliable` and a reason.
pub fn evaluate(
    spec: &MeasurementSpec,
    evidence: &[ApertureFrame],
    selected_at_ms: i64,
    candidate: Option<&Candidate>,
) -> (DepthReport, Option<Candidate>) {
    if let Err(e) = spec.validate() {
        return (DepthReport::unavailable(e, 0), None);
    }
    let mut ids = BTreeSet::new();
    if evidence
        .iter()
        .any(|f| f.frame_id.is_empty() || !ids.insert(&f.frame_id))
    {
        return (
            DepthReport::unavailable(
                "Two exposures share an identity, or one has none; re-measure the goal",
                0,
            ),
            None,
        );
    }
    let mut frames = Vec::new();
    let mut excluded = 0usize;
    for frame in evidence
        .iter()
        .filter(|f| f.acquired_at_ms > selected_at_ms)
    {
        match frame_usable(spec, frame) {
            Ok(true) => frames.push(frame),
            // A frame whose background was mostly unmeasurable (a trail, a
            // hit, a mask edge) is set aside, not pooled and not fatal.
            Ok(false) => excluded += 1,
            Err(e) => return (DepthReport::unavailable(e, 0), None),
        }
    }
    frames.sort_by(|a, b| (a.acquired_at_ms, &a.frame_id).cmp(&(b.acquired_at_ms, &b.frame_id)));
    let n = frames.len();
    if n < MIN_FRAMES {
        let mut report = DepthReport::unavailable(
            "Collecting the first 32 exposures. Nothing is measured until then",
            n,
        );
        report.state = DepthState::InsufficientEvidence;
        report.excluded_frames = excluded;
        return (report, None);
    }
    let provenance = &frames[0].provenance_digest;
    if provenance.is_empty() || frames.iter().any(|f| &f.provenance_digest != provenance) {
        return (
            DepthReport::unavailable(
                "The exposures were not all calibrated with the same masters; re-measure the goal",
                n,
            ),
            None,
        );
    }
    if candidate.is_some_and(|c| {
        c.measurement != *spec
            || c.selected_at_ms != selected_at_ms
            || c.provenance_digest != *provenance
    }) {
        return (
            DepthReport::unavailable(
                "The provisional crossing came from an earlier definition or calibration; re-measure the goal",
                n,
            ),
            None,
        );
    }
    let summary = match summarize(spec, &frames) {
        Ok(s) => s,
        Err(e) => return (DepthReport::unavailable(e, n), None),
    };
    let margin = margin(n);
    let score = quantile(&summary.scores, 0.25);
    let errors: Vec<f64> = summary
        .errors
        .iter()
        .copied()
        .filter(|v| v.is_finite())
        .collect();
    let mut report = DepthReport {
        state: DepthState::Collecting,
        score: Some(score),
        conservative_score: Some(score - margin),
        uncertainty_adu: Some(median(&errors)),
        coverage: summary.coverage,
        evidence_frames: n,
        excluded_frames: excluded,
        confirmation_frames: 0,
        reason: "Measuring. Not reached yet; exposures keep counting across nights".into(),
        forecast: Some(forecast(&summary, spec.threshold, 0)),
    };
    if score - margin < spec.threshold {
        return (report, None);
    }
    let halves: Vec<Vec<&ApertureFrame>> = (0..2)
        .map(|p| {
            frames
                .iter()
                .copied()
                .filter(|f| partition(&f.frame_id) == p)
                .collect()
        })
        .collect();
    if halves.iter().any(|h| h.len() < 12) {
        return (report, None);
    }
    let a = match summarize(spec, &halves[0]) {
        Ok(s) => s,
        Err(e) => return (DepthReport::unavailable(e, n), None),
    };
    let b = match summarize(spec, &halves[1]) {
        Ok(s) => s,
        Err(e) => return (DepthReport::unavailable(e, n), None),
    };
    if !consistent(&a, &b) {
        report.reason =
            "Crossed once, but the two halves of the evidence disagree; still collecting".into();
        return (report, None);
    }
    report.state = DepthState::ConfirmationPending;
    report.reason = "Reached provisionally; waiting for 16 later exposures to confirm".into();
    let admitted = candidate.cloned().unwrap_or_else(|| Candidate {
        frame_ids: frames.iter().map(|f| f.frame_id.clone()).collect(),
        latest_acquired_at_ms: frames.last().expect("minimum frames").acquired_at_ms,
        measurement: spec.clone(),
        selected_at_ms,
        provenance_digest: provenance.clone(),
    });
    let discovery: Vec<&ApertureFrame> = frames
        .iter()
        .copied()
        .filter(|f| admitted.frame_ids.contains(&f.frame_id))
        .collect();
    if discovery.len() != admitted.frame_ids.len()
        || discovery.len() < MIN_FRAMES
        || discovery.iter().map(|f| f.acquired_at_ms).max() != Some(admitted.latest_acquired_at_ms)
    {
        return (
            DepthReport::unavailable(
                "The provisional crossing no longer matches its evidence; re-measure the goal",
                n,
            ),
            None,
        );
    }
    let discovery_summary = match summarize(spec, &discovery) {
        Ok(s) => s,
        Err(e) => return (DepthReport::unavailable(e, n), None),
    };
    let later: Vec<&ApertureFrame> = frames
        .iter()
        .copied()
        .filter(|f| {
            !admitted.frame_ids.contains(&f.frame_id)
                && f.acquired_at_ms > admitted.latest_acquired_at_ms
        })
        .collect();
    report.confirmation_frames = later.len();
    // Past the crossing the remaining cost is the confirmation window.
    report.forecast = Some(forecast(&summary, spec.threshold, later.len()));
    if later.len() >= CONFIRMATION_FRAMES {
        match summarize(spec, &later) {
            Ok(c) if consistent(&discovery_summary, &c) && quantile(&c.scores, 0.25) > 3.0 => {
                report.state = DepthState::Achieved;
                report.reason = "Reached and confirmed by 16 later exposures".into();
            }
            Ok(_) => {
                report.reason = "Later exposures do not confirm it; still collecting".into();
                return (report, None);
            }
            Err(e) => return (DepthReport::unavailable(e, n), None),
        }
    }
    (report, Some(admitted))
}

fn consistent(a: &Summary, b: &Summary) -> bool {
    let valid: Vec<bool> = a
        .means
        .iter()
        .zip(&a.errors)
        .zip(b.means.iter().zip(&b.errors))
        .filter(|((x, e), (y, f))| [**x, **e, **y, **f].iter().all(|v| v.is_finite()))
        .map(|((x, e), (y, f))| (x - y).abs() <= 4.0 * e.hypot(*f))
        .collect();
    valid.len() >= 16 && valid.iter().filter(|v| **v).count() as f64 / valid.len() as f64 >= 0.9
}

/// Measure both regions' apertures on one calibrated frame. `pixels` and
/// `mask` are row-major over `width × height`; `source_wcs` is the frame's
/// own TAN solution. Each aperture is the mean of a midpoint grid of
/// bilinear samples; an aperture touching a masked, non-finite or off-frame
/// pixel is `None`.
pub fn sample_apertures(
    spec: &MeasurementSpec,
    pixels: &[f64],
    mask: &[bool],
    width: usize,
    height: usize,
    source_wcs: &SipWcs,
) -> Result<(ApertureSamples, ApertureSamples), String> {
    spec.validate()?;
    if width.checked_mul(height) != Some(pixels.len())
        || mask.len() != pixels.len()
        || !source_wcs.is_invertible()
        || source_wcs.a_order != 0
        || source_wcs.b_order != 0
        || source_wcs.ap_order != 0
        || source_wcs.bp_order != 0
        || ![
            source_wcs.crval1,
            source_wcs.crval2,
            source_wcs.crpix1,
            source_wcs.crpix2,
            source_wcs.cd1_1,
            source_wcs.cd1_2,
            source_wcs.cd2_1,
            source_wcs.cd2_2,
        ]
        .iter()
        .all(|v| v.is_finite())
    {
        return Err("Invalid linear image, mask or unsupported distorted WCS".into());
    }
    let pixel_scale = (source_wcs.cd1_1 * source_wcs.cd2_2 - source_wcs.cd1_2 * source_wcs.cd2_1)
        .abs()
        .sqrt()
        * 3600.0;
    let sx = source_wcs.cd1_1.hypot(source_wcs.cd2_1) * 3600.0;
    let sy = source_wcs.cd1_2.hypot(source_wcs.cd2_2) * 3600.0;
    let skew = (source_wcs.cd1_1 * source_wcs.cd1_2 + source_wcs.cd2_1 * source_wcs.cd2_2).abs()
        * 3600.0
        * 3600.0
        / (sx * sy);
    if (sx / sy - 1.0).abs() > 0.01
        || skew > 0.01
        || source_wcs.crval2.abs() > 90.0
        || !(0.0..360.0).contains(&source_wcs.crval1)
    {
        return Err(
            "DepthLock requires an orthogonal, approximately square-pixel TAN reference".into(),
        );
    }
    let samples = (spec.scale_arcsec / pixel_scale).ceil() as usize;
    if !(4..=64).contains(&samples) {
        return Err("Choose a fixed aperture between 4 and 64 native pixels across".into());
    }
    let sample_region = |region: &SkyRectangle| -> Result<Vec<Option<f64>>, String> {
        region
            .grid(spec.scale_arcsec)?
            .into_iter()
            .map(|(ra, dec)| {
                let angle = region.rotation_deg.to_radians();
                let s = spec.scale_arcsec / samples as f64 / 3600.0;
                let wcs = SipWcs::tan_only(
                    ra,
                    dec,
                    (samples as f64 + 1.0) / 2.0,
                    (samples as f64 + 1.0) / 2.0,
                    -s * angle.cos(),
                    s * angle.sin(),
                    s * angle.sin(),
                    s * angle.cos(),
                );
                let mut sum = 0.0;
                for y in 0..samples {
                    for x in 0..samples {
                        let (r, d) = wcs.pixel_to_world(x as f64, y as f64);
                        let Some((sx, sy)) = source_wcs.world_to_pixel(r, d) else {
                            return Ok(None);
                        };
                        if !sx.is_finite()
                            || !sy.is_finite()
                            || sx < 0.0
                            || sy < 0.0
                            || sx >= (width.saturating_sub(1)) as f64
                            || sy >= (height.saturating_sub(1)) as f64
                        {
                            return Ok(None);
                        }
                        let ix = sx.floor() as usize;
                        let iy = sy.floor() as usize;
                        let indices = [
                            iy * width + ix,
                            iy * width + ix + 1,
                            (iy + 1) * width + ix,
                            (iy + 1) * width + ix + 1,
                        ];
                        if indices.iter().any(|i| mask[*i] || !pixels[*i].is_finite()) {
                            return Ok(None);
                        }
                        let dx = sx - ix as f64;
                        let dy = sy - iy as f64;
                        sum += pixels[indices[0]] * (1.0 - dx) * (1.0 - dy)
                            + pixels[indices[1]] * dx * (1.0 - dy)
                            + pixels[indices[2]] * (1.0 - dx) * dy
                            + pixels[indices[3]] * dx * dy;
                    }
                }
                Ok(Some(sum / (samples * samples) as f64))
            })
            .collect()
    };
    Ok((
        sample_region(&spec.region)?,
        sample_region(&spec.background)?,
    ))
}
