#!/bin/sh
# usage: run_touptek_checks.sh [cargo test filter]     (run from native/skotiq_native)
#
# Builds the fake ToupTek-family SDK and runs tests/touptek_fake_sdk.rs against
# it, one test at a time (the fake keeps one camera's state per process).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
FAKES=${FAKE_SDK_ROOT:-${TMPDIR:-/tmp}/skotiq-fake-sdks}
python3 "$HERE/build_fakes.py" "$FAKES" > /dev/null
BIN=$(cargo test --release -p skotiq_native --test touptek_fake_sdk --no-run --message-format=json 2>/dev/null | python3 -c '
import sys, json
for line in sys.stdin:
    try: d = json.loads(line)
    except Exception: continue
    if d.get("executable") and "touptek_fake_sdk" in d["executable"]: print(d["executable"])')
[ -n "$BIN" ] || { echo "touptek_fake_sdk test binary did not build"; exit 1; }
LD_LIBRARY_PATH=$FAKES/touptek "$BIN" --ignored --test-threads 1 "$@"
