# bfix batch: collab-mosaic-catalogs

Items: COL2-16 (P1), COL2-15 (+ wave-1 COL-7), COL2-17, COL2-1, COL2-3, COL2-11, COL2-7,
COL2-2, COL2-8, COL2-12, COL2-13.

## Files claimed (edited by this batch only)

- `packages/skotiq_app/lib/screens/sequencer/widgets/mosaic_wizard_dialog.dart`
- `packages/skotiq_app/lib/screens/sequencer/widgets/mosaic_wizard_dialog/config_controls.dart`
- `packages/skotiq_app/lib/screens/sequencer/widgets/mosaic_wizard_dialog/visual_planner.dart`
- `packages/skotiq_app/lib/screens/suggestions/widgets/transient_alerts_panel.dart`
- `packages/skotiq_app/lib/screens/settings/widgets/element_refresh_card.dart`
- `packages/skotiq_core/lib/src/services/mosaic/collaborative_mosaic_service.dart`
- `packages/skotiq_core/lib/src/services/target_suggestion_service.dart`
- `packages/skotiq_core/lib/src/providers/transient_alert_provider.dart`

The mosaic wizard lives under `screens/sequencer/widgets/` and the catalog cards under
`screens/settings/widgets/` rather than the scope's literal directories; the batch owns the
mosaic and catalog items so those files are claimed here.

## Log

- Read the adjudication + cluster report. Started with the RA-seam pair (COL2-15 + COL-7):
  both are pure geometry and directly testable.
- **COL2-15** — `_panelGeometry` positioned each panel from `(panelRa - centreRa) * 15` with no
  wrap, so a mosaic centred at 0.0h read its 23.9h column as +358.5 deg and drew it a sky away.
  Failing-first proven by temporarily reverting the fix: the new test reported **6 of 9** panels
  on canvas — exactly the count the live drive measured. Fixed with a signed
  (-180, 180] wrap; 9/9 at RA 0h, 23.9h and 12.5h.
- **wave-1 COL-7** — `publishProject` used the arithmetic mean of panel RAs in degrees. New test
  seeds the report's own five panels (358.595 … 1.405) and asserts the published centre is within
  0.01 deg of 0; the old expression yields 144.0. Fixed with a circular (unit-vector) mean.
- **COL2-16 / COL2-17** — "Create mosaic project" is in fact *disabled* at HEAD (no panel size),
  but its only explanation was a hover tooltip, which is why the live drive read it as a silent
  no-op. Added a footer reason line beside the action (`mosaic_action_blocked_reason`) naming the
  real blocker, and stopped the Advanced fields pre-filling 60.0/40.0 under a banner that says the
  panel size is unknown — they start empty behind a hint, and typing one unblocks the action.
  Banner copy now points at Advanced as well as Settings.
  The missing `[DISABLED]` semantics on the button itself is the A11Y-STATE class, owned at
  `SkotiqButton` by the component batch — recorded as covered-by-component.
- **COL2-1 / COL2-2** — card copy now names Soft00Bright ("not the full MPCORB") and the status
  line reads "N bright asteroids". Refresh now always acknowledges: success snackbar with the
  counts, error snackbar with the failure summary (previously a partial failure was silent).
  The button already swapped to "Refreshing…" and disabled at HEAD, so the "no spinner" half of
  COL2-2 did not reproduce.
- **COL2-3** — already fixed at HEAD: Download is disabled while the URL is empty and an inline
  note explains why. Pinned with a regression test; recorded as a false positive.
- **COL2-11** — the root of the lie: `kFetchableTransientSources` is `{tns}`, so enabling AAVSO
  alone makes `getAllAlerts` fetch nothing and return an authoritative-looking empty list. Added
  `TransientFeedCheck` / `transientFeedCheckProvider` recorded by every completed poll (queried +
  skipped sources), an honest empty state ("Not checked yet" / "No alert source is being checked"
  with the reason / "No active alerts · checked N min ago"), a "Check for alerts now" control in
  the card header, and a warning subtitle on sources this build cannot poll.
- **COL2-12** — the type chips are wrapped in `MergeSemantics`+`Semantics(checked:)` so they
  announce on/off like the checkboxes in the same dialog.
- **COL2-7** — a sizeless star-typed row is no longer offered as an imaging candidate unless the
  user asked for stars; star-typed rows with a real angular size are kept.
- **COL2-13** — already fixed at HEAD (auto-queue magnitude has its own slider plus a
  fainter-than-the-feed warning, and `transient_auto_queue_magnitude_test.dart` covers it).
  Recorded as a false positive.
- **COL2-8** — added a semantics/order test to `planner_screen_test.dart`: after switching the
  planner sort, each candidate card's own semantics subtree must name the target it renders.
  The live evidence is an accessibility-tree dump only reachable by driving the app, which this
  wave may not do; the test pins the invariant so Wave D can re-check the live tree.
- Concurrent-agent breakage in `skotiq_core` (scheduler_engine, frame_quality_assessment,
  polar_alignment_provider) and in `skotiq_app` (your_sky/name_region_sheet.dart) broke three
  test runs mid-flight; retried after a wait and they cleared.

## Verification

- `skotiq_core`: `flutter test test/services/... test/providers` → **1569 passed**.
- `skotiq_app`: transients + settings cards + sequencer/widgets + planner → all passed
  (`planner_screen_test.dart` 25 passed; earlier combined run 87 passed).
- `flutter analyze` clean on every lib file touched; the only analyzer output on the test files is
  the pre-existing `hasFlag` deprecation info already present elsewhere in the package.
- COL2-8 did **not** reproduce at the widget level: the new re-sort/semantics test passes against
  unmodified production code. Recorded as a false positive with the invariant pinned for Wave D.

- `mosaic_wizard_resume_test.dart > Resume button invokes the sequence executor resume lifecycle`
  fails at HEAD **independently of this batch** — proven by disabling the new footer-reason widget
  and re-running: identical binding-level failure. Not caused here, not fixed here.
