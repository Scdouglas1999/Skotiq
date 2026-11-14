#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo '::error::No release APKs to verify.' >&2
  exit 1
fi
apksigner="${APKSIGNER:-$(find "$ANDROID_HOME/build-tools" -name apksigner -type f | sort -V | tail -1)}"
[ -n "$apksigner" ] || { echo '::error::Android apksigner is unavailable.' >&2; exit 1; }
report="$(mktemp)"
trap 'rm -f "$report"' EXIT
for apk in "$@"; do
  "$apksigner" verify --verbose --print-certs "$apk" > "$report"
  # An explicitly supplied release identity must never be the standard debug
  # certificate, even when CI is only building artifacts for review.
  if { [ "${SKOTIQ_REQUIRE_RELEASE_SIGNING:-false}" = true ] || [ -n "${KEYSTORE_FILE:-}" ]; } &&
      grep -Eiq 'certificate DN:.*CN[[:space:]]*=[[:space:]]*Android Debug([,[:space:]]|$)' "$report"; then
    echo "::error::$apk uses the Android Debug certificate; release signing refused." >&2
    exit 1
  fi
  echo "Verified APK signature: $apk"
done
