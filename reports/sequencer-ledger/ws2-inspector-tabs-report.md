# WS2 — Inspector tabs (Settings / Activity / Notes)

Workstream: `ws2-inspector-tabs` · spec §8 (+ the Activity-tab "frame landed" pop from §9)
Base commit: `23147bf0a` (verified `git rev-parse HEAD` at session start — matched, no checkout needed)
Branch: `agent/ws2-inspector-tabs`

## Design decisions / deviations (running log)

- **Exposure Activity layout.** The spec'd frame grid (success / primary /
  surfaceOverlay cells + `N of M done · capturing K` caption + total
  integration + thumbnail strip) IS the exposure node's activity view in the
  inspector. I deliberately do NOT also render `_ExposureProgressPanel`
  (returned by `getProgressPanelForNode` for exposures): that panel already
  contains its own frame grid and stat boxes, so stacking both would paint two
  grids carrying ~90% identical information. The generic
  `getProgressPanelForNode` covers every non-exposure leaf; the new grid
  section carries the same facts in the spec's form.
- **Frame-math duplication.** `_ExposureProgressPanel`'s
  tally > structured > parsed-string > node.count precedence is mirrored in a
  small resolver inside `node_activity_tab.dart` rather than refactoring the
  panel — the brief restricts `node_progress_panels` edits to the last-known
  factoring, and the tree-side copy is owned by another workstream.
- **Last-known persistence as a provider.** `_NodeItem`'s `_lastKnown*`
  fields/remember/forget logic is factored into
  `lastKnownNodeActivityProvider` (a `StateNotifierProvider` folding
  `sequenceProgressProvider` deltas per node id, clearing on a fresh
  `running` transition exactly like `didUpdateWidget` does). The tree keeps
  its own copy for now per the brief; the inspector shares this one.
- **Comment clearing.** `SequenceNode.copyWith(comment:)` is keep-or-replace
  (null keeps), so "no comment" is committed as `''` — the tree's italic line
  and the tab dot both check `isNotEmpty`.
- **Notes dot.** `AdaptiveTab` has no dot slot (skotiq_ui is out of
  scope), so the Notes tab label gains a `•` suffix when the node has a
  comment; `semanticLabel` announces "Notes, has comment".
- **Banner on mobile.** `_SelectedNodeBanner` is pinned at the bottom of the
  mobile sheet as well as the desktop sidebar, per "pinned at the bottom
  regardless of tab". It self-hides when the node has no issues.
- **Subtree progress** reuses `plannedCaptureUnder` for totals (all three
  capture node types) and derives "done" per node from
  `sequenceProgressProvider.nodeStatuses` + `nodeExposureTallyProvider`,
  carrying the same repeat-caveat semantics as
  `targetExecutionProgressProvider` (per-pass statuses can't scale across a
  loop repeat → completion is reported as unknown rather than fabricated).
- **Notes commit.** Multi-line field; commits on focus loss and on
  `onSubmitted` (Enter). Guarded by `canEditSequenceProvider` and routed
  through `withSequenceMutation` like every other inspector edit.
  `onTapOutside` unfocuses the field explicitly, because Flutter does not
  auto-unfocus a `TextField` when another widget is tapped — without it,
  switching tabs would drop the half-typed note silently. When the selection
  moves to a DIFFERENT node while the field holds uncommitted text,
  `didUpdateWidget` commits that text against the node it was typed on
  rather than letting it bleed onto the newly selected node.
- **Iconless tabs.** `AdaptiveTabBar` collapses labelled tabs to icons below
  480 px (`collapseLabelsWhenTight`, default on, tuned for the 4-tab page
  header). The inspector is a 300 px sidebar where icon-only
  Settings/Activity/Notes would be cryptic, so the collapse is disabled and
  the tabs are text-only (icons cost ~28 px/tab and pushed the strip past
  even 340 px, clipping "Notes" behind the scroll affordance). The bar's
  own overflow scrolling remains as the fallback on narrower hosts.
- **Pop-animation re-baseline.** When the captured count DROPS (a loop's
  next pass resets the tally), `_previousCaptured` is reset to 0 so the
  first landing of the new pass pops as well — otherwise a completed count
  of 1 against a remembered 12 would never re-arm the animation.

## Commands run (exit codes appended as I go)

- `git rev-parse HEAD` → `23147bf0a472b314da1e458384cb9cacf9d5973c` (exit 0)
- `graphify update .` → exit 0 (graph was missing in this worktree)
- `flutter test test/screens/sequencer/node_properties_panel_tabs_test.dart
  --concurrency=4` → exit 0, 11/11 (run with
  `TMPDIR=$HOME/.cache/ns-tmp/ws2-inspector-tabs`)
- `flutter test test/screens/sequencer --concurrency=4` → exit 0,
  **518/518** (507 base + 11 new)
- `dart format --output=none --set-exit-if-changed packages/skotiq_app
  packages/skotiq_core packages/skotiq_ui` → exit 1 — **pre-existing
  drift on the base commit**: the 11 unformatted files are all outside my
  file list (`status_bar*`, `mount_site*`, `weather_alert*`,
  `device_operations`, `imaging_chain`, `mount_site_reconciler*`); none are
  in my diff. Scoped to my 6 files the same command exits 0.
- `cd packages/skotiq_app && dart analyze` → exit 2, 891 issues —
  **all pre-existing on the base** (0 errors; unused-import warnings +
  deprecation infos in files outside this workstream). Scoped to my files:
  0 issues of any severity. Base count was 893; the change nets −2
  (removed a `surfaceAlt` use the notes editor would have added, and no new
  diagnostics).
- `graphify update .` (post-implementation) → exit 0

### Post-review verification

- `flutter test test/screens/sequencer/node_properties_panel_tabs_test.dart
  --concurrency=4` → exit 0, 21/21
- `flutter test test/screens/sequencer --concurrency=4` → exit 0,
  **528/528**
- `dart analyze` on all touched files (incl. `sequencer_screen.dart`) →
  exit 0, 0 issues
- `dart format --set-exit-if-changed` on all touched files → exit 0
- `dart analyze` on `node_item.dart` (untouched, out of scope) reports the
  one expected `dead_null_aware_expression` warning noted under fix 9.

## Review fixes (adversarial review of 8ee4f68eb)

1. **HIGH — snapshots survived into run #2.** `reset()` empties the
   progress maps, so `if (ids.isEmpty) return;` made a new run invisible to
   the fold. Fixed by listening to `sequenceExecutionStateProvider` inside
   the notifier: entering `running` from a `canStart` state
   (idle/completed/failed — the enum's own admission set) clears the map.
   `paused`/`recovering` → `running` (resume) deliberately does not clear.
   Test: `a NEW run clears last-known activity…` + provider-level
   `clears every snapshot when a new run enters running from a settled
   state`.
2. **HIGH — lazy provider saw nothing.** The notifier only existed once
   the Activity tab was built. `NodePropertiesPanel.build` now watches
   `lastKnownNodeActivityProvider` (keeps it alive whenever the inspector
   exists — which is also what makes the widget test honest), and
   `sequencer_screen.dart` got the permitted ONE `ref.watch` line (+ the
   import needed to see the provider) so the fold runs even with the panel
   closed. Test: `Activity shows last-known values after the run clears
   the maps — seeded while the Settings tab was shown`.
3. **HIGH — double commit / write-during-build in the Notes editor.**
   `didUpdateWidget` committed synchronously against the stale
   `oldWidget.node`: a duplicate undo entry plus a
   `currentSequenceProvider` write mid-build (Riverpod asserts in debug).
   Both deferred paths (node-switch and unmount) now write via
   `Future.microtask` + `_commitText`, which re-reads the LIVE comment from
   `currentSequenceProvider` before comparing — so a commit that already
   landed dedupes instead of writing twice. The interactive path
   (focus-loss, Ctrl+Enter) keeps `withSequenceMutation` but also compares
   against the fresh provider value. Test: `selecting another node commits
   the typed note exactly once, against the node it was typed on`
   (counts writes per node; asserts no build-phase assert by simply
   pumping).
4. **MED — "-1 of 12 done" caption.** `liveFrame - 1` with `liveFrame == 0`
   (just-entered `running`, no tally/detail yet) went negative.
   `completed` is now clamped to `[0, totalFrames]`, matching
   `_ExposureProgressPanel`'s intent (`headerFrames` never goes negative).
   Test: `a just-started node captions 0 done, not -1`.
5. **MED — dead "commits on Enter".** `onSubmitted` never fires on a
   multiline field (Enter inserts a newline). Removed it; added a
   `CallbackShortcuts` Ctrl+Enter / Cmd+Enter commit (the key event is seen
   before the field consumes it) and the help text now says
   "Ctrl+Enter saves." Test: `Ctrl+Enter commits the comment from inside
   the field`.
6. **MED — pop fired on selection.** `_previousCaptured` started at 0, so
   opening Activity on a node with 6 captured frames popped as if six
   frames just landed. A `_seeded` flag now makes the first build (and
   every build after a node switch) adopt the resolved count as baseline;
   only a real increment pops. The new-pass drop still re-arms the
   animation. Test: `frame-landed pop does not fire on selection, only on
   a real increment`.
7. **MED — rebuild storm.** The tab watched the whole
   `sequenceProgressProvider` and the whole tally map. It now watches
   per-node `.select` slices (`nodeStatuses[id]`, `percent[id]`,
   `detail[id]`, `structuredDetail[id]`, `currentFilter`, snapshot[id],
   tally[id]). `NodeActivitySnapshot` and `SubtreeActivity` gained value
   equality so `select` dedupes; containers read a
   `_subtreeActivityProvider(node.id)` family (recompute per tick, rebuild
   only when the numbers move). Tests: `value equality` group.
8. **MED — note lost on unmount.** The focus listener was removed before
   `_focusNode.dispose()`, so a focused field unmounted mid-edit dropped
   its text. `dispose()` now schedules `_commitText` on a microtask
   through the `ProviderContainer` captured in `initState` (`ref`/`context`
   are invalid there — `containerOf` throws after deactivate). Test:
   `unmounting the Notes tab commits the pending note`.
9. **LOW — nullable factory.** `getProgressPanelForNode` now returns
   `Widget`; the `?? SizedBox.shrink()` at my call site is gone.
   **Known consequence:** the untouched call site in `node_item.dart:327`
   now reports `dead_null_aware_expression` — that file is owned by the
   density workstream (its inline panels, and this `??`, are being
   removed there); I may not edit it.
10. **LOW — double announcement.** Both `Semantics(label:)` wrappers
    (frame grid, subtree section — two sites) now set
    `excludeSemantics: true`, so the label is the single announcement
    instead of label-plus-inner-text.

## Left undone

- The tree's private `_lastKnown*` copy in `node_item.dart` is deliberately
  left in place — the density-mode workstream removes it when the inline
  panels move; `lastKnownNodeActivityProvider` is the shared slot they will
  switch to. Its `?? SizedBox.shrink()` after `getProgressPanelForNode` is
  now a `dead_null_aware_expression` warning owned by the same removal.
