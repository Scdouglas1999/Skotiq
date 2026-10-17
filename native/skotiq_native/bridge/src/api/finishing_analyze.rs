//! Post-session **analysis + photometric colour-calibration** FFI surface.
//!
//! Three stateless, JSON-in / JSON-out functions that wrap the committed native
//! analysis cores (`skotiq_imaging::{optimizer, color_calibration}` plus the
//! star detector in `stats`) for the smart-finishing / morning-report pipeline:
//!
//! * [`api_analyze_night`] — predict the marginal-SNR integration curve and a
//!   keep/cull subset recommendation from per-sub quality descriptors and
//!   weights. No pixels are touched (the optimizer is a cheap analytic predictor).
//! * [`api_detect_stars_photometry`] — detect stars on a master and measure each
//!   star's per-channel background-subtracted aperture flux. This is the raw
//!   photometry the **Dart side** cross-matches against a star catalogue to
//!   assign each star a colour index `B − V`.
//! * [`api_color_calibrate`] — given the Dart-matched, colour-indexed stars,
//!   solve the per-channel white balance ([`color_calibration::solve_color_calibration`])
//!   and apply it to a master ([`color_calibration::apply_color_calibration`]),
//!   writing the rebalanced linear FITS.
//!
//! Why JSON and `#[frb(ignore)]` DTOs (same rationale as `post_session.rs`):
//! regenerating the `flutter_rust_bridge` bindings is heavyweight, so only the
//! three `String -> Result<String, String>` signatures cross the FFI boundary —
//! every knob added later rides inside the JSON payload and never triggers
//! another regen. All failure modes surface as `Err(String)`; nothing is ever
//! silently best-effort'd.

use skotiq_imaging::color_calibration::{
    apply_color_calibration, solve_color_calibration, ColorStar,
};
use skotiq_imaging::frame_weighting::FrameQuality;
use skotiq_imaging::optimizer::{integration_curve, recommend_subset, OptimizerConfig};
use skotiq_imaging::{
    carry_source_header, detect_stars, read_fits, write_fits, FitsHeader, ImageData, PixelType,
    StarDetectionConfig,
};
use serde::{Deserialize, Serialize};
use std::path::Path;

// api_analyze_night — marginal-SNR optimizer

/// One per-sub quality descriptor (mirrors
/// [`skotiq_imaging::frame_weighting::FrameQuality`]). `eccentricity` is
/// optional: omit it (or pass `null`) when too few reliable stars were available
/// to measure it honestly — the optimizer treats a missing value as neutral.
#[derive(Debug, Clone, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct FrameQualityArgs {
    /// Robust per-pixel noise σ (ADU).
    noise: f64,
    /// Sky-background level (ADU).
    background: f64,
    /// Frame signal-to-noise proxy.
    snr: f64,
    /// Median star FWHM (px); `0.0` when no stars were measurable.
    fwhm: f64,
    /// Median star eccentricity (0 = round, →1 = trailed), or `null`.
    eccentricity: Option<f64>,
    /// Number of stars detected.
    star_count: u32,
}

impl Default for FrameQualityArgs {
    fn default() -> Self {
        Self {
            noise: 0.0,
            background: 0.0,
            snr: 0.0,
            fwhm: 0.0,
            eccentricity: None,
            star_count: 0,
        }
    }
}

impl From<&FrameQualityArgs> for FrameQuality {
    fn from(a: &FrameQualityArgs) -> Self {
        FrameQuality {
            noise: a.noise,
            background: a.background,
            snr: a.snr,
            fwhm: a.fwhm,
            eccentricity: a.eccentricity,
            star_count: a.star_count,
        }
    }
}

/// Optimizer tunables (subset of [`OptimizerConfig`]). Each unset field keeps
/// the production default (`aggressiveness = 0.7`, `min_keep = 1`).
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct OptimizerArgs {
    /// Where to land between the diminishing-returns knee (`0`) and the
    /// maximum-SNR prefix (`1`); clamped into `[0, 1]`. `null`/absent ⇒ default.
    aggressiveness: Option<f64>,
    /// Never recommend keeping fewer than this many subs. `null`/absent ⇒ 1.
    min_keep: Option<usize>,
}

/// Top-level request for [`api_analyze_night`]. `qualities`, `weights`, and
/// `exposures_s` are parallel arrays over the same population of subs.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct AnalyzeNightArgs {
    /// Per-sub quality descriptors.
    qualities: Vec<FrameQualityArgs>,
    /// Per-sub integration weights, aligned to `qualities`. Must match length.
    weights: Vec<f64>,
    /// Per-sub exposure seconds, aligned to `qualities`. May be shorter (missing
    /// exposures count as 0 s on the cost axis).
    exposures_s: Vec<f64>,
    /// Optimizer tunables.
    optimizer: OptimizerArgs,
}

/// One predicted point on the integration curve (mirrors
/// [`skotiq_imaging::optimizer::CurvePoint`]).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct CurvePointDto {
    /// Number of subs in this weight-ranked prefix (`1..=N`).
    n: usize,
    /// Predicted integrated SNR of the best `n` subs.
    snr: f64,
    /// Weighted-mean FWHM (px) over the prefix.
    fwhm: f64,
    /// Cumulative integration time (seconds) of the prefix.
    cumulative_integration_s: f64,
}

/// The optimizer's keep/cull verdict (mirrors
/// [`skotiq_imaging::optimizer::SubsetRecommendation`]).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct RecommendationDto {
    /// How many weight-ranked subs to keep.
    keep_n: usize,
    /// Original indices (into the input arrays) of the kept subs, weight-ranked.
    kept_indices: Vec<usize>,
    /// Predicted SNR change of the subset vs keeping all subs, in percent
    /// (never negative — the optimizer's never-harm floor guarantees it).
    predicted_snr_gain_pct: f64,
    /// Human-readable summary.
    reason: String,
}

/// Response for [`api_analyze_night`].
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct AnalyzeNightResult {
    /// The predicted integration curve over the weight-ranked prefixes.
    curve: Vec<CurvePointDto>,
    /// The keep/cull recommendation.
    recommendation: RecommendationDto,
}

/// Predict the marginal-SNR integration curve and a keep/cull subset
/// recommendation from per-sub quality descriptors + weights.
///
/// This wraps [`optimizer::integration_curve`](skotiq_imaging::optimizer::integration_curve)
/// and [`optimizer::recommend_subset`](skotiq_imaging::optimizer::recommend_subset):
/// it is a *pure analytic predictor* — no pixels are integrated. The only hard
/// error is a `qualities`/`weights` length mismatch (the project idiom: refuse
/// inconsistent parallel arrays rather than best-effort on them).
///
/// `args_json` is an [`AnalyzeNightArgs`]; the result is an
/// [`AnalyzeNightResult`].
pub fn api_analyze_night(args_json: String) -> Result<String, String> {
    let args: AnalyzeNightArgs =
        serde_json::from_str(&args_json).map_err(|e| format!("invalid analyze args: {e}"))?;
    let result = analyze_night_impl(args)?;
    serde_json::to_string(&result).map_err(|e| format!("failed to encode result: {e}"))
}

fn analyze_night_impl(args: AnalyzeNightArgs) -> Result<AnalyzeNightResult, String> {
    let qualities: Vec<FrameQuality> = args.qualities.iter().map(FrameQuality::from).collect();

    let cfg = {
        let mut c = OptimizerConfig::default();
        if let Some(a) = args.optimizer.aggressiveness {
            c.aggressiveness = a;
        }
        if let Some(m) = args.optimizer.min_keep {
            c.min_keep = m;
        }
        c
    };

    let curve = integration_curve(&qualities, &args.weights, &args.exposures_s)
        .map_err(|e| format!("integration curve failed: {e}"))?;
    let recommendation = recommend_subset(&qualities, &args.weights, &args.exposures_s, &cfg)
        .map_err(|e| format!("subset recommendation failed: {e}"))?;

    let curve_dto: Vec<CurvePointDto> = curve
        .iter()
        .map(|p| CurvePointDto {
            n: p.n,
            snr: p.snr,
            fwhm: p.fwhm,
            cumulative_integration_s: p.cumulative_integration_s,
        })
        .collect();

    Ok(AnalyzeNightResult {
        curve: curve_dto,
        recommendation: RecommendationDto {
            keep_n: recommendation.keep_n,
            kept_indices: recommendation.kept_indices,
            predicted_snr_gain_pct: recommendation.predicted_snr_gain_pct,
            reason: recommendation.reason,
        },
    })
}

// api_detect_stars_photometry — detect + per-channel aperture photometry

/// Default circular-aperture radius (px) for per-channel flux measurement when
/// the caller does not specify one. Three pixels comfortably contains the core
/// of a well-sampled star while keeping the local-background annulus close to
/// the source (so a gradient does not bias the subtraction).
const DEFAULT_APERTURE_RADIUS: usize = 3;

/// Star-detection sensitivity overrides for photometry (the same knob
/// `post_session::DetectionArgs` exposes for registration).
///
/// The production [`StarDetectionConfig::default`] is tuned for real CCD frames
/// and deliberately rejects idealised/undersampled PSFs. These optional
/// overrides let callers loosen the hot-pixel / SNR / sharpness gates for
/// unusual masters (very short stacks, undersampled optics, synthetic data).
/// Each `0`/unset field keeps the production default for that knob.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct PhotometryDetectionArgs {
    /// Detection σ above background (default 5.0).
    detection_sigma: f64,
    /// Minimum connected-component area in px (default 9).
    min_area: u32,
    /// Maximum star eccentricity to accept (default 0.7).
    max_eccentricity: f64,
    /// Minimum HFR in px (default 1.0).
    min_hfr: f64,
    /// Minimum SNR (default 5.0).
    min_snr: f64,
    /// Maximum sharpness, 0..1 (default 0.95; raise toward 1.0 to keep
    /// tight/idealised PSFs the hot-pixel gate would otherwise reject).
    max_sharpness: f64,
}

/// Request for [`api_detect_stars_photometry`].
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct DetectStarsPhotometryArgs {
    /// Master FITS path to detect + photometer (required).
    input_fits: String,
    /// Keep only the brightest `maxStars` detections (by flux). `0`/absent ⇒ all.
    max_stars: usize,
    /// Circular-aperture radius (px) for the per-channel flux. `0`/absent ⇒
    /// [`DEFAULT_APERTURE_RADIUS`].
    aperture: Option<usize>,
    /// Optional star-detection sensitivity overrides.
    detection: PhotometryDetectionArgs,
}

/// One detected star with its per-channel aperture photometry. The detection
/// metrics (`flux`/`snr`/`hfr`/`fwhm`/`eccentricity`) come from the mono
/// detection plane; `channel_flux[c]` is the background-subtracted aperture flux
/// in image channel `c` — the photometry the Dart side cross-matches against a
/// catalogue to assign a colour index.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct StarPhotometryDto {
    /// Sub-pixel centroid X (px).
    x: f64,
    /// Sub-pixel centroid Y (px).
    y: f64,
    /// Detection flux on the mono plane (ADU).
    flux: f64,
    /// Detection SNR.
    snr: f64,
    /// Half-flux radius (px).
    hfr: f64,
    /// FWHM (px).
    fwhm: f64,
    /// Eccentricity (0 = round, →1 = trailed).
    eccentricity: f64,
    /// Peak ADU of the detection on the rescaled (0..65535) mono detection
    /// plane. A detection whose peak sits at/near that ceiling is saturated and
    /// its per-channel `channelFlux` ratios are unreliable for colour work, so
    /// the Dart cross-matcher rejects it (SPCC saturation rejection).
    peak: f64,
    /// Background-subtracted aperture flux per image channel, in channel order.
    channel_flux: Vec<f64>,
}

/// Response for [`api_detect_stars_photometry`].
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct DetectStarsPhotometryResult {
    width: u32,
    height: u32,
    channels: u32,
    stars: Vec<StarPhotometryDto>,
}

/// Detect stars on a master and measure each one's per-channel background-
/// subtracted aperture flux.
///
/// Pipeline: read the master → derive a mono U16 detection plane (the star
/// detector is single-channel: for an RGB master it averages the channels into a
/// luminance plane, mirroring `post_session::aligned_quality`) → `detect_stars`
/// with the production [`StarDetectionConfig`] defaults → for every detection,
/// measure aperture flux in *each* original channel of the master (sum inside a
/// small circular aperture minus a local-median background, evaluated on the
/// native pixel buffer so the photometry is faithful to the linear master).
///
/// The per-channel flux vector is what the Dart side cross-matches against a
/// photometric catalogue; this function deliberately does **not** know the
/// catalogue.
///
/// `args_json` is a [`DetectStarsPhotometryArgs`]; the result is a
/// [`DetectStarsPhotometryResult`].
pub fn api_detect_stars_photometry(args_json: String) -> Result<String, String> {
    let args: DetectStarsPhotometryArgs =
        serde_json::from_str(&args_json).map_err(|e| format!("invalid photometry args: {e}"))?;
    let result = detect_stars_photometry_impl(args)?;
    serde_json::to_string(&result).map_err(|e| format!("failed to encode result: {e}"))
}

fn detect_stars_photometry_impl(
    args: DetectStarsPhotometryArgs,
) -> Result<DetectStarsPhotometryResult, String> {
    if args.input_fits.trim().is_empty() {
        return Err("inputFits is required".to_string());
    }
    let (image, _header) = read_fits(Path::new(&args.input_fits))
        .map_err(|e| format!("failed to read '{}': {e:?}", args.input_fits))?;

    let width = image.width as usize;
    let height = image.height as usize;
    let channels = image.channels as usize;
    if width == 0 || height == 0 || channels == 0 {
        return Err("input image has zero geometry".to_string());
    }

    // Per-location, per-channel f64 values of the master (channel-interleaved).
    let interleaved = image_to_f64(&image);
    if interleaved.len() != width * height * channels {
        return Err(format!(
            "unsupported pixel type {:?} for photometry (expected U16 or F32)",
            image.pixel_type
        ));
    }

    // Build the mono U16 detection plane: the star detector is single-channel,
    // so an RGB master is averaged into a luminance plane (matching the
    // post-session quality path). The plane is rescaled into 0..65535 because
    // `detect_stars` expects U16 and its thresholds are ADU-scaled; star
    // *positions* are scale-invariant, so this only affects detection sensitivity,
    // never the per-channel photometry below (measured on the native buffer).
    let detection_plane = mono_u16_detection_plane(&interleaved, width, height, channels);

    let mut config = StarDetectionConfig::default();
    apply_detection_overrides(&mut config, &args.detection);
    let mut stars = detect_stars(&detection_plane, &config);

    // Brightest-first so an optional `max_stars` cap keeps the most informative
    // photometry sources.
    stars.sort_by(|a, b| b.flux.total_cmp(&a.flux));
    let keep = if args.max_stars > 0 {
        args.max_stars.min(stars.len())
    } else {
        stars.len()
    };
    stars.truncate(keep);

    let radius = args
        .aperture
        .filter(|&r| r > 0)
        .unwrap_or(DEFAULT_APERTURE_RADIUS);

    let star_dtos: Vec<StarPhotometryDto> = stars
        .iter()
        .map(|s| {
            let channel_flux =
                aperture_flux_per_channel(&interleaved, width, height, channels, s.x, s.y, radius);
            StarPhotometryDto {
                x: s.x,
                y: s.y,
                flux: s.flux,
                snr: s.snr,
                hfr: s.hfr,
                fwhm: s.fwhm,
                eccentricity: s.eccentricity,
                peak: s.peak,
                channel_flux,
            }
        })
        .collect();

    Ok(DetectStarsPhotometryResult {
        width: image.width,
        height: image.height,
        channels: image.channels,
        stars: star_dtos,
    })
}

// api_color_calibrate — solve + apply per-channel white balance

/// G2V (solar) `B − V` — the conventional daylight-balanced "white" reference.
/// Used when the caller does not pass an explicit `whiteRefBv`.
const DEFAULT_WHITE_REF_BV: f64 = 0.65;

/// One Dart-matched, colour-indexed star (mirrors
/// [`skotiq_imaging::color_calibration::ColorStar`]).
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct MatchedStarArgs {
    /// Background-subtracted flux of this star in each image channel, in channel
    /// order. Must contain exactly `channels` entries.
    channel_flux: Vec<f64>,
    /// Catalogue colour index `B − V` for the matched source.
    catalog_bv: f64,
}

/// Request for [`api_color_calibrate`].
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct ColorCalibrateArgs {
    /// Master FITS to rebalance (required).
    input_fits: String,
    /// Where to write the colour-calibrated master (required).
    output_fits: String,
    /// Image channel count (the per-star `channelFlux` length must match).
    channels: usize,
    /// Reference colour index a neutral star is solved for. `null`/absent ⇒
    /// [`DEFAULT_WHITE_REF_BV`] (G2V / solar).
    white_ref_bv: Option<f64>,
    /// The Dart-matched, colour-indexed stars (need at least
    /// `color_calibration::MIN_MATCHED_STARS`).
    matched_stars: Vec<MatchedStarArgs>,
}

/// Response for [`api_color_calibrate`].
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
struct ColorCalibrateResult {
    /// Path of the written calibrated master.
    output_path: String,
    /// The solved per-channel scale factors, in channel order.
    channel_scale: Vec<f64>,
    /// Number of matched stars that informed the solve.
    matched: usize,
    /// Robust RMS of the per-channel fit residuals (log10-flux units).
    residual: f64,
}

/// Solve a per-channel white balance from the Dart-matched colour-indexed stars
/// and apply it to a master, writing the rebalanced linear FITS.
///
/// Wraps [`solve_color_calibration`](skotiq_imaging::color_calibration::solve_color_calibration)
/// (Theil–Sen + Tukey-biweight robust per-channel colour-vs-flux fit) then
/// [`apply_color_calibration`](skotiq_imaging::color_calibration::apply_color_calibration).
/// All solver errors (too few stars, channel mismatch, degenerate fit) surface
/// as `Err(String)` — a confidently-wrong white balance is never silently
/// applied, since it would tint every downstream frame.
///
/// `args_json` is a [`ColorCalibrateArgs`]; the result is a
/// [`ColorCalibrateResult`].
pub fn api_color_calibrate(args_json: String) -> Result<String, String> {
    let args: ColorCalibrateArgs = serde_json::from_str(&args_json)
        .map_err(|e| format!("invalid color-calibrate args: {e}"))?;
    let result = color_calibrate_impl(args)?;
    serde_json::to_string(&result).map_err(|e| format!("failed to encode result: {e}"))
}

fn color_calibrate_impl(args: ColorCalibrateArgs) -> Result<ColorCalibrateResult, String> {
    if args.input_fits.trim().is_empty() {
        return Err("inputFits is required".to_string());
    }
    if args.output_fits.trim().is_empty() {
        return Err("outputFits is required".to_string());
    }
    if args.channels == 0 {
        return Err("channels must be > 0".to_string());
    }

    let white_ref_bv = args.white_ref_bv.unwrap_or(DEFAULT_WHITE_REF_BV);

    let stars: Vec<ColorStar> = args
        .matched_stars
        .iter()
        .map(|s| ColorStar {
            channel_flux: s.channel_flux.clone(),
            catalog_bv: s.catalog_bv,
        })
        .collect();

    let calibration = solve_color_calibration(&stars, args.channels, white_ref_bv)
        .map_err(|e| format!("color calibration solve failed: {e}"))?;

    // Read the master, rebalance it in place, and write the calibrated FITS. The
    // master count guard in the solver does not see the image, so guard the
    // channel count here too: the calibration's scales must match the master.
    let (mut image, source_header) = read_fits(Path::new(&args.input_fits))
        .map_err(|e| format!("failed to read '{}': {e:?}", args.input_fits))?;
    if image.channels as usize != args.channels {
        return Err(format!(
            "channels mismatch: solved for {} but master '{}' has {}",
            args.channels, args.input_fits, image.channels
        ));
    }

    apply_color_calibration(&mut image, &calibration);

    let out_path = Path::new(&args.output_fits);
    ensure_parent_dir(out_path)?;
    let mut header = FitsHeader::new();
    header.set_string("IMAGETYP", "MASTER_LIGHT");
    header.set_string("CALSTAT", "Skotiq photometric color calibration");
    // FITS keywords are capped at 8 chars (see `fits::is_valid_keyword`).
    header.set_float("WHITEBV", white_ref_bv);
    header.set_int("CCSTARS", calibration.matched as i64);
    header.set_float("CCRESID", calibration.residual);
    header.add_history(&format!(
        "Photometric color calibration from {} matched stars (B-V ref {white_ref_bv:.3}, residual {:.4})",
        calibration.matched, calibration.residual
    ));
    // The rebalance is a per-channel scale on the input's own grid. The solve
    // that produced it came from a plate-matched star list, so an output that
    // dropped the WCS could not be re-solved against the catalogue it was
    // calibrated with, and every later step in the chain would inherit no
    // astrometry.
    carry_source_header(&mut header, &source_header);
    write_fits(out_path, &image, &header)
        .map_err(|e| format!("failed to write calibrated master: {e:?}"))?;

    Ok(ColorCalibrateResult {
        output_path: args.output_fits,
        channel_scale: calibration.channel_scale,
        matched: calibration.matched,
        residual: calibration.residual,
    })
}

// Shared helpers

/// Apply non-zero star-detection overrides onto a base [`StarDetectionConfig`],
/// leaving each unset (zero) knob at its production default — identical to
/// `post_session::apply_detection_overrides`.
fn apply_detection_overrides(cfg: &mut StarDetectionConfig, d: &PhotometryDetectionArgs) {
    if d.detection_sigma > 0.0 {
        cfg.detection_sigma = d.detection_sigma;
    }
    if d.min_area > 0 {
        cfg.min_area = d.min_area;
    }
    if d.max_eccentricity > 0.0 {
        cfg.max_eccentricity = d.max_eccentricity;
    }
    if d.min_hfr > 0.0 {
        cfg.min_hfr = d.min_hfr;
    }
    if d.min_snr > 0.0 {
        cfg.min_snr = d.min_snr;
    }
    if d.max_sharpness > 0.0 {
        cfg.max_sharpness = d.max_sharpness;
    }
}

/// Flatten an [`ImageData`] (U16 or F32) into a channel-interleaved f64 buffer.
/// Returns an empty buffer for unsupported pixel types (the callers validate the
/// length and surface an error).
fn image_to_f64(image: &ImageData) -> Vec<f64> {
    match image.pixel_type {
        PixelType::U16 => image
            .as_u16()
            .map(|v| v.into_iter().map(|x| x as f64).collect())
            .unwrap_or_default(),
        PixelType::F32 => image
            .as_f32()
            .map(|v| v.into_iter().map(|x| x as f64).collect())
            .unwrap_or_default(),
        _ => Vec::new(),
    }
}

/// Headroom ceiling (ADU) the detection plane is rescaled into.
///
/// The plane's global max maps here, deliberately *below* the detector's default
/// saturation limit (60000): if we rescaled all the way to 65535, the master's
/// own brightest stars would land above the saturation gate and be spuriously
/// rejected as saturated. 50000 keeps the whole star population detectable while
/// preserving relative tone (star *positions* are scale-invariant, so the exact
/// ceiling only affects sensitivity, never the photometry below).
const DETECTION_PLANE_CEILING: f64 = 50000.0;

/// Build a mono U16 detection plane from a channel-interleaved f64 master.
///
/// For RGB the channels are averaged into a luminance plane (the star detector
/// is single-channel — see `post_session::aligned_quality`). The plane is
/// rescaled from its finite min..max into `0..=DETECTION_PLANE_CEILING` because
/// `detect_stars` reads U16 and its thresholds are ADU-scaled; this only affects
/// detection sensitivity, never the per-channel photometry (measured on the
/// native buffer).
fn mono_u16_detection_plane(
    interleaved: &[f64],
    width: usize,
    height: usize,
    channels: usize,
) -> ImageData {
    let locations = width * height;
    let mut luma = vec![0.0f64; locations];
    for (loc, out) in luma.iter_mut().enumerate() {
        let mut sum = 0.0;
        for ch in 0..channels {
            sum += interleaved[loc * channels + ch];
        }
        *out = sum / channels as f64;
    }

    let mut lo = f64::INFINITY;
    let mut hi = f64::NEG_INFINITY;
    for &v in &luma {
        if v.is_finite() {
            lo = lo.min(v);
            hi = hi.max(v);
        }
    }

    let u16data: Vec<u16> = if !lo.is_finite() || !hi.is_finite() || hi <= lo {
        vec![0u16; locations]
    } else {
        let range = hi - lo;
        luma.iter()
            .map(|&v| (((v - lo) / range).clamp(0.0, 1.0) * DETECTION_PLANE_CEILING).round() as u16)
            .collect()
    };

    ImageData::from_u16(width as u32, height as u32, 1, &u16data)
}

/// Measure background-subtracted aperture flux for a star centred at `(cx, cy)`
/// in every channel of a channel-interleaved f64 master.
///
/// For each channel: sum the pixels inside a circular aperture of radius
/// `radius`, estimate the local background as the median of the pixels in a
/// surrounding annulus (radius `radius+1 ..= radius+2`), and subtract
/// `background_per_pixel × aperture_area`. The per-channel result is floored at
/// `0` (a star cannot have negative flux; a non-positive value would only mean
/// the aperture is dominated by noise, and the colour solver rejects
/// non-positive fluxes per channel anyway).
fn aperture_flux_per_channel(
    interleaved: &[f64],
    width: usize,
    height: usize,
    channels: usize,
    cx: f64,
    cy: f64,
    radius: usize,
) -> Vec<f64> {
    let r = radius as f64;
    let r_in = r + 1.0; // inner edge of the background annulus
    let r_out = r + 2.0; // outer edge of the background annulus
    let r2 = r * r;
    let r_in2 = r_in * r_in;
    let r_out2 = r_out * r_out;

    let icx = cx.round() as i64;
    let icy = cy.round() as i64;
    let reach = (r_out.ceil() as i64) + 1;

    let mut out = vec![0.0f64; channels];
    for (ch, out_ch) in out.iter_mut().enumerate() {
        let mut aperture_sum = 0.0f64;
        let mut aperture_pixels = 0usize;
        let mut annulus: Vec<f64> = Vec::new();

        for dy in -reach..=reach {
            let y = icy + dy;
            if y < 0 || y as usize >= height {
                continue;
            }
            for dx in -reach..=reach {
                let x = icx + dx;
                if x < 0 || x as usize >= width {
                    continue;
                }
                let ddx = x as f64 - cx;
                let ddy = y as f64 - cy;
                let dist2 = ddx * ddx + ddy * ddy;
                let idx = ((y as usize) * width + (x as usize)) * channels + ch;
                let v = interleaved[idx];
                if dist2 <= r2 {
                    aperture_sum += v;
                    aperture_pixels += 1;
                } else if dist2 >= r_in2 && dist2 <= r_out2 {
                    annulus.push(v);
                }
            }
        }

        // Local background per pixel = median of the annulus (robust to a nearby
        // neighbour leaking in). No annulus samples ⇒ treat background as 0.
        let bg_per_pixel = if annulus.is_empty() {
            0.0
        } else {
            median(&mut annulus)
        };

        let flux = aperture_sum - bg_per_pixel * aperture_pixels as f64;
        *out_ch = flux.max(0.0);
    }
    out
}

/// Median of a mutable slice (sorts in place). Returns `0.0` for an empty slice.
fn median(v: &mut [f64]) -> f64 {
    if v.is_empty() {
        return 0.0;
    }
    v.sort_by(f64::total_cmp);
    let n = v.len();
    if n % 2 == 0 {
        (v[n / 2 - 1] + v[n / 2]) / 2.0
    } else {
        v[n / 2]
    }
}

/// Create the parent directory of `path` if it does not exist.
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

    /// Unique scratch directory so parallel test runs don't collide.
    fn temp_dir(prefix: &str) -> TempDir {
        let n = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let p = std::env::temp_dir().join(format!("ns_fa_{prefix}_{}_{n}", std::process::id()));
        std::fs::create_dir_all(&p).unwrap();
        TempDir(p)
    }

    /// Render a synthetic mono U16 star field with Gaussian PSFs on a flat,
    /// lightly-noised sky (mirrors the post_session test renderer).
    fn render_field(size: u32, stars: &[(f64, f64, f64)], background: f64) -> ImageData {
        let w = size as usize;
        let h = size as usize;
        let mut pixels = vec![0f64; w * h];
        for (i, p) in pixels.iter_mut().enumerate() {
            let n = ((i.wrapping_mul(2654435761) >> 8) % 1000) as f64 / 1000.0;
            *p = background + (n - 0.5) * 6.0;
        }
        // Wider PSF (FWHM ≈ 5.6 px) than a single-pixel hot spot so the detector's
        // area / HFR gates accept it — a realistically-sampled star, not an
        // undersampled spike.
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
                    pixels[y as usize * w + x as usize] += g;
                }
            }
        }
        let u16data: Vec<u16> = pixels
            .iter()
            .map(|v| v.round().clamp(0.0, 65535.0) as u16)
            .collect();
        ImageData::from_u16(size, size, 1, &u16data)
    }

    fn write_fits_file(path: &Path, image: &ImageData) {
        let mut h = FitsHeader::new();
        h.set_string("IMAGETYP", "MASTER_LIGHT");
        write_fits(path, image, &h).expect("write synthetic master");
    }

    /// Relaxed star-detection overrides for clean synthetic Gaussian PSFs (the
    /// production default detector deliberately rejects idealised single-peak
    /// Gaussians). Mirrors post_session's `synthetic_align().detection`.
    fn synthetic_detection() -> serde_json::Value {
        serde_json::json!({
            "detectionSigma": 3.0,
            "minArea": 1,
            "maxEccentricity": 1.0,
            "minHfr": 0.5,
            "minSnr": 3.0,
            "maxSharpness": 1.0
        })
    }

    // api_analyze_night

    /// Equal-quality subs follow the √n SNR law and the recommender keeps them all.
    #[test]
    fn analyze_night_keeps_all_equal_subs() {
        let n = 10usize;
        let qualities: Vec<serde_json::Value> = (0..n)
            .map(|_| {
                serde_json::json!({
                    "noise": 5.0,
                    "background": 1000.0,
                    "snr": 10.0,
                    "fwhm": 3.0,
                    "eccentricity": 0.1,
                    "starCount": 50
                })
            })
            .collect();
        let args = serde_json::json!({
            "qualities": qualities,
            "weights": vec![1.0; n],
            "exposuresS": vec![60.0; n],
        });

        let resp = api_analyze_night(args.to_string()).expect("analyze");
        let result: AnalyzeNightResult = serde_json::from_str(&resp).unwrap();

        assert_eq!(result.curve.len(), n);
        // SNR(1) == per-sub SNR; SNR(n) == √n · SNR(1).
        assert!((result.curve[0].snr - 10.0).abs() < 1e-9);
        assert!((result.curve[n - 1].snr - (n as f64).sqrt() * 10.0).abs() < 1e-6);
        // Curve climbs monotonically.
        for w in result.curve.windows(2) {
            assert!(w[1].snr > w[0].snr);
        }
        // All subs kept, no predicted gain from culling equal subs.
        assert_eq!(result.recommendation.keep_n, n);
        assert_eq!(result.recommendation.kept_indices.len(), n);
        assert!(result.recommendation.predicted_snr_gain_pct.abs() < 1e-9);
    }

    /// A net-negative tail sub is dropped, by its ORIGINAL index, and the cull is
    /// predicted to improve SNR. Optional eccentricity is omitted on the bad sub.
    #[test]
    fn analyze_night_culls_a_net_negative_sub() {
        let good_n = 8usize;
        let mut qualities: Vec<serde_json::Value> = (0..good_n)
            .map(|_| {
                serde_json::json!({
                    "noise": 4.0, "background": 1000.0, "snr": 15.0,
                    "fwhm": 2.5, "eccentricity": 0.1, "starCount": 60
                })
            })
            .collect();
        // Villain appended at the end (original index good_n), no eccentricity.
        qualities.push(serde_json::json!({
            "noise": 60.0, "background": 3000.0, "snr": 1.0, "fwhm": 8.0, "starCount": 5
        }));
        let mut weights = vec![1.0; good_n];
        weights.push(0.05);

        let args = serde_json::json!({
            "qualities": qualities,
            "weights": weights,
            "exposuresS": vec![120.0; good_n + 1],
            "optimizer": { "aggressiveness": 0.7 }
        });

        let resp = api_analyze_night(args.to_string()).expect("analyze");
        let result: AnalyzeNightResult = serde_json::from_str(&resp).unwrap();
        assert_eq!(result.recommendation.keep_n, good_n);
        assert!(!result.recommendation.kept_indices.contains(&good_n));
        assert!(result.recommendation.predicted_snr_gain_pct > 0.0);
    }

    /// A `qualities`/`weights` length mismatch is an error (never best-effort).
    #[test]
    fn analyze_night_length_mismatch_errors() {
        let args = serde_json::json!({
            "qualities": [
                { "noise": 5.0, "snr": 10.0, "fwhm": 3.0, "starCount": 1 },
                { "noise": 5.0, "snr": 10.0, "fwhm": 3.0, "starCount": 1 }
            ],
            "weights": [1.0]
        });
        assert!(api_analyze_night(args.to_string()).is_err());
        assert!(api_analyze_night("not json".to_string()).is_err());
    }

    // api_detect_stars_photometry

    /// Detect stars on a synthetic mono master and measure single-channel
    /// aperture flux. The bright planted stars are found and report positive flux.
    #[test]
    fn photometry_detects_and_measures_mono() {
        let size = 256u32;
        let stars = vec![
            (60.0, 60.0, 30000.0),
            (180.0, 90.0, 28000.0),
            (120.0, 200.0, 26000.0),
            (210.0, 210.0, 24000.0),
        ];
        let field = render_field(size, &stars, 400.0);
        let dir = temp_dir("phot_mono");
        let path = dir.join("field.fits");
        write_fits_file(&path, &field);

        let args = serde_json::json!({
            "inputFits": path.to_string_lossy(),
            "aperture": 3,
            // Relaxed detection for clean synthetic Gaussian PSFs (the production
            // default detector deliberately rejects idealised single-peak PSFs —
            // see post_session's synthetic_align). This is the real, user-exposed
            // `detection` knob, not a test backdoor.
            "detection": synthetic_detection()
        });
        let resp = api_detect_stars_photometry(args.to_string()).expect("photometry");
        let result: DetectStarsPhotometryResult = serde_json::from_str(&resp).unwrap();

        assert_eq!(result.channels, 1);
        assert!(
            result.stars.len() >= 3,
            "should detect most planted stars, got {}",
            result.stars.len()
        );
        for s in &result.stars {
            assert_eq!(s.channel_flux.len(), 1);
            assert!(
                s.channel_flux[0] > 0.0,
                "aperture flux must be positive for a real star, got {}",
                s.channel_flux[0]
            );
        }
        // maxStars cap is honoured.
        let capped = serde_json::json!({
            "inputFits": path.to_string_lossy(),
            "maxStars": 2,
            "detection": synthetic_detection()
        });
        let resp2 = api_detect_stars_photometry(capped.to_string()).expect("photometry capped");
        let result2: DetectStarsPhotometryResult = serde_json::from_str(&resp2).unwrap();
        assert!(result2.stars.len() <= 2);
    }

    /// RGB master: each detected star carries a 3-entry per-channel flux vector.
    #[test]
    fn photometry_measures_three_channels() {
        let size = 128u32;
        let mono = render_field(size, &[(40.0, 40.0, 30000.0), (90.0, 70.0, 28000.0)], 300.0);
        // Replicate the mono plane into an interleaved RGB image with a per-channel
        // tint so the channels differ.
        let mono_u16 = mono.as_u16().unwrap();
        let locs = (size * size) as usize;
        let mut rgb = vec![0u16; locs * 3];
        for i in 0..locs {
            let v = mono_u16[i] as f64;
            rgb[i * 3] = (v * 1.0).min(65535.0) as u16;
            rgb[i * 3 + 1] = (v * 0.8).min(65535.0) as u16;
            rgb[i * 3 + 2] = (v * 0.6).min(65535.0) as u16;
        }
        let rgb_image = ImageData::from_u16(size, size, 3, &rgb);
        let dir = temp_dir("phot_rgb");
        let path = dir.join("field.fits");
        write_fits_file(&path, &rgb_image);

        let args = serde_json::json!({
            "inputFits": path.to_string_lossy(),
            "detection": synthetic_detection()
        });
        let resp = api_detect_stars_photometry(args.to_string()).expect("rgb photometry");
        let result: DetectStarsPhotometryResult = serde_json::from_str(&resp).unwrap();
        assert_eq!(result.channels, 3);
        assert!(!result.stars.is_empty());
        for s in &result.stars {
            assert_eq!(s.channel_flux.len(), 3, "one flux per channel");
            // The tint makes R > G > B for a positive source.
            assert!(s.channel_flux[0] >= s.channel_flux[2]);
        }
    }

    /// A missing input path is an error.
    #[test]
    fn photometry_missing_input_errors() {
        assert!(api_detect_stars_photometry(r#"{"inputFits":""}"#.to_string()).is_err());
        assert!(api_detect_stars_photometry("not json".to_string()).is_err());
    }

    // api_color_calibrate

    /// Solve + apply a per-channel white balance over a synthetic RGB master.
    /// The middle (green) channel is pinned to 1.0 and the calibrated FITS is a
    /// readable image of the same geometry.
    #[test]
    fn color_calibrate_solves_applies_and_writes() {
        // Plant a 3-channel star population with a known imbalance + colour slopes
        // (mirrors color_calibration's own synthetic generator).
        let a = [3.00, 3.10, 2.55];
        let b = [0.30, 0.00, -0.40];
        let white_ref_bv = 0.65;
        let count = 40usize;
        let mut state: u64 = 0xC0FFEE | 1;
        let mut signed = || {
            state = state
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            2.0 * ((state >> 11) as f64 / (1u64 << 53) as f64) - 1.0
        };
        let matched: Vec<serde_json::Value> = (0..count)
            .map(|i| {
                let bv = -0.2 + 1.8 * (i as f64 / (count as f64 - 1.0));
                let flux: Vec<f64> = (0..3)
                    .map(|c| 10f64.powf(a[c] + b[c] * bv + 0.01 * signed()))
                    .collect();
                serde_json::json!({ "channelFlux": flux, "catalogBv": bv })
            })
            .collect();

        // A small RGB master to rebalance.
        let size = 16u32;
        let locs = (size * size) as usize;
        let data: Vec<f32> = (0..locs * 3).map(|i| 0.1 + (i % 7) as f32 * 0.01).collect();
        let master = ImageData::from_f32(size, size, 3, &data);
        let dir = temp_dir("cc");
        let in_path = dir.join("in.fits");
        let out_path = dir.join("out.fits");
        write_fits_file(&in_path, &master);

        let args = serde_json::json!({
            "inputFits": in_path.to_string_lossy(),
            "outputFits": out_path.to_string_lossy(),
            "channels": 3,
            "whiteRefBv": white_ref_bv,
            "matchedStars": matched
        });

        let resp = api_color_calibrate(args.to_string()).expect("calibrate");
        let result: ColorCalibrateResult = serde_json::from_str(&resp).unwrap();
        assert_eq!(result.channel_scale.len(), 3);
        assert!(
            (result.channel_scale[1] - 1.0).abs() < 1e-9,
            "green must be pinned to 1.0, got {}",
            result.channel_scale[1]
        );
        assert_eq!(result.matched, count);
        assert!(result.residual.is_finite() && result.residual >= 0.0);

        // The calibrated master is a real, readable F32 FITS of the same geometry.
        let (img, _h) = read_fits(out_path.as_path()).expect("read calibrated master");
        assert_eq!(img.pixel_type, PixelType::F32);
        assert_eq!(img.width, size);
        assert_eq!(img.channels, 3);
    }

    /// Too few matched stars is a loud error (never a silent tint).
    #[test]
    fn color_calibrate_too_few_stars_errors() {
        let size = 8u32;
        let data: Vec<f32> = vec![0.5; (size * size * 3) as usize];
        let master = ImageData::from_f32(size, size, 3, &data);
        let dir = temp_dir("cc_few");
        let in_path = dir.join("in.fits");
        let out_path = dir.join("out.fits");
        write_fits_file(&in_path, &master);

        let matched: Vec<serde_json::Value> = (0..4)
            .map(|i| {
                serde_json::json!({
                    "channelFlux": [1000.0 + i as f64, 1000.0, 900.0],
                    "catalogBv": 0.3 + i as f64 * 0.1
                })
            })
            .collect();
        let args = serde_json::json!({
            "inputFits": in_path.to_string_lossy(),
            "outputFits": out_path.to_string_lossy(),
            "channels": 3,
            "matchedStars": matched
        });
        assert!(api_color_calibrate(args.to_string()).is_err());
        assert!(!out_path.exists(), "no output written on a failed solve");
    }

    // WCS carry-over

    /// A colour-calibrated master must keep the astrometry its own colour solve
    /// depended on: the matched stars came from a plate solve, and an output that
    /// dropped the WCS could not be re-matched against the same catalogue.
    #[test]
    fn color_calibrate_preserves_wcs() {
        // Same synthetic star population the round-trip test uses.
        let a = [3.00, 3.10, 2.55];
        let b = [0.30, 0.00, -0.40];
        let count = 40usize;
        let mut state: u64 = 0xC0FFEE | 1;
        let mut signed = || {
            state = state
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            2.0 * ((state >> 11) as f64 / (1u64 << 53) as f64) - 1.0
        };
        let matched: Vec<serde_json::Value> = (0..count)
            .map(|i| {
                let bv = -0.2 + 1.8 * (i as f64 / (count as f64 - 1.0));
                let flux: Vec<f64> = (0..3)
                    .map(|c| 10f64.powf(a[c] + b[c] * bv + 0.01 * signed()))
                    .collect();
                serde_json::json!({ "channelFlux": flux, "catalogBv": bv })
            })
            .collect();

        let size = 16u32;
        let locs = (size * size) as usize;
        let data: Vec<f32> = (0..locs * 3).map(|i| 0.1 + (i % 7) as f32 * 0.01).collect();
        let master = ImageData::from_f32(size, size, 3, &data);
        let dir = temp_dir("cc_wcs");
        let in_path = dir.join("in.fits");
        let out_path = dir.join("out.fits");

        let wcs = WcsInfo::from_plate_solve(202.4695, 47.1953, -33.0, 2.1, size, size);
        let mut source = FitsHeader::new();
        source.set_string("IMAGETYP", "MASTER_LIGHT");
        add_wcs_headers(&mut source, &wcs);
        source.set_int("A_ORDER", 2);
        source.set_float("A_1_1", 4.5e-7);
        source.set_string("OBJECT", "M51");
        source.set_string("DATE-OBS", "2026-08-14T22:10:00");
        write_fits(in_path.as_path(), &master, &source).expect("write solved master");

        let args = serde_json::json!({
            "inputFits": in_path.to_string_lossy(),
            "outputFits": out_path.to_string_lossy(),
            "channels": 3,
            "matchedStars": matched
        });
        api_color_calibrate(args.to_string()).expect("calibrate");

        let (_img, out) = read_fits(out_path.as_path()).expect("read calibrated master");
        for key in [
            "CRVAL1", "CRVAL2", "CRPIX1", "CRPIX2", "CD1_1", "CD1_2", "CD2_1", "CD2_2",
        ] {
            let want = source.get_float(key).expect("fixture WCS");
            let got = out
                .get_float(key)
                .unwrap_or_else(|| panic!("calibrated master dropped {key}"));
            assert!(
                (got - want).abs() <= want.abs() * 1e-9 + 1e-15,
                "{key}: output {got} != input {want}"
            );
        }
        assert_eq!(out.get_string("CTYPE1"), Some("RA---TAN"));
        assert_eq!(out.get_int("A_ORDER"), Some(2), "SIP order must survive");
        assert_eq!(out.get_float("A_1_1"), Some(4.5e-7));
        assert_eq!(out.get_string("OBJECT"), Some("M51"));
        assert_eq!(out.get_string("DATE-OBS"), Some("2026-08-14T22:10:00"));
        // The op's own provenance still wins over anything carried.
        assert_eq!(
            out.get_string("CALSTAT"),
            Some("Skotiq photometric color calibration")
        );
    }
}
