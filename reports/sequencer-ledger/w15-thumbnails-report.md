# w15-thumbnails — frame thumbnails stop decoding full-resolution FITS on the UI isolate

Worktree `agent/w15-thumbnails` off `5b2235cc7`. Camera in play: ASI1600MM-Cool,
4656 x 3520 = 16.4 Mpx, 32.8 MB per FITS frame.

> "When going to the dashboard or coming back to imaging, I don't see any of the actual
> taken imaging, I think because the app tried to load every full resolution image taken
> all at once, rather than just load the full res last one and cache thumbnails for all
> not in the current viewport." — the owner

## ROOT CAUSE — three defects stacked, each proved

### 1. The thumbnail bridge call ran the whole decode on the UI isolate

`api_generate_fits_thumbnail` was `#[flutter_rust_bridge::frb(sync)]`
(`native/skotiq_native/bridge/src/api/imaging.rs`). An FRB `sync` function executes
its Rust body **on the thread of the Dart isolate that called it**, and the caller here
is the UI isolate: `ThumbnailSidecarService.defaultGenerateFitsThumbnail` ->
`bridge_api.apiGenerateFitsThumbnail`, reached from
`_FfiSessionHeartbeatOperations.getImageThumbnail`.

The generated code is the proof, not an inference. Before:

```dart
Uint8List crateApiImagingApiGenerateFitsThumbnail({...}) {
  return handler.executeSync(SyncTask(callFfi: () { ... }));
}
```

After regeneration:

```dart
Future<Uint8List> crateApiImagingApiGenerateFitsThumbnail({...}) {
  return handler.executeNormal(NormalTask(callFfi: (port_) { ... }));
}
```

`executeSync` is a blocking FFI call on the calling isolate; `executeNormal` posts to a
port and returns a future. The Dart signature was `Uint8List`, not `Future<Uint8List>` —
there was no await to yield at.

**What that body costs, measured.** A standalone release-mode Rust bench over 20 of the
seeded 4656 x 3520 frames, running the same pipeline the bridge function runs
(`read_fits` -> u16 -> subsample):

| page cache | min | median | mean | max |
|---|---|---|---|---|
| warm | 23.9 ms | 33.7 ms | 35.0 ms | 70.3 ms |
| dropped (`/proc/sys/vm/drop_caches`) | 40.8 ms | 45.9 ms | 52.7 ms | 95.8 ms |

So on this desktop (NVMe, many cores) the visible 13-cell rail cost ~0.5-0.7 s of frozen
UI isolate, and every navigation paid it again. The owner's Win10 imaging laptop is
several times slower per frame, and his Dashboard asks from three surfaces at once (the
cockpit strip, the Tonight preview panel and the run dashboard's history rail), which is
how 35 ms per frame becomes "I don't see any of the actual taken imaging".

### 2. The sidecar cache existed and the desktop path never looked at it

`ThumbnailSidecarService` writes `{filePath}.thumb.jpg` beside every captured frame, and
the remote-mode HTTP handler (`session_handlers/thumbnail_handlers.dart`) has always read
it first. The FFI backend's `getImageThumbnail` went straight to the Rust decode with no
sidecar read and no sidecar write.

**Proved live, twice over.** With 120 seeded frames:

* The unmodified build wrote **0 sidecars** across a full launch, a Dashboard -> Analytics
  open, a return visit, and a 24-burst sweep of the rail across all 120 frames — in every
  run.
* The decisive A/B: with **120 sidecars already on disk and 120 `thumbnail_path` stamps
  already in the database**, the unmodified build still peaked at **74.9 MB** of image
  cache and **612 ms** of single-window UI-isolate block, i.e. it decoded every frame
  again with the answer sitting next to it.

### 3. Nothing in the app ever asked for a downscaled decode

Repo-wide before this change: **zero** occurrences of `cacheWidth`, `cacheHeight`,
`ResizeImage` or any `imageCache` tuning in `packages/` or `apps/`. Every thumbnail cell
decoded its image at full encoded resolution and parked that decode in
`PaintingBinding.instance.imageCache` (default budget 100 MB / 1000 images):

* a 512 px backend thumbnail in a 72 px cell = ~1 MB of RGBA for ~20 KB of visible pixels;
* a master's `previewPngPath` — a full-frame preview — in a 72 px tile = ~65 MB.

**Measured**: 120 thumbnails occupied **74.9 MB of the 100 MB byte budget**, reproducible
to the decimal in all four runs of the unmodified build. `Image.memory` keys the cache on
the byte-list's identity, so each refetch is both a miss and a new entry: the cache fills
with entries nothing is showing, evicts the ones that are, and each eviction costs another
full blocking FITS decode. That is the mechanism that turns per-frame jank into a rail
that never fills in.

### What the owner's diagnosis got right and what it got wrong

Right: the app was paying full-resolution costs for thumbnails, and was not caching.
Wrong in one detail: it did not load them "all at once" — every strip in the app is
`ListView.builder`/`GridView.builder` and is lazy within itself. What it did was pay the
full cost **serially, on the UI isolate, for every cell that came into view, on every
navigation, forever**. One clarification worth recording: the Analytics session tab is a
`SingleChildScrollView` (`analytics_screen/session_tab.dart`), so its rail is *built* the
moment the tab opens even though it sits ~700 px below the fold. The rail is still lazy
internally, so the cost is bounded by its viewport, not by the night — left as is.

## WHAT CHANGED

### Rust — `native/skotiq_native/bridge/src/api/imaging.rs`

* `api_generate_fits_thumbnail` is now `pub async fn`, with the blocking body extracted to
  `generate_fits_thumbnail_jpeg` and run under `tokio::task::spawn_blocking`.
* Generation is admitted through a `tokio::sync::Semaphore` at
  `THUMBNAIL_GENERATION_CONCURRENCY = 4`, because concurrency without a bound would let a
  night's gallery start a hundred full-frame reads together.
* The whole-frame `Vec<u16>` conversion is gone. It converted all 16.4 M samples and then
  read one in 81 — a second 32.8 MB allocation of which 98.8% was discarded, now paid four
  times over by the concurrency above. Samples are converted on demand instead.

**FRB regeneration.** `flutter_rust_bridge_codegen generate` 2.11.1 (matching the pinned
`flutter_rust_bridge = "=2.11.1"`), run through the CPATH dance `scripts/dev.sh` uses.
Codegen was verified idempotent on the untouched tree first; the only drift it produced
there was a comment-only re-listing of private fns in
`packages/skotiq_bridge/lib/src/api/plate_solve.dart` (pre-existing, from w14's Rust
changes), which is carried in this branch rather than left to reappear.

**A trap worth recording:** `rustContentHash` did **not** change (`-1467366630` before and
after), even though the wire signature gained a `port_` argument. The startup handshake
would therefore *not* have caught a stale `.so`, so both bundles below were verified by
string-grepping the binaries rather than by trusting the hash.

### Dart — `packages/skotiq_core`

* `ThumbnailSidecarService` gains `readSidecar(fitsPath, {stampedPath})` and
  `generateAndCacheSidecar(...)`. The read tries the row's stamped path first, then the
  canonical path beside the frame, and treats a **zero-length** sidecar as a miss (a write
  cut short by a pulled SD card would otherwise pin that frame to a broken-image glyph
  forever). Generation hands the caller its bytes immediately and writes the sidecar
  afterwards, unawaited, so a read-only frame directory cannot turn a viewable frame into
  a placeholder. `writeSidecar`/`writeSidecarForRow` now share the same
  `_persistSidecar`/`_stampRow` helpers, so the HTTP and FFI paths cannot drift.
* Concurrent generations for one frame are coalesced through an in-flight map keyed on the
  source path. Three surfaces ask for the newest frame simultaneously; that was three
  full-frame decodes for one answer.
* `FfiBackend.getImageThumbnail` is sidecar-first, self-heals rows that predate sidecars,
  and only then generates.
* `_FfiBackendBase` takes a `ThumbnailSidecarService` (test seam, default in production),
  and `backend_provider.useLocalBackend` passes the container's singleton so the capture
  path's fire-and-forget writes and the UI's reads share one in-flight map and one logger.

### Dart — `packages/skotiq_app`

New `lib/utils/image_decode_size.dart` — `thumbnailDecodeWidth(context, logicalWidth)`,
returning `logicalWidth * devicePixelRatio` rounded **up**, and null for an unbounded,
collapsed or NaN box (where there is nothing to derive a size from and `cacheWidth: 0` is
an error).

**Sites given a cell-sized decode:**

| site | box | what it was decoding |
|---|---|---|
| `widgets/frame_thumbnail_loader.dart` (`FrameThumbnail`, both rungs) | 72-100 px | the 512 px backend JPEG, and full-size local rasters |
| `screens/analytics/.../image_thumbnail_strip_parts/_thumbnail.dart` | 100 px rail cell | same, times a whole night |
| `screens/session_review/.../sub_cull_rail_parts/_thumbnails.dart` | 200 px grid cell | same, times up to 500 subs |
| `screens/settings/widgets/captured_images_settings.dart` (gallery tile) | grid tile | same |
| `screens/session_review/widgets/master_library_panel.dart` (`_Thumb`) | 72 px | a master's **full-frame** preview PNG (~65 MB decoded) |
| `screens/mosaic/widgets/mosaic_panel_grid.dart` | grid cell | each panel master's full-frame preview PNG |
| `screens/your_sky/widgets/atlas_region_cutout.dart` | card **and** hero | a multi-thousand-pixel co-add; `LayoutBuilder` so each use gets its own size |

`FrameThumbnail` covers the Dashboard cockpit strip, the Tonight preview panel, the
sequencer exposure strip and the run dashboard's history rail in one place, so those four
were fixed by fixing it.

**Sites deliberately left at full resolution** (the operator is inspecting pixels, or the
bytes are already the display size):

* `screens/imaging/widgets/image_display.dart` and the rest of the Imaging canvas — the
  brief's rule, and they do not go through `ImageCache` at all (see below).
* the fullscreen/inspect viewers: `analytics/widgets/frame_detail_dialog.dart`,
  `sequencer/.../run_dashboard/frame_detail_dialog.dart`,
  `run_dashboard/live_frame_panel_parts/_inspect_dialog.dart`,
  `sequencer/widgets/exposure_node_thumbnail_strip.dart`'s `InteractiveViewer`,
  `session_review/.../sub_cull_rail_parts/_thumbnails.dart`'s `_BlinkView`,
  `settings/widgets/captured_images_settings.dart`'s `InteractiveViewer`.
* `session_review/widgets/master_overlay_view.dart` and `master_preview_view.dart` —
  Darkroom-class surfaces at `maxScale: 8`.
* `polar_alignment/.../\_measurement_panel.dart` — the live capture being measured.
* `first_light/widgets/cutout_strip.dart` — the bytes are already a cutout generated at
  the displayed size, and it sets `filterQuality: FilterQuality.none` on purpose so the
  operator sees raw pixels; a `cacheWidth` would resample and defeat that.
* `sequencer/.../node_progress_panels/autofocus_visuals.dart` — an RGBA buffer built in
  Dart at the display size.
* `screens/imaging/widgets/imaging_session_frames.dart` — named in the brief, but it holds
  **no images at all**: it is a `ListView.builder` of `ListRow` text. No change needed.

### Diagnostics — `apps/desktop/lib/frame_timing_probe.dart`

The probe (opt-in, `SKOTIQ_FRAME_TIMING=1`) gained two things, because this defect had
no number attached to it and neither existed:

* `imgCacheMB` / `imgCacheImages` / `imgCacheLive` from
  `PaintingBinding.instance.imageCache`. A decode-bound stall shows up here before it
  shows up in the frame count.
* `blockedMs` — how much later than the window the report arrived. The probe's
  `Timer.periodic` lives on the UI isolate, so a late report is that isolate having been
  unable to run. `frames=0` could not distinguish a blocked isolate from an idle one,
  which is precisely why nobody had a figure for this.

## BEFORE / AFTER, LIVE

Both bundles built from this worktree and verified to be the binaries under test by
string-grepping them (`libskotiq_bridge.so` for `Thumbnail task join error`,
`libapp.so` for the sidecar log line) — the repo's own freshness signal, and the only one
available here given the unchanged `rustContentHash`.

* **BEFORE** = `5b2235cc7` + the two probe commits cherry-picked (so both builds report the
  same instrumentation and nothing else differs).
* **AFTER** = `agent/w15-thumbnails` tip.

**Fixture**: 120 real 4656 x 3520 BITPIX=16 BZERO=32768 FITS frames (3.7 GB on disk,
32.78 MB each) carrying a sky gradient and 2,500 Gaussian stars, plus per-frame read
noise so no two frames are byte-identical; one `imaging_sessions` row and 120
`captured_images` rows pointing at them in a scratch `SKOTIQ_DATABASE_DIR`.

**Drive**: Xvfb `:87`, softpipe, `tools/ui_audit/drive_linux.py`. Launch -> skip
onboarding (verified, retried: softpipe drops the odd synthetic click) -> Tonight ->
Analytics -> scroll to the captured-images rail -> sample the rail's 13 visible cells by
per-cell pixel statistics until all 13 have painted -> 24-burst sweep of the rail across
all 120 frames.

### Cold: no sidecars on disk, 120 rows

| | BEFORE | AFTER |
|---|---|---|
| rail open: UI-isolate block, worst window | 24.9 ms | **0.0 ms** |
| rail open: image cache peak | 10.0 MB | **0.4 MB** |
| rail open: sidecars written | **0** | **16** |
| sweep of all 120: block, worst window | 87.6 ms | 51.7-110.0 ms |
| sweep of all 120: image cache peak | **74.9 MB / 120 images** | **3.2 MB / 120 images** |
| sweep of all 120: sidecars written | **0** | **120** |
| peak RSS | 1015.5 MB | 1007.4 MB |

### Warm: identical disk state, 120 sidecars + 120 DB stamps, only the binary differs

Two runs of each, reported as a range.

| | BEFORE | AFTER |
|---|---|---|
| image cache peak | **74.9 MB** (both runs) | **3.2 MB** (both runs) |
| UI-isolate block, worst window on open | 145.1-612.2 ms | 96.3-109.3 ms |
| UI-isolate block, total over the open | 339.0-783.0 ms | 271.6-353.1 ms |
| peak RSS | 992.6-1004.6 MB | 1004.0-1011.6 MB |
| all 13 cells painted | 5.9-6.0 s | 5.9-6.3 s |

**Read these honestly.**

* **The image cache figure is the headline and it is exact**: 74.9 MB -> 3.2 MB for the
  same 120 thumbnails, byte-for-byte reproducible across all four runs of each build. A
  23x reduction, and it takes the thumbnail surfaces from 75% of the cache's byte budget
  to 3%.
* **Sidecars written, 0 -> 120**, is categorical. The BEFORE build never wrote or read one
  from the FFI path in any run, including the run where all 120 were already on disk with
  the DB stamped.
* **`blockedMs` is noisy on this host** (softpipe rasterises at 100-350 ms per frame and
  dominates the signal). The direction is consistent — the worst single window drops from
  145-612 ms to 96-109 ms — but I will not claim a precise factor from it. The structural
  proof (`executeSync` -> `executeNormal`) plus the 35 ms/frame bench is what actually
  establishes defect 1.
* **Time-to-painted does not separate the two builds here** and I am not claiming it does:
  the ~6 s is navigation plus softpipe raster, and my screenshot sampling floor is ~1 s, so
  a 0.5 s decode difference is below the noise on this machine. On the owner's laptop, where
  one decode is several times more expensive and three surfaces request at once, the same
  work is what he saw as an empty strip. **This is the part that needs on-sky / on-rig
  confirmation.**
* **Peak RSS is unchanged** (1004-1012 MB vs 993-1016 MB) *because of* the on-demand
  conversion. An intermediate build with 4x concurrency but the old whole-frame conversion
  measured **1225.2 MB** — +210 MB, which is 4 x 32.8 MB of discarded `Vec<u16>` plus slack.
  Removing that conversion bought the concurrency for free.

### Equivalence of the on-demand conversion, at real frame size

The 120 sidecar JPEGs written by the whole-frame-conversion build and by the on-demand
build are **byte-identical** — 120/120 md5 matches on real 4656 x 3520 frames. Plus 8 Rust
unit tests covering every FITS pixel type against each other, the luminance reduction for
3-channel frames, geometry, and the async wrapper returning the blocking body verbatim.

### Image cache budget — measured, deliberately unchanged

With correct `cacheWidth`, a 120-frame night's thumbnail surfaces peak at **3.2 MB of the
100 MB default budget and 120 of the 1000-image default** — 31x headroom. Nothing is bought
by raising it, and raising a global budget on a laptop to fix a 3%-utilised cache would be
papering. The Imaging canvas and every other full-resolution surface built from raw pixels
(`image_display.dart`, `live_stack_canvas.dart`, `stacking_panel/stacked_preview.dart`,
`centering_dialog/image_canvas.dart`, `widgets/astro_image_viewer.dart`,
`darkroom_screen_parts/_image_surface.dart`) go through `ui.decodeImageFromPixels` /
`ui.ImageDescriptor.raw`, which are not `ImageProvider`s and never enter `ImageCache` at
all — so the 65 MB frame was never in this budget to begin with. **Left at the Flutter
default.** See "Still open" for the one surface where the default genuinely is too small.

### One full-resolution frame at a time on the Imaging canvas — verified, no change needed

This was already true after w13, and I checked rather than assumed:

* `currentImageProvider` (`services/imaging_service.dart:580`) is a
  `StateProvider<CapturedImageData?>` — a **single slot**. A new frame drops the previous
  one's only reference.
* `stretchedImageProvider` (`providers/auto_stretch_provider.dart:24`) is
  `FutureProvider.autoDispose` with no `keepAlive`, so leaving Imaging frees the stretched
  buffer.
* `image_display.dart` disposes the replaced `ui.Image`, disposes on the unmounted-decode
  path, and disposes in `dispose()` (w13's fix, still in place).
* I audited every other `ui.Image` holder in `packages/skotiq_app/lib` —
  `_image_surface.dart`, `image_canvas.dart`, `live_stack_canvas.dart`,
  `stacked_preview.dart`, `astro_image_viewer.dart`, `objects_panel.dart` — and all six
  dispose both on replace and in `dispose()`. `preview_viewport.dart` and the framing
  painters take a `ui.Image` they do not own. No leak found, nothing changed here.

## VERIFICATION

All commands unpiped, exit codes recorded. `TMPDIR=$HOME/.cache/ns-tmp/w15-thumbnails`,
`CARGO_TARGET_DIR=$HOME/.cache/ns-worktrees/cargo-target` throughout.

| gate | command | exit | result |
|---|---|---|---|
| FRB codegen (idempotency baseline, untouched tree) | `flutter_rust_bridge_codegen generate` | 0 | only the pre-existing comment drift in `plate_solve.dart` |
| FRB codegen (after the Rust change) | `flutter_rust_bridge_codegen generate` | 0 | 9 files, all expected |
| Rust build | `cargo build --release -p skotiq_bridge` | 0 | `libskotiq_bridge.so` 48.9 MB |
| Rust clippy | `cargo clippy --release -p skotiq_bridge --lib` | 0 | no new findings |
| Rust fmt | `cargo fmt --check` (bridge) | 0 | clean for my files; see caveat below |
| Rust tests (new) | `cargo test -p skotiq_bridge --lib fits_thumbnail` | 0 | 8 passed |
| Rust tests (full libs) | `cargo test -p skotiq_bridge -p skotiq_native --lib` | 0 | 721 passed (713 baseline + 8 new), 6 ignored; 202 passed |
| Dart format | `dart format --output=none --set-exit-if-changed` on `packages/skotiq_core`, `packages/skotiq_app`, `packages/skotiq_bridge` | 0, 0, 0 | clean |
| Dart format | `dart format --output=none --set-exit-if-changed apps/desktop` | **1** | 5 files drifted, **all 5 pre-existing at `5b2235cc7`** — see below. My two files in that package are clean. |
| analyze (bridge) | `dart analyze` in `packages/skotiq_bridge` | 0 | No issues found |
| analyze (core) | `dart analyze lib` in `packages/skotiq_core` | 0 | 2 infos, both pre-existing in `scheduler/rejection_labels.dart` |
| analyze (app) | `dart analyze` in `packages/skotiq_app` | 0 | 873 infos — the exact pre-existing baseline; **zero** errors or warnings |
| analyze (desktop) | `dart analyze` in `apps/desktop` | 0 | 9 infos, all pre-existing |
| tests (core) | `flutter test --exclude-tags golden --concurrency=4` | 0 | 6530 passed, 4 skipped (10 new) |
| tests (app) | `flutter test --exclude-tags golden --concurrency=4` | 0 | 4407 passed (11 new) |
| tests (desktop) | `flutter test --exclude-tags golden --concurrency=4` | 0 | 1284 passed (12 new) |
| tests (desktop, sidecar HTTP) | `flutter test test/headless_api/thumbnail_sidecar_test.dart --concurrency=4` | 0 | 11 passed, behaviour unchanged |
| Flutter bundle (BEFORE) | `flutter build linux --release` | 0 | bundle stashed and string-verified |
| Flutter bundle (AFTER) | `flutter build linux --release` | 0 | bundle stashed and string-verified |
| live repro | `drive_linux.py start/shot/wheel/click-xy/stop`, both bundles | 0 | see the tables above |

The AFTER bundle measured above was built at `21d6db67d`; every commit after it touches
only tests and this report (`git diff --name-only 21d6db67d HEAD` outside `reports/` and
`*/test/*` is empty), so the measured binary is the tip's library code.

`--exclude-tags golden` is the project's own gate (`ns-worktrees/final-verify.sh`); those
goldens are captured on the Windows/CI host and fail on Linux. I created and modified no
golden PNGs.

### Pre-existing drift I did not touch, recorded so the reviewer does not read it as mine

* `dart format --set-exit-if-changed apps/desktop` reports **5 files** already drifted at
  `5b2235cc7`: `headless_api/handlers/depthlock_handlers.dart`,
  `headless_api/handlers/device_handlers/mount_handlers.dart`,
  `headless_api/routes/depthlock_routes.dart`,
  `test/headless_api/depthlock_handlers_test.dart`,
  `test/headless_api/sequencer_wire_validation_test.dart`. Each verified untouched by me
  with `git diff --quiet HEAD -- <file>`. I formatted only the two files of mine in that
  package's neighbours and left these alone.
* `cargo fmt` wants to reformat three files already drifted at `5b2235cc7`:
  `imaging/src/depthlock/mod.rs`, `sequencer/src/lib.rs`,
  `sequencer/tests/dart_wire_contract.rs`. `cargo fmt` rewrote them as a side effect; I
  reverted all three.
* `packages/skotiq_bridge/lib/src/api/plate_solve.dart` carries a comment-only codegen
  refresh (w14's private Rust fns). Kept, because any future codegen run reproduces it.

## STILL OPEN — identified, deliberately not fixed here

1. **On-rig confirmation is owed.** The change is pure Dart + a `spawn_blocking` move, so
   it behaves identically on Windows, but the *symptom* is the owner's and I could not
   reproduce its severity on this hardware (35 ms/frame here). The properties that make it
   impossible are pinned by tests; the felt improvement is not yet witnessed on his laptop.
2. **`master_overlay_view.dart` / `master_preview_view.dart` can exceed the image cache
   budget on their own.** They are deliberately full-resolution and they *do* go through
   `ImageCache` (`Image.file` on `previewPngPath`). With the coverage and rejection overlays
   toggled on, that is 3-4 x ~65 MB against a 100 MB budget — guaranteed thrash on every
   toggle. Out of this workstream's scope (Darkroom/session-review surfaces) and it wants
   its own measurement before anyone picks a number; flagged rather than half-fixed with a
   global budget bump.
3. **The Rust generator still reads the whole FITS.** `read_fits` materialises all 32.8 MB
   before a single sample is taken, while `skotiq_imaging::generate_thumbnail`
   (`imaging/src/reader.rs`) already exists and does a memory-mapped `read_downsampled`.
   Switching to it would cut the remaining per-call allocation roughly 30-fold, but it is a
   different downsampling implementation and would change thumbnail appearance, so it needs
   its own before/after on real frames rather than being smuggled in here.
4. **The sequencer/run-dashboard strips each re-fetch on remount.** They fetch in the
   tile's `initState` with no memoisation, unlike `sub_cull_rail`'s
   `subThumbnailProvider`, which retains 128 entries through Riverpod. Now that a re-fetch
   is a sidecar file read rather than a full decode, the cost is small; unifying them on
   one retained provider is the right cleanup and it touches the ledger widgets another
   agent owns this wave.
5. **`maximumSize` (1000 images) is untuned.** Measured as 120 images at peak here, so
   there was nothing to decide; a much longer night in one session would want a look.

## SCRATCH ARTEFACTS (outside the repo, safe to delete)

Roughly 4 GB under `~/.cache/ns-tmp/w15-thumbnails/`: `measure/frames/` (the 120 real
FITS fixtures, 3.7 GB, plus their sidecars), `measure/bundle-before/` and
`measure/bundle-after/` (the two release bundles the A/B ran against, 141 MB each),
`measure/shots/` (the rail captures the paint counts were read from), `ns-audit/w15/` (the
scratch profile and its `app.log` with every `[frame-timing]` line), and `bench/` (the
one-off Rust timing harness). The generator and driver scripts that produced all of it are
`measure/make_fits.py`, `measure/seed_db.py`, `measure/cold_probe.py` and
`measure/warm_probe.py`. Kept as evidence, not needed by the build.

## COMMITS

* `234258bdf` perf(thumbnails): take the full-frame FITS decode off the UI isolate
* `adf57384a` feat(diagnostics): the frame-timing probe reports the image cache
* `f8bcce75e` feat(diagnostics): the frame-timing probe reports UI-isolate block time
* `21d6db67d` perf(thumbnails): sample the frame instead of converting all of it
* `fe177ec70` test(thumbnails): pin the sidecar-first path and the cell-sized decode
