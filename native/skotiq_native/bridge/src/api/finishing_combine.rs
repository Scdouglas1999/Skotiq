//! Post-session **combination** FFI surface — drizzle integration and
//! narrowband channel combine.
//!
//! This module exposes two committed native finishing primitives
//! (`skotiq_imaging::{drizzle, channel_combine}`) to Dart through the same
//! **JSON-in / JSON-out** boundary the rest of the post-session surface uses
//! (see [`crate::api::post_session`] for the canonical template and the
//! rationale). Every knob — drizzle scale / pixfrac / kernel, palette name,
//! custom weight tables — rides inside the JSON payload, so adding one never
//! triggers a `flutter_rust_bridge` regen. The boundary is exactly two
//! `String -> Result<String, String>` functions:
//!
//! * [`api_drizzle_integrate`] — variable-pixel linear reconstruction (drizzle)
//!   of a population of already-registered frames onto a finer output grid,
//!   with an RGB / Bayer-CFA mode, producing a linear `F32` master plus an
//!   optional per-pixel coverage map.
//! * [`api_combine_channels`] — linear narrowband palette combine (SHO / HOO /
//!   custom weights) of single-channel masters into a 3-channel `F32` RGB
//!   composite.
//!
//! These are **stateless per call** (no process-wide singleton) and CPU-bound;
//! the Dart side runs them off the UI isolate. As everywhere in the
//! post-session surface, every failure mode (no frames, unreadable FITS,
//! geometry mismatch, bad parameters, write failure) surfaces as `Err(String)`
//! — never a silent partial result.

use skotiq_imaging::calibration::calibrate_frame;
use skotiq_imaging::calibration_masters::{cosmetic_correct_transient, CosmeticConfig};
use skotiq_imaging::channel_combine::{combine_channels, hoo_palette, sho_palette};
use skotiq_imaging::drizzle::{
    bayer_drizzle_integrate, drizzle_integrate, BayerDrizzleFrame, DrizzleConfig, DrizzleFrame,
    DrizzleKernel,
};
use skotiq_imaging::registration::{TransformKind, TransformModel};
use skotiq_imaging::{
    copy_astrometry_headers, read_bayer_geometry, read_fits, write_fits, FitsHeader, ImageData,
    PixelType,
};
use serde::{Deserialize, Serialize};
use std::path::Path;

// api_drizzle_integrate — JSON contracts

/// One frame's contribution to a drizzle integration.
///
/// `transform` is the **row-major 3×3** homogeneous matrix mapping this frame's
/// pixel coordinates onto the **reference grid** (source → reference, the same
/// convention as [`skotiq_imaging::registration::TransformModel`]). It is
/// supplied as a flat 9-element array `[m00, m01, m02, m10, m11, m12, m20, m21,
/// m22]`. `weight` is the scalar quality weight applied to every drop from this
/// frame.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct DrizzleFrameArgs {
    /// FITS path of the (registered) frame to drizzle. For Bayer mode this is
    /// the raw, **un-debayered** single-channel CFA mosaic.
    fits_path: String,
    /// Row-major 3×3 source→reference transform, flattened to 9 elements.
    transform: Vec<f64>,
    /// Scalar quality weight for every drop from this frame (`<= 0` ⇒ skipped).
    weight: f64,
}

/// Calibration master paths applied to every (raw) sub **before** its drops are
/// deposited onto the drizzle grid.
///
/// This is the **same shape** `api_integrate_session`'s `CalibrationArgs` uses
/// (see [`crate::api::post_session`]). The DRIZZLE CALIBRATION CONTRACT requires
/// the drizzle to consume the *same resolved calibration* the standard integrate
/// pass did, so a drizzled master is calibrated identically to the standard
/// master it replaces — never a raw, uncalibrated deposit. `defect_map` is
/// accepted for shape-compatibility with the shared calibration block (it is
/// resolved Dart-side); the per-frame correction we apply here is the same
/// dark/flat/bias + self-derived cosmetic repair `api_integrate_session` runs.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct CalibrationArgs {
    /// Master dark FITS path, or `None`/empty to skip.
    dark: Option<String>,
    /// Master flat (unit-mean) path, or `None`/empty to skip.
    flat: Option<String>,
    /// Master bias path, or `None`/empty to skip.
    bias: Option<String>,
    /// Resolved defect-map path (shape-compatible with the shared calibration
    /// block; defect repair is applied Dart-side / at capture time).
    defect_map: Option<String>,
    /// Apply self-derived cosmetic (hot/cold transient) correction per sub.
    cosmetic_correction: bool,
}

impl CalibrationArgs {
    /// `true` when this block requests at least one calibration step that the
    /// drizzle path itself performs (dark/flat/bias subtraction-division or the
    /// per-sub cosmetic repair). When `false`, sub loading skips the (cloning)
    /// calibrate pass entirely and deposits the raw pixels as before.
    fn is_active(&self) -> bool {
        non_empty(&self.dark)
            || non_empty(&self.flat)
            || non_empty(&self.bias)
            || self.cosmetic_correction
    }
}

/// `true` when an optional path is `Some` and non-blank.
fn non_empty(path: &Option<String>) -> bool {
    matches!(path, Some(p) if !p.trim().is_empty())
}

/// Drizzle tunables (subset of [`DrizzleConfig`]). Each unset field falls back
/// to the [`DrizzleConfig::default`] (2× drizzle, `pixfrac = 0.9`, square
/// kernel).
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct DrizzleConfigArgs {
    /// Linear output/input scale factor (`> 0`). `0`/unset ⇒ default `2.0`.
    scale: f64,
    /// Drop-shrink fraction in `(0, 1]`. `0`/unset ⇒ default `0.9`.
    pixfrac: f64,
    /// `"square"` (default) | `"point"` | `"gaussian"`. Empty ⇒ square.
    kernel: String,
}

/// Top-level request for [`api_drizzle_integrate`].
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct DrizzleIntegrateArgs {
    /// The frames to drizzle (each with its source→reference transform).
    frames: Vec<DrizzleFrameArgs>,
    /// Reference-grid width in pixels (the output grid is `ceil(ref_w · scale)`).
    ref_w: u32,
    /// Reference-grid height in pixels.
    ref_h: u32,
    /// Optional calibration block applied to every (raw) sub before its drops
    /// are deposited. Defaults to "no calibration" (every field unset) — the
    /// historical raw-deposit behaviour — so omitting it is a no-op. The
    /// caller is expected to pass the **same** resolved calibration the standard
    /// integrate pass used so the drizzled master is calibrated identically.
    calibration: CalibrationArgs,
    /// Drizzle tunables (optional; defaults applied per field).
    config: DrizzleConfigArgs,
    /// When `true`, treat every input as a raw single-channel CFA mosaic and run
    /// **Bayer drizzle** into a 3-channel RGB master (no debayer interpolation).
    /// The Bayer pattern is read from each frame's FITS header (`BAYERPAT` +
    /// `XBAYROFF`/`YBAYROFF`).
    bayer: bool,
    /// Output FITS path for the linear `F32` master (required).
    output_fits: String,
    /// Optional output FITS path for the per-pixel coverage (drizzle weight) map.
    coverage_fits: Option<String>,
    /// Optional stretched PNG sibling for the coverage overlay.
    coverage_png_path: Option<String>,
    /// Optional stretched preview PNG path for the drizzled master, mirroring
    /// `api_integrate_session`'s preview so the session-review hero can show the
    /// (scaled) drizzled image rather than the standard 1× preview.
    preview_png_path: Option<String>,
}

/// Response for [`api_drizzle_integrate`].
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct DrizzleIntegrateResult {
    /// Path the `F32` master was written to.
    output_path: String,
    /// Path the coverage map was written to, when requested.
    coverage_path: Option<String>,
    /// Path the stretched coverage-map PNG was written to, when requested.
    coverage_png_path: Option<String>,
    /// Path the stretched preview PNG was written to, when requested.
    preview_png_path: Option<String>,
    /// Output master width (`ceil(ref_w · scale)`).
    out_width: u32,
    /// Output master height (`ceil(ref_h · scale)`).
    out_height: u32,
    /// Output master channel count (1 or 3 for the RGB warp; always 3 for Bayer).
    channels: u32,
}

// api_combine_channels — JSON contracts

/// Top-level request for [`api_combine_channels`].
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct CombineChannelsArgs {
    /// Single-channel linear master FITS paths, in palette order.
    inputs: Vec<String>,
    /// Per-input `[r, g, b]` weight triples. Required unless `palette` is set;
    /// when both are given, `palette` wins and these are ignored.
    weights: Option<Vec<[f64; 3]>>,
    /// `"sho"` (S II→R, Hα→G, O III→B) | `"hoo"` (Hα→R, O III→G+B). When set,
    /// the canonical palette weight table is used and the input count must match
    /// the palette (3 for SHO, 2 for HOO).
    palette: Option<String>,
    /// Output FITS path for the 3-channel `F32` RGB composite (required).
    output_fits: String,
}

/// Response for [`api_combine_channels`].
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct CombineChannelsResult {
    /// Path the `F32` RGB composite was written to.
    output_path: String,
    /// Composite width in pixels.
    width: u32,
    /// Composite height in pixels.
    height: u32,
}

// Public FFI entry points

/// Drizzle (variable-pixel linear reconstruction) a population of registered
/// frames onto a `scale`× output grid.
///
/// Each frame is read from FITS, its 3×3 source→reference transform is rebuilt
/// into a [`TransformModel`], and its pixels are deposited as `pixfrac`-shrunk
/// drops via [`drizzle_integrate`] (RGB / mono) or [`bayer_drizzle_integrate`]
/// (raw CFA mosaic → 3-channel RGB, when `bayer == true`). The reconstructed
/// `F32` master is written to `output_fits`; when `coverage_fits` is given the
/// per-pixel drizzle-weight map is written there too.
///
/// `args_json` is a [`DrizzleIntegrateArgs`]; the result is a
/// [`DrizzleIntegrateResult`]. Every failure surfaces as `Err(String)` rather
/// than a partial stack.
pub fn api_drizzle_integrate(args_json: String) -> Result<String, String> {
    let args: DrizzleIntegrateArgs =
        serde_json::from_str(&args_json).map_err(|e| format!("invalid drizzle args: {e}"))?;
    let result = drizzle_integrate_impl(args)?;
    serde_json::to_string(&result).map_err(|e| format!("failed to encode result: {e}"))
}

/// Linearly combine single-channel narrowband masters into a 3-channel `F32`
/// RGB composite, wrapping [`combine_channels`].
///
/// When `palette` is `"sho"`/`"hoo"` the canonical weight table
/// ([`sho_palette`]/[`hoo_palette`]) is used; otherwise the explicit per-input
/// `[r, g, b]` `weights` are applied. The composite is written to `output_fits`.
///
/// `args_json` is a [`CombineChannelsArgs`]; the result is a
/// [`CombineChannelsResult`].
pub fn api_combine_channels(args_json: String) -> Result<String, String> {
    let args: CombineChannelsArgs =
        serde_json::from_str(&args_json).map_err(|e| format!("invalid combine args: {e}"))?;
    let result = combine_channels_impl(args)?;
    serde_json::to_string(&result).map_err(|e| format!("failed to encode result: {e}"))
}

// api_drizzle_integrate implementation

fn drizzle_integrate_impl(args: DrizzleIntegrateArgs) -> Result<DrizzleIntegrateResult, String> {
    if args.frames.is_empty() {
        return Err("no frames to drizzle".to_string());
    }
    if args.output_fits.trim().is_empty() {
        return Err("outputFits is required".to_string());
    }
    if args.ref_w == 0 || args.ref_h == 0 {
        return Err("refW and refH must both be > 0".to_string());
    }

    let cfg = build_drizzle_config(&args.config)?;

    // Load calibration masters once (shared across all subs).
    //
    // DRIZZLE CALIBRATION CONTRACT: the drizzle must calibrate each sub with the
    // SAME dark/flat/bias the standard integrate pass applied — otherwise the
    // drizzled FITS that `_runDrizzle` swaps in as THE persisted master would be
    // a raw, uncalibrated deposit (amp glow, hot pixels, vignetting, dust). We
    // read the masters with `read_fits` (NOT the auto-debayering `read_image`):
    // calibration is per-raw-pixel and must run on the same single-channel
    // geometry the (raw, Bayer or mono) sub carries, before any debayer/warp.
    let calibrate = args.calibration.is_active();
    let dark = load_optional_master(&args.calibration.dark, "dark")?;
    let flat = load_optional_master(&args.calibration.flat, "flat")?;
    let bias = load_optional_master(&args.calibration.bias, "bias")?;

    // The native `DrizzleFrame`/`BayerDrizzleFrame` borrow their pixel buffer
    // and transform by reference (`&'a [f64]`, `&'a TransformModel`). We must
    // therefore materialise the owned `Vec<f64>` buffers and owned
    // `TransformModel`s into vectors that outlive the borrowed frame slice — so
    // the `&[f64]` stays valid for the whole `*_integrate` call. We build the
    // owned storage first, then borrow from it in a second pass.
    let mut buffers: Vec<Vec<f64>> = Vec::with_capacity(args.frames.len());
    let mut transforms: Vec<TransformModel> = Vec::with_capacity(args.frames.len());
    let mut dims: Vec<(u32, u32, u32)> = Vec::with_capacity(args.frames.len());
    let mut patterns: Vec<skotiq_imaging::BayerPattern> = Vec::with_capacity(args.frames.len());

    for fa in &args.frames {
        if fa.fits_path.trim().is_empty() {
            return Err("a drizzle frame has an empty fitsPath".to_string());
        }
        let (mut image, header) = read_fits(Path::new(&fa.fits_path))
            .map_err(|e| format!("failed to read '{}': {e:?}", fa.fits_path))?;
        let transform = transform_from_row_major(&fa.transform)
            .map_err(|e| format!("frame '{}': {e}", fa.fits_path))?;

        if args.bayer {
            // Raw CFA mode: the mosaic must be a single-channel buffer, and the
            // Bayer pattern is read from the typed FITS header; guessing a
            // pattern mis-colours the reconstruction.
            if image.channels != 1 {
                return Err(format!(
                    "Bayer drizzle requires a single-channel CFA mosaic, but '{}' has {} channels",
                    fa.fits_path, image.channels
                ));
            }
            let geometry = read_bayer_geometry(&header).ok_or_else(|| {
                format!(
                    "'{}' has no BAYERPAT header; cannot Bayer-drizzle a frame without a CFA pattern",
                    fa.fits_path
                )
            })?;
            patterns.push(geometry.effective);
        }

        // Calibrate the (raw) sub before depositing its drops.
        //
        // Same helpers `api_integrate_session` uses: dark/flat/bias via
        // `calibrate_frame`, then the per-sub self-derived cosmetic repair. This
        // runs on the raw single-channel (Bayer) or RGB/mono buffer, before the
        // drizzle warp, so a hot pixel / pedestal / vignette is removed once, at
        // the source — exactly as the standard integrate pass does it. Without
        // this, `_runDrizzle` would persist an UNcalibrated master as canonical.
        if calibrate {
            if dark.is_some() || flat.is_some() || bias.is_some() {
                image = calibrate_frame(&image, dark.as_ref(), flat.as_ref(), bias.as_ref())
                    .map_err(|e| format!("calibration of '{}' failed: {e}", fa.fits_path))?;
            }
            if args.calibration.cosmetic_correction {
                // Operates per-channel in place; the report is advisory.
                let _ = cosmetic_correct_transient(&mut image, CosmeticConfig::default());
            }
        }

        buffers.push(decode_image_f64(&image, &fa.fits_path)?);
        dims.push((image.width, image.height, image.channels));
        transforms.push(transform);
    }

    let output = if args.bayer {
        let frames: Vec<BayerDrizzleFrame> = buffers
            .iter()
            .zip(dims.iter())
            .zip(transforms.iter())
            .zip(patterns.iter())
            .zip(args.frames.iter())
            .map(
                |((((mosaic, &(w, h, _c)), transform), &pattern), fa)| BayerDrizzleFrame {
                    mosaic,
                    width: w,
                    height: h,
                    pattern,
                    transform,
                    weight: fa.weight,
                },
            )
            .collect();
        bayer_drizzle_integrate(&frames, args.ref_w, args.ref_h, &cfg)
            .map_err(|e| format!("Bayer drizzle failed: {e}"))?
    } else {
        let frames: Vec<DrizzleFrame> = buffers
            .iter()
            .zip(dims.iter())
            .zip(transforms.iter())
            .zip(args.frames.iter())
            .map(|(((pixels, &(w, h, c)), transform), fa)| DrizzleFrame {
                pixels,
                width: w,
                height: h,
                channels: c,
                transform,
                weight: fa.weight,
            })
            .collect();
        drizzle_integrate(&frames, args.ref_w, args.ref_h, &cfg)
            .map_err(|e| format!("drizzle failed: {e}"))?
    };

    // Write the F32 master.
    let master_path = Path::new(&args.output_fits);
    ensure_parent_dir(master_path)?;
    let mut header = FitsHeader::new();
    header.set_string("IMAGETYP", "MASTER_LIGHT");
    header.set_string("FRAMETYP", "MASTER");
    header.set_string("CALSTAT", "Skotiq drizzle master");
    header.set_int("NFRAMES", args.frames.len() as i64);
    header.set_float("DRZSCALE", cfg.scale);
    header.set_float("PIXFRAC", cfg.pixfrac);
    header.set_string("DRZKERN", kernel_name(cfg.kernel));
    header.add_history(if args.bayer {
        "Skotiq Bayer-CFA drizzle integration"
    } else {
        "Skotiq drizzle integration"
    });
    // No WCS is carried. The drizzle output lives on a `scale`x grid, so no
    // input frame's CRPIX/CD describes it, and the reference grid's own solve is
    // not supplied to this call. Stamping a frame's astrometry here would
    // produce a header that reads as solved and points at the wrong sky; the
    // absence is stated so a reader knows to solve the drizzled master.
    header.add_history(&format!(
        "No astrometry carried: output grid is {:.3}x the reference grid",
        cfg.scale
    ));
    write_fits(master_path, &output.master, &header)
        .map_err(|e| format!("failed to write drizzle master: {e:?}"))?;

    // Optional coverage map FITS.
    let coverage_path = match args.coverage_fits.as_ref() {
        Some(p) if !p.trim().is_empty() => {
            let path = Path::new(p);
            ensure_parent_dir(path)?;
            let mut h = FitsHeader::new();
            h.set_string("IMAGETYP", "COVERAGE_MAP");
            h.add_history("Skotiq drizzle per-pixel coverage (drizzle weight) map");
            write_fits(path, &output.coverage, &h)
                .map_err(|e| format!("failed to write coverage map: {e:?}"))?;
            Some(p.clone())
        }
        _ => None,
    };

    // Optional stretched coverage-map PNG.
    // Preserve the linear coverage FITS for science while providing a format
    // Flutter can actually composite in the review overlay.
    let coverage_png_path = match args.coverage_png_path.as_ref() {
        Some(p) if !p.trim().is_empty() => {
            match crate::api::post_session::write_preview_png(&output.coverage, Path::new(p)) {
                Ok(()) => Some(p.clone()),
                Err(e) => {
                    tracing::warn!(
                        path = %p,
                        error = %e,
                        "coverage preview PNG write failed; keeping drizzle master and FITS map"
                    );
                    None
                }
            }
        }
        _ => None,
    };

    // Optional stretched preview PNG of the drizzled master.
    // Mirror `api_integrate_session`: emit a sibling 8-bit preview so the
    // session-review hero shows the (scaled) drizzled image, not the standard
    // 1× preview.
    //
    // BEST-EFFORT: the preview is a cosmetic convenience, not a real output. A
    // drizzle run is expensive (read + calibrate + warp + deposit every sub);
    // aborting the whole run because an 8-bit sibling PNG failed to write would
    // throw away the master + coverage — the artifacts that actually matter. So
    // a preview-write failure is logged and skipped (`preview_png_path = None`),
    // never propagated. The Dart side already falls back to the standard preview
    // when the drizzle returns no `previewPngPath`.
    let preview_png_path = match args.preview_png_path.as_ref() {
        Some(p) if !p.trim().is_empty() => {
            match crate::api::post_session::write_preview_png(&output.master, Path::new(p)) {
                Ok(()) => Some(p.clone()),
                Err(e) => {
                    tracing::warn!(
                        path = %p,
                        error = %e,
                        "drizzle preview PNG write failed; returning master/coverage without a \
                         drizzle preview (best-effort)"
                    );
                    None
                }
            }
        }
        _ => None,
    };

    Ok(DrizzleIntegrateResult {
        output_path: args.output_fits,
        coverage_path,
        coverage_png_path,
        preview_png_path,
        out_width: output.master.width,
        out_height: output.master.height,
        channels: output.master.channels,
    })
}

/// Build a [`DrizzleConfig`] from the JSON args, applying the
/// [`DrizzleConfig::default`] for any unset (`0`/empty) field. Out-of-range
/// values are left for the native `validate()` to reject with a descriptive
/// error.
fn build_drizzle_config(a: &DrizzleConfigArgs) -> Result<DrizzleConfig, String> {
    let mut cfg = DrizzleConfig::default();
    if a.scale > 0.0 {
        cfg.scale = a.scale;
    }
    if a.pixfrac > 0.0 {
        cfg.pixfrac = a.pixfrac;
    }
    cfg.kernel = match a.kernel.trim().to_ascii_lowercase().as_str() {
        "" | "square" => DrizzleKernel::Square,
        "point" => DrizzleKernel::Point,
        "gaussian" => DrizzleKernel::Gaussian,
        other => return Err(format!("unknown drizzle kernel '{other}'")),
    };
    Ok(cfg)
}

/// The FITS-header token for a drizzle kernel (for the `DRZKERN` provenance card).
fn kernel_name(kernel: DrizzleKernel) -> &'static str {
    match kernel {
        DrizzleKernel::Square => "square",
        DrizzleKernel::Point => "point",
        DrizzleKernel::Gaussian => "gaussian",
    }
}

/// Rebuild a [`TransformModel`] (source → reference) from a flat row-major
/// 9-element 3×3 matrix `[m00, m01, m02, m10, m11, m12, m20, m21, m22]`.
///
/// `kind` is purely informational on the native side (the warp uses the matrix
/// directly), so we tag a general matrix as [`TransformKind::Homography`]: it is
/// the only family whose bottom row is unconstrained, and reporting it as such
/// is honest about the most general matrix we accept.
fn transform_from_row_major(m: &[f64]) -> Result<TransformModel, String> {
    if m.len() != 9 {
        return Err(format!(
            "transform must be a row-major 3x3 (9 elements), got {}",
            m.len()
        ));
    }
    if !m.iter().all(|v| v.is_finite()) {
        return Err("transform contains a non-finite element".to_string());
    }
    let matrix = [[m[0], m[1], m[2]], [m[3], m[4], m[5]], [m[6], m[7], m[8]]];
    Ok(TransformModel {
        matrix,
        kind: TransformKind::Homography,
    })
}

/// Decode an [`ImageData`] (the linear masters / mosaics the pipeline emits,
/// `U16` and `F32`) into a flat channel-interleaved `f64` buffer.
///
/// Any other pixel type is a hard error: drizzle needs the real linear samples,
/// and silently producing an empty buffer would mis-size the integration.
fn decode_image_f64(image: &ImageData, path: &str) -> Result<Vec<f64>, String> {
    match image.pixel_type {
        PixelType::U16 => image
            .as_u16()
            .map(|v| v.into_iter().map(|x| x as f64).collect())
            .ok_or_else(|| format!("'{path}' could not be decoded as U16")),
        PixelType::F32 => image
            .as_f32()
            .map(|v| v.into_iter().map(|x| x as f64).collect())
            .ok_or_else(|| format!("'{path}' could not be decoded as F32")),
        other => Err(format!(
            "'{path}' is {other:?}; drizzle requires a U16 or F32 frame"
        )),
    }
}

// api_combine_channels implementation

fn combine_channels_impl(args: CombineChannelsArgs) -> Result<CombineChannelsResult, String> {
    if args.inputs.is_empty() {
        return Err("no input channels supplied to combine".to_string());
    }
    if args.output_fits.trim().is_empty() {
        return Err("outputFits is required".to_string());
    }

    // Read every single-channel master with its header. The images stay in this
    // owned vector so the `&[&ImageData]` slice `combine_channels` borrows stays
    // valid, and the first input's header supplies the composite's astrometry.
    let inputs: Vec<(ImageData, FitsHeader)> = args
        .inputs
        .iter()
        .map(|p| read_fits(Path::new(p)).map_err(|e| format!("failed to read '{p}': {e:?}")))
        .collect::<Result<_, _>>()?;
    let images: Vec<&ImageData> = inputs.iter().map(|(image, _)| image).collect();

    // Resolve the weight table: a named palette wins, else the explicit weights.
    let weights: Vec<[f64; 3]> = if let Some(palette) = args.palette.as_ref() {
        let p = palette.trim().to_ascii_lowercase();
        match p.as_str() {
            "sho" => {
                let w = sho_palette();
                if images.len() != w.len() {
                    return Err(format!(
                        "SHO palette expects {} inputs (S II, Hα, O III) but {} were supplied",
                        w.len(),
                        images.len()
                    ));
                }
                w
            }
            "hoo" => {
                let w = hoo_palette();
                if images.len() != w.len() {
                    return Err(format!(
                        "HOO palette expects {} inputs (Hα, O III) but {} were supplied",
                        w.len(),
                        images.len()
                    ));
                }
                w
            }
            other => return Err(format!("unknown palette '{other}'; expected sho or hoo")),
        }
    } else {
        match args.weights {
            Some(w) if !w.is_empty() => w,
            _ => return Err("either palette or a non-empty weights table is required".to_string()),
        }
    };

    let composite =
        combine_channels(&images, &weights).map_err(|e| format!("channel combine failed: {e}"))?;

    let out_path = Path::new(&args.output_fits);
    ensure_parent_dir(out_path)?;
    let mut header = FitsHeader::new();
    header.set_string("IMAGETYP", "MASTER_LIGHT");
    header.set_string("FRAMETYP", "MASTER");
    header.set_string("CALSTAT", "Skotiq channel combine");
    if let Some(palette) = args.palette.as_ref() {
        header.set_string("PALETTE", palette.trim());
    }
    header.add_history("Skotiq narrowband channel combination");
    // `combine_channels` has already rejected any input whose geometry differs
    // from the first, so every input shares one pixel grid and the first one's
    // astrometry describes the composite. Only astrometry is carried: FILTER,
    // EXPTIME and the sensor settings belong to one channel and would misstate
    // the composite. OBJECT is the exception — the whole point of a palette
    // combine is that every channel is the same target.
    let (_, first_header) = &inputs[0];
    let carried = copy_astrometry_headers(&mut header, first_header);
    if let Some(object) = first_header.get_string("OBJECT") {
        header.set_string("OBJECT", object);
    }
    header.add_history(&format!(
        "Carried {carried} astrometry cards from '{}'",
        args.inputs[0]
    ));
    write_fits(out_path, &composite, &header)
        .map_err(|e| format!("failed to write composite: {e:?}"))?;

    Ok(CombineChannelsResult {
        output_path: args.output_fits,
        width: composite.width,
        height: composite.height,
    })
}

// Shared helpers

/// Read an optional calibration master by path. Empty / `None` → `Ok(None)`.
///
/// Reads with [`read_fits`] (NOT the auto-debayering `read_image`): the drizzle
/// calibration runs on the raw, single-channel (Bayer) or RGB/mono sub geometry,
/// so the master must keep the same raw layout. Mirrors the `load_optional_master`
/// in [`crate::api::post_session`]; duplicated here so this module stays
/// self-contained (its sibling is private to that module).
fn load_optional_master(path: &Option<String>, label: &str) -> Result<Option<ImageData>, String> {
    match path {
        Some(p) if !p.trim().is_empty() => {
            let (image, _header) = read_fits(Path::new(p))
                .map_err(|e| format!("failed to read {label} master '{p}': {e:?}"))?;
            Ok(Some(image))
        }
        _ => Ok(None),
    }
}

/// Ensure the parent directory of `path` exists, creating it if necessary.
///
/// Mirrors the `ensure_parent_dir` in [`crate::api::post_session`]; duplicated
/// here so this module stays self-contained (its `pub(super)` sibling is private
/// to that module).
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
    use skotiq_imaging::{add_wcs_headers, WcsInfo};
    use std::path::PathBuf;

    /// A scratch directory that deletes itself when the test ends. Cleanup runs
    /// from `Drop`, so it happens even while a panic unwinds out of a failing test.
    struct TempDir(PathBuf);

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

    /// Deterministic scratch directory derived from the calling test's name (NO
    /// rng): the per-test name plus the process id keeps parallel runs from
    /// colliding while staying fully reproducible.
    fn temp_dir(name: &str) -> TempDir {
        let p = std::env::temp_dir().join(format!("ns_fc_{name}_{}", std::process::id()));
        std::fs::create_dir_all(&p).unwrap();
        TempDir(p)
    }

    /// A row-major 3x3 translation `[1,0,tx, 0,1,ty, 0,0,1]`, flattened to 9
    /// elements — a simple dither offset (source → reference).
    fn translate(tx: f64, ty: f64) -> Vec<f64> {
        vec![1.0, 0.0, tx, 0.0, 1.0, ty, 0.0, 0.0, 1.0]
    }

    /// Render a synthetic mono `F32` frame: a flat sky with a few injected
    /// Gaussian stars (so drizzle has structure, not just noise, to reconstruct).
    fn render_mono_f32(size: u32, stars: &[(f64, f64, f64)], background: f64) -> ImageData {
        let w = size as usize;
        let h = size as usize;
        let mut pixels = vec![background as f32; w * h];
        let sigma = 1.8f64;
        let two_sigma_sq = 2.0 * sigma * sigma;
        let radius = (sigma * 4.0).ceil() as i64;
        for &(sx, sy, peak) in stars {
            let cx = sx.round() as i64;
            let cy = sy.round() as i64;
            for dy in -radius..=radius {
                for dx in -radius..=radius {
                    let x = cx + dx;
                    let y = cy + dy;
                    if x < 0 || y < 0 || x as usize >= w || y as usize >= h {
                        continue;
                    }
                    let ddx = x as f64 - sx;
                    let ddy = y as f64 - sy;
                    let g = peak * (-(ddx * ddx + ddy * ddy) / two_sigma_sq).exp();
                    pixels[y as usize * w + x as usize] += g as f32;
                }
            }
        }
        ImageData::from_f32(size, size, 1, &pixels)
    }

    /// A handful of bright stars positioned for a `size`x`size` frame.
    fn drizzle_stars(size: f64) -> Vec<(f64, f64, f64)> {
        vec![
            (size * 0.25, size * 0.30, 12000.0),
            (size * 0.65, size * 0.25, 11000.0),
            (size * 0.45, size * 0.65, 13000.0),
            (size * 0.78, size * 0.70, 9000.0),
        ]
    }

    fn write_master(path: &Path, image: &ImageData) {
        let mut h = FitsHeader::new();
        h.set_string("IMAGETYP", "MASTER_LIGHT");
        write_fits(path, image, &h).expect("write synthetic master");
    }

    /// Write a synthetic single-channel CFA mosaic carrying a `BAYERPAT` header,
    /// so the Bayer-drizzle path can read its pattern back off disk.
    fn write_bayer_mosaic(path: &Path, image: &ImageData, pattern: &str) {
        let mut h = FitsHeader::new();
        h.set_string("IMAGETYP", "LIGHT");
        h.set_string("BAYERPAT", pattern);
        h.set_int("XBAYROFF", 0);
        h.set_int("YBAYROFF", 0);
        write_fits(path, image, &h).expect("write synthetic CFA mosaic");
    }

    // api_drizzle_integrate — RGB/mono warp path

    /// Two dithered mono frames drizzle onto a 2x grid: the output dims are
    /// `ceil(ref * scale)`, an `F32` master + coverage map land on disk, and the
    /// coverage is single-channel.
    #[test]
    fn drizzle_integrate_mono_round_trip() {
        let dir = temp_dir("drizzle_integrate_mono_round_trip");
        let size = 64u32;
        let ref_w = size;
        let ref_h = size;
        let stars = drizzle_stars(size as f64);

        let f0 = render_mono_f32(size, &stars, 200.0);
        // Second frame physically shifted; its transform maps it back to the ref.
        let shifted: Vec<(f64, f64, f64)> = stars
            .iter()
            .map(|&(x, y, p)| (x + 2.0, y - 1.0, p))
            .collect();
        let f1 = render_mono_f32(size, &shifted, 200.0);

        let p0 = dir.join("drizzle_integrate_mono_round_trip_f0.fits");
        let p1 = dir.join("drizzle_integrate_mono_round_trip_f1.fits");
        write_master(&p0, &f0);
        write_master(&p1, &f1);

        let out_path = dir.join("drizzle_integrate_mono_round_trip_out.fits");
        let cov_path = dir.join("drizzle_integrate_mono_round_trip_cov.fits");
        let cov_png_path = dir.join("drizzle_integrate_mono_round_trip_cov_preview.png");
        let png_path = dir.join("drizzle_integrate_mono_round_trip_prev.png");

        let scale = 2.0;
        let args = serde_json::json!({
            "frames": [
                { "fitsPath": p0.to_string_lossy(), "transform": translate(0.0, 0.0), "weight": 1.0 },
                // Source→reference transform undoes the +2,-1 dither.
                { "fitsPath": p1.to_string_lossy(), "transform": translate(-2.0, 1.0), "weight": 1.0 }
            ],
            "refW": ref_w,
            "refH": ref_h,
            "config": { "scale": scale, "pixfrac": 0.9, "kernel": "square" },
            "outputFits": out_path.to_string_lossy(),
            "coverageFits": cov_path.to_string_lossy(),
            "coveragePngPath": cov_png_path.to_string_lossy(),
            "previewPngPath": png_path.to_string_lossy()
        });

        let resp = api_drizzle_integrate(args.to_string()).expect("drizzle");
        let result: DrizzleIntegrateResult = serde_json::from_str(&resp).unwrap();

        // Output dims ~= ref * scale (ceil).
        assert_eq!(result.out_width, (ref_w as f64 * scale).ceil() as u32);
        assert_eq!(result.out_height, (ref_h as f64 * scale).ceil() as u32);
        assert_eq!(result.channels, 1, "mono warp stays single-channel");
        assert_eq!(
            result.coverage_path.as_deref(),
            Some(cov_path.to_string_lossy().as_ref())
        );
        assert_eq!(
            result.coverage_png_path.as_deref(),
            Some(cov_png_path.to_string_lossy().as_ref())
        );
        // The drizzled master's stretched preview PNG was written and surfaced.
        assert_eq!(
            result.preview_png_path.as_deref(),
            Some(png_path.to_string_lossy().as_ref())
        );
        assert!(out_path.exists(), "drizzle master must be on disk");
        assert!(cov_path.exists(), "coverage map must be on disk");
        assert!(cov_png_path.exists(), "coverage preview must be on disk");
        assert!(png_path.exists(), "drizzle preview PNG must be on disk");

        let (master, _h) = read_fits(out_path.as_path()).expect("read drizzle master");
        assert_eq!(master.pixel_type, PixelType::F32);
        assert_eq!(master.width, result.out_width);
        assert_eq!(master.channels, 1);
        let (cov, _hc) = read_fits(cov_path.as_path()).expect("read coverage map");
        assert_eq!(cov.channels, 1, "coverage is a single-channel map");
        // The preview decodes as an 8-bit image of the scaled master geometry.
        let preview = image::open(&png_path).expect("decode drizzle preview");
        assert_eq!(preview.width(), result.out_width);
        assert_eq!(preview.height(), result.out_height);
        let coverage_preview = image::open(&cov_png_path).expect("decode coverage preview");
        assert_eq!(coverage_preview.width(), result.out_width);
        assert_eq!(coverage_preview.height(), result.out_height);
    }

    // api_drizzle_integrate — calibration contract

    /// A uniform `F32` field of `value`, single-channel `size`x`size`. Flat
    /// fields make the drizzle interior trivially predictable (`flux/weight`
    /// resolves a flat input to that same value), so calibration arithmetic is
    /// verifiable cell-by-cell.
    fn render_uniform_f32(size: u32, value: f32) -> ImageData {
        let n = (size * size) as usize;
        ImageData::from_f32(size, size, 1, &vec![value; n])
    }

    /// A two-region `F32` field: rows `[0, size/2)` hold `top`, the rest `bottom`.
    /// Lets a non-uniform flat be shown to correct each region differently.
    fn render_split_f32(size: u32, top: f32, bottom: f32) -> ImageData {
        let w = size as usize;
        let h = size as usize;
        let mut px = vec![0f32; w * h];
        for y in 0..h {
            let v = if y < h / 2 { top } else { bottom };
            for x in 0..w {
                px[y * w + x] = v;
            }
        }
        ImageData::from_f32(size, size, 1, &px)
    }

    /// Mean of the interior cells in a row band `[y0, y1)` of a single-channel
    /// `F32` master, away from the drizzle border (which loses some coverage).
    fn interior_band_mean(master: &ImageData, y0: usize, y1: usize) -> f64 {
        let w = master.width as usize;
        let px = master.as_f32().expect("master is F32");
        let margin = 4usize;
        let mut sum = 0.0f64;
        let mut count = 0u64;
        for y in y0..y1 {
            for x in margin..(w - margin) {
                sum += px[y * w + x] as f64;
                count += 1;
            }
        }
        assert!(count > 0, "interior band must contain cells");
        sum / count as f64
    }

    /// With a `calibration` block, drizzle calibrates every (raw) sub —
    /// dark/flat/bias — before depositing drops, so the drizzled master
    /// `_runDrizzle` swaps in as canonical is calibrated, not a raw deposit. The
    /// same input drizzled without the block is the raw reference: the two
    /// masters must differ exactly by the dark pedestal and the
    /// region-dependent flat.
    #[test]
    fn drizzle_calibration_removes_pedestal_and_applies_flat() {
        let dir = temp_dir("drizzle_calibration_removes_pedestal_and_applies_flat");
        let size = 64u32;

        // Uniform light: a flat sky at 1000 (no stars — interior is predictable).
        let light = render_uniform_f32(size, 1000.0);
        // Dark: a 200-count pedestal to be subtracted from every pixel.
        let dark = render_uniform_f32(size, 200.0);
        // Flat: top half 2.0, bottom half 1.0 ⇒ mean 1.5; normalized flat is
        // 1.3333 (top) / 0.6667 (bottom), so the dark-subtracted 800 becomes
        // 800/1.3333 ≈ 600 (top) and 800/0.6667 ≈ 1200 (bottom).
        let flat = render_split_f32(size, 2.0, 1.0);

        let light_path = dir.join("drizzle_cal_light.fits");
        let dark_path = dir.join("drizzle_cal_dark.fits");
        let flat_path = dir.join("drizzle_cal_flat.fits");
        write_master(&light_path, &light);
        write_master(&dark_path, &dark);
        write_master(&flat_path, &flat);

        let raw_out = dir.join("drizzle_cal_raw_out.fits");
        let cal_out = dir.join("drizzle_cal_cal_out.fits");

        // Two identical subs, identity transforms ⇒ full interior coverage.
        let frames = serde_json::json!([
            { "fitsPath": light_path.to_string_lossy(), "transform": translate(0.0, 0.0), "weight": 1.0 },
            { "fitsPath": light_path.to_string_lossy(), "transform": translate(0.0, 0.0), "weight": 1.0 }
        ]);

        // Raw deposit (no calibration block) — the historical behaviour.
        let raw_args = serde_json::json!({
            "frames": frames,
            "refW": size,
            "refH": size,
            "config": { "scale": 2.0, "pixfrac": 1.0, "kernel": "square" },
            "outputFits": raw_out.to_string_lossy()
        });
        let raw_resp = api_drizzle_integrate(raw_args.to_string()).expect("raw drizzle");
        let _: DrizzleIntegrateResult = serde_json::from_str(&raw_resp).unwrap();

        // Calibrated deposit — dark + flat applied per sub before depositing.
        let cal_args = serde_json::json!({
            "frames": frames,
            "refW": size,
            "refH": size,
            "calibration": {
                "dark": dark_path.to_string_lossy(),
                "flat": flat_path.to_string_lossy()
            },
            "config": { "scale": 2.0, "pixfrac": 1.0, "kernel": "square" },
            "outputFits": cal_out.to_string_lossy()
        });
        let cal_resp = api_drizzle_integrate(cal_args.to_string()).expect("calibrated drizzle");
        let _: DrizzleIntegrateResult = serde_json::from_str(&cal_resp).unwrap();

        let (raw_master, _h0) = read_fits(raw_out.as_path()).expect("read raw master");
        let (cal_master, _h1) = read_fits(cal_out.as_path()).expect("read calibrated master");

        let out_h = raw_master.height as usize;
        // Sample bands well inside each region (away from the half-split seam and
        // the drizzle border).
        let top_lo = out_h / 8;
        let top_hi = out_h * 3 / 8;
        let bot_lo = out_h * 5 / 8;
        let bot_hi = out_h * 7 / 8;

        // Raw drizzle reconstructs the uncalibrated sky (~1000) in BOTH bands.
        let raw_top = interior_band_mean(&raw_master, top_lo, top_hi);
        let raw_bot = interior_band_mean(&raw_master, bot_lo, bot_hi);
        assert!(
            (raw_top - 1000.0).abs() < 1.0,
            "raw top band ~= 1000, got {raw_top}"
        );
        assert!(
            (raw_bot - 1000.0).abs() < 1.0,
            "raw bottom band ~= 1000, got {raw_bot}"
        );

        // Calibrated drizzle removed the 200 pedestal and applied the non-uniform
        // flat: top ~600, bottom ~1200 — provably different from the raw deposit.
        let cal_top = interior_band_mean(&cal_master, top_lo, top_hi);
        let cal_bot = interior_band_mean(&cal_master, bot_lo, bot_hi);
        assert!(
            (cal_top - 600.0).abs() < 1.0,
            "calibrated top band ~= 600, got {cal_top}"
        );
        assert!(
            (cal_bot - 1200.0).abs() < 1.0,
            "calibrated bottom band ~= 1200, got {cal_bot}"
        );

        // The decisive guard: the calibrated master is NOT the raw deposit,
        // which is the silent-corruption symptom.
        assert!(
            (cal_top - raw_top).abs() > 100.0 && (cal_bot - raw_bot).abs() > 100.0,
            "calibrated master must differ from the raw deposit (cal_top={cal_top} \
             raw_top={raw_top} cal_bot={cal_bot} raw_bot={raw_bot})"
        );
    }

    /// Preview-PNG write failures must not abort the (expensive) drizzle run —
    /// the master + coverage FITS are the real outputs. Point both cosmetic
    /// previews at unwritable paths and assert the real artifacts survive.
    #[test]
    fn drizzle_preview_failure_still_returns_master() {
        let dir = temp_dir("drizzle_preview_failure_still_returns_master");
        let size = 32u32;
        let stars = drizzle_stars(size as f64);
        let frame = render_mono_f32(size, &stars, 200.0);
        let fp = dir.join("drizzle_preview_fail_frame.fits");
        write_master(&fp, &frame);

        let out_path = dir.join("drizzle_preview_fail_out.fits");
        let cov_path = dir.join("drizzle_preview_fail_cov.fits");

        // A "file" we create, then ask the preview to be written *underneath* as
        // if it were a directory: `<blocker>/preview.png`. `ensure_parent_dir`
        // (via write_preview_png) must `create_dir_all("<blocker>")`, which fails
        // because `<blocker>` already exists as a regular file — a deterministic,
        // platform-independent write failure.
        let blocker = dir.join("drizzle_preview_fail_blocker.dat");
        std::fs::write(&blocker, b"not a directory").expect("create blocker file");
        let bad_preview = blocker.join("preview.png");
        let bad_coverage_preview = blocker.join("coverage.png");

        let args = serde_json::json!({
            "frames": [
                { "fitsPath": fp.to_string_lossy(), "transform": translate(0.0, 0.0), "weight": 1.0 }
            ],
            "refW": size,
            "refH": size,
            "config": { "scale": 2.0 },
            "outputFits": out_path.to_string_lossy(),
            "coverageFits": cov_path.to_string_lossy(),
            "coveragePngPath": bad_coverage_preview.to_string_lossy(),
            "previewPngPath": bad_preview.to_string_lossy()
        });

        let resp = api_drizzle_integrate(args.to_string())
            .expect("a failing preview write must NOT abort the drizzle run");
        let result: DrizzleIntegrateResult = serde_json::from_str(&resp).unwrap();

        // The real outputs landed; the preview was best-effort skipped.
        assert!(out_path.exists(), "master must still be on disk");
        assert!(cov_path.exists(), "coverage must still be on disk");
        assert_eq!(
            result.preview_png_path, None,
            "a failed preview write surfaces as no preview, not an aborted run"
        );
        assert_eq!(
            result.coverage_png_path, None,
            "a failed coverage preview preserves the scientific coverage FITS"
        );
    }

    // api_drizzle_integrate — Bayer (CFA) path

    /// Two dithered raw single-channel CFA mosaics (with `BAYERPAT` headers)
    /// Bayer-drizzle into a 3-channel RGB master of the scaled dimensions.
    #[test]
    fn drizzle_integrate_bayer_round_trip() {
        let dir = temp_dir("drizzle_integrate_bayer_round_trip");
        let size = 64u32;
        let w = size as usize;
        let h = size as usize;
        let ref_w = size;
        let ref_h = size;

        // A plain gradient mosaic — Bayer drizzle bins by CFA colour, so any
        // non-degenerate single-channel buffer exercises the path.
        let mosaic = |shift: f32| -> ImageData {
            let mut px = vec![0f32; w * h];
            for y in 0..h {
                for x in 0..w {
                    px[y * w + x] = 1000.0 + 3.0 * x as f32 + 2.0 * y as f32 + shift;
                }
            }
            ImageData::from_f32(size, size, 1, &px)
        };

        let p0 = dir.join("drizzle_integrate_bayer_round_trip_f0.fits");
        let p1 = dir.join("drizzle_integrate_bayer_round_trip_f1.fits");
        write_bayer_mosaic(&p0, &mosaic(0.0), "RGGB");
        write_bayer_mosaic(&p1, &mosaic(5.0), "RGGB");

        let out_path = dir.join("drizzle_integrate_bayer_round_trip_out.fits");
        let scale = 2.0;
        let args = serde_json::json!({
            "frames": [
                { "fitsPath": p0.to_string_lossy(), "transform": translate(0.0, 0.0), "weight": 1.0 },
                { "fitsPath": p1.to_string_lossy(), "transform": translate(2.0, 2.0), "weight": 1.0 }
            ],
            "refW": ref_w,
            "refH": ref_h,
            "bayer": true,
            "config": { "scale": scale },
            "outputFits": out_path.to_string_lossy()
        });

        let resp = api_drizzle_integrate(args.to_string()).expect("bayer drizzle");
        let result: DrizzleIntegrateResult = serde_json::from_str(&resp).unwrap();

        assert_eq!(
            result.channels, 3,
            "Bayer drizzle always yields a 3-channel RGB master"
        );
        assert_eq!(result.out_width, (ref_w as f64 * scale).ceil() as u32);
        assert_eq!(result.out_height, (ref_h as f64 * scale).ceil() as u32);
        assert!(result.coverage_path.is_none(), "no coverage requested");
        assert!(result.preview_png_path.is_none(), "no preview requested");

        let (master, _h) = read_fits(out_path.as_path()).expect("read bayer drizzle master");
        assert_eq!(master.pixel_type, PixelType::F32);
        assert_eq!(master.channels, 3);
    }

    // api_combine_channels

    /// Three single-channel masters combine through the SHO palette into a
    /// 3-channel `F32` composite of the shared geometry.
    #[test]
    fn combine_channels_sho_round_trip() {
        let dir = temp_dir("combine_channels_sho_round_trip");
        let size = 32u32;
        let len = (size * size) as usize;
        // Distinct flat single-channel masters so each output channel is traceable.
        let make = |level: f32| -> ImageData {
            let data: Vec<f32> = (0..len).map(|i| level + (i % 5) as f32 * 0.5).collect();
            ImageData::from_f32(size, size, 1, &data)
        };
        let s_path = dir.join("combine_channels_sho_round_trip_s.fits");
        let ha_path = dir.join("combine_channels_sho_round_trip_ha.fits");
        let o_path = dir.join("combine_channels_sho_round_trip_o.fits");
        write_master(&s_path, &make(100.0));
        write_master(&ha_path, &make(200.0));
        write_master(&o_path, &make(300.0));

        let out_path = dir.join("combine_channels_sho_round_trip_out.fits");
        let args = serde_json::json!({
            "inputs": [
                s_path.to_string_lossy(),
                ha_path.to_string_lossy(),
                o_path.to_string_lossy()
            ],
            "palette": "sho",
            "outputFits": out_path.to_string_lossy()
        });

        let resp = api_combine_channels(args.to_string()).expect("combine sho");
        let result: CombineChannelsResult = serde_json::from_str(&resp).unwrap();
        assert_eq!(result.width, size);
        assert_eq!(result.height, size);
        assert!(out_path.exists(), "composite must be on disk");

        // The composite is a real, readable 3-channel F32 FITS of the same geometry.
        let (img, _h) = read_fits(out_path.as_path()).expect("read composite");
        assert_eq!(img.pixel_type, PixelType::F32);
        assert_eq!(img.width, size);
        assert_eq!(img.height, size);
        assert_eq!(img.channels, 3, "narrowband composite has three channels");
    }

    /// Explicit per-input `[r,g,b]` weights also produce a 3-channel composite.
    #[test]
    fn combine_channels_explicit_weights_round_trip() {
        let dir = temp_dir("combine_channels_explicit_weights_round_trip");
        let size = 24u32;
        let len = (size * size) as usize;
        let data: Vec<f32> = (0..len).map(|i| 50.0 + i as f32 * 0.1).collect();
        let a = ImageData::from_f32(size, size, 1, &data);
        let b = ImageData::from_f32(size, size, 1, &data);
        let a_path = dir.join("combine_channels_explicit_weights_round_trip_a.fits");
        let b_path = dir.join("combine_channels_explicit_weights_round_trip_b.fits");
        write_master(&a_path, &a);
        write_master(&b_path, &b);

        let out_path = dir.join("combine_channels_explicit_weights_round_trip_out.fits");
        let args = serde_json::json!({
            "inputs": [a_path.to_string_lossy(), b_path.to_string_lossy()],
            "weights": [[1.0, 0.0, 0.0], [0.0, 1.0, 1.0]],
            "outputFits": out_path.to_string_lossy()
        });
        let resp = api_combine_channels(args.to_string()).expect("combine explicit");
        let result: CombineChannelsResult = serde_json::from_str(&resp).unwrap();
        assert_eq!(result.width, size);
        let (img, _h) = read_fits(out_path.as_path()).expect("read composite");
        assert_eq!(img.channels, 3);
    }

    // Error paths

    /// Malformed JSON, empty populations, a nonexistent input frame, a bad
    /// transform, a missing Bayer header, and mismatched combine geometry all
    /// surface as `Err` — never a silent partial stack.
    #[test]
    fn combine_error_paths() {
        let dir = temp_dir("combine_error_paths");
        // Malformed JSON.
        assert!(api_drizzle_integrate("not json".to_string()).is_err());
        assert!(api_combine_channels("not json".to_string()).is_err());

        // Empty frame population / no inputs.
        assert!(api_drizzle_integrate(
            r#"{"frames":[],"refW":10,"refH":10,"outputFits":"x.fits"}"#.to_string()
        )
        .is_err());
        assert!(api_combine_channels(
            r#"{"inputs":[],"palette":"sho","outputFits":"x.fits"}"#.to_string()
        )
        .is_err());

        // Nonexistent input frame to drizzle.
        let missing = dir.join("combine_error_paths_missing.fits");
        let out = dir.join("combine_error_paths_out.fits");
        let nonexistent = serde_json::json!({
            "frames": [
                { "fitsPath": missing.to_string_lossy(), "transform": translate(0.0, 0.0), "weight": 1.0 }
            ],
            "refW": 16,
            "refH": 16,
            "outputFits": out.to_string_lossy()
        });
        assert!(
            api_drizzle_integrate(nonexistent.to_string()).is_err(),
            "a nonexistent drizzle frame must error"
        );

        // A real frame but a malformed (non-9-element) transform.
        let size = 16u32;
        let frame = render_mono_f32(size, &drizzle_stars(size as f64), 100.0);
        let fp = dir.join("combine_error_paths_frame.fits");
        write_master(&fp, &frame);
        let bad_transform = serde_json::json!({
            "frames": [ { "fitsPath": fp.to_string_lossy(), "transform": [1.0, 0.0, 0.0], "weight": 1.0 } ],
            "refW": size, "refH": size,
            "outputFits": out.to_string_lossy()
        });
        assert!(
            api_drizzle_integrate(bad_transform.to_string()).is_err(),
            "a non-9-element transform must error"
        );

        // Bayer mode against a frame with NO BAYERPAT header is rejected.
        let no_bayer = serde_json::json!({
            "frames": [ { "fitsPath": fp.to_string_lossy(), "transform": translate(0.0, 0.0), "weight": 1.0 } ],
            "refW": size, "refH": size, "bayer": true,
            "outputFits": out.to_string_lossy()
        });
        assert!(
            api_drizzle_integrate(no_bayer.to_string()).is_err(),
            "Bayer mode without a CFA header must error"
        );

        // combine_channels with mismatched input geometry is rejected.
        let big = ImageData::from_f32(8, 8, 1, &[1.0f32; 64]);
        let small = ImageData::from_f32(4, 4, 1, &[1.0f32; 16]);
        let big_path = dir.join("combine_error_paths_big.fits");
        let small_path = dir.join("combine_error_paths_small.fits");
        write_master(&big_path, &big);
        write_master(&small_path, &small);
        let mismatch = serde_json::json!({
            "inputs": [big_path.to_string_lossy(), small_path.to_string_lossy()],
            "weights": [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
            "outputFits": out.to_string_lossy()
        });
        assert!(
            api_combine_channels(mismatch.to_string()).is_err(),
            "mismatched combine geometry must error"
        );
    }

    // WCS carry-over

    /// The palette composite must carry the astrometry of the channels it was
    /// built from — every input shares one grid by construction (a geometry
    /// mismatch is already a hard error), so the first input's solve describes
    /// the composite exactly. Per-channel identity (`FILTER`, `EXPTIME`) is
    /// deliberately NOT carried: it would describe one channel and misstate the
    /// composite.
    #[test]
    fn combine_channels_carries_astrometry_but_not_per_channel_identity() {
        let size = 24u32;
        let dir = temp_dir("combine_wcs");
        let wcs = WcsInfo::from_plate_solve(299.8681, 40.7339, 5.0, 1.2, size, size);

        let mut inputs = Vec::new();
        for (i, filter) in ["Ha", "OIII"].iter().enumerate() {
            let data: Vec<f32> = vec![100.0 + i as f32 * 10.0; (size * size) as usize];
            let plane = ImageData::from_f32(size, size, 1, &data);
            let path = dir.join(format!("chan{i}.fits"));
            let mut h = FitsHeader::new();
            h.set_string("IMAGETYP", "MASTER_LIGHT");
            add_wcs_headers(&mut h, &wcs);
            h.set_string("OBJECT", "NGC 6960");
            h.set_string("FILTER", filter);
            h.set_float("EXPTIME", 3600.0 + i as f64 * 600.0);
            write_fits(path.as_path(), &plane, &h).expect("write channel master");
            inputs.push(path.to_string_lossy().to_string());
        }

        let out_path = dir.join("hoo.fits");
        let args = serde_json::json!({
            "inputs": inputs,
            "palette": "hoo",
            "outputFits": out_path.to_string_lossy()
        });
        api_combine_channels(args.to_string()).expect("combine");

        let (img, out) = read_fits(out_path.as_path()).expect("read composite");
        assert_eq!(img.channels, 3);
        for key in ["CRVAL1", "CRVAL2", "CRPIX1", "CRPIX2", "CD1_1", "CD2_2"] {
            let want = match key {
                "CRVAL1" => wcs.crval1,
                "CRVAL2" => wcs.crval2,
                "CRPIX1" => wcs.crpix1,
                "CRPIX2" => wcs.crpix2,
                "CD1_1" => wcs.cd1_1,
                _ => wcs.cd2_2,
            };
            let got = out
                .get_float(key)
                .unwrap_or_else(|| panic!("composite dropped {key}"));
            assert!(
                (got - want).abs() <= want.abs() * 1e-9 + 1e-15,
                "{key}: composite {got} != input {want}"
            );
        }
        assert_eq!(out.get_string("CTYPE1"), Some("RA---TAN"));
        assert_eq!(
            out.get_string("OBJECT"),
            Some("NGC 6960"),
            "every channel is the same target, so OBJECT is the composite's too"
        );
        assert_eq!(
            out.get_string("FILTER"),
            None,
            "one channel's filter must not be claimed for the composite"
        );
        assert_eq!(
            out.get_float("EXPTIME"),
            None,
            "one channel's exposure must not be claimed for the composite"
        );
    }
}
