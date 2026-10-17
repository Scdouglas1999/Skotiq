# C3 batch: rust-sequencer-executor

Mechanical file splits only. Code moved verbatim; the only edits are module
declarations, `use` lines, and visibility widenings recorded below. No logic
edit, no rename of a public symbol, no signature change.

Plan followed: `reports/release-pass/map/rust-sequencer.md` §1.2 (executor) and
§1.3 (triggers).

## Re-measured at start (post C1/C2)

| file | lines | over threshold (1500)? |
|---|---|---|
| `native/skotiq_native/sequencer/src/executor/mod.rs` | 11593 | yes |
| `native/skotiq_native/sequencer/src/triggers.rs` | 4467 | yes |

## 1. `executor/mod.rs` 11593 → 346

`mod.rs` now holds the crate-root-ish content only: file doc, imports, the two
defaults consts, module declarations + re-exports, the `SequenceExecutor`
struct, its small methods (`new`, `prepare_sequence_recovery_triggers`,
`get_state`, `get_progress`, `emit`, `set_state`), the `Default` impl,
`get_executor()`, and `classify_dither_result`.

| new file | lines | moved (original line range) |
|---|---|---|
| `executor/monitoring.rs` | 579 | 64–635 — poll bounding, stall watchdog, mount-tracking edge detection, recovery escalation, weather-verdict staleness |
| `executor/types.rs` | 705 | 637–852 + 1244–1723 — `DefectMapApplyState`, `ObserverProfile`, `RuntimeConfig`, `ExecutorCommand`, `ExecutorState`, `SequenceProgress`, `ExecutorEvent` |
| `executor/preflight.rs` | 398 | 854–1242 — required-device collection/validation, unreachable-instruction scan, save-path validation |
| `executor/trigger_context.rs` | 581 | 1725–2298 — `TriggerActionContext`, recovery-trigger specs, autofocus/flip context builders, in-flight guard, camera claiming, verdict helpers |
| `executor/recovery_ops.rs` | 328 | 2300–2620 — `alt_az_to_ra_dec`, `recover_guide_star`, `run_recovery_attempt` |
| `executor/start.rs` | 5271 | 2843–8104 — `SequenceExecutor::start`, moved verbatim into a second `impl SequenceExecutor` block |
| `executor/tests/mod.rs` | 1431 | 8157–9282 test block + the shared `ReacquireGuiderOps` `DeviceOps` fake (originally 11264–11563) |
| `executor/tests/runtime_tests.rs` | 1220 | 9283–10501 |
| `executor/tests/recovery_tests.rs` | 785 | 10503–11592 |

`#[cfg(test)] mod tests { … }` became `#[cfg(test)] mod tests;` over a
directory, so every test's `use super::*` still resolves to the `executor`
module exactly as before. `mod scenario_sim_tests;` is untouched.

### Not done, and why
`start()` is still one 5200-line function, so `start.rs` remains over the
1500-line threshold. Splitting it further is **not** behaviour-preserving code
motion: every inner block (`command_handler`, `recovery_driver`,
`trigger_monitor`, the poll phase, the 14 `RecoveryAction` arms) captures
40–80 locals by move, so extraction requires the map's §1.2 "Step 0" enabling
change (the `RunCore` / `RunSignals` / `RunDevices` / `RunDecision` /
`RunPersist` handle bundles) plus a hand-built parameter list per block. That
is a design change, not a move, and is out of scope for a mechanical batch.
Isolating `start()` in its own file is the part that was safe to do now, and it
leaves the Step-0 refactor a self-contained follow-up against one file.

## 2. `triggers.rs` 4467 → `triggers/` (mod.rs 39)

| new file | lines | moved (original line range) |
|---|---|---|
| `triggers/mod.rs` | 39 | file doc, `FOCUS_DRIFT_WINDOW_MAX`, `CAMERA_BUSY_DOWNLOAD_SLACK_SECS`, module decls + `pub use` globs |
| `triggers/trigger.rs` | 766 | 26–68 + 130–843 — `clamp_focus_drift_window`, `Trigger`, `TriggerClampWarning`, `Trigger::check` |
| `triggers/state.rs` | 1053 | 69–128 + 861–1845 — `looks_like_tracking_limit_hit`, `TriggerState` + `Default` + its mutators |
| `triggers/manager.rs` | 486 | 1847–2325 — `TriggerManager`, `check_all`, `sync_state_from_config`, `create_standard_triggers` |
| `triggers/dawn.rs` | 17 | 845–859 — `calculate_dawn_time` |
| `triggers/tests/mod.rs` | 1225 | 2329–3552 |
| `triggers/tests/audit_and_wave_tests.rs` | 741 | 3554–4292 |
| `triggers/filter_change_edge_tests.rs` | 38 | 4297–4333 |
| `triggers/cross_run_target_hygiene_tests.rs` | 130 | 4338–4466 |

`lib.rs`'s `pub use triggers::*;` is unchanged; `triggers/mod.rs` re-exports
each submodule with a glob so every `skotiq_sequencer::Trigger*` path holds.
The map's `evaluators.rs` idea (turning `Trigger::check`'s 20 match arms into
20 free functions) was **not** done — that rewrites the dispatch rather than
moving it, so `check` stays intact inside `trigger.rs`.

## Visibility widenings (the complete list)

Every one is forced by the move: the item stayed in the same crate and the same
`executor`/`triggers` visibility neighbourhood, but a child module cannot see a
sibling's private item.

Sequencer `executor`:
* every top-level private `fn` / `struct` / `enum` / `const` moved into
  `monitoring.rs`, `types.rs`, `preflight.rs`, `trigger_context.rs`,
  `recovery_ops.rs` → `pub(super)` (items already `pub` / `pub(crate)` kept
  their visibility). `mod.rs` re-imports them (`pub use monitoring::*;`,
  `pub use types::*;`, `pub(crate) use preflight::*;`,
  `pub(crate) use recovery_ops::*;`, `use trigger_context::*;`) so the names are
  in `executor` scope exactly as before, with the same external reachability.
* fields of `TriggerActionContext`, `SequenceRecoveryTriggerSpec`,
  `TriggerFlipTarget`, `TriggerActionInFlightGuard` and the inherent methods of
  `TriggerActionContext` / `TriggerActionInFlightGuard` / `AutofocusOutcome`
  → `pub(super)` (read by `start.rs`).
* `DeviceRequirement::node_name` / `::captures_frames` → `pub(super)` (read by
  the moved tests).
* test-only `ReacquireGuiderOps` + its inherent methods → `pub(super)` so both
  test submodules can use the one fake.

Sequencer `triggers`:
* `looks_like_tracking_limit_hit` → `pub(super)` (defined in `state.rs`, called
  from `trigger.rs`).

No `pub` item gained wider-than-crate visibility anywhere.

## Import-line adjustments in tests
The old test modules inherited `use crate::{PierSide, RecoveryAction,
TriggerType};`, `use chrono::Utc;` and `use std::time::{Duration, Instant};`
through `use super::*` from the single `triggers.rs`. `triggers/mod.rs` no
longer imports those, so the three trigger test files name them explicitly.
Test bodies are otherwise byte-identical (only the 4-space module indent was
removed).

## Verification
* Every non-blank line of both originals is accounted for in the split files
  (multiset comparison after normalising the added `pub(super)` tokens): the
  only lines dropped are the `mod tests {` wrappers and their closing braces;
  the only lines added are file docs, module decls, `use` lines and the
  `impl SequenceExecutor {` wrapper in `start.rs`.
* `cargo check -p skotiq_sequencer` and `--tests`: clean, zero warnings.
* `cargo test -p skotiq_sequencer`: **803 passed, 0 failed** (782 lib +
  5 + 4 + 12 integration, 1 pre-existing ignored doc-test). No test file was
  edited beyond the import lines noted above.
* `cargo fmt -p skotiq_sequencer -- --check`: clean. Only the files listed
  here were formatted.
* `cargo check -p skotiq_bridge`: clean — the FRB-facing
  `skotiq_sequencer::X` paths are unchanged (no bridge source references
  `skotiq_sequencer::executor::` or `::triggers::` sub-paths).
