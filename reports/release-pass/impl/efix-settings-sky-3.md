# E-fix batch `settings-sky-3`

Charter: SET-12, WE-SP-1..5, D-2, D-3, E-SKY-1, E-SKY-2, E-SKY-3.
Evidence: `reports/release-pass/waveE-result.json`,
`reports/release-pass/gui/waveE-settings-pairing.md`,
`reports/release-pass/gui/waveE-sky-planetarium.md`, plus the live shots under
`/tmp/ns-audit/waveE-settings-pairing/` (still on disk) and
`reports/release-pass/gui/shots/waveE-sky-*`.

No GUI harness, no bundle rebuild, no git writes, no FRB regen. Every item has a
test that fails on the old behaviour; the two GUI-geometry items are pinned by
widget/arithmetic tests, not screenshots.

---

## SET-12 — the dashboard tour narrated absent panels (second strike)

**What actually ran.** The D-fix's `tutorialStepIndexPastMissingTarget` returned
`index ± 1` and relied on being re-entered from the next build, behind a 450 ms
guard. So the tour did not skip a run of absent steps — it *walked* it, one step
every 450 ms, and each absent step became the current step long enough to be
announced by `_TutorialOverlayContent._announceStep`. That is exactly what the
auditor caught: `Right` → "step 6 of 12: Weather Status", `Right` → "step 11 of
12: Active Sequence" on a dashboard that has neither panel. (`dashboard_weather_widget`
is only attached inside `dashboard_widget_registry`'s weather tile, and
`dashboard_sequence_widget` is attached NOWHERE in the tree.)

**Fix** (`packages/skotiq_app/lib/widgets/tutorial_overlay.dart`):
the helper now scans the whole run in the direction of travel and returns the
first *landable* index (a step with no target, or with a live one); the overlay
moves with `notifier.goToStep(target)` instead of repeated `nextStep()`. No
absent step is ever current, so none is announced.

**Two-implementations guard.** The overlay now emits one log line that only it
can emit — `TutorialOverlay pass-over: dashboardTour 2 -> 11 (absent target
dashboard_live_preview)` on `name: 'TutorialOverlay'`. The app has a second tour
narrator (`OnboardingOverlay`, "Step n of 7"); a future fix that changes nothing
on screen can be told apart from a fix applied to the wrong widget by whether
this line appears.

**Test** (`test/widgets/tutorial_missing_target_test.dart`): uses the REAL
12-step dashboard tour with `dashboard_edit_button` as the only live target and
pins 2 → 11 in one answer, plus 10 → 1 going back. Fails at HEAD with `3`.

## WE-SP-1 — the picker clipped the row the operator had just selected

`OnboardingDevicePickerBody` scrolls (WD-N2's fix) but said nothing about it, and
the fixed-height box the filter-wheel step hands it left the selected card cut
through its subtitle. Now: `Scrollbar(thumbVisibility: true)` over the picker's
own controller, and `_DeviceTileState` calls `Scrollable.ensureVisible` when it
becomes selected *and* when it is rebuilt already-selected (re-entering the step,
the s60/s61 case).

Test (`test/screens/onboarding/onboarding_backend_failure_copy_test.dart`, group
`WE-SP-1`) pumps the filter-wheel step with the two failed backends AND the
simulated wheel listed, then asserts the always-visible scrollbar and that the
selected row's rect lies inside the picker's rect. Verified to FAIL with the
`_revealSelf` calls disabled, and pass with them.

## WE-SP-2 — the swallowed nav click after "Reset All Progress"

Root cause found in the auditor's own screenshots: `s43-afterreset.png` shows the
**first-launch tour overlay** ("Step 1 of 7 — Welcome to Skotiq") on screen —
`Reset All Progress` calls `onboardingTourProvider.reset()`, which flips the
status to `pending` and `OnboardingTourReplayLauncher` mounts `OnboardingOverlay`
over the app. The next click landed on its scrim, which was wired to `_skip`: the
click was consumed AND the tour was destroyed before the next screenshot, leaving
no trace — hence "the rail did nothing, a second click worked". (The rail's
highlight was never the destination repainting: Settings is not a rail
destination, so Dashboard stays highlighted the whole time.)

Fix: the scrim now absorbs taps without skipping (`onTap: () {}`). Escape and the
explicit Skip button still leave the tour. A modal that stays on screen explains
why the click did nothing.

Test: `test/widgets/onboarding_overlay_test.dart`, group `WE-SP-2` — a tap at
(40, 60) leaves the card up and persists nothing; Escape still records `skipped`.

## WE-SP-3 — pairing empty state at 1.31:1

`pairing_screen.dart` painted "Start pairing mode to connect a device" with
`colorScheme.outline` (a border colour). Now `SkotiqColors.textSecondary`.
Test `pairing_card_semantics_test.dart` computes the WCAG ratio against
`colors.surface` and requires ≥ 4.5:1, and asserts the colour is not `outline`.

## WE-SP-4 — the pairing card collapsed into one "button"; copy did nothing visible

* The card's prose lines (`Enter this code on your device:`, `Expires in …`) each
  get `Semantics(container: true)`, so they stop merging into the neighbouring
  button node. (Flutter merges compatible sibling label fragments into the
  nearest enclosing node; that node was a button.)
* The copy control is now `_CopyCodeButton` — a named `SkotiqButton` ("Copy
  code" → "Pairing code copied to clipboard" for 3 s) instead of a bare
  `IconButton` whose tooltip named nothing.
* The confirmation no longer waits on `Clipboard.setData`. Awaiting the platform
  round-trip before touching the UI is *why* the click looked dead — in the test
  environment the channel never answers and neither the label nor the snack bar
  ever appeared. On a real write failure the label reverts and an error is shown.

Test asserts: no node is both a button and the carrier of the card prose; a
button named "Copy code" exists; pressing it changes what is on screen.

## WE-SP-5 — the nudge covered the Moon card

`DashboardScrollView` (the single scroll host for all three dashboard layouts)
now reserves `kFloatingPromptReservedHeight` (108 px measured + 2×16 margin) at
the bottom while `smartNightAutoPromptShowingProvider` is true, so the last card
scrolls clear of the floating prompt. Test:
`test/screens/dashboard/floating_prompt_reserve_test.dart`.

## D-2 — tooltips never left the a11y tree

Two mechanisms, both closed in
`packages/skotiq_ui/lib/src/components/skotiq_tooltip.dart`:

1. the overlay was retired inside `_animController.reverse().then(...)`, and a
   `TickerFuture` whose ticker is cancelled never completes — so a second hide,
   or a show interrupting a hide, silently dropped the `hide()` and left the
   portal mounted. Retirement is now a `Timer(animationDuration)` that cannot be
   lost, plus a 6 s self-retirement clock (re-armed by `onHover`) for the case
   where `onExit` never arrives at all — the "Forward 1 hour" label still painted
   over the sky 12 s after the pointer left, visible in
   `shots/waveE-sky-d2-tt-clean-screen.png`;
2. the floating label published its own semantics node. It is now wrapped in
   `ExcludeSemantics`, and the message rides on the TRIGGER as
   `Semantics(tooltip:)` — which cannot outlive the control it describes.

Test: `packages/skotiq_ui/test/skotiq_tooltip_stale_node_test.dart`
(4 cases). The pre-existing `skotiq_tooltip_lifecycle_test.dart` /
`_anchor_` / `_edge_` tests still pass — full `skotiq_ui` suite: 312 passed.

## D-3 — the search box and the readout strip published themselves DISABLED

Same root as WE-SP-4: a tap action with no role, plus sibling label fragments
merging into the nearest enclosing node — on the planetarium that node is the sky
canvas, which is tappable, hence one focusable "panel" named
`20:37:18 / 1x / Center RA … / Bortle: 5`.

* `command_bar.dart`: the search box is wrapped in
  `Semantics(button: true, enabled: true, label: 'Search the sky (Ctrl+K)')`;
  the shortcut is in the NAME because `excludeSemantics` drops the chip that
  draws it. `CommandBarIconButton` (a bare `GestureDetector`) gets the same
  treatment, named by its tooltip.
* `bottom_info_bar.dart`: every `InfoItem` is a container node named
  `"<label> <value>"` — label AND value, the E-SKY-3 lesson.
* `time_control_panel.dart`: `_readoutNode` does the same for the clock ("Sky
  time 20:37:18") and the rate chip.

Tests: `test/screens/planetarium/hud_readout_semantics_test.dart` (pumps the
readout beside a tappable full-bleed canvas — the exact absorbing shape) and the
new clock case in `time_transport_semantics_test.dart`.

## E-SKY-1 — the D-4 inset replaced one overlap with another

The transport was inset by `dockedWidth` only, so at 900 px it was pushed INTO
the compass (whose altitude bar makes it `size + 40` wide) and the minimap.
`planetariumTransportBand()` (pure, `@visibleForTesting`) now excludes whichever
instruments are on screen from the band the transport centres in, and when what
remains is narrower than the transport's measured 272 px it lifts the transport
above the instrument row instead of squeezing it.

Test: three arithmetic cases in
`test/screens/planetarium/transport_docked_panel_overlap_test.dart` using the
refuter's own numbers (724 px stack / 280 drawer → lift; 1424 / 380 → centre
between; instruments hidden → whole band). The D-4 widget pins still pass.

## E-SKY-2 — play/pause announced its name and its state as opposites

`label: running ? 'Pause' : 'Play'` with `toggled: !running` made AT announce
"Play, toggle button, on" while time was HELD. Now the button carries an action
name only (`Pause time` / `Play time`) with no toggle state, and the *state*
lives on the rate chip, which publishes `Time paused` / `Time running at 1×` as
its own node. The old contract's assertions in `time_transport_semantics_test`
were replaced (with the reason recorded in the test).

## E-SKY-3 — the guide-graph a11y fix dropped the selected value

`Semantics(button, label: label, value: value, excludeSemantics: true)` published
nothing readable: the child `Text('5m')` was excluded and `value` never reaches
AT-SPI (the refuter's probe found no Value interface and an empty description).
The name is now `'$label $value'` — "Time: 5m" — with `value` still set for
platforms that read it. Test:
`packages/skotiq_ui/test/guide_graph_scale_selector_semantics_test.dart`
asserts label AND value in the accessible NAME, and that the node is still an
enabled button.

---

## Tests run

| suite | result |
| --- | --- |
| `packages/skotiq_ui` (full) | 312 passed |
| `packages/skotiq_planetarium` (full) | 559 passed, 1 failed — `test/benchmark/golden_compare_test.dart` |
| `skotiq_app` `test/screens/planetarium`, `test/screens/onboarding`, `test/widgets` | 610 passed, 2 failed — both `onboarding/captures_landscape_test.dart` goldens |
| `skotiq_app` `test/screens/settings`, `test/screens/dashboard` | 684 passed, 6 failed — all `dashboard/captures_landscape_test.dart` goldens |

**The 9 failures are pre-existing Linux golden/benchmark failures, not this
batch.** `captures_*` goldens were captured 2026-06-05 / 2026-07-20 on Windows
and diff 27–43 % of all pixels (font rasterisation, not layout); the onboarding
capture renders step 1, which has no device picker at all. The planetarium
benchmark golden imports only `benchmark/src/*` sky-chart fixtures — none of the
files this batch touched. Nothing was regenerated (per the standing rule against
committing Linux-regenerated goldens).

## Environment note for the orchestrator

Around 21:47 local the working tree was reverted underneath this agent (tracked
files snapped back to HEAD; untracked files survived) and several `git`/`sed`
reads returned stale content for a few minutes. Edits were re-applied and every
one was re-verified by content grep afterwards — see the marker sweep in the
session. One casualty: `packages/skotiq_ui/test/skotiq_tooltip_lifecycle_test.dart`
was briefly overwritten by this agent; it was restored from HEAD verbatim and the
new cases live in `skotiq_tooltip_stale_node_test.dart` instead.
