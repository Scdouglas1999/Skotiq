// Discord webhook transport.
//
// Wire protocol: JSON POST to a user-configured webhook URL on
// `discord.com`. We construct an "embed" with category-coloured side
// bars matching the legacy NotificationService.

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;

import '../../../models/notification/notification_categories.dart';
import '../../../models/notification/transport_configs.dart';
import 'notification_transport.dart';

class DiscordTransport extends NotificationTransport {
  final http.Client _client;
  final Duration _timeout;
  DiscordTransportConfig _config;

  DiscordTransport({
    required DiscordTransportConfig config,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 15),
  }) : _config = config,
       _client = httpClient ?? http.Client(),
       _timeout = timeout;

  @override
  NotificationTransportKind get kind => NotificationTransportKind.discord;

  @override
  String get name => 'Discord';

  @override
  bool get isConfigured => _config.isConfigured;

  void updateConfig(DiscordTransportConfig config) {
    _config = config;
  }

  DiscordTransportConfig get config => _config;

  int _colorFor(NotificationCategory category) {
    switch (category) {
      case NotificationCategory.sequenceFailed:
      case NotificationCategory.recoveryGaveUp:
      case NotificationCategory.weatherUnsafe:
      case NotificationCategory.guidingLost:
      case NotificationCategory.diskSpaceLow:
      case NotificationCategory.equipmentDisconnected:
      case NotificationCategory.autofocusFailed:
      case NotificationCategory.exposureFailed:
        return 0xEF4444; // red
      case NotificationCategory.frameRejected:
      case NotificationCategory.cloudArriving:
      case NotificationCategory.recoveryStarted:
      case NotificationCategory.sequencePaused:
        return 0xF59E0B; // amber
      case NotificationCategory.sequenceCompleted:
      case NotificationCategory.targetCompleted:
      case NotificationCategory.recoveryRecovered:
      case NotificationCategory.guidingRecovered:
      case NotificationCategory.weatherSafeAgain:
      case NotificationCategory.cloudOpening:
        return 0x22C55E; // green
      default:
        return 0x6366F1; // indigo
    }
  }

  @override
  Future<NotificationResult> send({
    required NotificationCategory category,
    required String title,
    required String body,
  }) async {
    if (!isConfigured) {
      return NotificationResult.fail('Discord not configured');
    }
    try {
      final payload = <String, dynamic>{
        'embeds': [
          {
            'title': title,
            'description': body,
            'color': _colorFor(category),
            'timestamp': DateTime.now().toUtc().toIso8601String(),
            'footer': {'text': 'Skotiq • ${category.label}'},
          },
        ],
      };
      if (_config.username != null && _config.username!.isNotEmpty) {
        payload['username'] = _config.username;
      }
      if (_config.avatarUrl != null && _config.avatarUrl!.isNotEmpty) {
        payload['avatar_url'] = _config.avatarUrl;
      }

      final response = await _client
          .post(
            Uri.parse(_config.webhookUrl),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(_timeout);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return NotificationResult.ok(statusCode: response.statusCode);
      }
      developer.log(
        '[Notifications/Discord] HTTP ${response.statusCode}: ${response.body}',
        name: 'DiscordTransport',
        level: 900,
      );
      return NotificationResult.fail(
        'Discord responded ${response.statusCode}',
        statusCode: response.statusCode,
      );
    } on TimeoutException {
      return NotificationResult.fail(
        'Discord request timed out after ${_timeout.inSeconds}s',
      );
    } catch (e) {
      developer.log(
        '[Notifications/Discord] Send failed: $e',
        name: 'DiscordTransport',
        level: 1000,
        error: e,
      );
      return NotificationResult.fail(e.toString());
    }
  }

  @override
  Future<void> dispose() async {
    _client.close();
  }
}
