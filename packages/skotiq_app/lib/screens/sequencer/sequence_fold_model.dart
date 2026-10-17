/// Run-length folding for the sequence tree — the MODEL half of spec §6.
///
/// In Ledger density the tree collapses two kinds of contiguous sibling runs
/// into a single row:
///
///   * a `filterRun` — ≥2 enabled [ExposureNode]s identical in every capture
///     field except `filter`/`filterIndex` (the classic "same subs through a
///     filter wheel" block: `Ha · OIII · SII`, `300 s ×12 each`);
///   * an `acquireTarget` — the 3-or-4-leaf run of slew / center / start
///     guiding / autofocus that opens a target (`Acquire target`).
///
/// This file is deliberately Flutter-free: it is pure Dart over
/// `skotiq_core` so the fold logic stays trivially unit-testable and can
/// run on every tree build without touching the widget layer. The riverpod
/// view-state (`unfoldedGroupIdsProvider`) and the `VisibleNode` projection
/// (`applyFoldsToVisibleOrder`) live in the sibling `sequence_fold_state.dart`
/// precisely because they need imports (`VisibleNode` is declared in
/// `sequence_tree_shortcuts.dart`, which pulls in `flutter/material`) that
/// would break this file's purity.
///
/// Rendering (wave 2) consumes [foldChildren] per parent instead of the raw
/// child list; the returned [TreeEntry]s are the ONLY contract it sees, so the
/// shapes here carry everything a folded row needs to paint — label, chip,
/// shared capture spec, member ids and per-member labels — without a second
/// pass over `Sequence.nodes`.
library;

import 'package:equatable/equatable.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'ledger_seconds.dart';

/// Which kind of contiguous sibling run a [FoldGroup] collapses into one row.
enum FoldKind {
  /// ≥2 enabled [ExposureNode]s that differ only by filter.
  filterRun,

  /// The leaf run {slew, center, start guiding, autofocus} — any order, each
  /// type at most once, 3 or 4 members.
  acquireTarget,
}

/// One row of a parent's children AFTER folding is applied: either a real
/// node or a folded group. Equatable so tests and provider `select`s can
/// compare entry lists structurally.
sealed class TreeEntry extends Equatable {
  const TreeEntry();
}

/// A child that renders as its own row — never foldable, or a member of a
/// group the user has unfolded.
final class SingleEntry extends TreeEntry {
  /// The child node as it appears in `Sequence.nodes`.
  final SequenceNode node;

  const SingleEntry(this.node);

  @override
  List<Object?> get props => [node];
}

/// A contiguous sibling run collapsed into one folded row.
final class FoldedEntry extends TreeEntry {
  /// The group the folded row stands in for.
  final FoldGroup group;

  const FoldedEntry(this.group);

  @override
  List<Object?> get props => [group];
}

/// A contiguous run of children folded into one row.
///
/// Immutable and [Equatable]-comparable: two builds producing the same fold
/// yield equal groups, so `Provider.select` / `didUpdateWidget` style change
/// detection works on the whole object.
class FoldGroup extends Equatable {
  /// Stable group identity.
  ///
  /// Derived ONLY from the sorted member ids (see [_foldGroupId]) — never
  /// from names, positions, or sibling state — so the id survives edits
  /// anywhere else in the tree, including renames of the members themselves.
  /// That stability is what makes `unfoldedGroupIds` meaningful: a set of
  /// ephemeral ids would forget the user's expansion on every rebuild.
  final String id;

  /// Which run kind produced this group.
  final FoldKind kind;

  /// Member node ids in tree order. The first id is the group's
  /// representative in the visible order — it stands in for the whole run for
  /// keyboard navigation and the minimap.
  final List<String> memberIds;

  /// Per-member display labels, aligned with [memberIds].
  ///
  /// For [FoldKind.filterRun] these are the filter names (`Ha`, `OIII`,
  /// `#3` when only a filter index is set, the node name as last resort). For
  /// [FoldKind.acquireTarget] they are the short verbs (`slew`, `center`,
  /// `guide`, `AF`) in tree order. Carried on the group because
  /// [foldProgressText] is deliberately `Sequence`-free: both the label join
  /// and the per-member progress text read from here.
  final List<String> memberLabels;

  /// Id of the parent whose child list this run came from.
  final String parentId;

  /// Index of the first member within the parent's child list. Wave-2
  /// drag/drop needs it to re-inject a moved group at the right slot; it is
  /// positional, not identity, so it can change between builds without
  /// affecting [id].
  final int firstIndex;

  /// Folded-row title: `Ha · OIII · SII` for a filter run, `Acquire target`
  /// for the acquire run.
  final String label;

  /// Folded-row summary chip: `300 s ×12 each` for a filter run,
  /// `slew · center · guide · AF` for the acquire run.
  final String chipText;

  // Shared capture spec — non-null only for [FoldKind.filterRun]. Carried so
  // the folded row and its inspector can render/edit the run's shared capture
  // parameters without dereferencing a member node.
  /// Per-sub exposure length shared by every member, in seconds.
  final double? durationSecs;

  /// Frames per member.
  final int? count;

  /// Shared camera gain override.
  final int? gain;

  /// Shared camera offset override.
  final int? offset;

  /// Shared binning mode.
  final BinningMode? binning;

  /// Shared frame type.
  final FrameType? frameType;

  /// Shared dither cadence (every N frames).
  final int? ditherEvery;

  FoldGroup({
    required this.id,
    required this.kind,
    required List<String> memberIds,
    required List<String> memberLabels,
    required this.parentId,
    required this.firstIndex,
    required this.label,
    required this.chipText,
    this.durationSecs,
    this.count,
    this.gain,
    this.offset,
    this.binning,
    this.frameType,
    this.ditherEvery,
  })  : memberIds = List.unmodifiable(memberIds),
        memberLabels = List.unmodifiable(memberLabels);

  /// Number of members the folded row stands in for.
  int get memberCount => memberIds.length;

  @override
  List<Object?> get props => [
        id,
        kind,
        memberIds,
        memberLabels,
        parentId,
        firstIndex,
        label,
        chipText,
        durationSecs,
        count,
        gain,
        offset,
        binning,
        frameType,
        ditherEvery,
      ];
}

/// What a folded row carries in a drag.
///
/// A distinct payload type — rather than the `String` node id an ordinary row
/// drags — because every [DragTarget] in the tree has to be able to tell "one
/// node" from "this whole run": the run moves as a contiguous block, in one
/// undo step, and a target that mistook it for a `String` would move only the
/// row under the pointer.
class FoldDragPayload extends Equatable {
  /// The dragged group's [FoldGroup.id], so a target can refuse a drop that
  /// would land the run inside itself.
  final String groupId;

  /// Member ids in tree order. The block is re-inserted in this order.
  final List<String> memberIds;

  /// The parent the run currently sits under.
  final String parentId;

  FoldDragPayload({
    required this.groupId,
    required List<String> memberIds,
    required this.parentId,
  }) : memberIds = List.unmodifiable(memberIds);

  @override
  List<Object?> get props => [groupId, memberIds, parentId];
}

/// The [FoldGroup] that [nodeId] belongs to, or null when the node is not part
/// of a run at all.
///
/// Deliberately computed with an EMPTY unfolded set: the caller (the Left /
/// Right arrow actions) needs the group whether or not it is currently
/// expanded, and [foldChildren] only constructs a [FoldGroup] for the runs it
/// folds. Compare the returned [FoldGroup.id] against `unfoldedGroupIds` to
/// learn which of the two states the run is in.
///
/// O(siblings): one fold pass over the node's own parent, never the tree.
FoldGroup? foldGroupForNode(Sequence sequence, String nodeId) {
  final parentId = sequence.nodes[nodeId]?.parentId;
  if (parentId == null) return null;
  for (final entry in foldChildren(
    sequence,
    parentId,
    unfoldedGroupIds: const <String>{},
  )) {
    if (entry is FoldedEntry && entry.group.memberIds.contains(nodeId)) {
      return entry.group;
    }
  }
  return null;
}

/// Walk [parentId]'s children in order and fold the contiguous runs §6
/// describes, returning one [TreeEntry] per resulting row.
///
/// Run rules:
///   * `filterRun` — a contiguous block of ENABLED leaf [ExposureNode]s is
///     split into sub-runs by capture-spec equality; each sub-run of ≥2 folds.
///     `filter`, `filterIndex`, `id`, `name`, `orderIndex`, `comment` and
///     `triggers` are the ONLY fields allowed to differ inside a run.
///   * `acquireTarget` — a contiguous block of ENABLED leaf nodes whose types
///     are all in {slew, center, start guiding, autofocus} folds iff it holds
///     3 or 4 members with each type at most once. A duplicate type means two
///     separate acquire passes, not one — the whole block stays unfolded.
///
/// A disabled or non-leaf node is simply not a candidate, so it breaks
/// contiguity by falling out of the run scan rather than by special-casing.
///
/// Groups whose id is in [unfoldedGroupIds] are emitted as their
/// [SingleEntry] members instead of a [FoldedEntry] — that is the entirety of
/// the "unfold" behaviour; member rows are ordinary rows.
///
/// O(children) and allocation-light: one pass, one entry per emitted row, and
/// [FoldGroup] construction is skipped entirely for unfolded groups. It runs
/// on every tree build, so nothing here may look past the parent's own child
/// list.
List<TreeEntry> foldChildren(
  Sequence sequence,
  String parentId, {
  required Set<String> unfoldedGroupIds,
}) {
  final children = sequence.childrenOf(parentId);
  if (children.isEmpty) return const <TreeEntry>[];

  final entries = <TreeEntry>[];
  var i = 0;
  while (i < children.length) {
    final child = children[i];
    if (_isFoldableExposure(child)) {
      var end = i + 1;
      while (end < children.length && _isFoldableExposure(children[end])) {
        end++;
      }
      _emitExposureBlock(children, i, end, parentId, unfoldedGroupIds, entries);
      i = end;
    } else if (_isAcquireLeaf(child)) {
      var end = i + 1;
      while (end < children.length && _isAcquireLeaf(children[end])) {
        end++;
      }
      _emitAcquireBlock(children, i, end, parentId, unfoldedGroupIds, entries);
      i = end;
    } else {
      entries.add(SingleEntry(child));
      i++;
    }
  }
  return entries;
}

/// Per-member progress text for the folded row's summary column:
/// `Ha 6/12 · OIII 6/12 · SII 6/12`.
///
/// Captured counts come from the same sources `_ExposureProgressPanel` reads,
/// in the same precedence — the typed [ExposureInstructionProgressDetail]
/// first, the legacy string detail second, node status last — with ONE
/// documented gap: the panel's preferred source, `nodeExposureTallyProvider`,
/// is a separate provider and therefore not visible through the
/// [SequenceProgress] parameter this signature is fixed to. Structured detail
/// carries the same number the tally counts (`frame` is a post-capture count,
/// see `node_exposure_tally.dart`), so the divergence is limited to hosts
/// whose executor emits no structured progress at all.
///
/// Only meaningful for [FoldKind.filterRun]; returns an empty string for
/// other kinds and whenever no member has run data yet (a pending run must
/// not render `0/12` noise over the whole row).
String foldProgressText(FoldGroup group, SequenceProgress progress) {
  if (group.kind != FoldKind.filterRun) return '';

  final fallbackPlanned = group.count ?? 0;
  final frames = List<({int captured, int planned})?>.filled(
    group.memberIds.length,
    null,
  );
  var anyProgress = false;
  for (var i = 0; i < group.memberIds.length; i++) {
    frames[i] = _memberFrameProgress(
      group.memberIds[i],
      fallbackPlanned,
      progress,
    );
    anyProgress = anyProgress || frames[i] != null;
  }
  if (!anyProgress) return '';

  return <String>[
    for (var i = 0; i < group.memberIds.length; i++)
      '${group.memberLabels[i]} ${frames[i]?.captured ?? 0}'
          '/${frames[i]?.planned ?? fallbackPlanned}',
  ].join(' · ');
}

/// Ids of every node hidden inside the folded groups of [entries] — the set
/// a tree renderer must NOT draw as individual rows. Includes the members'
/// representative (member 0) too: callers that need "draw these ids" vs "hide
/// these ids" distinguish via [FoldedEntry] itself; this is the membership
/// set, used for selection expands ("click selects all members").
Set<String> foldedMemberIds(List<TreeEntry> entries) => <String>{
      for (final entry in entries)
        if (entry is FoldedEntry) ...entry.group.memberIds,
    };

// Run detection

/// Filter runs fold frames the night will actually shoot: a disabled node
/// breaks the run, and a non-leaf is excluded because a folded row cannot
/// show its subtree.
bool _isFoldableExposure(SequenceNode node) =>
    node is ExposureNode && node.isEnabled && node.childIds.isEmpty;

/// Same gates for the acquire quartet: leaf-only (a folded row hides no
/// children) and enabled-only (a disabled slew is not part of the acquire).
bool _isAcquireLeaf(SequenceNode node) =>
    node.isEnabled &&
    node.childIds.isEmpty &&
    (node is SlewNode ||
        node is CenterNode ||
        node is StartGuidingNode ||
        node is AutofocusNode);

/// Emit a maximal contiguous block of foldable exposures, split into sub-runs
/// by capture-spec equality: a differing member splits the run AT that point
/// (the matching prefix still folds) rather than voiding the whole block.
void _emitExposureBlock(
  List<SequenceNode> children,
  int start,
  int end,
  String parentId,
  Set<String> unfoldedGroupIds,
  List<TreeEntry> entries,
) {
  var runStart = start;
  for (var k = start + 1; k <= end; k++) {
    if (k == end ||
        !_sameCaptureSpec(
          children[runStart] as ExposureNode,
          children[k] as ExposureNode,
        )) {
      if (k - runStart >= 2) {
        _emitGroupOrSingles(
          children: children,
          start: runStart,
          end: k,
          unfoldedGroupIds: unfoldedGroupIds,
          entries: entries,
          buildGroup: (groupId, memberIds) => _filterRunGroup(
            children,
            runStart,
            k,
            parentId,
            groupId,
            memberIds,
          ),
        );
      } else {
        entries.add(SingleEntry(children[runStart]));
      }
      runStart = k;
    }
  }
}

/// The capture-spec fields a filter run must share. Everything the spec lists
/// as free to differ — `id`, `name`, `orderIndex`, `filter`, `filterIndex`,
/// `comment`, `triggers` — is deliberately absent; everything else (including
/// [ExposureNode.adaptiveExposure], which silently changes what the sub
/// costs) must match.
bool _sameCaptureSpec(ExposureNode a, ExposureNode b) =>
    a.durationSecs == b.durationSecs &&
    a.count == b.count &&
    a.frameType == b.frameType &&
    a.gain == b.gain &&
    a.offset == b.offset &&
    a.binning == b.binning &&
    a.ditherEvery == b.ditherEvery &&
    a.adaptiveExposure == b.adaptiveExposure;

/// Emit a maximal contiguous block of acquire-type leaves. The block folds
/// only when it IS one acquire pass: 3 or 4 members, each leaf type at most
/// once. Any other shape — a pair, five nodes, a duplicated slew — is ordinary
/// rows, because folding it would invent a semantic the operator didn't write.
void _emitAcquireBlock(
  List<SequenceNode> children,
  int start,
  int end,
  String parentId,
  Set<String> unfoldedGroupIds,
  List<TreeEntry> entries,
) {
  final size = end - start;
  var valid = size == 3 || size == 4;
  if (valid) {
    final seen = <Type>{};
    for (var m = start; m < end; m++) {
      if (!seen.add(children[m].runtimeType)) {
        valid = false;
        break;
      }
    }
  }
  if (!valid) {
    for (var m = start; m < end; m++) {
      entries.add(SingleEntry(children[m]));
    }
    return;
  }
  _emitGroupOrSingles(
    children: children,
    start: start,
    end: end,
    unfoldedGroupIds: unfoldedGroupIds,
    entries: entries,
    buildGroup: (groupId, memberIds) => _acquireGroup(
      children,
      start,
      end,
      parentId,
      groupId,
      memberIds,
    ),
  );
}

/// Emit one [FoldedEntry] for the run, or its members as [SingleEntry]s when
/// the group is unfolded. The group id is computed BEFORE construction so an
/// unfolded group never pays for a [FoldGroup] it won't use.
void _emitGroupOrSingles({
  required List<SequenceNode> children,
  required int start,
  required int end,
  required Set<String> unfoldedGroupIds,
  required List<TreeEntry> entries,
  required FoldGroup Function(String groupId, List<String> memberIds)
      buildGroup,
}) {
  final memberIds = <String>[
    for (var m = start; m < end; m++) children[m].id,
  ];
  final groupId = _foldGroupId(memberIds);
  if (unfoldedGroupIds.contains(groupId)) {
    for (var m = start; m < end; m++) {
      entries.add(SingleEntry(children[m]));
    }
    return;
  }
  entries.add(FoldedEntry(buildGroup(groupId, memberIds)));
}

FoldGroup _filterRunGroup(
  List<SequenceNode> children,
  int start,
  int end,
  String parentId,
  String groupId,
  List<String> memberIds,
) {
  final first = children[start] as ExposureNode;
  final memberLabels = <String>[
    for (var m = start; m < end; m++) _filterLabel(children[m] as ExposureNode),
  ];
  return FoldGroup(
    id: groupId,
    kind: FoldKind.filterRun,
    memberIds: memberIds,
    memberLabels: memberLabels,
    parentId: parentId,
    firstIndex: start,
    label: memberLabels.join(' · '),
    chipText:
        '${formatLedgerSeconds(first.durationSecs)} s ×${first.count} each',
    durationSecs: first.durationSecs,
    count: first.count,
    gain: first.gain,
    offset: first.offset,
    binning: first.binning,
    frameType: first.frameType,
    ditherEvery: first.ditherEvery,
  );
}

/// Member verbs are emitted in tree order — the chip says what will actually
/// run, so a shuffled acquire (`guide · slew · AF`) honestly reads shuffled.
FoldGroup _acquireGroup(
  List<SequenceNode> children,
  int start,
  int end,
  String parentId,
  String groupId,
  List<String> memberIds,
) {
  final memberLabels = <String>[
    for (var m = start; m < end; m++) _acquireVerb(children[m]),
  ];
  return FoldGroup(
    id: groupId,
    kind: FoldKind.acquireTarget,
    memberIds: memberIds,
    memberLabels: memberLabels,
    parentId: parentId,
    firstIndex: start,
    label: 'Acquire target',
    chipText: memberLabels.join(' · '),
  );
}

/// The folded-row name for one filter-run member: the filter it shoots, or a
/// positional `#N` when only a wheel index is configured (the same convention
/// `node_summary.dart` uses for unnamed SmartExposure plans), or the node
/// name when neither exists.
String _filterLabel(ExposureNode node) {
  final filter = node.filter;
  if (filter != null && filter.isNotEmpty) return filter;
  final index = node.filterIndex;
  if (index != null) return '#${index + 1}';
  return node.name;
}

/// Short member verb for the acquire chip. Callers have already confined the
/// input to the four acquire leaf types, so the wildcard is unreachable — it
/// throws rather than guessing because silently mislabelling a member is the
/// failure mode this function exists to prevent.
String _acquireVerb(SequenceNode node) => switch (node) {
      SlewNode() => 'slew',
      CenterNode() => 'center',
      StartGuidingNode() => 'guide',
      AutofocusNode() => 'AF',
      _ => throw StateError('not an acquire leaf: ${node.runtimeType}'),
    };

/// Frames captured for one member, or null when the member has no run data.
///
/// Precedence mirrors `_ExposureProgressPanel`: structured detail, then the
/// string detail, then node status. A structured `frame` is already a
/// captured count (the native callback fires after the frame lands); the
/// string wordings distinguish "Frame n/m" (n in flight → n-1 captured) from
/// "Completed n/m" (n captured) — see `exposure_progress_vocabulary.dart`.
({int captured, int planned})? _memberFrameProgress(
  String nodeId,
  int fallbackPlanned,
  SequenceProgress progress,
) {
  final structured = progress.nodeProgressStructuredDetail[nodeId];
  if (structured is ExposureInstructionProgressDetail && structured.total > 0) {
    return (
      captured: structured.frame.clamp(0, structured.total),
      planned: structured.total,
    );
  }
  final parsed = parseExposureProgressDetail(
    progress.nodeProgressDetail[nodeId] ?? '',
  );
  if (parsed != null) {
    final captured = parsed.frameCompleted ? parsed.frame : parsed.frame - 1;
    return (
      captured: captured.clamp(0, parsed.total),
      planned: parsed.total > 0 ? parsed.total : fallbackPlanned,
    );
  }
  switch (progress.nodeStatuses[nodeId]) {
    case NodeStatus.success:
      return (captured: fallbackPlanned, planned: fallbackPlanned);
    case NodeStatus.running ||
          NodeStatus.failure ||
          NodeStatus.skipped ||
          NodeStatus.cancelled:
      return (captured: 0, planned: fallbackPlanned);
    case NodeStatus.pending || null:
      return null;
  }
}

/// Stable group id: FNV-1a over the SORTED member ids.
///
/// Hand-rolled rather than `String.hashCode` because Dart's string hash is
/// seeded per isolate launch — an id built from it would point at a different
/// group after every restart, orphaning `unfoldedGroupIds`. Member-derived
/// (not name- or position-derived) so the id survives renames and reorders
/// that leave the run's membership untouched.
String _foldGroupId(List<String> memberIds) {
  final sorted = List<String>.of(memberIds)..sort();
  var hash = 0xcbf29ce484222325;
  for (final id in sorted) {
    for (final unit in id.codeUnits) {
      hash = ((hash ^ unit) * 0x100000001b3) & 0x7fffffffffffffff;
    }
    // Member separator: without it ['ab', 'c'] and ['a', 'bc'] collide.
    hash = ((hash ^ 0x1f) * 0x100000001b3) & 0x7fffffffffffffff;
  }
  return 'fold-${hash.toRadixString(16).padLeft(15, '0')}';
}
