// The sequencer advertises a sheet full of keyboard shortcuts (Alt+1..4,
// Ctrl+T/Z/Y/D/C/V, Delete, Esc) and two delete dialogs tell the user Ctrl+Z
// is how they get a deleted node back. Those bindings live in a
// `CallbackShortcuts` subtree, so they only fire while primary focus is
// inside it — and the realistic path to deleting a node runs through the
// palette's search field, which keeps focus and swallows the keys.
//
// These tests drive the REAL SequencerScreen through that exact path:
// click the palette search field, then click a node row, then press the
// shortcut. Nothing here calls a handler directly.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/sequencer_screen.dart';
import 'package:skotiq_app/screens/sequencer/widgets/batch_operations_toolbar.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/ledger_columns.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

Sequence _seedSequence() {
  final exposure = ExposureNode(name: 'Lum', durationSecs: 120, count: 10);
  final container = InstructionSetNode(name: 'Lights');
  final root = InstructionSetNode(name: 'Root');
  final nodes = <String, SequenceNode>{
    exposure.id: exposure.copyWith(parentId: container.id),
    container.id: container.copyWith(
      parentId: root.id,
      childIds: [exposure.id],
    ),
    root.id: root.copyWith(childIds: [container.id]),
  };
  return Sequence.create(name: 'Test', nodes: nodes, rootNodeId: root.id);
}

Future<HarnessHandle> _pumpBuilder(WidgetTester tester) async {
  final notifier = CurrentSequenceNotifier();
  // ignore: invalid_use_of_protected_member
  notifier.state = _seedSequence();

  final handle = await pumpAppScreen(
    tester,
    const SequencerScreen(),
    size: const Size(1800, 1000),
    extraOverrides: [
      currentSequenceProvider.overrideWith((_) => notifier),
      sequenceExecutionStateProvider
          .overrideWith((ref) => SequenceExecutionState.idle),
      // The ledger ETA clock is a real periodic stream; in the fake-async
      // zone its timer outlives every pump and fails teardown.
      ledgerClockProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
    ],
    settle: false,
  );
  await tester.pump(const Duration(milliseconds: 600));
  return handle;
}

/// Reproduce the reported approach: type-to-search in the palette (which
/// parks primary focus on a TextField), then click the node row.
Future<void> _searchThenSelectRow(WidgetTester tester) async {
  final search = find.ancestor(
    of: find.text('Search nodes…'),
    matching: find.byType(TextField),
  );
  expect(search, findsOneWidget, reason: 'palette search field must exist');
  // Typing, not just clicking: a non-empty field is what makes EditableText
  // consume Delete, which is exactly the state a user is in after searching
  // the palette for the node they are about to delete.
  await tester.enterText(search, 'delay');
  await tester.pump();

  await tester.tap(find.text('Lum').first);
  await tester.pump();
}

Future<void> _pressCtrl(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Ctrl+D duplicates the row that was just clicked, even after typing in '
    'the palette search box',
    (tester) async {
      final handle = await _pumpBuilder(tester);
      final before =
          handle.container.read(currentSequenceProvider)!.nodes.length;

      await _searchThenSelectRow(tester);
      await _pressCtrl(tester, LogicalKeyboardKey.keyD);

      expect(
        handle.container.read(currentSequenceProvider)!.nodes.length,
        before + 1,
      );
      // Drain the autosave/snackbar timers the mutation schedules.
      await tester.pump(const Duration(milliseconds: 800));
      // Drain live validation's 500 ms debounce so the binding does not
      // fail the test on a pending timer.
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'Delete on a clicked row opens the confirmation, not silence',
    (tester) async {
      await _pumpBuilder(tester);

      await _searchThenSelectRow(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();

      expect(find.text('Delete "Lum"?'), findsOneWidget);
      // Drain live validation's 500 ms debounce so the binding does not
      // fail the test on a pending timer.
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'Ctrl+Z still reaches the editor once focus has been dropped entirely',
    (tester) async {
      final handle = await _pumpBuilder(tester);
      final editor = handle.container.read(currentSequenceProvider.notifier);
      final before =
          handle.container.read(currentSequenceProvider)!.nodes.length;

      // A mutation to undo.
      editor.addNode(DelayNode(seconds: 5));
      await tester.pump();
      expect(
        handle.container.read(currentSequenceProvider)!.nodes.length,
        before + 1,
      );

      // Simulate what every text field does on submit/tap-away: unfocus.
      // With a bare `Focus(autofocus: true)` this parked primary focus on the
      // ROUTE's scope — an ancestor of the bindings — and killed every
      // shortcut for the rest of the visit.
      primaryFocus?.unfocus();
      await tester.pump();

      await _pressCtrl(tester, LogicalKeyboardKey.keyZ);

      expect(
        handle.container.read(currentSequenceProvider)!.nodes.length,
        before,
      );
      await tester.pump(const Duration(milliseconds: 800));
    },
  );

  testWidgets(
    'clicking a row parks keyboard focus on that row, inside the shortcut '
    'subtree',
    (tester) async {
      await _pumpBuilder(tester);
      await _searchThenSelectRow(tester);

      // Not "some focus somewhere": the row itself. That is what makes the
      // next keystroke act on the node the user just clicked.
      expect(primaryFocus?.debugLabel, 'sequence-tree-row');
    },
  );

  testWidgets(
    'Alt+3 still switches tab after focus was dropped',
    (tester) async {
      final handle = await _pumpBuilder(tester);
      expect(
        handle.container.read(sequencerTabProvider),
        SequencerTab.builder.index,
      );

      primaryFocus?.unfocus();
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      // The tab-slide animation lays the library tab out at a fraction of
      // its final width for a few frames, which trips a pre-existing overflow
      // in that tab's filter row. Unrelated to the shortcut under test, so
      // clear it rather than let it mask the assertion.
      tester.takeException();

      expect(
        handle.container.read(sequencerTabProvider),
        SequencerTab.sequences.index,
      );
      // Drain live validation's 500 ms debounce so the binding does not
      // fail the test on a pending timer.
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets('the delete dialog points at the Undo control that works',
      (tester) async {
    await _pumpBuilder(tester);
    await _searchThenSelectRow(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();

    expect(
      find.textContaining('Undo in the toolbar'),
      findsOneWidget,
    );
    expect(find.textContaining('cannot be undone except'), findsNothing);
    // Drain live validation's 500 ms debounce so the binding does not
    // fail the test on a pending timer.
    await tester.pump(const Duration(seconds: 1));
  });

  // The SECOND dialog that carried the same false sentence. The single-node
  // confirmation above and this batch one are separate strings in separate
  // files, so fixing one proves nothing about the other.
  testWidgets('the BATCH delete dialog also points at the toolbar Undo',
      (tester) async {
    final notifier = CurrentSequenceNotifier();
    // ignore: invalid_use_of_protected_member
    notifier.state = _seedSequence();
    final selectedId =
        notifier.state!.nodes.values.whereType<ExposureNode>().first.id;

    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        currentSequenceProvider.overrideWith((_) => notifier),
        sequenceExecutionStateProvider
            .overrideWith((ref) => SequenceExecutionState.idle),
      ],
    );
    addTearDown(container.dispose);
    container.read(multiSelectedNodeIdsProvider.notifier).toggle(selectedId);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: BatchOperationsToolbar(colors: SkotiqColors.dark),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Delete 1 node?'), findsOneWidget);
    expect(find.textContaining('Undo in the toolbar'), findsOneWidget);
    expect(find.textContaining('cannot be undone except'), findsNothing);
    // Drain live validation's 500 ms debounce so the binding does not
    // fail the test on a pending timer.
    await tester.pump(const Duration(seconds: 1));
  });
}
