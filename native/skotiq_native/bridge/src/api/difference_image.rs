//! Difference imaging (Pillar B — "First Light") FFI surface.
//!
//! Exposes [`skotiq_imaging::difference_image::difference_against_template`] to
//! Dart through the same **JSON-in / JSON-out** boundary the sky-atlas surface uses
//! (see [`crate::api::sky_atlas`] for the canonical template and the rationale:
//! regenerating `flutter_rust_bridge` bindings is heavyweight, so every knob rides
//! inside the JSON payload).
//!
//! [`api_difference_image`] takes one fresh plate-solved frame + its CD + SIP WCS,
//! enumerates the atlas tiles its footprint covers, and for each tile whose deep
//! template is at least `minTemplateCoverage` frames deep, reprojects + photo-
//! metrically matches + subtracts the template and extracts residual sources. Each
//! candidate is tagged with its tile id, sky position, residual photometry, shape,
//! and shape/sign classification. The catalog / photometric / moving-object
//! cross-match that turns a residual into a *named* known object (or a flagged
//! unknown transient) happens Dart-side; this call deliberately stops at the
//! geometry + photometry, leaving `catalogMatch` null for the Dart layer to fill.

use serde::{Deserialize, Serialize};
use skotiq_imaging::difference_image::{
    difference_against_decoded, DecodedFrame, DifferenceOptions, DifferenceRejections,
    DifferenceResult, TransientCandidate,
};
use skotiq_imaging::registration::Interpolator;
use skotiq_imaging::sky_atlas::{
    tile_center, tile_ids_for_frame, AtlasError, SkyAtlas, TileId, ATLAS_HEALPIX_ORDER,
};
use skotiq_imaging::wcs_sip::SipWcs;
use skotiq_imaging::{read_image, ImageData, StarDetectionConfig};
use std::path::Path;

use crate::api::post_session::write_preview_png;

/// Default resident-tile memory budget (512 MiB) — matches the atlas surface.
const DEFAULT_MEMORY_BUDGET_BYTES: u64 = 512 * 1024 * 1024;

/// Tiles differenced concurrently for one frame.
const DIFFERENCE_WORKERS: usize = 4;

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

/// Map a [`skotiq_imaging::sky_atlas::AtlasError`] to a human FFI string.
fn describe_atlas_error(e: &AtlasError) -> String {
    e.to_string()
}

/// Open the atlas rooted at `atlas_root` for `order`, rejecting an empty root.
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

/// Read a light frame and convert it to the linear `F32`/`U16` layout the
/// differencing resampler decodes. The only hard error is an unreadable file.
fn read_frame(path: &str) -> Result<ImageData, String> {
    let read = read_image(Path::new(path)).map_err(|e| format!("failed to read '{path}': {e}"))?;
    Ok(read.image)
}

// api_difference_image

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct DifferenceArgs {
    atlas_root: String,
    #[serde(default = "default_order")]
    order: u32,
    /// The fresh, plate-solved light frame to difference against the atlas.
    frame_path: String,
    /// The frame's solved CD + SIP astrometry.
    wcs: SipWcs,
    /// `bilinear` | `catmullRom` | `lanczos3` (default lanczos3).
    #[serde(default)]
    interp: String,
    /// Compare only tile pixels whose template is at least this many frames
    /// deep.
    #[serde(default = "default_min_coverage")]
    min_template_coverage: u32,
    /// Filter layer of the template (the frame's filter). Templates of other
    /// filters are never used.
    #[serde(default)]
    layer: Option<String>,
    /// Minimum aperture significance of a reported source (default 7).
    #[serde(default)]
    min_significance: Option<f64>,
    /// Smallest reported brightening of a source already in the template, mag.
    #[serde(default)]
    min_brightening_mag: Option<f64>,
    /// Minimum distance (px) from the frame and compared-area edges.
    #[serde(default)]
    edge_margin_px: Option<f64>,
    /// Raw saturation level of the frame; default 95% of its maximum.
    #[serde(default)]
    saturation_level: Option<f64>,
    /// Optional directory; when set, a residual PNG is written per checked tile.
    #[serde(default)]
    residual_out_dir: Option<String>,
    /// Optional directory; when set, three **real-pixel** postage-stamp PNGs
    /// (template / science / residual) are written per surviving candidate,
    /// auto-stretched, named deterministically by tile id + sky position so the
    /// UI (and the `/api/firstlight/<id>/crops` host endpoint) can find them from
    /// the persisted detection row alone. Replaces the schematic cutout strip with
    /// the actual pixels around the detection.
    #[serde(default)]
    crop_out_dir: Option<String>,
    /// Half-width (px) of each square crop stamp on the tile grid (default 24 → a
    /// 49×49 stamp). Clamped to a sane range so a request can't allocate wildly.
    #[serde(default = "default_crop_half")]
    crop_half: u32,
    /// Optional star-detection overrides for the residual source extractor; the
    /// detector default is used for any field left out.
    #[serde(default)]
    detection_sigma: Option<f64>,
    #[serde(default)]
    min_snr: Option<f64>,
    #[serde(default)]
    min_area: Option<u32>,
    #[serde(default)]
    max_area: Option<u32>,
}

fn default_order() -> u32 {
    ATLAS_HEALPIX_ORDER
}

fn default_min_coverage() -> u32 {
    5
}

fn default_crop_half() -> u32 {
    24
}

/// Deterministic crop-stamp basename for a candidate, keyed by tile id + sky
/// position quantized to micro-degrees. The Dart host endpoint derives the exact
/// same key from the persisted detection row (`tileId`, `raDeg`, `decDeg`) so it
/// can serve the right stamp without storing a path in the DB. `stage` is
/// `template` | `science` | `residual`.
fn crop_basename(tile_id: TileId, ra: f64, dec: f64, stage: &str) -> String {
    // round-half-away-from-zero to micro-degree integers (stable across the wire).
    let ra_u = (ra * 1_000_000.0).round() as i64;
    let dec_u = (dec * 1_000_000.0).round() as i64;
    format!("crop_{tile_id}_{ra_u}_{dec_u}_{stage}.png")
}

/// Crop a square `2·half+1` stamp centred on `(cx, cy)` (tile-grid pixels) out of
/// an interleaved [`ImageData`], clamping the window to the image bounds (a
/// detection near a tile edge yields a smaller stamp rather than failing).
fn crop_stamp(img: &ImageData, cx: f64, cy: f64, half: i64) -> Option<ImageData> {
    let w = img.width as i64;
    let h = img.height as i64;
    let ch = img.channels as usize;
    if w <= 0 || h <= 0 || ch == 0 {
        return None;
    }
    let px = cx.round() as i64;
    let py = cy.round() as i64;
    let x0 = (px - half).clamp(0, w - 1);
    let x1 = (px + half).clamp(0, w - 1);
    let y0 = (py - half).clamp(0, h - 1);
    let y1 = (py + half).clamp(0, h - 1);
    let cw = (x1 - x0 + 1) as usize;
    let crh = (y1 - y0 + 1) as usize;
    if cw == 0 || crh == 0 {
        return None;
    }
    let src = img.as_f32()?;
    let stride = (w as usize) * ch;
    let mut out = vec![0.0f32; cw * crh * ch];
    for ry in 0..crh {
        let sy = (y0 as usize + ry) * stride;
        let dy = ry * cw * ch;
        for rx in 0..cw {
            let sx = (x0 as usize + rx) * ch;
            for c in 0..ch {
                out[dy + rx * ch + c] = src[sy + sx + c];
            }
        }
    }
    Some(ImageData::from_f32(
        cw as u32,
        crh as u32,
        img.channels,
        &out,
    ))
}

/// One residual candidate in the FFI result. `catalogMatch` is always `null` here;
/// the Dart layer fills it from its catalog / photometric / moving-object search.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct CandidateJson {
    ra: f64,
    dec: f64,
    tile_id: TileId,
    tile_x: f64,
    tile_y: f64,
    residual_flux: f64,
    /// `delta_mag` is `null` (rather than a JSON non-finite, which is invalid) when
    /// the template has no flux under a true new source.
    delta_mag: Option<f64>,
    snr: f64,
    fwhm: f64,
    eccentricity: f64,
    /// Major-axis position angle (deg, `[0, 180)`) measured from the second-moment
    /// covariance — a real measured shape attribute (a streak's trail direction),
    /// not a fabricated value.
    position_angle_deg: f64,
    kind: String,
    catalog_match: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct DifferenceResultJson {
    ok: bool,
    candidates: Vec<CandidateJson>,
    /// Tiles whose template was deep enough and were differenced.
    tiles_checked: Vec<TileId>,
    /// Tiles the frame covered but whose template was thinner than the gate.
    tiles_skipped_thin: Vec<TileId>,
    /// Tiles the frame footprint covered but which have not been folded into yet.
    tiles_no_template: Vec<TileId>,
    /// Deep-enough tiles skipped because too few template stars were available
    /// to scale the frame to the template.
    tiles_unnormalized: Vec<TileId>,
    /// Residual sources dropped, by reason, summed over the checked tiles.
    rejected: RejectionsJson,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct RejectionsJson {
    edge: usize,
    saturated: usize,
    sharp: usize,
    bright_star: usize,
    dipole: usize,
    elongated: usize,
    insignificant: usize,
    small_change: usize,
}

impl RejectionsJson {
    fn add(&mut self, r: &DifferenceRejections) {
        self.edge += r.edge;
        self.saturated += r.saturated;
        self.sharp += r.sharp;
        self.bright_star += r.bright_star;
        self.dipole += r.dipole;
        self.elongated += r.elongated;
        self.insignificant += r.insignificant;
        self.small_change += r.small_change;
    }
}

/// Difference one plate-solved frame against the atlas, returning residual
/// transient candidates per the contract JSON schema.
pub fn api_difference_image(args_json: String) -> Result<String, String> {
    let args: DifferenceArgs =
        serde_json::from_str(&args_json).map_err(|e| format!("invalid difference args: {e}"))?;
    let result = difference_impl(args)?;
    serde_json::to_string(&result).map_err(|e| format!("failed to encode result: {e}"))
}

fn difference_impl(args: DifferenceArgs) -> Result<DifferenceResultJson, String> {
    if !args.wcs.is_invertible() {
        return Err(format!(
            "frame '{}' has a degenerate (non-invertible) WCS",
            args.frame_path
        ));
    }
    let atlas = open_atlas(&args.atlas_root, args.order)?.with_layer(args.layer.as_deref());
    let interp = parse_interp(&args.interp)?;
    let frame = read_frame(&args.frame_path)?;
    let mut opts = DifferenceOptions {
        min_template_coverage: args.min_template_coverage,
        saturation_level: args.saturation_level,
        ..DifferenceOptions::default()
    };
    if let Some(v) = args.min_significance {
        opts.min_significance = v;
    }
    if let Some(v) = args.min_brightening_mag {
        opts.min_brightening_mag = v;
    }
    if let Some(v) = args.edge_margin_px {
        opts.edge_margin_px = v;
    }

    // The star-detection config for the residual extractor: detector defaults with
    // any explicit override applied.
    let mut star_cfg = StarDetectionConfig::default();
    if let Some(v) = args.detection_sigma {
        star_cfg.detection_sigma = v;
    }
    if let Some(v) = args.min_snr {
        star_cfg.min_snr = v;
    }
    if let Some(v) = args.min_area {
        star_cfg.min_area = v;
    }
    if let Some(v) = args.max_area {
        star_cfg.max_area = v;
    }

    // Every tile the frame footprint covers.
    let tiles = tile_ids_for_frame(&args.wcs, frame.width, frame.height, args.order);
    if tiles.is_empty() {
        return Err("frame footprint covers no tiles (off-sky / empty)".to_string());
    }

    // Prepare the residual output directory once if requested.
    if let Some(dir) = args
        .residual_out_dir
        .as_ref()
        .filter(|s| !s.trim().is_empty())
    {
        std::fs::create_dir_all(dir)
            .map_err(|e| format!("failed to create residual dir '{dir}': {e}"))?;
    }

    // Prepare the per-detection crop directory once if requested.
    let crop_dir = args
        .crop_out_dir
        .as_ref()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty());
    if let Some(dir) = crop_dir {
        std::fs::create_dir_all(dir)
            .map_err(|e| format!("failed to create crop dir '{dir}': {e}"))?;
    }
    let crop_half = (args.crop_half as i64).clamp(4, 128);

    let mut candidates: Vec<CandidateJson> = Vec::new();
    let mut tiles_checked: Vec<TileId> = Vec::new();
    let mut tiles_skipped_thin: Vec<TileId> = Vec::new();
    let mut tiles_no_template: Vec<TileId> = Vec::new();
    let mut tiles_unnormalized: Vec<TileId> = Vec::new();
    let mut rejected = RejectionsJson::default();

    // The frame is decoded once; tiles are differenced on a small pool (each
    // worker holds one ~42 MB template plus a few tile-sized planes).
    let decoded = DecodedFrame::new(&frame);
    enum TileOutcome {
        NoTemplate,
        Thin,
        Unnormalized(DifferenceRejections),
        Checked(Box<DifferenceResult>),
    }
    let run_tile = |tid: TileId| -> Result<TileOutcome, String> {
        let Some(template) = atlas.load_tile(tid).map_err(|e| describe_atlas_error(&e))? else {
            return Ok(TileOutcome::NoTemplate);
        };
        // A tile with no pixel as deep as the gate has nothing to compare.
        let deepest = template.state.coverage.iter().copied().max().unwrap_or(0);
        if deepest < args.min_template_coverage {
            return Ok(TileOutcome::Thin);
        }
        let result = match difference_against_decoded(
            &template, &decoded, &args.wcs, interp, &star_cfg, &opts,
        ) {
            Ok(r) => r,
            Err(AtlasError::DegenerateWcs) => return Err("frame WCS is degenerate".to_string()),
            Err(e) => return Err(describe_atlas_error(&e)),
        };
        if result.compared_pixels == 0 {
            return Ok(TileOutcome::Thin);
        }
        if result.normalization_stars < skotiq_imaging::difference_image::MIN_NORMALIZATION_STARS {
            return Ok(TileOutcome::Unnormalized(result.rejections));
        }
        Ok(TileOutcome::Checked(Box::new(result)))
    };
    let outcomes: Vec<(TileId, Result<TileOutcome, String>)> = {
        use rayon::prelude::*;
        match rayon::ThreadPoolBuilder::new()
            .num_threads(DIFFERENCE_WORKERS)
            .build()
        {
            Ok(pool) => pool.install(|| tiles.par_iter().map(|&t| (t, run_tile(t))).collect()),
            Err(_) => tiles.iter().map(|&t| (t, run_tile(t))).collect(),
        }
    };

    for (tid, outcome) in outcomes {
        let result = match outcome? {
            TileOutcome::NoTemplate => {
                tiles_no_template.push(tid);
                continue;
            }
            TileOutcome::Thin => {
                tiles_skipped_thin.push(tid);
                continue;
            }
            TileOutcome::Unnormalized(r) => {
                rejected.add(&r);
                tiles_unnormalized.push(tid);
                continue;
            }
            TileOutcome::Checked(r) => r,
        };
        rejected.add(&result.rejections);
        tiles_checked.push(tid);

        for c in &result.candidates {
            candidates.push(candidate_json(tid, c));
            if let Some(dir) = crop_dir {
                for (stage, plane) in [
                    ("template", &result.template_image),
                    ("science", &result.science),
                    ("residual", &result.residual),
                ] {
                    if let Some(stamp) = crop_stamp(plane, c.tile_x, c.tile_y, crop_half) {
                        let path = Path::new(dir).join(crop_basename(tid, c.ra, c.dec, stage));
                        // A crop write failure is non-fatal (the UI falls back to the
                        // schematic) but is logged with the path.
                        if let Err(e) = write_preview_png(&stamp, &path) {
                            tracing::warn!(
                                path = %path.display(),
                                error = %e,
                                "difference-image crop stamp not written"
                            );
                        }
                    }
                }
            }
        }

        if let Some(dir) = args
            .residual_out_dir
            .as_ref()
            .filter(|s| !s.trim().is_empty())
        {
            let path = Path::new(dir).join(format!("residual_{tid}.png"));
            write_preview_png(&result.residual, &path)?;
        }
    }

    // Tiles overlap by design (TILE_SCALE_MARGIN + neighbour-union cone cover), so
    // a residual near a tile boundary is detected once per covering tile with the
    // same (ra, dec). Deduplicate across tiles BEFORE sorting/returning so a single
    // nova / asteroid near a seam is not logged, counted, and announced multiple
    // times. Group by angular proximity, keeping the highest-SNR instance.
    let candidates = dedup_candidates(candidates);

    // Brightest (highest SNR) first across all tiles.
    let mut candidates = candidates;
    candidates.sort_by(|a, b| b.snr.total_cmp(&a.snr));

    Ok(DifferenceResultJson {
        ok: true,
        candidates,
        tiles_checked,
        tiles_skipped_thin,
        tiles_no_template,
        tiles_unnormalized,
        rejected,
    })
}

/// Cross-tile dedup radius (arcsec). A residual whose sky position lands inside
/// the tile-overlap/margin band is reported by every covering tile; two reports
/// within this angular distance are the same source. Tied to the Dart
/// cross-match's `_matchRadiusArcsec` (5.0") so dedup and naming agree.
const DEDUP_RADIUS_ARCSEC: f64 = 5.0;

/// Deduplicate candidates reported by more than one overlapping tile. Greedy:
/// the highest-SNR candidate is kept; any later candidate within
/// [`DEDUP_RADIUS_ARCSEC`] of an already-kept one is dropped. O(n²) in the
/// candidate count, which is small (residual sources per frame), so this is fine.
fn dedup_candidates(mut candidates: Vec<CandidateJson>) -> Vec<CandidateJson> {
    if candidates.len() < 2 {
        return candidates;
    }
    // Highest SNR first so the kept instance of each group is the strongest.
    candidates.sort_by(|a, b| b.snr.total_cmp(&a.snr));
    let mut kept: Vec<CandidateJson> = Vec::with_capacity(candidates.len());
    for c in candidates {
        let dup = kept
            .iter()
            .any(|k| angular_separation_arcsec(c.ra, c.dec, k.ra, k.dec) <= DEDUP_RADIUS_ARCSEC);
        if !dup {
            kept.push(c);
        }
    }
    kept
}

/// Great-circle separation (arcsec) between two sky positions (haversine — stable
/// at the small angles the dedup compares).
fn angular_separation_arcsec(ra1: f64, dec1: f64, ra2: f64, dec2: f64) -> f64 {
    let d_lat = (dec2 - dec1).to_radians();
    let d_lon = (ra2 - ra1).to_radians();
    let lat1 = dec1.to_radians();
    let lat2 = dec2.to_radians();
    let a = (d_lat * 0.5).sin().powi(2) + lat1.cos() * lat2.cos() * (d_lon * 0.5).sin().powi(2);
    let c = 2.0 * a.sqrt().clamp(-1.0, 1.0).asin();
    c.to_degrees() * 3600.0
}

/// Convert a native [`TransientCandidate`] to its JSON shape, sanitising the
/// non-finite `delta_mag` of a true new source into a JSON-valid `null`.
fn candidate_json(tile_id: TileId, c: &TransientCandidate) -> CandidateJson {
    let delta_mag = if c.delta_mag.is_finite() {
        Some(c.delta_mag)
    } else {
        None
    };
    CandidateJson {
        ra: c.ra,
        dec: c.dec,
        tile_id,
        tile_x: c.tile_x,
        tile_y: c.tile_y,
        residual_flux: c.residual_flux,
        delta_mag,
        snr: c.snr,
        fwhm: c.fwhm,
        eccentricity: c.eccentricity,
        position_angle_deg: c.position_angle_deg,
        kind: c.kind.as_wire().to_string(),
        catalog_match: None,
    }
}

/// Tile-centre helper: resolve a HEALPix tile id to its sky position, so the Dart
/// side can annotate a skipped/no-template tile without re-deriving the addressing.
/// JSON in (`{ "tileId": 42, "order": 9 }`) / JSON out (`{ "tileId", "ra", "dec" }`),
/// matching the rest of this surface's JSON boundary (FRB cannot wire a bare
/// `TileId` type-alias parameter, so the id rides inside the payload).
pub fn api_difference_tile_center(args_json: String) -> Result<String, String> {
    let args: TileCenterArgs =
        serde_json::from_str(&args_json).map_err(|e| format!("invalid tileCenter args: {e}"))?;
    let (ra, dec) = tile_center(args.tile_id, args.order);
    serde_json::to_string(&serde_json::json!({ "tileId": args.tile_id, "ra": ra, "dec": dec }))
        .map_err(|e| format!("failed to encode result: {e}"))
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct TileCenterArgs {
    tile_id: TileId,
    #[serde(default = "default_order")]
    order: u32,
}

#[cfg(test)]
mod tests {
    use super::*;
    use skotiq_imaging::master_accumulation::AccumulationMode;
    use skotiq_imaging::sky_atlas::{radec_to_tile, tile_wcs, SkyTileAccumulator, TILE_PIXELS};
    use skotiq_imaging::{write_fits, FitsHeader};
    use std::path::Path;
    use std::sync::atomic::{AtomicU64, Ordering};

    static COUNTER: AtomicU64 = AtomicU64::new(0);

    /// A scratch directory that deletes itself when the test ends.
    /// `Drop` rather than a cleanup call at the end of each test: the leak was
    /// worst exactly when a test FAILED, and drop still runs while a panic
    /// unwinds.
    struct TempDir(std::path::PathBuf);

    impl std::ops::Deref for TempDir {
        type Target = Path;
        fn deref(&self) -> &Path {
            &self.0
        }
    }

    // Deref alone does not satisfy a generic `AsRef<Path>` bound, which several
    // call sites here rely on.
    impl AsRef<Path> for TempDir {
        fn as_ref(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            // Best-effort: a test asserting on a half-removed tree should fail
            // on its own assertion, not on cleanup.
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn temp_dir(tag: &str) -> TempDir {
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);
        let p =
            std::env::temp_dir().join(format!("sk_diff_ffi_{}_{}_{}", tag, std::process::id(), n));
        std::fs::create_dir_all(&p).unwrap();
        TempDir(p)
    }

    fn render_star(buf: &mut [f32], w: usize, cx: f64, cy: f64, flux: f64) {
        let sigma = 1.6;
        let norm = flux / (2.0 * std::f64::consts::PI * sigma * sigma);
        let r = (4.0 * sigma).ceil() as i64;
        for dy in -r..=r {
            for dx in -r..=r {
                let x = cx.round() as i64 + dx;
                let y = cy.round() as i64 + dy;
                if x < 0 || y < 0 || x >= w as i64 || y >= w as i64 {
                    continue;
                }
                let ddx = x as f64 - cx;
                let ddy = y as f64 - cy;
                let g = norm * (-(ddx * ddx + ddy * ddy) / (2.0 * sigma * sigma)).exp();
                buf[y as usize * w + x as usize] += g as f32;
            }
        }
    }

    /// A star field like a real sub: 30 stars on a sky pedestal with
    /// deterministic Gaussian noise, plus `extra` stars.
    fn field(w: usize, extra: &[(f64, f64, f64)], seed: u64) -> Vec<f32> {
        let mut state = seed
            .wrapping_mul(2862933555777941757)
            .wrapping_add(3037000493);
        let mut uniform = move || {
            state = state
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            ((state >> 11) as f64 + 0.5) / (1u64 << 53) as f64
        };
        let mut buf = vec![0.0f32; w * w];
        for v in buf.iter_mut() {
            let (u1, u2) = (uniform(), uniform());
            let n = (-2.0 * u1.ln()).sqrt() * (2.0 * std::f64::consts::PI * u2).cos();
            *v = (100.0 + 3.0 * n) as f32;
        }
        for i in 0..30 {
            let x = 200.0 + (i % 6) as f64 * 120.0 + 7.0 * (i as f64).sin();
            let y = 150.0 + (i / 6) as f64 * 150.0 + 5.0 * (i as f64).cos();
            render_star(&mut buf, w, x, y, 2000.0 + 600.0 * i as f64);
        }
        for &(x, y, f) in extra {
            render_star(&mut buf, w, x, y, f);
        }
        buf
    }

    #[test]
    fn difference_detects_injected_source_via_ffi() {
        let dir = temp_dir("detect");
        let order = ATLAS_HEALPIX_ORDER;
        let tid = radec_to_tile(120.0, 25.0, order);
        let w = TILE_PIXELS as usize;
        let wcs = tile_wcs(tid, order);

        // Build a template tile on disk: 6 folds of a 30-star field.
        let mut acc = SkyTileAccumulator::create(
            tid,
            order,
            1,
            AccumulationMode::RunningWeightedMean { clip: None },
        );
        for i in 0..6 {
            let tmpl_img = ImageData::from_f32(w as u32, w as u32, 1, &field(w, &[], i));
            acc.fold_frame(
                &tmpl_img,
                &wcs,
                1.0,
                300.0,
                Interpolator::Bilinear,
                &format!("2026-06-0{}", i + 1),
                "",
            )
            .unwrap();
        }
        let atlas = SkyAtlas::open(&dir, order, DEFAULT_MEMORY_BUDGET_BYTES);
        atlas.store_tile(&acc).unwrap();

        // Tonight's frame: the same field plus a new source, written to FITS.
        let frame = field(w, &[(512.0, 600.0, 7000.0)], 99);
        let frame_img = ImageData::from_f32(w as u32, w as u32, 1, &frame);
        let frame_path = dir.join("light.fits");
        let mut header = FitsHeader::new();
        header.set_string("IMAGETYP", "LIGHT");
        write_fits(&frame_path, &frame_img, &header).unwrap();

        let args = serde_json::json!({
            "atlasRoot": dir.to_string_lossy(),
            "order": order,
            "framePath": frame_path.to_string_lossy(),
            "wcs": serde_json::to_value(&wcs).unwrap(),
            "interp": "bilinear",
            "minTemplateCoverage": 3,
            "minSnr": 4.0,
            "minArea": 3
        });
        let out = api_difference_image(args.to_string()).expect("difference ok");
        let parsed: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(parsed["ok"], true);
        let cands = parsed["candidates"].as_array().unwrap();
        // The injected new source near (512, 600) must appear.
        let found = cands.iter().any(|c| {
            (c["tileX"].as_f64().unwrap() - 512.0).abs() < 3.0
                && (c["tileY"].as_f64().unwrap() - 600.0).abs() < 3.0
        });
        assert!(found, "injected source not found in {cands:?}");
        // The checked tile is the template tile; delta_mag for a new source is null.
        assert!(parsed["tilesChecked"]
            .as_array()
            .unwrap()
            .iter()
            .any(|t| t.as_u64() == Some(tid)));
        let new_src = cands
            .iter()
            .find(|c| {
                (c["tileX"].as_f64().unwrap() - 512.0).abs() < 3.0
                    && (c["tileY"].as_f64().unwrap() - 600.0).abs() < 3.0
            })
            .unwrap();
        assert_eq!(new_src["kind"], "newSource");
        assert!(new_src["deltaMag"].is_null());
        assert!(new_src["catalogMatch"].is_null());
    }

    #[test]
    fn crop_out_dir_writes_real_pixel_stamps_per_detection() {
        let dir = temp_dir("crops");
        let order = ATLAS_HEALPIX_ORDER;
        let tid = radec_to_tile(120.0, 25.0, order);
        let w = TILE_PIXELS as usize;
        let wcs = tile_wcs(tid, order);

        // Template: 6 folds of a 30-star field.
        let mut acc = SkyTileAccumulator::create(
            tid,
            order,
            1,
            AccumulationMode::RunningWeightedMean { clip: None },
        );
        for i in 0..6 {
            let tmpl_img = ImageData::from_f32(w as u32, w as u32, 1, &field(w, &[], i));
            acc.fold_frame(
                &tmpl_img,
                &wcs,
                1.0,
                300.0,
                Interpolator::Bilinear,
                &format!("2026-06-0{}", i + 1),
                "",
            )
            .unwrap();
        }
        let atlas = SkyAtlas::open(&dir, order, DEFAULT_MEMORY_BUDGET_BYTES);
        atlas.store_tile(&acc).unwrap();

        // Tonight: the same field + a new source.
        let frame = field(w, &[(512.0, 600.0, 7000.0)], 99);
        let frame_img = ImageData::from_f32(w as u32, w as u32, 1, &frame);
        let frame_path = dir.join("light.fits");
        let mut header = FitsHeader::new();
        header.set_string("IMAGETYP", "LIGHT");
        write_fits(&frame_path, &frame_img, &header).unwrap();

        let crop_dir = dir.join("stamps");
        let args = serde_json::json!({
            "atlasRoot": dir.to_string_lossy(),
            "order": order,
            "framePath": frame_path.to_string_lossy(),
            "wcs": serde_json::to_value(&wcs).unwrap(),
            "interp": "bilinear",
            "minTemplateCoverage": 3,
            "minSnr": 4.0,
            "minArea": 3,
            "cropOutDir": crop_dir.to_string_lossy(),
            "cropHalf": 20
        });
        let out = api_difference_image(args.to_string()).expect("difference ok");
        let parsed: serde_json::Value = serde_json::from_str(&out).unwrap();
        let cands = parsed["candidates"].as_array().unwrap();
        let c = cands
            .iter()
            .find(|c| {
                (c["tileX"].as_f64().unwrap() - 512.0).abs() < 3.0
                    && (c["tileY"].as_f64().unwrap() - 600.0).abs() < 3.0
            })
            .expect("new source detected");
        // The three deterministic stamps for the detection's tile + position exist.
        let ra = c["ra"].as_f64().unwrap();
        let dec = c["dec"].as_f64().unwrap();
        for stage in ["template", "science", "residual"] {
            let p = crop_dir.join(crop_basename(tid, ra, dec, stage));
            assert!(p.exists(), "missing {stage} stamp at {p:?}");
            let bytes = std::fs::read(&p).unwrap();
            assert!(bytes.len() > 8, "{stage} stamp is empty");
            // PNG magic.
            assert_eq!(&bytes[1..4], b"PNG", "{stage} stamp is not a PNG");
        }
    }

    #[test]
    fn thin_template_is_skipped() {
        let dir = temp_dir("thin");
        let order = ATLAS_HEALPIX_ORDER;
        let tid = radec_to_tile(40.0, -10.0, order);
        let w = TILE_PIXELS as usize;
        let wcs = tile_wcs(tid, order);

        // A template only 1 fold deep.
        let frame_buf = vec![100.0f32; w * w];
        let img = ImageData::from_f32(w as u32, w as u32, 1, &frame_buf);
        let mut acc = SkyTileAccumulator::create(
            tid,
            order,
            1,
            AccumulationMode::RunningWeightedMean { clip: None },
        );
        acc.fold_frame(
            &img,
            &wcs,
            1.0,
            300.0,
            Interpolator::Bilinear,
            "2026-06-01",
            "",
        )
        .unwrap();
        let atlas = SkyAtlas::open(&dir, order, DEFAULT_MEMORY_BUDGET_BYTES);
        atlas.store_tile(&acc).unwrap();

        let frame_path = dir.join("light.fits");
        let mut header = FitsHeader::new();
        header.set_string("IMAGETYP", "LIGHT");
        write_fits(&frame_path, &img, &header).unwrap();

        let args = serde_json::json!({
            "atlasRoot": dir.to_string_lossy(),
            "order": order,
            "framePath": frame_path.to_string_lossy(),
            "wcs": serde_json::to_value(&wcs).unwrap(),
            "minTemplateCoverage": 5
        });
        let out = api_difference_image(args.to_string()).expect("difference ok");
        let parsed: serde_json::Value = serde_json::from_str(&out).unwrap();
        // The 1-deep template tile is gated out.
        assert!(parsed["tilesSkippedThin"]
            .as_array()
            .unwrap()
            .iter()
            .any(|t| t.as_u64() == Some(tid)));
        assert!(parsed["candidates"].as_array().unwrap().is_empty());
    }

    #[test]
    fn degenerate_wcs_is_rejected_via_ffi() {
        let dir = temp_dir("degen");
        let bad = SipWcs::tan_only(10.0, 20.0, 1.0, 1.0, 0.0, 0.0, 0.0, 0.0);
        let args = serde_json::json!({
            "atlasRoot": dir.to_string_lossy(),
            "framePath": "/nonexistent.fits",
            "wcs": serde_json::to_value(&bad).unwrap()
        });
        let err = api_difference_image(args.to_string()).unwrap_err();
        assert!(err.contains("degenerate"), "unexpected error: {err}");
    }

    fn mk_candidate(ra: f64, dec: f64, snr: f64, tile_id: TileId) -> CandidateJson {
        CandidateJson {
            ra,
            dec,
            tile_id,
            tile_x: 0.0,
            tile_y: 0.0,
            residual_flux: 1.0,
            delta_mag: None,
            snr,
            fwhm: 2.0,
            eccentricity: 0.1,
            position_angle_deg: 0.0,
            kind: "newSource".to_string(),
            catalog_match: None,
        }
    }

    #[test]
    fn dedup_collapses_cross_tile_duplicates_keeping_highest_snr() {
        // The same source reported by two overlapping tiles (same ra/dec, different
        // tile_id + SNR) must collapse to one, keeping the strongest report.
        let cands = vec![
            mk_candidate(120.0001, 25.0001, 8.0, 1),
            mk_candidate(120.00012, 25.00009, 12.0, 2), // ~same position, higher SNR
            mk_candidate(121.0, 26.0, 9.0, 3),          // a genuinely different source
        ];
        let out = dedup_candidates(cands);
        assert_eq!(out.len(), 2, "the boundary duplicate must collapse");
        // The kept instance of the duplicate group is the higher-SNR one.
        let near = out
            .iter()
            .find(|c| (c.ra - 120.0).abs() < 0.01)
            .expect("the merged source survives");
        assert_eq!(near.snr, 12.0);
        assert_eq!(near.tile_id, 2);
    }

    #[test]
    fn dedup_keeps_distinct_sources() {
        let cands = vec![
            mk_candidate(10.0, 10.0, 7.0, 1),
            mk_candidate(10.1, 10.1, 7.0, 1), // ~500" away — distinct
        ];
        assert_eq!(dedup_candidates(cands).len(), 2);
    }

    #[test]
    fn tile_center_round_trips() {
        let order = ATLAS_HEALPIX_ORDER;
        let tid = radec_to_tile(120.0, 25.0, order);
        let args = serde_json::json!({ "tileId": tid, "order": order });
        let out = api_difference_tile_center(args.to_string()).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(parsed["tileId"].as_u64(), Some(tid));
        assert!(parsed["ra"].as_f64().unwrap() >= 0.0);
    }
}
