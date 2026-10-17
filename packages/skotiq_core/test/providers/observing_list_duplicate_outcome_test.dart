// "Already in this list" is an outcome, not an error.
//
// `ObservingListNotifier.addItem` funnelled every exception into
// `errorMessage: 'Failed to add item: $e'`, so the planner dialog showed the raw
// `Bad state: …` text in red for a harmless duplicate. The notifier now reports
// the duplicate as a neutral statusMessage with NO errorMessage, which is how
// the three call sites tell a benign no-op apart from a real write failure — on
// both authorities: the local DAO throws
// [ObservingListDuplicateItemException], the host answers the same POST with
// HTTP 409.

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase database;

  setUp(() {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await database.close();
  });

  ProviderContainer buildContainer({SkotiqBackend? backend}) {
    return ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        if (backend != null)
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
      ],
    );
  }

  test('local duplicate reports a neutral status, not an error', () async {
    final container = buildContainer();
    addTearDown(container.dispose);
    final dao = container.read(observingListsDaoProvider);
    final listId = await dao.createList(name: 'Summer Galaxies');
    final notifier = container.read(observingListNotifierProvider.notifier);

    final first = await notifier.addItem(
      listId: listId,
      objectName: 'NGC6015',
      catalogId: 'NGC6015',
      ra: 15.9,
      dec: 62.3,
    );
    expect(first, isNotNull);

    final second = await notifier.addItem(
      listId: listId,
      objectName: 'NGC6015',
      catalogId: 'NGC6015',
      ra: 15.9,
      dec: 62.3,
    );

    final state = container.read(observingListNotifierProvider);
    expect(second, isNull, reason: 'no second row was written');
    expect(
      state.errorMessage,
      isNull,
      reason: 'a duplicate is not a failure and must not be shown in red',
    );
    expect(state.statusMessage, 'NGC6015 is already in this list');
    expect(state.statusMessage, isNot(contains('Bad state')));
    expect(state.statusMessage, isNot(contains('Failed')));
    // The list is untouched: exactly one copy.
    expect(await dao.getItemsForList(listId), hasLength(1));
  });

  test('a real write failure is still reported as an error', () async {
    final backend = _MockNetworkBackend();
    when(
      () => backend.addObservingListItem(
        listId: any(named: 'listId'),
        objectName: any(named: 'objectName'),
        catalogId: any(named: 'catalogId'),
        objectType: any(named: 'objectType'),
        ra: any(named: 'ra'),
        dec: any(named: 'dec'),
        magnitude: any(named: 'magnitude'),
        sizeArcmin: any(named: 'sizeArcmin'),
        notes: any(named: 'notes'),
      ),
    ).thenThrow(Exception('host disk full'));

    final container = buildContainer(backend: backend);
    addTearDown(container.dispose);
    final notifier = container.read(observingListNotifierProvider.notifier);

    final id = await notifier.addItem(
      listId: 5,
      objectName: 'NGC6015',
      catalogId: 'NGC6015',
      ra: 15.9,
      dec: 62.3,
    );

    final state = container.read(observingListNotifierProvider);
    expect(id, isNull);
    expect(state.errorMessage, contains('Failed to add item'));
    expect(state.statusMessage, isNull);
  });

  test('a host 409 is recognised as the same duplicate outcome', () async {
    final backend = _MockNetworkBackend();
    when(
      () => backend.addObservingListItem(
        listId: any(named: 'listId'),
        objectName: any(named: 'objectName'),
        catalogId: any(named: 'catalogId'),
        objectType: any(named: 'objectType'),
        ra: any(named: 'ra'),
        dec: any(named: 'dec'),
        magnitude: any(named: 'magnitude'),
        sizeArcmin: any(named: 'sizeArcmin'),
        notes: any(named: 'notes'),
      ),
    ).thenThrow(
      const ServerError(
        code: 'conflict',
        message: 'NGC6015 is already in this list',
        httpStatus: 409,
      ),
    );

    final container = buildContainer(backend: backend);
    addTearDown(container.dispose);
    final notifier = container.read(observingListNotifierProvider.notifier);

    final id = await notifier.addItem(
      listId: 5,
      objectName: 'NGC6015',
      catalogId: 'NGC6015',
      ra: 15.9,
      dec: 62.3,
    );

    final state = container.read(observingListNotifierProvider);
    expect(id, isNull);
    expect(state.errorMessage, isNull);
    expect(state.statusMessage, 'NGC6015 is already in this list');
  });
}
