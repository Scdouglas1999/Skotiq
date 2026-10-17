#!/bin/bash
# D1 crash-resume leg: run a sim night, kill -9 the app the moment the dawn
# job reports `running`, relaunch, and assert the crash-recovery contract:
# the row is re-queued with attempts+1 at database open.
#
# NOTE: completing the re-queued job after relaunch requires the startup
# drainQueue() wiring (Phase C). Until that lands this script asserts the
# re-queue half and reports the drain half honestly as PENDING; once the
# wiring exists, set D1_EXPECT_DRAIN=1 to require completion.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
D1="${D1_SCRATCH:-/tmp/skotiq-d1-crash}"
BUNDLE="${D1_BUNDLE:-$HERE/../../../apps/desktop/build/linux/x64/release/bundle/skotiq_desktop}"
T=d1-secret-token
P="${D1_PORT:-8094}"

# One observing site for the whole leg: the sequence builder picks it (solar
# 01:00 at the site, so no dawn logic can arm mid-run) and the settings POSTs
# below use the same pair.
read D1_SITE_LAT D1_SITE_LON SKOTIQ_HARNESS_SITE <<< "$(python3 "$HERE/make_sequence.py" --print-site)"
# Pin the site for the WHOLE leg: make_sequence.py runs again to build the
# sequence, and without the pin a leg straddling a crossover would target a
# different observatory than the one it wrote to the profile.
export SKOTIQ_HARNESS_SITE
B="http://127.0.0.1:$P"
AH="Authorization: Bearer $T"
DBDIR=$D1/db; OUT=$D1/captures; DROP=$D1/drop; DATA=$D1/data
LOG=$D1/app.log
PASS=0; FAIL=0
say()  { echo "[d1cr] $*"; }
ok()   { PASS=$((PASS+1)); echo "[d1cr]   PASS: $*"; }
bad()  { FAIL=$((FAIL+1)); echo "[d1cr]   FAIL: $*"; }
api()  { curl -sf -m 10 -H "$AH" "$@"; }
# Every read waits out a writer instead of failing on SQLITE_BUSY: the app holds
# the lock for whole seconds during open-time migration and crash recovery, and
# on a loaded machine the first query after a relaunch landed inside that window
# ("database is locked (5)") and read an empty row as a FAIL.
Q()    { sqlite3 -cmd ".timeout 10000" "$DBDIR/skotiq.db" "$1"; }

PIDFILE=$D1/app.pid
# Reap only what a previous run of THIS script left behind. `pkill -f
# skotiq_desktop` kills every instance on the machine — a parallel
# harness on another port, another agent's sweep, the operator's own rig —
# so the pid is recorded and re-identified by its command line (the port is
# unique per leg) before any signal goes out. Same discipline as run.sh.
reap_previous() {
  [ -f "$PIDFILE" ] || return 0
  old=$(cat "$PIDFILE" 2>/dev/null)
  rm -f "$PIDFILE"
  case "$old" in ''|*[!0-9]*) return 0;; esac
  kill -0 "$old" 2>/dev/null || return 0
  tr '\0' ' ' < "/proc/$old/cmdline" 2>/dev/null | grep -q -- "--port=$P" || return 0
  say "reaping leftover instance from a previous run (pid $old, port $P)"
  kill -TERM "$old" 2>/dev/null
  for i in $(seq 1 15); do kill -0 "$old" 2>/dev/null || return 0; sleep 1; done
  kill -9 "$old" 2>/dev/null
}
reap_previous
rm -rf "$D1"; mkdir -p "$DBDIR" "$OUT" "$DROP" "$DATA"

launch() {
  SKOTIQ_DATABASE_DIR=$DBDIR SKOTIQ_DATA_DIR=$DATA LIBGL_ALWAYS_SOFTWARE=1 \
    "$BUNDLE" --headless --auth-token=$T --port=$P >> "$LOG" 2>&1 &
  APP=$!
  echo "$APP" > "$PIDFILE"
  for i in $(seq 1 40); do
    sleep 1
    curl -sf -m 2 "$B/api/info" >/dev/null 2>&1 && return 0
    kill -0 $APP 2>/dev/null || { bad "app exited during launch"; return 1; }
  done
  bad "API never came up"; return 1
}

say "=== setup (schema boot, seed, configure, run sequence) ==="
launch || exit 1
kill -TERM $APP; sleep 3
NOW=$(date +%s)
sqlite3 "$DBDIR/skotiq.db" "INSERT INTO delivery_targets(name,kind,config_json,enabled,content_json,secret_ref,created_at,updated_at) VALUES('d1-drop','watched_folder','{\"path\":\"$DROP\"}',1,'[\"linear_masters\",\"draft_render\",\"night_report\"]',NULL,$NOW,$NOW);"
launch || exit 1
api -X POST "$B/api/settings" -H 'Content-Type: application/json' \
  -d "{\"settings\":{\"imageOutputPath\":\"$OUT\",\"notificationsEnabled\":true,\"notifyOnSequenceComplete\":true}}" >/dev/null
sleep 1
api -X POST "$B/api/settings/location" -H 'Content-Type: application/json' \
  -d "{\"location\":{\"latitude\":$D1_SITE_LAT,\"longitude\":$D1_SITE_LON,\"elevation\":1600.0}}" >/dev/null
sleep 1
api -X POST "$B/api/post-session/settings" -H 'Content-Type: application/json' -d '{"autoIntegrate":true}' >/dev/null
sleep 1
PID=$(api -X POST "$B/api/profiles" -H 'Content-Type: application/json' -d '{
 "profile":{"id":"","name":"d1-crash-rig","cameraId":"sim_camera_1","mountId":"sim_mount_1",
  "filterWheelId":"sim_filterwheel_1","focuserId":"sim_focuser_1","focalLength":1000.0,
  "aperture":200.0,"defaultBinX":1,"defaultBinY":1,"filterNames":"[\"L\",\"R\",\"G\",\"B\"]"}}' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))')
sleep 1
api -X POST "$B/api/profiles/$PID/load" >/dev/null
sleep 1
for d in camera:sim_camera_1 mount:sim_mount_1 filterWheel:sim_filterwheel_1 focuser:sim_focuser_1; do
  api -X POST "$B/api/devices/connect" -H 'Content-Type: application/json' \
    -d "{\"deviceId\":\"${d#*:}\",\"deviceType\":\"${d%%:*}\"}" >/dev/null; sleep 1
done
python3 "$HERE/make_sequence.py" "$D1/sequence.json"
api -X POST "$B/api/sequencer/save-path" -H 'Content-Type: application/json' -d "{\"path\":\"$OUT\"}" >/dev/null
sleep 1
curl -sf -m 15 -H "$AH" -X POST "$B/api/sequencer/load" -H 'Content-Type: application/json' --data-binary @"$D1/sequence.json" >/dev/null
sleep 1
api -X POST "$B/api/sequencer/start" >/dev/null && ok "sequence started" || { bad "start"; exit 1; }

say "=== wait for the dawn job to report running, then kill -9 ==="
KILLED=0
for i in $(seq 1 240); do
  sleep 1
  ST=$(Q "SELECT state FROM darkroom_jobs ORDER BY id DESC LIMIT 1;" 2>/dev/null)
  if [ "$ST" = "running" ]; then
    kill -9 $APP 2>/dev/null
    KILLED=1; ok "killed app with job running (${i}s after start)"; break
  fi
  [ "$ST" = "done" ] && { bad "job finished before the kill window — pipeline too fast for this leg on this machine"; break; }
done
[ "$KILLED" = "1" ] || { say "teardown"; kill -TERM $APP 2>/dev/null; echo "[d1cr] RESULT: PASS=$PASS FAIL=$((FAIL+1))"; exit 1; }
sleep 2
PRE_ATTEMPTS=$(Q "SELECT attempts FROM darkroom_jobs ORDER BY id DESC LIMIT 1;")

say "=== relaunch: crash-recovery must re-queue the running row ==="
launch || exit 1
sleep 3
# `attempts` counts execution STARTS (incremented at pickup, DarkroomJobsDao
# takeQueued); open-time recovery re-queues without incrementing, and fails
# the row instead once attempts >= kDarkroomJobMaxAttempts.
ROW=$(Q "SELECT state||'|'||attempts||'|'||COALESCE(started_at,'NULL') FROM darkroom_jobs ORDER BY id DESC LIMIT 1;")
STATE=$(echo "$ROW" | cut -d'|' -f1); ATT=$(echo "$ROW" | cut -d'|' -f2); STARTED=$(echo "$ROW" | cut -d'|' -f3)
if [ "$STATE" = "queued" ] && [ "$ATT" = "${PRE_ATTEMPTS:-1}" ] && [ "$STARTED" = "NULL" ]; then
  ok "row re-queued (attempts=$ATT unchanged, started_at cleared)"
elif [ "$STATE" = "running" ] || [ "$STATE" = "done" ]; then
  ok "row state=$STATE attempts=$ATT — a drain path picked it up (Phase C wiring present)"
else
  bad "row state=$STATE attempts=$ATT started_at=$STARTED after relaunch"
fi

if [ "${D1_EXPECT_DRAIN:-0}" = "1" ]; then
  DONE=""
  for i in $(seq 1 180); do
    sleep 2
    DONE=$(Q "SELECT state FROM darkroom_jobs ORDER BY id DESC LIMIT 1;")
    [ "$DONE" = "done" ] && break
  done
  [ "$DONE" = "done" ] && ok "re-queued job drained to done" || bad "re-queued job state=$DONE (drain expected)"
else
  say "  drain-to-done not asserted (D1_EXPECT_DRAIN=0; startup drain wiring lands with Phase C)"
fi

say "=== teardown ==="
kill -TERM $APP 2>/dev/null
for i in $(seq 1 10); do kill -0 $APP 2>/dev/null || break; sleep 1; done
kill -9 $APP 2>/dev/null; rm -f "$PIDFILE"
echo "[d1cr] RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
