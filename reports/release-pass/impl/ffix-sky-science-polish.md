# F-fix batch: sky-science-polish

Terminal batch of the release pass. Evidence: `reports/release-pass/waveF-result.json`
(still_broken `D-2`; new_findings `WF-SS-N1..N4`, `WF-SN-N1..N4`, `WF-SCI-N1..N4`).

## Files claimed (this batch owns them for the wave)

- `packages/skotiq_app/lib/screens/planetarium/widgets/view_controls.dart` (D-2, WF-SS-N3)
- `packages/skotiq_app/lib/screens/planetarium/widgets/redesign/command_bar.dart` (WF-SS-N3 Tools)
- `packages/skotiq_app/lib/screens/settings/pairing_screen.dart` (WF-SS-N1)
- `packages/skotiq_app/lib/screens/shell/shell_navigation.dart` + `app_shell.dart` (WF-SS-N2)
- `packages/skotiq_app/lib/widgets/tutorial_overlay/content.dart` (WF-SS-N4)
- `packages/skotiq_ui/lib/src/components/skotiq_button.dart` (WF-SN-N4 / WF-SCI-N3)
- `packages/skotiq_ui/lib/src/widgets/phd2/guide_star_view.dart` (WF-SN-N3)
- `packages/skotiq_app/lib/screens/sequencer/widgets/preflight_validation_dialog/{action_widgets,section_builders}.dart` (WF-SCI-N3)
- `packages/skotiq_app/lib/screens/analytics/widgets/science_analytics_tab.dart` (WF-SCI-N1)
- `packages/skotiq_app/lib/screens/session_review/session_review_controller.dart` + `session_review_controller_parts/_helpers.dart` (WF-SCI-N2)
- `packages/skotiq_app/lib/screens/dashboard/widgets/standby/last_night_recap_card.dart` (WF-SCI-N4)
- `packages/skotiq_app/lib/screens/settings/widgets/remote_access_settings.dart` +
  `lib/router/app_router.dart` (WF-SS-N2)
- `native/skotiq_native/bridge/src/builtin_guider/{control,state,tests}.rs` (WF-SN-N1)
- `native/skotiq_native/bridge/src/api/plate_solve.rs` (WF-SN-N2)

(The two Rust files are outside the batch's Dart scope line but are where the two
solver/guider findings live; no other terminal batch was chartered with WF-SN-*.)

## Findings and fixes

Every item below has a failing-test-first record: the test was written against the
live evidence, run RED, then run GREEN after the fix. Where a refuter's counter-input
existed it is a second assertion in the same file.

### D-2 (final) + WF-SS-N3 — the projection cycler and Tools
Root cause: both are `PopupMenuButton`s, which D-3 never touched (it named
`CommandBarIconButton` from its tooltip). Two consequences from one shape:
Material's `Tooltip` published `panel: Projection: Stereographic` and never retired
it, and the `IconButton` the popup builds carries no name, so both dumped as
`button: `. The name had to go on the ICON (`Icon(semanticLabel:)`) — a parent
`Semantics(label:)`, even under `MergeSemantics`, lands beside the IconButton's own
container node and leaves the button anonymous (observed in the test: label present
AND two empty `button:` nodes). Material tooltips are now empty strings (Flutter
returns the child untouched, so no tooltip node exists) with the hover message on
`SkotiqTooltip`. Also covers the Render-quality popup, same widget family.
Test: `test/screens/planetarium/command_bar_named_controls_test.dart` — every button
in the bar has a non-empty name; no Material tooltip in the bar carries a message.

### WF-SS-N1 — Copy code at 1.15:1
`ButtonVariant.ghost` paints no fill until hover, so `textSecondary` sat straight on
the card's `primaryContainer`. Changed to the filled `primary` variant, which brings
its own background so the label's contrast no longer depends on the card behind it.
Test: third case in `pairing_card_semantics_test.dart` measures the ink against
whatever is actually behind it (button fill if opaque, else the card) ≥ 4.5:1.

### WF-SS-N2 — pairing traps the nav rail
Manage Pairing was `Navigator.push(MaterialPageRoute(...))` onto the shell's
navigator, so it was not on go_router's match list and a rail `go()` swapped the
routed child underneath it. Now a `GoRoute` under the same `ShellRoute`
(`/pairing`), entered with `context.push`. `go()` replaces the whole match list,
imperative entries included, and back is a router pop that lands on Remote Access.
Test: `test/router/pairing_route_rail_escape_test.dart` (rail escapes; back returns
to the opener; the app registers the route).
DISCLOSURE: the framework counter-input did NOT reproduce in a minimal harness — a
`Navigator.push`ed page in a `ShellRoute` was removed by a later `go()` in that
harness, so the live trap is not fully explained by that alone. The fix removes the
imperative push entirely, which covers both observed symptoms; that assertion was
dropped rather than left in as a claim I could not reproduce.

### WF-SS-N4 — tutorial card focusable-without-enabled
`Focus(autofocus: true)` over a `Semantics` with no enabled state → `[DISABLED]` on
a live overlay. Declared `container: true, enabled: true`.

### WF-SCI-N3 + WF-SN-N4 — disabled buttons announce enabled
The flags were already right in the widget tree; what reached the platform was a
node that still ADVERTISED `SemanticsAction.tap`, because `GestureDetector` keeps a
`TapGestureRecognizer` if ANY of onTapDown/onTapUp/onTapCancel/onTap is non-null and
`SkotiqButton` wired onTapDown unconditionally. All four are now dropped when
disabled. Pre-flight's own Start button additionally announces its reason via
`GatedAction.announce`, and its visible label is `ExcludeSemantics`d — without that
the node read "Start Anyway\nStart Anyway" (and would have read the reason then
contradicted it).
Tests: `skotiq_button_disabled_semantics_test.dart` (no tap action when
disabled) and `preflight_validation_dialog_test.dart` (blocked Start announces
"— unavailable: fix the 1 pre-flight error above first", disabled, no tap action).

### WF-SN-N1 — Auto Select reports crop coordinates
`find_star` and `get_lock_position` returned `snapshot.star_x/star_y`, which live
inside the 50 px crop cut one line earlier. Added
`GuideSnapshot::star_frame_position()` (crop origin + crop-local) and returned it
from both, so the "chose"/"locked" log lines and the operator banner agree and the
built-in guider matches PHD2's frame-coordinate contract.
Test: `builtin_guider::tests::reported_lock_position_is_in_frame_coordinates`, which
first asserts the two spaces really differ for its fixture.

### WF-SN-N2 — the coalescer let the race pick the leader
Added `SolvePreference::{Hinted,Blind}`. A blind caller that finds no in-flight
solve for the frame offers the lead for 150 ms (polled every 5 ms) before taking it;
a hinted caller registers immediately. The live pair arrived 4-11 ms apart, so the
hinted solve now always leads and the blind one takes its answer.
Tests: `a_hinted_caller_leads_even_when_the_blind_one_arrives_first` (one solver
runs, and it is the hinted one) and `a_lone_blind_caller_still_solves`.

### WF-SN-N3 — SNR 0.0 on a stopped loop
`GuideStarView` printed `snr.toStringAsFixed(1)` unconditionally. Now an em dash
below/at zero, matching the guiding screen's own "positive means measured" rule.

### WF-SCI-N1 — Session tab pins the previous night
`latestScienceSessionProvider` was a plain `FutureProvider`, computed once. It now
awaits `allSessionsProvider.future`, so it recomputes on every session-row write —
including the status/end-time update a finishing run makes, which is the moment the
answer changes. Verified discriminating: with the watch removed the new test fails.

### WF-SCI-N2 — Night Doctor verdict cached forever
`_loadNightReport` preferred any stored row. Now: `refresh()` FORCES a recompute
(and awaits it, so Refresh does not return while the new verdict is still being
written), and a stored report that predates a sub it claims to judge is recomputed
on sight — capped at one automatic recompute per screen visit so a report can't
rewrite itself on every smart-data load.
DISCLOSURE: a change that alters only GRADES (accept/reject) with no new frames
still needs Refresh. Hooking `setAccepted` was rejected because the cull rail's
lasso calls it per frame in a loop, which would write one report row per frame.

### WF-SCI-N4 — Open last run opened an empty builder
`context.go('/sequencer')` → the run's own `/session-review?session=<id>` when the
run has a session, `'/sequencer?tab=history'` when it does not (never the builder) —
the same resolution the Morning Report tile already uses. The session id is watched
during BUILD; read inside the tap handler the family provider is still
`AsyncLoading` and the first click always took the fallback.

## Tests (all RED before the fix, GREEN after)

| Item | Test |
| --- | --- |
| D-2, WF-SS-N3 | `skotiq_app/test/screens/planetarium/command_bar_named_controls_test.dart` |
| WF-SS-N1 | `skotiq_app/test/screens/settings/pairing_card_semantics_test.dart` (3rd case) |
| WF-SS-N2 | `skotiq_app/test/router/pairing_route_rail_escape_test.dart` |
| WF-SS-N4 | `skotiq_app/test/widgets/tutorial_card_semantics_test.dart` |
| WF-SN-N1 | `bridge::builtin_guider::tests::reported_lock_position_is_in_frame_coordinates` |
| WF-SN-N2 | `bridge::api::plate_solve::solve_coalescing_tests::{a_hinted_caller_leads_…, a_lone_blind_caller_still_solves}` |
| WF-SN-N3 | `skotiq_ui/test/guide_star_view_snr_honesty_test.dart` |
| WF-SN-N4, WF-SCI-N3 | `skotiq_ui/test/components/skotiq_button_disabled_semantics_test.dart`, `skotiq_app/test/screens/sequencer/preflight_validation_dialog_test.dart` |
| WF-SCI-N1 | `skotiq_app/test/screens/analytics/latest_science_session_freshness_test.dart` |
| WF-SCI-N2 | `skotiq_app/test/screens/session_review/night_report_recompute_test.dart` |
| WF-SCI-N4 | `skotiq_app/test/screens/dashboard/last_night_recap_open_run_test.dart` |

Suites run green: `skotiq_ui` (316), `skotiq_app` session_review (92), planetarium,
router, settings, widgets (302), analytics (except one golden capture, below),
sequencer pre-flight (13); `cargo test -p skotiq_bridge --lib` 558 passed / 0 failed.

## Test-run notes

- Golden CAPTURE tests fail across screens: dashboard (4 cases, 40-44% pixel diff),
  analytics (2) and settings (2, 6.3%) `captures_landscape_test.dart`. A combined
  analytics + widgets + settings + pre-flight run was 1070 passed / 4 failed, and
  all 4 were those captures. Not this batch: every capture includes the shell, and
  `screens/shell/widgets/status_bar.dart` + `dashboard/widgets/cockpit_standby.dart`
  are being edited concurrently by other batches. Nothing this batch changed on those
  screens moves a pixel (a destination string and a provider dependency).
- Two `runColorCalibration` cases in `session_review_controller_test.dart` failed
  mid-batch because `refresh()`'s recompute outlived the test's database; fixed by
  awaiting the recompute rather than by weakening the test. All 92 session-review
  tests pass.
- `loadSmartData` gained a named parameter, so two test fakes that override it were
  updated (`seeded_review_fixture.dart`, `narrative_integrate_blocked_test.dart`).
