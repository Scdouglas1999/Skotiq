// Telegram Bot API transport.
//
// Wire protocol: HTTPS POST to
// `https://api.telegram.org/bot<token>/sendMessage` with a
// form-urlencoded body. The `chat_id` may be a username (`@channel`),
// a numeric user id, or a group id. We don't validate it client-side —
// the API surfaces a clear error if it's malformed.

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;

import '../../../models/notification/notification_categories.dart';
import '../../../models/notification/transport_configs.dart';
import 'notification_transport.dart';

const String _telegramApiBase = 'https://api.telegram.org';

class TelegramTransport extends NotificationTransport {
  final http.Client _client;
  final Duration _timeout;
  TelegramTransportConfig _config;

  TelegramTransport({
    required TelegramTransportConfig config,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 15),
  }) : _config = config,
       _client = httpClient ?? http.Client(),
       _timeout = timeout;

  @override
  NotificationTransportKind get kind => NotificationTransportKind.telegram;

  @override
  String get name => 'Telegram';

  @override
  bool get isConfigured => _config.isConfigured;

  void updateConfig(TelegramTransportConfig config) {
    _config = config;
  }

  TelegramTransportConfig get config => _config;

  @override
  Future<NotificationResult> send({
    required NotificationCategory category,
    required String title,
    required String body,
  }) async {
    if (!isConfigured) {
      return NotificationResult.fail('Telegram not configured');
    }
    try {
      final url = '$_telegramApiBase/bot${_config.botToken}/sendMessage';
      final text = title.isEmpty ? body : '*$title*\n$body';
      final response = await _client
          .post(
            Uri.parse(url),
            body: {
              'chat_id': _config.chatId,
              'text': text,
              'parse_mode': 'Markdown',
              'disable_notification': _config.disableNotification.toString(),
            },
          )
          .timeout(_timeout);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final decoded =
            jsonDecode(response.body) as Map<String, dynamic>? ?? const {};
        if (decoded['ok'] == true) {
          return NotificationResult.ok(statusCode: response.statusCode);
        }
        return NotificationResult.fail(
          decoded['description']?.toString() ?? 'Telegram returned ok=false',
          statusCode: response.statusCode,
        );
      }
      developer.log(
        '[Notifications/Telegram] HTTP ${response.statusCode}: ${response.body}',
        name: 'TelegramTransport',
        level: 900,
      );
      return NotificationResult.fail(
        'Telegram responded ${response.statusCode}',
        statusCode: response.statusCode,
      );
    } on TimeoutException {
      return NotificationResult.fail(
        'Telegram request timed out after ${_timeout.inSeconds}s',
      );
    } catch (e) {
      developer.log(
        '[Notifications/Telegram] Send failed: $e',
        name: 'TelegramTransport',
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
