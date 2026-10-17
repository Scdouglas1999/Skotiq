# E-fix batch `science-collab-3`

Wave-E harvest for the science / collaborative / shell-chrome cluster. Every
item below started from `reports/release-pass/waveE-result.json` +
`reports/release-pass/gui/waveE-science-collab.md`, and every behaviour item has
a test that fails on the pre-fix code and passes after.

Graphify hook: `graphify query "Night Doctor diagnostics score replay screen
navigation collaborative sky gated actions status bar chip"`.

---

## Environment hazard hit mid-batch (recorded for the orchestrator)

At **21:47** a concurrent agent ran `git stash` on the shared worktree
(`reflog: reset: moving to HEAD`, `stash@{0}: WIP on audit/end-to-end-campaign`).
That silently reverted **every tracked file** in the tree — mine included —
while leaving untracked new files in place. My work at that point (NEW-E5,
NEW-E2, NEW-E3) was recovered by writing the stash's blobs back over the five
files it owned:

```
git show "stash@{0}:<path>" > <path>
```

`git diff HEAD stash@{0} -- <path>` was checked first for each file and showed
only my own hunks, so nothing of another agent's was pulled back in. **The
stash still exists**; if anyone pops it, it will conflict with the current tree.
This is the "never git stash with concurrent agents" trap from memory, live.

A second concurrency effect: for ~20 minutes `skotiq_core` did not compile
(another agent's in-flight `scheduler_engine` / `autopilot_rules` edits), which
blocked test runs in both packages. Re-run later; all green.

---

## NEW-E5 / WD-SCI-N5 — Night Doctor scored an all-POOR night 100/100

**Root cause.** Every Night-Doctor detector looks for a *change* over the night
(drift, a collapse, an onset). A night that was uniformly bad from the first sub
to the last trips none of them, and `_score` only ever subtracts — so silence
lands on a perfect 100 with "A clean night — no problems detected". The D-fix
added a disclosure row under the verdict; the verdict itself still said clean.

**Fix.** The night verdict now reads the *same* grader the Workbench reads.
`NightSub` carries `qualityScore` and can render itself as the `CapturedImage`
the grader takes (`asGradableFrame`), and a new detector
`_detectGraderPoorNight` fires when at least half the subs grade POOR
(critical when all of them do). This is a reconciliation, not a second opinion —
the app can no longer hold two contradictory verdicts on one night.

- `packages/skotiq_core/lib/src/services/night_analysis_service.dart`
  (import, detector registry, `qualityScore` load)
- `.../night_analysis_service/night_data.dart` (field + `asGradableFrame`)
- `.../night_analysis_service/detectors.dart` (`_detectGraderPoorNight`)

**Test** (refuter's own numbers — `captured_images` 13–16, HFR 5.69–5.74,
`quality_score` 35.26–35.42, against 2.19–2.22 / 84 for the quick captures):
`packages/skotiq_core/test/services/night_doctor_frame_grade_test.dart`.
Pre-fix: `qualityScore` did not exist, and with it stubbed the report scored
100/"clean night". Post-fix: `frames_graded_poor`, critical, score < 100,
evidence `[13, 14, 15, 16]`; a good night still scores 100; one POOR sub in a
good night is still not a night-level failure.

## NEW-E2 — Replay swallowed rail navigation while the rail repainted as moved

**Root cause.** `ReplayDebugScreen.push` used `Navigator.of(context).push`, i.e.
an imperative route on the **shell's** navigator, above the page go_router owns.
`go()` from the rail replaced the page underneath and moved the rail's own
selected highlight, but the imperative route stayed on top — the chrome
advertised a destination the app had not gone to.

**Fix.** Replay is a real route inside the `ShellRoute`
(`/replay/:runId?name=&started=&ended=`), and the launcher goes through
`GoRouter.push` (with the imperative push kept only as a no-router fallback for
widget tests/embedders). A `go()` now discards it like any other page.
Also: the app-bar `✕` (which only cleared filters and read as "close" — the
drive clicked it twice expecting to leave) is now the filter-clear glyph.

- `packages/skotiq_app/lib/router/app_router.dart`
- `packages/skotiq_app/lib/screens/sequencer/widgets/replay_debug_screen.dart`

**Test:** `packages/skotiq_app/test/router/replay_route_test.dart` — the
route exists, is inside the shell (not above it), and the launcher location
carries run id, label and scrub window.

## NEW-E3 — "1 of 2 decisions" over a list of one

**Root cause.** The scrub window was the run row's `started_at`/`ended_at`
alone, while the header counted every decision. A decision written outside that
window — the completion decision persisted a beat after the run row was closed
is the common one — was unreachable at *every* slider position and still in the
denominator.

**Fix.** `replayScrubSpan()` (pure, public) takes the UNION of the run window
and the decision timestamps, and the filter short-circuits entirely at full
extent.

**Test:** `packages/skotiq_app/test/screens/sequencer/replay_debug_screen_test.dart`
with a decision 120 ms past `ended_at`. Pre-fix it rendered exactly the live
symptom ("1 of 2"); post-fix both rows render and the header reads 2 of 2.

## WD-COL-N3 — an auto-filled dimension swallowed keystrokes

**Root cause (two bugs, one shape).** `_PanelSizeSource.user` was set the moment
*either* dimension was typed, so typing a WIDTH declared the whole panel size
known — which flipped the HEIGHT field's `value` from null to the **60×40 field
initialiser** and `_NumberField.didUpdateWidget` wrote `40.0` straight over what
the user was typing. The same flip unlocked the footer actions on half-invented
geometry. Out-of-range typing was also dropped in silence.

**Fix.** Per-dimension `_userSuppliedWidth` / `_userSuppliedHeight`;
`_panelSizeKnown` requires both. `_NumberField` never rewrites a focused field,
snaps back to the value in force on blur, and shows an `errorText` when a
complete number lands outside the range.

- `.../sequencer/widgets/mosaic_wizard_dialog.dart`
- `.../sequencer/widgets/mosaic_wizard_dialog/config_controls.dart`

**Test:** `mosaic_wizard_refusal_test.dart` — the pre-existing case
"typing a panel size in Advanced unblocks the primary action" **encoded the
defect** (it typed a width alone and asserted the action unblocked); it is
replaced by "BOTH typed dimensions unblock the primary action", which asserts the
height field stays empty after a width-only entry and that a typed `35` survives.

## WD-COL-N2 + COL2-3 (third strike) — inert gated actions with no reason

**Why two waves of fixes did not settle it.** Both sites already passed
`onPressed: null` and already rendered an inline reason, yet two live drives read
the tree as a plain `button: X` with **no `[DISABLED]`** and a click that did
nothing. The two implementations were indistinguishable in a dump, because a
disabled control whose accessible NAME reads exactly like the enabled one is
indistinguishable from a live one.

Freshness was ruled out first: the D-fix strings ARE in the tested bundle. Note
for future drives — `grep` on `libapp.so` misses any Dart string containing a
non-Latin-1 character (an em dash makes the whole literal two-byte), which is
why "No official tileset is published yet" reads as absent and is not:

```python
u16 = s.encode('utf-16-le')   # this is the one that matches
```

**Fix.** New shared `GatedAction` widget: when blocked, the announced name
becomes `"<label> — unavailable: <reason>"` with `hasEnabledState` + no
`isEnabled`. That string is the discriminator — a future dump showing the bare
label proves the gate did not apply; a dump showing the reason proves this build
is the one on screen. Applied to the deep-star **Download** and to both mosaic
footer actions. The mosaic wizard also logs one line per action attempt
(`[MosaicWizard] create-project requested (panelSize=…)`, plus a line on each
early return), so "clicked and nothing happened" can be told from "the click
never arrived" — the drive explicitly recorded *no new log line* as evidence.

- `packages/skotiq_app/lib/widgets/gated_action.dart` (new)
- `.../settings/widgets/deep_star_catalog_card.dart`
- `.../sequencer/widgets/mosaic_wizard_dialog.dart`
- `.../sequencer/widgets/mosaic_wizard_dialog/wizard_logic.dart`

**Tests:** `deep_star_catalog_card_test.dart` — two new cases asserting the
SEMANTICS (the level the harness reads, which is where the two implementations
differed; the old test asserted only `onPressed == null` and passed through both
failed waves). `mosaic_wizard_refusal_test.dart` — the same assertion for
"Create mosaic project".

## WD-COL-N4 — status bar clipped "Simulated Cam" against the thermometer

**Root cause.** On desktop the trailing group began with no separator, so when
the pill strip overflowed the last pill butted straight against the temperature
chip. The only overflow signal was a 24 px alpha fade — not a control, so with a
mouse there was nothing to click.

**Fix.** The scrolling region always ends at a rule, and while it overflows a
real chevron control ("More equipment status") sits between the strip and the
rule and scrolls it.

- `.../shell/widgets/status_bar.dart`, `.../status_bar/pill_widgets.dart`

**Test:** `status_bar_overflow_test.dart` at **900×760** (the drive's own size):
the affordance exists, sits clear of the scroll viewport, and moves the group;
a wide bar offers none.

## WD-SCI-N3 — "Start Anyway" published as a role-less panel

Bare `GestureDetector` → `panel: Start Anyway`, beside its own siblings
`button: Re-check` / `button: Cancel`, and unreachable from the keyboard. Now
`Semantics(button, enabled)` + `FocusableActionDetector` with Enter/Space
routed through `ActivateIntent`, matching `SkotiqButton`.

- `.../sequencer/widgets/preflight_validation_dialog/action_widgets.dart`
- Test: `preflight_validation_dialog_test.dart` (semantics pin).

## WD-SCI-N4 — chevrons painted over the tab labels at 900 px

The edge affordances were `Positioned` in a `Stack` over the strip, so the right
chevron sat on top of the Science tab (`S › ce`). They are laid out **beside**
the strip now (`Row` + `Expanded`), which reserves the width instead of
borrowing it. Stability is argued in-code: showing a chevron only narrows the
viewport (more scrollable), hiding one at an end widens it and clamps the offset
to the smaller extent.

- `packages/skotiq_ui/lib/src/components/adaptive_tab_bar.dart`
- Test: `adaptive_tab_bar_test.dart` — no chevron rect may intersect the
  **visible** part of any tab label, at 900×760, before and after a nudge.
  Verified to FAIL on the old `Stack`/`Positioned` layout and pass on the new one.

**Two consequences of that layout change, both chased down rather than
absorbed** (`test/screens/mobile_tap_target_test.dart` caught them):

1. Out of a `Positioned`, the affordance no longer inherited the strip's height
   and measured **48×30** — a real 48 dp failure. It now carries an explicit
   `minHeight: _kMinTapTarget`. Verified by removing the constraint again: the
   suite reports `48.0x30.0 "Scroll tabs right"`, so the guard is live.
2. With the viewport 48 px narrower, the tab that straddles the right edge is
   cut differently, and at 360×640 the analytics strip left a **4×50**
   remnant of "Diagnostics". That is a *scrolled* control, not an undersized
   one — a scrolling strip slices whatever item straddles its edge at any
   offset, and no layout prevents it for every viewport width. So the audit
   test gained a narrow, documented exemption: a target is skipped only when it
   is flush against a scroll viewport's edge on the axis it is undersized on
   **and** its other edge is ≥ 48 dp, so a genuinely tiny control at an edge is
   still reported (proved by case 1 above, which sits at the same edge and is
   still caught). Applying it required fixing the measurement itself: the file's
   comment claimed global coordinates but passed `SemanticsNode.rect`, which is
   node-local — it now accumulates the ancestor transforms the way Flutter's own
   `androidTapTargetGuideline` does. Sizes are unchanged by translation, so no
   existing verdict moves.

## NEW-E4 + NEW-C2 (in-scope sites) — live controls announced `[DISABLED]`

`PopupMenuButton` and bare `InkWell` publish a tap action but no button role and
no enabled state, and AT-SPI reads a missing enabled flag as insensitive — hence
`panel: 🔭 My Equipment / 2 connected [DISABLED]` on **every** screen and
`panel: Advanced (numerical) [DISABLED]` in the mosaic wizard. Both now declare
`button: true, enabled: true` (and `expanded` for the disclosure).

- `packages/skotiq_app/lib/widgets/equipment_status_indicator.dart`
- `.../mosaic_wizard_dialog/config_controls.dart`

## NEW-C4 residual / dropdown announce parity

`SkotiqDropdown` sets both `selected` and `checked` on its entries;
`AccessibleDropdown` (which the three Analytics session pickers use) set only
`selected`. AT-SPI carries the two differently and the audit harness prints
`[ON]`/`[off]` from checked/checkable, so one family announced the current row
and the other did not. One line brings them into parity.

- `packages/skotiq_app/lib/screens/accessible_dropdown.dart`
- Test: `accessible_dropdown_test.dart` (hasCheckedState + isChecked per entry).

---

## Not done in this batch

- **NEW-C3** (Imaging's `button: Light` / `button: 1x1` whose words live in
  adjacent unassociated `panel: Frame Type` / `panel: Binning` nodes) is in
  `screens/imaging/**`, outside this batch's SCOPE and inside another E-fix
  batch's. Untouched, with the fix shape recorded: give the control a
  `Semantics(label: '<group>, <value>')` the way Settings ▸ Appearance already
  pairs them.
- **NEW-C2 outside the scoped directories** — `panel: Overlays [DISABLED]` in
  Imaging and the Sequencer palette's role-less `panel: Nodes / Tab 1 of 3` —
  same class, same one-line remedy, other batches' files.

## Known-failing, NOT caused by this batch

`test/screens/{sequencer,settings}/captures_landscape_test.dart` (tagged
`golden`, excluded from `melos run test`, captures gitignored) fail with 9.44% /
7.17% pixel diffs. Measured **identical** with and without the adaptive-tab-bar
change, i.e. a pre-existing host-baseline mismatch (baselines are Windows-
captured; see `docs/testing/golden-tests.md`).
