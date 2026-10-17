# WS3 — Run-length folding model (spec §6, model half)

Workstream: `ws3-fold-model`. Base: `23147bf0a` (verified via `git rev-parse HEAD` —
no checkout needed). Scope: pure-Dart fold model + view state only. No widgets,
no edits to existing files.

## What shipped

### `packages/skotiq_app/lib/screens/sequencer/sequence_fold_model.dart` (new)

Flutter-free model library (imports only `equatable` + `skotiq_core`):

- `sealed class TreeEntry` → `SingleEntry(SequenceNode node)` /
  `FoldedEntry(FoldGroup group)`, both `Equatable`.
- `enum FoldKind { filterRun, acquireTarget }`.
- `class FoldGroup extends Equatable` — `id`, `kind`, `memberIds` (tree order,
  unmodifiable), `memberLabels`, `parentId`, `firstIndex`, `label`
  (`Ha · OIII · SII` / `Acquire target`), `chipText` (`300 s ×12 each` /
  `slew · center · guide · AF`), and the shared filterRun capture spec
  (`durationSecs`, `count`, `gain`, `offset`, `binning`, `frameType`,
  `ditherEvery`; all null for `acquireTarget`).
- `foldChildren(sequence, parentId, {required unfoldedGroupIds})` — single
  O(children) pass; exposure blocks split into sub-runs by capture-spec
  equality (≥2 folds); acquire blocks fold iff 3–4 members with each leaf
  type at most once; unfolded groups emit `SingleEntry` members.
- `foldProgressText(group, progress)` — `Ha 6/12 · OIII 12/12 · SII 2/12`;
  `''` for non-filterRun kinds and when no member has run data.
- `foldedMemberIds(entries)` — membership set (includes the representative
  member; callers distinguish hide-vs-stand-in via `FoldedEntry`).

### `packages/skotiq_app/lib/screens/sequencer/sequence_fold_state.dart` (new)

- `unfoldedGroupIdsProvider` —
  `StateNotifierProvider.autoDispose<UnfoldedGroupIdsNotifier, Set<String>>`
  with `unfold` / `fold` / `toggle` / `isUnfolded`, modelled on
  `collapsedNodeIdsProvider` (`sequence_tree_shortcuts.dart:83`) with flipped
  polarity: fold is the default, the set holds only expanded exceptions.
- `applyFoldsToVisibleOrder(order, sequence, unfoldedGroupIds)` — removes
  folded members except each group's first (which stands in for the run), for
  wave 2 to wire into `visibleNodeOrderProvider`. Depths untouched. O(nodes).

### `packages/skotiq_app/test/screens/sequencer/sequence_fold_model_test.dart` (new)

28 tests, all green. Covers every case the brief names plus: ≥2 boundary,
mid-run spec differences leaving non-contiguous matches unfolded,
name/comment-only differences folding, `#N` labels for filterIndex-only
members, non-leaf exposures never folding, acquire pair not folding,
acquire+filterRun composition, `Completed n/m` wording, pending-status
empties, unfolded-group order preservation.

## Design decisions / deviations from the brief

1. **Two files, not one.** The brief allowed the provider in "the same new
   file or a sibling `sequence_fold_state.dart`". I split it: `VisibleNode`
   lives in `sequence_tree_shortcuts.dart`, which transitively imports
   `flutter/material` — keeping it out of the model file preserves the
   "pure Dart" contract and makes the model unit-testable without Flutter.

2. **`FoldGroup.memberLabels` added beyond the brief's field list.**
   `foldProgressText(FoldGroup, SequenceProgress)` receives no `Sequence`, so
   per-member labels cannot be derived at progress time. Carrying them on the
   group (aligned with `memberIds`) also lets wave 2 render per-member chips
   without a second `nodes` lookup. Documented on the field.

3. **Progress gap documented, not patched.** `foldProgressText` reads
   `nodeProgressStructuredDetail` → `nodeProgressDetail` → `nodeStatuses`,
   the same precedence `_ExposureProgressPanel` uses — minus its preferred
   source, `nodeExposureTallyProvider`, which is a separate provider and
   unreachable through the required `SequenceProgress` signature. Impact is
   minimal: the structured `ExposureInstructionProgressDetail.frame` is the
   same post-capture count the tally records (`node_exposure_tally.dart:163`),
   so only a host emitting no structured progress at all would diverge.

4. **Leaf gate applied to both run kinds.** Spec says "all leaves" only for
   the quartet; I also require `childIds.isEmpty` for exposure runs — a folded
   row has no way to render a subtree, so a non-leaf exposure is excluded
   rather than hiding children.

5. **Sub-run splitting semantics.** A capture-spec difference splits a
   contiguous exposure block AT the difference (the matching prefix/suffix
   still folds) rather than voiding the whole block. `[Ha g120, OIII g120,
   SII g100]` → fold(Ha,OIII) + single(SII). Non-contiguous matches do not
   fold.

6. **Acquire chip in tree order.** `guide · slew · AF` honestly reads
   shuffled; the canonical `slew · center · guide · AF` appears only when the
   tree order is canonical.

7. **Group id = FNV-1a over sorted member ids** (`fold-<15 hex>`).
   `String.hashCode` is isolate-seeded, so ids built from it would orphan
   `unfoldedGroupIds` on every restart. Member-derived (not name/position)
   so renames/reorders that leave membership untouched keep the id.

8. **Invalid acquire blocks emit ALL members as singles** (no partial
   folding): a duplicated leaf type means two acquire passes, and folding a
   prefix would invent a semantic the operator didn't write.

9. **`memberIds` includes the representative** in `foldedMemberIds` output —
   the set is "which nodes belong to folded groups" (for click-to-multi-
   select), not "which rows to hide" (wave 2 uses `memberIds.skip(1)`).

## Commands run (exit codes)

| Command | Exit | Result |
|---|---|---|
| `git rev-parse HEAD` | 0 | `23147bf0a…` — matches required base |
| `dart format` (3 new files) | 0 | 2 files formatted |
| `dart analyze` (3 new files) | 0 | No issues found |
| `flutter test test/screens/sequencer/sequence_fold_model_test.dart --concurrency=4` (TMPDIR set) | 0 | 28 tests passed |
| `dart format --output=none --set-exit-if-changed packages/skotiq_app packages/skotiq_core packages/skotiq_ui` | **1** | 11 files flagged — see below |
| `cd packages/skotiq_app && dart analyze` | **2** | 891 issues — all pre-existing, see below |
| `cd packages/skotiq_app && flutter test test/screens/sequencer --concurrency=4` (TMPDIR set) | 0 | **535 tests passed** (507 base + 28 new) |

## Pre-existing gate failures (NOT introduced by this change)

Both failures exist on the base commit and touch only files outside my
allowed file list, so per the workstream rules I did not fix them.

- **`dart format --set-exit-if-changed`**: 11 files —
  `skotiq_app`: `screens/shell/widgets/status_bar.dart`,
  `screens/shell/widgets/status_bar/sequence_indicator.dart`,
  `test/screens/shell/status_bar_overflow_test.dart`,
  `status_bar_timezone_test.dart`,
  `test/widgets/weather/weather_alert_banner_monitoring_test.dart`;
  `skotiq_core`: `backend/network_backend/device_operations.dart`,
  `models/mount_site_reconciliation.dart`,
  `providers/mount_site_provider.dart`,
  `services/device_service/connections/imaging_chain.dart`,
  `services/mount_site/mount_site_reconciler.dart`,
  `test/services/mount_site_reconciler_test.dart`. Likely a formatter-version
  drift vs. the pinned Flutter 3.44.1 SDK. `--output=none` left them
  unmodified; my three files are format-clean.
- **`dart analyze` on `skotiq_app`**: 891 issues = 0 errors, 7 warnings,
  884 infos — all in test files I did not touch (`test/widgets/`,
  `test/screens/guiding/`, `test/screens/planner/`, `test/screens/shell/`),
  dominated by `deprecated_member_use` for `hasFlag`/`pipelineOwner`.
  `grep sequence_fold /tmp/analyze.log` → zero hits: my files are clean.

## Left undone / notes for wave 2

- `applyFoldsToVisibleOrder` is written but intentionally NOT wired into
  `visibleNodeOrderProvider` (`sequence_tree_shortcuts.dart` is another
  agent's file). Wiring = wrap the provider body's output with this function.
- The tally-vs-`SequenceProgress` gap above is the only known model gap;
  if wave 2 wants tally-accurate counts it can pass a richer progress object
  or read `nodeExposureTallyProvider` directly — no `skotiq_core` change
  is strictly required.
- `unfoldedGroupIdsProvider` is autoDispose per spec ("fold is view state");
  it does not persist across sessions.
