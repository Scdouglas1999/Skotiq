# D-fix batch: equipment-shell-2

Source of truth for every item: `reports/release-pass/waveD-result.json` +
`reports/release-pass/gui/waveD-equipment-shell.md` +
`reports/release-pass/gui/waveD-consistency.md`.
Rules honoured: no git writes, no melos, no repo-wide format, no generated
files, no FRB regeneration. GUI harness NOT launched and the bundle NOT
rebuilt (per batch instructions), so every claim below is backed by a test in
the repo, by the live Wave D evidence, or by a source read that is quoted.

---

## WD-EQ-1 (P2) — heartbeats had no timestamp for 5 of 6 device types — FIXED

**Root cause.** `deviceHealthSnapshotsProvider` built its descriptor list two
ways: the camera got `lastSuccessfulCommunication: camera.lastSuccessfulCommunication`,
and every other device went through a local `addBasic(...)` that passed
`deviceId`, `deviceLabel` and `isHealthy` **and nothing else**. So
`DeviceHealthSnapshot.lastSuccessfulTimestampMs` was 0 for the mount, focuser,
filter wheel, rotator, guider, dome, weather station and safety monitor, and
`equipment_health_panel.dart:549` renders `<= 0` as
"OK - last contact unknown". EQP-1 fixed the *rendering* of that zero (it used
to print `20676d ago`); the timestamp itself was never obtained.

**Why an event listener could not fix it.** The Rust monitor only publishes
`HeartbeatStatusChanged` on a *transition*
(`native/skotiq_native/bridge/src/device_manager/heartbeat.rs:471` —
inside `if consecutive_failures > 0`, i.e. only on recovery — plus the degraded
and disconnected branches). A steadily healthy device emits nothing, so the
existing `deviceHeartbeatHealthProvider` can never learn "it answered again".
The value *is* recorded natively (`heartbeat.rs:492`) and is already exposed:
`api_get_device_health` → `DeviceBackend.getDeviceHealth(deviceId)` →
`(lastSuccessfulCommunicationMs, isHealthy)`, implemented for FFI, network and
disconnected backends — **and called by nothing in the app**.

**Fix.** New `packages/skotiq_core/lib/src/providers/device_last_contact_provider.dart`:
`DeviceLastContactNotifier` polls `getDeviceHealth` for the currently
connected devices (10 s), stores `DeviceContact{lastContact, isResponsive}`,
drops records for devices that disconnect, keeps the previous record when a
probe throws, and never stores a zero timestamp (a device that has never
answered must keep saying "unknown", not claim the epoch).
`equipment_health_provider.dart` was split so the connected set is its own
provider (`connectedDeviceDescriptorsProvider`) that the poller follows, and
the snapshot provider merges the contact record in — including
`isHealthy && contact.isResponsive`, so a device the backend considers
unresponsive stops contributing "100 - Excellent".

**Tests** (`packages/skotiq_core/test/providers/device_last_contact_test.dart`, 7):
contact recorded per device; zero timestamp stays absent; untracking prunes;
a throwing probe preserves the last record; **a connected mount's snapshot
carries the backend timestamp** (this is the regression: 0 at HEAD); an
unresponsive mount is not reported healthy; the poller follows connect and
disconnect.

---

## CON-61 (P2) — title bar + nav rail absent from the AT-SPI tree — PARTIALLY FIXED, rest is below Flutter

**What is fixed in-widget.** `side_navigation.dart`'s `_CollapseButton` was a
bare `MouseRegion → GestureDetector` — a tap action with no role and no name,
and when the rail is collapsed there is no label text under the glyph either.
It now carries `Semantics(button: true, enabled: true, label: 'Collapse
navigation' / 'Expand navigation')`.

**What is NOT fixable here, with proof.** The rest of the chrome already
publishes correct semantics, and I proved it against the **compiled
SemanticsNode tree** (not widget properties) in the exact arrangement the
desktop shell builds — title bar above, rail beside the content:
`packages/skotiq_app/test/screens/shell/shell_chrome_semantics_test.dart`
asserts `Settings`, `Equipment Profiles`, `Close window`, a `Dashboard`
destination, `Collapse navigation` and the routed content are all present.
All four tests pass. `NavItem` (skotiq_ui) has carried
`Semantics(enabled/button/selected/label)` all along, so waveD-consistency's
note that "`side_navigation.dart` contains no `Semantics` at all" is true of
the file and false of the rail's destinations.

So the loss is **below Flutter**: the app hands the engine a semantics tree
containing these nodes and the GTK/AT-SPI bridge does not expose them, while
it does expose the status bar (same `Column`, sibling of the title bar), the
routed content and the alert popup. That is an engine-level bridge concern
(`fl_accessible_node` / `fl_view_accessible`), not something this repo can
patch. Recorded as blocked, not as fixed.

Note for the next verifier: the harness's `_norm` behaviour matters here —
Flutter merges a labelled ancestor with the `Text` inside it into one node
(`"Collapse navigation\nCollapse"`), so an exact-match grep for a control's
word can miss a node that is present.

---

## WD-EQ-2 (P3) — raw device ids in user-facing copy — HALF FIXED, half out of scope

* **(b) Dashboard RECENT EVENTS `Camera · sim_camera_1` — FIXED.** The feed
  row's subtitle comes from the bridge's `_equipmentDetail`
  (`packages/skotiq_bridge/lib/src/event_display.dart:167`), which is
  outside this batch's scope, so the substitution is done where the feed model
  is built: `_toDashboardEvent` in
  `screens/sequencer/widgets/run_dashboard/run_dashboard_providers.dart` now
  passes the detail through `_humanizeDeviceIds`, replacing
  `SkotiqEvent.deviceId` with `friendlyNameFromDeviceId(...)`.
* **(a) the disconnect toast — BLOCKED (scope).** The string is
  `'${equipment.device_type} ${equipment.device_id} disconnected.'`, the
  default body template at
  `packages/skotiq_core/lib/src/services/notification/notification_router.dart:598`,
  filled from `event_classifier.dart:256-259`. Both are in
  `skotiq_core/lib/src/services/**`, which this batch may not edit (its
  core scope is `providers/**`, heartbeat state only). The fix is to carry a
  device *name* in the substitution map and template it instead of the id.

---

## WD-EQ-3 (P3) — three toasts for one failed connect — BLOCKED (scope)

The duplicate pair is raised through the notification pipeline
(`skotiq_core/lib/src/services/notification/**` +
`ui_notification_provider.dart`), and the third ("Equipment disconnected") is
the same `event_classifier` path as WD-EQ-2(a) firing for a device that never
connected. All three sites are in core `services/`, outside this batch's
scope. Nothing in `skotiq_app/lib/screens/**` raises them, so there was no
in-scope emission site to dedupe.

---

## WD-EQ-3b (P3) — the person icon goes dead once you move within Settings — FIXED

**Root cause.** `/settings` is a keyless page: navigating to
`/settings?section=equipment-profiles` while Settings is open UPDATES the
existing element with an identical `initialSection`, and
`didUpdateWidget` returned early on `widget.initialSection ==
oldWidget.initialSection`. From inside the State there is no way to tell that
repeat navigation from an ordinary parent rebuild — so once the operator
picked any other section by hand, the icon moved nothing.

**Fix.** `SettingsSectionRequest` (in `settings_screen.dart`): a serial that
chrome bumps on every click. The title bar's profile button raises it
immediately before its `context.go`, and `_SettingsScreenState` listens and
applies `_showSection(...)`. A rebuild never bumps the serial, so the
"don't move the operator on a plain rebuild" property that CON-61b's fix was
protecting is preserved. `didUpdateWidget` still handles the changed-key case
and now shares one `_showSection` implementation with the listener.

---

## WD-EQ-4 (P3) — Edit Dashboard silently inert in standby — FIXED

`dashboard_header_actions.dart` already disabled the button
(`onPressed: canEdit ? onToggleEdit : null`, and `SkotiqButton` publishes
`enabled: !isDisabled` at `skotiq_button.dart:196` with
`isDisabled = onPressed == null`), but the *reason* lived only in a `Tooltip`,
which is pointer-only. The refusal reason is now one named constant
(`standbyEditRefusalReason`) used as the tooltip AND as a semantics `hint`, so
a keyboard or screen-reader user is told why.
Test: `test/screens/dashboard/edit_dashboard_refusal_test.dart` asserts the
compiled node has `hasEnabledState`, not `isEnabled`, and a hint naming the
reason; and that a live dashboard still gets an enabled button that toggles.

Caveat recorded honestly: I could not reproduce Wave D's claim that the live
tree reported this node **without** `[DISABLED]` — at the widget layer it is
disabled at HEAD and after the fix. If it still reports enabled on the running
bundle, that points at the same bridge-level problem as CON-61.

---

## WD-EQ-5 (P3) — the floating tour nudge covers controls — FIXED (Equipment only)

`ContextualTourPrompt` already exposes `reserveSpaceForCard` precisely for "a
host whose bottom-right corner carries live, non-scrollable controls", and
Equipment is that host (Scan All / Collapse at 1000x800, the STATUS rail's
blockers block at 1600x900). `equipment_screen.dart` opts in; every other
screen keeps CON-44's floating default, so the 147 px band that CON-44 removed
does not come back anywhere else.
Test added to `test/widgets/contextual_tour_prompt_layout_test.dart`: with the
opt-in, the card's rect does not overlap the host's content.

---

## WD-EQ-6 (P3) — snackbars cover the whole status bar — FIXED

`utils/snackbar_helper.dart` gave a snackbar a margin only when the *screen*
declared a bottom bar; nothing accounted for the shell's own 36 dp status bar,
which sits inside the same Scaffold the floating snackbar anchors to. Every
routine toast was therefore full-bleed across the window bottom, over the
connection chips, save path and clock.
Now: lift = max(declared inset, `ShellChromeMetrics.contentStackBottomChromeHeight`
+ safe area), and a 520 px cap that right-aligns the bar on a wide window
(matching the toast overlay's own column) while keeping the near-full-width
bar on a narrow one. Margins are only emitted when the resolved behaviour is
floating, so a host without the app theme still gets a snackbar instead of the
framework's margin assertion.
Tests: `test/utils/snackbar_placement_test.dart` (4, including a measured
**baseline** test that reproduces the defect: 1570 px wide, bottom 10 px off
the window edge). One existing assertion in
`test/utils/transient_bottom_inset_test.dart` encoded "no lift by default" and
was updated to the new contract.

**Scope note:** `lib/utils/snackbar_helper.dart` is one directory outside the
listed SCOPE globs (`screens/**`, `widgets/**`). It is the only place the
geometry lives — the alternative is `skotiq_ui`'s theme, which is further
out — so the fix was made there and is flagged here rather than left undone.

---

## WD-EQ-7 (P4) — two heartbeat starts per connect — FALSE POSITIVE (as stated)

The finding's stated risk is "whether the second start replaces the first or
stacks a second timer is not visible from the log". It replaces:
`DeviceManager::start_heartbeat_with_config` calls
`self.stop_heartbeat(device_id).await?` — "Stop any existing heartbeat for this
device" — before spawning
(`native/skotiq_native/bridge/src/device_manager/heartbeat.rs:307`). So at
most one heartbeat task per device exists, and the disconnect's single stop is
symmetric with the single live task. What remains is a redundant Dart-side
start (`DeviceHeartbeatRouter.start`, core `services/`) duplicating the native
auto-start — log noise only, and out of this batch's scope.

---

## Consistency backlog

Fixed:

* **CON-46** — `analytics_screen/equipment_stats.dart`: Accepted Integration is
  a SUM, and printing "No data" for it beside "Total Exposures 0" is what made
  the two tokens look arbitrary. It now prints `0s`, and the rule is stated in
  the code: counts and sums of nothing are numbers, means of nothing are
  "No data".
* **CON-53** — `planner/widgets/scheduler_tab_content/decision_panel.dart`: the
  Unattended Autopilot card lives ON Plan Tonight and told the reader to "use
  Plan Tonight instead". It now names the actual alternative, the Target Queue
  tab.
* **CON-54** — same file: "No tick scheduled." → "Not evaluating targets —
  start it to begin."; "next eval in …" → "Next target check in …";
  "evaluating targets every 60s" → a sentence about what it does, without the
  scheduler's internal period.
* **CON-63** (half) — `widgets/remote_connection_indicator.dart`: the compact
  title-bar indicator painted a filled status chip in the RESTING
  "not connected to a server" state, which is the normal state of a local
  install, so it read as the one selected control in a row of three plain icon
  buttons. The chip is now drawn only when the status is meaningful
  (connected / connecting / offline / error).

Not done, with the reason:

* **CON-63** (glyph half) — the icon is `LucideIcons.wifiOff` for
  `notConnected`, which is the correct semantic choice; the audit read it as a
  crossed-out eye at 2x. If the rendered glyph really is an eye, that is an
  icon-font codepoint mismatch in the `lucide_icons` package rather than a
  wrong constant, and settling it needs the running app (not launched here).
* **CON-49** (dead Back on onboarding step 1) — the wizard is not under any
  SCOPE directory.
* **CON-51 / CON-52 / CON-58 / CON-59 / CON-62** — in-scope but not reached in
  this batch; they are copy/treatment edits with no behavioural risk. CON-59's
  "~1 hr 15 min" / "~3 min capture" strings are not produced anywhere in
  `skotiq_app/lib` (grep is clean), so the starter estimates are built
  outside this package and the fix site has to be located first.
* **CON-55** — the Framing half (`panel: Open Settings`) is
  `screens/framing/**`, outside SCOPE.
* **CON-56** — `NOW` / `TONIGHT` are the planetarium HUD's, `screens/planetarium/**`,
  outside SCOPE.

---

## Files touched

Core: `lib/src/providers/device_last_contact_provider.dart` (new),
`lib/src/providers/equipment_health_provider.dart`, plus one export line each
in `skotiq_core.dart` and `skotiq_core_providers.dart`.

App: `screens/shell/widgets/side_navigation.dart`,
`screens/shell/widgets/title_bar.dart`, `screens/settings/settings_screen.dart`,
`screens/dashboard/widgets/dashboard_header_actions.dart`,
`screens/equipment/equipment_screen.dart`,
`screens/analytics/analytics_screen/equipment_stats.dart`,
`screens/planner/widgets/scheduler_tab_content/decision_panel.dart`,
`screens/sequencer/widgets/run_dashboard/run_dashboard_providers.dart`,
`widgets/remote_connection_indicator.dart`, `utils/snackbar_helper.dart`.

Tests: 4 new files + 2 existing files extended/updated (listed per item above).

## Environment note

The working tree was NOT green throughout: other D-fix agents were mid-edit in
`skotiq_core` (`SchedulerSequenceSink.ownsRun` missing from its
implementation) and in `skotiq_planetarium` at several points, which made
`flutter test` in `skotiq_app` and `skotiq_core` fail to compile for
reasons unrelated to this batch. Every test result quoted above was taken in a
window where the tree compiled.

## Verification runs (all on this working tree)

New/extended, all green:
* `skotiq_core`: `test/providers/device_last_contact_test.dart` — 7/7.
* `skotiq_app`: `test/screens/shell/shell_chrome_semantics_test.dart` 4/4;
  `test/utils/snackbar_placement_test.dart` 4/4;
  `test/screens/dashboard/edit_dashboard_refusal_test.dart` 2/2;
  `test/screens/settings/settings_section_route_update_test.dart` 5/5 (2 new);
  `test/widgets/contextual_tour_prompt_layout_test.dart` (1 new) green.

Regression sweeps:
* `skotiq_core`: `test/providers` + `test/services/device_disconnect_test.dart`
  — **1585/1585 pass**.
* `skotiq_app`: `test/screens/shell`, `test/screens/equipment`,
  `test/screens/dashboard`, `test/utils`, `test/screens/sequencer/run_dashboard`,
  `test/screens/planner` — the only failures are `captures_*.dart`
  golden-image tests and three pre-existing `equipment_stats*` failures.

Both were proved not-mine by flipping the change and re-running:
* `equipment/captures_landscape_test.dart` fails with byte-identical diffs
  (21.61% / 24.78% / 26.82%) both with and without `reserveSpaceForCard: true`.
  `dashboard/captures_landscape_test.dart` fails at 40-43% with no layout change
  from this batch at all — the known Windows-captured-golden-on-Linux class.
* `analytics/equipment_stats*` fails identically with `_formatIntegration`
  returning `'0s'` and returning `'No data'`; its failure is
  "Found 0 widgets with text 'Session-based equipment totals are unavailable.'",
  which this batch does not touch.
