// The library card must not contradict itself or the Builder toolbar.
//
// The collapsed card's chips come from a grouped roll-up query that counts
// exposure NODES, so a "10 × 60s" node is 1 — labelling that "exposures" read
// as frames. The expandable preview loads the real node tree, so it CAN quote
// frames, but its old walk only looked at ExposureNode and ignored loop
// multipliers: a target imaged by a Smart Exposure rendered "No exposures",
// and a `Capture Loop ×10` reported a tenth of its integration.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/sequencer/tabs/sequence_library_tab.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _MockSequenceRepository extends Mock implements SequenceRepository {}

SequenceSummary _summary({int exposureCount = 2, int targetCount = 1}) {
  final now = DateTime(2026, 7, 13, 20);
  return SequenceSummary(
    id: 1,
    name: 'Orion run',
    nodeCount: 5,
    targetCount: targetCount,
    exposureCount: exposureCount,
    totalIntegrationSecs: 600,
    primaryTargetName: 'M42',
    lastRunAt: null,
    runCount: 0,
    tags: const [],
    isFavorite: false,
    createdAt: now,
    modifiedAt: now,
  );
}

/// Target → Capture Loop ×10 → Light 1 × 120s, plus a Smart Exposure
/// (L, 10 × 60s) directly under the target: 10 + 10 = 20 planned frames,
/// 20m + 10m = 30m integration.
Sequence _loopedSequence() {
  final container = ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
  addTearDown(container.dispose);
  final editor = container.read(currentSequenceProvider.notifier);
  editor.createSequence(name: 'Orion run');

  final target = TargetHeaderNode(
    targetName: 'M42',
    raHours: 5.59,
    decDegrees: -5.39,
  );
  final loop = LoopNode(
    conditionType: LoopConditionType.count,
    repeatCount: 10,
  );
  final light = ExposureNode(count: 1, durationSecs: 120, filter: 'L');
  final smart = SmartExposureNode(
    plans: const [FilterPlan(filterName: 'Ha', count: 10, durationSecs: 60)],
  );

  editor.addNode(target);
  editor.addNode(loop, parentId: target.id);
  editor.addNode(light, parentId: loop.id);
  editor.addNode(smart, parentId: target.id);

  return container.read(currentSequenceProvider)!;
}

Future<void> _pumpLibrary(
  WidgetTester tester, {
  required SequenceSummary summary,
  required SequenceRepository repository,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(900, 1200);
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        inMemoryDatabaseOverride(),
        sequenceRepositoryProvider.overrideWith((ref) => repository),
        savedSequenceSummariesProvider.overrideWith((ref) async => [summary]),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: SequenceLibraryTab()),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets(
    'the node-count chip is not labelled "exposures", and counts are '
    'pluralised',
    (tester) async {
      final repository = _MockSequenceRepository();
      await _pumpLibrary(
        tester,
        summary: _summary(exposureCount: 1, targetCount: 1),
        repository: repository,
      );

      // The roll-up counts capture NODES — say so instead of claiming frames.
      expect(find.text('1 capture step'), findsOneWidget);
      expect(find.text('1 exposures'), findsNothing);
      expect(find.text('1 targets'), findsNothing);
      expect(find.text('1 target'), findsOneWidget);
    },
  );

  testWidgets(
    'preview counts frames through loops and Smart Exposure plans',
    (tester) async {
      final sequence = _loopedSequence();
      final repository = _MockSequenceRepository();
      when(() => repository.loadSequence(1)).thenAnswer((_) async => sequence);

      await _pumpLibrary(
        tester,
        summary: _summary(),
        repository: repository,
      );

      await tester.tap(find.byTooltip('Preview'));
      await tester.pump();
      await tester.pump();

      // 10 looped lights + 10 Smart Exposure subs = 20 frames / 30m.
      expect(find.text('20 frames • 30m'), findsOneWidget);
      expect(find.text('No exposures'), findsNothing);
      // Per-filter breakdown covers the Smart Exposure band too.
      expect(find.text('L: 20m'), findsOneWidget);
      expect(find.text('Ha: 10m'), findsOneWidget);
    },
  );

  testWidgets('a target with no capture at all still says so', (tester) async {
    final container =
        ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
    addTearDown(container.dispose);
    final editor = container.read(currentSequenceProvider.notifier);
    editor.createSequence(name: 'Empty');
    final target = TargetHeaderNode(
      targetName: 'M42',
      raHours: 5.59,
      decDegrees: -5.39,
    );
    editor.addNode(target);
    editor.addNode(SlewNode(), parentId: target.id);

    final repository = _MockSequenceRepository();
    when(() => repository.loadSequence(1))
        .thenAnswer((_) async => container.read(currentSequenceProvider)!);

    await _pumpLibrary(
      tester,
      summary: _summary(exposureCount: 0),
      repository: repository,
    );

    await tester.tap(find.byTooltip('Preview'));
    await tester.pump();
    await tester.pump();

    expect(find.text('no exposures'), findsOneWidget);
  });
}
