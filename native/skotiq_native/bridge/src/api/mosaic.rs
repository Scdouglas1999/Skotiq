//! Mosaic-stitching FFI surface — project N plate-solved panel masters onto a
//! shared tangent-plane canvas and blend them into one mosaic master.
//!
//! This module exposes the native panel-mosaic stitcher
//! ([`skotiq_imaging::mosaic_stitch`]) to Dart through the same
//! **JSON-in / JSON-out** boundary the rest of the post-session / finishing
//! surface uses (see [`crate::api::post_session`] for the canonical template and
//! the rationale). Every knob — resampler, normalization toggle, blend mode,
//! feather width, output pixel scale, output/coverage/preview paths — rides
//! inside the JSON payload, so adding one never triggers a
//! `flutter_rust_bridge` regen. The boundary is exactly one
//! `String -> Result<String, String>` function:
//!
//! * [`api_stitch_mosaic`] — read each panel FITS (image + WCS from its CD-matrix
//!   header), stitch onto a common gnomonic canvas, write the `F32` master, an
//!   optional `F32` coverage plane, and an optional stretched preview PNG.
//!
//! The stitch is **stateless per call** (no process-wide singleton) and
//! CPU-bound; the Dart side runs it off the UI isolate. As everywhere in this
//! surface, every failure mode (no panels, unreadable FITS, missing WCS, a
//! degenerate solve, a canvas blow-up, a write failure) surfaces as
//! `Err(String)` — never a silent partial mosaic.

use skotiq_imaging::mosaic_stitch::{
    stitch_mosaic, MosaicBlend, MosaicError, MosaicPanel, MosaicStitchConfig,
};
use skotiq_imaging::registration::Interpolator;
use skotiq_imaging::{add_wcs_headers, read_fits, write_fits, FitsHeader, WcsInfo};
use serde::{Deserialize, Serialize};
use std::path::Path;

// JSON contracts

/// One panel feeding the mosaic.
///
/// `fits_path` is the integrated, plate-solved panel master. The panel WCS is
/// normally **read from that FITS header** (`CRVAL1/2`, `CRPIX1/2`,
/// `CD1_1..CD2_2`, or a `CDELT`/`CROTA` fallback). The optional `wcs` block lets
/// the caller pass the solved CD matrix explicitly (e.g. from the
/// `integrated_masters` v44 WCS columns) when it is more authoritative than the
/// on-disk header; when present it overrides the header WCS entirely.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct PanelArgs {
    /// FITS path of the integrated panel master.
    fits_path: String,
    /// Optional explicit CD-matrix WCS; overrides the header WCS when present.
    wcs: Option<WcsArgs>,
}

/// An explicit CD-matrix WCS (mirrors [`WcsInfo`]). Degrees / pixels, FITS
/// 1-based `CRPIX`. Field names are the literal FITS WCS keywords
/// (`crval1`, `crpix1`, `cd1_1`, …) — no camelCase rename, so the JSON keys
/// match the CD-matrix columns the caller already carries.
#[derive(Debug, Clone, Copy, Deserialize)]
#[flutter_rust_bridge::frb(ignore)]
struct WcsArgs {
    crval1: f64,
    crval2: f64,
    crpix1: f64,
    crpix2: f64,
    cd1_1: f64,
    cd1_2: f64,
    cd2_1: f64,
    cd2_2: f64,
}

impl From<WcsArgs> for WcsInfo {
    fn from(w: WcsArgs) -> Self {
        WcsInfo {
            crval1: w.crval1,
            crval2: w.crval2,
            crpix1: w.crpix1,
            crpix2: w.crpix2,
            cd1_1: w.cd1_1,
            cd1_2: w.cd1_2,
            cd2_1: w.cd2_1,
            cd2_2: w.cd2_2,
        }
    }
}

/// Stitch tunables. Each unset field falls back to the
/// [`MosaicStitchConfig::default`] (Lanczos-3, normalize on, feather blend,
/// 64 px feather, median panel scale).
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct StitchConfigArgs {
    /// `"lanczos3"` (default) | `"catmullrom"` | `"bilinear"`.
    resampler: Option<String>,
    /// Cross-panel photometric matching. Default `true`.
    normalize: Option<bool>,
    /// `"feather"` (default) | `"none"`.
    blend: Option<String>,
    /// Feather ramp width in output pixels. Default `64`.
    feather_px: Option<f64>,
    /// Output pixel scale (arcsec/px). Unset / `<= 0` ⇒ median panel scale.
    output_pixel_scale_arcsec: Option<f64>,
}

/// Output target paths.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct OutputArgs {
    /// Output FITS path for the linear `F32` mosaic master (required).
    mosaic_fits_path: String,
    /// Optional output FITS path for the `F32` per-pixel coverage plane.
    coverage_fits_path: Option<String>,
    /// Optional stretched preview PNG path for the mosaic master.
    preview_png_path: Option<String>,
}

/// Top-level request for [`api_stitch_mosaic`].
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct StitchMosaicArgs {
    /// The panel masters to stitch.
    panels: Vec<PanelArgs>,
    /// Stitch tunables (optional; defaults applied per field).
    config: StitchConfigArgs,
    /// Output paths.
    output: OutputArgs,
}

/// Response for [`api_stitch_mosaic`].
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct StitchMosaicResult {
    /// Path the `F32` mosaic master was written to.
    output_path: String,
    /// Path the coverage plane was written to, when requested.
    coverage_path: Option<String>,
    /// Path the preview PNG was written to, when requested.
    preview_png_path: Option<String>,
    /// Output canvas width in pixels.
    out_width: u32,
    /// Output canvas height in pixels.
    out_height: u32,
    /// Number of overlapping panel pairs found.
    overlap_pairs: usize,
    /// Mean of the solved per-panel gains (diagnostic).
    mean_panel_gain: f64,
}

// Public FFI entry point

/// Stitch N plate-solved panel masters into one mosaic master.
///
/// Each panel is read from FITS; its WCS is taken from the explicit `wcs` block
/// when supplied, else parsed from the header CD matrix (with a `CDELT`/`CROTA`
/// fallback). The panels are projected onto a common gnomonic canvas, optionally
/// photometrically normalized over their overlaps, and feather-blended into one
/// `F32` master via [`stitch_mosaic`]. The master is written to
/// `output.mosaicFitsPath` with the output canvas WCS stamped in the header;
/// when `coverageFitsPath` / `previewPngPath` are given the coverage plane /
/// stretched preview are written too.
///
/// `args_json` is a [`StitchMosaicArgs`]; the result is a [`StitchMosaicResult`].
/// Every failure surfaces as `Err(String)` rather than a partial mosaic.
pub fn api_stitch_mosaic(args_json: String) -> Result<String, String> {
    let args: StitchMosaicArgs =
        serde_json::from_str(&args_json).map_err(|e| format!("invalid stitch args: {e}"))?;
    let result = stitch_mosaic_impl(args)?;
    serde_json::to_string(&result).map_err(|e| format!("failed to encode result: {e}"))
}

// Implementation

fn stitch_mosaic_impl(args: StitchMosaicArgs) -> Result<StitchMosaicResult, String> {
    if args.panels.is_empty() {
        return Err("no panels supplied to the mosaic stitcher".to_string());
    }
    if args.output.mosaic_fits_path.trim().is_empty() {
        return Err("output.mosaicFitsPath is required".to_string());
    }

    // Read each panel master + resolve its WCS.
    let mut panels: Vec<MosaicPanel> = Vec::with_capacity(args.panels.len());
    for (idx, pa) in args.panels.iter().enumerate() {
        if pa.fits_path.trim().is_empty() {
            return Err(format!("panel {idx} has an empty fitsPath"));
        }
        let (image, header) = read_fits(Path::new(&pa.fits_path))
            .map_err(|e| format!("failed to read panel '{}': {e:?}", pa.fits_path))?;
        let wcs = match pa.wcs {
            Some(w) => w.into(),
            None => wcs_from_header(&header).ok_or_else(|| {
                format!(
                    "panel '{}' has no usable WCS (need CRVAL1/2 + CD matrix or CDELT/CROTA)",
                    pa.fits_path
                )
            })?,
        };
        panels.push(MosaicPanel { image, wcs });
    }

    // Build the stitch config from the JSON args.
    let cfg = build_config(&args.config)?;

    // Stitch.
    let output = stitch_mosaic(&panels, &cfg).map_err(|e| describe_error(&e))?;

    // Write the F32 master, stamping the output canvas WCS.
    let master_path = Path::new(&args.output.mosaic_fits_path);
    ensure_parent_dir(master_path)?;
    let mut header = FitsHeader::new();
    header.set_string("IMAGETYP", "MASTER_LIGHT");
    header.set_string("FRAMETYP", "MASTER");
    header.set_string("CALSTAT", "Skotiq mosaic stitch");
    header.set_int("NPANELS", output.stats.panels as i64);
    header.set_int("OVRLPPRS", output.stats.overlap_pairs as i64);
    header.set_float("MOSGAIN", output.stats.mean_panel_gain);
    add_wcs_headers(&mut header, &output.wcs);
    header.add_history("Skotiq mosaic stitch (WCS-projected panel composite)");
    write_fits(master_path, &output.master, &header)
        .map_err(|e| format!("failed to write mosaic master: {e:?}"))?;

    // Optional coverage plane FITS.
    let coverage_path = match args.output.coverage_fits_path.as_ref() {
        Some(p) if !p.trim().is_empty() => {
            let path = Path::new(p);
            ensure_parent_dir(path)?;
            let mut h = FitsHeader::new();
            h.set_string("IMAGETYP", "COVERAGE_MAP");
            add_wcs_headers(&mut h, &output.wcs);
            h.add_history("Skotiq mosaic per-pixel contributing-weight (coverage) plane");
            write_fits(path, &output.coverage, &h)
                .map_err(|e| format!("failed to write coverage plane: {e:?}"))?;
            Some(p.clone())
        }
        _ => None,
    };

    // Optional stretched preview PNG.
    // BEST-EFFORT: the preview is a cosmetic convenience, not a real output. A
    // stitch is expensive (read + project + blend every panel); aborting the
    // whole run because an 8-bit sibling PNG failed to write would throw away the
    // master + coverage — the artifacts that actually matter. So a preview-write
    // failure is logged and skipped, never propagated.
    let preview_png_path = match args.output.preview_png_path.as_ref() {
        Some(p) if !p.trim().is_empty() => {
            match crate::api::post_session::write_preview_png(&output.master, Path::new(p)) {
                Ok(()) => Some(p.clone()),
                Err(e) => {
                    tracing::warn!(
                        path = %p,
                        error = %e,
                        "mosaic preview PNG write failed; returning master/coverage without a \
                         mosaic preview (best-effort)"
                    );
                    None
                }
            }
        }
        _ => None,
    };

    Ok(StitchMosaicResult {
        output_path: args.output.mosaic_fits_path,
        coverage_path,
        preview_png_path,
        out_width: output.stats.out_width,
        out_height: output.stats.out_height,
        overlap_pairs: output.stats.overlap_pairs,
        mean_panel_gain: output.stats.mean_panel_gain,
    })
}

/// Build a [`MosaicStitchConfig`] from the JSON args, applying the per-field
/// defaults and rejecting unknown enum strings loudly.
fn build_config(args: &StitchConfigArgs) -> Result<MosaicStitchConfig, String> {
    let mut cfg = MosaicStitchConfig::default();
    if let Some(r) = args.resampler.as_ref() {
        cfg.resampler = match r.trim().to_ascii_lowercase().as_str() {
            "" | "lanczos3" | "lanczos" => Interpolator::Lanczos3,
            "catmullrom" | "catmull-rom" | "catmull" => Interpolator::CatmullRom,
            "bilinear" | "linear" => Interpolator::Bilinear,
            other => return Err(format!("unknown resampler '{other}'")),
        };
    }
    if let Some(n) = args.normalize {
        cfg.normalize = n;
    }
    if let Some(b) = args.blend.as_ref() {
        cfg.blend = match b.trim().to_ascii_lowercase().as_str() {
            "" | "feather" => MosaicBlend::Feather,
            "none" | "average" => MosaicBlend::None,
            other => return Err(format!("unknown blend '{other}'")),
        };
    }
    if let Some(f) = args.feather_px {
        if f > 0.0 {
            cfg.feather_px = f;
        }
    }
    cfg.output_pixel_scale_arcsec = match args.output_pixel_scale_arcsec {
        Some(s) if s > 0.0 => Some(s),
        _ => None,
    };
    Ok(cfg)
}

/// Map a [`MosaicError`] to a human-readable FFI error string.
fn describe_error(e: &MosaicError) -> String {
    match e {
        MosaicError::NoPanels => "no panels supplied to the mosaic stitcher".to_string(),
        MosaicError::Dimensionless => "a panel has zero width or height".to_string(),
        MosaicError::DegenerateWcs => {
            "a panel (or the output canvas) has a degenerate, non-invertible WCS".to_string()
        }
        MosaicError::ChannelMismatch => "panels have mismatched channel counts".to_string(),
        MosaicError::CanvasTooLarge { pixels } => {
            format!("output canvas too large: {pixels} pixels (check the panel WCS)")
        }
    }
}

/// Build a [`WcsInfo`] from a FITS header.
///
/// Prefers the explicit CD matrix (`CD1_1..CD2_2`). When the header carries only
/// the older `CDELT1/2` (+ optional `CROTA2`) convention, the CD matrix is
/// synthesised from it (this is exactly the inverse of `add_wcs_headers` /
/// `WcsInfo::from_plate_solve`). Returns `None` if neither a CD matrix nor a
/// `CDELT` pair (plus `CRVAL`) is present.
fn wcs_from_header(header: &FitsHeader) -> Option<WcsInfo> {
    let crval1 = header.get_float("CRVAL1")?;
    let crval2 = header.get_float("CRVAL2")?;
    // CRPIX defaults to the geometric centre (1-based) if absent.
    let naxis1 = header.get_int("NAXIS1").unwrap_or(0) as f64;
    let naxis2 = header.get_int("NAXIS2").unwrap_or(0) as f64;
    let crpix1 = header
        .get_float("CRPIX1")
        .unwrap_or_else(|| naxis1 / 2.0 + 0.5);
    let crpix2 = header
        .get_float("CRPIX2")
        .unwrap_or_else(|| naxis2 / 2.0 + 0.5);

    // Prefer an explicit CD matrix.
    if let (Some(cd1_1), Some(cd2_2)) = (header.get_float("CD1_1"), header.get_float("CD2_2")) {
        let cd1_2 = header.get_float("CD1_2").unwrap_or(0.0);
        let cd2_1 = header.get_float("CD2_1").unwrap_or(0.0);
        return Some(WcsInfo {
            crval1,
            crval2,
            crpix1,
            crpix2,
            cd1_1,
            cd1_2,
            cd2_1,
            cd2_2,
        });
    }

    // Fall back to CDELT + CROTA2 (older WCS convention).
    let cdelt1 = header.get_float("CDELT1")?;
    let cdelt2 = header.get_float("CDELT2")?;
    let crota2 = header.get_float("CROTA2").unwrap_or(0.0).to_radians();
    let cos_r = crota2.cos();
    let sin_r = crota2.sin();
    // Standard CDELT→CD synthesis: CD = [[c1·cosθ, −c2·sinθ], [c1·sinθ, c2·cosθ]].
    Some(WcsInfo {
        crval1,
        crval2,
        crpix1,
        crpix2,
        cd1_1: cdelt1 * cos_r,
        cd1_2: -cdelt2 * sin_r,
        cd2_1: cdelt1 * sin_r,
        cd2_2: cdelt2 * cos_r,
    })
}

/// Ensure the parent directory of `path` exists, creating it if necessary.
///
/// Mirrors the `ensure_parent_dir` in [`crate::api::post_session`]; duplicated
/// here so this module stays self-contained (its sibling is private to that
/// module).
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

// Tests

#[cfg(test)]
mod tests {
    use super::*;
    use skotiq_imaging::{ImageData, PixelType};
    use std::sync::atomic::{AtomicU64, Ordering};

    static COUNTER: AtomicU64 = AtomicU64::new(0);

    /// A scratch directory that deletes itself when the test ends. Cleanup runs
    /// from `Drop`, so it happens even while a panic unwinds out of a failing test.
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
        let p = std::env::temp_dir().join(format!(
            "ns_mosaic_ffi_{}_{}_{}",
            tag,
            std::process::id(),
            n
        ));
        std::fs::create_dir_all(&p).unwrap();
        TempDir(p)
    }

    /// CD-matrix WCS for an axis-aligned tangent plane (no rotation), RA flipping
    /// left, CRPIX at the geometric centre.
    fn make_wcs(ra: f64, dec: f64, scale_arcsec: f64, w: u32, h: u32) -> WcsInfo {
        let scale_deg = scale_arcsec / 3600.0;
        WcsInfo {
            crval1: ra,
            crval2: dec,
            crpix1: w as f64 / 2.0 + 0.5,
            crpix2: h as f64 / 2.0 + 0.5,
            cd1_1: -scale_deg,
            cd1_2: 0.0,
            cd2_1: 0.0,
            cd2_2: scale_deg,
        }
    }

    /// Write a synthetic single-channel F32 panel master (ramp field) to a FITS
    /// file with its WCS stamped, and return its path.
    fn write_panel(
        dir: &Path,
        tag: &str,
        wcs: &WcsInfo,
        w: u32,
        h: u32,
        base: f32,
    ) -> std::path::PathBuf {
        let data: Vec<f32> = (0..(w * h)).map(|i| base + (i % 997) as f32).collect();
        let image = ImageData::from_f32(w, h, 1, &data);
        let mut header = FitsHeader::new();
        add_wcs_headers(&mut header, wcs);
        let path = dir.join(format!("{tag}.fits"));
        write_fits(&path, &image, &header).expect("write synthetic panel");
        path
    }

    #[test]
    fn stitch_two_panels_round_trip() {
        // Two RA-overlapping panels at the same dec; same scale.
        let ra0: f64 = 120.0;
        let dec0: f64 = 10.0;
        let scale: f64 = 4.0;
        let (w, h) = (96u32, 96u32);
        let half_w_deg = (w as f64 / 2.0) * (scale / 3600.0) / dec0.to_radians().cos();
        let wcs_a = make_wcs(ra0, dec0, scale, w, h);
        let wcs_b = make_wcs(ra0 - half_w_deg, dec0, scale, w, h);
        let dir = temp_dir("stitch_two_panels_round_trip");
        let pa = write_panel(&dir, "a", &wcs_a, w, h, 100.0);
        let pb = write_panel(&dir, "b", &wcs_b, w, h, 100.0);

        let master_out = dir.join("master.fits");
        let coverage_out = dir.join("coverage.fits");
        let preview_out = dir.join("preview.png");

        let args = serde_json::json!({
            "panels": [ { "fitsPath": pa.to_string_lossy() }, { "fitsPath": pb.to_string_lossy() } ],
            "config": { "normalize": true, "blend": "feather", "resampler": "lanczos3" },
            "output": {
                "mosaicFitsPath": master_out.to_string_lossy(),
                "coverageFitsPath": coverage_out.to_string_lossy(),
                "previewPngPath": preview_out.to_string_lossy()
            }
        })
        .to_string();

        let resp = api_stitch_mosaic(args).expect("stitch should succeed");
        let result: StitchMosaicResult = serde_json::from_str(&resp).unwrap();

        assert!(master_out.exists(), "master FITS must be on disk");
        assert!(coverage_out.exists(), "coverage FITS must be on disk");
        assert!(preview_out.exists(), "preview PNG must be on disk");
        assert!(result.out_width > w, "union wider than a single panel");
        assert!(result.overlap_pairs >= 1, "panels overlap");

        // The written master must carry the output canvas WCS.
        let (master_img, master_hdr) = read_fits(&master_out).unwrap();
        assert_eq!(master_img.pixel_type, PixelType::F32);
        assert!(master_hdr.get_float("CRVAL1").is_some(), "master has WCS");
        assert_eq!(
            master_hdr.get_int("NPANELS"),
            Some(2),
            "panel count stamped"
        );
    }

    #[test]
    fn missing_wcs_errors() {
        // A panel FITS with no WCS keywords at all.
        let data = vec![1.0f32; 64 * 64];
        let image = ImageData::from_f32(64, 64, 1, &data);
        let header = FitsHeader::new();
        let dir = temp_dir("missing_wcs_errors");
        let path = dir.join("nowcs.fits");
        write_fits(&path, &image, &header).unwrap();

        let master_out = dir.join("master_nowcs.fits");
        let args = serde_json::json!({
            "panels": [ { "fitsPath": path.to_string_lossy() } ],
            "output": { "mosaicFitsPath": master_out.to_string_lossy() }
        })
        .to_string();
        let err = api_stitch_mosaic(args).unwrap_err();
        assert!(err.contains("no usable WCS"), "got: {err}");
    }

    #[test]
    fn explicit_wcs_overrides_header() {
        // Panel FITS with a (deliberately wrong) header WCS; the explicit `wcs`
        // block must win, so a single-panel stitch succeeds at the explicit
        // coordinates.
        let wrong = make_wcs(0.0, 0.0, 99.0, 80, 80);
        let right = make_wcs(250.0, -40.0, 3.0, 80, 80);
        let data = vec![500.0f32; 80 * 80];
        let image = ImageData::from_f32(80, 80, 1, &data);
        let mut header = FitsHeader::new();
        add_wcs_headers(&mut header, &wrong);
        let dir = temp_dir("explicit_wcs_overrides_header");
        let path = dir.join("override.fits");
        write_fits(&path, &image, &header).unwrap();

        let master_out = dir.join("master_override.fits");
        let args = serde_json::json!({
            "panels": [ {
                "fitsPath": path.to_string_lossy(),
                "wcs": {
                    "crval1": right.crval1, "crval2": right.crval2,
                    "crpix1": right.crpix1, "crpix2": right.crpix2,
                    "cd1_1": right.cd1_1, "cd1_2": right.cd1_2,
                    "cd2_1": right.cd2_1, "cd2_2": right.cd2_2
                }
            } ],
            "output": { "mosaicFitsPath": master_out.to_string_lossy() }
        })
        .to_string();
        let resp = api_stitch_mosaic(args).expect("explicit-WCS stitch succeeds");
        let _: StitchMosaicResult = serde_json::from_str(&resp).unwrap();
        // Output WCS should be near the explicit centre, not the wrong header.
        let (_img, hdr) = read_fits(&master_out).unwrap();
        let out_ra = hdr.get_float("CRVAL1").unwrap();
        assert!(
            (out_ra - 250.0).abs() < 1.0,
            "out RA {out_ra} should be ~250"
        );
    }

    #[test]
    fn empty_panels_errors() {
        let args = serde_json::json!({
            "panels": [],
            "output": { "mosaicFitsPath": "/tmp/never.fits" }
        })
        .to_string();
        let err = api_stitch_mosaic(args).unwrap_err();
        assert!(err.contains("no panels"), "got: {err}");
    }

    #[test]
    fn cdelt_fallback_wcs_parses() {
        // A header with only CRVAL + CDELT (no CD matrix) must still yield a
        // usable WCS via the synthesis path.
        let mut header = FitsHeader::new();
        header.set_float("CRVAL1", 30.0);
        header.set_float("CRVAL2", 45.0);
        header.set_float("CRPIX1", 50.0);
        header.set_float("CRPIX2", 50.0);
        header.set_float("CDELT1", -0.001);
        header.set_float("CDELT2", 0.001);
        let wcs = wcs_from_header(&header).expect("CDELT fallback yields WCS");
        assert!((wcs.cd1_1 - (-0.001)).abs() < 1e-12);
        assert!((wcs.cd2_2 - 0.001).abs() < 1e-12);
        assert_eq!(wcs.crval1, 30.0);
    }
}
