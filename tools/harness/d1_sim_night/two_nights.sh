#!/bin/bash
# Two sim nights back to back in ONE process, against the RELEASE bundle.
#
# run.sh proves the dawn pipeline for the FIRST night of a process. This leg
# proves the SECOND one: an appliance that is left running images again the
# next night, and every per-run latch the executor sets on the first terminal
# has to be released before that run reaches its own terminal. When it is not,
# the second night ends on the wire as `completed`, its `imaging_sessions` row
# stays open forever, and no integration and no draft are ever made for it.
#
#   D1_SCRATCH  scratch root (default /tmp/skotiq-d1-two-nights; wiped each run)
#   D1_BUNDLE   bundle binary (default: this repo's release build)
#   D1_PORT     API port (default 8094)
#
# Teardown kills only the PID this script launched — never `pkill skotiq`,
# which would take down another harness running its own instance at the same time.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
D1="${D1_SCRATCH:-/tmp/skotiq-d1-two-nights}"
BUNDLE="${D1_BUNDLE:-$HERE/../../../apps/desktop/build/linux/x64/release/bundle/skotiq}"
T=d1-two-nights-token
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
DB=$DBDIR/skotiq.db
LOG=$D1/app.log
APP=""
PASS=0; FAIL=0
say()  { echo "[2n] $*"; }
ok()   { PASS=$((PASS+1)); echo "[2n]   PASS: $*"; }
bad()  { FAIL=$((FAIL+1)); echo "[2n]   FAIL: $*"; }
api()  { curl -sf -m 10 -H "$AH" "$@"; }
# Every read waits out a writer instead of failing on SQLITE_BUSY: the app holds
# the lock for whole seconds during open-time migration and crash recovery, and
# on a loaded machine the first query after a relaunch landed inside that window
# ("database is locked (5)") and read an empty row as a FAIL.
Q()    { sqlite3 -cmd ".timeout 10000" "$DB" "$1"; }

rm -rf "$D1"; mkdir -p "$DBDIR" "$OUT" "$DROP" "$DATA"

launch() {
  SKOTIQ_DATABASE_DIR=$DBDIR SKOTIQ_DATA_DIR=$DATA LIBGL_ALWAYS_SOFTWARE=1 \
    "$BUNDLE" --headless --auth-token=$T --port=$P >> "$LOG" 2>&1 &
  APP=$!
  for i in $(seq 1 60); do
    sleep 1
    curl -sf -m 2 "$B/api/info" >/dev/null 2>&1 && { say "app up pid=$APP"; return 0; }
    kill -0 $APP 2>/dev/null || { bad "app exited during launch (see $LOG)"; return 1; }
  done
  bad "API never came up"; return 1
}
stopapp() {
  [ -n "$APP" ] || return 0
  kill -TERM $APP 2>/dev/null
  for i in $(seq 1 20); do kill -0 $APP 2>/dev/null || { APP=""; return 0; }; sleep 1; done
  kill -9 $APP 2>/dev/null; APP=""
}
trap 'stopapp' EXIT

say "=== phase 1: schema-creation boot ==="
launch || exit 1
stopapp
[ -f "$DB" ] && ok "database created" || { bad "no database file"; exit 1; }

say "=== phase 2: seed delivery target + auto_draft (daemon stopped) ==="
NOW=$(date +%s)
sqlite3 "$DB" "INSERT INTO delivery_targets(name,kind,config_json,enabled,content_json,secret_ref,created_at,updated_at) VALUES('2n-drop','watched_folder','{\"path\":\"$DROP\"}',1,'[\"linear_masters\",\"draft_render\",\"night_report\"]',NULL,$NOW,$NOW);" \
  && ok "delivery target seeded" || bad "delivery target seed failed"
sqlite3 "$DB" "INSERT INTO app_settings(key,value,updated_at) VALUES('darkroom.auto_draft','true',$NOW*1000) ON CONFLICT(key) DO UPDATE SET value=excluded.value;" \
  && ok "auto_draft on" || bad "auto_draft seed failed"

say "=== phase 3: relaunch + configure ==="
launch || exit 1
api -X POST "$B/api/settings" -H 'Content-Type: application/json' \
  -d "{\"settings\":{\"imageOutputPath\":\"$OUT\",\"notificationsEnabled\":true,\"notifyOnSequenceComplete\":true,\"latitude\":$D1_SITE_LAT,\"longitude\":$D1_SITE_LON}}" >/dev/null \
  && ok "settings written" || bad "settings write"
sleep 1
api -X POST "$B/api/settings/location" -H 'Content-Type: application/json' \
  -d "{\"location\":{\"latitude\":$D1_SITE_LAT,\"longitude\":$D1_SITE_LON,\"elevation\":1600.0}}" >/dev/null \
  && ok "observer location set" || bad "location set"
sleep 1
api -X POST "$B/api/post-session/settings" -H 'Content-Type: application/json' -d '{"autoIntegrate":true}' >/dev/null \
  && ok "autoIntegrate on" || bad "post-session settings"
sleep 1
PROF=$(api -X POST "$B/api/profiles" -H 'Content-Type: application/json' -d '{
 "profile":{"id":"","name":"2n-sim-rig","cameraId":"sim_camera_1","mountId":"sim_mount_1",
  "filterWheelId":"sim_filterwheel_1","focuserId":"sim_focuser_1","focalLength":1000.0,
  "aperture":200.0,"defaultBinX":1,"defaultBinY":1,"filterNames":"[\"L\",\"R\",\"G\",\"B\"]"}}')
PID=$(echo "$PROF" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null)
[ -n "$PID" ] && ok "profile created id=$PID" || bad "profile create: $PROF"
sleep 1
api -X POST "$B/api/profiles/$PID/load" >/dev/null && ok "profile activated" || bad "profile load"
sleep 1
for d in camera:sim_camera_1 mount:sim_mount_1 filterWheel:sim_filterwheel_1 focuser:sim_focuser_1; do
  api -X POST "$B/api/devices/connect" -H 'Content-Type: application/json' \
    -d "{\"deviceId\":\"${d#*:}\",\"deviceType\":\"${d%%:*}\"}" >/dev/null
  sleep 1
done
CONN=$(api "$B/api/devices/connected" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(len(d if isinstance(d,list) else d.get("devices",d.get("connected",[]))))' 2>/dev/null)
[ "${CONN:-0}" -ge 4 ] 2>/dev/null && ok "connected count=$CONN" || bad "connected count=$CONN"
api -X POST "$B/api/sequencer/save-path" -H 'Content-Type: application/json' -d "{\"path\":\"$OUT\"}" >/dev/null \
  && ok "save-path set" || bad "save-path"
sleep 1

# One night: load the sequence, start it, poll to the native terminal.
run_night() {
  local N="$1"
  python3 "$HERE/make_sequence.py" "$D1/sequence.json" >/dev/null
  LOAD=$(curl -s -m 15 -H "$AH" -X POST "$B/api/sequencer/load" -H 'Content-Type: application/json' --data-binary @"$D1/sequence.json")
  echo "$LOAD" | grep -qi '"error"' && { bad "night $N load: $LOAD"; return 1; }
  sleep 1
  api -X POST "$B/api/sequencer/start" >/dev/null || { bad "night $N start failed"; return 1; }
  local STATE="" LAST=""
  for i in $(seq 1 300); do
    sleep 2
    S=$(api "$B/api/sequencer/status" 2>/dev/null)
    STATE=$(echo "$S" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("state",""))' 2>/dev/null)
    [ "$STATE" != "$LAST" ] && { say "  night $N state -> $STATE ($((i*2))s)"; LAST=$STATE; }
    case "$STATE" in completed|failed|cancelled) break;; esac
  done
  [ "$STATE" = "completed" ] && ok "night $N terminal=completed" || bad "night $N terminal=$STATE"
}

# Everything a finished night owes the operator, asserted against the database
# and the files on disk. $1 = night number, $2 = that night's imaging_sessions.id,
# $3 = sum(frame_count) over all masters BEFORE the night ran.
assert_night() {
  local N="$1" SID="$2" FRAMES_BEFORE="$3"

  local STATUS
  for i in $(seq 1 60); do
    STATUS=$(Q "SELECT status FROM imaging_sessions WHERE id=$SID;")
    [ "$STATUS" = "completed" ] && break
    sleep 2
  done
  [ "$STATUS" = "completed" ] \
    && ok "night $N session $SID finalized (status=completed)" \
    || bad "night $N session $SID status='$STATUS' — the run never finalized its session"

  local JOB="" JOBSTATE=""
  for i in $(seq 1 150); do
    JOB=$(Q "SELECT id FROM darkroom_jobs WHERE session_id=$SID ORDER BY id DESC LIMIT 1;")
    if [ -n "$JOB" ]; then
      JOBSTATE=$(Q "SELECT state FROM darkroom_jobs WHERE id=$JOB;")
      case "$JOBSTATE" in done|failed|cancelled) break;; esac
    fi
    sleep 2
  done
  [ -n "$JOB" ] \
    && ok "night $N raised Darkroom job $JOB" \
    || bad "night $N raised NO Darkroom job for session $SID"
  [ "$JOBSTATE" = "done" ] \
    && ok "night $N Darkroom job state=done" \
    || bad "night $N Darkroom job state='$JOBSTATE'"

  local FRAMES_AFTER
  FRAMES_AFTER=$(Q "SELECT COALESCE(sum(frame_count),0) FROM integrated_masters;")
  [ "${FRAMES_AFTER:-0}" -gt "${FRAMES_BEFORE:-0}" ] \
    && ok "night $N integrated (master frames $FRAMES_BEFORE -> $FRAMES_AFTER)" \
    || bad "night $N integrated nothing (master frames stayed at $FRAMES_AFTER)"

  local DRAFTS=0
  [ -n "$JOB" ] && DRAFTS=$(ls "$OUT/darkroom/" 2>/dev/null | grep -c "^job_${JOB}_master_.*_draft.jpg$")
  [ "${DRAFTS:-0}" -ge 1 ] \
    && ok "night $N drafted $DRAFTS master(s)" \
    || bad "night $N produced no draft for job '$JOB'"
}

FRAMES0=$(Q "SELECT COALESCE(sum(frame_count),0) FROM integrated_masters;")
say "=== night 1 ==="
run_night 1
# run_night returns when the RUN is terminal; the session row's own write can
# land a beat later. One unpolled read here lost that race once in twenty runs
# and every later assert then queried "WHERE id=;". Poll like everything else.
SID1=""
for i in $(seq 1 30); do
  SID1=$(Q "SELECT id FROM imaging_sessions ORDER BY id DESC LIMIT 1;")
  [ -n "$SID1" ] && break
  sleep 1
done
say "night 1 session id=$SID1"
assert_night 1 "$SID1" "$FRAMES0"

FRAMES1=$(Q "SELECT COALESCE(sum(frame_count),0) FROM integrated_masters;")
say "=== night 2 (SAME process, no restart) ==="
run_night 2
SID2=""
for i in $(seq 1 30); do
  SID2=$(Q "SELECT id FROM imaging_sessions ORDER BY id DESC LIMIT 1;")
  [ -n "$SID2" ] && [ "$SID2" != "$SID1" ] && break
  sleep 1
done
say "night 2 session id=$SID2"
[ -n "$SID2" ] && [ "$SID2" != "$SID1" ] \
  && ok "night 2 opened its own session row ($SID2)" \
  || bad "night 2 has no session row of its own (got '$SID2', night 1 was '$SID1')"
assert_night 2 "$SID2" "$FRAMES1"

say "=== state ==="
sqlite3 -header -column "$DB" "SELECT id,status,total_exposures,successful_exposures FROM imaging_sessions;" | sed 's/^/[2n]   session: /'
sqlite3 -header -column "$DB" "SELECT id,session_id,kind,state,attempts FROM darkroom_jobs;" | sed 's/^/[2n]   job: /'
sqlite3 -header -column "$DB" "SELECT id,name,filter,frame_count,status FROM integrated_masters;" | sed 's/^/[2n]   master: /'
ls "$OUT/darkroom" 2>/dev/null | sed 's/^/[2n]   artifact: /'

say "=== teardown ==="
stopapp
say "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
