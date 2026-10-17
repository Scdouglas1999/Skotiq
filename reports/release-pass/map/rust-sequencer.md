# Release-pass map — Rust sequencer crate

Subsystem: `native/skotiq_native/sequencer/`
Mapped: 2026-08-11. Read-only pass; no source file was modified.

Scope note: the brief named five files. I measured every `.rs` under `sequencer/src/`
and applied the >1500-line Rust threshold to all of them, then separated production
lines from `#[cfg(test)]` lines because several files are mostly tests.

## Measured sizes (verified with `wc -l`)

| File | total | first `#[cfg(test)]` | production lines | oversized? |
|---|---:|---:|---:|---|
| `src/instructions.rs` | 11732 | 8080 | ~8079 | **yes** |
| `src/executor/mod.rs` | 11172 | 8022 | ~8021 | **yes** |
| `src/triggers.rs` | 4519 | 2379 | ~2378 | **yes** |
| `src/lib.rs` | 3152 | 2987 | ~2986 | **yes** |
| `src/meridian_flip_executor.rs` | 3044 | 1690 | ~1689 | **yes** (marginal) |
| `src/device_ops.rs` | 2024 | 1327 | ~1326 | borderline |
| `src/node/logic/target_scheduler.rs` | 1784 | 751 | ~750 | no |
| `src/checkpoint.rs` | 1578 | 923 | ~922 | no |
| `src/executor/scenario_sim_tests.rs` | 1322 | (all test) | 0 | no (test file) |

None of these are generated. There is no `frb_generated` / `*.g.*` output inside this
crate — the FRB codegen lives in `native/skotiq_native/bridge/`. Everything below
is hand-written.

The crate re-exports through `lib.rs` (`pub use instructions::*;`, `pub use executor::*;`,
`pub use triggers::*;`, …) and the bridge consumes types as `skotiq_sequencer::X`
(e.g. `bridge/src/sequencer_ops.rs:39`, `bridge/src/sequencer_api.rs:4`). **Every split
below keeps those `pub use` globs, so no bridge or FRB path changes.** That is the
single invariant an implementer must not break.

---

# 1. OVERSIZED FILES

## 1.1 `src/instructions.rs` — 11732 lines (8079 production, 3653 test) — risk: medium

### Why it is big
It is a flat file of ~25 independent instruction implementations, each already
separated by an ASCII banner comment. There is no shared state between the sections
beyond `InstructionContext`, `InstructionResult`, and a dozen `pub(crate)` helpers.
Adding one instruction has always meant appending another 300–1200 lines here.

### Existing section boundaries (banner comments, verbatim line numbers)

| lines | banner |
|---|---|
| 1–871 | (header) module doc, gating helpers, `InstructionResult` (409), `InstructionContext` (616) |
| 872–1376 | `SLEW INSTRUCTION` |
| 1377–1463 | `ROTATOR MOVE + VERIFY (shared by RotateToAngle instruction and centering)` |
| 1464–2125 | `CENTER INSTRUCTION (Plate Solve + Sync + Slew Loop)` |
| 2126–3133 | `EXPOSURE INSTRUCTION` |
| 3134–3826 | `IMAGE-GRADING HELPERS` + `DEFECT-MAP HELPERS` |
| 3827–4157 | `FRAME CONTEXT BUILDER` |
| 4158–5386 | `AUTOFOCUS INSTRUCTION` |
| 5387–5624 | `DITHER INSTRUCTION` |
| 5625–5984 | `GUIDING START/STOP INSTRUCTIONS` |
| 5985–6238 | `FILTER CHANGE INSTRUCTION` |
| 6239–6515 | `CAMERA COOLING/WARMING INSTRUCTIONS` |
| 6516–6579 | `ROTATOR INSTRUCTION` |
| 6580–6648 | `PARK/UNPARK INSTRUCTIONS` |
| 6649–6662 | `POLAR ALIGNMENT INSTRUCTION` |
| 6663–6936 | `WAIT TIME INSTRUCTION` (+ twilight solar math) |
| 6937–6986 | `DELAY INSTRUCTION` |
| 6987–7025 | `NOTIFICATION INSTRUCTION` |
| 7026–7218 | `SCRIPT INSTRUCTION` |
| 7219–7404 | `MERIDIAN FLIP INSTRUCTION` |
| 7405–7701 | `DOME INSTRUCTIONS` |
| 7702–7717 | `MOSAIC INSTRUCTION` |
| 7718–8075 | `COVER CALIBRATOR INSTRUCTIONS` |
| 8076–11732 | `TESTS` |

### Split plan
Convert `instructions.rs` → `instructions/mod.rs`. `mod.rs` keeps **only**:
the module doc, the `mod X; pub use X::*;` list, and nothing else. Every existing
public path (`crate::instructions::execute_slew`, …) and the `pub use instructions::*;`
glob in `lib.rs:69` survive unchanged.

New files under `src/instructions/`:

| new file | moves in (line ranges from today's `instructions.rs`) | visibility notes |
|---|---|---|
| `context.rs` | 409–553 (`InstructionResult` + impl), 616–871 (`InstructionContext` + impl) | both stay `pub` |
| `gating.rs` | 69–408: `unset_target_pointing_reason`, `frame_type_requires_darkness`, `daylight_gate_block_reason`, `validate_exposure_filter_request`, `resolve_max_sun_altitude`, `observed_wheel_filter`, `wheel_filter_name_at`, `wheel_filter_index_of`, `resolve_burst_filter`, `resolve_frame_filter`, `DEFAULT_MAX_SUN_ALTITUDE_DEGREES` | keep `pub(crate)`; `DEFAULT_MAX_SUN_ALTITUDE_DEGREES` stays `pub` (read by `node/context.rs:650`) |
| `disconnect.rs` | 554–615: `is_device_disconnected_message`, `request_device_disconnected_recovery` | `pub(crate)` |
| `wait.rs` | 1093–1375: `wait_for_mount_idle_with_progress`, `wait_for_focuser_idle`, `wait_for_focuser_stop_after_halt`, `wait_for_filterwheel_idle`, `wait_for_cancellation` | `pub(crate)`; `wait_for_focuser_stop_after_halt` stays `pub` |
| `save_path.rs` | 1290–1367: `claim_save_path`, `ensure_unique_save_path` | `pub(crate)` |
| `slew.rs` | 872–1092: `SLEW_POSITION_TOLERANCE_DEG`, `normalize_ra_diff_hours`, `validate_slew_position`, `execute_slew` | delete the local `normalize_ra_diff_hours` — see D1 |
| `rotator.rs` | 1377–1463 (`normalize_rotator_angle`, `rotator_angle_diff`, `rotator_move_to_verified`) + 6516–6579 (`execute_rotator_move`) | one file for the shared helper and the instruction that uses it |
| `center.rs` | 1464–2125 (`wait_for_centering_correction_slew`, `execute_center`, `apply_center_rotation`, `wait_for_meridian_flip_window`, `current_target_hour_angle`, `calculate_separation_arcsec`) | |
| `expose.rs` | 2126–3133 (`CameraExposureAbortGuard`, `BurstControl`, `execute_exposure`, `execute_exposure_with_renderer`) | name it `expose_impl.rs` if the sibling `node/instructions/expose.rs` causes confusion |
| `grading.rs` | 3134–3826 (`DefectMapOutcome`, `resolve_reject_dir`, `apply_defect_map_if_configured`, `save_uncorrected_raw_frame`, `build_environment_snapshot`, `push_forensic_sample`, `emit_grade_progress`) | `resolve_reject_dir` stays `pub` |
| `frame_context.rs` | 3827–4157 (`build_frame_context_for_save`) | |
| `autofocus.rs` | 4158–5386 (`AutofocusRunGuard`, `try_admit_autofocus_run`, all `execute_autofocus*`, `validate_autofocus_config`, `HfrMeasurementWithCrops`, `StarCropInfo`, `calculate_hfr_with_crops`, `restore_autofocus_origin`, `wait_for_autofocus_settle`) | biggest new file at ~1230 lines — acceptable, it is one cohesive state machine |
| `dither.rs` | 5387–5624 (`execute_dither`, `dither_guarded`) | |
| `guiding.rs` | 5625–5984 (`GuiderStartupCleanupGuard`, `execute_start_guiding`, `validate_calibration_quality`, `execute_stop_guiding`) | |
| `filter.rs` | 5985–6238 (`execute_filter_change`, `apply_filter_focus_offset`) | |
| `cooling.rs` | 6239–6515 (`execute_cool_camera`, `execute_warm_camera`) | |
| `park.rs` | 6580–6648 (`execute_park`, `execute_unpark`) | |
| `polar_align.rs` | 6649–6662 (`execute_polar_alignment`) | thin wrapper over `crate::polar_align` |
| `wait_time.rs` | 6663–6936 (`execute_wait_time`, `calculate_twilight_time`, `build_utc_naive_time_or_fallback`, `calculate_solar_position`) | see D2/D3 before moving — the solar math should not stay here long-term |
| `delay.rs` | 6937–6986 | |
| `notification.rs` | 6987–7025 | |
| `script.rs` | 7026–7218 (`execute_script`, `kill_script_process_group`, `enum Abort`) | |
| `meridian_flip.rs` | 7219–7404 (`execute_meridian_flip`, `execute_meridian_flip_with_autofocus`) | see D4 |
| `dome.rs` | 7405–7701 (`DomeShutterWaitOutcome`, `wait_for_dome_shutter_state`, `execute_open_dome`, `execute_close_dome`, `execute_park_dome`) | |
| `mosaic.rs` | 7702–7717 (`execute_mosaic`) | thin wrapper over `crate::mosaic` |
| `cover_calibrator.rs` | 7718–8075 (`execute_open_cover`, `execute_close_cover`, `execute_calibrator_on`, `execute_calibrator_off`, `wait_for_cover_state`, `wait_for_calibrator_state`) | |
| `testing.rs` | 8543–9136 (`ScriptedDomeRotatorOps` + its `DeviceOps` impl), 9137–9160 (`ctx_with_ops`), 10442–10460 (`ScratchDir`) | whole file behind `#![cfg(test)]`, items `pub(crate)` |

Tests (8080–11732) move **with the code they exercise**: each new file grows its own
`#[cfg(test)] mod tests { use super::*; use crate::instructions::testing::*; … }`.
This is the highest-effort part of the split (~3650 lines to re-home) and the only
place a mistake can silently drop coverage. Mitigation for the implementer: after the
move, `cargo test -p skotiq_sequencer -- --list | wc -l` must match the
pre-split count exactly.

Effort: **large**. Behaviour-preserving: yes — pure code motion plus visibility
adjustments; no signature changes.

---

## 1.2 `src/executor/mod.rs` — 11172 lines (8021 production, 3151 test) — risk: **high**

### Why it is big — the real headline
`SequenceExecutor::start()` is **one function spanning lines 2781–7976 — 5196 lines**.
I verified this: between 2781 and 7978 there is exactly one line matching `^    }`
(at 7976, the closing brace) and exactly one nested `fn` (a closure at 3635). The
crate already has a healthy `executor/` submodule convention — `setup.rs`,
`lifecycle.rs`, `loading.rs`, `recovery.rs`, `decision.rs`, `checkpoint.rs`,
`runtime_config.rs`, each with a doc header stating its axis — and `start()` is the
one thing that was never carved out of it.

Inner structure of `start()` (verified line ranges):

| lines | block |
|---|---|
| 2781–3316 | preflight + per-run priming (recycle-from-terminal, device_ops check, save-path preflight, device preflight, unreachable-instruction preflight, plate-solve preflight, trigger hygiene, autofocus seeding, node/target metadata build, runtime-config seed, recovery/decision handle cloning) |
| 3317 | `tokio::spawn(async move { … })` — closes at 7973 |
| 3318–7940 | `let executor_future = async move { … }` (supervised by `AssertUnwindSafe(...).catch_unwind()` at 7948) |
| 3319–3633 | `ExecutionContext` construction + ~60 `let x_for_y = ….clone();` handle clones |
| 3634–3953 | `context.progress_callback` closure — 320 lines |
| 3961–4647 | `let command_handler = async { … }` — 687 lines, 28 `ExecutorCommand` arms |
| 4684–4691 | `let execution = async { … }` (thin) |
| 4723–4822 | `let streaming_checkpoint_task = async move { … }` |
| 4891–5388 | `let recovery_driver = async move { … }` — 498 lines |
| 5394–7689 | `let trigger_monitor = async { … }` — **2296 lines** |
| ├ 5443–6027 | per-tick poll phase |
| └ 6028–7685 | `for (trigger_id, trigger_name, action) in fired_with_names` — 1658 lines, 14 `RecoveryAction` arms |
| 7690–7976 | `tokio::pin!` + `select!` join, in-flight quiesce, terminal-result coercion, finalization |

The rest of the file (64–2650) is free helpers, config structs, `ExecutorCommand`
(1169), `ExecutorState` (1389), `SequenceProgress` (1407), `ExecutorEvent` (1472),
trigger-context builders (1650–2001), and the `SequenceExecutor` struct (2547).

### Split plan
The mechanical obstacle is that every extracted async block captures 40–80 locals by
move. Solve it once, then the rest is code motion:

**Step 0 (enabling change).** Add `src/executor/run_handles.rs` defining plain
handle-bundle structs built once in `start()` and passed by value into each extracted
task. Suggested grouping, taken from today's `let *_for_*` clones at 3319–3633 and
4693–4890:

```
pub(super) struct RunCore     // event_tx, state, progress, is_cancelled, is_paused,
                              // resume_notify, runtime_config, trigger_manager, device_ops
pub(super) struct RunSignals  // skip_to_next_target, skip_to_node, recovery_signals,
                              // recovery_generation, park_and_abort_in_progress,
                              // execution_quiesced_{tx,rx}, park_and_abort_done_{tx,rx}
pub(super) struct RunDevices  // camera/mount/focuser/filterwheel/rotator/dome/cover ids,
                              // save_path, latitude, longitude, filter_focus_offsets
pub(super) struct RunDecision // decision_tx, active_run_id, current_recovery, recovery_history
pub(super) struct RunPersist  // checkpoint_manager, sequence, budget_registry,
                              // smart_exposure_states, triggers_enabled
```
Each struct derives `Clone` (all fields are `Arc`/`Option<String>`/`f64`), so the
per-task `.clone()` ceremony collapses from ~60 lines to 5.

**Step 1–6 (pure moves).** New files under `src/executor/`:

| new file | moves in | signature |
|---|---|---|
| `preflight.rs` | 781–1168 (`find_first_autofocus_config`, `tree_contains_centering`, `tree_needs_base_save_path`, `collect_required_devices`, `validate_required_devices`, `device_refusal`, `unreachable_instructions`, `collect_subtree_names`, `last_instruction_failure`, `unreachable_instructions_message`, `validate_capture_save_path`) **plus** the preflight prologue at 2781–3050 | `pub(super) fn run_preflight(&self) -> Result<PreflightOutcome, String>` — returns the resolved metadata maps + warnings so `start()` stays declarative |
| `commands.rs` | 3961–4647 verbatim | `pub(super) async fn command_handler(core: RunCore, signals: RunSignals, …) ` |
| `progress.rs` | 3634–3953 (the `progress_callback` closure) | `pub(super) fn build_progress_callback(core: RunCore, meta: NodeMetadata) -> Arc<dyn Fn(ProgressUpdate) + Send + Sync>` |
| `checkpoint_stream.rs` | 4723–4822 | `pub(super) async fn streaming_checkpoint_task(core: RunCore, persist: RunPersist, devices: RunDevices)` |
| `recovery_driver.rs` | 4891–5388 | `pub(super) async fn recovery_driver(core: RunCore, decision: RunDecision, …)` |
| `trigger_monitor/mod.rs` | 5394–6027 (poll phase) | `pub(super) async fn trigger_monitor(...) -> Vec<(String, RecoveryAction)>` |
| `trigger_monitor/poll.rs` | the eight device-poll blocks at 5476–6001, one `async fn` per device family (`poll_safety`, `poll_weather`, `poll_mount`, `poll_focuser`, `poll_dome`, `poll_guider`, `refresh_dawn`, `refresh_altitude`) | each takes `&SharedDeviceOps` + `&mut TriggerState`; this is where the perf fixes P1/P2 land naturally |
| `trigger_monitor/actions.rs` | 6028–7685 — the 14 `RecoveryAction` arms, one `async fn` each (`act_pause`, `act_park_and_abort`, `act_next_target`, `act_autofocus`, `act_retry`, `act_meridian_flip`, `act_dither`, `act_recenter`, `act_pause_and_wait_for_clear`, `act_slew_to_gap`, `act_switch_target_or_filter`, `act_continue`, `act_custom_branch`) | all take a shared `TriggerActionEnv` (which absorbs D5's repeated 4-tuple snapshot) |
| `finalize.rs` | 7690–7976 (select! join, quiesce loop, terminal coercion, `match result` finalization) | `pub(super) async fn join_and_finalize(...) -> ()` |

After this `start()` is ~150 lines: preflight → build handles → spawn → `try_join!`/
`select!` → finalize. `mod.rs` retains the types (`ExecutorCommand`, `ExecutorState`,
`SequenceProgress`, `ExecutorEvent`, `RuntimeConfig`, `ObserverProfile`,
`DefectMapApplyState`, `SequenceExecutor`), the free verdict helpers at 64–573, the
trigger-context builders at 1650–2001, and `get_executor()`.

Tests at 8022–11172 split the same way: the `RecoveryAction`/recovery tests
(10237–10726) go to `recovery_driver.rs` / `trigger_monitor/actions.rs`; the
start-refusal tests (8453–9109) go to `preflight.rs`; the `update_*` tests
(9959–10072) go to `runtime_config.rs`'s existing test module. `ReacquireGuiderOps`
(10860–11142) becomes `executor/testing.rs` (`#![cfg(test)]`).

Effort: **large**. This is the single highest-value structural item in the crate:
five of the six reliability findings below live inside `start()` and are currently
un-unit-testable because there is no seam to call.

---

## 1.3 `src/triggers.rs` — 4519 lines (2378 production) — risk: low

### Why it is big
Three unrelated concerns in one file, and one of them is a 568-line match:
`Trigger` + `Trigger::check` (146–860), `TriggerState` (927–1899, 62 fields and 50
mutator methods), `TriggerManager` (1900–2372).

`Trigger::check` (293–860) is a single `match self.trigger_type` with **20 arms**
(`HfrDegraded` 299, `MeridianFlip` 366, `GuidingFailed` 502, `AltitudeLimit` 536,
`WeatherUnsafe` 543, `TemperatureShift` 583, `FilterChange` 592, `DawnApproaching` 593,
`AutofocusInterval` 610, `DitherInterval` 620, `MountTrackingLost` 630,
`DomeShutterNotOpen` 655, `GuideStarLost` 663, `FocusDrift` 669, `HumidityThreshold` 730,
`DriftLimit` 736, `CloudArrivingIn` 750, `CloudOpeningIn` 774, `CloudCoverThreshold` 798,
`TransparencyDropped` 825).

### Split plan
`triggers.rs` → `triggers/mod.rs` (declarations + `pub use` only; `lib.rs:81`'s
`pub use triggers::*;` is unchanged).

| new file | moves in |
|---|---|
| `trigger.rs` | 18–33 (constants), 35–68 (`clamp_focus_drift_window`), 146–292 (`Trigger`, `TriggerClampWarning`, `new`, `new_focus_drift_checked`, `with_cooldown`, `is_in_cooldown`), and `check` reduced to a 20-line dispatch |
| `evaluators.rs` | the 20 match arms, one `fn eval_<name>(state: &TriggerState, …) -> bool` each; `check` becomes `match &self.trigger_type { TriggerType::HfrDegraded{..} => eval_hfr_degraded(state, ..), … }` |
| `state.rs` | 83–145 (`looks_like_tracking_limit_hit`), 927–1899 (`TriggerState`, `Default`, the 50 mutators) |
| `manager.rs` | 1900–2377 (`TriggerManager`, `check_all`, `sync_state_from_config`, `create_standard_triggers`, `Default`) |
| `dawn.rs` | 69–82 (`build_utc_naive_time_or_fallback`) + 855–927 (`calculate_dawn_time`) — **and see D2/D3: this should instead delegate to a single shared solar module** |

Tests at 2379–4519 follow their subjects. Effort: **medium**.

---

## 1.4 `src/lib.rs` — 3152 lines (2986 production) — risk: low

### Why it is big
Lines 1–100 are the real crate root (module decls + re-exports). Lines 100–2986 are a
flat dump of ~60 serde config structs, their `Default` impls, and ~45 `fn default_*()`
serde helpers: `SciencePhotometryConfig` (361), `PhotometryQualityGates` (495),
`LiveStackingConfig` (703), `SmartExposureConfig` (815), `FilterPlan` (893),
`TargetSchedulerConfig` (1044), `TargetHeaderConfig` (1231), `IntegrationBudget` (1361),
`MosaicConfig` (1581), `FlatWizardConfig` (1615), `LoopConfig` (1713),
`ConditionalConfig` (1752), `SlewConfig` (1793), `CenterConfig` (1810),
`ExposureConfig` (1835), `AutofocusConfig` (1964), `DitherConfig` (2214),
`StartGuidingConfig` (2248), `CoolConfig` (2317), `WarmConfig` (2332),
`RotatorConfig` (2364), `WaitTimeConfig` (2379), `DelayConfig` (2392),
`NotificationConfig` (2403), `ScriptConfig` (2425), `MeridianFlipConfig` (2453),
`DomeConfig` (2604), `CoverCalibratorConfig` (2610), `CalibratorOnConfig` (2622),
plus the `NodeType` (189) / `LoopCondition` (2645) / `ConditionalCheck` (2688) /
`TriggerType` (2709) enums.

### Split plan
Create `src/config/` and keep `lib.rs` at ~180 lines (module decls, `pub use` globs,
`SafetyFailMode`, `NodeStatus`, `SequenceDefinition`, `NodeDefinition`, `NodeType`).

| new file | moves in |
|---|---|
| `config/mod.rs` | `pub use` of every submodule below; `lib.rs` gains `mod config; pub use config::*;` so all existing `skotiq_sequencer::ExposureConfig` paths hold |
| `config/capture.rs` | 1835–1962 (`ExposureConfig`, `Binning`), 2214–2247 (`DitherConfig`, `DitherPattern`), 2305–2363 (`FilterConfig`, `CoolConfig`, `WarmConfig`), 2364–2402 (`RotatorConfig`, `WaitTimeConfig`, `TwilightType`, `DelayConfig`) |
| `config/autofocus.rs` | 1936–2213 (`AutofocusFilterConfig`, `AutofocusConfig`, `AutofocusFailureAction`, `AutofocusMethod`, the 16 `default_af_*` fns, `From<&AutofocusConfig>`) |
| `config/guiding.rs` | 2248–2304 (`StartGuidingConfig` + defaults) |
| `config/meridian.rs` | 2433–2603 (`MeridianTriggerMethod`, `FlipFailureAction`, `MeridianFlipConfig`, its `pub(crate)` defaults, `Default`) |
| `config/scheduling.rs` | 972–1209 (`FilterCycleMode`, `TargetSchedulerConfig`, the 9 `default_scheduler_*`), 1231–1576 (`TargetHeaderConfig`, `IntegrationBudget`, `FilterBudgetEntry`) |
| `config/smart_exposure.rs` | 800–971 (`SmartExposureConfig`, `FilterPlan`, `SmartExposureCheckpoint`, `smart_exposure_checkpoint_key`) |
| `config/science.rs` | 348–637 (`SciencePhotometryConfig`, `PhotometryQualityGates`, `PhotometryFrameVerdict`) |
| `config/live_stacking.rs` | 638–799 (`StackMethod`, `LiveStackingMode`, `LiveStackingConfig`) |
| `config/wizards.rs` | 1214–1230 (`MosaicPanelInfo`), 1577–1687 (`MosaicConfig`, `FlatWizardConfig`, `PanelLocation`) |
| `config/flow.rs` | 1688–1834 (`ExposureTrigger`, `TriggerCondition`, `TriggerAction`, `LoopConfig`, `ParallelConfig`, `ConditionalConfig`, `RecoveryConfig`, `SlewConfig`, `CenterConfig`), 2604–2644 (`DomeConfig`, `CoverCalibratorConfig`, `CalibratorOnConfig`), 2645–2708 (`LoopCondition`, `ConditionalCheck`) |
| `config/triggers.rs` | 2709–2986 (`TriggerType` + `default_*` for it) — note this is the *definition*; `src/triggers.rs` holds the evaluator |

Effort: **medium**, low risk — these are data types with derives, no logic moves.

---

## 1.5 `src/meridian_flip_executor.rs` — 3044 lines (1689 production) — risk: low

### Why it is big
`MeridianFlipExecutor::execute` is 188–584 (~397 lines) and the eight step
implementations (696–1367) are all in the same `impl`.

### Split plan
`meridian_flip_executor.rs` → `meridian_flip_executor/mod.rs`
(`FlipResult`, `PostFlipAutofocusConfig`, `FlipContext`, `MeridianFlipExecutor` struct,
`new`/`attempts_made`/`failed_attempts`/`with_event_channel`/`with_executor_event_tx`/
`abort_handle`/`execute`/`build_step_sequence`/`execute_steps`).

| new file | moves in |
|---|---|
| `steps.rs` | 696–1367: `pause_guider`, `stop_tracking`, `slew_to_target`, `verify_pier_side_changed`, `resume_tracking`, `plate_solve_and_center`, `resolve_post_flip_autofocus`, `run_autofocus`, `resume_guider`, `wait_settle` — as `impl MeridianFlipExecutor` in a second file |
| `safing.rs` | 1442–1652: `restore_tracking_on_cancel`, `execute_failure_action`, `retry_safety_action` |
| `util.rs` | 1372–1441 (`get_pier_side`, `calculate_hour_angle`, `is_cancelled`), 1653–1690 (`emit_event`, `format_failure_action`) — **delete `normalize_ra_diff_hours` at 1680, see D1** |

Effort: **small**. Rust allows multiple `impl` blocks for the same type across files
in the same module tree, so this is a straight cut.

---

## 1.6 `src/device_ops.rs` — 2024 lines (1326 production) — risk: low

Borderline: production is under 1500, but the `DeviceOps` trait (93–589) declares
**123 async methods** and `NullDeviceOps` (593–1053) is a 460-line stub that must
mirror all of them. Every trait addition costs two edits here and one in each of the
two bridge impls.

Optional split (do only if touching it anyway): `device_ops/mod.rs` (types +
`SharedDeviceOps` + `is_no_guider_configured`), `device_ops/trait_def.rs` (the trait,
possibly segmented into `MountOps`/`CameraOps`/`FocuserOps`/`FilterWheelOps`/
`RotatorOps`/`GuiderOps`/`DomeOps`/`CoverCalibratorOps`/`SolverOps` supertraits with
`DeviceOps: MountOps + …`), `device_ops/null.rs` (`NullDeviceOps`),
`device_ops/park.rs` (1054–1326: `ParkRetryResult`, `SafeStateOutcome`).
Splitting into supertraits is **not** behaviour-preserving for external impls (the two
bridge impls would need `impl MountOps for X` blocks), so treat that as a separate,
larger work item. Effort: **medium**.

---

# 2. DUPLICATION

## D1 — `normalize_ra_diff_hours` implemented twice, byte-identical
`src/instructions.rs:881` and `src/meridian_flip_executor.rs:1680`. Same body
(`diff % 24.0`, wrap at ±12). **Canonical survivor:** move it to
`src/meridian.rs` as `pub fn normalize_ra_diff_hours` — that module already owns
`julian_day`, `local_sidereal_time`, `hour_angle`, and both callers already depend on
it. Delete both local copies; both call sites become `crate::meridian::normalize_ra_diff_hours`.
Effort: **small**.

## D2 — `build_utc_naive_time_or_fallback` implemented twice, byte-identical
`src/instructions.rs:6882` and `src/triggers.rs:69`. Identical three-line chain
(`and_hms_opt` → fallback tuple → `NaiveTime::MIN`); `triggers.rs`'s own comment says
"same pattern as instructions.rs equivalent". **Canonical survivor:** one
`pub(crate) fn` in the new shared solar module from D3 (or `src/meridian.rs` if D3 is
deferred). Effort: **small**.

## D3 — Three independent solar-position implementations that disagree
The crate answers "where is the Sun" three different ways:

1. `src/node/context.rs:1295` `current_sun_altitude_degrees` + `:1313`
   `approximate_sun_equatorial_coords` — full mean-longitude/mean-anomaly series →
   RA/Dec → hour angle → altitude. Most accurate. Used by the daylight START gate
   (`instructions.rs:137`).
2. `src/instructions.rs:6810` `calculate_twilight_time` + `:6901`
   `calculate_solar_position` — declination series **plus equation of time**. Used by
   the `WaitTime` twilight instruction.
3. `src/triggers.rs:861` `calculate_dawn_time` — Cooper's equation for declination and
   **no equation-of-time term at all** (`solar_noon_utc = 12.0 - longitude / 15.0`,
   line 899). Used by the `DawnApproaching` trigger.

(2) and (3) compute the same physical quantity — the instant the Sun reaches −18° —
and will disagree by the omitted equation of time (±16 min across the year) plus the
Cooper-vs-series declination error. Consequence: "wait until astronomical dark" and
"stop at dawn" are calibrated against different suns.

**Canonical survivor:** a new `src/solar.rs` exporting
`sun_equatorial(jd) -> (ra_hours, dec_deg)`, `sun_altitude_degrees(lat, lon, at) -> f64`,
and `time_of_sun_altitude(lat, lon, altitude_deg, direction) -> Option<i64>` built on
implementation (1). `calculate_twilight_time` and `calculate_dawn_time` both become
thin callers; `calculate_solar_position` and `approximate_sun_equatorial_coords` are
deleted. This is the one duplication item with a correctness consequence, so it needs
a before/after table of dawn/twilight timestamps at several latitudes and dates as its
acceptance evidence. Effort: **medium**.

## D4 — Meridian flip has two call paths that emit different events
Both paths converge on `MeridianFlipExecutor::execute`, but:
* trigger path (`src/executor/mod.rs:6711`–6989) emits
  `ExecutorEvent::MeridianFlipOutcome` on success (6776), failure (6810) and the
  park-and-abort escalation (6956), and snapshots `attempts_made()` / `failed_attempts()`.
* instruction path (`src/instructions.rs:7249` `execute_meridian_flip_with_autofocus`,
  result handling at 7367–7401) emits **nothing** — it only returns an
  `InstructionResult`.

`MeridianFlipOutcome` is what the bridge maps to `SequencerEvent::MeridianFlipOutcome`
(`bridge/src/api/sequencer.rs:823`) and what Dart renders
(`packages/skotiq_bridge/lib/src/event_display.dart:386`). So a sequence that
flips via an **explicit MeridianFlip node** reports no flip at all.

**Canonical survivor:** move the outcome-event emission *into*
`MeridianFlipExecutor::execute` (it already owns `executor_event_tx` — see
`meridian_flip_executor.rs:177 with_executor_event_tx`, and `instructions.rs:7362`
already wires it). Both call sites then shrink to result mapping. Effort: **medium**.

## D5 — Copy-pasted ceremony inside the trigger monitor
Two shapes, both in `src/executor/mod.rs`:

* `let (target_name, target_ra, target_dec, current_filter) = { let ts = trigger_state_for_actions.read().await; (…, ts.target_ra.map(|ra| ra / 15.0), …) };`
  at 6357–6368, 6716–6731, 7037–7047, 7111–7121 (4×).
* `let manager = trigger_manager.read().await; let trigger_state = manager.state(); let mut state = trigger_state.write().await;`
  at 4103, 4135, 4337, 4395, 4467, 5591, 5798, 5916, 5945, 5964, 6024 (11×).

**Canonical survivor:** two helpers in the new `executor/trigger_monitor/mod.rs` —
`async fn snapshot_target(state: &Arc<RwLock<TriggerState>>) -> TargetSnapshot` and
`async fn with_trigger_state<R>(mgr: &Arc<RwLock<TriggerManager>>, f: impl FnOnce(&mut TriggerState) -> R) -> R`.
Fold this into the 1.2 split rather than doing it separately. Effort: **small**
(once 1.2 lands).

## D6 — Runtime-config mutation implemented twice, and four arms are unreachable
`src/executor/runtime_config.rs` (690 lines, 20 `update_*` methods) and the
`ExecutorCommand::Update*` arms inside `start()`'s command handler
(`src/executor/mod.rs:4063`–4600, ~540 lines) implement the same writes. The file's own
doc header (runtime_config.rs:1–20) states the contract as "write through
`self.runtime_config`, then forward the matching `ExecutorCommand` if running".

Four commands have **no sender anywhere in the workspace** (see DC1) — including
`UpdateLocation`, whose arm is the only code that pushes location into the live
`TriggerState` (see R2).

**Canonical survivor:** `executor/runtime_config.rs`. Every `update_*` must actually
follow the documented two-step contract; the command arms then become one-line
delegations to a shared `apply_runtime_update(&mut RuntimeConfig, RuntimeUpdate)`
enum-applier so the "what" string and the write can never drift. Effort: **medium**.

## D7 — Legacy vs renderer-based frame naming; the "test-only" legacy path has a production caller
`src/instructions.rs:2209` `execute_exposure` calls
`execute_exposure_with_renderer(..., None, ...)`. The `None` branch
(`instructions.rs:2756`) falls back to the hardcoded `<target>_<filter>_<NNNN>.fits`
layout, and its comment says *"When no renderer is supplied (legacy direct invocations
from **tests**)"*.

It is not tests-only. Grepping `execute_exposure(` across `native/` gives exactly one
non-test caller: **`src/flat_wizard/mod.rs:325`** (the file's `#[cfg(test)]` starts at
570, so this is production). Flat frames therefore ignore the user's configured
save-path template and land under the legacy naming scheme, unlike every other frame
in the session.

**Canonical survivor:** `execute_exposure_with_renderer`. Give the flat wizard a
`FrameSavePathRenderer` (same construction as `node/instructions/expose.rs:221`), then
either delete `execute_exposure` or mark it `#[cfg(test)]`. Effort: **small**.

## Suspected cross-package duplication (for the cross-cutting agent)
* `julian_day` is reimplemented in `bridge/src/sequencer_ops.rs:1579` and
  `bridge/src/unified_device_ops.rs:1883` while `sequencer/src/meridian.rs:259` is
  canonical — and `bridge/src/sequencer_ops.rs:2146` already calls the canonical one.
* Angular separation exists four times across `native/`:
  `sequencer/src/instructions.rs:2110` (haversine, arcsec),
  `sequencer/src/scheduling/astronomy.rs:131` (law of cosines, deg),
  `bridge/src/api/difference_image.rs:411`, `bridge/src/api/devices/simulation.rs:673`.
* `sequencer/src/scheduling/astronomy.rs` is documented (lines 1–12) as a
  byte-for-byte port of `packages/skotiq_planetarium/lib/src/astronomy/astronomy_calculations.dart`
  — whole-file cross-language duplication, deliberate, but the parity test needs auditing.
* Sun/twilight math (D3) also exists in Dart:
  `packages/skotiq_planetarium/lib/src/astronomy/observability.dart` and
  `astronomy_calculations.dart` — a fourth and fifth answer to the same question.
* The 123-method `DeviceOps` trait (`sequencer/src/device_ops.rs:93`) is implemented in
  full three times: `NullDeviceOps` (same file, 593), `bridge/src/sequencer_ops.rs`,
  `bridge/src/unified_device_ops.rs` — plus a 330-line test double in
  `instructions.rs:8809`.
* `SmartExposureCheckpoint` / `SessionCheckpoint` shapes are mirrored on the Dart side
  for resume UI; worth checking against `packages/skotiq_core` sequence models.

---

# 3. DEAD CODE

## DC1 — Four `ExecutorCommand` variants have no sender
`ExecutorCommand::Start`, `::UpdateDitherConfig`, `::UpdateFilterOffsets`,
`::UpdateLocation`.

Evidence: `grep -rn "ExecutorCommand::<V>" native/skotiq_native/{sequencer,bridge}/src`
returns exactly one hit for each — the match arm itself:
`Start` → `executor/mod.rs:4031`; `UpdateDitherConfig` → `:4063`;
`UpdateLocation` → `:4089`; `UpdateFilterOffsets` → `:4149`.
For contrast, every live variant has ≥2 hits (`UpdateObserverProfile` →
`runtime_config.rs:577` sender + `mod.rs:4194` arm; `UpdateRejectFolderPath` →
`runtime_config.rs:549` + `mod.rs:4182`).

The corresponding setters (`runtime_config.rs:195 update_dither_config`,
`:229 update_location`, `:381 update_filter_offsets`) write `runtime_config` directly
and never call `command_tx.send`. **Do not just delete the arms** — the `UpdateLocation`
arm is the only writer of live `TriggerState::observer_latitude/longitude`
(`mod.rs:4106–4107`); deleting it without wiring the sender makes R2 permanent.
Correct disposition: wire the three `Update*` senders (closing R2), delete
`ExecutorCommand::Start` and its arm.

## DC2 — `CheckpointManager`'s per-node SmartExposure slot API is test-only
`src/checkpoint.rs:838 save_smart_exposure_state`, `:862 load_smart_exposure_state`,
`:872 clear_smart_exposure_state`.

Evidence: `grep -rn "save_smart_exposure_state\|load_smart_exposure_state\|clear_smart_exposure_state" native/`
(excluding `target/`) → definitions plus `checkpoint.rs:1501/1505/1522/1523`, all inside
the `#[cfg(test)]` module that starts at `checkpoint.rs:923`. The production
SmartExposure path is `node/instructions/smart_exposure.rs:622 save_checkpoint`, which
only mutates the in-memory `context.smart_exposure_states` map; persistence happens
via the whole-map snapshot in the streaming task
(`executor/mod.rs:4808–4811 checkpoint.smart_exposure_states = …clone()`).

## DC3 — `smart_exposure_checkpoint_key` result is discarded at its only production call
`src/lib.rs:968 pub fn smart_exposure_checkpoint_key`.

Evidence: three call sites — `node/instructions/smart_exposure.rs:636`
(`let _ = smart_exposure_checkpoint_key(&node_id.to_string());`, result thrown away,
preceded by a comment describing it as future work) and `:866/:867` inside
`#[cfg(test)]`. No bridge caller (`grep -rn smart_exposure_checkpoint_key native/` finds
nothing outside the sequencer). Same cluster as DC2 — either finish the per-node
persistence or delete the key helper and the three `CheckpointManager` methods.

## DC4 — `SessionWizardCheckpointSink` (and the wizard slot API behind it) is only ever constructed in tests
`src/checkpoint.rs:890 SessionWizardCheckpointSink`, reachable-only-through-it:
`:786 save_wizard_state`, `:809 load_wizard_state`, `:817 clear_wizard_state`.

Evidence: `grep -rn "SessionWizardCheckpointSink::new" native/` (excluding `target/`)
returns exactly two hits — `checkpoint.rs:1260` and `mosaic/mod.rs:524`, both inside
`#[cfg(test)]` blocks (`checkpoint.rs` tests start at 923, `mosaic/mod.rs` tests at 291).
The production mosaic entry point `mosaic/mod.rs:218 run_mosaic_wizard` uses
`let sink = NullCheckpointSink;` at `:223`. `polar_align/mod.rs:552` and
`all_sky_polar/mod.rs:452` likewise use `NullCheckpointSink`.

This one is not merely dead — the test at `mosaic/mod.rs:461–471` documents
`SessionWizardCheckpointSink` as *"the production path"*, which is false. See R5.

## Explicitly NOT dead (checked, so nobody re-flags them)
* All 21 `ExecutorEvent` variants have a producer inside the crate and a consumer in
  `bridge/src/api/sequencer.rs` — including `TargetStarted` (produced at
  `executor/mod.rs:3697`), which a previous audit found producer-less.
* `pub fn get_executor()` (`executor/mod.rs:7989`) is the bridge's only handle
  (`bridge/src/sequencer_api.rs:4`).
* `NullDeviceOps` (`device_ops.rs:593`) is used in production at
  `bridge/src/sequencer_api.rs:183`.
* `resolve_reject_dir`, `validate_calibration_quality`, `try_admit_autofocus_run` all
  have non-test callers.

---

# 4. PERF RISKS

## P1 — `guider_get_status()` is called twice per 1-second trigger tick — impact: **medium**
`src/executor/mod.rs:5565` (`…guider_get_status().await.ok().map(|s| s.rms_total)`) and
`src/executor/mod.rs:5963` (`let guide_status = device_ops_for_triggers.guider_get_status().await;`).
Both are inside the same iteration of the `loop {` that starts at `:5443` and ticks on
`tokio::time::interval(Duration::from_secs(1))` (`:5402`). The first extracts
`rms_total`, the second extracts `is_guiding` — from the same `GuidingStatus` struct
(`device_ops.rs:67`). Over an eight-hour night that is ~28,800 redundant PHD2/guider
round-trips. Fix: one poll, both fields.

## P2 — Nine device round-trips per second, only two of which are cadence-gated — impact: **medium**
Per tick of the same loop, with a full rig connected:
`safety_is_safe` (:5496) and `weather_get_humidity` (:5579) are correctly gated behind
`should_poll_safety` (:5476, default `safety_check_interval`), but these are not:
`mount_is_tracking` (:5787), `mount_is_slewing` (:5789), `mount_is_parked` (:5791),
`mount_side_of_pier` (:5793), `mount_get_coordinates` (:5794),
`focuser_get_temperature` (:5906), `dome_get_shutter_status` (:5941),
`guider_get_status` (×2, see P1).

Five serial mount calls per second is meaningful on ASCOM (single-threaded apartment,
per-call COM marshalling) and on INDI. Focuser temperature in particular changes on
minute timescales — the `TemperatureShift` trigger's own threshold is in degrees.
Fix: give the mount block its own interval (2–5 s), and put focuser temperature and
dome shutter on the existing `safety_check_interval` cadence. Splitting these into
`executor/trigger_monitor/poll.rs` (see 1.2) is what makes the change reviewable.

## P3 — Synchronous `std::fs` checkpoint write on a tokio worker — impact: **low**
`src/executor/mod.rs:4813 checkpoint_mgr.save(&checkpoint)` runs inside the async
`streaming_checkpoint_task`; `src/checkpoint.rs:543 save` does
`create_dir_all` (:544) → `fs::copy` of the previous checkpoint (:554) →
`serde_json::to_string_pretty` → `fs::write` (:564) → `fs::rename` (:567), all blocking.
Cadence is 30 s (`mod.rs:4737`) and the file is small, so this is low impact — but on a
Pi with an SD card the `copy`+`write`+`rename` can stall a worker for tens of ms.
Fix: `tokio::task::spawn_blocking` around the `save` call, or make `save` async.
The same blocking `save` is reached from `executor/checkpoint.rs:219` inside
`pub async fn save_checkpoint`.

## P4 — Blocking `open()` loop in the per-frame save path — impact: **low**
`src/instructions.rs:2867 ensure_unique_save_path(save_dir.join(&filename))` runs once
per frame inside the exposure burst. `ensure_unique_save_path` (`:1298`) calls
`claim_save_path` (`:1290`, `OpenOptions::create_new`) and, on collision, loops
`suffix += 1` re-opening until it finds a free name — synchronous filesystem calls on
the async runtime, unbounded in the collision case. Common case is one call; a
re-run into a populated directory is O(existing frames) blocking opens per frame.
Fix: `spawn_blocking`, and/or seed `suffix` from the highest existing index instead of
scanning from 1.

## P5 — 100 ms busy-poll for cancellation — impact: **low**
`src/instructions.rs:1368 wait_for_cancellation` loops
`token.load(Relaxed)` / `sleep(100ms)`. It is `select!`ed against six long-running
instructions (`:1084`, `:1641`, `:1684`, `:1787`, `:2083`, `:2558`, `:7140`), so during
a multi-hour run several of these timers are always armed. Negligible CPU, but it also
caps cancellation latency at 100 ms per nesting level. Fix: back the cancel token with
a `tokio::sync::Notify` (the crate already has `resume_notify` as precedent) or a
`watch::Receiver`.

### Checked and NOT flagged
* `TriggerManager::check_all` clones the whole `TriggerState` per tick
  (`triggers.rs:2031`) — 62 fields, 5 heap allocations, ~300-entry RMS history. ~5 KB/s.
  Not worth reporting.
* No `tokio::sync` lock is held across an `.await` in the trigger monitor: the two
  long write-lock blocks (`mod.rs:5589–5762`, `:5798–5900`) contain no `.await` after
  the lock is taken (verified by line-scan). The comment at `:6000–6003` shows this was
  a deliberate design decision.
* `image_data.data.clone()` (`instructions.rs:2637`) is explicitly gated behind the
  user's `save_original` opt-in and documented as such.

---

# 5. RELIABILITY RISKS

## R1 — The safety monitor has no timeout on any device call, and nothing watches it for a stall — severity: **high**
`grep -n "tokio::time::timeout" src/executor/mod.rs` returns only `:10771` and `:10808`,
both inside the `#[cfg(test)]` module that starts at `:8022`. **No production device
call in the trigger monitor is wrapped in a timeout.** The bridge does not add one
either — `bridge/src/sequencer_ops.rs` has zero `tokio::time::timeout` occurrences, and
`mount_is_tracking` there (`:495`) is a bare `await` on `mount_get_status`.

The `select!` at `mod.rs:7706` explicitly handles the monitor *exiting*
(`_triggers = &mut trigger_monitor => { … "Safety monitoring (trigger monitor) exited
unexpectedly! Cancelling sequence" … }`, `:7728–7742`), and the comment at `:7690–7694`
states the fail-closed intent. But a **hung** driver call is not an exit: if
`mount_side_of_pier` or `dome_get_shutter_status` blocks (a documented real hazard on
this project's ASCOM path), the monitor's `loop` never reaches its next `tick()`, and
the `execution` branch keeps exposing with weather, altitude, drift, tracking-loss,
dome and meridian protection all silently gone. Nothing detects it and nothing reports it.

Fix: wrap each poll in `tokio::time::timeout` (a stalled poll is a poll *failure*,
which the existing `SafetyFailMode` ladder already knows how to handle), and add a
heartbeat `watch` the executor task checks — if the monitor has not ticked in
N × interval, treat it as the "exited unexpectedly" case at `:7728`.

## R2 — `update_location` never reaches the live trigger state, and its doc says it does — severity: **medium**
`src/executor/runtime_config.rs:229 update_location` writes `self.latitude/longitude`
and `runtime_config.latitude/longitude`, then emits `RuntimeConfigUpdated`. It does not
forward a command. Its doc comment (`:222–227`) claims: *"The trigger-monitor task reads
location from the trigger state, which is populated from `runtime_config` on each
iteration."*

That is not what happens. The only writers of `TriggerState::observer_latitude` are:
* `executor/mod.rs:5645–5646`, guarded by `if state.observer_latitude.is_none()` (:5641)
  and sourced from `device_ops.get_observer_location()`, **not** from `runtime_config`; and
* `executor/mod.rs:4106–4107`, the `ExecutorCommand::UpdateLocation` arm — which is
  **unreachable** (DC1).

The per-tick `runtime_config.read()` at `:5458–5475` reads only `safety_fail_mode`,
`safety_check_interval_secs` and `weather_verdict_staleness_secs`. So a mid-run location
change is picked up by exactly one consumer (`mod.rs:7293`, the `SlewToGapAndContinue`
arm) and by nothing else: `AltitudeLimit`, `DawnApproaching`, and the meridian
hour-angle calculation all keep using the first location `device_ops` ever reported.
Given this project's history with a Null Island location push, this matters.

Fix: make `update_location` forward `ExecutorCommand::UpdateLocation` per the file's own
documented contract (which un-deads that arm), and correct the doc comment.

## R3 — `ExecutorEvent::NodeCompleted` has exactly one producer, and it is a synthetic node — severity: **medium**
`grep -rn "ExecutorEvent::NodeCompleted" native/skotiq_native/{sequencer,bridge}/src`
→ `sequencer/src/executor/mod.rs:6464` (producer) and
`bridge/src/api/sequencer.rs:652` (consumer). The producer at `:6464` sits inside the
`RecoveryAction::Autofocus` trigger arm and its `id` is the synthetic
`format!("trigger:{trigger_id}:autofocus")` built at `:6405`.

Meanwhile `ExecutorEvent::NodeStarted` **is** emitted for every node
(`mod.rs:3685`, inside the progress callback's `status == Running` branch), and the
terminal branch at `:3704–3747` emits only `TargetCompleted` (`:3737`) for target nodes
— never `NodeCompleted`. So every real node produces a start with no matching
completion. Downstream, `packages/skotiq_core/lib/src/backend/bridge_event_mapper.dart:245`
and `services/notification/event_classifier.dart:144` both have live
`nodeCompleted` handling with dedicated tests
(`test/services/notification/event_classifier_node_completed_test.dart`) — a consumer
that only ever sees trigger-fired autofocus.

Fix: emit `NodeCompleted { id, status }` from the terminal branch at `mod.rs:3704`
alongside the existing `started_nodes.remove`. (Verify against the Dart consumers
first — this changes event volume.)

## R4 — An explicit MeridianFlip node reports no flip — severity: **medium**
Same evidence as D4: `instructions.rs:7367–7401` handles `FlipResult::{Success,Failed,
Aborted}` and returns an `InstructionResult` without ever sending
`ExecutorEvent::MeridianFlipOutcome`, while the trigger path
(`executor/mod.rs:6776/6810/6956`) does. Any run-vitals or session-report field fed by
`MeridianFlipOutcome` under-counts by exactly the number of node-driven flips.

## R5 — Mosaic panel resume is a no-op in production while its test asserts the opposite — severity: **medium**
`src/mosaic/mod.rs:223` — the production entry `run_mosaic_wizard` passes
`NullCheckpointSink`, whose `save`/`load`/`clear` discard everything
(`wizard/mod.rs:319–330`). The doc comment at `mosaic/mod.rs:461–471` says *"A
`MemoryCheckpointSink` is convenient in unit tests, but the production path is
`SessionWizardCheckpointSink` which writes through a `CheckpointManager` to disk. This
test exercises that path verbatim."* — but `SessionWizardCheckpointSink::new` is only
called from inside `#[cfg(test)]` (DC4). A crash or restart mid-mosaic re-shoots every
panel from index 0, and the test that "proves" resume works never runs the code
production runs.

Fix: thread the executor's `CheckpointManager` into `InstructionContext` and have
`run_mosaic_wizard` construct `SessionWizardCheckpointSink` — or, if resume is not
wanted, delete DC4 and rewrite the doc + test to state the truth.

## R6 — The same guider call gets two contradictory error policies in one tick — severity: **low**
`executor/mod.rs:5565–5568` swallows the error (`.await.ok().map(...)`) → `guiding_rms`
stays `None` → `state.update_guiding_rms` is skipped (`:5603`) → the `GuidingFailed`
trigger keeps evaluating against the last good RMS. `executor/mod.rs:5990–5995` treats
`Err(_)` from the *same call* as "guide star lost when guiding was expected"
(`tstate.set_guide_star_lost(true)`). Merging the two polls (P1) forces one policy;
pick the fail-closed one and make it explicit.

## R7 — Flat frames bypass the save-path renderer — severity: **low**
See D7. `flat_wizard/mod.rs:325` is a production caller of a code path whose own
comment declares it "legacy direct invocations from tests"
(`instructions.rs:2735–2736`). Flats land under `<target>_<filter>_<NNNN>.fits`
regardless of the user's configured template, and inherit the "untargeted"/"nofilter"
synthetic labels at `instructions.rs:2776–2792` when a flat run has no target set —
which it usually does not.

### Checked and NOT flagged
* Only three `unwrap`/`expect`/`unreachable!` reachable at runtime exist in production
  code across the five big files, and all three are guarded:
  `instructions.rs:183` (`unreachable!` after the `(None, None)` case already returned
  early at `:175`), `instructions.rs:4512` (attempt count clamped 1..=10 by
  `validate_autofocus_config` at `:4609`, check at `:4622`),
  `triggers.rs:727` (`expect("non-empty window invariant")` on a window
  the caller just pushed to).
* `positions[0]` / `positions[total_points - 1]` in the autofocus sweep
  (`instructions.rs:4732`, `:4968`, `:5052`) cannot panic: `validate_autofocus_config`
  runs at `:4382` before every attempt path (`:4451`), and it rejects
  `steps_out` outside `1..=50` (`:4619`), so `calculate_positions`
  (`autofocus.rs:109`) always returns ≥3 elements.
* `CameraExposureAbortGuard::drop` (`instructions.rs:2173`) detaching a `handle.spawn`
  is correct and documented — a sync `Drop` cannot await, and it handles the
  no-runtime case explicitly at `:2191`.
* The `select!`/quiesce/finalize sequence at `mod.rs:7690–7976` drains `execution` on
  every non-execution branch and bounds the in-flight quiesce with
  `TRIGGER_ACTION_QUIESCE_MAX_SECS` — no unawaited-future or abandoned-instruction hole
  found there.

---

# Top priorities (ordered)

1. **R1** — put timeouts + a stall watchdog on the trigger monitor's device polls. It
   is the only finding here that can cost a whole night with the app claiming everything
   is fine.
2. **1.2** — split `SequenceExecutor::start()` (5196 lines). Nothing else in this list
   is testable until it has seams.
3. **R2 / DC1** — wire `update_location` (and the other three orphan commands) to their
   handlers; correct the doc.
4. **D3** — unify the three solar-position implementations; dawn and twilight currently
   disagree by up to ~16 minutes.
5. **P1 + P2** — halve the guider polls and put the mount/focuser/dome on sane cadences.
6. **R5 / DC4** — decide whether mosaic resume is real; today the code says no and the
   test says yes.
7. **1.1** — split `instructions.rs` into `instructions/` (largest file, cleanest cut).
8. **D4 / R4 + D7 / R7** — move flip-outcome emission into `MeridianFlipExecutor`, and
   give the flat wizard a save-path renderer.
