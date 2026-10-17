use super::*;

// action "tilePng"

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct TilePngArgs {
    pub(crate) atlas_root: String,
    #[serde(default = "default_order")]
    pub(crate) order: u32,
    pub(crate) tile_id: TileId,
    pub(crate) out_path: String,
    /// Optional time-scrub anchor (ISO). When present, only folds at/before this
    /// instant contribute: the tile is rebuilt from its provenance fold log by
    /// retracting later folds, so the PNG shows the sky "as of" that date.
    #[serde(default)]
    pub(crate) as_of_iso: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct TilePngResult {
    pub(crate) ok: bool,
    pub(crate) out_path: String,
}

pub(crate) fn tile_png_impl(args: TilePngArgs) -> Result<TilePngResult, String> {
    if args.out_path.trim().is_empty() {
        return Err("tilePng requires outPath".to_string());
    }
    let atlas = open_atlas(&args.atlas_root, args.order)?;
    let tile = atlas
        .load_tile(args.tile_id)
        .map_err(|e| describe_atlas_error(&e))?
        .ok_or_else(|| format!("tile {} has not been folded into yet", args.tile_id))?;

    // Time-scrub: the running sums are linear and the fold log records each fold's
    // (signed) contribution, but the per-pixel deltas are not stored per fold —
    // only the per-fold scalar tallies are. So an `asOfIso` request is honoured
    // honestly at the granularity the accumulator supports: if every fold is
    // at/before the anchor the full tile is rendered; if the anchor predates the
    // tile's first fold there is nothing to show. We never fabricate a partial
    // per-pixel reconstruction the stored state cannot back.
    if let Some(as_of) = args.as_of_iso.as_ref().filter(|s| !s.trim().is_empty()) {
        let any_after = tile
            .provenance
            .folds
            .iter()
            .any(|f| iso_is_after(&f.label, as_of));
        let all_after = !tile.provenance.folds.is_empty()
            && tile
                .provenance
                .folds
                .iter()
                .all(|f| iso_is_after(&f.label, as_of));
        if all_after {
            return Err(format!(
                "tile {} has no folds at or before {as_of}",
                args.tile_id
            ));
        }
        if any_after {
            // Some folds are later than the anchor but we cannot retract them at
            // pixel granularity from the stored scalar log — surface that rather
            // than render a misleading "as-of" image.
            return Err(format!(
                "tile {} cannot be scrubbed to {as_of}: per-fold pixel deltas are not retained \
                 (export per-night deltas to reconstruct an as-of view)",
                args.tile_id
            ));
        }
    }

    let image = tile.finalize();
    let path = Path::new(&args.out_path);
    ensure_parent_dir(path)?;
    write_preview_png(&image, path)?;
    Ok(TilePngResult {
        ok: true,
        out_path: args.out_path,
    })
}

/// Best-effort lexicographic ISO-8601 comparison: returns `true` if `label`
/// parses as an ISO timestamp strictly after `anchor`. ISO-8601 in canonical
/// (zero-padded, UTC `Z`) form sorts lexicographically by instant, which is how
/// the fold labels are written by the Dart session layer. A `label` that is not
/// a timestamp (a free-form session id) is treated as **not after** the anchor
/// (it contributes), so a non-dated fold is never silently dropped.
pub(crate) fn iso_is_after(label: &str, anchor: &str) -> bool {
    let l = label.trim();
    // Only compare when the label looks like an ISO date/time (starts YYYY-MM).
    let looks_iso =
        l.len() >= 7 && l.as_bytes()[4] == b'-' && l[..4].chars().all(|c| c.is_ascii_digit());
    looks_iso && l > anchor.trim()
}

// action "coverage"

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct CoverageArgs {
    pub(crate) atlas_root: String,
    #[serde(default = "default_order")]
    pub(crate) order: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct TileCoverage {
    pub(crate) tile_id: TileId,
    pub(crate) center_ra: f64,
    pub(crate) center_dec: f64,
    pub(crate) coverage_mean: f64,
    pub(crate) total_frames: usize,
    pub(crate) integration_seconds: f64,
    pub(crate) last_fold_iso: Option<String>,
    pub(crate) channels: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct CoverageResult {
    pub(crate) ok: bool,
    pub(crate) tiles: Vec<TileCoverage>,
}

pub(crate) fn coverage_impl(args: CoverageArgs) -> Result<CoverageResult, String> {
    let atlas = open_atlas(&args.atlas_root, args.order)?;
    let ids = list_tiles_on_disk(&atlas)?;
    let mut tiles = Vec::with_capacity(ids.len());
    for tid in ids {
        let Some(tile) = atlas.load_tile(tid).map_err(|e| describe_atlas_error(&e))? else {
            continue;
        };
        let (center_ra, center_dec) = tile_center(tid, args.order);
        tiles.push(TileCoverage {
            tile_id: tid,
            center_ra,
            center_dec,
            coverage_mean: tile.coverage_mean(),
            total_frames: tile.provenance.total_frames,
            integration_seconds: tile.provenance.total_integration_seconds,
            last_fold_iso: tile
                .provenance
                .folds
                .last()
                .map(|f| f.label.clone())
                .filter(|s| !s.trim().is_empty()),
            channels: tile.channels,
        });
    }
    Ok(CoverageResult { ok: true, tiles })
}

// action "exportDelta"

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct ExportDeltaArgs {
    pub(crate) atlas_root: String,
    #[serde(default = "default_order")]
    pub(crate) order: u32,
    pub(crate) tile_id: TileId,
    /// ISO anchor: only folds strictly after this instant are in the delta.
    pub(crate) since_iso: String,
    /// Output `.nst` path for the delta accumulator.
    pub(crate) out_path: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct ExportDeltaResult {
    pub(crate) ok: bool,
    pub(crate) out_path: String,
    pub(crate) frames_in_delta: usize,
    pub(crate) integration_seconds: f64,
}

pub(crate) fn export_delta_impl(args: ExportDeltaArgs) -> Result<ExportDeltaResult, String> {
    if args.out_path.trim().is_empty() {
        return Err("exportDelta requires outPath".to_string());
    }
    let atlas = open_atlas(&args.atlas_root, args.order)?;
    let tile = atlas
        .load_tile(args.tile_id)
        .map_err(|e| describe_atlas_error(&e))?
        .ok_or_else(|| format!("tile {} has not been folded into yet", args.tile_id))?;

    // The delta is the accumulator state attributable to LOCAL folds after
    // `sinceIso`. With the per-fold scalar log (not per-fold pixel deltas) a
    // pixel-exact post-anchor subset cannot be carved from a single merged state.
    // So we classify every fold into one of three buckets:
    //   * post-anchor LOCAL  (contributor == "", dated, strictly after sinceIso)
    //       — the new own-light the caller legitimately wants to ship;
    //   * foreign            (contributor != "")
    //       — pulled community photons that must NEVER re-upload as ours (the
    //         belt-and-suspenders that holds even if the overlay-tree split is
    //         bypassed);
    //   * pre-anchor LOCAL   (own folds older than / undatable relative to the
    //       anchor) — already shipped on a prior contribution.
    //
    // The exported `frames_in_delta` / `integration_seconds` are the post-anchor
    // LOCAL tally ONLY — this is the true delta the high-water flow pushes, never
    // the whole accumulator and never foreign depth. The serialized accumulator
    // bytes are still the whole tile state (the hub re-grades on the tally, and
    // merge_tiles is idempotent against an unchanged accumulator), but we fail
    // closed when pre-anchor LOCAL folds are present AND there is post-anchor
    // LOCAL depth to ship, because then the whole-tile bytes would over-share the
    // already-contributed own-light. The all-post-anchor "share my first/new
    // night" case (frames == post-anchor tally) exports cleanly.
    let mut post_anchor_local_frames = 0usize;
    let mut post_anchor_local_seconds = 0.0f64;
    let mut has_pre_anchor_local = false;
    for f in &tile.provenance.folds {
        if !f.contributor.is_empty() {
            // Foreign (pulled) fold — never counted toward our contribution.
            continue;
        }
        if looks_dated(&f.label) && iso_is_after(&f.label, &args.since_iso) {
            post_anchor_local_frames += f.frames_added;
            post_anchor_local_seconds += f.integration_seconds_added;
        } else {
            // Own fold that is not provably after the anchor: already shipped (or
            // an undatable label we cannot prove is new).
            has_pre_anchor_local = true;
        }
    }

    if has_pre_anchor_local && post_anchor_local_frames > 0 {
        return Err(format!(
            "tile {} mixes pre-anchor own folds with new own folds after {}: a pixel-exact \
             delta cannot be carved from the merged accumulator (export each night's delta at \
             fold time)",
            args.tile_id, args.since_iso
        ));
    }

    let frames_in_delta = post_anchor_local_frames;
    let integration_seconds = post_anchor_local_seconds;
    let path = Path::new(&args.out_path);
    ensure_parent_dir(path)?;
    std::fs::write(path, tile.serialize()).map_err(|e| format!("failed to write delta: {e}"))?;
    Ok(ExportDeltaResult {
        ok: true,
        out_path: args.out_path,
        frames_in_delta,
        integration_seconds,
    })
}

/// True if a fold label looks like an ISO date (so it participates in `sinceIso`
/// gating). Free-form labels are excluded from the gate (they neither block nor
/// qualify), mirroring [`iso_is_after`]'s treatment.
pub(crate) fn looks_dated(label: &str) -> bool {
    let l = label.trim();
    l.len() >= 7 && l.as_bytes().get(4) == Some(&b'-') && l[..4].chars().all(|c| c.is_ascii_digit())
}

// action "info"

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct InfoArgs {
    pub(crate) atlas_root: String,
    #[serde(default = "default_order")]
    pub(crate) order: u32,
    pub(crate) tile_id: TileId,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct InfoResult {
    pub(crate) ok: bool,
    pub(crate) provenance: TileProvenance,
    pub(crate) center_ra: f64,
    pub(crate) center_dec: f64,
    pub(crate) channels: u32,
    pub(crate) coverage_mean: f64,
}

pub(crate) fn info_impl(args: InfoArgs) -> Result<InfoResult, String> {
    let atlas = open_atlas(&args.atlas_root, args.order)?;
    let tile = atlas
        .load_tile(args.tile_id)
        .map_err(|e| describe_atlas_error(&e))?
        .ok_or_else(|| format!("tile {} has not been folded into yet", args.tile_id))?;
    let (center_ra, center_dec) = tile_center(args.tile_id, args.order);
    Ok(InfoResult {
        ok: true,
        provenance: tile.provenance.clone(),
        center_ra,
        center_dec,
        channels: tile.channels,
        coverage_mean: tile.coverage_mean(),
    })
}
