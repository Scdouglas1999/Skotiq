#!/bin/sh
# usage: run_touptek_independent.sh [cargo test filter]     (run from native/skotiq_native)
#
# Builds the independent fake toupcam SDK (touptek_independent.c, written from
# toupcam.h and the INDI and NINA drivers) and runs tests/touptek_independent_fake.rs
# against it, one test at a time (the fake holds one open camera per process).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${FAKE_SDK_ROOT:-${TMPDIR:-/tmp}/skotiq-fake-sdks}/touptek-independent
mkdir -p "$OUT"
cc -Wall -O1 -shared -fPIC -o "$OUT/libtoupcam.so" "$HERE/touptek_independent.c" -lpthread
BIN=$(cargo test --release -p skotiq_native --test touptek_independent_fake --no-run --message-format=json 2>/dev/null | python3 -c '
import sys, json
for line in sys.stdin:
    try: d = json.loads(line)
    except Exception: continue
    if d.get("executable") and "touptek_independent_fake" in d["executable"]: print(d["executable"])')
[ -n "$BIN" ] || { echo "touptek_independent_fake test binary did not build"; exit 1; }
LD_LIBRARY_PATH=$OUT "$BIN" --ignored --test-threads 1 "$@"
