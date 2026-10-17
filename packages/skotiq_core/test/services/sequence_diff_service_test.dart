import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/services/sequence_diff_service.dart';

void main() {
  const diff = SequenceDiffService();

  /// Build a tiny sequence containing only the supplied nodes; uses the
  /// first node as the root. Keeps tests terse without rebuilding the
  /// full editor's mutator surface.
  Sequence buildSequence({
    required String name,
    required List<SequenceNode> nodes,
  }) {
    return Sequence.create(
      name: name,
      nodes: {for (final n in nodes) n.id: n},
      rootNodeId: nodes.isEmpty ? null : nodes.first.id,
    );
  }

  group('SequenceDiffService.diff', () {
    test('identical sequences produce empty diff', () {
      final root = TargetHeaderNode(
        targetName: 'M31',
        raHours: 0.7,
        decDegrees: 41.3,
      );
      final a = buildSequence(name: 'M31', nodes: [root]);
      final b = buildSequence(name: 'M31', nodes: [root]);
      final result = diff.diff(previous: a, current: b);
      expect(result.isEmpty, isTrue);
      expect(result.summary, 'No changes');
    });

    test('added node appears under "added"', () {
      final target = TargetHeaderNode(
        targetName: 'M31',
        raHours: 0.7,
        decDegrees: 41.3,
      );
      final previous = buildSequence(name: 'M31', nodes: [target]);
      final newExposure = ExposureNode(
        durationSecs: 60.0,
        count: 10,
        filter: 'Lum',
      );
      final current = buildSequence(name: 'M31', nodes: [target, newExposure]);
      final result = diff.diff(previous: previous, current: current);
      expect(result.added.length, 1);
      expect(result.added.single.nodeId, newExposure.id);
      expect(result.added.single.nodeKind, 'TakeExposure');
      expect(result.removed, isEmpty);
      expect(result.modified, isEmpty);
      expect(result.summary, '+1');
    });

    test('removed node appears under "removed"', () {
      final target = TargetHeaderNode(
        targetName: 'M31',
        raHours: 0.7,
        decDegrees: 41.3,
      );
      final exposure = ExposureNode(
        durationSecs: 60.0,
        count: 10,
        filter: 'Lum',
      );
      final previous = buildSequence(name: 'M31', nodes: [target, exposure]);
      final current = buildSequence(name: 'M31', nodes: [target]);
      final result = diff.diff(previous: previous, current: current);
      expect(result.removed.length, 1);
      expect(result.removed.single.nodeId, exposure.id);
      expect(result.added, isEmpty);
      expect(result.modified, isEmpty);
      expect(result.summary, '-1');
    });

    test('modified exposure duration produces field change', () {
      final target = TargetHeaderNode(
        targetName: 'M31',
        raHours: 0.7,
        decDegrees: 41.3,
      );
      final before = ExposureNode(
        id: 'exp-1',
        durationSecs: 180.0,
        count: 10,
        filter: 'Lum',
      );
      final after = ExposureNode(
        id: 'exp-1',
        durationSecs: 240.0,
        count: 10,
        filter: 'Lum',
      );
      final result = diff.diff(
        previous: buildSequence(name: 'M31', nodes: [target, before]),
        current: buildSequence(name: 'M31', nodes: [target, after]),
      );
      expect(result.added, isEmpty);
      expect(result.removed, isEmpty);
      expect(result.modified.length, 1);
      final entry = result.modified.single;
      expect(entry.nodeId, 'exp-1');
      final field = entry.changes.firstWhere(
        (c) => c.field == 'Exposure duration',
      );
      expect(field.oldValue, '180.0s');
      expect(field.newValue, '240.0s');
      expect(result.summary, '~1');
    });

    test('renaming a node is captured by the base-class diff', () {
      final before = ExposureNode(
        id: 'exp-1',
        name: 'Lights',
        durationSecs: 60.0,
      );
      final after = ExposureNode(
        id: 'exp-1',
        name: 'Lum Lights',
        durationSecs: 60.0,
      );
      final result = diff.diff(
        previous: buildSequence(name: 'a', nodes: [before]),
        current: buildSequence(name: 'a', nodes: [after]),
      );
      expect(result.modified.length, 1);
      expect(
        result.modified.single.changes.any((c) => c.field == 'Name'),
        isTrue,
      );
    });

    test('node-kind change under the same id is flagged', () {
      const id = 'shared';
      final before = ExposureNode(id: id, durationSecs: 60.0);
      final after = DitherNode(id: id);
      final result = diff.diff(
        previous: buildSequence(name: 'a', nodes: [before]),
        current: buildSequence(name: 'a', nodes: [after]),
      );
      expect(result.modified.length, 1);
      final kindChange = result.modified.single.changes.firstWhere(
        (c) => c.field == 'Node kind',
      );
      expect(kindChange.oldValue, 'TakeExposure');
      expect(kindChange.newValue, 'Dither');
    });

    test('summary string combines all three buckets', () {
      final target = TargetHeaderNode(
        targetName: 'M31',
        raHours: 0.7,
        decDegrees: 41.3,
      );
      final removed = ExposureNode(durationSecs: 60.0);
      final added = ExposureNode(durationSecs: 120.0);
      final modBefore = ExposureNode(id: 'mod', durationSecs: 60.0, count: 10);
      final modAfter = ExposureNode(id: 'mod', durationSecs: 60.0, count: 20);
      final previous = buildSequence(
        name: 'M31',
        nodes: [target, removed, modBefore],
      );
      final current = buildSequence(
        name: 'M31',
        nodes: [target, added, modAfter],
      );
      final result = diff.diff(previous: previous, current: current);
      expect(result.added.length, 1);
      expect(result.removed.length, 1);
      expect(result.modified.length, 1);
      expect(result.summary, '+1  -1  ~1');
    });

    test('changes carry deterministic ordering by label', () {
      final target = TargetHeaderNode(
        targetName: 'M31',
        raHours: 0.7,
        decDegrees: 41.3,
      );
      final a = ExposureNode(durationSecs: 60.0, filter: 'Zed');
      final b = ExposureNode(durationSecs: 60.0, filter: 'Alpha');
      final previous = buildSequence(name: 'M31', nodes: [target]);
      final current = buildSequence(name: 'M31', nodes: [target, a, b]);
      final result = diff.diff(previous: previous, current: current);
      expect(result.added.length, 2);
      // Sorted alphabetically by label — Alpha comes first.
      expect(result.added.first.label, contains('Alpha'));
      expect(result.added.last.label, contains('Zed'));
    });
  });

  group('SequenceDiffResult', () {
    test('isEmpty true only when all three lists are empty', () {
      const empty = SequenceDiffResult(
        previousName: 'a',
        currentName: 'b',
        added: [],
        removed: [],
        modified: [],
      );
      expect(empty.isEmpty, isTrue);
      expect(empty.summary, 'No changes');
    });
  });
}
