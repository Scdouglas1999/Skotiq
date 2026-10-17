import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/settings_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/push_notification_provider.dart';

class _FailingSettingsDao extends SettingsDao {
  _FailingSettingsDao(super.db);

  @override
  Future<void> setSetting(String key, String value) async {
    throw StateError('write failed');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase database;

  setUp(() {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => database.close());

  test(
    'concurrent event toggles merge and persist in invocation order',
    () async {
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)],
      );
      addTearDown(container.dispose);
      await container.read(pushNotificationConfigProvider.future);
      final notifier = container.read(pushNotificationConfigProvider.notifier);

      await Future.wait([
        notifier.setNotifySequenceCompleted(false),
        notifier.setNotifyWeatherUnsafe(false),
      ]);

      final config = container.read(pushNotificationConfigProvider).value!;
      expect(config.notifySequenceCompleted, isFalse);
      expect(config.notifyWeatherUnsafe, isFalse);
      final stored = await database.settingsDao.getSetting(
        'push_notification_config',
      );
      final json = jsonDecode(stored!) as Map<String, dynamic>;
      expect(json['notifySequenceCompleted'], isFalse);
      expect(json['notifyWeatherUnsafe'], isFalse);
    },
  );

  test(
    'failed persistence leaves the confirmed provider state unchanged',
    () async {
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          settingsDaoProvider.overrideWithValue(_FailingSettingsDao(database)),
        ],
      );
      addTearDown(container.dispose);
      await container.read(pushNotificationConfigProvider.future);
      final notifier = container.read(pushNotificationConfigProvider.notifier);

      await expectLater(notifier.setEnabled(false), throwsStateError);

      expect(
        container.read(pushNotificationConfigProvider).value!.enabled,
        isTrue,
      );
    },
  );

  test(
    'corrupt stored config errors and refuses default-based overwrite',
    () async {
      await database.settingsDao.setSetting(
        'push_notification_config',
        '{not valid json',
      );
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)],
      );
      addTearDown(container.dispose);

      await expectLater(
        container.read(pushNotificationConfigProvider.future),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        container
            .read(pushNotificationConfigProvider.notifier)
            .setEnabled(false),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('refusing to overwrite it with defaults'),
          ),
        ),
      );

      expect(
        await database.settingsDao.getSetting('push_notification_config'),
        '{not valid json',
      );
    },
  );
}
