import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/sequencer/tabs/sequence_library_tab.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockBackend extends Mock implements SkotiqBackend {}

class _MockSequenceRepository extends Mock implements SequenceRepository {}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

SequenceSummary _summary() {
  final now = DateTime(2026, 7, 13, 20);
  return SequenceSummary(
    id: 1,
    name: 'Orion run',
    nodeCount: 1,
    targetCount: 0,
    exposureCount: 0,
    totalIntegrationSecs: 0,
    primaryTargetName: null,
    lastRunAt: null,
    runCount: 0,
    tags: const [],
    isFavorite: false,
    createdAt: now,
    modifiedAt: now,
  );
}

Future<_SwappableBackendNotifier> _pumpLibrary(
  WidgetTester tester, {
  required SkotiqBackend hostA,
  required SkotiqBackend hostB,
  required SequenceRepository repositoryA,
  required SequenceRepository repositoryB,
  required CurrentSequenceNotifier editor,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(430, 932);
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });

  late _SwappableBackendNotifier notifier;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        backendProvider.overrideWith((ref) {
          notifier = _SwappableBackendNotifier(ref, hostA);
          return notifier;
        }),
        sequenceRepositoryProvider.overrideWith((ref) {
          final backend = ref.watch(backendProvider);
          return identical(backend, hostA) ? repositoryA : repositoryB;
        }),
        savedSequenceSummariesProvider
            .overrideWith((ref) async => [_summary()]),
        currentSequenceProvider.overrideWith((ref) => editor),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: SequenceLibraryTab()),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return notifier;
}

void main() {
  testWidgets('delete confirmation cannot cross sequence repositories',
      (tester) async {
    final hostA = _MockBackend();
    final hostB = _MockBackend();
    final repositoryA = _MockSequenceRepository();
    final repositoryB = _MockSequenceRepository();
    final notifier = await _pumpLibrary(
      tester,
      hostA: hostA,
      hostB: hostB,
      repositoryA: repositoryA,
      repositoryB: repositoryB,
      editor: CurrentSequenceNotifier(),
    );

    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete Sequence'), findsOneWidget);

    notifier.switchTo(hostB);
    await tester.pumpAndSettle();

    expect(find.text('Delete Sequence'), findsNothing);
    verifyNever(() => repositoryA.deleteSequence(any()));
    verifyNever(() => repositoryB.deleteSequence(any()));
  });

  testWidgets('late load result from the old host is not opened in the editor',
      (tester) async {
    final hostA = _MockBackend();
    final hostB = _MockBackend();
    final repositoryA = _MockSequenceRepository();
    final repositoryB = _MockSequenceRepository();
    final response = Completer<Sequence?>();
    when(() => repositoryA.loadSequence(1)).thenAnswer((_) => response.future);
    final editor = CurrentSequenceNotifier();
    final notifier = await _pumpLibrary(
      tester,
      hostA: hostA,
      hostB: hostB,
      repositoryA: repositoryA,
      repositoryB: repositoryB,
      editor: editor,
    );

    await tester.tap(find.byTooltip('Load'));
    await tester.pump();
    notifier.switchTo(hostB);
    await tester.pump();
    response.complete(Sequence.create(databaseId: 1, name: 'Stale Orion'));
    await tester.pump();
    await tester.pump();

    expect(editor.state, isNull);
    verify(() => repositoryA.loadSequence(1)).called(1);
    verifyNever(() => repositoryB.loadSequence(any()));
  });
}
