/// View state for run-length folding (spec §6), plus the visible-order
/// projection that keeps keyboard navigation and the minimap honest once a
/// folded row replaces its members.
///
/// Split from `sequence_fold_model.dart` on purpose: the model is pure Dart,
/// while this file needs riverpod and [VisibleNode] (declared in
/// `sequence_tree_shortcuts.dart`, which transitively imports
/// `flutter/material`). Wave 2 wires [applyFoldsToVisibleOrder] into
/// `visibleNodeOrderProvider` — that file is owned by another workstream, so
/// the projection is exposed here as a pure function instead.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'sequence_fold_model.dart';
import 'widgets/sequence_tree_shortcuts.dart';

/// Ids of the [FoldGroup]s the user has expanded back into member rows.
///
/// Default is FOLDED (empty set): the spec makes a fold the Ledger-density
/// rendering and unfolding the per-group exception, so the set tracks only
/// the exceptions. autoDispose so a fresh session starts folded — fold state
/// is view state, not document state, and a stale expansion would outlive
/// the run it described.
final unfoldedGroupIdsProvider =
    StateNotifierProvider.autoDispose<UnfoldedGroupIdsNotifier, Set<String>>(
        (ref) => UnfoldedGroupIdsNotifier());

/// Holds the set of expanded [FoldGroup] ids. Modelled on
/// `_CollapsedNodeIdsNotifier` (the collapse-state sibling in
/// `sequence_tree_shortcuts.dart`) with the polarity flipped: membership here
/// means EXPANDED, because the fold is the default.
class UnfoldedGroupIdsNotifier extends StateNotifier<Set<String>> {
  UnfoldedGroupIdsNotifier() : super(const <String>{});

  bool isUnfolded(String groupId) => state.contains(groupId);

  /// Expand a folded group into its member rows.
  void unfold(String groupId) {
    if (state.contains(groupId)) return;
    state = {...state, groupId};
  }

  /// Collapse an expanded group back into its folded row.
  void fold(String groupId) {
    if (!state.contains(groupId)) return;
    state = Set<String>.from(state)..remove(groupId);
  }

  void toggle(String groupId) {
    if (state.contains(groupId)) {
      fold(groupId);
    } else {
      unfold(groupId);
    }
  }
}

/// Remove the members a folded row hides from [order], keeping each group's
/// FIRST member — it stands in for the whole run so arrow keys and the
/// minimap treat a folded row as one row, exactly as §6 requires.
///
/// The fold scan runs over every parent in the tree (each child is visited
/// once, so the pass stays O(nodes)); depths are untouched because a folded
/// row renders where its first member already sat. [unfoldedGroupIds] selects
/// which groups are expanded — their members stay in the order untouched.
List<VisibleNode> applyFoldsToVisibleOrder(
  List<VisibleNode> order,
  Sequence sequence,
  Set<String> unfoldedGroupIds,
) {
  if (order.isEmpty) return order;

  Set<String>? hidden;
  for (final node in sequence.nodes.values) {
    if (node.childIds.isEmpty) continue;
    for (final entry in foldChildren(
      sequence,
      node.id,
      unfoldedGroupIds: unfoldedGroupIds,
    )) {
      if (entry is FoldedEntry) {
        // Members are leaves (the fold predicates require empty childIds), so
        // hiding them cannot orphan a descendant row.
        (hidden ??= <String>{}).addAll(entry.group.memberIds.skip(1));
      }
    }
  }
  if (hidden == null) return order;

  return <VisibleNode>[
    for (final visible in order)
      if (!hidden.contains(visible.id)) visible,
  ];
}
