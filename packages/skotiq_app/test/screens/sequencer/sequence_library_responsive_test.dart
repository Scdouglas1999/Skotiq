import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/tabs/sequence_library_tab.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
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
  List<SequenceSummary> summaries, {
  Size size = const Size(430, 932),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
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

Future<void> _openMenu(WidgetTester tester, String name) async {
  await tester.tap(find.byTooltip('More actions for $name'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'phone layout keeps the star and the menu, and the menu holds every '
      'other action', (tester) async {
    final now = DateTime(2026, 7, 13, 20);
    const name = 'A deliberately long Orion imaging sequence name';
    await _pumpLibrary(
      tester,
      [
        _summary(
          id: 1,
          name: name,
          createdAt: now.subtract(const Duration(days: 30)),
          modifiedAt: now,
        ),
      ],
    );

    expect(tester.takeException(), isNull);
    // No last-run column on a phone: the facts line says it.
    expect(find.textContaining('never run'), findsOneWidget);
    expect(find.text('LAST RUN'), findsNothing);
    expect(find.byTooltip('Add to favorites'), findsOneWidget);
    await _openMenu(tester, name);
    for (final action in [
      'Preview',
      'View run history',
      'Version history',
      'Edit tags',
      'Duplicate',
      'Export',
      'Delete',
    ]) {
      expect(find.text(action), findsOneWidget, reason: action);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('a row shows its facts on one line and its last run',
      (tester) async {
    final now = DateTime.now();
    await _pumpLibrary(
      tester,
      [_summary(id: 1, name: 'Orion', createdAt: now, modifiedAt: now)],
      size: const Size(1400, 900),
    );

    // One target that the facts already name is not counted again.
    expect(find.textContaining('M42 · 1 target'), findsNothing);
    expect(find.textContaining('M42 · 2 capture steps'), findsOneWidget);
    expect(find.textContaining('winter'), findsOneWidget);
    expect(find.text('Never run'), findsOneWidget);
    expect(find.text('LAST RUN'), findsOneWidget);
    expect(find.text('1 SEQUENCE'), findsOneWidget);
  });

  testWidgets('an empty library is the empty state alone, without a toolbar',
      (tester) async {
    await _pumpLibrary(tester, const []);

    expect(find.text('No saved sequences'), findsOneWidget);
    expect(find.byType(SkotiqSearchField), findsNothing);
    expect(find.textContaining('Sort:'), findsNothing);
  });

  testWidgets('Date created is selectable and sorts by the real creation time',
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

    await tester.tap(find.text('Sort: last modified'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Date created').last);
    await tester.pumpAndSettle();

    expect(find.text('Sort: date created'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Recently created')).dy,
      lessThan(tester.getTopLeft(find.text('Recently modified')).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('tags combine: each picked tag narrows the list', (tester) async {
    final now = DateTime(2026, 7, 13, 20);
    SequenceSummary tagged(int id, String name, List<String> tags) =>
        SequenceSummary(
          id: id,
          name: name,
          nodeCount: 4,
          targetCount: 1,
          exposureCount: 2,
          totalIntegrationSecs: 3600,
          primaryTargetName: 'M42',
          lastRunAt: null,
          runCount: 0,
          tags: tags,
          isFavorite: false,
          createdAt: now,
          modifiedAt: now,
        );
    await _pumpLibrary(tester, [
      tagged(1, 'Both', ['winter', 'lrgb']),
      tagged(2, 'Winter only', ['winter']),
    ]);

    await tester.ensureVisible(find.text('Tags: any'));
    await tester.tap(find.text('Tags: any'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('winter').last);
    await tester.pumpAndSettle();
    expect(find.text('Both'), findsOneWidget);
    expect(find.text('Winter only'), findsOneWidget);

    await tester.ensureVisible(find.text('Tag: winter'));
    await tester.tap(find.text('Tag: winter'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('lrgb').last);
    await tester.pumpAndSettle();
    expect(find.text('Both'), findsOneWidget);
    expect(find.text('Winter only'), findsNothing);
    expect(find.text('1 OF 2 SEQUENCES'), findsOneWidget);
  });
}
