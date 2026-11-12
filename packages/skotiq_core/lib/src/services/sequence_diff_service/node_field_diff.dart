part of '../sequence_diff_service.dart';

extension _SequenceDiffNodeFields on SequenceDiffService {
  /// Diff two nodes that share an id: the fields every node has, then the
  /// lines its [NodeKind.diff] lists.
  List<FieldChange> _diffNodes(
    SequenceNode a,
    SequenceNode b,
    ExposureSensitivity sensitivity,
  ) {
    final out = <FieldChange>[];

    // Common base-class fields first
    if (a.name != b.name) {
      out.add(FieldChange('Name', a.name, b.name));
    }
    if (a.isEnabled != b.isEnabled) {
      out.add(FieldChange('Enabled', a.isEnabled, b.isEnabled));
    }
    if ((a.comment ?? '') != (b.comment ?? '')) {
      out.add(FieldChange('Comment', a.comment ?? '', b.comment ?? ''));
    }
    // ChildIds changes are recorded as a single summary entry — node-by-
    // node child diffs are out of scope here; the per-child diff is
    // already covered by the top-level added/removed lists.
    if (!_listEquals(a.childIds, b.childIds)) {
      out.add(
        FieldChange(
          'Children',
          '${a.childIds.length} children',
          '${b.childIds.length} children',
        ),
      );
    }

    // If the runtime types disagree the user replaced one node with
    // a different kind under the same id (rare; the editor's mutator
    // doesn't do this, but imports may). Flag it as a kind change and
    // skip type-specific comparison.
    if (a.runtimeType != b.runtimeType) {
      out.add(FieldChange('Node kind', a.nodeType, b.nodeType));
      return out;
    }

    return [
      ...out,
      for (final (label, before, after) in a.kind.changes(a, b))
        FieldChange(
          label == exposureGainDiffLabel ? sensitivity.label : label,
          before,
          after,
        ),
    ];
  }

  bool _listEquals<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Display label for a node, shown next to its kind icon in the diff.
  String _describeNode(SequenceNode node) => node.kind.describe(node);
}
