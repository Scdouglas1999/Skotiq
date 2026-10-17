// Pushover Notification plugin — adds a sequence node that posts a
// Pushover push notification when executed.
//
// This is a "per-node" Pushover transport, distinct from the built-in
// app-wide Pushover transport. Use this when:
// * you want a notification only for ONE specific sequence step (e.g.
//   "ping me when the meridian flip is done") without enabling Pushover
//   as a global transport, or
// * you want a customized title / priority / device that differs from
//   the global default.
//
// Configuration parameters (read from the node config map):
// * `title` (String, required): notification title.
// * `message` (String, required): notification body.
// * `priority` (int, optional, default 0): Pushover priority -2..2.
// * `device` (String, optional): target Pushover device (`""` => all).
//
// Credentials are read from plugin storage (so they are written once via
// the plugin's settings panel and never embedded in saved sequences):
// * `apiToken` — Pushover application token (required).
// * `userKey`  — Pushover user/group key (required).
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../src/plugin_api.dart';

/// Storage key for the Pushover application token (per-plugin).
const String _kApiTokenStorageKey = 'pushover.apiToken';

/// Storage key for the Pushover user/group key (per-plugin).
const String _kUserKeyStorageKey = 'pushover.userKey';

/// Plugin entry point. Exposes a single `pushover.notify` sequence node.
class PushoverNotificationPlugin extends SequencePlugin {
  PluginContext? _context;

  /// Optional HTTP client override. Tests inject a mock client; production
  /// code leaves this null and we instantiate a fresh `http.Client` per
  /// node invocation (the client is cheap and lets each node tear down
  /// cleanly after a single POST).
  final http.Client Function()? clientBuilder;

  PushoverNotificationPlugin({this.clientBuilder});

  @override
  String get id => 'com.skotiq.examples.pushover';

  @override
  String get name => 'Pushover Notification';

  @override
  String get version => '1.0.0';

  @override
  String get description =>
      'Adds a sequence node that sends a Pushover push notification with a '
      'configurable title, message, and priority. Credentials are stored '
      'per-plugin so they do not leak into saved sequences.';

  @override
  String get author => 'Skotiq Team';

  @override
  String? get minAppVersion => '2.5.0';

  @override
  Future<void> onLoad(PluginContext context) async {
    _context = context;
    final tokenPresent =
        (await context.storage.getString(_kApiTokenStorageKey))?.isNotEmpty ??
        false;
    final userPresent =
        (await context.storage.getString(_kUserKeyStorageKey))?.isNotEmpty ??
        false;
    context.logger.info(
      'Pushover plugin loaded. Credentials configured: '
      'token=$tokenPresent, userKey=$userPresent',
    );
  }

  @override
  Future<void> onUnload() async {
    _context = null;
  }

  /// Persist credentials. Plugin authors typically expose these in a
  /// settings panel; here we surface them as a method so the host UI
  /// or a test can write the values.
  Future<void> configureCredentials({
    required String apiToken,
    required String userKey,
  }) async {
    final ctx = _context;
    if (ctx == null) {
      throw PluginException(
        'Cannot configure Pushover credentials before plugin is loaded',
      );
    }
    await ctx.storage.setString(_kApiTokenStorageKey, apiToken);
    await ctx.storage.setString(_kUserKeyStorageKey, userKey);
    ctx.logger.info('Pushover credentials updated');
  }

  @override
  List<SequenceNodeDefinition> get nodeDefinitions => [
    SequenceNodeDefinition(
      id: 'pushover.notify',
      name: 'Pushover Notification',
      category: 'Notifications',
      description:
          'Send a Pushover push notification. Title and message are '
          'configured per-node; credentials are configured once per '
          'plugin and stored in plugin storage.',
      createNode: (params) {
        final title = (params['title'] as String? ?? '').trim();
        final message = (params['message'] as String? ?? '').trim();
        final priority = (params['priority'] as num?)?.toInt() ?? 0;
        final device = (params['device'] as String?)?.trim();
        return _PushoverNotificationNode(
          title: title,
          message: message,
          priority: priority,
          device: (device == null || device.isEmpty) ? null : device,
          clientBuilder: clientBuilder ?? http.Client.new,
        );
      },
    ),
  ];
}

class _PushoverNotificationNode implements PluginSequenceNode {
  final String title;
  final String message;
  final int priority;
  final String? device;
  final http.Client Function() clientBuilder;

  _PushoverNotificationNode({
    required this.title,
    required this.message,
    required this.priority,
    required this.device,
    required this.clientBuilder,
  });

  @override
  String? validate() {
    if (title.isEmpty) return 'Pushover title is required';
    if (message.isEmpty) return 'Pushover message is required';
    if (priority < -2 || priority > 2) {
      return 'Pushover priority must be in [-2, 2]; got $priority';
    }
    return null;
  }

  @override
  Future<bool> execute(PluginContext context) async {
    final apiToken = await context.storage.getString(_kApiTokenStorageKey);
    final userKey = await context.storage.getString(_kUserKeyStorageKey);
    if (apiToken == null || apiToken.isEmpty) {
      context.logger.error(
        'Pushover API token is not configured; skipping push',
      );
      return false;
    }
    if (userKey == null || userKey.isEmpty) {
      context.logger.error(
        'Pushover user/group key is not configured; skipping push',
      );
      return false;
    }

    final client = clientBuilder();
    try {
      final body = <String, String>{
        'token': apiToken,
        'user': userKey,
        'title': title,
        'message': message,
        'priority': '$priority',
      };
      if (device != null) body['device'] = device!;

      context.logger.info(
        'Sending Pushover notification: priority=$priority, '
        'device=${device ?? "(any)"}',
      );

      final response = await client.post(
        Uri.parse('https://api.pushover.net/1/messages.json'),
        body: body,
      );

      if (response.statusCode != 200) {
        context.logger.error(
          'Pushover responded ${response.statusCode}: ${response.body}',
        );
        return false;
      }

      // Pushover returns { status: 1, request: "..." } on success and
      // { status: 0, errors: [ ... ] } on failure.
      try {
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        if (decoded['status'] != 1) {
          context.logger.error(
            'Pushover refused: ${decoded['errors'] ?? decoded}',
          );
          return false;
        }
        context.eventBus.emit('plugin.pushover.sent', {
          'title': title,
          'priority': priority,
          'request_id': decoded['request'],
        });
        return true;
      } on FormatException catch (e) {
        context.logger.error(
          'Pushover returned non-JSON body: ${response.body}',
          e,
        );
        return false;
      }
    } catch (e, stackTrace) {
      context.logger.error('Pushover POST threw', e, stackTrace);
      return false;
    } finally {
      client.close();
    }
  }
}
