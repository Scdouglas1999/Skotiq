# Wave E dryness check — equipment-chrome

Driver: `tools/ui_audit/drive_linux.py`, display `:83`, profile `waveE-equipment-chrome`,
`start --fresh`. Build under test:
`apps/desktop/build/linux/x64/release/bundle/skotiq_desktop`
(`lib/libapp.so` stamped 2026-08-13 20:33).

**Freshness proof (the D-fix strings are in this binary):** `strings libapp.so` finds
`Expand navigation` (side_navigation CON-61 half), `Next target check` and
`Target Queue tab` (CON-53/54), and `device_last_contact` (the new WD-EQ-1 provider
file). `Collapse navigation` is absent only because it is built as
`l10n.text('collapse') + ' navigation'`, not a literal.

Evidence: `/tmp/ns-audit/shots/waveE-eq/`.

Assigned: WD-EQ-1, WD-EQ-2, WD-EQ-3, WD-EQ-3b, WD-EQ-4, WD-EQ-5, WD-EQ-6, CON-61,
plus spot-checks CON-46/49/51/52/53/54/55/56/58/59/62/63.

**Result: 7 verified fixed, 12 still broken, 6 new findings.** The cluster is NOT dry.

---

## VERIFIED_FIXED

### WD-EQ-1 (P2) — heartbeats now carry a real age for every connected type
Repro run verbatim: Equipment → "I'll do it manually" → Discovery → Connect
Simulated Camera, Simulated Mount, Simulated Focuser, Simulated Filter Wheel →
expand System Health.
**Seen:** DEVICE HEARTBEATS lists all four with ages —
`Simulated Camera OK - 0s ago`, `Simulated Mount OK - 10s ago`,
`Simulated Focuser OK - 13s ago`, `Simulated Filter Wheel OK - 6s ago`
(`09-before-guider.png`, `tree-health1.txt`). The string
`OK - last contact unknown` does not appear anywhere in the tree.
**Not a poll-clock artefact:** three samples 25 s apart gave
(8,12,15,8) → (12,6,9,2) → (9,13,6) seconds. The values differ per device and
exceed the 10 s poll period, so they come from the native heartbeat timestamp
rather than from "now at poll time".
**Prunes correctly:** after disconnecting the camera the panel drops to three
cards and no stale camera entry is left behind.
**No new noise:** the 10 s poller adds nothing to `app.log` (146 lines for the
whole 20-minute session).
Not exercised: a device that stops answering (needs `SKOTIQ_SIM_FAULTS` and a
relaunch) — the "detect a dead mount" half of the original why-it-matters is still
unproven on this build.

### WD-EQ-3b (P3) — the person icon works after the operator moves within Settings
Person icon → Settings → **Equipment Profiles** (`11-person-settings.png`) →
click **Connection** in the sidebar (tree confirms `panel: Connection`) → person
icon again → the pane is back on **Equipment Profiles** ("Manage your imaging rigs
and configurations"). No cross-talk either: from the Dashboard the gear still lands
on **General** (verified by the General pane's "Launch app minimized to system
tray" row), so the new serial does not drag the operator around on a rebuild.

### WD-EQ-5 (P3) — the tour nudge no longer covers Equipment's controls
1600x900 (`13-equip-again.png`): the Equipment content stops at y≈570 and the
Equipment Tour card sits in the reserved band below; DISCOVERY's Scan All /
Expand row and the STATUS rail's blockers are fully visible.
1000x800 (`25-equip-narrow.png`, the width the finding named): content stops at
y≈613, the card sits below it, and the discovery refresh / search / collapse
buttons at y≈562 are clear. Other screens keep the floating default
(`20-analytics.png`, `22-sequencer.png`, `31-dash-connected.png`).
See **WE-EQ-N2** for what now lands in that reserved band.

### WD-EQ-6 (P3) — the snackbar no longer covers the global status bar
1600x900, connect Simulated Camera (`18-state.png`, measured on the raw frame
`burst-5.png`): the toast fill occupies root **y 956–1001, x 1228–1742** — a
514 px (≈411 dp) right-aligned bar whose bottom edge stops ~4 px above the status
bar (window bottom 1050, status bar ≈45 px tall). Every status-bar chip stays
readable.
1000x800, disconnect Simulated Camera (`nb-win-2.png`): the toast is near-full
content width, as designed, and still sits entirely above the status bar.

### CON-46 (P3) — "0" vs "No data" in one card grid
The reported repro no longer produces the grid: Analytics → Equipment Stats on a
fresh profile renders `No equipment history yet` / "Capture some frames and this
tab reports what your camera, mount and guider actually did." + `Go to Imaging`.
The rule itself is compiled in (`equipment_stats.dart:229` `_formatIntegration`
returns `'0s'` for a zero sum, `:247` keeps `'No data'` for means of nothing).
Caveat: with real capture history the grid was not exercised, so only the reported
state is proven clean.

### CON-54 (P3) — scheduler internals on screen
Plan Tonight → Schedule, tree verbatim: "Autopilot is stopped. Start it and it
will pick a target and keep re-picking as the sky changes.",
"Not evaluating targets — start it to begin." `No tick scheduled.` and the
`every 60s` period are gone.
Residual (unchanged, minor): "Cannot start unattended until: Observing location,
Capture output path, Disk space." is still a comma-joined list.

### CON-63 (P4) — the connection glyph
Both halves settled at 2x (`19-icons-zoom.png`): the leftmost title-bar glyph is
unmistakably **wifi-off** (three arcs + slash), not a crossed-out eye — the Wave-2
reading was a misread, and the icon constant was right all along. The filled
"selected" chip in the resting `not connected` state is **gone**; all four
title-bar icons now render identically flat.

---

## STILL_BROKEN

### WD-EQ-2 (P3) — raw device ids in user-facing copy — the (b) fix is a no-op
The D-fix log claims (b) FIXED via `_humanizeDeviceIds` in
`run_dashboard_providers.dart:576`. Live, Dashboard → RECENT EVENTS
(`tree-dash2.txt` lines 80–92) still reads verbatim:
`Guider · native:builtin_guider:multi_star`, `Filter Wheel · sim_filterwheel_1`
(twice), `Focuser · sim_focuser_1`.
**Why it cannot work as written:** `_humanizeDeviceIds` bails out when
`friendly == deviceId`, and `friendlyNameFromDeviceId`
(`skotiq_core/lib/src/utils/device_id.dart:289`) only rewrites ids beginning
`native:zwo_efw:`, `native:qhy_cfw:`, `native:fli_fw:`, `ascom:` or `alpaca:` —
everything else falls through to `return deviceId` at line 328. Every id in the
finding (`sim_camera_1`, `sim_filterwheel_1`, `native:builtin_guider:multi_star`)
takes that branch, so the substitution never fires for the exact ids reported.
(a) is unchanged as expected (declared out of scope): the failure toast still reads
`Equipment disconnected — Guider native:builtin_guider:multi_star disconnected.`
(`10-guider-fail.png`).

### WD-EQ-3 (P3) — one failed connect still raises three toasts
Discovery → Connect "Built-in Multi-Star Guider" once (`10-guider-fail.png`):
`Guider Error … requires an active profile with a guide focal length` **twice**,
verbatim, plus `Equipment disconnected — Guider native:builtin_guider:multi_star
disconnected.` for a device that never connected, on top of the Connection help
dialog. Four statements of one refusal — identical to Wave D. (Declared blocked on
scope by the D-fix batch; recorded as still broken, not as a regression.)

### WD-EQ-4 (P3) — Edit Dashboard is still silently inert, and still claims to be enabled
Standby dashboard, 0 devices (`02-dash.png`): clicking Edit Dashboard changes
nothing (`03-editdash-click.png` is identical) and posts no toast.
AT-SPI probe of that exact node:
`button: 'Edit Dashboard\nEdit Dashboard'  desc=''  states=['sensitive','showing','visible']`
— i.e. **enabled**, and the new `hint` did not reach the bridge (empty
description). Rendered treatment is a normal outline button (label peak luminance
159 vs 175 on the enabled "Plan Tonight"), `29-editdash-zoom.png`.
Decisive comparison: with three devices connected (non-standby, where the button
really is enabled and does toggle) the tree prints the **identical**
`button: Edit Dashboard` with no `[DISABLED]`. Enabled and disabled are
indistinguishable to assistive tech, and the refusal reason is still unreadable
without a pointer.

### CON-61 (P2) — the title bar and nav rail are still absent from the accessibility tree
`tree --all` on Equipment with four devices connected: 279 lines,
`grep -icE "minimi|maximi|close window|collapse navigation|expand navigation|transient|account|connection status"` → **0**.
No nav-rail destination appears (`Dashboard` matches only the status-bar chip).
The in-widget half of the D-fix (the rail's collapse button now wraps
`Semantics(button, label: 'Collapse navigation')`) is compiled into the binary and
has **no runtime effect**: the only `Collapse` node in the tree is Discovery's,
probed as `panel: 'Collapse'  desc=''  states=['focusable','showing','visible']`.
Unchanged consequence: Settings is still reachable only through a gear that
assistive tech cannot see.

### Consistency spot-checks — all reproduce as filed
* **CON-49** (P4) — onboarding step 1: `button: Back` with **no** `[DISABLED]`;
  clicking it leaves `panel: Step 1 of 13` unchanged.
* **CON-51** (P3) — Sequencer → History still ships seven live `button:` chips
  (Completed, Failed, Aborted, Stopped, Stopped (resumable), Interrupted, Running),
  five of them "did not finish", on a screen whose own empty state says
  "No runs yet".
* **CON-52** (P3) — Builder: no header. Templates: "Sequence Templates" /
  "Start with a template or save your sequences for reuse" (no stop).
  History: "Execution History" / "Past sequence runs with statistics and
  performance data." (stop). Unchanged.
* **CON-53** (P2) — the old sentence is gone but the replacement is a new false
  claim; see **WE-EQ-N1**.
* **CON-55** (P3) — Plan Tonight → Recommendation: `button: Open Settings`;
  Plan Tonight → Framing: `panel: Edit Profile` — still a non-focusable panel for
  the same kind of control. Copy changed ("Optical Specs Missing / Set the focal
  length in profile \"My Equipment\"…"), the treatment split did not.
* **CON-56** (P4) — Plan Tonight → Planetarium still exposes `button: NOW` and
  `button: TONIGHT`.
* **CON-58** (P3) — Analytics → Projects: "No targets available for project
  tracking yet" / "Add targets and capture images to track multi-night progress."
  (now with a `Go to Imaging` button) against Plan Tonight → Projects'
  "No projects yet" + `New Project`. Two screens named Projects, still opposite
  instructions for creating one.
* **CON-59** (P4) — Sequencer → Templates, verbatim: `~1 hr 15 min`,
  `~3 min capture`, `~3 hr 30 min`, `~10 min capture`, `~16 hr (multi-night)`.
* **CON-62** (P3) — Settings → Help & Tutorials unchanged: Title Case and sentence
  case in one five-row list, three verbs (Start / Re-run / Open) for one action,
  filled-blue against dark-outline treatments in the same column, plus the pale
  Start on Tutorial Tours (`24-help.png`).

---

## New findings

### WE-EQ-N1 (P3) — CON-53's replacement copy points at a tab that does not exist
**Repro:** Plan Tonight → Schedule → Unattended Autopilot card.
**Actual, verbatim:** "Runs hands-off and re-picks the best target all night as the
sky changes. **For a plan you can see and edit before it runs, build one in the
Target Queue tab.**"
There is no Target Queue tab. Plan Tonight's tabs are Recommendation, Projects,
Schedule, Framing, Planetarium, Discover.
`planner_screen_parts/_schedule_tab.dart:4` states it outright: *"The former
'This Week' + 'Target Queue' tabs are unified here"* — the tab was removed, and
`plannerTabTargetQueue: 'Target Queue'`
(`localization/skotiq_localizations/translations.dart:599`) is now an orphan
string with no live UI referent. The nearest thing wearing that name is the
Sequencer palette's third tab, labelled just **Queue**.
**Why it matters:** the defect CON-53 filed was "Plan Tonight tells you to use
Plan Tonight". The fix replaced one unfollowable instruction with another — and
the queue it means (`Scheduler queue`, "No targets in your catalog", with its own
`Open target catalog` button) is rendered **directly beneath the card that sends
you away**.
**Evidence:** Schedule-tab tree dump (this report's transcript), source lines
quoted above.

### WE-EQ-N2 (P3) — a toast now covers the tour nudge's buttons on Equipment
**Repro:** Equipment, tour nudge not dismissed → connect or disconnect any device.
**Actual:** the snackbar lands in exactly the band WD-EQ-5 reserved for the card.
At 1600x900 the toast (root y 956–1001) covers the card's action row (root y≈970),
hiding **Maybe Later** and **Start Tour** completely (`18-state.png`); at 1000x800
the same thing (`nb-win-2.png`). The two D fixes were made independently — one
reserved the bottom-right band for the nudge, the other lifted every snackbar into
it — and they collide on the one screen that opted in.
**Why it matters:** low stakes (toasts are transient) but it is the exact
"floating card covers a control" complaint WD-EQ-5 was raised to remove, now
inverted, and it reaches the nudge's only dismissal control.

### WE-EQ-N3 (P3) — the Dashboard's two primary actions are published as disabled panels
**Repro:** Dashboard with equipment connected → `tree`.
**Actual:** `panel: Image tonight [DISABLED]` and `panel: Sequencer [DISABLED]` —
not buttons, marked dead. Both are live: clicking `Sequencer` navigated straight to
the Sequencer (tree then shows Builder / Templates / Sequences / History).
Screen-reader users are told the dashboard's headline call-to-action is a disabled
non-control.
**Not a regression:** the same two lines are in Wave D's own dump
(`/tmp/ns-audit/shots/waveD-eq/tree-dash2.txt:19-20`); nobody filed them. Same
class as CON-47 / waveD-consistency NEW-C2, at the app's most prominent controls.

### WE-EQ-N4 (P4) — Equipment's Discovery collapse control is a focusable panel, reported disabled
`panel: 'Collapse'  states=['focusable','showing','visible']` → the harness prints
`[DISABLED]` because the node carries no enabled/sensitive state, yet clicking it
expands and collapses the Discovery list every time (used repeatedly in this run).
Third instance of the same class inside my cluster.

### WE-EQ-N5 (P4) — the status bar clips a device name into its neighbour at 1000 px
`resize 1000 800`, two devices connected (`27-statusbar-zoom.png`, 4x crop): the
mount entry renders `Simulate` fading mid-word into the thermometer icon of the
next item — no ellipsis, no `Mount` prefix, no state dot, and the items after it
still render. At 1600 px the same entry reads `Mount Simulated Mount •`.
**Not a regression:** the same fade is visible in Wave D's `29-equip-narrow2.png`
(`28-waveD-statusbar.png` is a crop of it) — pre-existing, previously unfiled.

### WE-EQ-N6 (P4) — the filter-wheel card truncates its device name at a wide window
Equipment at 1600x900 (`13-equip-again.png`, `30-dash-live.png`): the FILTER WHEEL
card's title reads `Simulated Filter ...` while the camera, mount and focuser cards
next to it show their full names in the same column width.

---

## Notes for the next verifier

* The AT-SPI walk drops the whole shell chrome (CON-61), so anything published only
  as a chrome semantics node is unverifiable from the tree — check it by clicking,
  not by grepping.
* `tree` was seen to return "no accessibility root" transiently right after a
  click; re-run before believing a node vanished.
* A window `resize` moves the window origin, which invalidates the `.coords.json`
  of every earlier screenshot — take a fresh `shot` before the next `click-img`.
