#!/usr/bin/env bash
# Install the Skotiq pre-commit hook.
#
# Run once after cloning the repo:
#   ./scripts/install-hooks.sh
#
# This copies scripts/pre-commit.sh into .git/hooks/pre-commit and makes it
# executable. We deliberately copy rather than symlink because Windows git
# does not always respect symlinks in .git/hooks.
#
# Reference: docs/code-quality/audit-tests.md §7 recommendation #1.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK_SRC="$REPO_ROOT/scripts/pre-commit.sh"
HOOK_DEST="$REPO_ROOT/.git/hooks/pre-commit"

if [[ ! -f "$HOOK_SRC" ]]; then
  echo "install-hooks: source hook not found at $HOOK_SRC" >&2
  exit 1
fi

if [[ ! -d "$REPO_ROOT/.git" ]]; then
  echo "install-hooks: .git directory not found — are you in a worktree without one?" >&2
  echo "install-hooks: for git worktrees the hook should be installed in the primary checkout." >&2
  exit 1
fi

mkdir -p "$(dirname "$HOOK_DEST")"
cp "$HOOK_SRC" "$HOOK_DEST"
chmod +x "$HOOK_DEST"

echo "install-hooks: installed pre-commit hook -> $HOOK_DEST"
echo "install-hooks: hooks will run on every 'git commit'. Skip with SKIP_PRECOMMIT=1 git commit ..."
