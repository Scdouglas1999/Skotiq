import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

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
  test('remote list and record reads use the appliance library', () async {
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
    final service = container.read(calibrationLibraryServiceProvider);

    final records = await service.listMasters(
      filter: const CalibrationLibraryFilter(type: CalibrationMasterType.dark),
    );
    expect(records.map((record) => record.id), [9, 4]);
    expect((await service.getRecord(CalibrationMasterType.dark, 4))?.id, 4);
    verify(() => backend.getCalibrationMasters(type: 'dark')).called(2);
  });

  test('a late library response from the old host is discarded', () async {
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
    final service = container.read(calibrationLibraryServiceProvider);

    final loading = service.listMasters();
    await Future<void>.delayed(Duration.zero);
    backendNotifier.replaceWith(newBackend);
    response.complete([
      _masterJson(
        id: 7,
        type: CalibrationMasterType.dark,
        createdAt: DateTime.utc(2026, 7, 15),
      ),
    ]);

    await expectLater(
      loading,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('host changed'),
        ),
      ),
    );
  });
}
