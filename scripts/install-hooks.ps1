# Install the Skotiq pre-commit hook on Windows.
#
# Run once after cloning the repo from PowerShell:
#   .\scripts\install-hooks.ps1
#
# The hook itself is a bash script (scripts/pre-commit.sh). Windows git
# invokes hooks via the bundled MSYS2 bash, so .sh works on Windows out
# of the box as long as Git for Windows is installed.
#
# Reference: docs/code-quality/audit-tests.md §7 recommendation #1.

$ErrorActionPreference = 'Stop'

$repoRoot = (git rev-parse --show-toplevel).Trim()
if (-not $repoRoot) {
    Write-Error "install-hooks: not inside a git checkout."
    exit 1
}

$hookSrc  = Join-Path $repoRoot 'scripts/pre-commit.sh'
$hookDest = Join-Path $repoRoot '.git/hooks/pre-commit'

if (-not (Test-Path $hookSrc)) {
    Write-Error "install-hooks: source hook not found at $hookSrc"
    exit 1
}

$hooksDir = Split-Path $hookDest -Parent
if (-not (Test-Path $hooksDir)) {
    Write-Error "install-hooks: $hooksDir does not exist. For git worktrees install the hook in the primary checkout."
    exit 1
}

Copy-Item -LiteralPath $hookSrc -Destination $hookDest -Force

Write-Host "install-hooks: installed pre-commit hook -> $hookDest"
Write-Host "install-hooks: hooks will run on every 'git commit'. Skip with SKIP_PRECOMMIT=1 git commit ..."
