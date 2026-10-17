# Release-pass GUI audit — Equipment / Diagnostics / Weather / Dashboard / App shell

Driver: `tools/ui_audit/drive_linux.py`, display `:83`, profile `gui-equipment-shell`, `start --fresh`.
Build: `apps/desktop/build/linux/x64/release/bundle/skotiq_desktop`.
Evidence screenshots live in `/tmp/ns-audit/gui-equipment-shell/`.

**Harness note for whoever re-drives this:** `--profile NAME` must come *after* the subcommand.
`drive_linux.py --profile X start` silently runs as profile `main` (the subparser re-applies the
`main` default over the value parsed by the top-level parser), which collides with other agents.

---

## Findings

### EQP-1 — P1 — Device heartbeats read "OK - 20676d ago" seconds after connecting
**Screen:** Equipment → STATUS rail → System Health (expanded) → DEVICE HEARTBEATS
**Minimal repro (deterministic — reproduced twice, including on a fresh app process):**
1. Equipment → DISCOVERY → Expand → **Connect** the Simulated Camera, then the Simulated Mount, then
   the Simulated Focuser.
2. Expand the "System Health" chevron in the STATUS rail and read DEVICE HEARTBEATS.
**Expected:** every just-connected device shows a heartbeat of a few seconds.
**Actual:** only the **camera** ever shows a real age (`OK - 26s ago`). Every other device type
shows `OK - 20676d ago` — 56.6 years, i.e. an epoch-zero timestamp — while still painted with a
**green "OK" dot**, and the overall score still reads **100 - Excellent**. Verified for Mount,
Focuser, Filter Wheel, Dome and Weather Station.
**Evidence:** `/tmp/ns-audit/gui-equipment-shell/s13-heartbeats.png`,
`/tmp/ns-audit/gui-equipment-shell/s34-small-equip.png` (all seven cards legible in one frame).
**Why it matters:** the heartbeat panel exists precisely to tell an unattended imager that a device
has gone quiet. It renders the worst possible staleness value and calls it OK, so the one widget that
should catch a dead device is proven untrustworthy on the happy path.

### EQP-2 — P2 — "System Health: 100 - Excellent" and "Equipment health stable … in the recent session history" are asserted from ~15 s of data on a fresh profile
**Screen:** Equipment → STATUS rail → System Health
**Repro:**
1. Start with a fresh profile (`start --fresh`), skip onboarding, open Equipment. Health chip reads
   `Not assessed`.
2. Connect one device (Simulated Camera). Within a second the chip flips to `100 - Excellent`.
3. Expand it: "100/100 — All metrics within normal ranges. Equipment performing well." and a green
   card "Equipment health stable — No negative trend exceeded alert thresholds in the recent session history."
**Expected:** a score that reflects an actual observation window, or a "collecting data" state.
**Actual:** a maximal score and a claim about "recent session history" on a profile that has no
session history at all (the same screen says "No runs yet" on the Dashboard).
**Evidence:** `/tmp/ns-audit/gui-equipment-shell/s10-health.png`

### EQP-3 — P2 — A connected device card is clipped mid-label by the Discovery panel, with no scrollbar and no way to reach its controls
**Screen:** Equipment → profile device pane
**Repro:** at a 1600x900 window: Equipment → Connect the Simulated Camera → expand DISCOVERY.
**Expected:** the device pane scrolls, or the card compacts.
**Actual:** the camera card is cut off horizontally through the middle of its metric labels
("Sensor Temp / Cooler / Status" are sliced in half) and its entire control row — **Cool to -10°C,
Warm Up, the settings icon and the disconnect icon** — is not rendered at all. No scrollbar, no
fade, no indication content is hidden. The only way to reach the cooler controls is to notice that
collapsing Discovery brings them back.
**Evidence:** clipped `/tmp/ns-audit/gui-equipment-shell/s08-cam-connected.png` vs intact
`/tmp/ns-audit/gui-equipment-shell/s09-camcard.png`.

### EQP-4 — P2 — Every control on a connected device card is invisible to assistive tech
**Screen:** Equipment → device card
**Repro:** connect the Simulated Camera, then `drive_linux.py tree`.
**Actual:** the whole card comes back as a single `panel:` node whose name is the card's text run
concatenated ("CAMERA\nSimulated Camera\nConnected\n…20.0°C\nSensor Temp\n0%\nCooler…"). At the
1600x900 window the buttons are not exposed at all; the "Assign" dropdown on every Discovery row is
exposed as `panel: Assign [DISABLED]` rather than a button. A screen-reader user is told a wall of
text and given no operable controls.

### EQP-5 — P2 — The whole navigation rail and the title-bar icon buttons expose no accessible name or role
**Screen:** app shell
**Repro:** on any screen run `drive_linux.py tree`.
**Actual:** none of the 8 rail destinations (Dashboard, Equipment, Imaging, Sequencer, Guiding,
Weather, Plan Tonight, Analytics), the rail "Collapse" control, or the 4 title-bar icon buttons
(eye-with-slash, bell, person, gear) appear anywhere in the accessibility tree. Primary navigation
is entirely unreachable by a screen reader, and the 4 icon-only title-bar buttons have no visible
label either — there is no way to learn what the eye-with-slash does without clicking it.

### EQP-6 — P2 — Equipment's first-run card promises a 3-step device scan and instead re-opens the 13-step onboarding at Step 2
**Screen:** Equipment (fresh profile, after skipping onboarding)
**Repro:**
1. Fresh profile → skip onboarding → click **Equipment** in the rail.
2. The pane reads "Welcome to Skotiq / Let's set up your first equipment profile" and lists
   "1 We'll scan for connected equipment · 2 Select the devices you want to use · 3 Save as a profile
   for one-click connection", with a primary **Start Setup** button.
3. Click **Start Setup**.
**Expected:** the 3-step scan/select/save flow the card just described.
**Actual:** the full-screen "Set up your rig — **Step 2 of 13**" onboarding wizard reappears, opened
on the *Drivers* checkbox step. Nothing about it matches the three promised steps, and it takes over
the whole window.
**Evidence:** `/tmp/ns-audit/gui-equipment-shell/s04-equip-welcome.png`

### EQP-7 — P3 — "Skip onboarding" from the Equipment entry point dumps the user on the Dashboard
**Screen:** Equipment → Start Setup → Skip onboarding
**Repro:** Equipment → Start Setup → **Skip onboarding** (top right).
**Expected:** return to Equipment, where the flow was launched from.
**Actual:** lands on the Dashboard. The user has to find Equipment in the rail again. (Verified
twice; the rail highlight moves to Dashboard and the content pane is the Dashboard briefing.)

### EQP-8 — P3 — A second, competing "Welcome to Skotiq" after the onboarding wizard already said it
**Screen:** onboarding step 1 vs Equipment first-run card
**Repro:** fresh profile → the wizard's step 1 is headed "Welcome to Skotiq"; skip it → Equipment
shows a *different* full-pane card also headed "Welcome to Skotiq". Two first-run experiences
with the same title, overlapping content (both offer to pick devices and drivers), and no
acknowledgement of each other.

### EQP-9 — P4 — Onboarding driver copy for "Sim" is ungrammatical and inconsistent with the rest of the app
**Screen:** onboarding Step 2 of 13 "Which drivers should we scan?"
**Actual:** "**Sim** — Simulated device where that workflow is enabled for testing". "where that
workflow is enabled" refers to nothing; the peers are clean sentences ("ASCOM Alpaca over network.
Device capabilities are reported by the Alpaca server."). Everywhere else the app calls these
devices "Simulated …" / "Simulator", not "Sim". The option is also **off by default**, so a fresh
install finds 0 devices and cannot try the app without hardware.
**Evidence:** `/tmp/ns-audit/gui-equipment-shell/s02-drivers.png`

### EQP-10 — P1 — Three different device counts for the same profile, on the same screen at the same moment
**Screen:** Equipment (plus the global status bar)
**Repro:** connect Simulated Camera, Mount, Focuser, Filter Wheel, Dome and Weather Station from
Discovery. Read the three counters without moving.
**Actual, simultaneously:**
- left profile card: **"My Equipment / 0 devices"**
- Equipment header chip (top right): **"6 connected · 6 unsaved"**
- global status bar (bottom left): **"My Equipment / 4 connected"**
**Expected:** one number, or three numbers whose labels explain the difference.
**Evidence:** `/tmp/ns-audit/gui-equipment-shell/s18-connhelp.png` (all three visible in one frame);
tree confirms `panel: 4 connected` in the status bar and `panel: 6 connected · 6 unsaved` in the header.
**Why it matters:** the status bar is the thing a user glances at before starting a run. It is
under-reporting connected hardware by a third, with no legend to say what it counts.

### EQP-11 — P2 — A device that never connected is listed under DEVICE HEARTBEATS and permanently degrades System Health, quoting a raw internal device ID
**Screen:** Equipment → STATUS
**Repro:**
1. Equipment → DISCOVERY → Expand → scroll to GUIDERS → **Connect** on "Built-in Multi-Star Guider".
2. It fails (correctly — no focal length in the profile) and shows the Connection help dialog. Close it.
3. Look at STATUS.
**Actual:** the guider row still reads "Connect" with a grey dot (i.e. not connected), and the
status bar reads "Guider Disconnected" — yet DEVICE HEARTBEATS now contains a card
**"Built-in Multi-Star Guider — Unhealthy - last seen 20676d ago"**, System Health has dropped from
`100 - Excellent` to `75 - Good / 1 issue`, and the insight card reads
**"Unhealthy devices detected: native:builtin_guider:multi_star."**
**Expected:** a device that was never connected does not appear in a heartbeat list, and no
user-facing string contains `native:builtin_guider:multi_star`.
**Evidence:** `/tmp/ns-audit/gui-equipment-shell/s17-guiderclick.png`
**Note:** the same epoch value `20676d ago` is rendered as green "OK" for five devices and red
"Unhealthy" for this one — see EQP-1.

### EQP-12 — P2 — The title-bar bell opens a *science* feature, not notifications
**Screen:** app shell → title bar
**Repro:** click the bell icon in the title bar (root ≈ x=1662 at a 1900px-wide window).
**Actual:** a popup headed **"Transient Alerts"** with "No active alerts" and "View all alerts →".
"View all alerts" navigates to **Analytics → Science → Observing Alerts**, a TNS supernova-alert
queue ("TNS: skipped — no API key · never checked").
**Expected:** a bell in the window chrome is the app's notification centre. Here it is a citizen-
science alert feed, and it reports "No active alerts" at the same moment the Equipment screen is
showing an unresolved device-health issue. There is no other notification surface in the chrome, so
a user who wants "what went wrong tonight" has nowhere to look.

### EQP-13 — P2 — Weather Radar hides live sensor data behind the location gate
**Screen:** Weather
**Repro:**
1. On a fresh profile with no observing location, connect the **Simulated Weather Station** on
   Equipment (its card shows Temperature / Humidity / Cloud Cover / Rain Rate updating).
2. Open **Weather** in the rail.
**Actual:** the entire screen is one empty state — "Location Not Configured / Weather radar requires
your observation location to display relevant data." The connected weather station's live readings,
the Hardware Sensors card, and the whole Safety Status block are not rendered at all, even though
none of them need a location.
**Expected:** gate only the satellite/radar map on location; keep hardware sensors and safety status
visible.
**Evidence:** `/tmp/ns-audit/gui-equipment-shell/s20-weather-empty.png` (gated) vs
`/tmp/ns-audit/gui-equipment-shell/s26-weather.png` (same devices, after entering 44.05 / -121.31).

### EQP-14 — P2 — Diagnostics tells the user to select a session and gives them no control to do it
**Screen:** Analytics → Diagnostics ("Optical Train Diagnostics")
**Repro:** Analytics → **Diagnostics** tab on a profile with no sessions.
**Actual:** the body is an empty state reading **"Select an imaging session to analyze"**, but the
screen contains no session picker — the only session-related element is the static grey text
"No sessions available" in the top-right corner (a `panel:` in the tree, not a control). The
instruction is unactionable, and the empty-state glyph is an outlined **star**, which has nothing to
do with optical trains.
**Expected:** either a disabled session dropdown, or an empty state that says there are no sessions
yet and points at how to make one.
**Evidence:** `/tmp/ns-audit/gui-equipment-shell/s30-diagnostics.png`

### EQP-15 — P3 — Diagnostics intro paragraph is set full-bleed at ~180 characters per line
**Screen:** Analytics → Diagnostics
**Actual:** the 5-sentence explainer under the title runs the full 1130 px content width with no
`maxWidth`, giving three lines of ~180 characters each in small grey text. Every other explanatory
block in the app (readiness cards, connection help, weather) is constrained to a readable measure.
**Evidence:** `/tmp/ns-audit/gui-equipment-shell/s30-diagnostics.png`

### EQP-16 — P3 — Discovery list cannot be scrolled from the keyboard
**Screen:** Equipment → DISCOVERY (expanded)
**Repro:** click on a Discovery section header (a non-interactive spot inside the list), then press
`Page_Down`, then `Down`.
**Actual:** nothing scrolls; the view stays pinned at CAMERAS. The same list scrolls immediately on
a mouse wheel. At a 1900x1180 window only 4 of the 11 device categories are visible, so **Guiders,
Rotators, Domes, Weather, Safety Monitors, Cover/Calibrators and Switches are unreachable without a
mouse wheel.**
**Evidence:** `/tmp/ns-audit/gui-equipment-shell/s14-scroll.png` (after Page_Down — unchanged) vs
`/tmp/ns-audit/gui-equipment-shell/s15-wheel.png` (after six wheel notches).

### EQP-17 — P3 — "Transient Alerts" and "TC" are unexplained jargon in the chrome
**Screen:** app shell
**Actual:** the title-bar notification popup is headed "Transient Alerts" (see EQP-12), and the
global status bar contains a two-letter chip reading **"TC"** with no label, no tooltip and no
accessible name (`panel: TC` in the tree). Nothing on screen says what TC is.

### EQP-18 — P2 — With no equipment connected, "Edit Dashboard" edits a dashboard the user cannot see
**Screen:** Dashboard
**Repro (the no-equipment state is load-bearing — do not connect anything first):**
1. With **zero devices connected**, open Dashboard at a 1600x900 window. On screen: TONIGHT'S
   BRIEFING, the ASTRO DARK IN / IMAGING WINDOW twilight bar, "Tonight's targets", "Readiness",
   "Last run", "Moon".
2. Click **Edit Dashboard** (top right).
**Expected:** the same tiles, now draggable/removable.
**Actual:** the page is replaced by a *different set of six tiles* — Target ("No active target — load
a sequence to begin."), Live frame ("Waiting for first frame…"), GUIDING, Equipment, SAFETY and
RECENT EVENTS. **Not one** of the tiles the user was just looking at is present. Click **Done** and
the briefing comes back. So in this state there is no way to reorder, hide or configure any tile the
dashboard actually shows, and the editor presents six tiles that are not on it.
**Root cause is visible in the app:** the Dashboard swaps its whole layout on connection state —
briefing when nothing is connected, the operations widget grid once a device is connected — but the
**editor always shows the widget grid**. Connect the Simulated Camera and repeat: view mode and edit
mode now agree, which is what makes the no-equipment case a bug rather than a design.
**Evidence:** `/tmp/ns-audit/gui-equipment-shell/s41-dash.png` (view) vs
`/tmp/ns-audit/gui-equipment-shell/s43-editdash.png` (edit), both with 0 devices connected.

### EQP-19 — P2 — "Glance mode" is a dead toggle
**Screen:** Dashboard → header strip → the eye icon left of "Edit Dashboard"
**Repro:** Dashboard → click the eye-with-slash button in the header strip.
**Expected:** something changes — bigger type, fewer tiles, a night-glance layout.
**Actual:** the button lights up blue, its icon flips to an open eye, and the tree flips
`button: Glance mode [off]` → `[ON]` — **and nothing else on the page changes at all**. The two
screenshots are identical apart from the button and the clock.
The state survives navigation and is still `[ON]` after visiting Equipment and coming back, still
with no effect. There is no tooltip, no disabled state and no "only during a run" hint.
**Evidence:** `/tmp/ns-audit/gui-equipment-shell/s41-dash.png` (off) vs
`/tmp/ns-audit/gui-equipment-shell/s42-glance.png` (on).

### EQP-20 — P2 — Internal debug events are shown in the user-facing "Recent events" feed
**Screen:** Dashboard → Edit Dashboard → RECENT EVENTS tile
**Actual:** the only entry reads
`System  EventStreamReady   10:23:44 / Event stream subscription is active (debug)`
— a raw internal enum name and a line that literally ends in "(debug)", in a feed a paying user is
meant to read for what happened during their night.
**Evidence:** `/tmp/ns-audit/gui-equipment-shell/s43-editdash.png`

### EQP-21 — P2 — Toasts are queued and lag the action, so the last message on screen contradicts the live state
**Screen:** Equipment → Discovery
**Repro:** click **Connect / Disconnect** on the Simulated Camera row eight times as fast as the
mouse allows, then wait 8 s and read the bottom of the window.
**Actual:** the snackbars replay one at a time long after the clicks stop. `tree` at 10:28:05 shows
the status bar carrying **"Disconnected camera"** while the same tree shows `My Equipment / 1
connected`, the row button reading `Disconnect`, and a live sensor temperature of 20.0°C — i.e. the
message on screen says the camera is disconnected while it is connected. Seconds later the queue
catches up with a green "Connected to Simulated Camera".
Two supporting defects in the same test:
- the snackbar is a **full-bleed bar across the entire 1600 px window** that covers the whole global
  status bar while it is up (`/tmp/ns-audit/gui-equipment-shell/s45-statusbar.png`);
- the copy is inconsistent between the two directions — "Connected to **Simulated Camera**" (device
  name, title case) vs "Disconnected camera" (generic, lowercase).

### EQP-22 — P3 — Rapid reconnect issues a connect to an already-connected device and floods the user-facing event feed with heartbeat plumbing
**Screen:** Equipment → Discovery → Simulated Camera, then Dashboard → RECENT EVENTS
**Repro:** the same eight-click hammer as EQP-21, then `log --tail 60`, then open the Dashboard.
**Actual:**
- the log shows two `Connecting to Camera device: sim_camera_1` **190 ms apart with no intervening
  disconnect**, each starting its own heartbeat monitor — the UI happily issues a connect for a
  device that is already connected;
- the user-facing **RECENT EVENTS** feed on the Dashboard then reads, all stamped `10:27:57`:
  `Heartbeat started · Heartbeat stopped · Heartbeat started · Heartbeat stopped · Connected`
  — five entries for one connect, four of which are internal heartbeat lifecycle noise that means
  nothing to an astrophotographer.
**Not a leak:** the stop events are present, so the monitors are being torn down; the defect is the
double-connect and the plumbing spam in a feed meant to summarise the night.

### EQP-23 — P2 — The app died on a window resize, with six devices connected and no teardown
**Screen:** app shell
**Repro (observed once, reproduced as a warning twice):**
1. Run at 1900x1180 with Camera, Mount, Focuser, Filter Wheel, Dome and Weather Station connected.
2. Resize down to 1000x700, use the app, then resize back up to 1900x1180.
**Actual:** GTK logs
`WARNING: Timed out waiting for OpenGL frame of size 1900x1180 (have 1000x700)`, the window paints
solid black, the accessibility tree disappears, and shortly after the window and the process are
both gone. The log's **last line is that warning** — there is no shutdown record, no error, and none
of the connected devices were safed or disconnected on the way out.
The identical warning was logged on an earlier grow-resize (1600x900 → 1900x1180) which the app
survived, so the timeout itself is reproducible.
**Caveat for the verifier:** this harness renders with Mesa **softpipe** on Xvfb, where a large
resize is genuinely slow, so some of this may be environmental. What is not environmental is that a
frame-timeout is allowed to end the process **silently** — no crash dialog, no log entry, no device
safing — which is exactly what an unattended imager must never do.
**Evidence:** `/tmp/ns-audit/gui-equipment-shell/s37-equip-big.png` (all black), `app.log` tail.

### EQP-24 — P3 — One glyph, three meanings, one screen: the eye-with-slash
**Screen:** app shell + Dashboard
**Actual:** the same eye-with-a-slash icon is used for three unrelated things visible at once on the
Dashboard:
1. **title bar, far left of the icon group** — opens a "Connection Status / Not connected to a
   server" popup (remote-server state);
2. **dashboard header strip** — the "Glance mode" toggle (EQP-19);
3. **each tile in Edit Dashboard** — "hide this tile".
None of the three carries a visible label.

### EQP-25 — P3 — Device card titles are ellipsized while the card has room
**Screen:** Equipment → device cards
**Repro:** connect the Simulated Filter Wheel and Simulated Weather Station at a 1900x1180 window.
**Actual:** the card headings render as **"Simulated Filter ..."** and **"Simulated Weath..."**
because the fixed-width "✓ Connected" chip is laid out first and the title takes what is left, even
though the card is ~220 px wide and the strings are short. "Simulated Camera", "Simulated Mount" and
"Simulated Focuser" fit, so only some cards truncate — it reads as a rendering fault rather than a
deliberate rule.
**Evidence:** `/tmp/ns-audit/gui-equipment-shell/s17-guiderclick.png`

### EQP-26 — P3 — "Tonight's targets" gives every target the same score
**Screen:** Dashboard → Tonight's targets
**Actual:** NGC7080, NGC7056, IC5104 and NGC7063 are all scored **98**. The card's only ranking
signal is a column of identical numbers, so the list conveys no preference between four different
objects.
**Evidence:** `/tmp/ns-audit/gui-equipment-shell/s41-dash.png`

### EQP-27 — P4 — The status bar's globe-icon "Dashboard" chip duplicates the first nav-rail item
**Screen:** app shell → status bar
**Repro:** on **Equipment**, read the status bar: it contains a globe icon followed by the word
**"Dashboard"**. Click it.
**Actual:** it navigates to the in-app Dashboard screen. So it is a plain navigation shortcut
duplicating the top rail item, but it is drawn with a **globe** (the universal "web / remote" glyph)
and it reads as a *current-screen* indicator that is wrong on every screen except one.

### EQP-28 — P3 — The SAFETY tile's status chip is truncated
**Screen:** Dashboard → Edit Dashboard → SAFETY tile
**Actual:** the chip reads **"Not monito"** with the rest clipped, and the tile's expand icon sits
immediately against it. The full string is "Not monitoring", which the same tile prints in full two
lines lower ("Weather safety is off — conditions are not being checked"). The **same chip in view
mode reads "Not monitored"** — a third wording for one state on one tile ("Not monitoring" /
"Not monito…" / "Not monitored").
**Evidence:** `/tmp/ns-audit/gui-equipment-shell/s43-editdash.png`

### EQP-29 — P3 — The Observing Alerts filter chips float unanchored in the middle of the page
**Screen:** Analytics → Science → Observing Alerts
**Actual:** the "All / New / Queued / Observed" segmented control is horizontally centred in an
otherwise left-aligned page, sitting inside a rounded container that is wider than the chips and
detached from every other element. Every other filter row in the app is left-aligned with the
content.
**Evidence:** `/tmp/ns-audit/gui-equipment-shell/s29-analytics.png`

---

## Checked and found sound (so a verifier does not re-file these)

- The readiness roll-up counts honestly: the collapsed card's "3 items are blocking first light" and
  "View all (3 more)" resolve to a dialog reading "3 items are blocking first light and 3 items need
  attention", with 3 red, 3 amber and 1 green item. No miscount.
- The **Connection help** dialog for the failed built-in guider is genuinely good: it explains that
  the guider is software, names the missing value (focal length), gives three concrete steps, and
  offers Retry. It appears ~2-3 s after the click.
- Every "session only" device card carries an honest warning that it is not saved to the profile and
  will not reconnect next launch — and after the app restarted, none of them did.
- Weather's Safety block is honest under a disabled setting: "Not monitoring — weather safety is off,
  conditions are not being checked", plus a footer stating that none of the listed settings are in
  effect.
- The narrow (1000x700) layout reflows sensibly — the STATUS rail moves above the content instead of
  being crushed — and no RenderFlex overflow was logged at any size tested.
- 24 rapid rail-to-rail navigations across all 8 destinations produced no exception, no visual
  corruption and no log error.
- Location entered in Settings persisted across the app restart, and LST / twilight / moon values
  populated correctly for 44.05 N, 121.31 W.

---

## Coverage

**Screens driven:** first-run onboarding (steps 1-2 and the Skip path); Dashboard (wide, narrow,
Glance mode, Edit Dashboard); Equipment (profile rail, empty state, Discovery collapsed + expanded,
all 11 device categories listed, 7 device types connected, device cards, STATUS/System Health/Device
Heartbeats/readiness roll-up dialog, Connection help dialog); Weather (location-gated empty state and
the populated radar + hardware sensors + safety view); Analytics → Diagnostics; Analytics → Science →
Observing Alerts; Settings → Location (reached as a deep link from Weather); app shell (nav rail
expanded and collapsed, all four title-bar icons, global status bar, window resize 1600x900 /
1900x1180 / 1000x700, snackbars, rapid navigation stress, rapid connect/disconnect stress).

**Not reached, and why:**
- Onboarding steps 3-13 — deliberately skipped to reach the assigned cluster; only Welcome and
  Drivers were audited.
- Populated Diagnostics — needs plate-solved session frames; a fresh profile has none and the screen
  offers no way to load any (that inability is EQP-14).
- Rotator / Safety Monitor / Cover-Calibrator / Switch device cards — discovered and listed, but not
  connected (Discovery's mouse-wheel-only scroll, EQP-16, plus the crash in EQP-23 ended the run).
- `SKOTIQ_SIM_FAULTS` fault-injection pass — not run. The crash in EQP-23 forced a restart and
  the remaining budget went to re-verifying state truthfulness instead. Error-state review here is
  based only on the one real failure encountered (the built-in guider).
- The title-bar "person" icon — never opened.

