# C3 batch: rust-bridge-imaging

Scope: `native/skotiq_native/bridge/src/api/imaging.rs` (map baseline 7406; measured at
HEAD **7673**). Threshold for Rust is 1500 lines, so the file is in scope.

Map plan followed: `reports/release-pass/map/rust-bridge.md` §1.1.

## What the map plan asked for, and why most of it is NOT executable

The map's plan converts `api/imaging.rs` into an `api/imaging/` directory module with 12
sibling files holding the FRB-exported items, and asserts that "the glob re-export in
`mod.rs` preserves every existing path" so the regenerated `frb_generated.rs` diff would be
empty.

That assertion is wrong, and the repo proves it in two places:

- `src/frb_generated.rs` addresses split modules by their **full defining path**, not by the
  parent's re-export: e.g. `crate::api::devices::camera::api_camera_capture_preview`,
  `crate::api::devices::cover_calibrator::api_cover_calibrator_get_status`. Today it
  addresses every imaging entry point as `crate::api::imaging::api_*`.
- FRB mirrors the Rust module tree into the **Dart output tree**. `api/devices/*.rs` produced
  `packages/skotiq_bridge/lib/src/api/devices/*.dart`, and even the *inline* `pub mod
  alpaca_connections` / `pub mod ascom_connections` blocks inside `api/connection.rs`
  produced `lib/src/api/connection/alpaca_connections.dart` and `.../ascom_connections.dart`.

So moving any `pub` (FRB-exported) item out of `imaging.rs`'s own body would, on the next
codegen run, relocate `lib/src/api/imaging.dart` into `lib/src/api/imaging/<n>.dart` and
rewrite ~538 call sites in `frb_generated.rs`. That is an FRB regeneration, and FRB bindings
plus generated files are untouchable in this batch. Per the batch rules the FRB-exported
portion of the plan is **skipped and recorded**, not attempted.

(For the same reason a non-`pub` child module is not a workaround: FRB would stop exporting
the items entirely, deleting API surface.)

## What was executed (FRB-neutral, strictly verbatim)

Everything moved is invisible to FRB: `#[cfg(test)]` modules (FRB skips them — the existing
`#[cfg(test)]` module inside `api/connection.rs`'s `pub mod alpaca_connections` has no Dart
counterpart) and `pub(crate)`/private helpers (not `pub`, therefore never exported).

`api/imaging.rs` stays a file; its children live in the sibling `api/imaging/` directory
(Rust 2018+ layout), so the module path of every remaining item is unchanged and
`frb_generated.rs` is untouched. Regenerating FRB now would still produce an empty diff.

| new file | lines | moved from (HEAD line range) |
|---|---|---|
| `api/imaging/quality_math.rs` | 364 | 1857-2215 — `percentile_sorted`, `percentile`, `median`, `mad`, `compute_quality_maps_from_linear_data` (all `pub(crate)`) |
| `api/imaging/rich_header_tests.rs` | 820 | 5702-6524 |
| `api/imaging/sim_exposure_tests.rs` | 417 | 7105-7524 |
| `api/imaging/fits_keyword_update_tests.rs` | 200 | 6901-7103 |
| `api/imaging/exposure_failure_classification_tests.rs` | 119 | 6778-6899 |
| `api/imaging/unified_image_storage_tests.rs` | 115 | 5579-5696 |
| `api/imaging/rgba_save_tests.rs` | 99 | 3001-3103 |
| `api/imaging/auto_stretch_color_tests.rs` | 73 | 7526-7601 |
| `api/imaging/linear_decode_tests.rs` | 62 | 1541-1605 |
| `api/imaging/calibrate_header_carry_over_tests.rs` | 37 | 7634-7673 |
| `api/imaging/quality_map_tests.rs` | 33 | 2294-2329 |
| `api/imaging/display_diagnostic_tests.rs` | 27 | 7603-7632 |

`api/imaging.rs`: **7673 -> 5304 lines** (-2369, -31%).

In place of each removed block `imaging.rs` now carries only the declaration
(`#[cfg(test)] mod <name>;`), and for the helpers:

```rust
mod quality_math;
pub(crate) use quality_math::{
    compute_quality_maps_from_linear_data, mad, median, percentile, percentile_sorted,
};
```

The explicit (non-glob) re-export keeps `crate::api::imaging::median` and its four siblings
resolving exactly as before for the rest of the crate, and avoids any glob-ambiguity with the
child's own `use super::*;`.

### Visibility widenings

**None.** No item's visibility changed. `quality_math`'s five items were already `pub(crate)`
and stay `pub(crate)`; the module itself is private and re-exported at `pub(crate)`. Test
modules moved as `#[cfg(test)] mod X;`, same privacy as the inline `#[cfg(test)] mod X { }`
they replaced.

### Renames / signature changes

None. No logic edits.

## Verification

- Content equivalence proved mechanically, not by eye: with all whitespace stripped, each new
  file is **character-identical** to the source line range it came from, and the remainder of
  `imaging.rs` is character-identical to the original minus exactly those ranges plus the new
  declaration lines. The only textual change is indentation (`rustfmt` re-indented the moved
  bodies one level shallower; no trailing-comma or line-wrap churn).
- Top-level item-signature set across `imaging.rs` + `imaging/*.rs` is identical to HEAD's
  single file (diff empty).
- `rustfmt --edition 2021 --check` clean on all 13 touched files. No repo-wide format run.
- `cargo check -p skotiq_bridge --tests` clean.
- `cargo test -p skotiq_bridge` — see the batch result. Note: the workspace was being
  edited concurrently by other C3 batches (`builtin_guider/`, `device_capabilities/`,
  `sequencer/triggers/`, `native/vendor/`) which were transiently non-compiling during this
  batch; none of the transient errors were ever in `api/imaging`.

## Residual

`api/imaging.rs` is still 5304 lines, over the 1500 threshold. Closing the rest requires
running FRB codegen and accepting the Dart-side import move
(`package:skotiq_bridge/src/api/imaging.dart` -> `.../api/imaging/*.dart`), which is a
generated-surface change and out of scope for a mechanical split batch. Recommend scheduling
it as its own codegen-owning task using the map's 12-file table verbatim.
