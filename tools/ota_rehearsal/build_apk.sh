#!/usr/bin/env bash
# Build one mobile release APK the way release.yml's android job does, signed
# with a THROWAWAY keystore (never the release keystore).
#
#   build_apk.sh <version> <build-number> <public-key-file> <keystore-dir> <out-apk> [abi]
#
# The keystore is created in <keystore-dir> on first use and reused after,
# so N and N+1 share a signing key and Android accepts N+1 as an upgrade.
# [abi] defaults to x86_64, the emulator's ABI; CI builds all three with
# --split-per-abi and this keeps the same per-ABI output naming.
set -euo pipefail

VERSION="$1"; BUILD="$2"; PUBKEY_FILE="$3"; KS_DIR="$(mkdir -p "$4" && readlink -f "$4")"
OUT="$5"; ABI="${6:-x86_64}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PUBKEY="$(tr -d '[:space:]' < "$PUBKEY_FILE")"

KS="$KS_DIR/rehearsal.jks"
if [ ! -f "$KS" ]; then
  keytool -genkeypair -keystore "$KS" -storepass rehearsal -keypass rehearsal \
    -alias rehearsal -keyalg RSA -keysize 2048 -validity 30 \
    -dname "CN=Nightshade OTA rehearsal (throwaway)"
fi

case "$ABI" in
  x86_64) PLATFORM=android-x64 ;;
  arm64-v8a) PLATFORM=android-arm64 ;;
  armeabi-v7a) PLATFORM=android-arm ;;
  *) echo "unknown ABI $ABI" >&2; exit 64 ;;
esac

cd "$REPO/apps/mobile"
cp pubspec.yaml pubspec.yaml.ota-rehearsal.bak
trap 'mv -f "$REPO/apps/mobile/pubspec.yaml.ota-rehearsal.bak" "$REPO/apps/mobile/pubspec.yaml"' EXIT
sed -i -E "s/^version: .*/version: ${VERSION}+${BUILD}/" pubspec.yaml

KEYSTORE_FILE="$KS" KEYSTORE_PASSWORD=rehearsal KEY_ALIAS=rehearsal KEY_PASSWORD=rehearsal \
  flutter build apk --release --split-per-abi --target-platform "$PLATFORM" \
  "--dart-define=NIGHTSHADE_UPDATE_PUBLIC_KEY=$PUBKEY"

mkdir -p "$(dirname "$OUT")"
cp -f "build/app/outputs/flutter-apk/app-$ABI-release.apk" "$OUT"
echo "apk $VERSION+$BUILD ($ABI) -> $OUT"
