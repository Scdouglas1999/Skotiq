#!/bin/sh
# usage: run_gphoto2_independent.sh [cargo test filter]     (run from native/skotiq_native)
#
# Builds the independent fake libgphoto2 (gphoto2_independent.c, written from the
# libgphoto2 2.5.34 sources and the INDI gphoto driver) and runs
# tests/gphoto2_independent_fake.rs against it, one test at a time (the fake keeps
# its cameras in static state).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${FAKE_SDK_ROOT:-${TMPDIR:-/tmp}/skotiq-fake-sdks}/gphoto2-independent
mkdir -p "$OUT"
cc -Wall -Wextra -O1 -shared -fPIC -o "$OUT/libgphoto2.so" "$HERE/gphoto2_independent.c"
BIN=$(cargo test --release -p skotiq_native --test gphoto2_independent_fake --no-run --message-format=json 2>/dev/null | python3 -c '
import sys, json
for line in sys.stdin:
    try: d = json.loads(line)
    except Exception: continue
    if d.get("executable") and "gphoto2_independent_fake" in d["executable"]: print(d["executable"])')
[ -n "$BIN" ] || { echo "gphoto2_independent_fake test binary did not build"; exit 1; }
LD_LIBRARY_PATH=$OUT "$BIN" --ignored --test-threads 1 "$@"
