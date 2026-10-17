use super::*;

// action "fold"

/// One plate-solved frame to fold: its path, integration weight, exposure, and
/// the full CD + SIP astrometry it was solved with.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct FoldFrameArgs {
    /// Light-frame path (FITS/XISF/etc.), already plate-solved.
    pub(crate) frame_path: String,
    /// Integration weight (≤ 0 ⇒ the frame folds as no contribution).
    #[serde(default = "default_weight")]
    pub(crate) weight: f64,
    /// Exposure seconds (for the integration-time provenance tally).
    #[serde(default)]
    pub(crate) exposure_sec: f64,
    /// The solved CD + SIP WCS for this frame.
    pub(crate) wcs: SipWcs,
}

pub(crate) fn default_weight() -> f64 {
    1.0
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct FoldArgs {
    pub(crate) atlas_root: String,
    #[serde(default = "default_order")]
    pub(crate) order: u32,
    /// Contributor id; `""` for local.
    #[serde(default)]
    pub(crate) contributor: String,
    /// `bilinear` | `catmullRom` | `lanczos3` (default lanczos3).
    #[serde(default)]
    pub(crate) interp: String,
    /// ISO date / session label for the fold log.
    #[serde(default)]
    pub(crate) label: String,
    /// Optional online-clip thresholds (σ). Both present ⇒ clipped running mean.
    #[serde(default)]
    pub(crate) online_clip_low: Option<f64>,
    #[serde(default)]
    pub(crate) online_clip_high: Option<f64>,
    /// The frames to fold.
    pub(crate) frames: Vec<FoldFrameArgs>,
}

pub(crate) fn default_order() -> u32 {
    ATLAS_HEALPIX_ORDER
}

/// Per-tile fold summary returned to Dart for the `sky_tiles` index update.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct TileFoldSummary {
    pub(crate) tile_id: TileId,
    pub(crate) frames_added: usize,
    pub(crate) weight_added: f64,
    pub(crate) rejected: u64,
    pub(crate) coverage_mean: f64,
    pub(crate) center_ra: f64,
    pub(crate) center_dec: f64,
    pub(crate) total_frames: usize,
    pub(crate) integration_seconds: f64,
    pub(crate) channels: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct FoldResult {
    pub(crate) ok: bool,
    /// Ascending, deduplicated ids of every tile this fold touched.
    pub(crate) tiles_touched: Vec<TileId>,
    /// Per-tile fold + post-fold-state summaries.
    pub(crate) folds_by_tile: Vec<TileFoldSummary>,
    /// Frames whose footprint covered no tiles (dropped, not fatal).
    pub(crate) frames_skipped_no_coverage: usize,
}

pub(crate) fn fold_impl(args: FoldArgs) -> Result<FoldResult, String> {
    if args.frames.is_empty() {
        return Err("fold requires at least one frame".to_string());
    }
    let atlas = open_atlas(&args.atlas_root, args.order)?;
    let interp = parse_interp(&args.interp)?;
    let mode = mode_from_clip(args.online_clip_low, args.online_clip_high);
    let label = if args.label.trim().is_empty() {
        "fold"
    } else {
        args.label.trim()
    };

    // Aggregate per-tile results across every frame in this call. A tile touched
    // by N frames reports the summed fold tallies and its final post-fold state.
    use std::collections::BTreeMap;
    let mut frames_added: BTreeMap<TileId, usize> = BTreeMap::new();
    let mut weight_added: BTreeMap<TileId, f64> = BTreeMap::new();
    let mut rejected: BTreeMap<TileId, u64> = BTreeMap::new();
    let mut frames_skipped = 0usize;

    for frame_args in &args.frames {
        if !frame_args.wcs.is_invertible() {
            return Err(format!(
                "frame '{}' has a degenerate (non-invertible) WCS",
                frame_args.frame_path
            ));
        }
        let frame = read_frame(&frame_args.frame_path)?;
        match atlas.fold_frame(
            &frame,
            &frame_args.wcs,
            frame_args.weight,
            frame_args.exposure_sec,
            interp,
            mode,
            label,
            &args.contributor,
        ) {
            Ok(records) => {
                for (tid, rec) in records {
                    *frames_added.entry(tid).or_default() += rec.frames_added;
                    *weight_added.entry(tid).or_default() += rec.weight_added;
                    *rejected.entry(tid).or_default() += rec.rejected;
                }
            }
            Err(AtlasError::NoCoverage) => {
                // A frame whose footprint is off-sky / empty is dropped, not
                // fatal: the rest of the call still folds.
                frames_skipped += 1;
            }
            Err(e) => return Err(describe_atlas_error(&e)),
        }
    }

    // Load each touched tile once more for its post-fold summary (coverage mean,
    // running totals, geometry) — the index the Dart side persists to `sky_tiles`.
    let mut folds_by_tile = Vec::with_capacity(frames_added.len());
    let mut tiles_touched: Vec<TileId> = frames_added.keys().copied().collect();
    tiles_touched.sort_unstable();
    for &tid in &tiles_touched {
        let (center_ra, center_dec) = tile_center(tid, args.order);
        let (coverage_mean, total_frames, integration_seconds, channels) =
            match atlas.load_tile(tid).map_err(|e| describe_atlas_error(&e))? {
                Some(tile) => (
                    tile.coverage_mean(),
                    tile.provenance.total_frames,
                    tile.provenance.total_integration_seconds,
                    tile.channels,
                ),
                None => (0.0, 0, 0.0, 0),
            };
        folds_by_tile.push(TileFoldSummary {
            tile_id: tid,
            frames_added: frames_added.get(&tid).copied().unwrap_or(0),
            weight_added: weight_added.get(&tid).copied().unwrap_or(0.0),
            rejected: rejected.get(&tid).copied().unwrap_or(0),
            coverage_mean,
            center_ra,
            center_dec,
            total_frames,
            integration_seconds,
            channels,
        });
    }

    Ok(FoldResult {
        ok: true,
        tiles_touched,
        folds_by_tile,
        frames_skipped_no_coverage: frames_skipped,
    })
}

// action "finalize"

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct FinalizeArgs {
    pub(crate) atlas_root: String,
    #[serde(default = "default_order")]
    pub(crate) order: u32,
    pub(crate) tile_id: TileId,
    /// Output FITS path for the finalized `F32` tile raster.
    pub(crate) out_path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct FinalizeResult {
    pub(crate) ok: bool,
    pub(crate) out_path: String,
    pub(crate) width: u32,
    pub(crate) height: u32,
    pub(crate) channels: u32,
}

pub(crate) fn finalize_impl(args: FinalizeArgs) -> Result<FinalizeResult, String> {
    if args.out_path.trim().is_empty() {
        return Err("finalize requires outPath".to_string());
    }
    let atlas = open_atlas(&args.atlas_root, args.order)?;
    let tile = atlas
        .load_tile(args.tile_id)
        .map_err(|e| describe_atlas_error(&e))?
        .ok_or_else(|| format!("tile {} has not been folded into yet", args.tile_id))?;
    let image = tile.finalize();
    let path = Path::new(&args.out_path);
    ensure_parent_dir(path)?;
    let mut header = FitsHeader::new();
    header.set_string("IMAGETYP", "MASTER_LIGHT");
    header.set_string("FRAMETYP", "MASTER");
    header.set_string("CALSTAT", "Skotiq sky-atlas tile");
    header.set_int("TILEID", args.tile_id as i64);
    header.set_int("HPXORDER", args.order as i64);
    header.set_int("NFRAMES", tile.provenance.total_frames as i64);
    header.set_float("EXPTIME", tile.provenance.total_integration_seconds);
    add_wcs_headers(&mut header, &wcs_info_from_tile(&tile.wcs));
    header.add_history(&format!(
        "Sky-atlas tile {} (order {}) finalized from {} frames across {} folds",
        args.tile_id,
        args.order,
        tile.provenance.total_frames,
        tile.provenance.folds.len()
    ));
    write_fits(path, &image, &header).map_err(|e| format!("failed to write tile FITS: {e:?}"))?;
    Ok(FinalizeResult {
        ok: true,
        out_path: args.out_path,
        width: image.width,
        height: image.height,
        channels: image.channels,
    })
}
