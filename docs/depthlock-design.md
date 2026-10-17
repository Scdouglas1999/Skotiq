# DepthLock: measurement and design note

Status: implemented end to end (region selection → persistent per-filter goal →
calibrated ingestion → depth measurement → conservative confirmation →
Smart Exposure completion → checkpoint/restart recovery → visible
explanation). Validated against synthetic nights and fake devices only; no
on-sky data has been through it. Automatic completion is off by default and
should stay advisory until the on-sky validation listed at the end has been
done on the user's own rig.

User-facing documentation lives in `docs/depthlock.md`. This note is the
technical contract: what the number means, what it assumes, where it refuses,
and what evidence exists for each claim.

## Architecture

| Layer | Where | Owns |
| --- | --- | --- |
| Estimator | `native/skotiq_native/imaging/src/depthlock/mod.rs` | Pure, deterministic measurement and stopping policy over admitted evidence. |
| Ingestion | `imaging/src/depthlock/input.rs` | Reference geometry, registration→WCS composition, signed calibration, source mask, frame identity, acquisition-provenance checks. |
| Store | `bridge/src/depthlock_service/store.rs` | One JSON record per goal, pending-file rename commits, lock file, revision and evidence-revision checks, poisoning on a failed commit. |
| Engine | `bridge/src/depthlock_service/engine.rs` | Bounded analysis queue (8 jobs, blocking-pool workers), per-frame pipeline, file-derived provenance digest, crash repair on open, the executor's verdict source. |
| API/events | `bridge/src/api/depthlock.rs`, `bridge/src/event/depthlock_events.rs` | Goal CRUD, reference inspection, selection geometry, replay, ingest; `DepthLockEvent` on the app bus. |
| Sequencer | `sequencer/src/depth_goal.rs`, `node/instructions/smart_exposure.rs` | `FilterPlan.depth_goal` binding, `DepthGoalOps` verdict trait, batch-boundary completion, `ExecutorEvent::DepthGoalCompleted`, checkpointed completions. |
| Dart | `packages/skotiq_core/lib/src/backend/roles/depthlock_backend.dart`, `models/depthlock/`, `providers/depthlock_provider.dart`; headless handlers under `apps/desktop/lib/headless_api/`; UI under `packages/skotiq_app/lib/screens/imaging/widgets/depthlock/` and `live_stack_canvas.dart`, plus the Smart Exposure editor | Role interface implemented by the FFI, network and disconnected backends; region tool with editable rectangles on the live view and the live-stack canvas, preset-first editor with a master-derived floor, list→detail panel, plan binding. Saved goals are drawn through a Dart TAN projection over `ReferenceGeometry` (`depthlock_geometry.dart`) that mirrors the native `world_to_pixel`, so a header-only solution draws as well as a plate solve. |

The executor remains the only acquisition authority. DepthLock never
captures, never extends a plan, and never aborts an exposure: the verdict is
consulted between batches, and an achieved verdict only retires the bound
plan's remaining count. Count, integration budget, target window, pause,
safety and cancellation keep precedence. A bound plan in drain mode
(`rotate_filters = false`) is stepped in `batch_size` batches instead of one
burst so the boundary exists.

Saved frames reach the engine through the bridge's single executor-event
subscription (`FrameAccepted` with a save path and `IMAGETYP = Light`); the
hook is a `try_send`, so a full queue sheds the job with an
`AnalysisDropped` event and the frame stays on disk for later ingestion.
Raw saving and safety are never behind analysis.

## Goal identity and revisions

A goal carries: label, optional project/target/profile grouping identities
(strings; a goal's own identity is its id, filter and provenance), filter
name and optional 0-based slot, the reference frame path and its frozen
`ReferenceGeometry` (width, height, CRVAL/CRPIX/CD), the `AcquisitionSettings`
every contributing light must match (camera `INSTRUME`, filter, exposure,
gain, offset, binning, sensor temperature), a temperature tolerance, the
master dark and flat paths, the `MeasurementSpec`, and two preferences
(`enabled`, `automatic_completion`).

Changing anything except the two preferences is a *revision*: the previous
revision is archived with references to its evidence, and evidence starts
over with a new selection timestamp. Preferences change in place. A Smart
Exposure binding names a goal *and* a revision; a binding to an older
revision is refused at run time (one warning per plan per run, plan runs to
its authored count). Late analysis jobs commit only against the revision and
evidence revision they were computed for; the store rejects anything else.

Only exposures whose `DATE-OBS` is after the revision's selection timestamp
are evidence. The image the region was drawn on is discovery data. Evidence
accumulates across nights as long as the provenance digest matches.

## Measurement definition (estimator version 1)

Supported regime: monochrome, linear, matched-acquisition lights calibrated
with Skotiq master frames, registered to a reference with an undistorted
TAN solution, over a local, approximately constant sky background.

**Regions.** The signal and background rectangles are tangent-plane
rectangles anchored in ICRS degrees with sides in arcseconds and a rotation
(position angle of the height axis). Each is tiled with square apertures of
side `scale_arcsec` (≥ 2″); incomplete edge strips are not measured; a
region holds 16–256 apertures; fields are ≤ 1°, centres within ±85°
declination. The background must be disjoint from the signal region and no
farther than five summed circumscribed radii or 1°. The grid is fixed by the
goal, not by any image.

**Sampling.** Each aperture is the mean of a midpoint grid of bilinear
samples of the calibrated frame, taken through the frame's own TAN solution;
the aperture must span 4–64 native pixels. A sample whose four neighbours
include a masked or non-finite pixel makes the whole aperture `None`.

**Calibration.** `(light − dark) × median(flat) / flat` in signed f64 ADU.
The dark is an unscaled, matched-exposure master that still contains its
bias pedestal; the flat is a Skotiq master flat (unit-mean, F32 or U16),
normalized by its own median at use. Pixels where the flat is outside
0.5–1.5× its median, and light pixels ≥ 60 000 ADU, become NaN. Negative
results are kept: the display calibrator's clipping at zero would bias every
blank region positive.

**Mask.** Saturated pixels (12 px disk), every pixel more than five robust
sigma (MAD-based) above the frame median (2.5 px disk), and the star
detector's stars at `clamp(3·FWHM, 6, 25)` px. The radius is clamped because
the detector's FWHM is a measurement, not a truth: an inflated value would
blanket the frame (the first version did exactly that on synthetic stars).

**Per-frame level and per-cell series.** For exposure *i*, the local sky
level is the median of its measurable background apertures; a frame with
fewer than 75 % measurable background apertures is set aside (counted as
`excluded_frames`, neither pooled nor fatal). For signal cell *j*, the series
is `d_ij = aperture_ij − level_i` over the frames that measured it. A cell
counts only if it was measured in ≥ 90 % of the used frames and ≥ 8 frames;
otherwise it is invalid and counts against coverage. This is what keeps a
single cosmic ray, satellite trail or masked star wing from removing a cell
or a goal for the whole night while still refusing cells that are mostly
unmeasurable.

**Uncertainty.** With `v_j` the sample variance of `d_ij` over its `n_j`
frames, `v4_j` the sample variance of consecutive four-exposure block means,
and `B` the number of usable background cells, the random variance is
`max(v_j/n_j, v4_j/⌊n_j/4⌋) · (1 + 1/B)`. Background spatial residuals (per
background cell, the mean of `cell − level_i` over frames) give a floor: the
90th percentile of their absolute deviation about their median. The
systematic floor is the larger of that and the goal's user-documented
calibration floor; neither is reduced by 1/√N. Per-cell uncertainty is the
root of random variance plus squared systematic floor. This is an empirical
error model, not a formal confidence guarantee.

**Refusal gates.** Non-finite samples or changed aperture geometry refuse
the evaluation outright. The background is unreliable when the range of its
four quadrant means exceeds `2 × floor + 4√2 × σ_quadrant`, where
`σ_quadrant` is the largest quadrant mean's own standard error — the noise
allowance is what stops the gate firing on quiet nights early on and
flipping the goal between unreliable and collecting. With ≥ 32 frames, a
lag-one autocorrelation above 0.35 in more than 20 % of signal cells is
unreliable. Coverage below the goal's `min_coverage` (0.9–1.0) or fewer than
16 valid cells is unreliable. These are empirical gates, not proofs that
gradients or correlated errors are absent.

**Score.** The lower quartile (sorted index `⌊(M−1)/4⌋`) of `mean_j /
uncertainty_j` over valid cells — dimensionless. It describes the fainter
majority of the marked area at the chosen aperture scale. It is not
star-detection quality, exposure time, global image SNR, aesthetic finish or
detection of a new object; bright contaminants occupying a minority cannot
certify a blank majority. The reported `uncertainty_adu` is the median
per-cell uncertainty, a summary and not an interval on the score.

## Forecast, ceiling and yield

The same per-cell noise model is run forward. With `s_j` a cell's mean
signal, `w_j` its effective per-exposure variance (the larger of the sample
variance and four times the block variance), `B` usable background cells,
`n` exposures so far and `f(N)` the projected floor, the lower-quartile
score after `N` exposures is `q_0.25[ s_j / sqrt(w_j/N · (1+1/B) + f(N)²) ]`.
The measured spatial floor is mostly the noise of the background cells'
means, which falls as 1/√N, so `f(N) = max(f_declared, f_now · sqrt(n/N))`:
the excess over the declared calibration floor is projected down, the
declared floor never is. The forecast is the smallest `N ≥ n` (searched in
3 % steps up to 10 000) at which the projected quartile clears the user
threshold plus the repeated-look margin at that `N`, plus the 16-exposure
confirmation window; when no `N` does, the goal is *unreachable* and the
`ceiling_score` — `q_0.25[s_j / f_declared]` — is reported so the operator
knows where it stops and that the remedy is a coarser scale or a smaller
floor (better calibration), not more hours. Yield compares the background
scatter of the newest eight exposures with the quietest eight-exposure
stretch the goal has seen; the host quotes the variance ratio as "tonight's
exposures are worth X× your best". `progress_curve` evaluates the evidence
prefixes (thinned) and appends the projection, for display only.

All of this assumes the sky stays as it has been and that the background
residual is noise rather than a gradient; the gradient gate polices the
second assumption as frames arrive, the first is stated on every surface
that shows a forecast. On the synthetic night the forecast made at 32
exposures predicted the crossing within a factor of two of where it fell
(`forecast_agrees_with_the_night_it_predicted`).

## Stopping policy

- At least 32 usable post-selection exposures before any score is reported
  (`insufficient_evidence` until then).
- The conservative score `score − √(2 ln(2000 · N · (N+1)))` must meet the
  user threshold (3–100). The margin grows with every look so that repeated
  evaluation cannot be shopped.
- Frame ids (FNV-1a with avalanche mixing) split the evidence into two
  partitions independent of brightness; each needs ≥ 12 frames and ≥ 90 % of
  comparable cells must agree within four times their combined uncertainty.
- A provisional crossing freezes a *candidate*: its frame ids, latest
  acquisition time, measurement definition, selection timestamp and
  provenance digest. At least 16 distinct exposures acquired after the
  candidate's latest frame must then arrive; their own lower-quartile score
  must exceed 3 and their cell means must agree with the frozen candidate
  population by the same consistency rule, while the full accumulated score
  still clears the growing margin. Confirmation does not require those 16
  frames to reach the full depth on their own. Replaying the same evidence
  never advances confirmation; a candidate whose definition or provenance no
  longer matches is discarded.
- An achieved revision stops taking evidence: its verdict is final for that
  revision and cannot oscillate. Editing the goal starts a new revision.
- Automatic completion requires `enabled`, `automatic_completion`, a
  committed report over exactly the current evidence, and `achieved`;
  anything else answers "continue" (or "unavailable" for a revision
  mismatch, which the executor warns about once).

The margin resembles a summable repeated-look penalty, but the empirical
variances, spatial correlations, refusal gates and data-dependent selection
do **not** establish an anytime-valid confidence bound. No false-alarm
probability is claimed. A persistent, feature-shaped calibration residual
whose error floor is underestimated is indistinguishable from sky signal by
these data alone.

## Provenance and compatibility

Every admitted exposure carries a provenance digest computed from the files
at ingestion time: estimator version, the goal's acquisition tuple, the
reference geometry, and the exact pixel bytes of the master dark and flat.
Evidence with a different digest is never pooled; a rebuilt master refuses
new frames with an explanation and keeps the evidence already gathered.

Each light must be an unprocessed monochrome `Light` (no `CALSTAT`, no
`BAYERPAT`, not a master) from the goal's camera and filter, with the goal's
exposure (darks are never scaled), binning, gain and offset (when the goal
knows them), and a sensor temperature within the tolerance when both sides
carry one. Masters must declare `FRAMETYP = MASTER`, the right `IMAGETYP`
(`DARK`/`FLAT`, case-insensitive, as `api_combine_master_frames` writes
them), ≥ 8 input frames, and the reference's geometry; acquisition cards on a
master, when present, must agree. Skotiq's own masters carry no
acquisition cards, which is why the goal freezes the tuple the calibration
library matched them for. Frames are registered to the reference with the
existing star-based similarity fit; the fit must have matched scale within
1 %, ≥ 8 inliers, ≥ 80 % agreement and ≤ 0.5 px RMS, and the composed WCS is
`CD_frame = CD_ref · A` with the reference pixel pulled back through the
inverse map.

Stable frame identity is `ns:<NS-SESID>:<NS-FIDX>` for Skotiq-saved
frames and a digest of the pixel bytes plus `DATE-OBS` otherwise, so
reprocessing or a duplicate event is not new evidence.

## Durability

Each goal is one JSON file written through a `.pending` rename with
directory fsync; a lock file refuses a second open. Evidence and analysis are
committed separately but each atomically; a crash between the two leaves
evidence without a report, which the engine re-evaluates on the next open
without re-reading any frame. A failed commit poisons the store until
restart rather than letting memory and disk disagree. Smart Exposure
checkpoints record retired goals (`depth_completed`) so a resumed run neither
re-announces nor re-queries them; pre-feature checkpoints and sequence
documents deserialize unchanged.

## Validation evidence

Native suites (`cargo test -p skotiq_imaging -p skotiq_sequencer
-p skotiq_bridge`, all green on Linux at the time of writing):

- `imaging/tests/depthlock_measurement.rs` (16): 100 seeded blank and
  minority-contaminant trials × 160 repeated looks with no achieved verdict;
  injected faint signal progressing and requiring later confirmation; later
  blank frames failing to confirm; duplicate ids, non-finite samples,
  selection-date exclusion, out-of-order arrival, shared error floors,
  persistent gradients, temporally correlated residuals; dither/flip/reframe
  equivalence through TAN projections (0.015 ADU); signed calibration; one
  hit per frame tolerated, the same cells missing in > 10 % of frames
  failing coverage; a frame with an unmeasurable background excluded and
  counted.
- `imaging/tests/depthlock_input.rs` (11): registration→WCS composition
  against the reference for dither, flip, mirror, reframe and 0.4 % scale
  drift (< 1e-9°); loose or wrong fits refused; CD and CDELT/CROTA headers,
  SIP and unstated frames refused; both master encodings agreeing; saturated
  and dead pixels NaN; mask disks; Skotiq session identity and stable
  pixel digests; acquisition parsing and compatibility reasons; Skotiq
  master headers accepted and each mismatch named.
- `sequencer` `executor::tests::depth_goal_tests` (9): a two-filter Smart
  Exposure run through the real executor with a recording device double —
  the achieved filter stops at the next boundary while the other runs to
  count with exactly one `DepthGoalCompleted`; drain mode still completes
  between exposures; a still-collecting goal leaves the plan unchanged; a
  stale-revision binding and a wrong-revision answer warn once and run to
  count; no verdict source warns once; an unbound sequence never consults
  the store; checkpoint and plan bindings optional on the wire.
- `bridge` `depthlock_service` (20 + 1 ignored benchmark): the store's
  revision, tombstone, corruption, pending-file and fault-injection cases;
  a rendered synthetic night on disk (512×384, dithered star field,
  sensor-fixed vignetting, 12 ADU flat-topped patch, 20 ADU noise, Skotiq
  masters) reaching a provisional crossing after 39 exposures and `achieved`
  after exactly 16 more (score 14.8, conservative 9.2 against a threshold of
  5, median per-cell uncertainty 0.77 ADU, one frame set aside), advisory
  until automation is switched on, closed to further intake, intact after a
  restart and unchanged by replay; a blank region never achieving over 64
  exposures; other-filter, other-exposure, starless, already-calibrated and
  rebuilt-master frames refused with the reason named while earlier evidence
  is kept; the queue shedding with an event when full; saved frames routed
  only to enabled goals for their filter and camera; an interrupted analysis
  repaired on open.

Representative cost (`full_sensor_frame_cost`, ignored benchmark, release
build, this development machine): 1.42–1.54 s per frame per goal on a
4144×2822 U16 light — read, vet, calibrate, mask, register, sample, store
and evaluate; the reference and both masters are re-read from disk every
time rather than cached (predictable memory, ~150 MB transient per job).
That is well inside an exposure cadence for one or two goals; the queue
holds eight jobs and sheds beyond that. The pipeline runs one job at a time
on the blocking pool and never on an async or UI thread.

Dart-side suites cover the backend role through the FFI, network and
disconnected implementations, the headless routes and scopes, event
round-trips, the provider, and the widgets (region tool, editor, panel,
Smart Exposure binding).

## Limitations and required on-sky validation

- Synthetic validation establishes the estimator's behaviour under its own
  noise model. It does not establish that a real rig's calibration residuals
  are below the user's declared floor, that the mask catches every wing, or
  that the temporal-independence gates are sufficient. Use a real
  two-filter night with automation off first and compare the reported
  states, coverage and `last_issue` texts against what the frames look like.
- The calibration floor the editor proposes (`api_depthlock_suggest_floor`)
  is the masters' own pixel noise — the master dark's neighbour-difference
  noise and the master flat's relative noise times the sky level — averaged
  over the aperture. It is a minimum, not a ceiling: spatially correlated
  residuals (a dust shadow that moved, a gradient the flat does not match)
  are not in it, and only on-sky data can say how far above it the true
  floor sits.
- Whether a master flat was pedestal-corrected is not recorded in
  Skotiq's master headers; an uncorrected flat is a smooth multiplicative
  error the systematic floor must cover.
- OSC data, dark scaling, SIP/distorted solutions and multi-rig pooling are
  out of scope for this release. Regions are selected on a plate-solved sub,
  a FITS file with a TAN header, or the live stack — whose pixel geometry is
  its reference sub's, so the goal's reference is that sub, never the
  stacked (float, unregistrable) image.
- No hardware was commanded during validation and no unattended-use
  recommendation is made.
