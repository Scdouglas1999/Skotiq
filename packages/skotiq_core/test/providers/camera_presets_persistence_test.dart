import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _ControllableSettingsDao extends SettingsDao {
  _ControllableSettingsDao(super.db);

  bool failWrites = false;

  @override
  Future<void> setSetting(String key, String value) async {
    if (failWrites) throw StateError('write failed');
    await super.setSetting(key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase database;
  late _ControllableSettingsDao dao;
  late ProviderContainer container;

  setUp(() {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    dao = _ControllableSettingsDao(database);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        settingsDaoProvider.overrideWithValue(dao),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await database.close();
  });

  Future<CameraPresetsNotifier> loadedNotifier() async {
    final notifier = container.read(cameraPresetsProvider.notifier);
    while (container.read(cameraPresetsProvider).valueOrNull == null) {
      await Future<void>.delayed(Duration.zero);
    }
    return notifier;
  }

  CameraPreset preset(String id) => CameraPreset(
    id: id,
    name: 'Preset $id',
    gain: 100,
    offset: 20,
    createdAt: DateTime(2026, 7, 13),
  );

  test('failed persistence leaves the confirmed preset list intact', () async {
    final notifier = await loadedNotifier();
    final before = container.read(cameraPresetsProvider).value!;
    dao.failWrites = true;

    await expectLater(notifier.addPreset(preset('failed')), throwsStateError);

    expect(container.read(cameraPresetsProvider).value, before);
    expect(container.read(cameraPresetsProvider).hasError, isFalse);
  });

  test('concurrent preset additions merge and persist both entries', () async {
    final notifier = await loadedNotifier();

    await Future.wait([
      notifier.addPreset(preset('one')),
      notifier.addPreset(preset('two')),
    ]);

    final ids = container
        .read(cameraPresetsProvider)
        .value!
        .map((item) => item.id);
    expect(ids, containsAll(['one', 'two']));
    final stored =
        jsonDecode((await dao.getSetting('camera_presets'))!) as List;
    expect(
      stored.map((item) => (item as Map<String, dynamic>)['id']),
      containsAll(['one', 'two']),
    );
  });
}
