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
`Build Test (Desktop) (ubuntu-latest)`. These are the checks that run on every PR.
They were red on every commit from 2026-11-01 until the 9.0.1 fixes; check the
live state with `gh run list --workflow ci.yml --branch main`.

Deliberately **not** required:
- **`Code Coverage`** — currently overruns its 20-minute timeout because it
  re-runs the full instrumented test suite (it roughly duplicates `Dart Tests`).
  It is slow, not broken; requiring it would block merges on a timeout rather
  than a code problem. Re-add it once the timeout is raised or the run is
  de-duplicated.
- **`Rust Tests (windows)`** — conditional (push, schedule, `release/*` and
  `fix/*` PRs, `ci:windows-rust` label), so it does not run on most PRs;
  requiring it would block PRs where it never starts. The release gate
  requires it on the commit being released (section 3).
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
audit, fail-closed policy, behavioral audit, bridge boundary, dependency
hygiene, analyzer rollup) are documented gate-by-gate in `docs/ci-gates.md`. Failing any one of
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
  (github.event_name == 'pull_request' && (
    startsWith(github.head_ref, 'release/') ||
    startsWith(github.head_ref, 'fix/') ||
    contains(github.event.pull_request.labels.*.name, 'ci:windows-rust')))
```

In words, the Windows Rust job runs when **any** of these is true:

- the event is a **push** (to `main`, `master`, or `develop`);
- the event is the nightly **schedule**;
- the event is a **pull request** from a `release/*` or `fix/*` branch, the
  branches a release is cut after; or
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

`release.yml` runs on a pushed `v*.*.*` tag, or by `workflow_dispatch` run from
that tag with `release_tag` set to it (to attach the assets to an existing
draft). It builds the Android APKs, the Linux x64 bundle and the Windows x64
package and publishes them.

**The release workflow does not re-run the CI gate suite; it refuses a commit
that has not passed it.** `scripts/release_gate.py` runs in the `version` job,
before an hour of builds, and again in `publish`, right before anything is
uploaded. It refuses unless:

1. The run builds the commit the tag names. A dispatch run from a branch with
   `release_tag` set is refused, so `SOURCE-COMMIT.txt` in every archive is
   the tag commit (`scripts/verify_source_commit.py` checks it).
2. That commit is on `origin/main`. Merge a release branch with a merge commit
   (not a squash), so the tagged commit is an ancestor of `main`.
3. Every check in `REQUIRED_CHECKS` concluded `success` on that commit: the
   required checks of section 1 and `Rust Tests (windows)`, which runs on the
   push to `main` and on `release/*` and `fix/*` pull requests.
4. No published release has the tag. A published release's packages, checksums
   and signed manifests are never replaced; a fix ships as a new version.

Publishing also requires every Android and update signing credential
(`scripts/release_policy.py`), for every channel. A `workflow_dispatch` without
`release_tag` is a build-only validation run: it gets no signing keys, so its
APKs are debug-signed and its OTA manifests unsigned, and nothing it builds can
be published or installed over a release.

The version must also be consistent across the tag, the app pubspecs and
`version.yaml`, and `docs/release/<tag>.md` must exist; the `version` and
`publish` jobs check both.

A run started before these checks existed runs the workflow file of its own
commit. Re-running such a run (for example the cancelled 9.0.0 tag run
43626418799) skips the gate; delete those runs (`gh run delete <id>`) rather
than re-running them.

---

## 4. Verifying a release after the fact

1. **Resolve the tag to its commit:** `git rev-list -n 1 v9.0.1`.
2. **Read the release gate's log line** in the release run's `version` and
   `publish` jobs: it names the commit, confirms it is on `origin/main`, every
   required check green, and the release not yet published.
3. **Compare `SOURCE-COMMIT.txt`** in the release assets with the tag commit.
4. **Inspect the release workflow run** (`gh run list --workflow release.yml`,
   `gh run view <run-id>`): all three platform jobs and `publish` succeeded,
   and `publish` used `fail_on_unmatched_files: true`, so a missing platform
   artifact fails the release rather than shipping a partial one.

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
