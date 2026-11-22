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

The checks are one table, `tools/production/gate.dart`. Each CI job of
`.github/workflows/ci.yml` runs one stage of it, and `melos run gate` runs
every stage (`-- --list` prints the table, `-- --stage <s>`, `--only <check>`
and `--skip <stage or check>` narrow it, `--out <dir>` keeps one log per
check). Every selected check runs even after one fails; the step fails when
any did, and the summary names each failure. The `melos run audit:*` scripts
run single checks of the same table. The Rust jobs set up no Dart, so they
call `scripts/rust_checks.sh`, which the gate's `rust` stage runs too.

| CI job (check name) | Gate stage |
|---|---|
| Analyze | `analyze`: UI token audit and its tests, nebula light tests, the `scripts/test_*.py` release-script tests, the live-rig API driver against the route table, dependency hygiene, version consistency and its self-test, analyzer rollup, `dart analyze packages apps tools` |
| Launch Gate | `audits`: the audit gates below, every audit self-test, and four reports that print counts and do not fail (design tokens, UI consistency, oversized files, narrative comments) |
| Dart Tests | `dart-tests` |
| Constellation Hub | `hub` |
| Format Check | `format` |
| Rust Tests (linux), Rust Tests (windows), Cargo Duplicate Versions | `rust` (via `scripts/rust_checks.sh`) |
| (none: the runners have no codegen) | `codegen`: `scripts/check_bridge_codegen.sh` regenerates the bridge and fails when that changed the generated files or the event wire codec is stale; skipped where `flutter_rust_bridge_codegen` is not installed |
| Rust License Audit | `rust` → `rust-licenses` (CI uses cargo-deny-action; the gate skips it, saying so, where cargo-deny is not installed) |

Build Test (Desktop) is CI only. `audit:windows-bundle` is not in the gate:
it needs a built Windows bundle.

| Gate | Job / Step | What it enforces | Local repro |
|------|------------|------------------|-------------|
| Placeholder/stub — no new vs baseline | `Launch Gate` → `placeholders` | Zero **new** high-risk placeholder/stub markers vs the triaged baseline (`docs/production-readiness/highrisk-baseline.txt`). A marker is matched by its enclosing declaration and line text, so moved files and shifted lines stay covered. High-risk = `UnimplementedError`, `not implemented` and the other stub markers. The silent-fallback shapes (empty `catch (_)`, `.unwrap_or_default()`, `.ok();`) are judged by the behavioral gate in Dart and Rust, so each finding has one register; in other scanned languages they stay high-risk here. | `melos run audit:placeholders` |
| Fail-closed policy | `Launch Gate` → `fail-closed` | Each rule in `docs/production-readiness/fail_closed_rules.yaml` must be clean. A rule names a declaration (`declares:`) or a path glob, and covers every `part` file of the Dart library it matches. | `melos run audit:fail-closed` |
| Behavioral audit | `Launch Gate` → `behavioral` | Every behavioral marker (literal null-coalesce, empty catch, etc.) must have a closed verdict in `docs/production-readiness/behavioral-audit-register.md`. Unregistered or open markers fail. | `melos run audit:behavioral` |
| Audit gate self-tests | `Launch Gate` → `behavioral:self-test`, `placeholders:self-test`, `fail-closed:self-test` | The behavioral, placeholder and fail-closed tools still keep a verdict attached to moved and re-numbered code, fail on new and open findings, and report rows for deleted code as prunable. | `melos run audit:gates:self-test` |
| Bridge boundary | `Launch Gate` → `bridge-boundary` | `skotiq_core` is the only package that imports `package:skotiq_bridge`. A reviewed exception is a `// bridge-boundary: <id>` comment above the import, with `<id>` justified in `tools/production/bridge_boundary_whitelist.json`. | `melos run audit:bridge-boundary` |
| Dependency hygiene | `Analyze` → `dependency-hygiene` | Every workspace package must declare a direct dependency for each library it imports under `lib/`. | `melos run audit:dependency-hygiene` |
| Analyzer rollup (production) | `Analyze` → `analyze-production` | Zero analyzer errors in production code (`docs/production-readiness/audit-scope.yaml` minus the excludes in `analyzer-policy.yaml`), zero criticals from `critical-warning-codes.txt`. | `melos run analyze:production` |
| Dart tests | `Dart Tests` → `flutter-tests`, `pure-dart-tests`, `manual-migration` | All `flutter test` packages green, then the pure-Dart packages and the migration of a 4.3.0 database to the current schema. The last two run even when the first step fails, so one red package does not hide them. `melos run test` passes `--exclude-tags golden`, so the host-specific pixel-diff/perceptual golden suites do NOT run on the Linux runner (their committed baselines are Windows-rendered). See `docs/testing/golden-tests.md`; run the goldens with `melos run test:golden` on the canonical host. | `melos run gate -- --stage dart-tests` |
| Rust tests (Linux) | `Rust Tests (linux)` → `scripts/rust_checks.sh test` | `cargo test --all-features --workspace --no-fail-fast` green. Runs on every PR. `--no-fail-fast` runs every test binary, so one failing binary cannot hide the crates after it. | `bash scripts/rust_checks.sh test` |
| Rust clippy (workspace, deny warnings) | `Rust Tests (linux)` → `scripts/rust_checks.sh clippy` | `cargo clippy --all-features --workspace --all-targets -- -D warnings -D clippy::result_unit_err -D clippy::await_holding_lock -D clippy::undocumented_unsafe_blocks` clean. Promotes `result_unit_err`, `await_holding_lock`, and `undocumented_unsafe_blocks` to errors. | `bash scripts/rust_checks.sh clippy` |
| Rust tests (Windows) | `Rust Tests (windows)` → `scripts/rust_checks.sh test` | `cargo test --workspace --no-fail-fast` on `windows-2022`. Runs on push to main/master/develop, nightly, PRs from a `release/*` or `fix/*` branch, and PRs labeled `ci:windows-rust`. Gates the Windows-only `ascom/` crate. | (Windows only) `bash scripts/rust_checks.sh test` |
| Rust clippy (Windows) | `Rust Tests (windows)` → `scripts/rust_checks.sh clippy` | Same as the Linux clippy gate but on Windows so `ascom/windows_impl.rs` is exercised. | (Windows only) `bash scripts/rust_checks.sh clippy` |
| Dart format | `Format Check` → `dart-format` | `dart format --set-exit-if-changed` clean on every package. | `melos run gate -- --only dart-format` |
| Rust format | `Format Check` → `rust-format` | `cargo fmt --all -- --check` clean. | `bash scripts/rust_checks.sh fmt` |
| Build test | `build-test` → "Test build Flutter app" | Flutter debug build succeeds on Ubuntu, Windows, and macOS runners. Catches platform-specific build regressions before they reach release. | `cd apps/desktop && flutter build <platform> --debug` |
| Coverage upload | `Dart Tests` → "Upload coverage to Codecov" | The Dart Tests run is instrumented (`--coverage`); it merges and archives the lcov of every Flutter package. The Codecov upload has `fail_ci_if_error: false` and `continue-on-error` until a `CODECOV_TOKEN` secret exists. | `melos run gate -- --stage dart-tests --coverage` |

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
| `Cargo Duplicate Versions` | `scripts/rust_checks.sh duplicates` | Fails when the resolved duplicate-version set differs from `native/skotiq_native/duplicate-versions-baseline.txt`; not a required check, so a drift does not block a merge on its own. |
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

## Release gate

`release.yml` does not re-run these gates; it publishes only a commit that
already passed them. Before the builds and again right before publishing,
`scripts/release_gate.py` refuses unless:

- the run builds the commit the release tag names (a dispatch has to be run
  from the tag);
- that commit is on `origin/main`;
- every check in its `REQUIRED_CHECKS` (the branch-protection list in
  `docs/branch-protection.md` plus `Rust Tests (windows)`) concluded `success`
  on that commit; and
- no published release has that tag. A published release's assets are never
  replaced; a fix ships as a new version.

Publishing also requires every signing credential (`scripts/release_policy.py`),
and `scripts/verify_source_commit.py` checks that every archive's
`SOURCE-COMMIT.txt` names the tag commit. A build-only dispatch gets no signing
keys, so what it builds cannot be published. Local repro:
`python3 scripts/test_release_policy.py && python3 scripts/test_release_gate.py`.

---

## Current gate status

The required gates were red from 2026-11-01 to the 9.0.1 fixes (a time-zone
dependent Smart Night test, a stale driver fixture, an update test reading the
wrong file); 9.0.0 was published around them by hand, which the release gate
above now prevents. Check the live state with
`gh run list --workflow ci.yml --branch main` before relying on this section.

The placeholder/stub and behavioral gates enforce **no new high-risk markers vs
the committed baselines** — `docs/production-readiness/highrisk-baseline.txt` and
`docs/production-readiness/behavioral-audit-register.md` (with its
`.sites.tsv`) — not an absolute-zero
count. An earlier "fail on any high-risk" (absolute-zero) policy was aspirational
and never passed, because the triaged baseline holds reviewed entries that are mostly
fail-loud documentation comments (the Rust `unwrap_or_default()` defaults on
optional driver properties are behavioral findings with their own verdicts).
The enforced policy is therefore baseline-compare (by declaration and line
text, so moved files and line drift cannot trip it) plus the scope check from
`audit-scope.yaml`, which catches a glob change accidentally dropping a
package.

The `undocumented_unsafe_blocks` clippy lint, formerly advisory, is now enforced
as `-D` in the workspace clippy gate (see the "Required gates" table above).

---

## Adding a new required gate

1. Add a `Check` to the stage it belongs to in `tools/production/gate.dart`.
   The CI job of that stage runs it from then on; no workflow edit is needed.
2. Confirm the command exits non-zero on failure (no `|| true`).
3. Add a row to the **Required gates** table above with the local repro
   command, and a melos `audit:*` script (`dart run tools/production/gate.dart
   --only <check>`) if people will run it by name.
4. A new CI job (a new check name) also needs branch protection on `main`
   updated in the GitHub UI, and `REQUIRED_CHECKS` in
   `scripts/release_gate.py`; `scripts/test_release_gate.py` fails when a
   required name is not a CI job.

---

*End of CI gates reference.*
