import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _SettingsDao extends SettingsDao {
  _SettingsDao(super.db);

  final values = <String, String>{};
  Completer<String?>? delayedRead;
  bool failNextWrite = false;

  @override
  Future<String?> getSetting(String key) {
    final pending = delayedRead;
    if (pending != null) return pending.future;
    return Future<String?>.value(values[key]);
  }

  @override
  Future<void> setSetting(String key, String value) async {
    if (failNextWrite) {
      failNextWrite = false;
      throw StateError('first write failed');
    }
    values[key] = value;
  }
}

final _profileState = StateProvider<EquipmentProfileModel?>((ref) => null);

EquipmentProfileModel _profile(int id, {int gain = 100, int offset = 50}) =>
    EquipmentProfileModel(
      id: id,
      name: 'Rig $id',
      defaultGain: gain,
      defaultOffset: offset,
    );

ProviderContainer _container(
  SkotiqDatabase database,
  _SettingsDao dao,
  EquipmentProfileModel profile,
) {
  return ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(database),
      settingsDaoProvider.overrideWithValue(dao),
      _profileState.overrideWith((ref) => profile),
      activeEquipmentProfileProvider.overrideWith(
        (ref) => ref.watch(_profileState),
      ),
    ],
  );
}

Future<void> _hydrate(ProviderContainer container) async {
  container.read(syncExposureFromProfileProvider);
  await pumpEventQueue(times: 20);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase database;
  setUp(() {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() => database.close());

  test(
    'saved settings restore independently across A/B/A profile switches',
    () async {
      final dao = _SettingsDao(database);
      final container = _container(database, dao, _profile(1));
      addTearDown(container.dispose);

      await _hydrate(container);
      final updater = container.read(manualExposureSettingsUpdaterProvider);
      updater.update(
        container
            .read(exposureSettingsProvider)
            .copyWith(exposureTime: 11, gain: 111, offset: 21),
      );
      await pumpEventQueue(times: 20);

      container.read(_profileState.notifier).state = _profile(2, gain: 222);
      await _hydrate(container);
      updater.update(
        container
            .read(exposureSettingsProvider)
            .copyWith(exposureTime: 22, gain: 222, offset: 32),
      );
      await pumpEventQueue(times: 20);

      container.read(_profileState.notifier).state = _profile(1);
      await _hydrate(container);
      final restored = container.read(exposureSettingsProvider);
      expect(restored.exposureTime, 11);
      expect(restored.gain, 111);
      expect(restored.offset, 21);
    },
  );

  test(
    'an unsaved profile gets a complete safe baseline after a saved profile',
    () async {
      final dao = _SettingsDao(database);
      final container = _container(database, dao, _profile(1));
      addTearDown(container.dispose);
      await _hydrate(container);
      container
          .read(manualExposureSettingsUpdaterProvider)
          .update(
            container
                .read(exposureSettingsProvider)
                .copyWith(
                  exposureTime: 120,
                  filter: 'Ha',
                  frameType: FrameType.dark,
                  fastReadout: true,
                ),
          );
      await pumpEventQueue(times: 20);

      container.read(_profileState.notifier).state = _profile(2, gain: 222);
      await _hydrate(container);
      final fresh = container.read(exposureSettingsProvider);
      expect(fresh.exposureTime, 2);
      expect(fresh.frameType, FrameType.light);
      expect(fresh.filter, isNull);
      expect(fresh.fastReadout, isFalse);
      expect(fresh.gain, 222);
    },
  );

  test('corrupt stored JSON falls back to the safe profile baseline', () async {
    final dao = _SettingsDao(database);
    dao.values['imaging_capture_settings_profile_1'] = '{not-json';
    final container = _container(database, dao, _profile(1, gain: 123));
    addTearDown(container.dispose);

    await _hydrate(container);
    final settings = container.read(exposureSettingsProvider);
    expect(settings.exposureTime, 2);
    expect(settings.frameType, FrameType.light);
    expect(settings.filter, isNull);
    expect(settings.gain, 123);
  });

  test('manual edit wins over delayed hydration', () async {
    final dao = _SettingsDao(database);
    dao.delayedRead = Completer<String?>();
    dao.values['imaging_capture_settings_profile_1'] = jsonEncode({
      'exposureTime': 90,
      'gain': 900,
      'offset': 90,
      'binningX': 1,
      'binningY': 1,
      'frameType': 'dark',
    });
    final container = _container(database, dao, _profile(1));
    addTearDown(container.dispose);
    container.read(syncExposureFromProfileProvider);
    await pumpEventQueue(times: 5);

    container
        .read(manualExposureSettingsUpdaterProvider)
        .update(
          container.read(exposureSettingsProvider).copyWith(exposureTime: 7),
        );
    dao.delayedRead!.complete(dao.values['imaging_capture_settings_profile_1']);
    await pumpEventQueue(times: 20);

    expect(container.read(exposureSettingsProvider).exposureTime, 7);
  });

  test('a failed write does not poison the next manual write', () async {
    final dao = _SettingsDao(database)..failNextWrite = true;
    final container = _container(database, dao, _profile(1));
    addTearDown(container.dispose);
    await _hydrate(container);
    final updater = container.read(manualExposureSettingsUpdaterProvider);
    updater.update(
      container.read(exposureSettingsProvider).copyWith(exposureTime: 3),
    );
    updater.update(
      container.read(exposureSettingsProvider).copyWith(exposureTime: 4),
    );
    await pumpEventQueue(times: 30);

    final stored = jsonDecode(
      dao.values['imaging_capture_settings_profile_1']!,
    );
    expect((stored as Map)['exposureTime'], 4);
  });
}
