# Release-pass map — Rust imaging crate (`native/skotiq_native/imaging/src/`)

Read-only mapping pass. Nothing in this report was edited. All line numbers are from
`audit/end-to-end-campaign` at commit `b07d91c9d`. Line counts verified with `wc -l`.

Crate facts used throughout:

- 34 `.rs` files under `src/` + `src/platesolve/platesolve_paths.rs`, **48,413 lines total**.
- **Nothing in this crate is generated.** No `@generated` / `frb_generated` marker exists
  anywhere under `src/` (`grep -rln "@generated\|GENERATED CODE\|frb_generated" src/` → empty).
  Every large file below is hand-written.
- Public surface is a flat re-export barrel: `lib.rs:50-80` does `pub use <module>::*;` for
  every module. **Consequence for every split plan below: as long as a split module's
  `mod.rs` re-exports its submodules' public items, the crate's external API does not
  change and no caller in `bridge/`, `sequencer/` or Dart needs touching.**
- Tests live in per-file `#[cfg(test)] mod tests` blocks (one integration test file,
  `tests/performance_tests.rs`, 263 lines). Test blocks are a large fraction of the
  oversized files and are the cheapest half of every split.

---

## 1. Oversized files

Rust threshold ~1500 lines. Thirteen files qualify. Code-vs-test split computed by
locating each `#[cfg(test)] mod` and brace-matching it.

| File | Total | Code | Tests | Risk |
|---|---:|---:|---:|---|
| `fits.rs` | 3699 | 2167 | 1532 | high |
| `platesolve.rs` | 3386 | 2393 (762 of which are `#[cfg(test)]`-gated) | 993 | high |
| `stacking.rs` | 3020 | 1551 | 1469 | high |
| `stats.rs` | 2503 | 1382 | 1121 | high |
| `sky_atlas.rs` | 2352 | 1519 | 833 | medium |
| `phd2.rs` | 2201 | 1975 | 226 | high |
| `mosaic_stitch.rs` | 1884 | 1279 | 605 | medium |
| `registration.rs` | 1871 | 1348 | 523 | medium |
| `master_accumulation.rs` | 1716 | 952 | 764 | low |
| `background_extraction.rs` | 1695 | 1130 | 565 | low |
| `drizzle.rs` | 1694 | 753 | 941 | low |
| `deconvolution.rs` | 1635 | 1122 | 513 | low |
| `difference_image.rs` | 1509 | 1132 | 377 | low |

### 1.1 `fits.rs` — 3699 lines

**Why it is big.** It is five unrelated concerns in one file: the header object model,
the reader, the writer, FITS-adjacent domain helpers (Bayer geometry, WCS cards, airmass),
and an entire image-validation/quality subsystem that has nothing to do with FITS I/O at
all. Plus one 1532-line `mod tests` covering all of it.

**Section boundaries (verified).**

| Lines | Content |
|---|---|
| 1-38 | module docs (`as`-cast policy) + imports |
| 40-233 | `FitsHeader`, `FitsValue`, `FitsError` |
| 234-667 | readers: `read_fits`, `read_fits_from_bytes`, `read_fits_from_reader`, `read_header` (`pub(crate)`), `parse_fits_value`, `split_value_and_comment`, `is_valid_keyword`, `fits_pixel_count`, `read_u8/i16/i32/f32/f64_data` |
| 668-993 | writers: `write_fits`, `format_fits_string_value`, `format_fits_float`, `write_end_card`, `write_text_card`, `write_value_card` |
| 994-1083 | `BayerGeometry`, `effective_bayer_pattern`, `read_bayer_geometry` |
| 1084-1192 | `WcsInfo`, `add_wcs_headers` |
| 1193-1243 | `StandardKeywords` (**dead — see §3.1**) |
| 1244-1320 | `calculate_airmass` |
| 1321-2043 | `ImageValidation`, `validate_image`, saturation/full-scale helpers, `ImageValidationOptions`, `validate_image_with_options`, `validate_image_comprehensive` |
| 2044-2072 | `validate_fits_header` |
| 2073-2167 | `calculate_quality_score` (**dead — see §3.2**) |
| 2168-3699 | `mod tests` |

**Split plan (behavior-preserving).** Convert `src/fits.rs` → `src/fits/` directory.
`lib.rs` keeps `mod fits;` and `pub use fits::*;` unchanged.

1. `src/fits/mod.rs` — the module docs from lines 1-38, then
   `mod header; mod read; mod write; mod bayer; mod wcs; mod airmass; mod validate;`
   and `pub use header::*; pub use read::*; pub use write::*; pub use bayer::*;
   pub use wcs::*; pub use airmass::*; pub use validate::*;`
   Add `pub(crate) use read::read_header;` — `reader.rs:55` calls
   `crate::fits::read_header`, and that is the **only** cross-module `pub(crate)` item
   in this file, so it is the one path-visibility detail the implementer must not miss.
2. `src/fits/header.rs` ← lines 40-233 (`FitsHeader`, `FitsValue`, `FitsError`,
   `impl Display for FitsError`, `impl From<std::io::Error>`).
3. `src/fits/read.rs` ← lines 234-667. Needs `use super::header::{FitsHeader, FitsValue, FitsError};`
   plus `crate::{ImageData, PixelType}`.
4. `src/fits/write.rs` ← lines 668-993.
5. `src/fits/bayer.rs` ← lines 994-1083. Needs `crate::BayerPattern`.
6. `src/fits/wcs.rs` ← lines 1084-1192.
7. `src/fits/airmass.rs` ← lines 1244-1320.
8. `src/fits/validate.rs` ← lines 1321-2072. **This is the section that does not belong in
   a FITS module at all** — only `validate_fits_header` touches `FitsHeader`; everything
   else operates on `ImageData`. Preferred end state is a top-level `src/validation.rs`
   with `validate_fits_header` left behind in `fits/`, but that changes nothing at the
   barrel level so it is safe either way. Splitting it out of `fits.rs` is the load-bearing
   step; promoting it to a sibling module is a follow-up.
9. Delete lines 1193-1243 (`StandardKeywords`) and 2073-2167 (`calculate_quality_score`) —
   see §3. If the quality score is instead kept, it goes in `src/fits/quality.rs`.
10. Tests: the single `mod tests` at 2168-3699 splits by subject into each new file's own
    `#[cfg(test)] mod tests`. The test bodies use `write_fits` + `read_fits` round-trips
    heavily, so `read.rs` and `write.rs` tests should share one helper — put the FITS
    fixture builders in `src/fits/test_support.rs` behind `#[cfg(test)]` and
    `pub(super) use` them.

Result: 8 files, largest ~750 lines.

### 1.2 `platesolve.rs` — 3386 lines

**Why it is big.** Two reasons, and the second is the important one.

1. It carries the full ASTAP driver, the astrometry.net driver, solver discovery, solver
   verification, `.wcs`/`.ini` parsing, and the process-global preference store.
2. **Lines 1271-2032 (762 lines) are `#[cfg(test)]`-gated** — a complete second, internal
   plate solver (a WGSL compute shader for GPU max-downsample, a CPU fallback, a
   local-maxima star detector, header-based centre/scale inference, sexagesimal parsing,
   rotation estimation, and `solve_internal`). Verified: every one of these items carries
   its own `#[cfg(test)]` attribute (lines 1271, 1320, 1332, 1399, 1457, 1467, 1482, 1533,
   1723, 1732, 1759, 1768, 1851, 1897, 1927, 1932, 1937, 1958, 1982, 2002) and the only
   callers are inside `mod tests` (`platesolve.rs:2503`, `2513`). It ships in no build.
   Roughly another 400 lines of the 993-line test module exist only to exercise it.

**Section boundaries (verified).**

| Lines | Content |
|---|---|
| 1-56 | module docs (`as`-cast + `unwrap_or` policy), `mod platesolve_paths` at 42 |
| 57-63 | `#[cfg(test)]` imports (`wgpu::util::DeviceExt`, `bytemuck`, `detect_stars`, …) |
| 65-256 | `PlateSolveError`, `PlateSolveResult`, `PlateSolverChoice`, `PlateSolverConfig`, `SolverPref`, `ACTIVE_SOLVER_PREF`, `set_solver_preference` |
| 264-430 | discovery: `find_astap_with_override`, `find_astap`, `find_astrometry*`, `home_dir`, `which_on_path`, `detect_astap_catalog` |
| 432-529 | `SolverInfo`, `SolverVerifyError`, `verify_solver` |
| 530-928 | `AstapSolver` (`new`, `with_default_config`, `is_available`, `astap_path`, `solve`) |
| 930-1269 | `FITS_CARD_LEN`, `fits_header_cards`, `parse_wcs_file_inner`, `sip_indices`, `sip_layout`, `parse_astap_ini_inner` |
| **1271-2032** | **`#[cfg(test)]`-only internal solver — delete** |
| 2033-2087 | `blind_solve`, `blind_solve_with_timeout`, `solve_near`, `solve_near_with_timeout` |
| 2088-2182 | `solve_with_external_config` |
| 2183-2258 | `SolverCommandOutput`, `run_solver_command` |
| 2259-2364 | `solve_with_astrometry`, `external_solver_unavailable` |
| 2366-2393 | `SOLVER_AVAILABLE_CACHE`, `is_solver_available`, `invalidate_solver_availability_cache`, `get_solver_path` |
| 2394-3386 | `mod tests` |

**Split plan.** `src/platesolve.rs` → `src/platesolve/mod.rs` (the directory already
exists and holds `platesolve_paths.rs`, so this is a rename + `mod` line edits).

1. **Delete lines 1271-2032** and the tests that exercise them, then drop the now-unused
   `#[cfg(test)]` imports at 57-63 and move `wgpu`/`pollster` out of `[dependencies]`
   (see §3.4). Do this *first* — it removes 762 code lines and ~400 test lines before any
   file surgery, which makes the rest of the split trivially small.
2. `src/platesolve/mod.rs` — module docs (1-56), `mod` declarations, `pub use` of every
   submodule's public items, and the public entry points from 2033-2087 plus the
   availability cache 2366-2393.
3. `src/platesolve/types.rs` ← lines 65-256: `PlateSolveError`, `PlateSolveResult`,
   `PlateSolverChoice`, `PlateSolverConfig` + its `Default`, `SolverPref`,
   `ACTIVE_SOLVER_PREF`, `set_solver_preference`. `ACTIVE_SOLVER_PREF` must stay `static`
   in exactly one module — it is the process-global config, so it moves whole, and
   `PlateSolverConfig::default()` moves with it.
4. `src/platesolve/discovery.rs` ← lines 264-529: `find_astap*`, `find_astrometry*`,
   `home_dir`, `which_on_path`, `detect_astap_catalog`, `SolverInfo`, `SolverVerifyError`,
   `verify_solver`. This is the natural home of the `platesolve_paths` submodule too —
   re-point `mod platesolve_paths;` here and re-export `CatalogInfo` from `mod.rs`.
5. `src/platesolve/astap.rs` ← lines 530-928 (`AstapSolver`).
6. `src/platesolve/astrometry.rs` ← lines 2259-2364.
7. `src/platesolve/process.rs` ← lines 2183-2258 (`SolverCommandOutput`,
   `run_solver_command`). **`AstapSolver::solve` must be migrated onto this** — see §2.3.
8. `src/platesolve/wcs_parse.rs` ← lines 930-1269. This is the highest-value extraction:
   the `.wcs`/`.ini` parsers are pure functions with the densest test coverage and the
   worst history (the "reads only the first FITS card" defect lived here), and they belong
   in a file where a reviewer can see the whole parser at once.
9. `src/platesolve/dispatch.rs` ← lines 2088-2182 (`solve_with_external_config`).

Result: 9 files, largest ~400 lines, and the crate stops compiling a GPU compute pipeline
it never runs.

### 1.3 `stacking.rs` — 3020 lines

**Why it is big.** Two independent engines share the file by explicit decision — the
comment at `stacking.rs:1225-1230` says so ("Why this lives next to LiveStacker"). The
online engine (`LiveStacker`) and the offline calibration-master combiner
(`combine_master_frames`) share only the concept "combine pixels", not one line of code.
Between them sits a complete rigid-registration stack (star matching, Procrustes fit,
consensus/RANSAC-ish inlier search, bilinear warp) that duplicates `registration.rs`
(see §2.5).

**Section boundaries (verified).**

| Lines | Content |
|---|---|
| 1-25 | docs + imports |
| 26-124 | `SensorMode`, `LiveStackConfig`, `Default` |
| 126-238 | `debayer_cfa_to_rgb`, `luminance_proxy`, `detection_plane` |
| 239-306 | `StackingStats`, `AffineTransform`, `PixelAccumulator` |
| 308-694 | `impl LiveStacker` (`new`, `add_frame`, `accumulate_pixels`, `get_current_stack`, `reset`, `frame_count`, `get_stats`) |
| 695-1122 | `StarMatch`, `match_stars`, `compute_affine_transform`, clip/consensus constants, `consensus_inliers`, `fit_transform_robust`, `compute_alignment_residual` |
| 1123-1230 | `apply_transform_bilinear`, `extract_u16_as_f64` |
| 1231-1551 | `MasterFrameKind`, `CombineMethod`, `MasterOutputType`, `MasterFrame`, `combine_master_frames`, `combine_pixel`, `median_in_place`, `sigma_clip_in_place` |
| 1552-3020 | `mod tests` |

**Split plan.** `src/stacking.rs` → `src/stacking/`.

1. `src/stacking/mod.rs` — docs, `mod` lines, `pub use` of all four submodules.
2. `src/stacking/config.rs` ← lines 26-124 + `StackingStats` (239-258).
3. `src/stacking/ingest.rs` ← lines 126-238 (`debayer_cfa_to_rgb`, `luminance_proxy`,
   `detection_plane`). Flag: `luminance_proxy` + `detection_plane` are byte-near-identical
   to `registration.rs:390-427` (§2.5) — this file is where the merge lands.
4. `src/stacking/align.rs` ← lines 259-287 (`AffineTransform`) + 695-1230
   (matching, fitting, warp, `extract_u16_as_f64`). ~460 lines.
5. `src/stacking/live.rs` ← lines 288-694 (`PixelAccumulator`, `LiveStacker`). ~400 lines.
6. **`src/stacking/masters.rs` ← lines 1231-1551.** Move it out entirely; it is not
   "stacking" in the live sense and its per-pixel loop is the one that should be deleted
   in favour of `integration.rs` (§2.2). Keeping it in its own file makes that follow-up a
   single-file change.
7. Tests split four ways along the same lines; the alignment tests
   (`test_apply_transform_bilinear_rotation_and_translation` at 1779,
   `match_stars_refuses_to_let_an_orphan_steal_a_claimed_star` at 2849,
   `sigma_clipping_uses_sample_variance_for_small_stacks` at 1864) are already grouped by
   subject and map cleanly.

### 1.4 `stats.rs` — 2503 lines

**Why it is big.** It is the crate's whole measurement layer: frame statistics, star
detection, star *measurement* (HFR/FWHM/SNR/eccentricity/sharpness), histograms, and star
crop extraction. `measure_star` alone (541-742) plus its helpers (743-947) is 400 lines.

**Section boundaries (verified).**

| Lines | Content |
|---|---|
| 1-22 | docs + imports |
| 23-110 | `ImageStats`, `calculate_stats_u16` |
| 111-260 | `DetectedStar`, `CameraNoiseModel`, eccentricity constants, `StarDetectionConfig` + `Default` |
| 261-482 | `detect_stars`, `selection_eccentricity_ceiling`, `measurement_eccentricity_ceiling`, `detect_stars_for_selection` |
| 483-529 | `estimate_background` |
| 530-947 | `StarMeasurementContext`, `measure_star`, `fallback_visited_radius`, `stamp_visited_disk`, `calculate_hfr_at_point`, `compute_snr` |
| 948-1051 | `calculate_median_hfr`, `calculate_histogram`, `calculate_display_histogram` |
| 1052-1275 | `StarDetectionResult`, `MIN_STARS_FOR_FRAME_ECCENTRICITY`, `frame_eccentricity`, `detect_stars_with_stats` |
| 1276-1382 | `StarCropData`, `extract_star_crop`, `extract_top_star_crops` |
| 1383-2503 | `mod tests` |

**Split plan.** `src/stats.rs` → `src/stats/`.

1. `src/stats/mod.rs` — docs + `mod`/`pub use`.
2. `src/stats/frame_stats.rs` ← lines 23-110 + 979-1051 (`ImageStats`,
   `calculate_stats_u16`, `calculate_histogram`, `calculate_display_histogram`). These are
   the three whole-frame reductions and they share the same u16 decode; grouping them is
   the precondition for the histogram-based rewrite in §4.3.
3. `src/stats/star_types.rs` ← lines 111-260 (`DetectedStar`, `CameraNoiseModel`,
   `DETECTION_MAX_ECCENTRICITY`, `SELECTION_MAX_ECCENTRICITY`, `StarDetectionConfig`).
4. `src/stats/detect.rs` ← lines 261-529 (`detect_stars`, the two ceiling helpers,
   `detect_stars_for_selection`, `estimate_background`).
5. `src/stats/measure.rs` ← lines 530-947. The single largest cohesive unit; it needs only
   `StarMeasurementContext`, `DetectedStar` and `StarDetectionConfig` from siblings.
6. `src/stats/summary.rs` ← lines 948-978 (`calculate_median_hfr`) + 1052-1275
   (`StarDetectionResult`, `frame_eccentricity`, `detect_stars_with_stats`).
7. `src/stats/crops.rs` ← lines 1276-1382.
8. Tests split by subject; note `stats.rs:2174` uses `detect_stars_for_selection` and
   `stats.rs:1960` (`median_hfr_is_not_inflated_by_trailed_sources`) belongs with
   `summary.rs`.

### 1.5 `sky_atlas.rs` — 2352 lines

**Why it is big.** It packs three layers: a from-scratch HEALPix NESTED implementation
(bit spread/compress, `zphi_to_nest`, `nest_to_zphi`, neighbour walk, cone/frame tile
queries), the per-tile accumulator with its own binary serialization format, and the
filesystem-backed `SkyAtlas`.

**Section boundaries (verified).**

| Lines | Content |
|---|---|
| 1-56 | docs + imports (`crate::registration::{sample_interleaved, Interpolator}` at 60) |
| 57-95 | `STORE_TILE_NONCE`, `TILE_STATE_VERSION`, `TILE_MAGIC`, `ATLAS_HEALPIX_ORDER`, `TILE_PIXELS`, `TILE_SCALE_MARGIN` |
| 96-455 | HEALPix + tile geometry: `nside_for`, `npix_for`, `spread_bits`, `compress_bits`, `xyf_to_nest`, `nest_to_xyf`, `zphi_to_nest`, `nest_to_zphi`, `wrap_jp`, `neighbours_nest`, `radec_to_tile`, `tile_center`, `tile_circum_radius_deg`, `tile_ids_for_cone`, `tile_ids_for_frame`, `tile_wcs` |
| 456-555 | `TileFoldRecord`, `TileProvenance`, `AtlasError` |
| 556-1028 | `SkyTileAccumulator` (create/fold/finalize/`serialize`/`deserialize`) |
| 1029-1187 | `MIN_HISTORY_FOR_CLIP`, `TileHeader`, `merge_tiles`, `merge_tiles_subtract`, `merge_signed` |
| 1188-1420 | `SkyAtlas` (open/`tile_path`/`load_tile`/`load_or_create`/`store_tile`/`fold_frame`/cutout) |
| 1421-1519 | `tile_buffer_bytes`, `tile_is_empty`, `decode_to_f64`, `estimate_frame_norm`, `normalize_sample`, `percentile_sorted`, `read_f64`, `read_u32` |
| 1520-2352 | `mod tests` |

**Split plan.** `src/sky_atlas.rs` → `src/sky_atlas/`.

1. `src/sky_atlas/mod.rs` — docs, constants 57-95, `mod`/`pub use`.
2. **`src/sky_atlas/healpix.rs` ← lines 96-455.** This is a self-contained, dependency-free
   spherical-indexing library with its own dense test set; it is the piece most worth
   isolating because it can then be property-tested (round-trip `radec_to_tile` /
   `tile_center`) without touching the atlas.
3. `src/sky_atlas/tile.rs` ← lines 456-1028 (`TileFoldRecord`, `TileProvenance`,
   `AtlasError`, `SkyTileAccumulator`). ~570 lines — still the biggest piece; if a second
   cut is wanted, `serialize`/`deserialize`/`TileHeader` + `read_f64`/`read_u32` move to
   `src/sky_atlas/codec.rs` (from 890-1028 plus 1033-1062 plus 1496-1519).
4. `src/sky_atlas/merge.rs` ← lines 1029-1187.
5. `src/sky_atlas/atlas.rs` ← lines 1188-1420 (`SkyAtlas`).
6. `src/sky_atlas/norm.rs` ← lines 1421-1495 (`tile_buffer_bytes`, `tile_is_empty`,
   `decode_to_f64`, `estimate_frame_norm`, `normalize_sample`, `percentile_sorted`).
   `percentile_sorted` here is one of the five duplicate percentile helpers (§2.1) — this
   is where the call to the shared helper lands.

### 1.6 `phd2.rs` — 2201 lines (1975 code — the largest *code* body in the crate)

**Why it is big.** `impl Phd2Client` spans lines 506-1536 — **a single 1031-line impl
block** — and `parse_phd2_event` is another 236 (1550-1785). It is a sync, thread-based
TCP JSON-RPC client (no `async`; `std::net::TcpStream` with read timeouts at 676-690, an
event listener thread at 745-754), plus PHD2 process discovery/launch at 1839-1949.

**Split plan.** `src/phd2.rs` → `src/phd2/`.

1. `src/phd2/mod.rs` — docs + `mod`/`pub use` + `normalize_phd2_tcp_host` /
   `is_phd2_server_listening` (21-37).
2. `src/phd2/types.rs` ← lines 39-244 (`Phd2State`, `GuideStats`, `StarImageData`,
   `AlgoParam`, `RollingGuideStats` + `Default`/`impl`).
3. `src/phd2/wire.rs` ← lines 245-374 (`Phd2ConnectionConfig`, `GuideFrame`, `Phd2Event`,
   `JsonRpcRequest`, `JsonRpcResponse`, `JsonRpcError`, `Phd2EventMessage`) + 1550-1805
   (`parse_phd2_event`, `parse_phd2_app_state`) + 1806-1838 (`base64_decode`).
4. `src/phd2/settle.rs` ← lines 375-479 (`SettleOutcome`, `SettleWaiter`, `SettleTracker`).
5. `src/phd2/client.rs` ← lines 480-1549 (`Phd2Client`, its impl, `Drop`). Still ~1070
   lines; the impl itself should then be cut along the two boundaries already visible in
   it — the connection/listener half (506-~860, including the free
   `start_event_listener`/`handle_event` helpers that take `&Arc<Mutex<…>>` parameters at
   857-861) into `src/phd2/listener.rs`, and the RPC-command half (~860-1536) staying in
   `client.rs`.
6. `src/phd2/process.rs` ← lines 1839-1975 (`is_phd2_running`, `is_phd2_installed`,
   `launch_phd2`) — platform-specific process code that has no business inside a protocol
   client.

### 1.7 Remaining seven files (compact plans)

- **`mosaic_stitch.rs` (1884).** Cut into `mod.rs` (config/types 66-205, `stitch_mosaic`
  1176-1279), `projection.rs` (`WcsProjection` 207-360), `panels.rs` (`DecodedPanel`,
  `CanvasBox` 361-453), `resample.rs` (454-594 — **delete instead and call
  `registration::sample_interleaved`, §2.4**), `layout.rs` (`build_output_wcs` 595-757),
  `photometry.rs` (`PanelPhotometry`, `solve_panel_photometry`, `solve_anchored_chain`,
  `gaussian_solve`, `fit_overlap_pair` 758-1010), `render.rs` (`render_canvas`,
  `panel_weight` 1011-1175).
- **`registration.rs` (1871).** Cut into `mod.rs` (types/config/errors 49-252, public
  `min_registration_stars` / `registrable_star_count` / `register_frame` 253-427),
  `descriptors.rs` (428-670), `fit.rs` (671-1009 — RANSAC + the four model fitters),
  `resample.rs` (1010-1228 — `warp_frame`, `sample`, `sample_interleaved`,
  `separable_sample`, `catmull_rom`, `lanczos3`; this becomes the crate's single
  resampler), `linalg.rs` (1229-1345 — `invert_3x3`, `mat3_vec3`, `solve_linear_system`,
  `rms`, `Rng`).
- **`master_accumulation.rs` (1716 / 952 code).** Below the code threshold once tests are
  split out. Cut `mod.rs` + `codec.rs` (serialize/deserialize ~640-730 + `read_f64`/`read_u32`
  880-910) only.
- **`background_extraction.rs` (1695 / 1130).** Cut model fitting from sample-grid
  construction; `median_f64`/`percentile_f64` (1102-1127) delete in favour of §2.1.
- **`drizzle.rs` (1694 / 753).** Code body is fine. The 941-line test module is the problem —
  move the synthetic-frame builders into a `#[cfg(test)] mod fixtures` and split the tests
  by kernel/geometry/regression.
- **`deconvolution.rs` (1635 / 1122).** Split PSF estimation (`bilinear_sample`,
  `median_combine`, crop resampling ~200-450) from Richardson-Lucy iteration (~450-1122).
- **`difference_image.rs` (1509 / 1132).** Split reprojection+subtraction from source
  extraction (the flood-grow detector around 549-790) and photometric matching
  (`robust_theil_sen` 794-848).

---

## 2. Duplication

### 2.1 Eight median implementations and five percentile implementations — HIGH value, small effort

Every one of these is a hand-rolled sort-then-index over `f64`/`u16`:

| Site | Signature | Convention |
|---|---|---|
| `stacking.rs:1498` `median_in_place` | `&mut [f64] -> f64` | sort_by partial_cmp, no empty guard |
| `calibration_masters.rs:508` `median_of` / `:515` `median_in_place_f64` | `&[u16]` / `&mut [f64]` | `total_cmp`, empty→0 |
| `color_calibration.rs:442` `median` | `&mut [f64]` | `total_cmp`, empty→0 |
| `difference_image.rs:849` `median` | `&mut [f64]` | `total_cmp`, empty→0 |
| `mosaic_stitch.rs:694` `median` | `&mut [f64]` | partial_cmp, empty→0 |
| `background_extraction.rs:1102` `median_f64` | `&mut [f64]` | `total_cmp`, empty→0 |
| `frame_weighting.rs:257` `median_f64` | `Vec<f64>` (consumes) | `par_sort_unstable`, empty→0 |
| `integration.rs:777` `median_of_sorted` | `&[f64]` pre-sorted | empty→0 |
| `defect_map.rs:457`, `:512`, `:633`, `:832` | inline in-place medians | scratch-buffer variants |

| Site | Convention |
|---|---|
| `sky_atlas.rs:1488` `percentile_sorted` | nearest-rank on `(len-1)*q`, `.round()` |
| `difference_image.rs:626` `percentile_sorted` | **byte-identical to sky_atlas** |
| `background_extraction.rs:1117` `percentile_f64` | nearest-rank, sorts in place |
| `frame_weighting.rs:271` `percentile_u16` | nearest-rank over u16 |
| `stretch.rs:367` `percentile_sorted` | `(n * frac) as usize` — **floor, no `-1`; a different answer** |
| `master_accumulation.rs:864` `percentile_of_sorted` | **linear interpolation between ranks** |

Three genuinely different percentile conventions are in play, and nothing names them. That
is the actual risk: `stretch.rs` and `sky_atlas.rs` return different values for the same
input and neither says so at the call site.

**Canonical survivor.** New `src/robust_stats.rs`, `pub(crate)`, exporting exactly:

```
pub(crate) fn median_sorted(sorted: &[f64]) -> f64            // even -> mean of centres
pub(crate) fn median_in_place(v: &mut [f64]) -> f64           // total_cmp, empty -> 0.0
pub(crate) fn percentile_nearest_rank(sorted: &[f64], q: f64) -> f64
pub(crate) fn percentile_interpolated(sorted: &[f64], q: f64) -> f64
pub(crate) fn percentile_floor(sorted: &[f64], q: f64) -> f64 // stretch.rs's PixInsight-matching variant
pub(crate) fn mad_sigma(sorted: &[f64], median: f64) -> f64   // the 1.4826 scaling used in 6 places
```

Merge in: all nine median sites → `median_in_place` / `median_sorted`;
`sky_atlas.rs:1488`, `difference_image.rs:626`, `background_extraction.rs:1117`,
`frame_weighting.rs:271` → `percentile_nearest_rank`; `master_accumulation.rs:864` →
`percentile_interpolated`; `stretch.rs:367` → `percentile_floor` (keeping the existing doc
comment as that function's doc, so the difference is stated once instead of implied
nowhere). `frame_weighting.rs`'s `par_sort_unstable` variant is a performance choice, not
a semantic one — keep it as `median_in_place_par`.

Effort: small. Behaviour-preserving as long as each call site is mapped to the variant that
matches its current convention, which the table above fixes.

### 2.2 Two per-pixel stack combiners — `combine_master_frames` vs `integrate_frames` — HIGH value

- `stacking.rs:1327 combine_master_frames(frames: &[ImageData], kind, method, output_type)`
  — Mean / Median / SigmaClip.
- `integration.rs:273 integrate_frames(frames: &[IntegrationFrame], w, h, c, config)` —
  Mean / weighted mean, and rejection by SigmaClip, WinsorizedSigmaClip, LinearFitClip,
  PercentileClip, MinMax, plus coverage masks, rejection maps and weight maps.

`integrate_frames` is a strict superset of `combine_master_frames`'s statistics, and it is
also the *correctly written* one: it parallelises over rows and reuses one `samples`
scratch buffer per row (`integration.rs:353-373`), whereas `combine_master_frames`
allocates a fresh `Vec<f64>` **per output pixel** (`stacking.rs:1419`) and holds every
frame as a separate full-size `f64` buffer (`stacking.rs:1400-1411`).

**Canonical survivor: `integration.rs::integrate_frames`.** `combine_master_frames` becomes
a thin adapter that keeps its public signature, decodes each `ImageData` to `f64` once,
builds `IntegrationFrame { pixels, weight: 1.0, coverage: None }`, maps
`CombineMethod::{Mean,Median,SigmaClip}` onto `Combine`/`Reject`, calls `integrate_frames`,
then applies the flat-normalisation and `MasterFrame` wrapper it already owns
(`stacking.rs:1425-1473`). The only behaviour worth checking in review is that
`Reject::SigmaClip { low: kappa, high: kappa }` with `MAX_ITERATIONS` clamped to the
caller's `iterations` reproduces `sigma_clip_in_place`'s fallback-to-median-on-total-rejection
(`stacking.rs:1514-1551`).

Callers to leave untouched: `calibration_masters.rs:188` (`build_master_flat`) and
`bridge/src/api/post_session.rs:1438`. Effort: medium.

### 2.3 The ASTAP subprocess runner is copy-pasted — MEDIUM value, small effort

`platesolve.rs:655-740` (inside `AstapSolver::solve`) and `platesolve.rs:2189-2256`
(`run_solver_command`) are the same 70-line routine: spawn with piped stdio, take both
pipes into detached reader threads, `wait_timeout`, on `Ok(None)` log + `kill` + `wait` +
`drop` both readers + format a `(cleanup: kill=…, reap=…)` string, on `Err` kill/wait/drop,
otherwise `join().unwrap_or_default()` both readers. Even the cleanup-message format string
is duplicated verbatim.

`run_solver_command` was clearly extracted for the astrometry.net path and `AstapSolver`
was never migrated. **Canonical survivor: `run_solver_command`** (it already returns a
`SolverCommandOutput` and a `Result<_, String>`); `AstapSolver::solve` replaces lines
655-740 with one call and maps the `Err(String)` into its `PlateSolveResult { success:
false, error: Some(msg), solve_time_secs: start.elapsed()… }`. The only content-bearing
difference is the log label ("ASTAP" vs the `label` parameter), which `run_solver_command`
already parameterises.

### 2.4 `mosaic_stitch` re-implements the shared resampler — MEDIUM value, small effort

`registration.rs:1130 sample_interleaved` exists specifically as the shared entry point;
its doc says so, and `sky_atlas.rs:60,752,1380,1385` and `difference_image.rs:51,227` use
it. `mosaic_stitch.rs` does not: it has private `sample_plane` (454), `separable` (502),
`catmull_rom` (559) and `lanczos3` (572), with comments at 558 and 571 that literally read
"matches `registration::catmull_rom`" / "matches `registration::lanczos3`".

**Canonical survivor: `registration::sample_interleaved` + `Interpolator`.** Delete
`mosaic_stitch.rs:454-594` and route `render_canvas` (1011) through the shared sampler.
The one thing to verify in review: `mosaic_stitch::sample_plane` takes a single-channel
plane while `sample_interleaved` takes `(data, width, height, channels, channel, …)` —
calling it with `channels = 1, channel = 0` is the equivalent form, and both return `0.0`
when the kernel support leaves the image (stated in `registration.rs:1118-1121`).

### 2.5 `luminance_proxy` + `detection_plane` exist twice — LOW-MEDIUM value, small effort

`stacking.rs:183-238` and `registration.rs:390-427`. Diffed: the bodies of
`luminance_proxy` differ only by a `debug_assert_eq!` present in `stacking` and absent in
`registration`; `detection_plane` differs only in the `unreachable!` message. The
`registration.rs:392` doc comment already says "mirrors `stacking::detection_plane`".

**Canonical survivor:** one `pub(crate) fn detection_plane` + `luminance_proxy` in a new
`src/detection_plane.rs` (or in `stats/` next to `detect_stars`, which is its only
consumer). Keep the `debug_assert_eq!`. Both call sites already validate `channels ∈ {1,3}`
and `pixel_type == U16` before calling (`stacking.rs:342-350`,
`registration.rs:364-384`), so the `unreachable!` stays honest.

### 2.6 Two FITS geometry parsers that disagree — HIGH value (correctness), small effort

`fits.rs:248-290` (`read_fits_from_reader`) and `reader.rs:55-95`
(`MappedFitsReader::open`) both parse BITPIX/NAXIS/NAXIS1/NAXIS2/NAXIS3 and map BITPIX to
`PixelType`. `reader.rs` already reuses `crate::fits::read_header` (line 55), so only the
*interpretation* is duplicated — and it has drifted:

- `fits.rs:268-272` rejects `NAXIS > 3` with `FitsError::Unsupported4DCube { naxis }`,
  with a "Why:" comment explaining that silently loading one plane of a cube corrupts
  science workflows.
- `reader.rs:83-85` has no such check: `channels = if naxis >= 3 { NAXIS3 } else { 1 }`.
  A 4-D cube opened through `MappedFitsReader` is silently read as a 3-D image.

**Canonical survivor:** extract
`pub(crate) fn geometry_from_header(&FitsHeader) -> Result<(u32,u32,u32,PixelType), FitsError>`
into `fits/read.rs` (or `fits/header.rs`) carrying the `NAXIS > 3` rejection, and have both
call sites use it. This closes the divergence as a side effect of the dedup.

### 2.7 `WcsInfo` vs `SipWcs` — LOW value, medium effort, note only

`fits.rs:1087 WcsInfo` (CRVAL/CRPIX/CD only) is a proper subset of `wcs_sip.rs:61 SipWcs`
(same eight fields plus A/B/AP/BP SIP coefficient arrays). Both have a `from_plate_solve`
(`fits.rs:1116`, `wcs_sip.rs:111`). I checked the CRPIX derivation in both and they agree
(`(N+1)/2` vs `w/2 + 0.5`), and `wcs_sip.rs:117-119` explicitly documents mirroring
`WcsInfo::from_plate_solve` for the degenerate-CD case — so this is *documented* parallelism,
not silent drift. `bridge/src/api/sky_atlas.rs:98 wcs_info_from_tile` already exists to
convert one to the other.

Recommendation is deliberately weak: **do not merge these in this pass.** `WcsInfo` is the
FITS-card DTO that `add_wcs_headers` writes; `SipWcs` is the projection engine. The
worthwhile tightening is one-directional — add `impl From<&SipWcs> for WcsInfo` in
`fits/wcs.rs` and delete `bridge/src/api/sky_atlas.rs:98-110` — not a type merge.

### 2.8 Cross-package duplication suspects (one line each; for the cross-cutting agent)

- **Frame quality score, CONFIRMED DRIFTED.** `fits.rs:2090 calculate_quality_score` and
  `packages/skotiq_core/lib/src/services/frame_quality_score.dart:37
  computeFrameQualityScore` implement the same weights/bands (the Dart file's own comment
  at line 33 says it "mirrors the Rust implementation in `imaging/fits.rs`"), but the Rust
  version applies an extra severe-focus penalty for `hfr > 5.0` (`fits.rs:2150-2160`) that
  the Dart version does not, and the Dart version returns `NaN` where Rust returns `0.0`
  when no component is measurable.
- **Airmass.** `fits.rs:1273 calculate_airmass` vs Dart `airmassForFrame`
  (`packages/skotiq_app/lib/screens/analytics/widgets/photometric_calibration_wizard/frame_selection.dart:420`).
- **Auto-stretch / STF.** `stretch.rs` (`robust_stats` 342, `stf_from_stats`) vs the Dart
  stretch controls in `packages/skotiq_app/lib/screens/imaging/widgets/stretch_controls.dart`
  and `packages/skotiq_app/lib/screens/stack_result/`.
- **Display histogram.** `stats.rs:1012 calculate_display_histogram` (log/linear binning
  for the UI) vs whatever the Dart histogram widget computes from raw pixels.
- **Gnomonic projection.** `wcs_sip.rs:368 tan_project` / `:391 tan_deproject` and
  `mosaic_stitch.rs:207 WcsProjection` vs the planetarium's Dart projection math.
- **Debayer.** `debayer.rs` (bilinear + higher-quality) vs any Dart-side preview debayer
  in the imaging preview path.
- **FITS keyword names.** `fits.rs:1195 StandardKeywords` (dead here) vs the FITS keyword
  string constants the Dart/bridge side writes into headers.

---

## 3. Dead code

### 3.1 `StandardKeywords` — `fits.rs:1193-1243` — CONFIRMED

A unit struct with 49 associated `&'static str` constants (BITPIX, NAXIS…, RADESYS).
Evidence: `grep -rn "StandardKeywords" native/ --include="*.rs"` (excluding `frb_dump`)
returns exactly two hits — the `pub struct` at 1195 and the `impl` at 1197. Zero uses, in
this crate, in `bridge/`, in `sequencer/`, in tests, or in examples. Every one of these
keywords is written as a bare string literal elsewhere (e.g. `fits.rs:1180-1191`,
`fits.rs:722-724`). It is `pub` and re-exported by the `lib.rs` barrel, but no Dart binding
can consume a Rust associated const, so the barrel is not a caller. **Delete 51 lines.**

### 3.2 `calculate_quality_score` — `fits.rs:2090-2167` — CONFIRMED (production-dead)

Evidence: `grep -rn "calculate_quality_score(" native/ --include="*.rs"` returns 7 hits,
all inside `fits.rs`'s own `mod tests` (2996, 3006, 3018, 3028, 3175, 3182, 3189). No
`bridge/` caller, no FRB export. The live implementation is the Dart one
(`packages/skotiq_core/lib/src/services/frame_quality_score.dart`, §2.8) — and the
Dart file's comment names this Rust function as the thing it mirrors, which is exactly how
the two drifted. **Delete 95 lines and the 7 tests**, or — if the intent is that Rust owns
the formula — wire it up and delete the Dart copy. Do not leave both.

### 3.3 `validate_image_with_options` — `fits.rs:1691-1706` — CONFIRMED (production-dead)

A 4-argument shim over `validate_image_comprehensive`. Evidence: `grep -rn
"validate_image_with_options(" native/ --include="*.rs"` → 4 hits, all in `fits.rs`'s test
module (2538, 2560, 2609, 2635). The live callers use `validate_image`
(`bridge/src/api/imaging.rs:3617`) or `validate_image_comprehensive`
(`bridge/src/unified_device_ops.rs:763`). **Delete 16 lines**; retarget the 4 tests at
`validate_image_comprehensive`.

### 3.4 The entire internal plate solver — `platesolve.rs:1271-2032` — CONFIRMED (762 lines)

Every item is individually `#[cfg(test)]`-gated (attribute lines listed in §1.2): the
`GPU_DOWNSAMPLE_SHADER` WGSL source, `DownsampleParams`, `to_monochrome_u16`,
`cpu_downsample_max_u16`, `GPU_ATTEMPT_TIMEOUT`, `GPU_PLATE_SOLVE_UNRESPONSIVE`,
`gpu_downsample_max_u16_bounded`, `gpu_downsample_max_u16`, `PLATESOLVE_DETECTION_SIGMA`,
`estimate_background_u16`, `plate_solve_min_separation`, `detect_local_maxima`,
`extract_plate_stars`, `infer_center_from_header`, `parse_ra_string`, `parse_dec_string`,
`parse_sexagesimal`, `infer_pixel_scale_from_header`, `estimate_rotation`, `solve_internal`.

Evidence of no production caller: `grep -rn "solve_internal\|extract_plate_stars\|gpu_downsample"
native/skotiq_native --include="*.rs"` outside `platesolve.rs` returns nothing; inside
`platesolve.rs` the only `solve_internal(` call sites are 2503 and 2513, both in
`mod tests`. Whoever quarantined it behind `#[cfg(test)]` stopped one step short of
deleting it.

**Consequences of deleting it:**

- 762 code lines plus roughly 400 lines of the 993-line test module.
- `platesolve.rs:57-63` — the `#[cfg(test)]` imports of `wgpu::util::DeviceExt`,
  `bytemuck::{Pod, Zeroable}`, `detect_stars`, `read_fits`, `StarDetectionConfig`,
  `PixelType` — become removable.
- **`wgpu = "0.19"` and `pollster = "0.3"` (`imaging/Cargo.toml:31-32`) are in
  `[dependencies]` and are used by nothing else in the workspace.** Evidence:
  `grep -rln "wgpu::\|pollster::" native/skotiq_native --include="*.rs"` (excluding
  `frb_dump`) returns exactly one file, `imaging/src/platesolve.rs`, and every hit in it is
  inside the `#[cfg(test)]` block. Deleting the block lets both dependencies go, which
  removes a large transitive graph (and a GPU-driver-loading surface) from the shipped
  `.so`. `bytemuck` stays — it is used by `[dependencies]` code elsewhere; verify before
  removing.

This is the single biggest, lowest-risk line reduction available in this subsystem.

### 3.5 `FitsValue::Comment` variant — `fits.rs:62-64` — CONFIRMED (never constructed)

The variant's own doc says "Retained only for backward source compatibility; never
produced by the reader". Evidence: `grep -rn "FitsValue::Comment" native/ --include="*.rs"`
returns two hits, both in `write_fits`'s match arm (`fits.rs:749` comment, `:752` the arm).
Nothing anywhere constructs it. Removing the variant deletes the arm and one branch from
every `match` over `FitsValue`. Low value on its own; free if `fits.rs` is being split
anyway.

### 3.6 `generate_thumbnail` — `reader.rs:319` — example-only, NOT dead

Flagged so a later pass does not mis-delete it: the only callers are
`imaging/examples/performance_demo.rs:12,152`. It is `pub` and barrel-exported but no
`bridge/` code calls it. Judgement: this is a real capability the headless/mobile thumbnail
path might want; leave it and note it, rather than delete.

### 3.7 Things that look dead but are not (do not touch)

- `detect_astap_catalog` (`platesolve.rs:373`) — called from
  `bridge/src/api/plate_solve.rs:373`.
- `verify_solver` (`platesolve.rs:472`) — `bridge/src/api/plate_solve.rs:403`.
- `invalidate_solver_availability_cache` (`platesolve.rs:2385`) — settings hook;
  referenced from `bridge/src/api/storage.rs:92`'s comment block, verify before touching.
- `calculate_display_histogram` (`stats.rs:1012`) — one caller,
  `bridge/src/api/imaging.rs:2541`.
- `extract_top_star_crops` (`stats.rs:1353`) — `bridge/src/api/imaging.rs:2499` and
  `sequencer/src/instructions.rs:5367`.
- `merge_tiles_subtract` (`sky_atlas.rs:1074`) — used by the atlas un-fold path; keep.

---

## 4. Performance risks

### 4.1 `write_fits` writes pixel data one scalar at a time — HIGH

`fits.rs:783-789` (U16), `:791-799` (U32), `:800-806` (F32), `:807-814` (F64): each branch
is a `for chunk in image.data.chunks_exact(N)` loop whose body ends in
`writer.write_all(&val.to_be_bytes())?`. The writer is a default `BufWriter` (`fits.rs:680`,
8 KiB capacity). For a 61 MP mono 16-bit frame that is ~61 million `write_all` calls, each
with its own buffer-capacity check, plus a `write` syscall every 4096 pixels. The
header-padding loops at `fits.rs:773-775` and `816-819` have the same shape (up to 2879
single-byte `write_all` calls each).

This is on the capture hot path — every light frame, every calibration frame, every temp
FITS the sequencer writes before a plate solve (`bridge/src/sequencer_ops.rs:1129`).

Fix: build the big-endian buffer once (`rayon` `par_chunks` into a `Vec<u8>` of the same
size, or a 64 KiB block loop to bound peak memory) and issue one `write_all` per block.
Padding becomes `write_all(&[b' '; 2880][..padding])`.

### 4.2 `combine_master_frames` allocates a `Vec` per output pixel — HIGH

`stacking.rs:1419`: `let mut samples: Vec<f64> = frame_stacks.iter().map(|s| s[i]).collect();`
inside `(0..pixel_count).into_par_iter().map(…)`. One heap allocation and free per output
pixel — 24 million of them for a 24 MP mono master, 61 million for a 61 MP one. The
in-file comment ("Small Vec; allocation per pixel is the cost of the offline path")
acknowledges it. The gather is also strided across `frames.len()` separate allocations, so
every sample is a cache miss.

Compounding it, `stacking.rs:1400-1411` materialises `frame_stacks: Vec<Vec<f64>>` —
`frames.len() × pixel_count × 8` bytes, on top of the caller's already-resident
`&[ImageData]`. 30 darks at 24 MP mono is 5.8 GB of `f64` plus 1.4 GB of source `u16`.

Fix: §2.2 — delegate to `integrate_frames`, which already solves both (row-parallel with a
reused scratch `Vec<Sample>`, `integration.rs:353-373`). If the merge is deferred, the
interim fix is `par_chunks_mut` over rows with one hoisted scratch buffer, plus decoding
frames a row-band at a time instead of whole.

### 4.3 `calculate_stats_u16` does two full-size allocations and two full sorts — MEDIUM-HIGH

`stats.rs:39-43` allocates `pixels: Vec<u16>` (2 bytes/px), `:75` sorts it, `:85-89`
allocates `deviations: Vec<f64>` (**8 bytes/px**) and `:91` sorts that too. For a 61 MP
frame: 122 MB + 490 MB transient and two `par_sort_unstable` passes over 61 M elements —
to produce six scalars.

The input is `u16`. A 65536-bucket histogram gives min/max/mean/median exactly in one O(n)
pass with 256 KB of memory, and MAD in a second O(n) pass over the same histogram. That is
the standard fix and it is exact, not approximate.

Called per frame from `frame_weighting.rs:176 analyze_frame_quality`, which in the same
function also calls `image.as_u16()` (`frame_weighting.rs:167` — a third full copy) and
`detect_stars_with_stats` (which allocates its own `Vec<f64>`, `stats.rs:269-274`). One
quality assessment of a 61 MP frame therefore allocates and frees on the order of 1.2 GB.

### 4.4 `SkyAtlas::fold_frame` reads and rewrites every touched tile per frame — HIGH

`sky_atlas.rs:1276 fold_frame` processes tiles one at a time: `load_tile`
(`:1223 std::fs::read` of the whole sidecar) → fold → `store_tile`
(`:1269 std::fs::write` of the whole re-serialised sidecar + rename). A tile is
`TILE_PIXELS² × channels × 40` bytes (`sky_atlas.rs:1421-1424`; `TILE_PIXELS = 1024` at
`:77`) — **41.9 MB per channel**, 126 MB for a 3-channel tile.

A frame typically covers several tiles. At 4 tiles/frame mono that is ~168 MB read +
~168 MB written *per frame*; over a 200-frame night, ~67 GB of disk traffic, most of it
rewriting bytes that the next frame will immediately re-read. Caller:
`bridge/src/api/sky_atlas.rs:336`, once per frame.

The struct already has the concept needed to fix it — `memory_budget_bytes`
(`sky_atlas.rs:1193-1195`) is documented as bounding resident tile buffers — but
`fold_frame` never uses it as a cache; the `debug_assert!` at `:1300` only checks that one
buffer fits. Fix: an LRU of decoded tiles keyed by `TileId`, bounded by
`memory_budget_bytes`, flushed at end-of-session or on eviction; or a batch
`fold_frames(&[…])` that groups frames by tile.

Secondary: `SkyTileAccumulator::serialize` (`sky_atlas.rs:914-931`) appends 8 bytes at a
time in six loops over `slot_count` elements — for a 3-channel tile that is ~19 M
`extend_from_slice` calls. `bytemuck::cast_slice` (already a dependency) turns each loop
into one `extend_from_slice`.

### 4.5 Every plate solve re-probes the filesystem, twice, and may spawn 3 subprocesses — MEDIUM

`PlateSolverConfig::default()` (`platesolve.rs:179`) calls `find_astap_with_override`
(`:264`) and `find_astrometry_with_override` (`:298`). Each builds a candidate list, stats
them (`first_existing`), and **if none exists falls through to `which_on_path`**
(`platesolve.rs:331-336`), which does `Command::new("which"|"where").arg(…).output()` — a
process spawn. ASTAP tries two names (`"astap"` then `"astap_cli"`, `:281-282`) and
astrometry one (`"solve-field"`, `:308`), so on a machine with no solver installed a single
`PlateSolverConfig::default()` spawns three subprocesses.

And `blind_solve` (`platesolve.rs:2033-2035`) calls
`PlateSolverConfig::default().timeout_secs` and then `blind_solve_with_timeout`, which
calls `PlateSolverConfig::default()` **again** (`:2040-2043`) — the whole probe runs twice
per solve. `solve_near` (`:2048-2060`) has the identical double-call.

`is_solver_available()` is cached (`SOLVER_AVAILABLE_CACHE`, `platesolve.rs:2366-2384`) but
`get_solver_path()` (`:2390`, exported to Dart via `bridge/src/api/plate_solve.rs:87`) is
not, so any UI that polls it re-probes each time.

Fix: (a) have `blind_solve`/`solve_near` build the config once and pass it down —
two-line change, removes half the cost immediately; (b) memoise the discovery result in the
same `OnceLock`/`Mutex` pattern `SOLVER_AVAILABLE_CACHE` already establishes, invalidated
by `set_solver_preference` (`:243`) and `invalidate_solver_availability_cache` (`:2385`).

### 4.6 `LiveStacker::add_frame` allocates two full-frame `f64` buffers per frame — MEDIUM-HIGH (memory)

`stacking.rs:544 extract_u16_as_f64(frame)` (8 bytes/px) and `:545 apply_transform_bilinear(…)`
returning another `Vec<f64>` of the same size. On top of that the persistent
`accumulators: Vec<PixelAccumulator>` where `PixelAccumulator` is `{ f64, f64, u32 }`
(`stacking.rs:288-295`) — 24 bytes/px with padding.

At 61 MP mono: 1.47 GB resident + 980 MB transient per frame. At 24 MP: 576 MB resident +
384 MB transient. For 3-channel OSC, triple it. `detection_plane` adds one more full-frame
allocation for RGB input (`stacking.rs:226-238`).

Fix (in priority order): (a) pack `PixelAccumulator` as three parallel `Vec`s
(`sum: Vec<f64>`, `sum_sq: Vec<f64>`, `count: Vec<u32>`) — removes the padding and makes
the accumulate loop (`stacking.rs:602-644`) sequential over three contiguous arrays instead
of strided over a 24-byte struct; (b) fuse `extract_u16_as_f64` into
`apply_transform_bilinear` so it samples the `u16` buffer directly and never materialises
the intermediate; (c) `get_current_stack()` is called at the end of *every* `add_frame`
(`stacking.rs:588`) and allocates a full `u16` output — offer an `add_frame_no_render`
for callers that stack N frames before displaying.

### 4.7 Reading a 16-bit FITS triple-buffers it — MEDIUM

`fits.rs:585-596 read_i16_data` allocates `buffer: Vec<u8>` (2 bytes/px), then collects
`data: Vec<i16>` (2 bytes/px). `read_fits_from_reader` then builds `adjusted: Vec<u8>`
(2 bytes/px) at `fits.rs:319-341`. Three full-size allocations to load one image; for a
61 MP frame, 366 MB of allocation for a 122 MB result.

Fix: read into one `Vec<u8>` and byte-swap + apply BZERO in place (`chunks_exact_mut(2)`),
returning that same buffer. Same shape applies to `read_i32_data` (600), `read_f32_data`
(622), `read_f64_data` (644).

### 4.8 `consensus_inliers` clones and allocates per hypothesis — LOW-MEDIUM

`stacking.rs:968` builds `let seed = [matches[a].clone(), matches[b].clone()]` — two
`StarMatch`, each holding two `DetectedStar` (10 `f64` each) — and `:971-980` collects a
fresh `Vec<usize>` of agreeing indices, both inside a loop bounded by
`MAX_CONSENSUS_HYPOTHESES = 8000` (`stacking.rs:897`). Worst case per rejected frame: 16000
struct clones and 8000 `Vec` allocations. It only runs when the plain fit already exceeds
`CONSENSUS_TRIGGER_PX = 1.0` (`stacking.rs:887`), which is the common case on a drifting
mount. `fit_transform_robust` additionally does `matches.to_vec()` at `stacking.rs:1021`.

Marked LOW-MEDIUM honestly: with `max_match_stars = 100` (`stacking.rs:89`) the absolute
cost is on the order of milliseconds. Fix is cheap regardless — pass `(&matches[a], &matches[b])`
by reference into a two-pair overload of `compute_affine_transform`, and reuse one
`Vec<usize>` across hypotheses with `clear()`.

### 4.9 `MappedFitsReader::open` logs at `info` per open — LOW

`reader.rs:100-107` emits a `tracing::info!` with dimensions on every open. On a live-stack
or gallery scroll that is one info line per file. Should be `debug!`.

---

## 5. Reliability risks

### 5.1 `read_image` Debug-stringifies FITS values, and a calibrated frame inherits the mangled cards — HIGH

`lib.rs:842` and `lib.rs:857`:

```rust
.map(|(k, v)| (k, format!("{:?}", v)))
```

`FitsValue` is `#[derive(Debug)]` (`fits.rs:56-65`) with variants `String(String)`,
`Integer(i64)`, `Float(f64)`, `Boolean(bool)`. So `ImageReadResult.header` carries values
like `String("Ha")`, `Float(120.0)`, `Integer(100)`, `Boolean(true)` — the Rust variant
syntax, not the value.

That is survivable as long as consumers only display it. One does not:
`bridge/src/api/imaging.rs:4811-4813` (the calibrate-and-save path) does

```rust
for (key, value) in &light_result.header {
    header.set_string(key, value);
}
```

and then `write_fits`. The resulting calibrated FITS contains
`EXPTIME  = 'Float(120.0)'`, `GAIN = 'Integer(100)'`, `FILTER = 'String("Ha")'`,
`DATE-OBS = 'String("2026-…")'`, `CCD-TEMP = 'Float(-10.0)'` — every value a *string*
carrying its Rust type name. Skotiq's own reader will then return `None` from
`get_float("EXPTIME")` on that file, and PixInsight/ASTAP/Siril see garbage.

Mitigating fact worth stating: `write_fits` skips `SIMPLE/BITPIX/NAXIS*/BZERO/BSCALE`
(`fits.rs:722-729`), so the file still *opens*; the damage is confined to the science
metadata.

Fix at the root (in this subsystem): give `FitsValue` a `to_header_string()` (or `Display`)
that emits the bare token — `s.clone()`, `i.to_string()`, `format_fits_float(*f)`,
`"T"`/`"F"` — and use it at `lib.rs:842` and `:857`. Better still, change
`ImageReadResult.header` to `HashMap<String, FitsValue>` and let the bridge choose;
that is a wider change and should be scoped separately.

### 5.2 Two FITS geometry parsers disagree on 4-D cubes — MEDIUM

Covered as duplication in §2.6; restated here because the consequence is silent data
corruption, not just duplication. `fits.rs:268-272` rejects `NAXIS > 3`;
`reader.rs:83-85` accepts it and reads only `NAXIS3` planes as channels. Any path that
uses `MappedFitsReader` (`reader.rs:332 generate_thumbnail`, and any bridge use of the
mapped reader) will silently mis-read a spectral/temporal cube that `read_fits` correctly
refuses.

### 5.3 `detect_stars` and `calculate_stats_u16` reinterpret bytes without checking `pixel_type` — MEDIUM

`stats.rs:265-274`: the only guard is `image.data.len() < width * height * 2`; the function
then does `image.data.par_chunks_exact(2).map(|c| u16::from_le_bytes(…))` regardless of
`image.pixel_type`. Same in `calculate_stats_u16` (`stats.rs:39-43`). Grep confirms
`pixel_type` appears exactly once in the whole 2503-line file, at `stats.rs:1401`
(inside `extract_star_crop`).

Handed an `F32` or `U32` `ImageData`, both functions return confident nonsense rather than
an error.

Honest scoping: **I could not find a live call site that does this.** Every caller I traced
either constructs a `U16` plane explicitly
(`bridge/src/api/finishing_analyze.rs:373 mono_u16_detection_plane`,
`star_reduction.rs:244 plane_to_u16_image`) or guards with `as_u16()?`
(`frame_weighting.rs:167`, which does check — `ImageData::as_u16` returns `None` for a
non-`U16` type, `lib.rs:357-359`). So this is a contract enforced by convention at ~20 call
sites rather than a live defect. It should be made structural: an early
`if image.pixel_type != PixelType::U16 { return Vec::new(); }` (or `Option`/`Result`) in
both functions, and the `detect_stars` doc comment should state the contract.

### 5.4 A 60-second blocking solve runs on an async worker — MEDIUM

`bridge/src/sequencer_ops.rs:1136` calls `skotiq_imaging::solve_near(…)` and `:1143`
`blind_solve(…)` directly inside `async fn plate_solve` (declared at
`bridge/src/sequencer_ops.rs:1009`). These block on `wait_timeout` for up to
`PlateSolverConfig::default().timeout_secs`, which is **60** (`platesolve.rs:204`). No
`spawn_blocking`.

The FRB API path gets this right and documents why —
`bridge/src/api/plate_solve.rs:155-160` wraps the identical call in
`tokio::task::spawn_blocking` with the comment "External solvers are blocking subprocesses.
Keep them off the async runtime worker."

Scoping note: the call site is in `bridge/`, outside this subsystem's paths, but the
blocking API is ours. The durable fix on our side is to stop exposing a bare blocking
`solve_near`/`blind_solve` as the only option — either rename them
`solve_near_blocking`/`blind_solve_blocking` so a caller in an `async fn` cannot use them by
accident, or add `async` wrappers that do the `spawn_blocking` internally.

### 5.5 `store_tile` leaves its temp file behind on a failed rename — LOW-MEDIUM

`sky_atlas.rs:1263-1271`: writes `path.with_extension("nst.tmp.<pid>.<nonce>")` then
renames. If `fs::write` fails partway or `fs::rename` fails (cross-device, permissions,
disk full), the error propagates and **the temp file is never removed**, and nothing else
in the module sweeps `*.nst.tmp.*`. On a disk-full night the atlas directory accumulates
partial 42 MB sidecars that make the disk-full condition worse. Add a scope guard that
`fs::remove_file(&tmp)` on any error path. `master_accumulation.rs` uses the same
write-temp-then-rename shape (around `:660-730`) and should be checked for the same gap.

### 5.6 Lock-poisoning `expect`s make solver config fail permanently — LOW

`platesolve.rs:186`, `:251`, `:290`, `:313`, `:395` (`ACTIVE_SOLVER_PREF.read()/.write()`)
and `:2373`, `:2386` (`SOLVER_AVAILABLE_CACHE.lock()`) all `.expect(...)`. If any thread
ever panics while holding one of these, every subsequent `PlateSolverConfig::default()` —
i.e. every plate solve for the rest of the process — panics.

Probability is genuinely low: the guarded regions are small and do nothing but clone
`Option<PathBuf>`s. But the blast radius is "no plate solving until restart", on an
unattended imaging rig. `unwrap_or_else(|e| e.into_inner())` is the appropriate treatment
for a cache/preference lock whose invariant cannot be broken by a partial write.

### 5.7 Solver pipe-reader threads are detached, never joined, on the timeout path — LOW

`platesolve.rs:704-705` (`AstapSolver::solve`) and `:2228-2229` (`run_solver_command`)
`drop()` both `JoinHandle`s on timeout rather than joining them. The in-file comment
(`platesolve.rs:700-703`) explains the choice — a solver-spawned descendant may hold a
copied pipe open and joining would hang the timeout — which is correct reasoning. The
residue is that each timed-out solve leaks two threads until the descendant closes the
pipe. Over a long unattended night with a repeatedly-hanging solver this accumulates.
Worth a bounded `join_timeout` helper or an explicit note that the leak is accepted; it is
currently neither measured nor bounded.

---

## 6. Top priorities

Ordered by (value × confidence) ÷ effort.

1. **Delete `platesolve.rs:1271-2032` (the `#[cfg(test)]`-only internal solver) and drop
   `wgpu`/`pollster` from `imaging/Cargo.toml:31-32`.** ~1150 lines gone including tests,
   two heavy dependencies gone from the shipped `.so`, zero behaviour change.
2. **Fix the Debug-stringified FITS header at `lib.rs:842`/`:857`.** Calibrated frames
   currently ship `EXPTIME = 'Float(120.0)'`. Small change, real data-quality defect.
3. **Rewrite `write_fits`'s pixel loop (`fits.rs:783-814`) to block writes.** Every capture
   pays for 61 M `write_all` calls today.
4. **Merge `combine_master_frames` onto `integrate_frames` (§2.2).** Removes a per-pixel
   heap allocation and an N×frame `f64` residency that OOMs on modern sensors, and
   collapses two rejection engines into the better one.
5. **Cache solver discovery and stop calling `PlateSolverConfig::default()` twice per solve
   (`platesolve.rs:2033-2060`).** Two-line first half; removes up to 6 subprocess spawns
   per solve on machines without ASTAP.
6. **Extract one `robust_stats` module and retire the 8 median / 5 percentile copies
   (§2.1).** The three divergent percentile conventions are the actual hazard.
7. **Split `fits.rs` and `platesolve.rs` per §1.1/§1.2** (do §1.2 *after* priority 1, when
   the file is already 1150 lines smaller).
8. **Unify the two FITS geometry parsers (§2.6/§5.2)**, which closes the `NAXIS > 3`
   divergence between `read_fits` and `MappedFitsReader` as a side effect.
