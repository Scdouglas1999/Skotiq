#!/usr/bin/env bash
# Build a WHAT-IF copy of skotiq_core with the catalog projection fix from
# findings H1-1 applied (GnomonicProjection CD branch: x = W/2 + a, y = H/2 + b,
# and the matching inverse). It is NOT product code: it exists so tonight's
# evaluators can see what calibration, transparency and residuals would report
# once the projection is fixed. run-science.sh --whatif-projection uses it.
#
#   make-whatif.sh [dest root]   (default $HOME/.cache/ns-science-1025/whatif)
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PKG="$(cd "$HERE/../.." && pwd)"
REPO="$(cd "$PKG/../.." && pwd)"
DEST="${1:-$HOME/.cache/ns-science-1025/whatif}"

mkdir -p "$DEST/packages" "$DEST/native/skotiq_native/bridge/target/release"
for p in skotiq_bridge skotiq_planetarium skotiq_plugins skotiq_remote_protocol; do
  ln -sfn "$REPO/packages/$p" "$DEST/packages/$p"
done
# Sibling packages import each other by relative paths, so mirror the
# top-level layout.
for d in third_party tools apps lib assets server test_fixtures; do
  [[ -e "$REPO/$d" ]] && ln -sfn "$REPO/$d" "$DEST/$d"
done
ln -sfn "$(readlink -f "$REPO/native/skotiq_native/bridge/target/release/libskotiq_bridge.so")" \
  "$DEST/native/skotiq_native/bridge/target/release/libskotiq_bridge.so"
rsync -a --delete --exclude build --exclude .dart_tool "$PKG/" "$DEST/packages/skotiq_core/"

F="$DEST/packages/skotiq_core/lib/src/services/wcs/gnomonic_projection.dart"
python3 - "$F" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
pairs = [
    ("      x = wcs.imageWidth / 2.0 - a;\n      y = wcs.imageHeight / 2.0 - b;",
     "      x = wcs.imageWidth / 2.0 + a; // WHAT-IF (h1 H1-1)\n      y = wcs.imageHeight / 2.0 + b;"),
    ("      var a = wcs.imageWidth / 2.0 - x;\n      var b = wcs.imageHeight / 2.0 - y;",
     "      var a = x - wcs.imageWidth / 2.0; // WHAT-IF (h1 H1-1)\n      var b = y - wcs.imageHeight / 2.0;"),
]
for old, new in pairs:
    if old not in s:
        sys.exit(f"pattern not found: {old!r}")
    s = s.replace(old, new, 1)
open(p, "w").write(s)
PY
(cd "$DEST/packages/skotiq_core" && flutter pub get --offline >/dev/null)
echo "what-if package ready: $DEST/packages/skotiq_core"
