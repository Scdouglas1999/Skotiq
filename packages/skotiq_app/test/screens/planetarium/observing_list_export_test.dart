import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/planetarium/widgets/lists_tab.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  final now = DateTime.utc(2026, 7, 13);
  final list = ObservingList(
    id: 4,
    name: 'Winter targets',
    sortOrder: 0,
    createdAt: now,
    updatedAt: now,
  );
  final item = ObservingListItem(
    id: 8,
    listId: 4,
    objectName: 'Orion Nebula',
    catalogId: 'M"42',
    ra: 5.588,
    dec: -5.391,
    sortOrder: 0,
    addedAt: now,
  );

  Future<void> pumpList(
    WidgetTester tester,
    NetworkBackend backend, {
    List<ObservingListItem>? items,
    bool phone = false,
    bool showSelector = false,
  }) async {
    if (phone) {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(430, 932);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });
    }
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
          observingListsProvider.overrideWith(
            (ref) => Stream.value([list]),
          ),
          observingListItemsProvider.overrideWith(
            (ref, listId) => Stream.value(items ?? [item]),
          ),
          activeObservingListIdProvider.overrideWith(
            (ref) => showSelector ? null : list.id,
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: SizedBox(
              width: double.infinity,
              height: 700,
              child: ListsTab(colors: SkotiqColors.dark),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('remote export creates the sequence and nodes on the host',
      (tester) async {
    final backend = _MockNetworkBackend();
    when(() => backend.createSequence(any())).thenAnswer((_) async => 73);
    when(
      () => backend.createSequenceNode(any(), any()),
    ).thenAnswer((_) async {});

    await pumpList(tester, backend);
    await tester.tap(find.byTooltip('Export to Sequence'));
    await tester.pumpAndSettle();

    final sequenceRequest = verify(
      () => backend.createSequence(captureAny()),
    ).captured.single as Map<String, dynamic>;
    expect(sequenceRequest['name'], 'Winter targets');

    final nodeRequest = verify(
      () => backend.createSequenceNode(73, captureAny()),
    ).captured.single as Map<String, dynamic>;
    expect(nodeRequest['name'], 'Orion Nebula');
    expect(
      jsonDecode(nodeRequest['properties'] as String)['catalogId'],
      'M"42',
      reason: 'Catalog IDs must be JSON-escaped, not string-interpolated.',
    );
    expect(find.textContaining('Created sequence'), findsOneWidget);
  });

  testWidgets('a failed node write removes the partial remote sequence',
      (tester) async {
    final backend = _MockNetworkBackend();
    when(() => backend.createSequence(any())).thenAnswer((_) async => 91);
    when(
      () => backend.createSequenceNode(any(), any()),
    ).thenThrow(StateError('host write failed'));
    when(() => backend.deleteSequence(91)).thenAnswer((_) async {});

    await pumpList(tester, backend);
    await tester.tap(find.byTooltip('Export to Sequence'));
    await tester.pumpAndSettle();

    verify(() => backend.deleteSequence(91)).called(1);
    expect(find.textContaining('Could not create sequence'), findsOneWidget);
  });

  testWidgets('phone users can remove an item without mouse hover',
      (tester) async {
    final backend = _MockNetworkBackend();
    when(() => backend.removeObservingListItem(item.id))
        .thenAnswer((_) async {});
    when(() => backend.getListedCatalogIds()).thenAnswer((_) async => {});
    when(
      () => backend.getListedCatalogIds(listId: any(named: 'listId')),
    ).thenAnswer((_) async => {});

    await pumpList(tester, backend, phone: true);

    expect(find.byTooltip('Remove from list'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove from list'));
    await tester.pump();

    verify(() => backend.removeObservingListItem(item.id)).called(1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed list creation stays open and explains the failure',
      (tester) async {
    final backend = _MockNetworkBackend();
    when(
      () => backend.createObservingList(
        name: any(named: 'name'),
        description: any(named: 'description'),
      ),
    ).thenThrow(StateError('host rejected list'));

    await pumpList(tester, backend, showSelector: true);
    await tester.tap(find.byTooltip('Create new list'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'List Name'),
      'Launch targets',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(find.text('Create Observing List'), findsOneWidget);
    expect(find.textContaining('host rejected list'), findsOneWidget);
  });
}
