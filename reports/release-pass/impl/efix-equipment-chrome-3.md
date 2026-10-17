# E-fix — batch `equipment-chrome-3`

Charter: WD-SEQ-N4, WD-EQ-2, WD-EQ-3, WD-EQ-4, WE-EQ-N1/CON-53, CON-49, CON-51,
CON-52/55/56/58/59/62, WE-EQ-N2, WE-EQ-N3, WE-EQ-N5/N6.
Evidence: `reports/release-pass/waveE-result.json`,
`reports/release-pass/gui/waveE-equipment-chrome.md`, Wave E verdict section of
`RELEASE-PASS-2026-08-11.md`.

Orientation: one `graphify query "friendlyNameFromDeviceId device id display
names, equipment dashboard edit standby, target score row status label reason"`.

---

## Incident during the batch: the working tree was `git stash`ed under us

Mid-batch every tracked-file edit in the repo vanished (`stash@{0}: WIP on
audit/end-to-end-campaign`). Untracked new files survived. The stash was
restored shortly afterwards by whoever made it and my edits came back intact —
verified file-by-file before continuing. Recording it because it is the known
"never git stash with concurrent agents" trap and it cost this batch ~15 minutes
of re-verification. No git writes were made by me.

---

## Two-implementations strikes closed

### WD-SEQ-N4 (third strike) — the chip overrode the engine's reason

The engine's `_summarizeRejection` and the queue row's `_statusLabel` each
carried their own `reason.contains(...)` ladder. Wave D fixed the engine's copy;
the chip the operator actually reads is the widget's, so the screen was
unchanged: a target at +9.8° under a 30° site minimum still read
`Below horizon` beside its own correct sentence.

* New `packages/skotiq_core/lib/src/services/scheduler/rejection_labels.dart`
  — ONE classifier (`classifySchedulerRejection`) with two renderings
  (`schedulerRejectionChipLabel` for the chip, `schedulerRejectionSummary` for
  the decision record). Also fixes a latent bug the old widget ladder had:
  a custom-horizon rejection (`altitude 41.0° below horizon profile "Trees" …`)
  matched `altitude`+`below` first and was mislabelled `Below horizon`.
* `evaluation.dart::_summarizeRejection` and
  `target_score_row.dart::_statusLabel` both delegate; neither matches strings.
* Chip for the refuter's exact counter-input is now `Too low`.

**What makes it loud next time:** `target_score_row_status_test.dart` pins the
rendered chip for the verbatim repro input AND reads the widget's own source,
failing if any `contains('altitude'` / `contains('moon` / … ladder reappears in
that file.

### WD-EQ-2 (second strike) — the humanizer had no arm for any id you can produce

`_humanizeDeviceIds` called `friendlyNameFromDeviceId`, which only rewrote
`native:zwo_efw:` / `native:qhy_cfw:` / `native:fli_fw:` / `ascom:` / `alpaca:` —
so `native:builtin_guider:multi_star`, `sim_camera_1`, `sim_filterwheel_1` and
`sim_focuser_1` all fell through to `return deviceId`.

* `device_id.dart`: arms for `native:builtin_guider:*` and `sim_<type>_<n>`, with
  `kSimulatorDeviceDisplayNames` copied verbatim from the backend's own
  `discovery.rs` table, and `kBuiltinGuiderDisplayName`.
* `device_format_utils.dart::formatDeviceId` (the app's richer, SECOND
  formatter) now delegates for exactly those ids instead of falling through to
  `cleanupDeviceId` ("Sim Filterwheel 1").

**Deviation from the charter, deliberate:** the charter says
`native:builtin_guider:* → "Built-in Guider"`. I used
**"Built-in Multi-Star Guider"**, which is the name `bridge/src/api/discovery.rs`
already advertises and the name `formatDeviceId` and the Discovery list already
show. Introducing a third spelling for one device would have recreated the
defect class this batch exists to close.

**What makes it loud next time:** `device_display_name_parity_test.dart` pins the
four ids from the live tree dump and then asserts the two formatters agree on
every id they both know.

## WD-EQ-4 (second strike) — the refusal never reached the bridge

Wave D put the reason in `Semantics(hint:)` and a widget test passed; the live
AT-SPI probe returned `button: 'Edit Dashboard\nEdit Dashboard' desc=''
states=['sensitive',…]` — enabled, no description, byte-identical to the enabled
state. Two causes: `SkotiqButton` publishes its own node (so the wrapper was
contradicted and the label doubled), and the Linux bridge does not carry `hint`.

* `excludeSemantics: !canEdit` makes the wrapper the ONE node for the control.
* The reason moved into the accessible **name**
  (`standbyEditSemanticLabel`) — the one field the harness demonstrably prints.
* A pointer click now states the reason: a `Listener` (not `GestureDetector` —
  the button registers a tap recognizer even when disabled and wins the arena)
  raises the refusal as a toast.
* Test asserts `hasEnabledState && !isEnabled`, the reason in `label`, **no
  newline in the label** (the doubling signature), and that the enabled name is
  different.

---

## The rest

| Item | Fix |
| --- | --- |
| WD-EQ-3 | `notification_toast_overlay.dart` collapses notifications identical in (level, title, body) into one toast with an `(xN)` count; the whole group dismisses together so a twin cannot pop back. Keyed on what the operator SEES, not on the producer — two producers for one refusal is architectural, saying it twice is not. |
| WE-EQ-N1 / CON-53 | `decision_panel.dart` now names the **Scheduler queue below** (rendered directly beneath the card, on the same tab) instead of a "Target Queue tab" that no longer exists; `progress_tab_content.dart` → "the Schedule tab". Guard: `planner_copy_names_real_tabs_test.dart` scans every non-comment line under `screens/planner` for "`<Name>` tab" and fails unless `<Name>` is a tab `PlannerTab` renders. |
| CON-49 | The desktop onboarding footer drew `Back` unconditionally while `onBack` was null on step 1; the phone footer already omitted it. Both footers now agree. |
| CON-51 | History chips + search are disabled over an **unfiltered** empty run list (not `filteredRunsProvider`, which would disable the chips needed to widen a filter that matched nothing), with the reason in the tooltip and the a11y name. One vocabulary: new `runStatusMeaning()` defines each status once, with every not-finished status opening on the same clause. |
| CON-52 | New `SequencerTabTitle` (24 px title + one subtitle sentence ending in a full stop, asserted). Adopted by Templates, Sequence Library, History — and the Builder, which had no heading at all. |
| CON-55 | The Framing warning card's action was a bare `GestureDetector` (published as `panel: Edit Profile`); now `Semantics(button, excludeSemantics) + InkWell`, matching the sibling `button: Open Settings`. |
| CON-58 | Analytics → Projects empty state now says "No projects yet" and offers **New Project** → `/planner?tab=projects`, i.e. the same single creation path Plan Tonight → Projects offers, instead of "add targets and capture images". |
| CON-59 | `sample_sequence_service.dart`: `~3 min capture` / `~10 min capture` → `~3 min` / `~10 min`. The column is a duration. |
| CON-62 | Help & Tutorials: one verb (`Start` on all five rows) and one treatment (all outline; the lone filled primary is gone). |
| WE-EQ-N2 | The tour nudge now declares its own `TransientBottomInset` (measured top-edge-to-window-bottom), so floating snackbars clear it the same way they clear the Imaging control strip. Published only while the card is visible and bottom-anchored, so a host screen's declaration is never clobbered by a zero. |
| WE-EQ-N3 | `_ControlButton` (the Dashboard's "Image tonight" / "Sequencer") published as `panel … [DISABLED]` while fully live: now `Semantics(button, enabled, excludeSemantics)`. |
| WE-EQ-N5 | Dense status pills cap their value at 88 px so the strip fits a 1000 px bar and a name truncates with a visible ellipsis inside its pill instead of being sliced mid-word by the scroll viewport's fade. |
| WE-EQ-N6 | The device-card name shrinks to fit (`FittedBox.scaleDown`) before it truncates, with a tooltip carrying the full name — so "Simulated Filter Wheel" stops being the one card in the grid showing a mangled device. |

---

## Not done

* **CON-56** (`NOW` / `TONIGHT` all-caps) — **BLOCKED.** The strings live in
  `packages/skotiq_planetarium/lib/src/widgets/time_control_panel.dart`,
  outside this batch's scope, and that file was **actively modified by another
  E-fix batch** during this run (`git status` showed it dirty with a 26-line
  diff). Editing it concurrently would have risked the clobber this batch
  already suffered once. Reassign to the sky-planetarium batch.
* **WD-EQ-2 half (a)** — the disconnect TOAST still interpolates the raw id. The
  template lives in `skotiq_core/services/notification/notification_router
  .dart` + `event_classifier.dart`, outside scope, and `event_classifier.dart`
  was being edited concurrently by the WD-SEQ-N1 batch (its sequencer-stop
  classification landed mid-run). I prepared the two-line fix
  (`equipment.device_name` context key resolved through
  `friendlyNameFromDeviceId`, template switched to it) and **reverted it** rather
  than collide. The run-dashboard feed half (b) IS fixed.
* **CON-62 title case** — the five row titles are mirrored into the generated
  `settings_search_index.g.dart`; this batch may not regenerate generated files,
  so the Title-Case / sentence-case split in the titles is left for a batch that
  can regenerate the index. Verbs and treatments are unified.

## Tests

New: `target_score_row_status_test.dart`, `device_display_name_parity_test.dart`,
`notification_toast_dedupe_test.dart`, `planner_copy_names_real_tabs_test.dart`.
Rewritten: `edit_dashboard_refusal_test.dart` (three tests, now encoding the
refuter's counter-checks).

Green: those files, plus `skotiq_app` `test/widgets` (299),
`test/utils/snackbar_placement_test.dart` + `transient_bottom_inset_test.dart`
(10), `test/screens/analytics/widgets` (170),
`test/screens/settings/help_tutorials_replay_hub_test.dart` (6),
`test/screens/sequencer` + `test/screens/equipment` (no failures in the 798-test
combined run), and `skotiq_core` `test/services/scheduler/` (144),
`test/utils` (132) and `sample_sequence_service_test.dart` (8).
`flutter analyze` over every touched area of both packages: 0 errors, 0 warnings
(11 pre-existing infos in skotiq_app, none in skotiq_core).

Pre-existing, unrelated: the whole `captures_*` golden suite fails on this
machine — the documented Windows-captured-goldens-on-Linux problem. Proved, not
assumed: `test/screens/guiding/captures_landscape_test.dart` and
`test/screens/weather/captures_landscape_test.dart` — screens this batch never
touched — fail with 12–48 % pixel diffs (`weather_android_portrait_430x932`:
47.72 %, 191 240 px). Every failure observed in this batch's runs
(dashboard / analytics / planner / settings / framing captures, plus
`framing_registration_test` 11.30 % and `framing_hips_layer_wiring_test`
0.17 %) is that same golden suite; neither framing golden renders
`FramingEquipmentWarningCard`, the only framing widget this batch touched
(`grep -c WarningCard` on both test files → 0).

One real regression from this batch, found and fixed:
`help_tutorials_replay_hub_test.dart` targeted the replay buttons by the label
`'Re-run'`, which CON-62 unified to `'Start'`. The test now targets the button
through its row TITLE (which is what actually distinguishes the rows) and is
green — 6/6.
