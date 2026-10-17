// Two sibling instruction nodes of the SAME type at depth 1 must both
// render. Live drive 2026-08-13 (waveH-final, 38-two-siblings.png): adding a
// second "Take Exposures" node beside the first left the tree showing ONE
// instruction card painted over the root card, and the second card absent
// from the accessibility tree — every model surface (header, pre-flight,
// timeline) counted two. Root cause: the depth-1 tutorial anchor was a
// static GlobalKey handed to EVERY node of the matching type, and Flutter
// resolves a duplicate GlobalKey by stealing the element from its first
// holder.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/ledger_columns.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequencer_density.dart';
import 'package:skotiq_app/widgets/tutorial_keys/tutorial_keys.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

Sequence _twoSiblings({required String first, required String second}) {
  final a = ExposureNode(name: first, durationSecs: 2, count: 4);
  final b = ExposureNode(name: second, durationSecs: 2, count: 4);
  final root = InstructionSetNode(name: 'Sequence');
  final tree = <String, SequenceNode>{
    a.id: a.copyWith(parentId: root.id, orderIndex: 0),
    b.id: b.copyWith(parentId: root.id, orderIndex: 1),
    root.id: root.copyWith(childIds: [a.id, b.id]),
  };
  return Sequence.create(name: 'T', nodes: tree, rootNodeId: root.id);
}

/// [density] null leaves the shipped default (Ledger) in place, which is where
/// the collision this file guards has to be proved. Pass Comfortable only for
/// a fixture Ledger would FOLD: two same-spec sibling exposures are one row
/// there (spec §6), and a case about two rows cannot be asserted on one.
Future<({ProviderContainer container, void Function() dispose})> _pumpTree(
  WidgetTester tester,
  Sequence sequence, {
  SequencerDensity? density,
}) async {
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      currentSequenceProvider.overrideWith((ref) {
        final n = CurrentSequenceNotifier();
        // ignore: invalid_use_of_protected_member
        n.state = sequence;
        return n;
      }),
      // The ledger ETA clock is a real periodic stream; in the fake-async
      // zone its timer outlives every pump and fails teardown.
      ledgerClockProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
      if (density != null)
        sequencerDensityProvider.overrideWith((ref) => density),
    ],
  );
  var disposed = false;
  void disposeOnce() {
    if (disposed) return;
    disposed = true;
    container.dispose();
  }

  addTearDown(disposeOnce);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: SequenceTree(colors: SkotiqColors.dark),
        ),
      ),
    ),
  );
  await tester.pump();
  // The tree schedules a short (500 ms) debounce after build; drain it so
  // teardown never trips the pending-timer assertion under a loaded run.
  await tester.pump(const Duration(milliseconds: 600));
  return (container: container, dispose: disposeOnce);
}

void main() {
  testWidgets('two sibling Take Exposures nodes both render a card',
      (tester) async {
    await _pumpTree(
      tester,
      _twoSiblings(first: 'Node A', second: 'Node B'),
      density: SequencerDensity.comfortable,
    );

    expect(tester.takeException(), isNull,
        reason: 'building the tree must not trip a duplicate-GlobalKey error');
    expect(find.text('Node A'), findsOneWidget);
    expect(find.text('Node B'), findsOneWidget,
        reason: 'the second sibling card vanished from the tree '
            '(waveH-final 38-two-siblings.png)');
  });

  testWidgets('the first node of each type still carries a tutorial anchor',
      (tester) async {
    // The coach marks need SOME depth-1 capture node to point at; losing the
    // anchor entirely would silently break the tutorial overlay.
    await _pumpTree(
      tester,
      _twoSiblings(first: 'Node A', second: 'Node B'),
      density: SequencerDensity.comfortable,
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(SequencerTutorialKeys.captureNode), findsOneWidget);
  });

  testWidgets('three same-type siblings all render', (tester) async {
    // Three DIFFERENT exposure lengths, so Ledger draws three rows rather than
    // one folded run — the anchor collision is a per-row problem and this
    // proves it is gone in the density the app ships on.
    final a = ExposureNode(name: 'Node A', durationSecs: 2, count: 1);
    final b = ExposureNode(name: 'Node B', durationSecs: 3, count: 1);
    final c = ExposureNode(name: 'Node C', durationSecs: 4, count: 1);
    final root = InstructionSetNode(name: 'Sequence');
    final tree = <String, SequenceNode>{
      a.id: a.copyWith(parentId: root.id, orderIndex: 0),
      b.id: b.copyWith(parentId: root.id, orderIndex: 1),
      c.id: c.copyWith(parentId: root.id, orderIndex: 2),
      root.id: root.copyWith(childIds: [a.id, b.id, c.id]),
    };
    await _pumpTree(
      tester,
      Sequence.create(name: 'T', nodes: tree, rootNodeId: root.id),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Node A'), findsOneWidget);
    expect(find.text('Node B'), findsOneWidget);
    expect(find.text('Node C'), findsOneWidget);
  });

  testWidgets('two sibling target headers both render', (tester) async {
    // The targetNode anchor is the same static-GlobalKey pattern; a two-
    // target sequence (any mosaic or multi-target night) hit the identical
    // collision.
    final a = TargetHeaderNode(
        name: 'M31', targetName: 'M31', raHours: 0.71, decDegrees: 41.27);
    final b = TargetHeaderNode(
        name: 'M42', targetName: 'M42', raHours: 5.59, decDegrees: -5.39);
    final root = InstructionSetNode(name: 'Sequence');
    final tree = <String, SequenceNode>{
      a.id: a.copyWith(parentId: root.id, orderIndex: 0),
      b.id: b.copyWith(parentId: root.id, orderIndex: 1),
      root.id: root.copyWith(childIds: [a.id, b.id]),
    };
    await _pumpTree(
      tester,
      Sequence.create(name: 'T', nodes: tree, rootNodeId: root.id),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('M31'), findsOneWidget);
    expect(find.text('M42'), findsOneWidget);
    expect(find.byKey(SequencerTutorialKeys.targetNode), findsOneWidget);
  });

  testWidgets('deleting the anchor holder hands the anchor to the next node',
      (tester) async {
    final handle = await _pumpTree(
      tester,
      _twoSiblings(first: 'Node A', second: 'Node B'),
      density: SequencerDensity.comfortable,
    );
    final container = handle.container;
    final sequence = container.read(currentSequenceProvider)!;
    final rootId = sequence.rootNodeId!;
    final firstChildId = sequence.getChildren(rootId)[0].id;
    container.read(currentSequenceProvider.notifier).removeNode(firstChildId);
    await tester.pump();
    // The edit arms the sequence auto-save debounce, and dropping a watch
    // lets drift close its query stream via a zero-duration timer on the
    // following frame; drain both.
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Node A'), findsNothing);
    expect(find.text('Node B'), findsOneWidget);
    expect(find.byKey(SequencerTutorialKeys.captureNode), findsOneWidget);

    // The edit opened a drift query stream the CONTAINER holds; closing it is
    // a zero-duration timer that must fire inside the test body, so unmount
    // and dispose here rather than in teardown.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    handle.dispose();
    // Plain pump() never advances the fake clock, and a zero-duration timer
    // only fires on an elapse.
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
  });
}
