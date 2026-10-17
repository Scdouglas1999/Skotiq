# Cross-cutting duplication map

Subsystem: **cross-cutting** (functionality implemented more than once across
package / layer boundaries).
Date: 2026-08-11. Branch: `audit/end-to-end-campaign`.
Method: graphify orientation, then mechanical symbol-duplication scans over
4413 Dart files and 366 Rust files, then call-path tracing for each candidate to
establish which copy is LIVE. Every claim below carries a `file:line`.

Scope note: this is a *duplication* map, not a defect list. Where a duplicate
carries a behavioural divergence I say so and cite both sides; where the copies
are currently equivalent I say that too, because "equivalent today" is the whole
risk.

---

## The single most important structural fact

`native/skotiq_native/flutter_rust_bridge.yaml:4` sets `rust_input: crate::api`.
Only `bridge/src/api/**` is exposed to Dart — confirmed by enumerating the
generated wire functions:

```
grep -o 'fn wire__crate__[a-z_]*__' bridge/src/frb_generated.rs | sort -u
# → api, api__api_version, api__connection, api__devices__*, api__imaging,
#   api__sequencer, ... and NOTHING outside api__
```

But `bridge/src/lib.rs:100-116` still does `pub use imaging_ops::*;`,
`pub use real_device_ops::*;`, `pub use sequencer_api::*;`, `pub use
sequencer_ops::*;`. Those re-exports make every symbol in those modules crate-public,
which is precisely what silences `dead_code` — so ~7 000 lines of superseded
device/imaging plumbing compile, get maintained, get tested, and never run.
Clusters 1, 2 and 3 below are all consequences of this.

---

## Cluster 1 — Three `DeviceOps` implementations; one runs (P1)

`skotiq_sequencer::DeviceOps` (77 methods, `sequencer/src/device_ops.rs`) is
implemented three times inside the bridge crate:

| impl | file | lines | overrides | wired by |
|---|---|---|---|---|
| `UnifiedDeviceOps` | `bridge/src/unified_device_ops.rs:224` | 2272 | 71/77 | **LIVE** |
| `BridgeDeviceOps` | `bridge/src/sequencer_ops.rs:45` | 2191 | 75/77 | dead |
| `RealDeviceOps` | `bridge/src/real_device_ops.rs:189` | 3231 | 62/77 | dead |

Call-path trace:

* LIVE: `bridge/src/api/sequencer.rs:1468`, `:1557`, `:1622` →
  `create_unified_device_ops()` (`unified_device_ops.rs:1932`) →
  `executor.set_device_ops(...)`. `api/sequencer.rs` is FRB-exposed
  (`wire__crate__api__sequencer__*`), so this is the path a Dart-driven run takes.
  `create_unified_device_ops` is additionally imported by 20+ `api/*.rs` modules.
* DEAD: `create_device_ops()` (`sequencer_ops.rs:1621`) returns `BridgeDeviceOps`
  and is called from exactly three places — `sequencer_api.rs:25`, `:195`, `:316`.
  `sequencer_api.rs` is `crate::sequencer_api`, i.e. **outside `crate::api`**, so
  it is not FRB-exposed; and the only reference to it anywhere in the crate is
  `lib.rs:109 pub use sequencer_api::*;`. Nothing calls it.
  (`grep -rn "sequencer_api::" bridge/src` → 1 hit, the re-export.)
* DEAD: `RealDeviceOps` is referenced only by `imaging_ops.rs:53/77/87/650`
  (see cluster 2), which is itself unreachable. `RealDeviceOps::new` has zero
  live callers.

Two things make this a reliability finding rather than mere clutter:

**(a) The two executor accessors are the same singleton.**
`bridge/src/api/sequencer.rs:41-44` `get_sequence_executor()` returns
`skotiq_sequencer::get_executor()` — the `static EXECUTOR: OnceLock` at
`sequencer/src/executor/mod.rs:7985-7991`. `sequencer_api.rs` mutates that same
global via `exec.set_device_ops(...)`. If any future caller reaches
`sequencer_api::sequencer_load_plan` / `sequencer_set_simulation_mode` /
`sequencer_resume_from_checkpoint`, it silently swaps the executor's device ops
to the dead implementation for the rest of the process. "Which impl runs" is
last-writer-wins on a process-global.

**(b) The tested behaviour lives in the dead copy.** `save_fits` diverges:

* `sequencer_ops.rs:1171-1214` (**dead**) resolves the pointing at the
  *exposure midpoint* (`frame_ctx.exposure_midpoint()`), falls back to a live
  mount read (`read_mount_pointing`) when the `FrameContext` carries none, and
  builds the header through `build_rich_header` (`sequencer_ops.rs:246-322`).
  It is the only impl with regression tests — `mod pointing_tests` at
  `sequencer_ops.rs:1626-2191`, including
  `save_fits_writes_the_header_from_its_own_frame_context:2047` and
  `save_fits_derives_the_altitude_at_the_exposure_midpoint:2130`
  ("the altitude a frame records must be its own").
* `unified_device_ops.rs:1488-1521` (**live**) calls
  `FitsWriteHeaderRich::from_frame_context(frame_ctx)` and then *unconditionally
  overwrites* gain/offset/ccd_temp/exposure_time from `ImageData`. There is no
  midpoint epoch handling and no mount-read fallback here.

The precedence is literally inverted between the two:

```rust
// sequencer_ops.rs:267-278 (dead) — the FrameContext wins
if header.gain.is_none() { header.gain = image_data.gain; }
if frame_ctx.duration_secs <= 0.0 { header.exposure_time = image_data.exposure_secs; }

// unified_device_ops.rs:1502-1511 (live) — ImageData wins
if let Some(g) = image_data.gain { header.gain = Some(g); }
header.exposure_time = image_data.exposure_secs;
```

A previous fix did partially converge them — `api/imaging.rs:3398-3405` documents
that `from_frame_context` folds in the pointing/altitude preference "so the two
other `DeviceOps::save_fits` impls … agree with it" — which is a maintainer
explicitly working around the duplication instead of removing it.

Good news that should be recorded so the fix is not over-scoped: I diffed the
override sets mechanically and `UnifiedDeviceOps` is a strict superset of
`BridgeDeviceOps ∪ RealDeviceOps` on trait methods. There is **no** method where
the live impl currently falls back to the `DeviceOps` trait default while a dead
impl had a real body. (`unified_device_ops.rs:2236-2270` is a regression test
guarding exactly that hazard for `device_is_connected`/`connect_device`.)

**Survivor:** `UnifiedDeviceOps`.
**Merge:** delete `bridge/src/sequencer_api.rs` and the `DeviceOps` impl in
`bridge/src/sequencer_ops.rs` + all of `bridge/src/real_device_ops.rs`; keep and
relocate the three helpers the live path actually uses —
`connected_camera_label` (`sequencer_ops.rs:222`, called from
`unified_device_ops.rs:1054`), `build_rich_header` (`:246`),
`context_altitude_pointing` (`:193`) / `altitude_degrees` (`:159`) — into
`unified_device_ops.rs` (or better, `api/imaging.rs` next to
`FitsWriteHeaderRich`), and re-point the six `save_fits` regression tests at the
live impl. Drop the `pub use sequencer_api::*` / `pub use sequencer_ops::*` /
`pub use real_device_ops::*` lines from `lib.rs` so the compiler starts reporting
the next occurrence of this.
**Risk:** medium. The helpers are the load-bearing part; moving them is a pure
relocation, but the *tests* must move with them or the FITS-altitude behaviour
loses its only coverage. Deleting `real_device_ops.rs` also removes an
`AlpacaConnectionInfo` type (`:91`) — check no FRB type leaks through `lib.rs`
before deleting.

---

## Cluster 2 — `ImagingSession`: a whole capture engine no caller can reach (P2)

`bridge/src/imaging_ops.rs` (1128 lines) contains `ImagingSession` plus a
Flutter-facing-looking API surface (`imaging_start_single_exposure`,
`imaging_start_looping`, `imaging_stop_looping`, `imaging_abort_exposure`,
`imaging_is_running`, `set_image_directory`, `get_session_images`,
`get_image_thumbnail_by_path`, `get_image_data_by_path`).

Every one of those funnels through `get_imaging_session()`
(`imaging_ops.rs:656-663`), which reads `static IMAGING_SESSION`
(`imaging_ops.rs:647`) and errors with `"Imaging session not initialized"` unless
`init_imaging_session` (`imaging_ops.rs:650`) has run.

`init_imaging_session` has **zero callers** anywhere in the crate. And the module
is not FRB-exposed. Verified per-symbol:

```
set_image_directory: 0 external refs      imaging_start_single_exposure: 0
get_session_images: 0 external refs       imaging_stop_looping: 0
get_image_thumbnail_by_path: 0            imaging_is_running: 0
get_image_data_by_path: 0                 init_imaging_session: 0
```

The only live consumers of this file are four pure image helpers, called from
`api/imaging.rs:4176, 4198, 4215, 4240, 4437`: `get_image_stats`
(`imaging_ops.rs:735`), `auto_stretch_image` (`:741`),
`auto_stretch_color_image` (`:775`), `debayer_image` (`:802`).

The real capture path is `api/imaging.rs` (7406 lines) + `UnifiedDeviceOps`;
Dart's `getSessionImages` resolves through the Drift DB / network backend
(`skotiq_core/lib/src/backend/ffi_backend/session_heartbeat_operations.dart:9`,
`network_backend/imaging_profile_operations.dart:485`), never through Rust.

**Survivor:** `api/imaging.rs` for capture; keep the four stretch/debayer/stats
helpers.
**Merge:** move `get_image_stats` / `auto_stretch_image` /
`auto_stretch_color_image` / `debayer_image` (and their four unit tests at
`imaging_ops.rs:1059-1128`) into `bridge/src/api/imaging.rs` or a new
`bridge/src/image_transforms.rs`; delete the rest of the file and
`pub use imaging_ops::*` from `lib.rs:101`.
**Risk:** low — the deleted surface is provably unreachable, and the retained
helpers are pure functions with tests.

---

## Cluster 3 — Two device registries answering the same question (P1)

Two independent in-memory registries of "which devices are connected":

| registry | file | key | query API |
|---|---|---|---|
| `DeviceManager.devices` | `bridge/src/device_manager/mod.rs:408` | `device_id: String` | `is_connected:940`, `is_device_connected:949`, `first_connected_device_id:961`, `get_device:927`, `get_devices_by_type:917`, `get_connected_device_infos:973` |
| `AppState.devices` | `bridge/src/state.rs:25` | `(DeviceType, String)` | `is_device_connected:220`, `first_connected_device_id:235`, `get_device:204`, `get_devices:194`, `get_devices_by_type:613`, `get_all_device_states:581` |

`AppState` is written as a mirror from `device_manager/connection.rs:418`
(connect), `:1201`/`:1238` (disconnect), `:1277` (heartbeat loss). Both sides are
live consumers:

* DeviceManager registry: `api/connection.rs:312-321`
  (`api_is_device_connected`, `api_get_connected_devices` — the Dart-facing
  answers), `unified_device_ops.rs:239/1598/1604`, `builtin_guider.rs:1298`.
* AppState mirror: `hotplug.rs:242` (`get_all_device_states()` — hotplug arbitration),
  `api/phd2.rs:105/111/117` (guider resolution), `api/storage.rs:41-156`.

**Concrete confirmed divergence — the PHD2 guider.** `api/phd2.rs:296-311`:

```rust
// Register PHD2 as a connected guider device in AppState
// This ensures api_get_connected_devices() returns the guider
get_state().register_device(phd2_device_info, ConnectionState::Connected).await;
```

The comment is false. `api_get_connected_devices()` is
`bridge/src/api/connection.rs:319-321` and reads
`get_device_manager().get_connected_device_infos()` — the **DeviceManager**
registry. PHD2 registers only into `AppState` (grep for `get_device_manager` in
`api/phd2.rs` → 0 hits). So after a successful PHD2 connect:

* `api_get_connected_devices()` does not list the guider,
* `api_is_device_connected(Guider, "phd2_guider")` returns `false`
  (`api/connection.rs:312-316` → DeviceManager → id not present),
* but `get_active_guider_id_for_ops()` (`api/phd2.rs:101-118`, consumed by
  `unified_device_ops.rs:1271/1287/1303/1324/1335` for dither/status/calibration/
  start/stop) resolves it as `"phd2_guider"` and guides fine.

That is the cry-wolf shape: the app reports "no guider connected" on the surfaces
a user reads while the sequencer guides through it.

Secondary evidence of drift: `AppState::update_device_state` (`state.rs:171`) has
**no production callers** — only the two `state.rs` tests. `DeviceManager` moves
devices to `Connecting` (`connection.rs:295`) and `Disconnected` (`:870`) without
mirroring, so those transitions are invisible to `hotplug.rs`.
`AppState::first_connected_device_id` is now reachable only from the dead
cluster-1 code (`sequencer_ops.rs:60/109/1299/1305`, `real_device_ops.rs:260`)
and its own test; the live equivalents all use `get_device_manager()`.
`device_manager/mod.rs:985` still cites an `ALPACA_CLIENTS` static in
`api/connection.rs` that no longer exists — a stale pointer to the previous
generation of this same duplication.

**Survivor:** `DeviceManager.devices`.
**Merge:** make PHD2 (and the builtin guider) register through
`DeviceManager::register_device` so one registry knows every device; reduce
`AppState.devices` to a read-through view over `DeviceManager` (or delete it and
re-point `hotplug.rs:242`, `api/phd2.rs:105-118`, `api/storage.rs` at the
manager). Delete `AppState::update_device_state` / `first_connected_device_id`
once cluster 1 is gone. Fix the stale comment at `device_manager/mod.rs:985`.
**Risk:** medium — `hotplug.rs` arbitration and PHD2 connect/disconnect need
re-testing; the two registries key differently (`(type,id)` vs `id`), so the
`get_devices_by_type` semantics must be preserved when collapsing.

---

## Cluster 4 — Local sidereal time / Julian date implemented 14 times (P1)

Every copy carries the same literal `280.46061837 + 360.98564736629 * (jd - 2451545.0)`:

Rust (4):
* `native/skotiq_native/sequencer/src/scheduling/astronomy.rs:24,45,56` —
  `julian_date` / `greenwich_mean_sidereal_time` / `local_sidereal_time`,
  plus `equatorial_to_horizontal:64`, `object_alt_az:89`, `airmass:123`,
  `angular_separation:131`. **This is the canonical, tested one.**
* `native/skotiq_native/sequencer/src/meridian.rs:259,293` — `julian_day` /
  `local_sidereal_time`
* `native/skotiq_native/bridge/src/unified_device_ops.rs:1883,1909` (private, **live**)
* `native/skotiq_native/bridge/src/sequencer_ops.rs:1579,1605` (dead) and
  `real_device_ops.rs:2846` (dead)

Dart (10 files, 14 `julianDate`-family definitions):
* `packages/skotiq_core/lib/src/services/scheduler/sky_calculations.dart:46,101,185`
* `packages/skotiq_core/lib/src/services/scheduler_service.dart:107,140`
* `packages/skotiq_core/lib/src/services/night_analysis_service.dart:1019,1039`
* `packages/skotiq_core/lib/src/services/planning/forecast_planning_service.dart:401`
* `packages/skotiq_core/lib/src/services/coimaging/coimaging_session_service.dart:976,984`
* `packages/skotiq_core/lib/src/database/daos/targets_dao.dart:262,273`
* `packages/skotiq_planetarium/lib/src/coordinate_system.dart:68,89`
* `packages/skotiq_planetarium/lib/src/astronomy/astronomy_calculations.dart:72,143`
* `packages/skotiq_planetarium/lib/src/astronomy/planetary_positions.dart:23`,
  `sgp4.dart:492`, `catalogs/minor_planet_catalog.dart:312`,
  `catalogs/variable_star_catalog.dart:235`, `catalogs/mpcorb.dart:269`
* `server/skotiq_hub/lib/src/scheduler/follow_the_night.dart:247,259`
* `packages/skotiq_app/lib/screens/analytics/widgets/science_export_hub.dart:108`

The altitude formula `sin(dec)sin(lat) + cos(dec)cos(lat)cos(H)` is separately
re-typed in nine files (`targets_dao.dart`, `scheduler_service.dart`,
`night_analysis_service.dart`, `forecast_planning_service.dart`,
`scheduler/scheduler_engine.dart`, `scheduler/scheduler_engine/astronomy_helpers.dart`,
`coimaging_session_service.dart`, `astronomy_calculations.dart`, and the Rust copies).

These are not byte-identical, and the differences are real:

* **Two different JD algorithms.** Most use the Meeus Gregorian form
  (`365.25*(y+4716) + 30.6001*(m+1) + d + b - 1524.5`);
  `astronomy_calculations.dart:72-90` uses the Fliegel–Van Flandern form
  (`((153*m2+2)/5).floor() + 365*y2 + ...`);
  `science_export_hub.dart:108` uses the epoch form
  (`millisecondsSinceEpoch/86400000 + 2440587.5`).
* **Sub-second precision differs.** `sky_calculations.dart:46`,
  `targets_dao.dart:273`, `coimaging_session_service.dart:984`,
  `astronomy_calculations.dart:72` include `millisecond/86400000`;
  `scheduler_service.dart:140` and `night_analysis_service.dart:1039` stop at
  whole seconds.
* **One copy trusts its parameter name for UTC.**
  `server/skotiq_hub/lib/src/scheduler/follow_the_night.dart:259
  static double _julianDay(DateTime utc)` never calls `.toUtc()`. It is safe
  *today* only because both call sites normalise first (`:154`, `:211`). A third
  caller passing a local `DateTime` gets a JD wrong by the whole UTC offset — a
  whole-hours error in LST, i.e. a target scored as up when it is down.

**Survivor:** one shared Dart astronomy module (promote
`packages/skotiq_core/lib/src/services/scheduler/sky_calculations.dart` —
it is already `static`, already millisecond-accurate, and already the most
complete: JD, GMST, sun position, twilight) and, in Rust, the already-canonical
`sequencer/src/scheduling/astronomy.rs`.
**Merge:** (1) delete the nine Dart re-typings and import `SkyCalculations`
— note `skotiq_planetarium` does **not** depend on `skotiq_core` (it is a
leaf), so the planetarium copies need the shared module to live in the leaf
package or in a new tiny `skotiq_astro` package that both depend on.
(2) In Rust, replace the private `julian_day`/`local_sidereal_time` in
`unified_device_ops.rs:1883-1926` with
`skotiq_sequencer::scheduling::astronomy::{julian_date, local_sidereal_time}`
(the bridge already depends on `skotiq_sequencer`), and fold
`meridian.rs:259/293` into the same module.
(3) Give `follow_the_night.dart:259` a `.toUtc()` on the way in regardless.
**Risk:** medium. Changing JD precision changes numbers in scheduler golden
tests; do it as one commit per consumer with the goldens regenerated
deliberately, not in bulk.

---

## Cluster 5 — TAN/SIP world-coordinate projection implemented twice, both live (P1)

| copy | file | surface |
|---|---|---|
| Rust | `native/skotiq_native/imaging/src/wcs_sip.rs` (`SipWcs`, 700 lines) | `pixel_to_world:247`, `world_to_pixel:273`, `undistort:295`, `sip_poly:322`, `tan_project:368`, `tan_deproject:391`, `cd_det:199`, `is_invertible:207`, `pixel_scale_arcsec:239`; 10 unit tests at `:429-650` |
| Dart | `packages/skotiq_core/lib/src/services/wcs/gnomonic_projection.dart` (`GnomonicProjection`/`SolvedWcs`, 519 lines) | `worldToPixel:244`, `pixelToWorld:318`, `_sipPoly:485`, `_cdDet:236`, `_normaliseRaDeg:477`, `fieldOfViewDeg:472` |

Both are live and they serve *the same frames*:

* Rust: `bridge/src/api/sky_atlas.rs:32,95-98,241,828`,
  `bridge/src/api/difference_image.rs:24,83`,
  `imaging/src/mosaic_stitch.rs` — atlas tiling, difference imaging, mosaic stitch.
* Dart: `skotiq_core/lib/src/services/catalog_overlay_service.dart`,
  `providers/catalog_overlay_provider.dart`,
  `services/sky_atlas/sky_atlas_service.dart` + `sky_atlas_models.dart`,
  `services/transients/first_light_service.dart`,
  `services/science/science_processing_service/private_helpers.dart`,
  `services/science/default_science_backend/helpers.dart`,
  `services/imaging_records_repository.dart`,
  `skotiq_app/.../catalog_overlay_widget.dart`,
  `.../live_preview_area/preview_overlays.dart`, `.../frame_selection.dart`,
  `.../photometric_calibration_wizard/star_matching.dart`
  — annotation overlay, click-identify, framing, photometric star matching.

There is even a duplicated *serialisation* of the same SIP block:
`packages/skotiq_core/lib/src/services/wcs/wcs_sip_codec.dart` hand-encodes
`{aOrder,bOrder,a,b,apOrder,bpOrder,ap,bp}` for the `captured_images.solved_sip`
column, against `SipWcs::from_plate_solve` (`wcs_sip.rs:111`) on the Rust side.

Divergence risk is concrete: the Dart side is the one that draws the annotation
circle over a star; the Rust side is the one that decides where that star lands
in a stack or a difference image. Nothing forces them to agree, and only the
Rust side has round-trip tests (`cd_only_round_trip_sub_pixel:463`,
`forward_sip_round_trip_via_newton:516`, `inverse_sip_path_round_trips:626`).

**Survivor:** the Rust `SipWcs`.
**Merge:** expose `pixel_to_world` / `world_to_pixel` / `pixel_scale_arcsec` as
FRB entry points from `bridge/src/api/` and make `GnomonicProjection` a thin
Dart wrapper. If the per-pixel call rate makes FFI impractical for the overlay
painters (likely — these run per frame over hundreds of catalogue objects), the
minimum acceptable step is a **shared conformance test**: a fixture WCS + a table
of (pixel → world) pairs generated by the Rust tests, asserted by a Dart test, so
divergence becomes a red build rather than a mis-drawn overlay.
**Risk:** medium-high if merged (hot path); low if only the conformance test is
added — do that first regardless.

---

## Cluster 6 — Five hand-rolled FITS header parsers/writers in Dart (P2)

Rust already owns FITS: `native/skotiq_native/imaging/src/fits.rs` (3699
lines), reached from Dart via `api_save_fits_file_rich` /
`api/imaging.rs:3741 save_fits_file_rich` and `read_fits`. Dart nevertheless
re-implements 2880-byte-block card parsing five more times:

1. `packages/skotiq_core/lib/src/services/calibration/fits_header_reader.dart`
   (137 lines; `blockSize=2880`, `cardSize=80`, `maxBlocks=36`) — Calibration
   Library metadata enrichment.
2. `packages/skotiq_core/lib/src/services/dark_library_service.dart:368-460`
   (reader, incl. its own `BITPIX`/`BZERO` decode) **and** `:600-640` (writer,
   its own 2880 padding). Its own doc comment at `fits_header_reader.dart:11-12`
   admits the split: "The full pixel parser lives in `DarkLibraryService`; the
   header *writer* in `science/fits_header_writer.dart`."
3. `packages/skotiq_core/lib/src/services/science/fits_header_writer.dart`
   (371 lines; `blockSize=2880` at `:109`) — the science-keyword writer.
4. `packages/skotiq_core/lib/src/services/mosaic/collaborative_mosaic_service.dart:764-830`
   — **two** separate inline block scanners (`maxHeaderBytes = 2880*16` at `:775`
   and again at `:812`).
5. `server/skotiq_hub/lib/src/calibration/fits_master_validation.dart`
   (324 lines; `_blockSize=2880` at `:59`, `SIMPLE` check at `:103`/`:133`) —
   the hub's own master-frame validator. `server/skotiq_hub/pubspec.yaml`
   depends on no `skotiq_*` package, so this one is forced by the current
   dependency graph, not by preference.

Divergence already visible: only (1) and (5) enforce a `SIMPLE` first card;
only (1) caps at 36 blocks; (2) and (4) use different caps again; (2) is the only
one that rejects unsupported `BITPIX`.

**Survivor:** one `FitsHeaderReader` in `skotiq_core` (extend the existing
`services/calibration/fits_header_reader.dart` with the `BITPIX`/`BZERO` decode
from `dark_library_service.dart`), and one writer
(`services/science/fits_header_writer.dart`).
**Merge:** re-point `dark_library_service.dart`, `collaborative_mosaic_service.dart`
(both scanners) and the two writers at the shared pair. For the hub, either add a
`skotiq_core` path dependency or extract the reader into a new leaf package
both can depend on — do not leave a sixth copy.
**Risk:** low-medium. Dark-library reads touch multi-hundred-MB masters, so
preserve the "header-only, never touch pixels" I/O shape when consolidating.

---

## Cluster 7 — RA/Dec sexagesimal formatting: 39 private copies against 2 canonicals (P2)

A canonical exists and even documents the problem:
`packages/skotiq_core/lib/src/utils/coordinate_format.dart:4-7` —
*"Historically, ~20 screens each carried their own private `_formatRa` /
`_formatDec` helper … This class consolidates them."* The consolidation was not
finished.

Counts today (excluding tests and `build/`):

* **19** private `_formatRa|_formatRA[...]` definitions, **20** private
  `_formatDec|_formatDEC[...]` definitions, across **21** files.
* **11** files use the canonical `CoordinateFormat.*`.

Copies live in three packages plus the mobile app, i.e. this is genuinely
cross-boundary:
`skotiq_app/.../mount_control_card.dart:24`,
`.../imaging/centering_dialog.dart:994,1001`,
`.../overlay_painters/celestial_grid_painter.dart:357,372`,
`.../polar_alignment/..._measurement_panel.dart:249,257`,
`.../sequencer/tabs/templates_tab_parts/_save_template_dialog.dart:452,458`,
`.../sequencer/widgets/target_header_card.dart:71,78`,
`.../target_preview_tooltip.dart:113,120`,
`.../quick_start_wizard_dialog.dart:537,544`,
`.../suggestions/widgets/transient_alerts_panel.dart:625,632`,
`.../services/finder_chart_service.dart:649,657`,
`.../widgets/annotation_overlay/object_info_tooltip.dart:226,234`,
`.../widgets/first_light/first_light_flow_dialog.dart:746,755`,
`.../widgets/catalog_overlay_widget/details_panel.dart:155,164`,
`.../analytics/widgets/mpc_export_panel.dart:512,523`;
`skotiq_core/.../services/device_service/mount_controls.dart:54,61`,
`.../services/science/mpc_export_service.dart:291,331`,
`.../services/science/narrator/detectors/first_light_detectors.dart:216,226`;
`skotiq_planetarium/.../rendering/sky_renderer/coordinate_layers.dart:249,263`;
`apps/mobile/.../dashboard/tabs/mount_tab.dart:1110,1119`,
`.../dashboard/tabs/devices_tab.dart:600,606`.

**The unit hazard is the real finding, not the line count.** The copies do not
agree on what they are handed. Some take **decimal hours**
(`centering_dialog.dart:994 _formatRa(double raHours)`,
`target_header_card.dart:71`, `mount_controls.dart:54`,
`mount_tab.dart:1110`), others take **degrees**
(`celestial_grid_painter.dart:357 _formatRa(double raDeg)`,
`mpc_export_service.dart:291 _formatRa(double raDegrees)`,
`first_light_detectors.dart:216 _formatRa(double raDeg)`,
`first_light_flow_dialog.dart:746 _formatRa(double degrees)`,
`_measurement_panel.dart:249 _formatRA(double degrees)`). Identical names, 15×
different meaning, no type distinguishes them — which is exactly the RA-in-degrees-
stored-in-an-hours-field class this project has already been bitten by.

There are also **two competing canonicals in the same package**:
`CoordinateFormat.ra` (`coordinate_format.dart:50`) does **not** wrap into
[0,24) and does not guard NaN; `CoordinateParser.formatRaHms`
(`coordinate_parser.dart:178`) does both, and produces a different string
(`HH:MM:SS.ss` vs `HHh MMm SS.Ss`).

**Survivor:** `CoordinateFormat` (it is style-parameterised and its doc already
declares byte-for-byte output a contract). Fold
`CoordinateParser.formatRaHms/formatDecDms` into it as a third
`SexagesimalStyle`/`SecondsPrecision` combination, and move the wrap/NaN guards
up into `CoordinateFormat.ra`.
**Merge:** mechanical — replace each private helper with the matching style. Do
it one file at a time, asserting the previous string in a widget/golden test,
because the doc explicitly warns the exact glyphs are user-visible contract. While
touching each site, rename the degrees-taking ones to `_formatRaDegrees` or push
the conversion to the call site.
**Risk:** low per site, but 21 sites × user-visible strings; the payoff is
killing the hours-vs-degrees ambiguity.

Same shape, lower stakes: **30** private `String _formatDuration(...)` definitions
against the canonical `formatIntegrationSeconds` /
`formatIntegrationHours` in
`packages/skotiq_core/lib/src/utils/duration_format.dart:16,29`, whose own
doc records the bug that motivated it ("0 minutes" vs "12s" for the same run).

---

## Cluster 8 — `apps/mobile` ships a second, dead-by-default mobile UI (P2)

`apps/mobile/lib/screens/dashboard/` is a parallel 7-tab companion UI totalling
4845 lines: `camera_tab.dart` (1221), `mount_tab.dart` (1125),
`sequencer_tab.dart` (751), `devices_tab.dart` (609), `log_tab.dart` (565),
`settings_tab.dart` (305), `science_tab.dart` (269).

It is reachable only through `apps/mobile/lib/main.dart:492-509`:

```dart
final useCompanionUi = isPhone && isCompanionUiEnabled;
if (useCompanionUi) { ... home: const MobileDashboardScreen() ... }
```

and `isCompanionUiEnabled` (`apps/mobile/lib/companion_ui_config.dart:7-14`)
requires `--dart-define=SKOTIQ_COMPANION_UI=1` or the env var. A repo-wide
search finds that name in exactly five files, all of them the definition or a
doc comment — **no build script, CI workflow, gradle config or release recipe
sets it**. The default path is full `SkotiqApp` parity
(`packages/skotiq_app/lib/router/app_router.dart:39-46`).

So these tabs are compiled into every shipped APK, are never rendered, and
duplicate screens that `skotiq_app` already owns — the class-name collisions
`MountTab`, `SequencerTab`, `ScienceTab` between
`apps/mobile/lib/screens/dashboard/tabs/*` and
`packages/skotiq_app/lib/screens/*` are the giveaway. They also carry their
own copies of cluster-7's formatters (`mount_tab.dart:1110,1119`,
`devices_tab.dart:600,606`), so every coordinate-formatting fix has to be applied
to code no user sees.

**Survivor:** `packages/skotiq_app` (the shared shell).
**Merge:** this is a product decision, not a refactor — either delete the
companion tabs and the `SKOTIQ_COMPANION_UI` switch, or promote the switch to
something a build actually sets and give it a test. Shipping it in the third
state ("present, unreachable, still maintained") is the only option with no
upside.
**Risk:** low to delete (nothing references it), but confirm with the owner that
"ops-only field-ops workflow" is not a promised feature before removing.

---

## Cluster 9 — `skotiq_bridge` ⇄ `skotiq_core/models/backend` parallel type layer (P3, by design — verify, don't merge)

~35 type names exist in both `packages/skotiq_bridge/lib/src/**` (FRB-generated
or FRB-adjacent) and `packages/skotiq_core/lib/src/models/backend/**`
(hand-written): `DeviceInfo`, `DeviceType`, `DriverType`, `ConnectionState`,
`PierSide`, `CameraState`, `CameraStatus`, `MountStatus`, `FocuserStatus`,
`FilterWheelStatus`, `RotatorStatus`, `ShutterStatus`, `TrackingRate`,
`CameraCapabilities`, `MountCapabilities`, `FocuserCapabilities`,
`FilterWheelCapabilities`, `RotatorCapabilities`, `DomeCapabilities`,
`EventSeverity`, `EventCategory`, `SkotiqEvent`, `FitsWriteHeader`,
`ImageStats`, `ImageStatsResult`, `CapturedImageResult`, `FocusDataPoint`,
`SequencerStatus`, `SessionState`, `EquipmentProfile`, `ObserverLocation`,
`AppSettings`, `BuiltinGuiderConfig`, `Phd2Status`, `Phd2StarImage`,
`Phd2GuideStats`, `Phd2CalibrationData`, `Phd2AlgoParam`, `PlateSolverInfo`,
`PlateSolverDetection`.

This is **not** an accident: `SkotiqBackend`
(`skotiq_core/lib/src/backend/skotiq_backend.dart`) has three
implementations — `ffi_backend` (9 part files), `network_backend` (24 part
files), `disconnected_backend` — and the `models/backend/*` types are the
transport-neutral shape with `fromJson`/`toJson` that the network path needs.
`skotiq_core` *does* depend on `skotiq_bridge`, so the split is a choice,
and a defensible one.

I am recording it rather than recommending a merge, with one caveat worth
checking in the tightening pass: the enums are kept identical **by hand** on both
sides (`skotiq_bridge/lib/src/device.dart:309` vs
`skotiq_core/lib/src/models/backend/device_types.dart:5` — same 11
`DeviceType` members, same order). Adding a device type in Rust and regenerating
the bridge will not fail any build; it will silently produce a `DeviceType` the
network path cannot name.

**Recommendation:** add a single exhaustiveness test that maps every bridge enum
member to a core enum member by `.name` and fails on any unmapped member. Do not
merge the layers.

---

## Cross-package duplication suspects (flagged, not yet call-path-traced)

* `packages/skotiq_core/lib/src/services/constellation/constellation_models.dart`
  vs `server/skotiq_hub/lib/src/**` — `SubframeReceipt`, `SharedTarget`,
  `MosaicPanelClaim`, `CoImagingBatonState`, `CoImagingAccounting`,
  `ContributionOutcome`, `HandoffClaim` are declared on both sides. I inspected
  `HandoffClaim` (`constellation_models.dart:221` vs `handoff_service.dart:177`)
  and they are *not* the same type — the server's is a 3-field internal, the
  client's a 6-field wire decode. The suspect is the wire contract itself:
  `server/skotiq_hub` depends on no `skotiq_*` package, so every JSON key
  is typed twice with nothing binding them.
* `packages/skotiq_core/lib/src/backend/network_backend/wire_models.dart` +
  `wire_history_models.dart` (1908 lines) vs
  `apps/desktop/lib/headless_api/handlers/**` — the request/response shapes of
  ~589 endpoints are hand-encoded on the server side and hand-decoded on the
  client side, in different packages.
* `_median` in six files across `skotiq_core` and `server/skotiq_hub`
  (`focus_model_service.dart`, `science/default_science_backend/helpers.dart`,
  `science/science_processing_service/private_helpers.dart`,
  `smart_project_service.dart`, `hub/calibration/fits_master_validation.dart`,
  `hub/tiles/tile_quality.dart`); `_percentile` in five.
* `TwilightTimes` declared in both
  `skotiq_core/lib/src/services/scheduler/sky_calculations.dart:29` and
  `skotiq_planetarium/lib/src/astronomy/astronomy_calculations.dart:1667` —
  same concept, two packages, no shared dependency (see cluster 4's leaf-package
  problem).
* `TargetScore` in `skotiq_core/lib/src/models/scheduler/scheduler_decision.dart:46`
  vs `skotiq_planetarium/lib/src/planning/target_scoring.dart:77`;
  `SurveySource` in `skotiq_core/.../framing_provider/models.dart:370` vs
  `skotiq_planetarium/.../survey_image_service.dart:6`.
* `calculate_hfr` exists at `native/skotiq_native/imaging/src/stats.rs:800`
  (`calculate_hfr_at_point`), `indi/src/autofocus.rs:1100`,
  `sequencer/src/instructions.rs:5301` (`calculate_hfr_with_crops`) and
  `bridge/src/imaging_ops.rs:634` (dead). Worth a dedicated trace: autofocus
  correctness depends on all live copies agreeing.

---

## Dead code confirmed while tracing (all consequences of the clusters above)

| symbol | location | evidence |
|---|---|---|
| `sequencer_api` module (whole file, 506 lines) | `bridge/src/sequencer_api.rs` | outside `crate::api` so not FRB-exposed; sole reference is `lib.rs:109 pub use sequencer_api::*` |
| `BridgeDeviceOps` + `create_device_ops` | `bridge/src/sequencer_ops.rs:45,1621` | only callers are `sequencer_api.rs:25,195,316` |
| `RealDeviceOps` (`impl DeviceOps`, 3231-line file) | `bridge/src/real_device_ops.rs:189,506` | only referenced by `imaging_ops.rs:53,77,87,650`, itself unreachable |
| `ImagingSession` + `init_imaging_session` + the `imaging_*` / file-scan API | `bridge/src/imaging_ops.rs:76-733` and `:826-1057` (live remainder is only `:735-825`) | `init_imaging_session` (`:650`) has 0 callers, so `get_imaging_session()` (`:656`) always errors; module not FRB-exposed |
| `AppState::update_device_state` | `bridge/src/state.rs:171` | 0 production callers (tests only) |
| `AppState::first_connected_device_id` | `bridge/src/state.rs:235` | live callers all use `get_device_manager()`; remaining callers are the dead cluster-1 files |
| stale comment citing `ALPACA_CLIENTS` | `bridge/src/device_manager/mod.rs:985` | the named static does not exist anywhere in the crate |
| `apps/mobile` companion dashboard (4845 lines) | `apps/mobile/lib/screens/dashboard/**` | gated on `SKOTIQ_COMPANION_UI`, which nothing in the repo sets |

---

## Suggested order of work

1. **Cluster 3 (PHD2 registry)** — smallest change, fixes a user-visible false
   statement, and shrinks the surface cluster 1 has to reason about.
2. **Cluster 1 + 2** — delete `sequencer_api.rs`, `real_device_ops.rs`,
   `BridgeDeviceOps` and the unreachable half of `imaging_ops.rs` after moving the
   four helpers and the six FITS-header tests. ~7 000 lines out; every later
   duplication scan gets quieter.
3. **Cluster 5 conformance test** — cheap, and it converts a silent divergence
   into a build failure before anyone touches either WCS implementation.
4. **Cluster 4** — needs the leaf-package decision for `skotiq_planetarium`
   first; then one consumer per commit with goldens regenerated deliberately.
5. **Clusters 6, 7** — mechanical, high volume, low risk each.
6. **Cluster 8** — product decision, then a delete.
7. **Cluster 9** — add the enum exhaustiveness test; leave the layers alone.
