#!/bin/sh
# usage: run_sessions.sh <out_dir>     (run from native/skotiq_native)
#
# Builds the instrumented fake vendor SDKs, then runs each `session_*` test of
# tests/camera_session.rs in its own process with that vendor's fakes first on
# the loader path. Leaves in <out_dir>:
#   <vendor>.session       every driver answer, frame hashes and metadata
#   <vendor>.trace         the SDK calls the fake received, in order
#   <vendor>.trace.timing  gaps of 100 ms or more between SDK calls
#
# To prove a driver change keeps device-visible behavior: run this on the commit
# before and on the commit after into two directories and `diff -r` them.
# Repeated polls of one status call are collapsed (`uniq`) because their count
# depends on machine load.
set -u
OUT=$(mkdir -p "$1" && cd "$1" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
FAKES=${FAKE_SDK_ROOT:-$OUT/fakes}
python3 "$HERE/build_fakes.py" "$FAKES" > "$OUT/build.log" || { cat "$OUT/build.log"; exit 1; }
BIN=$(cargo test --release -p skotiq_native -j 8 --test camera_session --no-run --message-format=json 2>/dev/null | python3 -c '
import sys, json
for line in sys.stdin:
    try: d = json.loads(line)
    except Exception: continue
    if d.get("executable") and "camera_session" in d["executable"]: print(d["executable"])')
[ -n "$BIN" ] || { echo "camera_session test binary did not build"; exit 1; }
for vendor in zwo atik svbony player_one qhy touptek fli moravian; do
  rm -f "$OUT/$vendor.trace" "$OUT/$vendor.trace.timing" "$OUT/$vendor.session"
  CAMERA_SESSION_OUT=$OUT FAKE_SDK_TRACE=$OUT/$vendor.trace.raw LD_LIBRARY_PATH=$FAKES/$vendor \
    "$BIN" --ignored --exact --test-threads 1 "session_$vendor" > "$OUT/$vendor.log" 2>&1
  status=$?
  if [ -f "$OUT/$vendor.trace.raw" ]; then uniq "$OUT/$vendor.trace.raw" > "$OUT/$vendor.trace"; rm "$OUT/$vendor.trace.raw"; fi
  if [ -f "$OUT/$vendor.trace.raw.timing" ]; then mv "$OUT/$vendor.trace.raw.timing" "$OUT/$vendor.trace.timing"; fi
  echo "$vendor: exit $status, $(wc -l < "$OUT/$vendor.session" 2>/dev/null || echo 0) answers, $(wc -l < "$OUT/$vendor.trace" 2>/dev/null || echo 0) SDK calls"
done
