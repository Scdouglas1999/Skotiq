import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/providers/sequence_provider.dart';
import 'package:skotiq_core/src/services/sequence_file_service.dart';

/// W1.7 — parent-keyed children index refactor.
///
/// Pins:
///   * `childrenOf` / `parentOf` / `descendantsOf` agree with the legacy
///     `getChildren` / `node.parentId` / `countDescendants` views.
///   * `Sequence.invariants()` returns empty for well-formed sequences and
///     surfaces real violations for malformed ones.
///   * Reorder within a long sibling list does NOT touch nodes outside the
///     parent's child list (proxy for "O(1) within the parent").
///   * On-disk JSON round-trips byte-for-byte through the new representation.

ProviderContainer _newContainer() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

CurrentSequenceNotifier _notifier(ProviderContainer c) =>
    c.read(currentSequenceProvider.notifier);

/// Build a small balanced tree:
///
///     root
///     ├── A
///     │   ├── A1
///     │   └── A2
///     └── B
///         └── B1
Sequence _smallTree() {
  final root = InstructionSetNode(id: 'root', name: 'R');
  final a = InstructionSetNode(id: 'A', name: 'A', parentId: 'root');
  final a1 = DelayNode(id: 'A1', parentId: 'A');
  final a2 = DelayNode(id: 'A2', parentId: 'A');
  final b = InstructionSetNode(id: 'B', name: 'B', parentId: 'root');
  final b1 = DelayNode(id: 'B1', parentId: 'B');
  return Sequence.create(
    name: 'small',
    rootNodeId: 'root',
    nodes: {
      'root': root.copyWith(childIds: const ['A', 'B']),
      'A': a.copyWith(childIds: const ['A1', 'A2']),
      'A1': a1,
      'A2': a2,
      'B': b.copyWith(childIds: const ['B1']),
      'B1': b1,
    },
  );
}

void main() {
  group('Sequence.childrenOf', () {
    test('returns children in canonical order', () {
      final s = _smallTree();
      expect(
        s.childrenOf('root').map((n) => n.id).toList(),
        equals(['A', 'B']),
      );
      expect(s.childrenOf('A').map((n) => n.id).toList(), equals(['A1', 'A2']));
    });

    test('returns const empty list for a leaf', () {
      final s = _smallTree();
      expect(s.childrenOf('A1'), isEmpty);
      expect(s.childrenOf('B1'), isEmpty);
    });

    test('returns empty list for unknown parent', () {
      final s = _smallTree();
      expect(s.childrenOf('does-not-exist'), isEmpty);
    });

    test('matches legacy getChildren result exactly', () {
      final s = _smallTree();
      for (final parentId in ['root', 'A', 'B']) {
        expect(
          s.childrenOf(parentId).map((n) => n.id).toList(),
          equals(s.getChildren(parentId).map((n) => n.id).toList()),
        );
      }
    });
  });

  group('Sequence.parentOf', () {
    test('returns the parent id for child nodes', () {
      final s = _smallTree();
      expect(s.parentOf('A'), 'root');
      expect(s.parentOf('A1'), 'A');
      expect(s.parentOf('B1'), 'B');
    });

    test('returns null for the root node', () {
      final s = _smallTree();
      expect(s.parentOf('root'), isNull);
    });

    test('returns null for unknown node id', () {
      final s = _smallTree();
      expect(s.parentOf('ghost'), isNull);
    });

    test('agrees with node.parentId on every node', () {
      final s = _smallTree();
      for (final node in s.nodes.values) {
        expect(
          s.parentOf(node.id),
          node.parentId,
          reason: 'parentOf(${node.id}) must equal node.parentId',
        );
      }
    });
  });

  group('Sequence.descendantsOf', () {
    test('returns subtree in DFS pre-order', () {
      final s = _smallTree();
      expect(s.descendantsOf('root'), equals(['A', 'A1', 'A2', 'B', 'B1']));
      expect(s.descendantsOf('A'), equals(['A1', 'A2']));
    });

    test('returns empty for leaf', () {
      final s = _smallTree();
      expect(s.descendantsOf('A1'), isEmpty);
    });

    test('returns empty for unknown id', () {
      final s = _smallTree();
      expect(s.descendantsOf('ghost'), isEmpty);
    });

    test('agrees with countDescendants', () {
      final s = _smallTree();
      expect(s.countDescendants('root'), s.descendantsOf('root').length);
      expect(s.countDescendants('A'), s.descendantsOf('A').length);
      expect(s.countDescendants('B'), s.descendantsOf('B').length);
      expect(s.countDescendants('A1'), s.descendantsOf('A1').length);
    });
  });

  group('Sequence.invariants', () {
    test('returns empty list for a well-formed sequence', () {
      final s = _smallTree();
      expect(s.invariants(), isEmpty);
    });

    test('returns empty list for an empty sequence', () {
      final s = Sequence.create(name: 'empty');
      expect(s.invariants(), isEmpty);
    });

    test('catches a child whose parentId does not match its parent bucket', () {
      // Hand-craft a corrupt sequence: B's parentId is A, but root claims B
      // as a child. This would never happen via the editor (mutators keep
      // both in sync), but a corrupt JSON import could produce it.
      final root = InstructionSetNode(id: 'root', name: 'R');
      final b = InstructionSetNode(id: 'B', name: 'B', parentId: 'A');
      final corrupted = Sequence.create(
        name: 'corrupt',
        rootNodeId: 'root',
        nodes: {
          'root': root.copyWith(childIds: const ['B']),
          'B': b,
        },
      );
      final issues = corrupted.invariants();
      expect(issues, isNotEmpty);
      expect(
        issues.any((m) => m.contains('parentId')),
        isTrue,
        reason: 'should flag the parentId mismatch',
      );
    });

    test('catches a cycle', () {
      // A -> B -> A
      final a = InstructionSetNode(
        id: 'A',
        name: 'A',
        parentId: 'B',
        childIds: const ['B'],
      );
      final b = InstructionSetNode(
        id: 'B',
        name: 'B',
        parentId: 'A',
        childIds: const ['A'],
      );
      final corrupted = Sequence.create(
        name: 'cycle',
        rootNodeId: 'A',
        nodes: {'A': a, 'B': b},
      );
      final issues = corrupted.invariants();
      expect(issues.any((m) => m.contains('cycle')), isTrue);
    });

    test('catches a child id that does not resolve in nodes map', () {
      final root = InstructionSetNode(
        id: 'root',
        name: 'R',
        childIds: const ['missing'],
      );
      final corrupted = Sequence.create(
        name: 'dangling',
        rootNodeId: 'root',
        nodes: {'root': root},
      );
      final issues = corrupted.invariants();
      expect(issues.any((m) => m.contains('not present in nodes')), isTrue);
    });
  });

  group('Reorder within a long sibling list (proxy for O(1) cost)', () {
    test(
      'reorderNodes only renumbers the affected parent; other subtrees are untouched',
      () {
        // Build a sequence with >20 siblings under a single container plus a
        // *separate* subtree under a different parent. After reordering one of
        // the >20 siblings, every node OUTSIDE the parent's child list must be
        // the SAME instance — no gratuitous copyWith calls across the tree.
        final c = _newContainer();
        _notifier(c).createSequence();

        final rootId = c.read(currentSequenceProvider)!.rootNodeId!;

        // Add an unrelated subtree under a separate container.
        _notifier(c).addNode(
          InstructionSetNode(id: 'other', name: 'Other'),
          parentId: rootId,
        );
        _notifier(
          c,
        ).addNode(DelayNode(id: 'unrelated-1', seconds: 1), parentId: 'other');
        _notifier(
          c,
        ).addNode(DelayNode(id: 'unrelated-2', seconds: 2), parentId: 'other');

        // Now add the container that will hold the reordered siblings, then
        // populate it with 25 exposures.
        _notifier(c).addNode(
          InstructionSetNode(id: 'container', name: 'C'),
          parentId: rootId,
        );
        _notifier(c).withUndoGroup(() {
          for (var i = 0; i < 25; i++) {
            _notifier(c).addNode(
              ExposureNode(
                id: 'exp-$i',
                durationSecs: 60,
                count: 1,
                name: 'E$i',
              ),
              parentId: 'container',
            );
          }
        });

        final before = c.read(currentSequenceProvider)!;
        final unrelatedBefore = before.nodes['unrelated-1']!;
        final unrelatedBefore2 = before.nodes['unrelated-2']!;
        final otherBefore = before.nodes['other']!;

        // Swap the first two exposures inside the container.
        _notifier(c).reorderNodes('container', 0, 1);

        final after = c.read(currentSequenceProvider)!;
        // Nodes outside the affected parent are identical instances — proxy
        // for "the reorder didn't sweep the whole tree", which is the
        // performance contract the W1.7 refactor pins.
        expect(
          identical(after.nodes['unrelated-1'], unrelatedBefore),
          isTrue,
          reason: 'sibling in another subtree must not be rebuilt',
        );
        expect(
          identical(after.nodes['unrelated-2'], unrelatedBefore2),
          isTrue,
          reason: 'sibling in another subtree must not be rebuilt',
        );
        expect(
          identical(after.nodes['other'], otherBefore),
          isTrue,
          reason: 'the unrelated parent must not be rebuilt',
        );

        // Verify the swap actually happened.
        final containerChildIds = after.nodes['container']!.childIds;
        expect(containerChildIds.first, 'exp-1');
        expect(containerChildIds[1], 'exp-0');
      },
    );

    test('cross-parent move keeps invariants', () {
      final c = _newContainer();
      _notifier(c).loadSequence(_smallTree(), discardUnsaved: true);

      // Move A1 from under A to under B.
      _notifier(c).moveNode('A1', 'B', 0);

      final after = c.read(currentSequenceProvider)!;
      expect(after.parentOf('A1'), 'B');
      expect(after.childrenOf('A').map((n) => n.id), equals(['A2']));
      expect(after.childrenOf('B').map((n) => n.id), equals(['A1', 'B1']));
      expect(after.invariants(), isEmpty);
    });

    test('invariants hold after a chain of editor mutations', () {
      final c = _newContainer();
      _notifier(c).loadSequence(_smallTree(), discardUnsaved: true);

      _notifier(c).addNode(
        ExposureNode(id: 'newE', durationSecs: 10, count: 2, name: 'New'),
        parentId: 'A',
        index: 1,
      );
      _notifier(c).reorderNodes('A', 0, 2);
      _notifier(c).moveNode('newE', 'B', 0);
      _notifier(c).removeNode('A1');

      final after = c.read(currentSequenceProvider)!;
      expect(after.invariants(), isEmpty);
    });
  });

  group('Serialization round-trip is byte-equal', () {
    test('export → import → re-export produces identical JSON', () {
      final s = _smallTree();
      final service = SequenceFileService();
      // The private _sequenceToJson is invoked via parseFromMap/exportSequence
      // path. Build the JSON the same way export does, then re-import it,
      // then re-build — byte-for-byte identical means the parent-keyed
      // representation preserves the on-disk shape.

      // We can't call the private encoder, but we can encode/parse via the
      // pubic parseFromMap on a JSON map we author the same way export does.
      // Use jsonEncode of the published node serialization to drive the
      // round-trip — done via the SequenceFileService.exportSequence path
      // would require disk; instead we go: object → encoded JSON object map
      // → parseFromMap → object → encoded JSON object map and compare.

      // Build a JSON map that matches the export shape exactly.
      Map<String, dynamic> toExportMap(Sequence seq) {
        return {
          'schemaVersion': SequenceFileService.currentSchemaVersion,
          'version': '2.0',
          'name': seq.name,
          'description': seq.description,
          'rootNodeId': seq.rootNodeId,
          'isTemplate': seq.isTemplate,
          'nodes': {
            for (final entry in seq.nodes.entries)
              entry.key: _nodeToShapeMap(entry.value),
          },
          'createdAt': seq.createdAt.toIso8601String(),
          'modifiedAt': seq.modifiedAt.toIso8601String(),
        };
      }

      final firstMap = toExportMap(s);
      final firstJson = jsonEncode(firstMap);

      // Round-trip through the public importer.
      final reparsed = service.parseFromMap(jsonDecode(firstJson));
      // Force the indexes to build to verify they don't perturb the model.
      expect(reparsed.invariants(), isEmpty);

      // Now mutate the rootNodeId/createdAt to match the original (parseFromMap
      // assigns a fresh id by design — see sequence_file_service.dart).
      final normalized = Sequence.create(
        id: s.id,
        name: reparsed.name,
        description: reparsed.description,
        nodes: reparsed.nodes,
        rootNodeId: reparsed.rootNodeId,
        isTemplate: reparsed.isTemplate,
        createdAt: s.createdAt,
        modifiedAt: s.modifiedAt,
      );

      final secondMap = toExportMap(normalized);
      final secondJson = jsonEncode(secondMap);

      // Byte-equal at the encoded level → the new representation does not
      // alter the on-disk shape.
      expect(secondJson, equals(firstJson));
    });
  });
}

/// Minimal helper that mirrors a few keys from `_nodeToJson` for the
/// round-trip byte-compare. We use this in the test instead of the private
/// method so the assertion remains tightly coupled to "what the test author
/// authored" — not to drift from a Pgrade in the file service.
Map<String, dynamic> _nodeToShapeMap(SequenceNode node) {
  // The test only round-trips InstructionSetNode + DelayNode, neither of
  // which has extras beyond the base set.
  return <String, dynamic>{
    'id': node.id,
    'nodeType': node.nodeType,
    'name': node.name,
    'parentId': node.parentId,
    'childIds': node.childIds,
    'orderIndex': node.orderIndex,
    'isEnabled': node.isEnabled,
    if (node is DelayNode) 'seconds': node.seconds,
  };
}
