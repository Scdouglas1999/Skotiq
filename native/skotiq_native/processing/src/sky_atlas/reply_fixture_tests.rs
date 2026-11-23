//! The sky-atlas replies, as samples the app's decoders are held to
//! (`test_fixtures/ffi_replies/sky_atlas_<action>.json`; see
//! [`crate::reply_fixtures`]). `finalize` and `addFrame` have no app caller
//! and no sample.

use super::fold::{FoldResult, FrameTileFold, TileFoldSummary};
use super::frames::QueryCutoutResult;
use super::regions::{GrowthPoint, GrowthResult, MergeDeltaResult, RegionInfoResult};
use super::tiles::{CoverageResult, ExportDeltaResult, InfoResult, TileCoverage, TilePngResult};
use crate::reply_fixtures::check_or_write;
use skotiq_imaging::sky_atlas::{TileFoldRecord, TileProvenance};

#[test]
fn sky_atlas_fold_reply_fixture() {
    check_or_write(
        "sky_atlas_fold",
        &FoldResult {
            ok: true,
            tiles_touched: vec![1_234_567, 1_234_568],
            folds_by_tile: vec![TileFoldSummary {
                tile_id: 1_234_567,
                frames_added: 3,
                weight_added: 2.75,
                integration_seconds_added: 540.0,
                coverage_added: 2.5,
                rejected: 17,
                coverage_mean: 11.25,
                center_ra: 10.6847,
                center_dec: 41.269,
                total_frames: 42,
                integration_seconds: 7560.0,
                channels: 3,
            }],
            frame_folds: vec![FrameTileFold {
                frame_index: 2,
                label: "2026-11-21".to_string(),
                tile_id: 1_234_567,
                weight_added: 0.875,
                integration_seconds_added: 180.0,
                coverage_added: 0.75,
                rejected: 5,
            }],
            frames_skipped_no_coverage: 1,
            layer: Some("Ha".to_string()),
        },
    );
}

#[test]
fn sky_atlas_tile_png_reply_fixture() {
    check_or_write(
        "sky_atlas_tile_png",
        &TilePngResult {
            ok: true,
            out_path: "/atlas/cache/tile_1234567.png".to_string(),
        },
    );
}

#[test]
fn sky_atlas_coverage_reply_fixture() {
    check_or_write(
        "sky_atlas_coverage",
        &CoverageResult {
            ok: true,
            tiles: vec![TileCoverage {
                tile_id: 1_234_567,
                center_ra: 10.6847,
                center_dec: 41.269,
                coverage_mean: 11.25,
                total_frames: 42,
                integration_seconds: 7560.0,
                last_fold_iso: Some("2026-11-21T04:30:00Z".to_string()),
                channels: 3,
            }],
        },
    );
}

#[test]
fn sky_atlas_info_reply_fixture() {
    check_or_write(
        "sky_atlas_info",
        &InfoResult {
            ok: true,
            provenance: TileProvenance {
                total_frames: 42,
                total_integration_seconds: 7560.0,
                contributors: vec!["rig-nyx".to_string(), "friend-1".to_string()],
                folds: vec![TileFoldRecord {
                    frames_added: 3,
                    weight_added: 2.75,
                    integration_seconds_added: 540.0,
                    rejected: 17,
                    label: "2026-11-21".to_string(),
                    contributor: "rig-nyx".to_string(),
                }],
            },
            center_ra: 10.6847,
            center_dec: 41.269,
            channels: 3,
            coverage_mean: 11.25,
        },
    );
}

#[test]
fn sky_atlas_export_delta_reply_fixture() {
    check_or_write(
        "sky_atlas_export_delta",
        &ExportDeltaResult {
            ok: true,
            out_path: "/atlas/cache/delta_1234567.skt".to_string(),
            frames_in_delta: 12,
            integration_seconds: 2160.0,
        },
    );
}

/// The compact reply is built in the dispatcher, so it is sampled from it, on
/// an atlas with no tiles yet.
#[test]
fn sky_atlas_compact_reply_fixture() {
    let root =
        std::env::temp_dir().join(format!("sk_atlas_compact_fixture_{}", std::process::id()));
    std::fs::create_dir_all(&root).expect("atlas root");
    let reply = super::sky_atlas(
        serde_json::json!({"action": "compact", "atlasRoot": root.to_string_lossy()}).to_string(),
    );
    std::fs::remove_dir_all(&root).ok();
    let reply: serde_json::Value = serde_json::from_str(&reply.expect("compact")).expect("JSON");
    check_or_write("sky_atlas_compact", &reply);
}

#[test]
fn sky_atlas_query_cutout_reply_fixture() {
    check_or_write(
        "sky_atlas_query_cutout",
        &QueryCutoutResult {
            ok: true,
            fits_path: "/atlas/cache/cutout.fits".to_string(),
            png_path: Some("/atlas/cache/cutout.png".to_string()),
            width: 2048,
            height: 1536,
            channels: 3,
            covered_fraction: 0.875,
            mean_coverage: 6.5,
            max_coverage: 14.0,
            tiles_used: 4,
        },
    );
}

#[test]
fn sky_atlas_region_info_reply_fixture() {
    check_or_write(
        "sky_atlas_region_info",
        &RegionInfoResult {
            ok: true,
            tiles_in_region: 9,
            tiles_with_data: 4,
            total_frames: 42,
            integration_seconds: 7560.0,
            mean_coverage: 6.5,
            max_coverage: 14.0,
            contributors: vec!["rig-nyx".to_string(), "friend-1".to_string()],
            last_fold_iso: Some("2026-11-21T04:30:00Z".to_string()),
        },
    );
}

#[test]
fn sky_atlas_growth_reply_fixture() {
    check_or_write(
        "sky_atlas_growth",
        &GrowthResult {
            ok: true,
            points: vec![GrowthPoint {
                label: "2026-11-21".to_string(),
                frames_added: 3,
                seconds_added: 540.0,
                cumulative_frames: 42,
                cumulative_seconds: 7560.0,
                contributor: "rig-nyx".to_string(),
            }],
            total_frames: 42,
            total_seconds: 7560.0,
        },
    );
}

#[test]
fn sky_atlas_merge_delta_reply_fixture() {
    check_or_write(
        "sky_atlas_merge_delta",
        &MergeDeltaResult {
            ok: true,
            tile_id: 1_234_567,
            total_frames_after: 54,
            integration_seconds_after: 9720.0,
            contributors_after: 3,
        },
    );
}
