# w6-reveal-scroll — every row reveal must scroll the tree, not the screen

Base `f705b0e15`, branch `agent/w6-reveal-scroll`. Follow-up to `w6-inspector-shift`,
which fixed the same defect in `AdaptiveTabBar` and flagged the rest of the class.

## 1. The defect class

`Scrollable.ensureVisible` does not scroll *a* scrollable. It walks EVERY
ancestor `Scrollable` and scrolls each one so the target is visible in it:

```dart
ScrollableState? scrollable = Scrollable.maybeOf(context);
while (scrollable != null) {
  futures.add(scrollable.position.ensureVisible(...));
  context = scrollable.context;
  scrollable = Scrollable.maybeOf(context);
}
```

The sequencer body is an `AnimatedTabBarView` → `TabBarView`
(`sequencer_screen.dart`), a horizontal pager holding Builder / Templates /
Saved / History, and the builder's tree is a descendant. So every "jump to this
node" also asked the PAGER to reveal the row: the screen slid toward the next
page and the page physics sprang it back. `NeverScrollableScrollPhysics` does
not prevent this — it only refuses user drags (`shouldAcceptUserOffset`), never
a programmatic `animateTo`. The space uncovered is blank because `_LazyTab`
renders `SizedBox.shrink()` for a tab not yet visited.

## 2. The helper

`packages/skotiq_app/lib/screens/sequencer/widgets/sequence_tree.dart`,
next to `treeNodeKeyRegistryProvider`:

```dart
void revealSequenceRow(
  BuildContext rowContext, {
  required double alignment,
  required Duration duration,
}) {
  final position = Scrollable.maybeOf(rowContext)?.position;
  final target = rowContext.findRenderObject();
  if (position == null || target == null || !target.attached) return;
  position.ensureVisible(
    target,
    alignment: alignment,
    duration: animationDuration(rowContext, duration),
    curve: SkotiqTokens.curveStandard,
  );
}
```

`Scrollable.maybeOf(rowContext)` is the nearest enclosing scrollable, which for
a registry row key is always the tree's own viewport; `ScrollPosition.ensureVisible`
applies the offset to that position and nothing else.

A free function rather than a controller object: the callers already hold the
row's `BuildContext` (they resolve it through `treeNodeKeyRegistryProvider`),
so a provider-published controller would add plumbing without adding
information. It lives beside the registry provider it is always used with.

The curve is fixed inside the helper because all five sites passed
`SkotiqTokens.curveStandard` — the map's jump and the run's own scroll are
one movement started by different hands (spec §9).

## 3. Sites converted

| site | alignment | duration | note |
|---|---|---|---|
| `sequence_tree.dart` `_scrollToCurrentNode` | 0.3 | `durationSlow` | the run's auto-follow — fires on every step |
| `sequence_tree.dart` `_scrollToPinnedRow` | 0 | `durationSlow` | sticky-ancestor pin tap |
| `sequence_minimap.dart` `navigateToSequenceMapRow` | `_navigateAlignment` | `_navigateDuration` | map / gutter jump |
| `sequence_step_finder.dart` `_jumpTo` | 0.3 | `durationSmooth` | Find a step |
| `target_queue_panel.dart` `_InSequenceRow._select` | 0.3 | `durationSlow` | "In this sequence" |

Alignments and duration TOKENS are unchanged at every site. One behaviour
changed on purpose: Find a step passed its duration raw, so it animated even
under `MediaQuery.disableAnimations`; routed through the helper it now honours
the platform's no-motion request like the other four.

Checked and deliberately left alone:

- `sequence_tree/gutter_map.dart` `_dragTo` / `_pageBy` drive
  `widget.scrollController` directly (`jumpTo` / `animateTo`), so they were
  never able to touch an ancestor. Correct as they stand.
- `sequence_tree/sticky_ancestors.dart` has no scroll route of its own; its pin
  taps come back through `_scrollToPinnedRow`.

`grep -rn "Scrollable.ensureVisible" lib/screens/sequencer/widgets/` now returns
one hit: the sentence in the helper's own doc comment explaining the bug.

## 4. Proof — widget tests

`packages/skotiq_app/test/screens/sequencer/sequence_reveal_no_pager_scroll_test.dart`
(new, 5 cases) pumps the whole `SequencerScreen` at 1400x700 with a 20-sub tree
that overflows its viewport, and for each entry point asserts **on every frame**
of the transition that

- the `SequenceTree` Rect is unchanged,
- the `NodePropertiesPanel` Rect is unchanged,
- the screen pager's scroll offset is unchanged,

and afterwards that the TREE's own offset *did* change, so a case cannot pass by
doing nothing.

| case | driven by | tree Rect pre-fix |
|---|---|---|
| run auto-follow | `sequenceProgressProvider.updateProgress(currentNodeId:)` | `L=251.1` (−12.9 px) |
| pinned-ancestor tap | tap the pin inside `sequenceStickyAncestorsKey` | `L=223.8` (−40.2 px) |
| gutter jump | tap near the top of `sequenceGutterMapKey` | `L=251.1` (−12.9 px) |
| Find a step | `showSequenceStepFinder`, type, tap the match | `L=246.6` (−17.4 px) |
| "In this sequence" | tap the target row in `TargetQueuePanel` | `L=251.1` (−12.9 px) |

Expected in all five: `Rect.fromLTRB(264.0, 102.0, 1100.0, 700.0)`. With the
helper reverted to `Scrollable.ensureVisible` all five fail on the first sampled
frame; with the helper in place all five pass.

## 5. Proof — the running app (release build)

Bundle built in this worktree (`flutter build linux --release`) with the
campaign bridge copied over it
(`libskotiq_bridge.campaign-1858542796.so`; `rustContentHash => -1858542796`).
Harness on `:93`, profile `w6reveal` seeded from the ledger preview with
`observer_longitude` set to `67.0` so the executor accepts the run. Measurement:
`ffmpeg -f x11grab` at 20-25 fps over a 1600x46 band across the canvas bar —
static content INSIDE the pager, so any pager movement shifts all of it —
then per-frame column-profile cross-correlation against the last settled frame.

Pre-fix runs used the `f1f739da1` bundle (before both fixes).

| action | pre-fix peak shift | post-fix peak shift |
|---|---|---|
| inspector Activity tab (the w6-inspector-shift defect, as a control that the method works) | **+39 px** over 4 frames, recovering through +4, +2, 0 | **0 px** / 125 frames |
| gutter jump on "NGC 7000 + M31 · full night" | 0 px / 125 frames | **0 px** / 125 frames |
| full "Sim run · short" execution (18-19 s, 6/6 frames, ~10 node transitions) | 0 px / 1200 frames | **0 px** / 1100 frames |

Read this honestly: **at 1600x900 the tree paths did not visibly bounce the
pager, pre-fix or post-fix.** The same measurement, same band, same build caught
the inspector bar's 39 px lurch, so the method is not blind — the tree sites
simply land on a pager offset of 0 at that geometry, while at the 1400x700 the
widget test uses they move 12.9-40.2 px. The offset a host scrollable receives
depends on the row's rectangle inside the host's viewport, so the same code is
quiet on one window size and lurches on another. The fix removes the mechanism
rather than one geometry's symptom.

Behaviour preserved, verified in the same live build:

- the gutter jump lands on exactly the same row post-fix as pre-fix (NGC 7000 at
  the top of the viewport in both captures),
- the inspector's Activity tab still opens,
- the sim run completes identically: 18 s / 6/6 frames pre-fix, 19 s / 6/6
  frames post-fix, 0 rejected in both.

Evidence: `/tmp/ns-audit/{iframes_pre,iframes_post,gframes_pre2,gframes_post,rframes_pre,rframes_post}`,
`/tmp/ns-audit/shots/rv-*.png`.

## 6. Verification (unpiped, exit codes as recorded)

```
flutter test test/screens/sequencer --concurrency=3    EXIT=0   749 passed
flutter test <this file>                               EXIT=0   5 passed
dart analyze (packages/skotiq_app)                 EXIT=2   886 issues, zero naming a touched file
dart format --output=none --set-exit-if-changed
  packages/skotiq_app skotiq_core skotiq_ui EXIT=0
flutter build linux --release                          EXIT=0
```

`dart analyze` exits 2 because the baseline contains infos; 886 is what this
commit's tree reports with and without this change, and no issue names
`sequence_tree.dart`, `sequence_minimap.dart`, `sequence_step_finder.dart`,
`target_queue_panel.dart` or the new test.

Note on the test count: the brief expected 729 on base. The suite reports 749
with this change's 5 cases included, so the base on `f705b0e15` is 744 — the
729 figure is stale, not a sign of skipped tests.

## 7. Left undone

The same ancestor-walking `Scrollable.ensureVisible` is still used outside the
sequencer builder, where the host is not a pager and the symptom has not been
reproduced: `screens/analytics/widgets/science_export_hub.dart:195`,
`screens/analytics/widgets/science_analytics_tab/tab_sections.dart:9`,
`screens/darkroom/darkroom_screen_parts/_recipe_panel.dart:116`,
`screens/onboarding/steps/device_picker_step.dart:525`,
`screens/settings/widgets/settings_widgets/settings_section_and_row.dart:151`.
Each would need its own host check before being converted; none is in this
workstream's file list.
