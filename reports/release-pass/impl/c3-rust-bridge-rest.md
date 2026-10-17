# C3 — batch `rust-bridge-rest`

Scope: `native/skotiq_native/bridge/src/**`, every non-generated file over the
1500-line Rust threshold **except** `api/imaging.rs` (another batch) and
`frb_generated.rs` (generated, untouchable).

Plan source: `reports/release-pass/map/rust-bridge.md` §1.2–§1.11.
All line ranges were **re-measured at HEAD** before splitting — the map's ranges were
stale after C1/C2.

## Result

14 files split, 0 behaviour changes, `cargo test -p skotiq_bridge` green
(**550 passed / 0 failed / 4 ignored** — identical to the HEAD baseline of
548 passed + 2 failed, where the 2 failures were the source-path guards this batch
had to re-point; see "Test edits" below).

| former file | lines @HEAD | now | largest child |
|---|---|---|---|
| `device_capabilities.rs` | 4296 | `device_capabilities/` × 8 | `tests.rs` 918 |
| `builtin_guider.rs` | 3929 | `builtin_guider/` × 8 | `tests.rs` 1245 |
| `api/sequencer.rs` | 3734 | `api/sequencer/` × 7 | `runtime_config.rs` 874 |
| `unified_device_ops.rs` | 3012 | `unified_device_ops/` × 6 | `device_ops.rs` 1577 ⚠ |
| `api/post_session.rs` | 2996 | `api/post_session/` × 7 | `tests.rs` 694 |
| `device_manager/ops/camera.rs` | 2967 | `…/camera/` × 5 | `mod.rs` 666 |
| `device_manager/ops/mount.rs` | 2679 | `…/mount/` × 5 | `status.rs` 930 |
| `api/devices/simulation.rs` | 2551 | `…/simulation/` × 12 | `mount.rs` 396 |
| `device_manager/tests.rs` | 2369 | `device_manager/tests/` × 10 | `simulator.rs` 639 |
| `api/sky_atlas.rs` | 1850 | `api/sky_atlas/` × 6 | `tests.rs` 473 |
| `api/polar_alignment.rs` | 1736 | `api/polar_alignment/` × 7 | `run_loop.rs` 772 |
| `device_id.rs` | 1629 | `device_id/` × 3 | `mod.rs` 805 |
| `sim_frame.rs` | 1568 | `sim_frame/` × 2 | `tests.rs` 924 |
| `event.rs` | 1514 | `event/` × 8 | `sequencer.rs` 611 |

## Method (strictly mechanical)

* Every child file is `use super::*;` + **verbatim** line ranges lifted from the
  original. The original's `use` header stays in `mod.rs`; children reach it through
  the glob (a descendant module can see an ancestor's private imports).
* `mod.rs` = original header + `mod <child>; pub use <child>::*;` + whatever items were
  not assigned to a child.
* Inline `#[cfg(test)] mod X { … }` blocks that were moved wholesale became out-of-line
  `#[cfg(test)] mod X;` + a dedented `X.rs` — a pure move, an out-of-line test module
  still reaches private items via `use super::*`.
* `device_manager/ops/{camera,mount}.rs` were single **inherent** `impl DeviceManager`
  blocks. Inherent impls may be spread across modules of the same crate, so each child
  re-opens `impl DeviceManager { … }` around its verbatim methods. No method body,
  signature or name changed.
* Nothing was renamed. No public symbol changed. No `pub fn` under `api/` changed
  visibility, so the FRB-exported surface is byte-identical.

## Visibility widenings (the only edits that are not pure motion)

664 declarations gained `pub(crate)` because a sibling module now needs what used to be
file-private. Mechanically: top-level private `fn`/`struct`/`enum`/`static`/`const`,
private struct **fields**, and private inherent-impl **methods** in the child files.

| split | widened decls |
|---|---|
| `api/sky_atlas.rs` | 184 |
| `api/post_session.rs` | 177 |
| `builtin_guider.rs` | 141 |
| `api/devices/simulation.rs` | 101 |
| `api/polar_alignment.rs` | 19 |
| `device_capabilities.rs` | 14 |
| `device_id.rs` | 14 |
| `api/sequencer.rs` | 8 |
| `unified_device_ops.rs` | 6 |
| `event.rs`, `ops/camera.rs`, `ops/mount.rs`, `device_manager/tests.rs`, `sim_frame.rs` | 0 |

Nothing was widened past `pub(crate)`. The crate is `crate-type = ["cdylib",
"staticlib"]` with no Rust dependents, so `pub(crate)` is not observable outside the
crate.

Two secondary, warning-driven adjustments (both required to keep CI's
`clippy -D warnings` clean, neither observable):

* Where a child exports only `pub(crate)` items, `mod.rs` uses `pub(crate) use child::*;`
  instead of `pub use` (otherwise rustc warns the glob re-exports nothing public).
* Inside `api/` and `event/`, child modules are declared `mod child;` (private) rather
  than `pub mod child;`, because module names like `sequencer`, `imaging` and
  `entrypoints` would otherwise collide in the crate-root / `api::*` glob re-exports.
  The items themselves are still re-exported by the `pub use child::*;` line, so every
  existing `crate::api::sequencer::api_…` path (including the ones inside
  `frb_generated.rs`) resolves exactly as before.

## Import-line adjustments in moved test code

Four explicit `use super::NAME;` lines inside moved test modules of `api/sequencer`
now read `use crate::api::sequencer::NAME;` — `super` used to mean the file's module and
now means the child. Import lines only; no test body changed.

## Test edits (forced by the move, recorded deliberately)

`bridge/src/sim_capture.rs` holds two guards that assert on **source file paths**. The
split moved the files they name, so the paths were re-pointed:

* `SANCTIONED`: `"bridge/src/sim_frame.rs"` → `"bridge/src/sim_frame/mod.rs"`.
* `release_gate_still_guards_null_device_ops`: `"api/sequencer.rs"` →
  `"api/sequencer/runtime_config.rs"` (where `api_sequencer_set_simulation_mode` now
  lives). The assertion itself is unchanged and still passes.

These are the 2 tests that failed mid-batch; both pass now.

## Skipped

* **`api/imaging.rs`** — explicitly out of scope for this batch.
* **`ascom_wrapper/camera.rs` (1629)** — `#[cfg(windows)]`. It cannot be compile-verified
  from this machine: `cargo check --target x86_64-pc-windows-msvc -p skotiq_bridge`
  dies in a C build script (`failed to find tool "lib.exe"`). Splitting Windows-only code
  with no compiler to check it is exactly the kind of unverifiable change this pass must
  not make.
* **`unified_device_ops/device_ops.rs` (1577)** — this is the *residual* of the
  `unified_device_ops.rs` split: a single `#[async_trait] impl DeviceOps for
  UnifiedDeviceOps` block. Rust requires all methods of one trait impl to live in one
  block, so it cannot be split further by code motion. Reducing it needs delegation
  wrappers (new inherent methods called by the trait methods) — that is a refactor with
  new functions, not a mechanical move, so it is out of this batch's mandate. The parent
  file still went 3012 → 254 in `mod.rs`.
* Everything else in `bridge/src` is now under 1500 lines.

## Verification

* `cargo check -p skotiq_bridge --all-targets` — clean (no errors, no warnings from
  bridge).
* `cargo test -p skotiq_bridge` — 550 passed, 0 failed, 4 ignored.
* `cargo clippy -p skotiq_bridge --all-targets -- -D warnings -D clippy::result_unit_err
  -D clippy::await_holding_lock -D clippy::undocumented_unsafe_blocks` — two errors, both
  **pre-existing** with this workstation's newer clippy (1.96) and neither in a file this
  batch created:
  * `device_manager/ops/weather.rs:254` `needless_borrow` — file untouched by this batch
    (`git status` shows it unmodified).
  * `sim_capture.rs:434` `single_element_loop` — verified format-independent: the same
    lint fires on HEAD's one-line form of that loop.
* `rustfmt --edition 2021 --check` — clean over all 99 files this batch touched. No
  repo-wide formatter was run.
* `frb_generated.rs` untouched (`git status` clean) and still compiles against the new
  module tree.

## Owed / not done here

* **FRB regeneration diff.** The map asks that each `api/*` split be confirmed by
  regenerating `frb_generated.rs` and diffing to empty. That was not run here (codegen is
  not available in this batch and the generated file is untouchable). The weaker but real
  evidence: no `pub` symbol under `api/` changed name or visibility, the directory-module
  pattern is the one `api/devices/` already uses, and the checked-in generated file still
  compiles and resolves every `crate::api::…` path.
* `graphify update .` was **not** run — nine other agents were writing to this repo
  concurrently and `graphify-out/` is shared state. Run it once after the wave lands.
