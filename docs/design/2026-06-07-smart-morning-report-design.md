# Smart Morning Report & Master Forge — Technical Design

- **Date:** 2026-06-07
- **Branch:** `feature/smart-integration-morning-report`
- **Status:** ✅ **SHIPPED end-to-end** (built 2026-06-08, on `feature/smart-integration-morning-report`, not pushed). All five pillars + the broad algorithm track + the layered narrative/workbench UI landed and are gate-green. See **§10** for the as-built record, the re-run verification table, and the honest gap list. §0–§9 are preserved as the original design contract.
- **Builds on:** `docs/design/2026-06-07-post-session-integration-design.md` (the shipped batch-integration pipeline). That doc delivered a PixInsight-class *engine*; this doc turns the engine into a *smart, opinionated finishing room* by fusing it with everything else Skotiq already knows about the night.
- **North star:** when the imager wakes up, the master isn't just *built* — the app has **understood the night**, **proven the master is as good as it can be**, **calibrated and annotated it using its own catalogs**, and **told the imager what to do next** — all in a UI that feels like a morning briefing, not a settings dialog.

---

## 0. Scope & philosophy — why this is different

The shipped pipeline (`PostSessionIntegrationService` → `api_integrate_session` → `registration.rs`/`frame_weighting.rs`/`normalization.rs`/`integration.rs`/`master_accumulation.rs`) already produces an archival linear master with PixInsight-family rejection. That is table stakes. Every serious package does it.

**The moat is integration with the rest of Skotiq.** PixInsight, APP, and Siril are *finishing-only* tools — they get a folder of subs and nothing else. Skotiq owns the *whole night*: the per-sub quality metrics in `captured_images`, the PSF field maps and residual vectors (`optical_train_diagnostics_service.dart`, `psf_field_map.dart`, `residual_vector.dart`), the guiding history (PHD2), the autofocus history, the weather log, the scheduler autopilot (`scheduler_engine.dart`), a built-in HYG star catalog + OpenNGC DSO catalog + plate solver (`skotiq_planetarium`, `platesolve.rs`, `wcs_overlay.dart`), and a push-notification service. **No finishing tool on earth has that context.** This design spends it.

Five pillars, plus a broad algorithm-depth track and a cross-cutting progress foundation. Each pillar is independently shippable and gated.

**Preserve-exactly invariants** (do not regress): the existing `api_integrate_session` calibrate→register→normalize→weight→integrate chain, the `IntegratedMaster` weighted-mean accumulation parity (`None`-clip path is bit-equal to single-batch), the schema-v41 tables and their dedup join, the live `LiveStacker` singleton path (untouched — the two pipelines stay separate per the prior design). Everything below is **additive**.

**Reuse, do not rewrite.** The grounding inventory (verified by reading the source):

| Capability | Where | Surface used |
|---|---|---|
| Per-sub quality | `frame_weighting.rs` | `FrameQuality { noise, background, snr, fwhm, eccentricity, star_count }`, `analyze_frame_quality`, `weight_frames` → `WeightingReport`/`CullPolicy` |
| Batch integrate | `integration.rs` | `integrate_frames(frames, cfg)` → `IntegrationOutput { master, rejection_map, weight_map, stats }` |
| Star detection | `stats.rs` | `detect_stars` / `detect_stars_with_stats` → `DetectedStar { x, y, flux, hfr, fwhm, peak, background, snr, eccentricity, sharpness }`; `calculate_median_hfr`, `frame_eccentricity` |
| Registration | `registration.rs` | `register_frame`, `TransformModel` (Similarity/Affine/Homography, 3×3), `Interpolator` (Bilinear/CatmullRom/Lanczos3) |
| Accumulating master | `master_accumulation.rs` | `IntegratedMaster::{create,add_frames,finalize,serialize,deserialize}` |
| Master flat / cosmetic | `calibration_masters.rs` | `build_master_flat`, defect/cosmetic correction |
| FITS + WCS | `fits.rs` | `read_fits`/`write_fits` (incl. F32 BITPIX -32), `WcsInfo`, `add_wcs_headers` |
| Plate solve | `platesolve.rs` | `AstapSolver::solve` → `PlateSolveResult { ra, dec, pixel_scale, rotation, … }` |
| Pixel↔sky | `wcs_overlay.dart` | `WcsOverlay.pixelToCelestial(x,y)`, `celestialToPixel(ra,dec)` (TAN projection, bidirectional) |
| Star catalog | `skotiq_planetarium` | `HygStarCatalog.getStarsNear(center, radius, {maxMagnitude})` → `Star { magnitude, colorIndex (B-V), spectralType, coordinates }` |
| DSO catalog | `skotiq_planetarium` | `CatalogManager.searchDsoNearby({ra, dec, radiusDegrees, maxMagnitude})`; `DeepSkyObject { name, coordinates, type, magnitude, sizeArcMin, positionAngle }` |
| Scheduler | `scheduler_engine.dart` | integration goals, `scoreCandidate`, `previewRanking` (read-only) |
| Push | `push_notification_service.dart` | `enqueueCriticalNotification` and friends |
| Bridge events | `event_stream.rs` | existing app-wide event channel (currently **not** used by post-session — see §3) |
| Stretch/preview | `stretch.rs`, auto-stretch path used by `StackAndShareService` | preview PNG generation |

---

## 1. North-star UX — the Morning Report

The current `session_review_screen.dart` is three functional tabs (Subs / Integrate / Masters). The redesign makes it a **layered** experience (the user picked "both, layered"):

- **Narrative view (default, "the briefing").** A single vertical scroll you read like a story:
  1. **Hero** — the finished, color-calibrated, annotated master, auto-stretched, fills the top. One line: *"While you slept, I built 6h 12m on NGC 7000 from 74 of 81 subs."*
  2. **The verdict** — Night-Doctor headline (§2.1): *"Good night. Focus held, guiding was clean. 7 subs lost to a passing cloud at 02:14 — already excluded."*
  3. **Proof it's optimal** — the integration-improvement curve (§2.2) with the chosen cut marked: *"Keeping all 81 subs would have been 4% noisier. I used the best 74."*
  4. **What I fixed / found** — Night-Doctor finding cards, each with severity, evidence thumbnail, and a *"next time: …"* action.
  5. **The growth story** (multi-night, §2.5) — integration-time growth curve, best-night badge, *"2.5 h more gets you to your target SNR — I've added it to tonight's plan."*
  6. **Calibrated & labelled** — annotation toggle, before/after color-calibration swatch.
- **Workbench view (one tap, "the cockpit").** The same data as dense, fast, power-user panels: full per-sub table with every metric sortable, PSF field map per sub, blink/compare, A/B of two integration recipes, rejection/coverage/annotation overlays, the palette mixer (§ algo track), manual cull with lasso, re-integrate with edited settings. This is where a serious imager lives.

A single `SessionReviewController` state feeds both; the views are two renderings of one model. The narrative view computes nothing the workbench can't show and vice-versa.

**Design-system discipline:** `skotiq_ui` tokens/components throughout (`SkotiqCard`, the token/icon migration maps under `docs/design/`). No bespoke colors. Charts via the existing charting approach used in Analytics.

---

## 2. The pillars

### 2.1 Pillar 1 — The Night Doctor (root-cause diagnosis)

**Goal:** read the *whole* night and tell the imager what happened and why, in plain language, with evidence and fix-advice.

**Inputs (all already captured):** per-sub `FrameQuality` + the richer per-sub columns in `captured_images` (HFR, eccentricity, SNR, background, star count, timestamp, filter, guiding RMS at capture, focus position), the per-sub PSF field maps (`optical_train_diagnostics_service.dart`), PHD2 guiding history, autofocus history, the weather log.

**Engine (`NightAnalysisService`, Dart core).** A deterministic, rule-based analyzer (no ML) that runs a battery of detectors over the per-sub time series and emits `NightFinding { id, severity (info/warn/critical), title, explanation, evidenceSubIds, thumbnail?, advice, metricSeries? }`:

- **Focus drift** — regression of HFR (and focus position) vs time/temperature; flags monotone degradation and recommends tighter autofocus cadence or temperature-compensation tuning. (Reuses HFR series; cross-references autofocus events.)
- **Tilt / collimation** — aggregate the per-sub PSF field maps: persistent corner-vs-center HFR asymmetry across the night ⇒ tilt; radial symmetric bloat ⇒ spacing/collimation. Surfaces the offending corner and a magnitude. (Reuses `PsfFieldMap` inputs at per-sub granularity.)
- **Cloud / transparency loss** — detect step/down excursions in star-count and background-corrected SNR vs the night's robust baseline; cluster consecutive bad subs into "events" with a time range. These become the auto-cull recommendation feeding §2.2.
- **Satellite / plane / cosmic hits** — read the integration **rejection map** (`IntegrationOutput.rejection_map`): localized high-rejection streaks ⇒ flag the sub(s) and time. (Reuses an artifact we already produce.)
- **Guiding correlation** — correlate guiding-RMS spikes with elongated/high-eccentricity subs; attribute trailing to mount vs wind.
- **Moon-gradient onset** — rising background gradient through the night cross-referenced with moon altitude (Skotiq already computes moon ephemeris in `astronomy_helpers.dart`); recommends the local-normalization preset (already implemented in `normalization.rs`).
- **Dew / sudden HFR collapse** — sharp irreversible HFR/star-count drop ⇒ dew or clouds; distinguishes by recovery shape.

**Output:** a ranked `NightReport { headline, score (0–100), findings[] }`. The headline + score drive the narrative "verdict"; the findings render as cards. Severity sets order and color.

**Native vs Dart split:** the time-series statistics (robust baselines, step detection, regressions) are light and live in Dart core (`NightAnalysisService`) operating over DB rows — no native needed for most detectors. The **rejection-map streak analysis** is the one heavier pass; it can read the already-written rejection-map FITS in Dart, or (if it's slow on 60 MP) a tiny native helper `analyze_rejection_map(path) -> [Streak]`. Default: Dart-first; add native helper only if profiling demands.

**Honest limits:** thresholds (what counts as a "cloud step," tilt magnitude that matters) are defensible defaults exposed as constants; they need tuning against real nights. Findings are advisory, never destructive — culling is always a recommendation the user confirms.

### 2.2 Pillar 2 — The Marginal-SNR Optimizer (culling that proves itself)

**Goal:** answer "is it worth keeping?" quantitatively, and pick the optimal subset + reference automatically.

**The curve.** Rank subs by integration weight (we already compute `weight_frames` → normalized weights). For the top-N subset (N = 1..total), estimate the master's SNR and FWHM. Key insight — we do **not** re-integrate N times (too slow for 60 MP × 80 subs). For a weighted mean of independent frames, background-limited noise scales as σ_master(N) ≈ 1 / √(Σ_{i≤N} wᵢ · (1/σᵢ²)-equivalent), and stacked signal is ~constant, so **SNR(N) is an analytic function of the per-frame `FrameQuality` + weights** — computable in microseconds. Effective FWHM(N) ≈ weighted-mean FWHM of the kept set (a slight over-estimate; honest). The curve has the classic shape: steep early gains, a knee, then a flat or *declining* tail when low-quality subs add more noise than signal under non-ideal weighting.

**The recommendation.** The optimal cut is the N maximizing estimated SNR (or the knee, under a user "aggressiveness" knob). Output: *"Use best 74 of 81 (+4% SNR vs all; the last 7 are cloud-degraded)."* Cross-reference the §2.1 cloud events so the dropped subs have a *reason*, not just a number.

**Verification.** Because the estimate is analytic, offer an optional **verified re-integration** at the chosen N (one real `integrate_frames` call) to confirm the predicted SNR before committing — shown as "predicted +4%, measured +3.7%."

**Reference-frame optimization.** Today the reference is "best sub by HFR." Generalize: pick the reference that minimizes total registration residual *and* sits near the median scale/rotation (so warps are small) — a cheap score over the already-detected star lists. Surfaced as "reference: sub #23 (best seeing, central pointing)."

**Native surface:** `integration_curve(qualities: &[FrameQuality], weights: &[f64]) -> Vec<CurvePoint { n, snr, fwhm, cumulative_integration_s }>` + `recommend_subset(...) -> SubsetRecommendation { keep_n, keep_ids, predicted_gain, reason_hint }`. Pure, deterministic, trivially unit-testable (monotone SNR for equal-quality subs; declining tail when a noisy sub is appended). Exposed through the FFI as part of the analysis result (§4).

**Honest limits:** the analytic SNR(N) assumes background-limited, independent noise and the configured weighting; the verified re-integration is the ground truth when the user wants certainty. We state the assumption in the UI tooltip.

### 2.3 Pillar 3 — Catalog-powered finishing (the differentiator)

Three features, all leaning on assets PixInsight has to download or fake.

**(a) Photometric color calibration.** The full chain is confirmed present:
1. `detect_stars` on the linear master → `DetectedStar { x, y, flux, snr }`.
2. WCS for the master — from a plate solve of the master (`AstapSolver::solve`) or carried from the reference sub's solve; stored as `WcsInfo` in the FITS.
3. For each detected star, `WcsOverlay.celestialToPixel`/`pixelToCelestial` maps to sky; `HygStarCatalog.getStarsNear` returns catalog `Star { magnitude, colorIndex (B-V) }`.
4. Cross-match detected↔catalog by sky proximity (arcsec), reject blends/saturated/low-SNR.
5. Solve per-channel scale factors so the matched stars' instrumental colors match the catalog B-V relation (a robust linear fit in log-flux vs B-V per channel; for OSC, R/G/B; for mono filter sets, per-filter zero-points). Apply scale to the linear master → photometrically white-balanced master.

This is **SPCC-grade color calibration using Skotiq's own catalog** — no Gaia download, no eyedropper. Orchestrated in Dart (`ColorCalibrationService`) calling native `detect_stars` + a small native or Dart robust linear solve; the catalog + WCS are Dart.

**(b) Auto-annotated master.** With the WCS + catalogs: `CatalogManager.searchDsoNearby` over the master's field returns DSOs (name, position, size, PA); `HygStarCatalog.getStarsNear` returns named bright stars. Map each to pixel via `celestialToPixel`. Produce an **annotation layer** `[Annotation { label, x, y, kind, sizePx, paDeg }]` rendered as a toggleable overlay in `astro_image_viewer.dart`, and exportable as a burned-in annotated PNG. The finished image labels itself — galaxies, nebulae, Messier/NGC numbers, named stars.

> **Gap to close:** the DSO catalog has no native cone search; the Dart `CatalogManager.searchDsoNearby` workaround exists and is sufficient. Both features run in Dart; no new native catalog code.

**(c) Background / gradient extraction (DBE/ABE analogue).** New native module `background_extraction.rs`: place a grid of sample boxes, reject any box containing stars/nebulosity (use the detected-star mask + a robustness pass), fit a low-order 2-D polynomial (or thin-plate spline reusing the TPS math the prior design deferred) to the surviving background samples, subtract. Removes moon/light-pollution gradients from the linear master before stretch. Exposed as an integration post-step and a manual button. Default tolerance conservative; user can add/remove sample points in the workbench.

**Honest limits:** color calibration quality depends on a good plate solve and enough catalog matches (sparse high-galactic-latitude fields have few bright stars — fall back to "insufficient stars, skipped" rather than fabricating). Gradient extraction's polynomial order is a knob; over-fitting eats real nebulosity, so default low order + star-masked samples, and always show before/after.

### 2.4 Algorithm-depth track (PixInsight-parity muscle — the user chose "go broad")

Independent of the smart pillars; each is a native module behind an off-by-default setting with a smart-preset trigger.

- **Drizzle + Bayer drizzle** (`drizzle.rs`, the prior design's deferred P5). Classic Fruchter–Hook variable-pixel reconstruction: map each input pixel as a shrunken drop (pixfrac default 0.9) through the inverse `TransformModel` onto a finer grid (scale 2.0), accumulating drop-area-weighted flux + weight, final = flux/weight. **Bayer drizzle** for OSC: drizzle each CFA color plane separately from the raw mosaic (no debayer interpolation), reconstructing true color at higher resolution — a genuine quality win for dithered OSC rigs. Row-band streamed like `integrate.rs`. Auto-trigger only when dither + under-sampling detected from sub metadata.
- **Linear deconvolution preview** (`deconvolution.rs`). Estimate the PSF from the master's detected stars (median star profile → parametric Moffat/Gaussian kernel). Richardson–Lucy (or regularized RL) on the *linear* master, with a star mask to suppress ringing. Shipped as a **preview** (non-destructive layer the user can dial), not an auto-applied step — deconvolution is taste-sensitive.
- **Star reduction preview** (`star_reduction.rs`). Detect stars, build a star mask, apply a morphological/мorphological-transform shrink or a screened residual reduction, composite back. Preview only, strength slider.
- **SHO / HOO narrowband palette mixing.** This is a *compositing* feature over multiple per-filter masters (Ha/OIII/SII), not a stacking change. Native `channel_combine(masters, palette_matrix)` does the linear channel math; the **UI palette mixer** (sliders + named presets SHO/HOO/Foraxx-style) gives a live preview. Per-filter masters already exist (the pipeline makes one master per filter). This turns Skotiq into a one-stop narrowband finisher.

**Honest limits:** drizzle pixfrac/scale sweet spots, the under-sampled+dithered auto-detector, deconvolution iteration/regularization, and palette aesthetics all need on-sky validation. All ship off-by-default or as previews, with the knobs exposed.

### 2.5 Pillar 4 — The living multi-night project + scheduler loop

**Goal:** make the accumulating master a project the imager watches grow, and close the loop with the autopilot.

- **Growth story.** Per-night fold log already exists in `integrated_master_frames`; surface an integration-time-vs-date growth curve, total hours per filter, and a "best night so far" badge (night with highest mean weight).
- **Auto-re-reference.** If a later night delivers a materially better reference (seeing/pointing) than the frozen one, *offer* to re-reference (re-register the accumulator to the better grid). Honest tradeoff: re-reference requires the subs on disk; gated and explained.
- **"How much more?" → scheduler.** From §2.2's SNR curve and a user **target SNR / target integration time** per target, compute the remaining hours needed and feed it into `scheduler_engine.dart`'s integration goals so the autopilot schedules the deficit automatically. The narrative report says *"2.5 h more on Ha to hit target — added to tonight's plan,"* and it actually happens. This is the unique full-loop story: capture → integrate → analyze → re-plan, unattended.
- **Push when ready.** On auto-integrate completion (the existing `auto_integration_service.dart` hook), fire `push_notification_service` so the imager gets *"Your NGC 7000 master is ready — 6h 12m, +4% from culling"* on their phone.

**Native vs Dart:** all Dart/DB/provider wiring + a read of §2.2's curve; the scheduler integration reuses the existing integration-goals surface (no autopilot decision-math change — preserve-exactly).

### 2.6 Pillar 5 — Layered UI (covered in §1; component inventory)

Reuse-first component plan:
- Hero/master viewer + overlays — extend `stack_result/widgets/astro_image_viewer.dart` with rejection/coverage/annotation overlay toggles.
- Per-sub field quality — reuse `diagnostics/psf_field_map.dart` (the shared `PsfFieldMapView` painter extracted from the diagnostics part-file) at per-sub granularity. Astrometric residual vectors (`residual_vector.dart`) remain on the Diagnostics surface for now; the workbench renders the PSF field map per sub.
- Sub gallery + cull + blink — extend the existing `session_review/sub_gallery_panel` (already has blink mode + bulk reject); add lasso/multi-select and the improvement-curve-linked cull.
- Curve + growth charts — new widgets using the Analytics charting approach.
- Night-Doctor cards — new `night_report_panel` with severity-styled `SkotiqCard`s.
- Palette mixer — new `narrowband_mixer_panel`.
- A/B compare + re-integrate — new, driving two `IntegrationSettings` through the service.
- Progress — bind the (now real, §3) progress stream to the existing `integrationProgress` state field.

---

## 3. Cross-cutting foundation — real progress reporting

**Today the progress is dead end-to-end** (verified): `post_session.rs` emits no events; the Dart `SessionReviewState.integrationProgress` is only ever set to 0. A multi-minute integration shows a frozen spinner.

**Fix (foundational, build first):** thread the native `integrate_lights` `progress: &dyn Fn(f32)` out through `event_stream.rs` as `IntegrationProgress { phase, fraction }` events (phases: calibrating / registering / normalizing / integrating / writing / analyzing). Subscribe in `BridgePostSessionSeam`, surface on the controller's `integrationProgress` + a phase label. This unblocks every long-running operation in this design (integration, accumulation, drizzle, deconvolution) and is the single biggest perceived-quality win. ~Self-contained across bridge/seam/controller.

---

## 4. FFI surface plan (minimize regen)

Keep the JSON-in/JSON-out, `#[frb(ignore)]`-DTO discipline so new knobs never trigger an FRB regen (the established trick). Net new bridge functions, all `String -> Result<String, String>`:

- `api_analyze_night(args_json)` — runs §2.2 curve + subset recommendation natively over supplied `FrameQuality`/weights (and optional rejection-map path for streak analysis); returns curve + recommendation. (Most of §2.1 Night-Doctor is Dart-side over DB rows; this call is the heavy native stats.)
- `api_color_calibrate(args_json)` — detect stars on master + apply solved per-channel scales (catalog matching passed in from Dart, or done Dart-side and only the apply is native). Likely **no new native fn** if the apply is a trivial per-channel scale done in Dart; decide at build time.
- `api_extract_background(args_json)` — gradient extraction (§2.3c).
- `api_drizzle_integrate(args_json)` — drizzle / Bayer drizzle (§2.4).
- `api_deconvolve_preview(args_json)` / `api_reduce_stars_preview(args_json)` — preview ops (§2.4).
- `api_combine_channels(args_json)` — narrowband palette combine (§2.4).
- Extend `api_integrate_session` progress to emit events (§3) — no signature change.

Batch the bridge additions into **one regen** (regen is heavyweight per `docs/FRB_TROUBLESHOOTING.md`). Several of these may collapse into Dart-only if the native part is trivial — resolved per phase.

**Also fix the latent bug:** `api_combine_master_frames` (`bridge/src/api/imaging.rs`) writes 9-char FITS keywords `INPUTMEAN`/`OUTPTMEAN` (max 8) — correct to `INMEAN`/`OUTMEAN` as the new path already does.

---

## 5. DB schema additions (drift, follow the v41 idiom)

Bump `schemaVersion` 41 → 42, additive migration:
- `night_reports` — `id`, `sessionId`/`targetId`, `score`, `headlineJson`, `findingsJson`, `createdAt`. (Cache the Night-Doctor output so the morning view is instant.)
- `integrated_masters` gains: `colorCalibratedPath?`, `annotatedPreviewPath?`, `backgroundExtracted` (bool), `targetSnr?`, `targetIntegrationS?`, `improvementCurveJson?`. (Additive columns.)
- `narrowband_composites` (optional, if we persist mixes) — `id`, `targetId`, `paletteJson`, `componentMasterIds`, `outputPath`, `createdAt`.

Reuse `captured_images` for all per-sub metrics (no change). Reuse `integrated_master_frames` for fold/dedup (no change).

---

## 6. Build order & gates (revert-on-red per phase)

Native gate = `cargo test -p skotiq_imaging` + `cargo clippy -p skotiq_imaging --all-features -- -D warnings`. Bridge gate = `cargo build -p skotiq_bridge` (+ regen for the FFI phase). Dart gate = `flutter analyze` (0 errors in changed files) + targeted `flutter test`. UI phases add widget/golden tests.

| Phase | Deliverable | Gate |
|---|---|---|
| **F0** | **Progress events** (§3) — bridge→seam→controller; real progress bar | bridge build; analyze; manual progress moves |
| **F1** | **Marginal-SNR optimizer** native (`integration_curve`, `recommend_subset`) + tests | imaging test/clippy: monotone SNR, declining tail, knee |
| **F2** | **Night Doctor** Dart engine (`NightAnalysisService`) + detectors + `night_reports` table | analyze; service unit tests per detector on synthetic series |
| **F3** | **Color calibration** + **annotation** (Dart over catalog/WCS + `detect_stars`) | analyze; cross-match test on synthetic WCS+catalog; annotation pixel-mapping test |
| **F4** | **Background extraction** native (`background_extraction.rs`) | imaging test/clippy: synthetic gradient removed, nebulosity preserved |
| **F5** | **FFI batch** — `api_analyze_night`, `api_extract_background`, (+ any apply fns) + **one regen** + fix keyword bug | regen clean; workspace build; JSON contract tests |
| **F6** | **Dart services + DB v42** — `ColorCalibrationService`, analysis/curve wiring, schema migration | analyze; migration test; service tests via fake seam |
| **F7** | **Layered Morning Report UI** — narrative + workbench, hero/overlays/cards/curve/cull/blink/A-B | analyze; widget tests; golden for narrative + workbench |
| **F8** | **Multi-night + scheduler loop + push** (§2.5) | analyze; scheduler-goal integration test (no autopilot math change); push enqueued test |
| **F9** | **Drizzle + Bayer drizzle** (`drizzle.rs`) | imaging test/clippy: dithered synthetic improves sampling; Bayer color reconstructed |
| **F10** | **Deconvolution + star-reduction previews** (`deconvolution.rs`, `star_reduction.rs`) | imaging test/clippy: synthetic PSF deconvolved; star mask shrinks stars only |
| **F11** | **Narrowband palette mixing** native combine + `narrowband_mixer_panel` live preview | imaging test; analyze; widget test |

Phases F0–F8 deliver the *smart* product (the differentiators + UX). F9–F11 are the algorithm-depth muscle. Each phase is an independent commit; partial completion still leaves a coherent, green tree.

---

## 7. Honest deferrals, risks & what needs real data

- **Every native algorithm is unit-tested on synthetic frames only.** Registration RMS on real stars, real satellite-trail rejection, color-calibration accuracy, gradient extraction on a real moon-gradient, drizzle/decon aesthetics — all need an on-sky multi-sub night. This design ships *algorithmically sound + honest*, exactly the bar the prior post-session doc set.
- **Tuning constants** (Night-Doctor thresholds, optimizer aggressiveness, weight exponents, gradient polynomial order, drizzle pixfrac, decon regularization) are defensible defaults, exposed as knobs, flagged for real-data tuning — not faked as final.
- **Color calibration** needs a successful plate solve + sufficient catalog matches; fail-soft to "skipped, too few stars" rather than guessing.
- **Auto-re-reference** and "full re-integrate from archived subs" require subs on disk; gated and explained, never silent.
- **Scheduler loop** must not touch autopilot decision math — it only writes/reads the existing integration-goals surface (preserve-exactly W1–W5 from the architecture-unification plan).
- **Previews (decon, star reduction) are non-destructive layers**, never auto-applied — taste-sensitive operations stay under user control.

---

## 8. File inventory (new / edited)

**New native** (`imaging/src/`): `background_extraction.rs`, `drizzle.rs`, `deconvolution.rs`, `star_reduction.rs`; additions to `integration.rs` (curve/optimizer helpers, or a new `optimizer.rs`), `channel combine` helper. **Edited native:** `fits.rs` (none expected; WCS already present), progress plumbing into the integration entry the bridge calls.

**Edited bridge** (`bridge/src/api/`): `post_session.rs` (progress events + new ops), `event_stream.rs` (IntegrationProgress event), `imaging.rs` (keyword-bug fix), FRB regen.

**New Dart core** (`skotiq_core/lib/src/`): `services/night_analysis_service.dart`, `services/color_calibration_service.dart`, `services/annotation_service.dart`, `models/night_report.dart`, `models/integration_curve.dart`; `database/tables/night_reports.dart` + DAO; v42 migration; `integration_settings.dart` extensions (decon/star-reduction/drizzle/palette knobs). **Reused:** `wcs_overlay.dart`, planetarium catalogs, `post_session_seam.dart`, `master_accumulation_service.dart`, scheduler integration goals, `push_notification_service.dart`.

**New/edited app UI** (`skotiq_app/lib/screens/session_review/`): narrative + workbench shell, `night_report_panel`, improvement-curve + growth-curve widgets, `narrowband_mixer_panel`, A/B + re-integrate, overlay toggles in `astro_image_viewer.dart`, extend `sub_gallery_panel` (lasso/curve-linked cull), bind progress stream. **Reused:** `psf_field_map.dart` (via the extracted public `PsfFieldMapView` painter, embedded per-sub in the workbench), `frame_detail_dialog.dart`, auto-stretch path. (`residual_vector.dart` stays on Diagnostics.)

---

## 9. Summary

This turns a competent batch integrator into something no finishing tool can match, because no finishing tool *owns the night*. The master gets built, **proven optimal**, **diagnosed**, **calibrated and labelled from the app's own sky catalogs**, **grown across nights**, and **fed back into tonight's plan** — and it's all presented as a morning briefing you actually want to read, with a power cockpit one tap away. The smart pillars (F0–F8) are the moat; the algorithm-depth track (F9–F11) is the muscle that removes any reason to leave the app.

---

## 10. What shipped & honest as-built assessment (2026-06-08)

Built overnight via orchestrated multi-agent workflows (author → integrate+gate → adversarial review → fix per tier), every tier independently gated and committed. 12 commits on `feature/smart-integration-morning-report`, not pushed.

### 10.1 As-built inventory

**Native algorithms** (`imaging/src/`, 7 new modules, rayon-parallel, synthetic-data unit-tested):
- `optimizer.rs` — marginal-SNR integration curve + optimal-subset recommendation (analytic background-limited weighted-mean SNR(n), never-harm floor).
- `background_extraction.rs` — DBE/ABE star-masked polynomial gradient model with iterative *residual* rejection (preserves real nebulosity).
- `color_calibration.rs` — SPCC-style per-channel white balance from matched catalog stars (robust log-flux vs B-V fit) + apply.
- `drizzle.rs` — Fruchter–Hook variable-pixel reconstruction + Bayer (CFA) drizzle.
- `deconvolution.rs` — star-estimated PSF (empirical/Moffat/Gaussian) + regularized Richardson–Lucy preview with star protection.
- `star_reduction.rs` — mask-confined morphological / screened-residual preview.
- `channel_combine.rs` — narrowband palette mixing (SHO/HOO/custom).

**FFI** (`bridge/src/api/`): three new `finishing_*.rs` modules exposing 8 JSON functions (`api_analyze_night`, `api_detect_stars_photometry`, `api_color_calibrate`, `api_extract_background`, `api_deconvolve_preview`, `api_reduce_stars_preview`, `api_drizzle_integrate`, `api_combine_channels`), all `#[frb(ignore)]`-DTO so future knobs never re-trigger regen. `SkotiqEvent::IntegrationProgress` emitted across the integration phases. `PerFrameRecord` gained per-sub snr/fwhm/eccentricity (no regen — JSON DTO). The latent `INPUTMEAN`/`OUTPTMEAN` 9-char keyword bug is fixed.

**Dart core** (`skotiq_core`): result/report models; `PostSessionSeam` + 8 methods + a progress `Stream`; **DB schema v42** (raw-DDL: `night_reports` table + DAO; additive `integrated_masters` smart columns; per-sub snr/fwhm/ecc on `integrated_master_frames`); `IntegrationSettings` finishing knobs; `NightAnalysisService` (the Night Doctor: focus-drift / cloud-transparency / guiding-correlation / dew-collapse / moon-gradient detectors, each fail-soft, with score + headline); `ColorCalibrationService`; `MasterAnnotationService`; `SmartProjectService` (growth / best-night / re-reference advisory / target-SNR deficit → `IntegrationGoalService`, scheduler scoring untouched); `PostSessionIntegrationService` now persists per-sub metrics, computes the improvement curve, and runs gated fail-soft finishing passes.

**App** (`skotiq_app`): the layered Session Review — `NarrativeView` (hero annotated master + overlays, Night-Doctor verdict + finding cards, improvement curve, growth curve, calibrate/background actions) and `WorkbenchView` (sub-cull rail with blink/lasso/cull-to-recommended, per-sub PSF field map, master overlays, narrowband mixer, A/B compare) over one `SessionReviewController`; live progress bar bound to the IntegrationProgress stream; `auto_integration_service` fires the Night Doctor + a "master ready" push on run-completion.

### 10.2 Verification (gates re-run 2026-06-08)

| Gate | Result |
|---|---|
| `cargo test -p skotiq_imaging` | **409 pass / 0 fail** |
| `cargo clippy -p skotiq_imaging --all-features -- -D warnings` | **clean** |
| `cargo test -p skotiq_bridge --lib` | **230 pass / 0 fail** (incl. 18 finishing round-trips) |
| `cargo build -p skotiq_bridge` (+ FRB regen) | **clean** (Linux regen now correct — see §10.3) |
| `flutter analyze` skotiq_core / skotiq_app | **0 errors** |
| skotiq_core full suite | **3267 pass** (all morning-report tests green; 12 pre-existing failures unrelated — see §10.4) |
| skotiq_app session_review + golden | **39 pass**; 9 golden review PNGs in `docs/design/goldens/morning-report-*.png` (visually inspected + iterated) |

### 10.3 Notable infrastructure catch — Linux FRB regen

The first regen with a bare `flutter_rust_bridge_codegen generate` mis-generated `typedef bool = ffi.NativeFunction<...>` (the `stdbool.h`-not-found ffigen bug): it **passed `flutter analyze` but broke the Dart VM kernel FFI transform** — i.e. it would have broken the running app, and blocked every bridge-importing test from compiling. Fixed by running regen with `CPATH` at clang's resource headers, and made durable in `scripts/dev.sh` (symmetric with `dev.ps1`'s Windows CPATH). Lesson: analyze-clean ≠ runtime-clean for generated FFI; always run a bridge-importing test after a regen.

### 10.4 Honest gaps & follow-ups

- **All native tests are synthetic-frame.** On-sky validation of registration RMS, real trail/plane rejection, color-calibration accuracy, gradient extraction under a real moon, and drizzle/decon aesthetics is still the highest-value next step. Tuning constants (Night-Doctor thresholds, weight exponents, drizzle pixfrac, decon regularization) are defensible defaults, exposed as knobs, flagged for real-data tuning — not faked as final.
- **Annotation WCS source — LANDED (schema v44).** The per-master solved WCS is now persisted end-to-end: `migration_v44.dart` adds the eight CD-matrix scalars (`wcs_crval1`/`wcs_crval2`, `wcs_crpix1`/`wcs_crpix2`, `wcs_cd1_1`/`wcs_cd1_2`/`wcs_cd2_1`/`wcs_cd2_2`) to `integrated_masters`, written from the master's plate solve and read back into a `WcsOverlay`. This lights up both the catalog-annotation overlay and photometric colour calibration (each needs the master's own WCS). (The annotation *rendering* + catalog query were already done and golden-tested with a synthetic WCS.)
- **Pre-existing, unrelated test failures (NOT introduced here).** 12 `imaging_service_test` failures in the live-capture → `ScienceProcessingService` path fail on this Linux dev box; verified pre-existing (this branch never modifies `imaging_service.dart` / `science_processing_service.dart`). Out of scope for this feature; flagged for a separate Linux-port pass.
- **Deconvolution / star-reduction ship as non-destructive previews** (taste-sensitive), never auto-applied. **Drizzle / Bayer-drizzle / narrowband combine** are exposed but off-by-default / preset-gated, pending on-sky tuning of their auto-detectors.
