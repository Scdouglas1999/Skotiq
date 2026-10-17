# rust-bridge implementation log

Baseline: b07d91c9d. Scope: `native/skotiq_native/bridge/**` except `frb_generated.rs`.

## Resume state found on the tree
`git diff b07d91c9d -- native/skotiq_native/bridge/` showed only compile-fixups from
the concurrent rust-sequencer batch (`update_location`/`update_dither_config`/
`update_filter_offsets` became `async`) in `api/sequencer.rs` and `sequencer_api.rs`.
No predecessor work on any of my items; no `*.tmp.*` files under my scope.

## Items

### 1. RELOCATE the live-needed helpers out of the doomed files — DONE

Into `unified_device_ops.rs` (verbatim moves, no logic edits):
- `MountPointing`, `altitude_degrees`, `context_altitude_pointing`, `build_rich_header`,
  `connected_camera_label` (was `sequencer_ops.rs:143-324`)
- `read_mount_pointing` as an inherent method on `UnifiedDeviceOps` (was
  `BridgeDeviceOps::read_mount_pointing`, `sequencer_ops.rs:104-137`)
- `mod pointing_tests` → `unified_device_ops.rs`, re-pointed at `UnifiedDeviceOps`
- `unified_device_ops.rs:1054` now calls the local `connected_camera_label` instead of
  `crate::sequencer_ops::connected_camera_label`.

Into `api/imaging.rs` (as PRIVATE `fn`, so FRB's `crate::api` scan cannot pick them up and
`frb_generated.rs` needs no regeneration):
- `get_image_stats` → `image_stats`, `auto_stretch_image`, `auto_stretch_color_image`,
  `debayer_image` (were `imaging_ops.rs:735-825`), plus `mod auto_stretch_color_tests`.
- The five call sites at `api/imaging.rs` (`api_get_image_stats`, `api_auto_stretch_image`,
  `api_auto_stretch_color_image`, `api_debayer_image`, `api_generate_fits_thumbnail`) now
  call them directly.

### 2. Re-point the 9 FITS-header pointing tests at `UnifiedDeviceOps::save_fits` — DONE

`cargo test -p skotiq_bridge --lib unified_device_ops::pointing_tests` → 9 passed.

### 3. BUG — `save_fits` precedence / midpoint epoch / mount fallback — CONFIRMED + FIXED

**Failing first.** With the tests re-pointed but `save_fits` untouched, 2 of the 9 failed:
```
save_fits_writes_the_header_from_its_own_frame_context  FAILED
  assertion `left == right` failed   left: Some(100)  right: Some(139)     (GAIN card)
save_fits_derives_the_altitude_at_the_exposure_midpoint FAILED
  OBJCTALT card must be present
```
i.e. the live impl let `ImageData` (gain 100) overwrite the `FrameContext` (gain 139) — the
same struct the `captured_images` row is written from — and had no midpoint epoch and no
mount-read fallback, so a sequenced frame lost OBJCTALT/AIRMASS outright.

**Fix.** `UnifiedDeviceOps::save_fits` now resolves the sky epoch from
`frame_ctx.exposure_midpoint()`, uses `context_altitude_pointing` when the context already
carries the pointing and `read_mount_pointing` when it does not, and builds the header via
`build_rich_header` — where `FrameContext` wins when `Some` and `ImageData` fills only the
`None`s (the adjudicated precedence).

After: `unified_device_ops::pointing_tests` → **9 passed, 0 failed**.

### 4. DELETE the dead parallel stack — DONE

Deleted whole files: `sequencer_api.rs` (506), `real_device_ops.rs` (3231),
`sequencer_ops.rs` (2191), `imaging_ops.rs` (1128). Dropped `mod` + `pub use` for all four
from `lib.rs` (8 single-line edits).

Zero-caller re-proof (fresh, `native/ packages/ apps/ tools/`, `*.rs` and `*.dart`, plus
`grep -c` in `frb_generated.rs`): every deleted symbol → **0** references outside the
deleted files and **0** in `frb_generated.rs`. `Dart getSessionImages` is served by the
Drift/network backends, not this Rust fn (checked all 4 Dart implementations).

Two collateral edits:
- `sim_capture.rs::release_gate_still_guards_null_device_ops` iterated over two entry
  points, one of them `sequencer_api.rs`. Reduced to the one surviving entry point
  (`api/sequencer.rs::api_sequencer_set_simulation_mode`) and the doc comment corrected.
- `unified_device_ops.rs` module doc + the `RealDeviceOps` reference in the recovery comment
  rewritten (they named the now-deleted impls).

**Tests deleted with the dead code:** `sequencer_api.rs`'s `status_tests`
(`completed_non_exposure_plan_reports_full_progress`,
`running_exposure_plan_reports_bounded_fraction`). They exercised only
`sequencer_progress_fraction`, a private helper of the dead `sequencer_get_status`. The live
surface (`api/sequencer.rs::SequencerState`) exposes raw `completed_exposures` /
`total_exposures` and computes no fraction in Rust at all, so there is nothing for them to
re-point at. `real_device_ops.rs` had no tests; `sequencer_ops.rs`'s 9 and
`imaging_ops.rs`'s 4 were both carried across (above).

Build proof that FRB needs no regeneration: `cargo build -p skotiq_bridge --lib`
compiles against the untouched `frb_generated.rs`.

### 5. MOVE `device_manager/mod.rs`'s test module → `device_manager/tests.rs` — DONE

Pure move (body extracted verbatim, then `rustfmt`; `mod.rs` keeps `#[cfg(test)] mod tests;`).
`mod.rs` 3391 → 1056 lines; `tests.rs` 2314 lines. Module path unchanged
(`device_manager::tests::*`), so `use super::*` still reaches the private items.
`cargo test -p skotiq_bridge --lib device_manager::tests` → **47 passed** (identical set).

### 6. DEDUP — the hand-rolled INDI id parses — DONE (48 sites)

All of `device_id.split(':')` / `info.id.split(':')` under `device_manager/` and
`dispatch/indi.rs` now go through `DeviceManager::parse_indi_device_id`
(→ `device_id::parse_device_id_cached`, i.e. the LRU cache):
camera 10, dome 10, mount 13, focuser 8, rotator 6, filter_wheel 4, weather 3 (2 test
helpers), cover 1 (test helper), safety 1, switch 1, connection 1, dispatch/indi 3
(incl. `connect_indi`, the writer of the `indi_clients` key). Remaining matches in the
crate: my own explanatory comment, and `dispatch/native.rs` (a NATIVE id, not INDI).

Shape mapping, chosen so each site keeps its own dominant intent:
- sites that already errored (`if parts.len() < 4 { return Err(...) }`, or a `?` on the port
  parse) → `Self::parse_indi_device_id(device_id).map_err(DeviceOpError::invalid_device_id)?`
  or, where the whole INDI arm's fall-through was itself `Err(invalid_device_id)` (focuser,
  filter_wheel), `if let Ok(...)` which reaches that same error.
- sites that fell through on a malformed id (`if parts.len() >= 4 { … }`) →
  `if let Ok((host, port, device_name)) = …` — same fall-through, same fallback.
- `switch.rs:423` indexed `parts[1]`/`parts[2]` with **no** length guard in production code;
  it now returns `invalid_device_id` instead of being one malformed id away from a panic.

Parity tests (`device_manager/tests.rs`) on the inputs where the copies disagreed:
`indi_id_keeps_a_device_name_that_contains_colons`,
`indi_server_key_is_the_parsed_port_not_the_raw_text` (the readers used to key on the RAW
port text while `connect_indi` inserted under the PARSED `u16`, so `indi:host:07624:X`
looked up a key that could never exist), and
`indi_id_rejects_what_the_hand_rolled_copies_waved_through` (non-numeric port, empty host,
empty device name, missing device name, wrong prefix). → 3 passed.

Mid-item incident, recorded because it matters for review: the first regex pass had an
unbounded `(?:.*\n)*?` in the guard body and swallowed 272 lines (2 whole functions) of
`device_manager/ops/camera.rs`. Caught by `cargo check` and by a `grep -c "fn "` census
against the baseline. `camera.rs` was restored from `b07d91c9d` (`git show`, read-only) and
redone with a bounded, line-based transform. The `fn` census was then run against the
baseline for **every** touched file: all match.

### 7. PERF on the capture path (`api/imaging.rs`) — DONE

- **P1** the whole full-frame CPU section of `camera_start_exposure_configured_opt`
  (`ImageData::from_u16` → debayer/stretch → `calculate_stats_u16` → `detect_stars` →
  histogram → `display_data_to_rgba`) now runs inside `tokio::task::spawn_blocking`,
  returning `(CapturedImageResult, RawImageInfo)`. No `.await` existed anywhere inside that
  span, so the move is mechanical. Only `store_captured_image_atomically` stays on the
  runtime.
- **P2** the three unconditional full-frame diagnostic scans became one fused fold in a new
  private `display_data_summary(&[u8]) -> Option<(u8, u8, u64)>`, called only under
  `tracing::enabled!(tracing::Level::DEBUG)` and logged at `debug!`.
- **P3 / R3** `RawImageInfo` now MOVES `seq_image.data` instead of cloning it (one
  w*h*2-byte alloc + memcpy less per frame), and the `Option` return of
  `display_data_summary` removes the `sum / len()` divide-by-zero on an empty buffer.

Tests: `api::imaging::display_diagnostic_tests` — `fused_summary_matches_three_separate_passes`
(fold vs. the three passes it replaced), `empty_buffer_reports_nothing_rather_than_dividing_by_zero`,
`single_pixel_is_its_own_min_max_and_mean` → 3 passed.

## Final verification

- `cargo check -p skotiq_bridge --all-targets` → clean (0 errors, 0 warnings in the
  bridge; the only warning in the workspace is `native/src/vendor/gphoto2.rs`, another
  agent's crate).
- `cargo build -p skotiq_bridge --lib` → Finished (proves `frb_generated.rs` is
  unchanged and still compiles).
- `cargo test -p skotiq_bridge` → **534 passed; 0 failed; 4 ignored**.
  Baseline was 530 passed / 4 ignored; net +4 = −2 (dead `sequencer_api` helper tests)
  +3 (INDI parity) +3 (fused-fold).
- Net: **−9853 / +1261 lines** across the crate.

## Not done / out of scope
- `NO api/imaging.rs split; NO dispatch_device! macro` per the adjudication.
- P4 (`save_fits_file_rich` taking `&[u16]`) was not in the item list; the `.clone()` at
  `unified_device_ops.rs` remains.
