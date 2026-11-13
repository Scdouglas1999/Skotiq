import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _ReplaceableBackendNotifier extends BackendNotifier {
  _ReplaceableBackendNotifier(super.ref, SkotiqBackend initial) : super() {
    state = initial;
  }

  void replaceWith(SkotiqBackend next) => state = next;
}

Map<String, dynamic> _masterJson({
  required int id,
  required CalibrationMasterType type,
  required DateTime createdAt,
}) => CalibrationMasterRecord(
  type: type,
  id: id,
  filePath: '/host/master_$id.fits',
  isMaster: true,
  createdAt: createdAt,
).toJson(now: createdAt);

void main() {
  test('a linked client lists and reads the host library', () async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final backend = _MockNetworkBackend();
    final newer = DateTime.utc(2026, 7, 15);
    final older = newer.subtract(const Duration(days: 1));
    when(() => backend.getCalibrationMasters(type: 'dark')).thenAnswer(
      (_) async => [
        _masterJson(id: 4, type: CalibrationMasterType.dark, createdAt: older),
        _masterJson(id: 9, type: CalibrationMasterType.dark, createdAt: newer),
      ],
    );

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _ReplaceableBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);
    final library = container.read(calibrationLibraryProvider);
    expect(library, same(backend.remoteHost!.calibrationLibrary));

    final records = await library.listMasters(
      filter: const CalibrationLibraryFilter(type: CalibrationMasterType.dark),
    );
    expect(records.map((record) => record.id), [9, 4]);
    expect((await library.getRecord(CalibrationMasterType.dark, 4))?.id, 4);
    verify(() => backend.getCalibrationMasters(type: 'dark')).called(2);
  });

  test('a late library response from the old host is stale', () async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final oldBackend = _MockNetworkBackend();
    final newBackend = _MockNetworkBackend();
    final response = Completer<List<Map<String, dynamic>>>();
    when(oldBackend.getCalibrationMasters).thenAnswer((_) => response.future);

    late _ReplaceableBackendNotifier backendNotifier;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith((ref) {
          backendNotifier = _ReplaceableBackendNotifier(ref, oldBackend);
          return backendNotifier;
        }),
      ],
    );
    addTearDown(container.dispose);
    final scope = AsyncScopes(
      container.read,
      calibrationLibraryProvider,
    ).begin();

    final loading = scope.value.listMasters();
    await Future<void>.delayed(Duration.zero);
    backendNotifier.replaceWith(newBackend);
    response.complete([
      _masterJson(
        id: 7,
        type: CalibrationMasterType.dark,
        createdAt: DateTime.utc(2026, 7, 15),
      ),
    ]);

    expect((await loading).single.id, 7);
    expect(scope.isStale, isTrue);
    expect(
      container.read(calibrationLibraryProvider),
      same(newBackend.remoteHost!.calibrationLibrary),
    );
    expect(
      () => scope.ensureCurrent('the calibration library was loading'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('host changed'),
        ),
      ),
    );
  });

  test('a local backend reads this process\'s own library', () async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final local = DisconnectedBackend();
    addTearDown(local.dispose);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _ReplaceableBackendNotifier(ref, local),
        ),
      ],
    );
    addTearDown(container.dispose);

    final library = container.read(calibrationLibraryProvider);
    expect(library, same(container.read(calibrationLibraryServiceProvider)));
    expect(library.masterFileDownload(_record(1)), isNull);
    expect(await library.listMasters(), isEmpty);
  });
}

CalibrationMasterRecord _record(int id) => CalibrationMasterRecord(
  type: CalibrationMasterType.dark,
  id: id,
  filePath: '/host/master_$id.fits',
  isMaster: true,
  createdAt: DateTime.utc(2026, 7, 15),
);
