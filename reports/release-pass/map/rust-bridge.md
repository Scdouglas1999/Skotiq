# Release-pass map — Rust bridge crate (`native/skotiq_native/bridge/src/`)

Scope: everything under `native/skotiq_native/bridge/src/` **except** `frb_generated.rs`
(36,318 lines, generated). Read-only mapping pass; no source was edited.

## Ground rules established before anything else (these underpin every dead-code claim)

1. **The crate has no Rust dependents.** `bridge/Cargo.toml` declares
   `crate-type = ["cdylib", "staticlib"]` only — no `rlib`/`lib`. A repo-wide search for
   `skotiq_bridge` in every `Cargo.toml` under `native/skotiq_native/` returns
   only the crate's own manifest. Nothing links this crate as a Rust library.
2. **There are no hand-written C exports.** `grep -rn "no_mangle\|extern \"C\"" bridge/src/`
   excluding `frb_generated.rs` returns **zero** hits.
3. **Only `crate::api` is FRB-scanned.** `native/skotiq_native/flutter_rust_bridge.yaml`
   says `rust_input: crate::api`. Confirmed empirically: `lib.rs` carries
   `#[flutter_rust_bridge::frb(sync)]` on `init_native` (lib.rs:399-401) and
   `get_native_version` (lib.rs:533-536), and **neither name appears anywhere in
   `frb_generated.rs`** (`grep -c` → 0), while the `api::init` equivalents
   (`api_get_log_directory`, `api_init`, …) do appear.

**Therefore:** the *only* externally reachable surface of this crate is the FRB wire
functions generated from `crate::api::*`. Any symbol outside `api/` with (a) no occurrence
in `frb_generated.rs` and (b) no occurrence in any other non-generated `.rs` file in the
crate is unreachable at runtime. Every dead-code item below was verified against both.

---

# 1. OVERSIZED FILES

Counts verified with `wc -l`. "code" excludes `#[cfg(test)]` module bodies (measured by
brace-matching, so ±a few lines).

| lines | test | code | file |
|---|---|---|---|
| 7406 | ~1890 | ~5516 | `api/imaging.rs` |
| 4296 | ~1026 | ~3270 | `device_capabilities.rs` |
| 3784 | ~1170 | ~2614 | `builtin_guider.rs` |
| 3729 | ~377 | ~3352 | `api/sequencer.rs` |
| 3391 | ~2337 | ~1054 | `device_manager/mod.rs` |
| 3231 | 0 | 3231 | `real_device_ops.rs` **(dead — delete, do not split)** |
| 3023 | ~546 | ~2477 | `device_manager/ops/camera.rs` |
| 2996 | ~916 | ~2080 | `api/post_session.rs` |
| 2713 | ~246 | ~2467 | `device_manager/ops/mount.rs` |
| 2551 | ~252 | ~2299 | `api/devices/simulation.rs` |
| 2272 | ~330 | ~1942 | `unified_device_ops.rs` |
| 2191 | ~567 | ~1624 | `sequencer_ops.rs` **(dead — delete, do not split)** |
| 1850 | ~478 | ~1372 | `api/sky_atlas.rs` |
| 1629 | ~225 | ~1404 | `ascom_wrapper/camera.rs` (Windows-only) |
| 1619 | ~559 | ~1060 | `device_id.rs` |
| 1619 | ~107 | ~1512 | `api/polar_alignment.rs` |
| 1568 | ~929 | ~639 | `sim_frame.rs` (mostly tests; leave alone) |
| 1514 | ~52 | ~1462 | `event.rs` |

None of these are generated. `frb_generated.rs` is the only generated file and is excluded.

Precedent that makes every split below safe: `api/devices/` is already a directory module
(`api/devices/mod.rs` = 21 lines of `pub(crate) mod X; pub use X::*;`) whose contents FRB
picks up correctly. Splitting an `api/*.rs` into `api/*/mod.rs + siblings` with a glob
re-export therefore does not change the generated wire surface. **Every split plan below
must be verified by regenerating FRB and diffing `frb_generated.rs` — the diff must be
empty.**

---

### 1.1 `api/imaging.rs` — 7406 lines → target ≤ 900 per file

**Why it is big:** it is the union of eight unrelated concerns that happen to touch pixels:
autofocus orchestration, the camera exposure entry point, FITS read, FITS write, star/stat
analysis, image file export (XISF/TIFF/PNG/JPEG), live stacking facade, and defect maps —
plus ~1890 lines of tests, of which one module (`rich_header_tests`, 5584-6407) is 824
lines on its own.

**Split plan** — convert to `api/imaging/` (directory module). `api/imaging/mod.rs` holds
only the section banner comments and `pub(crate) mod …; pub use …::*;`.

| new file | moves (line ranges in today's file) |
|---|---|
| `api/imaging/autofocus.rs` | `AutofocusConfigApi`, `FocusDataPoint`, `AutofocusResultApi` (87-129), `api_run_autofocus` (130-457), `api_cancel_autofocus` (458-464), plus the INDI autofocus block 4543-4728 (`IndiAutofocusConfigApi`, `IndiAutofocusResultApi`, `FocusDataPointApi`, `api_run_indi_autofocus`) |
| `api/imaging/capture.rs` | `CapturedImageResult`, `ImageStatsResult`, `RawImageInfo`, `CapturedImageData`, `display_data_to_rgba`, `UNIFIED_IMAGE_STORAGE*`, `store_captured_image_atomically` (471-615), `api_camera_start_exposure`, `api_camera_start_exposure_configured`, `camera_start_exposure_opt`, `camera_start_exposure_configured_opt` (616-1312), `api_get_last_image`, `api_get_last_raw_image_data`, `get_last_raw_image_info`, `api_clear_device_image`, `api_camera_cancel_exposure` (1313-1390). Tests: `unified_image_storage_tests` (5461-5579), `exposure_failure_classification_tests` (6660-6782), `sim_exposure_tests` (6987-7406) |
| `api/imaging/fits_read.rs` | `FitsReadResult`, `FitsLinearReadResult`, `Quality*Api` (1397-1516), `api_read_fits_file` (1584-1662), `api_read_fits_linear_data` (1790-2193), `api_compute_last_capture_quality_maps`, `api_compute_fits_quality_maps` (2194-2269). Tests: `linear_decode_tests` (1517-1583), `quality_map_tests` (2270-2308) |
| `api/imaging/fits_keywords.rs` | `FitsKeywordUpdate`, `api_update_fits_keywords` (1674-1789). Tests: `fits_keyword_update_tests` (6783-6986) |
| `api/imaging/analysis.rs` | `DetectedStarInfo`, `StarDetectionResultApi`, `StarDetectionConfigApi` + `Default` (2315-2379), `api_detect_stars_in_file` (2380-2444), `StarCropApi` + `api_get_star_crops_from_last_image` (2445-2517), `api_calculate_hfr` (2518-2528), `api_calculate_histogram` (2529-2546), `StretchParamsApi`, `api_calculate_auto_stretch`, `api_apply_stretch` (2547-2593), `api_debayer_fits_file` (2617-2652), and the sync helpers 4165-4542 (`api_get_image_stats`, `api_auto_stretch_image`, `api_auto_stretch_color_image`, `api_debayer_image`, `api_generate_fits_thumbnail`). Also move `pub(crate) fn median` (1861) here |
| `api/imaging/export.rs` | `XisfReadResult`, `api_read_xisf_file`, `api_save_xisf_file`, `api_save_tiff_file`, `api_save_png_file`, `api_save_jpeg_file`, `api_save_rgba_png_file`, `api_save_rgba_jpeg_file` (2659-2976). Tests: `rgba_save_tests` (2977-3080) |
| `api/imaging/filenames.rs` | `api_generate_filename`, `api_get_next_frame_number` (3097-3195) |
| `api/imaging/fits_write.rs` | `FitsWriteHeader`, `FitsWriteHeaderRich`, `From<FitsWriteHeader>`, `impl FitsWriteHeaderRich` incl. `from_frame_context`, the three `frb(ignore)` helpers at 3504/3541/3581, `api_save_fits_file`, `save_fits_file_rich`, `api_save_fits_from_last_capture` (3213-4164). Tests: `rich_header_tests` (5584-6407) — this is the single largest test module and belongs next to the writer it exercises |
| `api/imaging/calibration.rs` | `api_calibrate_image_file`, `api_calibrate_image_data` (4744-4912) |
| `api/imaging/live_stacking.rs` | `ApiLiveStackingConfig`/`Stats`/`Result` + all `api_stacking_*` (4918-5115) |
| `api/imaging/defect_map.rs` | `ApiDefectMapStatus`, `api_defect_map_build/apply/clear`, `api_sequencer_apply_defect_map`, `api_defect_map_get_status` (5121-5460) |
| `api/imaging/master_frames.rs` | `ApiCombineMethod`, `ApiMasterFrameResult`, `api_combine_master_frames` (6426-6655) |

Stays in `api/imaging/mod.rs`: nothing but module declarations and `pub use`. Note
`UNIFIED_IMAGE_STORAGE`, `get_unified_image_storage`, `store_captured_image_atomically`,
`median`, `display_data_to_rgba` and `IMAGE_VALIDATION_FAILED_PREFIX` are `pub(crate)` and
consumed across the crate — the glob re-export in `mod.rs` preserves every existing path.

---

### 1.2 `device_capabilities.rs` — 4296 lines → 6 files

**Why it is big:** one file holds (a) 11 capability DTO structs, (b) the cache, and (c)
**five complete per-transport probe implementations** that share nothing but their return
type: `get_alpaca_capabilities` (982-1518, 537 lines), `get_ascom_capabilities`
(1519-2111, 593 lines, `#[cfg(windows)]`, with a non-Windows stub at 2112-2118),
`get_indi_capabilities` (2142-2634, 493 lines), `get_native_capabilities` (2635-3064,
430 lines), `get_simulator_capabilities` (3065-3269, 205 lines).

**Split plan** — `device_capabilities/` directory module:

- `device_capabilities/types.rs` ← lines 61-576: `MountCapabilities`, `CameraCapabilities`,
  `CameraRecommendedSettings` + its `From` impl, `FocuserCapabilities`,
  `AscomFocuserReadings`, `focuser_capabilities_from_ascom`, `FilterWheelCapabilities`,
  `RotatorCapabilities`, `DomeCapabilities`, `ShutterStatus` + `Default`,
  `CoverCalibratorCapabilities`, `WeatherCapabilities`, `SafetyMonitorCapabilities`,
  `SwitchCapabilities`, `SwitchInfo`. Plus `DeviceCapabilities` (956-981) — the enum has to
  live with the structs it wraps. Test module `ascom_focuser_capability_tests` (3270-3353)
  moves here.
- `device_capabilities/cache.rs` ← 577-595 + 891-955: `CAPABILITY_CACHE_TTL`,
  `CapabilityCacheEntry`, `CAPABILITY_CACHE`, `capability_cache`,
  `invalidate_capability_cache`, and the caching wrapper of `get_device_capabilities`.
- `device_capabilities/ascom.rs` ← 596-781 (`capability_probe_should_own_connection`,
  `normalize_ascom_capability_device_type`, `ascom_registry_type_for_capabilities`,
  `ascom_capability_device_types`, `classify_ascom_capability_device_type`) + 1519-2118
  (both `#[cfg]` arms of `get_ascom_capabilities`).
- `device_capabilities/alpaca.rs` ← 982-1518.
- `device_capabilities/indi.rs` ← 2119-2634 (`indi_sensor_type_is_color`,
  `indi_readout_mode_label`, `get_indi_capabilities`).
- `device_capabilities/native.rs` ← 721-781 (`native_cover_state_to_capability`,
  `native_calibrator_state_to_capability`) + 2635-3064.
- `device_capabilities/simulator.rs` ← 3065-3269.
- `device_capabilities/mod.rs` keeps `refresh_volatile_state` (782-889 — it dispatches
  across transports, so it is the router), the routing body of `get_device_capabilities`
  (903-955), the module declarations and `pub use *`. Test module `tests` (3354-4296)
  splits by which probe each test exercises; anything cross-cutting stays in `mod.rs`.

`lib.rs:58` `mod device_capabilities;` and `lib.rs:96` `pub use device_capabilities::*;`
are unchanged.

---

### 1.3 `builtin_guider.rs` — 3784 lines (2614 code) → 6 files

**Why it is big:** it is a complete autoguider — public control API, calibration, the
guide loop, the star-tracking/centroiding maths, and the correction/settle controller — in
one module, plus a 1149-line test module (2614-3762).

**Split plan** — `builtin_guider/` directory module:

- `builtin_guider/config.rs` ← 50-160: all `GUIDE_*` / `MAD_TO_SIGMA` consts,
  `GuiderConfig` + `Default`, `Vec2` + `impl`, `guiding_failure_reason` (58-65). Test module
  `guiding_failure_reason_tests` (3763-3784) moves here.
- `builtin_guider/state.rs` ← 162-543: `guide_pixel_scale_arcsec`,
  `binned_guide_pixel_scale`, `guide_offset_arcsec`, `GuideCalibration` + impl,
  `BuiltinGuideStatus` + `Default`, `BuiltinGuideTrackedStar(s)`, `build_tracked_stars`,
  `get_tracked_stars_json`, `BuiltinGuiderState` + `Default`, `RMS_HISTORY_LEN`,
  `BUILTIN_GUIDER`, `state()`, `GUIDER_OP_LOCK`, `op_lock()`.
- `builtin_guider/control.rs` ← 544-832 + 1040-1244: `set_config`, `get_config`, `connect`,
  `disconnect`, `start_guiding`, `loop_exposures`, `begin_loop`, `start_synthetic_loop`,
  `stop`, `stop_locked`, `find_star`, `deselect_star`, `set_lock_position`,
  `get_lock_position`, `get_star_image`, `get_status`, `get_calibration_data`, `device_id`,
  `is_connected`.
- `builtin_guider/dither.rs` ← 833-1039: `DITHER_*` consts, `dither_offset`,
  `abandon_dither`, `dither_target_within_jump`, `dither`.
- `builtin_guider/calibration.rs` ← 1608-1907: `calibrate_mount_response`,
  `build_calibration`, `calibrate_dec_response`, `estimate_dec_backlash_ms`,
  `calibrate_axis_response`, `matched_displacements`.
- `builtin_guider/loop_runner.rs` ← 1245-1607: `ensure_connected`, `resolve_devices`,
  `first_connected_device`, `resolve_unbinned_guide_pixel_scale`, `capture_guide_frame`,
  `ensure_frame_available`, `capture_and_store_loop_frame`, `run_guiding_loop`.
- `builtin_guider/metrics.rs` ← 1908-2613: `median`, `measure_offset`,
  `robust_weighted_offset`, `push_rms_sample`, `axis_rms`, `push_arcsec_sample`,
  `recent_rms`, `record_per_star_residuals`, `guide_reference_weight`,
  `compute_pulse_durations`, `project_offset`, `resolve_axis_pulse`,
  `apply_guide_correction`, `pulse_axis`, `apply_settle_state`, `is_usable_reference`,
  `select_reference_stars`, `choose_lock_star`, `nearest_star`,
  `update_snapshot_from_frame`, `crop_raw_u16_image`.

The 1149-line `tests` module (2614-3762) splits along the same seams; each new file gets its
own `#[cfg(test)] mod tests`. Everything in this file is `pub`/private within the crate and
reached via `crate::builtin_guider::…`, so `mod.rs` with `pub use *` is a no-op for callers.

---

### 1.4 `api/sequencer.rs` — 3729 lines (3352 code) → 5 files

**Why it is big:** lifecycle control + a 535-line event-bridge task + ~30 typed-event
translation helpers + ~35 runtime-config setters + ~20 node factory functions + mosaic maths.

**Split plan** — `api/sequencer/` directory module:

- `api/sequencer/mod.rs` — `get_sequence_executor` (41-44), `SequencerState` (46-60), module
  decls, `pub use *`.
- `api/sequencer/lifecycle.rs` ← 187-466 + 1434-1604: `api_sequencer_load_json`,
  `api_sequencer_load`, `api_sequencer_start`, `_pause`, `_resume`, `_stop`, `_skip`,
  `_skip_to_node`, `_reset`, `_plugin_node_finished`, `api_sequencer_get_state`, plus the
  checkpoint set (`_set_checkpoint_dir`, `_has_checkpoint`, `_get_checkpoint_info`,
  `_resume_from_checkpoint`, `_save_checkpoint`, `_clear_checkpoint`) and
  `api_perform_meridian_flip` (1491-1585).
- `api/sequencer/event_bridge.rs` ← 467-1001 + 1384-1433: `api_sequencer_subscribe_events`
  (the supervised task), `run_decision_event_loop` (556-…), `run_sequencer_event_loop`
  (600-…), `api_sequencer_event_stream`.
- `api/sequencer/event_translation.rs` ← 1002-1383:
  `typed_sequencer_event_from_progress_detail`,
  `structured_progress_payload_from_progress_detail`, `recovery_cause_fields`,
  `recovery_phase_str`, `recovery_event_started/progress/completed/gave_up`.
- `api/sequencer/runtime_config.rs` ← 1605-2386 + 3413-3541: every
  `api_sequencer_set_*` / `api_sequencer_update_*` / `api_sequencer_get_*_json`, the
  recovery controls (`_recovery_try_now`, `_recovery_abort`, `_update_recovery_config`,
  `_get_current_recovery_json`, `_get_recovery_history_json`), plus
  `_set_active_sequence_run_id`, `_get_active_sequence_run_id`,
  `_set_decision_logging_enabled`, `_get_decision_logging_enabled`,
  `_update_conditions_score`, `_get_adaptive_swap_json`.
- `api/sequencer/node_factory.rs` ← 2387-3218: all 20 `api_create_*_node` functions and
  `api_build_sequence`.
- `api/sequencer/mosaic_and_geometry.rs` ← 3219-3412: `api_calculate_mosaic_panels`,
  `api_calculate_mosaic_area`, `api_estimate_mosaic_time`, `api_calculate_altitude`,
  `LiveStackingBroadcastSnapshot`, `api_broadcast_get_active`, `api_broadcast_deactivate`.

---

### 1.5 `device_manager/mod.rs` — 3391 lines, but **2337 of them are one test module**

This one is cheap and should be done first because it is nearly risk-free.
`#[cfg(test)] mod tests {` starts at line 1055 and runs to EOF. Code is only ~1054 lines.

**Split plan:** replace lines 1051-3391 with `#[cfg(test)] mod tests;` and move the body to
`device_manager/tests.rs` (an out-of-line test module can still `use super::*` and reach
private items, so this is a pure move — no visibility changes). If `device_manager/tests.rs`
is still too big, split it into `device_manager/tests/mod.rs` + topic files
(`reconnect.rs`, `heartbeat_config.rs`, `registry.rs`, `alpaca_client.rs`) each `use
crate::device_manager::*`.

The remaining ~1050 lines of real code (`HeartbeatConfig` + its 11 `for_*` presets 57-361,
`ReconnectConfig`, `ManagedDevice`, `DeviceManager` struct + `OperationGuard`/
`UsbContentionGuard` `Drop` impls 406-750, constructors and accessors 751-1050) can then
optionally split as `device_manager/heartbeat_config.rs` (57-361) + `device_manager/mod.rs`
(the rest), but that is optional; getting under 1100 lines is enough.

---

### 1.6 `device_manager/ops/camera.rs` (3023) and `device_manager/ops/mount.rs` (2713)

**Why they are big:** each public op is a 5-arm `match driver_type { Ascom | Alpaca |
Native | Indi | Simulator }` and each arm is 20-100 lines. `camera.rs` has 11 such matches,
`mount.rs` has 14. See §2.4 — the durable fix is to collapse the repeated match, and the
file split below is the interim structural move that does not require that refactor.

**`device_manager/ops/camera.rs` split plan** — `device_manager/ops/camera/`:
- `exposure.rs` ← `parse_fits_card_u32` (97-107), `camera_start_exposure` (119-142),
  `camera_start_exposure_configured` (143-550), `camera_is_exposure_complete` (551-655),
  `camera_abort_exposure` (1179-1263).
- `download.rs` ← `camera_download_image` (656-1178), `camera_capture_preview` (2389-2429).
- `status.rs` ← `camera_get_status` (1264-1713), `camera_get_recommended_settings`
  (2430-2473).
- `settings.rs` ← `camera_set_gain` (1714-1830), `camera_set_offset` (1831-1931),
  `camera_set_binning` (1932-2055), `camera_set_readout_mode` (2056-2228),
  `camera_set_cooler` (2229-2388).
- `mod.rs` ← module decls only. The three test modules at 2474, 2538, 2719 move next to the
  code they cover.

**`device_manager/ops/mount.rs` split plan** — `device_manager/ops/mount/`:
- `slew.rs` ← `mount_slew` (37-244), `mount_slew_alt_az` (569-709), `mount_abort`
  (880-957), `mount_stop` (958-1032), `mount_move_axis` (2286-2467).
- `park.rs` ← `mount_park` (366-465), `mount_unpark` (466-568), `mount_find_home`
  (710-802), `mount_can_park` (1312-1398).
- `tracking.rs` ← `mount_set_tracking` (1033-1167), `mount_set_tracking_rate` (2132-2220),
  `mount_get_tracking_rate` (2221-2285), `mount_pulse_guide` (1168-1311).
- `status.rs` ← `mount_sync` (245-365), `mount_get_coordinates` (803-879),
  `mount_get_status` (1399-2131 — 732 lines; this one alone justifies the split).
- `mod.rs` ← module decls; tests (2468-2713) move to `status.rs`/`slew.rs` by subject.

---

### 1.7 `api/devices/simulation.rs` — 2551 lines → one file per simulated device

**Why it is big:** it is ten independent device simulators plus their API entry points in
one file. The seams are already marked with banner comments.

**Split plan** — `api/devices/simulation/`:
- `camera.rs` ← 47-555 (`SimulatedCamera`, `SimExposureRequest`, `SIM_LAST_EXPOSURE`,
  `SIM_FRAME_SEED`, `SIM_EXPOSURE_PHASE`, `sim_exposure_elapsed_is_complete`,
  `SIM_COOLER_LAST_TICK`, `api_get_camera_status`, `api_set_camera_cooler`,
  `api_set_camera_gain`, `api_set_camera_offset`).
- `guiding.rs` ← 371-512 (`SIM_GUIDE_OFFSET`, `SIM_DRIFT_LAST_TICK`, `sim_pulse_delta`,
  `apply_offset_delta`, `drift_step_secs`).
- `mount.rs` ← 556-950 (`SimulatedMount`, `SimSlew`, `angular_separation_deg`,
  `sim_slew_duration_secs`, `interpolate_ra`, `pier_side_after_slew_to`,
  `sim_local_sidereal_time`, all `api_mount_*`).
- `focuser.rs` ← 951-1054. `filter_wheel.rs` ← 1055-1338 (incl.
  `FILTER_WHEEL_STATUS_POLL_STATES` and `poll_filter_wheel_position`).
  `rotator.rs` ← 1339-1463. `environment.rs` ← 1464-1555 (`SimulatedDome`,
  `SimulatedWeather`, `SimulatedSafetyMonitor`).
- `errors.rs` ← 1556-1650 (`SimDeviceError`, `From<SimDeviceError> for DeviceOpError`).
- `mod.rs` ← module decls + `pub use *`. The test-only singleton lock
  (`SIM_SINGLETON_TEST_LOCK`, 159-192) stays in `mod.rs` so every sub-simulator's tests can
  serialize on the same lock.

---

### 1.8 `device_id.rs` — 1619 lines (~1060 code)

**Why it is big:** `ParsedDeviceId::parse` alone is lines 394-798 (404 lines) — a single
function matching every device-id scheme.

**Split plan** — `device_id/`:
- `cache.rs` ← 34-295: `DEVICE_ID_CACHE`, `CacheMetrics`, `DeviceIdCache`, `get_cache`,
  `parse_device_id_cached`, `get_device_id_cache_stats`, `invalidate_device_id_cache`,
  `clear_device_id_cache`, `reset_device_id_cache_metrics`, `DeviceIdCacheStats` + `Display`.
- `parse.rs` ← 296-378 (`ParsedDeviceId`, `ConnectionInfo`) + 379-798 (`impl
  ParsedDeviceId::parse`) + 959-1000 (`parse_base_url`). Inside `parse.rs`, break `parse`
  into `parse_ascom`, `parse_alpaca`, `parse_indi`, `parse_native`, `parse_touptek` — the
  outer `parse` becomes a scheme-prefix `match` that delegates. This is the behaviour-
  preserving decomposition, not a rewrite: each arm's body moves verbatim.
- `accessors.rs` ← 799-958 (`raw`, `ascom_prog_id`, `alpaca_info`, `alpaca_base_url`,
  `indi_info`, `native_info`, `native_vendor`, `touptek_info`, `zwo_subtype`, `qhy_subtype`,
  `fli_subtype`, `is_network_device`, `network_address`) + 1001-1055 (`Display`).
- Tests (1060-1619) split into `parse.rs` / `cache.rs` test modules.

---

### 1.9 `event.rs` — 1514 lines (~1462 code)

**Why it is big:** every event enum in the system plus the event bus plus the correlation
helpers. `SequencerEvent` alone is lines 423-955 (532 lines of variants).

**Split plan** — `event/`:
- `event/kinds/equipment.rs` ← 65-244 (`EventSeverity`, `EventCategory`,
  `HeartbeatStatus`, `EquipmentEvent`).
- `event/kinds/imaging.rs` ← 245-374 (`PolarAlignmentEvent`, `PolarAlignmentStatus`,
  `PolarAlignmentImageEvent`, `ImagingEvent`).
- `event/kinds/guiding.rs` ← 375-422 (`GuidingEvent`).
- `event/kinds/sequencer.rs` ← 423-1032 (`SequencerEvent`, `SchedulerScoreEntry`,
  `FrameCaptureMetadata` + its `From`).
- `event/kinds/system.rs` ← 1033-1077 (`SafetyEvent`, `SystemEvent`).
- `event/bus.rs` ← 1078-1378 (`SkotiqEvent`, `EventPayload`, `EventBusStats`,
  `EventBus` + impl + `Default`, and the existing test module at 1324).
- `event/correlation.rs` ← 1379-1514 (`GLOBAL_EVENT_SEQUENCE`, `create_event`,
  `create_event_auto_id`, `create_event_with_cause`, `EventContext`,
  `generate_correlation_id`).
- `event/mod.rs` ← `pub mod kinds; pub use kinds::*; …`. `lib.rs:100 pub use event::*;`
  keeps every existing import path working.

---

### 1.10 `api/post_session.rs` (2996 / ~2080 code)

Sections are already banner-delimited. Split to `api/post_session/`:
`args.rs` (59-403: `AlignArgs`, `WeightingArgs`, `NormalizationArgs`, `IntegrationArgs` and
their `Default`s), `entrypoints.rs` (404-478: the four `api_*` fns), `integrate.rs`
(479-913), `masters.rs` (914-1351 incl. `MasterSettingsArgs`), `normalize.rs` (1352-1468),
`weighting.rs` (1469-1573), `reference.rs` (1574-2075 — `reference_choice_tests`
(2779-2996) moves here), `mod.rs` (decls). General `tests` (2080-2778) splits by subject.

### 1.11 Remaining files 1000-1900 lines

`api/sky_atlas.rs`, `api/polar_alignment.rs`, `ascom_wrapper/camera.rs`,
`device_manager/connection.rs`, `device_manager/ops/dome.rs`, `device_manager/ops/cover.rs`,
`api/discovery.rs`, `api/phd2.rs`, `hotplug.rs`, `api/finishing_*.rs`, `sim_sky.rs`,
`device_manager/ops/switch.rs`, `ascom_wrapper/mount.rs`, `adaptive_polling.rs`,
`stacking_api.rs`, `device_manager/heartbeat.rs` — all under the 1500-line Rust bar or
dominated by tests (`sim_frame.rs` is 929/1568 tests; `device_manager/ops/sim_gate.rs` is
588/1005). **Leave them alone this pass.** Splitting them would burn review budget without
reducing the cognitive load that actually hurts: the six files above 2500 lines.

---

# 2. DUPLICATION

### 2.1 ★ THE BIG ONE — three complete `DeviceOps` implementations, only one runs

`skotiq_sequencer::DeviceOps` has **67 methods** (measured on
`sequencer/src/device_ops.rs`). The bridge implements the trait **three times**:

| impl | file:line | methods | reachable? |
|---|---|---|---|
| `UnifiedDeviceOps` | `unified_device_ops.rs:224`, `impl` at `:273` | overrides **all 67** | **YES — the only live one** |
| `BridgeDeviceOps` | `sequencer_ops.rs:45`, `impl` at `:325` | 64 | **NO** |
| `RealDeviceOps` | `real_device_ops.rs:189`, `impl` at `:506` | 62 | **NO** |

60 method names are implemented in all three.

**Reachability proof.**
- `UnifiedDeviceOps` — built by `create_unified_device_ops()` (`unified_device_ops.rs:1932`),
  which is imported by 26 files under `api/` and is what installs ops on the executor at
  `api/sequencer.rs:1468`, `:1557`, `:1622`.
- `BridgeDeviceOps` — built only by `create_device_ops()` (`sequencer_ops.rs:1621`). Its
  **only** callers are `sequencer_api.rs:25`, `:195`, `:316`. Every public function in
  `sequencer_api.rs` is itself dead (§3.1). Plus two in-file tests at `sequencer_ops.rs:2056`
  and `:2142`.
- `RealDeviceOps` — referenced only by `imaging_ops.rs:53/77/87/650` (the `ImagingSession`,
  which is itself dead — §3.2) and by `lib.rs:108 pub use real_device_ops::*;`.

**Canonical survivor: `UnifiedDeviceOps`.** Nothing merges *into* it functionally — it is
already a strict superset (0 trait methods unoverridden). Delete `real_device_ops.rs`
(3231 lines) and `sequencer_ops.rs` (2191 lines) entirely, along with `sequencer_api.rs`
(506 lines) and the dead half of `imaging_ops.rs` (§3.2). That is **~6,500 lines of Rust
removed from a 93k-line non-generated crate (~7%)**.

**Two things must be carried across before deleting, or the delete is a regression:**

1. **Tests.** `sequencer_ops.rs`'s test module (2024-2191 plus the `pointing_tests` block
   from 1625) contains the only coverage of the FITS-header pointing invariants:
   `save_fits_writes_the_header_from_its_own_frame_context` (2047),
   `save_fits_derives_the_altitude_at_the_exposure_midpoint` (2130),
   `mount_pointing_wins_over_nominal_target_coordinates`,
   `untargeted_frame_carries_the_mount_pointing`,
   `missing_mount_falls_back_to_target_coordinates`,
   `database_row_and_fits_header_agree_for_the_same_frame`,
   `mountless_sequencer_frame_keeps_its_altitude_through_the_save_path`,
   `context_altitude_wins_and_no_site_stays_absent`,
   `context_pointing_without_altitude_resolves_it_from_app_settings`.
   These must be **repointed at `UnifiedDeviceOps::save_fits`** and must still pass. If any
   of them fails against `UnifiedDeviceOps`, that failure is a pre-existing live defect that
   the dead impl was masking — see 2.1a.

2. **`build_rich_header` / `MountPointing` / `context_altitude_pointing` /
   `altitude_degrees`** (`sequencer_ops.rs:143-324`) are only reachable from the dead impl.
   Decide deliberately whether to port `read_mount_pointing`'s live-mount fallback into
   `UnifiedDeviceOps::save_fits` or to drop it; do not delete it by accident.

**2.1a — an evidenced behavioural divergence between the live and dead `save_fits`.**
`UnifiedDeviceOps::save_fits` (`unified_device_ops.rs:1488-1521`) overrides the
`FrameContext`-derived header with `ImageData` **unconditionally**:

```
if let Some(g) = image_data.gain    { header.gain    = Some(g); }   // :1501
if let Some(o) = image_data.offset  { header.offset  = Some(o); }   // :1504
if let Some(t) = image_data.temperature { header.ccd_temp = Some(t); } // :1507
header.exposure_time = image_data.exposure_secs;                     // :1510
```

The dead `build_rich_header` (`sequencer_ops.rs:275-278`) does the opposite — it fills from
`ImageData` **only when the context field is `None`** — and documents why at
`sequencer_ops.rs:255-262`: the `FrameContext` is also what the `captured_images` DB row is
written from, so preferring it is what makes a FITS card and its DB column unable to
disagree about one frame. The comment at `api/imaging.rs:3399-3405` shows the codebase is
aware of all three impls and pushed the pointing fallback down into `from_frame_context` so
they'd agree — but the gain/offset/temp/exptime precedence was **not** unified. I did not
prove this produces a wrong card today (the sequencer folds the camera report into the
context before saving, so they are equal by construction on the sequencer path), but it is
the exact drift that the surviving code's own comments say must not be possible. Settle it
when the merge lands.

**Effort:** large (the delete itself is mechanical; the test repointing is the work).

### 2.2 `julian_day` / `local_sidereal_time` — three copies, one canonical, in another crate

Byte-identical bodies (diffed):
- `unified_device_ops.rs:1883` `julian_day`, `:1909` `local_sidereal_time`
- `sequencer_ops.rs:1579` `julian_day`, `:1605` `local_sidereal_time`
- canonical: `sequencer/src/meridian.rs:259` `julian_day`, `:293` `local_sidereal_time`,
  `:172` `calculate_altitude`

`api/sequencer.rs:3315` **already** calls `skotiq_sequencer::meridian::calculate_altitude`,
proving the dependency direction is fine. `UnifiedDeviceOps::calculate_altitude`
(`unified_device_ops.rs:1656-1671`) is `meridian::calculate_altitude(ra, dec, lat, lon,
Utc::now())` written out longhand (the only difference is `lst - ra_hours` vs
`hour_angle(ra_hours, lst)`, which is `cos`-equivalent).

**Canonical survivor:** `skotiq_sequencer::meridian`. Delete the two bridge copies of
`julian_day`/`local_sidereal_time` (that's automatic once §2.1 lands for `sequencer_ops.rs`;
`unified_device_ops.rs` needs an explicit edit) and make
`UnifiedDeviceOps::calculate_altitude` a one-line delegation. Also delete
`real_device_ops.rs:3195 calculate_days_since_j2000` with the file.
**Effort:** small.

### 2.3 `median` — three copies inside the bridge

- `builtin_guider.rs:1908` `fn median(values: &[f64]) -> f64` (sorts a clone)
- `api/finishing_analyze.rs:732` `fn median(v: &mut [f64]) -> f64` (sorts in place)
- `api/imaging.rs:1861` `pub(crate) fn median(values: &[f64]) -> f64`
- plus `unified_device_ops.rs:77` `median_from_sorted_f64(sorted: &[f64]) -> Option<f64>`
  (pre-sorted variant, different contract)

**Canonical survivor:** `api/imaging.rs:1861` is already `pub(crate)` — promote it to a new
`util/stats.rs` (`util/` already exists with `supervisor.rs`, `executor_event_bridge.rs`),
keep the `&mut [f64]` in-place variant as `median_in_place` since `finishing_analyze` relies
on not allocating, and keep `median_from_sorted_f64` as `median_sorted`. Three call sites to
repoint. **Effort:** small.

### 2.4 ★ The 5-arm `match driver_type` skeleton, repeated ~45 times

`grep -rn "match driver_type" device_manager/` → **45 hits**. Every one has the same shape
(`Some(DriverType::Ascom) => { #[cfg(windows)] {…} not_connected } | Alpaca => … | Native =>
… | Indi => … | Simulator => … | _ => not_connected`). Distribution of the
`Some(DriverType::Ascom)` arm alone: `ops/dome.rs` 11, `ops/camera.rs` 11, `ops/cover.rs` 10,
`ops/rotator.rs` 6, `api_version.rs` 2, `ops/safety.rs` 1, `ops/weather.rs` 1
(`ops/mount.rs` and `ops/filter_wheel.rs` use the un-`Option`-wrapped `DriverType::Ascom`
form). Canonical example to read: `device_manager/ops/camera.rs:1714-1823` — 110 lines to
set one integer.

There is already a seed of the right abstraction: `dispatch/device_common_metadata.rs`
defines a `DeviceCommonMetadata` trait implemented for both the ASCOM
(`dispatch/ascom_device_common.rs`) and Alpaca (`dispatch/alpaca_device_common.rs`) wrappers,
and `dispatch/mod.rs` documents the intent — "localize per-driver code paths so `devices.rs`
can read as a thin router" — but the routing itself was never extracted.

**Recommendation** (medium/large, do it *after* the file splits in §1.6 so the diff is
reviewable): add `device_manager/dispatch_macro.rs` with a `dispatch_device!` macro (or a
`with_camera!/with_mount!` family) that takes the device id, the per-driver expression, and
the operation name, and generates the arm skeleton + the uniform
`DeviceOpError::not_connected` / `invalid_device_id` fallbacks. Convert `ops/camera.rs`
first (11 sites) as the pilot, verify against the existing `ops/camera.rs` test modules
(2474/2538/2719), then roll through the other files.

### 2.5 ★ Hand-rolled INDI device-id parsing, ~40 production sites

`grep -rn 'let parts: Vec<&str> = device_id.split' bridge/src/` → **60 hits** (~40 in
production code, the rest in test helpers). Concentrations: `ops/camera.rs` ×11,
`ops/mount.rs` ×14, `ops/filter_wheel.rs` ×4, `ops/weather.rs` ×3, `dispatch/indi.rs` ×3,
`ops/switch.rs` ×1.

Meanwhile the canonical parser exists and is *better*:
`DeviceManager::parse_indi_device_id` (`dispatch/indi.rs:152-163`) delegates to
`crate::device_id::parse_device_id_cached` — i.e. it goes through the **LRU cache** in
`device_id.rs:220` with hit/miss metrics. It has only 4 production callers
(`ops/dome.rs:880`, `ops/switch.rs:207`, `ops/switch.rs:516`, and internally).

Drift is already visible between the copies: `ops/camera.rs:349` uses
`if parts.len() >= 4 { … }` and falls through, `ops/filter_wheel.rs:131` uses
`if parts.len() < 4 { return Err(invalid_device_id) }`. (I checked for an unguarded index:
`ops/weather.rs:256`/`:296` index `parts[1]` with no length check but both are inside the
`#[cfg(test)]` module that starts at `ops/weather.rs:172`, so **no reachable panic** — do
not report one.)

**Canonical survivor:** `DeviceManager::parse_indi_device_id`. Replace every hand-rolled
site with `let (host, port, device_name) = Self::parse_indi_device_id(device_id)?;` (or
`format!("{host}:{port}")` where a `server_key` is wanted). Mechanical, high line-count
reduction, and it puts every INDI id through the cache. **Effort:** medium (volume, not
difficulty).

### 2.6 `parse_alpaca_device_id` / `parse_ascom_device_id` / `parse_indi_device_id` in `real_device_ops.rs`

`real_device_ops.rs:107`, `:139`, `:163` re-implement what `device_id::ParsedDeviceId::parse`
already does. Resolved for free by deleting the file (§2.1). Same for
`real_device_ops.rs:3157 decode_base64` (the crate already depends on the `base64` crate).

### 2.7 Two parallel sequencer control surfaces over **one** executor singleton

`sequencer_api.rs` (`sequencer_load_plan`/`_start`/`_stop`/`_pause`/`_resume`/
`_get_status`/`_set_devices`/…) and `api/sequencer.rs` (`api_sequencer_load_json`/
`_start`/…) both operate on the *same* global — `api/sequencer.rs:41-44
get_sequence_executor()` is literally `skotiq_sequencer::get_executor()`, which is what
`sequencer_api.rs:4` imports directly. Only the `api/` surface is FRB-exported.
`sequencer_api.rs` is therefore dead **and** a latent footgun: if anyone ever wired it up,
`sequencer_load_plan` (line 25) would silently swap the live executor's `DeviceOps` from
`UnifiedDeviceOps` to the stale `BridgeDeviceOps`. **Canonical survivor: `api/sequencer.rs`.
Delete `sequencer_api.rs`.**

---

## SUSPECTED CROSS-PACKAGE DUPLICATION (one line each — for the cross-cutting agent)

- `bridge/src/unified_device_ops.rs:1883,1909` vs `sequencer/src/meridian.rs:259,293` —
  `julian_day` / `local_sidereal_time` are byte-identical; the bridge copies should go.
- `bridge/src/api/devices/simulation.rs:723 sim_local_sidereal_time` — a *third* LST
  implementation, in the simulator this time.
- `sequencer/src/scheduling/astronomy.rs:56 local_sidereal_time(dt, lon)` vs
  `sequencer/src/meridian.rs:293 local_sidereal_time(jd, lon)` — two LST entry points inside
  the sequencer crate itself.
- `bridge/src/builtin_guider.rs` (a complete multi-star autoguider, ~2600 lines of code) vs
  `bridge/src/api/phd2.rs` (1024 lines) — same guiding contract, two backends; check whether
  the status/calibration DTO translation is duplicated rather than shared.
- `bridge/src/api/imaging.rs` `api_auto_stretch_image` / `api_apply_stretch` /
  `api_calculate_auto_stretch` vs `skotiq_imaging::{auto_stretch_stf, apply_stretch,
  auto_stretch_rgb_with_mode}` — the bridge may be re-deriving stretch params Dart-side too;
  check `packages/skotiq_core` for a Dart auto-stretch.
- `bridge/src/imaging_ops.rs:998 downsample_image` / `:1035 encode_jpeg` (both dead here) vs
  whatever produces thumbnails on the live path (`api/imaging.rs:4248
  api_generate_fits_thumbnail`) — likely the same algorithm twice.
- `bridge/src/api/finishing_combine.rs` vs `bridge/src/api/post_session.rs` master-frame
  combination vs `api/imaging.rs:6527 api_combine_master_frames` — three master-frame paths;
  worth one pass.
- `skotiq_imaging::ImageData::from_u16` (`imaging/src/lib.rs:384`) allocates a fresh
  `Vec<u8>` via `flat_map(to_le_bytes).collect()` — called on every FITS save from
  `api/imaging.rs:3746`; check whether a borrowing constructor exists elsewhere.
- `bridge/src/device_capabilities.rs` capability DTOs vs
  `packages/skotiq_bridge/lib/src/device_capabilities.dart` — verify the Dart side is
  the FRB-generated mirror and not a hand-maintained second copy.
- `bridge/src/event.rs` event enums vs `packages/skotiq_bridge/lib/src/event.dart` +
  `event.freezed.dart` — same question.

---

# 3. DEAD CODE

Method for every item: (a) `grep -c '<name>' frb_generated.rs` → 0, and (b) a whole-crate
scan of every non-generated `.rs` file counting occurrences of the identifier, subtracting
the definition. 1012 `pub fn`s were scanned; 91 came back with **literally zero** references
anywhere. The ones that matter:

### 3.1 `sequencer_api.rs` — the whole file, 506 lines

All 25 public functions have zero references anywhere in the repo (`.rs`, `.dart`, `.js`):
`sequencer_load_plan` (:17), `sequencer_start` (:33), `sequencer_stop` (:43),
`sequencer_pause` (:53), `sequencer_resume` (:63), `sequencer_get_status` (:73),
`sequencer_set_devices` (:154), `sequencer_set_simulation_mode` (:169),
`sequencer_set_safety_fail_mode` (:207), `sequencer_set_safety_check_interval_seconds`
(:230), `sequencer_set_checkpoint_dir` (:280), `sequencer_has_recoverable_checkpoint`
(:289), `sequencer_get_checkpoint_info` (:301), `sequencer_resume_from_checkpoint` (:311),
`sequencer_save_checkpoint` (:324), `sequencer_clear_checkpoint` (:335),
`sequencer_set_trigger_enabled` (:352), `sequencer_set_all_triggers_enabled` (:370),
`sequencer_get_triggers` (:382), `sequencer_update_guiding_rms` (:416),
`sequencer_update_hfr` (:429), `sequencer_update_dither_config` (:448),
`sequencer_update_location` (:464), `sequencer_update_filter_offsets` (:477),
`sequencer_reset_hfr_baseline` (:487).

Evidence: `grep -rn "sequencer_load_plan\|sequencerLoadPlan\|sequencer_reset_hfr_baseline\|
sequencer_update_hfr\|sequencer_get_triggers\|sequencer_set_trigger_enabled" --include='*.rs'
--include='*.dart' --include='*.js' .` → only the definitions in `sequencer_api.rs`. And
`grep -c "sequencer_load_plan" frb_generated.rs` → 0 (it is outside `crate::api`, which is
the only FRB input). **Delete the file and `lib.rs:68 mod sequencer_api;` /
`lib.rs:109 pub use sequencer_api::*;`.**

### 3.2 `imaging_ops.rs` — the `ImagingSession` half, ~600 of 1128 lines

`init_imaging_session` (`imaging_ops.rs:650`) is **the only way** `IMAGING_SESSION`
(`:647`) is ever populated, and it has **zero callers** anywhere. Therefore `ImagingSession`
(`:75-645`) never exists, `get_imaging_session` (`:656`) always errors, and the five
entry points that go through it are unreachable: `imaging_start_single_exposure` (:669),
`imaging_start_looping` (:678), `imaging_stop_looping` (:711), `imaging_abort_exposure`
(:718), `imaging_is_running` (:724) — all with zero references, none in `frb_generated.rs`.

Also dead in the same file, zero references: `set_image_directory` (:826) — so
`IMAGE_DIRECTORY` (:823) is permanently `None` and `get_image_directory` (:833) always
returns `None`; `get_session_images` (:860); `get_image_thumbnail_by_path` (:964);
`get_image_data_by_path` (:985); and therefore `downsample_image` (:998) and `encode_jpeg`
(:1035), whose only callers are those two. **Careful:** the Dart method `getSessionImages`
exists (`packages/skotiq_core/lib/src/backend/roles/imaging_backend.dart:214` and 3
implementations) — it is served by the Dart backends, **not** by this Rust function.

`auto_stretch_color_image` (:775) has no non-test caller: `grep` shows only its definition,
its doc-comment, and four uses inside the file's own test module (1055-1122). Note
`api/imaging.rs:4210 api_auto_stretch_color_image` exists and is FRB-exported but calls
`skotiq_imaging` directly, not this.

**Survives and must stay:** `auto_stretch_image` (:741) → called by
`api/imaging.rs:4198`; `debayer_image` (:802) → called by `api/imaging.rs:4240`;
`ImageInfo` (:839) — verify before removing anything around it.

**Action:** reduce `imaging_ops.rs` to `auto_stretch_image`, `debayer_image`, `ImageInfo`
and their tests (≈250 lines), or fold those two into `api/imaging/analysis.rs` and delete
the module outright.

### 3.3 `real_device_ops.rs` — the whole file, 3231 lines

Only two references outside the file: `lib.rs:108 pub use real_device_ops::*;` and
`imaging_ops.rs:53 use crate::{RealDeviceOps, SharedAppState};` (dead per §3.2).
`grep -rn "real_device_ops::" bridge/src/` → one hit, the `lib.rs` re-export.
`AlpacaConnectionInfo` (`:91`) — zero references outside the file. Zero test modules in the
file, so nothing is lost. Delete with `lib.rs:67` / `lib.rs:108`.

### 3.4 `sequencer_ops.rs` — the whole file, 2191 lines

`create_device_ops` (`:1621`) → only `sequencer_api.rs:25,195,316` (dead per §3.1).
`BridgeDeviceOps` (`:45`) → constructed only by `create_device_ops` and by the file's own
tests at `:2056`, `:2142`. `MountPointing` (`:143`), `altitude_degrees` (`:159`),
`context_altitude_pointing` (`:193`), `build_rich_header` (`:246`), `julian_day` (`:1579`),
`local_sidereal_time` (`:1605`) — all private, all reachable only from the dead impl.
**Delete with `lib.rs:69` / `lib.rs:110`, after repointing the 9 header tests listed in
§2.1(1).**

### 3.5 `lib.rs` — two `frb(sync)`-annotated functions that FRB never generated

- `lib.rs:399-401 init_native()` — zero references; not in `frb_generated.rs`. The live path
  is `init_native_with_logging` (`:289`), called from `init_native_internal` and from
  `api/init.rs`.
- `lib.rs:533-536 get_native_version()` — zero references; not in `frb_generated.rs`.

Both carry `#[flutter_rust_bridge::frb(sync)]`, which is a **no-op** here because
`flutter_rust_bridge.yaml` sets `rust_input: crate::api`. The annotation is actively
misleading — it reads as "this is exported" and it is not.

**Related live-behaviour note (belongs to the Dart side but originates here):**
`packages/skotiq_bridge/lib/src/bridge_stub/runtime_operations.dart:412-435`
does a raw `_nativeLib.lookupFunction<Pointer<Utf8> Function(), …>('get_native_version')`.
Since `lib.rs:534` is a plain Rust `fn` with no `#[no_mangle]` and no `extern "C"`, that
symbol does not exist in the `.so`/`.dll`, the lookup throws, the `catch` at line 427 logs
at level 900 and the function returns the hard-coded `'0.1.0'`. The version shown by this
path has never been the real one. (The live version display uses
`gen_api.apiGetVersion()` at `runtime_operations.dart:35`, which is fine — so this is a
dead fallback, not a user-visible wrong version, but the dead symbol should go.)

### 3.6 Lower-confidence dead candidates — zero refs, but verify intent before deleting

These all came back with zero references crate-wide and zero in `frb_generated.rs`, but
several are plausible "public API for completeness" surfaces on otherwise-live types. Listed
so an implementer can decide, not as a delete order:

- `error.rs` constructor/predicate family (14 fns): `device_timeout` (:222), `ascom_error`
  (:260), `alpaca_error` (:273), `indi_error` (:288), `native_error` (:303),
  `hardware_error_with_code` (:325), `communication_error` (:338), `device_disconnected`
  (:346), `operation_not_supported` (:354), `parameter_out_of_range` (:365),
  `is_hardware_error` (:460), `is_not_supported` (:474), `is_invalid_input` (:481),
  `is_cancellation` (:492), `to_json` (:777), `from_legacy_invalid_device_id` (:789),
  `from_legacy_connection_failed` (:797).
- `state.rs`: `new_with_storage` (:156), `update_device_state` (:171), `update_session`
  (:249), `publish_equipment_event_caused_by` (:501), `publish_imaging_event_correlated`
  (:527), `publish_safety_event` (:555), `publish_sequencer_event` (:566),
  `get_device_state` (:596), `is_profile_device_connected` (:645). **`publish_safety_event`
  having no callers is worth a second look** — safety events are the sort of thing that
  should be emitted.
- `event.rs`: `EventBus::current_sequence` (:1286), `has_capacity` (:1306),
  `create_event_with_cause` (:1413), `EventContext::with_correlation` (:1477),
  `with_device` (:1483), `generate_correlation_id` (:1503). The whole `EventContext`
  correlation facility appears unused.
- `timeout_ops.rs`: `with_timeout_custom` (:204), `exposure_with_timeout` (:253), `patient`
  (:337), `with_retry` (:349), `from_instant` (:445).
- `adaptive_polling.rs` builder methods: `with_name` (:93), `backoff_ratio` (:233),
  `change_ratio` (:242), `default_tolerance` (:468), `no_auto_reset` (:752), `build_sync`
  (:780), `build_atomic` (:785).
- `device_manager/heartbeat.rs`: `stop_all_heartbeats` (:691) — **check shutdown ordering
  before deleting**; `update_device_communication` (:743).
- `device_manager/mod.rs:825 with_config` — the `ReconnectConfig` injection point; only
  `new` (:753) is used, so `ReconnectConfig` is never non-default in production.
- `device_id.rs:942 is_network_device`, `:950 network_address`.
- `unified_device_ops.rs:1937 create_unified_device_ops_with_state` — the `_with_state`
  variant; only the global-state `create_unified_device_ops` is used.
- `api/sequencer.rs:1384 api_sequencer_event_stream` — **this one is inside `crate::api` and
  still absent from `frb_generated.rs`.** Either FRB skipped it (it returns `impl
  futures::Stream`, which FRB may not bridge) or it is genuinely orphaned. Worth a specific
  check: if the Dart side expects a sequencer event stream and this is how it was meant to
  arrive, this is a defect, not dead code. The live path appears to be
  `api_sequencer_subscribe_events` (:467) pushing into the global event bus instead.

---

# 4. PERF RISKS

### P1 — Full-frame star detection, stretch and statistics run on the async runtime with no `spawn_blocking` — **impact: medium-high**

`api/imaging.rs`, inside `camera_start_exposure_configured_opt` (the FRB-exported real-camera
capture path), all on the calling tokio task:
- `:1191` `apply_stretch` (or `:1174` `apply_stretch_rgb_per_channel`) — one full-frame pass
- `:1207` `calculate_stats_u16` — one full-frame pass
- `:1208-1211` `detect_stars(&image, StarDetectionConfig::default())` — the expensive one
- `:1261-1263` 256-bin histogram — one full-frame pass
- `:1267` `display_data_to_rgba` — rayon, but `par_chunks_exact_mut` **blocks the calling
  thread** until the rayon pool finishes

The whole crate uses `spawn_blocking` in exactly three production places
(`api/plate_solve.rs:158`, `:223`, and inside vendor drivers per the comment at
`unified_device_ops.rs:685`). On a 24 MP frame `detect_stars` is comfortably seconds of pure
CPU; that tokio worker is unavailable for the event bridge, heartbeats and the headless HTTP
handlers for the duration. **Fix:** wrap `:1150`-`:1267` in `tokio::task::spawn_blocking`
(the inputs are already owned `Vec`s, so the move is clean).

### P2 — Three extra full-frame passes per exposure purely to build an INFO log line — **impact: medium**

`api/imaging.rs:1194-1197`:
```
let display_min  = display_data_raw.iter().min()...;   // pass 1
let display_max  = display_data_raw.iter().max()...;   // pass 2
let display_sum: u64 = display_data_raw.iter().map(|&v| v as u64).sum();  // pass 3
let display_mean = display_sum / display_data_raw.len() as u64;
```
feeding `tracing::info!("[DIAGNOSTIC] Display data after stretch: …")` at `:1198`. Three
unconditional linear scans of a w×h buffer on **every** exposure, for diagnostics. **Fix:**
single fused fold, and gate the whole block behind `tracing::enabled!(Level::DEBUG)` (the
adjacent code at `api/imaging.rs:1313-1316` already documents demoting per-call INFO to
DEBUG for exactly this reason).

### P3 — Avoidable full-frame copy on the last use of the buffer — **impact: medium**

`api/imaging.rs:1295` `data: seq_image.data.clone()` inside the `RawImageInfo` construction.
`seq_image` is not used again after `:1298` (only `.width`/`.height`/`.sensor_type`/
`.bayer_offset` are read, all before the clone). **Fix:** destructure `seq_image` (or
`std::mem::take(&mut seq_image.data)`) and move the `Vec<u16>` instead. Saves one
w×h×2-byte allocation + memcpy per exposure — 48 MB on a 24 MP sensor.

### P4 — Double copy on every FITS save — **impact: medium**

`unified_device_ops.rs:1517` passes `image_data.data.clone()` (copy 1, `Vec<u16>`) into
`api/imaging.rs:3736 save_fits_file_rich(… data: Vec<u16> …)`, which at `:3745` immediately
does `ImageData::from_u16(width, height, 1, &data)` — and
`imaging/src/lib.rs:384-394` builds a whole new `Vec<u8>` via
`data.iter().flat_map(|&v| v.to_le_bytes()).collect()` (copy 2, and `flat_map` over an array
iterator gives a poor `size_hint`, so this reallocates repeatedly). Combined with P3 the
capture+save path allocates roughly 4× the frame size per light frame. **Fix (bridge side):**
change `save_fits_file_rich` to take `&[u16]` and drop the `.clone()` at the two call sites
(`unified_device_ops.rs:1454` and `:1517`). The `from_u16` reallocation is a
`skotiq_imaging` fix — flagged for the cross-cutting agent.

### P5 — `UNIFIED_IMAGE_STORAGE`'s documented memory bound undercounts by ~3× — **impact: low-medium**

`api/imaging.rs:559-561` states "At ~24 MB per u16 frame (4144x2822 sensors), the cap holds
worst-case ~1.2 GB". But each LRU value is `CapturedImageData` (`:544-551`) = `display:
CapturedImageResult` **plus** `raw_info: RawImageInfo`, and `CapturedImageResult.display_data`
(`:474`) is "Always RGBA (width*height*4)". For 4144×2822 that is 46.8 MB **on top of** the
23.4 MB raw — ~70 MB per entry, so the real cap is ≈3.5 GB, not 1.2 GB. Not a leak (the LRU
bound is real and eviction is traced at `:590-596`), and realistic rigs hold 1-5 entries —
but the stated headroom is wrong and the cap was chosen from the wrong number. **Fix:**
either correct the comment and lower `UNIFIED_IMAGE_STORAGE_CAPACITY` (`:561`) to something
justified by the true per-entry cost, or store the display buffer separately with its own
smaller cap.

### P6 — Two unbounded process-lifetime maps keyed by device id — **impact: low**

- `device_capabilities.rs:589` `static CAPABILITY_CACHE: … HashMap<String,
  CapabilityCacheEntry>`. Entries have a 5-minute TTL (`:581`) but expiry only *refreshes*
  an entry on re-query (`:911-941`); nothing sweeps. A device id that is queried once and
  never again holds its `DeviceCapabilities` (a large enum) forever. Only
  `invalidate_capability_cache` (`:891`) clears, and it clears everything.
- `unified_device_ops.rs:108` `static EXPOSURE_ABORT_GENERATIONS: … HashMap<String, u64>`,
  inserted by `mark_camera_exposure_aborted` (`:127-131`), never removed. Tiny entries;
  noted only for completeness.

Both are bounded by *distinct device ids seen this process*, which is small in practice —
low impact. Worth a TTL sweep on the capability cache since USB re-enumeration is exactly
the churn the codebase already calls out at `api/imaging.rs:556-558`.

### P7 — `std::thread::sleep` inside `async fn` (5 sites) — **impact: none today, but do not resurrect**

`real_device_ops.rs:561` (500 ms, in `mount_slew_to_coordinates`), `:1173` (100 ms, in
`camera_start_exposure`), `:1933` (`focuser_move_to`), `:2398` and `:2449`
(`rotator_move_to`/`_relative`). These block the tokio worker outright. **They are
unreachable today** (§3.3) — recorded here as one more reason the file must be deleted
rather than revived, and as the pattern to reject if it reappears.

---

# 5. RELIABILITY RISKS

### R1 — `#[flutter_rust_bridge::frb(sync)]` outside `crate::api` is silently a no-op

`lib.rs:399` (`init_native`) and `lib.rs:533` (`get_native_version`) both carry the
attribute; `flutter_rust_bridge.yaml` sets `rust_input: crate::api`; neither appears in
`frb_generated.rs`. Nothing warns. Any future contributor who adds an `frb` annotation
outside `api/` will get a function that compiles, looks exported, and is never callable.
**Fix:** delete both dead functions (§3.5) and add a one-line note to `lib.rs`'s module doc
stating that only `crate::api` is FRB input.

### R2 — A raw `dlsym` on a Rust symbol that cannot exist

`packages/skotiq_bridge/lib/src/bridge_stub/runtime_operations.dart:414-419` looks up
`'get_native_version'` by name. `lib.rs:534` has no `#[no_mangle]` and no `extern "C"`, and
`grep -rn "no_mangle\|extern \"C\"" bridge/src/` (excluding generated) returns nothing — so
the symbol is name-mangled and the lookup always throws, is caught at
`runtime_operations.dart:427`, and returns the literal `'0.1.0'`. A permanently-failing
lookup that is swallowed into a hard-coded value. Delete the Rust fn and the Dart fallback
together.

### R3 — `division by len()` with no local emptiness guard

`api/imaging.rs:1197` `let display_mean = display_sum / display_data_raw.len() as u64;`
inside the grayscale branch. Integer division by zero panics. I traced back to `:1150` and
did **not** find a `width > 0 && height > 0` guard between the driver download and this
line; I also did not construct a case where a driver returns a zero-pixel frame, so treat
this as "add the guard", not "known crash". Low. (Fixed for free if P2's fused fold is
implemented with a `checked_div` / `is_empty` early-out.)

### R4 — `.expect("device cache mutex poisoned")` on a `std::sync::Mutex`

`hotplug.rs:262` and `:347`. A `std::sync::Mutex` poisons if any thread panics while
holding it; after that, every hotplug scan panics. The rest of the crate handles this
correctly — `device_manager/mod.rs:3340` uses `.unwrap_or_else(|e| e.into_inner())`, and the
tokio `Mutex`es elsewhere cannot poison at all. **Fix:** use `unwrap_or_else(|e|
e.into_inner())` at both sites, matching the existing crate idiom. Low, but a one-line fix.
(`device_manager/ops/sim_faults.rs` has nine similar `.expect("sim fault registry
poisoned")` calls at `:197,:220,:231,:241,:260,:273,:284,:299,:351`; that registry is only
armed by the `SKOTIQ_SIM_FAULTS` test harness, so lower priority — but same fix.)

### R5 — Things I checked and found CLEAN (recorded so a verifier does not re-derive them)

- **Locks held across `await`:** I scanned every `let … = X.lock()/.read()/.write()` without
  `.await` and looked 40 lines ahead for an `.await` while the guard was live. **Every hit
  was in test code** (`ascom_wrapper/mount.rs:1009`, `device_manager/mod.rs:3340`,
  `util/supervisor.rs:295/341/356/412/446`). No production sync-lock-across-await.
- **`unwrap`/`expect`/`panic!` in production paths:** the full scan (excluding `#[cfg(test)]`
  bodies) produced only R3/R4 above plus documented-invariant expects
  (`api/imaging.rs:658-667 "checked above"` — preceded by the all/any check at `:651-661`;
  `api/discovery.rs:753` — the cache is populated at `:747-750` immediately above;
  `api/imaging.rs:580` — a `const 50` `NonZeroUsize`). No `todo!`/`unimplemented!`.
- **Exposure polling has real timeouts.** `unified_device_ops.rs:143-211`
  (`wait_for_camera_exposure_complete`) bounds both the overall deadline and *each individual
  poll* (`tokio::time::timeout(remaining, is_complete())` at `:178`), and honours an abort
  generation (`:159`). This is the correct pattern; hold other polling loops to it.
- **Background tasks are supervised.** Only 12 raw `tokio::spawn` sites exist outside tests,
  and 7 places go through `util/supervisor.rs`'s `spawn_supervised_restart`
  (e.g. `api/sequencer.rs:497`), which restarts on panic with backoff.
- **`std::fs` in async:** the only production hits are `std::fs::remove_file` on a temp path
  in the plate-solve / polar-align cleanup (`unified_device_ops.rs:1471`,
  `api/polar_alignment.rs:640,644,653,887,891,912`). Single small unlinks; not worth changing.

---

# 6. RECOMMENDED ORDER OF WORK

1. **Delete the dead parallel stack** — `sequencer_api.rs`, `real_device_ops.rs`,
   `sequencer_ops.rs`, the `ImagingSession` half of `imaging_ops.rs`, and the two dead
   `lib.rs` fns. ~6,500 lines. Gate: the 9 header tests from §2.1(1) must pass against
   `UnifiedDeviceOps::save_fits`.
2. **Settle §2.1a** (ImageData-vs-FrameContext precedence in the surviving `save_fits`)
   while those tests are in hand.
3. **`device_manager/mod.rs` test extraction** — 2337 lines out of a 3391-line file, pure
   move, near-zero risk.
4. **Split `api/imaging.rs`** — the largest file and the one on the capture hot path.
5. **P1+P2+P3** together (they are all in the block that moves to
   `api/imaging/capture.rs`): `spawn_blocking` the analysis, fuse+gate the diagnostic scans,
   move the buffer instead of cloning.
6. **Split `device_capabilities.rs`** (clean per-transport seams) and **`builtin_guider.rs`**.
7. **§2.5** — replace ~40 hand-rolled INDI id parses with
   `DeviceManager::parse_indi_device_id`.
8. **§2.4** — the `dispatch_device!` macro, piloted on `device_manager/ops/camera.rs`, after
   §1.6 has split it.
9. Small cleanups: §2.2 (delete the astronomy copies), §2.3 (one `median`), R4 (poison
   handling), P5 (fix the storage bound comment/cap).
