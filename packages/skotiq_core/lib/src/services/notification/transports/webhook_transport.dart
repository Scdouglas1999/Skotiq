// Generic user-defined webhook transport.
//
// Posts a JSON payload to a URL of the user's choice. The body template
// (if set) is rendered with the notification template engine — the user
// can craft arbitrary JSON like `{"category":"${category}","title":"${title}"}`
// using two synthetic context variables (`category` and `title` /
// `body`) that the router injects before rendering.
//
// Without a body template we ship a default JSON document that mirrors
// the in-app notification shape, so Home Assistant / n8n / Make.com /
// curl can consume it directly.

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;

import '../../../models/notification/notification_categories.dart';
import '../../../models/notification/transport_configs.dart';
import 'notification_transport.dart';

class WebhookTransport extends NotificationTransport {
  final http.Client _client;
  final Duration _timeout;
  WebhookTransportConfig _config;

  WebhookTransport({
    required WebhookTransportConfig config,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 15),
  }) : _config = config,
       _client = httpClient ?? http.Client(),
       _timeout = timeout;

  @override
  NotificationTransportKind get kind =>
      NotificationTransportKind.webhookGeneric;

  @override
  String get name => 'Webhook';

  @override
  bool get isConfigured => _config.isConfigured;

  void updateConfig(WebhookTransportConfig config) {
    _config = config;
  }

  WebhookTransportConfig get config => _config;

  @override
  Future<NotificationResult> send({
    required NotificationCategory category,
    required String title,
    required String body,
  }) async {
    if (!isConfigured) {
      return NotificationResult.fail('Webhook not configured');
    }
    final bodyText = _renderBody(category, title, body);
    final headers = <String, String>{
      'Content-Type': 'application/json',
      ..._config.headers,
    };
    try {
      final response = await _client
          .post(Uri.parse(_config.url), headers: headers, body: bodyText)
          .timeout(_timeout);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return NotificationResult.ok(statusCode: response.statusCode);
      }
      developer.log(
        '[Notifications/Webhook] HTTP ${response.statusCode}: ${response.body}',
        name: 'WebhookTransport',
        level: 900,
      );
      return NotificationResult.fail(
        'Webhook responded ${response.statusCode}',
        statusCode: response.statusCode,
      );
    } on TimeoutException {
      return NotificationResult.fail(
        'Webhook request timed out after ${_timeout.inSeconds}s',
      );
    } catch (e) {
      developer.log(
        '[Notifications/Webhook] Send failed: $e',
        name: 'WebhookTransport',
        level: 1000,
        error: e,
      );
      return NotificationResult.fail(e.toString());
    }
  }

  String _renderBody(NotificationCategory category, String title, String body) {
    final template = _config.bodyTemplate;
    if (template == null || template.trim().isEmpty) {
      return jsonEncode({
        'source': 'skotiq',
        'category': category.storageKey,
        'categoryLabel': category.label,
        'title': title,
        'body': body,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      });
    }
    // Light pre-substitution: replace ${title} / ${body} / ${category}
    // in the user-supplied template directly. The full interpolation
    // engine already ran on `title`/`body` upstream; here we let the
    // template wrap them in arbitrary JSON.
    return template
        .replaceAll(r'${title}', _jsonEscapeForTemplate(title))
        .replaceAll(r'${body}', _jsonEscapeForTemplate(body))
        .replaceAll(r'${category}', category.storageKey)
        .replaceAll(r'${timestamp}', DateTime.now().toUtc().toIso8601String());
  }

  /// Escape a string so it can be safely substituted inside a
  /// double-quoted JSON string literal in the user's template.
  String _jsonEscapeForTemplate(String s) {
    final encoded = jsonEncode(s);
    // Strip surrounding quotes; the template provides them.
    return encoded.substring(1, encoded.length - 1);
  }

  @override
  Future<void> dispose() async {
    _client.close();
  }
}
