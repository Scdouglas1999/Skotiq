# Skotiq 6.0.0 — no-hardware campaign, round 2, 2026-07-28

Second campaign of the day against shipping `main`, run after
`reports/simulator-campaign-2026-07-28.md`. ~13 agents plus the lead, driving the Linux
release bundle under Xvfb, a freshly built Android release APK on an emulator, a live
`skotiq_hub` server with two real accounts, and Rust-level harnesses with known ground
truth. No hardware at any point.

**The first finding was that round 1 fixed nothing.** It documented ~140 defects; every P0 was
still live in shipping code when this campaign started. So this campaign both closed that
backlog and went looking for what round 1 could not see.

Findings are CONFIRMED-LIVE unless labelled otherwise. Where I later found a claim of mine to
be wrong, the correction is left in place rather than edited out.

## The six that would cost a night's data or an operator's safety margin

1. **Pause is cosmetic — the camera keeps exposing while the UI says PAUSED.** People pause in
   order to walk in front of the telescope.
2. **The sequence builder nests each instruction as a child of the previous one** while drawing
   a flat list, so a run executes one step and reports `completed` with zero frames.
3. **The meridian gate holds every light exposure**, even ~2 h east of the meridian — no
   LIGHT-frame run could be completed at all.
4. **The planetarium's fallback star catalogue stores RA in degrees in a field documented as
   hours**, and those wrong positions are accepted by Slew, Framing and the Sequencer.
5. **FITS `DATE-OBS` is shifted by the machine's timezone offset**, applied backwards —
   invisible on a UTC host, which is why CI never saw it.
6. **Weather safety reads SAFE indefinitely while it has no data at all**, and ships disabled
   by default under a green "Safe" badge.

## The pattern

The characteristic defect of this codebase is **the app stating something untrue** — not
crashing. Across two long GUI sessions the logs contained **zero warnings or errors**, the
analyzer was clean, and 708 sequencer + 379 bridge + 885 desktop + 1231 provider tests passed.
None of that carries information about any defect above.

The tests cannot see this class by construction: the pre-fix DATE-OBS suite passes 100% under
`TZ=UTC`; a grading threshold the settings screen recommends is unreachable because the star
detector discards those stars first; a pier-side test passed *vacuously* on `DeviceNotFound`;
and `parallactic` has zero references repo-wide despite being surfaced as a feature.

---

# Lead findings — no-hardware campaign round 2, 2026-07-28

Live rig: Linux release bundle `apps/desktop/build/linux/x64/release/bundle/skotiq_desktop`
under Xvfb :77, `LIBGL_ALWAYS_SOFTWARE=1 GDK_BACKEND=x11 GALLIUM_DRIVER=llvmpipe`.
All simulators; no hardware.

## L1 — CONFIRMED-LIVE, P0 — the safety system reports SAFE indefinitely while it has NO data at all
Originally logged as a ~70 s startup window; the real behaviour is worse and unbounded.

Instance A (TZ=America/New_York): Dashboard SAFETY read green **"✓ Safe"** with
`Data: Unavailable` at 13:28:42, then correctly flipped to **"⚠ Unsafe"** at 13:29:55 once
the Weather API answered (100% cloud). Screenshots `shot01.png`, `shot03_safety.png`.

Instance B (TZ=Asia/Tokyo, same machine, same network, same profile): after
**16 min 27 s of uptime** (`ps -o etime`), the card still reads:
- badge **"✓ Safe"**
- `Data: Unavailable`, `As of 02:51:02`
- warning "No weather data sources available"
Screenshot `safety_now_crop.png`.

So when the weather source never answers, the verdict does not stay unknown and does not
fail closed — it sits on **SAFE**, forever, while the same card admits it has no data.
An unattended observatory whose weather sensor is dead is told it is safe to keep imaging.
This is the S1 fail-open shape confirmed live in its severe form, and the only variable
between the safe-forever instance and the correct instance was the timezone.

## L2 — CONFIRMED-LIVE — Safety card shows "No weather data sources available" while displaying live data from a weather source
In `shot03_safety.png` the card simultaneously shows:
- `Data: Weather API`, `As of 13:29:55`
- the amber warning **"No weather data sources available"**
- the reading "Heavy cloud cover overhead (100% density) - consider pausing"
The warning is emitted from `weather_safety_provider.dart:604` / `:718` and is not cleared
when a source is in fact supplying data. The card contradicts itself in three lines.

## L3 — CONFIRMED-LIVE — "Rig safed: secondary rig stopped" is reported when no secondary rig exists
Toast on the Weather screen: *"Safe the rig — CRITICAL: Heavy cloud cover overhead (100%
density) - consider pausing. Rig safed: secondary rig stopped, mount already safe."*
No secondary rig is configured or armed in this profile.
Source: `packages/skotiq_core/lib/src/services/safe_rig_service.dart:218-220` sets
`secondaryRigQuiesced: true` whenever `_stopSecondaryRig()` returns without throwing —
there is no check that a secondary rig was ever armed — and `:456` renders that flag as
the user-facing string `'secondary rig stopped'`.
Impact: the operator is told a safing step happened that did not. Same "app states
something untrue" class as `cry-wolf-defect-class-2026-07-25`.
Screenshot: `shot02.png`.

## L4 — CONFIRMED-LIVE (downgraded to P3, UX) — integration time rendered in whole minutes
"Continue Session" dialog, `shot01.png`: "8/8 frames captured, 0 minutes integration".
Not data loss — Analytics shows the same session arithmetic working (16 exposures /
32 s integration), so a sub-60 s session simply floors to "0 minutes". The dialog should
show seconds, or "<1 min", rather than telling the operator a session with 8 frames has
zero integration.
Separately in the same dialog: `Equipment Profile: Unknown Profile` while still offering
"Load Previous Setup" — unclear what that button would restore.

## L0 — CONFIRMED-LIVE, P0 — FITS DATE-OBS corrupted by the timezone offset (scope corrected)
**Proven by controlled experiment; only the TZ env var changed between runs.**

| TZ | true UTC at capture | DATE-OBS written | error |
|----|--------------------|------------------|-------|
| America/New_York (-4) | `2026-07-28T17:33:34` | `2026-07-28T21:33:34.000Z` | **+4 h** |
| Asia/Tokyo (+9)       | `2026-07-28T17:37:12` | `2026-07-28T08:37:14.000Z` | **-9 h** |

**CORRECTION TO MY OWN FINDING.** I originally wrote "every saved FITS". That was wrong and
I am recording it rather than quietly narrowing it. Actual scope, established by tracing
every capture path:
- **Manual / ad-hoc capture: CORRUPTED** by `-tz_offset` (what I measured).
- **Flat Wizard: CORRUPTED**, by a *separate mirror-image bug* —
  `flat_wizard_provider.dart:1135` put `DateTime.now().toIso8601String()` (local, no `Z`)
  straight into DATE-OBS, so every flat in the calibration library carried local time.
- **Sequencer: NOT corrupted.** Sequencer frames never round-trip through Dart; the header
  is built in Rust (`FitsWriteHeaderRich::from_frame_context`). Real imaging runs were fine.
- **Remote/companion capture: NOT corrupted — by accident.**
  `apps/desktop/lib/headless_api/display_buffer_jpeg.dart:35` already contained
  `capturedImageTimestampUtc`, i.e. exactly this fix, with a doc comment naming this bug
  class. It was applied to all four server egress paths and never to the local FFI ingress,
  so the desktop-local and remote-client paths disagreed about what the same frame's
  timestamp meant.

Root cause (confirmed, and broader than I first stated — **five** naive-format sites in the
bridge, not three; the two I had missed are the ones that actually cause it):
`unified_device_ops.rs:879` and `api/imaging.rs:1031` set `CapturedImageResult.timestamp`,
the field that `imaging_service.dart:325` parses with `DateTime.parse` — which reads a
designator-less UTC string as **local** — after which `persistence.dart:51` applies
`.toUtc()` a second time and stamps a `Z`, making the wrong value look authoritative.

Worst downstream consumer, and it confirms the scientific-submission concern:
`default_science_backend/helpers.dart:145-146` parsed two DATE-OBS values as local and then
called `.toUtc()`, applying a **second** shift. That value is the moving-object astrometric
epoch feeding `moving_object_candidates.timestamp` and then the **MPC 80-column date
field** — so submitted astrometry carried a wrong epoch, under a comment asserting the
epoch was trustworthy.

Why every gate missed it: under `TZ=UTC` the pre-fix test suite passes completely. The
existing fixture also defaulted the timestamp to `'2025-01-15T22:30:00Z'` — with a `Z` the
bridge never actually sends.

**Data migration deliberately NOT written, and that is the right call:** the corruption
factor is the capture *machine's* TZ at capture time, which is unrecoverable and varies per
frame across DST boundaries and across hosts sharing a library. Corrupt and correct
populations are indistinguishable on disk (all carry a `Z`), so a blanket migration would
corrupt the three currently-correct populations. Release-note it instead.

## L6 — CONFIRMED-LIVE — AIRMASS is byte-identical across frames (downstream of fake altitude)
Both captures, four minutes apart and with wildly different DATE-OBS, carry
`AIRMASS = 3.1734862391E1`. This is **not** a fabricated constant: `api/imaging.rs:3553`
computes it correctly — from `mountState.altitude`, which is the hardcoded `0.0°` the
simulator reports. Symptom of the mount-telemetry stub, listed here only so it is not
re-reported as its own bug.

## L5 — CONFIRMED-LIVE — No simulator exists for Switch or Cover Calibrator
App launch log: every device type reports "Discovery complete for X: 1 devices" except
`Switch: 0 devices` and `Cover Calibrator: 0 devices`. Those two device classes therefore
cannot be exercised at all without hardware — flat-panel/cover workflows included.

## Not a defect — checked and cleared
- Migration `onCreate` helper list vs upgrade chain: all 15 `_create*`/`_ensure*` helpers
  called in `onCreate` are also reachable from the `_upgradeSchemaV*` chain. No orphan.
- An empty database stamped with an old `user_version` crashes the upgrade chain
  ("no such table"), but that is not a real user shape (the chain is ALTER-based and real
  old databases have the tables). Not reported as a defect.

## L7 — CONFIRMED-LIVE, P3 UX — target card shows two different "peak altitude" numbers with no distinction
Plan Tonight → Recommendation, NGC0752 card (`nav_plantonight.png`): a chip reads
**"Peak 59.7°"** while the altitude panel on the same card reads **"Max Alt: 87.8°"**.
I verified the astronomy: for dec +37°50'0.2" at latitude 39.9846°N, transit altitude is
**87.85°**, so the chart is correct. 59.7° corresponds to an hour angle of ±2.61 h, i.e. it
is plausibly a *windowed* peak (highest altitude within the usable dark window) — but
nothing on the card says so, and the card simultaneously claims "2.8h visible" / "Rises
late at 21:40", which is not consistent with a window ending at the time 59.7° implies.
Not filed as a wrong number: filed as the user being shown two unlabelled, conflicting
answers to "how high does this get?".
(Airmass 4.08 vs Alt 13.9° checks out — 1/sin(13.9°) = 4.16.)

## L8 — CONFIRMED-LIVE, P3 UX — truncated labels and a cramped path field on the Imaging screen
`nav_imaging.png`: the right-hand tab strip ellipsizes "Annotatio…", the session button
ellipsizes "Clear Sess…", and the Save Path field wraps
`/home/scdouglas/skotiq-captures-test` across four lines inside a small box.

## L9 — CONFIRMED-LIVE, P1 — a user with no filter wheel cannot build a sequence from Plan Tonight at all
Clicking the primary CTA **"Review in Sequencer"** on Plan Tonight fails with the red
snackbar *"No filters configured on the equipment profile or connected filter wheel."*
Screenshots: `snap_2.png` / `full_2.png`.

Correction to my first read: the button is NOT a no-op — I initially sampled at 10 s and
missed the snackbar, which is transient. Verified the instrument by clicking the
neighbouring "Send to Framing" control, which navigated correctly.

Hard gate with no fallback:
- `packages/skotiq_app/lib/utils/plan_tonight_sequencer_helper.dart:85-91`
  `final filters = ref.read(effectiveFiltersProvider); if (filters.isEmpty) throw ...`
- same gate in `packages/skotiq_core/lib/src/services/smart_night_service.dart:669`,
  which also backs One-Tap Tonight / Autopilot.
- `effectiveFiltersProvider` (`filter_wheel_state_provider.dart:378`) returns the profile
  filter list when no wheel is connected — empty on a default profile.

The inconsistency that makes this a defect rather than a policy: **manual capture already
has the fallback.** `packages/skotiq_app/lib/widgets/capture_settings_panel.dart:318`
does `wheelConnected ? ref.watch(effectiveFiltersProvider) : _defaultFilters`. So the same
build lets you take frames without a wheel, but refuses to plan a sequence without one.
Manual capture even writes frames named `..._NoFilter_...` — I have those on disk.

Impact: an OSC / one-shot-colour imager with no filter wheel — the most common setup in
this product's target market — is locked out of the entire automated planning entry point.
The error is terse, offers no remedy or link to fix it, and the same screen displays an
"L" filter chip and "55s exp" on the target card, implying a plan that cannot be built.

## L10 — Observation: both app runs logged ZERO warnings or errors
`grep -iE "warn|error|panic|exception|failed"` over the full stdout of both the EDT and
the Tokyo run returns nothing. The app ran for tens of minutes, wrote timezone-corrupted
FITS timestamps, told the operator it had stopped a secondary rig that does not exist, and
reported "Safe" with no data — and logged none of it. Consistent with the campaign thesis:
the existing instrumentation (logs + static gates) cannot see this defect class, so "green"
carries no information about it.

## L11 — CONFIRMED-LIVE, P2 — Red night mode leaves the Guide Star panel BLUE
Settings → Appearance → Theme → **Red night** ("red night preserves dark adaptation at the
telescope"). On the **Guiding** screen the Guide Star panel renders blue-dominant while
every other surface is correctly red-tinted. Measured from `guiding.png`:

| panel | mean RGB | B/R |
|-------|----------|-----|
| **Guide Star**    | (11.68, 10.65, **18.50**) | **1.58 — blue-dominant** |
| Target Display    | (20.57, 2.25, 2.25) | 0.11 |
| Guide Graph       | (10.18, 0.10, 0.10) | 0.01 |
| Guiding Controls  | (28.86, 12.39, 12.39) | 0.43 |
| nav sidebar       | (31.26, 13.73, 13.73) | 0.44 |

This is content-independent and reproducible: the panel is showing the empty
"Waiting for image…" placeholder, so the blue is the panel's own background, not image
data. Blue is the worst part of the spectrum for scotopic dark adaptation, and this is the
guiding screen — the one an operator has open at the telescope, in the dark, which is
exactly the case red-night mode exists for.

Process note: I first wrote this finding up from the Dashboard image preview and had to
**withdraw** it — those measurements did not reproduce (one frame neutral, another
red-tinted, and my confirming toggle failed to actually switch themes, producing two
identical captures). The Guide Star panel is the clean instance. Also confirmed correct
and worth keeping: Red night no longer crashes (the previously reported broken/unreachable
red theme is genuinely fixed) and it correctly OVERRIDES a chosen accent colour — I picked
cyan while in Red night and the UI stayed red.
Screenshots: `guiding.png`, `theme_red.png`.

## L12 — CONFIRMED-LIVE, P3 UX — title-bar status icons have no tooltips
The crossed-out network glyph in the window title bar shows nothing on hover (waited 4 s).
Clicking it opens a dialog reading *"Connection Status — Not connected to a server"*.
The user must click an unlabelled icon to discover what it means. Same applies to the
neighbouring bell / account / gear glyphs and the crossed-eye glyph in the dashboard
header. Screenshots: `tooltip_crop.png`, `netclick.png`.

## L13 — CONFIRMED-LIVE, P3 — "Exposure progress 91% · 0s remaining"
Dashboard → Recent Events (`netclick.png`) shows an exposure progress entry reading
`91% · 0s remaining`. 91% complete cannot have zero seconds left; the remaining-time field
is floored/rounded independently of the percentage.

## L14 — CONFIRMED-LIVE, P2 — Guiding "Connect" and "Start" are silent no-ops with PHD2 absent
On the **Guiding** screen with the header reading "PHD2 Disconnected / Stopped":
- Clicking **Connect** produced no spinner, no toast, no error and no state change. Still
  "PHD2 Disconnected" **45 seconds later** (`phd_late_crop.png`).
- Clicking **Start** (Guiding Controls) likewise produced nothing — sampled once per second
  for 5 s to catch a transient snackbar, and the panel still read "Stopped" (`gstat_5.png`).

**Instrument verified.** I did not accept these negatives on their own: I clicked
"Brain Settings" on the same screen and it toggled correctly (the button changed to
"Hide Brai…" and the panel opened, `brain_crop.png`), proving clicks land at these
coordinates on this screen.

PHD2 is not installed on this machine, so failing to connect is correct — saying nothing at
all is not. The user gets no indication of what happened, what is wrong, or what to do.
Contrast the Equipment screen, which handles the analogous case well ("No plate solver is
configured. Install ASTAP…" with a "Set up plate solving" button).

## L15 — CONFIRMED-LIVE, P3 UX — more truncated button labels
"Hide Brai…" (Hide Brain Settings) and "Loop E…" (Loop Exposures) on the Guiding screen
once the Brain Settings panel is open (`brain_crop.png`). Same class as the Imaging screen's
"Clear Sess…" / "Annotatio…" (L8) — this is a recurring layout problem, not a one-off.

---

# FIXES LANDED (uncommitted, working tree)

## G1 — built-in guider dither, FIXED
Root cause deeper than the original report: `dither_offset` computed a Vogel-sunflower
*position* (angle n·137.5°, radius amount·adaptive·sqrt(n+1)) and `dither()` **added** it to
`desired_offset` as an increment, so both the standing offset and each commanded move grew
as sqrt(n+1) without bound; `dither_step` was reset by neither `start_guiding` nor
`stop_locked`. At the shipped 5 px / 1.5 adaptive the moves run 7.5, 10.6, … 21.2 px, and
the 8th exceeds `GUIDE_MAX_MATCH_DISTANCE_PX = 20`, so `measure_offset` returns None, the
loop errors, and the handler publishes `GuidingEvent::Disconnected` — the self-disconnect.
Fixed to a bounded 16-point Vogel disc with the offset ASSIGNED not accumulated, per-dither
move capped, and state reset on stop. An unmatched frame mid-dither now rolls back and
keeps guiding instead of failing the loop.
Evidence: before — unbounded, >20 px at dither 8. After — max move 9.32 px, max |offset|
5.00 px over 35 dithers at shipped defaults; new test drives 200 dithers × 6 configs.

## C2 — centering never corrects, FIXED
Confirmed both hardcoded `syncMount: false` literals, AND that the non-sync branch issued
`slewMountToCoordinates(targetRa, targetDec)` — the identical call as the sync branch — so
centering was a literal no-op. Unit path verified correct before changing (hours all the
way through; no unit change needed). Fixed with a real persisted `centering_sync_mount`
setting (default true) surfaced in Settings → Plate Solving, both GUI sites now awaiting
settings before building config (they previously read cold, which also silently emptied the
solver path on a fast start), and the no-sync branch made genuinely corrective.

## L16 — CONFIRMED AT SOURCE, P1 — weather safety ships DISABLED by default, under a green "Safe" badge
`packages/skotiq_core/lib/src/models/weather/weather_settings.dart:48`
`@Default(false) bool weatherSafetyEnabled` — verified unmodified by any agent (`git diff`
on that file is empty). So out of the box the rig does no weather safety evaluation, and
the Dashboard SAFETY card still presents a reassuring green **"✓ Safe"** badge. An operator
reading that badge has no way to tell "evaluated, and conditions are fine" from
"not evaluating anything".

Adjudication note: the fix agent attributed my Tokyo instance's permanent "Safe" solely to
this default. I am **not** propagating that as settled — both my instances shared one
settings database, yet instance A *did* flip to "⚠ Unsafe" when the Weather API returned
100% cloud. So the default cannot be the whole explanation, and the never-answered
fail-open (L1) stands on its own evidence. Both are real; the interaction between them
should be confirmed against the new tests rather than assumed.

## S1/Q1/Q2 — FIXED (see fixes section)

## Verified correct — do not re-investigate
- **Headless API auth is uniformly enforced.** The desktop app serves the headless API on
  `0.0.0.0:8080`. I probed 14 endpoints unauthenticated — `/api/status`, `/api/system/info`,
  `/api/health`, `/healthz`, `/api/version`, `/api/devices`, `/api/pairing/info`,
  `/api/discovery`, `/api/safety/status`, `/api/catalog/status`, `/api/settings`,
  `/api/collaboration/state`, `/api/logs` — and **every one returned 401**. Only
  `/dashboard` serves unauthenticated (the HTML shell, which ships a CSP restricting
  `connect-src`). No auth bypass found. Note the bind is all-interfaces rather than
  loopback, which is a deliberate design choice for the appliance use case and is defensible
  given auth holds.
- **Optical Train Diagnostics empty state is honest and well-built** — "Select an imaging
  session to analyze / Optical diagnostics require plate-solved frames with PSF and residual
  data", with a real explanation of what the screen is for. No defect (`diag.png`).
- **Equipment screen "Ready to image" checklist is good UX** — three actionable cards
  (plate solver / dark library / focus) each with a working button, and honest copy
  ("No plate solver is configured. Install ASTAP…"). This is the pattern the Guiding screen
  should follow for its silent-failure case (L14). (`equip.png`)
- **Rust workspace compiles clean** after all concurrent agent edits
  (`cargo check --workspace --all-targets`), and **708 sequencer tests pass, 0 failures**.
- **Weather-safety regression suite verified by me, not taken on trust**: 8/8 pass in
  `weather_source_unreachable_test.dart`, including "a configured source that has never
  answered is UNSAFE (fail-closed)" — the exact live condition I reproduced.

## L0 DATE-OBS — FIXED
Both ends of the boundary made explicit: all five Rust sites now emit
`to_rfc3339_opts(SecondsFormat::Millis, true)` (trailing `Z`), and a new shared
`packages/skotiq_core/lib/src/utils/utc_timestamp.dart`
(`parseUtcTimestamp`/`tryParseUtcTimestamp`/`normalizeUtcTimestamp`) is used at the Dart
ingress. `display_buffer_jpeg.dart` now delegates to that one helper instead of carrying a
second private copy. Also fixed: the Flat Wizard local-time DATE-OBS, the MPC-epoch double
shift in `default_science_backend/helpers.dart`, and naive local `expiresAt` strings in the
co-imaging and mosaic lease API payloads.

Test evidence — **the key property is that the test fails on a UTC host too**, which the old
suite could not do (Dart `DateTime` equality compares `isUtc`, so a local-flagged parse
fails even at zero offset). Pre-fix under `TZ=UTC`: 3 failures. Pre-fix end-to-end under
`TZ=Asia/Tokyo`: `Expected '2026-07-28T17:33:34.000Z' / Actual '2026-07-28T08:33:34.000Z'`
— my live -9 h result reproduced exactly in a test. Pre-fix under `TZ=UTC` the same
end-to-end test **passed**, which is exactly why CI never caught it.
**I verified this myself**, not on trust: `utc_timestamp_test.dart` is 12/12 green under
`TZ=UTC`, `TZ=Asia/Tokyo` and `TZ=America/New_York`.

Known remaining naive-timestamp sites, deliberately not fixed (each needs a compatibility
decision, not a drive-by): `wire_history_models.dart` (:273, :380, :427-428, :488, :538 —
host serialises Drift-local DateTimes with a bare `toIso8601String()`, correct only when
client and host share a timezone), `db_read_handlers.dart:181`, `analytics_handlers.dart:63`,
`json_validation.dart:102`, `noaa_radar_provider.dart`, and
`flat_wizard_provider.dart:1485` (`_fmtStamp` still builds flat *filenames* from local time
while DATE-OBS is now UTC — changing it would rename files in existing calibration
libraries).

## SIMULATOR HONESTY — FIXED (the highest-leverage change of the campaign)
This is what unblocks the 17 previously-unverifiable categories.

- **30 HTTP-API `sim_` short-circuits deleted** (28 in `api/devices/simulation.rs`, 2 in
  `api/imaging.rs`). They returned synthetic state with no connected-gate, while
  `device_manager/ops/sim_gate.rs` — written specifically to stop this, per its own header —
  was wired only to the DeviceManager arm. Verified by me: `grep -c 'starts_with("sim_")'`
  now returns **0**. A disconnected simulated mount now refuses slew/park/unpark/tracking
  and its refused slew leaves RA/Dec at 0 and `parked` true; previously it accepted the slew
  and reported itself tracking *and* parked simultaneously.
  Two pre-existing tests had asserted the OLD bypass — one was passing vacuously on
  `DeviceNotFound` rather than on the direction rejection it claimed to test.
- **Mount telemetry derived, not stored.** `read_mount_status()` cloned a singleton, so
  alt/az/LST were whatever was last written (0.0 after an equatorial slew) while
  `availability` claimed `Available` — this is the source of my L6 constant-AIRMASS. Now
  derived from RA/Dec + site + `Utc::now()` via new `calculate_alt_az`/`alt_az_to_ra_dec` in
  `meridian.rs` (verified present). With no site configured it reports `Unsupported`/`None`
  instead of a fabricated default.
- **The two camera simulators are now one.** The 4144x2822 randomised generator became
  unreachable and was removed; `sim_frame.rs` is the single generator and the *declared*
  sensor now is the *generated* sensor (also fixes a camera that delivered 4144 px while
  advertising `maxWidth: 4096`).
- **Fabricated measurements gone.** `hfr: Some(2.5 + rand()*0.5)` is deleted — that is
  exactly the 2.51 average I saw live in Analytics. Also found and fixed: frame type was
  never plumbed to the download op, so a **DARK was generated as a star field** and
  announced itself as a light (45 peaks up to 33,780 ADU); calibration frames now contain
  no stars.
- **Physically plausible frames.** The old background was a diagonal sawtooth
  `200 + ((x+y)%400)` — 442 of 65,536 ADU, coupled to nothing. Now built in electrons with
  bias/dark/sky accumulating with time, shot and read noise, binning summing charge, and a
  hard clip at the advertised ceiling. Row lag-1 autocorrelation dropped from 0.9835 to
  <0.2; a 600 s frame now saturates to exactly 65535 and trips the validator while a 1 s
  frame does not.

**Now testable: 11 of 17** — horizon limits and altitude safety-park, post-flip pier side,
measurements from a manual frame, saturation/clipping, calibration-frame quality, defect
maps, disconnect-mid-operation over HTTP, binning/subframe/pixel-scale geometry, airmass and
parallactic angle, grading, motion-in-progress.

**Still blind: 6** — dome slaving and shutter transitions; weather-triggered abort/pause/park;
safety-monitor unsafe response (weather and safety monitor still have NO writer and are
hardcoded safe); autofocus temperature compensation (focuser temp hardcoded 20.0); cooler
saturation and delta-T; rotator sky-vs-mechanical transform and reverse (all four arms write
both angles to the same value); plate solving/framing/mosaic differentiation.

**Honest caveat from the implementer, worth keeping:** the new frame model is calibrated to
be *physically shaped*, not to match any specific sensor's measured performance. On-sky
comparison against real hardware is still owed.

## Incident — `git stash` + `git reset --hard` wiped the working tree mid-campaign
One agent ran stash+reset, which wiped every agent's in-flight edits, and the stash was then
dropped. Another agent recovered the whole tree from the dangling commit and preserved it at
`refs/recovered/wip-simulator-2026-07-28`. **I verified the ref exists (`fff2490b`)** and
spot-checked that each agent's distinctive work is present. Nothing was lost. Lesson for
future campaigns: never `git stash` in a repo with concurrent agents.

## Diff hygiene (checked across all 86 changed files)
- **Zero** debug leftovers introduced: no `println!`/`print(`/`debugPrint`/`dbg!`, and no new
  `TODO`/`FIXME`/`XXX`/`HACK` markers anywhere in the diff.
- **17 test files** touched, **+961 lines of new test code** — every fix landed with a
  regression test, and each agent was required to demonstrate the test failing against the
  unfixed code first.
- **ACTION BEFORE ANY COMMIT:** `docs/design/goldens/surface-run-session-progress.png` has
  been regenerated on Linux. Per the project rule (goldens are Windows-captured and fail on
  Linux) this must be reverted with `git checkout -- docs/design/goldens/` before committing.
  One agent already caught and reverted a different golden
  (`mosaic-project-complete.png`) for the same reason.

## L0 DATE-OBS — FIX VERIFIED BY ME, ACROSS TIMEZONES
I rebuilt the release bundle and intended to re-run the live TZ experiment, but another
agent had its own app instance running on the same Xvfb display and was actively capturing
(`SPINE1_*.fits`), so my GUI clicks were landing in ITS window. Rather than report a result
from a contended instrument, I verified the same code path directly.

`test/services/imaging_service_test.dart` drives `captureImage` end-to-end and asserts the
`FitsWriteHeader` handed to the FITS writer. Its expected value is
`'2026-07-28T17:33:34.000Z'` — **the exact true-UTC instant from my live experiment**, the
one the shipped build wrote as `08:33:34.000Z` under Tokyo (-9 h) and `21:33:34.000Z` under
New York (+4 h).

Result, run by me:

| TZ | result |
|----|--------|
| `Asia/Tokyo` | 68/68 pass |
| `America/New_York` | 68/68 pass |
| `UTC` | 68/68 pass |

Plus `utc_timestamp_test.dart` 12/12 under all three. The fix holds in both directions and
on a UTC host, and — critically — the new tests FAIL on a UTC host against the unfixed code,
which the old suite could not do. That is what closes the CI blind spot that let this ship.

## Independent cross-check of the DATE-OBS scope correction (on a real artifact)
A concurrently-running agent's sequencer frame, `SPINE1_nofilter_0003.fits`, written at
13:54:14 EDT = **true UTC 17:54:14**, carries:
`DATE-OBS= '2026-07-28T17:54:14'` — the correct true-UTC instant, with no `Z` (old binary).
So the sequencer path genuinely was NOT corrupted, confirming the scope correction to my L0
on real data rather than on the agent's word.
The same header shows `NAXIS1=1920 NAXIS2=1080`, while my manual capture was 4144x2822 —
first-hand confirmation of the two-different-camera-simulators-in-one-process defect that
has now been unified.

---

# PLANETARIUM (v5 "Living Sky") — 4 CONFIRMED-LIVE DEFECTS

I noticed bright stars rendered far outside the stated 60° field and could not settle whether
the stars or the readout was wrong. Adjudicated by pixel-measurement against the app's own
projection. **Verdict: the star placement is wrong; the readout is correct.** My own
competing hypothesis — that this was really a wide horizon panorama and the FOV readout was
lying — was DISPROVED, and I am recording that I was wrong about the mechanism while right
that something was broken.

## P1 — the fallback bright-star catalogue stores RA in DEGREES in a field that means HOURS
`packages/skotiq_planetarium/lib/src/catalogs/star_catalog.dart:553` — all **79** entries.
`Arcturus … CelestialCoordinate(ra: 213.918, …)` while `CelestialCoordinate.ra` is hours
(`coordinate_system.dart:5-6`, `:14 raDegrees => ra * 15`). The projection computes
`213.918 * 15 = 3208.8° = 328.8° = 21.918h` instead of 14.261h. **Declinations are correct**,
which is why the sky looks almost plausible rather than obviously broken.
Proof: 7 of 7 star glyphs matched the buggy prediction to a fraction of a degree
(Arcturus 0.11°, Aldebaran 0.13°, Alphard 0.30°, Alhena 0.15°, plus three unlabelled ones
identified as Eta Piscium 0.03°, Rasalhague 0.02°, Menkar 0.07°), and a second independent
pose reproduced it (Polaris 1.5 px from the buggy prediction vs 18 px from the true one).
Corroboration from the same image: the Great Square of Pegasus is drawn in exactly the right
place **with no star at any of its four corners**, because constellation figures store correct
hours (`figures_01.dart:283`) while the star list does not. Saturn and Neptune are also
correct against an independent Keplerian ephemeris — so the frame is right, only the stars
are displaced. **No test touches `_fallbackBrightStars`.**

## P1 — the v42→v44 catalogue rename silently drops upgraded users onto the broken fallback
The loader falls back when the catalogue file is absent (`star_catalog.dart:60-61`). The
expected name is now `hyg_v44.csv` (`source_models.dart:174`); this machine has
`hyg_v42.csv` (33 MB, downloaded in June). The legacy name is honoured **only in the delete
path** (`legacy_catalog_io.dart:476-477`), never in load or status. So a normal upgrade
orphans the catalogue and silently yields a 79-star sky with **no banner** — every star that
should be in frame (Fomalhaut, Hamal, Diphda, Scheat, Markab, Mira…) simply vanishes.

## P0 (safety-adjacent) — a wrong star position reaches the mount, and it is not fail-safe
Clicking the glyph labelled "Capella" opens a popup reading `RA 7h 10m 53.6s` (real Capella
is 5h 16m) with `Alt 2.9°` where the true altitude is ≈ +14.7°. The popup carries the **tap**
coordinate, not the catalogue one (`planetarium_shell.dart:256-257`,
`interactive_sky_view.dart:936-1058`), so it is an in-range coordinate that passes
`_equatorialCoordinateError` (`mount_command_service.dart:95-103`) — **Slew, Framing,
Sequencer and Add to List all accept it** and point ~20° off target.

## P1 — ground plane, horizon glow and light-pollution dome use AZIMUTH as if it were ALTITUDE
`equatorialToHorizontal` returns `(alt, az)`; four sites destructure it as
`final (_, centerAlt) = …`, binding the **azimuth** into a variable named `centerAlt` —
`horizon_layers.dart:90`, `:234`, `:360`, `:431`. With centre alt −37.49° / az 310.04°,
`horizonY` computes to 4103 ≥ canvas height → early return → **a view entirely below the
horizon was rendered as pristine night sky.** Since `az ∈ [0,360)`, ground can only ever
appear when the centre is within `fov/2` of due north, and the `if (centerAlt < 0)`
"looking below the horizon" branch at `:234` is **unreachable**. Proved by controlled A/B:
altitude held constant, azimuth varied, ground behaviour flipped.

## P3 — `FOV: 60.0°` is the short-axis field
`scale = min(w,h)/2/(fov/2)` (`paint_lifecycle.dart:10-11`): on a 1379x724 canvas that is 60°
vertically but ~106° horizontally. Ambiguous label, not a wrong number.

## Planetarium — checked and clean
LST (9h30m, matches an independent GMST computation; the Tokyo-local clock correctly
converted to UTC) · planet positions (Saturn, Neptune verified against an independent
ephemeris) · moon RA/Dec and 99.3% illumination (dashboard read 99%) · constellation figure
geometry · fallback magnitudes and spectral types · the dark daytime sky is deliberate
(documented at `background_layers.dart:104-112`) · the `/api/planetarium/fov-config`
precedent is unrelated — this FOV number is the honest one.

## L9 no-filter-wheel planning blocker — FIXED
Confirmed both gates, and found a **third undocumented one**:
`session_optimizer_provider.dart:380` (`if (filters.isEmpty) return null`), so a no-wheel user
also silently lost the integration-estimate chip. Also explained the phantom "L" chip I saw
on the target card: with no filters, `selectFilterForTarget` returns
`FilterExposureSpec.luminance()` whose `.name` is `'L'`.
**This was never policy** — `resolveSmartNightFilterSet` already had a wheel-less fallback
(`return ['OSC']`) and `smart_night_dialog.dart:626` carried the comment "OSC works without a
wheel". The fallback was simply unreachable behind the gate.
Design chosen after tracing the Rust runtime: emit a plain `ExposureNode` with `filter: null`,
NOT a `SmartExposureNode` with an empty filter — the latter would still fire
`run_filter_change` → "No filter wheel connected" and fail the whole run, trip
`EquipmentConnectionRule`, and raise two validation errors. The chosen shape needs zero Rust
changes and reuses the existing `nofilter` label convention (`resolver.rs:22`).
Evidence: 3/3 new app tests fail against `HEAD` with the exact live snackbar text and pass
after; 5 of 6 new core tests fail before (the 6th is the control, proving genuine
misconfiguration still errors). `skotiq_core` full suite 5024 pass / 0 fail.
Owed: an actual sim-camera run of a no-wheel Plan Tonight sequence — the proof stops at the
Dart build boundary.

## Mobile checkpoint-dir + catalog-scope — FIXED
Checkpoint: the brief was incomplete — `app_shell.dart:342` gates on
`Platform.isWindows/isMacOS/isLinux` only, so a **desktop GUI driving a remote host pushed its
own directory at the rig too**. Same bug, second caller, now fixed. Host refuses any
client-supplied path with `403 checkpoint_dir_host_owned` + a warn log, validates its own
(absolute/creatable/writable), and clients no longer push a local path to a `NetworkBackend`.
**I verified this myself**: the desktop suite now includes "refuses client-supplied path
/data/user/0/com.skotiq.mobile/app_flutter" — the exact string from the live host log —
and 885 headless tests pass. Before: all 3 cases returned 200.
Catalog: made the primary screen remote-aware rather than merging the two screens (the
device's own catalogs are genuinely used by the on-device planetarium/atlas). Cards now carry
`On this device` and `On the rig` / `Not on the rig` separately, with a warning that plate
solving runs on the rig and a deep link to manage rig catalogs. Admin scope deliberately NOT
widened; the refusal now explains re-pairing with admin. Before: 2 of 3 tests failed, with
the control passing.

### Lead's independent confirmation of the RA-units defect
I checked this at source myself rather than accepting the agent's word:
- `coordinate_system.dart`: `/// Right Ascension in hours (0-24)` on `final double ra;`,
  with `double get raDegrees => ra * 15;`
- `star_catalog.dart:582`: `coordinates: CelestialCoordinate(ra: 213.918, dec: 19.1825)`
213.918 cannot be hours in a field documented as 0-24, and it is exactly Arcturus's RA in
**degrees** (14.261 h x 15 = 213.9°). Confirmed beyond doubt.

---

# SEQUENCER END-TO-END — real runs driven through the GUI

Eight real runs (66-73) driven to completion or failure. **A second run CAN now start in the
same app launch — the old regression is fixed** (four runs per launch, twice, including
start-after-failure, start-after-stop and start-after-completion).

## THE WORST DEFECT OF THE CAMPAIGN — P0, SAFETY — Pause is cosmetic; the camera keeps exposing
`native/skotiq_native/sequencer/src/instructions.rs:1934` — the capture loop has **no
pause check**. `wait_while_paused()` is called in exactly ONE instruction in that entire
file: `execute_delay` at `:6043`.
Live: Take Exposures 3x8s, Start, Pause during frame 2. UI showed a PAUSED badge, a Resume
button and "Paused 33%". Log: `18:30:13.611 Pausing sequence execution` →
`18:30:18.377 Capturing frame 3/3 (8.0s)`. Run recorded `status=completed, framesCaptured=3`
with Resume never pressed.
**This is a safety defect, not a UI bug.** An operator pauses precisely in order to walk in
front of the telescope, uncap it, or put a hand in the light path. The shutter is still
opening.

## P0, DATA LOSS — a sequence reports "completed" after silently skipping most of its instructions
The builder nests each newly added instruction as a **child of the previous one** while
rendering them as a flat list. Run 70's stored tree: `Target → Unpark → SlewToTarget →
TakeExposure`, each nested in the last. `Unpark` is a leaf, so the executor runs it, returns
Success and never descends. Log: `Executing child 1/1: 'Unpark Mount'` …
`execute_children_sequential completed with result: Success`. Session Report:
**"New Sequence - completed"**, green badge, 0 frames, `errorMessages: []`, header chip still
reading "3 frames". Leave that overnight and you wake to "Completed" and an empty disk.

## P1 — the meridian gate blocks EVERY light exposure, which is why no LIGHT run could complete
`instructions.rs:1542-1607`. Target RA 23.4 h at LST 21:27 → HA ≈ **−1.95 h** (east of the
meridian), threshold raised to 120 min past meridian, and the log still says
`Holding next 2s exposure: meridian flip fires in ~0s and would interrupt it`. A run sat at
0/3 frames for 3+ minutes with no UI explanation. `MERIDIAN_GATE_MAX_WAIT` is 30 min **per
exposure**, so a normal sub sequence stalls for hours. Every run that completed in testing was
a DARK. **A release blocker for the product's primary use case.**

## P1 — a failed run's real reason is discarded
`executor/mod.rs:6967-6968` — `SequenceFailed { error: "Sequence failed".into() }`, hardcoded.
A run killed by the daylight gate logged `Sun altitude 66.9° is above the maximum -12.0°`,
but the toast, the Session Report and persisted `stats_json.errorMessages` all contained only
`["Sequence failed"]`. Not universal — a FITS-write failure DID propagate its message.

## Other confirmed sequencer defects
- Pre-flight reports "Ready with Warnings" for a daytime LIGHT run guaranteed to capture zero
  frames (it died in 0.5 s on the daylight gate) — yet pre-flight *does* have a hard-block
  path, correctly refusing an unwritable output directory.
- A failed meridian flip turned a fully successful 3/3 run into `status=failed` and stretched
  a 7-second run to 5 minutes (`waiting up to 900s` for trigger recovery). The flip's plate
  solve fails because no solver is configured, but the UI only ever says "Plate solve failed",
  never "no plate solver installed". Also `Retry 1/4 scheduled` when `max_retries: 3`.
- Three progress readouts disagreeing in one frame: header "3/3 100%", sequence bar "0%",
  target card "0/3 done", status pill "Running 100%", `Mount: Idle` while actively slewing.
- Raw Rust `Debug` struct dumped into the operator status line:
  `MeridianFlip(MeridianFlipConfig { trigger_method: MinutesPastMeridian, … ` truncated.
- A user-initiated Stop raises three toasts including "Critical" and "Sequence Error".
- Pre-flight rise-time warning compares time-of-day without a date: "scheduled at 14:02
  before target rises at 06:52" for a target at 67.5° altitude.
- Altitude Limit trigger evaluates MOUNT position, not target, firing NextTarget on a target
  at 69° with a 30° minimum.
- Dark frames carry sky pointing (`IMAGETYP='Dark'` with `OBJECT='SPINE1'`, RA/DEC set); the
  header is thin (no FILTER/TELESCOP/SET-TEMP/ALT/AZ/AIRMASS/PIERSIDE/EQUINOX) and `RA` is in
  hours with no unit comment.
- **RA sexagesimal renders "60s"** — 9.2 h shows `09h 11m 60s`, 23.4 h shows `23h 23m 60s`.
  Systemic across target card, properties and slew node.
- Settings silently discard or clamp input: typing a path into Image output reverts with no
  message and no DB write; typing 600 into "Minutes past meridian" silently becomes 120.
- False "Cooler Out of Setpoint Band" on a rig with cooling at 0% and no setpoint; disk
  estimate ~7x high; duplicate pause toasts 0.2 ms apart; header pill "Sequence Running" while
  state is PAUSED; `targetBreakdown` stores the SEQUENCE name as the target name.

## Sequencer — verified correct
**Files vs DB agreed perfectly across all 8 runs** — filenames, counts, frame_type, exposure,
`producing_run_id`/`producing_node_id`, including a partial run (1 file, 1 row). A mid-run
write failure is handled honestly (aborts, full reason in UI and DB). Pre-flight hard-blocks
an unwritable output dir. Stop is fast and DB-accurate. The flip-abort message ("The mount was
NOT flipped") is truthful. Second-run-per-launch works.

## Could not be tested, and why
A **LIGHT-frame run to completion** — blocked by the meridian gate above. So all light-only
accounting (Session Report integration, frames-accepted, HFR/FWHM/star-count, guiding stats,
`is_accepted` grading) remains **unverified**. Also untested: Resume (the run finished while
"paused"), plate solving/centering (no solver installed), filter-wheel paths.

---

# THE 11 NEWLY-TESTABLE CATEGORIES — results

Two of these are **regressions introduced by the simulator-honesty change commissioned in
this campaign**, and are recorded as such rather than as pre-existing defects:

- **REGRESSION — the simulated camera never leaves `CameraState::Idle`.** The deleted `sim_`
  short-circuit was the ONLY writer of `Exposing`/`Reading`; the device-layer arm
  (`ops/camera.rs:500`) sets gain/offset but not `state`. Live: 4 s exposure, at t=0.3 s
  `api_get_camera_status` returns `state=Idle` while `is_exposure_complete=false` — two
  statuses contradicting each other on the exact API the UI polls.
- **REGRESSION — post-flip pier-side confirmation now ALWAYS fails.** `sim_gate.rs:196`
  derives `side_of_pier` from `expected_pier_side(hour_angle(ra, lst))`, a pure function of RA
  and the clock, so a flip cannot change it; `meridian_flip_executor.rs:866` errors when
  pre == post. Previously the sim returned `Unknown` and verification fell back to coordinate
  convergence and passed — so this converted a **vacuous pass into a hard failure of every
  simulated meridian flip**. (Related: `meridian.rs:144-152` `expected_pier_side` uses the
  OPPOSITE convention from ASCOM, with a self-contradictory comment. Simulator-only.)

Pre-existing defects the honest simulators finally exposed:
- **The star detector discards every star with eccentricity > 0.70** (`imaging/src/stats.rs:190`
  `max_eccentricity: 0.7`), so the grading eccentricity rule **cannot fire on a trailed
  frame** — and the settings UI recommends an unreachable 0.8
  (`image_grading_settings.dart:190`: "0.8 catches catastrophic tracking failure"). Measured:
  ecc 0.700 → 48 stars; 0.724 → **0 stars, frame_ecc None**; `grade_frame` then passes on
  `None`. A wind-trailed night is silently ACCEPTED. Measurable band is only 0.6-0.7.
- **`camera_download_image` returns a complete frame mid-exposure and after an abort**,
  stamped with the full requested EXPTIME (`ops/camera.rs:1077-1150`, no completion/abort
  gate).
- **Saturation is only reported above 90% clipped, and never at all on a sensor whose ADU
  ceiling is below 65024** (`imaging/src/fits.rs:1482` hardcoded `saturation_threshold: 65024`).
  `CameraStatus.max_adu` exists and is never used. On a 12-bit sensor, 50% clipped is
  completely silent and 100% clipped is misdiagnosed as "possible sensor failure".
- **A subframe requested at bin > 1 comes back a quarter the requested size** while the
  metadata claims the requested size — ROI (100,200,640,480) at bin1 → 640x480, at bin2 →
  320x240 with `metadata.subframe = {640,480}`. The Alpaca/ASCOM contract ("NumX/NumY in
  binned pixels") is stated in the same file.
- **Sequencer-written FITS never carries ALTITUDE or AIRMASS** — `api/imaging.rs:3175`
  `altitude: None`, while `frame_context.rs:225` explicitly says "AIRMASS is intentionally NOT
  added here — the bridge writer already computes it from the altitude when present." It never
  does. (This also explains my L6.)
- **Two airmass implementations disagree**: `imaging/src/fits.rs:1273` (Pickering/Young) vs
  `sequencer/src/scheduling/astronomy.rs:98` (Pickering everywhere). At alt 0°: 31.73 vs ∞.
- **Binning multiplies the simulated bias pedestal by the bin factor** (bias mean 499.5 at
  bin1, 1999.5 at bin2) — real on-chip binning sums charge and reads once. The in-tree test
  sets `offset: 0` to sidestep exactly this.
- **Simulated lights have no vignetting but simulated flats do**, so flat-fielding a simulated
  light injects **+36% corner brightening** — calibration "succeeds" while degrading the frame,
  leaving flat correctness unverifiable.
- A parked sim mount reports the previous target's alt/az and that altitude keeps moving with
  the sky. The sim mount is never `slewing`. It advertises `can_set_tracking_rate: true` then
  refuses.
- Runtime horizon protection is a single global minimum altitude; the azimuth-dependent
  horizon profile exists only in scheduler scoring, so a configured tree-line mask does not
  protect a running sequence.

## Verified genuinely correct (with ground truth, not "couldn't break it")
- **LST and alt/az derivation are exact** — independently reimplemented IAU-1982 GMST + Meeus
  horizontal transform; matched `local_sidereal_time` to <0.0001 s at four epochs and
  `mount_get_status` alt/az to <1e-4° after a live slew. (The verifier's own first run showed a
  32 s disagreement and they correctly traced it to their OWN bug, not the app's.)
- **The altitude-limit trigger fires exactly at the crossing** — walked a full day in 1-minute
  steps, found both 30° crossings independently, trigger fired iff altitude < limit.
- **Disconnect gating is real** — 13/13 mount ops and 3/3 camera ops refuse with a descriptive
  error, and a refused slew leaves RA/Dec/parked untouched.
- Defect map: 67 false positives in 2,073,600 px (0.0032%); positive control found 20/20
  injected hot pixels. HFR/FWHM are real (1.89 px in focus → 6.23 px at +600 steps; dark
  60s/120s ratio exactly 2.000). Eccentricity zero point unbiased.

**Category verdicts: PASSED 3 (defect map, horizon-limit trigger, disconnect gating at the
Rust layer) · DEFECT 7 · STILL-BLIND 3** (parallactic angle — `rg -i parallactic` returns
**zero hits repo-wide**, i.e. not implemented at all; pixel-scale-under-binning; motion-in-
progress, since the sim mount is never `slewing`).

### Lead's independent confirmation of the three most severe claims
Checked at source myself rather than accepting the agents' reports:
1. `grep -n "wait_while_paused" instructions.rs` → **exactly one hit, line 6043**. The capture
   loop genuinely has no pause check. The Pause-is-cosmetic defect is real.
2. `grep -rin "parallactic"` across `native/`, `packages/`, `apps/` → **0 hits**. Parallactic
   angle is not implemented anywhere in the product.
3. `stats.rs:190 max_eccentricity: 0.7` with the discard at `:309`
   (`if star.eccentricity > config.max_eccentricity`), and
   `image_grading_settings.dart:190` reads verbatim: *"0.6 catches trailed frames; 0.8 catches
   catastrophic tracking failure."* The app recommends a threshold that can never be reached,
   because stars above 0.70 are discarded before grading sees them.

### Test-suite note
`skotiq_app` full run showed 1 failure (`analytics_remote_image_poll_test.dart`). It
**passes in isolation** — a parallel-execution flake, not a regression. The `captures/*.png`
golden failures are pre-existing (Windows-captured goldens on Linux) and were independently
confirmed pre-existing by an agent stashing all work and reproducing byte-identical diffs.

### RETRACTED — "the planetarium golden baseline encoded the bug"
I claimed `test/benchmark/golden_compare_test.dart` was failing because its baselines were
captured with the RA defect live, and called it the sharpest example of this campaign's theme.
**That was wrong, and the implementer disproved it properly rather than accepting my framing.**

A controlled A/B (revert the three rendering-relevant files to HEAD, re-run, restore) shows the
benchmark fails **identically without the fix**: 00-wide-start 0.3410% both ways, 02-deep-zoom
0.0983% both ways, 04-wide-return 0.3488% → 0.3492%. And I verified the mechanism myself:
`golden_compare_test.dart:44` calls `StressFixture.load()` — a **synthetic fixture**
(`benchmark/src/stress_fixture.dart:30`), not the HYG or fallback star catalogue — so the RA
fix cannot move those pixels at all.

It is a pre-existing host-specific baseline mismatch, tagged `@Tags(['golden'])` and excluded
from `melos run test` by design. **No Windows re-capture is required by this work**, and I have
removed that from the owed-actions list. My reasoning was plausible and unverified; the lesson
is the campaign's own: a controlled A/B beats a good story.

### The planetarium golden baseline encoded the bug
`packages/skotiq_planetarium/test/benchmark/golden_compare_test.dart` perceptually diffs
rendered sky frames against **committed baselines**. Those baselines were captured while the
RA-in-degrees defect was live, so they encode a sky with every bright star in the wrong place.
Consequence: the golden test could never have caught this defect — it would only ever fail on
the **fix**. It duly failed the moment the star positions were corrected.
This is the sharpest single example of the campaign's theme: the test suite was pinning the
wrong behaviour in place and reporting green. The baseline must be deliberately re-captured
(and per the project rule, goldens are Windows-captured, so a Linux regen must not be left in
the tree).

## MOBILE UI — FIXED, and a latent crash class found beyond the brief
- **Guiding screen blanking to grey** reproduced in a widget test with the exact logcat
  signature (`Invalid argument(s): 200.0` → `double.clamp` → `RenderFlex._computeSizes`), then
  fixed total-order-safely (`min(max(h*0.42, 200), h*0.6)` — the 200 dp floor is now a
  preference capped by the ceiling, so the bounds cannot invert). Made genuinely usable rather
  than merely non-crashing: plot area at 300 dp went **78.8 → 114.8 dp (+46%)** and the
  overflow floor dropped from ~270 dp to ~215 dp. 4 cases fail before, pass after.
- **Onboarding back-gesture exit** fixed with `PopScope(canPop: false)` routing to the wizard's
  own back action, and a "Leave setup?" confirm on the first/last step instead of dumping the
  user at the launcher. Test drives `binding.handlePopRoute()` and traps `SystemNavigator.pop`:
  **before, `exit.exited == true`** — the app really does leave.
- **Guide-graph Y-axis smear** root cause was NOT text scaling (`TextPainter` defaults to
  `TextScaler.noScaling`, which is why it looked identical at 1.0x and 1.3x) but panel chrome
  squeezing `graphRect` to ~19 dp, so 5 labels at ~4.75 dp pitch stacked. Fixed by measuring
  and thinning the tick set.

### The `.clamp` inversion audit — a latent crash class, found beyond the brief
All 862 non-test call sites parsed; 240 had a non-literal bound; **9 provably invertible and
fixed**. The most serious was NOT the reported one:
- `skotiq_ui/.../adaptive_dialog_constraints.dart:63` — `minWidth` 200 vs a cap of
  `viewport*0.4`, so it inverts on **any phone under 500 dp**. Two callers take the defaults
  (`framing_assistant_inline.dart:152`, `mosaic_wizard_dialog.dart:786`), so **both throw on a
  phone today**.
- `contextual_tour_prompt.dart:716,719` (width<272/height<172 — mounted over most screens, so a
  throw blanks them), `object_info_popup.dart:60,65` (height<312, reachable in phone landscape
  / split screen), `celestial_grid_painter.dart:249-256` (label larger than canvas → kills the
  whole imaging overlay), `autofocus_progress_overlay.dart:114,116`, `sequence_minimap.dart:237`,
  the BLS/periodogram painters, and `onboarding_tooltip_card.dart:99` (currently lands exactly
  on the boundary).
- ~15 further sites verified SAFE and deliberately left alone; a further set reported but not
  fixed because they are **data**-derived rather than constraint-derived and each needs its own
  decision — notably `camera_panel.dart:503,528` `clamp(gainMin!, gainMax!)`, which throws if a
  device reports max < min. This repo has documented history of exactly that class of hardware
  lie, so it is a real risk on real gear.

### Honest caveat recorded from the implementer
The widget-test environment reports as Linux, so `SkotiqTouchTarget.minExtent` returns 0
and the graph's scale-selector row measures ~25 dp instead of the 48 dp it occupies on Android.
The fix was sized against the device numbers, not the test's, so the exact plot height on
hardware will differ from what the tests measure — worth re-eyeballing on a real phone.

Golden discipline held: 12 failing goldens in the touched directories were each baselined
against unmodified `main` and produce **identical pixel-diff percentages before and after**
(e.g. imaging 8.29/42.29/9.68%, guiding 11.86/10.05/15.38%), i.e. zero pixel change from these
edits, and none were regenerated on Linux.

## Integration state verified by the lead (not taken on report)
| check | result |
|-------|--------|
| `cargo check --workspace --all-targets` | clean |
| `cargo test -p skotiq_sequencer` | 708 pass, 0 fail |
| `cargo test -p skotiq_bridge` | 386 pass (2 in-flight slew-pacing tests red while that agent works) |
| `apps/desktop` headless_api | 885 pass |
| `skotiq_core` providers | 1231 pass |
| `skotiq_ui` full | 226 pass |
| `imaging_service` under UTC / Tokyo / New York | 68 x 3 pass |
| `utc_timestamp` under UTC / Tokyo / New York | 12 x 3 pass |
| analyzer: core / planetarium / ui / desktop | **0 errors, 0 campaign-introduced warnings** (the single `unused_import` in `auto_save_status_hydration_test.dart` is pre-existing — that file is unmodified in the diff) |
| diff hygiene | 0 debug leftovers, 0 new TODO/FIXME across 115 files |

Two flaky-under-parallelism tests confirmed NOT regressions by running them in isolation:
`analytics_remote_image_poll_test.dart` (Dart) and `api::sky_atlas::tests::add_frame_wrapper_matches_fold` (Rust).

## PRE-COMMIT ACTIONS STILL OWED
1. ~~`git checkout -- docs/design/goldens/surface-run-session-progress.png`~~ — **done**, and
   verified: no PNG is modified anywhere in the tree.
2. ~~Windows re-capture of the planetarium benchmark goldens~~ — **retracted, not required.**
   See the RETRACTED entry above: the benchmark renders a synthetic `StressFixture`, not the
   star catalogue, and fails identically with and without the fix. Pre-existing host-specific
   baseline mismatch, already excluded from `melos run test` by its `golden` tag.
3. **Still genuinely owed — on-sky / real-hardware validation** for: the new physically-shaped
   simulated frame model (calibrated to be physically *shaped*, not to match a specific
   sensor's measured performance); a no-filter-wheel Plan Tonight run (proof stops at the Dart
   build boundary); the mobile guiding layout at 300 dp (the widget-test environment reports as
   Linux, so touch targets measure 0 instead of 48 dp); and the Android findings generally,
   which are Linux widget-test evidence rather than on-device.
4. **A LIGHT-frame sequence run to completion** was never achieved — it was blocked by the
   meridian gate, which is now fixed but unverified end-to-end. All light-only accounting
   (Session Report integration, frames-accepted, HFR/FWHM/star-count, guiding stats,
   `is_accepted` grading) therefore remains unproven.
5. **Four independent flaky tests** surfaced only under full-suite parallelism
   (`analytics_remote_image_poll`, `sequence_executor_live_stacking_autofeed`, `settings_sync`,
   and Rust `api::sky_atlas`). Each passes in isolation. None is a regression from this work,
   but the pattern deserves its own investigation.
6. `graphify update .` has not been run — deliberately, since it rewrites a shared index while
   ~121 files are uncommitted.

## Sequencer P0s — FIXED
- **Pause.** Root cause was more specific than "no check": `is_paused` lives only on
  `ExecutionContext`; `InstructionContext` (what `execute_exposure` receives) had **no pause
  handle at all**, and the tree checks pause only at *instruction* boundaries — but a burst is
  N frames inside ONE instruction, so the check could never fire between frames. Fixed with a
  detachable `PauseGate`. **Decision, documented in code: the frame already integrating is
  allowed to finish** — the shutter is already open when the request lands, and aborting throws
  away data the operator did not ask to lose. The guarantee is "no NEW exposure starts".
  A full audit was delivered of which loops got the gate (exposure burst, autofocus attempt and
  per-sample loops — with paused time subtracted from the AF deadline so a Pause cannot
  manufacture a timeout), which already had it, and which were deliberately left with reasons
  (wall-clock waits, thermal ramps, and hardware-already-moving polls, where holding the poll
  would not stop the hardware, only blind the app).
- **Nested-spine "completed".** `addNode` checked only `containsKey(parentId)`, with no
  container check — while `isContainerNode` **already existed** and its own doc comment claimed
  editor insertion used it. It did not. Four copies of the palette handler all fed it. Fixed in
  one place. Test replays the palette handler verbatim: before
  `Expected ['unpark','slew','expose'] / Actual ['unpark']` — the exact run-70 shape. Plus a
  Rust guard: a Success/Skipped run whose tree contains unreachable instructions is now coerced
  to Failure and **names them**.
- **Meridian gate.** Two real bugs, both more specific than my brief: (1) the gate read
  `TriggerState::current_hour_angle`, written only by a poll loop that runs *while a sequence
  executes* and is never invalidated between runs — the hold fired **1.5 ms after run start**,
  reading the previous run's value taken at a different longitude; (2) the pre-flip-side test
  was only half-mirrored, so with pier side Unknown (what the simulator and many mounts report)
  it could hold waiting for a trigger that structurally could not fire. Now recomputes hour
  angle from the target's RA and observer longitude, mirrors the trigger's preconditions, and
  reports *why* it is holding instead of appearing stalled at 0/N.
- **Hardcoded "Sequence failed"** replaced with a real `InstructionFailed` event carrying the
  instruction's own reason.

## Simulator regressions — FIXED
Camera now walks `Idle → Exposing → Reading → Idle`; pier side became **stored mechanical
state** set at slew time rather than a pure function of pointing (and the ASCOM convention in
`meridian.rs` was inverted — fixed); download refuses while integrating or after an abort;
slew is interpolated so `slewing` is observable; park moves to a real park position whose
altitude equals site latitude and is stationary; tracking rate implemented rather than
de-advertised. **All changes are inside `DriverType::Simulator` arms — machine-verified, zero
real-hardware impact.**

The implementer also corrected my brief: the exact repro I quoted (slew to HA +0.30, re-slew
the same coordinates) still errors after the fix, **and correctly so** — a GEM already on the
natural side for a post-meridian target does not flip when re-slewed there; that is not a flip.
The real defect was pier side being a function of pointing, which broke the actual flip path.

Incidental find worth keeping: the crate had **three independent test mutexes over the same
process-global simulator singletons**. Independent mutexes over shared state exclude nothing —
consolidated to one.

## Final verification (lead-run)
`cargo test --workspace` with `TMPDIR` off the tmpfs: **0 failures across every crate**
(389 bridge, 715 sequencer — up from the 708 baseline by exactly the new tests, plus the rest).
The `sky_atlas` failures were environmental and I proved it: `/tmp` is a 16 GB tmpfs at 72%
from agent scratchpads, and the same tests are 10/10 green with `TMPDIR` on disk.
`docs/design/goldens/surface-run-session-progress.png` reverted; **no PNG is modified anywhere
in the tree.**

## Planetarium — FIXED (lead-verified)
`CelestialCoordinate.fromDegrees(raDegrees: ...)` named constructor chosen over hand-converting
79 numbers, so the unit is unambiguous **at the point of definition** and cannot silently
regress. Verified by me: **0 entries with a raw `ra:` > 24** remain, and the new
`star_catalog_ra_units_test.dart` passes both cases ("fallback bright stars store RA in hours,
not degrees" and "HYG parser stores the CSV RA column in hours").
Planetarium suite: **306 pass, 1 fail** — and the single failure is exactly
`benchmark/golden_compare_test.dart`, whose baselines encode the pre-fix (wrong) sky. That is
the correct outcome, not a regression: the golden could only ever fail on the fix. It needs a
deliberate **Windows** re-capture, which I instructed the implementer NOT to do on Linux.

## ESCALATION — the planetarium RA defect was WORSE than I reported
I scoped it to the 79-entry `_fallbackBrightStars` list. **The same bug was in the live HYG
parser**, so **every real install was affected**, not only rigs that had fallen back:
`star_catalog.dart` built `CelestialCoordinate(ra: raHours * 15, /* Convert hours to degrees */ …)`
— i.e. the parser deliberately converted the CSV's hours into degrees and stored them in the
field documented as hours.

Two silent knock-ons the implementer found:
- `getStarsNear` compared an **hours** RA delta against a **degrees** radius, so proximity
  search was wrong by a factor of 15 (a 5° cone on Aldebaran returned Alhena, 29° away).
- `catalog_overlay_service.dart`, which correctly assumed hours, was broken as a consequence,
  while `guide_star_overlay.dart` had been *compensating* with a `/15.0`.

Fixed by storing `raHours` directly, a real angular cone in `getStarsNear` (cos(dec)-narrowed,
0h/24h wrap), and removing the compensating divide. **Live proof against the real 33 MB
catalogue on this machine:** Arcturus 14.2605h, Capella 5.2782h, Polaris 2.5314h,
Fomalhaut 22.9610h — all correct.

Defect 3 was closed structurally rather than patched: `_popupCoordinates` was **removed
entirely** from the app, so popup / Slew / Framing / Sequencer / Add-to-List can only read
`_popupObject!.coordinates`. Before: a tap 5 px off Capella reported RA 5.2400h/Dec 45.6966
instead of 5.2782h/45.998.
**One tap-derived path remains, by design and disclosed:** Slew mode on *empty sky* sends the
tap coordinate behind an explicit confirm dialog showing the RA/Dec. Gyroscope aiming is
sensor-derived, not tap-derived.

Defect 4 evidence: before the fix a below-horizon view drew **0%** ground at az 90/180/310, and
a **zenith** view at az 0 drew **97.6%** ground. After: correct.

### Final flake accounting
`skotiq_core` full suite: 5025 pass, 4 skipped, 2 failures — both
(`sequence_executor_live_stacking_autofeed_test`, `settings_sync_test`) **pass in isolation**,
so parallel-execution flakes, not regressions. Same pattern as the Rust `sky_atlas` and Dart
`analytics_remote_image_poll` cases. Four independent flakes surfaced only under full-suite
parallelism across this campaign — worth its own look, but none is a regression from this work.

### Settled `skotiq_app` suite figure (two agents disagreed; lead adjudicated)
One agent reported 1950/1950, another 1972 pass / 44 fail. Neither was right for the final
tree — the first ran before later fixes landed, the second included goldens. My own run on the
final tree, `flutter test --exclude-tags golden`:
**1949 pass, 1 fail** — and the single failure is `analytics_remote_image_poll_test.dart`,
which I separately confirmed **passes in isolation**. Known parallelism flake, not a regression.
