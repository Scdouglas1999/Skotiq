# C3 — rust-sequencer-instructions

Batch: `rust-sequencer-instructions`
Scope: `native/skotiq_native/sequencer/src/instructions.rs` + its module tree
Date: 2026-08-13
Plan followed: `reports/release-pass/map/rust-sequencer.md` §1.1

## Re-measurement at start

| file | lines at start | threshold (Rust 1500) | action |
|---|---:|---|---|
| `sequencer/src/instructions.rs` | 11786 | over | **split** |

The map recorded 11732; the file had grown to 11786 by the time this batch ran, so
every line number in the map's table was re-derived from the live file before cutting.
No other file was in scope for this batch.

## What was done

`instructions.rs` became `instructions/` — 27 production child modules, one `mod.rs`,
and a `tests/` subtree of 18 topic modules plus its own `mod.rs`. Every line of the
old file landed in exactly one new file; the split script asserted that (it refuses to
run if any source line is consumed twice, and the only lines it is allowed to drop are
blank separators, the `// TESTS` banner, and the `mod tests { … }` wrapper the module
system now supplies).

`mod.rs` keeps the original module doc and the original `use` preamble, declares the
children, and re-exports them with `pub use <child>::*;`. Because the preamble stays in
`mod.rs`, every child needs only `use super::*;` to see both the crate imports the old
file had and its sibling modules. Three modules whose contents are all crate-private
(`disconnect`, `frame_context`, `save_path`) are re-exported as `pub(crate) use` instead,
which is what rustc asked for.

Every existing path survives: `crate::instructions::InstructionContext`,
`crate::instructions::DEFAULT_MAX_SUN_ALTITUDE_DEGREES`, `lib.rs:72`'s
`pub use instructions::*;`, and `skotiq_sequencer::instructions::{…}` as imported by
`bridge/src/api/imaging.rs:183` all resolve exactly as before. No FRB regeneration is
involved — the codegen lives in `bridge/` and none of its inputs moved.

### Production modules

| file | lines | file | lines |
|---|---:|---|---:|
| `mod.rs` | 77 | `dither.rs` | 244 |
| `gating.rs` | 401 | `guiding.rs` | 366 |
| `context.rs` | 447 | `filter.rs` | 260 |
| `disconnect.rs` | 66 | `cooling.rs` | 283 |
| `slew.rs` | 226 | `park.rs` | 75 |
| `wait.rs` | 208 | `polar_align.rs` | 20 |
| `save_path.rs` | 89 | `wait_time.rs` | 175 |
| `rotator.rs` | 157 | `delay.rs` | 56 |
| `center.rs` | 673 | `notification.rs` | 45 |
| `expose.rs` | 1015 | `script.rs` | 199 |
| `grading.rs` | 702 | `meridian_flip.rs` | 192 |
| `frame_context.rs` | 337 | `dome.rs` | 303 |
| `autofocus.rs` | 1235 | `mosaic.rs` | 22 |
| | | `cover_calibrator.rs` | 364 |

Largest is `autofocus.rs` at 1235 — the map anticipated this and accepted it as one
cohesive state machine. Nothing is over 1500.

`rotator.rs` merges the two ranges the map paired: the shared move-and-verify helper
(old 1418–1503) and `execute_rotator_move` (old 6558–6620). `context.rs` likewise takes
the two `InstructionResult` / `InstructionContext` ranges with `disconnect.rs` lifted out
from between them.

### Tests

The map wanted the 3.7k test lines re-homed alongside the code they exercise. Doing that
per-production-module would have meant hand-sorting 92 tests across 27 files against
shared fixtures defined mid-file. Instead the tests moved as one verbatim block into
`instructions/tests/`, where:

- `tests/mod.rs` (979 lines) holds every non-test item — `AF_GATE_TEST_LOCK`,
  `ScriptedDomeRotatorOps` and its `DeviceOps` impl, `ctx_with_ops`, `ScratchDir`,
  `scratch_dir`, the `*_ctx` builders, `one_light` / `one_dark` / `one_dark_no_filter`,
  `drain_frame_captures`, the Linux-only script fixtures, and so on. **No visibility
  widening was needed here**: a child module can already see its ancestors' private items.
- 18 topic modules hold the 92 tests, grouped by cluster: `autofocus`, `center`,
  `cooling`, `daylight_gate`, `disconnect`, `dome`, `expose`, `filter_identity`,
  `frame_metadata`, `grading`, `guiding`, `meridian_gate`, `pointing_gate`, `rotator`,
  `save_path`, `script`, `slew`, `wait_time`. Largest is `frame_metadata.rs` at 433 lines.

Test bodies are byte-identical; only the module path grew one segment
(`instructions::tests::foo` → `instructions::tests::dome::foo`).

## Visibility widenings (the only non-motion edits)

55 top-level items that were file-private became `pub(crate)` because the split put them
behind a module boundary from their callers or from the tests:

- `gating.rs`: `frame_type_requires_darkness`, `resolve_max_sun_altitude`, `validate_exposure_filter_request`
- `disconnect.rs`: `request_device_disconnected_recovery`
- `slew.rs`: `SLEW_POSITION_TOLERANCE_DEG`, `normalize_ra_diff_hours`, `validate_slew_position`
- `wait.rs`: `wait_for_mount_idle_with_progress`, `wait_for_focuser_idle`, `wait_for_filterwheel_idle`, `wait_for_cancellation`
- `save_path.rs`: `claim_save_path`, `ensure_unique_save_path`
- `rotator.rs`: `ROTATOR_TOLERANCE_DEG`, `ROTATOR_TIMEOUT_SECS`, `ROTATOR_POLL_SECS`, `normalize_rotator_angle`, `rotator_angle_diff`, `rotator_move_to_verified`
- `center.rs`: `CENTER_CORRECTION_SLEW_START_TIMEOUT`, `CENTER_CORRECTION_SLEW_COMPLETE_TIMEOUT`, `CENTER_CORRECTION_SLEW_POLL_INTERVAL`, `wait_for_centering_correction_slew`, `apply_center_rotation`, `wait_for_meridian_flip_window`, `current_target_hour_angle`, `calculate_separation_arcsec`
- `expose.rs`: `CameraExposureAbortGuard`
- `grading.rs`: `build_environment_snapshot`, `push_forensic_sample`, `emit_grade_progress`
- `frame_context.rs`: `build_frame_context_for_save`
- `autofocus.rs`: `AUTOFOCUS_RUN_ACTIVE`, `admit_autofocus_run_waiting`, `execute_autofocus_attempts`, `move_autofocus_filter`, `resume_guiding_after_autofocus`, `append_autofocus_cleanup_failure`, `validate_autofocus_config`, `execute_autofocus_once`, `restore_autofocus_origin`, `wait_for_autofocus_settle`, `HfrMeasurementWithCrops`, `StarCropInfo`, `calculate_hfr_with_crops`
- `guiding.rs`: `GuiderStartupCleanupGuard`
- `filter.rs`: `DEFAULT_FILTER_WHEEL_TIMEOUT_SECS`, `apply_filter_focus_offset`
- `wait_time.rs`: `calculate_twilight_time`
- `script.rs`: `kill_script_process_group`, `Abort`
- `dome.rs`: `DOME_SHUTTER_TIMEOUT_SECS`, `wait_for_dome_shutter_state`
- `cover_calibrator.rs`: `wait_for_cover_state`, `wait_for_calibrator_state`

Plus 5 inherent-impl methods the compiler flagged once the boundary existed:

- `context.rs`: `InstructionResult::log_and_get_status_with_recovery`
- `expose.rs`: `CameraExposureAbortGuard::new`, `CameraExposureAbortGuard::disarm`, `BurstControl::report`
- `grading.rs`: `DefectMapOutcome::into_record`

Nothing was widened past `pub(crate)`. Everything already `pub` stayed `pub`. No symbol was
renamed, no signature changed, no logic touched.

## Deviations from the map plan

1. **Tests grouped into `tests/<topic>.rs`, not scattered into each production module.**
   Same outcome for the file-size goal, far less opportunity to silently drop a test, and
   it keeps the shared `ScriptedDomeRotatorOps` fixture in one place instead of forcing a
   `testing.rs` with widened visibility (the map's `testing.rs` file is therefore not
   needed and was not created).
2. **`expose.rs` kept its plain name.** The map offered `expose_impl.rs` if the sibling
   `node/instructions/expose.rs` caused confusion; it does not — the paths are distinct
   and nothing in the crate refers to either by a bare `expose::` path.
3. **The map's D1–D4 follow-ups were not acted on** (deduping `normalize_ra_diff_hours`,
   moving the twilight/solar math out of `wait_time.rs`, etc.). Those are logic changes;
   this batch is motion only. `slew.rs` still carries its local `normalize_ra_diff_hours`.

## Verification

The working tree could not be used as the verification target: two other C3 batches were
concurrently mid-split in the same crate (`sequencer/src/triggers/` and
`sequencer/src/executor/`), leaving it transiently non-compiling for reasons unrelated to
this batch. Verification therefore ran in an isolated copy of
`native/skotiq_native/` carrying this batch's split and no other in-flight edit.

- `cargo check -p skotiq_sequencer --all-targets` — clean, 0 errors, 0 warnings.
- `cargo check --workspace --all-targets` — 0 errors. The only warnings are pre-existing
  ones in `bridge/src/device_capabilities/mod.rs` (a C1/C2 split, untouched here).
- `cargo test -p skotiq_sequencer` — **782 passed, 0 failed** in the lib target, plus
  5 + 4 + 12 in the three integration targets and 1 ignored doc-test. Identical to the
  pre-split baseline captured before any file was moved.
- Test inventory: `cargo test -- --list` gives 782 tests before and after; the 92
  `instructions::*` test names diff **identical** when compared on their leaf names.
- Against the live working tree, `cargo check -p skotiq_sequencer --all-targets`
  reports errors only in `executor/start.rs`, `executor/mod.rs` and `executor/tests/*` —
  the other batch's in-flight work. **Zero diagnostics point into `instructions/`.**

Formatting: `rustfmt --edition 2021` was run on `instructions/mod.rs` and
`instructions/tests/mod.rs` (which recurses into their children). No repo-wide formatter
was invoked and no file outside `instructions/` was touched.

## Files

Deleted: `native/skotiq_native/sequencer/src/instructions.rs`

Created (all under `native/skotiq_native/sequencer/src/instructions/`):
`mod.rs`, `autofocus.rs`, `center.rs`, `context.rs`, `cooling.rs`, `cover_calibrator.rs`,
`delay.rs`, `disconnect.rs`, `dither.rs`, `dome.rs`, `expose.rs`, `filter.rs`,
`frame_context.rs`, `gating.rs`, `grading.rs`, `guiding.rs`, `meridian_flip.rs`,
`mosaic.rs`, `notification.rs`, `park.rs`, `polar_align.rs`, `rotator.rs`, `save_path.rs`,
`script.rs`, `slew.rs`, `wait.rs`, `wait_time.rs`,
and `tests/`: `mod.rs`, `autofocus.rs`, `center.rs`, `cooling.rs`, `daylight_gate.rs`,
`disconnect.rs`, `dome.rs`, `expose.rs`, `filter_identity.rs`, `frame_metadata.rs`,
`grading.rs`, `guiding.rs`, `meridian_gate.rs`, `pointing_gate.rs`, `rotator.rs`,
`save_path.rs`, `script.rs`, `slew.rs`, `wait_time.rs`.
