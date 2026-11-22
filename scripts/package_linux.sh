#!/usr/bin/env bash
# Linux release packaging, one recipe for release.yml and
# linux-release-build.yml. Run from the repository root after
# `dart scripts/build.dart desktop linux`.
#
#   scripts/package_linux.sh libs <bundle> [--libraw stage|ldconfig]
#       check the bridge and the hermetic sqlite, bundle LibRaw, write the launcher
#   scripts/package_linux.sh updater <bundle>
#       build the Rust updater and put it in the bundle
#   scripts/package_linux.sh glibc-floor <bundle> [--versioned-libs]
#       fail when a bundled binary needs a glibc newer than SKOTIQ_GLIBC_FLOOR (2.36)
#   scripts/package_linux.sh notices <bundle> <source-commit> [--desktop-entry]
#       licenses, notices and SOURCE-COMMIT.txt (and the menu entry and installer)
set -euo pipefail

step="${1:-}"
BUNDLE="${2:-}"
if [ -z "$step" ] || [ -z "$BUNDLE" ]; then
  sed -n '2,13p' "$0" >&2
  exit 2
fi
shift 2
BUNDLE_LIB="$BUNDLE/lib"

case "$step" in
  libs)
    libraw=stage
    while [ $# -gt 0 ]; do
      case "$1" in
        --libraw) libraw="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
      esac
    done
    if [ ! -d "$BUNDLE_LIB" ]; then
      echo "Bundle lib dir not found: $BUNDLE_LIB" >&2
      exit 1
    fi
    if [ ! -e "$BUNDLE_LIB/libskotiq_bridge.so" ]; then
      echo "libskotiq_bridge.so is MISSING — the Rust build likely failed." >&2
      ls -l "$BUNDLE_LIB" >&2 || true
      exit 1
    fi
    case "$libraw" in
      stage)
        # LibRaw with its actual JPEG ABI (Jammy uses libjpeg.so.8; Bookworm
        # supplies a different one) and the distro copyright notices.
        python3 -m unittest discover -s scripts -p 'test_*linux*.py'
        python3 scripts/stage_linux_libraw.py "$BUNDLE"
        ;;
      ldconfig)
        # The bridge dynamically links libraw (-lraw); ship it in the bundle
        # (executable rpath = $ORIGIN/lib) so the release is self-contained.
        LIBRAW_PATH="$(ldconfig -p | awk '/libraw\.so/ {print $NF; exit}')"
        if [ -z "${LIBRAW_PATH:-}" ] || [ ! -e "$LIBRAW_PATH" ]; then
          echo "libraw shared object not found via ldconfig" >&2
          exit 1
        fi
        cp -Lv "$LIBRAW_PATH" "$BUNDLE_LIB/"
        ;;
      *) echo "--libraw takes stage or ldconfig, not $libraw" >&2; exit 2 ;;
    esac
    # package:sqlite3 installs a hermetic libsqlite3.so through Dart build
    # hooks (CMake copies build/native_assets/linux/ into bundle/lib), linked
    # with -Bsymbolic so it can coexist with the system libsqlite3 that
    # GTK→tinysparql already loads. Do NOT replace it with the host's
    # libsqlite3 or a symlink: that clobbers the native asset and brings back
    # dual-SQLite crashes.
    if [ ! -f "$BUNDLE_LIB/libsqlite3.so" ] || [ -L "$BUNDLE_LIB/libsqlite3.so" ]; then
      echo "MISSING: hermetic native-asset $BUNDLE_LIB/libsqlite3.so (regular file)" >&2
      ls -l "$BUNDLE_LIB"/libsqlite3* >&2 || true
      exit 1
    fi
    if [ -e "$BUNDLE_LIB/libsqlite3_flutter_libs_plugin.so" ]; then
      echo "UNEXPECTED: sqlite3_flutter_libs plugin still linked — remove the dependency" >&2
      exit 1
    fi
    # Launcher: prepend the bundled lib/ so libraw (and the hermetic sqlite
    # native asset) win the loader search. The Flutter binary is BINARY_NAME
    # `skotiq`; the launcher owns that name, so the real executable moves to
    # `skotiq.bin` first.
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
    ls -l "$BUNDLE_LIB" "$BUNDLE/skotiq"
    ;;

  updater)
    # The apply step runs a separate `updater` binary, because the running app
    # holds its own files open and cannot swap them. It goes inside the
    # archive the manifest hashes.
    dart scripts/build.dart updater
    install -m 0755 \
      native/skotiq_native/target/release/updater "$BUNDLE/updater"
    echo "Bundled updater: $(ls -l "$BUNDLE/updater")"
    ;;

  glibc-floor)
    versioned=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --versioned-libs) versioned=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
      esac
    done
    # The shipped appliance runs Debian/Raspberry Pi OS Bookworm (glibc 2.36).
    # A binary needing a newer glibc aborts on boot there with "GLIBC_2.38 not
    # found", which a smoke test on the build runner cannot see. Building on
    # ubuntu-22.04 (glibc 2.35) passes by construction; this is the backstop.
    # scripts/docker_build_linux.sh on debian:bookworm-slim runs the same check.
    FLOOR="${SKOTIQ_GLIBC_FLOOR:-2.36}"
    floor_major=${FLOOR%%.*}; floor_minor=${FLOOR#*.}
    violations=0
    binaries=("$BUNDLE"/skotiq.bin "$BUNDLE"/updater "$BUNDLE"/lib/*.so)
    if [ "$versioned" -eq 1 ]; then binaries+=("$BUNDLE"/lib/*.so.*); fi
    for bin in "${binaries[@]}"; do
      [ -f "$bin" ] || continue
      maxv=$(objdump -T "$bin" 2>/dev/null \
        | grep -oE 'GLIBC_2\.[0-9]+' | sort -V | tail -1 || true)
      [ -n "$maxv" ] || continue
      v=${maxv#GLIBC_}; major=${v%%.*}; minor=${v#*.}
      if [ "$major" -gt "$floor_major" ] || \
         { [ "$major" -eq "$floor_major" ] && [ "$minor" -gt "$floor_minor" ]; }; then
        echo "VIOLATION: $(basename "$bin") needs $maxv (> $FLOOR)"
        violations=$((violations + 1))
      fi
    done
    if [ "$violations" -gt 0 ]; then
      echo "::error::$violations binary(ies) exceed glibc $FLOOR — this bundle would NOT boot on the Bookworm appliance. Build on Bookworm (scripts/docker_build_linux.sh)."
      exit 1
    fi
    echo "glibc floor OK (no binary exceeds $FLOOR)"
    ;;

  notices)
    commit="${1:-}"
    if [ -z "$commit" ]; then echo "notices needs the source commit" >&2; exit 2; fi
    shift
    desktop_entry=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --desktop-entry) desktop_entry=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
      esac
    done
    cp LICENSE "$BUNDLE/SKOTIQ-LICENSE.txt"
    cp docs/THIRD_PARTY_NOTICES.md "$BUNDLE/THIRD_PARTY_NOTICES.md"
    printf '%s\n' "$commit" > "$BUNDLE/SOURCE-COMMIT.txt"
    mkdir -p "$BUNDLE/LICENSES"
    cp third_party/licenses/LGPL-2.1.txt "$BUNDLE/LICENSES/LGPL-2.1.txt"
    if [ "$desktop_entry" -eq 1 ]; then
      # Menu entry and per-user installer (~/.local/opt + app menu).
      install -m 0644 packaging/linux/skotiq.desktop "$BUNDLE/skotiq.desktop"
      install -m 0755 packaging/linux/install.sh "$BUNDLE/install.sh"
      desktop-file-validate "$BUNDLE/skotiq.desktop"
    fi
    ;;

  *)
    sed -n '2,13p' "$0" >&2
    exit 2
    ;;
esac
