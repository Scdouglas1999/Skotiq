#!/usr/bin/env bash
# Skotiq pre-commit hook.
#
# Runs the fast format and lint gates locally so contributors catch trivial
# issues before pushing instead of round-tripping through CI. Reference:
# docs/code-quality/audit-tests.md §7 (CI / Pre-commit), recommendation #1.
#
# Install once after clone with: ./scripts/install-hooks.sh
#
# To skip in an emergency: SKIP_PRECOMMIT=1 git commit ...
# (Skip should be rare — CI runs the same checks and will fail the PR.)

set -euo pipefail

if [[ "${SKIP_PRECOMMIT:-0}" == "1" ]]; then
  echo "[pre-commit] SKIP_PRECOMMIT=1 — skipping local gates."
  exit 0
fi

# ---------------------------------------------------------------------------
# Resolve repository root so the hook works regardless of $PWD when the
# user invokes `git commit` from a subdirectory.
# ---------------------------------------------------------------------------
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Collect staged files by type. We only run formatters on staged files so
# the hook stays fast on partially-staged worktrees.
# ---------------------------------------------------------------------------
STAGED_DART=$(git diff --cached --name-only --diff-filter=ACMR -- '*.dart' | tr '\n' ' ')
STAGED_RUST=$(git diff --cached --name-only --diff-filter=ACMR -- '*.rs' | tr '\n' ' ')

EXIT=0

# ---------------------------------------------------------------------------
# 1. Dart format check on staged Dart files.
# ---------------------------------------------------------------------------
if [[ -n "${STAGED_DART// }" ]]; then
  if ! command -v dart >/dev/null 2>&1; then
    echo "[pre-commit] dart not on PATH — install Flutter SDK or set SKIP_PRECOMMIT=1." >&2
    exit 1
  fi
  echo "[pre-commit] dart format --set-exit-if-changed (staged Dart files)..."
  # shellcheck disable=SC2086
  if ! dart format --output=none --set-exit-if-changed $STAGED_DART; then
    echo "[pre-commit] Dart formatting issues above. Run 'dart format <file>' and re-stage." >&2
    EXIT=1
  fi
fi

# ---------------------------------------------------------------------------
# 2. Rust format check on the whole workspace if any .rs is staged.
#    cargo fmt is fast and operates per-package; running it across the
#    workspace catches violations in files that import from staged modules.
# ---------------------------------------------------------------------------
if [[ -n "${STAGED_RUST// }" ]]; then
  if ! command -v cargo >/dev/null 2>&1; then
    echo "[pre-commit] cargo not on PATH — install Rust toolchain or set SKIP_PRECOMMIT=1." >&2
    exit 1
  fi
  echo "[pre-commit] cargo fmt --all --check (native/skotiq_native)..."
  if ! (cd native/skotiq_native && cargo fmt --all -- --check); then
    echo "[pre-commit] Rust formatting issues above. Run 'cargo fmt --all' in native/skotiq_native and re-stage." >&2
    EXIT=1
  fi
fi

# ---------------------------------------------------------------------------
# 3. dart analyze on staged Dart files only, via the analyzer's
#    package-aware mode. We deliberately do NOT run `melos run analyze`
#    here because it bootstraps the whole workspace; that's CI's job.
#    The local pass is a fast static check on touched files.
# ---------------------------------------------------------------------------
if [[ -n "${STAGED_DART// }" ]]; then
  echo "[pre-commit] dart analyze (staged Dart files)..."
  # shellcheck disable=SC2086
  if ! dart analyze --fatal-infos --fatal-warnings $STAGED_DART; then
    echo "[pre-commit] dart analyze reported issues above. Fix or set SKIP_PRECOMMIT=1 with justification." >&2
    EXIT=1
  fi
fi

if [[ $EXIT -ne 0 ]]; then
  echo "" >&2
  echo "[pre-commit] One or more checks failed. Commit aborted." >&2
  echo "[pre-commit] Re-run after fixing, or use 'SKIP_PRECOMMIT=1 git commit ...' (CI still gates)." >&2
fi

exit $EXIT
