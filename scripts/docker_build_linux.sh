#!/usr/bin/env bash
# Linux release build for Skotiq, run inside the cirruslabs/flutter image.
# Builds a clean source snapshot of the committed HEAD (mounted read-only at
# /host) so the host's Windows .dart_tool/build dirs are never touched, then
# emits a packaged bundle tarball to /out.
set -euo pipefail

PRINT_BUILD_METADATA=0
for arg in "$@"; do
  case "$arg" in
    --print-build-metadata) PRINT_BUILD_METADATA=1 ;;
    -h|--help)
      echo "Usage: $0 [--print-build-metadata]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

SOURCE_ROOT="${SKOTIQ_SOURCE_ROOT:-/host}"
if [ ! -d "$SOURCE_ROOT" ]; then
  SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

HOST_ARCH="${SKOTIQ_LINUX_ARCH:-$(uname -m)}"
case "$HOST_ARCH" in
  x86_64|amd64) FLUTTER_ARCH=x64 ;;
  aarch64|arm64) FLUTTER_ARCH=arm64 ;;
  *)
    echo "Unsupported Linux desktop architecture: $HOST_ARCH" >&2
    echo "Expected x86_64/amd64 or aarch64/arm64." >&2
    exit 1
    ;;
esac

VERSION="${SKOTIQ_VERSION:-}"
if [ -z "$VERSION" ] && [ -f "$SOURCE_ROOT/version.yaml" ]; then
  VERSION=$(sed -n 's/^version:[[:space:]]*"\{0,1\}\([^"# ]*\).*/\1/p' "$SOURCE_ROOT/version.yaml" | head -1)
fi
if [ -z "$VERSION" ] && [ -f "$SOURCE_ROOT/apps/desktop/pubspec.yaml" ]; then
  VERSION=$(sed -n 's/^version:[[:space:]]*\([^+ ]*\).*/\1/p' "$SOURCE_ROOT/apps/desktop/pubspec.yaml" | head -1)
fi
VERSION="${VERSION:-0.0.0}"
ARTIFACT_NAME="${SKOTIQ_ARTIFACT_NAME:-skotiq-linux-${FLUTTER_ARCH}-${VERSION}.tar.gz}"
BUNDLE="build/linux/${FLUTTER_ARCH}/release/bundle"

echo "== build target: linux/${FLUTTER_ARCH} (${HOST_ARCH}), version ${VERSION} =="

if [ "$PRINT_BUILD_METADATA" -eq 1 ]; then
  echo "SOURCE_ROOT=$SOURCE_ROOT"
  echo "HOST_ARCH=$HOST_ARCH"
  echo "FLUTTER_ARCH=$FLUTTER_ARCH"
  echo "VERSION=$VERSION"
  echo "BUNDLE=$BUNDLE"
  echo "ARTIFACT_NAME=$ARTIFACT_NAME"
  exit 0
fi

echo "== [1/7] apt deps =="
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y build-essential clang cmake ninja-build pkg-config \
  libgtk-3-dev libsecret-1-dev libjsoncpp-dev libssl-dev \
  libudev-dev libusb-1.0-0-dev libraw-dev \
  curl git unzip xz-utils tar ca-certificates rsync xvfb xauth binutils

echo "== [2/7] rust toolchain =="
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
# shellcheck disable=SC1091
. "$HOME/.cargo/env"
rustc --version

echo "== [3/7] source snapshot from the working tree (includes local edits) =="
# Copy the live working tree (so an iterating developer's uncommitted edits are
# built) while excluding the .git dir and the heavy, platform-specific build
# caches that don't belong in a fresh Linux build.
rm -rf /work && mkdir -p /work
# NOTE: rsync include/exclude patterns without a leading slash match a dir of
# that name at ANY depth. A bare `--exclude=target/` therefore wrongly drops
# source dirs like `packages/skotiq_core/lib/src/models/target/`. We anchor
# the Rust `target/` cache to its real location and only exclude `build/` /
# `.dart_tool/` directories that are direct children of a package/app dir (the
# generated Flutter/Dart caches), never deeper source folders.
rsync -a \
  --exclude='.git/' \
  --exclude='/dist-linux/' --exclude='/dist-release/' \
  --exclude='/native/skotiq_native/target/' \
  --exclude='/packages/*/build/' --exclude='/packages/*/.dart_tool/' \
  --exclude='/apps/*/build/' --exclude='/apps/*/.dart_tool/' \
  --exclude='/build/' --exclude='/.dart_tool/' \
  /host/ /work/
cd /work

# This is a Linux DESKTOP build. The mobile app is not built here, and its
# path-dependency on the desktop app trips `melos bootstrap` on Linux. Drop the
# mobile app from the workspace so bootstrap only has to resolve the desktop
# dependency graph (mobile is a leaf app — nothing the desktop build needs
# depends on it).
#
# `apps/mobile_e2e` is a test-only seam package that path-depends on
# `skotiq_mobile`; once the mobile app is removed its dependency can't
# resolve and `melos bootstrap` fails with "could not find package
# skotiq_mobile at ../mobile". It's never built for the Linux desktop
# target either, so drop it too.
rm -rf /work/apps/mobile /work/apps/mobile_e2e

# Melos-managed pubspec_overrides.yaml files are auto-generated and can carry
# host-OS-specific path separators (a Windows bootstrap writes backslash paths
# like `..\\..\\packages\\foo`, which Dart on Linux cannot resolve). Delete them
# so `melos bootstrap` below regenerates clean POSIX-path overrides for Linux.
find /work -name pubspec_overrides.yaml -delete

echo "== [4/7] flutter linux desktop =="
# When the base image doesn't already ship Flutter (e.g. a plain
# debian:bookworm-slim chosen so the bundle's glibc floor matches Raspberry Pi
# OS Bookworm), bootstrap a pinned SDK here. cirruslabs/flutter images already
# have `flutter` on PATH, so this is a no-op there. Pin with SKOTIQ_FLUTTER_REF
# (defaults to the version CI builds with).
if ! command -v flutter >/dev/null 2>&1; then
  FLUTTER_REF="${SKOTIQ_FLUTTER_REF:-3.44.1}"
  echo "flutter not found; cloning SDK ($FLUTTER_REF) into /opt/flutter"
  git config --global --add safe.directory /opt/flutter || true
  git clone --depth 1 --branch "$FLUTTER_REF" \
    https://github.com/flutter/flutter.git /opt/flutter
  export PATH="/opt/flutter/bin:$PATH"
  flutter precache --linux
fi
flutter config --enable-linux-desktop >/dev/null
flutter --version

echo "== [5/7] melos bootstrap =="
dart pub global activate melos
export PATH="$PATH:$HOME/.pub-cache/bin"
dart run melos bootstrap

echo "== [6/7] rust bridge (release) =="
cargo build --release --manifest-path native/skotiq_native/bridge/Cargo.toml

echo "== [7/7] flutter build linux (release) =="
cd apps/desktop
flutter build linux --release

echo "== bundle contents =="
ls -lah "$BUNDLE"
# Ensure the Rust shared library is present in the bundle's lib/ (mirror the
# Windows packaging step, which copies the bridge DLL next to the exe).
SO=$(find /work/native/skotiq_native/target/release -maxdepth 1 -name 'libskotiq_bridge.so' -o -name 'skotiq_bridge.so' 2>/dev/null | head -1 || true)
if [ -n "${SO:-}" ] && [ ! -f "$BUNDLE/lib/$(basename "$SO")" ]; then
  echo "Copying $(basename "$SO") into bundle/lib/"
  mkdir -p "$BUNDLE/lib"
  cp "$SO" "$BUNDLE/lib/"
fi

# Optional redistributable vendor SDK shared libraries. The native Rust loaders
# search the executable directory and bundle/lib before /usr/lib, so copying
# arm64/x64 vendor .so files here makes appliance builds self-contained where
# the vendor license allows redistribution. Keep this opt-in: some SDKs must be
# installed from vendor packages instead.
if [ -n "${SKOTIQ_VENDOR_LIB_DIR:-}" ]; then
  if [ ! -d "$SKOTIQ_VENDOR_LIB_DIR" ]; then
    echo "ERROR: SKOTIQ_VENDOR_LIB_DIR is not a directory: $SKOTIQ_VENDOR_LIB_DIR" >&2
    exit 1
  fi
  echo "== vendor SDK libraries from $SKOTIQ_VENDOR_LIB_DIR =="
  mkdir -p "$BUNDLE/lib"
  find "$SKOTIQ_VENDOR_LIB_DIR" -maxdepth 1 -type f \
    \( -name '*.so' -o -name '*.so.*' \) \
    -exec cp -av {} "$BUNDLE/lib/" \;
fi

echo "== headless smoke test =="
# Confirm the built binary links (no missing symbols / unresolved .so deps) and
# starts in headless mode without crashing. The bridge .so is loaded at runtime
# via the Flutter bundle's lib/ rpath, so a clean headless boot proves the
# Dart<->Rust FFI library resolves on Linux. We run under xvfb because the GTK
# embedder still initialises a display even in headless app mode.
EXE="$BUNDLE/skotiq_desktop"
if [ ! -x "$EXE" ]; then
  # Fall back to whatever single executable the bundle produced.
  EXE=$(find "$BUNDLE" -maxdepth 1 -type f -executable | head -1)
fi
echo "Smoke-testing: $EXE"
# ldd should resolve every dependency (the bridge .so lives in lib/).
LD_LIBRARY_PATH="$PWD/$BUNDLE/lib" ldd "$EXE" || true
set +e
LD_LIBRARY_PATH="$PWD/$BUNDLE/lib" SKOTIQ_HEADLESS=1 \
  timeout 45s xvfb-run -a "$EXE" --headless
SMOKE_RC=$?
set -e
# timeout returns 124 when it kills a still-running (healthy, long-lived) app;
# treat that as success. A non-zero, non-124 exit means it crashed on boot.
if [ "$SMOKE_RC" != "0" ] && [ "$SMOKE_RC" != "124" ]; then
  echo "HEADLESS SMOKE FAILED (exit $SMOKE_RC)"
  exit 1
fi
echo "Headless smoke OK (exit $SMOKE_RC)"

# --- glibc floor guard -------------------------------------------------------
# The headless smoke test above runs INSIDE this build container, so it proves
# nothing about whether the bundle runs on the *deployment* target. The Pi
# appliance ships Raspberry Pi OS / Debian Bookworm (glibc 2.36), but a build
# done on a newer host (e.g. Ubuntu 24.04 / glibc 2.39) silently bakes a 2.38+
# floor into the Rust bridge AND the from-source Flutter plugins
# (flutter_secure_storage, flutter_webrtc). Such a bundle
# aborts on boot on Bookworm with "GLIBC_2.38 not found" — invisible here.
# Fail the build loudly if any bundle binary requires glibc newer than the
# target floor. Override the floor with SKOTIQ_GLIBC_FLOOR (default 2.36 =
# Bookworm); set it empty to skip the check.
GLIBC_FLOOR="${SKOTIQ_GLIBC_FLOOR-2.36}"
if [ -n "$GLIBC_FLOOR" ] && command -v objdump >/dev/null 2>&1; then
  echo "== glibc floor guard (target <= $GLIBC_FLOOR) =="
  floor_major=${GLIBC_FLOOR%%.*}
  floor_minor=${GLIBC_FLOOR#*.}
  glibc_violations=0
  for bin in "$EXE" "$BUNDLE"/lib/*.so; do
    [ -f "$bin" ] || continue
    # `|| true` is load-bearing: under `set -euo pipefail` a binary with no
    # GLIBC_* symbols (e.g. libapp.so) makes grep exit 1, which would otherwise
    # abort the whole build mid-guard.
    maxv=$(objdump -T "$bin" 2>/dev/null \
      | grep -oE 'GLIBC_2\.[0-9]+' | sort -V | tail -1 || true)
    [ -n "$maxv" ] || continue
    v=${maxv#GLIBC_}
    major=${v%%.*}; minor=${v#*.}
    if [ "$major" -gt "$floor_major" ] || \
       { [ "$major" -eq "$floor_major" ] && [ "$minor" -gt "$floor_minor" ]; }; then
      echo "  VIOLATION: $(basename "$bin") needs $maxv (> $GLIBC_FLOOR)"
      glibc_violations=$((glibc_violations + 1))
    fi
  done
  if [ "$glibc_violations" -gt 0 ]; then
    echo "GLIBC FLOOR CHECK FAILED: $glibc_violations binary(ies) require a"
    echo "glibc newer than the $GLIBC_FLOOR deployment target. Build on a base"
    echo "image whose glibc matches the appliance OS (Debian Bookworm) so the"
    echo "Rust bridge and native Flutter plugins link against glibc <= $GLIBC_FLOOR."
    exit 1
  fi
  echo "glibc floor OK (no binary exceeds $GLIBC_FLOOR)"
fi

mkdir -p /out
cd "$BUNDLE"
tar -czf "/out/$ARTIFACT_NAME" .
echo "DONE -> /out/$ARTIFACT_NAME"
ls -lah /out/
