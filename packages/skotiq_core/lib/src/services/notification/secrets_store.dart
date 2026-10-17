// Secure storage for notification transport secrets.
//
// Why split storage:
//   * Non-secret fields (SMTP host, port, from address, MQTT broker,
//     Discord webhook URL host, etc.) live in the existing
//     `app_settings` key-value table as JSON. Keeping them there
//     preserves the export/import / backup story the user already has.
//   * Secret fields (SMTP password, Pushover api_token + user_key,
//     Telegram bot_token, Discord webhook URL — yes the URL itself is
//     a bearer-token, MQTT password) live in the platform keyring via
//     `flutter_secure_storage` — Keychain on macOS/iOS, Credential
//     Manager on Windows, libsecret on Linux, EncryptedSharedPreferences
//     on Android.
//
// Migration: on first run after this change, the legacy plaintext
// blobs (which stored the secret inside the JSON) are split:
//   1. The secret is moved into the secure store under a stable key.
//   2. The blob is rewritten without the secret field.
// Migration is one-shot, driven by [migrateFromPlaintext]. The function
// is idempotent: rerunning it after a successful migration is a no-op.
//
// Test surface: [SecretsStore] takes a [FlutterSecureStorage] in its
// constructor so unit tests can inject an in-memory fake (the
// FlutterSecureStorage class exposes its own mocking story via static
// `setMockInitialValues`).

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../database/daos/settings_dao.dart';
import '../../models/notification/notification_categories.dart';

/// Stable key prefix inside the secure store. Versioned so a future
/// breaking change (e.g. encrypting per-field) can migrate again.
const String _secretsKeyPrefix = 'ns.notif.v1.';

/// Sentinel value written to `app_settings` once the one-shot migration
/// has completed. Presence of this flag short-circuits subsequent
/// migration attempts.
// v2 adds generic-webhook URLs and authorization headers. It intentionally
// does not honor the old v1 flag: all v1 migrations are idempotent, while
// honoring it would leave newly-classified webhook secrets in plaintext for
// existing users.
const String _migrationFlagKey = 'notification_secrets_migrated_v2';

/// Logical secret fields the store owns. Each one is a stable string
/// the UI / providers reference (vs. coupling to enum names that might
/// be reordered).
abstract class SecretField {
  static const String emailPassword = 'email.password';
  static const String pushoverApiToken = 'pushover.api_token';
  static const String pushoverUserKey = 'pushover.user_key';
  static const String telegramBotToken = 'telegram.bot_token';
  static const String discordWebhookUrl = 'discord.webhook_url';
  static const String genericWebhookUrl = 'webhook.url';
  static const String genericWebhookHeaders = 'webhook.headers_json';
  static const String mqttPassword = 'mqtt.password';

  /// Cloud backup/sync — WebDAV password for the configured sync target
  /// (see `services/sync/sync_service.dart`). Lives here so it rides the
  /// same keyring-backed store as the other transport secrets.
  static const String cloudSyncPassword = 'sync.webdav_password';

  /// Cloud backup/sync — S3 secret key for an S3-compatible sync target
  /// (AWS / MinIO / Backblaze B2; see `services/sync/sync_service.dart`).
  /// The S3 secret key is a credential and MUST live here in the keyring,
  /// never in `app_settings` (which rides export/backup) — exactly like
  /// the WebDAV password. The S3 access key is non-secret and lives in
  /// `app_settings` alongside the WebDAV username.
  static const String cloudSyncS3SecretKey = 'sync.s3_secret_key';

  /// TNS (Transient Name Server) bot API key used by both alert ingestion and
  /// the First Light submission path to authenticate TNS API calls.
  ///
  /// This is the SUBMISSION key and MUST live in the keyring, never in
  /// `app_settings`/science settings (those are plaintext and ride
  /// export/backup). `TransientAlertSettings.tnsApiKey` is populated only as an
  /// in-memory request snapshot from this keyring value and is never persisted.
  static const String tnsApiKey = 'tns.api_key';
}

/// Minimal interface for the backing secure-storage implementation.
///
/// `flutter_secure_storage` doesn't expose an abstract class we can mock
/// directly (it's a concrete class with platform channels). Wrapping it
/// behind [SecureKeyValueStore] lets tests inject a deterministic
/// in-memory fake without spinning up a method-channel.
abstract class SecureKeyValueStore {
  Future<String?> read({required String key});
  Future<void> write({required String key, required String value});
  Future<void> delete({required String key});
}

/// Production-only adapter that delegates to flutter_secure_storage.
class _PlatformSecureStore implements SecureKeyValueStore {
  final FlutterSecureStorage _inner;
  const _PlatformSecureStore(this._inner);

  @override
  Future<String?> read({required String key}) => _inner.read(key: key);

  @override
  Future<void> write({required String key, required String value}) =>
      _inner.write(key: key, value: value);

  @override
  Future<void> delete({required String key}) => _inner.delete(key: key);
}

/// In-memory fake [SecureKeyValueStore]. Public so tests outside this
/// package can use it (widget tests in skotiq_app).
class InMemorySecureKeyValueStore implements SecureKeyValueStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read({required String key}) async => values[key];

  @override
  Future<void> write({required String key, required String value}) async {
    values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }
}

/// Thin wrapper over flutter_secure_storage that
/// scopes every key to the notification subsystem and provides typed
/// read/write per field plus a one-shot migration from plaintext.
class SecretsStore {
  final SecureKeyValueStore _store;

  /// Construct with a custom backing store — tests should pass an
  /// [InMemorySecureKeyValueStore]. Production callers should use
  /// [SecretsStore.platformDefault].
  SecretsStore(this._store);

  /// Production constructor with OS-recommended defaults per platform.
  factory SecretsStore.platformDefault() {
    return SecretsStore(
      const _PlatformSecureStore(
        FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true),
          iOptions: IOSOptions(
            accessibility: KeychainAccessibility.first_unlock_this_device,
          ),
        ),
      ),
    );
  }

  String _keyFor(String field) => '$_secretsKeyPrefix$field';

  /// Read a single secret. Returns an empty string when not present so
  /// callers that rebuild typed configs from the store don't need to
  /// fork for the "first run" case.
  Future<String> read(String field) async {
    try {
      final v = await _store.read(key: _keyFor(field));
      return v ?? '';
    } catch (e) {
      developer.log(
        '[SecretsStore] read($field) failed: $e',
        name: 'SecretsStore',
        level: 900,
        error: e,
      );
      // An unavailable keyring is not the same thing as an absent secret.
      // Propagate the failure so config providers fail closed and the UI can
      // offer Retry instead of publishing a manufactured empty credential.
      rethrow;
    }
  }

  /// Write a secret. Empty string deletes the key — we don't want to
  /// keep an empty entry rattling around in the keyring.
  Future<void> write(String field, String value) async {
    final key = _keyFor(field);
    try {
      if (value.isEmpty) {
        await _store.delete(key: key);
      } else {
        await _store.write(key: key, value: value);
      }
    } catch (e) {
      // Errors writing to the secure store are NOT swallowed silently.
      // Re-throwing so the UI surface (Save button) reports the failure.
      developer.log(
        '[SecretsStore] write($field) failed: $e',
        name: 'SecretsStore',
        level: 1000,
        error: e,
      );
      rethrow;
    }
  }

  /// Delete a single secret.
  Future<void> delete(String field) async {
    try {
      await _store.delete(key: _keyFor(field));
    } catch (e) {
      developer.log(
        '[SecretsStore] delete($field) failed: $e',
        name: 'SecretsStore',
        level: 900,
        error: e,
      );
      rethrow;
    }
  }

  /// Convenience: did the user already enter a value? UI uses this to
  /// show the "•••••••• (stored securely)" placeholder vs the empty
  /// hint.
  Future<bool> has(String field) async {
    final v = await read(field);
    return v.isNotEmpty;
  }

  /// One-shot migration of plaintext secrets that pre-date this change.
  ///
  /// The contract:
  ///   * Read each transport's blob from [dao].
  ///   * If a secret field is non-empty, copy it into the secure store
  ///     and clear it from the blob.
  ///   * Re-write the cleaned blob.
  ///   * Set the migration flag so subsequent calls short-circuit.
  ///
  /// Idempotent: if the flag is already set, returns immediately.
  /// Best-effort: if a single transport's blob is malformed, the
  /// migration continues for the others rather than aborting whole.
  Future<bool> migrateFromPlaintext(SettingsDao dao) async {
    final flag = await dao.getSetting(_migrationFlagKey);
    if (flag == 'true') return false; // already migrated

    // Migrate each transport in turn. Each call writes the cleaned blob
    // back, so a crash midway leaves the database in a consistent state
    // (the half that migrated is gone, the half that didn't is still
    // there — both halves still functional).
    var complete = await _migrateWebhookBlob(dao);
    complete =
        await _migrateBlob(
          dao,
          transportKey:
              'notification_transport_${NotificationTransportKind.email.storageKey}',
          secretFields: const {'password': SecretField.emailPassword},
        ) &&
        complete;
    complete =
        await _migrateBlob(
          dao,
          transportKey:
              'notification_transport_${NotificationTransportKind.pushover.storageKey}',
          secretFields: const {
            'apiToken': SecretField.pushoverApiToken,
            'userKey': SecretField.pushoverUserKey,
          },
        ) &&
        complete;
    complete =
        await _migrateBlob(
          dao,
          transportKey:
              'notification_transport_${NotificationTransportKind.telegram.storageKey}',
          secretFields: const {'botToken': SecretField.telegramBotToken},
        ) &&
        complete;
    complete =
        await _migrateBlob(
          dao,
          transportKey:
              'notification_transport_${NotificationTransportKind.discord.storageKey}',
          secretFields: const {'webhookUrl': SecretField.discordWebhookUrl},
        ) &&
        complete;
    complete =
        await _migrateBlob(
          dao,
          transportKey:
              'notification_transport_${NotificationTransportKind.mqtt.storageKey}',
          secretFields: const {'password': SecretField.mqttPassword},
        ) &&
        complete;

    // A malformed blob may still contain a plaintext credential. Marking the
    // one-shot migration complete in that state would strand the credential
    // forever. Successfully cleaned blobs are idempotent, so retrying all of
    // them after the malformed blob is repaired is safe.
    if (complete) {
      await dao.setSetting(_migrationFlagKey, 'true');
    }
    return complete;
  }

  Future<bool> _migrateBlob(
    SettingsDao dao, {
    required String transportKey,
    required Map<String, String> secretFields,
  }) async {
    final raw = await dao.getSetting(transportKey);
    if (raw == null) return true;

    Map<String, dynamic> blob;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return false;
      blob = Map<String, dynamic>.from(decoded);
    } catch (e) {
      developer.log(
        '[SecretsStore] Skipping migration of $transportKey: bad JSON ($e)',
        name: 'SecretsStore',
        level: 900,
      );
      return false;
    }

    var changed = false;
    for (final entry in secretFields.entries) {
      final blobField = entry.key;
      final secretField = entry.value;
      final value = blob[blobField];
      if (value is String && value.isNotEmpty) {
        await write(secretField, value);
        blob[blobField] = '';
        changed = true;
      }
    }

    if (changed) {
      await dao.setSetting(transportKey, jsonEncode(blob));
      developer.log(
        '[SecretsStore] Migrated secrets out of $transportKey',
        name: 'SecretsStore',
        level: 800,
      );
    }
    return true;
  }

  Future<bool> _migrateWebhookBlob(SettingsDao dao) async {
    const transportKey = 'notification_transport_webhookGeneric';
    final raw = await dao.getSetting(transportKey);
    if (raw == null) return true;

    Map<String, dynamic> blob;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return false;
      blob = Map<String, dynamic>.from(decoded);
    } catch (error) {
      developer.log(
        '[SecretsStore] Skipping migration of $transportKey: bad JSON '
        '($error)',
        name: 'SecretsStore',
        level: 900,
      );
      return false;
    }

    var changed = false;
    final url = blob['url'];
    if (url is String && url.isNotEmpty) {
      await write(SecretField.genericWebhookUrl, url);
      blob['url'] = '';
      changed = true;
    } else if (url != null && url is! String) {
      return false;
    }

    final rawHeaders = blob['headers'];
    if (rawHeaders != null) {
      if (rawHeaders is! Map) return false;
      final headers = <String, String>{};
      for (final entry in rawHeaders.entries) {
        if (entry.key is! String || entry.value is! String) return false;
        headers[entry.key as String] = entry.value as String;
      }
      if (headers.isNotEmpty) {
        await write(SecretField.genericWebhookHeaders, jsonEncode(headers));
        blob['headers'] = <String, String>{};
        changed = true;
      }
    }

    if (changed) {
      await dao.setSetting(transportKey, jsonEncode(blob));
      developer.log(
        '[SecretsStore] Migrated secrets out of $transportKey',
        name: 'SecretsStore',
        level: 800,
      );
    }
    return true;
  }
}
