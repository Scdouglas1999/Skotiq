//! Post-session *enhancement* FFI surface — background extraction, deconvolution
//! preview, and star-size reduction preview.
//!
//! This module is the JSON-in / JSON-out bridge for the committed native
//! "finishing" passes that run *after* a master is integrated:
//! `skotiq_imaging::{background_extraction, deconvolution, star_reduction}`.
//! It mirrors [`crate::api::post_session`] exactly — the same **minimal**
//! `String -> Result<String, String>` boundary, the same
//! `#[flutter_rust_bridge::frb(ignore)]` serde DTOs that ride *inside* the JSON
//! payload so new knobs never trigger another FRB regen, and the same failure
//! contract: every failure (unreadable frame, too-few-stars, malformed PSF,
//! write failure) surfaces as `Err(String)`, never a silent degraded preview.
//!
//! The boundary is exactly three `pub fn`:
//!
//! * [`api_extract_background`] — fit a star-masked low-order polynomial
//!   background model and write the flattened linear frame.
//! * [`api_deconvolve_preview`] — estimate (or accept) a PSF and run bounded,
//!   regularized Richardson–Lucy, writing the restored frame.
//! * [`api_reduce_stars_preview`] — mask-confined morphological / screened
//!   residual star-size reduction, writing the reduced frame.
//!
//! These are **stateless per call** (no process-wide singleton), CPU-bound, and
//! synchronous; the Dart side runs them off the UI isolate. Masters that are
//! linear (the background-flattened frame) are written as `F32`; the
//! deconvolution and star-reduction passes preserve the source pixel type since
//! they already return a same-layout frame.

use serde::{Deserialize, Serialize};
use skotiq_imaging::background_extraction::{self, BackgroundConfig};
use skotiq_imaging::deconvolution::{self, DeconvConfig, PsfEstimateConfig, PsfKind, PsfModel};
use skotiq_imaging::star_reduction::{self, StarReduceMethod, StarReductionConfig};
use skotiq_imaging::{
    carry_source_header, read_fits, write_fits, FitsHeader, ImageData, PixelType,
};
use std::path::Path;

// Public FFI entry points

/// Fit a star-masked, low-order polynomial background model and write the
/// background-subtracted (flattened) frame as a linear `F32` FITS master.
///
/// `args_json` is an [`ExtractBackgroundArgs`]; the result is an
/// [`ExtractBackgroundResult`] carrying the fitted polynomial degree, channel
/// count, and per-channel mean level (the pedestal preserved when
/// `preserveMean` is set). Wraps
/// [`background_extraction::extract_and_subtract`]. Every failure — unreadable
/// input, an empty frame, an unsupported polynomial degree, too few clean
/// background samples, a singular fit, or a write error — surfaces as
/// `Err(String)`.
pub fn api_extract_background(args_json: String) -> Result<String, String> {
    let args: ExtractBackgroundArgs =
        serde_json::from_str(&args_json).map_err(|e| format!("invalid background args: {e}"))?;
    let result = extract_background_impl(args)?;
    serde_json::to_string(&result).map_err(|e| format!("failed to encode result: {e}"))
}

/// Estimate (or accept) a PSF and run bounded, regularized Richardson–Lucy
/// deconvolution, writing the restored frame.
///
/// `args_json` is a [`DeconvolvePreviewArgs`]; the result is a
/// [`DeconvolvePreviewResult`] reporting the PSF actually used (kind, FWHM,
/// Moffat β, kernel side). When `estimatePsf` is true (the default) the PSF is
/// derived from the frame's own stars via [`deconvolution::estimate_psf`];
/// otherwise a [`PsfModel`] is rendered from the supplied analytic parameters.
/// Wraps [`deconvolution::richardson_lucy`]. The output preserves the input
/// pixel type. Every failure — unreadable input, an empty frame, too few usable
/// stars for estimation, a malformed PSF, or a write error — surfaces as
/// `Err(String)`.
pub fn api_deconvolve_preview(args_json: String) -> Result<String, String> {
    let args: DeconvolvePreviewArgs =
        serde_json::from_str(&args_json).map_err(|e| format!("invalid deconvolve args: {e}"))?;
    let result = deconvolve_preview_impl(args)?;
    serde_json::to_string(&result).map_err(|e| format!("failed to encode result: {e}"))
}

/// Mask-confined star-size reduction preview, writing the reduced frame.
///
/// `args_json` is a [`ReduceStarsPreviewArgs`]; the result is a
/// [`ReduceStarsPreviewResult`] with the output path. Wraps
/// [`star_reduction::reduce_stars`] (morphological erosion or screened
/// residual, confined to a soft star mask that leaves the background
/// byte-identical). The output preserves the input pixel type. Every failure —
/// unreadable input, an empty frame, an out-of-range strength, or a write
/// error — surfaces as `Err(String)`.
pub fn api_reduce_stars_preview(args_json: String) -> Result<String, String> {
    let args: ReduceStarsPreviewArgs =
        serde_json::from_str(&args_json).map_err(|e| format!("invalid reduce-stars args: {e}"))?;
    let result = reduce_stars_preview_impl(args)?;
    serde_json::to_string(&result).map_err(|e| format!("failed to encode result: {e}"))
}

// api_extract_background

/// Tunables for [`api_extract_background`] (subset of [`BackgroundConfig`]).
/// Each unset field keeps the production [`BackgroundConfig::default`] value.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct BackgroundConfigArgs {
    /// Sample boxes per axis (`grid × grid`). `None`/0 ⇒ default (24).
    grid: Option<usize>,
    /// Fitted polynomial degree (`0..=6`). `None` ⇒ default (4).
    poly_degree: Option<usize>,
    /// Square sample-box side in px. `None`/0 ⇒ default (15).
    sample_box: Option<usize>,
    /// Lower sigma-clip threshold. `None` ⇒ default (3.0).
    sigma_low: Option<f64>,
    /// Upper sigma-clip threshold. `None` ⇒ default (2.0).
    sigma_high: Option<f64>,
    /// Add the model's mean back on subtraction (remove gradient only).
    /// `None` ⇒ default (true).
    preserve_mean: Option<bool>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct ExtractBackgroundArgs {
    /// Input FITS path (required).
    input_fits: String,
    /// Output FITS path for the flattened `F32` frame (required).
    output_fits: String,
    /// Optional background-extraction overrides.
    config: BackgroundConfigArgs,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct ExtractBackgroundResult {
    output_path: String,
    /// Fitted polynomial degree.
    degree: usize,
    channels: u32,
    /// Per-channel mean level of the fitted surface (the preserved pedestal).
    mean_level: Vec<f64>,
}

fn extract_background_impl(args: ExtractBackgroundArgs) -> Result<ExtractBackgroundResult, String> {
    if args.input_fits.trim().is_empty() {
        return Err("inputFits is required".to_string());
    }
    if args.output_fits.trim().is_empty() {
        return Err("outputFits is required".to_string());
    }

    let (image, source_header) = read_fits(Path::new(&args.input_fits))
        .map_err(|e| format!("failed to read '{}': {e:?}", args.input_fits))?;

    // Build the config from defaults, overriding only the fields the caller set.
    let defaults = BackgroundConfig::default();
    let cfg = BackgroundConfig {
        grid: args.config.grid.filter(|&v| v > 0).unwrap_or(defaults.grid),
        poly_degree: args.config.poly_degree.unwrap_or(defaults.poly_degree),
        sample_box: args
            .config
            .sample_box
            .filter(|&v| v > 0)
            .unwrap_or(defaults.sample_box),
        sigma_low: args.config.sigma_low.unwrap_or(defaults.sigma_low),
        sigma_high: args.config.sigma_high.unwrap_or(defaults.sigma_high),
        preserve_mean: args.config.preserve_mean.unwrap_or(defaults.preserve_mean),
    };

    let (flattened, model) = background_extraction::extract_and_subtract(&image, &cfg)
        .map_err(|e| format!("background extraction failed: {e}"))?;

    // The flattened frame is linear: write it as an F32 master.
    let out_image = to_f32(&flattened);
    let out_path = Path::new(&args.output_fits);
    ensure_parent_dir(out_path)?;
    let mut header = FitsHeader::new();
    header.set_string("IMAGETYP", "MASTER_LIGHT");
    header.set_string("CALSTAT", "Skotiq background-extracted");
    header.set_int("BGDEGREE", model.degree as i64);
    // Background extraction rewrites pixel values on the input's own grid, so
    // the input's astrometry describes this output unchanged.
    carry_source_header(&mut header, &source_header);
    write_fits(out_path, &out_image, &header)
        .map_err(|e| format!("failed to write background-extracted FITS: {e:?}"))?;

    Ok(ExtractBackgroundResult {
        output_path: args.output_fits,
        degree: model.degree,
        channels: model.channels,
        mean_level: model.mean_level,
    })
}

// api_deconvolve_preview

/// PSF parameters supplied when `estimatePsf` is false. The bridge renders a
/// sum-normalized kernel from these so [`deconvolution::richardson_lucy`] can
/// run without sampling the frame's stars.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct PsfArgs {
    /// `"empirical"` | `"moffat"` | `"gaussian"`. Empirical cannot be rendered
    /// from parameters, so it is treated as Gaussian when provided here.
    kind: String,
    /// Full-width-half-maximum in px (required for a rendered PSF).
    fwhm: f64,
    /// Moffat wing steepness `β` (used only for the Moffat kind).
    beta: f64,
    /// Kernel side length in px (forced odd, floored at 5).
    size: usize,
}

/// Richardson–Lucy knobs (subset of [`DeconvConfig`]). Each unset field keeps
/// the production [`DeconvConfig::default`] value.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct DeconvConfigArgs {
    /// RL iteration count. `None`/0 ⇒ default (30).
    iterations: Option<usize>,
    /// Total-variation regularization strength `λ`. `None` ⇒ default (0.01).
    regularization: Option<f64>,
    /// Protect saturated star cores from RL ringing. `None` ⇒ default (true).
    star_protect: Option<bool>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct DeconvolvePreviewArgs {
    /// Input FITS path (required).
    input_fits: String,
    /// Output FITS path (required).
    output_fits: String,
    /// Estimate the PSF from the frame's own stars (default true). When false,
    /// `psf` must supply analytic parameters.
    estimate_psf: bool,
    /// Analytic PSF parameters, used only when `estimatePsf` is false.
    psf: PsfArgs,
    /// Optional Richardson–Lucy overrides.
    config: DeconvConfigArgs,
}

impl Default for DeconvolvePreviewArgs {
    fn default() -> Self {
        Self {
            input_fits: String::new(),
            output_fits: String::new(),
            estimate_psf: true,
            psf: PsfArgs::default(),
            config: DeconvConfigArgs::default(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct PsfReport {
    /// `"empirical"` | `"moffat"` | `"gaussian"`.
    kind: String,
    fwhm: f64,
    /// Moffat `β`; `0.0` for the Gaussian/empirical kinds.
    beta: f64,
    /// Kernel side length (odd) in px.
    size: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct DeconvolvePreviewResult {
    output_path: String,
    /// The PSF actually used for the deconvolution.
    psf: PsfReport,
}

fn deconvolve_preview_impl(args: DeconvolvePreviewArgs) -> Result<DeconvolvePreviewResult, String> {
    if args.input_fits.trim().is_empty() {
        return Err("inputFits is required".to_string());
    }
    if args.output_fits.trim().is_empty() {
        return Err("outputFits is required".to_string());
    }

    let (image, header) = read_fits(Path::new(&args.input_fits))
        .map_err(|e| format!("failed to read '{}': {e:?}", args.input_fits))?;

    // Resolve the PSF: estimate from the frame's stars, or render from the
    // supplied analytic parameters.
    let psf: PsfModel = if args.estimate_psf {
        let psf_cfg = PsfEstimateConfig::default();
        deconvolution::estimate_psf(&image, &psf_cfg)
            .map_err(|e| format!("PSF estimation failed: {e}"))?
    } else {
        build_psf_model(&args.psf)?
    };

    // Build the RL config from defaults, overriding only the supplied fields.
    let defaults = DeconvConfig::default();
    let cfg = DeconvConfig {
        iterations: args
            .config
            .iterations
            .filter(|&v| v > 0)
            .unwrap_or(defaults.iterations),
        regularization: args
            .config
            .regularization
            .unwrap_or(defaults.regularization),
        star_protect: args.config.star_protect.unwrap_or(defaults.star_protect),
    };

    let restored = deconvolution::richardson_lucy(&image, &psf, &cfg)
        .map_err(|e| format!("deconvolution failed: {e}"))?;

    // The restored frame keeps the source pixel type and the source grid, so the
    // input's astrometry and observation identity carry straight through.
    let out_path = Path::new(&args.output_fits);
    ensure_parent_dir(out_path)?;
    let mut out_header = FitsHeader::new();
    out_header.set_string("IMAGETYP", "MASTER_LIGHT");
    out_header.set_string("CALSTAT", "Skotiq deconvolution preview");
    out_header.set_float("PSFFWHM", psf.fwhm);
    carry_source_header(&mut out_header, &header);
    write_fits(out_path, &restored, &out_header)
        .map_err(|e| format!("failed to write deconvolved FITS: {e:?}"))?;

    Ok(DeconvolvePreviewResult {
        output_path: args.output_fits,
        psf: PsfReport {
            kind: psf_kind_str(psf.kind).to_string(),
            fwhm: psf.fwhm,
            beta: psf.beta,
            size: psf.size,
        },
    })
}

/// Render a sum-normalized [`PsfModel`] from caller-supplied analytic
/// parameters. `empirical` is not renderable from parameters (it *is* the
/// stacked star core), so a caller asking for it without estimation is served a
/// Gaussian of the requested FWHM. Returns `Err` if `fwhm`/`size` are unusable.
fn build_psf_model(args: &PsfArgs) -> Result<PsfModel, String> {
    if !(args.fwhm.is_finite()) || args.fwhm <= 0.0 {
        return Err(format!(
            "psf.fwhm must be a positive finite value, got {}",
            args.fwhm
        ));
    }
    // Odd side, floored at 5 (mirrors estimate_psf's crop handling).
    let size = {
        let s = args.size.max(5);
        if s % 2 == 0 {
            s + 1
        } else {
            s
        }
    };
    let half = size / 2;

    let kind = match args.kind.trim().to_ascii_lowercase().as_str() {
        // Empirical cannot be rendered analytically; serve a Gaussian.
        "" | "gaussian" | "empirical" => PsfKind::Gaussian,
        "moffat" => PsfKind::Moffat,
        other => {
            return Err(format!(
                "unknown psf.kind '{other}'; expected gaussian/moffat"
            ))
        }
    };

    // FWHM → σ for a Gaussian: FWHM = 2·√(2 ln 2)·σ.
    const FWHM_PER_SIGMA: f64 = 2.354_820_045_030_949;

    let (kernel, beta) = match kind {
        PsfKind::Gaussian | PsfKind::Empirical => {
            let sigma = (args.fwhm / FWHM_PER_SIGMA).max(f64::MIN_POSITIVE);
            let two_sig_sq = 2.0 * sigma * sigma;
            let mut k = vec![0.0_f64; size * size];
            for j in 0..size {
                for i in 0..size {
                    let dx = i as f64 - half as f64;
                    let dy = j as f64 - half as f64;
                    k[j * size + i] = (-(dx * dx + dy * dy) / two_sig_sq).exp();
                }
            }
            (k, 0.0)
        }
        PsfKind::Moffat => {
            // β in the realistic atmospheric range; α from the Moffat FWHM
            // relation FWHM = 2·α·√(2^(1/β) − 1).
            let beta = if args.beta.is_finite() && args.beta > 1.0 {
                args.beta
            } else {
                2.5
            };
            let denom = (2.0_f64.powf(1.0 / beta) - 1.0).sqrt();
            let alpha = if denom > 0.0 {
                args.fwhm / (2.0 * denom)
            } else {
                args.fwhm / 2.0
            };
            let alpha_sq = (alpha * alpha).max(f64::MIN_POSITIVE);
            let mut k = vec![0.0_f64; size * size];
            for j in 0..size {
                for i in 0..size {
                    let dx = i as f64 - half as f64;
                    let dy = j as f64 - half as f64;
                    let r2 = dx * dx + dy * dy;
                    k[j * size + i] = (1.0 + r2 / alpha_sq).powf(-beta);
                }
            }
            (k, beta)
        }
    };

    // Normalize to sum 1.0 (unit-DC kernel preserves flux under convolution).
    let mut kernel = kernel;
    let sum: f64 = kernel.iter().sum();
    if sum.is_finite() && sum > 0.0 {
        let inv = 1.0 / sum;
        for v in kernel.iter_mut() {
            *v *= inv;
        }
    } else {
        return Err("rendered PSF kernel has a non-positive sum".to_string());
    }

    Ok(PsfModel {
        kind,
        fwhm: args.fwhm,
        beta,
        size,
        kernel,
    })
}

/// Stable lowercase string name for a [`PsfKind`] (for the JSON result).
fn psf_kind_str(kind: PsfKind) -> &'static str {
    match kind {
        PsfKind::Empirical => "empirical",
        PsfKind::Moffat => "moffat",
        PsfKind::Gaussian => "gaussian",
    }
}

// api_reduce_stars_preview

/// Star-reduction knobs (subset of [`StarReductionConfig`]). Each unset field
/// keeps the production [`StarReductionConfig::default`] value.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct ReduceStarsConfigArgs {
    /// Reduction strength in `[0, 1]`. `None` ⇒ default (0.5). `0` is identity.
    strength: Option<f64>,
    /// `"morphological_erosion"` | `"screened_residual"`. `None` ⇒ default
    /// (screened residual).
    method: Option<String>,
    /// Extra mask dilation in px before feathering. `None` ⇒ default (2).
    mask_dilate: Option<usize>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct ReduceStarsPreviewArgs {
    /// Input FITS path (required).
    input_fits: String,
    /// Output FITS path (required).
    output_fits: String,
    /// Optional star-reduction overrides.
    config: ReduceStarsConfigArgs,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct ReduceStarsPreviewResult {
    output_path: String,
}

fn reduce_stars_preview_impl(
    args: ReduceStarsPreviewArgs,
) -> Result<ReduceStarsPreviewResult, String> {
    if args.input_fits.trim().is_empty() {
        return Err("inputFits is required".to_string());
    }
    if args.output_fits.trim().is_empty() {
        return Err("outputFits is required".to_string());
    }

    let (image, source_header) = read_fits(Path::new(&args.input_fits))
        .map_err(|e| format!("failed to read '{}': {e:?}", args.input_fits))?;

    let defaults = StarReductionConfig::default();
    let method = match args
        .config
        .method
        .as_deref()
        .map(|m| m.trim().to_ascii_lowercase())
        .as_deref()
    {
        None | Some("") => defaults.method,
        Some("screened_residual") | Some("screenedresidual") => {
            StarReduceMethod::ScreenedResidual
        }
        Some("morphological_erosion") | Some("morphologicalerosion") => {
            StarReduceMethod::MorphologicalErosion
        }
        Some(other) => {
            return Err(format!(
                "unknown star-reduction method '{other}'; expected morphological_erosion or screened_residual"
            ))
        }
    };
    let cfg = StarReductionConfig {
        strength: args.config.strength.unwrap_or(defaults.strength),
        method,
        mask_dilate: args.config.mask_dilate.unwrap_or(defaults.mask_dilate),
    };

    let reduced = star_reduction::reduce_stars(&image, &cfg)
        .map_err(|e| format!("star reduction failed: {e}"))?;

    // The reduced frame keeps the source pixel type and the source grid, so the
    // input's astrometry and observation identity carry straight through.
    let out_path = Path::new(&args.output_fits);
    ensure_parent_dir(out_path)?;
    let mut header = FitsHeader::new();
    header.set_string("IMAGETYP", "MASTER_LIGHT");
    header.set_string("CALSTAT", "Skotiq star-reduction preview");
    carry_source_header(&mut header, &source_header);
    write_fits(out_path, &reduced, &header)
        .map_err(|e| format!("failed to write star-reduced FITS: {e:?}"))?;

    Ok(ReduceStarsPreviewResult {
        output_path: args.output_fits,
    })
}

// Shared helpers

/// Convert an image to `F32` for an archival linear master, de-interleaving and
/// promoting any supported source pixel type. A frame already `F32` is returned
/// as a clone.
fn to_f32(image: &ImageData) -> ImageData {
    if image.pixel_type == PixelType::F32 {
        return image.clone();
    }
    let width = image.width as usize;
    let height = image.height as usize;
    let channels = image.channels as usize;
    let n = width * height * channels;
    let bpp = image.pixel_type.byte_size();
    let mut out = vec![0.0_f32; n];
    for (idx, o) in out.iter_mut().enumerate() {
        let off = idx * bpp;
        if off + bpp <= image.data.len() {
            *o = read_pixel_f32(&image.data[off..off + bpp], image.pixel_type);
        }
    }
    ImageData::from_f32(image.width, image.height, image.channels, &out)
}

/// Read a single little-endian pixel of the given type as `f32`.
#[inline]
fn read_pixel_f32(bytes: &[u8], pt: PixelType) -> f32 {
    match pt {
        PixelType::U8 => bytes[0] as f32,
        PixelType::U16 => u16::from_le_bytes([bytes[0], bytes[1]]) as f32,
        PixelType::U32 => u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]) as f32,
        PixelType::F32 => f32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]),
        PixelType::F64 => f64::from_le_bytes([
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        ]) as f32,
    }
}

/// Create the parent directory of an output path if it does not exist. Mirrors
/// the helper in [`crate::api::post_session`].
fn ensure_parent_dir(path: &Path) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)
                .map_err(|e| format!("failed to create directory {}: {e}", parent.display()))?;
        }
    }
    Ok(())
}

// Tests

#[cfg(test)]
mod tests {
    use super::*;
    use skotiq_imaging::{add_wcs_headers, read_fits, WcsInfo};
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
        let p = std::env::temp_dir().join(format!("sk_fe_{name}_{}", std::process::id()));
        std::fs::create_dir_all(&p).unwrap();
        TempDir(p)
    }

    /// Render a synthetic mono `F32` star field: a smooth two-axis gradient sky
    /// with a handful of injected Gaussian "stars". The gradient gives the
    /// background extractor a real surface to fit, and the wide PSFs (σ ≈ 2.4,
    /// FWHM ≈ 5.6 px) are accepted by the deconvolution PSF sampler.
    fn render_field_f32(size: u32, stars: &[(f64, f64, f64)], background: f64) -> ImageData {
        let w = size as usize;
        let h = size as usize;
        let mut pixels = vec![0f32; w * h];
        for y in 0..h {
            for x in 0..w {
                // Gentle planar gradient + a tiny deterministic dither.
                let grad = background + 0.6 * x as f64 + 0.4 * y as f64;
                let n = ((((y * w + x).wrapping_mul(2654435761)) >> 8) % 1000) as f64 / 1000.0;
                pixels[y * w + x] = (grad + (n - 0.5) * 4.0) as f32;
            }
        }
        let sigma = 2.4f64;
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

    /// A spread of bright, well-separated stars for a `size`x`size` frame.
    fn field_stars(size: f64) -> Vec<(f64, f64, f64)> {
        vec![
            (size * 0.20, size * 0.25, 18000.0),
            (size * 0.70, size * 0.18, 16000.0),
            (size * 0.40, size * 0.60, 20000.0),
            (size * 0.82, size * 0.62, 14000.0),
            (size * 0.28, size * 0.80, 17000.0),
            (size * 0.62, size * 0.83, 15000.0),
        ]
    }

    fn write_master(path: &Path, image: &ImageData) {
        let mut h = FitsHeader::new();
        h.set_string("IMAGETYP", "MASTER_LIGHT");
        write_fits(path, image, &h).expect("write synthetic master");
    }

    // api_extract_background

    /// A gradient sky with a few stars flattens to a readable `F32` master of the
    /// same geometry, and the result reports the fitted degree + per-channel mean.
    #[test]
    fn extract_background_round_trip() {
        let size = 256u32;
        let field = render_field_f32(size, &field_stars(size as f64), 800.0);
        let dir = temp_dir("extract_background_round_trip");
        let in_path = dir.join("in.fits");
        let out_path = dir.join("out.fits");
        write_master(&in_path, &field);

        let args = serde_json::json!({
            "inputFits": in_path.to_string_lossy(),
            "outputFits": out_path.to_string_lossy(),
            // A low-order surface the synthetic planar gradient is well within.
            "config": { "polyDegree": 2 }
        });
        let resp = api_extract_background(args.to_string()).expect("extract background");
        let result: ExtractBackgroundResult = serde_json::from_str(&resp).unwrap();

        assert_eq!(result.degree, 2);
        assert_eq!(result.channels, 1, "mono master flattens to one channel");
        assert_eq!(
            result.mean_level.len(),
            result.channels as usize,
            "one mean level per channel"
        );
        assert!(out_path.exists(), "flattened FITS must be on disk");

        // The flattened frame is a real, readable F32 master of the same geometry.
        let (img, _h) = read_fits(out_path.as_path()).expect("read flattened master");
        assert_eq!(img.pixel_type, PixelType::F32);
        assert_eq!(img.width, size);
        assert_eq!(img.height, size);
        assert_eq!(img.channels, 1);
    }

    // api_deconvolve_preview

    /// Deconvolution with an explicitly supplied Moffat PSF restores a readable
    /// frame and echoes the PSF actually used.
    #[test]
    fn deconvolve_preview_explicit_psf_round_trip() {
        let size = 96u32;
        let field = render_field_f32(size, &field_stars(size as f64), 600.0);
        let dir = temp_dir("deconvolve_preview_explicit_psf_round_trip");
        let in_path = dir.join("in.fits");
        let out_path = dir.join("out.fits");
        write_master(&in_path, &field);

        let args = serde_json::json!({
            "inputFits": in_path.to_string_lossy(),
            "outputFits": out_path.to_string_lossy(),
            "estimatePsf": false,
            "psf": { "kind": "moffat", "fwhm": 3.0, "beta": 2.5, "size": 15 },
            // Keep the preview cheap and deterministic.
            "config": { "iterations": 5 }
        });
        let resp = api_deconvolve_preview(args.to_string()).expect("deconvolve");
        let result: DeconvolvePreviewResult = serde_json::from_str(&resp).unwrap();

        assert_eq!(result.psf.kind, "moffat");
        assert!((result.psf.fwhm - 3.0).abs() < 1e-9);
        assert!(result.psf.size >= 5 && result.psf.size % 2 == 1);
        assert!(out_path.exists(), "restored FITS must be on disk");

        // The restored frame preserves the source pixel type + geometry.
        let (img, _h) = read_fits(out_path.as_path()).expect("read restored frame");
        assert_eq!(img.pixel_type, PixelType::F32);
        assert_eq!(img.width, size);
        assert_eq!(img.height, size);
    }

    /// The PSF-estimation path samples the frame's own injected stars and runs to
    /// a readable restored frame, reporting the estimated PSF FWHM.
    #[test]
    fn deconvolve_preview_estimated_psf_round_trip() {
        let size = 192u32;
        // A dense, bright, well-separated field so the PSF sampler clears its
        // minimum-stars gate on synthetic data.
        let mut stars = field_stars(size as f64);
        stars.extend_from_slice(&[
            (size as f64 * 0.50, size as f64 * 0.30, 19000.0),
            (size as f64 * 0.15, size as f64 * 0.55, 16000.0),
            (size as f64 * 0.88, size as f64 * 0.40, 15000.0),
        ]);
        let field = render_field_f32(size, &stars, 500.0);
        let dir = temp_dir("deconvolve_preview_estimated_psf_round_trip");
        let in_path = dir.join("in.fits");
        let out_path = dir.join("out.fits");
        write_master(&in_path, &field);

        let args = serde_json::json!({
            "inputFits": in_path.to_string_lossy(),
            "outputFits": out_path.to_string_lossy(),
            "estimatePsf": true,
            "config": { "iterations": 5 }
        });
        let resp = api_deconvolve_preview(args.to_string()).expect("deconvolve (estimate)");
        let result: DeconvolvePreviewResult = serde_json::from_str(&resp).unwrap();

        assert!(result.psf.fwhm.is_finite() && result.psf.fwhm > 0.0);
        assert!(result.psf.size >= 5 && result.psf.size % 2 == 1);
        let (img, _h) = read_fits(out_path.as_path()).expect("read restored frame");
        assert_eq!(img.pixel_type, PixelType::F32);
        assert_eq!(img.width, size);
    }

    // api_reduce_stars_preview

    /// Star reduction writes a same-geometry reduced frame preserving pixel type.
    #[test]
    fn reduce_stars_preview_round_trip() {
        let size = 128u32;
        let field = render_field_f32(size, &field_stars(size as f64), 700.0);
        let dir = temp_dir("reduce_stars_preview_round_trip");
        let in_path = dir.join("in.fits");
        let out_path = dir.join("out.fits");
        write_master(&in_path, &field);

        let args = serde_json::json!({
            "inputFits": in_path.to_string_lossy(),
            "outputFits": out_path.to_string_lossy(),
            "config": { "strength": 0.4, "method": "screened_residual" }
        });
        let resp = api_reduce_stars_preview(args.to_string()).expect("reduce stars");
        let result: ReduceStarsPreviewResult = serde_json::from_str(&resp).unwrap();
        assert_eq!(result.output_path, out_path.to_string_lossy());
        assert!(out_path.exists(), "reduced FITS must be on disk");

        let (img, _h) = read_fits(out_path.as_path()).expect("read reduced frame");
        assert_eq!(img.pixel_type, PixelType::F32);
        assert_eq!(img.width, size);
        assert_eq!(img.height, size);
    }

    // Error paths

    /// Bad JSON, a missing required path, and a nonexistent input FITS all surface
    /// as `Err` — never a silent degraded preview — across all three entry points.
    #[test]
    fn enhance_error_paths() {
        // Malformed JSON.
        assert!(api_extract_background("not json".to_string()).is_err());
        assert!(api_deconvolve_preview("not json".to_string()).is_err());
        assert!(api_reduce_stars_preview("not json".to_string()).is_err());

        // Empty required paths.
        assert!(api_extract_background(r#"{"inputFits":"","outputFits":""}"#.to_string()).is_err());

        // Nonexistent input FITS.
        let dir = temp_dir("enhance_error_paths");
        let missing = dir.join("missing.fits");
        let out = dir.join("out.fits");
        let args = serde_json::json!({
            "inputFits": missing.to_string_lossy(),
            "outputFits": out.to_string_lossy()
        });
        assert!(
            api_extract_background(args.to_string()).is_err(),
            "a nonexistent input FITS must error"
        );
        assert!(api_reduce_stars_preview(args.to_string()).is_err());

        // An unknown deconvolution PSF kind (estimatePsf off) is rejected.
        let size = 32u32;
        let field = render_field_f32(size, &field_stars(size as f64), 400.0);
        let in_path = dir.join("psf_in.fits");
        write_master(&in_path, &field);
        let bad_psf = serde_json::json!({
            "inputFits": in_path.to_string_lossy(),
            "outputFits": out.to_string_lossy(),
            "estimatePsf": false,
            "psf": { "kind": "bananas", "fwhm": 3.0, "size": 9 }
        });
        assert!(
            api_deconvolve_preview(bad_psf.to_string()).is_err(),
            "an unknown PSF kind must error"
        );
    }

    // WCS carry-over

    /// Write a synthetic master whose header carries a plate-solved WCS plus a
    /// second-order SIP distortion pair and the observation identity a real
    /// solved frame has, so a carry-over can be checked card for card.
    fn write_solved_master(path: &Path, image: &ImageData) -> FitsHeader {
        let mut h = FitsHeader::new();
        h.set_string("IMAGETYP", "MASTER_LIGHT");
        add_wcs_headers(
            &mut h,
            &WcsInfo::from_plate_solve(83.822, -5.391, 12.0, 1.5, image.width, image.height),
        );
        h.set_string("CTYPE1", "RA---TAN-SIP");
        h.set_string("CTYPE2", "DEC--TAN-SIP");
        h.set_int("A_ORDER", 2);
        h.set_int("B_ORDER", 2);
        h.set_float("A_2_0", 1.25e-6);
        h.set_float("B_0_2", -9.5e-7);
        h.set_string("OBJECT", "M42");
        h.set_string("FILTER", "Ha");
        h.set_string("DATE-OBS", "2026-08-14T21:03:11");
        h.set_float("EXPTIME", 1800.0);
        h.set_string("INSTRUME", "Test Cam");
        write_fits(path, image, &h).expect("write solved master");
        h
    }

    /// Every astrometry and observation card the input carried must be present,
    /// with the same value, in the op's output header. A missing or altered card
    /// leaves the next op in a recipe with no sky reference.
    fn assert_astrometry_survived(source: &FitsHeader, out_path: &Path) {
        let (_img, out) = read_fits(out_path).expect("read op output");
        for key in [
            "CRVAL1", "CRVAL2", "CRPIX1", "CRPIX2", "CD1_1", "CD1_2", "CD2_1", "CD2_2", "EQUINOX",
            "A_2_0", "B_0_2",
        ] {
            let want = source
                .get_float(key)
                .unwrap_or_else(|| panic!("test fixture is missing {key}"));
            let got = out
                .get_float(key)
                .unwrap_or_else(|| panic!("output dropped WCS keyword {key}"));
            assert!(
                (got - want).abs() <= want.abs() * 1e-9 + 1e-15,
                "{key}: output {got} != input {want}"
            );
        }
        for key in [
            "CTYPE1", "CTYPE2", "RADESYS", "OBJECT", "FILTER", "DATE-OBS", "INSTRUME",
        ] {
            assert_eq!(
                out.get_string(key),
                source.get_string(key),
                "output dropped or changed {key}"
            );
        }
        assert_eq!(out.get_int("A_ORDER"), Some(2), "SIP order must survive");
        assert_eq!(out.get_int("B_ORDER"), Some(2));
    }

    /// Background extraction preserves the input's astrometry end to end.
    #[test]
    fn extract_background_preserves_wcs() {
        let size = 128u32;
        let field = render_field_f32(size, &field_stars(size as f64), 800.0);
        let dir = temp_dir("extract_background_preserves_wcs");
        let in_path = dir.join("in.fits");
        let out_path = dir.join("out.fits");
        let source = write_solved_master(&in_path, &field);

        let args = serde_json::json!({
            "inputFits": in_path.to_string_lossy(),
            "outputFits": out_path.to_string_lossy(),
            "config": { "polyDegree": 2 }
        });
        api_extract_background(args.to_string()).expect("extract background");
        assert_astrometry_survived(&source, &out_path);
    }

    /// Deconvolution preserves the input's astrometry end to end.
    #[test]
    fn deconvolve_preview_preserves_wcs() {
        let size = 128u32;
        let field = render_field_f32(size, &field_stars(size as f64), 600.0);
        let dir = temp_dir("deconvolve_preview_preserves_wcs");
        let in_path = dir.join("in.fits");
        let out_path = dir.join("out.fits");
        let source = write_solved_master(&in_path, &field);

        let args = serde_json::json!({
            "inputFits": in_path.to_string_lossy(),
            "outputFits": out_path.to_string_lossy(),
            "estimatePsf": false,
            "psf": { "kind": "moffat", "fwhm": 5.6, "beta": 3.0, "size": 15 },
            "config": { "iterations": 2 }
        });
        api_deconvolve_preview(args.to_string()).expect("deconvolve");
        assert_astrometry_survived(&source, &out_path);
    }

    /// Star reduction preserves the input's astrometry end to end.
    #[test]
    fn reduce_stars_preview_preserves_wcs() {
        let size = 128u32;
        let field = render_field_f32(size, &field_stars(size as f64), 600.0);
        let dir = temp_dir("reduce_stars_preview_preserves_wcs");
        let in_path = dir.join("in.fits");
        let out_path = dir.join("out.fits");
        let source = write_solved_master(&in_path, &field);

        let args = serde_json::json!({
            "inputFits": in_path.to_string_lossy(),
            "outputFits": out_path.to_string_lossy(),
            "config": { "strength": 0.5 }
        });
        api_reduce_stars_preview(args.to_string()).expect("reduce stars");
        assert_astrometry_survived(&source, &out_path);
    }

    /// An unsolved input yields an unsolved output: the carry-over never invents
    /// astrometry, and the HISTORY says plainly that nothing was carried.
    #[test]
    fn extract_background_invents_no_wcs_for_an_unsolved_input() {
        let size = 128u32;
        let field = render_field_f32(size, &field_stars(size as f64), 800.0);
        let dir = temp_dir("extract_background_invents_no_wcs");
        let in_path = dir.join("in.fits");
        let out_path = dir.join("out.fits");
        write_master(&in_path, &field);

        let args = serde_json::json!({
            "inputFits": in_path.to_string_lossy(),
            "outputFits": out_path.to_string_lossy(),
            "config": { "polyDegree": 2 }
        });
        api_extract_background(args.to_string()).expect("extract background");

        let (_img, out) = read_fits(out_path.as_path()).expect("read flattened master");
        assert_eq!(
            out.get_float("CRVAL1"),
            None,
            "no WCS to carry -> none written"
        );
        assert_eq!(out.get_float("CD1_1"), None);
        assert!(
            out.history
                .iter()
                .any(|h| h.contains("Carried 0 astrometry")),
            "the absence must be stated, not silent: {:?}",
            out.history
        );
    }
}
