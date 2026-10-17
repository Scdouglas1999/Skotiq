# Skotiq 6.0.0 — no-hardware test campaign, 2026-07-28

Everything below was exercised **live** against the shipping `main` build
(desktop Linux bundle + a freshly built Android release APK), driven entirely by
the built-in simulators, a hand-written Alpaca server, a real `indiserver`, and
synthetic FITS with known ground truth. Eleven parallel investigators plus the
lead. No real hardware was involved at any point.

Findings are CONFIRMED unless marked otherwise. Each was verified live before
being written down; where a claim rests only on reading code, it says so.

---

## The six worst, in order

1. **A sensor that stops responding reads SAFE, in fail-closed mode, forever** (S1)
   — and restoring it does not resume polling.
2. **Target state leaks between runs**, so the darks and flats you queue after a
   light session are silently skipped and reported `completed` (Q1) — and the same
   leak can drive a **real mount slew in daylight**, bypassing the daylight gate
   that correctly blocks explicit slews (Q2).
3. **A restore reports success, then the next settings write destroys all of it**
   (D1). Restore itself is sound; the window before a restart is not.
4. **`Parallel` runs two exposures on one camera at once and they can collide on
   one filename** — two DB rows, one file, one frame's data gone (Q3).
5. **A run with no save path reports 100 % complete and writes nothing** (D2), and
   the endpoint that sets that path accepts an empty string with `{"status":"ok"}`
   (D2b).
6. **The built-in guider's dither grows without bound and kills guiding**
   deterministically — with shipped defaults, around the 8th dither of the night
   (G1). Guiding stops *and* the guider disconnects itself.
7. **The thin client cannot start a run, and the failed attempt silently disables
   the host's own Start button** for the rest of the night (M1) — the flagship
   "couch-grade remote" path.
8. **Centering can never correct a pointing error** on the shipping GUI path — it
   re-issues the identical slew N times, then reports max-iterations (C2).

Everything except #8 would cost an operator a night's data or an unattended
observatory's safety margin. None of them is caught by any static gate.

Two structural notes that matter more than any single defect: **session ownership
is dead code** — nothing in the shipping product ever claims the operator slot, so
every gated endpoint is open to every client (M2) — and **the simulators fail in
the direction that makes tests pass**, leaving seventeen categories of behaviour
unverifiable while appearing green (F1-F7).

## The one thing to read first

**The simulators are not a faithful stand-in for hardware, and they fail in the
direction that makes tests pass.** The camera has *two entirely different
simulators running in the same process* (1920×1080 deterministic for the
sequencer, 4144×2822 randomised for manual capture); the HTTP API's simulator arm
has **no connected-gate at all**, so a disconnected mount still accepts slews and
reports itself "tracking and parked"; and the mount's altitude/azimuth/sidereal
time are hardcoded or stale while explicitly marked `availability: "available"`.

Seventeen categories of behaviour — horizon limits, altitude safety-park,
post-flip pier-side confirmation, dome slaving, weather-triggered abort, grading,
saturation handling, disconnect-mid-operation, and more — **cannot be validated
at all** against the current simulators, and will appear to pass. Any prior green
result in those areas should be treated as unproven rather than as evidence.

---

## P0 — safety

### S1. A sensor that stops responding is treated as SAFE, in fail-closed mode, and polling never restarts

Driven against a real Alpaca safety monitor with injectable faults.

1. Monitor reports `issafe=false` → app correct: `isSafe=false, shouldPark=true,
   reason='Safety monitor reports unsafe conditions'`.
2. Inject HTTP 500 on every device read.
3. **Within 8 s** the app flips to `isSafe=true, safetyStatus=safe,
   shouldPark=false, reason=null, failModeWarning=null`, asserting
   `hardwareWeatherSafe:true, safetyMonitorSafe:true` — while its own `monitors[]`
   array *in the same payload* says `connected:false, isSafe:null`.
4. Restore the server fully. **`issafe` polls in the next 70 s: 0** (123 before).
   The app stayed "safe" for ~9 minutes; only an explicit
   `POST /api/devices/connect` resumed polling, after which it immediately went
   back to unsafe.

Root cause, `packages/skotiq_core/lib/src/providers/weather_safety_provider.dart:489-503`:

```dart
bool hardwareWeatherSafe = true;          // default TRUE
if (isWeatherDeviceConnected) { ... }     // only evaluated when CONNECTED
bool safetyMonitorSafe = true;            // default TRUE
if (isSafetyMonitorConnected) { ... }
```

A device in `error` state is not `connected`, so the branch is skipped and the
`true` default wins. The fail-mode escape at `:526` requires **all three** sources
absent, so it never engages when one sensor merely breaks.

Operator impact: a rain sensor drops off the network while it is raining →
Skotiq cancels the park order and declares the sky safe, permanently.

**Independently reproduced by the lead on a separate rig, which also pinned the
precondition.** Alpaca safety monitor connected and reporting `issafe=false`;
baseline correct (`isSafe False, safetyMonitorSafe False, shouldPark True,
reason "Safety monitor reports unsafe conditions"`). The sensor was then frozen
with `SIGSTOP` — a genuine stops-responding, not a clean disconnect:

```
t+ 15s..60s  isSafe=False  smSafe=False   reason=Safety monitor reports unsafe conditions
t+ 75s       isSafe=False  smSafe=True    reason=No weather data sources available   <- flipped
t+105s       isSafe=False  smSafe=True
--- sensor resumed (still reporting issafe=false) ---
t+ 20s..80s  isSafe=False  smSafe=True    monitorsConnected=1
```

Two halves confirmed: `safetyMonitorSafe` flips to the fabricated `true`, and
**polling never resumes** — 80 s after the sensor came back alive and reporting
UNSAFE, the app was still asserting `safetyMonitorSafe: true` for it.

The precondition for the *full* P0 is now precise. On the lead's rig the overall
verdict correctly stayed `isSafe: false` — because no weather source was connected
either, so the `!isWeatherDeviceConnected && !isSafetyMonitorConnected &&
currentAlert == null` escape at `:526` fired and fail-closed caught it. On a rig
with **one healthy source still connected** — the normal configuration — that
escape cannot fire, the fabricated `true` wins, and the verdict flips all the way
to safe. **So the fail-mode safety net only works when every source is dead at
once; it is defeated by exactly one sensor failing, which is the common case.**

(A first attempt using the Alpaca server's `fail_mode=500` control did **not**
reproduce anything — the server recorded the mode but kept returning HTTP 200, so
the sensor was never actually broken. Worth noting so the negative result is not
mistaken for a refutation.)

The same two lines produce a second symptom, confirmed independently on the lead's
rig: with **zero** devices connected, `/api/safety/status` returns
`hardwareWeatherSafe:true, safetyMonitorSafe:true, apiWeatherSafe:true,
monitorsConnected:0, monitors:[]` — three positive assertions about sensors that
do not exist. The desktop and mobile Safety cards render this as a green
**"✓ Safe"** badge directly above their own line reading **"Data: Unavailable"**.

### S2. Weather safety is OFF by default while the settings screen advertises protection

Fresh install, two independent rigs: `weatherSafetyEnabled: false`. The same
screen shows **"Auto-park mount — ON"** with the subtitle *"Park automatically
when the safety monitor trips"*. Nothing indicates it is inert. Turning weather
safety on made everything work correctly, so this is purely a default +
disclosure problem.

### S3. `autoCloseRoofOnUnsafe` is never consumed; the roof never closes for a hardware-sensed unsafe

With `autoCloseRoofOnUnsafe:true`, `failMode:fail_closed`, dome shutter open and
the safety monitor tripped: the mount parked correctly, but `shouldCloseDome:false`
every tick for 60 s and the roof stayed open. `_shouldCloseDome`
(`weather_safety_provider.dart:1264`) returns false unless there is a non-null
**internet weather API** alert at critical level; a safety-monitor trip always has
`currentAlert == null`. The setting is read nowhere outside persistence.

### S4. Stale readings are stamped with a fresh timestamp, and nothing enforces an age

Killed the Alpaca server. For 4 minutes `/api/weather/current` kept returning the
last-known values with `hardwareConnected: true` and **`lastUpdated` advancing
every poll** (11:18:58 → 11:19:18 → 11:19:38 → …). The only staleness check in the
tree (`sequencer/src/triggers.rs:1525`) early-returns unless the verdict is
*already* unsafe — it can catch a stale UNSAFE, never a stale SAFE.

---

## P0 — data loss

### D1. A restore reports success, then any later settings write silently destroys it

```
POST /api/backup/upload-restore -> {"status":"restored","itemsRestored":190}
sqlite3: bortle_class|14  default_gain|130  observer_name|MUT      # on disk, restored
GET /api/settings          -> bortleClass 5, defaultGain 100, observerName ''   # in memory, stale

POST /api/settings {"settings":{"theme":"light"}} -> {"status":"updated"}
sqlite3: bortle_class|5   default_gain|100  observer_name|(empty)  # all 184 restored settings GONE
```

`apps/desktop/lib/headless_api/handlers/backup_handlers.dart` contains **zero**
`invalidate` calls (verified by grep), so the process keeps its pre-restore
`AppSettings` snapshot; the next write merges onto that stale state and persists
the whole map. The GUI at least invalidates three providers and prints "Restart
Skotiq before the next run" — the HTTP API says nothing. Restore itself is
sound: restore into a fresh rig and restart before touching anything and
everything comes back byte-correct.

### D2. A sequencer run with no save path reports 100% complete and writes nothing

`native/skotiq_native/sequencer/src/node/instructions/expose.rs:302` —
`build_save_path_renderer` does `base_path.as_ref()?;` and returns `None`. The
`Option` is handed to `execute_exposure_with_renderer` while the per-frame
progress callback (`:133`) fires regardless, so frames are captured, counted, and
discarded. The only trace is a `tracing::warn!`. **Not simulator-specific — this
would silently discard a real night's data.**

### D2b. `POST /api/sequencer/save-path` accepts a path that cannot possibly work

```
{"path":"/proc/skotiq-cannot-write"}  -> {"status":"ok"}    # unwritable
{"path":"/nonexistent-root-dir/x"}        -> {"status":"ok"}    # uncreatable
{"path":""}                               -> {"status":"ok"}    # empty string
```

No writability check, no existence check, not even a non-empty check — and the
empty string is exactly the input that trips D2's `base_path.as_ref()?` into
discarding every frame. This is the user-reachable trigger for the data-loss path
above, and it confirms itself as ok.

### D3. Restoring the same backup twice silently duplicates every target and sequence

`replaceExisting=false` — which is what the GUI always sends — blind-inserts.
0 → 3 targets → 6 targets over two restores of one file, with no dedup and no
warning. The backup format drops target `id` entirely, so every restore mints new
rows. Profiles keep their id and `insertOrIgnore` correctly, so the behaviour is
inconsistent *within a single restore*.

### D4. A database from a newer Skotiq is silently accepted and relabelled backwards

`PRAGMA user_version = 99` + a future table and column → the app starts, works
normally, and **rewrites `user_version` to 57**. There is no `onDowngrade`
anywhere in the repo; drift runs `onUpgrade(from:99, to:57)`, every step is
guarded `if (from < N)` so all 21 no-op, and drift then stamps the current
version. `POST /api/system/update/rollback` exists, so "run 6.1, roll back to 6.0"
is a supported action that permanently mismarks the DB.

---

## P1 — correctness

### C1. Every star in the desktop planetarium is drawn at RA × 15

`CelestialCoordinate.ra` is documented *"Right Ascension in hours (0-24)"* with
`double get raDegrees => ra * 15`
(`packages/skotiq_planetarium/lib/src/coordinate_system.dart:5-14`), but the
HYG parser stores degrees into it:

```dart
// star_catalog.dart:241
ra: raHours * 15, // Convert hours to degrees
```

Live: clicking the star labelled Arcturus reports **RA 21h 54m 46.6s** (truth
14h 15m 40s); Aldebaran **20h 58m** (truth 04h 35m 55s). Both reproduce
`(RA_deg × 15) mod 360` exactly. The headless API returns the same star correctly
(`raHours: 14.26103`), so this is GUI-planetarium-only. DSOs are unaffected, which
is why stars do not sit on their own constellation lines. The detail panel's
alt/az, its "Below Horizon" badge, and its Slew / Framing / Sequence actions all
carry the wrong coordinate.

### C2. Centering can never correct a pointing error in the default path

`centering_service.dart:911-921`: when `syncMount` is false the correction step
issues the **identical slew** that produced the mis-pointed frame — no offset, no
sync. `syncMount` defaults to `false` and is a hard-coded literal at both desktop
GUI call sites (`centering_dialog.dart:139`, `slew_dropdown_button.dart:423`);
there is no UI to turn it on. Live, with the solver pinned to a known offset:

```
iteration 1  offsetArcsec 17570.40506768608
iteration 2  offsetArcsec 17570.40506768608     <- bit-identical
iteration 3  offsetArcsec 17570.40506768608
errorMessage "Maximum iterations (3) reached. Final offset: 292.84 arcmin"
```

"Slew & Center" burns 5 exposures, 5 slews and 5 plate solves per target and then
fails, with a message that never hints the correction is a no-op.

### C3. After setting location over the API, the autopilot scores every target from 0°N 0°E until restart

`/api/scheduler/state` returned geometrically impossible altitudes — NGC188
(Dec +85.2°) at **−4.5°** when its minimum from Boston is +37.6°. All seven
targets match Null Island to 0.03°. `POST /api/settings/location` then
`GET /api/settings/location` returns Boston, but `GET /api/settings` still reports
`0.0 0.0`, and a restart fixes it. Cause: `profile_handlers.dart:665-668` writes
`settingsDao` directly, bypassing `AppSettingsNotifier`, while
`scheduler_provider.dart:637` reads
`ref.read(appSettingsProvider).valueOrNull?.latitude ?? 0.0`. The GUI path is
safe. An appliance configured from a phone runs its autopilot from the Gulf of
Guinea for the whole boot, confidently rejecting every real target with a
fully-explained false reason.

### C4. `POST /api/settings/location` silently clears the location on an unrecognised body

```
POST {"latitude":42.36,"longitude":-71.06,"elevation":43}  -> {"status":"updated"}
GET  /api/settings/location                                -> {"location":null}
POST {"foo":"bar"}                                         -> {"status":"updated"}
GET  /api/settings/location                                -> {"location":null}   # WIPED
GET  /api/settings latitude/longitude                      -> 0.0 0.0
```

`handleSetLocation` uses `optionalObject(payload,'location')` and treats absent as
"clear" (`profile_handlers.dart:646-668`). Every sibling endpoint uses
`requireObject` and 400s properly. Losing your site silently before an unattended
night is expensive.

### C5. Sunset/sunrise double-count atmospheric refraction

Checked against an independently written Meeus implementation, validated first
against Meeus' own worked examples. **Civil, nautical and astronomical dusk and
dawn agreed to within 3 seconds at six sites across six dates.** Only sunset and
sunrise disagreed, always in the same direction:

| site | sunset error | sunrise error |
|---|---|---|
| Quito 0° | +2.9 … +3.2 min | −2.9 … −3.1 min |
| Boston 42.4°N | +3.9 … +4.7 min | −3.9 … −4.7 min |
| Tromsø 69.6°N | **+8.3 … +11.2 min** | −8.3 … −11.4 min |

`astronomy_calculations.dart:612-619` compares `sunAltitude()` — which already
adds Bennett refraction — against `_sunRiseSetAltitude = -0.8333`, a constant that
*already contains* the 34′ refraction plus 16′ semi-diameter. Twilight escapes
because Bennett returns 0 below −2°. Day length is overstated by ~9 min at Boston,
~20 min at Tromsø.

### C5b. `/api/suggestions/*` returns transit exactly 24 hours late — while the GUI's own card gets it right

Independently reproduced on the lead's rig. `GET /api/suggestions/score/1` (M81,
RA 09h55m33s, Dec +69°04′) at 12:11 local on 28 July:

```
"transitTime": 1785349637015   ->  2026-07-29 14:27:17 local   <- tomorrow
"transitProximity": 10.0                                        <- the axis floor
```

Hand-computed transit for **today**: LST 07:35 now, transit at LST 09:55.5 →
**14:31 local, 28 July**. The time of day is right to four minutes; the **date is
one day out**, exactly as the diagnosis predicts (`target_scoring.dart:390` scores
at `nightMid`, which is after local midnight, and `astronomy_calculations.dart:1024`
then anchors on noon of *that* calendar day).

The sharpened point: the desktop **Plan Tonight → Night Outlook** card is
**correct** — I hand-verified NGC0752's Rise 21:44 / Transit 06:30 / Set 15:16 /
Max Alt 87.8° against first-principles calculation and all four match. So the two
surfaces in one app disagree about the same quantity, and only the API path is
wrong. `transitProximity: 10.0` is the floor value, confirming that scoring axis
contributes nothing to ranking.

**Not a defect (checked, do not re-file):** the same payload's *"Low peak altitude
(29°)"* beside `transitAltitude: 60.93` is correct — 60.93° is the true transit
altitude (which occurs in daylight) and 28.85° is the highest M81 actually reaches
inside tonight's dark window. Both numbers are right; only the labelling invites
the misreading.

### C6. The scheduler's moon model uses the wrong angle for ecliptic latitude

`scheduler_engine/astronomy_helpers.dart:54`:

```dart
final beta = 5.128 * math.sin(mpRad);   // WRONG: must be sin(F), the argument of latitude
```

The planetarium copy has it right (`astronomy_calculations.dart:737`). Verified by
re-implementing the engine's formula and matching its live output to 0.27°, then
comparing against truth: up to **8.9° of moon position error** and 6 percentage
points of illumination over July 2026. This feeds the autopilot's moon-avoidance
weight.

### C7. Polar day and polar night produce identical confident plans

Tromsø during the midnight sun: the app's own twilight endpoint correctly returns
**every field null**, and `/api/suggestions/tonight` then returns four targets
scored 77-80 with `darkness: 100.0` and *"8.3 hours above minimum altitude"*. The
South Pole during 24-hour polar night returns the same shape and the same "8.3
hours". `target_suggestion_service.dart:412-428` silently falls back to a
hardcoded 21:00–05:00 window when no twilight boundary exists; only a
`_logging.warning` records it. The Planner's own Schedule tab handles the same
night honestly (`darkHours: 0.0, bestTargets: []`), so the two tabs of one screen
contradict each other.

### C8. `POST /api/sequencer/update-default-quality-check` is a total no-op that reports success

The only remote control for image grading does nothing — every run re-seeds the
quality check from app settings at start (`runtime_config_operations.dart:345-390`),
discarding the pushed config. Three-arm proof on one sequence: `starCountMin:500`
via the API → 4 frames all accepted; the same value via `/api/settings` → 4 frames
all rejected with *"star count 41 below minimum 500"*. The API cannot even switch
grading on.

### C9. Every run reports `framesRejected: 0`, including runs where every frame was rejected

Across 13 runs and 17 rejected frames on disk, `framesRejected` is `0` in
`runVitals`, in the persisted `sequence_runs.statsJson`, and in `imaging_sessions`.
The app knows the truth — its own error string reads *"Accepted so far: 0,
rejected: 3."* while every structured counter says 0.

### C10. Bias matching ignores temperature and reports a fabricated 100/100

Library held bias @ −10 °C and bias @ +30 °C. For a light at −10 °C the matcher
picked the **40 °C-wrong** bias, scored it **100/100**, and emitted zero warnings.
The dark path correctly prints `Temperature -10.0°C (Δ5.0°C, tolerance ±1.0°C)`.
`_matchBias` (`calibration_library_service.dart:1168`) has no temperature gate and
ranks purely by recency. Separately, geometry is ignored for local candidates: a
512×512 master scored 100/100 against a 9999×9999 context and then hard-failed
calibration with a dimension mismatch.

### C11. Calibration silently breaks when the dark file path exceeds ~68 characters

`darkPath` 68 chars → `200 {"darkApplied":true}`; 70+ chars → `500 Failed to write
calibrated FITS: InvalidFormat("FITS string value too long for DARKFILE")`. The
pixel maths succeeds and the whole operation is lost. 68 is the FITS
single-record string limit; the CONTINUE long-string convention exists for exactly
this. A default Windows layout (`C:\Users\<name>\Documents\Skotiq\Calibration\
Darks\master_dark_...fits`) blows straight past it.

### C12. The eccentricity grading gate cannot reject a trailed frame

`StarDetectionConfig::max_eccentricity = 0.7` (`stats.rs:190`) discards every star
above 0.7 **before** aggregation, so frame eccentricity is bounded to [0, 0.7] by
construction and the default gate (`> 0.7`, strict) can never fire. A deliberately
trailed frame (true eccentricity 0.9165) additionally yielded only 1 detected star
— below `MIN_STARS_FOR_FRAME_ECCENTRICITY = 5` — so grading skipped it entirely.
Trailing is the commonest reason to bin a sub.

### C13. Three divergent implementations of mosaic panel geometry, and impossible declinations

`mosaic_geometry.dart:106` (planner + service), `framing_provider.dart:669`
(framing overlay) and `sequencer/src/mosaic/panels.rs:66` (the Rust executor) each
use a different `cos(dec)` reference, pole guard and clamp. For a 3×3 at dec +88°
the Dart planner puts adjacent panels **1.91 h of RA apart** from where the Rust
executor would. The existing parity test compares two functions that both call the
same helper, so it is tautological.

Separately, `generate-panels` at centre dec +89° emits **`decDegrees: 91.0`** and a
live `SlewNode {'customDec': 91.0}`, and `/api/mosaic/validate` calls that config
`isValid: true`. `panelsHorizontal/Vertical` have `min:1` and **no max** — 500×500
returned HTTP 200 with 250,000 panels, 100,000 of them beyond ±90° declination.
At the pole exactly, a 3×1 mosaic returns three panels with identical coordinates.

### C14. Reported mosaic sky coverage ignores overlap

3×3 of 60′×40′ panels at 30 % overlap → `areaSquareDegrees: 6.0`; true coverage is
3.84. Overstated by **56 %** (3.3× at 10×10 / 50 %). The panel *centres* correctly
apply `1 − overlap/100`; the area does not. Three independent copies of the same
wrong formula.

### C15. `DATE-OBS` is the exposure END, not the start

A frame that began at 15:32:35.004 carries `DATE-OBS = 15:32:37` — the
download-complete instant. Anything computing a mid-exposure epoch (airmass,
ephemeris matching, transient timing, AAVSO/MPC submission) is off by the full
integration time, and the error scales with exposure. **Not simulator-specific.**

### C16. Target and project progress can never advance

`TargetsDao.updateProgress` has exactly one caller in the repo — the HTTP handler
`PUT /api/targets/<id>/progress`. Nothing in the capture or sequencer path touches
it. Live: a target with 8 attributed light frames (6 accepted, 720 s) reports
`capturedSubs: 0, totalIntegrationSecs: 0.0` against a 3600 s goal, rendered as a
permanent 0 %. `POST /api/projects` returns **404**, so `/api/projects` is
permanently empty for remote clients.

Confirmed from the GUI as well: Analytics → **Projects** shows the one target
(M81 / NGC3031) as **Integrated 0.0h · Sessions 0 · Frames 0**, with the summary
row reading *1 Targets · 0 Tracked · 0 Completed · 0.0h Total Integration*, on a
database holding 65 sessions. The screen is honest about what it has — "Goal: Not
set", "Remaining: –" — the data underneath is simply never written.

### C17. `imaging_sessions` never records profile, target or sequence provenance

```sql
select count(*), sum(profile_id is null), sum(target_id is null), sum(sequence_id is null)
  from imaging_sessions;  ->  65|65|65|65
```

All 65 sessions have NULL for all three and an empty `equipment_snapshot`. The
consequence is visible on both desktop and mobile: the **"Continue Session"** modal
offers a session with *"Equipment Profile: Unknown Profile"* and *"Sequence: No
Sequence"*, then a primary button **"Load Previous Setup"** which is a **silent
no-op** — no profile loaded, no sequence loaded, no toast, no error, and the
dashboard still reads "No active target — load a sequence to begin."

---

## P0/P1 — the sequencer long tail

### Q1. Target state leaks between runs, so a calibration run is silently skipped and reported `completed`

A sequence with **no `TargetHeader` anywhere** (`InstructionSet → ChangeFilter →
TakeExposure(dark)`) produced, 4 ms after start:

```
WARN Trigger fired: Altitude Limit (altitude_limit) - action: NextTarget
INFO execute_children_sequential completed with result: Skipped
```

Final API state `{"state":"completed","progress":1.0,"message":"Skipped: root"}`,
`framesCaptured: 0`, `sequence_runs.status='completed'`, **zero FITS written**.
An altitude-limit trigger can only be evaluated with target coordinates; this run
has none, so it used the **previous run's**. Reproduced four times independently.

Operator impact: image a night of lights, then queue your darks and flats. The
calibration run captures nothing and the app reports success.

### Q2. The same leak causes an unwanted physical slew that bypasses the daylight gate

Same shape, worse outcome. A target-less sequence, 15 ms after start:

```
[MERIDIAN] Pre-flip altitude check: target 'B' altitude = 10.5°
[MERIDIAN] FLIP TRIGGER ACTIVATED
[MERIDIAN]   Target: B     Hour Angle: 11.18h (670.5 minutes past meridian)
[MERIDIAN] Slewing to target (flip side): RA=18.0000h, Dec=60.0000°
[MERIDIAN]   ✓ Slewing to target (flip) (took 15.1s)
```

`Target: B` / RA 18h / Dec +60° are verbatim the previous run's target. **The mount
really slewed.** Two further defects in the same trace: an explicit `SlewToTarget`
node *is* correctly refused in daylight (*"Sun altitude 42.6°…"*) but the
**trigger-driven flip slew is not gated at all**; and a target **11.18 hours past
the meridian** was treated as needing a flip, so the meridian window has no upper
bound. The flip then retried on backoff for 131 s while status read
`state:running, progress:1.0, message:"Completed: root"`.

### Q3. `Parallel` runs two exposures on one camera concurrently and they can collide on one filename

```
15:27:42.562434 Starting 0.4s exposure on camera sim_camera_1
15:27:42.562553 Starting 0.4s exposure on camera sim_camera_1   <- same camera, overlapping
15:27:43.320428 Saving FITS image to: .../Dark_nofilter_0001_011.fits
15:27:43.320429 Saving FITS image to: .../Dark_nofilter_0001_011.fits   <- same path
```

`captured_images` ends with **two rows pointing at one file**; one frame's data is
gone. End-of-campaign reconciliation: 73 rows, 72 distinct paths, 72 files on disk.
Nothing serialises camera access across parallel branches and the unique-filename
resolution is not atomic. The concurrent same-camera exposure is 100 %
reproducible; the collision is the race it enables.

### Q4. Frames captured inside `Parallel` or `SmartExposure` are never counted

`framesCaptured: 0`, `integrationSecs: 0.0` and `targetBreakdown: {}` while the DB
and disk hold the frames. Two independent causes, both located:
`node/logic/parallel.rs:78-82` sets `branch_context.progress_callback = None`, so
branches emit no events at all; and `executor/mod.rs:2531-2545` maps only
`NodeType::TakeExposure`, so a `SmartExposure` node's own id is never in
`exposure_node_metadata` and no `ExposureCompleted` is emitted.

### Q5. `maxSafetyIterations` is a placebo the validator recommends

The validator refuses `forever`/`whileDark` loops as *"Unbounded Loop"* and tells
the user to add *"a safety iteration cap on the loop"*. Setting one clears
validation and is then **never serialised** — `serialization_operations.dart:586`
emits only `{type, iterations, condition, condition_value}`, Rust's `LoopConfig`
has no such field, and `loop_node.rs:65` sets `max_iterations = u32::MAX`.
Measured: caps of 2 / 3 / 5 / 10 produced 1 / 29 / 58 / 55 actual iterations. Every
one of those loops was terminated by the Q1 stale-target trigger, not by any cap —
without that accident they would have run forever.

Independently re-verified: Rust's `LoopConfig` (`sequencer/src/lib.rs:1689`) has
exactly four fields — `iterations`, `condition`, `condition_value`,
`horizon_profile`. There is no safety-cap field for the value to land in. Yet
`unbounded_loop_safety_section.dart:127` renders a slider and tells the operator
in so many words: *"Loop will stop after N iterations even if the condition is
still met."* That sentence is false, and it is the exact remedy the validator
points users to.

### Q6. Seven dome and cover instruction nodes are structurally dead

The executor is only ever given camera, mount, focuser, filter wheel and rotator
ids — never dome, cover-calibrator, weather or safety monitor — even with
`sim_dome_1` connected and listed. `OpenDome` then fails, and the failure is
misrouted into the **disconnect-recovery** ladder:

```
ERROR Open Dome failed: No dome connected
WARN  [RECOVERY] Instruction 'd1' failed on device disconnect; waiting for recovery driver…
INFO  [RECOVERY] Device reconnected; retrying instruction 'd1'   <- untrue, nothing disconnected
… ×5 … giving up
```

while `/api/sequencer/status` reported `message: "Recovered — resuming sequence"`.

### Q7. Smaller sequencer defects

* **`WaitForTime` twilight countdown is 60× understated** — Rust logs
  `Waiting 45016 seconds`, the UI shows `"Wait: 750s remaining"`. The Rust side
  formats *minutes*, the Dart parser grabs the first number and labels it seconds.
  The `wait_until` branch is correct; only the twilight branch is wrong.
* **Autofocus progress is pinned at `step 0/N`** for the whole run —
  `parse_autofocus_detail` searches for the literal `"step "` while the emitter
  writes `"Point {}/{}"`. The HFR half parses fine.
* **`autofocusRuns` and `ditherCount` are always 0** — `recordAutofocus()` and
  `recordDither()` have **zero call sites** in the tree, unlike their siblings
  `recordTriggerFire()` and `recordMeridianFlip()`. These land in
  `sequence_runs.stats_json` and in the night report. Corroborated independently
  against historical rows on the lead's rig, which show exactly that asymmetry:
  `"triggerFires":2, ... "autofocusRuns":0, "meridianFlips":0, "ditherCount":0`.
* **Progress reaches 100 % / "Completed: root" while the run still drives
  hardware** — observed for 86 s, 88 s and 131 s in three runs, with a `WARN`
  admitting it will wait up to **900 s**.
* **Cyclic `childIds` → `500 internal_error: "Stack Overflow"`** on save.
  A 40-deep *acyclic* nesting saves and runs fine, so it is the cycle specifically.
* **`totalIntegrationSecs` is neither integration nor seconds** —
  `sequence_repository.dart:498` returns `estimatedDurationMins * 60`. Measured:
  0.001 s, 0.5 s, 4 s and 59 s of real integration all report **60**.
* **A deliberate Stop is recorded as a run error** (`errorMessages:
  ["Sequence cancelled"]`), and the terminal-state vocabulary disagrees across
  three layers: `stopped` / `cancelled` / `paused-stopped`.
* **A loop or conditional whose altitude condition cannot be evaluated aborts the
  whole run** rather than failing validation at save time.

## P1 — autofocus, guiding and the wizards

### G1. The built-in guider's dither grows without bound and deterministically kills guiding mid-night

35 dithers, all requesting a constant `amount: 2.0` px. The commanded magnitudes:

```
4.39 5.70 7.13 8.92 10.30 11.31 12.00 12.65 13.27 13.86
9.08 11.88 15.32 16.00 16.49 16.97 17.44 17.89 18.33 18.76 19.18 19.60 20.00 20.40 20.78
```

At 20.78 px the guider emitted `Error: "Guiding stopped: Unable to match guide
stars"`, stopped guiding, and **removed itself from `/api/devices/connected`**.
Reproduced independently with a single `amount: 15` → 21.96 px → same instant
death.

`builtin_guider.rs:819-842` computes a Vogel-spiral **position**
(`radius = base * sqrt(n+1)`) and then adds it to `desired_offset` as an
**increment**. `dither_step` is never reset — not by `start_guiding`, not by
`stop_locked` (which resets `desired_offset` but not the step) — so it grows for
the process lifetime until the jump exceeds `GUIDE_MAX_MATCH_DISTANCE_PX = 20.0`
and the next frame finds no star match.

With the shipped `default_dither_pixels = 5.0` and the adaptive factor at ~1.5, the
**8th dither of the night** already exceeds 20 px; even at 1.0 the 17th does. On a
dither-every-sub run that is well under an hour of unattended imaging, after which
guiding is dead *and* the guider is disconnected so recovery must reconnect it
first. The user's requested amount is also never honoured after the first dither:
asking for 2 px gets 13.9 px by the tenth.

### G2. The settle timeout terminates healthy guiding with no dither in flight

`settlePixels: 0.05, settleTimeout: 20`; calibration succeeded, guiding ran at
**0.30 px RMS**, and 20 s later: `"Guiding stopped: Settle timeout exceeded (20s)
during guide settle; guiding RMS 0.30px still above threshold 0.05px"` — guiding
stopped, guider disconnected. `apply_settle_state` runs on *every* guide frame and
arms the deadline whenever it is null, including during ordinary guiding, and
exceeding it returns `Err` which fails the loop task. With realistic values
(1.5 px / 60 s) one minute of wind or thin cloud ends guiding for the night.

### G3. The autofocus sweep is not clamped to the focuser's travel range

Starting autofocus with the focuser at position 100 drove it to **negative
positions** (`Moving simulator focuser to position: -100`). The same app rejects
that through its own API (`"Value must be >= 0.0"`, `"outside the travel range 0 to
50000"`). `autofocus.rs:109-134` derives the sweep purely from
`current ± steps_out*step_size` with no reference to the focuser's limits, and
moves via `device_ops.focuser_move_to`, bypassing the REST validator. A real
ASCOM/INDI focuser throws on an out-of-range move, so autofocus hard-fails at
sweep point 1 whenever the focuser sits within ~750 steps of either limit (with
defaults). Not provable end to end here — the simulator accepts out-of-range
positions on the native path.

### G4. With the site cleared, the meridian flip's only pre-flight safety gate fails open

The destructive `POST /api/settings/location` shape (C4) has a direct safety
consequence:

```
[MERIDIAN] Observer location unavailable — cannot verify target altitude before flip. Proceeding with flip.
[MERIDIAN] Observer location unavailable, using longitude=0 for LST calculation
[MERIDIAN]   Hour Angle: 6.10h (366.0 minutes past meridian)
```

versus the correct run with the site set: `altitude = 76.2° (minimum = 10.0°)`,
`Hour Angle: 1.20h`. The altitude gate is skipped entirely and the hour angle is
wrong by the longitude offset — up to 12 hours.

### G5. Smaller routine defects

* **The built-in guider is invisible to every REST guiding surface while actively
  guiding.** `/api/phd2/status` and `/api/run-watch/snapshot` both report
  `disconnected` with null RMS while the guider is locked on and correcting.
  `run_watch_handlers.dart:184` calls `phd2GetStatus()`; the device-aware
  `api_guider_get_status` exists in Rust but is **not bridged to Dart** and there
  is no `GET /api/guider/status` route. Run Watch and the web dashboard therefore
  show "guiding: disconnected" all night whenever the app's own guider is in use.
* **`start-guiding` returns `{"status":"guiding"}` in 18 ms**, before calibration
  (which completed 6.6 s later) and without waiting for settle. Definitive case: it
  returned success at 16:08:59 and three seconds later logged
  `Built-in guider task failed: Calibration star match failed`. An automation
  client that trusts the 200 exposes against an unguided mount.
* **`backlashApplied: true` is reported when no backlash move happened** —
  `autofocus.rs:225` reports *configured*, not *applied*. And `backlashOut` can
  never fire in an autofocus run, because every move in the sequence approaches
  from the same direction. (Backlash **IN** was verified genuinely working.)
* **"Flip verified by coordinate convergence" is vacuous** — with pier-side
  telemetry unavailable, `meridian_flip_executor.rs:887-905` only checks that
  RA/Dec matches the target, which is true after *any* successful slew. On a real
  mount without pier-side reporting that re-pointed on the same side, this declares
  a verified flip, and guiding then resumes with a Dec-inverted calibration.
* **A focuser disconnect mid-autofocus hangs 4m11s and writes 2468 identical WARN
  lines** at ~10 Hz, because `wait_for_focuser_idle` treats a hard "not connected"
  the same as a transient poll error, with no classification and no backoff. The
  restore path also runs *outside* the autofocus timeout, so the advertised maximum
  duration can be overrun by ~250 s.
* **`Settling`/`SettleDone` ping-pong every ~4 s** for a whole session during
  steady 0.3 px guiding against a 2.0 px threshold — any UI bound to these flickers
  all night.
* **`method` on `/api/focuser/autofocus/start` is silently ignored**, and an
  unrecognised `curveFitting` (`"BOGUSGARBAGE"`) silently falls back to VCurve with
  a 200.
* **`stop-guiding` mid-calibration takes 4.7 s** and publishes `CalibrationComplete`
  *and* `GuidingStarted` **after** the operator's Stop — the UI reads "Guiding
  started" following a Stop while the mount is still being pulsed.
* **A failed flat calibration returns `errorMessage: null` over REST** even though
  the GUI shows the real reason.
* **`POST /api/sequencer/meridian-flip` is a synchronous five-minute HTTP call**
  across the retry ladder, with no job id or progress affordance.

### Correction to the simulator verdict list

The brief warned that meridian-flip work would be unverifiable given the stubbed
mount telemetry. **That was wrong, and the investigator disproved it:** the flip
never reads the mount's `altitude`/`azimuth`/`siderealTime`. It reads only RA/Dec
and computes LST itself from the system clock plus site longitude
(`executor/mod.rs:5137`, `meridian.rs:222`). Verified live — HA 1.20 h and altitude
76.2° were both computed correctly for lon −75. The 8-step ladder, its ordering,
and the retry ladder (`[30,60,120]` s, 4 attempts) are all genuinely testable and
all behaved correctly. **Only `sideOfPier` is affected**, which is finding G5's
vacuous-verification item. Item 2 of the "cannot be tested" list below should be
read as narrowed to post-flip pier-side confirmation only.

## P1 — the simulators themselves

### F1. Two different camera simulators, both live, differing by 5.6× in pixel count

| | sequencer / autofocus / guider | `POST /api/camera/expose` (manual capture, UI, viewer) |
|---|---|---|
| generator | `bridge/src/sim_frame.rs:73` | `bridge/src/api/imaging.rs:1247` |
| dimensions | **1920 × 1080** | **4144 × 2822** |
| determinism | fixed-seed, 45 stars | new random field every frame |
| focuser coupling | yes | **none** |
| guide-pulse coupling | yes | **none** |
| star count | 45 fixed | `100 + exposure·50`, capped 500 |

`imaging.rs:772` short-circuits on `starts_with("sim_")` before reaching
`UnifiedDeviceOps`. Every measurement an operator sees after pressing Capture comes
from a generator the sequencer never uses, and vice versa.

Confirmed from the product UI, not just the API: a 55 s snapshot taken from the
Android app reported **4144 × 2822, HFR 2.69, 500 ★**.

### F2. The manual-capture path fabricates the HFR and eccentricity it reports

```rust
// api/imaging.rs:850-853
hfr: Some(2.5 + (rand::random::<f64>() - 0.5) * 0.5),   // Simulated HFR
eccentricity: Some(0.15 + (rand::random::<f64>() - 0.5) * 0.1),
```

Not measured — a random number in [2.25, 2.75] presented as a measurement. The
2.69 the phone displayed sits inside that range, and the 500 stars is exactly
`min(100 + 55·50, 500)`. Any HFR-degradation trigger or focus-drift detector
validated on this path was validated against a random number generator.

### F3. The API's simulator arm has no connected-gate; disconnected devices execute commands

With the mount **disconnected**:

```
POST /api/mount/slew {"ra":12.34,"dec":-5.6} -> {"status":"slewing"}
POST /api/mount/park                          -> {"status":"parking"}
GET  /api/mount/status -> {"connected":false,"tracking":true,"parked":true,
                           "rightAscension":12.34,"altitude":45.0,...}
```

A disconnected mount simultaneously tracking and parked at coordinates it accepted
while disconnected. `sim_gate.rs` was written specifically to stop this — its own
header says so — but was applied only to the DeviceManager arm. Every
"device disconnected mid-run" test on the HTTP surface is therefore meaningless.

### F4. Mount alt/az/LST are hardcoded or stale, and marked `available`

After `POST /api/mount/slew {"ra":5.5,"dec":30.0}` from the app's own configured
site, RA/Dec tracked correctly but:

```
altitude 0.0   azimuth 0.0   siderealTime 0.0
availability: {altitude:"available", azimuth:"available", sidereal_time:"available"}
sideOfPier "unknown"   while   availability.side_of_pier "available"
```

Independently computed truth at that instant: **altitude +72.83°, azimuth 239.76°,
LST 6.642 h.** After an alt/az slew the fields become sticky leftovers instead —
one measurement showed **199.85° of azimuth error**. A slew to Dec −80° from
lat +40° (permanently ~30° *below* the horizon) is accepted and reported at
**+45° above** it.

The app is not incapable of this: the desktop header's LST read **06:51:32** at
11:27:42 local, matching an independent calculation to ~2 seconds. Only the device
path is stubbed. `FieldAvailability`'s own doc (`device.rs:232-237`) states the
purpose of the map is to stop *"a fabricated default value… caus[ing] the
sequencer/UI to silently treat broken mounts as healthy."*

### F5. Every simulated frame is a star field — darks, biases and flats included

`ops/camera.rs:1067` is never passed the frame type. A DARK captured at true focus
contains **exactly 45 compact peaks above 1000 ADU**, brightest 33,780 ADU. The
API arm is worse: `frameType:"dark"` produced **148 star cores** plus 20 randomly
placed hot pixels, and `imaging.rs:784` hardcodes the event so a dark
**announces itself as a light**. The sequencer dark's background is additionally a
deterministic diagonal sawtooth `200 + ((x+y)%400)`, so subtracting it as a master
dark injects a diagonal ramp into every calibrated frame.

### F6. Exposure, gain and offset move zero pixels on the sequencer path

An 8.0 s / gain 0 / offset 0 frame vs a 2.0 s / gain 120 / offset 30 frame at the
same focus: mean 408.623 vs 408.620, std 354.830 vs 354.820, **99.73 % of pixels
bit-identical**. The apparent noise is a ramp — lag-1 autocorrelation 0.9835, and
row 500 literally reads `300, 301, 302, 303, …`. Dynamic range is **442 of 65,536
ADU (0.67 %)**, so saturation, clipping and well-depth handling cannot fire at all.

### F7. Everything else that is a frozen constant

Weather and safety monitor have **no writer** — connect/disconnect are the only
code that touches them, `SafetyMonitorCapabilities { is_safe: true }` is hardcoded,
and there is no API to change any of it, so the simulator can only ever say
"perfect and safe". Focuser temperature is a hard 20.0. Dome slaving is a complete
no-op (mount slewed 3.5 h of RA; dome azimuth stayed at 123.4). `slewing` is never
set true in the DeviceManager arm, so slew-settle, move timeouts and
abort-mid-motion are no-ops in a sequencer run. Rotator sky angle and mechanical
angle are written to the same value in all four arms, so the transform is untested.
`get_simulator_capabilities` is a third, frozen description that contradicts live
status on every device — including a camera whose delivered 4144-px frame exceeds
its own advertised `maxWidth: 4096`.

### The seventeen things that cannot be tested at all

Horizon limits and altitude safety-park · **post-flip pier-side confirmation only**
(narrowed — the flip's trigger, timing, altitude gate, 8-step ladder and retry
ladder are all testable and were verified working; the flip computes LST itself and
never reads the stubbed telemetry, so only `sideOfPier` is affected, which is what
makes "verified by coordinate convergence" vacuous) · anything measured off a
manually captured frame · dome slaving, slew
waits and shutter transitions · weather-triggered abort/pause/park · safety-monitor
unsafe response · defect-map generation · dark/bias/flat calibration quality ·
autofocus temperature compensation · cooler saturation and delta-T limits ·
device-disconnect-mid-operation on HTTP · motion-in-progress handling in the
sequencer · saturation/clipping/`maxAdu` · binning, subframe and pixel-scale
geometry · rotator sky-vs-mechanical transform and reverse · airmass and
parallactic angle · plate solving, framing accuracy and mosaic differentiation.

### The two fixes that collapse the most defects per line changed

1. **Delete the api-layer `sim_` short-circuits** in `api/devices/simulation.rs`
   and `api/imaging.rs:772`, routing both through the DeviceManager arm. Collapses
   F1, F2, F3, F5 and the motion-state half of F7 at once, and makes `sim_gate`
   do the job it was written for.
2. **Compute `altitude` / `azimuth` / `sidereal_time` in `read_mount_status()`**
   from the existing `meridian.rs` maths plus the stored site — or mark them
   `Unsupported`. Either is honest; the current state is the only option that is
   not.

---

## P0/P1 — multi-client and the thin-client "couch" experience

Driven with a real desktop host serving on :8100 plus two `--remote-host` GUI
clients on their own displays and HOMEs, plus HTTP clients as extra actors.

### M1. The thin client cannot start a run, and the failed attempt bricks the host's Start button for the night

Pre-flight passes ("All Checks Passed"); pressing **Start Sequence** on the remote
GUI yields a red banner containing a raw SQLite error:

```
Failed to start sequence: SqliteException(787): FOREIGN KEY constraint failed
  INSERT INTO "sequence_runs" (...) VALUES (?,?,?,?), parameters: 1, COUCH-DARKS, …
```

`sequence_executor.dart:636` writes the run row to the **local** Drift DB
regardless of whether the backend is a `NetworkBackend`; the client's DB has zero
`sequences` rows, so the FK fails. But the line above it (`:622`,
`sessionNotifier.startSession`) **does** go remote — so the host is left with an
orphaned `active` imaging session and no run:

```
host imaging_sessions: 1|COUCH-DARKS|…|active
host sequence_runs:    0
```

That orphan then blocks the host permanently. `load-and-start` returns
`409 active_session_exists`, and — worse — **the host's own GUI Start button does
nothing at all**: modal closes, state stays `idle`, no toast, no banner, nothing
in either log. `POST /api/sequencer/reset` clears it and the identical click then
works. One Start press from the couch silently disables the observatory's Start
button, with no message anywhere.

### M2. Session ownership is dead code — nothing in the shipping product ever claims it

`RemoteOperations.claimSession` / `takeOverSession` / `releaseSession` have **zero
call sites** in `apps/` or `packages/` — not the desktop thin client, not mobile,
not the web dashboard. Verified live: with a thin client connected and actively
driving the mount, `GET /api/session/owner` returned `{"owner":null}` throughout,
and the middleware falls through when the slot is empty. So the operator slot is
never occupied and every gated endpoint is open to every control-scope client. The
mobile app listens for an `OwnershipTakenOver` event that nothing can emit.

The state machine itself is sound when driven directly by curl (claim → 200,
second claimant → 409 with the owner's identity, take-over mid-run leaves the run
undisturbed, release and auto-release both work). It is simply never used.

### M3. The ownership gate misses the endpoints that matter, including sequence start

63 of 311 POST routes are gated. Verified with owner = A, attacker = B:

| endpoint | non-owner result |
|---|---|
| `POST /api/sequencer/start` | `409 not_session_owner` ✔ |
| `POST /api/sequencer/load-and-start` | **`200 {"status":"started"}`** — full run |
| `POST /api/sequencer/stop` | `409 not_session_owner` |
| `POST /api/devices/disconnect` (camera, mid-exposure) | **`200 disconnected`** |

So a non-owner can **start a run it is then forbidden to stop** — a runaway with
no off switch for its author. Also ungated: `/api/devices/connect`, `/api/phd2/*`
(dither and calibration, i.e. real mount motion), `/api/settings*`,
`/api/profiles/*`, `/api/system/update/apply` and `/rollback`.

### M4. Heartbeat auto-release evicts an operator while their own run is executing

`touchHeartbeat` has exactly one call site — the ownership middleware, on gated
destructive POSTs only. The doc comment claims it is "updated on every WS frame
from the owner"; **there is no WS call site**. Verified: A claimed at 15:45:51,
then polled `/api/sequencer/status` continuously with A's token while A's own
sequence ran; at 15:52:45 the slot read `{"owner":null,"mode":"unowned"}`. An
operator *watching* their own five-hour run loses the slot after five minutes.

### M5. Kill the host mid-run and the client presents a dead rig as live

Host `SIGKILL`ed at frame 3/40. The client correctly shows a red **Offline** chip
within 5 s — and then keeps everything else looking live for at least 60 s:
"Running" pill, "Running 8%", **Sequence 3/40**, Camera **Exposing / Remaining
5s**, Mount **Tracking**, Pause/Stop/Skip still enabled, header clock still
ticking. **There is no "last updated" age anywhere**, and **pressing Stop does
nothing at all** — no toast, no error, no state change. Emergency control fails
silently against a dead host.

After the host returns the client reconnects correctly, but the dashboard's
headline state pill stays stuck on **"Capturing"** for minutes while the host says
`idle`, the client's own Equipment card says "No equipment connected", and its own
status bar says "Idle".

### M6. A second client joining mid-run is told the live run was "interrupted", and Discard destroys its checkpoint

Client #2 connected at frame 25/40 and was shown *"Recover Sequence? — A previous
sequence was interrupted and can be resumed. LONG-DARKS · Saved 0m ago · Completed
25 frames"* — for a sequence running at that moment. **Resume** is correctly
refused. **Discard** flipped `hasCheckpoint` true → false while the run continued
to frame 34: the live run's crash-recovery checkpoint was destroyed by a second
client acting on a false prompt. If the host then dies, the night is unrecoverable.
The host GUI showed the mirror image — an unprompted "Incomplete Sessions Found"
modal offering to discard the run it was executing.

### M7. Concurrent starts, lost updates, and no read-only pairing

* Two simultaneous `load-and-start`: exactly one wins (correct), but the loser gets
  `500 internal_error` naming the *previous* state — a concurrency conflict
  reported as a server fault. 3/3 reproducible.
* Two concurrent `save-full` on the same `databaseId`: both get `200 {"id":1}` and
  one edit is silently gone. No version, etag or `If-Match` on the endpoint.
* **A guest who asks for `view` scope is silently upgraded to `control`** —
  `pairing_handlers.dart:722` maps both to control, documented as deliberate. That
  token then slews the mount and disconnects devices. The `view` scope is enforced
  flawlessly but is unobtainable by any client except the headless `--view-token=`
  flag. Token lifetime is one year.
* **The host operator cannot see who is connected.** With two thin clients
  streaming, Settings → Remote Access shows no client list, count or indicator, and
  `/api/collaboration/state` returned `"viewers":[]` throughout.

## P2 — devices, errors and remote parity

### R1. Rotator `mechanicalPosition` is fabricated by copying the sky position, on every real backend

`bridge/src/api/devices/simulation.rs:1344`, the **non-simulator** branch:
`mechanical_position: position`. Live against Alpaca with a real −30° sync offset:
device `pos=200.0 mech=230.0`, app reported `mechanicalPosition: 200.0`; later
**175° wrong**. `/api/v1/rotator/0/mechanicalposition` is requested exactly once,
at connect. `reverse` is likewise frozen at connect time and is never consumed in
any angle maths; `meridian_flip_executor.rs:589-609` has nine flip steps, none
rotator-related, and the post-flip recenter passes `target_rotation: None`. On a
GEM the run resumes imaging at a sky PA 180° from the pre-flip frames.

### R2. Switch and cover/calibrator are silently absent, and INDI flat panels are misclassified

No simulator exists for either, and the GUI discovery panel lists nine device
categories and simply **stops** — no "Switches" or "Cover Calibrators" section,
not even an empty one. Meanwhile `get_simulator_capabilities` contains full
hardcoded tables for a 4-port switch box and a 255-step flat panel that can never
be connected. Against a real `indiserver`, INDI `LIGHTBOX` and `DUSTCAP` devices
are classified as `switch_`, so `/api/cover/*`, the sequencer's Open/Close-Cover
instructions and the Flat Wizard can never bind to a real INDI flat panel through
the normal flow — even though the cover path works perfectly when the device is
connected manually as `coverCalibrator`.

### R3. Normal domain outcomes returned as `500 internal_error`

Reproduced against both Alpaca and INDI: rotator `move-to {angle:400}`,
`{angle:-45}`, `sync {positionAngle:1000}`, `cover/brightness {999}` (while the
same status reports `maxBrightness: 255`), `switch/set {value:500}` (status says
`maxValue: 100`), and writing a read-only switch — all `500`. Also
`POST /api/plate-solver/verify` with a mistyped path → `500 internal_error`, which
is the endpoint the settings page uses to check a hand-entered path, so the most
common setup mistake tells the user the appliance is broken. Sibling endpoints
(`dome/slew`, negative brightness, bad switch index) validate correctly with a
`400`, so the codebase already knows the right shape.

### R4. `/api/dome/sync` ignores its `azimuth` argument and turns slaving on instead

`{azimuth:45}`, `{azimuth:-45}`, `{azimuth:400}` all return
`{"status":"sync_enabled","syncEnabled":true}`. In ASCOM, dome sync means
`SyncToAzimuth(az)` — calibrate without moving. Here it starts the dome chasing
the mount. The argument is `enable`, not `enabled`, so `{"enabled":false}` also
returns `syncEnabled:true`. `canSyncAzimuth` is advertised in capabilities with no
endpoint that performs it.

### R5. `POST /api/settings` returns `{"status":"updated"}` for keys it discards

Mechanically diffed every key. Nine silently ignored, including the **entire
updater configuration**: `updateChannel`, `updateServerUrl`, `updateCheckEnabled`,
`updateCheckIntervalHours`, `skippedUpdateVersion`, plus `observer`, `telescope`,
`instrument`, `useSimulationMode`. 29 others persisted correctly, so this is
per-key. `GET` exports the full freezed model; writes go through a switch covering
135 keys and no-op for the rest. Consequence beyond cry-wolf: the app ships with
`updateServerUrl: ""` and reports *"Update server URL not configured"*, and **there
is no way to fix that through the API** — only the `SKOTIQ_UPDATE_SERVER` env
var. The shipping updater is unconfigurable on a headless appliance.

### R6. `POST /api/system/update/check` has no timeout, and Abort lies

Against a blackholed server: 5 min in, job still `running`; `abort` returns
`{"aborted":true,"cancelledJobs":[...]}` while the socket stays ESTABLISHED and
the job stays running; 35 min in, status is still `cancelling`, `check` 409s and
`abort` says `no_update_in_flight`. There is no recovery path short of an app
restart. `update_service.dart:245,319` uses bare `package:http` with no
`.timeout()`.

### R7. Zero server-side validation on settings

`bortleClass -5` and `9999` (scale is 1-9), `webServerPort -1` and `70000`,
`ditherEveryFrames 0`, `defaultGain -1000`, `plateSolveTimeout -1`,
`theme 'not-a-theme'`, a 5000-char naming pattern, `imageOutputPath
'../../../../etc/passwd'` — all accepted verbatim and preserved across restart.
`webServerEnabled:true` + `webServerPort:70000` produced no bound socket and no log
line. Only `safetyFailMode` validates, and it does so as a **500**. The GUI's
first-run wizard validates the same fields properly, so one surface is defended and
the other is wide open.

### R8. `GET /api/location` sends the host's IP to a third party over plaintext HTTP

`sequencer_recovery_operations.dart:524`:
`await http.get(Uri.parse('http://ip-api.com/json'))` — **`http://`, not https**.
The observatory's approximate coordinates and the host's public IP travel
unencrypted, on a fresh install, with no consent prompt and no setting to disable.
The updater in the same codebase refuses `http://` on principle, so the posture is
inconsistent. Credit where due: the **UI** around it is exemplary — the wizard card
says *"This is where your internet provider appears to be, not where your telescope
is, so it can be tens of kilometres out."* The dishonesty is at the API layer.

### R9. `/api/suggestions/tonight` returns nothing while the same process's GUI shows 1193 candidates

Same running app, same instant: the desktop Plan Tonight reads *"Tonight's
candidates — 1193 targets after filters"* with a full NGC0752 card, while
`GET /api/suggestions/tonight` returns `{"suggestions":[],"totalMatching":0}`.
`suggestion_handlers.dart:115` scores `targetsDao.getAllTargets()` — the user's
**saved library**, which holds one row — rather than the installed catalogs. Every
non-Flutter client asking the appliance what to image tonight gets an empty array
with no reason field.

### R9b. `/api/sequencer/load` succeeds and `/api/sequencer/start` then refuses it as empty

On a GUI instance that also serves the API:

```
POST /api/sequencer/load  {"json":"<valid SequenceDefinition, 1 TakeExposure root>"}
  -> {"status":"loaded"}
POST /api/sequencer/start
  -> {"code":"sequence_validation_failed",
      "message":"Cannot start sequence: 1 validation error: Empty Sequence",
      "issues":[{"title":"Empty Sequence",...},{"title":"No Exposures",...}]}
```

The validator is describing a *different* sequence from the one that was just
loaded — the empty "New Sequence" the GUI happened to have open. **Honest limit:**
another investigator ran this exact recipe successfully on a **headless** rig, so I
have not isolated whether the split is GUI-specific or a general Rust-vs-Dart
current-sequence divergence. Either way, `load` returning `loaded` for a sequence
that `start` then calls empty is a contradiction a remote client cannot debug.

### R10. "Tonight's candidates" recommends non-imageable catalog artifacts

The **#1 recommendation for the night** (score 78) was NGC7748 — OpenNGC type `*`,
a single 7.15-mag star — presented with a "Star" chip, *"Excellent peak altitude
(60°)"*, and **Send to Framing** / **Review in Sequencer** buttons. The installed
OpenNGC contains 546 `*`, 243 `**`, **651 `Dup`** and 10 `NonEx` rows — 1,869 of
13,969 entries that are not imaging targets and are not excluded from the pool.

### R11. The catalog "package size" chooser is a placebo, and Settings then reports a false depth

Choosing **Essential (~10 MB, "magnitude < 6.5, ~9,000 stars")** installed the
identical 33.9 MB / 119,614-star file that Standard and Complete install. Settings
then prints on the same card *"Objects 119.6k · Package Essential · Depth
mag ≤ 6.5"* — telling the user their catalog is limited to naked-eye stars while
sitting on the full file. Separately, `catalog_settings_screen.dart:455` hardcodes
`latestVersion: '4.2'` while the app installs **v4.4**, so a catalog installed 60
seconds earlier permanently advertises "Update available" and re-downloading can
never clear it.

### R12. Two surfaces in one app disagree about the same camera's field of view by 47%

Same connected camera, same profile (600 mm f/5.0), same instant:

| surface | sensor used | FOV | image scale |
|---|---|---|---|
| desktop **Framing** screen | 4144 × 2822 @ 3.76 µm (live `status`) | **1.49° × 1.01°** | 1.29 ″/px |
| `GET /api/planetarium/fov-config` | 4096 × 4096 @ 3.8 µm (frozen `capabilities`) | **1.49° × 1.49°** | 1.306 ″/px |

Hand-checked both: the Framing screen's arithmetic is exactly right for the real
sensor. The API path draws a **square** frame for a 3:2 sensor and overstates the
vertical field by **1.47×**. It feeds the planetarium FOV overlay and every remote
client. (An earlier read of mine attributed this to the Framing screen as well —
that was wrong; Framing is correct.)

### R13. The framing / HiPS sky view is east–west mirrored

Verified on M81/M82, whose separation is unambiguous (M82 is ~37′ north and ~1.7′
east of M81). Rendered at the measured scale, M82 lands ~245 px up and ~10 px
**right** of M81 — matching the computed 233 px and 11 px — and the axis labels
read **N top, S bottom, W left, E right**. Internally consistent, but mirrored
relative to the N-up/**E-left** convention that DSS presentation and plate-solved
frames use. For a framing tool whose whole job is to predict what the camera will
record, that is the wrong way round.

Also visible on the same screen: the round gear button **overlaps and clips the
survey dropdown**, rendering "DSS2 Red" as "SS2 Red".

### R14. The OpenNGC upstream fallback can never succeed

One `sha256` is pinned per source and every candidate's as-downloaded bytes are
checked against it. Measured today:

| candidate | sha256 | bytes |
|---|---|---|
| GitHub release `NGC.csv` (primary) | `840fe0c9…aa9e` | 3,876,288 |
| upstream `raw.githubusercontent.com/…/master/NGC.csv` (fallback) | `be150bda…6fae` | 3,876,622 |
| pinned in source | `840fe0c9…aa9e` | — |

So in the only situation the fallback exists for, it downloads fine and is then
rejected as corrupt. Structural rather than a stale pin: the fallback tracks a
mutable `master` branch. HYG shows the intent working — its two candidates are
byte-identical and match. All four URLs returned 200, so neither catalog is dead.

---

## P2 — UI / UX

* **The framing / HiPS sky view is east–west mirrored.** Centred on M31, M110
  (west, north) renders up and **left**; axis labels read W-left, E-right. Standard
  sky orientation is N up, **E left**. Consistently mirrored, so a user comparing
  the preview with a captured or plate-solved frame sees it flipped.
* **The Dome device card never shows telemetry** — `Azimuth: ---`,
  `Shutter: Unknown`, unchanged after Open Shutter with no toast or error, while
  the API reports `azimuth:0.0, shutterState:"closed"` for the same device. Roof
  state is *the* safety-critical readout for an observatory.
* **There is no UI for the safety settings that matter.** No control anywhere for
  `failMode`, `autoCloseRoofOnUnsafe`, `checkIntervalSeconds`, `enabledMonitors`,
  or rain/sky-temperature thresholds — and searching settings for "fail" finds
  nothing. There is no safety-monitor status screen at all.
* **Unsafe reasons never name the metric.** Humidity 99, wind 50, cloud 100 and
  rain 5 simultaneously all produce the single string *"Weather device reports
  unsafe conditions"*. `WeatherThresholdResult.breach` knows which sensor tripped
  and is discarded at `weather_safety_provider.dart:1260`.
* **Raw internal error text reaches the operator**, e.g.
  `Dome slew failed: SkotiqError.invalidParameter(field0: Dome azimuth must be
  finite and in [0, 360))` — from a dialog whose own prompt says "0 - 360 degrees".
* **The object detail panel is not clamped to the viewport** — clicking a star on
  the right of the planetarium pushes it off-screen, truncating the coordinates and
  making Slew / Framing / Sequence unreachable. Escape does not dismiss it.
* **Every mobile screen shows its own tour card, positioned over real content.**
  On Sequence the empty state says *"Tap + to add nodes"* while the card covers the
  **+** FAB; on Imaging it covers the capture buttons; on Gear it covers the
  Discovery result line. Two overlays were on screen at once after pairing.
  Dismissal itself does persist across navigation — that part is correct.
* **Mobile Imaging overlays collide.** The HFR chip, histogram and stats panel
  overlap each other and the image; before a capture they are clipped off the top
  of the viewport. The **Controls** sheet covers the whole preview and cannot be
  closed by its drag handle or by swiping — only the system back button works.
* **Durations are formatted in units too coarse for the data.** "Continue Session"
  reads *"8/8 frames captured, 0 minutes integration"* for a session whose DB row
  says `total_integration_secs = 24.0`; Analytics → History renders all 65 real
  sessions as *"0m · 0.0h"*.
* **The Recent Events feed carries raw internal payloads** —
  `Equipment / Property changed — system · device_change=removal` — and is flooded
  at startup by *"Heartbeat started / Heartbeat stopped / Heartbeat started"*,
  because the heartbeat is started **twice per device per connect** from two
  independent call sites 195 ms apart. Six such rows in a five-row panel means
  anything real has already been evicted. The existing repeat-collapser cannot
  merge them because they alternate.
* **Two different rise times on one card** — the desktop NGC0752 card warns *"Rises
  late at 21:40"* while its own altitude panel reads *"Rise: 21:44"*. Independent
  calculation says 21:44 is right.
* **"Skip this step" silently does nothing** in the first-run wizard when a field
  holds an out-of-range value; the only text on screen is the validation message.
  **"Back" is visually enabled on Step 1 of 13** and is a no-op.
* **The Sequencer header's validation badges are a dead end, and their counts
  disagree with pre-flight.** A brand-new empty sequence shows `⊘1 ⚠1` in the
  header. The badges are not clickable and have no tooltip — hovering for four
  seconds produced nothing — so there is no way to learn what the error is from
  that surface. Pressing Start then opens a Pre-Flight modal reporting
  **1 error, 2 warnings, 2 info** for the same sequence. (The modal itself is
  excellent — see below — so this is a discoverability and consistency nit, not a
  blocker.)
* **The Imaging screen loses its filter picker below ~1300 px wide.** At 1024×768
  the "R" filter circle is **sliced vertically in half** by the panel edge and
  G/B/Ha/OIII/SII, the sensor temperature and the **Stretch** toggle are simply
  gone — no overflow menu, no scroll, no indication anything is missing. At
  1280×720 the Stretch toggle and both live metrics are already absent. **On a
  1366×768 laptop you cannot select a filter from the Imaging screen.**
* **The Save Path field wraps a path into a 12-line block**, breaking mid-token
  (`/tmp/` `claude-1000/-` `home-` `scdouglas-` …), 230 px tall, pushing the rest
  of the rail off screen. Settings → Files & Storage renders the identical path on
  one line with a middle ellipsis, so this is a bug and not a style choice. Any
  Windows path triggers it.
* **A raw Dart exception is shown in a user-facing tooltip**, verbatim and
  edge-to-edge: `Exception: Failed to connect … SkotiqError.connectionFailed(
  deviceId: …, reason: …)`. The failed chip never clears and offers no retry.
* **"Estimated integration: 3h 60m"** on the Plan Tonight card, 30 px below a chip
  reading "~4.0h". `_primary_target_card.dart:295` rounds minutes without carrying
  60 into the hour.
* **The Connection Status sheet renders half below the window and cannot be
  reached** — `showModalBottomSheet` inside a desktop shell that draws its own
  status bar. No scroll, no close button, Esc only. For a remote user this hides
  Host, Port, Latency, **Reconnect now** and **Disconnect**.
* **The app contradicts itself about safety 110 px apart:** a red *"Critical —
  Heavy cloud cover overhead (93%)"* card directly above a green *"Safety Status —
  Conditions safe for imaging"* card, both from the same source — while the
  notification bell reads *"No active alerts"*.
* **Twelve separate per-screen tours**, each needing its own dismissal, and each
  shrinking the content viewport by ~145 px while shown — the direct cause of
  several "content is clipped" symptoms. Dismissing the 7-step welcome tour with
  "Skip — I know what I'm doing" dismisses none of them.
* **Cards clip content mid-widget with no scroll affordance** — a "Dither" heading
  sliced in half; two buttons sliced so only their rounded tops draw; only 4 of 7
  Flat Wizard filters reachable; a rotator row reading `-15° -5° -1° | +1° +5°`
  because `+15°` is clipped.
* **RA/Dec is formatted five different ways** across five screens; temperature
  loses its degree symbol on Equipment only (`20.0C`, `Cool to -10C`) while the
  status bar on the same screen shows `20.0°C`; "nothing" is rendered as `0`,
  `0.0`, `--`, `—`, `No data` and `Not tracked`, often side by side in one list.
* **macOS ⌘K is shown as the search shortcut on a Linux build.**
* **Colour emoji survives Red Night mode** — the 🔭 glyph renders full white/blue,
  the brightest and only non-red element on screen, in the one mode whose entire
  purpose is preserving dark adaptation.
* **"System Health 100 – Excellent" sits directly above "1 item is blocking first
  light."**
* **The onboarding wizard never mentions observatory hardware** — 13 steps covering
  drivers, camera, mount, focuser, filter wheel, guider, optics, defaults, folder
  and site, with no dome, rotator, switch, cover, weather or safety-monitor step.

---

## Verified correct — do not re-investigate

**Astronomy.** All twilight boundaries (civil/nautical/astronomical, dusk and dawn)
within **3 seconds** of Meeus across six sites × six dates including both DST
boundaries; polar nulls correct at the exact poles; transit instants exact (hour
angle < 1 s) and transit altitudes exactly `90 − |φ − δ|`; moon position and
illumination in `skotiq_planetarium` within 0.15°/0.1 pp. DSO astrometry exact
(M31 → NGC0224, RA 10.68479°, Dec +41.26906°, 177.8′×69.7′). FOV overlay maths
exact — 1000 mm / 3.76 µm / 4144×2822 → 0.89° × 0.61°, 0.78 ″/px, f/10.0, and the
drawn rectangle measured to match.

**Plate solving.** A known `.wcs` came back numerically verbatim (CRVAL, pixel
scale, rotation, CD matrix). Hint plumbing is unit-correct (deg on the wire →
hours + south-polar-distance for ASTAP). Every failure mode is honest with no fake
success; timeouts kill the child with no orphan; the concurrency gate explains
itself. Fresh-install no-solver behaviour is truthful, fast and actionable, and
fails in <4 s **without taking an exposure**.

**Image pipeline.** HFR/FWHM arithmetic accurate against planted Gaussians
(σ=2.0 → 2.300 vs 2.3548 expected; σ=6.0 → 7.054 vs 7.064); `FWHM = 2 × HFR` held
exactly. Session `avgHfr` exact to 15 digits with NULLs correctly excluded.
Pathological FITS (all-zero, all-saturated, single hot pixel, NaN, lying NAXIS,
truncated, garbage, empty) all degrade honestly — 0 stars, no crash, no stale data
served under a new filename. Deleted-file handling returns 404 naming the missing
path. Calibration boundary comparisons are correct `<=` and the score penalties
match the documented formula.

**Backup.** Round trip is exact — `diff` of settings, targets and sequence nodes
all zero lines, unicode intact. All 15 malformed-backup cases refused cleanly with
a specific message and zero data change. Transaction rollback holds even after the
destructive clear. Path containment holds (`/etc/passwd` and `../../` both
refused; an upload named `../../evil` sanitised inside the backup dir). Crash
durability verified with SIGKILL mid-write: no stray WAL, `integrity_check` ok.

**Security boundaries.** Token scope enforcement is precise and actionable —
`POST /api/settings` with a control token returns
`{"requiredScope":"admin","tokenScope":"control","requiredResource":"system",
"requiredLevel":"admin"}`. The updater is fail-closed on transport (self-signed →
`CERTIFICATE_VERIFY_FAILED`; `http://` refused by policy; unconfigured → honest
failure, never a false "up to date"). Plugin surface is honest and structurally
unbreakable from outside. Rate limiting works with `retryAfterSecs`. `lan-claim`
correctly refuses loopback per its documented trust model.

**Alpaca and INDI.** Discovery, connect and the full command surface work against a
spec-shaped Alpaca server for all six device types, and against a real
`indiserver`. `capability_unsupported` errors are excellent — `400` naming the
capability. Auto-park works once weather safety is enabled: mount parked and
tracking off within 8 s, with the deciding input named. Safety decisions read the
driver live rather than through the capability cache.

**Simulator components that are genuinely good.** Exposure pacing is real
(1.0 s → 1.755 s wall; 4.0 s → 4.781 s). The cooler ramp is modelled (19.876 →
−10.0 °C at the declared 8 °C/s, 85 % pulling then 35 % holding). Autofocus against
the sequencer arm produces a real V-curve — R² 0.968, 41 stars at all 11 points,
best position **25066** against a modelled truth of 25075. The guide-pulse and
drift model translates the field rigidly, as intended. Filter wheel indexing is
consistent and bounds-checked.

**Web dashboard — every prior fix still holds on 6.0.** `GET /` with
`Accept: text/html` → **302 /dashboard**; `/favicon.ico` → **204**; the served
`dashboard/js/app.js` contains `sequencerProgressPercent` at all three sites, so
the 0-1-vs-0-100 progress bug has not regressed.

**Pre-Flight Validation is one of the best surfaces in the app.** Starting an
empty sequence produced: *"Cannot Start Sequence — Please fix 1 error(s) before
starting"*, a simulation panel (Duration 0s / Segments 0 / Targets 0 / Issues 1,
"Ends 11:55"), the warning *"Sequence is expected to start at 11:55, before the
dark window starts at 22:09"*, a named structural error *"Empty Sequence — The
sequence has no runnable instructions. Add at least one instruction to run."* with
the actionable hint *"Add exposure or other instruction nodes to the sequence"* —
and **"Start Sequence" correctly disabled**. Nothing was fabricated and nothing
was allowed through.

**Product surfaces that are well built.** The Plan Tonight empty state names the
missing OpenNGC catalog and offers "Open catalog settings" + "Reset filters" —
use it as the app's own benchmark. The first-run wizard gates honestly, validates
lat/lon inline *and* in a banner, computes image scale correctly, shows "Site —
not set —" rather than pretending 0/0 is a location, and "Skip onboarding" lands on
a working dashboard with no phantom state. Android pairing works end to end with
the real `WORD-WORD-NNNN` format. The status-bar device counter is scoped to the
active profile (2/2). Idle honesty is good throughout — `HFR ---`, `RMS ---`,
"No guide data", "No active target". Mobile landscape reflows cleanly with no
overflow.

---

## The static gates are green, and that is the point

`dart run tools/production/analyzer_rollup.dart` on this tree:

```
All: errors=0, warnings=1, infos=54
Production: errors=0, warnings=0, infos=1
Critical warnings: 0
```

`behavioral_audit.dart` completed with the committed register unchanged (`git
status` clean), so nothing regressed there either. That register is a **triaged
backlog**, not a pass/fail gate — every entry carries a status and a rationale.

Worth noting precisely, because it is a near miss: the audit **has** a detector
for this defect class, `literal_null_coalesce` — "a literal default standing in
for a real value". It only matches `??` expressions. The safety evaluator's

```dart
bool safetyMonitorSafe = true;
if (isSafetyMonitorConnected) { ... }
```

is a plain assignment plus a conditional overwrite, so the detector never sees it.
`weather_safety_provider.dart` *is* in the register, marked
`accepted_modeled_approximation` — but for six entirely unrelated hits (the
conditions-score weights at lines 1091-1094 and two empty catches). **The P0 was
not reviewed and accepted; it was invisible to the tool.** Widening that detector
to cover `bool x = <literal>` followed by a guarded overwrite would have caught it.

Every defect in this report was found by *running* the app, not by analysing it.
None of them are type errors, unused imports or lint violations — they are a
default of `true` where the honest answer is "unknown", a restore that does not
invalidate a cache, a units mismatch between a field's doc comment and its writer,
an `Option` that silently becomes `None`, and a simulator that answers questions it
should refuse. A clean analyzer run is worth having and says nothing about any of
this.

## Harness notes worth keeping

* **GUI rigs under Xvfb need `LIBGL_ALWAYS_SOFTWARE=1 GDK_BACKEND=x11
  GALLIUM_DRIVER=llvmpipe`.** `main.dart:305-311` calls `windowManager.show()` only
  inside `addPostFrameCallback`, so when the first GL frame times out
  (`WARNING: Timed out waiting for OpenGL frame of size 1600x900`) **no window is
  ever mapped** while the process runs, connects devices and serves the API
  normally. On a customer machine with a broken GL stack this presents as "the app
  does not open, with no error", and there is no timeout fallback.
* **`--auth-token foo` (space form) is silently ignored** —
  `headless_auth_config.dart:115` matches only `--auth-token=`. The appliance then
  still prints *"Add --require-auth or --auth-token to expose authenticated LAN
  access"* and rejects every request with "Invalid authentication token".
* **The APK in the tree was five days stale.** It predated the 6.0.0 release commit
  and produced a catalog-download failure that does **not** reproduce on a build
  from current `main`. Always rebuild before testing mobile.
* A four-call sequencer recipe that avoids the rate limiter:
  `POST /api/sequencer/devices` → `/api/sequencer/save-path` (**mandatory**, see D2)
  → `/api/sequencer/load {"json":"<stringified Rust SequenceDefinition>"}` →
  `/api/sequencer/start`.
