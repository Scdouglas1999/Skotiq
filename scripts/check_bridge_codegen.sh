#!/usr/bin/env bash
# Fail when the committed Flutter Rust Bridge output is not what the codegen
# writes from the current Rust API. Regenerates in place (Linux/macOS recipe of
# scripts/dev.sh) and compares the generated paths before and after, so
# uncommitted edits elsewhere are left alone. A stale tree keeps the
# regenerated files for review.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
GENERATED=(
  native/skotiq_native/bridge/src/frb_generated.rs
  packages/skotiq_bridge/lib/src
  packages/skotiq_bridge/ios/bridge_generated.h
  packages/skotiq_bridge/macos/bridge_generated.h
  packages/skotiq_bridge/linux/bridge_generated.h
)

snapshot() {
  git diff --no-ext-diff -- "${GENERATED[@]}"
  git ls-files --others --exclude-standard -- "${GENERATED[@]}"
}

before="$(snapshot | sha256sum)"
clang_resources="$(clang -print-resource-dir 2>/dev/null || true)"
(
  cd native/skotiq_native
  CC=clang CPATH="${clang_resources:+$clang_resources/include:}/usr/include${CPATH:+:$CPATH}" \
    flutter_rust_bridge_codegen generate
)
after="$(snapshot | sha256sum)"

if [ "$before" != "$after" ]; then
  echo "::error::The bridge bindings are stale: flutter_rust_bridge_codegen changed the generated files. Review and commit them (git diff -- ${GENERATED[*]})."
  exit 1
fi
dart run packages/skotiq_bridge/tool/generate_event_wire.dart --check
echo "Bridge bindings and event wire codec match the Rust API."
