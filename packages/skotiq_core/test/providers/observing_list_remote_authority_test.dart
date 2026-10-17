import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase database;
  late _MockNetworkBackend hostA;
  late _MockNetworkBackend hostB;
  late _SwappableBackendNotifier backendNotifier;
  late ProviderContainer container;

  setUp(() {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    hostA = _MockNetworkBackend();
    hostB = _MockNetworkBackend();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        backendProvider.overrideWith((ref) {
          backendNotifier = _SwappableBackendNotifier(ref, hostA);
          return backendNotifier;
        }),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await database.close();
  });

  test(
    'host switch clears active list and discards late delete completion',
    () async {
      final deleteGate = Completer<void>();
      when(
        () => hostA.deleteObservingList(42),
      ).thenAnswer((_) => deleteGate.future);
      final notifier = container.read(observingListNotifierProvider.notifier);
      container.read(activeObservingListIdProvider.notifier).state = 42;

      final deletion = notifier.deleteList(42);
      expect(container.read(observingListNotifierProvider).isSaving, isTrue);

      backendNotifier.switchTo(hostB);
      expect(container.read(activeObservingListIdProvider), isNull);
      expect(container.read(observingListNotifierProvider).isSaving, isFalse);

      deleteGate.complete();
      expect(await deletion, isFalse);
      expect(
        container.read(observingListNotifierProvider).statusMessage,
        isNull,
      );
      verify(() => hostA.deleteObservingList(42)).called(1);
      verifyNever(() => hostB.deleteObservingList(42));
    },
  );

  test(
    'browsing stream clears active list without constructing notifier',
    () async {
      when(
        hostA.getObservingLists,
      ).thenAnswer((_) async => const <ObservingList>[]);
      when(
        hostB.getObservingLists,
      ).thenAnswer((_) async => const <ObservingList>[]);
      final subscription = container.listen(
        observingListsProvider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      container.read(activeObservingListIdProvider.notifier).state = 51;

      backendNotifier.switchTo(hostB);

      expect(container.read(activeObservingListIdProvider), isNull);
    },
  );

  test('same-list duplicates coalesce and a new host is not blocked', () async {
    final hostAGate = Completer<int>();
    when(
      () => hostA.duplicateObservingList(7),
    ).thenAnswer((_) => hostAGate.future);
    when(() => hostB.duplicateObservingList(7)).thenAnswer((_) async => 99);
    final notifier = container.read(observingListNotifierProvider.notifier);

    final first = notifier.duplicateList(7);
    final duplicate = notifier.duplicateList(7);
    verify(() => hostA.duplicateObservingList(7)).called(1);

    backendNotifier.switchTo(hostB);
    expect(await notifier.duplicateList(7), 99);
    verify(() => hostB.duplicateObservingList(7)).called(1);

    hostAGate.complete(88);
    expect(await first, isNull);
    expect(await duplicate, isNull);
    expect(container.read(observingListNotifierProvider).isSaving, isFalse);
  });

  test('UI state copyWith preserves omitted messages and can clear them', () {
    const original = ObservingListUiState(
      isSaving: true,
      statusMessage: 'done',
      errorMessage: 'failed',
    );

    final stopped = original.copyWith(isSaving: false);
    expect(stopped.statusMessage, 'done');
    expect(stopped.errorMessage, 'failed');

    final cleared = stopped.copyWith(statusMessage: null, errorMessage: null);
    expect(cleared.statusMessage, isNull);
    expect(cleared.errorMessage, isNull);
  });
}
