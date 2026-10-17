import '../models/sequence/sequence_models.dart';
part 'sequence_diff_service/node_field_diff.dart';
part 'sequence_diff_service/node_describe.dart';

/// Structural diff between two [Sequence] snapshots.
///
/// The diff is tree-aware rather than text-based: comparing two stored
/// JSON blobs as strings is useless for the operator ("the order of
/// keys changed" is not actionable), so this walks the node graphs and
/// classifies each node into [SequenceDiffChange.added],
/// [SequenceDiffChange.removed], or [SequenceDiffChange.modified] using
/// a stable identity strategy:
///
///   1. **Same node id in both**: candidate for "modified". Every
///      type-specific property (exposure duration, filter, autofocus
///      method, etc.) is compared into a per-field [FieldChange] entry.
///      A node whose every field is equal is not emitted at all (no-op).
///   2. **Id only in old**: classified as removed.
///   3. **Id only in new**: classified as added.
///
/// Nodes carry a human label (e.g. "Exposure 60s · Lum" or "Loop x10")
/// so the dialog can render meaningful rows without re-running display
/// logic.
///
/// Semantic categories generated per-field example:
///   * Exposure duration changed from `60.0s` to `120.0s`
///   * Added 3 new TargetHeader nodes
///   * Removed HFR trigger from "Capture Hα"
///
/// Every SequenceNode subtype is diffed here, so adding a new node kind
/// to the sealed hierarchy generates a missed-case compile-time error
/// (the switch is exhaustive). That matches the
/// repository's persistence layer in `sequence_repository.dart` and
/// keeps the diff in lock-step with what is actually saved.
class SequenceDiffService {
  const SequenceDiffService();

  /// Compute the diff. Returns an empty [SequenceDiffResult] when the
  /// two sequences are structurally identical.
  ///
  /// [previous] and [current] may have unrelated `Sequence.id` values
  /// (we are comparing runs, not edit history) — the node-id-based
  /// matching depends on stable per-node UUIDs, which the sequence
  /// editor preserves on every edit (`copyWith` always keeps `id`).
  SequenceDiffResult diff({
    required Sequence previous,
    required Sequence current,
  }) {
    final previousIds = previous.nodes.keys.toSet();
    final currentIds = current.nodes.keys.toSet();

    final added = <NodeDiffEntry>[];
    final removed = <NodeDiffEntry>[];
    final modified = <NodeDiffEntry>[];

    for (final id in currentIds.difference(previousIds)) {
      final node = current.nodes[id]!;
      added.add(
        NodeDiffEntry(
          nodeId: id,
          nodeKind: node.nodeType,
          label: _describeNode(node),
          changes: const <FieldChange>[],
        ),
      );
    }

    for (final id in previousIds.difference(currentIds)) {
      final node = previous.nodes[id]!;
      removed.add(
        NodeDiffEntry(
          nodeId: id,
          nodeKind: node.nodeType,
          label: _describeNode(node),
          changes: const <FieldChange>[],
        ),
      );
    }

    for (final id in currentIds.intersection(previousIds)) {
      final before = previous.nodes[id]!;
      final after = current.nodes[id]!;
      final fieldChanges = _diffNodes(before, after);
      if (fieldChanges.isNotEmpty) {
        modified.add(
          NodeDiffEntry(
            nodeId: id,
            nodeKind: after.nodeType,
            label: _describeNode(after),
            changes: fieldChanges,
          ),
        );
      }
    }

    // Stable display ordering: by label so the UI is diffable between
    // re-runs of the same comparison.
    int byLabel(NodeDiffEntry a, NodeDiffEntry b) => a.label.compareTo(b.label);
    added.sort(byLabel);
    removed.sort(byLabel);
    modified.sort(byLabel);

    return SequenceDiffResult(
      previousName: previous.name,
      currentName: current.name,
      added: List.unmodifiable(added),
      removed: List.unmodifiable(removed),
      modified: List.unmodifiable(modified),
    );
  }
}

/// Result of [SequenceDiffService.diff].
class SequenceDiffResult {
  final String previousName;
  final String currentName;
  final List<NodeDiffEntry> added;
  final List<NodeDiffEntry> removed;
  final List<NodeDiffEntry> modified;

  const SequenceDiffResult({
    required this.previousName,
    required this.currentName,
    required this.added,
    required this.removed,
    required this.modified,
  });

  bool get isEmpty => added.isEmpty && removed.isEmpty && modified.isEmpty;

  /// Concise headline (used in the dialog title / preflight banner).
  String get summary {
    if (isEmpty) return 'No changes';
    final parts = <String>[];
    if (added.isNotEmpty) parts.add('+${added.length}');
    if (removed.isNotEmpty) parts.add('-${removed.length}');
    if (modified.isNotEmpty) parts.add('~${modified.length}');
    return parts.join('  ');
  }
}

/// One entry in the diff: either an added node, a removed node, or a
/// modified node carrying its per-field [changes] list.
class NodeDiffEntry {
  final String nodeId;
  final String nodeKind;
  final String label;
  final List<FieldChange> changes;

  const NodeDiffEntry({
    required this.nodeId,
    required this.nodeKind,
    required this.label,
    required this.changes,
  });
}

/// One field-level change inside a modified node.
class FieldChange {
  final String field;
  final Object? oldValue;
  final Object? newValue;

  const FieldChange(this.field, this.oldValue, this.newValue);

  /// Human-readable line (used by tests and the markdown export).
  String describe() => '$field: $oldValue → $newValue';
}
