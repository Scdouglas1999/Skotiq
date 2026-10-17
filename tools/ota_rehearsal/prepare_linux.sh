#!/usr/bin/env bash
# Build every release the Linux scenarios serve, and write scenarios.json.
#
#   prepare_linux.sh <root> <set> <bundle-N> <bundle-N+1> <N-version> <N-build> <N1-version> <N1-build>
#
# Everything lands under <root>/dist/<set>/<scenario>/. Packaging goes through
# package_release.sh, i.e. through build_update_manifest.dart with the same
# arguments release.yml passes, so a manifest here is one CI would publish.
set -euo pipefail

ROOT="$(readlink -f "$1")"; SET="$2"
BN="$(readlink -f "$3")"; BN1="$(readlink -f "$4")"
NV="$5"; NB="$6"; N1V="$7"; N1B="$8"
HERE="$(cd "$(dirname "$0")" && pwd)"
KEYS="$ROOT/keys"
DIST="$ROOT/dist/$SET"
PKG="$HERE/package_release.sh"
rm -rf "$DIST"; mkdir -p "$DIST"

zip_of() { echo "skotiq-$1-$2-$3.zip"; }

# 1. the real thing: N+1, signed with the rehearsal key
"$PKG" "$BN1" "$N1V" "$N1B" linux x64 "$DIST/good" "$KEYS/update_private.b64"

# 2. one byte of the package changed after signing (same size)
mkdir -p "$DIST/tamper"
cp "$DIST/good/manifest-linux-x64.json" "$DIST/tamper/"
cp "$DIST/good/$(zip_of "$N1V" linux x64)" "$DIST/tamper/"
python3 - "$DIST/tamper/$(zip_of "$N1V" linux x64)" <<'PY'
import os, sys
p = sys.argv[1]
with open(p, "r+b") as fh:
    off = os.path.getsize(p) // 2
    fh.seek(off); b = fh.read(1); fh.seek(off); fh.write(bytes([b[0] ^ 0x01]))
PY

# 3. signed, but with a key this build does not trust
"$PKG" "$BN1" "$N1V" "$N1B" linux x64 "$DIST/wrongkey" "$KEYS/other_private.b64"

# 4. unsigned: what CI produces while SKOTIQ_UPDATE_PRIVATE_KEY is unset
"$PKG" "$BN1" "$N1V" "$N1B" linux x64 "$DIST/unsigned" none

# 5. a Windows manifest published under the Linux name
"$PKG" "$BN1" "$N1V" "$N1B" windows x64 "$DIST/mismatch" "$KEYS/update_private.b64"
mv "$DIST/mismatch/manifest-windows-x64.json" "$DIST/mismatch/manifest-linux-x64.json"

# 6. a release that only carries another platform's manifest
mkdir -p "$DIST/otherplatform"
"$PKG" "$BN1" "$N1V" "$N1B" windows x64 "$DIST/otherplatform" "$KEYS/update_private.b64"

# 7. an older build, properly signed (a downgrade offer)
DV="$(python3 -c "import sys; a=sys.argv[1].split('.'); a[-1]=str(int(a[-1])-1); print('.'.join(a))" "$NV")"
DB=$((NB - 1))
"$PKG" "$BN" "$DV" "$DB" linux x64 "$DIST/downgrade" "$KEYS/update_private.b64"

# 8. N+1 that installs cleanly but cannot start: the executable exits 1
BROKEN="$ROOT/builds/$SET-N1-broken"
rm -rf "$BROKEN"; cp -a "$BN1" "$BROKEN"
# The launcher is `skotiq`; the real binary it execs is `skotiq.bin`.
printf '#!/bin/sh\necho "rehearsal: this build refuses to start" >&2\nexit 1\n' > "$BROKEN/skotiq.bin"
chmod 0755 "$BROKEN/skotiq.bin"
printf '%s\n' "N1-broken-$N1V" > "$BROKEN/REHEARSAL-MARKER.txt"
"$PKG" "$BROKEN" "$N1V" "$N1B" linux x64 "$DIST/broken" "$KEYS/update_private.b64"

N1MARK="$(cat "$BN1/REHEARSAL-MARKER.txt")"
python3 "$HERE/write_scenarios.py" "$DIST" "$NV" "$NB" "$N1V" "$N1B" "$DV" "$DB" "$N1MARK" \
  > "$DIST/scenarios.json"
echo "prepared $DIST/scenarios.json"
