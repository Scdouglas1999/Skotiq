// Where each notification transport's config is stored: the settings key,
// the exact JSON written there (secrets blanked), and the keyring fields.
// Installed hosts hold these values, so they must not move.

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

class _Row {
  const _Row({
    required this.key,
    required this.label,
    required this.config,
    required this.storedJson,
    required this.secrets,
    required this.read,
    required this.save,
  });

  final String key;
  final String label;
  final Object config;
  final String storedJson;
  final Map<String, String> secrets;
  final Future<Object> Function(ProviderContainer c) read;
  final Future<void> Function(ProviderContainer c, Object config) save;
}

final _rows = <_Row>[
  _Row(
    key: 'notification_transport_email',
    label: 'Email',
    config: const EmailTransportConfig(
      smtpHost: 'smtp.example.com',
      smtpPort: 465,
      username: 'rig',
      password: 'pw',
      useTls: false,
      fromAddress: 'rig@example.com',
      toAddress: 'me@example.com',
    ),
    storedJson:
        '{"smtpHost":"smtp.example.com","smtpPort":465,"username":"rig",'
        '"password":"","useTls":false,"fromAddress":"rig@example.com",'
        '"toAddress":"me@example.com"}',
    secrets: {SecretField.emailPassword: 'pw'},
    read: (c) async => c.read(emailTransportConfigProvider.future),
    save: (c, v) => c
        .read(emailTransportConfigProvider.notifier)
        .save(v as EmailTransportConfig),
  ),
  _Row(
    key: 'notification_transport_webhookGeneric',
    label: 'Webhook',
    config: const WebhookTransportConfig(
      url: 'https://example.com/hook',
      headers: {'Authorization': 'Bearer x'},
      bodyTemplate: '{"t":"x"}',
    ),
    storedJson: '{"url":"","headers":{},"bodyTemplate":"{\\"t\\":\\"x\\"}"}',
    secrets: {
      SecretField.genericWebhookUrl: 'https://example.com/hook',
      SecretField.genericWebhookHeaders: '{"Authorization":"Bearer x"}',
    },
    read: (c) async => c.read(webhookTransportConfigProvider.future),
    save: (c, v) => c
        .read(webhookTransportConfigProvider.notifier)
        .save(v as WebhookTransportConfig),
  ),
  _Row(
    key: 'notification_transport_pushover',
    label: 'Pushover',
    config: const PushoverTransportConfig(
      apiToken: 'tok',
      userKey: 'usr',
      device: 'phone',
      priority: 1,
    ),
    storedJson: '{"apiToken":"","userKey":"","device":"phone","priority":1}',
    secrets: {
      SecretField.pushoverApiToken: 'tok',
      SecretField.pushoverUserKey: 'usr',
    },
    read: (c) async => c.read(pushoverTransportConfigProvider.future),
    save: (c, v) => c
        .read(pushoverTransportConfigProvider.notifier)
        .save(v as PushoverTransportConfig),
  ),
  _Row(
    key: 'notification_transport_telegram',
    label: 'Telegram',
    config: const TelegramTransportConfig(
      botToken: 'bot',
      chatId: '42',
      disableNotification: true,
    ),
    storedJson: '{"botToken":"","chatId":"42","disableNotification":true}',
    secrets: {SecretField.telegramBotToken: 'bot'},
    read: (c) async => c.read(telegramTransportConfigProvider.future),
    save: (c, v) => c
        .read(telegramTransportConfigProvider.notifier)
        .save(v as TelegramTransportConfig),
  ),
  _Row(
    key: 'notification_transport_discord',
    label: 'Discord',
    config: const DiscordTransportConfig(
      webhookUrl: 'https://discord.com/api/webhooks/1/a',
      username: 'Rig',
    ),
    storedJson: '{"webhookUrl":"","username":"Rig","avatarUrl":null}',
    secrets: {
      SecretField.discordWebhookUrl: 'https://discord.com/api/webhooks/1/a',
    },
    read: (c) async => c.read(discordTransportConfigProvider.future),
    save: (c, v) => c
        .read(discordTransportConfigProvider.notifier)
        .save(v as DiscordTransportConfig),
  ),
  _Row(
    key: 'notification_transport_mqtt',
    label: 'MQTT',
    config: const MqttTransportConfig(
      host: 'broker.local',
      username: 'u',
      password: 'p',
      topic: 'rig/events',
    ),
    storedJson: '',
    secrets: {SecretField.mqttPassword: 'p'},
    read: (c) async => c.read(mqttTransportConfigProvider.future),
    save: (c, v) => c
        .read(mqttTransportConfigProvider.notifier)
        .save(v as MqttTransportConfig),
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final row in _rows) {
    test('${row.label}: saved under ${row.key} with the secrets in the '
        'keyring, and read back whole', () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final keyring = InMemorySecureKeyValueStore();
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          secretsStoreProvider.overrideWithValue(SecretsStore(keyring)),
        ],
      );
      addTearDown(container.dispose);

      await row.read(container);
      await row.save(container, row.config);

      final stored = await db.settingsDao.getSetting(row.key);
      if (row.storedJson.isEmpty) {
        final decoded = jsonDecode(stored!) as Map<String, dynamic>;
        expect(decoded['password'], isNull);
        expect(decoded['host'], 'broker.local');
      } else {
        expect(stored, row.storedJson);
      }
      final secrets = SecretsStore(keyring);
      for (final entry in row.secrets.entries) {
        expect(await secrets.read(entry.key), entry.value, reason: entry.key);
      }

      final fresh = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          secretsStoreProvider.overrideWithValue(SecretsStore(keyring)),
        ],
      );
      addTearDown(fresh.dispose);
      expect(await row.read(fresh), row.config);
    });

    test('${row.label}: a corrupt stored config is an error, not a '
        'default', () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await db.settingsDao.setSetting(row.key, '{not json');
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          secretsStoreProvider.overrideWithValue(
            SecretsStore(InMemorySecureKeyValueStore()),
          ),
        ],
      );
      addTearDown(container.dispose);

      await expectLater(
        row.read(container),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            startsWith('${row.label} routing configuration is corrupt: '),
          ),
        ),
      );
    });
  }
}
