# Wave D verification — equipment-shell / chrome

Driver: `tools/ui_audit/drive_linux.py`, display `:83`, profile `waveD-equipment-shell`,
`start --fresh`. Build: `apps/desktop/build/linux/x64/release/bundle/skotiq_desktop`
(bundle + `lib/libapp.so` both stamped 2026-08-13 18:31; freshness confirmed by
`strings libapp.so | grep "Close window"` → 1 hit, a string that only exists in the CON-61 fix).
Evidence: `/tmp/ns-audit/shots/waveD-eq/`.

Assigned: EQP-1, EQP-10, EQP-11, EQP-12, EQP-13, EQP-18, EQP-19, EQP-21, EQP-22,
CON-44, CON-60, CON-61, CON-61b.

Result: **12 VERIFIED_FIXED, 1 STILL_BROKEN (CON-61), 8 new findings.**

---

## VERIFIED_FIXED

### EQP-1 — epoch-zero heartbeats reported as OK
Repro run verbatim: connected Simulated Camera, Mount, Focuser, Filter Wheel, Dome and
Weather Station from Discovery, then expanded the System Health chevron.
**Seen:** `Simulated Camera / OK - 0s ago`, and Mount, Focuser, Filter Wheel, Dome and
Weather Station each `OK - last contact unknown`. The string `20676d ago` does not appear
anywhere in the tree. Cards are titled with the device label (`Simulated Mount`), not an
id-derived name. Evidence: `/tmp/ns-audit/shots/waveD-eq/tree-health.txt`, `22-hammer.png`.
The epoch-zero render is gone. **See new finding WD-EQ-1** — the panel still has no
heartbeat at all for 5 of the 6 connected types, and still scores them 100 - Excellent.

### EQP-10 — three device counts on one screen
With all six simulators connected: Equipment header chip **`6 connected · 6 unsaved`**,
global status bar **`My Equipment • 6 connected`** — they agree, including the dome and
weather station that used to be uncounted. Re-checked at 4 and 5 connected: both surfaces
tracked together every time (`17-connected4.png` 4/4, `19-six.png` 6/6, `29-equip-narrow2.png`
5/5). The profile card's `0 devices` is a different quantity (devices *assigned* to the
profile) and the STATUS rail now says so in place: "No devices are assigned to this profile,
so nothing connects automatically." Evidence: `19-six.png`.

### EQP-11 — never-connected device in DEVICE HEARTBEATS
Connected "Built-in Multi-Star Guider"; it failed as expected with the Connection help
dialog. After closing it: DEVICE HEARTBEATS contains exactly the six connected devices and
**no guider card**; System Health still reads `100 - Excellent` with no "1 issue"; there is
no "Unhealthy devices detected" insight. The only `Built-in Multi-Star Guider` node left in
the tree is its Discovery row with a `Connect` button. Evidence: `20-guider.png`,
`tree-afterguider.txt` lines 41-53, 89-95.
Residual, filed separately as **WD-EQ-2**: the failure toast still prints the raw id
`native:builtin_guider:multi_star`, which EQP-11's expected clause forbade.

### EQP-12 — the title-bar bell opened a science feed
The bell glyph is gone. The title bar now carries a **radio/broadcast icon**, the same glyph
the popup's own header uses, and the popup is still "Transient Alerts". The chrome no longer
promises a notification centre it does not have. Evidence: `11-radio-popup.png`.
Scope note: the fix is disclosure only — there is still no notification centre anywhere in
the chrome, which was the second half of the original "why it matters".

### EQP-13 — Weather gated live sensors on the observing location
Fresh profile, no location, Simulated Weather Station connected → Weather now renders the
"Location Not Configured" card **and below it** a Hardware Sensors card with live readings
(Temperature 10.0 °C, Humidity 45 %, Dew Point -1.5 °C, Wind 1.0 m/s, Cloud Cover 5 %, Sky
Quality 21.50 mag/arcsec², "Last updated: just now") **and** the Safety Status card
("Not monitoring — weather safety is off, conditions are not being checked").
Only the radar is gated. Evidence: `26-weather.png`.

### EQP-18 — Edit Dashboard edited a dashboard the user could not see
0 devices connected, Dashboard showing TONIGHT'S BRIEFING → clicked **Edit Dashboard**:
the page did **not** swap to the six-tile widget grid; the briefing stayed exactly as it was
(`12-editdash.png` is pixel-identical to `02-dash.png` apart from the clock). With equipment
connected, view mode and edit mode agree: both list TARGET / GUIDING / SAFETY / RECENT
EVENTS and edit mode adds `Done` + `Reset`. The mismatch is gone.
Residual, filed as **WD-EQ-4**: the refusal is silent — the button is not reported
`[DISABLED]` in the accessibility tree and nothing on screen says why the click did nothing.

### EQP-19 — "Glance mode" was a dead toggle
Clicking it flips `button: Glance mode [off]` → `[ON]` **and** posts
`Glance mode on — session readouts use the large type.` — the toggle now says what it did.
Evidence: `13-glance.png`, tree filter `Glance`.
(The claim is truthful: on an idle dashboard the readouts are the only thing it resizes.)

### EQP-21 — queued toasts contradicting live state
Ran the eight-click hammer on the Simulated Camera row, waited 8 s: **no backlog of
snackbars** — the screen was quiet and every surface agreed (row = `Disconnect`, chip =
`6 connected · 6 unsaved`, status bar = `6 connected`). Evidence: `22-hammer.png`.
Single-click checks caught the toasts in the act, and they are current, not lagging:
`panel: Connected to Simulated Camera` alongside `6 connected · 6 unsaved`, then
`panel: Disconnected Simulated Camera` alongside `5 connected · 5 unsaved`.
The copy is symmetric now — "Disconnected **Simulated Camera**", not "Disconnected camera".
Residual, filed as **WD-EQ-6**: the snackbar is still a full-bleed bar that covers the whole
global status bar while it is up.

### EQP-22 — rapid reconnect double-connected, and flooded the events feed
Log after the eight-click hammer (`/tmp/ns-audit/waveD-equipment-shell/app.log`, 22:43:46 →
22:43:50): every `Connecting to Camera device: sim_camera_1` is preceded by a
`Disconnecting from Camera device` — strictly alternating, no two connects in a row. The
190 ms double-connect is gone.
Dashboard → RECENT EVENTS now reads only `Equipment / Connected / 18:44:56`,
`Equipment / Disconnected / 18:45:10` etc. — **no** `Heartbeat started` / `Heartbeat stopped`
and no `EventStreamReady … (debug)` row. Evidence: `tree-dash2.txt`.
Two residuals: **WD-EQ-2** (the feed labels each row `Camera · sim_camera_1`) and
**WD-EQ-7** (two heartbeat starts per connect against one stop per disconnect).

### CON-44 — the in-flow tour nudge shortened every screen
`start --fresh`, skipped onboarding, **did not dismiss any nudge**:
* **Sequencer** with the "Sequencer Tour" card up: the three-panel workspace runs to the
  bottom of the window — the node palette ends in its "Drag nodes or double-click to add"
  footer at y≈690/720 and the Science category is on screen. No black band.
  (`27-sequencer.png`; compare the old `147px` band.)
* **Settings** with the "Settings Tour" card up: the sidebar shows GENERAL → **ADVANCED**,
  with `Collapse` still visible below it. The whole ADVANCED group is on screen on a fresh
  install, which was the consequence CON-44 called out. (`04-settings.png`.)
* The nudge itself now floats over the content in the bottom-right on every screen.
New trade-off filed as **WD-EQ-5**: floating, it now covers controls at narrower widths.

### CON-60 — Connection Status dialog clipped by the window bottom
Clicked the crossed-eye title-bar icon at 1600x900: the dialog opens **centred** (y 288-432
of 720, wholly on screen), with its title, "Not connected to a server", and a visible
**Close** button. Escape and Close both dismiss it. Evidence: `10-conn-dialog.png`.
Cosmetic leftover, not filed: the card reserves ~60 px of empty body between the message and
the button.

### CON-61b — a `?section=` deep link taken while Settings is open did nothing
Opened Settings with the gear (lands on **General**), then clicked the person icon:
the pane switched to **Equipment Profiles** and the sidebar selection moved with it.
Evidence: `08-gear-settings.png` (General) → `09-deeplink2.png` (Equipment Profiles).
The dead person icon of CON-61's second half is alive: from the Dashboard it navigates to
Settings → Equipment Profiles (`03-person.png`).
One case is still inert and is filed as **WD-EQ-3b** below: after the operator picks a
different section by hand, the same link no longer moves anything.

---

## STILL_BROKEN

### CON-61 (first half) — the title bar is still absent from the accessibility tree
**Repro:** any screen, `tree --all`, grep for the chrome.
**Actual:** at every window size and on every screen, `tree` contains **zero** title-bar
nodes. Direct probes: `click "Settings"`, `click "Notifications"`, `click "Account"`,
`click "Connection status"`, `click "Alerts"` → all five return
`error: no control matching … in the live tree`, while `click "Equipment"` in the same
breath resolves to the on-screen `Connect equipment` button, so the walk is working.
`grep -icE "minimize|maximize|close window|transient|settings"` over a full `--all` dump on
the Dashboard, on Settings and again after a `resize 1000 800` relayout: **0**.
The **nav rail is missing too** — no `Dashboard`/`Equipment`/`Imaging`/… destination and no
`Collapse` button appear anywhere in the tree; the only `Dashboard` node is the status-bar
chip. Whole-tree shape is one unbranched chain (`application → frame → panel → filler
[offscreen] → panel×6 → content`), i.e. the shell chrome contributes no semantics node at all.
**The fix is compiled in:** `_TitleBarButton`/`_WindowButton` do wrap `Semantics(button:
true, label: …)` in
`packages/skotiq_app/lib/screens/shell/widgets/title_bar.dart:187,281`, and the built
`libapp.so` contains the `Close window` literal — so this is not a stale binary and not a
missing label. Something between those widgets and the AT-SPI bridge is dropping the whole
chrome subtree; a per-button `Semantics` wrapper was the wrong layer, or was not the only
thing needed.
**Consequence unchanged:** the Settings gear is still the only route to Settings and it is
still unreachable to assistive tech, which is what made this a P2.
Evidence: `/tmp/ns-audit/shots/waveD-eq/tree-dash.txt`, `tree-settings.txt`,
`tree-health.txt`.

---

## New findings

### WD-EQ-1 (P2) — the heartbeat panel still cannot detect a dead device, for 5 of 6 types
**Repro:** connect Camera, Mount, Focuser, Filter Wheel, Dome, Weather Station; expand
System Health.
**Actual:** only the camera ever has an age (`OK - 0s ago`, later `OK - 28s ago`). The other
five read `OK - last contact unknown` permanently — the value never becomes a time, because
nothing but `CameraStateNotifier` records `lastSuccessfulCommunication`. Meanwhile the panel
above them says `100 /100 — All metrics within normal ranges. Equipment performing well.`
and `Equipment health stable`.
**Why it matters:** EQP-1 fixed the *rendering* of a missing timestamp; the panel's actual
job — telling an unattended imager that the mount has gone quiet — is still not done for any
device except the camera, and the score still says everything is fine. A mount that dies at
01:00 will read exactly what it reads now.
**Evidence:** `tree-health.txt` lines 41-53, `22-hammer.png`.

### WD-EQ-2 (P3) — raw internal device ids are still in user-facing copy
**Repro (a):** Discovery → Connect "Built-in Multi-Star Guider" (fails). A toast reads
**"Equipment disconnected — Guider native:builtin_guider:multi_star disconnected."**
**Repro (b):** Dashboard → RECENT EVENTS after any connect: every row is subtitled
**`Camera · sim_camera_1`**.
EQP-11's fix moved the id out of the insight card; these two surfaces still print it. (b)
is in the same feed EQP-20 was cleaning up.
**Evidence:** `20-guider.png`, `tree-dash2.txt`.

### WD-EQ-3 (P3) — one failed connect raises three toasts, two of them identical
**Repro:** Discovery → Connect the built-in guider once.
**Actual:** three stacked toasts — `Guider Error … requires an active profile with a guide
focal length` **twice**, verbatim, plus `Equipment disconnected — Guider … disconnected` for
a device that was never connected — on top of the Connection help dialog that says the same
thing a third time. Four statements of one refusal.
**Evidence:** `20-guider.png`.

### WD-EQ-3b (P3) — the person icon is dead again once you move within Settings
**Repro:** person icon (lands on Equipment Profiles) → click **Connection** in the sidebar →
click the person icon again.
**Actual:** nothing moves; the pane stays on Connection. The route target is unchanged, so
`didUpdateWidget` sees no changed key and the CON-61b fix declines to act. The implementation
note called this "already showing what the link names", but the screen is *not* showing it —
the operator navigated away — so from the outside this is exactly the dead-icon symptom
CON-61 filed.
**Evidence:** `06-conn-section.png` (before) vs `07-deeplink.png` (after, unchanged).

### WD-EQ-4 (P3) — Edit Dashboard is silently inert in standby
**Repro:** 0 devices connected → Dashboard → click **Edit Dashboard**.
**Actual:** nothing happens and nothing explains it. The tree reports
`button: Edit Dashboard` with **no `[DISABLED]` state** (the harness does print `[DISABLED]`
for genuinely disabled nodes in the same dumps), so assistive tech is told the control is
live; there is no snackbar and no visible disabled styling. The fix's stated disclosure
("with the reason in its tooltip") is not reachable by keyboard or screen reader, and a
pointer user who clicks gets silence.
**Evidence:** `12-editdash.png`, tree filter `Edit Dashboard` on the standby dashboard.

### WD-EQ-5 (P3) — the now-floating tour nudge covers controls at narrower widths
**Repro:** `resize 1000 800` → Equipment (Equipment Tour nudge still up).
**Actual:** the nudge (x≈745-985, y≈620-745) sits on top of the DISCOVERY panel header,
covering its right-hand `Scan All` / `Collapse` controls, and abuts the mount card's
`Unpark / Track / Home / Flip` row. At 1600x900 it also overlays the STATUS rail's
"Ready to image — 2 items are blocking first light" block.
This is the cost side of CON-44's fix: the coach mark no longer steals layout, but it is a
plain floating card with no scrim and no offset from interactive content, so on a fresh
install some controls are unclickable until it is dismissed.
**Evidence:** `29-equip-narrow2.png`, `22-hammer.png`.

### WD-EQ-6 (P3) — snackbars still cover the entire global status bar
**Repro:** any snackbar (Glance mode toggle, or connect/disconnect a device) at 1600x900.
**Actual:** the bar is full-bleed across all 1600 px at the window bottom and paints over
the whole status bar — connection chips, save path, clock and all — for its whole lifetime.
This is EQP-21's second sub-defect; the copy and the currency were fixed, the geometry was
not. The status bar is the one strip an operator glances at, and a routine toast blanks it.
**Evidence:** `13-glance.png`.

### WD-EQ-7 (P4) — two heartbeat starts per connect, one stop per disconnect
**Repro:** connect/disconnect a simulator, read the log.
**Actual:** each connect logs `Starting heartbeat for device sim_camera_1` twice — once as
`Auto-started heartbeat` right after `Simulator connected`, and again under
`Starting heartbeat monitoring for Camera device` — while each disconnect logs a single
`Stopping heartbeat monitoring for device`. The native auto-start and the Dart-side request
are both firing. Whether the second start replaces the first or stacks a second timer is not
visible from the log; the asymmetry is.
**Evidence:** `/tmp/ns-audit/waveD-equipment-shell/app.log` 22:43:47-22:43:50.

### WD-EQ-8 (P4, harness) — two traps that will make the next verifier report a false result
1. **The AT-SPI tree lags navigation.** After clicking the person icon, a `tree` dump taken
   2 s later still showed the whole previous screen (and the dump itself took ~25 s of wall
   clock — its first and last clock panels differed by 25 s). A second dump showed the new
   screen. Always dump twice before calling a control dead.
2. **`resize` moves the window to +0+0.** `shot` bakes the window origin into its
   `click-img` mapping, so every `click-img` against a screenshot taken *before* a resize
   lands 160,150 px off and silently does nothing (or worse, hits something else). Re-shoot
   after any resize. `resize --show` reports the new origin.

---

## Coverage / not exercised
* Banner order could not be exercised: none of `DisconnectedBackendBanner`,
  `ConnectionStaleBanner`, `WeatherAlertBanner`, `IosBackgroundBanner`,
  `AndroidNotificationsBanner` triggers on a local desktop profile with simulators and
  weather safety off, so their stacking order is still unverified live.
* Narrow width tested at 1000x800 only (single-column Equipment reflow, Sequencer three-pane
  → same three panes). Phone widths (<600) were not driven in this cluster.
