#!/usr/bin/env bash
# Package and sign one release target exactly as release.yml does.
#
#   package_release.sh <payload> <version> <build> <platform> <arch> <out-dir> <key-file|none>
#
# <payload> is a bundle directory (linux/windows: zipped + every file hashed)
# or an APK (android: the APK is its own package). The download URL is the
# per-tag GitHub Releases link CI bakes into the signed manifest, so the
# rehearsal server has to answer it at github.com, as GitHub does.
#
# <key-file> holds a base64 Ed25519 seed (NIGHTSHADE_UPDATE_PRIVATE_KEY in
# CI); "none" writes an unsigned manifest, which is what CI produces while the
# secret is unset and what the live v7.1.0 release carries.
set -euo pipefail

PAYLOAD="$(readlink -f "$1")"; VERSION="$2"; BUILD="$3"; PLATFORM="$4"; ARCH="$5"
OUT="$(mkdir -p "$6" && readlink -f "$6")"; KEY="$7"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OWNER_REPO="${NS_OTA_REPO:-Scdouglas1999/Nightshade}"

if [ -d "$PAYLOAD" ]; then
  ASSET="nightshade-${VERSION}-${PLATFORM}-${ARCH}.zip"
  EXTRA=(--package-name "$ASSET")
else
  ASSET="$(basename "$PAYLOAD")"
  EXTRA=()
fi
URL="https://github.com/${OWNER_REPO}/releases/download/v${VERSION}/${ASSET}"

if [ "$KEY" = "none" ]; then
  SEED=""
else
  SEED="$(tr -d '[:space:]' < "$KEY")"
fi

(cd "$REPO/packages/nightshade_updater" && \
  NIGHTSHADE_UPDATE_PRIVATE_KEY="$SEED" dart run tool/build_update_manifest.dart \
    --payload "$PAYLOAD" \
    --out-dir "$OUT" \
    --version "$VERSION" \
    --build-number "$BUILD" \
    --platform "$PLATFORM" \
    --arch "$ARCH" \
    "${EXTRA[@]}" \
    --download-url "$URL")
if [ ! -d "$PAYLOAD" ]; then cp -f "$PAYLOAD" "$OUT/$ASSET"; fi
echo "$OUT/manifest-${PLATFORM}-${ARCH}.json"
