//! One filter's master from every night of a target, in one call.
//!
//! [`master_build`] folds subs into an [`IntegratedMaster`] one at a time, so
//! its memory is the accumulator (about 40 bytes per sample) plus one sub in
//! flight, whatever the number of nights. Each night (a "group") brings its own
//! calibration masters. A sub that cannot be read, has the wrong geometry or
//! will not register is skipped and reported with its reason; the master is
//! built from the rest.
//!
//! Registration and normalization use separate references. Every filter of a
//! target can register onto one grid reference (typically the best L sub), so
//! the finished masters share a pixel grid. Normalization must stay within a
//! filter, so each master scales its subs to a reference sub of its own filter,
//! itself registered onto the grid.

use super::*;
use sha2::{Digest, Sha256};

use rayon::prelude::*;
use std::collections::HashMap;
use std::sync::Arc;

/// One night (or any set of subs sharing calibration masters).
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct BuildGroupArgs {
    /// Shown in the report and the master's `HISTORY` (e.g. the night's date).
    pub(crate) label: String,
    pub(crate) calibration: CalibrationArgs,
    pub(crate) lights: Vec<BuildLightArgs>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct BuildLightArgs {
    pub(crate) path: String,
    pub(crate) exposure_sec: f64,
}

/// A frame used as a reference, with the calibration its night applies.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct BuildReferenceArgs {
    pub(crate) path: String,
    pub(crate) calibration: CalibrationArgs,
}

/// Request for `op: "build"`.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct MasterBuildArgs {
    /// Cancellation id ([`api_post_session_cancel`]); empty ⇒ not cancellable.
    pub(crate) run_id: String,
    /// The frame whose pixel grid every sub is registered onto.
    pub(crate) grid_reference: BuildReferenceArgs,
    /// A sub of this master's filter that sets its photometric scale. Absent ⇒
    /// the grid reference, which must then be of this filter.
    pub(crate) normalization_reference: Option<BuildReferenceArgs>,
    pub(crate) groups: Vec<BuildGroupArgs>,
    pub(crate) filter: Option<String>,
    pub(crate) target: Option<String>,
    pub(crate) settings: IntegrationSettingsArgs,
    /// Accepted for older callers and ignored: a build integrates every sub
    /// in one batch with `rejection`.
    #[allow(dead_code)]
    pub(crate) clip: MasterSettingsArgs,
    pub(crate) master_fits_path: String,
    pub(crate) preview_png_path: Option<String>,
    /// Geometric support count, including sigma-rejected samples.
    pub(crate) coverage_fits_path: Option<String>,
    pub(crate) min_overlap: f64,
    pub(crate) max_eccentricity: Option<f64>,
    pub(crate) validate_flats: bool,
    /// `auto` (default: PixInsight's choice for the number of subs),
    /// `percentile`, `winsorized`, `linearFit`, `esd` or `none`.
    pub(crate) rejection: Option<String>,
    /// Folder for the registered subs while they are integrated; removed
    /// afterwards. Default: `<masterFitsPath>.subs` beside the master.
    pub(crate) spool_dir: Option<String>,
    /// Memory for registered subs and one band of integration, in MiB
    /// (default 1024). Subs that do not fit are written to `spoolDir`.
    pub(crate) memory_budget_mb: Option<u64>,
}

/// One sub that went into the master.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct FoldedSub {
    pub(crate) path: String,
    pub(crate) group: String,
    pub(crate) weight: f64,
    /// Median flux of its stars over the same stars in the reference.
    pub(crate) transparency: Option<f64>,
    /// Its noise over the reference's.
    pub(crate) noise_ratio: Option<f64>,
    pub(crate) stars_matched: usize,
    pub(crate) rms_px: f64,
    pub(crate) rotation_deg: f64,
    pub(crate) shift_px: [f64; 2],
}

/// One sub that did not, and why.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct SkippedSub {
    pub(crate) path: String,
    pub(crate) group: String,
    /// `read` | `geometry` | `calibration` | `registration` | `normalization` | `quality`.
    pub(crate) stage: String,
    pub(crate) reason: String,
}

/// What one group contributed.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct GroupSummary {
    pub(crate) label: String,
    pub(crate) offered: usize,
    pub(crate) folded: usize,
    pub(crate) skipped: usize,
    pub(crate) integration_sec: f64,
    pub(crate) calibration: CalibrationReport,
    /// The exposure ratio the group's dark was scaled by, when it was.
    pub(crate) dark_scale: Option<f64>,
}

/// Response for `op: "build"`.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct MasterBuildResult {
    pub(crate) master_path: String,
    pub(crate) preview_path: Option<String>,
    pub(crate) filter: Option<String>,
    pub(crate) frame_count: usize,
    pub(crate) total_integration_sec: f64,
    pub(crate) width: u32,
    pub(crate) height: u32,
    pub(crate) rejected: u64,
    pub(crate) coverage_path: Option<String>,
    pub(crate) median_rms_px: Option<f64>,
    pub(crate) groups: Vec<GroupSummary>,
    pub(crate) folded: Vec<FoldedSub>,
    pub(crate) skipped: Vec<SkippedSub>,
    /// The rejection that ran, with its parameters.
    pub(crate) rejection: String,
    /// The sub the master's photometric scale comes from.
    pub(crate) normalization_reference: String,
    /// Set when the requested normalization reference could not be used.
    pub(crate) normalization_fallback: Option<ReferenceFallback>,
    /// Where the master's WCS came from, when it has one.
    pub(crate) wcs_source: Option<String>,
}

/// The weighting formula that weighs each sub by its star signal over its noise.
pub(crate) const STAR_SIGNAL_FORMULA: &str = "starSignal";

/// Matched stars a sub needs before its signal is trusted.
pub(crate) const MIN_SIGNAL_PAIRS: usize = 8;

/// Brightest stars of a sub compared with the reference.
const SIGNAL_MAX_STARS: usize = 400;

/// Largest distance, in grid pixels, between a sub's star and the reference
/// star it is matched to.
const SIGNAL_MATCH_PX: f64 = 1.5;

/// A sub's weight from its stars, and the two measurements behind it.
#[derive(Debug, Clone, Copy)]
pub(crate) struct SignalWeight {
    pub(crate) weight: f64,
    pub(crate) transparency: f64,
    pub(crate) noise_ratio: f64,
}

/// The reference's unsaturated stars on the grid, and its noise.
///
/// A sub's weight is `(t / n)²`, where `t` is the median ratio of its stars'
/// flux to the same stars in the reference and `n` its noise over the
/// reference's: the square of its star signal-to-noise relative to the
/// reference. Unlike the frame-statistics SNR, a background gradient (trees
/// rising into the field, a brightening sky) cannot raise it, and cloud lowers
/// it as it dims the stars.
pub(crate) struct ReferenceSignal {
    stars: Vec<(f64, f64, f64)>,
    noise: f64,
    cell: f64,
    index: HashMap<(i64, i64), Vec<usize>>,
}

fn unsaturated_stars(image: &ImageData) -> Vec<skotiq_imaging::DetectedStar> {
    let mut stars =
        skotiq_imaging::detect_stars(image, &skotiq_imaging::StarDetectionConfig::default());
    stars.truncate(SIGNAL_MAX_STARS);
    stars
}

/// Tiles per side of the grid the noise is measured on.
const NOISE_TILES: usize = 8;

/// The sky noise of a frame: per tile, the MAD of neighboring-pixel
/// differences; over the frame, the upper quartile of the tiles. A part of the
/// field blocked by trees or a dome holds little more than read noise, so a
/// whole-frame estimate would fall and inflate the frame's weight; the upper
/// quartile stays on open sky while three quarters of the field is blocked.
fn noise_of(image: &ImageData) -> Option<f64> {
    let pixels = image.as_u16()?;
    let (w, h) = (image.width as usize, image.height as usize);
    let c = image.channels as usize;
    if w < 2 * NOISE_TILES || h < NOISE_TILES {
        return None;
    }
    let mut tiles = Vec::with_capacity(NOISE_TILES * NOISE_TILES);
    for ty in 0..NOISE_TILES {
        for tx in 0..NOISE_TILES {
            let (x0, x1) = (tx * w / NOISE_TILES, (tx + 1) * w / NOISE_TILES);
            let (y0, y1) = (ty * h / NOISE_TILES, (ty + 1) * h / NOISE_TILES);
            let mut diffs: Vec<f64> = Vec::with_capacity((x1 - x0) * (y1 - y0) / 2);
            for y in (y0..y1).step_by(2) {
                let row = &pixels[y * w * c..(y + 1) * w * c];
                for x in (x0 + 1)..x1 {
                    diffs.push(row[x * c] as f64 - row[(x - 1) * c] as f64);
                }
            }
            if diffs.is_empty() {
                continue;
            }
            diffs.sort_by(f64::total_cmp);
            let median = diffs[diffs.len() / 2];
            let mut deviations: Vec<f64> = diffs.iter().map(|d| (d - median).abs()).collect();
            deviations.sort_by(f64::total_cmp);
            tiles.push(1.4826 * deviations[deviations.len() / 2] / std::f64::consts::SQRT_2);
        }
    }
    tiles.sort_by(f64::total_cmp);
    let noise = *tiles.get(tiles.len() * 3 / 4)?;
    (noise.is_finite() && noise > 0.0).then_some(noise)
}

impl ReferenceSignal {
    /// Measure the reference: its noise on the calibrated frame, its stars on
    /// the grid.
    pub(crate) fn measure(calibrated: &ImageData, on_grid: &ImageData) -> Option<Self> {
        let noise = noise_of(calibrated)?;
        let stars: Vec<(f64, f64, f64)> = unsaturated_stars(on_grid)
            .into_iter()
            .map(|s| (s.x, s.y, s.flux))
            .filter(|s| s.2 > 0.0)
            .collect();
        if stars.len() < MIN_SIGNAL_PAIRS {
            return None;
        }
        let cell = 2.0 * SIGNAL_MATCH_PX;
        let mut index: HashMap<(i64, i64), Vec<usize>> = HashMap::new();
        for (i, (x, y, _)) in stars.iter().enumerate() {
            index
                .entry(((x / cell).floor() as i64, (y / cell).floor() as i64))
                .or_default()
                .push(i);
        }
        Some(Self {
            stars,
            noise,
            cell,
            index,
        })
    }

    fn nearest(&self, x: f64, y: f64) -> Option<usize> {
        let (cx, cy) = (
            (x / self.cell).floor() as i64,
            (y / self.cell).floor() as i64,
        );
        let mut best: Option<(usize, f64)> = None;
        for dx in -1..=1 {
            for dy in -1..=1 {
                for &i in self.index.get(&(cx + dx, cy + dy)).into_iter().flatten() {
                    let (rx, ry, _) = self.stars[i];
                    let d = (rx - x).hypot(ry - y);
                    if d <= SIGNAL_MATCH_PX && best.is_none_or(|(_, bd)| d < bd) {
                        best = Some((i, d));
                    }
                }
            }
        }
        best.map(|(i, _)| i)
    }

    /// Weigh a calibrated sub whose pixels map onto the grid by `transform`.
    /// `None` when too few of its stars match the reference's.
    pub(crate) fn weigh(
        &self,
        calibrated: &ImageData,
        transform: &TransformModel,
    ) -> Option<SignalWeight> {
        let noise = noise_of(calibrated)?;
        let mut ratios: Vec<f64> = unsaturated_stars(calibrated)
            .into_iter()
            .filter_map(|s| {
                let (x, y) = transform.apply(s.x, s.y);
                let i = self.nearest(x, y)?;
                let ratio = s.flux / self.stars[i].2;
                ratio.is_finite().then_some(ratio)
            })
            .collect();
        if ratios.len() < MIN_SIGNAL_PAIRS {
            return None;
        }
        ratios.sort_by(f64::total_cmp);
        let transparency = ratios[ratios.len() / 2].max(0.0);
        let noise_ratio = noise / self.noise;
        Some(SignalWeight {
            weight: (transparency / noise_ratio).powi(2),
            transparency,
            noise_ratio,
        })
    }
}

/// Constant added to every calibrated sample, in ADU, so that sky samples
/// that noise pulls below zero keep their value through the 16-bit star
/// detection. It is removed again from the finished master.
pub(crate) const CALIBRATION_PEDESTAL: f32 = 100.0;

/// Memory, in bytes, the batch integration may hold for one band of rows
/// across every sub. Registered subs that do not fit are kept on disk.
const DEFAULT_MEMORY_BUDGET: usize = 1 << 30;

/// Calibration masters of one group, loaded once and shared.
#[flutter_rust_bridge::frb(ignore)]
#[derive(Default, Clone)]
pub(crate) struct GroupMasters {
    dark: Option<Arc<ImageData>>,
    /// The dark's exposure in seconds, when its header says.
    dark_exposure: Option<f64>,
    flat: Option<Arc<FlatMaster>>,
    bias: Option<Arc<ImageData>>,
}

/// Calibration masters loaded once and shared by every group that names them.
#[flutter_rust_bridge::frb(ignore)]
#[derive(Default)]
struct MasterCache {
    images: HashMap<String, Arc<ImageData>>,
    flats: HashMap<String, Arc<FlatMaster>>,
}

fn present(path: &Option<String>) -> Option<&str> {
    path.as_deref().map(str::trim).filter(|p| !p.is_empty())
}

impl MasterCache {
    fn image(
        &mut self,
        path: &Option<String>,
        label: &str,
    ) -> Result<Option<Arc<ImageData>>, String> {
        let Some(path) = present(path) else {
            return Ok(None);
        };
        if let Some(image) = self.images.get(path) {
            return Ok(Some(Arc::clone(image)));
        }
        let image = Arc::new(
            read_image(Path::new(path))
                .map_err(|e| format!("failed to read {label} master '{path}': {e}"))?
                .image,
        );
        self.images.insert(path.to_string(), Arc::clone(&image));
        Ok(Some(image))
    }

    fn flat(&mut self, path: &Option<String>) -> Result<Option<Arc<FlatMaster>>, String> {
        let Some(key) = present(path) else {
            return Ok(None);
        };
        if let Some(flat) = self.flats.get(key) {
            return Ok(Some(Arc::clone(flat)));
        }
        let Some(flat) = load_optional_flat(path)? else {
            return Ok(None);
        };
        let flat = Arc::new(flat);
        self.flats.insert(key.to_string(), Arc::clone(&flat));
        Ok(Some(flat))
    }

    fn masters(&mut self, calibration: &CalibrationArgs) -> Result<GroupMasters, String> {
        Ok(GroupMasters {
            dark: self.image(&calibration.dark, "dark")?,
            dark_exposure: present(&calibration.dark)
                .and_then(fits_header_of)
                .and_then(|h| h.get_float("EXPTIME")),
            flat: self.flat(&calibration.flat)?,
            bias: self.image(&calibration.bias, "bias")?,
        })
    }
}

/// A light calibrated in floating point, and the 16-bit copy star detection
/// and registration run on.
pub(crate) struct CalibratedLight {
    pub(crate) image: ImageData,
    pub(crate) detection: ImageData,
    /// The multiplier applied to the dark's thermal signal.
    pub(crate) dark_scale: f64,
}

/// The calibrated samples rounded into 16 bits for star detection.
fn detection_copy(image: &ImageData) -> ImageData {
    let samples = skotiq_imaging::calibration::samples_f64(image);
    let data: Vec<u16> = samples
        .iter()
        .map(|v| {
            if v.is_finite() {
                v.round().clamp(0.0, 65535.0) as u16
            } else {
                0
            }
        })
        .collect();
    ImageData::from_u16(image.width, image.height, image.channels, &data)
}

/// The dark multiplier for a light of `light_exposure` seconds: the exposure
/// ratio when no exposure-matched dark exists. Scaling needs a bias, so the
/// pedestal can be separated from the dark's thermal signal.
fn dark_scale(masters: &GroupMasters, light_exposure: Option<f64>) -> Result<f64, String> {
    let (Some(_), Some(dark_s), Some(light_s)) =
        (&masters.dark, masters.dark_exposure, light_exposure)
    else {
        return Ok(1.0);
    };
    if dark_s <= 0.0 || light_s <= 0.0 || (light_s / dark_s - 1.0).abs() <= 0.01 {
        return Ok(1.0);
    }
    if masters.bias.is_none() {
        return Err(format!(
            "the dark is {dark_s} s and the light {light_s} s; a dark of another exposure can only be scaled with a master bias"
        ));
    }
    Ok(light_s / dark_s)
}

/// Read a light and apply its night's calibration in floating point.
fn calibrated_light(
    path: &str,
    exposure: Option<f64>,
    calibration: &CalibrationArgs,
    masters: &GroupMasters,
) -> Result<CalibratedLight, (&'static str, String)> {
    let image = read_image(Path::new(path))
        .map_err(|e| ("read", format!("cannot be read: {e}")))?
        .image;
    if !matches!(image.channels, 1 | 3) {
        return Err((
            "read",
            format!(
                "has {} channels; only mono and RGB lights are integrated",
                image.channels
            ),
        ));
    }
    let exposure = exposure
        .filter(|s| *s > 0.0)
        .or_else(|| fits_header_of(path).and_then(|h| h.get_float("EXPTIME")));
    let dark_scale = dark_scale(masters, exposure).map_err(|e| ("calibration", e))?;
    if calibration.scale_dark
        && masters.dark.is_some()
        && (masters.bias.is_none() || masters.dark_exposure.is_none() || exposure.is_none())
    {
        return Err((
            "calibration",
            "the dark is to be scaled, but scaling needs a master bias and the exposures of the dark and the light".to_string(),
        ));
    }
    let cal = skotiq_imaging::calibration::FloatCalibration {
        bias: masters.bias.as_deref(),
        dark: masters.dark.as_deref(),
        dark_scale,
        flat: masters.flat.as_deref().map(|f| &f.image),
        flat_pedestal: masters
            .flat
            .as_deref()
            .map(|f| f.pedestal)
            .unwrap_or(skotiq_imaging::calibration::FlatPedestal::Removed),
        output_pedestal: CALIBRATION_PEDESTAL,
    };
    let mut image = skotiq_imaging::calibration::calibrate_frame_f32(&image, &cal)
        .map_err(|e| ("calibration", format!("calibration failed: {e}")))?;
    if calibration.cosmetic_correction {
        cosmetic_correct_transient(&mut image, CosmeticConfig::default())
            .map_err(|e| ("calibration", format!("cosmetic correction failed: {e}")))?;
    }
    let detection = detection_copy(&image);
    Ok(CalibratedLight {
        image,
        detection,
        dark_scale,
    })
}

/// A sub resampled onto the grid: samples with `NaN` where it has no
/// coverage, and the covered locations.
pub(crate) struct OnGrid {
    pub(crate) pixels: Vec<f64>,
    pub(crate) covered: Vec<bool>,
}

impl OnGrid {
    pub(crate) fn new(
        calibrated: &ImageData,
        grid: (u32, u32),
        transform: &TransformModel,
        interp: Interpolator,
    ) -> Self {
        let warped = skotiq_imaging::registration::warp_to_grid(
            calibrated, grid.0, grid.1, transform, interp,
        );
        let channels = calibrated.channels as usize;
        let pixels = warped
            .pixels
            .iter()
            .enumerate()
            .map(|(i, &v)| {
                if warped.covered[i / channels] {
                    f64::from(v)
                } else {
                    f64::NAN
                }
            })
            .collect();
        Self {
            pixels,
            covered: warped.covered,
        }
    }

    fn overlap(&self) -> f64 {
        self.covered.iter().filter(|&&c| c).count() as f64 / self.covered.len().max(1) as f64
    }

    /// The 16-bit copy quality measurement and star matching run on.
    pub(crate) fn detection(&self, width: u32, height: u32, channels: u32) -> ImageData {
        let data: Vec<u16> = self
            .pixels
            .iter()
            .map(|v| {
                if v.is_finite() {
                    v.round().clamp(0.0, 65535.0) as u16
                } else {
                    0
                }
            })
            .collect();
        ImageData::from_u16(width, height, channels, &data)
    }
}

/// The calibration masters `calibration` names, for one accumulating fold.
pub(crate) fn fold_masters(calibration: &CalibrationArgs) -> Result<GroupMasters, String> {
    MasterCache::default().masters(calibration)
}

/// A light calibrated as a build calibrates it, for one accumulating fold.
pub(crate) fn calibrate_for_fold(
    path: &str,
    exposure: Option<f64>,
    calibration: &CalibrationArgs,
    masters: &GroupMasters,
) -> Result<CalibratedLight, String> {
    calibrated_light(path, exposure, calibration, masters).map_err(|(_, e)| format!("'{path}' {e}"))
}

/// The rejection the build applies, from the request token.
fn build_rejection(token: Option<&str>, frames: usize) -> Result<Reject, String> {
    Ok(
        match token
            .map(str::trim)
            .unwrap_or("")
            .to_ascii_lowercase()
            .as_str()
        {
            "" | "auto" => Reject::pixinsight_auto(frames),
            "none" => Reject::None,
            "percentile" => Reject::PercentileClip {
                low: 0.2,
                high: 0.1,
            },
            "winsorized" | "winsorizedsigma" => Reject::WinsorizedSigmaClip {
                low: 4.0,
                high: 3.0,
            },
            "linearfit" => Reject::LinearFitClip {
                low: 5.0,
                high: 4.0,
            },
            "esd" | "generalizedesd" => Reject::GeneralizedEsd {
                outliers: 0.3,
                alpha: 0.05,
                low_relaxation: 1.5,
            },
            other => return Err(format!("unknown rejection '{other}'")),
        },
    )
}

/// The weighting formula that weighs a sub by the inverse variance of its
/// noise on the reference's scale (PixInsight's noise evaluation weight).
pub(crate) const NOISE_FORMULA: &str = "noiseEvaluation";

/// How each sub is weighted in the build.
enum Weighting {
    None,
    StarSignal(ReferenceSignal),
    Noise,
    Quality(WeightFormula),
}

/// Why the normalization reference the caller asked for was not used.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct ReferenceFallback {
    pub(crate) requested: String,
    pub(crate) used: String,
    pub(crate) reason: String,
}

/// One sub that passed every check, waiting for integration.
struct Accepted {
    sub: FoldedSub,
    exposure_sec: f64,
    group: usize,
}

/// Fold every group's subs into one master and write it.
///
/// Each sub is calibrated in floating point, registered onto the grid with
/// coverage taken from the warp geometry, normalized to the filter's reference
/// and weighted. The registered subs are then integrated in one batch with
/// PixInsight's rejection for the number of subs, a band of rows at a time, so
/// the result does not depend on the order of the subs and memory stays
/// bounded.
pub(crate) fn master_build(args_json: &str) -> Result<MasterBuildResult, String> {
    let args: MasterBuildArgs =
        serde_json::from_str(args_json).map_err(|e| format!("invalid build args: {e}"))?;
    let result = master_build_inner(&args);
    match &result {
        Ok(r) => tracing::info!(
            "master build {:?}: {} of {} subs integrated, {} skipped, {:.0} s",
            args.filter,
            r.frame_count,
            r.frame_count + r.skipped.len(),
            r.skipped.len(),
            r.total_integration_sec
        ),
        Err(e) => tracing::warn!("master build {:?} failed: {e}", args.filter),
    }
    result
}

fn master_build_inner(args: &MasterBuildArgs) -> Result<MasterBuildResult, String> {
    if args.grid_reference.path.trim().is_empty() || args.master_fits_path.trim().is_empty() {
        return Err("build requires gridReference.path and masterFitsPath".to_string());
    }
    if !(0.0..=1.0).contains(&args.min_overlap)
        || args
            .max_eccentricity
            .is_some_and(|v| !v.is_finite() || !(0.0..=1.0).contains(&v))
    {
        return Err("overlap and eccentricity limits must be between 0 and 1".into());
    }
    let total: usize = args.groups.iter().map(|g| g.lights.len()).sum();
    if total == 0 {
        return Err("build requires at least one light".to_string());
    }
    for group in &args.groups {
        for light in &group.lights {
            if !light.exposure_sec.is_finite() || light.exposure_sec < 0.0 {
                return Err(format!(
                    "light '{}' has exposure {} s; an exposure is a non-negative number of seconds",
                    light.path, light.exposure_sec
                ));
            }
        }
    }

    let cancel = RunCancelToken::register(&args.run_id)?;
    cancel.check("calibrating", None, None)?;
    let mut cache = MasterCache::default();

    if args.validate_flats {
        for calibration in args
            .groups
            .iter()
            .map(|g| &g.calibration)
            .chain(std::iter::once(&args.grid_reference.calibration))
            .chain(args.normalization_reference.iter().map(|r| &r.calibration))
        {
            if let Some(flat) = cache.flat(&calibration.flat)? {
                validate_flat_response(&flat.image).map_err(|e| {
                    format!(
                        "Flat '{}': {e}. Select another flat or explicitly choose no flat.",
                        calibration.flat.as_deref().unwrap_or_default()
                    )
                })?;
            }
        }
    }
    let reg_cfg = build_registration_config(&args.settings.align)?;
    let interp = reg_cfg.interpolator;
    let grid_masters = cache.masters(&args.grid_reference.calibration)?;
    let grid = calibrated_light(
        &args.grid_reference.path,
        None,
        &args.grid_reference.calibration,
        &grid_masters,
    )
    .map_err(|(_, reason)| format!("the grid reference '{}' {reason}", args.grid_reference.path))?;
    let grid_stars =
        skotiq_imaging::registration::ReferenceStars::detect(&grid.detection, &reg_cfg)
            .map_err(|e| format!("the grid reference '{}': {e}", args.grid_reference.path))?;
    let min_stars = min_registration_stars(reg_cfg.transform_kind);
    if grid_stars.len() < min_stars {
        return Err(format!(
            "the grid reference '{}' has only {} detectable stars (need >= {min_stars})",
            args.grid_reference.path,
            grid_stars.len()
        ));
    }
    let grid_id = format!(
        "{:x}",
        Sha256::digest(args.grid_reference.path.trim().as_bytes())
    );
    let (gw, gh, gc) = (grid.image.width, grid.image.height, grid.image.channels);
    let (width, height, chan) = (gw as usize, gh as usize, gc as usize);
    let locations = width * height;
    drop(grid);

    // The normalization reference: a sub of this master's own filter, placed
    // on the grid. When the requested one cannot serve, the next sub that can
    // is used and the substitution is logged and reported.
    let norm_cfg = if args.settings.normalization.enabled {
        Some(build_normalization_config(&args.settings.normalization)?)
    } else {
        None
    };
    let requested = args
        .normalization_reference
        .clone()
        .unwrap_or_else(|| args.grid_reference.clone());
    let mut candidates = vec![requested.clone()];
    for group in &args.groups {
        for light in &group.lights {
            if !candidates.iter().any(|r| r.path == light.path) {
                candidates.push(BuildReferenceArgs {
                    path: light.path.clone(),
                    calibration: group.calibration.clone(),
                });
            }
        }
    }
    let mut chosen = None;
    let mut first_refusal: Option<String> = None;
    for reference in candidates {
        cancel.check("reference", None, None)?;
        let refusal = (|| -> Result<_, String> {
            let masters = cache.masters(&reference.calibration)?;
            let light = calibrated_light(&reference.path, None, &reference.calibration, &masters)
                .map_err(|(_, e)| e)?;
            let (transform, _) = skotiq_imaging::registration::solve_registration_against(
                &grid_stars,
                &light.detection,
                &reg_cfg,
            )
            .map_err(|e| format!("does not register: {e}"))?;
            let on_grid = OnGrid::new(&light.image, (gw, gh), &transform, interp);
            let detection = on_grid.detection(gw, gh, gc);
            let quality = aligned_quality(&detection, &FrameQualityConfig::default())
                .ok_or("its star shapes cannot be measured")?;
            if let Some(limit) = args.max_eccentricity {
                if quality.eccentricity.is_none_or(|e| e > limit) {
                    return Err(format!(
                        "star eccentricity {:?} exceeds {limit:.2}",
                        quality.eccentricity
                    ));
                }
            }
            if on_grid.overlap() < args.min_overlap {
                return Err(format!(
                    "{:.1}% field overlap; need at least {:.1}%",
                    on_grid.overlap() * 100.0,
                    args.min_overlap * 100.0
                ));
            }
            Ok((light, on_grid, detection))
        })();
        match refusal {
            Ok(found) => {
                chosen = Some((found, reference.path));
                break;
            }
            Err(reason) => {
                let reason = format!("'{}' {reason}", reference.path);
                tracing::warn!("normalization reference refused: {reason}");
                first_refusal.get_or_insert(reason);
            }
        }
    }
    let ((reference_light, reference_on_grid, reference_detection), normalization_path) =
        chosen.ok_or_else(|| {
            format!(
                "No normalization reference passes registration, overlap and star-shape limits ({}). Review the reference and excluded frames.",
                first_refusal.clone().unwrap_or_default()
            )
        })?;
    let normalization_fallback = (normalization_path != requested.path).then(|| {
        let fallback = ReferenceFallback {
            requested: requested.path.clone(),
            used: normalization_path.clone(),
            reason: first_refusal.clone().unwrap_or_default(),
        };
        tracing::warn!(
            "normalizing {:?} to '{}' instead of the requested '{}': {}",
            args.filter,
            fallback.used,
            fallback.requested,
            fallback.reason
        );
        fallback
    });
    let norm_planes: Option<(Vec<Vec<f64>>, Vec<bool>)> = norm_cfg.as_ref().map(|_| {
        (
            (0..chan)
                .map(|ch| extract_channel(&reference_on_grid.pixels, locations, chan, ch))
                .collect(),
            reference_on_grid.covered.clone(),
        )
    });
    let formula = args.settings.weighting.formula.trim();
    let weighting = if !args.settings.weighting.enabled {
        Weighting::None
    } else if formula.eq_ignore_ascii_case(STAR_SIGNAL_FORMULA) {
        Weighting::StarSignal(
            ReferenceSignal::measure(&reference_light.detection, &reference_detection).ok_or_else(
                || {
                    "the normalization reference has too few unsaturated stars to weight by"
                        .to_string()
                },
            )?,
        )
    } else if formula.eq_ignore_ascii_case(NOISE_FORMULA) {
        Weighting::Noise
    } else {
        Weighting::Quality(build_weight_formula(&args.settings.weighting)?)
    };
    drop((reference_light, reference_on_grid, reference_detection));
    drop(grid_masters);

    let budget = args
        .memory_budget_mb
        .map(|mb| (mb as usize) << 20)
        .unwrap_or(DEFAULT_MEMORY_BUDGET);
    let spool_dir = args
        .spool_dir
        .as_deref()
        .map(str::trim)
        .filter(|d| !d.is_empty())
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| {
            let mut dir = std::path::PathBuf::from(args.master_fits_path.trim());
            let name = dir
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default();
            dir.set_file_name(format!("{name}.subs"));
            dir
        });
    let mut spool = super::spool::FrameSpool::new(width, height, chan, total, budget, &spool_dir)?;

    let q_cfg = FrameQualityConfig::default();
    let mut accepted: Vec<Accepted> = Vec::new();
    let mut weights = Vec::new();
    let mut skipped = Vec::new();
    let mut groups = Vec::new();
    let mut done = 0u32;
    for (group_index, group) in args.groups.iter().enumerate() {
        let label = if group.label.trim().is_empty() {
            "group".to_string()
        } else {
            group.label.trim().to_string()
        };
        let calibration = group
            .lights
            .first()
            .map(|l| build_calibration_report(&l.path, &group.calibration))
            .unwrap_or_else(|| build_calibration_report("", &group.calibration));
        let masters = cache.masters(&group.calibration)?;
        let skipped_before = skipped.len();
        let mut summary = GroupSummary {
            label: label.clone(),
            offered: group.lights.len(),
            folded: 0,
            skipped: 0,
            integration_sec: 0.0,
            calibration,
            dark_scale: None,
        };
        for light in &group.lights {
            cancel.check("registering", Some(done), Some(total as u32))?;
            emit_integration_progress(
                "registering",
                FRACTION_INTEGRATE * done as f32 / total as f32,
                Some(done),
                Some(total as u32),
            );
            done += 1;
            let mut skip = |stage: &str, reason: String| {
                skipped.push(SkippedSub {
                    path: light.path.clone(),
                    group: label.clone(),
                    stage: stage.to_string(),
                    reason,
                });
            };
            let exposure = (light.exposure_sec > 0.0).then_some(light.exposure_sec);
            let calibrated =
                match calibrated_light(&light.path, exposure, &group.calibration, &masters) {
                    Ok(image) => image,
                    Err((stage, reason)) => {
                        skip(stage, reason);
                        continue;
                    }
                };
            if (calibrated.dark_scale - 1.0).abs() > 1e-9 {
                summary.dark_scale = Some(calibrated.dark_scale);
            }
            let image = &calibrated.image;
            if image.width != gw || image.height != gh || image.channels != gc {
                skip(
                    "geometry",
                    format!(
                        "is {}×{}×{}, the grid is {gw}×{gh}×{gc}",
                        image.width, image.height, image.channels
                    ),
                );
                continue;
            }
            let (transform, stats) = match skotiq_imaging::registration::solve_registration_against(
                &grid_stars,
                &calibrated.detection,
                &reg_cfg,
            ) {
                Ok(r) => r,
                Err(e) => {
                    skip("registration", e.to_string());
                    continue;
                }
            };
            let signal = match &weighting {
                Weighting::StarSignal(reference) => {
                    match reference.weigh(&calibrated.detection, &transform) {
                        Some(s) => Some(s),
                        None => {
                            skip(
                                "quality",
                                format!(
                                    "fewer than {MIN_SIGNAL_PAIRS} of its stars match the reference's, so its signal cannot be measured"
                                ),
                            );
                            continue;
                        }
                    }
                }
                _ => None,
            };
            let noise = match weighting {
                Weighting::Noise => noise_of(&calibrated.detection),
                _ => None,
            };
            let mut on_grid = OnGrid::new(image, (gw, gh), &transform, interp);
            drop(calibrated);
            let overlap = on_grid.overlap();
            if overlap < args.min_overlap {
                skip(
                    "framing",
                    format!(
                        "{:.1}% field overlap; need at least {:.1}%",
                        overlap * 100.0,
                        args.min_overlap * 100.0
                    ),
                );
                continue;
            }
            let Some(quality) = aligned_quality(&on_grid.detection(gw, gh, gc), &q_cfg) else {
                skip("quality", "its quality could not be measured".to_string());
                continue;
            };
            if let Some(limit) = args.max_eccentricity {
                if quality.eccentricity.is_none_or(|e| e > limit) {
                    skip(
                        "quality",
                        format!(
                            "star eccentricity {:?} exceeds {limit:.2} or could not be measured",
                            quality.eccentricity
                        ),
                    );
                    continue;
                }
            }
            let mut scale = 1.0;
            if let (Some(cfg), Some((planes, covered))) = (norm_cfg.as_ref(), norm_planes.as_ref())
            {
                let shared = CoverageMask::new(
                    width,
                    height,
                    (0..locations)
                        .map(|i| covered[i] && on_grid.covered[i])
                        .collect(),
                )
                .expect("the mask has one entry per pixel");
                let mut failed = None;
                for (ch, ref_plane) in planes.iter().enumerate() {
                    let mut plane = extract_channel(&on_grid.pixels, locations, chan, ch);
                    match estimate_normalization(&plane, ref_plane, &shared, width, height, cfg) {
                        Ok(coeffs) => {
                            scale = coeffs.scale;
                            apply_normalization(&mut plane, &coeffs, width, height);
                            write_channel(&mut on_grid.pixels, locations, chan, ch, &plane);
                        }
                        Err(e) => failed = Some(e.to_string()),
                    }
                }
                if let Some(reason) = failed {
                    skip("normalization", reason);
                    continue;
                }
            }
            let weight = match &weighting {
                Weighting::StarSignal(_) => signal.map(|s| s.weight).unwrap_or(0.0),
                Weighting::Noise => match noise {
                    Some(n) if n * scale > 0.0 => 1.0 / (n * scale).powi(2),
                    _ => 0.0,
                },
                Weighting::Quality(formula) => {
                    accumulation_weights(std::slice::from_ref(&quality), formula)[0]
                }
                Weighting::None => 1.0,
            };
            if !(weight.is_finite() && weight > 0.0) {
                skip("quality", "its integration weight is zero".to_string());
                continue;
            }
            let samples: Vec<f32> = on_grid.pixels.iter().map(|&v| v as f32).collect();
            drop(on_grid);
            spool.push(&samples)?;
            weights.push(weight);
            let m = transform.matrix;
            accepted.push(Accepted {
                sub: FoldedSub {
                    path: light.path.clone(),
                    group: label.clone(),
                    weight,
                    transparency: signal.map(|s| s.transparency),
                    noise_ratio: signal.map(|s| s.noise_ratio),
                    stars_matched: stats.inlier_count,
                    rms_px: stats.rms_residual_px,
                    rotation_deg: m[1][0].atan2(m[0][0]).to_degrees(),
                    shift_px: [m[0][2], m[1][2]],
                },
                exposure_sec: light.exposure_sec,
                group: group_index,
            });
        }
        summary.skipped = skipped.len() - skipped_before;
        groups.push(summary);
    }
    cancel.check("integrating", Some(done), Some(total as u32))?;

    if accepted.is_empty() {
        let outcome = NoSubsIntegrated {
            kind: NO_SUBS_KIND.to_string(),
            filter: args.filter.clone(),
            offered: total,
            skipped: skipped.clone(),
        };
        tracing::warn!(
            "no sub of {:?} could be integrated; first reasons: {:?}",
            args.filter,
            skipped
                .iter()
                .take(3)
                .map(|s| &s.reason)
                .collect::<Vec<_>>()
        );
        return Err(serde_json::to_string(&outcome)
            .unwrap_or_else(|_| format!("none of the {total} subs could be integrated")));
    }

    let reject = build_rejection(args.rejection.as_deref(), spool.len())?;
    let integrated = integrate_spool(&spool, &weights, reject, budget, &cancel, (done, total))?;
    drop(spool);
    for a in &accepted {
        groups[a.group].folded += 1;
        groups[a.group].integration_sec += a.exposure_sec;
    }
    let folded: Vec<FoldedSub> = accepted.into_iter().map(|a| a.sub).collect();

    emit_integration_progress("writing", FRACTION_WRITE, Some(done), Some(total as u32));
    if let Some(path) = &args.coverage_fits_path {
        let mut header = FitsHeader::new();
        header.set_int("NFRAMES", folded.len() as i64);
        header.set_string("GRIDREF", &grid_id);
        header.add_history("Subs whose warp covers each pixel, rejected samples included");
        ensure_parent_dir(Path::new(path))?;
        write_fits(
            Path::new(path),
            &ImageData::from_f32(gw, gh, gc, &integrated.coverage),
            &header,
        )
        .map_err(|e| format!("failed to write coverage: {e:?}"))?;
    }
    let image = ImageData::from_f32(gw, gh, gc, &integrated.master);
    let master_path = Path::new(&args.master_fits_path);
    ensure_parent_dir(master_path)?;
    let seconds: f64 = groups.iter().map(|g| g.integration_sec).sum();
    let mut header = FitsHeader::new();
    if let Some(source) = fits_header_of(&normalization_path) {
        copy_optics_cards(&mut header, &source);
    }
    header.set_string("IMAGETYP", "MASTER_LIGHT");
    header.set_string("FRAMETYP", "MASTER");
    header.set_string("CALSTAT", "Skotiq multi-night master");
    header.set_string("GRIDREF", &grid_id);
    header.set_int("NFRAMES", folded.len() as i64);
    header.set_int("NCOMBINE", folded.len() as i64);
    header.set_float("EXPTIME", seconds);
    header.set_float("TOTALEXP", seconds);
    if let Some(f) = &args.filter {
        header.set_string("FILTER", f);
    }
    if let Some(t) = &args.target {
        header.set_string("OBJECT", t);
    }
    header.set_string("REJECTM", &reject_label(&reject));
    header.add_history(&format!(
        "Registered onto {}",
        args.grid_reference.path.trim()
    ));
    header.add_history(&format!("Normalized to {normalization_path}"));
    if let Some(fallback) = &normalization_fallback {
        header.add_history(&format!(
            "Requested normalization reference {} not used: {}",
            fallback.requested, fallback.reason
        ));
    }
    header.add_history(&format!(
        "Calibrated in 32-bit float with a {CALIBRATION_PEDESTAL} ADU pedestal, removed from this master"
    ));
    header.add_history(&format!(
        "Batch integration: weighted mean, rejection {}, {} of {} samples rejected",
        reject_label(&reject),
        integrated.rejected,
        integrated.samples
    ));
    header.add_history(&format!(
        "Weights: {}",
        if args.settings.weighting.enabled {
            formula
        } else {
            "none"
        }
    ));
    for group in &groups {
        header.add_history(&format!(
            "Group '{}': {} of {} subs integrated, {:.0} s",
            group.label, group.folded, group.offered, group.integration_sec
        ));
        if let Some(k) = group.dark_scale {
            header.add_history(&format!("  dark scaled by the exposure ratio {k:.4}"));
        }
        for applied in &group.calibration.masters {
            header.add_history(&format!(
                "  {}: {}",
                applied.kind,
                applied.path.as_deref().unwrap_or("none")
            ));
        }
    }
    write_fits(master_path, &image, &header)
        .map_err(|e| format!("failed to write master: {e:?}"))?;
    let wcs_source = attach_wcs(
        &mut header,
        &args.grid_reference.path,
        master_path,
        (gw, gh),
    );
    if let Some(source) = &wcs_source {
        header.add_history(&format!("WCS: {source}"));
        write_fits(master_path, &image, &header)
            .map_err(|e| format!("failed to write master: {e:?}"))?;
    }
    let preview_path = match args.preview_png_path.as_deref().map(str::trim) {
        Some(p) if !p.is_empty() => {
            write_preview_png(&image, Path::new(p))?;
            Some(p.to_string())
        }
        _ => None,
    };
    emit_integration_progress("done", FRACTION_DONE, Some(done), Some(total as u32));

    let mut rms: Vec<f64> = folded.iter().map(|f| f.rms_px).collect();
    rms.sort_by(f64::total_cmp);
    Ok(MasterBuildResult {
        master_path: args.master_fits_path.clone(),
        preview_path,
        filter: args.filter.clone(),
        frame_count: folded.len(),
        total_integration_sec: seconds,
        width: gw,
        height: gh,
        rejected: integrated.rejected,
        coverage_path: args.coverage_fits_path.clone(),
        median_rms_px: rms.get(rms.len() / 2).copied(),
        groups,
        folded,
        skipped,
        rejection: reject_label(&reject),
        normalization_reference: normalization_path,
        normalization_fallback,
        wcs_source,
    })
}

/// The `kind` of the error a build returns when no sub could be integrated.
pub(crate) const NO_SUBS_KIND: &str = "noSubsIntegrated";

/// The error payload of a build in which no sub could be integrated, so the
/// caller can report the filter and carry on with the others.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct NoSubsIntegrated {
    pub(crate) kind: String,
    pub(crate) filter: Option<String>,
    pub(crate) offered: usize,
    pub(crate) skipped: Vec<SkippedSub>,
}

/// The integrated master on the grid, its per-pixel coverage and the
/// rejection totals.
struct Integrated {
    master: Vec<f32>,
    coverage: Vec<f32>,
    rejected: u64,
    samples: u64,
}

/// Integrate every spooled sub, reading the same band of rows from each, with
/// `reject` and a weighted mean. The calibration pedestal is removed and
/// pixels no sub covers are 0.
fn integrate_spool(
    spool: &super::spool::FrameSpool,
    weights: &[f64],
    reject: Reject,
    budget: usize,
    cancel: &RunCancelToken,
    progress: (u32, usize),
) -> Result<Integrated, String> {
    let (width, height, channels) = spool.geometry();
    let n = spool.len();
    let row_bytes = width * channels * 8 * n;
    let rows = (budget / row_bytes.max(1)).clamp(1, height);
    let config = IntegrationConfig {
        combine: Combine::Mean,
        reject,
        output_type: PixelType::F32,
        generate_rejection_map: false,
        generate_weight_map: false,
        min_coverage: 1,
    };
    let mut master = Vec::with_capacity(width * height * channels);
    let mut coverage = Vec::with_capacity(width * height * channels);
    let (mut rejected, mut samples) = (0u64, 0u64);
    let mut buffers: Vec<Vec<f64>> = vec![Vec::new(); n];
    let mut y0 = 0;
    while y0 < height {
        let band = rows.min(height - y0);
        cancel.check("integrating", Some(progress.0), Some(progress.1 as u32))?;
        emit_integration_progress(
            "integrating",
            FRACTION_INTEGRATE
                + (FRACTION_INTEGRATE_DONE - FRACTION_INTEGRATE) * y0 as f32 / height as f32,
            Some(progress.0),
            Some(progress.1 as u32),
        );
        for (i, buffer) in buffers.iter_mut().enumerate() {
            spool.read_rows(i, y0, band, buffer)?;
        }
        let frames: Vec<IntegrationFrame<'_>> = buffers
            .iter()
            .zip(weights)
            .map(|(pixels, &weight)| IntegrationFrame {
                pixels,
                weight,
                coverage: None,
            })
            .collect();
        let out = integrate_frames(&frames, width as u32, band as u32, channels as u32, &config)
            .map_err(|e| format!("integration failed: {e}"))?;
        rejected += out.stats.total_rejected;
        samples += out.stats.total_samples;
        let values = out
            .master
            .as_f32()
            .ok_or("integration returned no float master")?;
        let mut counts = vec![0u32; values.len()];
        counts
            .par_chunks_mut(4096)
            .enumerate()
            .for_each(|(chunk, counts)| {
                let start = chunk * 4096;
                let len = counts.len();
                for buffer in &buffers {
                    for (count, v) in counts.iter_mut().zip(&buffer[start..start + len]) {
                        *count += u32::from(v.is_finite());
                    }
                }
            });
        for (v, &count) in values.iter().zip(&counts) {
            coverage.push(count as f32);
            master.push(if count == 0 {
                0.0
            } else {
                v - CALIBRATION_PEDESTAL
            });
        }
        y0 += band;
    }
    Ok(Integrated {
        master,
        coverage,
        rejected,
        samples,
    })
}

/// A broad near-black region or a banded readout cannot calibrate light
/// reaching the sensor.
fn validate_flat_response(image: &ImageData) -> Result<(), String> {
    let pixels = image_to_f64(image);
    let mut sampled: Vec<f64> = pixels
        .iter()
        .step_by((pixels.len() / 100_000).max(1))
        .copied()
        .collect();
    if sampled.is_empty() || sampled.iter().any(|v| !v.is_finite()) {
        return Err("contains missing or non-finite response".into());
    }
    sampled.sort_by(f64::total_cmp);
    let median = sampled[sampled.len() / 2];
    if median <= 0.0 {
        return Err("has no positive median response".into());
    }
    let dark = sampled.iter().filter(|&&v| v < median * 0.1).count();
    if dark as f64 / sampled.len() as f64 > 0.005 {
        return Err(format!("{:.1}% of the flat has less than 10% of its median response (possible obstruction or shutter band)", 100.0 * dark as f64 / sampled.len() as f64));
    }
    if let Some(bands) = skotiq_imaging::calibration_masters::flat_bands(image) {
        return Err(format!("is banded: {bands}"));
    }
    Ok(())
}

pub(crate) fn check_build_calibration(json: &str) -> Result<serde_json::Value, String> {
    let reference: BuildReferenceArgs = serde_json::from_str(json).map_err(|e| e.to_string())?;
    let mut cache = MasterCache::default();
    let masters = cache.masters(&reference.calibration)?;
    if let Some(flat) = &masters.flat {
        validate_flat_response(&flat.image)?;
    }
    let _ = calibrated_light(&reference.path, None, &reference.calibration, &masters)
        .map_err(|(_, e)| e)?;
    let report = build_calibration_report(&reference.path, &reference.calibration);
    // A build scales a dark of another exposure when a bias is present, so
    // that difference does not block it.
    let scales_darks = masters.bias.is_some();
    for master in &report.masters {
        if master.mismatches.iter().any(|m| {
            !m.within_tolerance
                && !(scales_darks && master.kind == "dark" && m.dimension == "EXPTIME")
        }) {
            return Err(format!(
                "{} calibration mismatch: {:?}",
                master.kind, master.mismatches
            ));
        }
    }
    serde_json::to_value(report).map_err(|e| e.to_string())
}
