# Post-Session Image Processing — Technical Design & Decomposition

- **Date:** 2026-06-07
- **Branch:** `roadmap/planetarium-atlas-and-perf`
- **Status:** ✅ **SHIPPED end-to-end** (native + FFI + Dart pipeline + Session-Review UI; all gates green; not pushed). See §7 "What shipped & honest quality assessment" for the as-built record and PixInsight gap analysis. The original design (§0–§6) is preserved; the layout deviated from the proposed `integration/` subtree (the modules landed as flat top-level files — see §7.1).
- **North star:** PixInsight-grade integration quality, advanced manual settings with smart defaults, and **multi-night master accumulation** (keep adding new captured subs to an existing master over time).

---

## 0. Scope & Philosophy

Today Skotiq has a strong *live* path (`LiveStacker`, Stack-and-Share) but the *finishing* path is thin: rigid-only registration, incremental sigma-clip only, no per-sub weighting, no normalization, no 16-bit linear master output, no master accumulation, no cohesive "review the night" surface. This document designs the **batch, offline, post-session integration** pipeline that runs *after* a sub-collection exists (one session, one target, possibly across nights) and produces an archival-quality linear master plus a review UI.

Two pipelines coexist on purpose and must **not** be merged:

| Pipeline | Engine | Use | Quality target |
|---|---|---|---|
| **Live** (existing) | `imaging/src/stacking.rs::LiveStacker` | EAA, sequencer `LiveStackingNode`, Stack-and-Share preview | fast, online, single-pass |
| **Post-session** (this design) | new `imaging/src/integration/` modules | morning report, archival master, accumulation | best-effort, multi-pass, batch |

The live engine is a process-wide singleton (see `StackAndShareService` / `LiveStackBusyException`). The post-session engine is **stateless per call** (no singleton) so it can run in an isolate without clobbering a live session.

Reuse, do not rewrite: `ImageData` / `PixelType` (`imaging/src/lib.rs`), `detect_stars` / `DetectedStar` / `frame_eccentricity` / `CameraNoiseModel` / `calculate_stats_u16` (`imaging/src/stats.rs`), `calibrate_frame` and friends (`imaging/src/calibration.rs`), `build_defect_map` / `DefectMap` / `correct_frame_u16` (`imaging/src/defect_map.rs`), `combine_master_frames` (`imaging/src/stacking.rs`), `write_fits` / `read_fits` / `FitsHeader` / `add_wcs_headers` (`imaging/src/fits.rs`), `debayer_cfa_to_rgb` (`imaging/src/stacking.rs`).

---

## 1. Native algorithm modules

New subtree: `native/skotiq_native/imaging/src/integration/` with a `mod.rs` re-exporting the public surface. Each file is single-responsibility, `rayon`-parallel like `calibration.rs`, and unit-tested with synthetic frames (the project idiom — see synthetic-PSF tests in `stats.rs` and the calibration tests).

### 1.1 `integration/align.rs` — advanced star alignment

Supersedes the rigid-only path in `stacking.rs` (`compute_affine_transform`, `apply_transform_bilinear`, `match_stars`). The live engine keeps its rigid path; this module is the high-quality replacement used by batch integration.

**Detection.** Reuse `detect_stars` on the `detection_plane` (luminance proxy for RGB) but tighten for registration: SNR-thresholded, saturation-rejected, edge-margin-rejected, and capped to the brightest `N` (default 200) by flux. Add **flux-weighted centroid refinement** (intensity-weighted barycenter in a small window) and a per-star **PSF sanity gate** (reject stars whose `frame_eccentricity`-style axis ratio implies a hot pixel or trail) to get sub-pixel, outlier-free control points.

**Matching — geometric-invariant, robust to rotation/scale/flip.** Replace nearest-neighbour-by-flux (`match_stars`) with a **triangle/quad asterism matcher** (the astrometry.net / PixInsight StarAlignment approach):

- Build the *k* (default 8) nearest neighbours of each reference star; form **quads** (4-star groups) and compute a **scale/rotation/translation/flip-invariant hash** (the 4-point geometric hash: order the 4 stars, normalise by the most-distant pair, encode the inner two as `(xc, yd)` — invariant under similarity *and* mirror because we canonicalise handedness explicitly).
- Hash reference quads into a spatial bucket map; for each target quad look up matching reference quads by hash distance; each hash agreement votes for a set of star-pair correspondences.
- This is **robust to large rotation, modest scale change, and meridian-flip mirroring** with no prior — exactly the cases rigid NN-flux matching fails on.
- Fallback: if the camera reports no flip and a plate-solve WCS exists for both frames (`WcsInfo` in `fits.rs`), seed correspondences from sky coordinates first (fast path), then refine with quads.

**Transform estimation — RANSAC over a model hierarchy.** From the candidate correspondences, fit with **RANSAC** (random minimal-sample consensus, inlier threshold default 2.0 px, adaptive iteration count from estimated inlier ratio):

- `TransformModel::Similarity` (4 dof: translation + rotation + uniform scale) — minimal sample 2 pairs.
- `TransformModel::Affine` (6 dof) — minimal sample 3 pairs; **default** for most rigs (handles small differential field rotation + plate-scale drift).
- `TransformModel::Homography` (8 dof, projective) — minimal sample 4 pairs; for wide fields / uncorrected optics.
- `TransformModel::ThinPlateSpline { control_points }` — **optional distortion correction** layered *after* a global affine/homography: TPS warp fit to the inlier residuals (regularised, λ default auto from residual scatter) to soak up field curvature / differential refraction. This is the PixInsight "distortion correction" knob.

After RANSAC, **refine** the model with a full least-squares fit over all inliers (Levenberg–Marquardt for homography/TPS; closed-form normal equations for similarity/affine). Report inlier count, RMS residual, peak residual, and the chosen model.

```rust
pub enum TransformModel { Similarity, Affine, Homography, ThinPlateSpline }

pub struct AlignmentResult {
    pub transform: GeometricTransform, // forward map src->ref
    pub model: TransformModel,
    pub inliers: u32,
    pub total_pairs: u32,
    pub rms_residual_px: f64,
    pub peak_residual_px: f64,
}

pub struct GeometricTransform { /* 3x3 homogeneous matrix + optional TPS warp field */ }
impl GeometricTransform {
    pub fn inverse_map(&self, dst_x: f64, dst_y: f64) -> (f64, f64); // for resampling
}

pub fn align_frame(
    reference: &AlignmentReference, // pre-detected ref stars + dims
    frame: &ImageData,
    cfg: &AlignmentConfig,
) -> Result<AlignmentResult, AlignError>;
```

**Resampling — `integration/resample.rs`.** Reverse-map each output pixel through `inverse_map` and interpolate the source with a selectable kernel:

- `Resampler::Bilinear` (fast, live-parity).
- `Resampler::CatmullRom` (cubic, default — good sharpness/ringing tradeoff).
- `Resampler::Lanczos { a }` (a=3 default, **highest quality**, the PixInsight default for registration; windowed-sinc separable kernel).

All resamplers clamp to image bounds, track a **per-output-pixel coverage mask** (0 where the source mapped outside the frame — fed to integration so edges that only some frames cover are weighted/rejected correctly), and operate per-channel in `f64` to avoid intermediate quantisation. Separable Lanczos/Catmull-Rom is `rayon`-parallel over output rows.

### 1.2 `integration/weighting.rs` — per-sub frame weighting

Computes a scalar weight per sub so the best subs dominate the master (PixInsight "image weighting"). Inputs are cheap to derive from primitives already present:

- **Noise estimation:** robust per-frame σ via the **MAD of the residual after a 3×3 median** (k-sigma-robust, matches PixInsight's noise evaluator intent) — new helper, or reuse `CameraNoiseModel` + `calculate_stats_u16` background where available.
- **SNR:** `(median_signal - background) / noise`.
- **FWHM / HFR:** median of detected-star HFR (reuse `calculate_median_hfr` in `stats.rs`).
- **Eccentricity:** `frame_eccentricity(&stars)` (already in `stats.rs`).
- **Star count** and **background level** (transparency/skyglow proxy).

```rust
pub struct FrameQuality {
    pub noise: f64, pub snr: f64, pub fwhm: f64,
    pub eccentricity: Option<f64>, pub star_count: u32, pub background: f64,
}
pub enum WeightFormula { Snr, SnrSquared, FwhmInverse, Custom { snr_pow, fwhm_pow, ecc_pow } }
pub fn frame_weight(q: &FrameQuality, ref_q: &FrameQuality, f: &WeightFormula) -> f64;
```

Default formula mirrors PixInsight's *PSF Signal Weight* spirit: `w ∝ SNR² · (fwhm_ref/fwhm)^a · (1-ecc)^b`, normalised so the best sub = 1.0. Weights also drive a **quality-gate auto-cull** (drop subs below a percentile / above an FWHM multiple) surfaced as a recommendation, not silently applied.

### 1.3 `integration/normalize.rs` — light-frame normalization

Brings every aligned sub onto the reference's photometric scale **before** integration (essential for correct rejection — un-normalised frames make sigma-clip reject signal):

- **Additive (background) match:** estimate background per frame (robust low-percentile / iterative-clipped mean) and subtract the offset to the reference background.
- **Multiplicative (scale) match:** ratio of reference-to-frame signal estimated from a robust linear fit of frame-vs-reference pixels over a shared sample mask (excludes stars/saturation/zero-coverage).
- **Optional local normalization:** a coarse grid (default 8×8) of additive+multiplicative coefficients, bilinearly interpolated per pixel, to correct **gradient drift** between subs (sky gradient changing through the night) — the PixInsight LocalNormalization analogue. Off by default (global), on for "long night / moving moon" smart preset.

```rust
pub struct NormalizationCoeffs { pub scale: f64, pub offset: f64, pub local_grid: Option<Grid> }
pub fn estimate_normalization(frame: &[f64], reference: &[f64], mask: &CoverageMask, mode: NormMode) -> NormalizationCoeffs;
pub fn apply_normalization(frame: &mut [f64], c: &NormalizationCoeffs, w: u32, h: u32);
```

### 1.4 `integration/integrate.rs` — advanced batch integration

The core difference from `LiveStacker`: **batch over the whole aligned, normalized, weighted population** (a column of samples per output pixel), enabling rejection algorithms that need the full distribution. Memory-bounded by **row-band streaming** (process H/bands rows at a time, reading each aligned sub's band; never hold all subs in RAM — critical for 50×60MP subs).

Combination + rejection (all weighted by per-sub weights and per-pixel coverage):

- `Combine::Mean`, `Combine::Median`.
- `Reject::None`.
- `Reject::SigmaClip { low, high }` (batch, iterated to convergence — unlike the live online clip).
- `Reject::WinsorizedSigmaClip { low, high }` (replaces outliers with the clip bound before computing σ — robust default for ≥15 subs).
- `Reject::LinearFitClip { low, high }` (fit a line to the sorted samples, reject by residual — PixInsight's best-for-many-subs algorithm; default for ≥25 subs).
- `Reject::PercentileClip { low, high }` (best for few subs, <8).
- `Reject::MinMax { n_low, n_high }`.

Outputs the integrated `ImageData` (**`PixelType::F32` linear**, the archival format) **plus**:

- A **per-pixel rejection map** (count of rejected samples / fraction) — surfaced in the UI as a "where did rejection bite" overlay (satellite trails, planes, cosmic rays show up here).
- A **per-pixel coverage map** (how many subs contributed) — drizzle/edge diagnostics.
- Final integration metadata (algorithm, params, effective frame count, total integration seconds, mean weight).

```rust
pub struct IntegrationConfig {
    pub combine: Combine, pub reject: Reject,
    pub weighting: WeightFormula, pub normalization: NormMode,
    pub resampler: Resampler, pub model: TransformModel,
    pub generate_rejection_map: bool,
}
pub struct IntegrationOutput {
    pub master: ImageData,        // F32 linear
    pub rejection_map: Option<ImageData>,
    pub coverage_map: Option<ImageData>,
    pub stats: IntegrationStats,
    pub per_frame: Vec<FrameIntegrationRecord>, // weight, residual, accepted/rejected + reason
}
pub fn integrate_lights(refs: &[AlignedSubHandle], cfg: &IntegrationConfig, progress: &dyn Fn(f32)) -> Result<IntegrationOutput, IntegrationError>;
```

### 1.5 `integration/drizzle.rs` — variable-pixel linear reconstruction (Drizzle)

Optional, for well-dithered, under-sampled data. Implements **classic Drizzle** (Fruchter & Hook): map each input pixel as a shrunken "drop" (pixfrac default 0.9) through the inverse `GeometricTransform` onto a finer output grid (scale default 2.0), accumulating drop-area-weighted flux into an output buffer and a weight buffer, final = flux/weight. Requires per-sub `GeometricTransform` (from §1.1) and per-sub weight. Gated behind `enable_drizzle` (off by default; smart preset enables it only when dithering + under-sampling are detected from the sub metadata). Memory via the same row-band streaming.

### 1.6 `integration/master.rs` — accumulating IntegratedMaster (multi-night)

The headline feature: a **serializable running master** you can keep adding subs to across nights, without re-reading old subs.

Key insight: a **weighted mean** is exactly accumulable — store running sums, add new subs, finalize by division. Rejection is the hard part; we use a **two-tier model** that keeps accumulation exact for the mean while still rejecting outliers:

- **Per-pixel running state (streaming, exact for weighted mean + variance):**
  - `sum_w` (Σ weight), `sum_wx` (Σ weight·value), `sum_wx2` (Σ weight·value²) → finalize = `sum_wx/sum_w`; running variance available for noise/SNR readout.
  - `coverage` (contributing sub count), `rejected_count`.
- **Outlier handling on accumulation:** each new sub is normalized to the **frozen normalization reference** stored in the master, then each pixel is **rejected against the current running mean ± k·running σ** (an online robust clip, same spirit as `LiveStacker::accumulate_pixels` but persisted). This is *not* identical to a full batch re-clip, but it is the standard accumulation tradeoff and is honest about it (the master records `accumulation_mode`).
- **Normalization reference is frozen at master creation** (the first night's reference frame's background+scale), so every later night is brought onto the same photometric footing — the thing that makes cross-night accumulation valid.
- **Geometric reference is frozen too** (the master's WCS / reference star list); later subs align to it.

```rust
pub struct IntegratedMaster {
    pub version: u32,
    pub width: u32, pub height: u32, pub channels: u32,
    pub accumulation_mode: AccumulationMode, // RunningWeightedMean { clip }
    pub norm_reference: NormalizationReference, // frozen background+scale + optional WCS
    pub geom_reference: GeometryReference,      // frozen ref stars / WCS for alignment
    pub state: PerPixelAccumulator,             // sum_w, sum_wx, sum_wx2, coverage, rejected
    pub metadata: MasterMetadata,               // filters, total integration s, frame count, per-night log
}
impl IntegratedMaster {
    pub fn create(reference: &ImageData, cfg: &MasterCreateConfig) -> Result<Self, MasterError>;
    pub fn add_frames(&mut self, frames: &[ImageData], qualities: &[FrameQuality]) -> Result<AddReport, MasterError>;
    pub fn finalize(&self) -> ImageData; // F32 linear master
    pub fn serialize(&self) -> Vec<u8>;  // versioned, like DefectMap::serialize
    pub fn deserialize(bytes: &[u8]) -> Result<Self, MasterError>;
}
```

**Persistence:** finalized master → `write_fits` (we extend with F32 output, §1.8) carrying full provenance in `FitsHeader` (`HISTORY` cards already supported); the *resumable accumulator state* → a **sidecar** `.nsmaster` file (the `serialize` blob, versioned exactly like `DefectMap::serialize`/`deserialize` in `defect_map.rs`). Re-opening reads the sidecar to keep accumulating; the FITS is the shareable artifact.

### 1.7 `integration/calibration_ext.rs` — calibration completeness

Closes the calibration gaps next to the existing `calibration.rs` (which only *applies* masters) and `defect_map.rs` (which already builds defect maps and corrects):

- **Master flat build:** `build_master_flat(flats, bias_or_darkflat) -> MasterFrame` — bias/dark-flat-subtract each flat, then `combine_master_frames(..., MasterFrameKind::Flat, CombineMethod::SigmaClip, F32)` (reuse existing combine!) and **normalize to mean 1.0** so `divide_flat` (already in `calibration.rs`) works. This is the missing master-flat builder.
- **Cosmetic / hot-cold pixel correction:** reuse `build_defect_map` + `correct_frame_u16` (`defect_map.rs`) directly; expose a per-light "cosmetic correction" step in the integration pre-pass. Add a **transient cosmic-ray hint** (sigma-rejection map from integration already catches these — no separate per-frame CR pass needed for stacks ≥ a few subs).
- **Defect map source:** build once from the master dark (or a dedicated bad-pixel scan) via existing `build_defect_map`; persist to `defect_map_table.dart` (already exists).

### 1.8 FITS F32 master output (small extension to `fits.rs`)

`write_fits` currently writes 16-bit. Add `write_fits_f32(path, &ImageData /*F32*/, &FitsHeader)` (BITPIX=-32, BZERO=0/BSCALE=1, IEEE float big-endian per FITS spec) so linear masters survive without quantisation. `read_fits` already returns `(ImageData, FitsHeader)`; extend its BITPIX handling to read -32 if not already present. This is the only change to an existing native file.

---

## 2. Minimal FFI surface (JSON-in / JSON-out)

To keep `flutter_rust_bridge` regeneration churn tiny (regen is heavyweight — needs LLVM 21 + MSVC 14.44 + WinKit per `docs/FRB_TROUBLESHOOTING.md`), add **exactly three** new bridge functions to `bridge/src/api/imaging.rs`, all `String -> Result<String, String>` with `serde_json` payloads. New config fields then never trigger a regen (same trick the live stacker uses for node config per MEMORY.md).

```rust
// bridge/src/api/imaging.rs

/// One-shot batch integration of a sub list into a linear FITS master.
/// args: { lights:[{path,weight_hint?}], calibration:{dark?,flat?,bias?,defect_map?},
///         settings:{align, weighting, normalization, integration, drizzle?},
///         reference:{path|auto}, output:{master_fits_path, rejection_map_path?, preview_png_path?} }
/// returns: { master_path, preview_path?, rejection_map_path?, stats:{...}, per_frame:[{path,weight,residual,accepted,reason?}] }
pub fn api_integrate_session(args_json: String) -> Result<String, String>;

/// Multi-night accumulation. op = create | add | finalize | info.
/// create: { op:"create", reference_path, settings, sidecar_path, master_fits_path }
/// add:    { op:"add", sidecar_path, lights:[...], calibration:{...} }
/// finalize:{ op:"finalize", sidecar_path, master_fits_path, preview_png_path? }
/// returns: { sidecar_path, master_path?, preview_path?, frame_count, total_integration_s, coverage_stats }
pub fn api_master_accumulate(args_json: String) -> Result<String, String>;

/// Save an in-memory F32/U16 buffer as a 16-bit or float FITS master with provenance.
/// (Convenience for paths where the buffer is already in Dart; integration paths
///  write the FITS natively and just return the path, so this is for re-export.)
pub fn api_save_fits_master(args_json: String) -> Result<String, String>;
```

Progress is reported through the **existing event stream** (`bridge/src/api/event_stream.rs`) as integration-progress events (phase + 0..1), so the long-running calls don't need a streaming FFI return. These run on a background thread in the bridge (the bridge already does this for other long ops) so the Dart isolate is not blocked.

**Regen impact:** 3 new functions, no new structs across the boundary → one regen, then all future knobs ride in the JSON. Regen command (from `native/skotiq_native`, env per `docs/FRB_TROUBLESHOOTING.md`): `flutter_rust_bridge_codegen generate`.

---

## 3. Dart layer (`packages/skotiq_core/`)

### 3.1 `IntegrationSettings` model — `lib/src/models/imaging/integration_settings.dart`

Immutable value type (freezed-style like existing models) holding **every advanced knob with smart defaults**, plus named presets:

```dart
class IntegrationSettings {
  // Alignment
  final TransformModel model;          // default: affine
  final Resampler resampler;           // default: lanczos3
  final double ransacThresholdPx;      // 2.0
  final bool distortionCorrection;     // false (TPS)
  final int maxRefStars;               // 200
  // Weighting
  final WeightFormula weighting;       // snrSquared
  final bool autoCull; final double cullPercentile; // true, p10
  // Normalization
  final NormMode normalization;        // global (additive+scale)
  // Integration
  final Combine combine;               // mean
  final Reject reject;                 // AUTO -> chosen by frame count
  final double rejectLow, rejectHigh;  // 3.0 / 3.0 (sigma family)
  final bool generateRejectionMap;     // true
  // Drizzle
  final bool drizzle; final double pixfrac, dropScale; // false / 0.9 / 2.0

  factory IntegrationSettings.smartDefaults({required int subCount, required bool dithered, required bool underSampled, required bool osc});
  static const presets = { 'quick', 'balanced', 'maximumQuality', 'fewSubs', 'longNightGradient' };
}
```

**Smart-default logic** (the "smart" in the brief): reject algorithm auto-selected by sub count (`<8 → percentileClip`, `8–24 → winsorizedSigma`, `≥25 → linearFitClip`); drizzle on only when `dithered && underSampled`; local normalization on for `longNightGradient`; resampler `lanczos3` unless `subCount` is huge and the user picks `quick`.

### 3.2 `PostSessionIntegrationService` — `lib/src/services/post_session_integration_service.dart`

Mirrors `StackAndShareService` idiom but targets the **batch** engine and is **not** gated by the live singleton (different native entry point). Pipeline:

1. **Select** accepted subs via the existing `StackLightSelector.selectForSession` / `selectForTarget` (`stack_light_selector.dart`) — already supports multi-night and honours accepted/quality gates. Reuse verbatim.
2. **Calibrate match** via existing `CalibrationService` + `DarkLibraryService.findBestMatch` (`calibration_service.dart`, `dark_library_service.dart`) for the dark; resolve master flat from the **new `FlatLibrary`** (§3.4) by filter/optics/temperature; bias/defect-map from settings/library.
3. **Build the JSON args** (sub paths + calibration master paths + `IntegrationSettings.toJson()` + reference choice + output paths under the session folder via `naming.rs` conventions).
4. **Invoke** `apiIntegrateSession(argsJson)` on an isolate; stream progress events to a `ValueNotifier`/`Stream` for the UI.
5. **Persist:** write an `integrated_masters` row (§3.4) with master FITS path, preview PNG path, settings JSON, per-frame records, stats; optionally also a `stacked_results` row for back-compat with the existing viewer.

It produces a **16-bit/float linear FITS master** (the gap called out in current state) *and* a stretched preview PNG (reuse the auto-stretch path used by `StackAndShareService`).

### 3.3 `MasterAccumulationService` — `lib/src/services/master_accumulation_service.dart`

Drives `apiMasterAccumulate`:

- `createMaster(targetId, referenceSub, settings)` → `op:create`, stores sidecar path + `integrated_masters` row (status `accumulating`).
- `addNight(masterId, newSubs)` → selects new accepted subs **not already folded in** (track folded sub ids in a join table `integrated_master_frames`), calibrates, calls `op:add`, updates frame count / total integration seconds / per-night log.
- `finalizeMaster(masterId)` → `op:finalize`, writes the shareable FITS + preview, flips status to `finalized` (re-openable for more `add`s).

Idempotency + dedup: the `integrated_master_frames` join (master_id, image_id) prevents double-counting a sub across runs (echoes the cross-stream dedup concern in MEMORY.md).

### 3.4 New DB tables (drift, `lib/src/database/tables/` + DAOs, registered in `database.dart`)

Follow the `DarkLibrary` idiom exactly (indices, `@DataClassName`, `withDefault`). Bump `schemaVersion` (currently 40 in `database.dart`) and add a migration step.

- **`integrated_masters`** — `id`, `targetId?`, `name`, `masterFitsPath`, `previewPngPath?`, `sidecarPath?` (null once finalized-only), `status` (`accumulating`/`finalized`), `channels`, `width`, `height`, `frameCount`, `totalIntegrationSeconds`, `filter?`, `settingsJson`, `statsJson`, `rejectionMapPath?`, `createdAt`, `updatedAt`. Indices on `targetId`, `status`, `createdAt`.
- **`integrated_master_frames`** (join) — `id`, `masterId`, `imageId` (FK → `captured_images`), `weight`, `alignmentResidualPx`, `accepted`, `rejectionReason?`, `foldedAt`. Unique index `(masterId, imageId)` for dedup.
- **`flat_library`** — mirrors `dark_library`: `id`, `filePath` (master flat FITS), `filter`, `opticalTrainId?`/`equipmentProfileId?`, `temperature?`, `gain`, `offset`, `binX/binY`, `width/height`, `panelOrSkyFlat`, `masterFrameCount`, `createdAt`. `findBestMatch(filter, optics, temp, gain, bin)` DAO method analogous to `DarkLibraryDao.findBestMatch`. (Note `flat_history.dart` already exists for the *exposure planner*; this is the missing **master-flat artifact library** — distinct concern.)

Reuse `captured_images` / `ImagesDao` for sub metadata, accept/reject, and per-sub quality columns (HFR, ecc, etc.) — no change needed there.

### 3.5 `FlatLibraryService` + master-flat build — `lib/src/services/flat_library_service.dart`

Parallels `dark_library_service.dart` (`createMasterDark` median-combine in an isolate). `createMasterFlat(flats, biasOrDarkFlat, meta)` calls the native master-flat build (via a small extension to `api_combine_master_frames`, or a `FLAT`-kind path already supported by `combine_master_frames`), normalizes to mean 1.0, writes FITS, inserts a `flat_library` row. Closes the "no master-flat / no flat auto-match" gap.

---

## 4. UI (`packages/skotiq_app/`) — design-system (`skotiq_ui`) idiom throughout

### 4.1 Session Review / Morning Report — `lib/screens/session_review/session_review_screen.dart`

The cohesive "review the night" surface (the current biggest gap). One screen, panelled with `SkotiqCard`:

- **Sub gallery + cull rail** — promote and reuse the existing `screens/analytics/widgets/image_thumbnail_strip.dart` (quality badges, HFR chip, accept/reject context menu via `ImagesDao`) from its dialog into a first-class panel; add **blink mode** (cycle subs at N fps to spot clouds/satellites/bad subs by eye — a long-requested missing feature) and multi-select cull.
- **Per-sub detail** — reuse `screens/sequencer/widgets/run_dashboard/frame_detail_dialog.dart` (`showForFrame(imageId)`), but **lift the reject-only restriction** so it opens for any sub (accepted or rejected) with preview + metrics + forensics.
- **Per-sub field-quality heatmap** — reuse `optical_train_diagnostics_service.dart` + `PsfFieldMap`/`AstrometryResidualVectors` widgets (`screens/diagnostics/psf_field_map.dart`, `residual_vector.dart`) at **per-sub granularity** (inputs are already per-sub) so the user sees tilt/collimation per frame and across the night.
- **Finished master viewer** — reuse `screens/stack_result/widgets/astro_image_viewer.dart` (per-channel STF stretch, zoom/pan) to display the integrated master + a **rejection-map overlay toggle** (from §1.4) and a coverage overlay.
- **Re-integrate** — a button that re-runs `PostSessionIntegrationService` with edited settings (after culling) without re-capturing.

### 4.2 Advanced integration settings panel — `lib/screens/session_review/widgets/integration_settings_panel.dart`

`IntegrationSettings` editor: a **preset dropdown** (smart defaults front-and-center) with an "Advanced" expander revealing every knob (model, resampler, weighting, normalization mode, reject algorithm + sigmas, drizzle pixfrac/scale, distortion correction). Each control has a one-line rationale tooltip. The panel shows the **auto-chosen reject algorithm** for the current sub count so the smart default is transparent, and a live "this will use N of M subs after cull" readout.

### 4.3 Master library / accumulation UI — `lib/screens/session_review/widgets/master_library_panel.dart` (+ a tab in Analytics)

Lists `integrated_masters` (preview thumb, target, filter, total integration time, frame count, status). Actions: **open**, **finalize**, **add tonight's subs** (drives `MasterAccumulationService.addNight`), **re-finalize**. A per-master detail shows the per-night fold log and a growth curve (total integration time vs date) — the multi-night accumulation story made visible.

### 4.4 Auto-process-at-run-end hook

In the sequencer run-completion path (where the run dashboard / `session_report_dialog.dart` already fires at end of night), add an opt-in **"auto-integrate at end of run"** setting: on run completion, if enabled, kick `PostSessionIntegrationService` (or `MasterAccumulationService.addNight` when the target has an active accumulating master) in the background and surface the result in the Morning Report. This makes the master "just be there" in the morning — the unattended-night ethos.

---

## 5. Build order, gates, and PI-grade honesty

Each phase is independently committable and **must pass its gate before commit** (revert-on-red discipline). Native gate = `cargo test -p skotiq_imaging` + `cargo clippy -p skotiq_imaging --all-features -- -D warnings`. Dart gate = `flutter analyze` (0 err/warn in changed files) + targeted `flutter test`. FRB phase additionally needs a successful regen + full-workspace build.

| Phase | Deliverable | Gate |
|---|---|---|
| **P0** | `fits.rs` F32 write/read; `integration/` skeleton + `mod.rs` | imaging `cargo test` + clippy; round-trip F32 FITS test |
| **P1** | `align.rs` (detection refine + quad matcher + RANSAC similarity/affine/homography) + `resample.rs` (bilinear/Catmull/Lanczos) | synthetic frames: known rotation/scale/flip recovered within RMS < 0.3 px; resampler kernel unit tests |
| **P2** | `weighting.rs` + `normalize.rs` | synthetic SNR/FWHM weights monotone; normalization brings two scaled/offset frames into agreement < 1% |
| **P3** | `integrate.rs` (batch combine + all reject algos + maps, row-band streaming) | synthetic: injected hot column/trail rejected; weighted-mean correctness vs analytic; memory bounded |
| **P4** | `master.rs` accumulation (create/add/finalize/serialize) + sidecar round-trip | accumulate-in-3-batches == single-batch weighted mean within float ε; serialize/deserialize identity |
| **P5** | `calibration_ext.rs` master-flat build + defect-map cosmetic wiring; `drizzle.rs` | master-flat normalizes to mean 1.0; drizzle on dithered synthetic improves sampling |
| **P6** | FFI: 3 JSON functions + regen | regen clean; workspace build; bridge JSON contract tests |
| **P7** | Dart: `IntegrationSettings`, `PostSessionIntegrationService`, DB tables + migration, `FlatLibraryService`, `MasterAccumulationService` | `flutter analyze` clean; service unit tests (mock seam like `stacking_engine_seam.dart`); migration test |
| **P8** | UI: Session Review screen + settings panel + master library + auto-hook | `flutter analyze`; widget tests; golden for the new screen |
| **P9** | TPS distortion correction + local normalization grid (advanced extras) | synthetic curved-field recovery; local-norm gradient removal |

**Realistically PI-grade now (algorithmically sound, deterministic, unit-testable on synthetic data):**
- Quad-asterism matching + RANSAC similarity/affine/homography (this is the documented astrometry.net/PixInsight approach).
- Lanczos/Catmull-Rom resampling, weighted batch integration with Winsorized-sigma / linear-fit / percentile rejection, rejection/coverage maps.
- Weighted-mean master accumulation (exact, provably accumulable).
- Master-flat build (reuses the already-tested `combine_master_frames`) and defect/cosmetic correction (reuses tested `defect_map.rs`).

**Needs real-data tuning before claiming parity (honest deferrals — flag, don't fake):**
- **Noise/weight evaluator constants** — the SNR/FWHM/ecc weight exponents and the auto-cull percentiles need tuning against real sub sets; ship defensible defaults, expose the knobs, revisit with real frames (matches the "made honest, not functional" lesson in MEMORY.md).
- **TPS distortion + local normalization** — algorithmically correct but the regularisation λ / grid resolution need real wide-field data; ship behind off-by-default presets (P9).
- **Drizzle** — correct reconstruction, but pixfrac/scale sweet spots and the "is it actually under-sampled + dithered" auto-detector need on-sky validation; off by default.
- **Accumulation rejection vs full batch re-clip** — running online clip is the accepted accumulation tradeoff, not bit-identical to re-integrating every night's full population; the master records `accumulation_mode` so the UI can offer a "full re-integrate from archived subs" path when subs are still on disk.

---

## 6. Files touched / created (summary)

**New native** (`native/skotiq_native/imaging/src/integration/`): `mod.rs`, `align.rs`, `resample.rs`, `weighting.rs`, `normalize.rs`, `integrate.rs`, `drizzle.rs`, `master.rs`, `calibration_ext.rs`.
**Edited native:** `imaging/src/fits.rs` (F32 write/read), `imaging/src/lib.rs` (module wiring), `bridge/src/api/imaging.rs` (3 FFI fns), bridge event-stream progress events.
**New Dart core:** `models/imaging/integration_settings.dart`, `services/post_session_integration_service.dart`, `services/master_accumulation_service.dart`, `services/flat_library_service.dart`, `database/tables/{integrated_masters,integrated_master_frames,flat_library}.dart` + DAOs; `database/database.dart` registration + migration (schemaVersion 40 → 41).
**Reused Dart core (no rewrite):** `services/stack_light_selector.dart`, `services/calibration_service.dart`, `services/dark_library_service.dart`, auto-stretch path, `daos/images_dao.dart`, `daos/stacked_results_dao.dart`.
**New/edited app UI:** `screens/session_review/` (screen + `integration_settings_panel.dart`, `master_library_panel.dart`), promote `analytics/widgets/image_thumbnail_strip.dart` + add blink/multi-select, lift reject-only gate in `sequencer/widgets/run_dashboard/frame_detail_dialog.dart`, reuse `stack_result/widgets/astro_image_viewer.dart` + `diagnostics/{psf_field_map,residual_vector}.dart`, auto-integrate hook in the run-completion path.

---

## 7. What shipped & honest quality assessment (as-built, 2026-06-07)

This section records the **as-built** feature against the design above, verified by re-running every gate (not self-report). All work is on `roadmap/planetarium-atlas-and-perf`, not pushed.

### 7.1 What shipped end-to-end

**Native algorithm layer** (`native/skotiq_native/imaging/src/`, committed `1850a67a` -> `0ee6d0e9`). Landed as **flat top-level modules**, not the proposed `integration/` subtree (functionally identical; the flat layout matches the crate's existing convention â€” `stacking.rs`, `calibration.rs`, etc.):

- `registration.rs` (1809 lines) â€” robust star detection + flux-weighted centroid refinement, **triangle/quad asterism matching** (rotation/scale/flip-invariant), **RANSAC over a model hierarchy** (`TransformModel` Similarity / Affine / Homography stored as a single 3x3 homogeneous matrix), least-squares inlier refinement, **Lanczos3 / Catmull-Rom resampling** with bounds clamping. Reports inlier count + RMS/peak residual.
- `frame_weighting.rs` (826 lines) â€” `FrameQuality` (noise via **MAD of the 3x3-median residual**, SNR, FWHM/HFR, eccentricity, star count, background) -> scalar weight via `WeightFormula` (SNR / SNR^2 / FWHM-inverse / custom exponents) normalized to best-sub = 1.0, plus a `CullPolicy` recommendation.
- `normalization.rs` (986 lines) â€” additive (background) + multiplicative (scale) match to reference via robust linear fit, **`CoverageMask`** so warp-border zero-fill never contaminates the fit, optional local grid.
- `integration.rs` (1458 lines) â€” **batch** combine (mean/median) with all five rejection algorithms: `SigmaClip`, `WinsorizedSigmaClip`, `LinearFitClip`, `PercentileClip`, `MinMax`, plus `None`; weighted by per-sub weight x per-pixel coverage; emits the master (F32 linear) + **rejection-count map** + **coverage map** + per-frame records.
- `master_accumulation.rs` (1578 lines) â€” serializable `IntegratedMaster` running weighted sums (`sum_w`, `sum_wx`, `sum_wx2`) -> **exactly accumulable weighted mean**; frozen normalization + geometry reference; online k-sigma clip on add (`AccumulationMode::RunningWeightedMean { clip }`); versioned `serialize`/`deserialize` with magic-byte container (mirrors `defect_map.rs`); the `None`-clip path is provably bit-equal to a single-batch weighted-mean integration.
- `calibration_masters.rs` (853 lines) â€” `build_master_flat` (pedestal-subtract -> `combine_master_frames` Flat-kind -> **unit-mean normalize** so `divide_flat` works) + cosmetic hot/cold-pixel correction + defect map. Fails closed on degenerate input.
- `fits.rs` â€” **F32 (BITPIX -32) read + write** so linear masters survive without quantization (the called-out gap).

**FFI** (`bridge/src/api/post_session.rs`, 1981 lines, committed `3e0a5d19`; FRB regenerated + committed). Exactly **four** `String -> Result<String, String>` JSON entrypoints (all DTOs `#[frb(ignore)]`, so future knobs never trigger a regen â€” the live-stacker trick):

- `api_integrate_session` â€” one-shot **calibrate -> register -> normalize -> weight -> integrate(reject)** into a 16-bit/float linear FITS master + stretched preview PNG + optional rejection-map FITS; returns frames integrated/rejected, total integration seconds, mean RMS residual, per-frame cull stats. Smart reject auto-select by sub count (percentile <8, winsorized-sigma 8-24, linear-fit >=25).
- `api_master_accumulate` â€” create / add / finalize / info over `IntegratedMaster`; freezes a registration-reference companion FITS at create; resumable via the `.nsmaster` sidecar.
- `api_build_master_flat` â€” unit-mean master-flat build (+ optional bias/dark-flat pedestal).
- `api_save_fits_master` â€” re-export an in-memory F32/U16 buffer as a provenance-carrying FITS master.

> **Known latent bug (out of scope, flagged):** the pre-existing `api_combine_master_frames` writes 9-char FITS keywords `INPUTMEAN` / `OUTPTMEAN` (FITS keywords max 8 chars). The new path writes the correct `INMEAN` / `OUTMEAN`. The old function should be fixed in a follow-up.

**Dart pipeline** (`packages/skotiq_core/`, committed `7b8268e4`):

- `IntegrationSettings` (816 lines) â€” every advanced knob + smart defaults + named presets (Fast / Balanced / Maximum-Quality / Few-Subs / Long-Night-Gradient); `smartDefaults()` resolves the auto-rejection rule by sub count; JSON round-trip + bridge-args.
- `PostSessionSeam` / `BridgePostSessionSeam` â€” injectable interface over the four FFI calls (mirrors `StackingEngineSeam`, so the services are unit-testable without the native layer).
- `PostSessionIntegrationService` â€” per-filter accepted-sub integration; resolves dark (DarkLibrary) + flat (FlatLibrary) calibration; persists an `integrated_masters` row + per-sub fold records.
- `MasterAccumulationService` â€” multi-night create/add/finalize/info with **image-id dedup** via the join table (a sub is never double-folded).
- `FlatLibraryService` + `flat_library` table â€” the missing master-flat artifact library; `findBestMatch` mirrors `DarkLibrary`.
- New tables `integrated_masters` / `integrated_master_frames` / `flat_library` + DAOs (`integrated_masters_dao.dart`, `flat_library_dao.dart`) + **schemaVersion 40 -> 41** migration (`migration_v41.dart`, idempotent, runs from onCreate and onUpgrade).

**UI** (`packages/skotiq_app/lib/screens/session_review/`, committed `97e50767`): Session Review / Morning Report screen + controller + auto-integration service, with `sub_gallery_panel` (quality badges, accept/reject cull, **blink mode**, bulk reject-above-HFR), `integration_settings_panel` (smart-default preset chips + collapsible Advanced section + live "will use N subs" readout), `master_library_panel`, `master_preview_view`. Reuses the existing `FrameDetailDialog`.

### 7.2 Verification (gates re-run 2026-06-07, real output)

| Gate | Command | Result |
|---|---|---|
| Native tests | `cargo test -p skotiq_imaging` | **308 + 12 + 1 = 321 pass / 0 fail** |
| Native lint | `cargo clippy -p skotiq_imaging --all-features -- -D warnings` | **clean (exit 0)** |
| Bridge build | `cargo build -p skotiq_bridge` | **clean (exit 0)** |
| Core analyze | `flutter analyze` (skotiq_core) | **0 errors** (205 pre-existing infos/warnings in unrelated test files; 0 in any post-session file) |
| App analyze | `flutter analyze` (skotiq_app) | **0 errors** (97 pre-existing infos in unrelated test files; 0 in any session_review file) |
| Core tests (new) | settings / integration-service / accumulation / flat-library / migration | **35 pass** |
| UI tests (new) | `test/screens/session_review/` | **8 pass** |
| Desktop build | `flutter build windows --release` (apps/desktop) | **success** â€” `skotiq_desktop.exe` built fresh (88.9 s); **FRB bindings are fully regenerated and committed, no regen needed** |

### 7.3 Honest quality assessment vs PixInsight

**Algorithms that reach serious (PI-comparable) quality â€” sound, deterministic, unit-tested on synthetic data:**

- **Registration.** Quad-asterism matching + RANSAC similarity/affine/homography is the documented astrometry.net / PixInsight `StarAlignment` approach. Synthetic tests recover known translation/rotation/scale within sub-pixel RMS and survive 30 % spurious stars. This is genuinely in the right algorithmic class.
- **Resampling.** Lanczos3 (windowed-sinc) and Catmull-Rom are PixInsight's own registration interpolators; the per-channel f64 pipeline avoids intermediate quantization.
- **Batch integration + rejection.** Weighted mean/median with Winsorized-sigma, linear-fit-clip, percentile, sigma, and min-max rejection â€” the same family PixInsight ships, with the same "linear-fit best for many subs" guidance baked into the smart default. Rejection + coverage maps are produced.
- **Master-flat build** reuses the already-tested `combine_master_frames` and unit-mean normalizes correctly; **cosmetic/defect correction** reuses the tested `defect_map.rs`.
- **Multi-night accumulation (weighted mean)** is *provably* accumulable: the `None`-clip path is bit-equal to a single-batch integration of the same frames (verified by the accumulate-in-batches == single-batch test), and the F32 linear FITS master is archival-grade.

**Needs real-data / reference-stack validation before claiming parity (honest deferrals â€” flagged, not faked):**

- **Weight/noise evaluator constants.** The SNR/FWHM/ecc weight exponents and the auto-cull percentiles are *defensible defaults*, not tuned against real sub sets. They are monotone and correct in direction (better SNR/FWHM => higher weight) but the exact curve needs A/B against PixInsight's PSF Signal Weight on real data. Knobs are exposed.
- **Accumulation rejection != full batch re-clip.** The online k-sigma clip on `add_frames` is the accepted accumulation tradeoff, not bit-identical to re-integrating every night's full population. The master records `accumulation_mode` so a future "full re-integrate from archived subs" path can be offered when subs are still on disk.
- **No on-sky end-to-end run yet.** Every test is synthetic-frame. Registration RMS, rejection of real satellite trails/planes, normalization under a moving-moon gradient, and preview-stretch aesthetics all need a real multi-sub night before a parity claim.

**Designed but NOT shipped in this pass (off-by-default extras from the original P5/P9):**

- **Drizzle** (`integration/drizzle.rs`) â€” not implemented. Correct reconstruction is well understood but pixfrac/scale sweet spots + the "is it actually under-sampled & dithered" auto-detector need on-sky validation; deferred.
- **Thin-Plate-Spline distortion correction + local-normalization grid** â€” `TransformModel` stops at Homography; the local-norm grid scaffolding exists in `normalization.rs` but the TPS warp + auto-lambda are not wired. These are the wide-field/long-night extras; deferred behind would-be off-by-default presets.

### 7.4 Advanced settings + smart defaults (as-built)

`IntegrationSettings` exposes: transform model, resampler, RANSAC threshold, max ref stars, weighting formula + auto-cull + percentile, normalization mode, combine, **reject = AUTO** (resolved by sub count), reject low/high sigmas, rejection-map generation, output bit depth. **Smart-default rule:** `<8 subs -> PercentileClip`, `8-24 -> WinsorizedSigmaClip`, `>=25 -> LinearFitClip`; resampler `Lanczos3` unless the Fast preset; presets Fast / Balanced / Maximum-Quality / Few-Subs / Long-Night-Gradient. The settings panel surfaces the **auto-chosen reject algorithm for the current sub count** and a live "will use N of M subs" readout, so the smart default is transparent rather than hidden.

### 7.5 Multi-night accumulation design (as-built)

A `.nsmaster` sidecar holds the resumable per-pixel accumulator (`sum_w`, `sum_wx`, `sum_wx2`, coverage, rejected) + frozen normalization reference + frozen geometry reference + per-night log; the shareable artifact is the finalized F32 FITS. `create` freezes a registration-reference companion FITS so every later night aligns to the same grid; `add` normalizes incoming subs onto the frozen photometric anchor, online-clips, and folds; `finalize` divides out the weighted mean and writes the FITS + preview (re-openable for more adds). The Dart `integrated_master_frames` join dedups by image id so re-running an add never double-counts a sub.

### 7.6 Follow-up list

1. **On-sky validation run** â€” drive a real multi-night sub set through `PostSessionIntegrationService` end-to-end; measure registration RMS, confirm trail/plane rejection in the rejection map, eyeball the preview stretch. (Highest priority â€” converts "algorithmically sound" into "verified.")
2. **Tune weight/cull constants** against real data + a PixInsight reference stack; revisit the SNR/FWHM/ecc exponents and auto-cull percentile.
3. **Fix the latent `INPUTMEAN`/`OUTPTMEAN` 9-char FITS keyword bug** in the pre-existing `api_combine_master_frames` (the new path already uses `INMEAN`/`OUTMEAN`).
4. **Drizzle** (P5) â€” implement `drizzle.rs` + the under-sampled/dithered auto-detector; ship off by default.
5. **TPS distortion correction + local-normalization grid** (P9) â€” wire the TPS warp + auto-lambda and the local-norm grid into the pipeline behind the Long-Night-Gradient / wide-field presets.
6. **"Full re-integrate from archived subs"** path for accumulating masters (re-clip the entire population when subs are still on disk), to close the online-clip vs batch-clip gap when the user wants it.
7. **Auto-integrate-at-run-end** opt-in hook â€” the scaffolding `auto_integration_service.dart` exists; verify it is actually invoked from the sequencer run-completion flow and surfaced in the morning report.
