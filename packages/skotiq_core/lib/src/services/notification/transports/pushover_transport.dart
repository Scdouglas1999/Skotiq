// Pushover transport (https://pushover.net).
//
// Wire protocol: simple HTTPS POST with form-urlencoded body to the
// single `messages.json` endpoint. The message's [EventSeverity] maps onto
// Pushover's priority scale; the user can raise the floor in the
// per-transport config.

import 'dart:async';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;

import '../../../models/backend/event_types.dart';
import '../../../models/notification/notification_categories.dart';
import '../../../models/notification/transport_configs.dart';
import 'notification_transport.dart';

/// Endpoint constant — kept private so other transports cannot reach
/// into Pushover's URL by accident (self-audit requirement).
const String _pushoverApiUrl = 'https://api.pushover.net/1/messages.json';

class PushoverTransport extends NotificationTransport {
  final http.Client _client;
  final Duration _timeout;
  PushoverTransportConfig _config;

  PushoverTransport({
    required PushoverTransportConfig config,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 15),
  }) : _config = config,
       _client = httpClient ?? http.Client(),
       _timeout = timeout;

  @override
  NotificationTransportKind get kind => NotificationTransportKind.pushover;

  @override
  String get name => 'Pushover';

  @override
  bool get isConfigured => _config.isConfigured;

  void updateConfig(PushoverTransportConfig config) {
    _config = config;
  }

  PushoverTransportConfig get config => _config;

  /// Pushover's -2..2 priority for a severity. The configured priority is a
  /// floor: a user who picks "high" gets at least +1, and a critical message
  /// still escalates to +2.
  int _priorityFor(EventSeverity severity) {
    final fromSeverity = switch (severity) {
      EventSeverity.critical => 2,
      EventSeverity.error => 1,
      EventSeverity.warning => 0,
      EventSeverity.info => -1,
    };
    final base = _config.priority;
    return (fromSeverity > base ? fromSeverity : base).clamp(-2, 2);
  }

  @override
  Future<NotificationResult> send(NotificationMessage message) async {
    final title = message.title;
    final body = message.body;
    if (!isConfigured) {
      return NotificationResult.fail('Pushover not configured');
    }
    try {
      final response = await _client
          .post(
            Uri.parse(_pushoverApiUrl),
            body: {
              'token': _config.apiToken,
              'user': _config.userKey,
              if (_config.device != null && _config.device!.isNotEmpty)
                'device': _config.device!,
              'title': title,
              'message': body,
              'priority': _priorityFor(message.severity).toString(),
            },
          )
          .timeout(_timeout);

      if (response.statusCode == 200) {
        return NotificationResult.ok(statusCode: 200);
      }
      developer.log(
        '[Notifications/Pushover] HTTP ${response.statusCode}: ${response.body}',
        name: 'PushoverTransport',
        level: 900,
      );
      return NotificationResult.fail(
        'Pushover responded ${response.statusCode}',
        statusCode: response.statusCode,
      );
    } on TimeoutException {
      return NotificationResult.fail(
        'Pushover request timed out after ${_timeout.inSeconds}s',
      );
    } catch (e) {
      developer.log(
        '[Notifications/Pushover] Send failed: $e',
        name: 'PushoverTransport',
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
