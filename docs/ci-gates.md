# CI Gates Reference

> Owner: CQ / Code Quality.
>
> This document is the canonical reference for the **required CI checks** on
> every pull request to `main`/`master`. Each gate listed below is enforced by
> a step in `.github/workflows/ci.yml`; failing any of them blocks merge.
>
> Origin: this file makes the audit gates required rather than advisory.

---

## Required gates (block merge on red)

Every gate below corresponds to a step in `.github/workflows/ci.yml`. If the
step exits non-zero, the job fails, the check shows red on the PR, and the
"Required checks must pass" branch-protection rule prevents merge.

| Gate | Job / Step | What it enforces | Local repro |
|------|------------|------------------|-------------|
| Placeholder/stub — no new vs baseline (direct) | `analyze` → "Placeholder/Stub Audit Gate (fail on new vs baseline, direct)" | Zero **new** high-risk placeholder/stub markers vs the triaged baseline (`docs/production-readiness/highrisk-baseline.txt`), compared by path+content signature so unrelated line drift cannot trip the gate. High-risk = `UnimplementedError`, `not implemented`, empty `catch (_)`, `.unwrap_or_default()`, `.ok();`. `--min-files 797` pins scope so a glob regression that drops a package fails the gate. | `dart run tools/production/placeholder_audit.dart --fail-on-new-highrisk --compare-highrisk-baseline docs/production-readiness/highrisk-baseline.txt --min-files 797` |
| Placeholder/stub — no new vs baseline (melos) | `analyze` → "Placeholder/Stub Audit Gate (fail on new vs baseline)" | The same baseline comparison via the documented developer command, so the script and the documented command cannot diverge silently. | `melos run audit:placeholders` |
| Fail-closed policy (direct) | `analyze` → "Fail-Closed Policy Gate (direct, with --min-files regression-pin)" | Each rule in `docs/production-readiness/fail_closed_rules.yaml` must be clean. Also fails if `--min-files 1337` regression-pin not met (catches accidental scope shrink from a glob change). | `dart run tools/production/fail_closed_check.dart --min-files 1337` |
| Fail-closed policy (melos) | `analyze` → "Fail-Closed Policy Gate (melos wrapper)" | Exercises the documented developer command `melos run audit:fail-closed` so the script and the documented command can never diverge silently. | `melos run audit:fail-closed` |
| Behavioral audit | `analyze` → "Behavioral Audit Gate" | Every behavioral marker (literal null-coalesce, empty catch, etc.) must be registered in `docs/production-readiness/behavioral-audit-register.md` with a closed status. Unregistered or open markers fail. | `dart run tools/production/behavioral_audit.dart --register docs/production-readiness/behavioral-audit-register.md --fail-on-unregistered --fail-on-open --report .behavioral_audit_hits.txt --min-files 796` |
| Dependency hygiene | `analyze` → "Dependency Hygiene Gate" | Every workspace package must declare a direct dependency for each library it imports under `lib/`. | `dart run tools/production/dependency_hygiene.dart` |
| Analyzer rollup (production) | `analyze` → "Analyze code (production gate)" and `launch-gate` → "Launch Analyzer Gate (zero production warnings)" | Zero analyzer errors against `docs/production-readiness/analyzer-policy.yaml`, zero criticals from `critical-warning-codes.txt`. Equivalent to `melos run analyze:production`. | `melos run analyze:production` (or the explicit `dart run tools/production/analyzer_rollup.dart ...` from `ci.yml`). |
| Launch-gate placeholder | `launch-gate` → "Runtime Placeholder Gate" | Mirror of the baseline-compare placeholder gate, run in the dedicated launch-gate job (so the launch-gate badge reflects production readiness independently). | Same as the direct placeholder gate above. |
| Launch-gate behavioral | `launch-gate` → "Runtime Behavioral Gate" | Mirror of the behavioral audit, run in the dedicated launch-gate job. | Same as Behavioral audit above. |
| Dart tests | `test-dart` → "Run Dart tests" | All `flutter test` packages green. `melos run test` passes `--exclude-tags golden`, so the host-specific pixel-diff/perceptual golden suites do NOT run on the Linux runner (their committed baselines are Windows-rendered). See `docs/testing/golden-tests.md`; run the goldens with `melos run test:golden` on the canonical host. | `melos run test` |
| Rust tests (Linux) | `test-rust` → "Run Rust tests" | `cargo test --all-features --workspace` green. Runs on every PR. | `cd native/skotiq_native && cargo test --all-features --workspace` |
| Rust clippy (workspace, deny warnings) | `test-rust` → "Run Rust clippy (workspace, deny warnings + high-value lints)" | `cargo clippy --all-features --workspace --all-targets -- -D warnings -D clippy::result_unit_err -D clippy::await_holding_lock -D clippy::undocumented_unsafe_blocks` clean. Promotes `result_unit_err`, `await_holding_lock`, and `undocumented_unsafe_blocks` to errors. | `cd native/skotiq_native && cargo clippy --all-features --workspace --all-targets -- -D warnings -D clippy::result_unit_err -D clippy::await_holding_lock -D clippy::undocumented_unsafe_blocks` |
| Rust tests (Windows) | `test-rust-windows` → "Run Rust tests" | `cargo test --workspace` on `windows-latest`. Runs on push to main/develop, nightly, or PRs labeled `ci:windows-rust`. Gates the Windows-only `ascom/` crate. | (Windows only) `cd native/skotiq_native && cargo test --all-features --workspace` |
| Rust clippy (Windows) | `test-rust-windows` → "Run Rust clippy (workspace, deny warnings + high-value lints)" | Same as the Linux clippy gate but on Windows so `ascom/windows_impl.rs` is exercised. | (Windows only) Same command as Linux clippy. |
| Dart format | `format-check` → "Check Dart formatting" | `dart format --set-exit-if-changed` clean on every package. | `melos run format -- --set-exit-if-changed` |
| Rust format | `format-check` → "Check Rust formatting" | `cargo fmt --all -- --check` clean. | `cd native/skotiq_native && cargo fmt --all -- --check` |
| Build test | `build-test` → "Test build Flutter app" | Flutter debug build succeeds on Ubuntu, Windows, and macOS runners. Catches platform-specific build regressions before they reach release. | `cd apps/desktop && flutter build <platform> --debug` |
| Coverage upload | `coverage` → "Upload coverage to Codecov" | `fail_ci_if_error: true` and Codecov target/threshold from `.github/codecov.yml`. Forked-PR uploads tolerated when token absent. | `melos run test -- --coverage` then run `codecov` locally. |

---

## Advisory gates (visible but non-blocking)

These steps annotate the PR with warnings but do not fail the job. They are
the "early warning" tier — they exist so a known-in-progress sweep stays
visible on every PR.

| Step | Where | Why advisory |
|------|-------|--------------|
| `cargo-duplicates` | `cargo-duplicates` job | Documents the bloater crates being tracked under the windows-upgrade work. Annotated as a build warning until those land. Promote to `exit 1` once the deny.toml skip list is empty. |
| Codecov upload (forked PR) | `coverage` step | `continue-on-error` only when the PR is from a fork without the `CODECOV_TOKEN` secret. Native-repo PRs still gate. |

---

## `undocumented_unsafe_blocks` — promoted to `-D`

**Status:** promoted from `-W` (advisory) to `-D` (deny)
on top of HEAD `2a17c1b` (the residual
non-vendor SAFETY sweep landed in the same change). The advisory step has been
removed and the lint is now folded into the main
`-D warnings -D clippy::result_unit_err -D clippy::await_holding_lock
-D clippy::undocumented_unsafe_blocks` invocation on both the Linux and
Windows clippy jobs — see the "Required gates" table above.

Coverage notes:

- The vendor-SDK sweep covered 8
  camera vendors (ZWO, FLI, QHY, PlayerOne, Atik, Moravian, SVBony, Fujifilm,
  Touptek) and the SDK loader macro.
- The residual sweep documented the
  remaining non-vendor sites in ASCOM Windows COM helpers (variant, connection,
  switch, camera, cover_calibrator), the imaging mmap reader, gphoto2,
  updater Win32 helpers, and the ZWO test example.
- `bridge/src/frb_generated.rs` is auto-generated by
  `flutter_rust_bridge_codegen` and cannot carry hand-edited `// SAFETY:`
  comments (any edit would be overwritten on the next codegen run). The
  `mod frb_generated;` declaration in `bridge/src/lib.rs` therefore carries a
  module-level `#[allow(clippy::undocumented_unsafe_blocks)]` with a comment
  explaining the FRB-internal ownership boundary; every hand-written unsafe
  block in the crate still trips the deny gate.

If this lint ever needs to be relaxed again (e.g., a new auto-generated module
arrives without SAFETY comments), prefer scoping the `#[allow]` to that
specific module rather than reverting the workspace-level `-D`.

---

## How to debug a red gate locally

1. **Identify the failing step** in the GitHub Actions run summary. The job
   name + step name maps directly to a row in the "Required gates" table.
2. **Run the local repro command** from the same row. Every gate has a
   command that reproduces CI's failure exactly, with the same flags.
3. **Inspect the report file** if one is written:
   - Placeholder: `.audit_hits.txt`, `.audit_highrisk.txt`
   - Fail-closed: `docs/production-readiness/fail-closed-audit.json` / `.md`
   - Behavioral: `.behavioral_audit_hits.txt`
   - Dependency hygiene: `docs/production-readiness/dependency-hygiene.json`
   - Analyzer rollup: `docs/production-readiness/analyzer-rollup.json`
4. **For Rust gates**, the GitHub Actions log includes the full `cargo`
   output. The same command runs locally; clippy's annotations include the
   file/line.

If the gate output is unclear, the audit scripts under
`tools/production/*.dart` are short (a few hundred lines each) and document
their flags in the source.

---

## Current gate status

All required gates above are green on `main`.

The placeholder/stub and behavioral gates enforce **no new high-risk markers vs
the committed baselines** — `docs/production-readiness/highrisk-baseline.txt` and
`docs/production-readiness/behavioral-audit-register.md` — not an absolute-zero
count. An earlier "fail on any high-risk" (absolute-zero) policy was aspirational
and never passed, because the triaged baseline holds roughly 160 reviewed entries
that are mostly fail-loud documentation comments and audited Rust
`unwrap_or_default()` defaults on optional ASCOM/Alpaca/INDI driver properties.
The enforced policy is therefore baseline-compare (by path+content signature, so
unrelated line drift cannot trip it) plus a `--min-files` scope pin that catches a
glob change accidentally dropping a package. To tighten a baseline, lower the
recorded floor in the same commit that removes the markers.

The `undocumented_unsafe_blocks` clippy lint, formerly advisory, is now enforced
as `-D` in the workspace clippy gate (see the "Required gates" table above).

---

## Adding a new required gate

1. Add the step to `.github/workflows/ci.yml`. Use a name beginning with the
   audit's plain English label and ending in "Gate" so the GitHub Actions UI
   makes the required-vs-advisory distinction obvious.
2. Confirm the step exits non-zero on failure (no `continue-on-error`, no
   `set +e`, no `|| true`).
3. Add a row to the **Required gates** table above with the local repro
   command. The local command must be a single-line copy-paste that
   reproduces the CI failure exactly.
4. If the gate is advisory (warning-level, informational), add it to the
   **Advisory gates** table instead and document the promotion criteria so
   the gate doesn't stay advisory forever.
5. Update branch-protection on `main`/`master` so the new job is in the
   "Require status checks to pass before merging" list. This is a GitHub UI
   step, not a YAML change — see `docs/RUNBOOK.md` if you have admin access.

---

*End of CI gates reference.*
