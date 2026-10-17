# Branch Protection & Release-Readiness

> This document records the required-checks policy for `main` in the Skotiq
> repository so it is reviewable in-repo. Branch protection is configured via the
> GitHub API / UI (Settings → Branches), not in YAML; the rules below describe
> what that configuration enforces.
>
> For the full per-gate detail (what each gate enforces, plus the exact local
> reproduction command), see [`docs/ci-gates.md`](./ci-gates.md). This document
> does not repeat that table.

## Current state (enabled 2026-06-18)

Branch protection **is enabled** on `main` with these **required status checks**:
`Analyze`, `Launch Gate`, `Dart Tests`, `Rust Tests (linux)`, `Format Check`, and
`Build Test (Desktop) (ubuntu-latest)`. These are the checks that run on every PR
and are currently green.

Deliberately **not** required:
- **`Code Coverage`** — currently overruns its 20-minute timeout because it
  re-runs the full instrumented test suite (it roughly duplicates `Dart Tests`).
  It is slow, not broken; requiring it would block merges on a timeout rather
  than a code problem. Re-add it once the timeout is raised or the run is
  de-duplicated.
- **`Rust Tests (windows)`** — conditional (push/schedule/`ci:windows-rust`
  label), so it does not run on most PRs; requiring it would block PRs where it
  never starts.
- **`Cargo Duplicate Versions`** — advisory (never fails the build).

**Admin bypass is intentionally left on** (`enforce_admins: false`): the
maintainer can still push directly to `main`. Pull-request reviews are not
required (solo maintainer). Verify the live configuration with:

```bash
gh api repos/Scdouglas1999/Skotiq/branches/main/protection \
  --jq '{checks: .required_status_checks.contexts, enforce_admins: .enforce_admins.enabled}'
```

---

## 1. Required status checks for merging to `main`

Pull requests target `main` (and `master`). Every job below comes from
`.github/workflows/ci.yml` and must be green before a PR may merge. Each job
maps to one or more required status checks in branch protection:

| CI job (`ci.yml`) | Status check name | When it runs |
|-------------------|-------------------|--------------|
| `analyze` | Analyze | Every PR + push |
| `launch-gate` | Launch Gate | Every PR + push |
| `test-dart` | Dart Tests | Every PR + push |
| `test-rust` | Rust Tests (linux) | Every PR + push |
| `format-check` | Format Check | Every PR + push |
| `build-test` | Build Test (Desktop) — Ubuntu, Windows, macOS matrix | Every PR + push |
| `coverage` | Code Coverage | Every PR + push |
| `test-rust-windows` | Rust Tests (windows) | Conditional — see section 2 |

The `cargo-duplicates` job is **advisory**: it only emits a build warning
annotation and never exits non-zero, so it should **not** be a required check.
See the advisory tier in `docs/ci-gates.md`.

The individual gate steps inside `analyze` and `launch-gate` (placeholder
audit, fail-closed policy, behavioral audit, dependency hygiene, analyzer
rollup) are documented gate-by-gate in `docs/ci-gates.md`. Failing any one of
them fails its job, which turns the corresponding required check red.

CI also runs on `push` to `main`, `master`, and `develop`, and on a nightly
`schedule` (cron `0 4 * * *`). Those triggers do not gate merges directly, but
the push run on `main` is what proves a merged commit is green (see section 4).

Two more workflows exist but are **not** PR merge gates:

- `linux-release-build.yml` — `workflow_dispatch`, plus a PR run scoped to
  desktop/native/script path changes. It packages the Linux bundle and runs the
  glibc floor + headless smoke checks.
- `hardware-compatibility.yml` — `workflow_dispatch`, plus a PR run scoped to
  `native/**` and compat-tool changes.

`windows-release-build.yml` is `workflow_dispatch`-only.

---

## 2. When the Windows Rust job runs

`test-rust-windows` is conditional. The exact `if:` expression in `ci.yml` is:

```yaml
if: >-
  github.event_name == 'push' ||
  github.event_name == 'schedule' ||
  (github.event_name == 'pull_request' && contains(github.event.pull_request.labels.*.name, 'ci:windows-rust'))
```

In words, the Windows Rust job runs when **any** of these is true:

- the event is a **push** (to `main`, `master`, or `develop`);
- the event is the nightly **schedule**; or
- the event is a **pull request** carrying the `ci:windows-rust` label.

**Why it is gated this way.** The ASCOM integration (`ascom/`, including
`ascom/windows_impl.rs`) is a Windows-only crate built around COM; it compiles
and tests **only** on a Windows runner. Without this job that crate would get
zero CI exercise. Running it on every PR would add a ~45-minute
`windows-latest` job to the critical path, so most PRs skip it and instead rely
on:

1. the **push** run when the PR merges to `main` (the Windows crate is verified
   post-merge, before any release is cut from that commit), and
2. the nightly **schedule** run as a backstop.

The `ci:windows-rust` label is the opt-in escape hatch: add it to any PR that
touches `ascom/` so the Windows crate is verified **before** merge rather than
after.

Because `test-rust-windows` does not run on most PRs, branch protection should
treat it as required **only** in contexts where it actually runs (push/nightly
or labeled PRs). A check that is skipped on a given PR is reported as
not-applicable and must not block that PR.

---

## 3. What must pass before tagging a release

`release.yml` is **tag-triggered**: it fires on pushing a tag matching
`v*.*.*` (e.g. `git tag v4.1.0 && git push origin v4.1.0`), with a
`workflow_dispatch` for on-demand artifact rebuilds. It builds the Android APK,
the Linux x64 bundle, and the Windows x64 package, then publishes them to a
public GitHub Release.

**The release workflow does not re-run the CI gate suite.** It assumes the
commit it builds is already green. Therefore the release precondition is:

1. The commit you are about to tag is already merged to `main`.
2. The CI run for that commit on `main` is fully green — every required check
   from section 1, **including** the `test-rust-windows` job (which runs on the
   push to `main`, so a merged commit has been Windows-verified).
3. The version is consistent across the tag, the app pubspecs, and the
   `APP_VERSION` env in `release.yml` (currently `4.1.0`). The published
   artifact file names derive from `APP_VERSION`, and the release notes are read
   from `docs/release/<tag>.md` (e.g. `docs/release/v4.1.0.md`), so that file
   must exist for the tagged version.

Only tag a commit that satisfies all three. A tag pointing at a red or
unverified commit will still build and publish artifacts, because nothing in
`release.yml` checks gate status — the discipline lives here, not in the YAML.

---

## 4. Verifying a release tag was built from green CI

A release tag is trustworthy only if the commit it points at has a passing CI
run on `main`. To verify after the fact:

1. **Resolve the tag to its commit SHA:**

   ```bash
   git rev-list -n 1 v4.1.0
   ```

2. **Confirm that SHA has a passing CI run on `main`.** Either use the Actions
   UI (filter the `CI` workflow by branch `main` and locate the commit), or the
   `gh` CLI:

   ```bash
   gh run list --workflow ci.yml --branch main --commit <SHA>
   gh run view <run-id>
   ```

   Every required check from section 1 should be `success`. Confirm
   `Rust Tests (windows)` ran and passed on that push run — it is the proof the
   Windows-only ASCOM crate was exercised for the released commit.

3. **Inspect the release workflow run for the tag** to confirm all three
   platform build jobs (`android`, `linux`, `windows`) and `publish` succeeded:

   ```bash
   gh run list --workflow release.yml
   gh run view <run-id>
   ```

   The `publish` job runs only for tag refs
   (`if: startsWith(github.ref, 'refs/tags/')`) and publishes with
   `fail_on_unmatched_files: true`, so a missing platform artifact fails the
   release rather than shipping a partial one.

---

## 5. Note on where this policy lives

Branch protection is enforced by GitHub repository settings
(Settings → Branches → branch protection rule for `main`), not by any file in
this repository. GitHub Actions YAML defines *which checks exist and when they
run*; it cannot mark a check as *required* to merge. This document exists so the
intended required-checks policy is version-controlled and reviewable alongside
the code, and so that adding or changing a gate prompts a matching update to the
GitHub-side configuration. When a required gate is added in `ci.yml`, also add
its job to the required-checks list in the branch protection rule — see the
"Adding a new required gate" section of `docs/ci-gates.md`.
