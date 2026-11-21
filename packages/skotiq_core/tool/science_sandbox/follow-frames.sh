#!/usr/bin/env bash
# Feed frames into the science sandbox as a sync drops them.
#
#   follow-frames.sh --dir <frames root> --match <glob> --db <scratch dir> --session-name <name>
#                    [--interval SECONDS] [--idle-exit SECONDS] [run-science.sh options...]
#
# Every interval, collects the FITS files under --dir whose base name (after any
# Windows path prefix the sync left in the name) matches --match, and runs
# run-science.sh --skip-done on them, so each frame is processed once, in
# capture order, into the same session and atlas. Exits after --idle-exit
# seconds without a new frame (default 3 h).
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
DIR=""; MATCH="*"; INTERVAL=600; IDLE=10800; PASS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR="$2"; shift 2;;
    --match) MATCH="$2"; shift 2;;
    --interval) INTERVAL="$2"; shift 2;;
    --idle-exit) IDLE="$2"; shift 2;;
    *) PASS+=("$1"); shift;;
  esac
done
[[ -n "$DIR" ]] || { sed -n 2,12p "$0"; exit 2; }

last_new=$(date +%s)
retry=0
declare -A seen=()
while true; do
  frames=()
  new=0
  while IFS= read -r -d '' f; do
    base="${f##*/}"; base="${base##*\\}"
    [[ "$base" == .* ]] && continue
    # shellcheck disable=SC2053
    [[ "$base" == $MATCH ]] || continue
    # Skip files still being written.
    (( $(date +%s) - $(stat -c %Y "$f") < 30 )) && continue
    frames+=("$f")
    if [[ -z "${seen[$base]:-}" ]]; then seen[$base]=1; new=$((new + 1)); fi
  done < <(find "$DIR" -type f \( -iname '*.fits' -o -iname '*.fit' \) -print0)
  if (( new > 0 || retry )); then
    (( new > 0 )) && last_new=$(date +%s)
    echo "$(date -Is) follow: $new new, ${#frames[@]} total matching $MATCH"
    if "$HERE/run-science.sh" --skip-done "${PASS[@]}" "${frames[@]}"; then
      retry=0
    else
      echo "$(date -Is) follow: run failed, retrying next round"
      retry=1
    fi
  fi
  if (( $(date +%s) - last_new > IDLE )); then
    echo "$(date -Is) follow: no new frames for ${IDLE}s, exiting"
    exit 0
  fi
  sleep "$INTERVAL"
done
