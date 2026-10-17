# Sequencer Ledger — product spec

Status: approved direction 2026-09-13 (owner picked "A · Ledger" plus all three
"F · Add-ons" from the Sequencer Night Overview canvas). This document is the
contract for the implementation; every workstream brief points here.

## The problem

A full night (setup, two targets with narrowband and LRGB loops, triggers,
shutdown) is ~40 nodes. Today every node is a 60–130 px card with its own
progress panel, thumbnail strip and notes, so the tree runs to thousands of
pixels. The user scrolls blind and cannot evaluate the plan they built.

## What ships

### 1. Density modes

A `SequencerDensity` setting with three values, selectable from a segmented
control in the canvas bar and persisted per device:

| Mode        | Row                                  | Inline extras                          |
|-------------|--------------------------------------|----------------------------------------|
| Comfortable | today's card rows, unchanged         | progress panels, thumbnails, notes     |
| Compact     | today's rows, single summary line    | none (all moved to the inspector)      |
| Ledger      | NEW 28 px line with aligned columns  | none (all moved to the inspector)      |

Ledger is the default on desktop. Mobile keeps its own editor and is out of
scope. Switching density crossfades the tree; no layout jump of the canvas bar
or inspector.

### 2. Ledger row anatomy

Fixed 28 px height. Left to right:

1. Depth guides: 18 px per level, a 1 px `colors.border` vertical line.
2. Chevron (containers only, 12 px), rotates 90° on expand/collapse.
3. Node icon, 13 px, in the node's category colour (same palette the palette
   uses today).
4. Name (600 weight for containers, 400 for leaves). A collapsed container
   appends its **rollup summary** in `textMuted`, ellipsised.
5. Existing chips where they carry state (`running`, `×12`, validation badge).
6. Four right-aligned monospace columns, fixed widths 70 / 60 / 74 / 62 px:
   **Filter / exp**, **Count**, **Duration**, **ETA**. Column header row above
   the tree (26 px, eyebrow style).
7. A 2 px progress bar along the bottom edge: primary while running, success
   when complete, hidden when nothing has run.

States: running = primary tint background + 2 px primary left border;
selected = `surfaceElevated`; multi-selected = as today; done = name in
`textMuted`. Hover reveals the row's inline actions (drag handle, overflow
menu) on the right, fading in.

Column semantics:

- Exposure / smart exposure: Filter/exp = `Ha 300s`; Count = frame count;
  Duration = count × exposure (+ known overhead if the estimator has it);
  ETA = predicted start clock time.
- Container: Count = total frames in the subtree; Duration = subtree estimate;
  ETA = subtree start.
- Delay / wait-for-time / others with a known length: Duration and ETA only.
- ETA comes from the existing pre-session simulation
  (`sequenceTimelineProvider`); blank when there is no location or the
  simulation cannot place the node. During a run, ETA for finished nodes
  shows the actual start time.

### 3. Rollup summaries on collapse

A pure function produces a one-line description of a container's contents:

- Loop of exposures differing only by filter: `Ha · OIII · SII 300 s ×12 each · dither every 3`.
- A target: `North America Nebula · Ha/OIII/SII` (target name + filter set).
- Generic: first three child names joined by ` · `, then `+k more`.
- Trigger group: `meridian flip ~23:12 · autofocus after 1°C / 60 min`.

Unit-tested in isolation. Shown in Ledger and Compact modes.

### 4. Auto-collapse to the running branch

When a run starts and Follow execution is on: expand the ancestors of the
executing node; collapse containers whose status is complete. On each change
of the executing node: expand its ancestors; collapse the container that just
completed. Containers the user opened by hand and that have not run yet stay
open. Turning Follow execution off stops all automatic collapsing.

### 5. Sticky ancestors

While scrolling, the ancestor rows (target, loop) of the topmost visible row
pin to the top of the tree viewport when their own row has scrolled out of
view, stacked in depth order, at most three deep. They render in the same row
style on `surfaceElevated` with a soft bottom shadow. Clicking a pinned row
scrolls to it. Pinned rows are not duplicated in the accessibility traversal
order (mark them `excludeSemantics`, the real row remains reachable).

### 6. Run-length folding

In Ledger mode only, contiguous sibling exposure nodes that differ only by
filter (same duration, gain, offset, binning, frame type, dither settings)
fold into one row: name `Ha · OIII · SII`, Filter/exp `300 s ×12 each`, per
member progress in the summary (`Ha 6/12 · OIII 6/12 · SII 6/12`). The
contiguous quartet slew / center / start guiding / autofocus (any order,
all leaves) folds into `Acquire target` with a chip naming its members.

A fold is view state (`unfoldedGroupIds`): the chevron expands it into the
member rows, which are ordinary rows. Clicking a folded row multi-selects its
members so the existing batch toolbar edits them together. Dragging a folded
row moves all members as a contiguous block. Deleting asks once and deletes
all members. Keyboard navigation treats a folded row as one row (members are
hidden from the visible order until unfolded).

### 7. Gutter map

In Ledger mode the minimap is an always-on 34 px gutter on the right edge of
the tree viewport: one block per visible row, coloured by node category,
running row highlighted, a viewport rectangle that can be dragged to scroll,
click to jump. The existing minimap toggle continues to govern Comfortable and
Compact.

### 8. Inspector tabs

The node inspector gets tabs: **Settings** (today's properties),
**Activity** (progress panel, frame grid, thumbnail strip, per-frame stats
that today render inline in the tree), **Notes** (today's notes panel).
Containers get Settings / Activity (subtree progress) / Notes. The tab bar is
the `skotiq_ui` adaptive tab bar; the active tab persists per node type.

### 9. Animations

Subtle, short, and every one gated by `MediaQuery.disableAnimations` (zero
duration when set). Use `SkotiqTokens` durations and curves; no bespoke
timings.

- Expand / collapse: `AnimatedSize` on the children block plus a fade-and-
  slide of 6 px; chevron rotation.
- Density switch: crossfade between the old and new row sets.
- Running row: the 2 px progress bar tweens its width; the left border
  breathes (opacity 0.55 → 1.0, 2.4 s, ease-in-out) inside an
  `OnScreenAnimationGate` whose `RepaintBoundary` is OUTSIDE the gate.
- Hover: background tint and inline actions fade in over the short token.
- Drop zones: grow from 0 to their height and fade in when a drag starts.
- Sticky ancestors: slide down 6 px and fade in when they pin.
- Frame landed: the corresponding progress-grid cell in the Activity tab
  pops (scale 0.6 → 1.0) once.
- Selection outline: animated colour.

### 10. Untouched behaviours (must keep working in every density)

Palette drag-in to the root, into containers, and between rows; reorder by
drag; the context menu; every shortcut in `sequence_tree_shortcuts.dart`;
Find step; multi-select and the batch toolbar; undo / redo; validation
badges; tutorial keys; Timeline and Map toggles; the accessibility semantics
of every row (a row's label includes its columns).

## Verification bar

Every workstream: `dart analyze` clean, `dart format` clean, its own tests plus
`packages/skotiq_app/test/screens/sequencer` green, no committed Linux
goldens. The campaign closes on the full `melos run test`, the production
gates listed in `.github/workflows`, and a live GUI check of a seeded
full-night sequence in the release bundle through `tools/ui_audit/drive_linux.py`.
