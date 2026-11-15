// Tags typed one after another in the tag editor, each ended with Enter, are
// all kept.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/sequencer/tabs/sequence_library_tab.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _MockSequenceRepository extends Mock implements SequenceRepository {}

void main() {
  testWidgets('Enter adds a tag and leaves the field ready for the next one',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    final now = DateTime(2026, 7, 13, 20);
    final repository = _MockSequenceRepository();
    when(() => repository.setTags(any(), any())).thenAnswer((_) async {});

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          sequenceRepositoryProvider.overrideWith((ref) => repository),
          savedSequenceSummariesProvider.overrideWith(
            (ref) async => [
              SequenceSummary(
                id: 1,
                name: 'Orion run',
                nodeCount: 5,
                targetCount: 1,
                exposureCount: 2,
                totalIntegrationSecs: 600,
                primaryTargetName: 'M42',
                lastRunAt: null,
                runCount: 0,
                tags: const [],
                isFavorite: false,
                createdAt: now,
                modifiedAt: now,
              ),
            ],
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: SequenceLibraryTab()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('More actions for Orion run'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit tags'));
    await tester.pumpAndSettle();

    // The keyboard: type, Enter, type, Enter, without touching the field.
    tester.testTextInput.enterText('winter');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    tester.testTextInput.enterText('lrgb');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(find.text('winter'), findsOneWidget);
    expect(find.text('lrgb'), findsOneWidget);

    await tester.tap(find.widgetWithText(SkotiqButton, 'Save'));
    await tester.pumpAndSettle();
    verify(() => repository.setTags(1, ['winter', 'lrgb'])).called(1);
  });
}
