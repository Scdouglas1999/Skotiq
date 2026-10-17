# W2A — Sticky ancestors, auto-collapse, gutter map — report

Workstream: `w2a-navigation`. Branch `agent/w2a-navigation`, base commit
`c40989dda` (verified with `git rev-parse HEAD`; the tree was already on it — no
checkout needed). Spec sections delivered: **§4 (auto-collapse to the running
branch)**, **§5 (sticky ancestors)**, **§7 (gutter map)**, plus the §9 motion
gating for both new animations.

## What was built

### 1. Auto-collapse to the running branch — `sequence_tree/auto_collapse.dart` (new part)

A pure planner plus the listeners that drive it.

- `sequenceAncestorIds(sequence, nodeId)` — the node's ancestors, outermost
  first, root excluded (the root is not a drawn row) and cycle-guarded. Shared
  with the sticky-ancestor pass.
- `AutoCollapsePlan { toExpand, toCollapse }` and
  `planAutoCollapse({sequence, previousNodeId, currentNodeId, statuses,
  collapsed, userExpanded, followExecution})`.
  - `previousNodeId == null` **is** the run-start case: every finished
    container in the sequence is a candidate. Non-null means the run moved on,
    and only the containers it has just LEFT (the ancestors-or-self of the
    previous node that are not ancestors-or-self of the current one) are.
  - `toExpand` is the executing node's collapsed ancestors, always.
  - A candidate is **shielded** when it — or anything it sits inside — is
    already collapsed (nothing on screen left to fold) or is in `userExpanded`
    (the operator asked to see in there; gutting it one level down answers a
    question they did not ask). Both of those turned up as real defects when
    the tests first ran: without the ancestor half of the rule, folding a
    user-opened target instead folded the loop inside it.
  - `toCollapse` keeps only the OUTERMOST of each chain. Folding a container
    inside one you are already folding changes nothing now and surprises the
    operator when they reopen the outer one onto a collapsed inner one.
  - Completeness: a node's own `success / skipped / cancelled` status, OR a
    container whose children are all complete. `failure` and `running` are
    never complete — a failed branch is the one outcome the operator has to
    look at, so it stays open.
- Wiring in `_SequenceTreeState` (three `ref.listen`s, plus four methods):
  - `sequenceProgressProvider.select((p) => p.currentNodeId)` →
    `_onExecutingNodeChanged`, which also carries the pre-existing
    manual-scroll reset.
  - `sequenceExecutionStateProvider` → `_onExecutionStateChanged`, firing the
    run-start plan on a transition INTO `running` from anything but `running`
    or `paused` (a resume is not a fresh start; the tree is already folded to
    where the run left off).
  - `collapsedNodeIdsProvider` → `_onCollapsedSetChanged`, which maintains
    `_userExpandedIds` (see deviation 3).
  - An id leaves `_userExpandedIds` when the run reaches that node or enters
    its branch (it has now run, so the operator's manual expansion stops
    protecting it), and when the operator collapses it again.

### 2. Sticky ancestors — `sequence_tree/sticky_ancestors.dart` (new part)

- `pinnedAncestorsOf(sequence, anchorId, isRowAbove)` — pure given the
  caller's geometry predicate; returns `VisibleNode` records (id + tree depth,
  which is what a ledger row needs for its guide columns), at most three, the
  NEAREST three when the chain is deeper.
- `_SequenceTreeState._computePinnedAncestors()` measures live render boxes
  through the existing `_nodeKeyRegistry`: it walks `visibleNodeOrderProvider`
  only as far as the first row still partly visible (the anchor), then keeps
  the anchor's ancestors whose own row's BOTTOM is at or above the viewport
  top — i.e. rows that are fully gone, so a row is never drawn twice.
  Short-circuits when `maxScrollExtent <= 0`. The viewport's top edge comes
  from a `GlobalKey` on the tree's `SingleChildScrollView`.
- `_scheduleStickyPass()` guards to ONE pass per frame
  (`addPostFrameCallback` + a bool), scheduled from the scroll-controller
  listener and from the tree's layout pass.
- Rendering: `_StickyAncestorStack` — `surfaceElevated`, a bottom hairline and
  the design system's one floating shadow
  (`SkotiqDecorations.popover(colors).boxShadow`), taking the scroll
  view's own horizontal padding so a pin sits over the column of the row it
  stands for. Ledger pins are real `_LedgerRow(pinned: true)`; Compact pins
  are `_PinnedCompactRow`, a single 28 px line (Compact keeps today's cards,
  which are far too tall to stack three deep over a viewport).
- `_PinEntrance` slides each new pin down 6 px and fades it in over
  `durationQuick`, zero under `MediaQuery.disableAnimations`.
- Interaction: `GestureDetector(behavior: HitTestBehavior.translucent,
  onTap:) → IgnorePointer(row)`. Translucent is load-bearing: an opaque hit
  box would leave the wheel and the drag-scroll dead in the top 84 px of the
  canvas, and would hide the drop targets under it from a palette drag.
  Tapping a pin runs `Scrollable.ensureVisible(alignment: 0)` on the real row.

### 3. Gutter map — `sequence_minimap.dart` (extracted) + `sequence_tree/gutter_map.dart` (new part)

`sequence_minimap.dart` now holds the model and painter BOTH maps use:

- `SequenceMapEntry`, `sequenceMapEntries(sequence, order)` (from
  `visibleNodeOrderProvider`, so a block can never point at a row the tree is
  not showing), `sequenceMapRowAt(dy, extent, rowCount)`,
  `sequenceMapViewportRect({offset, viewportDimension, maxScrollExtent,
  size})`, `sequenceMapMetrics(controller)` and
  `navigateToSequenceMapRow(...)` — all pure or controller-only, so the tests
  can assert the same arithmetic the painter draws.
- `SequenceMapPainter` (was the private `_MinimapPainter`): blocks coloured by
  `nodeCategoryTint` — the same function the rows' glyphs use, replacing a
  duplicate category switch — run state outranking category, the selected
  outline, the viewport rectangle and the execution line.

`_SequenceGutterMap` is 34 px at the right edge of the tree's scroll area,
always on in Ledger; the 80 px strip is suppressed there and keeps governing
Comfortable and Compact through `minimapVisibleProvider`. Tap jumps (select +
`ensureVisible`), a vertical drag scrolls, and the whole gutter is one
`Semantics(slider: true, label: 'Sequence overview', value: 'row N of M',
excludeSemantics: true)`.

The tree's layout became
`Expanded(Row[ Expanded(Stack[scroll view, pinned stack]), gutter ])`, with
`StackFit.expand` so the scroll view keeps the tight height the `Expanded` it
replaced gave it.

## Deviations from the brief / spec, and why

1. **`planAutoCollapse` gained a `followExecution` parameter.** The brief's
   signature has none, but its own test list asks for a PURE "follow off →
   empty plan" case. One extra named parameter keeps that rule in the tested
   layer instead of only in the widget.
2. **`previousNodeId == null` discriminates run start from a node move** —
   the brief's signature has no other flag, and this is the honest reading:
   at a run start there is no previous node.
3. **No chevron hook.** The brief allowed one call in `ledger_row.dart`'s and
   `node_item.dart`'s chevron `onTap`. Instead `_userExpandedIds` is
   maintained by DIFFING `collapsedNodeIdsProvider`, subtracting the
   expansions this widget just applied (`_pendingAutoExpansions`). That covers
   every manual path at once — both chevrons, the Left/Right arrows,
   Collapse-all / Expand-all — instead of two of them, and it edits neither
   file. Subtracting a recorded id set rather than holding a boolean "I am
   writing now" window makes it correct whether Riverpod delivers the listener
   synchronously or not.
4. **Container completeness is derived when its own status is missing** (all
   children complete ⇒ complete). The executor does emit `NodeCompleted` for
   containers, but a branch should not sit open waiting for a message that
   adds nothing after its last child has finished.
5. **A failed branch is never folded.** Not in the spec's wording; a fold that
   hides a failure is the one fold the operator cannot afford.
6. **Only the outermost finished container in a chain folds** (see above).
7. **The shield covers descendants** of collapsed and user-expanded
   containers, not just the container itself.
8. **One viewport-indicator treatment for both maps.** Spec §7 specifies
   `primary` at 12 % fill + a 1 px border for the gutter; the 80 px strip used
   to dim everything OUTSIDE the viewport instead. Sharing one painter means
   sharing one treatment, and the fill is the one that reads correctly in a
   34 px column — a strip that dims most of itself reads as disabled. The
   strip therefore loses its outside scrim.
9. **Block colours moved to `nodeCategoryTint`.** The old painter carried its
   own copy of the same four-way switch. The `success` block's alpha moves
   0.7 → `SkotiqTokens.opacityMuted` (0.6) so it is a token rather than a
   literal.
10. **The gutter's drag is delta-based** from the grab point, not an absolute
    gutter-y → offset mapping: grabbing the viewport rectangle anywhere inside
    it must not snap the grab point to its centre. A tap still jumps.
11. **A pin appears only when its row is FULLY above the viewport top**
    (bottom ≤ top), not merely when its top is. The looser test draws the same
    row twice for 28 px of scrolling.
12. **The pinned stack's anchor is measured against the raw viewport top,**
    not the top plus the stack's own height. Offsetting by the stack height is
    a feedback loop (the height depends on the anchor); as an overlay the
    simple rule has no layout consequence.
13. **`ledger_row.dart` was edited beyond the `pinned` flag** — the two target
    coordinate chips became `Flexible` and `_LedgerChip`'s label ellipsises.
    Required, not optional: the gutter takes 34 px out of every ledger row,
    and the fixed-width chips then overflowed
    `builder_narrow_desktop_test.dart` by 17 px. The same overflow is
    reachable on the BASE commit at the documented `_ledgerColumnsMinWidth`
    floor (500 px leaves the name ~63 px, and the chips need ~136), so this is
    a pre-existing defect my change merely moved a passing test onto. With the
    fix the chips give ground the way the name already did.
14. **`_ledgerColumnsMinWidth` is now tested against `contentWidth - 34`** —
    the gutter comes out of the same width as the columns, so a canvas that
    only fits the columns by spending the gutter's pixels cannot host Ledger.
    Rows still get at least 500 px in both densities' decision.
15. **A Compact pin names a target by `displayName`**, which is what
    `TargetHeaderCard` titles itself with, rather than `node.name`. A pin that
    names something other than the row it stands for is worse than no pin.
    (Ledger pins use `_LedgerRow`, so they match ledger rows by construction.)
16. **A fourth test file** beyond the three the brief lists —
    `sequence_tree_auto_collapse_test.dart` — covers the wiring: which signals
    the tree listens to, whether it can tell its own expansions from the
    operator's, and whether Follow execution really stops it. The pure planner
    test proves none of that, and the diff-based user-expansion tracking is
    the part most able to go wrong.
17. **`sequenceMapMetrics` exists at all** because both maps build inside a
    `LayoutBuilder`, which runs before the scroll view beside them has content
    dimensions on the first frame; reading `maxScrollExtent` there throws
    rather than returning zero.

## Tests

New, all under `packages/skotiq_app/test/screens/sequencer/`:

- `auto_collapse_plan_test.dart` — 12 pure cases: ancestor order, run start
  (expand the branch, fold finished ones, outermost only), derived container
  completeness, half-finished stays open, the node move, moving inside the
  same branch, the user-expanded guard with its control case, a pending
  container is not a candidate, a failed branch, an already-collapsed
  container, follow off, and no/unknown executing node.
- `sequence_tree_auto_collapse_test.dart` — 5 widget cases on the live tree:
  the run leaving a finished target folds it, the executing branch is
  re-opened, a container the operator re-opened is left alone, the tree's OWN
  expansion is not mistaken for the operator's, follow off stops everything.
- `sequence_tree_sticky_ancestors_test.dart` — 7 cases in a 300 px viewport
  driving the real scroll view: nothing pins at rest; scrolling past the
  target pins target + loop and the entrance lands flush with the viewport
  top; scrolling back unpins; the pin adds no second semantics node; tapping a
  pin brings the real row back to the top; Compact pins a single line naming
  the target its card names; Comfortable never pins; the animations-disabled
  path builds.
- `sequence_gutter_map_test.dart` — 9 cases: the gutter is 34 px in Ledger and
  absent in Comfortable and Compact; the 80 px strip stays out of Ledger even
  with the toggle on, and still answers the toggle in Compact; the slider
  announces `row N of M` and follows the scroll; the viewport rectangle's top
  moves with the offset while its height holds; tapping the gutter's bottom
  selects AND reveals the last row; dragging the gutter scrolls the tree.

A note on the harness: a `Scrollable.ensureVisible` started by the frame
before a `pump(Duration)` does not move, because the controller takes its start
time from its FIRST tick and that pump IS the first tick. Every drain in these
files therefore pumps a zero-length frame first and two timed frames after —
without it the tap-a-pin test silently asserted nothing.

## Commands run (unpiped exit codes)

```
cd packages/skotiq_app && dart analyze
```
EXIT=2 — **891 issues, identical to the base commit's 891**: zero net new
diagnostics (0 errors, 0 warnings in `lib/screens/sequencer`). The base commit
is not analyze-clean repo-wide; the 891 are the pre-existing 7 warnings + 884
info lints WS1 recorded.

```
dart format --output=none --set-exit-if-changed \
  packages/skotiq_app packages/skotiq_core packages/skotiq_ui
```
EXIT=1 — 11 files, ALL pre-existing drift on the base commit in files this
workstream does not own (`status_bar*`, `mount_site_*`, `imaging_chain.dart`,
`device_operations.dart`, weather/status-bar tests). Re-check of exactly the
10 files this workstream touched: `Formatted 10 files (0 changed)`, EXIT=0.

```
cd packages/skotiq_app && flutter test test/screens/sequencer \
  --concurrency=3        # TMPDIR=$HOME/.cache/ns-tmp/w2a-navigation
```
EXIT=0 — **644 passed** (base: 611; +33 new: 12 pure + 21 widget).

No other test directory imports `sequence_tree.dart`, `sequence_minimap.dart`
or `ledger_row.dart`
(`grep -rln … test/ | grep -v '^test/screens/sequencer/'` is empty), so
`test/screens/sequencer` is the whole blast radius.

## Left undone

- **A trigger row's `Watchdog` badge can still overflow a ledger row** at the
  `_ledgerColumnsMinWidth` floor: the badge is ~85 px of fixed width against a
  ~63 px name budget at depth 1. Pre-existing on the base commit, independent
  of the gutter (it is reachable at 500 px either way), and the fix belongs in
  `support_widgets.dart`, which another workstream owns. Recorded rather than
  silently patched.
- The 11 pre-existing format-drift files and the 891 pre-existing analyzer
  diagnostics outside this workstream's file list are untouched.
- No live GUI check: the campaign closes on `melos run test`, the production
  gates and a seeded full-night run through `tools/ui_audit/drive_linux.py`.
  Everything here is verified in widget tests against the real scroll view and
  the real gesture wiring, not on a running desktop bundle.
