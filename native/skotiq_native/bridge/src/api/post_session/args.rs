use super::*;

// JSON request / response contracts

/// Calibration master paths applied to every light before registration.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct CalibrationArgs {
    /// Master dark FITS/XISF path, or `None`/empty to skip.
    pub(crate) dark: Option<String>,
    /// Master flat (unit-mean) path, or `None`/empty to skip.
    pub(crate) flat: Option<String>,
    /// Master bias path, or `None`/empty to skip.
    pub(crate) bias: Option<String>,
    /// Apply self-derived cosmetic (hot/cold transient) correction per light.
    pub(crate) cosmetic_correction: bool,
}

/// Star-detection sensitivity overrides for registration.
///
/// The production `StarDetectionConfig::default()` is tuned for real CCD frames.
/// These optional overrides let callers loosen the hot-pixel / SNR / sharpness
/// gates for unusual data (very short subs, undersampled optics, or synthetic
/// frames) — the PixInsight StarDetector "sensitivity" analogue. Each `0`/unset
/// field keeps the production default for that knob.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct DetectionArgs {
    /// Detection σ above background (default 5.0).
    pub(crate) detection_sigma: f64,
    /// Minimum connected-component area in px (default 9).
    pub(crate) min_area: u32,
    /// Maximum star eccentricity to accept (default 0.7).
    pub(crate) max_eccentricity: f64,
    /// Minimum HFR in px (default 1.0).
    pub(crate) min_hfr: f64,
    /// Minimum SNR (default 5.0).
    pub(crate) min_snr: f64,
    /// Maximum sharpness, 0..1 (default 0.95; raise toward 1.0 to keep
    /// tight/idealised PSFs the hot-pixel gate would otherwise reject).
    pub(crate) max_sharpness: f64,
}

/// Alignment / registration knobs (subset of [`RegistrationConfig`]).
#[derive(Debug, Clone, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct AlignArgs {
    /// `"similarity"` | `"affine"` | `"homography"`.
    pub(crate) model: String,
    /// `"bilinear"` | `"catmullRom"` | `"lanczos3"`.
    pub(crate) resampler: String,
    /// RANSAC inlier threshold in reference pixels.
    pub(crate) ransac_threshold_px: f64,
    /// Brightest-N stars used to build matching descriptors.
    pub(crate) max_ref_stars: usize,
    /// Optional star-detection sensitivity overrides.
    pub(crate) detection: DetectionArgs,
}

impl Default for AlignArgs {
    fn default() -> Self {
        Self {
            model: "affine".to_string(),
            resampler: "lanczos3".to_string(),
            ransac_threshold_px: 2.0,
            max_ref_stars: 60,
            detection: DetectionArgs::default(),
        }
    }
}

/// Per-sub weighting knobs.
#[derive(Debug, Clone, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct WeightingArgs {
    /// Whether weighting is applied at all (off ⇒ every contributing sub = 1.0).
    pub(crate) enabled: bool,
    /// `"snr"` | `"snrSquared"` | `"fwhmInverse"` | `"custom"`.
    pub(crate) formula: String,
    /// Exponents used only when `formula == "custom"`.
    pub(crate) snr_pow: f64,
    pub(crate) fwhm_pow: f64,
    pub(crate) ecc_pow: f64,
}

impl Default for WeightingArgs {
    fn default() -> Self {
        Self {
            enabled: true,
            formula: "snrSquared".to_string(),
            snr_pow: 2.0,
            fwhm_pow: 1.0,
            ecc_pow: 1.0,
        }
    }
}

/// Normalization knobs.
#[derive(Debug, Clone, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct NormalizationArgs {
    /// Whether normalization to the reference is applied at all.
    pub(crate) enabled: bool,
    /// `"global"` | `"local"`.
    pub(crate) mode: String,
    /// Local-grid rows/cols, used only when `mode == "local"`.
    pub(crate) local_rows: usize,
    pub(crate) local_cols: usize,
}

impl Default for NormalizationArgs {
    fn default() -> Self {
        Self {
            enabled: true,
            mode: "global".to_string(),
            local_rows: 8,
            local_cols: 8,
        }
    }
}

/// Integration (combine + rejection) knobs.
#[derive(Debug, Clone, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct IntegrationArgs {
    /// `"mean"` | `"median"`.
    pub(crate) combine: String,
    /// `"auto"` | `"none"` | `"sigmaClip"` | `"winsorizedSigma"` |
    /// `"linearFit"` | `"percentile"` | `"minMax"`.
    ///
    /// `"auto"` picks by sub count (PixInsight-style): `<8 → percentile`,
    /// `8–24 → winsorizedSigma`, `≥25 → linearFit`.
    pub(crate) reject: String,
    /// Low/high thresholds. Sigma-family: κ in σ. Percentile: fraction in (0,1).
    pub(crate) reject_low: f64,
    pub(crate) reject_high: f64,
    /// Min/max counts, used only when `reject == "minMax"`.
    pub(crate) min_max_low: usize,
    pub(crate) min_max_high: usize,
    /// Emit the per-pixel rejection-count map alongside the master.
    pub(crate) generate_rejection_map: bool,
    /// `"f32"` (archival linear, default) | `"u16"`.
    pub(crate) output_bit_depth: String,
}

impl Default for IntegrationArgs {
    fn default() -> Self {
        Self {
            combine: "mean".to_string(),
            reject: "auto".to_string(),
            reject_low: 3.0,
            reject_high: 3.0,
            min_max_low: 1,
            min_max_high: 1,
            generate_rejection_map: true,
            output_bit_depth: "f32".to_string(),
        }
    }
}

/// The full settings block for [`api_integrate_session`].
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct IntegrationSettingsArgs {
    pub(crate) align: AlignArgs,
    pub(crate) weighting: WeightingArgs,
    pub(crate) normalization: NormalizationArgs,
    pub(crate) integration: IntegrationArgs,
}

/// Output paths for [`api_integrate_session`].
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct OutputArgs {
    /// Where to write the 16-bit/float linear FITS master (required).
    pub(crate) master_fits_path: String,
    /// Optional stretched preview PNG path.
    pub(crate) preview_png_path: Option<String>,
    /// Optional per-pixel rejection-count map FITS path.
    pub(crate) rejection_map_path: Option<String>,
    /// Optional stretched PNG sibling for the rejection-count overlay.
    pub(crate) rejection_map_preview_path: Option<String>,
}

/// Top-level request for [`api_integrate_session`].
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct IntegrateSessionArgs {
    /// Caller-chosen id this run answers to for cancellation
    /// ([`api_post_session_cancel`]). Empty ⇒ the run is not cancellable, and no
    /// registry entry is made.
    pub(crate) run_id: String,
    /// Light-frame paths (FITS/XISF/etc.), in any order.
    pub(crate) light_paths: Vec<String>,
    /// Reference choice: a path among `light_paths`, or `"auto"`/empty for the
    /// highest-quality sub.
    pub(crate) reference: Option<String>,
    /// Per-light exposure seconds, aligned to `light_paths`. Used only to report
    /// `totalIntegrationSec`. Empty ⇒ unknown (reported as 0); any other length
    /// than `light_paths` is refused rather than zero-filled.
    pub(crate) exposures_sec: Vec<f64>,
    pub(crate) calibration: CalibrationArgs,
    pub(crate) settings: IntegrationSettingsArgs,
    pub(crate) output: OutputArgs,
}

/// Per-frame record returned to Dart for the cull UI.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct PerFrameRecord {
    pub(crate) path: String,
    /// Normalized integration weight in (0, 1], or 0 if the frame was dropped.
    pub(crate) weight: f64,
    /// RMS registration residual (reference px), or null if not registered.
    pub(crate) rms_residual_px: Option<f64>,
    /// Whether the frame contributed to the master.
    pub(crate) accepted: bool,
    /// Human-readable reason when `accepted == false`.
    pub(crate) reason: Option<String>,
    /// Per-sub signal-to-noise proxy from this sub's own [`FrameQuality`]
    /// (measured on the aligned luminance plane), or null when the sub could
    /// not be registered + measured. Persisted by the Dart side for the Night
    /// Doctor after a morning integration.
    pub(crate) snr: Option<f64>,
    /// Per-sub robust noise σ (ADU) from this sub's own [`FrameQuality`], or
    /// null when not measured. **Load-bearing for the morning report:** the
    /// marginal-SNR optimizer (`integration_curve`) skips any sub whose
    /// `noise <= 0` from the SNR sums, so without surfacing this the whole
    /// improvement curve collapses to zero (signal·noise = 0, variance = 0) and
    /// `target_snr` anchors to 0. The Dart `_analyzeAndStoreCurve` threads this
    /// into the `qualities` map it hands `apiAnalyzeNight`.
    pub(crate) noise: Option<f64>,
    /// Per-sub sky-background level (ADU) from this sub's own [`FrameQuality`],
    /// or null when not measured. Surfaced alongside `noise` so the optimizer's
    /// quality descriptors are complete (the optimizer reads `noise`/`snr`; the
    /// extras keep the morning-report record faithful).
    pub(crate) background: Option<f64>,
    /// Per-sub detected star count from this sub's own [`FrameQuality`], or null
    /// when not measured (transparency / depth proxy carried to the report).
    pub(crate) star_count: Option<u32>,
    /// Per-sub median star FWHM in px (focus / seeing proxy), or null when not
    /// measured.
    pub(crate) fwhm: Option<f64>,
    /// Per-sub median star eccentricity (0 = round, →1 = trailed), or null when
    /// too few reliable stars were available to measure it honestly.
    pub(crate) eccentricity: Option<f64>,
    /// The fitted **source→reference** registration transform, as the row-major
    /// 3×3 homogeneous matrix flattened to 9 elements `[m00, m01, m02, m10, m11,
    /// m12, m20, m21, m22]` — the exact wire shape `DrizzleFrameArgs.transform`
    /// (`finishing_combine.rs`) consumes. `null` only when the sub failed
    /// registration (and so contributes nothing to a drizzle stack). Surfaced so
    /// the Dart drizzle flow can feed each accepted sub's raw, un-resampled
    /// pixels + its transform to `api_drizzle_integrate`.
    pub(crate) transform: Option<Vec<f64>>,
    /// The transform family (`"similarity"` / `"affine"` / `"homography"`),
    /// purely informational; `null` when [`transform`] is `null`.
    pub(crate) transform_kind: Option<String>,
}

/// Flatten a [`TransformModel`] into the row-major 9-element wire array the
/// drizzle frame contract (`DrizzleFrameArgs.transform`) consumes.
pub(crate) fn transform_to_row_major(t: &TransformModel) -> Vec<f64> {
    let m = &t.matrix;
    vec![
        m[0][0], m[0][1], m[0][2], m[1][0], m[1][1], m[1][2], m[2][0], m[2][1], m[2][2],
    ]
}

/// The wire token for a [`TransformKind`] (matches `build_alignment` parsing in
/// `finishing_combine.rs`).
pub(crate) fn transform_kind_wire(kind: TransformKind) -> &'static str {
    match kind {
        TransformKind::Similarity => "similarity",
        TransformKind::Affine => "affine",
        TransformKind::Homography => "homography",
    }
}

/// Response for [`api_integrate_session`].
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct IntegrateSessionResult {
    pub(crate) master_fits_path: String,
    pub(crate) preview_path: Option<String>,
    pub(crate) rejection_map_path: Option<String>,
    pub(crate) rejection_map_preview_path: Option<String>,
    pub(crate) frames_integrated: usize,
    pub(crate) frames_rejected: usize,
    pub(crate) total_integration_sec: f64,
    /// Mean inlier RMS residual across the registered subs (reference px).
    pub(crate) rms_residual: f64,
    pub(crate) width: u32,
    pub(crate) height: u32,
    pub(crate) channels: u32,
    pub(crate) per_frame_stats: Vec<PerFrameRecord>,
    /// Exactly which dark / flat / bias shaped these pixels, how well each
    /// matched the lights, and which corrections did not run at all. The same
    /// statements are written into the master's FITS `HISTORY`.
    pub(crate) calibration: CalibrationReport,
}
