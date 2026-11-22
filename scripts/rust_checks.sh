#!/usr/bin/env bash
# The Rust checks of the gate: one definition for the CI Rust jobs (Linux and
# Windows) and `melos run gate`.
#
#   scripts/rust_checks.sh clippy      workspace clippy, warnings and the listed lints denied
#   scripts/rust_checks.sh test        workspace tests, every test binary run
#   scripts/rust_checks.sh fmt         rustfmt check
#   scripts/rust_checks.sh duplicates  the resolved duplicate-version set matches the baseline
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../native/skotiq_native"

case "${1:-}" in
  clippy)
    # result_unit_err forbids `Result<(), ()>`; await_holding_lock catches
    # locks held across `.await` (the FFI deadlock pattern);
    # undocumented_unsafe_blocks requires a `// SAFETY:` comment on every
    # unsafe block (docs/ci-gates.md). clippy::pedantic is not promoted.
    cargo clippy --locked --all-features --workspace --all-targets -- \
      -D warnings -D clippy::result_unit_err -D clippy::await_holding_lock \
      -D clippy::undocumented_unsafe_blocks
    ;;
  test)
    # Light optimization keeps debug assertions and overflow checks but runs
    # the image and autofocus tests several times faster.
    CARGO_PROFILE_TEST_OPT_LEVEL=1 cargo test --locked --all-features --workspace --no-fail-fast
    ;;
  fmt)
    cargo fmt --all -- --check
    ;;
  duplicates)
    # Existing transitive duplicates are baselined; any change to the set must
    # update duplicate-versions-baseline.txt in the same change.
    current="$(mktemp)"
    trap 'rm -f "$current"' EXIT
    cargo metadata --locked --format-version 1 --all-features \
      | jq -r '.packages | sort_by(.name, .version) | group_by(.name)[] | select(map(.version) | unique | length > 1) | .[] | "\(.name) \(.version)"' \
      | LC_ALL=C sort -u > "$current"
    if ! diff -u duplicate-versions-baseline.txt "$current"; then
      echo "::error::The resolved duplicate-version set changed. Review the graph and update duplicate-versions-baseline.txt intentionally."
      exit 1
    fi
    echo "Duplicate-version baseline matches ($(wc -l < "$current") package-version entries)."
    ;;
  *)
    echo "usage: $0 clippy|test|fmt|duplicates" >&2
    exit 2
    ;;
esac
