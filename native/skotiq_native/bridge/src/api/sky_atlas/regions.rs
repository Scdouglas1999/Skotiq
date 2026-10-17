use super::*;

/// Summarise a circular region of the atlas (the tiles a cone covers): aggregate
/// integration time, frame count, coverage depth, and tile tally — the numbers a
/// "Your Sky" region card shows.
///
/// ```jsonc
/// { "atlasRoot": "/…", "order": 9,
///   "centerRa": 83.6, "centerDec": -5.4, "radiusDeg": 0.5 }
/// // -> { "ok": true, "tilesInRegion": 7, "tilesWithData": 5,
/// //      "totalFrames": 120, "integrationSeconds": 36000.0,
/// //      "meanCoverage": 11.3, "maxCoverage": 30.0,
/// //      "contributors": ["", "alice"], "lastFoldIso": "2026-06-19" }
/// ```
pub fn api_sky_atlas_region_info(args_json: String) -> Result<String, String> {
    let args: RegionInfoArgs =
        serde_json::from_str(&args_json).map_err(|e| format!("invalid regionInfo args: {e}"))?;
    let result = region_info_impl(args)?;
    serde_json::to_string(&result).map_err(|e| format!("failed to encode result: {e}"))
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct RegionInfoArgs {
    pub(crate) atlas_root: String,
    #[serde(default = "default_order")]
    pub(crate) order: u32,
    pub(crate) center_ra: f64,
    pub(crate) center_dec: f64,
    pub(crate) radius_deg: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct RegionInfoResult {
    pub(crate) ok: bool,
    pub(crate) tiles_in_region: usize,
    pub(crate) tiles_with_data: usize,
    pub(crate) total_frames: usize,
    pub(crate) integration_seconds: f64,
    pub(crate) mean_coverage: f64,
    pub(crate) max_coverage: f64,
    pub(crate) contributors: Vec<String>,
    pub(crate) last_fold_iso: Option<String>,
}

pub(crate) fn region_info_impl(args: RegionInfoArgs) -> Result<RegionInfoResult, String> {
    if args.radius_deg < 0.0 {
        return Err("regionInfo requires a non-negative radiusDeg".to_string());
    }
    let atlas = open_atlas(&args.atlas_root, args.order)?;
    let ids = skotiq_imaging::sky_atlas::tile_ids_for_cone(
        args.center_ra,
        args.center_dec,
        args.radius_deg,
        args.order,
    );
    let tiles_in_region = ids.len();
    let mut tiles_with_data = 0usize;
    let mut total_frames = 0usize;
    let mut integration_seconds = 0.0f64;
    let mut sum_cov = 0.0f64;
    let mut max_cov = 0.0f64;
    let mut contributors: Vec<String> = Vec::new();
    let mut last_fold: Option<String> = None;
    for tid in ids {
        let Some(tile) = atlas.load_tile(tid).map_err(|e| describe_atlas_error(&e))? else {
            continue;
        };
        let cov = tile.coverage_mean();
        if cov <= 0.0 && tile.provenance.total_frames == 0 {
            continue;
        }
        tiles_with_data += 1;
        total_frames += tile.provenance.total_frames;
        integration_seconds += tile.provenance.total_integration_seconds;
        sum_cov += cov;
        if cov > max_cov {
            max_cov = cov;
        }
        for c in &tile.provenance.contributors {
            if !contributors.iter().any(|e| e == c) {
                contributors.push(c.clone());
            }
        }
        if let Some(f) = tile.provenance.folds.last() {
            if looks_dated(&f.label) {
                last_fold = match last_fold {
                    Some(prev) if prev >= f.label => Some(prev),
                    _ => Some(f.label.clone()),
                };
            }
        }
    }
    let mean_coverage = if tiles_with_data > 0 {
        sum_cov / tiles_with_data as f64
    } else {
        0.0
    };
    Ok(RegionInfoResult {
        ok: true,
        tiles_in_region,
        tiles_with_data,
        total_frames,
        integration_seconds,
        mean_coverage,
        max_coverage: max_cov,
        contributors,
        last_fold_iso: last_fold,
    })
}

/// Report a deepening **growth curve** for a region: per-fold cumulative frame
/// count and integration time, oldest fold first, summed across the region's
/// tiles. This is the "your sky is getting deeper" timeline the dashboard plots.
///
/// ```jsonc
/// { "atlasRoot": "/…", "order": 9,
///   "centerRa": 83.6, "centerDec": -5.4, "radiusDeg": 0.5 }
/// // -> { "ok": true, "points": [
/// //        { "label": "2026-06-01", "framesAdded": 30, "secondsAdded": 9000.0,
/// //          "cumulativeFrames": 30, "cumulativeSeconds": 9000.0,
/// //          "contributor": "" }, … ],
/// //      "totalFrames": 120, "totalSeconds": 36000.0 }
/// ```
pub fn api_sky_atlas_growth(args_json: String) -> Result<String, String> {
    let args: GrowthArgs =
        serde_json::from_str(&args_json).map_err(|e| format!("invalid growth args: {e}"))?;
    let result = growth_impl(args)?;
    serde_json::to_string(&result).map_err(|e| format!("failed to encode result: {e}"))
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct GrowthArgs {
    pub(crate) atlas_root: String,
    #[serde(default = "default_order")]
    pub(crate) order: u32,
    pub(crate) center_ra: f64,
    pub(crate) center_dec: f64,
    pub(crate) radius_deg: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct GrowthPoint {
    /// Fold label (ISO date / session id).
    pub(crate) label: String,
    pub(crate) frames_added: usize,
    pub(crate) seconds_added: f64,
    pub(crate) cumulative_frames: usize,
    pub(crate) cumulative_seconds: f64,
    pub(crate) contributor: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct GrowthResult {
    pub(crate) ok: bool,
    pub(crate) points: Vec<GrowthPoint>,
    pub(crate) total_frames: usize,
    pub(crate) total_seconds: f64,
}

pub(crate) fn growth_impl(args: GrowthArgs) -> Result<GrowthResult, String> {
    if args.radius_deg < 0.0 {
        return Err("growth requires a non-negative radiusDeg".to_string());
    }
    let atlas = open_atlas(&args.atlas_root, args.order)?;
    let ids = skotiq_imaging::sky_atlas::tile_ids_for_cone(
        args.center_ra,
        args.center_dec,
        args.radius_deg,
        args.order,
    );

    // Gather every fold across the region's tiles, keyed by label so folds of the
    // same night (across many tiles) collapse into one growth point. A retraction
    // (negative weight_added, "retract:" label) subtracts from its night's tally.
    use std::collections::BTreeMap;
    #[derive(Default)]
    struct Bucket {
        frames: usize,
        seconds: f64,
        contributor: String,
    }
    // Preserve first-seen order while merging same-label folds: index map.
    let mut order_of: BTreeMap<String, usize> = BTreeMap::new();
    let mut buckets: Vec<(String, Bucket)> = Vec::new();

    for tid in ids {
        let Some(tile) = atlas.load_tile(tid).map_err(|e| describe_atlas_error(&e))? else {
            continue;
        };
        for fold in &tile.provenance.folds {
            // Retractions carry a "retract:" label prefix + a negative
            // weight_added; honour them by subtracting from the original night.
            let (key, sign) = if let Some(stripped) = fold.label.strip_prefix("retract:") {
                (stripped.to_string(), -1.0)
            } else {
                (fold.label.clone(), 1.0)
            };
            let idx = *order_of.entry(key.clone()).or_insert_with(|| {
                buckets.push((
                    key.clone(),
                    Bucket {
                        contributor: fold.contributor.clone(),
                        ..Bucket::default()
                    },
                ));
                buckets.len() - 1
            });
            let b = &mut buckets[idx].1;
            if sign > 0.0 {
                b.frames += fold.frames_added;
                b.seconds += fold.integration_seconds_added;
            } else {
                b.frames = b.frames.saturating_sub(fold.frames_added);
                b.seconds = (b.seconds - fold.integration_seconds_added.abs()).max(0.0);
            }
        }
    }

    // Sort growth points by label (ISO dates sort chronologically; non-dated
    // labels sort lexicographically after, which keeps the cumulative curve
    // monotonic for the common dated case).
    buckets.sort_by(|a, b| a.0.cmp(&b.0));

    let mut points = Vec::with_capacity(buckets.len());
    let mut cum_frames = 0usize;
    let mut cum_seconds = 0.0f64;
    for (label, b) in buckets {
        cum_frames += b.frames;
        cum_seconds += b.seconds;
        points.push(GrowthPoint {
            label,
            frames_added: b.frames,
            seconds_added: b.seconds,
            cumulative_frames: cum_frames,
            cumulative_seconds: cum_seconds,
            contributor: b.contributor,
        });
    }

    Ok(GrowthResult {
        ok: true,
        total_frames: cum_frames,
        total_seconds: cum_seconds,
        points,
    })
}

// Federation merge helper, exposed here so the atlas surface is self-contained
// for the hub/local merge the accumulator's additivity enables.

/// Merge a contributor delta accumulator into a base accumulator (or retract it),
/// the linear-additive federation operation the keystone proves exact:
///
/// ```jsonc
/// { "basePath": "/…/hub/tiles/9/42.nst", "deltaPath": "/…/delta_42.nst",
///   "trust": 0.85, "subtract": false, "outPath": "/…/hub/tiles/9/42.nst" }
/// // -> { "ok": true, "tileId": 42, "totalFramesAfter": 130,
/// //      "integrationSecondsAfter": 39000.0, "contributorsAfter": 7 }
/// ```
pub fn api_sky_atlas_merge_delta(args_json: String) -> Result<String, String> {
    let args: MergeDeltaArgs =
        serde_json::from_str(&args_json).map_err(|e| format!("invalid mergeDelta args: {e}"))?;
    let result = merge_delta_impl(args)?;
    serde_json::to_string(&result).map_err(|e| format!("failed to encode result: {e}"))
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct MergeDeltaArgs {
    pub(crate) base_path: String,
    pub(crate) delta_path: String,
    #[serde(default = "default_trust")]
    pub(crate) trust: f64,
    #[serde(default)]
    pub(crate) subtract: bool,
    pub(crate) out_path: String,
}

pub(crate) fn default_trust() -> f64 {
    1.0
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct MergeDeltaResult {
    pub(crate) ok: bool,
    pub(crate) tile_id: TileId,
    pub(crate) total_frames_after: usize,
    pub(crate) integration_seconds_after: f64,
    pub(crate) contributors_after: usize,
}

pub(crate) fn merge_delta_impl(args: MergeDeltaArgs) -> Result<MergeDeltaResult, String> {
    if args.base_path.trim().is_empty() || args.delta_path.trim().is_empty() {
        return Err("mergeDelta requires basePath and deltaPath".to_string());
    }
    if args.out_path.trim().is_empty() {
        return Err("mergeDelta requires outPath".to_string());
    }
    let trust = args.trust.clamp(0.0, 1.0);

    let delta_bytes =
        std::fs::read(&args.delta_path).map_err(|e| format!("failed to read delta: {e}"))?;
    let delta = SkyTileAccumulator::deserialize(&delta_bytes)
        .map_err(|e| format!("corrupt delta: {}", describe_atlas_error(&e)))?;

    // A base that does not exist yet starts from a fresh zeroed accumulator of the
    // delta's geometry, so the first contributor merge into a new hub tile works.
    let mut base = match std::fs::read(&args.base_path) {
        Ok(bytes) => SkyTileAccumulator::deserialize(&bytes)
            .map_err(|e| format!("corrupt base: {}", describe_atlas_error(&e)))?,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            SkyTileAccumulator::create(delta.tile_id, delta.order, delta.channels, delta.mode)
        }
        Err(e) => return Err(format!("failed to read base: {e}")),
    };

    if args.subtract {
        merge_tiles_subtract(&mut base, &delta, trust).map_err(|e| describe_atlas_error(&e))?;
    } else {
        merge_tiles(&mut base, &delta, trust).map_err(|e| describe_atlas_error(&e))?;
    }

    let out = Path::new(&args.out_path);
    ensure_parent_dir(out)?;
    std::fs::write(out, base.serialize())
        .map_err(|e| format!("failed to write merged base: {e}"))?;

    Ok(MergeDeltaResult {
        ok: true,
        tile_id: base.tile_id,
        total_frames_after: base.provenance.total_frames,
        integration_seconds_after: base.provenance.total_integration_seconds,
        contributors_after: base.provenance.contributors.len(),
    })
}
