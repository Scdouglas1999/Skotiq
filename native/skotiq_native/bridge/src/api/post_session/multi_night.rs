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
    /// Online rejection thresholds (σ); both absent ⇒ a plain weighted mean.
    pub(crate) clip: MasterSettingsArgs,
    pub(crate) master_fits_path: String,
    pub(crate) preview_png_path: Option<String>,
    /// Geometric support count, including sigma-rejected samples.
    pub(crate) coverage_fits_path: Option<String>,
    pub(crate) min_overlap: f64,
    pub(crate) max_eccentricity: Option<f64>,
    pub(crate) validate_flats: bool,
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
#[derive(Debug, Clone, Serialize)]
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

/// Calibration masters loaded once and shared by every group that names them.
#[derive(Default)]
struct MasterCache {
    loaded: HashMap<String, Arc<ImageData>>,
}

impl MasterCache {
    fn get(
        &mut self,
        path: &Option<String>,
        label: &str,
    ) -> Result<Option<Arc<ImageData>>, String> {
        let Some(path) = path.as_deref().map(str::trim).filter(|p| !p.is_empty()) else {
            return Ok(None);
        };
        if let Some(image) = self.loaded.get(path) {
            return Ok(Some(Arc::clone(image)));
        }
        let image = Arc::new(
            read_image(Path::new(path))
                .map_err(|e| format!("failed to read {label} master '{path}': {e}"))?
                .image,
        );
        self.loaded.insert(path.to_string(), Arc::clone(&image));
        Ok(Some(image))
    }

    /// Dark, flat and bias for `calibration`.
    fn masters(
        &mut self,
        calibration: &CalibrationArgs,
    ) -> Result<[Option<Arc<ImageData>>; 3], String> {
        Ok([
            self.get(&calibration.dark, "dark")?,
            self.get(&calibration.flat, "flat")?,
            self.get(&calibration.bias, "bias")?,
        ])
    }
}

/// Read a light and apply its night's calibration.
fn calibrated_light(
    path: &str,
    calibration: &CalibrationArgs,
    masters: &[Option<Arc<ImageData>>; 3],
) -> Result<ImageData, (&'static str, String)> {
    let mut image = read_image(Path::new(path))
        .map_err(|e| ("read", format!("cannot be read: {e}")))?
        .image;
    if image.pixel_type != PixelType::U16 {
        return Err((
            "read",
            format!(
                "is {:?}, and only 16-bit lights are integrated",
                image.pixel_type
            ),
        ));
    }
    let [dark, flat, bias] = masters;
    if dark.is_some() || flat.is_some() || bias.is_some() {
        image = skotiq_imaging::calibration::calibrate_frame(
            &image,
            dark.as_deref(),
            None,
            bias.as_deref(),
        )
        .map_err(|e| ("calibration", format!("calibration failed: {e}")))?;
    }
    // Library flats are already bias/dark-flat corrected response maps.
    // A light's bias must never be subtracted from that normalized response.
    if let Some(flat) = flat {
        image = skotiq_imaging::calibration::divide_flat(&image, flat)
            .map_err(|e| ("calibration", format!("flat correction failed: {e}")))?;
    }
    if calibration.cosmetic_correction {
        cosmetic_correct_transient(&mut image, CosmeticConfig::default())
            .map_err(|e| ("calibration", format!("cosmetic correction failed: {e}")))?;
    }
    Ok(image)
}

/// Fold every group's subs into one master and write it.
pub(crate) fn master_build(args_json: &str) -> Result<MasterBuildResult, String> {
    let args: MasterBuildArgs =
        serde_json::from_str(args_json).map_err(|e| format!("invalid build args: {e}"))?;
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
            if let Some(flat) = cache.get(&calibration.flat, "flat")? {
                validate_flat_response(&flat).map_err(|e| {
                    format!(
                        "Flat '{}': {e}. Select another flat or explicitly choose no flat.",
                        calibration.flat.as_deref().unwrap_or_default()
                    )
                })?;
            }
        }
    }
    let reg_cfg = build_registration_config(&args.settings.align)?;
    let grid_masters = cache.masters(&args.grid_reference.calibration)?;
    let grid = calibrated_light(
        &args.grid_reference.path,
        &args.grid_reference.calibration,
        &grid_masters,
    )
    .map_err(|(_, reason)| format!("the grid reference '{}' {reason}", args.grid_reference.path))?;
    let min_stars = min_registration_stars(reg_cfg.transform_kind);
    let grid_stars = registrable_star_count(&grid, &reg_cfg);
    if grid_stars < min_stars {
        return Err(format!(
            "the grid reference '{}' has only {grid_stars} detectable stars (need >= {min_stars})",
            args.grid_reference.path
        ));
    }

    let grid_id = format!(
        "{:x}",
        Sha256::digest(args.grid_reference.path.trim().as_bytes())
    );
    let width = grid.width as usize;
    let height = grid.height as usize;
    let chan = grid.channels as usize;
    let locations = width * height;

    // The normalization reference, on the grid, with the pixels it covers.
    let norm_cfg = if args.settings.normalization.enabled {
        Some(build_normalization_config(&args.settings.normalization)?)
    } else {
        None
    };
    // The reference of this master's own filter, as calibrated and as placed
    // on the grid.
    let mut candidates = Vec::new();
    if let Some(reference) = &args.normalization_reference {
        candidates.push(reference.clone());
    } else {
        candidates.push(args.grid_reference.clone());
    }
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
    for reference in candidates {
        cancel.check("reference", None, None)?;
        let masters = cache.masters(&reference.calibration)?;
        let Ok(image) = calibrated_light(&reference.path, &reference.calibration, &masters) else {
            continue;
        };
        let Ok(registered) = register_frame(&grid, &image, &reg_cfg) else {
            continue;
        };
        let Some(quality) = aligned_quality(&registered.aligned, &FrameQualityConfig::default())
        else {
            continue;
        };
        if args
            .max_eccentricity
            .is_some_and(|limit| quality.eccentricity.is_none_or(|e| e > limit))
        {
            continue;
        }
        let pixels = image_to_f64(&registered.aligned);
        let coverage =
            CoverageMask::from_zero_fill(&derive_luma_f64(&pixels, locations, chan), width, height);
        let overlap =
            (0..locations).filter(|&i| coverage.is_valid_at(i)).count() as f64 / locations as f64;
        if overlap < args.min_overlap {
            continue;
        }
        chosen = Some((image, registered.aligned, reference.path));
        break;
    }
    let (filter_reference, filter_reference_on_grid, normalization_path) = chosen.ok_or("No normalization reference passes registration, overlap and star-shape limits. Review the reference and excluded frames.")?;
    let norm_planes: Option<(Vec<Vec<f64>>, Vec<bool>)> = norm_cfg.as_ref().map(|_| {
        let pixels = image_to_f64(&filter_reference_on_grid);
        let covered = derive_luma_f64(&pixels, locations, chan)
            .iter()
            .map(|v| v.is_finite() && *v != 0.0)
            .collect();
        (
            (0..chan)
                .map(|ch| extract_channel(&pixels, locations, chan, ch))
                .collect(),
            covered,
        )
    });
    let star_weighting = args.settings.weighting.enabled
        && args
            .settings
            .weighting
            .formula
            .trim()
            .eq_ignore_ascii_case(STAR_SIGNAL_FORMULA);
    let reference_signal = if star_weighting {
        Some(
            ReferenceSignal::measure(&filter_reference, &filter_reference_on_grid).ok_or_else(
                || {
                    "the normalization reference has too few unsaturated stars to weight by"
                        .to_string()
                },
            )?,
        )
    } else {
        None
    };
    drop(filter_reference);
    drop(filter_reference_on_grid);

    let clip = match (args.clip.online_clip_low, args.clip.online_clip_high) {
        (Some(low), Some(high)) => Some(OnlineClip { low, high }),
        _ => None,
    };
    let mut master = IntegratedMaster::create(
        &grid,
        &MasterCreateConfig {
            mode: AccumulationMode::RunningWeightedMean { clip },
            filter: args.filter.clone(),
            target: args.target.clone(),
        },
    )
    .map_err(|e| format!("master create failed: {e}"))?;
    let geom = master.geometry.clone();
    drop(grid_masters);

    let q_cfg = FrameQualityConfig::default();
    let formula = if args.settings.weighting.enabled && !star_weighting {
        Some(build_weight_formula(&args.settings.weighting)?)
    } else {
        None
    };

    let mut folded = Vec::new();
    let mut skipped = Vec::new();
    let mut groups = Vec::new();
    let mut rejected = 0u64;
    let mut done = 0u32;
    for group in &args.groups {
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
        let mut summary = GroupSummary {
            label: label.clone(),
            offered: group.lights.len(),
            folded: 0,
            skipped: 0,
            integration_sec: 0.0,
            calibration,
        };
        for light in &group.lights {
            cancel.check("registering", Some(done), Some(total as u32))?;
            emit_integration_progress(
                "registering",
                done as f32 / total as f32,
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
            let image = match calibrated_light(&light.path, &group.calibration, &masters) {
                Ok(image) => image,
                Err((stage, reason)) => {
                    skip(stage, reason);
                    summary.skipped += 1;
                    continue;
                }
            };
            if image.width != grid.width
                || image.height != grid.height
                || image.channels != grid.channels
            {
                skip(
                    "geometry",
                    format!(
                        "is {}×{}×{}, the grid is {}×{}×{}",
                        image.width,
                        image.height,
                        image.channels,
                        grid.width,
                        grid.height,
                        grid.channels
                    ),
                );
                summary.skipped += 1;
                continue;
            }
            let registered = match register_frame(&grid, &image, &reg_cfg) {
                Ok(r) => r,
                Err(e) => {
                    skip("registration", e.to_string());
                    summary.skipped += 1;
                    continue;
                }
            };
            let signal = reference_signal
                .as_ref()
                .map(|reference| reference.weigh(&image, &registered.transform));
            drop(image);
            if let Err(e) = frame_buffer_for_master(0, &registered.aligned, &geom) {
                skip("geometry", e.to_string());
                summary.skipped += 1;
                continue;
            }
            let Some(quality) = aligned_quality(&registered.aligned, &q_cfg) else {
                skip("quality", "its quality could not be measured".to_string());
                summary.skipped += 1;
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
                    summary.skipped += 1;
                    continue;
                }
            }
            let mut pixels = image_to_f64(&registered.aligned);
            let coverage = CoverageMask::from_zero_fill(
                &derive_luma_f64(&pixels, locations, chan),
                width,
                height,
            );
            let overlap = (0..locations).filter(|&i| coverage.is_valid_at(i)).count() as f64
                / locations as f64;
            if overlap < args.min_overlap {
                skip(
                    "framing",
                    format!(
                        "{:.1}% field overlap; need at least {:.1}%",
                        overlap * 100.0,
                        args.min_overlap * 100.0
                    ),
                );
                summary.skipped += 1;
                continue;
            }
            if let (Some(cfg), Some((planes, covered))) = (norm_cfg.as_ref(), norm_planes.as_ref())
            {
                let shared = CoverageMask::new(
                    width,
                    height,
                    (0..locations)
                        .map(|i| covered[i] && coverage.is_valid_at(i))
                        .collect(),
                )
                .expect("the mask has one entry per pixel");
                let mut failed = None;
                for (ch, ref_plane) in planes.iter().enumerate() {
                    let mut plane = extract_channel(&pixels, locations, chan, ch);
                    match estimate_normalization(&plane, ref_plane, &shared, width, height, cfg) {
                        Ok(coeffs) => {
                            apply_normalization(&mut plane, &coeffs, width, height);
                            write_channel(&mut pixels, locations, chan, ch, &plane);
                        }
                        Err(e) => failed = Some(e.to_string()),
                    }
                }
                if let Some(reason) = failed {
                    skip("normalization", reason);
                    summary.skipped += 1;
                    continue;
                }
            }
            let weight = match (&signal, &formula) {
                (Some(Some(weight)), _) => weight.weight,
                (Some(None), _) => {
                    skip(
                        "quality",
                        format!(
                            "fewer than {MIN_SIGNAL_PAIRS} of its stars match the reference's, so its signal cannot be measured"
                        ),
                    );
                    summary.skipped += 1;
                    continue;
                }
                (None, Some(formula)) => {
                    accumulation_weights(std::slice::from_ref(&quality), formula)[0]
                }
                (None, None) => 1.0,
            };
            let frame = IntegrationFrame {
                pixels: &pixels,
                weight,
                coverage: Some(&coverage),
            };
            let report = master
                .add_frames(&[frame], &[light.exposure_sec], &label)
                .map_err(|e| format!("folding '{}' failed: {e}", light.path))?;
            rejected += report.rejected;
            if report.frames_added == 0 {
                skip("quality", "its integration weight is zero".to_string());
                summary.skipped += 1;
                continue;
            }
            let m = registered.transform.matrix;
            folded.push(FoldedSub {
                path: light.path.clone(),
                group: label.clone(),
                weight,
                transparency: signal.flatten().map(|s| s.transparency),
                noise_ratio: signal.flatten().map(|s| s.noise_ratio),
                stars_matched: registered.stats.inlier_count,
                rms_px: registered.stats.rms_residual_px,
                rotation_deg: m[1][0].atan2(m[0][0]).to_degrees(),
                shift_px: [m[0][2], m[1][2]],
            });
            summary.folded += 1;
            summary.integration_sec += light.exposure_sec;
        }
        groups.push(summary);
    }
    cancel.check("integrating", Some(done), Some(total as u32))?;

    if folded.is_empty() {
        let reasons: Vec<String> = skipped
            .iter()
            .take(3)
            .map(|s| format!("{}: {}", s.path, s.reason))
            .collect();
        return Err(format!(
            "none of the {total} subs could be folded ({})",
            reasons.join("; ")
        ));
    }

    emit_integration_progress("writing", FRACTION_WRITE, Some(done), Some(total as u32));
    let image = master.finalize();
    if let Some(path) = &args.coverage_fits_path {
        let counts: Vec<f32> = master
            .state
            .coverage
            .iter()
            .zip(&master.state.rejected)
            .map(|(&accepted, &rejected)| (accepted as f64 + rejected as f64) as f32)
            .collect();
        let mut header = FitsHeader::new();
        header.set_int("NFRAMES", folded.len() as i64);
        header.set_string("GRIDREF", &grid_id);
        ensure_parent_dir(Path::new(path))?;
        write_fits(
            Path::new(path),
            &ImageData::from_f32(grid.width, grid.height, grid.channels, &counts),
            &header,
        )
        .map_err(|e| format!("failed to write coverage: {e:?}"))?;
    }
    drop(master);
    let master_path = Path::new(&args.master_fits_path);
    ensure_parent_dir(master_path)?;
    let mut header = FitsHeader::new();
    header.set_string("IMAGETYP", "MASTER_LIGHT");
    header.set_string("FRAMETYP", "MASTER");
    header.set_string("CALSTAT", "Skotiq multi-night master");
    header.set_string("GRIDREF", &grid_id);
    header.set_int("NFRAMES", folded.len() as i64);
    let seconds: f64 = groups.iter().map(|g| g.integration_sec).sum();
    header.set_float("EXPTIME", seconds);
    if let Some(f) = &args.filter {
        header.set_string("FILTER", f);
    }
    if let Some(t) = &args.target {
        header.set_string("OBJECT", t);
    }
    header.add_history(&format!(
        "Registered onto {}",
        args.grid_reference.path.trim()
    ));
    header.add_history(&format!("Normalized to {}", normalization_path));
    for group in &groups {
        header.add_history(&format!(
            "Group '{}': {} of {} subs folded, {:.0} s",
            group.label, group.folded, group.offered, group.integration_sec
        ));
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
        master_path: args.master_fits_path,
        preview_path,
        filter: args.filter,
        frame_count: folded.len(),
        total_integration_sec: seconds,
        width: image.width,
        height: image.height,
        rejected,
        coverage_path: args.coverage_fits_path,
        median_rms_px: rms.get(rms.len() / 2).copied(),
        groups,
        folded,
        skipped,
    })
}

/// A broad near-black region cannot calibrate light reaching the sensor.
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
    Ok(())
}

pub(crate) fn check_build_calibration(json: &str) -> Result<serde_json::Value, String> {
    let reference: BuildReferenceArgs = serde_json::from_str(json).map_err(|e| e.to_string())?;
    let mut cache = MasterCache::default();
    let masters = cache.masters(&reference.calibration)?;
    if let Some(flat) = &masters[1] {
        validate_flat_response(flat)?;
    }
    let _ =
        calibrated_light(&reference.path, &reference.calibration, &masters).map_err(|(_, e)| e)?;
    let report = build_calibration_report(&reference.path, &reference.calibration);
    for master in &report.masters {
        if master.mismatches.iter().any(|m| !m.within_tolerance) {
            return Err(format!(
                "{} calibration mismatch: {:?}",
                master.kind, master.mismatches
            ));
        }
    }
    serde_json::to_value(report).map_err(|e| e.to_string())
}
