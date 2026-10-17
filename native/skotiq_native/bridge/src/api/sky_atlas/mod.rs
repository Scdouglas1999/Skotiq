//! Sky-atlas (Pillar A — "Your Sky") FFI surface.
//!
//! This module exposes the HEALPix-tiled, out-of-core, **additive** all-sky
//! accumulator ([`skotiq_imaging::sky_atlas`]) to Dart through the same
//! **JSON-in / JSON-out** boundary the rest of the post-session / finishing
//! surface uses (see [`crate::api::post_session`] for the canonical template and
//! the rationale: regenerating `flutter_rust_bridge` bindings is heavyweight, so
//! every knob rides inside the JSON payload and never triggers another regen).
//!
//! The keystone is built; this is its bridge. Two entry shapes are exposed:
//!
//! * [`api_sky_atlas`] — the **dispatcher** matching `docs/skotiq_5_0_contracts.md`
//!   §2.1, switched on an `"action"` field (`fold` / `finalize` / `tilePng` /
//!   `coverage` / `exportDelta` / `info`). The Dart `SkyAtlasService` calls this.
//! * Four **named convenience wrappers** — [`api_sky_atlas_add_frame`],
//!   [`api_sky_atlas_query_cutout`], [`api_sky_atlas_region_info`],
//!   [`api_sky_atlas_growth`] — the higher-level operations a UI wants directly:
//!   fold one plate-solved capture, co-add a cone into a sharable cutout, summarise
//!   a region, and report a deepening growth curve.
//!
//! Every call is **stateless per call** (the atlas state lives entirely in the
//! on-disk tile sidecars under `<atlasRoot>/tiles/<order>/<tileId>.skt`); the
//! calls are CPU- / IO-bound and synchronous, run off the Dart UI isolate. Every
//! failure mode (bad action, unreadable frame, degenerate WCS, no coverage, write
//! failure) surfaces as `Err(String)` — never a silent partial fold.

use serde::{Deserialize, Serialize};
use skotiq_imaging::registration::Interpolator;
use skotiq_imaging::sky_atlas::{
    merge_tiles, merge_tiles_subtract, tile_center, AtlasError, SkyAtlas, SkyTileAccumulator,
    TileId, TileProvenance, ATLAS_HEALPIX_ORDER,
};
use skotiq_imaging::wcs_sip::SipWcs;
use skotiq_imaging::{
    add_wcs_headers, master_accumulation::AccumulationMode, master_accumulation::OnlineClip,
    read_image, write_fits, FitsHeader, ImageData, WcsInfo,
};
use std::path::Path;

use crate::api::post_session::write_preview_png;

mod fold;
pub(crate) use fold::*;
pub mod frames;
pub use frames::*;
pub mod regions;
pub use regions::*;
#[cfg(test)]
mod tests;
mod tiles;
pub(crate) use tiles::*;

/// Default resident-tile memory budget for a fold (512 MiB). A 1024² mono
/// accumulator is ~50 MB; the atlas processes tiles one at a time, so the budget
/// only bounds the (currently single) resident buffer — generous headroom for the
/// largest channel counts and a future batched variant.
const DEFAULT_MEMORY_BUDGET_BYTES: u64 = 512 * 1024 * 1024;

// Shared JSON helpers

/// Parse an interpolator token (`bilinear` | `catmullRom` | `lanczos3`), falling
/// back to Lanczos-3 (the atlas / mosaic default) when unset or empty.
fn parse_interp(s: &str) -> Result<Interpolator, String> {
    match s.trim().to_ascii_lowercase().as_str() {
        "" | "lanczos3" | "lanczos" => Ok(Interpolator::Lanczos3),
        "catmullrom" | "catmull-rom" | "catmull" => Ok(Interpolator::CatmullRom),
        "bilinear" | "linear" => Ok(Interpolator::Bilinear),
        other => Err(format!("unknown interpolator '{other}'")),
    }
}

/// Resolve the accumulation mode from optional online-clip thresholds. Both
/// present ⇒ a clipped running mean; either absent ⇒ a pure running weighted mean
/// (the federation-exact mode, matching the master's `online_clip` contract).
fn mode_from_clip(low: Option<f64>, high: Option<f64>) -> AccumulationMode {
    match (low, high) {
        (Some(low), Some(high)) => AccumulationMode::RunningWeightedMean {
            clip: Some(OnlineClip { low, high }),
        },
        _ => AccumulationMode::RunningWeightedMean { clip: None },
    }
}

/// Map a [`skotiq_imaging::sky_atlas::AtlasError`] to a human FFI string.
fn describe_atlas_error(e: &AtlasError) -> String {
    e.to_string()
}

/// Ensure the parent directory of `path` exists, creating it if necessary.
fn ensure_parent_dir(path: &Path) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent).map_err(|e| {
                format!(
                    "failed to create output directory '{}': {e}",
                    parent.display()
                )
            })?;
        }
    }
    Ok(())
}

/// A tile's local TAN grid is CD-only ([`SipWcs::tan_only`]); project it onto the
/// CD-matrix [`WcsInfo`] the FITS writer stamps so a finalized tile carries its
/// astrometry on disk.
fn wcs_info_from_tile(wcs: &SipWcs) -> WcsInfo {
    WcsInfo {
        crval1: wcs.crval1,
        crval2: wcs.crval2,
        crpix1: wcs.crpix1,
        crpix2: wcs.crpix2,
        cd1_1: wcs.cd1_1,
        cd1_2: wcs.cd1_2,
        cd2_1: wcs.cd2_1,
        cd2_2: wcs.cd2_2,
    }
}

/// Open the atlas rooted at `atlas_root` for `order` with the default memory
/// budget, rejecting an empty root loudly.
fn open_atlas(atlas_root: &str, order: u32) -> Result<SkyAtlas, String> {
    if atlas_root.trim().is_empty() {
        return Err("atlasRoot is required".to_string());
    }
    Ok(SkyAtlas::open(
        atlas_root,
        order,
        DEFAULT_MEMORY_BUDGET_BYTES,
    ))
}

/// Read a light frame and (best-effort) convert it to the linear `F32`/`U16`
/// layout the atlas resampler decodes. A frame the atlas cannot decode folds as
/// no contribution, so the only hard error here is an unreadable file.
fn read_frame(path: &str) -> Result<ImageData, String> {
    let read = read_image(Path::new(path)).map_err(|e| format!("failed to read '{path}': {e}"))?;
    Ok(read.image)
}

/// Enumerate every tile sidecar id present on disk for this atlas/order by
/// walking `<root>/tiles/<order>/`. Returns an ascending, deduplicated id list.
/// A missing directory (atlas never folded into) yields an empty list, not an
/// error — a brand-new atlas legitimately has no tiles yet.
fn list_tiles_on_disk(atlas: &SkyAtlas) -> Result<Vec<TileId>, String> {
    // `tile_path(0)` gives `<root>/tiles/<order>/0.skt`; its parent is the dir.
    let dir = match atlas.tile_path(0).parent() {
        Some(p) => p.to_path_buf(),
        None => return Ok(Vec::new()),
    };
    let entries = match std::fs::read_dir(&dir) {
        Ok(e) => e,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(format!("failed to scan tile directory: {e}")),
    };
    let mut ids: Vec<TileId> = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|e| format!("failed to read tile directory entry: {e}"))?;
        let path = entry.path();
        // Scan both the current and pre-rename sidecar extensions so an
        // atlas folded before the rename still reports its coverage.
        let ext = path.extension().and_then(|s| s.to_str());
        if ext != Some("skt") && ext != Some("nst") {
            continue;
        }
        if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
            if let Ok(id) = stem.parse::<TileId>() {
                ids.push(id);
            }
        }
    }
    ids.sort_unstable();
    ids.dedup();
    Ok(ids)
}

// api_sky_atlas — the dispatcher

#[derive(Debug, Clone, Deserialize)]
#[flutter_rust_bridge::frb(ignore)]
struct AtlasAction {
    action: String,
}

/// Sky-atlas dispatcher. `args_json` carries an `"action"` selecting the
/// operation; the remaining fields are the action-specific payload documented in
/// `docs/skotiq_5_0_contracts.md` §2.1. Returns the action's JSON result.
pub fn api_sky_atlas(args_json: String) -> Result<String, String> {
    let action: AtlasAction =
        serde_json::from_str(&args_json).map_err(|e| format!("invalid atlas args: {e}"))?;
    match action.action.as_str() {
        "fold" => {
            let args: FoldArgs =
                serde_json::from_str(&args_json).map_err(|e| format!("invalid fold args: {e}"))?;
            let result = fold_impl(args)?;
            serde_json::to_string(&result).map_err(|e| format!("failed to encode result: {e}"))
        }
        "finalize" => {
            let args: FinalizeArgs = serde_json::from_str(&args_json)
                .map_err(|e| format!("invalid finalize args: {e}"))?;
            let result = finalize_impl(args)?;
            serde_json::to_string(&result).map_err(|e| format!("failed to encode result: {e}"))
        }
        "tilePng" => {
            let args: TilePngArgs = serde_json::from_str(&args_json)
                .map_err(|e| format!("invalid tilePng args: {e}"))?;
            let result = tile_png_impl(args)?;
            serde_json::to_string(&result).map_err(|e| format!("failed to encode result: {e}"))
        }
        "coverage" => {
            let args: CoverageArgs = serde_json::from_str(&args_json)
                .map_err(|e| format!("invalid coverage args: {e}"))?;
            let result = coverage_impl(args)?;
            serde_json::to_string(&result).map_err(|e| format!("failed to encode result: {e}"))
        }
        "exportDelta" => {
            let args: ExportDeltaArgs = serde_json::from_str(&args_json)
                .map_err(|e| format!("invalid exportDelta args: {e}"))?;
            let result = export_delta_impl(args)?;
            serde_json::to_string(&result).map_err(|e| format!("failed to encode result: {e}"))
        }
        "info" => {
            let args: InfoArgs =
                serde_json::from_str(&args_json).map_err(|e| format!("invalid info args: {e}"))?;
            let result = info_impl(args)?;
            serde_json::to_string(&result).map_err(|e| format!("failed to encode result: {e}"))
        }
        other => Err(format!(
            "unknown atlas action '{other}'; expected fold/finalize/tilePng/coverage/exportDelta/info"
        )),
    }
}

// Tests
