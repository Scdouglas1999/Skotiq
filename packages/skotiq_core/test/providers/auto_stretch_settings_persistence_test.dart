import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _ControllableSettingsDao extends SettingsDao {
  _ControllableSettingsDao(super.db);

  bool failWrites = false;

  @override
  Future<void> setAutoStretchSettings(String jsonSettings) async {
    if (failWrites) throw StateError('write failed');
    await super.setAutoStretchSettings(jsonSettings);
  }
}

class _DelayedReadSettingsDao extends SettingsDao {
  _DelayedReadSettingsDao(super.db);

  final readResult = Completer<String?>();

  @override
  Future<String?> getAutoStretchSettings() => readResult.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase database;

  setUp(() {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => database.close());

  test(
    'failed persistence restores the last confirmed stretch settings',
    () async {
      final dao = _ControllableSettingsDao(database);
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          settingsDaoProvider.overrideWithValue(dao),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(autoStretchSettingsProvider.notifier);
      await Future<void>.delayed(Duration.zero);

      final confirmed = AutoStretchSettings.defaults().copyWith(enabled: true);
      await notifier.update(confirmed);
      dao.failWrites = true;

      await expectLater(
        notifier.update(confirmed.copyWith(method: AutoStretchMethod.asinh)),
        throwsStateError,
      );

      expect(container.read(autoStretchSettingsProvider), confirmed);
    },
  );

  test('a late startup read cannot overwrite a newer stretch choice', () async {
    final dao = _DelayedReadSettingsDao(database);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        settingsDaoProvider.overrideWithValue(dao),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(autoStretchSettingsProvider.notifier);
    final requested = AutoStretchSettings.defaults().copyWith(enabled: true);

    final save = notifier.update(requested);
    dao.readResult.complete(
      jsonEncode(
        AutoStretchSettings.defaults()
            .copyWith(method: AutoStretchMethod.log)
            .toJson(),
      ),
    );
    await save;
    await Future<void>.delayed(Duration.zero);

    expect(container.read(autoStretchSettingsProvider), requested);
  });

  test(
    'rapid updates persist and expose the final requested settings',
    () async {
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(autoStretchSettingsProvider.notifier);
      await Future<void>.delayed(Duration.zero);
      final first = AutoStretchSettings.defaults().copyWith(enabled: true);
      final last = first.copyWith(method: AutoStretchMethod.gamma);

      await Future.wait([notifier.update(first), notifier.update(last)]);

      expect(container.read(autoStretchSettingsProvider), last);
      final stored = await database.settingsDao.getAutoStretchSettings();
      expect(AutoStretchSettings.fromJson(jsonDecode(stored!)), last);
    },
  );
}
