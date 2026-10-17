import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/providers/sequence_provider.dart';

// Tests for the multi-select fixes added in
//
//   1. `MultiSelectNotifier.deleteSelected` no longer iterates over both a
//      parent and its descendant — it pre-filters the selection to
//      top-level ancestors, so removing the parent doesn't leave a
//      tombstone child the next remove() can't find.
//
//   2. `CurrentSequenceNotifier.wrapChildrenSubset` wraps an exact list of
//      contiguous siblings under a shared parent and refuses to silently
//      reorder non-contiguous selections.

ProviderContainer _makeContainer() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

/// Build a sequence:
///
///     root
///     ├── A
///     │   └── A1
///     ├── B
///     │   ├── B1
///     │   └── B2
///     └── C
Sequence _abcdTree() {
  final root = InstructionSetNode(id: 'root', name: 'Root');
  final a = InstructionSetNode(id: 'A', name: 'A', parentId: 'root');
  final a1 = DelayNode(id: 'A1', parentId: 'A');
  final b = InstructionSetNode(id: 'B', name: 'B', parentId: 'root');
  final b1 = DelayNode(id: 'B1', parentId: 'B');
  final b2 = DelayNode(id: 'B2', parentId: 'B');
  final c = InstructionSetNode(id: 'C', name: 'C', parentId: 'root');

  return Sequence.create(
    name: 'T',
    rootNodeId: 'root',
    nodes: {
      'root': root.copyWith(childIds: const ['A', 'B', 'C']),
      'A': a.copyWith(childIds: const ['A1']),
      'A1': a1,
      'B': b.copyWith(childIds: const ['B1', 'B2']),
      'B1': b1,
      'B2': b2,
      'C': c,
    },
  );
}

void main() {
  group('MultiSelectNotifier.ancestorsOnly', () {
    test('drops descendants whose ancestor is also selected', () {
      final s = _abcdTree();
      // Selection: A (parent), A1 (its child), B (sibling), B2 (B's child).
      // A and B are top-level ancestors; A1 and B2 should be filtered out.
      final filtered = MultiSelectNotifier.ancestorsOnly(s, {
        'A',
        'A1',
        'B',
        'B2',
      });
      expect(filtered, equals({'A', 'B'}));
    });

    test('returns the input unchanged when no ancestor-descendant pairs', () {
      final s = _abcdTree();
      final filtered = MultiSelectNotifier.ancestorsOnly(s, {'A1', 'B1', 'C'});
      expect(filtered, equals({'A1', 'B1', 'C'}));
    });

    test('returns the input unchanged for empty / singleton sets', () {
      final s = _abcdTree();
      expect(MultiSelectNotifier.ancestorsOnly(s, <String>{}), isEmpty);
      expect(MultiSelectNotifier.ancestorsOnly(s, {'B'}), equals({'B'}));
    });
  });

  group('MultiSelectNotifier.deleteSelected', () {
    test('removes parent and all descendants in one call (no throws)', () {
      final c = _makeContainer();
      c
          .read(currentSequenceProvider.notifier)
          .loadSequence(_abcdTree(), discardUnsaved: true);
      // Select both B (parent) and B1 (its child).
      c.read(multiSelectedNodeIdsProvider.notifier).selectAll(['B', 'B1']);
      // ancestorsOnly drops B1; removing B then takes the subtree with it.
      // Iterating over both instead throws "node not found" on the second
      // iteration, which is what this pins.
      c.read(multiSelectedNodeIdsProvider.notifier).deleteSelected();

      final result = c.read(currentSequenceProvider)!;
      expect(
        result.nodes.containsKey('B'),
        isFalse,
        reason: 'parent B should be gone',
      );
      expect(
        result.nodes.containsKey('B1'),
        isFalse,
        reason: 'descendant B1 should be removed with parent',
      );
      expect(
        result.nodes.containsKey('B2'),
        isFalse,
        reason: 'descendant B2 should be removed with parent',
      );
      // Selection cleared after delete.
      expect(c.read(multiSelectedNodeIdsProvider), isEmpty);
    });

    test('handles three-deep nesting (root selected, leaf also selected)', () {
      final c = _makeContainer();
      c
          .read(currentSequenceProvider.notifier)
          .loadSequence(_abcdTree(), discardUnsaved: true);
      // Select A (parent) and A1 (its child).
      c.read(multiSelectedNodeIdsProvider.notifier).selectAll(['A', 'A1']);
      c.read(multiSelectedNodeIdsProvider.notifier).deleteSelected();

      final result = c.read(currentSequenceProvider)!;
      expect(result.nodes.keys, isNot(contains('A')));
      expect(result.nodes.keys, isNot(contains('A1')));
      // B and C survive.
      expect(result.nodes.containsKey('B'), isTrue);
      expect(result.nodes.containsKey('C'), isTrue);
    });

    test('still deletes a flat (no-ancestor) multi-selection', () {
      final c = _makeContainer();
      c
          .read(currentSequenceProvider.notifier)
          .loadSequence(_abcdTree(), discardUnsaved: true);
      c.read(multiSelectedNodeIdsProvider.notifier).selectAll(['A1', 'C']);
      c.read(multiSelectedNodeIdsProvider.notifier).deleteSelected();

      final result = c.read(currentSequenceProvider)!;
      expect(result.nodes.containsKey('A1'), isFalse);
      expect(result.nodes.containsKey('C'), isFalse);
      // A survives but loses A1.
      expect(result.nodes['A']!.childIds, isEmpty);
    });
  });

  group('CurrentSequenceNotifier.wrapChildrenSubset', () {
    test('wraps three contiguous siblings into one container', () {
      final c = _makeContainer();
      c
          .read(currentSequenceProvider.notifier)
          .loadSequence(_abcdTree(), discardUnsaved: true);
      final wrapper = InstructionSetNode(name: 'Group');
      c.read(currentSequenceProvider.notifier).wrapChildrenSubset('root', [
        'A',
        'B',
        'C',
      ], wrapper);

      final result = c.read(currentSequenceProvider)!;
      // The wrapper was assigned a fresh id by the notifier, so look it up
      // via the root's child list (which now contains only the wrapper).
      final rootChildren = result.nodes['root']!.childIds;
      expect(rootChildren, hasLength(1));
      final newWrapperId = rootChildren.first;
      final newWrapper = result.nodes[newWrapperId]!;
      expect(
        newWrapper.childIds,
        equals(['A', 'B', 'C']),
        reason: 'children stay in original sibling order',
      );
      // Each child's parent now points at the wrapper.
      for (final id in ['A', 'B', 'C']) {
        expect(result.nodes[id]!.parentId, newWrapperId);
      }
    });

    test('refuses to wrap a non-contiguous selection', () {
      final c = _makeContainer();
      c
          .read(currentSequenceProvider.notifier)
          .loadSequence(_abcdTree(), discardUnsaved: true);

      expect(
        () => c.read(currentSequenceProvider.notifier).wrapChildrenSubset(
          'root',
          ['A', 'C'], // A and C with B in between → not contiguous
          InstructionSetNode(name: 'Group'),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('not contiguous'),
          ),
        ),
      );

      // Sequence is unchanged.
      final result = c.read(currentSequenceProvider)!;
      expect(result.nodes['root']!.childIds, equals(['A', 'B', 'C']));
    });

    test('refuses to wrap children spanning multiple parents', () {
      final c = _makeContainer();
      c
          .read(currentSequenceProvider.notifier)
          .loadSequence(_abcdTree(), discardUnsaved: true);

      // B1 is a child of B, not root → passing root as the parent should
      // throw "not a child of root".
      expect(
        () => c.read(currentSequenceProvider.notifier).wrapChildrenSubset(
          'root',
          ['A', 'B1'],
          InstructionSetNode(name: 'Group'),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('not a child'),
          ),
        ),
      );
    });

    test('wraps a single child (degenerate but valid input)', () {
      final c = _makeContainer();
      c
          .read(currentSequenceProvider.notifier)
          .loadSequence(_abcdTree(), discardUnsaved: true);

      c.read(currentSequenceProvider.notifier).wrapChildrenSubset('B', [
        'B1',
      ], InstructionSetNode(name: 'Solo'));

      final result = c.read(currentSequenceProvider)!;
      final bChildren = result.nodes['B']!.childIds;
      expect(bChildren, hasLength(2), reason: 'wrapper replaces B1');
      // wrapper now occupies B1's old slot; B2 retained.
      final wrapperId = bChildren[0];
      expect(result.nodes[wrapperId]!.childIds, equals(['B1']));
      expect(bChildren[1], 'B2');
    });

    test('empty childIds is a no-op', () {
      final c = _makeContainer();
      final original = _abcdTree();
      c
          .read(currentSequenceProvider.notifier)
          .loadSequence(original, discardUnsaved: true);
      c
          .read(currentSequenceProvider.notifier)
          .wrapChildrenSubset(
            'root',
            const [],
            InstructionSetNode(name: 'Nothing'),
          );
      final result = c.read(currentSequenceProvider)!;
      expect(result.nodes['root']!.childIds, equals(['A', 'B', 'C']));
    });
  });
}
