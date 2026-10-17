// Per-transport configuration models.
//
// Each transport has its own settings (Pushover needs user+token,
// Telegram needs bot+chat, etc.). These types serialise to JSON.
//
// Storage split:
//   * Non-secret fields (SMTP host/port, MQTT topic, From-address, etc.)
//     → key-value SettingsDao under `notification_transport_<kind>`.
//   * Secret fields (passwords, tokens, webhook URLs) → flutter_secure_storage
//     via [SecretsStore] (one entry per logical secret).
//
// These config classes still carry the secret as a String field so the
// in-memory shape stays simple; the per-transport Riverpod notifier
// rebuilds the live config by reading the non-secret blob from the DAO,
// reading the secret from the keyring, and stitching them back together.
// On save the inverse split happens.
//
// Plaintext-secret blobs from before that migration are migrated on first run
// via [SecretsStore.migrateFromPlaintext] — one-shot, idempotent.

import 'package:equatable/equatable.dart';

String _stringField(
  Map<String, dynamic> json,
  String key, {
  required String fallback,
}) {
  final value = json[key];
  if (value == null) return fallback;
  if (value is! String) {
    throw FormatException('$key must be a string');
  }
  return value;
}

String? _nullableStringField(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) {
    throw FormatException('$key must be a string or null');
  }
  return value;
}

bool _boolField(
  Map<String, dynamic> json,
  String key, {
  required bool fallback,
}) {
  final value = json[key];
  if (value == null) return fallback;
  if (value is! bool) {
    throw FormatException('$key must be a boolean');
  }
  return value;
}

int _intField(
  Map<String, dynamic> json,
  String key, {
  required int fallback,
  int? min,
  int? max,
}) {
  final value = json[key];
  if (value == null) return fallback;
  if (value is! num ||
      !value.isFinite ||
      value.truncateToDouble() != value.toDouble()) {
    throw FormatException('$key must be a whole number');
  }
  final parsed = value.toInt();
  if ((min != null && parsed < min) || (max != null && parsed > max)) {
    final range = min != null && max != null
        ? '$min-$max'
        : min != null
        ? 'at least $min'
        : 'at most $max';
    throw FormatException('$key must be $range');
  }
  return parsed;
}

void _requireHttpUrl(String value, String key) {
  if (value.isEmpty) return;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !uri.isAbsolute ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    throw FormatException('$key must be an absolute http(s) URL');
  }
}

/// Common shape for every transport config.
abstract class NotificationTransportConfig {
  bool get isConfigured;
  Map<String, dynamic> toJson();
}

// Email (smtp)

class EmailTransportConfig extends Equatable
    implements NotificationTransportConfig {
  final String smtpHost;
  final int smtpPort;
  final String username;
  final String password; // secret
  final bool useTls;
  final String fromAddress;
  final String toAddress;

  const EmailTransportConfig({
    this.smtpHost = '',
    this.smtpPort = 587,
    this.username = '',
    this.password = '',
    this.useTls = true,
    this.fromAddress = '',
    this.toAddress = '',
  });

  @override
  bool get isConfigured =>
      smtpHost.isNotEmpty && fromAddress.isNotEmpty && toAddress.isNotEmpty;

  EmailTransportConfig copyWith({
    String? smtpHost,
    int? smtpPort,
    String? username,
    String? password,
    bool? useTls,
    String? fromAddress,
    String? toAddress,
  }) => EmailTransportConfig(
    smtpHost: smtpHost ?? this.smtpHost,
    smtpPort: smtpPort ?? this.smtpPort,
    username: username ?? this.username,
    password: password ?? this.password,
    useTls: useTls ?? this.useTls,
    fromAddress: fromAddress ?? this.fromAddress,
    toAddress: toAddress ?? this.toAddress,
  );

  @override
  Map<String, dynamic> toJson() => {
    'smtpHost': smtpHost,
    'smtpPort': smtpPort,
    'username': username,
    'password': password,
    'useTls': useTls,
    'fromAddress': fromAddress,
    'toAddress': toAddress,
  };

  factory EmailTransportConfig.fromJson(Map<String, dynamic> json) =>
      EmailTransportConfig(
        smtpHost: _stringField(json, 'smtpHost', fallback: ''),
        smtpPort: _intField(
          json,
          'smtpPort',
          fallback: 587,
          min: 1,
          max: 65535,
        ),
        username: _stringField(json, 'username', fallback: ''),
        password: _stringField(json, 'password', fallback: ''),
        useTls: _boolField(json, 'useTls', fallback: true),
        fromAddress: _stringField(json, 'fromAddress', fallback: ''),
        toAddress: _stringField(json, 'toAddress', fallback: ''),
      );

  @override
  List<Object?> get props => [
    smtpHost,
    smtpPort,
    username,
    password,
    useTls,
    fromAddress,
    toAddress,
  ];
}

// Generic webhook

class WebhookTransportConfig extends Equatable
    implements NotificationTransportConfig {
  final String url;
  final Map<String, String> headers;
  final String? bodyTemplate;

  const WebhookTransportConfig({
    this.url = '',
    this.headers = const {},
    this.bodyTemplate,
  });

  @override
  bool get isConfigured => url.isNotEmpty;

  WebhookTransportConfig copyWith({
    String? url,
    Map<String, String>? headers,
    String? bodyTemplate,
    bool clearBodyTemplate = false,
  }) => WebhookTransportConfig(
    url: url ?? this.url,
    headers: headers ?? this.headers,
    bodyTemplate: clearBodyTemplate
        ? null
        : (bodyTemplate ?? this.bodyTemplate),
  );

  @override
  Map<String, dynamic> toJson() => {
    'url': url,
    'headers': headers,
    'bodyTemplate': bodyTemplate,
  };

  factory WebhookTransportConfig.fromJson(Map<String, dynamic> json) {
    final headersRaw = json['headers'];
    final headers = <String, String>{};
    if (headersRaw != null) {
      if (headersRaw is! Map) {
        throw const FormatException('headers must be an object');
      }
      for (final entry in headersRaw.entries) {
        if (entry.key is! String || entry.value is! String) {
          throw const FormatException(
            'webhook header names and values must be strings',
          );
        }
        headers[entry.key as String] = entry.value as String;
      }
    }
    final url = _stringField(json, 'url', fallback: '');
    _requireHttpUrl(url, 'url');
    return WebhookTransportConfig(
      url: url,
      headers: headers,
      bodyTemplate: _nullableStringField(json, 'bodyTemplate'),
    );
  }

  @override
  List<Object?> get props => [url, headers, bodyTemplate];
}

// Pushover

class PushoverTransportConfig extends Equatable
    implements NotificationTransportConfig {
  final String apiToken; // secret
  final String userKey; // secret
  final String? device;
  final int priority; // -2..2

  const PushoverTransportConfig({
    this.apiToken = '',
    this.userKey = '',
    this.device,
    this.priority = 0,
  });

  @override
  bool get isConfigured => apiToken.isNotEmpty && userKey.isNotEmpty;

  PushoverTransportConfig copyWith({
    String? apiToken,
    String? userKey,
    String? device,
    int? priority,
    bool clearDevice = false,
  }) => PushoverTransportConfig(
    apiToken: apiToken ?? this.apiToken,
    userKey: userKey ?? this.userKey,
    device: clearDevice ? null : (device ?? this.device),
    priority: priority ?? this.priority,
  );

  @override
  Map<String, dynamic> toJson() => {
    'apiToken': apiToken,
    'userKey': userKey,
    'device': device,
    'priority': priority,
  };

  factory PushoverTransportConfig.fromJson(Map<String, dynamic> json) =>
      PushoverTransportConfig(
        apiToken: _stringField(json, 'apiToken', fallback: ''),
        userKey: _stringField(json, 'userKey', fallback: ''),
        device: _nullableStringField(json, 'device'),
        priority: _intField(json, 'priority', fallback: 0, min: -2, max: 2),
      );

  @override
  List<Object?> get props => [apiToken, userKey, device, priority];
}

// Telegram

class TelegramTransportConfig extends Equatable
    implements NotificationTransportConfig {
  final String botToken; // secret
  final String chatId;
  final bool disableNotification;

  const TelegramTransportConfig({
    this.botToken = '',
    this.chatId = '',
    this.disableNotification = false,
  });

  @override
  bool get isConfigured => botToken.isNotEmpty && chatId.isNotEmpty;

  TelegramTransportConfig copyWith({
    String? botToken,
    String? chatId,
    bool? disableNotification,
  }) => TelegramTransportConfig(
    botToken: botToken ?? this.botToken,
    chatId: chatId ?? this.chatId,
    disableNotification: disableNotification ?? this.disableNotification,
  );

  @override
  Map<String, dynamic> toJson() => {
    'botToken': botToken,
    'chatId': chatId,
    'disableNotification': disableNotification,
  };

  factory TelegramTransportConfig.fromJson(Map<String, dynamic> json) =>
      TelegramTransportConfig(
        botToken: _stringField(json, 'botToken', fallback: ''),
        chatId: _stringField(json, 'chatId', fallback: ''),
        disableNotification: _boolField(
          json,
          'disableNotification',
          fallback: false,
        ),
      );

  @override
  List<Object?> get props => [botToken, chatId, disableNotification];
}

// Discord

class DiscordTransportConfig extends Equatable
    implements NotificationTransportConfig {
  final String webhookUrl; // secret
  final String? username;
  final String? avatarUrl;

  const DiscordTransportConfig({
    this.webhookUrl = '',
    this.username,
    this.avatarUrl,
  });

  @override
  bool get isConfigured => webhookUrl.isNotEmpty;

  DiscordTransportConfig copyWith({
    String? webhookUrl,
    String? username,
    String? avatarUrl,
    bool clearUsername = false,
    bool clearAvatarUrl = false,
  }) => DiscordTransportConfig(
    webhookUrl: webhookUrl ?? this.webhookUrl,
    username: clearUsername ? null : (username ?? this.username),
    avatarUrl: clearAvatarUrl ? null : (avatarUrl ?? this.avatarUrl),
  );

  @override
  Map<String, dynamic> toJson() => {
    'webhookUrl': webhookUrl,
    'username': username,
    'avatarUrl': avatarUrl,
  };

  factory DiscordTransportConfig.fromJson(Map<String, dynamic> json) {
    final webhookUrl = _stringField(json, 'webhookUrl', fallback: '');
    _requireHttpUrl(webhookUrl, 'webhookUrl');
    final avatarUrl = _nullableStringField(json, 'avatarUrl');
    if (avatarUrl != null) _requireHttpUrl(avatarUrl, 'avatarUrl');
    return DiscordTransportConfig(
      webhookUrl: webhookUrl,
      username: _nullableStringField(json, 'username'),
      avatarUrl: avatarUrl,
    );
  }

  @override
  List<Object?> get props => [webhookUrl, username, avatarUrl];
}

// MQTT

class MqttTransportConfig extends Equatable
    implements NotificationTransportConfig {
  final String host;
  final int port;
  final String? username;
  final String? password; // secret
  final String topic;

  /// MQTT QoS supported by Skotiq's publisher (0 or 1).
  ///
  /// Older builds exposed QoS 2 even though the transport silently sent those
  /// messages at QoS 1. Legacy persisted values are migrated to 1 on decode.
  final int qos;
  final bool retain;
  final bool useTls;
  final String clientId;

  const MqttTransportConfig({
    this.host = '',
    this.port = 1883,
    this.username,
    this.password,
    this.topic = 'skotiq/notifications',
    this.qos = 0,
    this.retain = false,
    this.useTls = false,
    this.clientId = 'skotiq',
  });

  @override
  bool get isConfigured => host.isNotEmpty && topic.isNotEmpty;

  MqttTransportConfig copyWith({
    String? host,
    int? port,
    String? username,
    String? password,
    String? topic,
    int? qos,
    bool? retain,
    bool? useTls,
    String? clientId,
    bool clearUsername = false,
    bool clearPassword = false,
  }) => MqttTransportConfig(
    host: host ?? this.host,
    port: port ?? this.port,
    username: clearUsername ? null : (username ?? this.username),
    password: clearPassword ? null : (password ?? this.password),
    topic: topic ?? this.topic,
    qos: qos ?? this.qos,
    retain: retain ?? this.retain,
    useTls: useTls ?? this.useTls,
    clientId: clientId ?? this.clientId,
  );

  @override
  Map<String, dynamic> toJson() => {
    'host': host,
    'port': port,
    'username': username,
    'password': password,
    'topic': topic,
    'qos': qos,
    'retain': retain,
    'useTls': useTls,
    'clientId': clientId,
  };

  factory MqttTransportConfig.fromJson(Map<String, dynamic> json) {
    final persistedQos = _intField(json, 'qos', fallback: 0, min: 0, max: 2);
    return MqttTransportConfig(
      host: _stringField(json, 'host', fallback: ''),
      port: _intField(json, 'port', fallback: 1883, min: 1, max: 65535),
      username: _nullableStringField(json, 'username'),
      password: _nullableStringField(json, 'password'),
      topic: _stringField(json, 'topic', fallback: 'skotiq/notifications'),
      qos: persistedQos == 2 ? 1 : persistedQos,
      retain: _boolField(json, 'retain', fallback: false),
      useTls: _boolField(json, 'useTls', fallback: false),
      clientId: _stringField(json, 'clientId', fallback: 'skotiq'),
    );
  }

  @override
  List<Object?> get props => [
    host,
    port,
    username,
    password,
    topic,
    qos,
    retain,
    useTls,
    clientId,
  ];
}
