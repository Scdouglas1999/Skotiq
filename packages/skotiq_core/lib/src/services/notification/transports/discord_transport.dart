// Discord webhook transport.
//
// Wire protocol: JSON POST to a user-configured webhook URL on
// `discord.com`, carrying one embed whose side bar takes the message's tone.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../models/notification/notification_categories.dart';
import '../../../models/notification/transport_configs.dart';
import '../notification_presentation.dart';
import 'notification_transport.dart';
import '../../logging_service.dart';

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

  @override
  Future<NotificationResult> send(NotificationMessage message) async {
    final category = message.category;
    final title = message.title;
    final body = message.body;
    if (!isConfigured) {
      return NotificationResult.fail('Discord not configured');
    }
    try {
      final payload = <String, dynamic>{
        'embeds': [
          {
            'title': title,
            'description': body,
            'color': NotificationPresentation.of(
              category,
            ).toneAt(message.severity).discordColor,
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
      Log.warning(
        '[Notifications/Discord] HTTP ${response.statusCode}: ${response.body}',
        source: 'DiscordTransport',
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
      Log.error(
        '[Notifications/Discord] Send failed: $e',
        source: 'DiscordTransport',
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
