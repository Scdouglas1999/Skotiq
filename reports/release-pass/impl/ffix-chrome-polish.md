# F-fix — batch `chrome-polish`

Charter: WD-EQ-2a, CON-56, CON-62 (full), WE-EQ-N5 residual, WF-EQ-N1,
WF-EQ-N2, WF-EQ-N3, WE-SP-5 residual, NEW-C2/C3 remaining halves.
Evidence: `reports/release-pass/waveF-result.json`,
`reports/release-pass/gui/waveF-{equipment-chrome,settings-sky,science-collab}.md`,
the Wave F verdict in `RELEASE-PASS-2026-08-11.md`, and the E-fix log
`reports/release-pass/impl/efix-equipment-chrome-3.md` (WD-EQ-2a's reverted
shape).

Orientation: one `graphify query "equipment disconnect toast notification
template device_name friendlyNameFromDeviceId"`.

Every behaviour item has a test that was RED before the change and GREEN after;
where the Wave F refuter supplied a counter-input or a control experiment, the
test encodes that input rather than a convenient one.

---

## The two "two implementations, one runs" strikes in this batch

### WE-SP-5 — the reserve went into the scroll view standby does not use

The E-fix added `kFloatingPromptReservedHeight` to `DashboardScrollView`. Wave F
scrolled the standby dashboard to the hard bottom, dismissed the prompt at the
*identical* offset, and measured that **nothing moved** — max scroll was the
same with and without the prompt.

It could not have moved: `dashboard_screen.dart` renders
`Expanded(child: CockpitStandby(...))` on the standby branch, and
`CockpitStandby` owns its **own** `SingleChildScrollView`.
`DashboardScrollView` is the OTHER branch (the zone cockpit shown during a run).

* `cockpit_standby.dart` now watches `smartNightAutoPromptShowingProvider` and
  adds the same reserve to its own scroll view's bottom padding.
* `standby_prompt_reserve_test.dart` measures exactly what the refuter measured:
  max scroll extent WITH the prompt minus max scroll extent WITHOUT it. Before
  the fix that delta is `0.0` — the refuter's number, reproduced in a test.
  Verified red→green by reverting the one line and re-running.
* The old `floating_prompt_reserve_test.dart` is left alone: the zone cockpit
  really does use `DashboardScrollView`, so it pins a real surface. It was just
  never the surface in the report.

**Still open, disclosed:** the second surface Wave F found in the same class —
at 1100x900 the Planetarium Tour nudge is drawn over the open Layers drawer and
hides the Constellation art / Milky Way rows. That is a `skotiq_planetarium`
drawer, outside this batch's scope (only `time_control_panel.dart` was in it).

### WF-EQ-N2 — one inset declaration, two toast surfaces

`TransientBottomInset` is honoured by the SnackBar path only; the
`NotificationToastOverlay` — the surface that carries errors — had a hardcoded
`bottom: 56` and painted over the tour nudge it was supposed to clear.

* The overlay now reads the same notifier through a `ValueListenableBuilder`.
* The inset is measured window-relative while the overlay's `bottom` is relative
  to the shell's content Stack (which sits above the status bar), so it lifts
  *slightly further* than strictly required — deliberate: over-clearing is
  invisible, under-clearing is the defect. Recorded in the code comment.
* `notification_toast_bottom_inset_test.dart`: no declaration → usual place;
  240 px declared → the toast clears 240 px; released → back to the usual place.

---

## The rest

| Item | Fix | Test |
| --- | --- | --- |
| **WD-EQ-2a** | `event_classifier.dart` publishes `equipment.device_name`, resolved through `friendlyNameFromDeviceId` — the same resolver the run-dashboard feed uses, so a toast and the feed cannot name one device two ways. The default body template is now `${equipment.device_name} disconnected.` The name falls back down a chain (friendly name → device type → "A device") because some disconnect events carry no `device_id` at all, which is what produced "` disconnected.`". The device TYPE is deliberately not prefixed to the name ("Guider Built-in Multi-Star Guider disconnected."). | `disconnect_toast_device_name_test.dart` — the assertion is a PATTERN over the whole rendered body (`native:`/`ascom:`/`alpaca:`/`indi:`/`sim_x_1`), not an equality against one sentence, plus a source check that the disconnect arm of `_defaultBodyTemplate` never reaches for `equipment.device_id` again. |
| **CON-56** | `time_control_panel.dart:423/:459` → `Now` / `Tonight`. | `time_control_case_test.dart` scans EVERY button label the transport publishes and fails on any multi-letter all-caps word (acronym allowlist), so the next shouted label fails here too. `time_transport_semantics_test.dart` updated to the new names. |
| **CON-62 (a)** | Every ROW title on Help & Tutorials is sentence case — the register the rest of Settings uses, and the one that keeps "Capture your first light" identical to the wording the onboarding Next Steps card already uses for the same flow (retitling to Title Case would have needed an out-of-scope edit there). Section HEADERS stay Title Case, as app-wide. Index regenerated with `dart run tools/production/settings_search_index_gen.dart`; `--check` now passes, and it also swept up drift left by earlier batches in the `notifications` and `science` sections. | `help_tutorials_one_register_test.dart` — rendered titles + a source scan that allows Title Case ONLY on the four section headers. Plus an assertion on the generated index itself, so a stale index (a row unfindable by its visible name) fails. |
| **CON-62 (b)** | `_TutorialRow`'s button was filled-primary until the tour was completed, so five FILLED "Start" buttons rendered directly beneath five OUTLINE ones. All rows are outline now; completion is already published by the icon, the status line and the verb. | Same file: gathers every `SkotiqButton` on the page whose label is a run-verb and asserts ONE variant. |
| **WE-EQ-N5 residual** | The E-fix's premise ("the cap makes the strip fit a 1000 px bar") is false — the strip scrolls, and the pill at the cut was still sliced mid-word and dissolved by the fade. The strip now draws an explicit `…` at the cut, OUTSIDE the viewport and flush against it (inside, it would scroll away with the text it describes). The fade and the mark are also now driven by whether content is hidden **right now** (`pixels < maxScrollExtent`), not by whether the strip is scrollable at all — so at the end of the strip neither is drawn. | `status_bar_cut_marker_test.dart` drives the refuter's exact window (1000x800), asserts `maxScrollExtent > 0` (the premise falsified, in a test), asserts the mark exists and sits at the cut, and asserts it and the fade are BOTH gone once scrolled to the end. |
| **WF-EQ-N1** | Two causes. (1) The callers: both offending headers had the heading in a `Flexible` competing with a `Flexible` search box, so the row's free space split evenly and the toolbar kept its 250 px while the tab lost its name. The heading is now `Expanded` and the search box a fixed 250 px (the width its `maxWidth: 250` box reached at every desktop size anyway); the library header's `Spacer` — a third claimant — is gone, and the controls stay right-aligned. (2) The shared widget: `SequencerTabTitle` now SHRINKS its title to fit, down to a 16 px floor, before it ellipsises, and both title and subtitle carry a tooltip with the full text. | `sequencer_tab_title_width_test.dart`. **Method note, disclosed:** pumping the whole tab and measuring the painted title is not usable — widget tests render in a fixed-width test font whose glyphs are far wider than the real one (this repo's own measurement: a bar that fits 1400 real px needs ~1630 test px), so "did it fit 1000 px" cannot be asked of a widget test. The shared widget's shrink-before-cut IS asserted on the render tree (`didExceedMaxLines` + the resolved font size); the caller change is a source guard. Verified red→green by reverting `Expanded` to `Flexible`. |
| **WF-EQ-N3** | "…in the Scheduler queue below" → "…on this tab". True at a stacked width only; at 1600x900 the queue is the right-hand column, level with the card. | The existing `planner_copy_names_real_tabs_test.dart` gains a second guard: no user-visible string under `screens/planner` may point in a physical direction (`below`/`above`/`on the left`…), with `above/below the horizon` exempted as astronomy. **It found five more of the same defect**, all fixed: two in `_autopilot_preview_banner.dart` ("The Night Outlook below"), one in `_recommendation_tab.dart` ("Adjust filters below"), one in `progress_widgets.dart` ("Choose a project above"), one in `empty_state.dart` ("Press Start in the panel on the left" → "in the Unattended Autopilot panel"). |
| **NEW-C2 (Imaging)** | `panel: Overlays [DISABLED]` — PopupMenuButton's InkWell contributes a tap action but no role or enabled state, and the pill inside contributed a second named node. Now `MergeSemantics + Semantics(button, enabled, label: 'Overlays')` with the pill `ExcludeSemantics`'d (the tap sits above it, so it is unaffected). | `a11y_role_residuals_test.dart` — ONE node, named, button role, enabled state, tap action. |
| **NEW-C2 (palette)** | The palette tabs were role-less (`panel: Nodes / Tab 1 of 3`). TabBar does set `role: SemanticsRole.tab`, but on an ANCESTOR node; the node carrying the label is the merged one. `_tabLabel` now declares `button: true` alongside the `enabled`/`selected` WD-SEQ-N3 added. | `toolbox_tab_role_test.dart`. **Disclosed:** a source guard, because `_ToolboxPanel` is private to `SequencerScreen`; it asserts the ONE shared builder declares role + enabled + selected, and that all three tabs go through it. |
| **NEW-C3** | `panel: Frame Type` beside `button: Light` — label and value as two unassociated nodes. The CONTROL now carries both, as one merged node ("Frame Type Light", button role, tap action); the visible label text is excluded from semantics so it does not linger as a second, valueless node. The help affordance keeps its own node — merging the whole row would have swallowed it, which broke `panel_widgets_help_test` and told me so. | `a11y_role_residuals_test.dart` — asserts a node whose label contains BOTH the field and its value, and that no node is left carrying the bare field name. |

---

## Tests

New: `disconnect_toast_device_name_test.dart` (core),
`time_control_case_test.dart` (planetarium),
`help_tutorials_one_register_test.dart`, `status_bar_cut_marker_test.dart`,
`sequencer_tab_title_width_test.dart`, `toolbox_tab_role_test.dart`,
`notification_toast_bottom_inset_test.dart`, `standby_prompt_reserve_test.dart`,
`a11y_role_residuals_test.dart` (app).
Extended: `planner_copy_names_real_tabs_test.dart` (direction-word guard).
Updated for the renames: `time_transport_semantics_test.dart`,
`help_tutorials_replay_hub_test.dart`, `help_reset_progress_promise_test.dart`.

Green: `skotiq_core` `test/services/notification` + `test/utils` (229);
`skotiq_planetarium` time-transport suite (12); `skotiq_app`
`test/screens/imaging`, `test/screens/shell`, `test/widgets`,
`test/screens/dashboard`, `test/screens/settings`, `test/screens/sequencer`,
`test/screens/planner`. `flutter analyze lib test` on all three packages:
**0 errors, 0 new warnings** (the 4 unused-import warnings are in test files
this batch never touched).

Pre-existing, unrelated: the `captures_*` golden suite — the documented
Windows-captured-goldens-on-Linux problem. Proved rather than assumed: every
remaining failure in the runs above is a `Pixel test failed` in a `captures_*`
file (6 of 6 in dashboard+settings), and `test/screens/weather/
captures_landscape_test.dart` — a screen this batch never touched — fails at
45–48 %.

## Not done / disclosed

* The **planetarium tour nudge over the Layers drawer** (WE-SP-5's second
  surface): same class, different package, outside this batch's scope.
* `graphify update .` was NOT run: concurrent batches were editing the tree
  throughout (I twice hit a mid-edit `skotiq_core` that would not compile),
  and a regenerated graph would have raced them.

## Incident

`skotiq_core/lib/src/services/notification/notification_router.dart` and
`providers/sequence/sequence_progress.dart` were both mid-edit by other batches
while this one ran — three separate compile failures in files I had not touched,
each of which resolved on its own within a minute. My own edit to the router
survived intact (verified by grep, not assumed). No git writes were made.
