# Contributing to Skotiq

Welcome. This document covers the local setup steps every contributor should run once, plus the conventions CI enforces.

Skotiq is a Flutter front end over a Rust core, bridged with flutter_rust_bridge (FRB). The Dart bindings and the native library must stay in sync, so the toolchain and dev scripts exist to keep them aligned. See [README](../README.md#building-it-yourself) for the full build matrix.

## One-time setup

After cloning the repo:

```bash
# 1. Bootstrap the workspace (installs deps, runs code generators).
melos bootstrap

# 2. Install the pre-commit hook so dart format / cargo fmt / dart analyze
#    run on staged files before each commit.
#
#    macOS / Linux / WSL:
./scripts/install-hooks.sh

#    Windows PowerShell:
.\scripts\install-hooks.ps1
```

The pre-commit hook checks only staged files, so it stays fast on partially-staged worktrees. If you ever need to bypass it (emergency hotfix), run `SKIP_PRECOMMIT=1 git commit ...` — CI will still gate the same checks on the PR.

## Toolchain and Rust build

| Tool | Version |
|---|---|
| Flutter | 3.44.1 (CI pins this on every OS; match it locally so `dart format` and `dart analyze` agree with CI) |
| Dart | 3.12 / analyzer 10 (ships with the pinned Flutter) |
| Rust | stable toolchain, **2021 edition** |
| Melos | via `dart pub global activate melos` |

The native crates live under `native/skotiq_native/` (device drivers under `ascom/`, `indi/`, `alpaca/`, `native/`; automation under `sequencer/`). They build as a Rust workspace.

Run the front end with the dev script, **not** plain `flutter run`:

```bash
melos run dev          # FRB codegen + Rust build + copy native libs (DLL/so) + run desktop
```

`melos run dev` regenerates the FRB bindings, builds the native bridge, and stages the compiled library next to the app. Plain `flutter run` skips all three steps, so it loads stale bindings and fails at runtime with a binding/library hash mismatch.

Useful variants:

| Command | When to use |
|---|---|
| `melos run dev:quick` | Rust/Dart implementation changed but the FFI API surface is unchanged (skips FRB regen). |
| `melos run dev:norun` | Rebuild the native bridge + bindings without launching Flutter. |
| `melos run dev:clean` | Clean all build artifacts and rebuild from scratch. |

If codegen or the FFI boundary misbehaves, start with [docs/FRB_TROUBLESHOOTING.md](../docs/FRB_TROUBLESHOOTING.md).

## Regenerating code

After editing models or the FFI API, regenerate the derived sources:

```bash
melos run generate     # freezed + drift + json_serializable + FRB bindings (build_runner)
```

Commit the regenerated output in its own commit (see [Generated code](#generated-code) below) so reviewers can skip it.

## Running tests

```bash
melos run test                                              # Dart/Flutter tests across all packages
cd native/skotiq_native && cargo test --all-features --workspace   # Rust tests
```

`melos run test` excludes the `golden` tag on purpose. Golden (pixel-diff / perceptual) baselines are host-specific — the GPU rasteriser and font hinting differ across OSes, so the committed baselines (rendered on the canonical Windows host) produce false-positive diffs anywhere else. CI (ubuntu-latest) excludes the golden tag for the same reason. To run them, do so on the baseline host:

```bash
melos run test:golden  # runs ONLY the golden tests; re-baseline with flutter test --update-goldens --tags golden
```

See `docs/testing/golden-tests.md` for the re-baselining workflow.

## What CI enforces (and what the hook mirrors)

Every PR runs:

| Gate | Local equivalent |
|---|---|
| `dart format --set-exit-if-changed` | pre-commit hook (staged Dart files) |
| `cargo fmt --all --check` | pre-commit hook (when staging `.rs`) |
| `dart analyze` (analyzer-rollup with zero-error gate) | pre-commit hook (staged Dart files) + `melos run analyze` |
| `flutter test` across all packages | `melos run test` |
| `cargo test --all-features` + `cargo clippy -D warnings` (Linux + Windows) | `cd native/skotiq_native && cargo test --all-features && cargo clippy --all-features -- -D warnings` |
| `melos run audit:placeholders` (fails on **new** high-risk markers) | `melos run audit:placeholders` |
| `melos run audit:fail-closed` | `melos run audit:fail-closed` |
| `cargo tree --duplicates` (fails on multi-semver duplicates) | `cd native/skotiq_native && cargo tree --duplicates` |
| Codecov coverage threshold (max −1% regression) | `melos run test -- --coverage` |

## House rules

These are non-negotiable:

1. **No stubs / placeholders.** If you find yourself writing `TODO: implement` or returning a hardcoded value, stop and do the full implementation. Stubs get forgotten.
2. **Errors are a feature.** Do not silently swallow failures with `try { ... } catch { /* ignore */ }`, `unwrap_or_default()`, or `if let Ok(_) = ...`. Either propagate the error, log it with the appropriate severity, or document why the fallback is correct.
3. **Use `melos run dev` after Rust changes.** Direct `flutter run` skips FRB regen and the DLL copy step, which causes hash mismatches at runtime.
4. **Run `melos run analyze` before pushing.** The analyzer-rollup gate is the most common CI failure for first-time contributors.

## Generated code

Generated files are committed but tagged `linguist-generated=true` in `.gitattributes`, so GitHub's diff UI collapses them by default. If you regenerate them (FRB, freezed, json_serializable, drift), commit the regenerated output in a dedicated commit named `chore: regenerate generated code` so reviewers can skip it cleanly.

## Where to put new code

- UI for desktop only: `apps/desktop/lib/`
- UI shared across platforms: `packages/skotiq_app/lib/`
- Business logic / providers: `packages/skotiq_core/lib/src/`
- Rust device drivers: `native/skotiq_native/{ascom,indi,alpaca,native}/`
- Rust automation / sequencer: `native/skotiq_native/sequencer/`

When in doubt, follow the package layering: `apps` depend on `packages`,
`skotiq_app` depends on `skotiq_core`, and `skotiq_core` is the
only Dart package that talks to the Rust bridge directly.

## Adding a backend method

The backend is split into role interfaces under `packages/skotiq_core/lib/src/backend/roles/` (`DeviceBackend`, `ImagingBackend`, `GuidingBackend`, `SequencerBackend`, `ProfileSettingsBackend`, `DiagnosticsBackend`). The marker interface `SkotiqBackend` composes all of them, and three concrete backends implement it: `FfiBackend` (local, talks to the Rust bridge), `NetworkBackend` (remote client over the wire), and `DisconnectedBackend` (no-op fallback).

To add a method:

1. Declare it on the narrowest role interface that fits (e.g. a capture call goes on `ImagingBackend`, not the full `SkotiqBackend`).
2. Implement it in `FfiBackend` (`backend/ffi_backend/`). If the call touches the Rust boundary, add or extend the corresponding native API, then run `melos run generate` (or `melos run dev`) to regenerate the FRB bindings.
3. If the method crosses the wire — anything a remote client needs — implement it in `NetworkBackend` (`backend/network_backend/`) and wire the matching headless-API endpoint under `apps/desktop/lib/headless_api/`. Desktop and remote behavior must stay at parity.
4. Provide a sensible no-op or thrown-`SkotiqException` in `DisconnectedBackend`.
5. Run `melos run analyze` and `melos run test` before pushing.

## Updating the support matrix

Code that compiles is **not** the same as supported hardware. A device counts as supported only when it has been exercised against a real rig and the result is recorded. When you add or verify hardware support, update all of these together so they agree:

- `docs/supported-hardware-by-platform.md` — the per-platform support matrix.
- `docs/known-limitations.md` — anything that works partially or not at all.
- The in-app **Platform Capabilities** surface.
- `/api/info`'s `platformCapabilities` field (headless API), so remote clients see the same answer.

Record the real test evidence (rig, driver, observed behavior) under `docs/release-evidence/`. If you cannot point to evidence, the entry stays out of the matrix.
