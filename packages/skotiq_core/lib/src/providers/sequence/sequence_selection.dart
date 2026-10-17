import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../models/sequence/sequence_models.dart';
import 'sequence_editor.dart';

// Sequence editor state.

/// Current sequence being edited.
///
/// The notifier implementation lives in `sequence/sequence_editor.dart`.
/// We pass `ref` so the notifier can consult
/// `sequenceExecutionStateProvider` and throw `SequenceLockedException`
/// when mutations are attempted during an active run.
final currentSequenceProvider =
    StateNotifierProvider<CurrentSequenceNotifier, Sequence?>((ref) {
      return CurrentSequenceNotifier(ref: ref);
    });

// Selected node.

/// Currently selected node ID
final selectedNodeIdProvider = StateProvider<String?>((ref) => null);

/// Currently selected node (derived)
final selectedNodeProvider = Provider<SequenceNode?>((ref) {
  final sequence = ref.watch(currentSequenceProvider);
  final selectedId = ref.watch(selectedNodeIdProvider);

  if (sequence == null || selectedId == null) return null;
  return sequence.nodes[selectedId];
});

// Multi-select.

/// Set of currently multi-selected node IDs.
final multiSelectedNodeIdsProvider =
    StateNotifierProvider<MultiSelectNotifier, Set<String>>(
      (ref) => MultiSelectNotifier(ref),
    );

/// Whether multi-select mode is active (has >0 selections).
final isMultiSelectActiveProvider = Provider<bool>((ref) {
  return ref.watch(multiSelectedNodeIdsProvider).isNotEmpty;
});

/// Clipboard for batch copy/paste operations.
/// Stores serialized node trees ready for pasting.
final nodeCopyClipboardProvider = StateProvider<List<Map<String, dynamic>>?>(
  (ref) => null,
);

class MultiSelectNotifier extends StateNotifier<Set<String>> {
  final Ref ref;

  MultiSelectNotifier(this.ref) : super({});

  /// Toggle a single node in the selection (Ctrl+Click).
  void toggle(String nodeId) {
    if (state.contains(nodeId)) {
      state = Set.from(state)..remove(nodeId);
    } else {
      state = Set.from(state)..add(nodeId);
    }
  }

  /// Range select: select all siblings between the last selected node
  /// and the clicked node (Shift+Click).
  void rangeSelect(String nodeId) {
    final sequence = ref.read(currentSequenceProvider);
    if (sequence == null) return;

    final node = sequence.nodes[nodeId];
    if (node == null || node.parentId == null) return;

    // Anchor priority: last single-selected node, else last item in current set.
    final anchor = ref.read(selectedNodeIdProvider) ?? state.lastOrNull;
    if (anchor == null) {
      state = {nodeId};
      return;
    }

    final anchorNode = sequence.nodes[anchor];
    if (anchorNode == null ||
        anchorNode.parentId == null ||
        anchorNode.parentId != node.parentId) {
      // Different parents or invalid anchor — just toggle to this node.
      state = {nodeId};
      return;
    }

    final siblings = sequence.getChildren(node.parentId!);
    final anchorIndex = siblings.indexWhere((n) => n.id == anchor);
    final targetIndex = siblings.indexWhere((n) => n.id == nodeId);

    if (anchorIndex < 0 || targetIndex < 0) {
      state = {nodeId};
      return;
    }

    final start = anchorIndex < targetIndex ? anchorIndex : targetIndex;
    final end = anchorIndex < targetIndex ? targetIndex : anchorIndex;

    final rangeIds = <String>{};
    for (int i = start; i <= end; i++) {
      rangeIds.add(siblings[i].id);
    }

    state = rangeIds;
  }

  /// Clear all selections.
  void clear() {
    state = {};
  }

  /// Select specific nodes.
  void selectAll(Iterable<String> nodeIds) {
    state = Set.from(nodeIds);
  }

  /// Delete all selected nodes.
  ///
  /// Pre-filters the selection to only top-level *ancestors* before iterating:
  /// `removeNode` deletes a node's whole subtree, so a selection holding both a
  /// parent and one of its descendants must not remove the descendant twice.
  void deleteSelected() {
    if (state.isEmpty) return;
    final sequence = ref.read(currentSequenceProvider);
    if (sequence == null) {
      // Without a sequence we can't filter ancestors; clear to keep state
      // consistent with the post-delete contract.
      clear();
      return;
    }

    final ancestorsOnly = _ancestorsOnly(sequence, state);

    final notifier = ref.read(currentSequenceProvider.notifier);
    for (final nodeId in ancestorsOnly) {
      notifier.removeNode(nodeId);
    }
    clear();
    ref.read(selectedNodeIdProvider.notifier).state = null;
  }

  /// Return only the ids in [ids] that are not a descendant of another id
  /// in [ids]. Removing these top-level nodes will recursively delete the
  /// dropped descendants via [CurrentSequenceNotifier.removeNode], so we
  /// don't iterate them.
  ///
  /// Exposed via the public ancestor-only filter (no underscore) so unit
  /// tests can exercise the predicate directly without depending on the
  /// full delete pipeline.
  static Set<String> ancestorsOnly(Sequence sequence, Set<String> ids) =>
      _ancestorsOnly(sequence, ids);

  static Set<String> _ancestorsOnly(Sequence sequence, Set<String> ids) {
    if (ids.length < 2) return Set<String>.from(ids);

    bool hasAncestorInSet(String nodeId) {
      var cursor = sequence.nodes[nodeId]?.parentId;
      while (cursor != null) {
        if (ids.contains(cursor)) return true;
        cursor = sequence.nodes[cursor]?.parentId;
      }
      return false;
    }

    final out = <String>{};
    for (final id in ids) {
      if (!hasAncestorInSet(id)) out.add(id);
    }
    return out;
  }

  /// Enable all selected nodes.
  void enableSelected() {
    final notifier = ref.read(currentSequenceProvider.notifier);
    final sequence = ref.read(currentSequenceProvider);
    if (sequence == null) return;

    for (final nodeId in state) {
      final node = sequence.nodes[nodeId];
      if (node != null && !node.isEnabled) {
        notifier.updateNode(node.copyWith(isEnabled: true));
      }
    }
  }

  /// Disable all selected nodes.
  void disableSelected() {
    final notifier = ref.read(currentSequenceProvider.notifier);
    final sequence = ref.read(currentSequenceProvider);
    if (sequence == null) return;

    for (final nodeId in state) {
      final node = sequence.nodes[nodeId];
      if (node != null && node.isEnabled) {
        notifier.updateNode(node.copyWith(isEnabled: false));
      }
    }
  }

  /// Copy nodes to clipboard.
  ///
  /// Copies the multi-selection when it is non-empty. When [explicitIds] is
  /// supplied (e.g. a single-node Ctrl+C with no multi-selection) those ids
  /// are copied instead — this lets the keyboard shortcut fall back to the
  /// single [selectedNodeIdProvider] without seeding the multi-select set.
  void copySelected({Iterable<String>? explicitIds}) {
    final sequence = ref.read(currentSequenceProvider);
    if (sequence == null) return;

    final ids = (explicitIds != null && explicitIds.isNotEmpty)
        ? explicitIds
        : state;

    final clipboard = <Map<String, dynamic>>[];
    for (final nodeId in ids) {
      final tree = _serializeNodeTree(sequence, nodeId);
      if (tree != null) {
        clipboard.add(tree);
      }
    }

    if (clipboard.isNotEmpty) {
      ref.read(nodeCopyClipboardProvider.notifier).state = clipboard;
    }
  }

  /// Paste nodes from clipboard into the currently selected parent.
  void pasteFromClipboard() {
    final clipboard = ref.read(nodeCopyClipboardProvider);
    if (clipboard == null || clipboard.isEmpty) return;

    final sequence = ref.read(currentSequenceProvider);
    if (sequence == null) return;

    final notifier = ref.read(currentSequenceProvider.notifier);

    // Paste target: the single selected node's parent, else the root.
    final selectedId = ref.read(selectedNodeIdProvider);
    String? parentId;
    if (selectedId != null) {
      final selectedNode = sequence.nodes[selectedId];
      parentId = selectedNode?.parentId;
    }
    parentId ??= sequence.rootNode?.id;
    if (parentId == null) return;

    for (final tree in clipboard) {
      _pasteNodeTree(notifier, sequence, tree, parentId);
    }
  }

  /// Serialize a node and its children to a map for clipboard storage.
  Map<String, dynamic>? _serializeNodeTree(Sequence sequence, String nodeId) {
    final node = sequence.nodes[nodeId];
    if (node == null) return null;

    final children = <Map<String, dynamic>>[];
    for (final childId in node.childIds) {
      final childTree = _serializeNodeTree(sequence, childId);
      if (childTree != null) {
        children.add(childTree);
      }
    }

    return {'node': node, 'children': children};
  }

  /// Paste a serialized node tree, creating new IDs.
  void _pasteNodeTree(
    CurrentSequenceNotifier notifier,
    Sequence sequence,
    Map<String, dynamic> tree,
    String parentId,
  ) {
    final originalNode = tree['node'] as SequenceNode;
    final children = tree['children'] as List<Map<String, dynamic>>;

    // Fresh id so the pasted copy doesn't collide with the source node.
    final newNode = originalNode.copyWith(
      id: const Uuid().v4(),
      parentId: parentId,
      childIds: [],
    );
    notifier.addNode(newNode, parentId: parentId);

    for (final childTree in children) {
      _pasteNodeTree(notifier, sequence, childTree, newNode.id);
    }
  }
}
