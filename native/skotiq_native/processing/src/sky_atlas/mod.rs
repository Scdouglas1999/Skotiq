//! Sky-atlas (Pillar A — "Your Sky") pipeline.
//!
//! This module exposes the HEALPix-tiled, out-of-core, **additive** all-sky
//! accumulator ([`skotiq_imaging::sky_atlas`]) to Dart through the same
//! **JSON-in / JSON-out** boundary the rest of the post-session / finishing
//! surface uses (see [`crate::post_session`] for the canonical template and
//! the rationale: regenerating `flutter_rust_bridge` bindings is heavyweight, so
//! every knob rides inside the JSON payload and never triggers another regen).
//!
//! The keystone is built; this is its bridge. Two entry shapes are exposed:
//!
//! * [`sky_atlas`] — the **dispatcher** matching `docs/skotiq_5_0_contracts.md`
//!   §2.1, switched on an `"action"` field (`fold` / `finalize` / `tilePng` /
//!   `coverage` / `exportDelta` / `info`). The Dart `SkyAtlasService` calls this.
//! * Four **named convenience wrappers** — [`sky_atlas_add_frame`],
//!   [`sky_atlas_query_cutout`], [`sky_atlas_region_info`],
//!   [`sky_atlas_growth`] — the higher-level operations a UI wants directly:
//!   fold one plate-solved capture, co-add a cone into a sharable cutout, summarise
//!   a region, and report a deepening growth curve.
//!
//! Every call is **stateless per call** (the atlas state lives entirely in the
//! on-disk tile sidecars under `<atlasRoot>/tiles/<order>/<tileId>.skt`); the
//! calls are CPU- / IO-bound and synchronous, run off the Dart UI isolate. Every
//! failure mode (bad action, unreadable frame, degenerate WCS, no coverage, write
//! failure) surfaces as `Err(String)` — never a silent partial fold.

use crate::sky_atlas::fold::{default_order, finalize_impl, fold_impl, FinalizeArgs, FoldArgs};
use crate::sky_atlas::tiles::{
    coverage_impl, export_delta_impl, info_impl, tile_png_impl, CoverageArgs, ExportDeltaArgs,
    InfoArgs, TilePngArgs,
};
use serde::Deserialize;
use skotiq_imaging::master_accumulation::{AccumulationMode, OnlineClip};
use skotiq_imaging::registration::Interpolator;
use skotiq_imaging::sky_atlas::{AtlasError, SkyAtlas, TileId};
use skotiq_imaging::{read_image, ImageData};
use std::path::Path;

mod fold;
pub mod frames;
pub mod regions;
#[cfg(test)]
mod tests;
mod tiles;

/// Default resident-tile memory budget for a fold (512 MiB). A 1024² mono
/// accumulator is ~50 MB; the atlas processes tiles one at a time, so the budget
/// only bounds the (currently single) resident buffer — generous headroom for the
/// largest channel counts and a future batched variant.
pub(crate) const DEFAULT_MEMORY_BUDGET_BYTES: u64 = 512 * 1024 * 1024;

// Shared JSON helpers

/// Parse an interpolator token (`bilinear` | `catmullRom` | `lanczos3`), falling
/// back to Lanczos-3 (the atlas / mosaic default) when unset or empty.
pub(crate) fn parse_interp(s: &str) -> Result<Interpolator, String> {
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
pub(crate) fn describe_atlas_error(e: &AtlasError) -> String {
    e.to_string()
}

/// Open the atlas rooted at `atlas_root` for `order` with the default memory
/// budget, rejecting an empty root loudly.
pub(crate) fn open_atlas(atlas_root: &str, order: u32) -> Result<SkyAtlas, String> {
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
pub(crate) fn read_frame(path: &str) -> Result<ImageData, String> {
    let read = read_image(Path::new(path)).map_err(|e| format!("failed to read '{path}': {e}"))?;
    Ok(read.image)
}

/// Enumerate every tile sidecar id present on disk for this atlas/order (the
/// base layer and every filter layer). Returns an ascending, deduplicated id list.
/// A missing directory (atlas never folded into) yields an empty list, not an
/// error — a brand-new atlas legitimately has no tiles yet.
fn list_tiles_on_disk(atlas: &SkyAtlas) -> Result<Vec<TileId>, String> {
    atlas
        .tile_ids_on_disk()
        .map_err(|e| format!("failed to scan tile directory: {e}"))
}

// sky_atlas — the dispatcher

#[derive(Debug, Clone, Deserialize)]
struct AtlasAction {
    action: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CompactArgs {
    atlas_root: String,
    #[serde(default = "default_order")]
    order: u32,
}

/// The work behind the bridge's `api_sky_atlas`, which describes the request
/// and the reply.
pub fn sky_atlas(args_json: String) -> Result<String, String> {
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
        "compact" => {
            let args: CompactArgs = serde_json::from_str(&args_json)
                .map_err(|e| format!("invalid compact args: {e}"))?;
            let stats = open_atlas(&args.atlas_root, args.order)?
                .compact_sidecars()
                .map_err(|e| describe_atlas_error(&e))?;
            let mut value =
                serde_json::to_value(&stats).map_err(|e| format!("failed to encode result: {e}"))?;
            value["ok"] = serde_json::Value::Bool(true);
            serde_json::to_string(&value).map_err(|e| format!("failed to encode result: {e}"))
        }
        other => Err(format!(
            "unknown atlas action '{other}'; expected fold/finalize/tilePng/coverage/exportDelta/info/compact"
        )),
    }
}

// Tests
