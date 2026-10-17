# GUI release pass — cluster: sky-discovery

Screens in scope: Planetarium, Framing, Your Sky, First Light, Constellation.

Harness: `tools/ui_audit/drive_linux.py`, profile `gui-sky-discovery`, display `:85`.
Fresh profile, onboarding walked end to end (Sim driver enabled; Simulated
Camera / Mount / Focuser / Filter Wheel / Guider; 530 mm f/5.0, 3.76 µm →
1.46 arcsec/px; site 40.7128, -74.0060; captures in
`/tmp/ns-audit/gui-sky-discovery/captures`).

**Binary under test:** `apps/desktop/build/linux/x64/release/bundle` — `libapp.so`
built 2026-08-11 09:55 (the Wave-B bundle). Its `libskotiq_bridge.so` had been
deleted from the bundle before this pass started, so every GUI agent's `start`
failed with "Native bridge failed to initialize"; I rebuilt
`cargo build --release -p skotiq_bridge` and copied the fresh `.so` into
`bundle/lib/`. FRB generated glue (`frb_generated.rs`, `frb_generated.dart`,
both 2026-08-10 13:27) is unmodified in the tree, so the Dart/Rust ABI matches.
Dart-side fixes made after 2026-08-11 09:55 are **not** in this binary.

This report supersedes the 2026-08-11 pass of the same name (backed up at
`/tmp/claude-1000/.../scratchpad/sky-discovery-prev.md`). Findings that the
earlier pass also saw are marked **carryover** with the old ID; they were
re-driven here and still reproduce in this binary.

Findings are appended as they are confirmed.

---

## Findings

### SKY-1 — P1 — The planetarium's pause button says "paused" and the clock keeps running

**Screen:** Plan Tonight → Planetarium → time transport (bottom centre).
**Carryover** of the 2026-08-11 pass's SKY-5; re-driven and still reproduces.

Repro:
1. Plan Tonight → Planetarium.
2. Note the clock in the transport bar and the `08:52:23`-style readout in the
   top-left overlay. Both track wall time.
3. Click the transport's centre button (the one drawn as ⏸).
4. The glyph flips to ▶ — the control now states "paused, press play to resume".
5. Wait ≥100 s and read the clock again.

Expected: simulated time stops; the sky freezes at the paused instant.
Actual: the clock keeps advancing at exactly 1× wall rate. Measured: clicked
pause at planetarium clock `08:52:23` (wall 08:52:23); 112 s later the same
readout showed `08:54:15` (wall 08:54:15) with the ▶ glyph still displayed
(`/tmp/ns-audit/shots/sky-transport-paused.png` shows ▶ at 08:54:27, wall
08:54:27). The time model is "wall clock + offset" and nothing ever stops it —
pressing ⏭ three times just adds 3 h to the offset (clock `11:54:50` at wall
`08:54:50`, and M31's altitude changed 39.0° → 10.7°, so the offset is real).

Why it matters: a planning tool whose "pause" does not pause means every
screenshot, altitude readout and framing decision you take while "paused" is
against a moving sky, and the control is the one users trust to hold it still.

### SKY-2 — P0 — Creating a Your Sky region locks the whole app: the dialog spins forever and Cancel, Escape and the nav rail are all dead

**Screen:** Plan Tonight → Discover → Your Sky → "Name a region".
New in this pass (the earlier pass never got a region created).

Repro:
1. Plan Tonight → Discover → Your Sky (empty state) → `Name a region`.
2. Choose `Custom RA/Dec`. Enter RA `83.82`, Dec `-5.39`, leave Radius `0.5`,
   name `Orion audit region`.
3. Click `Create region`.

4. Try to get out: click `Cancel`; press `Escape`; click outside the modal;
   click `Dashboard` in the nav rail.

Expected: the region is created and the dialog closes (or reports an error).
Actual: the button swaps to a spinner and stays there — still spinning after
20 s, 60 s and 75 s (`/tmp/ns-audit/shots/sky-region-dlg3.png`,
`sky-region-dlg4.png`, `sky-region-dlg5.png`). **And the dialog can no longer be
dismissed by any means**: `Cancel` (clicked twice, coordinates verified against
two independent captures — root 803,785 and 805,785), `Escape` (twice),
an outside click, and every nav-rail item are all inert. The app is not frozen —
the status-bar clock keeps ticking (09:06:04 in
`/tmp/ns-audit/shots/sky-region-stuck.png`) and the sky panels behind repaint —
it is a modal barrier that never lifts. The only way out is killing the process.

Meanwhile the region **was** created and is correct: behind the modal Your Sky
now reads "Regions — 1 region · none imaged yet" with a card
"Orion audit region / 5h 35m · -5° 23' / Custom / 0s / 0 tiles" — the
degrees→sexagesimal conversion is right. So the work succeeded and only the
dialog's completion path is broken.

Why P0: the app that is running your imaging session cannot be recovered without
force-quitting it. Do this while a sequence is running and the run goes with it.
Nothing is written to the app log at any point, so there is no clue what stalled.

**Reproduced twice, on two separate app launches** — second run: RA `202.5`,
Dec `47.2`, name `Repro region two`; spinner stuck at 12 s, `Cancel` and
`Escape` both dead. After restarting the app, Your Sky reads "2 regions · none
imaged yet" and lists `Repro region two — Custom — 13h 30m · +47° 12'`
(202.5° = 13h30m, 47.2° = +47°12', both correct), so both writes committed and
only the dialog's completion path is broken. This is deterministic, not a race.

### SKY-3 — P2 — Your Sky asks for RA in degrees while the rest of the app speaks hours

**Screen:** Plan Tonight → Discover → Your Sky → "Name a region" → Custom RA/Dec.

The field is labelled `RA (degrees)` with the hint `0–360`. Two tabs away, the
Framing screen prints the same quantity as `05h 35m 16s`, the Planetarium
readout as `Center RA: 0h 42m 44s`, and the Framing RA input accepts sexagesimal.
A user who copies the RA they are looking at (`05h 35m 16s`) into this box
creates a region 79° from where they meant, and nothing validates it.

Expected: one RA convention across the product, or an input that accepts both
and echoes the interpreted value.

### SKY-4 — P2 — "Create region" is clickable with no target selected and silently does nothing

**Screen:** Plan Tonight → Discover → Your Sky → "Name a region", `From a target` mode.
**Carryover** of SKY-12 (2026-08-11); re-driven, still reproduces.

Repro:
1. Fresh profile (no targets in library). Your Sky → `Name a region`.
2. Leave the mode on `From a target`. The dialog itself says "No targets in your
   library yet — switch to Custom to enter a sky position by hand."
3. Click `Create region`.

Expected: the button is disabled (and reported disabled to accessibility), or
clicking explains what is missing.
Actual: the click is accepted; nothing happens — no error, no toast, no
close, no log line. The accessibility tree reports the button with no
`[DISABLED]` state, so a screen-reader user is told it is actionable.

### SKY-5 — P1 — Scrubbing the planetarium's clock silently rewrites the Dashboard's "Local" time, its astro-dark countdown and the moon phase

**Screen:** Plan Tonight → Planetarium (time transport) → Dashboard.
Extends the earlier pass's SKY-7, which only saw the status-bar LST. The leak is
much wider than that.

Repro:
1. Dashboard. Read the header: `08:48:12 / LST 05:19:56` labelled **Local**,
   `Dark in 12h 52m`, Moon `1%`. All correct for the real local time.
2. Plan Tonight → Planetarium. Click the transport's step-forward (⏭) ~20 times
   (each click = +1 h), or click `TONIGHT`.
3. Go back to Dashboard (nav rail) and read the same header.

Expected: the Dashboard reports the real time and the real countdown; a
planetarium preview must not redefine "now" for the rest of the app.
Actual (measured at wall-clock 09:20:04):

| element | shows | truth |
| --- | --- | --- |
| Dashboard header clock, labelled `Local` | `17:43:56` (Aug 14) | 09:20:04, Aug 13 |
| Dashboard `LST` | `14:21:12` | 05:52 |
| Dashboard `Dark in` | `3h 54m` | 12h 19m |
| Dashboard Moon | `6%` | 1% |
| App status bar clock (bottom right) | `09:20:04` | 09:20:04 |
| App status bar LST (right next to it) | `14:21` | 05:52 |

So one screen carries two clocks 8.5 hours apart, the wrong one is the one
labelled "Local", and nothing anywhere outside the Planetarium hints that the
app is showing a simulated instant. Pressing `NOW` in the Planetarium restores
every value (`Dark in 12h 19m`, `LST 05:52`), which confirms the causal link.
The state is session-scoped — a restart clears it.

Why it matters: "Dark in" is the number a user plans their evening around, and
the briefing does not say it is fictional.

### SKY-6 — P1 — Deep-sky objects are drawn with no angular size, so the planetarium cannot answer "does this fit my field?"

**Screen:** Plan Tonight → Planetarium.
**Carryover** of SKY-1 (2026-08-11); re-driven at two zoom levels on three
objects, still reproduces.

Repro:
1. Planetarium → search `M31` → select it (view centres on 0h42m44s +41°16').
2. Zoom to FOV 2.0° (wheel up ~23 clicks). M31 is 178' × 63' — it should fill
   the field.
3. Also search `NGC7000` (120' × 30') and view it at FOV 7.2°.

Expected: extended objects render at their catalogued angular size and position
angle, the way a planetarium is expected to.
Actual: every deep-sky object is a fixed ~6–10 px marker regardless of size.
Evidence: `/tmp/ns-audit/shots/sky-m31-2deg.png` (M31, M32 and M110 as three
identical dots in a 2° field) and `/tmp/ns-audit/shots/sky-ngc7000.png` (a 420 px
crop at 7.2° FOV — ~125 px per degree — where NGC7000 is a 10 px dot; at its
real 2.0° × 0.5° it should be ~250 px × 60 px, and IC5070 and NGC6997 beside it
are the same size dot).

The data is present and right — the details panel prints `120.0' × 30.0'` for
the same object, and marker colour already encodes object type — so this is
purely the renderer. Framing (which draws a real FOV rectangle over a survey
image) is the only place in the product that answers the framing question.

### SKY-7 — P2 — The planetarium search overlay draws two result lists on top of each other, the front one clipped mid-row

**Screen:** Plan Tonight → Planetarium → Search (or Ctrl+K).
**Carryover** of SKY-3 (2026-08-11); still reproduces.

Repro:
1. Planetarium → click `Search` → type `M31`.

Expected: one result list.
Actual: two. `/tmp/ns-audit/shots/sky-search.png` shows a narrow panel
("74 results / Deep Sky Objects (25) / M31 / M41 / M39 / M35 / M34 / M37 / M33")
painted over a wider list whose rows show through on the right edge as clipped
fragments — `ag 3.4`, `ag 3.8`, `ag 4.5` — and whose own rows ("31 Orion
HIP25737 mag 4.7", "31 Pegasus HIP110386 mag 4.8", "31 Boötes") continue below
the narrow panel. The accessibility tree confirms both lists exist at once: a
list of `button:` entries and a separate `panel: 74 results / Deep Sky Objects
(25) / …` list with the same objects. The front list's last visible row (M33) is
cut off mid-row.

### SKY-8 — P2 — Tooltips appear far from the control they describe, and several can be visible at once

**Screen:** Plan Tonight → Planetarium toolbar.
**Carryover** of SKY-2 (2026-08-11); still reproduces, plus a lifecycle problem.

Repro:
1. Planetarium. Hover/click the `Layers` button in the toolbar (5th icon).

Expected: the tooltip sits under the Layers button.
Actual: `/tmp/ns-audit/shots/sky-layers.png` shows the `Layers` tooltip drawn at
(643,170) in a 1280-wide capture while the button it belongs to is at (467,91) —
176 px right and 79 px down, i.e. floating over the star field next to a
different control.

Second half: tooltips do not retire. Clicking the toolbar buttons in sequence
leaves several alive at the same time — one tree dump contained both
`Reset view (zenith, FOV 60)` and `Equatorial view — tap for Alt/Az` while the
pointer was on a third button. On a dark star field two stale floating labels
read as sky annotations.

### SKY-9 — P2 — Framing's FOV overlay and mosaic planner are gated on a *connected* camera, not on the profile you just built

**Screen:** Plan Tonight → Framing.
Refines SKY-8 (2026-08-11), which attributed this to the wizard not asking for
sensor size.

Repro:
1. Complete onboarding with a full optical train (focal length 530, aperture 106,
   pixel 3.76 µm — the wizard computes and shows `1.46 arcsec/px`) and a camera
   assigned to the profile. Do not connect anything.
2. Plan Tonight → Framing.

Expected: with focal length and pixel size known and a camera in the profile,
the FOV overlay is available for planning from the couch.
Actual: `Equipment — Not Configured`, `Camera Not Configured — Connect a camera
or configure camera specs to enable accurate FOV preview`, `Configure equipment
to see FOV overlay`, `Configure equipment to enable mosaic planning`.
Connect the simulated camera on the Equipment screen and everything appears
immediately and correctly (`FOV 0.78° × 0.44°`, `Sensor 1920 × 1080`,
`1.46 arcsec/px`) — so the only missing input is the sensor pixel dimensions,
which the wizard never asks for and which only arrive from a live device.
Disconnecting the camera again reverts Framing to `Camera Not Configured`
(that part is honest).

Impact: framing and mosaic planning — the two things you do indoors before a
session — require the rig to be powered and connected.

### SKY-10 — P3 — Wheel zoom ignores the pointer and always zooms the view centre

**Screen:** Plan Tonight → Planetarium.

Repro:
1. Planetarium at FOV 60°, centre RA 5h45m56s +40°42'.
2. Put the pointer on Jupiter (bottom-left, ~30° from centre) and scroll up 14
   clicks.

Expected (every map UI, and Stellarium/SkySafari): the sky zooms toward the
cursor, so the object under it stays put.
Actual: FOV goes 60° → 7.2° and the centre is byte-identical
(`Center RA: 5h 45m 56s`, `Center Dec: +40° 42'`) — the object under the cursor
is thrown off screen and you must drag it back after every zoom step.

### SKY-11 — P3 — Planets render as an oversized disc with colliding labels

**Screen:** Plan Tonight → Planetarium at wide FOV.

Repro: Planetarium, FOV 60°, look at the Gemini/Cancer region on the morning of
2026-08-13 (`/tmp/ns-audit/shots/sky-plan1.png`, `sky-layers.png`).

Actual: Jupiter is a flat orange disc roughly 35–40 px across in a 1280-wide
capture — about 2° of sky, ~200× its true 40″ — and more than twice the diameter
of Capella (mag 0.08), the brightest star on screen. `MERCURY`'s label lands on
top of the same disc, so one blob carries two planet names. Nothing in the frame
is drawn at a comparable size, so it reads as a rendering fault rather than a
planet.

### SKY-12 — P3 — The planetarium's own readout overprints object labels

**Screen:** Plan Tonight → Planetarium, bottom edge.
**Carryover** of SKY-14 (2026-08-11); still reproduces.

The `Center RA / Center Dec / FOV / Bortle` strip is painted straight onto the
star field with no scrim, so it collides with whatever is behind it. In
`/tmp/ns-audit/shots/sky-plan1.png` the text `Bortle: 5 (lim 5.9m)` sits on top
of the object label `NGC2264 - Christmas Tree Cluster`, and both are unreadable.

### SKY-13 — P3 — Two different features are called "First Light"

**Screens:** onboarding step 13, Equipment status panel, Analytics → Science →
First Light.

- Onboarding's last step offers `Capture first light` / `Capture your first
  light` — "take your very first exposure, guided step by step".
- The Equipment status panel says `1 item is blocking first light.`
- The flagship discovery surface — transient detection against your atlas — is
  `Analytics → Science → First Light`.

Same words, three meanings, one product. Whichever one keeps the name, the
others need different words.

### SKY-14 — P3 — Fuzzy search returns hundreds of results for an exact catalogue designation

**Screen:** Plan Tonight → Planetarium → Search.

Typing `M31` reports `74 results` — including M41, M39, M35, M34, M37 and ten
`31 <constellation>` Flamsteed stars. Typing `NGC7000` reports
`Deep Sky Objects (434)`. The exact match is ranked first in both cases, so this
is noise rather than a wrong answer, but a 434-row list for a designation the
user typed in full is not a result set anyone reads.

### SKY-15 — P3 — Escape does not back out of the Your Sky region detail view

**Screen:** Plan Tonight → Discover → Your Sky → (region card).

The region detail is a full-screen route that hides the Plan Tonight tab bar;
the only way back is the ← arrow at the top left. `Escape` does nothing, and
clicking where the Discover tabs used to be does nothing. Combined with SKY-2
(Escape also cannot dismiss the region dialog), keyboard dismissal appears to be
unwired across this feature.

### SKY-16 — P4 — Desktop UI says "tap"

**Screen:** Plan Tonight → Planetarium, coordinate-mode toggle tooltip.

The tooltip reads `Alt/Az view — tap for Equatorial` (and `Equatorial view —
tap for Alt/Az`). This is the desktop build, driven with a mouse; the rest of
the app says "click" or names the action.

### SKY-17 — P3 — Planetarium layer switches expose no state to accessibility, inconsistently inside one panel

**Screen:** Plan Tonight → Planetarium → Layers.
**Carryover** of SKY-11 (2026-08-11); still reproduces, with a sharper example.

One `tree` dump of the open Layers panel:

```
panel: DSO labels [DISABLED]
panel: Constellation lines [DISABLED]
panel: Constellation labels [DISABLED]
panel: Constellation boundaries [DISABLED]
panel: Constellation art [DISABLED]
panel: Milky Way [DISABLED]
panel: Variable stars [DISABLED]
panel: Coordinate grid [DISABLED]
toggle button: Equatorial (RA/Dec) lines [off]
toggle button: Alt/Az lines [off]
panel: Ecliptic [DISABLED]
panel: Galactic plane [DISABLED]
panel: Meridian [DISABLED]
panel: Cardinal directions [DISABLED]
```

Two rows in the middle of the list are proper toggles with an on/off state; the
other twelve are inert panels reported as *disabled*. A screen reader is told
that twelve of the fourteen sky layers cannot be operated, and none of them
report whether they are currently on.

### SKY-18 — P3 — "Constellation" and "Collaborate" are two Discover tabs selling the same thing through the same dialog

**Screen:** Plan Tonight → Discover.
**Carryover** of SKY-16 (2026-08-11); still reproduces.

`Constellation`: "Join the swarm — pool your photons with other imagers into one
deeper sky" → `Connect to a hub`.
`Collaborate` ("Collaborative Sky"): "Image the sky together — pool integration
on one target across rigs, split a mosaic across your club, and share
calibration" → the same `Connect to a hub` dialog.
Both are empty until the same hub connection exists. A user cannot tell which
tab to open for which job.

## Prior findings that did NOT reproduce

| Prior ID | Claim | This pass |
| --- | --- | --- |
| SKY-10 (2026-08-11) | Constellation "Connect to a hub" rejects every address including its own example and never attempts a connection | **Does not reproduce.** The dialog performs a real connection and reports precise transport errors: `http://127.0.0.1:8090` → "Cannot reach 127.0.0.1: Connection refused"; the placeholder's own `http://skotiq.local:8090` → "Cannot reach skotiq.local: Failed host lookup: 'skotiq.local'". Both are correct for this machine (no hub running, no mDNS name). |
| SKY-13 (2026-08-11) | First Light cannot be reached at all on a fresh profile | **Does not reproduce.** `Analytics → Science → First Light` reaches it in two clicks from the nav rail on a fresh profile, and its empty state is good. (`/science` is a redirect to `/analytics?tab=science`.) |
| SKY-8 (2026-08-11) | Framing is dead because the wizard never asks for sensor size | Partly. Re-scoped as SKY-9 above: connecting the camera unlocks everything, so the gate is a live device, not the wizard alone. |

## Coverage

### Screens driven

| Screen | What was exercised |
| --- | --- |
| Onboarding (13 steps) | walked end to end on a fresh profile: driver set (Sim enabled), camera/mount/focuser/filter wheel/guider selection, optical train (530 mm / 106 mm / 3.76 µm → f/5.00, 1.46 arcsec/px — arithmetic verified), capture folder + writability check, observing site, review, save, final CTA screen |
| Plan Tonight → Planetarium | search (typeahead, result selection, centring on M31 and NGC7000), wheel zoom 60° → 16.5° → 2.0° → 7.2°, view centre stability, Alt/Az ↔ Equatorial toggle, Reset-view/Layers/Search toolbar buttons, Layers panel contents, time transport (pause, step ±1 h ×23, NOW, TONIGHT, date rollover to Aug 14), deep-zoom disclosure banner, object details panel (NGC7000: coordinates, designations, size, rise/transit/set, altitude & airmass charts, action buttons), bottom readout, tooltips |
| Plan Tonight → Framing | target resolve by name (M42 → 05h35m16s -05°23'23", alt/az verified by hand), DSS2 Red survey load + attribution, equipment FOV overlay (0.78° × 0.44° from 1920×1080 @ 1.46″/px — verified), preview-FOV presets, rotation control, sidebar scroll, Guided Framing 4-step state machine, behaviour with the camera connected *and* after disconnecting it mid-session |
| Plan Tonight → Discover → Your Sky | empty state, `Name a region` dialog in both modes, region creation (custom RA/Dec), region list + atlas coverage tiles, region detail view (contributing frames, deepening-over-time, depth & provenance), persistence across an app restart |
| Plan Tonight → Discover → Constellation | empty state, `Connect to a hub` dialog, two connection attempts (IP and hostname) with real error reporting |
| Plan Tonight → Discover → Collaborate | empty state and its CTA |
| Analytics → Science | Science sub-tab (science-idle state, plate-solve health, Night Story, Science guide ladder) |
| Analytics → Science → First Light | empty state, filter chips (All / Unnamed / Confirmed / Dismissed), explanation copy |
| Equipment (support, not audit) | Connect All / Disconnect All to drive Framing's equipment gate |
| Dashboard (support, not audit) | header clock/LST/dark-countdown/moon, used as the oracle for SKY-5 |

### Screens I could not reach

| Screen | Why |
| --- | --- |
| Your Sky — populated tiles, depth scrub through time, contributing-frame list | Requires plate-solved frames folded into the atlas. The region I created stays at "0 tiles / 0s"; no capture was run in this pass (imaging belongs to another cluster). |
| Constellation — swarm view, shared targets, distributed mosaic, co-add | Requires a reachable self-hosted hub. None exists on this machine; the dialog now fails honestly (see the non-reproducing table). |
| First Light — a real transient candidate card, submit/export flows | Requires ≥5 frames of atlas depth on a patch plus a solved frame that differs. |
| Planetarium — mount slew / "Go To" from the details panel | Deliberately not driven: it commands hardware, and the audit stayed read-only on hardware paths. |
| Planetarium — Milky Way layer rendering (prior SKY-4) | The Layers drawer opens but its rows are unlabelled panels with no exposed state and I could not locate the row's hit box within the screenshot budget; **not re-tested**, treat the prior finding as still open. |

## Notes

- **Log health.** `app.log` for the whole session contains no exception, no
  `RenderFlex`, no overflow warning (the 44 grep hits for "error" are all
  `… 0 backend errors` INFO lines). Note this is the Rust-side log; Flutter
  framework errors may not land here, so a clean log is not proof of a clean
  frame. No frame-timing lines are emitted at all, so I have no numbers to cite
  on jank; subjectively, pan/zoom/search stayed responsive under softpipe and I
  am not raising a performance finding.
- **Debug spew in a release build (not my cluster).** Every discovery cycle
  prints two unformatted, untimestamped lines to the app log:
  `[QHYDEMO DEBUG] Entering demo camera registration block` and
  `[QHYDEMO DEBUG] demo_enabled=0 demo_count=1 image_dir=`. This is native-side
  and will appear in every customer's log.
- **Status bar prints device IDs (not my cluster).** After connecting, the
  global status bar shows `Camera sim_camera_1` / `Mount sim_mount_1` rather
  than the model names the rest of the UI uses ("Simulated Camera").
- **Cry-wolf guider banner (not my cluster).** With PHD2 never connected and not
  installed, a banner appeared mid-session: "PHD2 connection lost and automatic
  relaunch failed after 3 attempts. Reconnect the guider manually." Nothing was
  ever connected, so nothing was lost.
- **Astrometry spot-checks pass.** M31 selected at 08:50 EDT from 40.7128 N,
  -74.0060 W reported Alt 39.1° / Az 295.1°; hand-computed 39.0° / 295.1°.
  M42 resolved to 05h35m16s -05°23'23" with Alt 43.9° at LST ≈ 5h30m
  (transit altitude 90 - (40.71 + 5.39) = 43.9°). NGC7000's rise/transit/set
  (14:23 / 00:20 / 10:18) is right for Dec +44.5° at that latitude. The maths
  layer is sound; SKY-6 is a renderer gap, not a data gap.
- **Harness notes for the next pass.**
  - `--profile` must come **after** the subcommand (`start --profile X`), not
    before it: the subparser re-declares the flag, so a leading `--profile`
    is silently overwritten with `main`.
  - In the Bash tool's zsh, an unquoted `$VAR` holding `--profile name` does not
    word-split, so `click-img $P shot.png X Y` fails argument parsing. Quote or
    inline the flags, and never send those calls to `/dev/null` — a whole batch
    of "the app ignored my typing" was actually eight arg-parse errors.
  - Layout shifts between captures (dismissing a tour card moved the Equipment
    screen's `Connect All` button 120 px), so re-`shot` before every click that
    follows a state change.
