#!/usr/bin/env bash
# Build one Linux release bundle the way .github/workflows/release.yml does,
# then copy it out so a second build can run without overwriting it.
#
#   build_bundle.sh <version> <build-number> <public-key-file> <out-dir> [marker]
#
# Mirrors the release job step for step: Rust bridge (release), flutter build
# linux --release with SKOTIQ_UPDATE_PUBLIC_KEY, libraw copied into lib/,
# the hermetic libsqlite3 check, the `skotiq` launcher, the `updater`
# binary installed 0755, and the license/commit files the tar step adds. The
# only thing CI sets that this does not is the version, which CI takes from
# the pubspec; here it comes from --build-name/--build-number so N and N+1
# can be built from one tree.
#
# [marker] is written to REHEARSAL-MARKER.txt in the bundle, so which build is
# installed can be read off the disk as well as off /api/system/version.
#
# Env: CARGO_TARGET_DIR (default <repo>/native/skotiq_native/target),
#      SKIP_RUST=1 to reuse an already-built bridge + updater.
set -euo pipefail

VERSION="$1"; BUILD="$2"; PUBKEY_FILE="$3"; OUT="$4"; MARKER="${5:-}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET="${CARGO_TARGET_DIR:-$REPO/native/skotiq_native/target}"
PUBKEY="$(tr -d '[:space:]' < "$PUBKEY_FILE")"

cd "$REPO"
if [ "${SKIP_RUST:-0}" != "1" ]; then
  cargo build --locked --release --manifest-path native/skotiq_native/bridge/Cargo.toml
  cargo build --locked --release --package skotiq_updater \
    --manifest-path native/skotiq_native/Cargo.toml
fi

# apps/desktop/linux/CMakeLists.txt installs the bridge from
# native/skotiq_native/target/release only. With a private
# CARGO_TARGET_DIR the library has to be put where CMake looks.
CMAKE_RUST_DIR="$REPO/native/skotiq_native/target/release"
if [ "$(readlink -f "$TARGET/release")" != "$(readlink -f "$CMAKE_RUST_DIR" 2>/dev/null || true)" ]; then
  mkdir -p "$CMAKE_RUST_DIR"
  cp -f "$TARGET/release/libskotiq_bridge.so" "$CMAKE_RUST_DIR/"
fi

# The version a Linux build reports (package_info reads
# data/flutter_assets/version.json) comes from the pubspec: --build-name and
# --build-number reach CMake's FLUTTER_VERSION but not version.json (checked
# with Flutter 3.44.1). CI builds from the pubspec too, so set it there for
# the duration of the build and put it back afterwards.
PUBSPEC="apps/desktop/pubspec.yaml"
cp "$PUBSPEC" "$PUBSPEC.ota-rehearsal.bak"
trap 'mv -f "$REPO/$PUBSPEC.ota-rehearsal.bak" "$REPO/$PUBSPEC"' EXIT
sed -i -E "s/^version: .*/version: ${VERSION}+${BUILD}/" "$PUBSPEC"

(cd apps/desktop && flutter build linux --release \
  "--dart-define=SKOTIQ_UPDATE_PUBLIC_KEY=$PUBKEY")
grep -q "\"version\":\"$VERSION\",\"build_number\":\"$BUILD\"" \
  apps/desktop/build/linux/x64/release/bundle/data/flutter_assets/version.json \
  || { echo "bundle does not report $VERSION+$BUILD" >&2; exit 1; }

BUNDLE="apps/desktop/build/linux/x64/release/bundle"
BUNDLE_LIB="$BUNDLE/lib"
[ -e "$BUNDLE_LIB/libskotiq_bridge.so" ] || { echo "bridge missing" >&2; exit 1; }
LIBRAW_PATH="$(ldconfig -p | awk '/libraw\.so/ && !found {print $NF; found=1}')"
cp -Lv "$LIBRAW_PATH" "$BUNDLE_LIB/"
if [ ! -f "$BUNDLE_LIB/libsqlite3.so" ] || [ -L "$BUNDLE_LIB/libsqlite3.so" ]; then
  echo "MISSING: hermetic $BUNDLE_LIB/libsqlite3.so" >&2; exit 1
fi
# The flutter binary lands as `skotiq`; the shipped layout parks it at
# `skotiq.bin` so `skotiq` can be this launcher (matches the release
# workflows, which do the same move).
mv "$BUNDLE/skotiq" "$BUNDLE/skotiq.bin"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")" && pwd)"'
  printf '%s\n' 'export LD_LIBRARY_PATH="$HERE/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"'
  printf '%s\n' '# Frameless GTK window under native Wayland runs headless-invisible'
  printf '%s\n' '# (no surface ever shows); XWayland is the path every tested launch'
  printf '%s\n' '# used. Force it until the Wayland surface path is fixed and proven.'
  printf '%s\n' 'export GDK_BACKEND=x11'
  printf '%s\n' 'exec "$HERE/skotiq.bin" "$@"'
} > "$BUNDLE/skotiq"
chmod +x "$BUNDLE/skotiq"
install -m 0755 "$TARGET/release/updater" "$BUNDLE/updater"
cp LICENSE "$BUNDLE/SKOTIQ-LICENSE.txt"
cp docs/THIRD_PARTY_NOTICES.md "$BUNDLE/THIRD_PARTY_NOTICES.md"
git rev-parse HEAD > "$BUNDLE/SOURCE-COMMIT.txt"
mkdir -p "$BUNDLE/LICENSES"
cp third_party/licenses/LGPL-2.1.txt "$BUNDLE/LICENSES/LGPL-2.1.txt"
if [ -n "$MARKER" ]; then printf '%s\n' "$MARKER" > "$BUNDLE/REHEARSAL-MARKER.txt"; fi

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
cp -a "$BUNDLE" "$OUT"
echo "bundle $VERSION+$BUILD -> $OUT"
