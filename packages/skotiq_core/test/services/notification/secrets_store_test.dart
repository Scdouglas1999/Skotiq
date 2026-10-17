// Unit tests for SecretsStore.
//
// Covers:
//   * Round-trip of every sensitive field via [SecretsStore.read/write].
//   * One-shot migration from plaintext app_settings blobs to the secure
//     store, with the migration flag short-circuiting re-runs.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/settings_dao.dart';
import 'package:skotiq_core/src/services/notification/secrets_store.dart';

import '../../mocks/mock_database.dart';

class _FailingReadStore implements SecureKeyValueStore {
  @override
  Future<void> delete({required String key}) async {}

  @override
  Future<String?> read({required String key}) async {
    throw StateError('keyring unavailable');
  }

  @override
  Future<void> write({required String key, required String value}) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SecretsStore round-trip', () {
    test('writes then reads back each sensitive field', () async {
      final store = SecretsStore(InMemorySecureKeyValueStore());
      final fields = <String, String>{
        SecretField.emailPassword: 'smtp-secret',
        SecretField.pushoverApiToken: 'pushover-token',
        SecretField.pushoverUserKey: 'pushover-user',
        SecretField.telegramBotToken: '1234:abcd',
        SecretField.discordWebhookUrl:
            'https://discord.com/api/webhooks/123/secret',
        SecretField.genericWebhookUrl:
            'https://example.com/hooks/skotiq?token=secret',
        SecretField.genericWebhookHeaders: '{"Authorization":"Bearer secret"}',
        SecretField.mqttPassword: 'mqtt-pw',
      };
      for (final entry in fields.entries) {
        await store.write(entry.key, entry.value);
      }
      for (final entry in fields.entries) {
        expect(
          await store.read(entry.key),
          entry.value,
          reason: 'round-trip ${entry.key}',
        );
        expect(await store.has(entry.key), isTrue);
      }
    });

    test('empty write deletes the key', () async {
      final store = SecretsStore(InMemorySecureKeyValueStore());
      await store.write(SecretField.emailPassword, 'something');
      await store.write(SecretField.emailPassword, '');
      expect(await store.read(SecretField.emailPassword), '');
      expect(await store.has(SecretField.emailPassword), isFalse);
    });

    test('absent field reads as empty', () async {
      final store = SecretsStore(InMemorySecureKeyValueStore());
      expect(await store.read(SecretField.mqttPassword), '');
    });

    test(
      'keyring read failure is not manufactured into an empty secret',
      () async {
        final store = SecretsStore(_FailingReadStore());
        await expectLater(
          store.read(SecretField.emailPassword),
          throwsStateError,
        );
      },
    );
  });

  group('SecretsStore.migrateFromPlaintext', () {
    test(
      'moves plaintext secrets from app_settings into the keyring',
      () async {
        final db = createTestDatabase();
        addTearDown(db.close);
        final dao = SettingsDao(db);
        final secure = InMemorySecureKeyValueStore();
        final store = SecretsStore(secure);

        // Seed the legacy plaintext blobs.
        await dao.setSetting(
          'notification_transport_email',
          jsonEncode({
            'smtpHost': 'smtp.example.com',
            'smtpPort': 587,
            'username': 'alice',
            'password': 'plain-smtp-pw',
            'useTls': true,
            'fromAddress': 'alice@example.com',
            'toAddress': 'alice@example.com',
          }),
        );
        await dao.setSetting(
          'notification_transport_webhookGeneric',
          jsonEncode({
            'url': 'https://example.com/hooks/skotiq?token=secret',
            'headers': {'Authorization': 'Bearer plain-token'},
            'bodyTemplate': null,
          }),
        );
        await dao.setSetting(
          'notification_transport_pushover',
          jsonEncode({
            'apiToken': 'plain-pushover-token',
            'userKey': 'plain-pushover-user',
            'device': null,
            'priority': 0,
          }),
        );
        await dao.setSetting(
          'notification_transport_telegram',
          jsonEncode({
            'botToken': 'plain-bot-token',
            'chatId': '@channel',
            'disableNotification': false,
          }),
        );
        await dao.setSetting(
          'notification_transport_discord',
          jsonEncode({
            'webhookUrl': 'https://discord.example/abc',
            'username': null,
            'avatarUrl': null,
          }),
        );
        await dao.setSetting(
          'notification_transport_mqtt',
          jsonEncode({
            'host': 'mqtt.example.com',
            'port': 1883,
            'username': 'bob',
            'password': 'plain-mqtt-pw',
            'topic': 'skotiq/notifications',
            'qos': 0,
            'retain': false,
            'useTls': false,
            'clientId': 'skotiq',
          }),
        );

        final migrated = await store.migrateFromPlaintext(dao);
        expect(migrated, isTrue);

        // Secrets are now in the keyring.
        expect(await store.read(SecretField.emailPassword), 'plain-smtp-pw');
        expect(
          await store.read(SecretField.pushoverApiToken),
          'plain-pushover-token',
        );
        expect(
          await store.read(SecretField.pushoverUserKey),
          'plain-pushover-user',
        );
        expect(
          await store.read(SecretField.telegramBotToken),
          'plain-bot-token',
        );
        expect(
          await store.read(SecretField.discordWebhookUrl),
          'https://discord.example/abc',
        );
        expect(
          await store.read(SecretField.genericWebhookUrl),
          'https://example.com/hooks/skotiq?token=secret',
        );
        expect(
          jsonDecode(await store.read(SecretField.genericWebhookHeaders)),
          {'Authorization': 'Bearer plain-token'},
        );
        expect(await store.read(SecretField.mqttPassword), 'plain-mqtt-pw');

        // The blobs no longer contain the plaintext secrets.
        final emailBlob = jsonDecode(
          await dao.getSetting('notification_transport_email') as String,
        );
        expect(emailBlob['password'], '');
        expect(emailBlob['smtpHost'], 'smtp.example.com'); // non-secret kept

        final pushoverBlob = jsonDecode(
          await dao.getSetting('notification_transport_pushover') as String,
        );
        expect(pushoverBlob['apiToken'], '');
        expect(pushoverBlob['userKey'], '');

        final webhookBlob = jsonDecode(
          await dao.getSetting('notification_transport_webhookGeneric')
              as String,
        );
        expect(webhookBlob['url'], '');
        expect(webhookBlob['headers'], isEmpty);

        final telegramBlob = jsonDecode(
          await dao.getSetting('notification_transport_telegram') as String,
        );
        expect(telegramBlob['botToken'], '');
        expect(telegramBlob['chatId'], '@channel');

        final discordBlob = jsonDecode(
          await dao.getSetting('notification_transport_discord') as String,
        );
        expect(discordBlob['webhookUrl'], '');

        final mqttBlob = jsonDecode(
          await dao.getSetting('notification_transport_mqtt') as String,
        );
        expect(mqttBlob['password'], '');
        expect(mqttBlob['username'], 'bob'); // non-secret kept

        // Flag is set.
        expect(
          await dao.getSetting('notification_secrets_migrated_v2'),
          'true',
        );
      },
    );

    test('re-running migration is a no-op', () async {
      final db = createTestDatabase();
      addTearDown(db.close);
      final dao = SettingsDao(db);
      final secure = InMemorySecureKeyValueStore();
      final store = SecretsStore(secure);

      // Manually set the flag and seed a secret. Second-run should NOT
      // touch the keyring.
      await dao.setSetting('notification_secrets_migrated_v2', 'true');
      await dao.setSetting(
        'notification_transport_email',
        jsonEncode({
          'smtpHost': 'smtp.example.com',
          'smtpPort': 587,
          'username': '',
          'password': 'should-not-be-migrated',
          'useTls': true,
          'fromAddress': '',
          'toAddress': '',
        }),
      );

      final migrated = await store.migrateFromPlaintext(dao);
      expect(migrated, isFalse);
      expect(await store.read(SecretField.emailPassword), '');
      // Blob still has plaintext (because we didn't migrate).
      final blob = jsonDecode(
        await dao.getSetting('notification_transport_email') as String,
      );
      expect(blob['password'], 'should-not-be-migrated');
    });

    test(
      'malformed JSON remains retryable and is never marked migrated',
      () async {
        final db = createTestDatabase();
        addTearDown(db.close);
        final dao = SettingsDao(db);
        final secure = InMemorySecureKeyValueStore();
        final store = SecretsStore(secure);

        // Only one blob, and it's malformed.
        await dao.setSetting('notification_transport_email', '{not json');

        final migrated = await store.migrateFromPlaintext(dao);
        expect(migrated, isFalse);
        // No secret got written (malformed JSON was skipped).
        expect(await store.read(SecretField.emailPassword), '');
        expect(
          await dao.getSetting('notification_secrets_migrated_v2'),
          isNull,
        );

        // Once repaired, the next launch can complete the migration.
        await dao.setSetting(
          'notification_transport_email',
          jsonEncode({'password': 'recovered-secret'}),
        );
        expect(await store.migrateFromPlaintext(dao), isTrue);
        expect(await store.read(SecretField.emailPassword), 'recovered-secret');
        expect(
          await dao.getSetting('notification_secrets_migrated_v2'),
          'true',
        );
      },
    );

    test('absent blob does not crash migration', () async {
      final db = createTestDatabase();
      addTearDown(db.close);
      final dao = SettingsDao(db);
      final secure = InMemorySecureKeyValueStore();
      final store = SecretsStore(secure);

      // No transport blobs at all.
      final migrated = await store.migrateFromPlaintext(dao);
      expect(migrated, isTrue);
      expect(await dao.getSetting('notification_secrets_migrated_v2'), 'true');
    });
  });
}
