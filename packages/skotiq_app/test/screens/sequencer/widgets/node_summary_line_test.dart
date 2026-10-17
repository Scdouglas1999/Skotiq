// Widget tests for [NodeSummaryLine] — the row-level renderer that turns
// the pure [nodeSummary] fragment list into design-system chips + muted
// text and wires editable chips to the anchored inline editors.
//
// What we pin here (the renderer's contract, not C1's classification which is
// unit-tested separately):
//   * Editable fragments show a chevron affordance and tap-edit ONLY while the
//     sequence is editable; while running they degrade to a plain, non-tappable
//     chip with no chevron (no fake affordance).
//   * Tapping an editable chip opens the inline editor popup (routing through
//     C3 → updateNode).
//   * Editable chips expose button semantics with the property label + value.
//
// (The `fragments.isEmpty → SizedBox.shrink()` guard is not exercised here:
// every concrete [SequenceNode] subtype produces at least one fragment, so the
// branch is unreachable through real nodes and would require a fake node the
// classifier cannot represent.)

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_summary_line.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

Future<void> _pump(
  WidgetTester tester,
  SequenceNode node, {
  required SequenceExecutionState executionState,
  List<Override> extraOverrides = const [],
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(900, 700);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final container = ProviderContainer(overrides: [
    inMemoryDatabaseOverride(),
    sequenceExecutionStateProvider.overrideWith((ref) => executionState),
    ...extraOverrides,
  ]);
  addTearDown(container.dispose);

  // Seed a real sequence + node so the inline editor's updateNode path has a
  // live target (the popup commits through currentSequenceProvider). Seeding
  // mutates the sequence and is itself gated on the editable state, so it is
  // only possible — and only needed (the running case never opens an editor) —
  // when the sequence is editable.
  if (executionState == SequenceExecutionState.idle) {
    container
        .read(currentSequenceProvider.notifier)
        .createSequence(name: 'test');
    container.read(currentSequenceProvider.notifier).addNode(node);
  }

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: NodeSummaryLine(
              node: node,
              colors: SkotiqColors.dark,
              isMobile: false,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'editable chip is tappable with a chevron affordance when idle',
    (tester) async {
      await _pump(
        tester,
        ExposureNode(count: 12, durationSecs: 180),
        executionState: SequenceExecutionState.idle,
      );

      // The count chip is editable → chevron affordance present.
      expect(find.byIcon(LucideIcons.chevronDown), findsWidgets);

      // The chip count value renders on the line.
      expect(find.text('12'), findsOneWidget);

      // Editable chips expose button semantics with their label.
      final semantics = tester.getSemantics(
        find
            .ancestor(
              of: find.text('12'),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(semantics.label, contains('exposure count'));
    },
  );

  testWidgets(
    'tapping an editable chip opens the inline editor popup when idle',
    (tester) async {
      await _pump(
        tester,
        ExposureNode(count: 12, durationSecs: 180),
        executionState: SequenceExecutionState.idle,
      );

      // Tap the exposure-count chip.
      await tester.tap(find.text('12'));
      await tester.pumpAndSettle();

      // The C3 inline editor titles its count section "Exposure count".
      expect(find.text('Exposure count'), findsOneWidget);
    },
  );

  testWidgets(
    'editable chip degrades to a non-tappable, chevron-less chip while running',
    (tester) async {
      await _pump(
        tester,
        ExposureNode(count: 12, durationSecs: 180),
        executionState: SequenceExecutionState.running,
      );

      // No chevron affordance while running — no fake edit hint.
      expect(find.byIcon(LucideIcons.chevronDown), findsNothing);
      // No tappable InkWell wrapping the chip.
      expect(find.byType(InkWell), findsNothing);

      // The value still renders (read-only).
      expect(find.text('12'), findsOneWidget);

      // Tapping does nothing — no popup opens.
      await tester.tap(find.text('12'));
      await tester.pumpAndSettle();
      expect(find.text('Exposure count'), findsNothing);
    },
  );

  // The executor drops AutofocusNode.method whenever `useSettingsDefaults` is
  // on (serialization passes `nodeOverrides: null`), so the row must name the
  // AppSettings method that will really run and must not offer a chip that
  // edits the discarded field.
  testWidgets(
    'autofocus row in defaults mode names the global method, no editable chip',
    (tester) async {
      await _pump(
        tester,
        AutofocusNode(method: AutofocusMethod.quadratic),
        executionState: SequenceExecutionState.idle,
        extraOverrides: [
          autofocusSettingsProvider.overrideWithValue(
            const AutofocusSettings(method: 'Star HFR'),
          ),
        ],
      );

      expect(find.text('Star HFR (global)'), findsOneWidget);
      expect(find.text('quadratic'), findsNothing);
      expect(find.byIcon(LucideIcons.chevronDown), findsNothing);
      expect(find.byType(InkWell), findsNothing);
    },
  );

  testWidgets(
    'autofocus row in override mode still offers the editable method chip',
    (tester) async {
      await _pump(
        tester,
        AutofocusNode(
          method: AutofocusMethod.quadratic,
          useSettingsDefaults: false,
        ),
        executionState: SequenceExecutionState.idle,
        extraOverrides: [
          autofocusSettingsProvider.overrideWithValue(
            const AutofocusSettings(method: 'Star HFR'),
          ),
        ],
      );

      expect(find.text('quadratic'), findsOneWidget);
      expect(find.text('Star HFR (global)'), findsNothing);
      expect(find.byIcon(LucideIcons.chevronDown), findsWidgets);
    },
  );

  testWidgets('static-only node renders muted text, no chips or chevron',
      (tester) async {
    await _pump(
      tester,
      ParkNode(),
      executionState: SequenceExecutionState.idle,
    );

    expect(find.text('park mount'), findsOneWidget);
    expect(find.byIcon(LucideIcons.chevronDown), findsNothing);
    expect(find.byType(InkWell), findsNothing);
  });
}
