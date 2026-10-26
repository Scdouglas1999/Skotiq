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
    /// Fold-log label for this frame (its capture time); falls back to the
    /// call's `label`.
    #[serde(default)]
    pub(crate) label: Option<String>,
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
    /// Filter layer to fold into (the frames' filter); blank folds into the
    /// base layer.
    #[serde(default)]
    pub(crate) layer: Option<String>,
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

/// Per-tile post-fold state returned to Dart for the `sky_tiles` index update.
/// The totals describe the folded layer's tile.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct TileFoldSummary {
    pub(crate) tile_id: TileId,
    /// Frames this call counted in the tile.
    pub(crate) frames_added: usize,
    pub(crate) weight_added: f64,
    /// Exposure seconds this call added to the tile (sum of the counted frames'
    /// own exposures).
    pub(crate) integration_seconds_added: f64,
    /// Mean coverage depth this call added to the tile.
    pub(crate) coverage_added: f64,
    pub(crate) rejected: u64,
    pub(crate) coverage_mean: f64,
    pub(crate) center_ra: f64,
    pub(crate) center_dec: f64,
    pub(crate) total_frames: usize,
    pub(crate) integration_seconds: f64,
    pub(crate) channels: u32,
}

/// One frame's contribution to one tile, for the fold timeline.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct FrameTileFold {
    pub(crate) frame_index: usize,
    pub(crate) label: String,
    pub(crate) tile_id: TileId,
    pub(crate) weight_added: f64,
    pub(crate) integration_seconds_added: f64,
    pub(crate) coverage_added: f64,
    pub(crate) rejected: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct FoldResult {
    pub(crate) ok: bool,
    /// Ascending, deduplicated ids of every tile this fold counted a frame in.
    pub(crate) tiles_touched: Vec<TileId>,
    /// Per-tile fold + post-fold-state summaries.
    pub(crate) folds_by_tile: Vec<TileFoldSummary>,
    /// Per (frame, tile) contributions, frame-major.
    pub(crate) frame_folds: Vec<FrameTileFold>,
    /// Frames whose footprint covered no tile's cell (dropped, not fatal).
    pub(crate) frames_skipped_no_coverage: usize,
    /// The layer folded into (`null` = base layer).
    pub(crate) layer: Option<String>,
}

pub(crate) fn fold_impl(args: FoldArgs) -> Result<FoldResult, String> {
    if args.frames.is_empty() {
        return Err("fold requires at least one frame".to_string());
    }
    let atlas = open_atlas(&args.atlas_root, args.order)?.with_layer(args.layer.as_deref());
    let interp = parse_interp(&args.interp)?;
    let mode = mode_from_clip(args.online_clip_low, args.online_clip_high);
    let call_label = if args.label.trim().is_empty() {
        "fold"
    } else {
        args.label.trim()
    };

    let mut prepared = Vec::with_capacity(args.frames.len());
    for frame_args in &args.frames {
        if !frame_args.wcs.is_invertible() {
            return Err(format!(
                "frame '{}' has a degenerate (non-invertible) WCS",
                frame_args.frame_path
            ));
        }
        let frame = read_frame(&frame_args.frame_path)?;
        let label = frame_args
            .label
            .as_deref()
            .map(str::trim)
            .filter(|l| !l.is_empty())
            .unwrap_or(call_label);
        prepared.push(
            PreparedFrame::new(
                &frame,
                frame_args.wcs.clone(),
                frame_args.weight,
                frame_args.exposure_sec,
                label,
            )
            .map_err(|e| describe_atlas_error(&e))?,
        );
    }

    let batch = atlas
        .fold_prepared_frames(&prepared, interp, mode, &args.contributor)
        .map_err(|e| describe_atlas_error(&e))?;

    use std::collections::BTreeMap;
    #[derive(Default)]
    struct Added {
        frames: usize,
        weight: f64,
        seconds: f64,
        coverage: f64,
        rejected: u64,
    }
    let mut added: BTreeMap<TileId, Added> = BTreeMap::new();
    let mut frame_folds = Vec::with_capacity(batch.outcomes.len());
    for o in &batch.outcomes {
        let a = added.entry(o.tile_id).or_default();
        a.frames += o.record.frames_added;
        a.weight += o.record.weight_added;
        a.seconds += o.record.integration_seconds_added;
        a.coverage += o.coverage_added;
        a.rejected += o.record.rejected;
        frame_folds.push(FrameTileFold {
            frame_index: o.frame_index,
            label: o.record.label.clone(),
            tile_id: o.tile_id,
            weight_added: o.record.weight_added,
            integration_seconds_added: o.record.integration_seconds_added,
            coverage_added: o.coverage_added,
            rejected: o.record.rejected,
        });
    }

    let mut folds_by_tile = Vec::with_capacity(batch.tiles.len());
    for state in &batch.tiles {
        let (center_ra, center_dec) = tile_center(state.tile_id, args.order);
        let a = added.get(&state.tile_id);
        folds_by_tile.push(TileFoldSummary {
            tile_id: state.tile_id,
            frames_added: a.map(|a| a.frames).unwrap_or(0),
            weight_added: a.map(|a| a.weight).unwrap_or(0.0),
            integration_seconds_added: a.map(|a| a.seconds).unwrap_or(0.0),
            coverage_added: a.map(|a| a.coverage).unwrap_or(0.0),
            rejected: a.map(|a| a.rejected).unwrap_or(0),
            coverage_mean: state.coverage_mean,
            center_ra,
            center_dec,
            total_frames: state.total_frames,
            integration_seconds: state.total_integration_seconds,
            channels: state.channels,
        });
    }
    folds_by_tile.sort_by_key(|t| t.tile_id);
    let tiles_touched: Vec<TileId> = folds_by_tile.iter().map(|t| t.tile_id).collect();

    Ok(FoldResult {
        ok: true,
        tiles_touched,
        folds_by_tile,
        frame_folds,
        frames_skipped_no_coverage: batch.frames_without_coverage.len(),
        layer: atlas.layer().map(str::to_string),
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
