import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/settings_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/notification/notification_categories.dart';
import 'package:skotiq_core/src/models/notification/transport_configs.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/notification_router_provider.dart';
import 'package:skotiq_core/src/services/notification/secrets_store.dart';

class _FailingEmailSettingsDao extends SettingsDao {
  _FailingEmailSettingsDao(super.db);

  @override
  Future<void> setSetting(String key, String value) async {
    if (key == 'notification_transport_email') {
      throw StateError('config write failed');
    }
    await super.setSetting(key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase database;

  setUp(() {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => database.close());

  test('rapid routing-rule edits merge instead of losing one change', () async {
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    addTearDown(container.dispose);
    await container.read(notificationRoutingMatrixProvider.future);
    final notifier = container.read(notificationRoutingMatrixProvider.notifier);

    const startedRule = NotificationRoutingRule(
      transports: [NotificationTransportKind.email],
      maxPerHour: 2,
    );
    const completedRule = NotificationRoutingRule(
      transports: [NotificationTransportKind.telegram],
      debounceSeconds: 30,
    );

    await Future.wait([
      notifier.setRule(NotificationCategory.sequenceStarted, startedRule),
      notifier.setRule(NotificationCategory.sequenceCompleted, completedRule),
    ]);

    final matrix = container.read(notificationRoutingMatrixProvider).value!;
    expect(matrix.ruleFor(NotificationCategory.sequenceStarted), startedRule);
    expect(
      matrix.ruleFor(NotificationCategory.sequenceCompleted),
      completedRule,
    );

    final stored = await database.settingsDao.getSetting(
      'notification_routing_matrix',
    );
    final restored = NotificationRoutingMatrix.fromJson(
      jsonDecode(stored!) as Map<String, dynamic>,
    );
    expect(restored.ruleFor(NotificationCategory.sequenceStarted), startedRule);
    expect(
      restored.ruleFor(NotificationCategory.sequenceCompleted),
      completedRule,
    );
  });

  test('failed config write restores the previous keyring secret', () async {
    final secureBacking = InMemorySecureKeyValueStore();
    final secrets = SecretsStore(secureBacking);
    await secrets.write(SecretField.emailPassword, 'old-password');
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        settingsDaoProvider.overrideWithValue(
          _FailingEmailSettingsDao(database),
        ),
        secretsStoreProvider.overrideWithValue(secrets),
      ],
    );
    addTearDown(container.dispose);
    final original = await container.read(emailTransportConfigProvider.future);
    expect(original.password, 'old-password');

    final updated = original.copyWith(
      smtpHost: 'smtp.example.com',
      password: 'new-password',
    );
    await expectLater(
      container.read(emailTransportConfigProvider.notifier).save(updated),
      throwsStateError,
    );

    expect(await secrets.read(SecretField.emailPassword), 'old-password');
    expect(container.read(emailTransportConfigProvider).value, original);
  });

  test(
    'generic webhook URL and authorization headers live in the keyring',
    () async {
      final secrets = SecretsStore(InMemorySecureKeyValueStore());
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          secretsStoreProvider.overrideWithValue(secrets),
        ],
      );
      addTearDown(container.dispose);
      await container.read(webhookTransportConfigProvider.future);

      const config = WebhookTransportConfig(
        url: 'https://example.com/hook?token=secret',
        headers: {'Authorization': 'Bearer secret'},
        bodyTemplate: '{"text":"\${title}"}',
      );
      await container
          .read(webhookTransportConfigProvider.notifier)
          .save(config);

      final raw = await database.settingsDao.getSetting(
        'notification_transport_webhookGeneric',
      );
      final persisted = jsonDecode(raw!) as Map<String, dynamic>;
      expect(persisted['url'], isEmpty);
      expect(persisted['headers'], isEmpty);
      expect(await secrets.read(SecretField.genericWebhookUrl), config.url);
      expect(
        jsonDecode(await secrets.read(SecretField.genericWebhookHeaders)),
        config.headers,
      );
      expect(container.read(webhookTransportConfigProvider).value, config);
    },
  );

  test(
    'corrupt routing matrix errors and refuses default-based overwrite',
    () async {
      await database.settingsDao.setSetting(
        'notification_routing_matrix',
        '{not valid json',
      );
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)],
      );
      addTearDown(container.dispose);

      await expectLater(
        container.read(notificationRoutingMatrixProvider.future),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        container
            .read(notificationRoutingMatrixProvider.notifier)
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
        await database.settingsDao.getSetting('notification_routing_matrix'),
        '{not valid json',
      );
    },
  );
}
