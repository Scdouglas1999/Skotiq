// Swipe-delete + Undo of a *container* node in the mobile sequence editor must
// restore the subtree with each child linked exactly once. Re-adding the
// captured root with its childIds intact and then re-adding every descendant
// duplicates them, because the editor's `addNode` appends to the parent's child
// list with no dedup (childIds go [c1, c2] -> [c1, c2, c1, c2]).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/mobile_sequence_editor.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

({Sequence sequence, String containerId, List<String> childIds})
    _containerTree() {
  final c1 = ExposureNode(name: 'c1', durationSecs: 1, count: 1);
  final c2 = ExposureNode(name: 'c2', durationSecs: 1, count: 1);
  final container = InstructionSetNode(name: 'Loop');
  final root = InstructionSetNode(name: 'Root');
  final nodes = <String, SequenceNode>{
    c1.id: c1.copyWith(parentId: container.id, orderIndex: 0),
    c2.id: c2.copyWith(parentId: container.id, orderIndex: 1),
    container.id:
        container.copyWith(parentId: root.id, childIds: [c1.id, c2.id]),
    root.id: root.copyWith(childIds: [container.id]),
  };
  return (
    sequence: Sequence.create(name: 'T', nodes: nodes, rootNodeId: root.id),
    containerId: container.id,
    childIds: [c1.id, c2.id],
  );
}

ProviderContainer _container(Sequence sequence) {
  final container = ProviderContainer(overrides: [
    inMemoryDatabaseOverride(),
    currentSequenceProvider.overrideWith((ref) {
      final n = CurrentSequenceNotifier();
      // ignore: invalid_use_of_protected_member
      n.state = sequence;
      return n;
    }),
    sequenceExecutionStateProvider
        .overrideWith((ref) => SequenceExecutionState.idle),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  testWidgets('undo of a deleted container restores children exactly once',
      (tester) async {
    final t = _containerTree();
    final container = _container(t.sequence);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: MobileSequenceEditor()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Swipe-delete the container row.
    await tester.drag(
      find.byKey(ValueKey('mobile-seq-dismiss-${t.containerId}')),
      const Offset(-600, 0),
    );
    await tester.pumpAndSettle();

    // Container and its subtree are gone; the Undo snackbar is up.
    expect(
        container.read(currentSequenceProvider)!.nodes[t.containerId], isNull);
    expect(find.text('Undo'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    final restored = container.read(currentSequenceProvider)!;
    final rebuilt = restored.nodes[t.containerId];
    expect(rebuilt, isNotNull);
    // The core assertion: children restored once, in order — not duplicated.
    expect(rebuilt!.childIds, t.childIds);
    // And the root re-adopts the container exactly once.
    expect(
      restored.rootNode!.childIds.where((id) => id == t.containerId).length,
      1,
    );
  });
}
