import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/settings/widgets/observing_lists_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

final _now = DateTime.utc(2026, 7, 13);
final _list = ObservingList(
  id: 4,
  name: 'Winter targets',
  description: 'Old description',
  sortOrder: 0,
  createdAt: _now,
  updatedAt: _now,
);

Future<_SwappableBackendNotifier> _pumpSettings(
  WidgetTester tester, {
  required NetworkBackend backend,
}) async {
  when(() => backend.getListedCatalogIds()).thenAnswer((_) async => {});
  late _SwappableBackendNotifier notifier;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        backendProvider.overrideWith((ref) {
          notifier = _SwappableBackendNotifier(ref, backend);
          return notifier;
        }),
        observingListsProvider.overrideWith((ref) => Stream.value([_list])),
        observingListItemsProvider.overrideWith(
          (ref, listId) => const Stream.empty(),
        ),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              ref.watch(backendProvider);
              return const ObservingListsSettings();
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return notifier;
}

void main() {
  testWidgets('editing can explicitly clear a persisted description',
      (tester) async {
    final backend = _MockNetworkBackend();
    when(
      () => backend.updateObservingList(
        id: _list.id,
        name: _list.name,
        description: null,
        setDescription: true,
      ),
    ).thenAnswer((_) async {});

    await _pumpSettings(tester, backend: backend);
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2));
    await tester.enterText(fields.at(1), '');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    verify(
      () => backend.updateObservingList(
        id: _list.id,
        name: _list.name,
        description: null,
        setDescription: true,
      ),
    ).called(1);
    expect(find.text('Edit Observing List'), findsNothing);
  });

  testWidgets('failed deletion remains open and reports the host error',
      (tester) async {
    final backend = _MockNetworkBackend();
    when(() => backend.deleteObservingList(_list.id))
        .thenThrow(StateError('host refused delete'));

    await _pumpSettings(tester, backend: backend);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SkotiqButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Delete List?'), findsOneWidget);
    expect(find.textContaining('host refused delete'), findsOneWidget);
  });

  testWidgets('an edit dialog closes before a backend switch can retarget it',
      (tester) async {
    final hostA = _MockNetworkBackend();
    final hostB = _MockNetworkBackend();
    final notifier = await _pumpSettings(tester, backend: hostA);
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(find.text('Edit Observing List'), findsOneWidget);

    notifier.switchTo(hostB);
    await tester.pumpAndSettle();

    expect(find.text('Edit Observing List'), findsNothing);
    verifyNever(
      () => hostA.updateObservingList(
        id: any(named: 'id'),
        name: any(named: 'name'),
        description: any(named: 'description'),
        setDescription: any(named: 'setDescription'),
      ),
    );
    verifyNever(
      () => hostB.updateObservingList(
        id: any(named: 'id'),
        name: any(named: 'name'),
        description: any(named: 'description'),
        setDescription: any(named: 'setDescription'),
      ),
    );
  });
}
