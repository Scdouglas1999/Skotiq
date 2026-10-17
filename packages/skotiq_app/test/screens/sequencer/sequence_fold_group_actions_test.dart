// The four mutations a folded row offers (spec §6), driven through the same
// entry points the row's kebab, its hover chips and its drag calls.
//
// The block move is the whole file's reason to exist. `moveNode` REMOVES the
// node before it inserts, so the index it takes is an index into the list
// WITHOUT that node — and a block of three re-seated one slot at a time has to
// chase its own predecessor through a list that shifts under it. Getting that
// arithmetic wrong does not throw: it silently reorders the night's frames,
// which is the kind of defect that is only ever found in the morning.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/sequence_fold_model.dart';
import 'package:skotiq_app/screens/sequencer/widgets/delete_node_confirmation.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/fold_group_actions.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// A parent holding [names] in order, exposures for the letters that are a
/// run member and delays for the rest.
///
/// `A`, `B` and `C` are one run: same length, same count, differing only by
/// filter. Every other name is a delay, so it can never join the run and the
/// block always has real neighbours to move past.
({Sequence sequence, String parentId, Map<String, String> ids}) _tree(
  List<String> names,
) {
  const runMembers = <String>{'A', 'B', 'C'};
  final parent = InstructionSetNode(name: 'Parent');
  final root = InstructionSetNode(name: 'Root');
  final nodes = <String, SequenceNode>{};
  final ids = <String, String>{};
  final childIds = <String>[];

  for (var i = 0; i < names.length; i++) {
    final name = names[i];
    final SequenceNode node = runMembers.contains(name)
        ? ExposureNode(
            name: name,
            filter: name,
            durationSecs: 300,
            count: 12,
            ditherEvery: 0,
          )
        : DelayNode(name: name, seconds: 5);
    nodes[node.id] = node.copyWith(parentId: parent.id, orderIndex: i);
    ids[name] = node.id;
    childIds.add(node.id);
  }

  nodes[parent.id] =
      parent.copyWith(parentId: root.id, orderIndex: 0, childIds: childIds);
  nodes[root.id] = root.copyWith(childIds: [parent.id]);

  return (
    sequence: Sequence.create(name: 'T', rootNodeId: root.id, nodes: nodes),
    parentId: parent.id,
    ids: ids,
  );
}

class _Probe extends ConsumerWidget {
  const _Probe({required this.onReady});
  final void Function(BuildContext context, WidgetRef ref) onReady;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    onReady(context, ref);
    return const SizedBox.shrink();
  }
}

/// Mount just enough of an app to satisfy the mutation helper (it needs a
/// `ScaffoldMessenger` for the locked-sequence snackbar) and hand back the
/// live context and ref every fold action takes.
Future<({ProviderContainer container, BuildContext context, WidgetRef ref})>
    _mount(WidgetTester tester, Sequence sequence) async {
  final container = ProviderContainer(overrides: [
    inMemoryDatabaseOverride(),
    currentSequenceProvider.overrideWith((ref) {
      final notifier = CurrentSequenceNotifier();
      // ignore: invalid_use_of_protected_member
      notifier.state = sequence;
      return notifier;
    }),
  ]);
  addTearDown(container.dispose);

  late BuildContext context;
  late WidgetRef ref;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: _Probe(onReady: (c, r) {
            context = c;
            ref = r;
          }),
        ),
      ),
    ),
  );
  return (container: container, context: context, ref: ref);
}

/// The child names of [parentId], in order — the one thing every case here is
/// really asserting.
List<String> _order(ProviderContainer container, String parentId) {
  final sequence = container.read(currentSequenceProvider)!;
  return sequence.nodes[parentId]!.childIds
      .map((id) => sequence.nodes[id]!.name)
      .toList();
}

FoldGroup _group(ProviderContainer container, String parentId) {
  final sequence = container.read(currentSequenceProvider)!;
  return foldChildren(sequence, parentId, unfoldedGroupIds: const <String>{})
      .whereType<FoldedEntry>()
      .single
      .group;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('moveFoldGroup — the block lands contiguous and in order', () {
    testWidgets('Move Down inside its own parent', (tester) async {
      final built = _tree(['A', 'B', 'C', 'Y', 'Z']);
      final m = await _mount(tester, built.sequence);
      final group = _group(m.container, built.parentId);

      // What the kebab passes: the slot the step AFTER the run occupies today.
      await moveFoldGroup(
        m.context,
        m.ref,
        memberIds: group.memberIds,
        parentId: built.parentId,
        index: group.firstIndex + group.memberCount,
      );
      await tester.pump();

      expect(_order(m.container, built.parentId), ['Y', 'A', 'B', 'C', 'Z']);
    });

    testWidgets('Move Up inside its own parent', (tester) async {
      final built = _tree(['X', 'A', 'B', 'C', 'Z']);
      final m = await _mount(tester, built.sequence);
      final group = _group(m.container, built.parentId);

      await moveFoldGroup(
        m.context,
        m.ref,
        memberIds: group.memberIds,
        parentId: built.parentId,
        index: group.firstIndex - 1,
      );
      await tester.pump();

      expect(_order(m.container, built.parentId), ['A', 'B', 'C', 'X', 'Z']);
    });

    testWidgets('a drop two slots below the run', (tester) async {
      final built = _tree(['A', 'B', 'C', 'Y', 'Z', 'W']);
      final m = await _mount(tester, built.sequence);
      final group = _group(m.container, built.parentId);

      await moveFoldGroup(
        m.context,
        m.ref,
        memberIds: group.memberIds,
        parentId: built.parentId,
        index: 4,
      );
      await tester.pump();

      expect(
        _order(m.container, built.parentId),
        ['Y', 'Z', 'A', 'B', 'C', 'W'],
      );
    });

    testWidgets('a drop onto the run\'s own position changes nothing',
        (tester) async {
      final built = _tree(['X', 'A', 'B', 'C', 'Z']);
      final m = await _mount(tester, built.sequence);
      final group = _group(m.container, built.parentId);

      await moveFoldGroup(
        m.context,
        m.ref,
        memberIds: group.memberIds,
        parentId: built.parentId,
        index: group.firstIndex,
      );
      await tester.pump();

      expect(_order(m.container, built.parentId), ['X', 'A', 'B', 'C', 'Z']);
    });

    testWidgets('appending to the end of its own parent', (tester) async {
      final built = _tree(['A', 'B', 'C', 'Y', 'Z']);
      final m = await _mount(tester, built.sequence);
      final group = _group(m.container, built.parentId);

      // `acceptIntoContainer`'s index: the child count of the destination.
      await moveFoldGroup(
        m.context,
        m.ref,
        memberIds: group.memberIds,
        parentId: built.parentId,
        index: 5,
      );
      await tester.pump();

      expect(_order(m.container, built.parentId), ['Y', 'Z', 'A', 'B', 'C']);
    });

    testWidgets('across parents, where the removal shifts nothing',
        (tester) async {
      final built = _tree(['A', 'B', 'C', 'Y']);
      final other = InstructionSetNode(name: 'Other');
      final keep = DelayNode(name: 'Keep', seconds: 5);
      final sequence = built.sequence.copyWith(nodes: {
        ...built.sequence.nodes,
        keep.id: keep.copyWith(parentId: other.id, orderIndex: 0),
        other.id: other.copyWith(
          parentId: built.sequence.rootNodeId,
          orderIndex: 1,
          childIds: [keep.id],
        ),
        built.sequence.rootNodeId!:
            built.sequence.rootNode!.copyWith(childIds: [
          built.parentId,
          other.id,
        ]),
      });
      final m = await _mount(tester, sequence);
      final group = _group(m.container, built.parentId);

      await moveFoldGroup(
        m.context,
        m.ref,
        memberIds: group.memberIds,
        parentId: other.id,
        index: 0,
      );
      await tester.pump();

      expect(_order(m.container, other.id), ['A', 'B', 'C', 'Keep']);
      expect(_order(m.container, built.parentId), ['Y']);
    });

    testWidgets('the whole block is one undo step', (tester) async {
      final built = _tree(['A', 'B', 'C', 'Y']);
      final m = await _mount(tester, built.sequence);
      final notifier = m.container.read(currentSequenceProvider.notifier);
      expect(notifier.undoStack, isEmpty);

      await moveFoldGroup(
        m.context,
        m.ref,
        memberIds: _group(m.container, built.parentId).memberIds,
        parentId: built.parentId,
        index: 4,
      );
      await tester.pump();
      expect(notifier.undoStack, hasLength(1));

      notifier.undo();
      expect(_order(m.container, built.parentId), ['A', 'B', 'C', 'Y']);
    });
  });

  testWidgets('Duplicate leaves the run twice, back to back', (tester) async {
    final built = _tree(['X', 'A', 'B', 'C', 'Y']);
    final m = await _mount(tester, built.sequence);

    await duplicateFoldGroup(
      m.context,
      m.ref,
      group: _group(m.container, built.parentId),
    );
    await tester.pump();

    // `duplicateNode` inserts each copy directly after ITS original, so the
    // naive loop interleaves the two runs (`A A' B B' C C'`) — which folds
    // back into one six-member group and reads as one run with every filter
    // doubled. What the user asked for is the same run, twice.
    expect(
      _order(m.container, built.parentId),
      ['X', 'A', 'B', 'C', 'A (Copy)', 'B (Copy)', 'C (Copy)', 'Y'],
    );
    final ids = m.container
        .read(currentSequenceProvider)!
        .nodes[built.parentId]!
        .childIds;
    expect(ids.toSet(), hasLength(8), reason: 'the copies are new nodes');
    expect(
      m.container.read(currentSequenceProvider.notifier).undoStack,
      hasLength(1),
      reason: 'one Ctrl+Z takes the whole duplicate back',
    );
  });

  testWidgets('Disable all strikes every member out in one step',
      (tester) async {
    final built = _tree(['X', 'A', 'B', 'C']);
    final m = await _mount(tester, built.sequence);
    final group = _group(m.container, built.parentId);

    await disableFoldGroup(m.context, m.ref, memberIds: group.memberIds);
    await tester.pump();

    final after = m.container.read(currentSequenceProvider)!;
    for (final id in group.memberIds) {
      expect(after.nodes[id]!.isEnabled, isFalse);
    }
    expect(after.nodes[built.ids['X']]!.isEnabled, isTrue);
    expect(
      m.container.read(currentSequenceProvider.notifier).undoStack,
      hasLength(1),
    );
    // A disabled step is not a run member, so the row is gone on the next
    // build and its (struck-through) members are back.
    expect(
      foldChildren(after, built.parentId, unfoldedGroupIds: const <String>{})
          .whereType<FoldedEntry>(),
      isEmpty,
    );
  });

  testWidgets('Delete asks once, removes every member and clears the selection',
      (tester) async {
    final built = _tree(['X', 'A', 'B', 'C']);
    final m = await _mount(tester, built.sequence);
    final group = _group(m.container, built.parentId);
    m.container.read(selectedNodeIdProvider.notifier).state =
        group.memberIds.first;

    final done = confirmAndDeleteFoldGroup(
      context: m.context,
      ref: m.ref,
      group: group,
    );
    await tester.pumpAndSettle();
    expect(find.text('Delete 3 steps?'), findsOneWidget);
    await tester.tap(find.widgetWithText(SkotiqButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(await done, isTrue);
    expect(_order(m.container, built.parentId), ['X']);
    expect(m.container.read(selectedNodeIdProvider), isNull);
    expect(m.container.read(multiSelectedNodeIdsProvider), isEmpty);
  });
}
