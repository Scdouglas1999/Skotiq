import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/sequencer/tabs/templates_tab.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _MockSequenceRepository extends Mock implements SequenceRepository {}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

void main() {
  setUpAll(() {
    registerFallbackValue(Sequence.create(name: 'fallback'));
  });

  test('saving a custom template does not replace the built-in catalog',
      () async {
    final repository = _MockSequenceRepository();
    final custom = Sequence.create(
      databaseId: 7,
      name: 'My Galaxy Template',
      isTemplate: true,
    );
    when(() => repository.loadAllTemplates()).thenAnswer((_) async => [custom]);

    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        sequenceRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);

    final templates = await container.read(sequenceTemplatesProvider.future);

    expect(templates.first, custom);
    expect(templates.where((template) => template.name == 'First Light'),
        hasLength(1));
    expect(templates.length, greaterThan(1));
  });

  testWidgets('Edit opens a custom template with its backing row intact',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 3000);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final repository = _MockSequenceRepository();
    final custom = Sequence.create(
      databaseId: 7,
      name: 'My Galaxy Template',
      isTemplate: true,
    );
    when(() => repository.loadAllTemplates()).thenAnswer((_) async => [custom]);
    when(() => repository.saveSequence(any(), isTemplate: true))
        .thenAnswer((_) async => 7);
    final editor = CurrentSequenceNotifier();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          sequenceRepositoryProvider.overrideWithValue(repository),
          currentSequenceProvider.overrideWith((ref) => editor),
          allSnippetsProvider.overrideWithValue(const []),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: TemplatesTab()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final name = find.text('My Galaxy Template');
    expect(name, findsOneWidget);

    await tester.tap(find.byTooltip('Edit template'));
    await tester.pump();

    expect(editor.state?.databaseId, 7);
    expect(editor.state?.isTemplate, isTrue);
    expect(editor.state?.name, 'My Galaxy Template');

    editor.setDescription('Updated recipe');
    await tester.pump();
    expect(editor.isDirty, isTrue);
    await tester.tap(find.widgetWithText(SkotiqButton, 'Update'));
    await tester.pump();

    expect(find.text('Update Template'), findsWidgets);
    final updateTemplateButton =
        find.widgetWithText(SkotiqButton, 'Update Template').last;
    await tester.ensureVisible(updateTemplateButton);
    await tester.pump();
    await tester.tap(updateTemplateButton);
    await tester.pump();
    await tester.pump();

    verify(() => repository.saveSequence(any(), isTemplate: true)).called(1);
    expect(editor.state?.databaseId, 7);
    expect(editor.state?.description, 'Updated recipe');
    expect(editor.isDirty, isFalse);
  });

  testWidgets('Use does not silently discard an unsaved sequence',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 3000);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final repository = _MockSequenceRepository();
    final custom = Sequence.create(
      databaseId: 7,
      name: 'My Galaxy Template',
      isTemplate: true,
    );
    when(() => repository.loadAllTemplates()).thenAnswer((_) async => [custom]);
    final editor = CurrentSequenceNotifier();
    final current = Sequence.create(name: 'Unsaved work');
    editor.loadSequence(current);
    editor.setDescription('Do not lose this');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          sequenceRepositoryProvider.overrideWithValue(repository),
          currentSequenceProvider.overrideWith((ref) => editor),
          allSnippetsProvider.overrideWithValue(const []),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: TemplatesTab()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('My Galaxy Template'));
    await tester.pump();

    expect(find.text('Discard unsaved changes?'), findsOneWidget);
    await tester.tap(find.widgetWithText(SkotiqButton, 'Cancel'));
    await tester.pump();
    expect(editor.state?.id, current.id);
    expect(editor.state?.description, 'Do not lose this');
  });

  testWidgets('Starter does not silently discard an unsaved sequence',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 932);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final repository = _MockSequenceRepository();
    when(() => repository.loadAllTemplates()).thenAnswer((_) async => []);
    final starter = SampleSequence(
      id: 'starter',
      displayName: 'Safe Starter',
      description: 'A starter sequence',
      iconName: 'camera',
      skillLevel: SampleSequenceSkillLevel.beginner,
      expectedTotalTime: '10 min',
      assetPath: 'unused',
      template: Sequence.create(name: 'Safe Starter'),
    );
    final editor = CurrentSequenceNotifier();
    final current = Sequence.create(name: 'Unsaved work');
    editor.loadSequence(current);
    editor.setDescription('Do not lose this');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          sequenceRepositoryProvider.overrideWithValue(repository),
          currentSequenceProvider.overrideWith((ref) => editor),
          allSnippetsProvider.overrideWithValue(const []),
          sampleSequencesProvider.overrideWith((ref) async => [starter]),
          // The starter is matched against the wheel's filter names; no rig
          // in this test.
          filterNamesToMatchProvider.overrideWithValue(const []),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: TemplatesTab()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(
      find.widgetWithText(SkotiqButton, 'Use this starter'),
    );
    await tester.pump();

    expect(find.text('Discard unsaved changes?'), findsOneWidget);
    await tester.tap(find.widgetWithText(SkotiqButton, 'Cancel'));
    await tester.pump();
    expect(editor.state?.id, current.id);
    expect(editor.state?.description, 'Do not lose this');
  });

  testWidgets(
      'a template delete the old host finishes after a switch reports nothing',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 3000);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final repository = _MockSequenceRepository();
    final custom = Sequence.create(
      databaseId: 7,
      name: 'My Galaxy Template',
      isTemplate: true,
    );
    when(() => repository.loadAllTemplates()).thenAnswer((_) async => [custom]);
    final deletion = Completer<void>();
    when(() => repository.deleteSequence(7))
        .thenAnswer((_) => deletion.future);
    final hostA = DisconnectedBackend();
    final hostB = DisconnectedBackend();
    addTearDown(hostA.dispose);
    addTearDown(hostB.dispose);
    late _SwappableBackendNotifier notifier;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => notifier = _SwappableBackendNotifier(ref, hostA),
          ),
          sequenceRepositoryProvider.overrideWithValue(repository),
          allSnippetsProvider.overrideWithValue(const []),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: TemplatesTab()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('Delete'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Delete Template'), findsOneWidget);
    await tester.tap(find.widgetWithText(SkotiqButton, 'Delete'));
    await tester.pump();
    verify(() => repository.deleteSequence(7)).called(1);
    clearInteractions(repository);

    // The old host answers in the same turn as the switch, before the closed
    // dialog has left the tree.
    notifier.switchTo(hostB);
    deletion.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Delete Template'), findsNothing);
    expect(
      find.text('The connected host changed. Template deletion canceled.'),
      findsOneWidget,
    );
    verifyNever(() => repository.loadAllTemplates());
    ScaffoldMessenger.of(tester.element(find.byType(TemplatesTab)))
        .removeCurrentSnackBar();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Deleted "My Galaxy Template"'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
