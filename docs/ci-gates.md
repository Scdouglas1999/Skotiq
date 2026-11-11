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
| Placeholder/stub — no new vs baseline | `launch-gate` → "Runtime Placeholder Gate" | Zero **new** high-risk placeholder/stub markers vs the triaged baseline (`docs/production-readiness/highrisk-baseline.txt`). A marker is matched by its enclosing declaration and line text, so moved files and shifted lines stay covered. High-risk = `UnimplementedError`, `not implemented`, empty `catch (_)`, `.unwrap_or_default()`, `.ok();`. | `melos run audit:placeholders` |
| Fail-closed policy | `launch-gate` → "Fail-Closed Policy Gate" | Each rule in `docs/production-readiness/fail_closed_rules.yaml` must be clean. A rule names a declaration (`declares:`) or a path glob, and covers every `part` file of the Dart library it matches. | `melos run audit:fail-closed` |
| Behavioral audit | `launch-gate` → "Runtime Behavioral Gate" | Every behavioral marker (literal null-coalesce, empty catch, etc.) must have a closed verdict in `docs/production-readiness/behavioral-audit-register.md`. Unregistered or open markers fail. | `melos run audit:behavioral` |
| Audit gate self-tests | `launch-gate` → "Audit Gate Self-Tests" | The behavioral, placeholder and fail-closed tools still keep a verdict attached to moved and re-numbered code, fail on new and open findings, and report rows for deleted code as prunable. | `melos run audit:gates:self-test` |
| Bridge boundary | `launch-gate` → "Bridge Boundary Gate" | `skotiq_core` is the only package that imports `package:skotiq_bridge`. A reviewed exception is a `// bridge-boundary: <id>` comment above the import, with `<id>` justified in `tools/production/bridge_boundary_whitelist.json`. | `melos run audit:bridge-boundary` |
| Dependency hygiene | `analyze` → "Dependency Hygiene Gate" | Every workspace package must declare a direct dependency for each library it imports under `lib/`. | `dart run tools/production/dependency_hygiene.dart` |
| Analyzer rollup (production) | `analyze` → "Analyze code (production gate)" | Zero analyzer errors in production code (`docs/production-readiness/audit-scope.yaml` minus the excludes in `analyzer-policy.yaml`), zero criticals from `critical-warning-codes.txt`. | `melos run analyze:production` |
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

## Keeping the audit gates in step

The audit gates are built so that ordinary refactoring does not touch their
input files.

**Scope.** `docs/production-readiness/audit-scope.yaml` is the one definition
of what the gates scan. Every Dart package and Rust crate in the repository
must either contribute scanned files or be listed under
`coverage.out_of_scope`; a package that falls outside the include globs fails
the gates. There is no file-count floor to adjust when files are added or
deleted. (`--min-files N` is still accepted for ad-hoc use.)

**Behavioral register.** Two files:

- `behavioral-audit-register.md` holds the verdicts, one row each:
  `| verdict | status | owner | notes |`. This is the file people write.
- `behavioral-audit-register.sites.tsv` lists the code each verdict covers.
  The tool writes it; do not edit it by hand.

A site is identified by rule, enclosing function (or type) and the text of the
line. The path in the sites file is a hint only. So:

| You did | What happens | What to do |
|---|---|---|
| Moved or renamed a file, split a file, moved a function to another file, added or removed lines above a finding | Gate stays green. | Nothing. `melos run audit:behavioral:sync` refreshes the path hints when convenient. |
| Deleted code that had findings | Gate stays green and prints `Prunable: N site rows`. | `melos run audit:behavioral:sync` drops the rows. Add `--prune-verdicts` to also drop verdict rows nothing points at any more. |
| Renamed the function around a finding, or moved the line into another function | Gate fails: the finding is unregistered under its new function. | `melos run audit:behavioral:sync` carries the verdict when the line text is unchanged. |
| Edited the line itself | Gate fails. | Review it. If the old verdict still holds: `dart run tools/production/behavioral_audit.dart --sync --carry-edited` (carries only when it is the single candidate in that function, and prints each pair). |
| Wrote new code that trips a rule | Gate fails and lists `path:line:rule [function] text`. | Fix the code, or add a verdict row to the register and run `dart run tools/production/behavioral_audit.dart --accept-new <verdict> --only <path prefix>`. |

Two identical lines in one function with the same rule are told apart only by
their order.

**High-risk baseline.** `highrisk-baseline.txt` uses the same site format and
matching (declaration + line text, path as a hint). After moving code nothing
is needed; after deleting code run `melos run audit:placeholders:sync`; to
accept a reviewed new marker run
`dart run tools/production/placeholder_audit.dart --compare-highrisk-baseline docs/production-readiness/highrisk-baseline.txt --accept-new-highrisk --only <path prefix>`.

**Fail-closed rules.** Prefer `declares: TypeName` over a path glob: the rule
then follows the type wherever its file goes and covers all `part` files of
its library. With `require_present: true` a rule whose target is gone fails
instead of silently checking nothing; decide then whether the rule moves to
the replacement type or is retired.

**Bridge boundary.** The exception travels with the import as a
`// bridge-boundary: <id>` comment. Moving the file needs nothing. Deleting
the import makes the audit print the id as prunable; delete its entry from
`tools/production/bridge_boundary_whitelist.json`.

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
`docs/production-readiness/behavioral-audit-register.md` (with its
`.sites.tsv`) — not an absolute-zero
count. An earlier "fail on any high-risk" (absolute-zero) policy was aspirational
and never passed, because the triaged baseline holds roughly 160 reviewed entries
that are mostly fail-loud documentation comments and audited Rust
`unwrap_or_default()` defaults on optional ASCOM/Alpaca/INDI driver properties.
The enforced policy is therefore baseline-compare (by declaration and line
text, so moved files and line drift cannot trip it) plus the scope check from
`audit-scope.yaml`, which catches a glob change accidentally dropping a
package.

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
