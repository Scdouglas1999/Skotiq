# w6-queue-panel — the toolbox "Queue" tab becomes "Targets"

Branch `agent/w6-queue-panel`, base `f1f739da1`.

## The complaint

The owner loaded the bundled "Mono LRGB M51" starter — a sequence with a target
in it — and the toolbox's Queue tab said "Your target queue is empty." Two
things were wrong at once. The tab named a *queue* the app has three of (the
planetarium wishlist, the autopilot's scheduler queue, and this pane), and the
panel was blind to the targets the loaded sequence already carries, so it
reported "empty" about a screen that was visibly full of M51.

His verdict: "it should be changed to be more clear what it means and why it's
there."

## What shipped

### 1. The tab is called Targets

`sequencer_screen_parts/toolbox_panel.dart` — `SegmentedControl` segments are
now `['Nodes', 'Snippets', 'Targets']`. The segment label is also the segment's
accessible name (the control publishes `button` + `enabled` + `selected` +
`label` per segment), so the rename is the screen-reader announcement too; no
separate a11y string exists to drift from it.

`SequencerToolboxTab.queue` → `SequencerToolboxTab.targets` in
`sequencer_screen.dart`. Checked first that nothing persists the enum by name:
`AppSettingsState.sequencerToolboxTab` and `setSequencerToolboxTab` exist in
core but have no caller, so there is no stored value to strand. Nothing
referenced `SequencerToolboxTab.queue` by name either, so the rename is the
declaration alone.

Alt-shortcut behaviour is unchanged. Alt+1..4 select the screen-level tabs
(Builder / Templates / Sequences / History), not the toolbox panes, and Ctrl+T
still toggles Nodes ↔ Snippets. The comment above Ctrl+T claimed "from the
Queue tab it switches to Snippets"; the code does the opposite (anything that
is not Nodes goes to Nodes), so the comment now describes what actually runs.

### 2. The panel has two sections

`widgets/target_queue_panel.dart`, one `CustomScrollView` over both sections —
they are one list of targets read twice, and two independently scrolling boxes
in a ~280 px column would each be a few rows tall and neither would reach its
end.

**In this sequence** (top) — one row per `TargetHeaderNode` from
`Sequence.targetHeaders`, deliberately the same list the canvas bar counts in
its "N targets" chip, so the panel and the chip two panes away cannot disagree.
Each row carries:

- the target name;
- RA/Dec chips at arcminute precision, `CoordinateFormat.raHm` /
  `decDm` with `SexagesimalStyle.compactLetters` and `wrapHours` — the exact
  call the ledger target row makes, so the same target reads identically in the
  panel and in the tree;
- a "Not set" chip in `warning` when `targetCoordinatesUnset(node)`, instead of
  printing 0h/+0° as a settled pointing (that placeholder is a real point in
  Pisces);
- a planned-capture summary from the shared `plannedCaptureUnder` walk.

Tapping a row clears the multi-selection, sets `selectedNodeIdProvider`, and
scrolls the tree to the node through `treeNodeKeyRegistryProvider` +
`Scrollable.ensureVisible` at alignment 0.3 and `durationSlow` — the same jump
(same landing spot, same speed) the step finder and the minimap make, routed
through `animationDuration` so `MediaQuery.disableAnimations` gets zero. A
target inside a collapsed container has no key and so no scroll; selection
still lands and the inspector follows it, which is the limit the step finder
already has.

Empty state, one sentence:

> No targets in this sequence yet. Drop a Target from the Nodes tab, or pick
> one below.

**Saved for later** (below) — the planetarium wishlist, unchanged in function:
`targetQueueProvider`, sort and filter dropdowns, live altitude / max / sets
readouts on the 30 s ticker, `LongPressDraggable<TargetQueueDragPayload>` onto
the tree, add-to-sequence, remove, and the existing "active target"
highlighting driven by the executor's current target. Its empty copy is now:

> Targets you queue from the Planetarium or Plan Tonight appear here, ready to
> drag into the sequence.

The section header and that sentence stay on screen when the wishlist is empty,
so the pane says what the wishlist IS rather than only reporting that it has
nothing. The sort/filter bar is hidden while there is nothing to sort.

Copy that went away, and why:

- "Your target queue is empty." — a headline about a container the reader did
  not ask about, in the one place where the sequence's own targets belong.
- "Add targets from Plan Tonight → Planetarium, then drag them into the
  sequence tree to start a plan. This queue is the builder's own — the autopilot
  runs the separate scheduler queue in Plan Tonight → Schedule." — four clauses,
  two arrow-joined navigation paths, and a disambiguation between two other
  queues that only exists because the tab was called Queue. Renaming the tab
  deleted the need for the paragraph.

### 3. Chrome

- Section headers are the repo's eyebrow (`SkotiqTypography.eyebrow` in
  `textMuted`, uppercased at render, the `node_palette` group-label pattern)
  with the row count at the right.
- The panel's own "Target Queue" title bar is gone: the segmented control above
  it already names the pane, and a title under it said the word twice. Its
  unused `onCollapse` parameter went with it (no caller passed one — the
  toolbox has its own collapse button).
- The redundant `Container(color: surface, border right)` wrapper is gone; the
  toolbox already paints both, and the sibling Nodes/Snippets panes do not draw
  their own.
- Migrated this file's three uses of the deprecated `colors.surfaceAlt` to
  `colors.well` so the two sections' rows share one tone (and the analyzer
  count drops by those three).

## Tests

`test/screens/sequencer/widgets/target_panel_in_sequence_test.dart` (new):

- `targetPlanSummary` unit tests: counted frames (`12 frames · 12m`), the
  singular (`1 frame · 1m`), a non-`count` loop making it a floor (`4 frames ·
  4m per pass`), an open-ended Smart Exposure described rather than counted as
  zero (`Looping up to 2h 0m`), and a bare target (`No exposures yet`).
- two target headers render in tree order with their chips and summaries;
- a target at 0h/+0° shows "Not set" and never prints `00h00m` / `+00°00'`;
- tapping a row sets `selectedNodeIdProvider` AND moves a real scroll view: the
  harness pumps the panel beside a stand-in tree whose rows carry the registered
  `GlobalKey`s, so the tap exercises the real `Scrollable.ensureVisible` path
  rather than a stub, and the test asserts the offset came off zero;
- an empty sequence, and no sequence at all, both show the one sentence with
  the wishlist section still visible below.

`test/screens/sequencer/widgets/target_queue_panel_test.dart` (extended): the
empty-wishlist test now pins the new sentence and the persistent section header
and asserts the old "Your target queue is empty." headline is gone; a new test
pins that the sentence gives way to the list once a target is queued. The
existing drag-payload, add-to-sequence and remove-from-queue tests are
unchanged and still pass.

`test/screens/sequencer/toolbox_tab_role_test.dart`: added a guard that the
third segment is named `Targets`.

`test/screens/sequencer/builder_narrow_desktop_test.dart`: this file, not the
role test, was the one asserting the literal label — three `'Queue'` assertions
(pane-open proof and two a11y loops) updated to `'Targets'`.

## Deviations from the brief

- **The widget class is still `TargetQueuePanel`, in `target_queue_panel.dart`.**
  Renaming it would edit `test/screens/planetarium/add_to_target_queue_test.dart`
  and `widgets/sequence_tree_queue_drop_test.dart`, outside the file list the
  brief fenced me to, and the name it shares with `TargetQueueDragPayload` is
  the contract `sequence_tree.dart` accepts. The file's header comment says so.
- **Chips are a local `_TargetChip`, not the ledger's `_LedgerChip`.**
  `sequence_tree/ledger_row.dart` is `part of sequence_tree.dart`, so its
  private chip cannot be imported. The local one takes the same
  `SkotiqDecorations.chip` + `SkotiqTypography.overline` + tone
  contract, so the visual is the ledger's.
- **Touched four files the brief did not name.** `sequencer_screen.dart` (the
  enum value and two stale/wrong comments), `builder_narrow_desktop_test.dart`
  (the `'Queue'` label assertions), `skotiq_ui/segmented_control.dart` (a
  doc comment that cites this control by its old segment names), and
  `docs/design/overhaul/{05-components,06-screens}.md` (the same citation in
  the spec). All are one-line label changes; leaving them would have left the
  spec and the kit naming a tab that no longer exists.
- **Did not touch** `design_system_gallery.dart`, whose sample segmented control
  is also spelled `['Nodes', 'Snippets', 'Queue']`: it is covered by
  `test/golden/design_gallery_golden_test.dart`, and the brief forbids touching
  goldens. `skotiq_ui/test/components/touch_target_floor_test.dart` uses
  `['Nodes', 'Queue']` as arbitrary sample strings, not as a claim about the
  sequencer.
- `sequence.targetHeaders` is ordered by `orderIndex` and skips disabled
  targets, which is what the canvas bar counts. That is the consistency the
  brief asked for, so the panel inherits both properties rather than doing its
  own tree walk.

## Commands (unpiped exit codes)

| command | exit |
| --- | --- |
| `dart format --output=none --set-exit-if-changed packages/skotiq_app packages/skotiq_core packages/skotiq_ui` | 0 (3808 files, 0 changed) |
| `cd packages/skotiq_app && dart analyze` | 2 — 886 issues, all pre-existing info-level; base is 890, and none of the 886 are in a file this branch touched |
| `cd packages/skotiq_app && flutter test test/screens/sequencer --concurrency=3` | 0 — `+733: All tests passed!` |

Analyzer note: `dart analyze` exits 2 on info-level lints in this package, on
base as well as on this branch. The number went DOWN by four (890 → 886)
because the panel's deprecated `surfaceAlt` uses went with the rewrite.

Test-count note: the brief's baseline is 721 for `test/screens/sequencer`. This
branch adds 12 — ten in `target_panel_in_sequence_test.dart`, one in
`target_queue_panel_test.dart`, one in `toolbox_tab_role_test.dart` — for 733.
The first full run flagged two failures, both in
`builder_narrow_desktop_test.dart` asserting the literal label `'Queue'`; that
file is where the tab name was really pinned, and updating those three
assertions is part of the rename. `TMPDIR=$HOME/.cache/ns-tmp/w6-queue-panel`
throughout.

## The live look — attempted, blocked

Built the bundle in this worktree (`cd apps/desktop && flutter build linux
--release`, exit 0) and copied
`/home/scdouglas/.cache/ns-worktrees/cargo-target/release/libskotiq_bridge.so`
into `build/linux/x64/release/bundle/lib/`, with the audit profile seeded from
`/home/scdouglas/.cache/skotiq-ledger-preview/data` minus
`skotiq.db.lock`. The app refused to start:

```
Bad state: Native bridge failed to initialize: libskotiq_bridge.so could
not be loaded, or it is stale relative to this build.
```

The copied `.so` is byte-identical in size to the one in the `preview-merged`
and `w8-performance` bundles, so it is the newest shared build; the mismatch is
between that library and this tree's generated Dart bridge, not a bad copy. The
fix would be a `cargo build --release` writing into the SHARED
`ns-worktrees/cargo-target` that other agents are reading from mid-run, which is
not a side effect to cause from inside one workstream — so the run was stopped
there. `drive_linux.py --profile w6queue stop` reported
`stopped app_pid 2083544` / `stopped xvfb_pid 2083439`; nothing of mine is left
running and no other worktree was touched.

The panel's behaviour is therefore evidenced by the widget tests, including the
tap-selects-and-scrolls one that drives a real `Scrollable`, not by a
screenshot. Worth a look on the next build that has a matching bridge.

## Left undone

Nothing else in the brief.
