import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _FailingSettingsDao extends SettingsDao {
  _FailingSettingsDao(super.db);

  @override
  Future<void> setSetting(String key, String value) async {
    throw StateError('write failed');
  }
}

class _DelayedReadSettingsDao extends SettingsDao {
  _DelayedReadSettingsDao(super.db);

  final readResult = Completer<String?>();

  @override
  Future<String?> getSetting(String key) => readResult.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase database;

  setUp(() {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => database.close());

  test(
    'failed persistence leaves the confirmed Glance mode unchanged',
    () async {
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          settingsDaoProvider.overrideWithValue(_FailingSettingsDao(database)),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(glanceModeProvider.notifier);
      await Future<void>.delayed(Duration.zero);

      await expectLater(notifier.setEnabled(true), throwsStateError);

      expect(container.read(glanceModeProvider), isFalse);
    },
  );

  test('a late startup read cannot overwrite a newer user choice', () async {
    final dao = _DelayedReadSettingsDao(database);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        settingsDaoProvider.overrideWithValue(dao),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(glanceModeProvider.notifier);

    final save = notifier.setEnabled(true);
    dao.readResult.complete('false');
    await save;
    await Future<void>.delayed(Duration.zero);

    expect(container.read(glanceModeProvider), isTrue);
    expect(
      await database.settingsDao.getSetting('glance_mode_enabled'),
      'true',
    );
  });

  test('rapid toggles persist and expose the final requested value', () async {
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(glanceModeProvider.notifier);
    await Future<void>.delayed(Duration.zero);

    await Future.wait([notifier.setEnabled(true), notifier.setEnabled(false)]);

    expect(container.read(glanceModeProvider), isFalse);
    expect(
      await database.settingsDao.getSetting('glance_mode_enabled'),
      'false',
    );
  });
}
