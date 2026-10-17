// Tests for the secondary-tap / long-press context menu wired around
// tree nodes. We mount only the wrapper widget itself with a known
// sequence so the test stays focused on the menu's lifecycle (open ->
// pick item -> mutate sequence).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_palette_empty_state.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree_context_menu.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

({Sequence sequence, String containerId, String childId})
    _containerWithOneChild() {
  final child = ExposureNode(name: 'child', durationSecs: 1, count: 1);
  final container = InstructionSetNode(name: 'container');
  final root = InstructionSetNode(name: 'Root');
  final tree = <String, SequenceNode>{
    child.id: child.copyWith(parentId: container.id),
    container.id: container.copyWith(parentId: root.id, childIds: [child.id]),
    root.id: root.copyWith(childIds: [container.id]),
  };
  return (
    sequence: Sequence.create(name: 'T', nodes: tree, rootNodeId: root.id),
    containerId: container.id,
    childId: child.id,
  );
}

({
  Sequence sequence,
  String containerId,
  String firstChildId,
  String secondChildId
}) _containerWithTwoChildren() {
  final first = ExposureNode(name: 'first', durationSecs: 1, count: 1);
  final second = ExposureNode(name: 'second', durationSecs: 1, count: 1);
  final container = InstructionSetNode(name: 'container');
  final root = InstructionSetNode(name: 'Root');
  final tree = <String, SequenceNode>{
    first.id: first.copyWith(parentId: container.id, orderIndex: 0),
    second.id: second.copyWith(parentId: container.id, orderIndex: 1),
    container.id:
        container.copyWith(parentId: root.id, childIds: [first.id, second.id]),
    root.id: root.copyWith(childIds: [container.id]),
  };
  return (
    sequence: Sequence.create(name: 'T', nodes: tree, rootNodeId: root.id),
    containerId: container.id,
    firstChildId: first.id,
    secondChildId: second.id,
  );
}

ProviderContainer _seed(Sequence seq) {
  final notifier = CurrentSequenceNotifier();
  // ignore: invalid_use_of_protected_member
  notifier.state = seq;
  final container = ProviderContainer(overrides: [
    inMemoryDatabaseOverride(),
    currentSequenceProvider.overrideWith((_) => notifier),
  ]);
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  Widget child,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(body: child),
      ),
    ),
  );
}

SkotiqColors _colors() {
  return SkotiqColors.dark;
}

/// Open the context menu via long-press. The wrapper exposes both
/// `onSecondaryTapUp` and `onLongPressStart`, and exercising the
/// long-press branch is enough to validate the menu lifecycle from the
/// test surface (the secondary-tap branch is identical except for the
/// trigger gesture). Tested separately on the desktop platform during
/// manual QA.
Future<void> _openMenu(WidgetTester tester, Finder finder) async {
  await tester.longPress(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('right-click opens menu and selects the node', (tester) async {
    final t = _containerWithOneChild();
    final container = _seed(t.sequence);

    await _pump(
      tester,
      container,
      SequenceTreeContextMenu(
        nodeId: t.childId,
        colors: _colors(),
        child: const SizedBox(
          width: 200,
          height: 40,
          child: Center(child: Text('row')),
        ),
      ),
    );

    await _openMenu(tester, find.text('row'));

    // Menu should be open and the node should be selected as a side
    // effect of opening it (matches OS conventions).
    expect(find.text('Insert Above'), findsOneWidget);
    expect(find.text('Duplicate'), findsOneWidget);
    expect(find.text('Group into Sequential Container'), findsOneWidget);
    expect(find.text('Group into Parallel Container'), findsOneWidget);
    expect(find.text('Disable'), findsOneWidget); // child starts enabled
    expect(find.text('Delete'), findsOneWidget);
    expect(container.read(selectedNodeIdProvider), t.childId);
  });

  testWidgets('Duplicate creates a sibling copy', (tester) async {
    final t = _containerWithOneChild();
    final container = _seed(t.sequence);

    await _pump(
      tester,
      container,
      SequenceTreeContextMenu(
        nodeId: t.childId,
        colors: _colors(),
        child: const SizedBox(
            width: 200, height: 40, child: Center(child: Text('row'))),
      ),
    );

    await _openMenu(tester, find.text('row'));

    await tester.tap(find.text('Duplicate'));
    await tester.pumpAndSettle();

    final seq = container.read(currentSequenceProvider)!;
    final parent = seq.nodes[t.containerId]!;
    expect(parent.childIds.length, 2);
  });

  testWidgets('Group into Sequential Container wraps the node', (tester) async {
    final t = _containerWithOneChild();
    final container = _seed(t.sequence);

    await _pump(
      tester,
      container,
      SequenceTreeContextMenu(
        nodeId: t.childId,
        colors: _colors(),
        child: const SizedBox(
            width: 200, height: 40, child: Center(child: Text('row'))),
      ),
    );

    await _openMenu(tester, find.text('row'));
    await tester.tap(find.text('Group into Sequential Container'));
    await tester.pumpAndSettle();

    final seq = container.read(currentSequenceProvider)!;
    final wrappedChild = seq.nodes[t.childId]!;
    // The child's parent should no longer be the original container — it
    // should be a freshly created InstructionSetNode sitting between
    // them.
    expect(wrappedChild.parentId, isNot(t.containerId));
    final newParent = seq.nodes[wrappedChild.parentId!]!;
    expect(newParent, isA<InstructionSetNode>());
    expect(newParent.parentId, t.containerId);
  });

  testWidgets(
      'Group into Parallel Container is disabled for a single node and '
      'leaves the tree unchanged', (tester) async {
    // A parallel branch of one is semantically a no-op, so the menu now
    // gates "Group into Parallel Container" behind a 2+ contiguous-sibling
    // selection. With only the right-clicked node "selected", the entry is
    // disabled and tapping it must not mutate the sequence.
    final t = _containerWithOneChild();
    final container = _seed(t.sequence);

    await _pump(
      tester,
      container,
      SequenceTreeContextMenu(
        nodeId: t.childId,
        colors: _colors(),
        child: const SizedBox(
            width: 200, height: 40, child: Center(child: Text('row'))),
      ),
    );

    await _openMenu(tester, find.text('row'));

    // The disabled PopupMenuItem renders its label muted; tapping it is a
    // no-op (Flutter swallows taps on disabled menu items).
    await tester.tap(find.text('Group into Parallel Container'));
    await tester.pumpAndSettle();

    final seq = container.read(currentSequenceProvider)!;
    final child = seq.nodes[t.childId]!;
    // Parent is still the original Sequential container — nothing wrapped.
    expect(child.parentId, t.containerId);
    expect(seq.nodes[t.containerId], isA<InstructionSetNode>());
  });

  testWidgets(
      'Group into Parallel Container wraps a 2+ contiguous sibling selection',
      (tester) async {
    final t = _containerWithTwoChildren();
    final container = _seed(t.sequence);
    // Multi-select both siblings so the parallel grouping is enabled and
    // wraps the whole subset into a single ParallelNode.
    container
        .read(multiSelectedNodeIdsProvider.notifier)
        .selectAll([t.firstChildId, t.secondChildId]);

    await _pump(
      tester,
      container,
      SequenceTreeContextMenu(
        nodeId: t.firstChildId,
        colors: _colors(),
        child: const SizedBox(
            width: 200, height: 40, child: Center(child: Text('row'))),
      ),
    );

    await _openMenu(tester, find.text('row'));
    await tester.tap(find.text('Group into Parallel Container'));
    await tester.pumpAndSettle();

    final seq = container.read(currentSequenceProvider)!;
    final wrappedChild = seq.nodes[t.firstChildId]!;
    final newParent = seq.nodes[wrappedChild.parentId!]!;
    expect(newParent, isA<ParallelNode>());
    // Both selected siblings end up under the same new parent.
    expect(seq.nodes[t.secondChildId]!.parentId, wrappedChild.parentId);
    expect(newParent.parentId, t.containerId);
  });

  testWidgets('Disable toggles isEnabled', (tester) async {
    final t = _containerWithOneChild();
    final container = _seed(t.sequence);

    await _pump(
      tester,
      container,
      SequenceTreeContextMenu(
        nodeId: t.childId,
        colors: _colors(),
        child: const SizedBox(
            width: 200, height: 40, child: Center(child: Text('row'))),
      ),
    );

    await _openMenu(tester, find.text('row'));
    await tester.tap(find.text('Disable'));
    await tester.pumpAndSettle();

    expect(
      container.read(currentSequenceProvider)!.nodes[t.childId]!.isEnabled,
      isFalse,
    );

    // Reopen the menu; the same entry should now read "Enable".
    await _openMenu(tester, find.text('row'));
    expect(find.text('Enable'), findsOneWidget);
  });

  testWidgets('Delete on a leaf prompts for confirmation, then removes',
      (tester) async {
    // Post-consolidation: every user-initiated delete surface (Properties
    // panel, targets tab, tree trash, right-click Delete, Delete key)
    // funnels through `confirmAndDeleteSequenceNode`, which always
    // prompts. Leaves get a simpler "removed from sequence" body without
    // a descendant count.
    final t = _containerWithOneChild();
    final container = _seed(t.sequence);

    await _pump(
      tester,
      container,
      SequenceTreeContextMenu(
        nodeId: t.childId,
        colors: _colors(),
        child: const SizedBox(
            width: 200, height: 40, child: Center(child: Text('row'))),
      ),
    );

    await _openMenu(tester, find.text('row'));
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    // Confirmation dialog is on screen and the leaf is still alive.
    expect(find.text('Cancel'), findsOneWidget);
    expect(
        container.read(currentSequenceProvider)!.nodes.containsKey(t.childId),
        isTrue);

    // Confirm — the "Delete" action button (not the menu entry which
    // closed when we tapped it). The dialog uses a SkotiqButton with
    // text "Delete".
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(
        container.read(currentSequenceProvider)!.nodes.containsKey(t.childId),
        isFalse);
  });

  testWidgets('Delete on a leaf can be cancelled and leaves the node in place',
      (tester) async {
    final t = _containerWithOneChild();
    final container = _seed(t.sequence);

    await _pump(
      tester,
      container,
      SequenceTreeContextMenu(
        nodeId: t.childId,
        colors: _colors(),
        child: const SizedBox(
            width: 200, height: 40, child: Center(child: Text('row'))),
      ),
    );

    await _openMenu(tester, find.text('row'));
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Cancel'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(
        container.read(currentSequenceProvider)!.nodes.containsKey(t.childId),
        isTrue);
  });

  // Order is semantically load-bearing in a sequence (unpark must precede
  // slew), and drag-and-drop inside a long scrolling tree is the wrong tool for
  // moving one row. Right-click is the reflex, so it carries the reorder.
  testWidgets('Move Up shifts the node one slot earlier among its siblings',
      (tester) async {
    final t = _containerWithTwoChildren();
    final container = _seed(t.sequence);

    await _pump(
      tester,
      container,
      SequenceTreeContextMenu(
        nodeId: t.secondChildId,
        colors: _colors(),
        child: const SizedBox(
            width: 200, height: 40, child: Center(child: Text('row'))),
      ),
    );

    await _openMenu(tester, find.text('row'));
    expect(find.text('Move Up'), findsOneWidget);
    await tester.tap(find.text('Move Up'));
    await tester.pumpAndSettle();

    final parent =
        container.read(currentSequenceProvider)!.nodes[t.containerId]!;
    expect(parent.childIds, [t.secondChildId, t.firstChildId]);
  });

  testWidgets('Move Down shifts the node one slot later among its siblings',
      (tester) async {
    final t = _containerWithTwoChildren();
    final container = _seed(t.sequence);

    await _pump(
      tester,
      container,
      SequenceTreeContextMenu(
        nodeId: t.firstChildId,
        colors: _colors(),
        child: const SizedBox(
            width: 200, height: 40, child: Center(child: Text('row'))),
      ),
    );

    await _openMenu(tester, find.text('row'));
    await tester.tap(find.text('Move Down'));
    await tester.pumpAndSettle();

    final parent =
        container.read(currentSequenceProvider)!.nodes[t.containerId]!;
    expect(parent.childIds, [t.secondChildId, t.firstChildId]);
  });

  testWidgets('Move Up is disabled on the first sibling and changes nothing',
      (tester) async {
    final t = _containerWithTwoChildren();
    final container = _seed(t.sequence);

    await _pump(
      tester,
      container,
      SequenceTreeContextMenu(
        nodeId: t.firstChildId,
        colors: _colors(),
        child: const SizedBox(
            width: 200, height: 40, child: Center(child: Text('row'))),
      ),
    );

    await _openMenu(tester, find.text('row'));
    // Flutter swallows taps on disabled PopupMenuItems — order must hold.
    await tester.tap(find.text('Move Up'));
    await tester.pumpAndSettle();

    final parent =
        container.read(currentSequenceProvider)!.nodes[t.containerId]!;
    expect(parent.childIds, [t.firstChildId, t.secondChildId]);
  });

  // The Insert Above / Insert Below picker is a THIRD node-palette search
  // box. The two main palettes were moved onto the shared relevance ranker;
  // this one still filtered on `name || description` in catalogue order, so
  // typing an exact node name here still offered a description match first.
  testWidgets(
      'Insert picker ranks an exact name match above a description '
      'match', (tester) async {
    final t = _containerWithTwoChildren();
    final container = ProviderContainer(overrides: [
      inMemoryDatabaseOverride(),
      currentSequenceProvider.overrideWith((_) {
        final n = CurrentSequenceNotifier();
        // ignore: invalid_use_of_protected_member
        n.state = t.sequence;
        return n;
      }),
      nodePaletteProvider.overrideWithValue([
        NodePaletteCategory(
          name: 'Imaging',
          icon: 'camera',
          items: [
            NodePaletteItem(
              name: 'Smart Exposure',
              icon: 'camera',
              description: 'Handles rotation + dither for you',
              createNode: () => ExposureNode(),
            ),
          ],
        ),
        NodePaletteCategory(
          name: 'Guiding',
          icon: 'crosshair',
          items: [
            NodePaletteItem(
              name: 'Dither',
              icon: 'move',
              description: 'Offset the mount between frames',
              createNode: () => DitherNode(),
            ),
          ],
        ),
      ]),
    ]);
    addTearDown(container.dispose);

    await _pump(
      tester,
      container,
      SequenceTreeContextMenu(
        nodeId: t.firstChildId,
        colors: _colors(),
        child: const SizedBox(
            width: 200, height: 40, child: Center(child: Text('row'))),
      ),
    );

    await _openMenu(tester, find.text('row'));
    await tester.tap(find.text('Insert Below'));
    await tester.pumpAndSettle();

    // Lower-case so the query echoed in the search field cannot be confused
    // with the "Dither" row label we are locating.
    await tester.enterText(find.byType(TextField).last, 'dither');
    await tester.pumpAndSettle();

    // Both still match, but the node the user literally typed must be the
    // first row — that is the one they tap.
    expect(find.text('Dither'), findsOneWidget);
    expect(find.text('Smart Exposure'), findsOneWidget);
    final ditherY = tester.getTopLeft(find.text('Dither')).dy;
    final smartY = tester.getTopLeft(find.text('Smart Exposure')).dy;
    expect(ditherY, lessThan(smartY));
  });

  // Besides the three palette surfaces that render `NodePalette` /
  // `_NodePaletteContent`, the Insert Above / Insert Below picker is a FOURTH
  // surface reading the same ranker. A ListView with zero children leaves the
  // sheet body blank below the search box when a search matches nothing.
  testWidgets('Insert picker explains a search that matches nothing',
      (tester) async {
    final t = _containerWithTwoChildren();
    final container = ProviderContainer(overrides: [
      inMemoryDatabaseOverride(),
      currentSequenceProvider.overrideWith((_) {
        final n = CurrentSequenceNotifier();
        // ignore: invalid_use_of_protected_member
        n.state = t.sequence;
        return n;
      }),
      nodePaletteProvider.overrideWithValue([
        NodePaletteCategory(
          name: 'Imaging',
          icon: 'camera',
          items: [
            NodePaletteItem(
              name: 'Smart Exposure',
              icon: 'camera',
              description: 'Handles rotation + dither for you',
              createNode: () => ExposureNode(),
            ),
          ],
        ),
      ]),
    ]);
    addTearDown(container.dispose);

    await _pump(
      tester,
      container,
      SequenceTreeContextMenu(
        nodeId: t.firstChildId,
        colors: _colors(),
        child: const SizedBox(
            width: 200, height: 40, child: Center(child: Text('row'))),
      ),
    );

    await _openMenu(tester, find.text('row'));
    await tester.tap(find.text('Insert Below'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, 'zzzqqq');
    await tester.pumpAndSettle();

    expect(find.byType(NodePaletteEmptyState), findsOneWidget);
    expect(find.text('No nodes match "zzzqqq"'), findsOneWidget);

    // The clear button has to actually restore the catalogue, or the
    // operator is stranded in a sheet with no visible way back.
    await tester.tap(find.text('Clear search'));
    await tester.pumpAndSettle();
    expect(find.byType(NodePaletteEmptyState), findsNothing);
    expect(find.text('Smart Exposure'), findsOneWidget);
  });

  testWidgets('Delete on a container with descendants asks for confirmation',
      (tester) async {
    final t = _containerWithOneChild();
    final container = _seed(t.sequence);

    await _pump(
      tester,
      container,
      SequenceTreeContextMenu(
        nodeId: t.containerId,
        colors: _colors(),
        child: const SizedBox(
            width: 200, height: 40, child: Center(child: Text('row'))),
      ),
    );

    await _openMenu(tester, find.text('row'));
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    // Confirmation dialog should now be on screen.
    expect(find.text('Cancel'), findsOneWidget);
    // The container is still present until the user confirms.
    expect(
        container
            .read(currentSequenceProvider)!
            .nodes
            .containsKey(t.containerId),
        isTrue);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(
        container
            .read(currentSequenceProvider)!
            .nodes
            .containsKey(t.containerId),
        isTrue);
  });
}
