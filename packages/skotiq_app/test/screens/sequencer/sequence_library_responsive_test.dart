import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/tabs/sequence_library_tab.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

SequenceSummary _summary({
  required int id,
  required String name,
  required DateTime createdAt,
  required DateTime modifiedAt,
}) {
  return SequenceSummary(
    id: id,
    name: name,
    nodeCount: 4,
    targetCount: 1,
    exposureCount: 2,
    totalIntegrationSecs: 3600,
    primaryTargetName: 'M42',
    lastRunAt: null,
    runCount: 0,
    tags: const ['winter'],
    isFavorite: false,
    createdAt: createdAt,
    modifiedAt: modifiedAt,
  );
}

Future<void> _pumpLibrary(
  WidgetTester tester,
  List<SequenceSummary> summaries,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(430, 932);
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        savedSequenceSummariesProvider.overrideWith((ref) async => summaries),
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
      'phone layout exposes every saved-sequence action without overflow',
      (tester) async {
    final now = DateTime(2026, 7, 13, 20);
    await _pumpLibrary(
      tester,
      [
        _summary(
          id: 1,
          name: 'A deliberately long Orion imaging sequence name',
          createdAt: now.subtract(const Duration(days: 30)),
          modifiedAt: now,
        ),
      ],
    );

    expect(tester.takeException(), isNull);
    for (final tooltip in [
      'Preview',
      'View run history',
      'Version history',
      'Edit tags',
      'Load',
      'Duplicate',
      'Export',
      'Delete',
    ]) {
      expect(find.byTooltip(tooltip), findsOneWidget);
    }
  });

  testWidgets('Date Created is selectable and sorts by the real creation time',
      (tester) async {
    final now = DateTime(2026, 7, 13, 20);
    await _pumpLibrary(
      tester,
      [
        _summary(
          id: 1,
          name: 'Recently modified',
          createdAt: now.subtract(const Duration(days: 100)),
          modifiedAt: now,
        ),
        _summary(
          id: 2,
          name: 'Recently created',
          createdAt: now.subtract(const Duration(days: 1)),
          modifiedAt: now.subtract(const Duration(days: 20)),
        ),
      ],
    );

    expect(
      tester.getTopLeft(find.text('Recently modified')).dy,
      lessThan(tester.getTopLeft(find.text('Recently created')).dy),
    );

    await tester.tap(find.text('Last Modified'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Date Created').last);
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.text('Recently created')).dy,
      lessThan(tester.getTopLeft(find.text('Recently modified')).dy),
    );
    expect(tester.takeException(), isNull);
  });
}
