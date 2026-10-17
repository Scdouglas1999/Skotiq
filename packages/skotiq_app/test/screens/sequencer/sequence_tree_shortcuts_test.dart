// Tests for the sequencer tree keyboard navigation actions.
//
// We exercise the [Intent] -> [Action] surface directly (without
// spinning up the real tree) by building a ProviderContainer, seeding
// a sequence, and invoking the intents. This keeps the tests fast and the
// failure messages obvious — a failure here points straight at _moveSelection /
// the collapse logic, not at widget layout.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree_shortcuts.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// Three plain sibling rows.
///
/// Delays, not exposures: three exposures with an identical capture spec are a
/// run, and in the default (Ledger) density a run is ONE row in the visible
/// order (spec §6) — which is what `sequence_tree_fold_rows_test.dart` covers.
/// This file is about walking rows, so its fixture must be three rows.
({Sequence sequence, List<String> visibleIds}) _threeNodeTree() {
  final a = DelayNode(name: 'a', seconds: 1);
  final b = DelayNode(name: 'b', seconds: 1);
  final c = DelayNode(name: 'c', seconds: 1);
  final root = InstructionSetNode(name: 'Root');
  final tree = <String, SequenceNode>{
    a.id: a.copyWith(parentId: root.id, orderIndex: 0),
    b.id: b.copyWith(parentId: root.id, orderIndex: 1),
    c.id: c.copyWith(parentId: root.id, orderIndex: 2),
    root.id: root.copyWith(childIds: [a.id, b.id, c.id]),
  };
  return (
    sequence: Sequence.create(name: 'T', nodes: tree, rootNodeId: root.id),
    visibleIds: [a.id, b.id, c.id],
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
  ]);
  addTearDown(container.dispose);
  return container;
}

/// Tiny widget that exposes a `WidgetRef` so we can grab the actions map
/// and dispatch intents without instantiating SequenceTree.
class _ProbeWidget extends ConsumerWidget {
  const _ProbeWidget({required this.onRef});
  final void Function(WidgetRef ref) onRef;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    onRef(ref);
    return const SizedBox.shrink();
  }
}

Future<Map<Type, Action<Intent>>> _grabActions(
  WidgetTester tester,
  ProviderContainer container,
) async {
  late Map<Type, Action<Intent>> actions;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: _ProbeWidget(
          onRef: (ref) => actions = buildSequenceTreeActions(ref),
        ),
      ),
    ),
  );
  return actions;
}

/// Invoke an action by intent type. Wrapping `.invoke` keeps the
/// `@protected` lint suppression in one place rather than at every call
/// site.
void _dispatch(Map<Type, Action<Intent>> actions, Intent intent) {
  // ignore: invalid_use_of_protected_member
  actions[intent.runtimeType]!.invoke(intent);
}

void main() {
  testWidgets('ArrowDown advances selection through visible rows',
      (tester) async {
    final t = _threeNodeTree();
    final container = _container(t.sequence);
    final actions = await _grabActions(tester, container);

    // No selection yet: ArrowDown should snap to the first node.
    _dispatch(actions, const TreeMoveSelectionDownIntent());
    expect(container.read(selectedNodeIdProvider), t.visibleIds.first);

    // Press again -> second node.
    _dispatch(actions, const TreeMoveSelectionDownIntent());
    expect(container.read(selectedNodeIdProvider), t.visibleIds[1]);

    // Past the bottom should clamp at the last row.
    _dispatch(actions, const TreeMoveSelectionDownIntent());
    _dispatch(actions, const TreeMoveSelectionDownIntent());
    expect(container.read(selectedNodeIdProvider), t.visibleIds.last);
  });

  testWidgets('ArrowUp walks backward and clamps at top', (tester) async {
    final t = _threeNodeTree();
    final container = _container(t.sequence);
    final actions = await _grabActions(tester, container);

    // Seed selection on the last visible node.
    container.read(selectedNodeIdProvider.notifier).state = t.visibleIds.last;

    _dispatch(actions, const TreeMoveSelectionUpIntent());
    expect(container.read(selectedNodeIdProvider), t.visibleIds[1]);

    _dispatch(actions, const TreeMoveSelectionUpIntent());
    expect(container.read(selectedNodeIdProvider), t.visibleIds.first);

    // Going past the top should not change selection (clamp at 0).
    _dispatch(actions, const TreeMoveSelectionUpIntent());
    expect(container.read(selectedNodeIdProvider), t.visibleIds.first);
  });

  testWidgets('Left arrow collapses, Right arrow expands the selected node',
      (tester) async {
    final t = _threeNodeTree();
    final container = _container(t.sequence);
    final actions = await _grabActions(tester, container);

    container.read(selectedNodeIdProvider.notifier).state = t.visibleIds[1];

    // Collapse.
    _dispatch(actions, const TreeCollapseFocusedIntent());
    expect(container.read(collapsedNodeIdsProvider).contains(t.visibleIds[1]),
        isTrue);

    // Expand.
    _dispatch(actions, const TreeExpandFocusedIntent());
    expect(container.read(collapsedNodeIdsProvider).contains(t.visibleIds[1]),
        isFalse);
  });

  testWidgets('Enter ticks the properties-focus request provider',
      (tester) async {
    final t = _threeNodeTree();
    final container = _container(t.sequence);
    final actions = await _grabActions(tester, container);

    final before = container.read(propertiesPanelFocusRequestProvider);
    _dispatch(actions, const TreeFocusPropertiesIntent());
    final after = container.read(propertiesPanelFocusRequestProvider);
    expect(after, before + 1);
  });

  testWidgets('Shift+ArrowDown extends multi-selection over a sibling range',
      (tester) async {
    final t = _threeNodeTree();
    final container = _container(t.sequence);
    final actions = await _grabActions(tester, container);

    // Start on the first sibling; Shift+Down should range-select [a, b].
    container.read(selectedNodeIdProvider.notifier).state = t.visibleIds.first;

    _dispatch(actions, const TreeMoveSelectionDownIntent(extend: true));

    final multi = container.read(multiSelectedNodeIdsProvider);
    expect(multi, containsAll([t.visibleIds[0], t.visibleIds[1]]));
  });
}
