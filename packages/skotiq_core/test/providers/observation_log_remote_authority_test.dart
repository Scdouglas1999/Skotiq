import 'dart:async';

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

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void replaceWith(SkotiqBackend backend) => state = backend;
}

RemoteNotesJournalEntry _remoteLog({
  required int id,
  required String objectName,
  required String notes,
}) {
  return RemoteNotesJournalEntry(
    id: id,
    timestamp: DateTime.utc(2026, 7, id, 1),
    objectName: objectName,
    catalogId: objectName,
    ra: 0.7,
    dec: 41.3,
    notes: notes,
    rating: 4,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  late _MockNetworkBackend backend;
  late ProviderContainer container;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    backend = _MockNetworkBackend();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  test('UI state copyWith can explicitly clear messages and filters', () {
    final populated = ObservationLogUiState(
      statusMessage: 'Saved',
      errorMessage: 'Old error',
      filterQuery: 'M31',
      filterMinRating: 4,
      filterStartDate: DateTime.utc(2026, 7, 1),
      filterEndDate: DateTime.utc(2026, 7, 31),
    );

    final cleared = populated.copyWith(
      statusMessage: null,
      errorMessage: null,
      filterQuery: null,
      filterMinRating: null,
      filterStartDate: null,
      filterEndDate: null,
    );

    expect(cleared.statusMessage, isNull);
    expect(cleared.errorMessage, isNull);
    expect(cleared.filterQuery, isNull);
    expect(cleared.filterMinRating, isNull);
    expect(cleared.filterStartDate, isNull);
    expect(cleared.filterEndDate, isNull);
  });

  test(
    'remote mutations use the imaging host and leave controller DB empty',
    () async {
      final timestamp = DateTime.utc(2026, 7, 13, 1, 2, 3);
      when(() => backend.fetchNotesJournal(limit: 1000, offset: 0)).thenAnswer(
        (_) async =>
            const RemotePage<RemoteNotesJournalEntry>(items: [], total: 0),
      );
      when(
        () => backend.createObservationLog(
          timestamp: timestamp,
          objectName: 'M31',
          ra: 0.7,
          dec: 41.3,
          objectType: 'galaxy',
          catalogId: 'M31',
          altitude: 55,
          azimuth: 120,
          notes: 'Good structure',
          rating: 4,
          equipmentProfileId: 7,
          seeingConditions: 'good',
          transparency: 'fair',
          locationName: 'Back yard',
          latitude: 40,
          longitude: -75,
        ),
      ).thenAnswer((_) async => 42);
      when(() => backend.deleteObservationLog(42)).thenAnswer((_) async {});
      when(() => backend.deleteAllObservationLogs()).thenAnswer((_) async {});

      final notifier = container.read(observationLogNotifierProvider.notifier);
      final id = await notifier.logObservation(
        timestamp: timestamp,
        objectName: 'M31',
        ra: 0.7,
        dec: 41.3,
        objectType: 'galaxy',
        catalogId: 'M31',
        altitude: 55,
        azimuth: 120,
        notes: 'Good structure',
        rating: 4,
        equipmentProfileId: 7,
        seeingConditions: 'good',
        transparency: 'fair',
        locationName: 'Back yard',
        latitude: 40,
        longitude: -75,
      );
      final deleted = await notifier.deleteLog(42);
      await notifier.deleteAllLogs();

      expect(
        id,
        42,
        reason: container.read(observationLogNotifierProvider).errorMessage,
      );
      expect(deleted, isTrue);
      expect(await db.observationLogsDao.getAllLogs(), isEmpty);
      verify(() => backend.deleteObservationLog(42)).called(1);
      verify(() => backend.deleteAllObservationLogs()).called(1);
    },
  );

  test(
    'remote provider paginates all host rows and exports those rows',
    () async {
      when(() => backend.fetchNotesJournal(limit: 1000, offset: 0)).thenAnswer(
        (_) async => RemotePage(
          items: [_remoteLog(id: 1, objectName: 'M31', notes: 'Clear, steady')],
          total: 2,
        ),
      );
      when(() => backend.fetchNotesJournal(limit: 1000, offset: 1)).thenAnswer(
        (_) async => RemotePage(
          items: [_remoteLog(id: 2, objectName: 'M42', notes: 'Bright "core"')],
          total: 2,
        ),
      );

      final logs = await container.read(observationLogsProvider.future);
      final csv = await container
          .read(observationLogNotifierProvider.notifier)
          .exportCsv();

      expect(logs.map((log) => log.objectName), ['M42', 'M31']);
      expect(csv, contains('M31'));
      expect(csv, contains('M42'));
      expect(csv, contains('"Clear, steady"'));
      expect(csv, contains('"Bright ""core"""'));
      expect(await db.observationLogsDao.getAllLogs(), isEmpty);
      // The live provider and the authority-bound export each fetch a complete
      // snapshot. Export deliberately does not reuse a provider future that
      // could be invalidated onto a different host mid-request.
      verify(() => backend.fetchNotesJournal(limit: 1000, offset: 0)).called(2);
      verify(() => backend.fetchNotesJournal(limit: 1000, offset: 1)).called(2);
    },
  );

  test(
    'duplicate remote deletes are coalesced while the first is pending',
    () async {
      final gate = Completer<void>();
      when(
        () => backend.deleteObservationLog(42),
      ).thenAnswer((_) => gate.future);
      final notifier = container.read(observationLogNotifierProvider.notifier);

      final first = notifier.deleteLog(42);
      final duplicate = notifier.deleteLog(42);
      await Future<void>.delayed(Duration.zero);

      verify(() => backend.deleteObservationLog(42)).called(1);
      gate.complete();
      expect(await Future.wait([first, duplicate]), [isTrue, isFalse]);
    },
  );

  test('host switch unlocks export and discards the old host CSV', () async {
    final hostA = _MockNetworkBackend();
    final hostB = _MockNetworkBackend();
    final hostAGate = Completer<RemotePage<RemoteNotesJournalEntry>>();
    when(
      () => hostA.fetchNotesJournal(limit: 1000, offset: 0),
    ).thenAnswer((_) => hostAGate.future);
    when(
      () => hostB.fetchNotesJournal(limit: 1000, offset: 0),
    ).thenAnswer((_) async => const RemotePage(items: [], total: 0));
    late _SwappableBackendNotifier backendNotifier;
    final switchedContainer = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith((ref) {
          backendNotifier = _SwappableBackendNotifier(ref, hostA);
          return backendNotifier;
        }),
      ],
    );
    addTearDown(switchedContainer.dispose);
    final notifier = switchedContainer.read(
      observationLogNotifierProvider.notifier,
    );

    final oldExport = notifier.exportCsv();
    await Future<void>.delayed(Duration.zero);
    backendNotifier.replaceWith(hostB);

    expect(await notifier.exportCsv(), isNull);
    hostAGate.complete(
      RemotePage(
        items: [_remoteLog(id: 3, objectName: 'M51', notes: 'Old host')],
        total: 1,
      ),
    );
    expect(await oldExport, isNull);
    expect(
      switchedContainer.read(observationLogNotifierProvider).statusMessage,
      'No observations to export.',
    );
    verify(() => hostB.fetchNotesJournal(limit: 1000, offset: 0)).called(1);
  });
}
