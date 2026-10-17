# Rebrand report — r1-native (Rust workspace + generated bridge)

Area: `native/skotiq_native/**` plus the flutter_rust_bridge generated files
(`frb_generated*`, the generated API files under `packages/skotiq_bridge/lib/src/`,
and `bridge_generated.h`).

## Verified environment

- `git rev-parse HEAD` -> `0f14e3843254697dd3ce3d5385a008f1a5342977`
  (the required `0f14e3843`; no detach needed).
- `export TMPDIR=$HOME/.cache/ns-tmp/r1-native` (created), plus
  `CARGO_TARGET_DIR=$HOME/.cache/ns-tmp/r1-native/target` so no target dir is
  shared with the other agents.
- flutter_rust_bridge_codegen: `2.11.1` already installed at
  `~/.cargo/bin/flutter_rust_bridge_codegen`, matching the pins
  (`bridge/Cargo.toml` `flutter_rust_bridge = "=2.11.1"`,
  `packages/skotiq_bridge/pubspec.yaml` `flutter_rust_bridge: ^2.11.1`).
  No install needed.

## What I changed and why

### 1. Cargo.lock ordering
`cargo build` rewrote `native/skotiq_native/Cargo.lock`: the mechanical pass had
renamed the `nightshade_*` package entries in place, leaving them out of
alphabetical order. Cargo re-sorted them as `skotiq_*`. Committed as produced.

### 2. Updater executable name (`native/skotiq_native/updater`)
- `APP_EXECUTABLE`: `skotiq_desktop.exe` -> `skotiq.exe` (Windows) and
  `skotiq_desktop` -> `skotiq` (non-Windows), matching the desktop binary name
  agent r3 sets via Flutter `BINARY_NAME`.
- `launch_target`: verified against agent r3's actual packaging — the shipped
  Linux bundle is `skotiq` (a launcher script that execs `skotiq.bin`; see
  r3's `.github/workflows/linux-release-build.yml` and
  `tools/ota_rehearsal/build_bundle.sh`, which `mv` the Flutter binary to
  `skotiq.bin` so the script owns the name). `launch_target` therefore
  returns `install/skotiq` — the launcher — and only falls back to
  `skotiq.bin` when the script is absent, so the LD_LIBRARY_PATH /
  GDK_BACKEND env the script exports is always in effect on relaunch.
  Windows has no launcher and runs `skotiq.exe` directly.
- `[[bin]] name = "updater"` kept: scripts (`package_windows.ps1`,
  `build_update_package.ps1`, `tools/ota_rehearsal/build_bundle.sh`) and the
  Dart updater service stage `updater.exe`/`updater` under that name.
- `updater.manifest`: assembly identity `Skotiq.Updater` + description already
  read correctly; no change needed.
- Test fixture names inside `main.rs` tests and `tests/relaunch.rs` updated to
  the shipped layout (`skotiq` launcher script, `skotiq.bin` binary).
- `skotiq_update_error.log` temp filename already matched the RUNBOOK docs.

### 3. FITS fixture headers (`native/skotiq_native/test-fixtures/rig-2026-09-14/*.fits`)
The six committed FITS still had `Nightshade` in header cards. Rewrote the
cards in place with a small Python pass:
- `NSHA_VER= 'Nightshade 7.0.0' / Nightshade build that stamped MAGZP*/TRANSPAR`
  -> `'Skotiq 7.0.0' / Skotiq build ...` (matches the value/comment the app
  writes today — `science_processing_service.dart` stamps
  `NSHA_VER = "Skotiq <version>"` with comment
  `Skotiq build that stamped MAGZP*/TRANSPAR`).
- `NSCROPX0`/`NSCROPY0` comments `Nightshade fixture:` -> `Skotiq fixture:`.
Every card stays exactly 80 chars (re-padded with spaces); header block count
and offsets are unchanged. Verified per file that the data unit (everything
after the END card's block) is sha256-identical before and after — the pixels
are untouched.

The `NSHA_VER`/`NSCROPX0`/`NSCROPY0` keyword names are kept: they are the
agreed FITS vocabulary the Dart side writes and tests assert on
(`science_writeback_e2e_test.dart` expects `NSHA_VER` = `'Skotiq 2.5.0'`).

### 4. UTF-16 log captures
`native/skotiq_native/check_output.txt`, `bridge/check_log.txt`,
`native/check_output_lib.txt` are UTF-16-LE captures of old `cargo check`
output; the rebrand script's binary heuristic (NUL in first 8 KiB) skipped
them. Applied the same word map the script uses (`tools/rebrand/rebrand.py`
WORDS list) preserving BOM + UTF-16-LE encoding. 21/37/5 replacements.
`bridge/build_log*.txt` were UTF-8 and had been handled already.

### 5. flutter_rust_bridge regeneration
Ran codegen exactly the way `scripts/dev.sh` does:

    cd native/skotiq_native
    CC=clang CPATH="$(clang -print-resource-dir)/include:/usr/include" \
      flutter_rust_bridge_codegen generate

Files written: `bridge/src/frb_generated.rs`,
`packages/skotiq_bridge/lib/src/{frb_generated.dart, frb_generated.io.dart,
frb_generated.web.dart, api/phd2.dart, error.dart}` and
`packages/skotiq_bridge/{ios,linux,macos}/bridge_generated.h`.

Notes on the diff:
- Output is deterministic: a second identical run produced a byte-identical
  `frb_generated.rs`.
- Reordering vs. the committed files is expected: codegen emits items in
  name order, and `Skotiq*`/`skotiq_*` sorts differently than `Nightshade*`/
  `nightshade_*`. Verified by regenerating at the parent commit
  (`663267b75`) and mechanically word-swapping its `frb_generated.rs`: it
  matches mine modulo line re-wraps (short names join wrapped lines).
- `api/phd2.dart` gained `select_fresh_guide_star` in its ignored-functions
  comment — a pre-existing drift: the committed generated files were already
  stale relative to source (running codegen at `663267b75` produces the same
  +1 line there).
- `error.dart` and `frb_generated.web.dart` diffs are dart-format rewraps
  caused by the shorter names.
- `packages/skotiq_bridge/lib/src/bridge_stub/native_bridge_state.dart` was
  reformatted by codegen's `dart format` pass but is a hand-written file
  outside my area (r2) — reverted it to keep the branch boundaries clean.
- `flutter analyze` on `packages/skotiq_bridge`: clean, no issues.

### 6. `cargo fmt`
The parent tree `663267b75` is `cargo fmt --check`-clean. The mechanical
rename broke that: `use skotiq_*` must sort where `use nightshade_*` did not,
and 207 spots (import groups, re-wraps) drifted. Ran `cargo fmt` across the
workspace; `cargo fmt --check` is now clean. Diffs are import reordering and
line re-wrapping only.

### 7. Test-scratch prefixes
Test temp-dir/format prefixes `ns_*`/`ns-*` (the old-name abbreviation) are
now `sk_*`/`sk-*` across bridge/imaging/sequencer test code (e.g.
`ns_diff_ffi_` -> `sk_diff_ffi_`, `ns-expose-abs-` -> `sk-expose-abs-`).
All are inside `#[cfg(test)]` modules or `tests/` files.

### 8. Deliberately NOT renamed
These are file-format / wire-format vocabulary shared with other agents'
areas; renaming only in `native/` would break the contract:
- FITS keyword family `NS-SESID`, `NS-FIDX`, `NS-MOSNM`, `NS-PIDX`,
  `NS-PROW`, `NS-PCOL`, `NSSTAGE`, `NSRECIPE`, `NSRECVER`, `NSRECSTP`,
  `NSHA_VER`, `NSCROPX0`/`NSCROPY0` — read and written by both the Rust side
  and `packages/skotiq_*` Dart code (and asserted by Dart-side tests).
- File extensions `.nsrecipe`, `.nsmaster`, `.nshatmp`, `.nst` — same
  cross-boundary contract.
- `ns:<session>:<index>` DepthLock frame-id format (`docs/depthlock-design.md`
  documents it; `imaging/src/depthlock/input.rs` builds it).
- `~/.cache/ns-rig-data/` — the physical rig-data cache path on the dev
  machine; tests skip gracefully when it is absent, and renaming the
  expected path would silently disable the full-frame tests. (The env var
  override is already `SKOTIQ_RIG_DATA`.)
- `NSEW` in `slew.rs` — INDI north/south/east/west directional movement,
  not a product name.
- `bridge/target/frb_dump/` — codegen dump artifacts, gitignored.

## Commands run (unpiped, with exit codes)

| Command | Exit |
|---|---|
| `git rev-parse HEAD` | 0 (`0f14e3843`) |
| `cargo build -j 8 --workspace` (initial, at 0f14e3843) | 0 |
| `cargo test -j 8 --workspace` (initial) | 101 — one flaky test, see below |
| `cargo test -p skotiq_native --test native_driver_tests test_zwo_camera_discovery_no_crash -- --exact` | 0 (passes in isolation) |
| `cargo test -p nightshade_native --test native_driver_tests` in a `663267b75` worktree | 101 — same flake pre-exists the rename |
| `flutter_rust_bridge_codegen generate` (via dev.sh's CC/CPATH) | 0 |
| `flutter analyze` in `packages/skotiq_bridge` | 0, no issues |
| `cargo deny check bans` | 0 (warnings only: pre-existing "unnecessary-skip" notes) |
| `cargo fmt --check` after fmt pass | 0 diffs |
| `cargo build -j 8 --workspace` (final) | 0 |
| `cargo test -j 8 --workspace` (final) | 101 — only the known flake below |
| `cargo clippy -j 8 --workspace --all-targets` | 0, no warnings |
| `cargo test -j 8 -p skotiq_updater` (after launch_target fix) | 0 (32 unit + 4 relaunch) |
| `cargo clippy -j 8 -p skotiq_updater --all-targets` | 0, no warnings |

Full logs in `$HOME/.cache/ns-tmp/r1-native/` (build*.log, test*.log,
clippy1.log, frb_codegen*.log, parent-test1.log).

## Known-failing test (pre-existing, not caused by the rename)

`skotiq_native --test native_driver_tests::test_zwo_camera_discovery_no_crash`
asserts `zwo::discover_devices()` returns `Ok` even with no ZWO hardware.
It is **flaky under test parallelism**: it fails intermittently in the full
binary (1 failure of 14 run / 25 total) and passes in isolation and on
re-runs (~2 of 3 full-binary runs fail). Proof it pre-exists the rename:
in a detached worktree at `663267b75` (`native/nightshade_native`,
`CARGO_TARGET_DIR=.../target-parent`), the same test fails:

    cd $WT/native/nightshade_native
    cargo test -j 8 -p nightshade_native --test native_driver_tests
    -> test_zwo_camera_discovery_no_crash ... FAILED
       test result: FAILED. 13 passed; 1 failed; 11 ignored

Likely mechanism: `run_discovery` serializes on `zwo_camera_mutex()` with a
`DISCOVERY_TIMEOUT`; the test binary's other ZWO/discovery tests hold the
lock long enough for this one to time out. Not rename-related (no name
lookups on that path; the SDK is loaded as `libASICamera2.so`).

## What I did not finish / notes for the merge

- The `NS-*`/`.ns*`/`ns:` file-format vocabulary stays (see §8). If the owner
  wants it renamed too, it needs a coordinated cross-area change (Dart model
  classes, generated bridge API, FITS readers, docs) — flagging for the
  coordinator.
- The shipped Linux layout was confirmed against r3's branch
  (`skotiq` launcher script + `skotiq.bin` binary); the updater matches it.
- Out-of-area observation for r2/r3: `packages/skotiq_updater/lib/src/services/
  update_service.dart:57` still describes a headless rig "launched as
  `skotiq_desktop --headless`" — a stale comment in a hand-written Dart file,
  left for its owner.
- The three UTF-16 check-log captures keep stale pre-rename build output
  content (crate names now read `skotiq_*`); they are committed artifacts,
  not regenerated output — consider deleting them in a cleanup pass.
