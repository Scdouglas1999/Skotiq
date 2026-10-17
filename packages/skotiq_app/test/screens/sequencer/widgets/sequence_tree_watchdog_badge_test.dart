// Polish Pass C7 — watchdog badge for trigger-category nodes.
//
// The sequence tree renders an inline "Watchdog" badge on any
// trigger-category node (today that is MeridianFlipNode, and any future
// trigger node). The badge tells the operator the node runs in parallel
// and fires on its condition regardless of list position — non-obvious
// behavior that would otherwise read as "this step runs here".
//
// These tests pin the gating contract end-to-end through the real
// SequenceTree widget: a trigger node shows the badge; an ordinary
// instruction node (ExposureNode) does not.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/ledger_columns.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

Future<void> _pumpTreeWithNode(
  WidgetTester tester,
  ProviderContainer container,
  SequenceNode node,
) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(900, 700);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  // Seed an active sequence (creates the root) and attach the node under it.
  container.read(currentSequenceProvider.notifier).createSequence(name: 'test');
  container.read(currentSequenceProvider.notifier).addNode(node);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: SequenceTree(colors: SkotiqColors.dark),
        ),
      ),
    ),
  );
  await tester.pump();
  // liveValidationProvider debounces validation with a 500ms one-shot Timer
  // when the sequence mutates (createSequence/addNode). Advance past it so the
  // timer fires and is cleared before teardown — otherwise the test binding
  // flags a pending Timer at dispose.
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  testWidgets(
    'trigger-category node (MeridianFlipNode) shows the Watchdog badge',
    (tester) async {
      final container = ProviderContainer(overrides: [
        inMemoryDatabaseOverride(),
        // The ledger ETA clock is a real periodic stream; in the
        // fake-async zone its timer outlives every pump and fails teardown.
        ledgerClockProvider
            .overrideWith((ref) => const Stream<DateTime>.empty()),
      ]);
      addTearDown(container.dispose);

      await _pumpTreeWithNode(tester, container, MeridianFlipNode());

      expect(find.text('Watchdog'), findsOneWidget);

      // The badge is keyed off category, not concrete type — sanity-check
      // the node we used really is a trigger so the gate is meaningful.
      final node =
          container.read(currentSequenceProvider)!.nodes.values.firstWhere(
                (n) => n is MeridianFlipNode,
              );
      expect(node.category, NodeCategory.trigger);
    },
  );

  testWidgets(
    'instruction-category node (ExposureNode) does not show the Watchdog badge',
    (tester) async {
      final container = ProviderContainer(overrides: [
        inMemoryDatabaseOverride(),
        // The ledger ETA clock is a real periodic stream; in the
        // fake-async zone its timer outlives every pump and fails teardown.
        ledgerClockProvider
            .overrideWith((ref) => const Stream<DateTime>.empty()),
      ]);
      addTearDown(container.dispose);

      await _pumpTreeWithNode(tester, container, ExposureNode());

      expect(find.text('Watchdog'), findsNothing);

      final node =
          container.read(currentSequenceProvider)!.nodes.values.firstWhere(
                (n) => n is ExposureNode,
              );
      expect(node.category, NodeCategory.instruction);
    },
  );
}
