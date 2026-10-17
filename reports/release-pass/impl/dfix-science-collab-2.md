# D-fix batch: science-collab-2

Wave D harvest for the Analytics / Science / Session Review / Mosaic /
Collaborative-Sky / Diagnostics surfaces. Evidence read first from
`reports/release-pass/waveD-result.json` and the three cluster narratives
(`waveD-science-review.md`, `waveD-collab-catalogs.md`, `waveD-consistency.md`).

Scope allowed: `packages/skotiq_app/lib/screens/{analytics,science,
session_review,mosaic,collaborative_sky,suggestions,transients,diagnostics}/**`
plus `packages/skotiq_ui/lib/src/components/skotiq_dropdown.dart`
(selected-state only), plus the owning packages' test directories.

---

## Fixed

### WD-SCI-N1 (P2) — quick captures unreachable once a run exists

Root cause: both pickers derived the night under review from a single
`int? _selectedSessionId` where `null` meant "auto" — follow the live session,
else the newest on record. There was no value that *said* quick captures, so the
first completed run won the auto-pick permanently and the 37 loose frames (with
their charts, captured-image grid, photometry and field-quality products) had no
route back. Diagnostics already had its own sentinel; SCI-46 landed in that one
picker of three.

- New `lib/screens/analytics/quick_capture_selection.dart` holds the sentinel
  (`kQuickCaptureSessionSelection = -1`) and the label
  (`kQuickCaptureSessionLabel = 'Quick captures (no session)'`) that all three
  pickers now share. Diagnostics' private `_kQuickCaptureSessionId` and its
  label are aliased to them so the three cannot drift again.
- `analytics_screen/session_tab.dart`: `quickCapturesPinned` outranks the
  auto-pick; the fallback watch was hoisted out of the `??` chain so it is
  unconditional; `standaloneImagesProvider` is watched unconditionally and also
  decides whether the entry is offered; the picker gained `offerQuickCaptures`
  and a leading menu entry.
- `widgets/science_analytics_tab.dart` + `.../tab_sections.dart`: same three
  changes for the "Analysing" picker, and the science-data loading/error branch
  now renders the session bar too (dropping it meant a slow or failing science
  query took the only way out of that session with it).

Pin: `test/screens/analytics/quick_capture_reachable_test.dart` — three cases,
built on the exact live state (37 standalone frames + one completed run +
`latestScienceSessionProvider` resolving to that run). Failure at HEAD was
reproduced by disabling the new menu entry: `Found 0 widgets with text "Quick
captures (no session)"`.

### WD-SCI-N2 + NEW-C2 (P3, in-scope half) — tap targets published as disabled panels

`_JumpChip` (Photometry / Field Quality / Anomalies / Export report) published a
tap action with no role and no enabled flag. Wrapped in
`Semantics(button: true, enabled: true, …)`, the pattern CON-47's fix used.

The class was then swept across all eight scoped directories: 24 further
`InkWell` / `GestureDetector` sites gained a role and an enabled state, and where
the site already carried a selection (`selected` / `isSelected` / `active`) it
now publishes that too. Two sites are deliberately exempt because they are drags,
not taps: the sub-cull lasso and the science surface-explorer orbit.

Pin: `test/screens/analytics/scoped_tap_role_sweep_test.dart` — a source sweep
over the eight directories. It listed 26 offenders before the fix.

### WD-SCI-N5 (P3) — Night Doctor 100/100 over four POOR subs

The two panels read different inputs: the verdict is a session-level degradation
score, the badges come from `FrameQualityAssessmentService` per frame. Scoring
lives in `skotiq_core` (out of scope), so the reconciliation was made at the
view layer, where both inputs are already in hand: `narrative_view.dart` now
reads the same grader the Workbench reads and, when a *clean graded* verdict with
zero findings sits over POOR-graded subs, states the disagreement under the
verdict instead of leaving the operator to find it on the other tab.

Pin: `test/screens/session_review/graded_subs_disagreement_test.dart` — four
cases over the public pure `gradedSubsDisagreementMessage`, including the three
states that must stay silent (good subs, a verdict with findings, an ungraded
night).

### WD-COL-N1 (P2) — mosaic list still pre-create after Back

`mosaicProjectsListProvider` is `autoDispose`, but the list screen stays mounted
under the pushed project route, so it is never disposed and never re-runs.
`mosaic_projects_list_screen.dart` now invalidates it when the wizard dialog
closes (both "New mosaic" buttons go through one `_newMosaic` helper) and when a
pushed project screen pops (`_ProjectRow.onReturn`).

### CON-45 (P3) — five empty-state dialects on one screen

New `lib/screens/analytics/widgets/analytics_empty_state.dart`: icon, title as a
label, body as exactly one sentence, and an action. The punctuation rule lives in
the widget (title's trailing stop stripped, body's supplied) so a translation
cannot reintroduce the split — the History and Projects strings stay localised.
Wired into Session, History, Projects, Equipment Stats (which had no empty state
at all — a fresh profile got a grid of zeroes) and Diagnostics.

### CON-48 (P3) — the one tab with an H1 and a 95-word essay

`DiagnosticsTabContent` gained `showTitle` (false in the Analytics tab, true on
the standalone `/diagnostics` shell, which has nothing else naming the page). The
paragraph is now one line; the scope contrast and the when-to-come-here advice
moved into the guide the "Learn more" chip already opens.

Pin for both: `test/screens/analytics/analytics_empty_state_test.dart`.

### COL2-13 (refutation) — auto-queue threshold

Wave D disagreed with B-fix, and both were partly right. The slider, its
`<= x.x` readout and the "fainter than the display threshold" warning all exist
at HEAD — but only while the switch is ON. With it off, the row still asserted
"brighter than mag 10" with no visible control, which is the state Wave D drove
and the state in which dragging Magnitude Threshold to 8.0 left the app claiming
it auto-queues objects two magnitudes fainter than the ones it will show. The
subtitle is now conditional: off states the behaviour, on states the number
beside the slider that owns it.

### NEW-C4 (P4) — no dropdown menu marks its current option

`SkotiqDropdown` did already set `selected:` on the chosen entry — but
AT-SPI carries that as SELECTED, which no menu consumer reads and which never
appeared in a live tree dump. A menu of mutually exclusive options is a radio
group and CHECKED is the state that role publishes, so each entry now carries
`checked: item == value` alongside `selected:`.

Pin: extended `packages/skotiq_ui/test/components/interactive_semantics_test.dart`.
Verified failing at HEAD ("Light offers no checked state, so nothing in the menu
says which option is in force") and passing after.

---

## Refuted / not a defect here

### COL2-3 — Deep-Star "Download" with an empty tileset URL

Wave D's evidence stands, but the card is
`lib/screens/settings/widgets/deep_star_catalog_card.dart` — outside this
batch's scope. Recorded blocked, not fixed.

---

## Blocked — out of scope

| ID | Where the fix has to land | Note |
| --- | --- | --- |
| WD-SCI-N3 | `lib/screens/sequencer/**` (pre-flight validation dialog) | "Start Anyway" needs the same `Semantics(button:…)` treatment as the sweep applied here. |
| WD-SCI-N4 | `packages/skotiq_ui/lib/src/components/adaptive_tab_bar.dart` | The chevrons are `Positioned` inside a `Stack` in the shared component; the scope grant for `skotiq_ui` was the dropdown's selected state only. |
| WD-COL-N2 | `lib/screens/sequencer/widgets/mosaic_wizard_dialog.dart` | Gated footer buttons must be disabled with the inline reason. |
| WD-COL-N3 | `lib/screens/sequencer/widgets/mosaic_wizard_dialog/config_controls.dart` | The auto-fill that swallows keystrokes in the second panel-dimension field. |
| WD-COL-N4 | shared shell status bar | Clips "Mou" at 900 px. |
| COL2-3 | `lib/screens/settings/widgets/deep_star_catalog_card.dart` | See above. |
| NEW-C2 (named sites) | `lib/screens/sequencer`, `lib/screens/planetarium`, `lib/screens/imaging` | The four surfaces Wave D named are all outside this batch; the class is closed inside it. |
| NEW-C3 | `lib/screens/accessible_dropdown.dart` + `lib/screens/imaging/**` | Label/value announce parity needs the dropdown call sites to pass a label. |

### Regression caught while verifying

The new Equipment Stats empty state first swallowed two truthful states: a
profile with runs but no frames (meridian flips and autofocus counts come from
the run rows) and a sessions query that had *failed*. It is now gated on images,
runs and sessions all having positively resolved to empty — a load in flight or
in error is not an empty history, which is the same class of untruth CON-45 is
about. `equipment_stats_meridian_flips_test.dart` and `equipment_stats_test.dart`
caught both.

## Verification

- `packages/skotiq_ui`: `test/components/interactive_semantics_test.dart` — 22/22.
- `packages/skotiq_app`: the four new/extended suites pass; the
  analytics / session_review / mosaic / diagnostics / suggestions / transients
  suites were re-run for regressions.
- `dart analyze lib/screens` — no errors or warnings introduced (the remaining
  `info` lines are the pre-existing `clampPanelWidth` deprecations).
- `packages/skotiq_ui`: full suite 306/306.

Four failures remain across those suites, all in `captures_landscape_test.dart`
(analytics ×2, diagnostics ×2). These are the documented Windows-captured-golden
debt: `reports/coverage/fixes/p2-p2-analytics.json` already recorded the two
analytics masters failing at 17.1 % / 23.8 % before this session, and
`f-wizards.json` records the same for diagnostics. The diagnostics diff is now
larger (24 %) because CON-48 intentionally removed the page title and the 95-word
paragraph those masters were captured with. **Not regenerated** — repo policy is
never to commit Linux-regenerated goldens; both pairs need recapture on the
reference host once this batch lands.

## Environment note for the next agent

Two concurrent D-fix batches broke `skotiq_core`
(`SchedulerSequenceSink.ownsRun`) and `skotiq_planetarium`
(`_holdZoomAnchor`, `focalPoint`) mid-session, which fails **every**
`skotiq_app` test with a compile error unrelated to the batch under test.
Re-run rather than concluding a fix is broken.
