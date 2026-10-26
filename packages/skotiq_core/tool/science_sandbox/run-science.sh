#!/usr/bin/env bash
# Run Skotiq's own per-frame science pipeline over FITS frames in a sandbox.
#
#   run-science.sh --db <scratch dir> --session-name <name> [options] <fits or dir>...
#
# Options:
#   --out DIR            output dir (default <db>/out/<session-name>)
#   --moving-objects     turn moving-object detection on for this session (sandbox only)
#   --differential FILE  JSON {"target": anchor, "comparisons": [anchor...]}, anchor =
#                        {"objectId","label","raDegrees","decDegrees"}
#   --rig-db FILE        rig database to seed app_settings from and to enrich frames with
#                        the rig's hfr/star count/pier side/grade (default: the Oct 24 copy)
#   --no-rig-db          seed nothing; use code defaults
#   --set KEY=VALUE      extra app_settings override (repeatable)
#   --keep-frames        keep every working copy of the frames (default keeps the last 6)
#   --skip-done          skip frames whose per-frame JSON already exists in --out
#   --fold-wait SECONDS  how long to wait for the atlas fold per solved frame (default 900)
#   --memory-max SIZE    systemd scope memory cap (default 6G)
#   --session-per-night  one imaging session per observing night (<name>-YYYY-MM-DD)
#   --atlas on|off       off skips the Your Sky fold (about 4 GB of disk writes and
#                        about 2 min per frame); First Light then has no template
set -euo pipefail

# Run from a private copy: bash reads scripts as it goes, so editing this file
# under a long run would otherwise break the run's last lines.
if [[ -z "${SANDBOX_SCRIPT_COPY:-}" ]]; then
  copy="$(mktemp "${TMPDIR:-/tmp}/run-science.XXXXXX.sh")"
  cp "$(readlink -f "${BASH_SOURCE[0]}")" "$copy"
  SANDBOX_SCRIPT_COPY="$(readlink -f "${BASH_SOURCE[0]}")" exec bash "$copy" "$@"
fi

HERE="$(cd "$(dirname "$SANDBOX_SCRIPT_COPY")" && pwd)"
PKG="$(cd "$HERE/../.." && pwd)"
REPO="$(cd "$PKG/../.." && pwd)"
SCI="${SKOTIQ_SCIENCE_ROOT:-$HOME/.cache/ns-science-1025}"

DB=""; SESSION=""; OUT=""; MOVING=false; DIFF=""; KEEP=false; SKIPDONE=false
RIGDB="$HOME/.cache/ns-review-2026-10-24/skotiq.db"; FOLDWAIT=900; MEM=6G
SETS=(); INPUTS=(); ATLAS=on; PERNIGHT=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --db) DB="$2"; shift 2;;
    --session-name) SESSION="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --moving-objects) MOVING=true; shift;;
    --differential) DIFF="$(readlink -f "$2")"; shift 2;;
    --rig-db) RIGDB="$2"; shift 2;;
    --no-rig-db) RIGDB=""; shift;;
    --set) SETS+=("$2"); shift 2;;
    --keep-frames) KEEP=true; shift;;
    --skip-done) SKIPDONE=true; shift;;
    --fold-wait) FOLDWAIT="$2"; shift 2;;
    --memory-max) MEM="$2"; shift 2;;
    --atlas) ATLAS="$2"; shift 2;;
    --session-per-night) PERNIGHT=true; shift;;
    -h|--help) sed -n 2,23p "$0"; exit 0;;
    --*) echo "unknown option $1" >&2; exit 2;;
    *) INPUTS+=("$1"); shift;;
  esac
done
[[ -n "$DB" && -n "$SESSION" && ${#INPUTS[@]} -gt 0 ]] || { sed -n 2,23p "$0"; exit 2; }

DB="$(mkdir -p "$DB" && cd "$DB" && pwd)"
OUT="${OUT:-$DB/out/$SESSION}"; mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
DATA="$DB/data"; mkdir -p "$DATA"

FRAMES=()
for in in "${INPUTS[@]}"; do
  [[ -e "$in" ]] || { echo "not found: $in" >&2; exit 2; }
  if [[ -d "$in" ]]; then
    while IFS= read -r -d '' f; do FRAMES+=("$f"); done < <(find "$in" -maxdepth 1 -type f \( -iname '*.fits' -o -iname '*.fit' -o -iname '*.fts' \) -print0 | sort -z)
  else
    FRAMES+=("$(readlink -f "$in")")
  fi
done
[[ ${#FRAMES[@]} -gt 0 ]] || { echo "no FITS frames found" >&2; exit 2; }

# The rig database is copied once per scratch dir so ATTACH never touches the original.
RIGCOPY=""
if [[ -n "$RIGDB" ]]; then
  RIGCOPY="$DB/rig-source.db"
  [[ -f "$RIGCOPY" ]] || cp "$RIGDB" "$RIGCOPY"
fi

ASTAP="${SKOTIQ_ASTAP:-$SCI/tools/astapx/astap_cli}"
ASTAPDB="${SKOTIQ_ASTAP_DB:-$SCI/astap}"

# The test loads libskotiq_bridge.so through FRB's default dev path, relative
# to the package dir.
LIB="$REPO/native/skotiq_native/bridge/target/release/libskotiq_bridge.so"
if [[ ! -e "$LIB" ]]; then
  mkdir -p "$(dirname "$LIB")"
  ln -sf "${SKOTIQ_BRIDGE_LIB:-$SCI/harness/lib/libskotiq_bridge.so}" "$LIB"
fi

CFG="$OUT/config.json"
python3 - "$CFG" "$DB" "$DATA" "$OUT" "$SESSION" "$ASTAP" "$ASTAPDB" "$RIGCOPY" "$MOVING" "$DIFF" "$KEEP" "$SKIPDONE" "$FOLDWAIT" "$ATLAS" "$PERNIGHT" "${#SETS[@]}" "${SETS[@]}" "${FRAMES[@]}" <<'PY'
import json, sys
a = sys.argv[1:]
cfg, db, data, out, session, astap, astapdb, rig, moving, diff, keep, skip, fold, atlas, pernight, nsets = a[:16]
rest = a[16:]
sets = dict(s.split('=', 1) for s in rest[:int(nsets)])
frames = rest[int(nsets):]
json.dump({
  "dbDir": db, "dataDir": data, "outDir": out, "sessionName": session,
  "astapPath": astap, "astapDbDir": astapdb, "rigDb": rig,
  "movingObjects": moving == "true", "differential": diff,
  "keepFrames": keep == "true", "skipDone": skip == "true",
  "foldWaitSeconds": int(fold), "atlasFold": atlas != "off", "sessionPerNight": pernight == "true", "settings": sets, "frames": frames,
}, open(cfg, "w"), indent=1)
PY

mkdir -p "${TMPDIR:-/tmp}"
echo "science sandbox: ${#FRAMES[@]} frames -> $OUT (db $DB/skotiq.db)"
cd "$PKG"
systemd-run --user --scope --quiet -p MemoryMax="$MEM" \
  env SKOTIQ_SANDBOX_CONFIG="$CFG" SKOTIQ_DATABASE_DIR="$DB" SKOTIQ_DATA_DIR="$DATA" \
  flutter test tool/science_sandbox/science_sandbox_test.dart --no-pub --timeout=none -r expanded \
  2>&1 | tee -a "$OUT/run.log"
