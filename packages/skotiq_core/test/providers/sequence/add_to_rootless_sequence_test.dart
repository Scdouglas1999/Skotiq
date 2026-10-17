// A sequence can reach the editor with no usable root node: `rootNodeId` is
// nullable on the model, on the `sequences` table and in the `.nseq.json`
// schema (the importer only checks the key is a String *if present*), and the
// id-remapping copy paths resolve it through a lookup that can miss.
//
// `addTargetHeader` and `addNode` used to bail out on exactly those documents
// with a bare `if (rootNodeId == null) return;`, returning normally having
// written nothing. That is what made Framing's "Add to Sequence -> Add target"
// unable to add a target — the later read-back only told the user it had
// failed. These pin the insert actually landing, and landing on a tree that
// still satisfies `Sequence.invariants()`.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/providers/sequence_provider.dart';

ProviderContainer _newContainer() {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  return container;
}

CurrentSequenceNotifier _notifier(ProviderContainer c) =>
    c.read(currentSequenceProvider.notifier);

TargetHeaderNode _target(
  String name, {
  String? id,
  String? parentId,
  List<String>? childIds,
}) => TargetHeaderNode(
  id: id,
  name: name,
  targetName: name,
  raHours: 0.712,
  decDegrees: 41.27,
  parentId: parentId,
  childIds: childIds ?? const [],
);

/// A library row whose `root_node_id` column is null: real nodes, no root.
Sequence _rootlessLibrarySequence() => Sequence.create(
  databaseId: 7,
  name: 'Old Plan',
  nodes: {
    'tgt-m31': _target('M31', id: 'tgt-m31', childIds: const ['exp-m31']),
    'exp-m31': ExposureNode(
      id: 'exp-m31',
      parentId: 'tgt-m31',
      durationSecs: 120,
      count: 20,
    ),
  },
);

void main() {
  group('addTargetHeader on a sequence with no usable root', () {
    test('inserts the target instead of silently returning', () {
      final c = _newContainer();
      // The route Framing takes for a saved destination.
      _notifier(c).loadCopyForEditing(_rootlessLibrarySequence());
      expect(
        c.read(currentSequenceProvider)!.rootNodeId,
        isNull,
        reason: 'precondition: the copy carries the missing root forward',
      );

      _notifier(c).addTargetHeader(_target('NGC 891', id: 'tgt-891'));

      final sequence = c.read(currentSequenceProvider)!;
      final rootId = sequence.rootNodeId;
      expect(rootId, isNotNull, reason: 'the insert has to produce a spine');
      expect(sequence.nodes[rootId], isNotNull);
      expect(sequence.nodes['tgt-891'], isNotNull);
      expect(
        sequence.nodes['tgt-891']!.parentId,
        rootId,
        reason:
            'a node in the map but under no parent is invisible to the '
            'tree builder and to the executor',
      );
      expect(sequence.nodes[rootId]!.childIds, ['tgt-m31', 'tgt-891']);
      expect(sequence.targetHeaders.map((t) => t.targetName), [
        'M31',
        'NGC 891',
      ]);
      expect(sequence.invariants(), isEmpty);
    });

    test('repairing the root does not strand the tree already there', () {
      final c = _newContainer();
      _notifier(c).loadCopyForEditing(_rootlessLibrarySequence());
      _notifier(c).addTargetHeader(_target('NGC 891', id: 'tgt-891'));

      final sequence = c.read(currentSequenceProvider)!;
      // M31's exposure must still hang off M31, not get re-adopted as an
      // orphan of the new target.
      expect(sequence.nodes['exp-m31']!.parentId, 'tgt-m31');
      expect(sequence.nodes['tgt-m31']!.childIds, ['exp-m31']);
      expect(sequence.nodes['tgt-m31']!.parentId, sequence.rootNodeId);
      expect(sequence.descendantsOf(sequence.rootNodeId!), hasLength(3));
    });

    test('a root pointer that dangles is repaired under its own id', () {
      final c = _newContainer();
      // Rows whose root node was deleted, and the id-remap copy paths that
      // fall back to the source id, both produce this shape.
      _notifier(c).loadSequence(
        Sequence.create(
          name: 'Dangling',
          rootNodeId: 'root-gone',
          nodes: {'tgt-m31': _target('M31', id: 'tgt-m31')},
        ),
      );

      _notifier(c).addTargetHeader(_target('NGC 891', id: 'tgt-891'));

      final sequence = c.read(currentSequenceProvider)!;
      expect(
        sequence.rootNodeId,
        'root-gone',
        reason: 'child parentIds and the persisted column still name it',
      );
      expect(sequence.nodes['root-gone']!.childIds, ['tgt-m31', 'tgt-891']);
      expect(sequence.invariants(), isEmpty);
    });

    test('an import that only lost the pointer keeps its own root', () {
      final c = _newContainer();
      _notifier(c).loadSequence(
        Sequence.create(
          name: 'Imported',
          nodes: {
            'set': InstructionSetNode(
              id: 'set',
              name: 'Sequence',
              childIds: const ['tgt-m31'],
            ),
            'tgt-m31': _target('M31', id: 'tgt-m31', parentId: 'set'),
          },
        ),
      );

      _notifier(c).addTargetHeader(_target('NGC 891', id: 'tgt-891'));

      final sequence = c.read(currentSequenceProvider)!;
      expect(
        sequence.rootNodeId,
        'set',
        reason:
            'the unparented container IS the root; wrapping it would '
            'deepen a tree the user authored',
      );
      expect(sequence.nodes.length, 3, reason: 'no extra wrapper node');
      expect(sequence.nodes['set']!.childIds, ['tgt-m31', 'tgt-891']);
    });
  });

  group('addNode on a sequence with no usable root', () {
    test('attaches the node to a root instead of orphaning it', () {
      final c = _newContainer();
      _notifier(c).loadCopyForEditing(_rootlessLibrarySequence());

      _notifier(c).addNode(ParkNode(id: 'park-1'));

      final sequence = c.read(currentSequenceProvider)!;
      final rootId = sequence.rootNodeId;
      expect(rootId, isNotNull);
      expect(
        sequence.nodes['park-1']!.parentId,
        rootId,
        reason:
            'the node used to land in `nodes` with no parent and no entry '
            'in anyone\'s childIds — present to containsKey, invisible to '
            'every renderer',
      );
      expect(sequence.descendantsOf(rootId!), contains('park-1'));
      expect(sequence.invariants(), isEmpty);
    });
  });
}
