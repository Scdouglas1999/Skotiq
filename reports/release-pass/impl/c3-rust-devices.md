# C3 — mechanical file splits: `rust-devices`

Batch: `rust-devices`
Scope: `native/skotiq_native/{indi,alpaca,ascom,native}/**`, files > 1500 lines
Plan source: `reports/release-pass/map/rust-devices.md` §1
Branch: `audit/end-to-end-campaign`, started from `b07d91c9d` (tree green).

Strictly behaviour-preserving. No logic edits, no renames of public symbols, no
signature changes. Every moved line was moved verbatim; the only textual
differences are module scaffolding, visibility modifiers, and `rustfmt` line
re-wrapping caused by the longer visibility prefixes.

---

## 1. Re-measurement at HEAD (C1/C2 had already shrunk the tree)

| File (map count) | count at HEAD | action |
|---|---|---|
| `indi/src/client.rs` (4146) | **4345** | split |
| `native/src/vendor/zwo.rs` (3928) | **3999** | split |
| `native/src/vendor/qhy.rs` (3015) | **3015** | split |
| `native/src/vendor/fujifilm.rs` (2976) | **2976** | split |
| `native/src/vendor/gphoto2.rs` (2973) | **2738** | split |
| `alpaca/src/camera.rs` (2391) | **2391** | split |
| `native/src/vendor/touptek.rs` (2295) | **2295** | split |
| `native/src/vendor/player_one.rs` (2134) | **2051** | split |
| `native/src/vendor/atik.rs` (2135) | **1936** | split |
| `native/src/vendor/fli.rs` (1947) | **1750** | split |
| `native/src/vendor/moravian.rs` (1807) | **1731** | split |
| `native/src/vendor/svbony.rs` (1853) | **1708** | split |
| `alpaca/src/client.rs` (1767) | **1682** | split |
| `native/src/vendor/lx200.rs` (1651) | **1655** | split |
| `ascom/src/windows/connection.rs` (1601) | **1434** | **SKIPPED — now under threshold** |

`ascom/src/windows/connection.rs` is the only listed candidate that fell below
1500 between the map and now (map §1.5 predicted this: it said to do the dead-code
removal first and re-measure, and that is what happened). It is left untouched.

Nothing in scope is generated. There is no `frb_generated` / `*.g.*` under these
four crates, and no split touched an FRB boundary, so no regeneration is needed.

---

## 2. What was split, and into what

Every split follows the same shape: `X.rs` becomes `X/mod.rs` plus sibling child
modules. Each child opens with `use super::*;` so the parent's imports and
private items stay in scope; `mod.rs` re-exports the children so the crate's
public paths are unchanged.

### `indi/src/client.rs` → `indi/src/client/` (4345 → max 1404)

| file | lines | contents |
|---|---|---|
| `mod.rs` | 550 | `IndiClient` struct + ctors + config accessors + `connect`/`disconnect`/`send_command` + `impl Default` + module wiring |
| `jitter.rs` | 75 | `JitterRng`, `make_jitter_rng`, `jitter_sample` |
| `event.rs` | 62 | `IndiEvent`, `send_indi_event` |
| `config.rs` | 157 | `ReaderStatus`, `ReaderTaskConfig`, `ProtocolConfig`, `ReconnectionConfig` |
| `xml.rs` | 380 | INDI XML parse helpers, `XmlContext(Kind)`, blob-format + version helpers, map lookup helpers, `current_time_ms` |
| `reader.rs` | 931 | `writer_task`, `supervised_reader_task`, `reader_task_with_timeout` (second `impl IndiClient` block) |
| `properties.rs` | 505 | property read/write API and high-level device control (second `impl IndiClient` block) |
| `health.rs` | 317 | keepalive, connection health, reconnect/backoff, version negotiation (second `impl IndiClient` block) |
| `tests.rs` | 1404 | the whole former `mod tests` |

Deviation from the map: the map's optional second-stage `client/reader/parse_loop.rs`
was **not** done. It is the one item the map itself flags as needing real
refactoring judgement (it requires inventing a `ParserState` struct and rewriting
the eight loop-locals as fields), which is outside a mechanical-split mandate.
`reader.rs` at 931 lines is under threshold without it.

### `alpaca/src/client.rs` → `alpaca/src/client/` (1682 → max 804)

`mod.rs` 804, `tests.rs` 359, `config.rs` 232, `error.rs` 213, `builder.rs` 62,
`version.rs` 22. Exactly the map §1.4 plan. D4 (collapsing the five duplicated
verb methods) was **not** applied — that is a consolidation, not a split.

### `alpaca/src/camera.rs` → `alpaca/src/camera/` (2391 → max 878)

`mod.rs` 878, `image_bytes.rs` 772 (decoder + its tests), `image_array.rs` 569
(decoder + its tests), `download.rs` 191. Exactly the map §1.3 plan.

### The eleven vendor drivers → `native/src/vendor/<V>/`

Uniform recipe from map §1.2 (ffi / sdk / discovery / camera / focuser /
filter_wheel / tests), with one addition: where the camera section alone would
still have exceeded ~1200 lines it was cut at the trait boundary into
`camera.rs` (struct + inherent impl) and `camera_ops.rs` (the `NativeDevice` /
`NativeCamera` / `Drop` impls).

| vendor | before | files after | largest child |
|---|---|---|---|
| `zwo` | 3999 | mod 120, ffi 169, sdk 179, camera 640, camera_ops 1031, discovery 149, focuser 702, filter_wheel 700, tests 362 | 1031 |
| `qhy` | 3015 | mod 57, ffi 90, sdk 637, camera 422, camera_ops 878, discovery 198, filter_wheel 572, tests 213 | 878 |
| `fujifilm` | 2976 | mod 53, ffi 236, models 288, sdk 352, discovery 96, camera 588, camera_ops 574, raw 100, tests 727 | 727 |
| `gphoto2` | 2738 | mod 53, ffi 146, sdk 153, discovery 127, camera 1239, camera_ops 700, utils 171, tests 181 | 1239 |
| `touptek` | 2295 | mod 38, ffi 225, sdk 453, tests 194, discovery 173, camera 121, camera_ops 1128 | 1128 |
| `player_one` | 2051 | mod 98, ffi 173, sdk 303, camera 296, camera_ops 695, discovery 92, filter_wheel 285, tests 144 | 695 |
| `atik` | 1936 | mod 50, ffi 87, sdk 330, discovery 228, camera 358, camera_ops 677, filter_wheel 252 | 677 |
| `fli` | 1750 | mod 48, ffi 45, sdk 182, discovery 186, camera 281, camera_ops 534, focuser 274, filter_wheel 247 | 534 |
| `moravian` | 1731 | mod 47, ffi 68, sdk 118, helpers 116, discovery 124, camera 346, camera_ops 768, tests 176 | 768 |
| `svbony` | 1708 | mod 141, ffi 234, sdk 131, discovery 102, camera 472, camera_ops 662 | 662 |
| `lx200` | 1655 | mod 149, protocol 460, mount 304, mount_ops 470, discovery 292 | 470 |

For `atik`, `fli` and `svbony` the `mod tests` block was 17–110 lines, so it was
left in `mod.rs` rather than given its own file.

Result: **no file in the batch exceeds 1500 lines.** The largest are
`indi/src/client/tests.rs` (1404), `gphoto2/camera.rs` (1239),
`touptek/camera_ops.rs` (1128) and `zwo/camera_ops.rs` (1031).

---

## 3. Visibility widenings (the only non-verbatim edits)

Splitting a module means items that were file-private are now cross-module. Every
widening below is **crate-internal**; the crates' public surfaces are byte-identical
(verified by §5).

1. **`native/src/vendor/sdk_loader.rs` — the `load_vendor_sdk!` macro.**
   The macro emitted `struct $sdk` and its function-pointer fields as private.
   Once the SDK loader moves to `V/sdk.rs` and the camera/discovery/filter-wheel
   modules are siblings, those fields are unreachable. Changed the macro to emit
   `pub(crate) struct $sdk` with `pub(crate)` fields (three token insertions at
   `sdk_loader.rs:366/368/371`). All of the macro's methods (`get`,
   `get_or_reason`, `load_error`, `is_available`, `required_symbol_names`) were
   already `pub`. This is the only edit outside the split directories, and it
   affects every vendor that uses the macro (zwo, atik, fli, gphoto2, moravian,
   player_one, svbony) — all of which are split in this batch, which is why their
   FFI types also had to be widened (below) to keep `private_interfaces` quiet.

2. **Per-vendor `pub(crate)` on previously file-private items.** In each split
   vendor directory, top-level private `fn` / `struct` / `enum` / `type` /
   `const` / `static` / `union` / `unsafe extern fn`, plus struct fields and
   inherent-impl methods that are now referenced across the new module boundary,
   were raised to `pub(crate)`. Trait-impl members were untouched (they cannot
   carry a visibility modifier). Notable individual cases:
   - `zwo`, `touptek`, `atik`, `moravian`: the `HandleWrapper(_)` tuple field.
   - `touptek`: `mod commands`-style items plus `touptek_event_callback`.
   - `player_one`: `union POAConfigValue` and its `int_value` / `float_value` /
     `bool_value` fields.
   - `lx200`: the inline `mod commands` → `pub(crate) mod commands`.
   - `qhy`: `QhySdk::set_qhyccd_resolution` (a multi-line field the bulk pass
     missed).

3. **`alpaca/src/client/config.rs`**: `parse_retry_after_header` and
   `parse_retry_after_value` → `pub(super)`.

4. **`alpaca/src/camera/`**: `parse_image_array_json`, `clamp_i64_to_u16`,
   `clamp_f64_to_u16` (in `image_array.rs`) and `parse_image_bytes` (in
   `image_bytes.rs`) → `pub(super)`.

5. **`indi/src/client/`**: everything moved into `jitter.rs`, `event.rs` and
   `xml.rs` → `pub(super)`; the private associated functions moved into
   `reader.rs` / `properties.rs` / `health.rs` → `pub(super)`; `XmlContext`'s
   five fields and its `new` → `pub(super)`. `current_time_ms` was already
   `pub(crate)` and is re-exported from `mod.rs` as `pub(crate) use xml::*;` so
   `crate::client::current_time_ms` (used by `indi/src/weather.rs`) still resolves.

6. **Three added imports** in `zwo/focuser.rs` and `zwo/filter_wheel.rs`
   (`crate::load_vendor_sdk`, `crate::vendor::sdk_loader::vendor_library_candidates`,
   `std::path::PathBuf`) — these were single imports at the top of the old
   `zwo.rs` shared by three SDK loaders; each loader's new home needs its own.

---

## 4. Not done (and why)

- **`ascom/src/windows/connection.rs`** — 1434 lines at HEAD, under threshold. Skipped.
- **`client/reader/parse_loop.rs`** (map §1.1, explicitly marked optional/second-stage)
  — requires introducing a `ParserState` struct and rewriting loop-locals as fields.
  Not mechanical; out of mandate. `reader.rs` is 931 lines without it.
- **D1–D10 deduplications, DC1–DC7 dead-code removals, P5.x perf fixes, R6.x
  reliability fixes** from the map — all consolidation/behaviour work, not splits.
  The one exception is the `load_vendor_sdk!` visibility change above, which the
  split forced.
- **`native/tests/native_driver_tests.rs`** (2398 lines) — a test file, not in the
  `{indi,alpaca,ascom,native}/src` split scope, and the batch rule is that existing
  tests pass unchanged.

---

## 5. Verification

- **`cargo check --workspace --all-targets`**: clean — zero errors, zero warnings.
  (The `bridge/` crate, which consumes all four of these crates, compiles against
  the new module layout untouched; two `pub fn`s that had landed in a private
  child module — `qhy::{is,set}_qhy_discovery_enabled` and `player_one`'s
  `pw_sdk_version` — were caught by this and re-exported.)
- **Public-surface audit**: every child file containing a `pub` item is re-exported
  from its `mod.rs` with `pub use <child>::*;`. Scripted check reports zero
  missing re-exports.
- **Verbatim-move proof**: for all 14 split groups, the whitespace-stripped,
  visibility-stripped statement multiset of the original file at `HEAD` is
  **identical** to that of the new directory's files (modulo `rustfmt` trailing
  commas and the three deliberate imports in §3.6). Zero statements added,
  removed or altered.
- **Test-count preservation**: `#[test]`/`#[tokio::test]` counts per group are
  unchanged (61→61 indi client, 24→24 alpaca camera, 19→19 alpaca client,
  15/12/33/11/10/7/1/1/16/7/13 for the vendors).
- **`cargo test -p skotiq_indi -p skotiq_alpaca -p skotiq_native`**:
  **348 passed, 0 failed, 20 ignored** across 8 test binaries. No test file was
  edited (no import lines needed changing — every test module moved with its
  `use super::*;` intact).
- **`cargo fmt --all -- --check`**: clean for every file this batch touched.
  (The command does report diffs, but only in `bridge/src/builtin_guider/**`,
  `bridge/src/device_capabilities/**`, `bridge/src/device_manager/ops/**` and
  `bridge/src/unified_device_ops/**` — untracked files being created concurrently
  by the sibling `rust-bridge` C3 batch, not touched here.)
