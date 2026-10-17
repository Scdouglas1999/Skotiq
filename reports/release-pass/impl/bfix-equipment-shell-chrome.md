# bfix — equipment-shell-chrome

Batch: EQP-1, EQP-10, EQP-11, EQP-12, EQP-13, EQP-18..23, CON-44, CON-60, CON-61.

## EQP-1 — epoch-zero heartbeats reported OK (P1)
Root cause: only `CameraStateNotifier` records `lastSuccessfulCommunication`; every
other device reaches `EquipmentHealthService.buildSnapshots` with null, which became
`lastSuccessfulTimestampMs: 0`, and the chip rendered epoch zero as an age
("OK - 20676d ago", green dot).
Fix: `_DeviceHeartbeatChip._statusLine` treats a non-positive timestamp as UNKNOWN
("OK - last contact unknown" / "Unhealthy - last contact unknown"); the chip also now
prefers the snapshot's device label over an id-derived name.
Test: `test/screens/equipment/equipment_health_panel_test.dart` (2 of 3 failed before).

## EQP-11 — a never-connected device degrades health, raw id in copy (P2)
Fix (a): `deviceHealthSnapshotsProvider` only admits devices whose connection state is
`connected`. A refused connect leaves the id in the notifier, which used to enter the
heartbeat list as unhealthy and cost 25 points. Genuine mid-session drops still arrive
through the USB disconnect log that `buildSnapshots` folds in.
Fix (b): the "Unhealthy devices detected" insight prints `displayName`, not `deviceId`.
Test: `packages/skotiq_core/test/providers/device_health_snapshots_test.dart` (3/3
failed before).
Scope note: (b) touches `skotiq_core/lib/src/services/equipment_health_service.dart`
(one identifier) — the device-health service behind the in-scope provider.

## EQP-10 — three device counts on one screen (P1)
Root cause: the shell chip tallied only the six slots the profile editor lists first, so
a connected dome + weather station were invisible ("4 connected" against the Equipment
header's "6 connected · 6 unsaved").
Fix: `EquipmentStatusIndicator` builds ONE `_DeviceSlot` list covering all eleven device
types and derives both the count and the dropdown rows from it.
Test: `test/widgets/equipment_status_indicator_test.dart` (proved failing by restoring
the HEAD file and re-running: "3 connected" and "Simulated Dome" both absent).

## CON-44 — the in-flow tour nudge shortens every screen (P2)
Fix: `ContextualTourPrompt.reserveSpaceForCard` now defaults to false — the coach mark
floats like every other overlay.
Tests: `test/widgets/contextual_tour_prompt_layout_test.dart` replaces
`contextual_tour_prompt_reserves_space_test.dart`, which asserted the opposite invariant
(`childRect.height < fullHeight`) and is the proof the new tests fail at HEAD.

## CON-60 — Connection Status dialog clipped at the bottom (P2)
Fix: `_showDetails` uses `showAdaptiveModal` (centred dialog on desktop, sheet on a
phone) instead of a bare bottom sheet welded to the edge opposite the title bar that
opens it; the sheet body lost its top-rounded chrome and gained an explicit Close, which
in the local-desktop case was the only control it had.

## CON-61 — title bar absent from the a11y tree (P2)
Fix: `_TitleBarButton` and `_WindowButton` publish `Semantics(button: true, label: ...)`
(an InkWell contributes an action but no role/name; a Tooltip contributes a tooltip, not
a label). Test: `test/screens/shell/title_bar_test.dart`.
NOT fixed — the dead person icon: `/settings?section=equipment-profiles` is read only by
`SettingsScreen.initState`, so navigating there from inside Settings reuses the existing
State and nothing happens. Same for ~8 other in-Settings `?section=` links. The fix is a
`didUpdateWidget` in `settings_screen.dart` (or a section-keyed page in `app_router.dart`)
— both outside this batch's scope. Recorded as blocked.

## EQP-12 — the chrome bell opens a science feed (P2)
Fix: `TransientAlertBadge` wears `LucideIcons.radio` (the glyph its own popup header
uses), carries a tooltip and a semantics label naming transient alerts. A bell in the
window chrome promises a notification centre.

## EQP-13 — Weather gates hardware sensors on the observing location (P2)
Fix: the no-location state now renders the Hardware Sensors card and the Weather Safety
card under the "Location Not Configured" card. Only the radar needs a location.

## EQP-18 — Edit Dashboard edits a dashboard the user cannot see (P2)
Fix: `dashboardStandbyProvider` (new, in `dashboard_layout_provider.dart`) is the single
standby predicate. `_isEditing` no longer suppresses standby, and
`DashboardHeaderActions` disables Edit while the briefing is showing, with the reason in
its tooltip. Test: `test/screens/dashboard/dashboard_header_actions_test.dart`.

## EQP-19 — Glance mode is a dead toggle (P2)
Glance mode only re-sizes the live session readouts, so on an idle dashboard nothing
changed. Fix: the toggle acknowledges what it did (snackbar) and its tooltip names the
effect instead of repeating its own state.

## EQP-20 / EQP-22 — debug + heartbeat plumbing in the Recent Events feed (P2/P3)
Fix: `isUserFacingRunEvent` filters debug-level system notifications and heartbeat
start/stop out of `runDashboardRecentEventsProvider`. Test:
`test/screens/dashboard/recent_events_feed_test.dart` (the provider-level case fails at
HEAD).
Scope note: `screens/sequencer/widgets/run_dashboard/run_dashboard_providers.dart` backs
the dashboard's RECENT EVENTS tile; targeted edit, one helper + one `.where`.

## EQP-21 / EQP-22 — toast lag and double connect (P2/P3)
Fixes in `discovery_panel.dart` / `device_row_item.dart`:
- device-state toasts clear the queue first, so the newest statement wins;
- disconnect copy matches connect ("Disconnected <device name>");
- `_handleConnect` refuses when the row's device is already connected, which is the
  second `Connecting to Camera device` 190 ms after the first.

## EQP-23 — silent process death (P2) — BLOCKED
The fix (a last-gasp shutdown record + device safing on a fatal render error) belongs in
the desktop entry point (`apps/desktop/lib/main.dart` / the Linux runner), outside this
batch's scope paths. Nothing in `packages/skotiq_app` can install the process-level
handler honestly.

## Existing tests adjusted (contract changes, not test-fixing)

- `test/screens/dashboard/dashboard_screen_test.dart` (edit_button_toggles_to_done) and
  `test/screens/dashboard/dashboard_widget_picker_dialog_test.dart` now override
  `dashboardStandbyProvider` to false. Both drive the Edit toggle on a profile with
  nothing connected, which EQP-18 makes a refused action; the toggle itself is what
  they are about.
- `test/screens/weather/weather_screen_responsive_test.dart` disposes the tree and the
  container inside the test body, then pumps one zero-duration frame (drift schedules a
  close timer when its query streams go). Do NOT `await database.close()` there — under
  the test binding's fake async that never completes and the suite hangs. Showing the weather-safety card without a location
  brings up `WeatherSafetyNotifier`, whose 5-minute evaluation timer is cancelled on
  provider dispose — and the harness tearDown runs after the binding's pending-timer
  check. Any test that pumps a LOCATED weather screen already had this shape.

## Failures confirmed NOT caused by this batch

`test/screens/{dashboard,equipment,weather}/captures_landscape_test.dart` (10 golden
comparisons) fail on this tree right now. Proved independent of CON-44 by restoring
`contextual_tour_prompt.dart` from HEAD and re-running the equipment captures: still
3/3 failing. Concurrent-agent edits or a pre-existing Linux golden drift; not re-based.


## Verification (final)

- new/updated suites green: equipment_health_panel, equipment_status_indicator,
  contextual_tour_prompt_layout (+ the existing guided-flow test), title_bar,
  remote_connection_indicator, recent_events_feed, dashboard_header_actions,
  glance_mode_toggle, discovery_toast_currency, weather_location_gate,
  weather_screen_responsive, device_health_snapshots (core).
- `flutter test test/screens/dashboard` — 172 passed, 4 failed, all four the golden
  `captures_landscape_test`; the same four fail with `contextual_tour_prompt.dart`
  restored from HEAD, so they are not this batch's.
- `skotiq_core`: device_health_snapshots + preflight_rules + the whole services
  suite — 2797 passed.
