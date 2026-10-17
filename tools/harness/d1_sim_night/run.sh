#!/bin/bash
# D1 sim-night end-to-end against the RELEASE bundle: fresh install -> sim
# LRGB sequence -> natural completion -> masters -> dawn autopilot draft ->
# watched-folder delivery, asserted at every stage. See
# docs/plans/skotiq_7_0_d1_runbook.md for the seam evidence.
#   D1_SCRATCH  scratch root (default /tmp/skotiq-d1-harness; wiped each run)
#   D1_BUNDLE   bundle binary (default: this repo's release build)
#   D1_PORT     API port (default 8093) — give a concurrent run its own port
#               and its own D1_SCRATCH and the two never meet
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
D1="${D1_SCRATCH:-/tmp/skotiq-d1-harness}"
mkdir -p "$D1"
BUNDLE="${D1_BUNDLE:-$HERE/../../../apps/desktop/build/linux/x64/release/bundle/skotiq}"
T=d1-secret-token
P="${D1_PORT:-8093}"

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
PIDFILE=$D1/app.pid
PASS=0; FAIL=0
say()  { echo "[d1] $*"; }
ok()   { PASS=$((PASS+1)); echo "[d1]   PASS: $*"; }
bad()  { FAIL=$((FAIL+1)); echo "[d1]   FAIL: $*"; }
api()  { curl -sf -m 10 -H "$AH" "$@"; }

# Reap only what a previous run of THIS script left behind. `pkill -f
# skotiq` killed every instance on the machine — a parallel harness
# on another port, another agent's sweep, the operator's own running rig — so
# the pid is recorded and re-identified by its command line before any signal
# goes out. A recycled pid belonging to something else does not match and is
# left alone.
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
rm -rf "$DBDIR" "$OUT" "$DROP" "$DATA"; mkdir -p "$DBDIR" "$OUT" "$DROP" "$DATA"

# The night writes ~200MB of frames/masters and the watched-folder transport
# preflights a 1GB headroom; a nearly-full scratch filesystem fails LATE with
# an honest-but-confusing delivery refusal. Fail here instead, by name.
FREE_MB=$(df -m --output=avail "$D1" | tail -1 | tr -d ' ')
if [ "${FREE_MB:-0}" -lt 3072 ]; then
  echo "[d1] ABORT: $D1 has ${FREE_MB}MB free; this harness needs >=3072MB (frames + masters + drop + delivery headroom)."
  exit 2
fi

launch() {
  SKOTIQ_DATABASE_DIR=$DBDIR SKOTIQ_DATA_DIR=$DATA LIBGL_ALWAYS_SOFTWARE=1 \
    "$BUNDLE" --headless --auth-token=$T --port=$P >> "$LOG" 2>&1 &
  APP=$!
  echo "$APP" > "$PIDFILE"
  for i in $(seq 1 40); do
    sleep 1
    curl -sf -m 2 "$B/api/info" >/dev/null 2>&1 && return 0
    kill -0 $APP 2>/dev/null || { bad "app exited during launch (see log)"; return 1; }
  done
  bad "API never came up"; return 1
}
stopapp() { kill -TERM $APP 2>/dev/null; for i in $(seq 1 15); do kill -0 $APP 2>/dev/null || { rm -f "$PIDFILE"; return 0; }; sleep 1; done; kill -9 $APP 2>/dev/null; rm -f "$PIDFILE"; }

say "=== phase 1: schema-creation boot ==="
launch || exit 1
stopapp
[ -f "$DBDIR/skotiq.db" ] && ok "database created" || { bad "no database file"; exit 1; }

say "=== phase 2: seed delivery target + auto_draft (daemon stopped) ==="
NOW=$(date +%s)
sqlite3 "$DBDIR/skotiq.db" "INSERT INTO delivery_targets(name,kind,config_json,enabled,content_json,secret_ref,created_at,updated_at) VALUES('d1-drop','watched_folder','{\"path\":\"$DROP\"}',1,'[\"linear_masters\",\"draft_render\",\"night_report\"]',NULL,$NOW,$NOW);" \
  && ok "delivery target seeded" || bad "delivery target seed failed"
sqlite3 "$DBDIR/skotiq.db" "INSERT INTO app_settings(key,value,updated_at) VALUES('darkroom.auto_draft','true',$NOW*1000) ON CONFLICT(key) DO UPDATE SET value=excluded.value;" \
  && ok "auto_draft on" || bad "auto_draft seed failed"

say "=== phase 3: relaunch + configure ==="
launch || exit 1
api -X POST "$B/api/settings" -H 'Content-Type: application/json' \
  -d "{\"settings\":{\"imageOutputPath\":\"$OUT\",\"notificationsEnabled\":true,\"notifyOnSequenceComplete\":true,\"latitude\":$D1_SITE_LAT,\"longitude\":$D1_SITE_LON}}" >/dev/null \
  && ok "settings written" || bad "settings write"
sleep 1
api -X POST "$B/api/settings/location" -H 'Content-Type: application/json' \
  -d "{\"location\":{\"latitude\":$D1_SITE_LAT,\"longitude\":$D1_SITE_LON,\"elevation\":1600.0}}" >/dev/null \
  && ok "observer location set (canonical store)" || bad "location set"
sleep 1
api -X POST "$B/api/post-session/settings" -H 'Content-Type: application/json' -d '{"autoIntegrate":true}' >/dev/null \
  && ok "autoIntegrate on" || bad "post-session settings"
sleep 1
PROF=$(api -X POST "$B/api/profiles" -H 'Content-Type: application/json' -d '{
 "profile":{"id":"","name":"d1-sim-rig","cameraId":"sim_camera_1","mountId":"sim_mount_1",
  "filterWheelId":"sim_filterwheel_1","focuserId":"sim_focuser_1","focalLength":1000.0,
  "aperture":200.0,"defaultBinX":1,"defaultBinY":1,"filterNames":"[\"L\",\"R\",\"G\",\"B\"]"}}')
PID=$(echo "$PROF" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null)
[ -n "$PID" ] && ok "profile created id=$PID" || { bad "profile create: $PROF"; }
sleep 1
api -X POST "$B/api/profiles/$PID/load" >/dev/null && ok "profile activated" || bad "profile load"
sleep 1
for d in camera:sim_camera_1 mount:sim_mount_1 filterWheel:sim_filterwheel_1 focuser:sim_focuser_1; do
  api -X POST "$B/api/devices/connect" -H 'Content-Type: application/json' \
    -d "{\"deviceId\":\"${d#*:}\",\"deviceType\":\"${d%%:*}\"}" >/dev/null \
    && ok "connected ${d#*:}" || bad "connect ${d#*:}"
  sleep 1
done
CONN=$(api "$B/api/devices/connected" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(len(d if isinstance(d,list) else d.get("devices",d.get("connected",[]))))' 2>/dev/null)
[ "${CONN:-0}" -ge 4 ] 2>/dev/null && ok "connected count=$CONN" || bad "connected count=$CONN"

say "=== phase 4: load + start sequence ==="
python3 "$HERE/make_sequence.py" "$D1/sequence.json"
api -X POST "$B/api/sequencer/save-path" -H 'Content-Type: application/json' -d "{\"path\":\"$OUT\"}" >/dev/null \
  && ok "save-path set" || bad "save-path"
sleep 1
LOAD=$(curl -s -m 15 -H "$AH" -X POST "$B/api/sequencer/load" -H 'Content-Type: application/json' --data-binary @"$D1/sequence.json")
echo "$LOAD" | grep -qi "error" && { bad "load: $LOAD"; stopapp; exit 1; } || ok "sequence loaded"
sleep 1
api -X POST "$B/api/sequencer/start" >/dev/null && ok "sequence started" || { bad "start"; stopapp; exit 1; }

say "=== phase 5: poll to natural terminal ==="
STATE=""; LAST=""
for i in $(seq 1 300); do
  sleep 2
  S=$(api "$B/api/sequencer/status" 2>/dev/null)
  STATE=$(echo "$S" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("state",""))' 2>/dev/null)
  [ "$STATE" != "$LAST" ] && { say "  state -> $STATE ($((i*2))s)"; LAST=$STATE; }
  case "$STATE" in completed|failed|cancelled) break;; esac
done
[ "$STATE" = "completed" ] && ok "terminal=completed" || { bad "terminal=$STATE"; }

say "=== phase 6: wait for dawn job ==="
JOBSTATE=""
for i in $(seq 1 150); do
  sleep 2
  JOBSTATE=$(sqlite3 -cmd ".timeout 10000" "$DBDIR/skotiq.db" "SELECT state FROM darkroom_jobs ORDER BY id DESC LIMIT 1;" 2>/dev/null)
  case "$JOBSTATE" in done|failed|cancelled) break;; esac
done
[ "$JOBSTATE" = "done" ] && ok "darkroom job done" || bad "darkroom job state='$JOBSTATE'"

say "=== phase 7: assertions ==="
# Every read waits out a writer instead of failing on SQLITE_BUSY: the app holds
# the lock for whole seconds during open-time migration and crash recovery, and
# on a loaded machine the first query after a relaunch landed inside that window
# ("database is locked (5)") and read an empty row as a FAIL.
Q() { sqlite3 -cmd ".timeout 10000" "$DBDIR/skotiq.db" "$1"; }
# Every registered frame carries the grader's measurements and its verdict. A
# null here means the frame reached the library ungraded, and everything that
# reads quality afterwards — the reject folder, the Darkroom's sub selection,
# the session report's HFR trend — is reading a hole.
#
# This says the grader RAN and its numbers were recorded. It says nothing
# about whose thresholds it ran against, because the native grader measures
# and stamps a verdict on its own defaults whether or not the start path ever
# pushed the operator's settings — which is exactly how a headless night could
# look fully graded while `Enable image grading` was inert. Phase 7b is the
# assertion for that half.
NF=$(Q "SELECT count(*) FROM captured_images;")
UNGRADED=$(Q "SELECT count(*) FROM captured_images WHERE hfr IS NULL OR star_count IS NULL OR quality_score IS NULL OR runtime_grade IS NULL;")
[ "${NF:-0}" -ge 1 ] && [ "${UNGRADED:-1}" -eq 0 ] \
  && ok "all $NF frames carry hfr/star_count/quality_score/runtime_grade" \
  || bad "$UNGRADED of $NF frames are missing grading fields"
NM=$(Q "SELECT count(*) FROM integrated_masters WHERE status IS NULL OR status NOT IN ('failed');")
[ "${NM:-0}" -ge 4 ] && ok "masters count=$NM (>=4)" || bad "masters count=$NM"
Q "SELECT id,filter,frame_count,total_integration_seconds,master_fits_path FROM integrated_masters;" | sed 's/^/[d1]   master: /'
BADEXP=$(Q "SELECT count(*) FROM integrated_masters WHERE total_integration_seconds<=0;")
[ "${BADEXP:-1}" -eq 0 ] && ok "no zero-integration masters" || bad "$BADEXP masters have <=0 integration seconds"

# A master can exist, carry the right frame count and a positive integration
# time, and still be scientifically worthless. A normalization defect once
# shipped LRGB masters that had erased over 99.9% of their star flux — every
# master was a near-flat field at the sky pedestal — and this harness passed
# 37/37 over them, because nothing here had ever looked at a master's PIXELS.
#
# The signal that separates the two is contrast: p99.9 minus the median. A real
# star field puts hundreds of ADU between the sky and the bright tail (the D1
# field measures 118-188). The star-erased masters measured 4.8. The 30 ADU
# floor below sits an order of magnitude under the good case and well above the
# broken one, so it catches total erasure without pretending to be a
# photometric assertion.
#
# python3 stdlib only (no numpy/astropy on the harness host): FITS is 2880-byte
# header blocks of 80-char cards followed by big-endian data.
MASTERPIX=$(python3 - "$OUT" <<'EOF'
import array, glob, sys

FLOOR = 30.0
TYPECODE = {8: 'B', 16: 'h', 32: 'i', -32: 'f', -64: 'd'}


def read_fits(path):
    with open(path, 'rb') as fh:
        cards, header = b'', {}
        while True:
            block = fh.read(2880)
            if not block:
                raise ValueError('header ended without END')
            cards += block
            if b'END     ' in block:
                break
        for i in range(0, len(cards), 80):
            card = cards[i:i + 80].decode('ascii', 'replace')
            key = card[:8].strip()
            if key == 'END':
                break
            if '=' not in card:
                continue
            value = card[10:].split('/')[0].strip()
            header[key] = value
        bitpix = int(header['BITPIX'])
        n = int(header['NAXIS1']) * int(header['NAXIS2'])
        code = TYPECODE.get(bitpix)
        if code is None:
            raise ValueError('unsupported BITPIX %s' % bitpix)
        data = array.array(code)
        data.fromfile(fh, n)
        if sys.byteorder == 'little':
            data.byteswap()   # FITS data is always big-endian
        bzero = float(header.get('BZERO', 0) or 0)
        bscale = float(header.get('BSCALE', 1) or 1)
        # Stride-sample: a median and a 99.9th percentile do not need every
        # pixel, and this keeps the harness's memory and runtime small.
        vals = [v * bscale + bzero for v in data[::3]]
        vals.sort()
        return vals


masters = [f for f in sorted(glob.glob(sys.argv[1] + '/**/*.fits', recursive=True))
           if 'master' in f.lower() and 'rejmap' not in f.lower()]
if not masters:
    print('FAIL no master FITS found')
    sys.exit(0)

worst, failures = None, []
for path in masters:
    name = path.split('/')[-1]
    try:
        vals = read_fits(path)
    except Exception as exc:                       # noqa: BLE001 - reported, not raised
        failures.append('%s unreadable (%s)' % (name, exc))
        continue
    median = vals[len(vals) // 2]
    p999 = vals[min(int(len(vals) * 0.999), len(vals) - 1)]
    contrast = p999 - median
    print('DETAIL %s median=%.1f p99.9=%.1f contrast=%.1f' % (name, median, p999, contrast))
    if worst is None or contrast < worst:
        worst = contrast
    if contrast < FLOOR:
        failures.append('%s contrast=%.1f < %.1f (stars erased?)' % (name, contrast, FLOOR))

if failures:
    print('FAIL ' + '; '.join(failures))
else:
    print('OK %d masters carry star contrast (worst=%.1f ADU, floor=%.1f)'
          % (len(masters), worst, FLOOR))
EOF
)
echo "$MASTERPIX" | grep '^DETAIL' | sed 's/^DETAIL /[d1]   master pixels: /'
MPVERDICT=$(echo "$MASTERPIX" | grep -E '^(OK|FAIL)' | head -1)
case "$MPVERDICT" in
  OK*)   ok "master pixels: ${MPVERDICT#OK }" ;;
  FAIL*) bad "master pixels: ${MPVERDICT#FAIL }" ;;
  *)     bad "master pixel probe produced no verdict" ;;
esac
NR=$(Q "SELECT count(*) FROM recipes WHERE created_by='autopilot';")
[ "${NR:-0}" -ge 1 ] && ok "autopilot recipes=$NR" || bad "autopilot recipes=$NR"
JOB=$(Q "SELECT id FROM darkroom_jobs ORDER BY id DESC LIMIT 1;")
DRAFTS=$(ls "$OUT/darkroom/" 2>/dev/null | grep -c "_draft.jpg$")
[ "${DRAFTS:-0}" -ge 1 ] && ok "draft JPEGs=$DRAFTS" || bad "no draft JPEGs in $OUT/darkroom"
SIDE=$(ls "$OUT/darkroom/" 2>/dev/null | grep -c ".skrecipe$")
[ "${SIDE:-0}" -ge 1 ] && ok "skrecipe sidecars=$SIDE" || bad "no sidecars"
REPORT="$OUT/darkroom/job_${JOB}_report.json"
[ -f "$REPORT" ] && ok "night report exists" || bad "night report missing ($REPORT)"
if [ -f "$REPORT" ]; then
  NSENT=$(python3 -c "import json;print(json.load(open('$REPORT')).get('notification',{}).get('sent'))" 2>/dev/null)
  say "  notification.sent=$NSENT"
fi
DELIVERED=$(Q "SELECT count(*) FROM delivery_journal WHERE state='delivered';")
JFAILED=$(Q "SELECT count(*) FROM delivery_journal WHERE state='failed';")
[ "${DELIVERED:-0}" -ge 1 ] && ok "journal delivered=$DELIVERED failed=$JFAILED" || bad "journal delivered=$DELIVERED failed=$JFAILED"
Q "SELECT file_path,state,attempts,last_error FROM delivery_journal;" | sed 's/^/[d1]   journal: /'
MISS=0
for f in $(Q "SELECT file_path FROM delivery_journal WHERE state='delivered';"); do
  bn=$(basename "$f")
  # Delivered names carry a rig-identity prefix (delivery_naming.dart), so the
  # drop-side file is found by suffix, not by equality; exactly one must match.
  hits=$(find "$DROP" -maxdepth 1 -type f -name "*${bn}" | wc -l)
  dropfile=$(find "$DROP" -maxdepth 1 -type f -name "*${bn}" | head -1)
  if [ "$hits" = "1" ] && [ -f "$dropfile" ]; then
    # EVERY delivered file, the night report included. The report used to be
    # exempted here: it was written once before delivery and again after, at
    # one name, so its source no longer held the bytes that left. It is now
    # written once per pass under that pass's own name and never rewritten, so
    # the source is still what landed — which is also what lets a retry re-read
    # it and a re-run verify it as already-there.
    A=$(sha256sum "$f" | cut -d' ' -f1); Bc=$(sha256sum "$dropfile" | cut -d' ' -f1)
    [ "$A" = "$Bc" ] || { MISS=$((MISS+1)); say "  checksum mismatch: $bn"; }
  else MISS=$((MISS+1)); say "  missing in drop: $bn"; fi
done
[ "$MISS" -eq 0 ] && ok "all delivered files present + checksum-identical in drop" || bad "$MISS delivery mismatches"
PASSREPORT=$(Q "SELECT count(*) FROM delivery_journal WHERE state='delivered' AND file_path LIKE '%job_${JOB}_pass1_report.json';")
[ "${PASSREPORT:-0}" -eq 1 ] \
  && ok "the delivered night report is named for the pass that wrote it" \
  || bad "no delivered job_${JOB}_pass1_report.json row (found $PASSREPORT)"
WCS=$(python3 - "$OUT" <<'EOF'
import glob, sys
fs = sorted(glob.glob(sys.argv[1] + "/**/*.fits", recursive=True))
masters=[f for f in fs if "master" in f.lower()]
if not masters: print("no-masters"); sys.exit()
hdr=open(masters[0],'rb').read(2880*4).decode('ascii',errors='replace')
print("HISTORY" if "HISTORY" in hdr else "no-history", "CALWARN" if "CALWARN" in hdr else "no-calwarn")
EOF
)
say "  master header probe: $WCS"

say "=== phase 7b: the operator's grading thresholds reach the executor ==="
# The guard for the whole runtime-config seed, expressed as behaviour rather
# than as a log line.
#
# Phase 7's "every frame is graded" assertion passes whether or not the start
# path ever pushed the operator's settings: the native grader measures and
# stamps a verdict using ITS OWN defaults regardless. So it cannot catch the
# defect this phase exists for — a headless `load -> start` that skipped the
# runtime-config seed, leaving `Enable image grading` and every threshold under
# it inert for the whole night while the app read them back happily over
# `GET /api/settings`. Measured before the fix: star floor 100000 in settings,
# 43-star frames, twelve of twelve accepted, `Reject/` empty.
#
# One impossible threshold, one two-frame sequence through the SAME load->start
# path, and the frames must be REJECTED. Runs last so the session it opens
# cannot disturb the masters, drafts or delivery asserted above.
FRAMES_BEFORE=$(Q "SELECT ifnull(max(id),0) FROM captured_images;")
api -X POST "$B/api/settings" -H 'Content-Type: application/json' \
  -d '{"settings":{"enableImageGrading":true,"imageGradingStarCountMin":100000,"imageGradingMaxConsecutiveRejects":9999}}' >/dev/null \
  && ok "raised the star floor above anything the simulator can produce" \
  || bad "grading settings write"
sleep 1
python3 - "$D1/reject_sequence.json" "$D1_SITE_LAT" "$D1_SITE_LON" <<'EOF'
import json, sys, time
# One target, one filter, two subs — the smallest sequence that can be graded.
# The site rides in from the leg so this probe and the main night agree.
lat, lon = float(sys.argv[2]), float(sys.argv[3])
jd = time.time() / 86400.0 + 2440587.5
d = jd - 2451545.0
lst = ((18.697374558 + 24.06570982441908 * d) % 24.0 + lon / 15.0) % 24.0
ra = round((lst + 1.5) % 24.0, 4)
nodes = [
    {"id": "root", "name": "Reject root", "enabled": True, "children": ["target_r"],
     "node_type": {"type": "Loop", "iterations": 1, "condition": "Count", "condition_value": None}},
    {"id": "target_r", "name": "D1 Grading Probe", "enabled": True, "children": ["exp_r"],
     "node_type": {"type": "TargetHeader", "target_name": "D1 Grading Probe",
                   "ra_hours": ra, "dec_degrees": lat, "rotation": None, "priority": 0}},
    {"id": "exp_r", "name": "Exposure L", "enabled": True, "children": [],
     "node_type": {"type": "TakeExposure", "duration_secs": 2.0, "count": 2,
                   "frame_type": "Light", "filter": "L", "filter_index": 0,
                   "gain": 100, "offset": 10, "binning": "One"}},
]
definition = {"id": "d1-grading-probe", "name": "D1 grading probe",
              "description": "phase 7b", "root_node_id": "root",
              "nodes": nodes, "metadata": {}}
json.dump({"json": json.dumps(definition)}, open(sys.argv[1], "w"))
EOF
RLOAD=$(curl -s -m 15 -H "$AH" -X POST "$B/api/sequencer/load" -H 'Content-Type: application/json' --data-binary @"$D1/reject_sequence.json")
echo "$RLOAD" | grep -qi "error" && bad "grading-probe load: $RLOAD" || ok "grading probe loaded"
sleep 1
api -X POST "$B/api/sequencer/start" >/dev/null && ok "grading probe started" || bad "grading probe start"
RSTATE=""
for i in $(seq 1 90); do
  sleep 2
  RSTATE=$(api "$B/api/sequencer/status" 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("state",""))' 2>/dev/null)
  case "$RSTATE" in completed|failed|cancelled) break;; esac
done
say "  grading probe terminal=$RSTATE"
NEWF=$(Q "SELECT count(*) FROM captured_images WHERE id>$FRAMES_BEFORE;")
ACCEPTED=$(Q "SELECT count(*) FROM captured_images WHERE id>$FRAMES_BEFORE AND is_accepted=1;")
REASONED=$(Q "SELECT count(*) FROM captured_images WHERE id>$FRAMES_BEFORE AND rejection_reason LIKE '%star count%';")
Q "SELECT file_name,star_count,runtime_grade,is_accepted,ifnull(rejection_reason,'<null>') FROM captured_images WHERE id>$FRAMES_BEFORE;" | sed 's/^/[d1]   probe frame: /'
if [ "${NEWF:-0}" -ge 1 ] && [ "${ACCEPTED:-1}" -eq 0 ] && [ "${REASONED:-0}" -eq "${NEWF:-0}" ]; then
  ok "all $NEWF probe frames rejected against the settings star floor"
else
  bad "grading is inert on the load->start path: $NEWF frames, $ACCEPTED accepted, $REASONED naming the star floor"
fi
RJ=$(find "$OUT" -type d -name 'Reject' -exec sh -c 'ls "$1" | wc -l' _ {} \; 2>/dev/null | head -1)
[ "${RJ:-0}" -ge 1 ] && ok "rejected frames filed under Reject/ ($RJ)" || bad "no rejected frames under Reject/"

# The probe's 100k star floor is a deliberate absurdity that forces the
# rejections asserted above. Put the defaults back so a database reused after
# this run (a GUI poke profile, a follow-on leg) does not inherit a grading
# config that rejects every real frame — found by an operator wondering why
# their frames demanded 100,000 stars.
sqlite3 "$DBDIR/skotiq.db" "DELETE FROM app_settings WHERE key IN ('image_grading_star_count_min','image_grading_max_consecutive_rejects');" \
  && say "  grading probe thresholds restored to defaults"

say "=== phase 7c: a crash-resumed pass can still deliver its night report ==="
# The window a rig loses power in: the pass has already delivered, and the row
# has not been closed yet. Open-time recovery re-queues the `running` row and
# drainQueue re-runs the whole pass — which used to meet the FIRST pass's night
# report sitting at the destination under the same name with different bytes.
# `destinationConflict` is terminal, so the report could never land and the
# morning report said a file had not arrived that never could.
stopapp
sqlite3 "$DBDIR/skotiq.db" "UPDATE darkroom_jobs SET state='running', finished_at=NULL WHERE id=$JOB;" \
  && ok "job $JOB left running, the way a power cut leaves it" || bad "could not stage the crash"
launch || exit 1
RESUMED=""
for i in $(seq 1 90); do
  sleep 2
  RESUMED=$(Q "SELECT state FROM darkroom_jobs WHERE id=$JOB;")
  case "$RESUMED" in done|failed|cancelled) break;; esac
done
[ "$RESUMED" = "done" ] && ok "the re-queued pass ran to done" || bad "resumed job state='$RESUMED'"
REPORTROWS=$(Q "SELECT count(*) FROM delivery_journal WHERE job_id=$JOB AND file_path LIKE '%_report.json';")
REPORTBAD=$(Q "SELECT count(*) FROM delivery_journal WHERE job_id=$JOB AND file_path LIKE '%_report.json' AND state<>'delivered';")
Q "SELECT file_path,state,attempts,ifnull(last_error,'') FROM delivery_journal WHERE job_id=$JOB AND file_path LIKE '%_report.json';" | sed 's/^/[d1]   report row: /'
if [ "${REPORTROWS:-0}" -eq 2 ] && [ "${REPORTBAD:-1}" -eq 0 ]; then
  ok "both passes' reports delivered — no destinationConflict on the re-run"
else
  bad "$REPORTROWS report rows, $REPORTBAD not delivered"
fi
DROPREPORTS=$(find "$DROP" -maxdepth 1 -type f -name "*job_${JOB}_pass*_report.json" | wc -l)
[ "${DROPREPORTS:-0}" -eq 2 ] \
  && ok "the drop holds one report per pass" \
  || bad "drop holds $DROPREPORTS per-pass reports"

say "=== phase 8: teardown ==="
stopapp
say "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
tail -5 "$LOG" | sed 's/^/[d1-log] /'
[ "$FAIL" -eq 0 ]
