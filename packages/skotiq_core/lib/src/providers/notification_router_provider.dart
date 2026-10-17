// Riverpod wiring for the NotificationRouter.
//
// Storage layout:
//   * Non-secret config (host, port, from-address, etc.) → key-value
//     `SettingsDao` blob per transport.
//   * Secret config (passwords, tokens, webhook URLs, user-keys) →
//     `flutter_secure_storage` via [SecretsStore].
//
// Key-value DAO entries:
//   * `notification_routing_matrix`       -> NotificationRoutingMatrix.toJson()
//   * `notification_transport_email`      -> EmailTransportConfig.toJson() (no password)
//   * `notification_transport_webhook`    -> WebhookTransportConfig.toJson()
//                                            (no URL/auth headers)
//   * `notification_transport_pushover`   -> PushoverTransportConfig.toJson() (no tokens)
//   * `notification_transport_telegram`   -> TelegramTransportConfig.toJson() (no bot token)
//   * `notification_transport_discord`    -> DiscordTransportConfig.toJson() (no webhook URL)
//   * `notification_transport_mqtt`       -> MqttTransportConfig.toJson() (no password)
//   * `notification_secrets_migrated_v2`  -> 'true' once one-shot migration done.
//
// We deliberately keep one key per transport so a corrupt blob in one
// (say, the user pasted invalid JSON into a webhook header field) only
// disables that one transport rather than the whole routing system.

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/network_backend.dart';
import '../database/daos/settings_dao.dart';
import '../models/notification/notification_categories.dart';
import '../models/notification/transport_configs.dart';
import '../services/notification/notification_router.dart';
import '../services/notification/secrets_store.dart';
import '../services/notification/transports/discord_transport.dart';
import '../services/notification/transports/email_transport.dart';
import '../services/notification/transports/in_app_transport.dart';
import '../services/notification/transports/mqtt_transport.dart';
import '../services/notification/transports/notification_transport.dart';
import '../services/notification/transports/pushover_transport.dart';
import '../services/notification/transports/system_push_transport.dart';
import '../services/notification/transports/telegram_transport.dart';
import '../services/notification/transports/webhook_transport.dart';
import 'backend_provider.dart';
import 'database_provider.dart';
import 'push_notification_provider.dart';
import 'ui_notification_provider.dart';

const String _kRoutingMatrixSettingKey = 'notification_routing_matrix';

String _transportSettingKey(NotificationTransportKind kind) =>
    'notification_transport_${kind.storageKey}';

/// Serializes persistence operations while still returning an independent
/// future to each caller. Notification settings are edited from several
/// controls on the same screen; without a queue, two rapid read-modify-write
/// operations can both start from the same snapshot and silently lose one
/// of the user's changes.
mixin _SerializedAsyncWrites<T> on AsyncNotifier<T> {
  Future<void> _writeTail = Future<void>.value();

  Future<R> serializeWrite<R>(Future<R> Function() operation) {
    final completer = Completer<R>();
    _writeTail = _writeTail.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  /// Post-write identity guard shared by every transport save. If the active
  /// [SettingsDao] — or, where secrets are used, the active [SecretsStore] —
  /// changed identity while the awaited persistence ran (e.g. the container
  /// was reconfigured mid-save), the value just written landed in a
  /// now-detached store and is not published as the live config.
  /// Mirrors the identity checks already guarding push-config and
  /// routing-matrix persistence. It does not roll writes back (secure storage
  /// and SQLite cannot share a transaction); [_persistConfigWithSecrets] keeps
  /// the secret-rollback semantics for the ordinary write-failure path.
  void _verifyPersistenceIdentity({
    required SettingsDao dao,
    SecretsStore? secrets,
    required String transport,
  }) {
    final daoChanged = !identical(ref.read(settingsDaoProvider), dao);
    final secretsChanged =
        secrets != null && !identical(ref.read(secretsStoreProvider), secrets);
    if (daoChanged || secretsChanged) {
      throw StateError(
        'The settings store changed while saving $transport routing; the '
        'entered values were not published as the live config.',
      );
    }
  }
}

/// Persist a config whose credentials live in the OS keyring.
///
/// Secure storage and SQLite cannot share a transaction. Snapshotting and
/// restoring the prior credentials gives the operation transactional
/// semantics from the user's perspective when the ordinary config write
/// fails after a keyring write has succeeded.
Future<void> _persistConfigWithSecrets({
  required SettingsDao dao,
  required SecretsStore secrets,
  required String settingKey,
  required String encodedConfig,
  required Map<String, String> secretValues,
}) async {
  final previousValues = <String, String>{};
  for (final field in secretValues.keys) {
    previousValues[field] = await secrets.read(field);
  }

  final writtenFields = <String>[];
  try {
    for (final entry in secretValues.entries) {
      await secrets.write(entry.key, entry.value);
      writtenFields.add(entry.key);
    }
    await dao.setSetting(settingKey, encodedConfig);
  } catch (error, stackTrace) {
    for (final field in writtenFields.reversed) {
      try {
        await secrets.write(field, previousValues[field] ?? '');
      } catch (rollbackError) {
        developer.log(
          '[NotificationProviders] Could not roll back $field after a '
          'config save failed: $rollbackError',
          name: 'NotificationProviders',
          level: 1000,
          error: rollbackError,
        );
      }
    }
    Error.throwWithStackTrace(error, stackTrace);
  }
}

// Secrets store provider

/// Overridable provider for the platform secrets store. Production
/// (apps/desktop, apps/mobile) uses [SecretsStore.platformDefault]; tests
/// override this with a fake backing store.
final secretsStoreProvider = Provider<SecretsStore>((ref) {
  return SecretsStore.platformDefault();
});

/// One-shot migration: moves plaintext secrets out of `app_settings`
/// blobs and into the secure store. Runs on first `notificationRouter`
/// build and is idempotent. Exposed as a provider so the app shell can
/// `ref.read` it during startup if it wants to surface migration
/// progress / errors.
final notificationSecretsMigrationProvider = FutureProvider<bool>((ref) async {
  final dao = ref.read(settingsDaoProvider);
  final store = ref.read(secretsStoreProvider);
  return store.migrateFromPlaintext(dao);
});

// Per-transport config notifiers

class EmailConfigNotifier extends AsyncNotifier<EmailTransportConfig>
    with _SerializedAsyncWrites<EmailTransportConfig> {
  @override
  Future<EmailTransportConfig> build() async {
    // Trigger one-shot migration before reading any blob — if a legacy
    // plaintext blob still has the password in it, we want it moved
    // before we hand the config back to anyone.
    await ref.read(notificationSecretsMigrationProvider.future);

    final dao = ref.read(settingsDaoProvider);
    final secrets = ref.read(secretsStoreProvider);
    final raw = await dao.getSetting(
      _transportSettingKey(NotificationTransportKind.email),
    );
    // A missing blob is a legitimate first-run default; a present-but-corrupt
    // blob must surface as an error rather than silently reverting to defaults
    // (which would hide the corruption and could re-activate an unconfigured
    // transport). Missing keys still fall back to backwards-compatible field
    // defaults inside fromJson.
    final EmailTransportConfig base = raw == null
        ? const EmailTransportConfig()
        : _decodeEmail(raw);
    final password = await secrets.read(SecretField.emailPassword);
    return base.copyWith(password: password);
  }

  EmailTransportConfig _decodeEmail(String raw) {
    try {
      return EmailTransportConfig.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (e, stackTrace) {
      developer.log(
        '[NotificationProviders] Bad email config: $e',
        name: 'NotificationProviders',
        level: 1000,
        error: e,
        stackTrace: stackTrace,
      );
      Error.throwWithStackTrace(
        StateError('Email routing configuration is corrupt: $e'),
        stackTrace,
      );
    }
  }

  Future<void> save(EmailTransportConfig config) async {
    return serializeWrite(() async {
      if (state.valueOrNull == null) {
        throw StateError(
          'Email routing config is not loaded; refusing to overwrite it '
          'with the entered values.',
        );
      }
      final dao = ref.read(settingsDaoProvider);
      final secrets = ref.read(secretsStoreProvider);
      final nonSecret = config.copyWith(password: '');
      await _persistConfigWithSecrets(
        dao: dao,
        secrets: secrets,
        settingKey: _transportSettingKey(NotificationTransportKind.email),
        encodedConfig: jsonEncode(nonSecret.toJson()),
        secretValues: {SecretField.emailPassword: config.password},
      );
      _verifyPersistenceIdentity(
        dao: dao,
        secrets: secrets,
        transport: 'email',
      );
      state = AsyncData(config);
    });
  }
}

class WebhookConfigNotifier extends AsyncNotifier<WebhookTransportConfig>
    with _SerializedAsyncWrites<WebhookTransportConfig> {
  @override
  Future<WebhookTransportConfig> build() async {
    await ref.read(notificationSecretsMigrationProvider.future);
    final dao = ref.read(settingsDaoProvider);
    final secrets = ref.read(secretsStoreProvider);
    final raw = await dao.getSetting(
      _transportSettingKey(NotificationTransportKind.webhookGeneric),
    );
    // Missing blob → first-run default; corrupt blob → surface the error.
    final WebhookTransportConfig base;
    if (raw == null) {
      base = const WebhookTransportConfig();
    } else {
      base = _decodeWebhook(raw);
    }
    final url = await secrets.read(SecretField.genericWebhookUrl);
    final encodedHeaders = await secrets.read(
      SecretField.genericWebhookHeaders,
    );
    final headers = encodedHeaders.isEmpty
        ? const <String, String>{}
        : _decodeWebhookHeaders(encodedHeaders);
    // Re-decode the stitched config so a malformed URL in secure storage is
    // treated as corruption just like a malformed non-secret field.
    return WebhookTransportConfig.fromJson({
      ...base.toJson(),
      'url': url,
      'headers': headers,
    });
  }

  WebhookTransportConfig _decodeWebhook(String raw) {
    try {
      return WebhookTransportConfig.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (e, stackTrace) {
      developer.log(
        '[NotificationProviders] Bad webhook config: $e',
        name: 'NotificationProviders',
        level: 1000,
        error: e,
        stackTrace: stackTrace,
      );
      Error.throwWithStackTrace(
        StateError('Webhook routing configuration is corrupt: $e'),
        stackTrace,
      );
    }
  }

  Map<String, String> _decodeWebhookHeaders(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('webhook headers must be an object');
      }
      final headers = <String, String>{};
      for (final entry in decoded.entries) {
        if (entry.key is! String || entry.value is! String) {
          throw const FormatException(
            'webhook header names and values must be strings',
          );
        }
        headers[entry.key as String] = entry.value as String;
      }
      return headers;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        StateError('Webhook routing credentials are corrupt: $error'),
        stackTrace,
      );
    }
  }

  Future<void> save(WebhookTransportConfig config) async {
    return serializeWrite(() async {
      if (state.valueOrNull == null) {
        throw StateError(
          'Webhook routing config is not loaded; refusing to overwrite it '
          'with the entered values.',
        );
      }
      final dao = ref.read(settingsDaoProvider);
      final secrets = ref.read(secretsStoreProvider);
      final nonSecret = config.copyWith(url: '', headers: const {});
      await _persistConfigWithSecrets(
        dao: dao,
        secrets: secrets,
        settingKey: _transportSettingKey(
          NotificationTransportKind.webhookGeneric,
        ),
        encodedConfig: jsonEncode(nonSecret.toJson()),
        secretValues: {
          SecretField.genericWebhookUrl: config.url,
          SecretField.genericWebhookHeaders: config.headers.isEmpty
              ? ''
              : jsonEncode(config.headers),
        },
      );
      _verifyPersistenceIdentity(
        dao: dao,
        secrets: secrets,
        transport: 'webhook',
      );
      state = AsyncData(config);
    });
  }
}

class PushoverConfigNotifier extends AsyncNotifier<PushoverTransportConfig>
    with _SerializedAsyncWrites<PushoverTransportConfig> {
  @override
  Future<PushoverTransportConfig> build() async {
    await ref.read(notificationSecretsMigrationProvider.future);
    final dao = ref.read(settingsDaoProvider);
    final secrets = ref.read(secretsStoreProvider);
    final raw = await dao.getSetting(
      _transportSettingKey(NotificationTransportKind.pushover),
    );
    final PushoverTransportConfig base = raw == null
        ? const PushoverTransportConfig()
        : _decodePushover(raw);
    final apiToken = await secrets.read(SecretField.pushoverApiToken);
    final userKey = await secrets.read(SecretField.pushoverUserKey);
    return base.copyWith(apiToken: apiToken, userKey: userKey);
  }

  PushoverTransportConfig _decodePushover(String raw) {
    try {
      return PushoverTransportConfig.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (e, stackTrace) {
      developer.log(
        '[NotificationProviders] Bad pushover config: $e',
        name: 'NotificationProviders',
        level: 1000,
        error: e,
        stackTrace: stackTrace,
      );
      Error.throwWithStackTrace(
        StateError('Pushover routing configuration is corrupt: $e'),
        stackTrace,
      );
    }
  }

  Future<void> save(PushoverTransportConfig config) async {
    return serializeWrite(() async {
      if (state.valueOrNull == null) {
        throw StateError(
          'Pushover routing config is not loaded; refusing to overwrite it '
          'with the entered values.',
        );
      }
      final dao = ref.read(settingsDaoProvider);
      final secrets = ref.read(secretsStoreProvider);
      final nonSecret = config.copyWith(apiToken: '', userKey: '');
      await _persistConfigWithSecrets(
        dao: dao,
        secrets: secrets,
        settingKey: _transportSettingKey(NotificationTransportKind.pushover),
        encodedConfig: jsonEncode(nonSecret.toJson()),
        secretValues: {
          SecretField.pushoverApiToken: config.apiToken,
          SecretField.pushoverUserKey: config.userKey,
        },
      );
      _verifyPersistenceIdentity(
        dao: dao,
        secrets: secrets,
        transport: 'Pushover',
      );
      state = AsyncData(config);
    });
  }
}

class TelegramConfigNotifier extends AsyncNotifier<TelegramTransportConfig>
    with _SerializedAsyncWrites<TelegramTransportConfig> {
  @override
  Future<TelegramTransportConfig> build() async {
    await ref.read(notificationSecretsMigrationProvider.future);
    final dao = ref.read(settingsDaoProvider);
    final secrets = ref.read(secretsStoreProvider);
    final raw = await dao.getSetting(
      _transportSettingKey(NotificationTransportKind.telegram),
    );
    final TelegramTransportConfig base = raw == null
        ? const TelegramTransportConfig()
        : _decodeTelegram(raw);
    final botToken = await secrets.read(SecretField.telegramBotToken);
    return base.copyWith(botToken: botToken);
  }

  TelegramTransportConfig _decodeTelegram(String raw) {
    try {
      return TelegramTransportConfig.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (e, stackTrace) {
      developer.log(
        '[NotificationProviders] Bad telegram config: $e',
        name: 'NotificationProviders',
        level: 1000,
        error: e,
        stackTrace: stackTrace,
      );
      Error.throwWithStackTrace(
        StateError('Telegram routing configuration is corrupt: $e'),
        stackTrace,
      );
    }
  }

  Future<void> save(TelegramTransportConfig config) async {
    return serializeWrite(() async {
      if (state.valueOrNull == null) {
        throw StateError(
          'Telegram routing config is not loaded; refusing to overwrite it '
          'with the entered values.',
        );
      }
      final dao = ref.read(settingsDaoProvider);
      final secrets = ref.read(secretsStoreProvider);
      final nonSecret = config.copyWith(botToken: '');
      await _persistConfigWithSecrets(
        dao: dao,
        secrets: secrets,
        settingKey: _transportSettingKey(NotificationTransportKind.telegram),
        encodedConfig: jsonEncode(nonSecret.toJson()),
        secretValues: {SecretField.telegramBotToken: config.botToken},
      );
      _verifyPersistenceIdentity(
        dao: dao,
        secrets: secrets,
        transport: 'Telegram',
      );
      state = AsyncData(config);
    });
  }
}

class DiscordConfigNotifier extends AsyncNotifier<DiscordTransportConfig>
    with _SerializedAsyncWrites<DiscordTransportConfig> {
  @override
  Future<DiscordTransportConfig> build() async {
    await ref.read(notificationSecretsMigrationProvider.future);
    final dao = ref.read(settingsDaoProvider);
    final secrets = ref.read(secretsStoreProvider);
    final raw = await dao.getSetting(
      _transportSettingKey(NotificationTransportKind.discord),
    );
    final DiscordTransportConfig base = raw == null
        ? const DiscordTransportConfig()
        : _decodeDiscord(raw);
    final webhookUrl = await secrets.read(SecretField.discordWebhookUrl);
    return DiscordTransportConfig.fromJson({
      ...base.toJson(),
      'webhookUrl': webhookUrl,
    });
  }

  DiscordTransportConfig _decodeDiscord(String raw) {
    try {
      return DiscordTransportConfig.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (e, stackTrace) {
      developer.log(
        '[NotificationProviders] Bad discord config: $e',
        name: 'NotificationProviders',
        level: 1000,
        error: e,
        stackTrace: stackTrace,
      );
      Error.throwWithStackTrace(
        StateError('Discord routing configuration is corrupt: $e'),
        stackTrace,
      );
    }
  }

  Future<void> save(DiscordTransportConfig config) async {
    return serializeWrite(() async {
      if (state.valueOrNull == null) {
        throw StateError(
          'Discord routing config is not loaded; refusing to overwrite it '
          'with the entered values.',
        );
      }
      final dao = ref.read(settingsDaoProvider);
      final secrets = ref.read(secretsStoreProvider);
      final nonSecret = config.copyWith(webhookUrl: '');
      await _persistConfigWithSecrets(
        dao: dao,
        secrets: secrets,
        settingKey: _transportSettingKey(NotificationTransportKind.discord),
        encodedConfig: jsonEncode(nonSecret.toJson()),
        secretValues: {SecretField.discordWebhookUrl: config.webhookUrl},
      );
      _verifyPersistenceIdentity(
        dao: dao,
        secrets: secrets,
        transport: 'Discord',
      );
      state = AsyncData(config);
    });
  }
}

class MqttConfigNotifier extends AsyncNotifier<MqttTransportConfig>
    with _SerializedAsyncWrites<MqttTransportConfig> {
  @override
  Future<MqttTransportConfig> build() async {
    await ref.read(notificationSecretsMigrationProvider.future);
    final dao = ref.read(settingsDaoProvider);
    final secrets = ref.read(secretsStoreProvider);
    final raw = await dao.getSetting(
      _transportSettingKey(NotificationTransportKind.mqtt),
    );
    final MqttTransportConfig base = raw == null
        ? const MqttTransportConfig()
        : _decodeMqtt(raw);
    final password = await secrets.read(SecretField.mqttPassword);
    return base.copyWith(password: password.isEmpty ? null : password);
  }

  MqttTransportConfig _decodeMqtt(String raw) {
    try {
      return MqttTransportConfig.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (e, stackTrace) {
      developer.log(
        '[NotificationProviders] Bad mqtt config: $e',
        name: 'NotificationProviders',
        level: 1000,
        error: e,
        stackTrace: stackTrace,
      );
      Error.throwWithStackTrace(
        StateError('MQTT routing configuration is corrupt: $e'),
        stackTrace,
      );
    }
  }

  Future<void> save(MqttTransportConfig config) async {
    return serializeWrite(() async {
      if (state.valueOrNull == null) {
        throw StateError(
          'MQTT routing config is not loaded; refusing to overwrite it '
          'with the entered values.',
        );
      }
      final dao = ref.read(settingsDaoProvider);
      final secrets = ref.read(secretsStoreProvider);
      final nonSecret = config.copyWith(clearPassword: true);
      await _persistConfigWithSecrets(
        dao: dao,
        secrets: secrets,
        settingKey: _transportSettingKey(NotificationTransportKind.mqtt),
        encodedConfig: jsonEncode(nonSecret.toJson()),
        secretValues: {SecretField.mqttPassword: config.password ?? ''},
      );
      _verifyPersistenceIdentity(dao: dao, secrets: secrets, transport: 'MQTT');
      state = AsyncData(config);
    });
  }
}

class RoutingMatrixNotifier extends AsyncNotifier<NotificationRoutingMatrix>
    with _SerializedAsyncWrites<NotificationRoutingMatrix> {
  @override
  Future<NotificationRoutingMatrix> build() async {
    final dao = ref.read(settingsDaoProvider);
    final raw = await dao.getSetting(_kRoutingMatrixSettingKey);
    if (raw == null) return NotificationRoutingMatrix.defaults();
    try {
      return NotificationRoutingMatrix.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (e, stackTrace) {
      developer.log(
        '[NotificationProviders] Bad routing matrix: $e',
        name: 'NotificationProviders',
        level: 1000,
        error: e,
        stackTrace: stackTrace,
      );
      Error.throwWithStackTrace(
        StateError('Notification routing matrix is corrupt: $e'),
        stackTrace,
      );
    }
  }

  Future<void> save(NotificationRoutingMatrix matrix) async {
    return serializeWrite(() => _persist(matrix));
  }

  Future<void> _persist(NotificationRoutingMatrix matrix) async {
    final dao = ref.read(settingsDaoProvider);
    await dao.setSetting(
      _kRoutingMatrixSettingKey,
      jsonEncode(matrix.toJson()),
    );
    if (!identical(ref.read(settingsDaoProvider), dao)) {
      throw StateError(
        'The settings database changed while saving notification routing.',
      );
    }
    state = AsyncData(matrix);
  }

  Future<void> setEnabled(bool enabled) async {
    return serializeWrite(() async {
      final current = state.valueOrNull;
      if (current == null) {
        throw StateError(
          'Notification routing is not loaded; refusing to overwrite it '
          'with defaults.',
        );
      }
      await _persist(current.copyWith(enabled: enabled));
    });
  }

  Future<void> setRule(
    NotificationCategory category,
    NotificationRoutingRule rule,
  ) async {
    return serializeWrite(() async {
      final current = state.valueOrNull;
      if (current == null) {
        throw StateError(
          'Notification routing is not loaded; refusing to overwrite it '
          'with defaults.',
        );
      }
      await _persist(current.withRule(category, rule));
    });
  }
}

// Public providers

final emailTransportConfigProvider =
    AsyncNotifierProvider<EmailConfigNotifier, EmailTransportConfig>(
      EmailConfigNotifier.new,
    );

final webhookTransportConfigProvider =
    AsyncNotifierProvider<WebhookConfigNotifier, WebhookTransportConfig>(
      WebhookConfigNotifier.new,
    );

final pushoverTransportConfigProvider =
    AsyncNotifierProvider<PushoverConfigNotifier, PushoverTransportConfig>(
      PushoverConfigNotifier.new,
    );

final telegramTransportConfigProvider =
    AsyncNotifierProvider<TelegramConfigNotifier, TelegramTransportConfig>(
      TelegramConfigNotifier.new,
    );

final discordTransportConfigProvider =
    AsyncNotifierProvider<DiscordConfigNotifier, DiscordTransportConfig>(
      DiscordConfigNotifier.new,
    );

final mqttTransportConfigProvider =
    AsyncNotifierProvider<MqttConfigNotifier, MqttTransportConfig>(
      MqttConfigNotifier.new,
    );

final notificationRoutingMatrixProvider =
    AsyncNotifierProvider<RoutingMatrixNotifier, NotificationRoutingMatrix>(
      RoutingMatrixNotifier.new,
    );

/// The NotificationRouter singleton.
///
/// Rebuilds when the backend changes (so it re-attaches to the new
/// event stream). Config changes from individual transport providers
/// are forwarded in-place via `updateConfig` to avoid tearing the
/// router down for every setting toggle.
final notificationRouterProvider = Provider<NotificationRouter>((ref) {
  final backend = ref.watch(diagnosticsBackendProvider);
  final uiNotifier = ref.read(uiNotificationProvider.notifier);

  // Routing credentials and delivery are host-owned. A NetworkBackend mirrors
  // the host event stream into a controller device; running that stream
  // through configs from the controller's local database would make external
  // delivery depend on the phone being connected and can duplicate the host's
  // own sends. Remote controllers retain only local in-app banners until the
  // host exposes routing configuration APIs.
  if (backend is NetworkBackend) {
    final router = NotificationRouter(
      transports: [InAppTransport(uiNotifier)],
      matrix: inAppOnlyFallbackMatrix(),
    );
    router.attachEventStream(backend.eventStream);
    ref.onDispose(() => unawaited(router.dispose()));
    return router;
  }

  final pushService = ref.read(pushNotificationServiceProvider);

  // Resolve initial configs synchronously (each provider returns its
  // default value before the DB read completes). The router applies the
  // real persisted values via the listeners registered below as soon as
  // they arrive.
  final emailCfg =
      ref.read(emailTransportConfigProvider).valueOrNull ??
      const EmailTransportConfig();
  final webhookCfg =
      ref.read(webhookTransportConfigProvider).valueOrNull ??
      const WebhookTransportConfig();
  final pushoverCfg =
      ref.read(pushoverTransportConfigProvider).valueOrNull ??
      const PushoverTransportConfig();
  final telegramCfg =
      ref.read(telegramTransportConfigProvider).valueOrNull ??
      const TelegramTransportConfig();
  final discordCfg =
      ref.read(discordTransportConfigProvider).valueOrNull ??
      const DiscordTransportConfig();
  final mqttCfg =
      ref.read(mqttTransportConfigProvider).valueOrNull ??
      const MqttTransportConfig();

  final inApp = InAppTransport(uiNotifier);
  final systemPush = SystemPushTransport(pushService);
  final email = EmailTransport(config: emailCfg);
  final webhook = WebhookTransport(config: webhookCfg);
  final pushover = PushoverTransport(config: pushoverCfg);
  final telegram = TelegramTransport(config: telegramCfg);
  final discord = DiscordTransport(config: discordCfg);
  final mqtt = MqttTransport(config: mqttCfg);

  final transports = <NotificationTransport>[
    inApp,
    systemPush,
    email,
    webhook,
    pushover,
    telegram,
    discord,
    mqtt,
  ];

  // Fail-closed routing while the matrix authority is loading or errored: the
  // router stays eager (safety-critical events still surface in-app) but the
  // fallback deliberately omits systemPush and every external transport, so an
  // unavailable/corrupt matrix cannot dispatch external notifications against
  // NotificationRoutingMatrix.defaults() (which routes several categories to
  // systemPush). Seeded from authoritative data only when it is already loaded.
  final matrix =
      ref.read(notificationRoutingMatrixProvider).valueOrNull ??
      inAppOnlyFallbackMatrix();
  final router = NotificationRouter(transports: transports, matrix: matrix);
  router.attachEventStream(backend.eventStream);

  // Listen for transport-config changes and forward in-place. On provider
  // error (corrupt/unavailable config) each external transport is reset to its
  // unconfigured safe config so stale credentials can no longer send; only
  // authoritative data re-activates it.
  ref.listen(emailTransportConfigProvider, (prev, next) {
    _applyOrReset(next, email.updateConfig, const EmailTransportConfig());
  });
  ref.listen(webhookTransportConfigProvider, (prev, next) {
    _applyOrReset(next, webhook.updateConfig, const WebhookTransportConfig());
  });
  ref.listen(pushoverTransportConfigProvider, (prev, next) {
    _applyOrReset(next, pushover.updateConfig, const PushoverTransportConfig());
  });
  ref.listen(telegramTransportConfigProvider, (prev, next) {
    _applyOrReset(next, telegram.updateConfig, const TelegramTransportConfig());
  });
  ref.listen(discordTransportConfigProvider, (prev, next) {
    _applyOrReset(next, discord.updateConfig, const DiscordTransportConfig());
  });
  ref.listen(mqttTransportConfigProvider, (prev, next) {
    _applyOrReset(next, mqtt.updateConfig, const MqttTransportConfig());
  });
  ref.listen(notificationRoutingMatrixProvider, (prev, next) {
    // Update in-place on authoritative data; revert to the in-app-only
    // fallback on error so a matrix that becomes corrupt/unavailable can no
    // longer route to any external transport.
    if (next.hasError) {
      router.updateMatrix(inAppOnlyFallbackMatrix());
      return;
    }
    next.whenData(router.updateMatrix);
  });

  ref.onDispose(() {
    // Don't await — provider disposal is synchronous.
    unawaited(router.dispose());
  });

  return router;
});

/// Transport kinds that currently hold enough configuration to actually
/// deliver.
///
/// [NotificationRouter] drops any transport whose `isConfigured` is false when
/// a notification fires, so a routing rule naming an unconfigured transport
/// delivers nothing and logs nothing. The routing UI reads this so it cannot
/// promise the operator a channel that would never reach them.
final configuredNotificationTransportsProvider =
    Provider<Set<NotificationTransportKind>>((ref) {
      final configured = <NotificationTransportKind>{
        // Holds no credentials: InAppTransport.isConfigured is always true.
        NotificationTransportKind.inApp,
      };
      void addIf(NotificationTransportKind kind, bool ready) {
        if (ready) configured.add(kind);
      }

      addIf(
        NotificationTransportKind.systemPush,
        // SystemPushTransport.isConfigured mirrors the push master gate.
        ref.watch(pushNotificationConfigProvider).valueOrNull?.enabled ?? false,
      );
      addIf(
        NotificationTransportKind.email,
        ref.watch(emailTransportConfigProvider).valueOrNull?.isConfigured ??
            false,
      );
      addIf(
        NotificationTransportKind.webhookGeneric,
        ref.watch(webhookTransportConfigProvider).valueOrNull?.isConfigured ??
            false,
      );
      addIf(
        NotificationTransportKind.pushover,
        ref.watch(pushoverTransportConfigProvider).valueOrNull?.isConfigured ??
            false,
      );
      addIf(
        NotificationTransportKind.telegram,
        ref.watch(telegramTransportConfigProvider).valueOrNull?.isConfigured ??
            false,
      );
      addIf(
        NotificationTransportKind.discord,
        ref.watch(discordTransportConfigProvider).valueOrNull?.isConfigured ??
            false,
      );
      addIf(
        NotificationTransportKind.mqtt,
        ref.watch(mqttTransportConfigProvider).valueOrNull?.isConfigured ??
            false,
      );
      return configured;
    });

/// Apply an authoritative transport config to [update], or reset the transport
/// to its unconfigured [safe] config when the provider errors. Loading states
/// with no value leave the transport untouched (the router was seeded with the
/// safe default, and a mid-flight reload keeps the last authoritative config
/// until it resolves).
void _applyOrReset<T>(AsyncValue<T> next, void Function(T) update, T safe) {
  if (next.hasError) {
    update(safe);
    return;
  }
  final value = next.valueOrNull;
  if (value != null) update(value);
}

/// Fail-closed routing matrix used while the persisted routing matrix is
/// loading or has errored. Every category routes to the in-app banner only —
/// so safety-critical events stay visible in the running UI — but NO external
/// transport (systemPush, email, webhook, Pushover, Telegram, Discord, MQTT)
/// can dispatch against a matrix the user never authorised. Unlike
/// [NotificationRoutingMatrix.defaults] it deliberately omits systemPush. Its
/// rules are non-empty so [NotificationRouter]'s empty-matrix→defaults()
/// coercion (which would re-introduce systemPush) never fires on it.
NotificationRoutingMatrix inAppOnlyFallbackMatrix() {
  const inApp = [NotificationTransportKind.inApp];
  return NotificationRoutingMatrix(
    enabled: true,
    rules: {
      for (final c in NotificationCategory.values)
        c: NotificationRoutingRule(
          transports: inApp,
          minSeverity: c.defaultSeverity,
        ),
    },
  );
}
