#!/usr/bin/env bash
# Make an isolated copy of skotiq_core for projection comparison runs.
# The corrected CD projection is included in 9.1. Experiments can edit the
# copied package without changing the package used for production runs.
#
#   make-whatif.sh [dest root]   (default $HOME/.cache/ns-science-1025/whatif)
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PKG="$(cd "$HERE/../.." && pwd)"
REPO="$(cd "$PKG/../.." && pwd)"
DEST="${1:-$HOME/.cache/ns-science-1025/whatif}"

if [[ "$(realpath -m "$DEST/packages/skotiq_core")" == "$PKG" ]]; then
  echo "Choose a separate destination for the comparison package." >&2
  exit 2
fi
mkdir -p "$DEST/packages" "$DEST/native/skotiq_native/bridge/target/release"
for sibling in "$REPO"/packages/*; do
  [[ -d "$sibling" && "$sibling" != "$PKG" ]] || continue
  ln -sfn "$sibling" "$DEST/packages/${sibling##*/}"
done
# Sibling packages import each other by relative paths, so mirror the
# top-level layout.
for d in third_party tools apps lib assets server test_fixtures; do
  [[ -e "$REPO/$d" ]] && ln -sfn "$REPO/$d" "$DEST/$d"
done
ln -sfn "$REPO/native/skotiq_native/bridge/target/release/libskotiq_bridge.so" \
  "$DEST/native/skotiq_native/bridge/target/release/libskotiq_bridge.so"
rsync -a --delete --exclude build --exclude .dart_tool "$PKG/" "$DEST/packages/skotiq_core/"

(cd "$DEST/packages/skotiq_core" && flutter pub get --offline >/dev/null)
echo "what-if package ready: $DEST/packages/skotiq_core"
