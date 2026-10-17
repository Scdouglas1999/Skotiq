// Home Assistant integration plugin — adds a sequence node that toggles
// a Home Assistant entity (switch / light / etc.) via the REST API.
//
// This is the canonical "automate my observatory" plugin example. Common uses:
// * turn dew heaters on at the start of an imaging burst,
// * close the observatory dome shutter on weather-trigger abort,
// * fire a "session started" scene that dims room lights + sets monitors
//   to night-vision red.
//
// The plugin uses the Home Assistant base URL + long-lived access token
// stored once in plugin storage. Each node configures:
//
// * `entityId` (String, required): e.g. `switch.dew_heater_1`.
// * `service` (String, optional, default `turn_on`): HA service to call
//   on the entity's domain (`turn_on`, `turn_off`, `toggle`).
// * `confirmStateAfterSecs` (int, optional, default 2): how long to wait
//   before reading the entity state back to confirm the toggle took
//   effect. `0` disables the confirm step (fire-and-forget).
// * `expectedState` (String, optional): if set + confirm is enabled, the
//   node fails when the entity does not end up in this state (e.g.
//   `"on"` after `turn_on`).
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../src/plugin_api.dart';

/// Returns a user-facing validation error for a Home Assistant base URL.
String? homeAssistantBaseUrlProblem(String value) {
  final parsed = Uri.tryParse(value.trim());
  if (parsed == null || parsed.host.isEmpty) {
    return 'The base URL must be a full URL, e.g. '
        'http://homeassistant.local:8123';
  }
  if (parsed.scheme != 'http' && parsed.scheme != 'https') {
    return 'The base URL must use http:// or https://.';
  }
  return null;
}

/// Storage key for the HA base URL (e.g. `http://homeassistant.local:8123`).
const String _kHaBaseUrlStorageKey = 'home_assistant.baseUrl';

/// Storage key for the HA long-lived access token.
const String _kHaTokenStorageKey = 'home_assistant.token';

class HomeAssistantPlugin extends SequencePlugin {
  PluginContext? _context;

  /// HTTP client factory; tests inject a mock client.
  final http.Client Function()? clientBuilder;

  HomeAssistantPlugin({this.clientBuilder});

  @override
  String get id => 'com.skotiq.examples.home_assistant';

  @override
  String get name => 'Home Assistant';

  @override
  String get version => '1.0.0';

  @override
  String get description =>
      'Adds a sequence node that toggles a Home Assistant entity (switch, '
      'light, scene, …) via the HA REST API. Useful for automating dew '
      'heaters, dome shutters, observatory lighting.';

  @override
  String get author => 'Skotiq Team';

  @override
  String? get minAppVersion => '2.5.0';

  @override
  Future<void> onLoad(PluginContext context) async {
    _context = context;
    final baseUrl = await context.storage.getString(_kHaBaseUrlStorageKey);
    final token = await context.storage.getString(_kHaTokenStorageKey);
    context.logger.info(
      'Home Assistant plugin loaded. Configured: '
      'base=${baseUrl != null && baseUrl.isNotEmpty}, '
      'token=${token != null && token.isNotEmpty}',
    );
  }

  @override
  Future<void> onUnload() async {
    _context = null;
  }

  /// Store the Home Assistant connection settings. Plugin authors typically
  /// expose these in a settings UI; here we provide a method so the host
  /// UI / a test can persist them.
  Future<void> configureConnection({
    required String baseUrl,
    required String accessToken,
  }) async {
    final ctx = _context;
    if (ctx == null) {
      throw PluginException(
        'Cannot configure Home Assistant before plugin is loaded',
      );
    }
    final trimmed = baseUrl.trim();
    final urlProblem = homeAssistantBaseUrlProblem(trimmed);
    if (urlProblem != null) {
      throw PluginException(urlProblem);
    }
    final normalized = trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
    await ctx.storage.setString(_kHaBaseUrlStorageKey, normalized);
    await ctx.storage.setString(_kHaTokenStorageKey, accessToken);
    ctx.logger.info('Home Assistant connection configured: $normalized');
  }

  @override
  List<SequenceNodeDefinition> get nodeDefinitions => [
    SequenceNodeDefinition(
      id: 'home_assistant.toggle',
      name: 'Toggle Home Assistant Entity',
      category: 'Observatory',
      description:
          'Call a Home Assistant service on a specific entity (turn_on, '
          'turn_off, toggle). Optionally confirm the post-call state.',
      createNode: (params) {
        final entity = (params['entityId'] as String? ?? '').trim();
        final service = (params['service'] as String? ?? 'turn_on')
            .trim()
            .toLowerCase();
        final confirmSecs =
            (params['confirmStateAfterSecs'] as num?)?.toInt() ?? 2;
        final expectedState = (params['expectedState'] as String?)
            ?.trim()
            .toLowerCase();
        return _HomeAssistantToggleNode(
          entityId: entity,
          service: service,
          confirmStateAfterSecs: confirmSecs,
          expectedState: (expectedState == null || expectedState.isEmpty)
              ? null
              : expectedState,
          clientBuilder: clientBuilder ?? http.Client.new,
        );
      },
    ),
  ];
}

class _HomeAssistantToggleNode implements PluginSequenceNode {
  final String entityId;
  final String service;
  final int confirmStateAfterSecs;
  final String? expectedState;
  final http.Client Function() clientBuilder;

  _HomeAssistantToggleNode({
    required this.entityId,
    required this.service,
    required this.confirmStateAfterSecs,
    required this.expectedState,
    required this.clientBuilder,
  });

  @override
  String? validate() {
    if (entityId.isEmpty) return 'Home Assistant entityId is required';
    if (!entityId.contains('.')) {
      return 'entityId must be in domain.entity format (e.g. switch.dew_heater)';
    }
    if (!_supportedServices.contains(service)) {
      return 'service must be one of ${_supportedServices.join(", ")}; '
          'got "$service"';
    }
    if (confirmStateAfterSecs < 0 || confirmStateAfterSecs > 60) {
      return 'confirmStateAfterSecs must be in [0, 60]; got $confirmStateAfterSecs';
    }
    return null;
  }

  static const Set<String> _supportedServices = {
    'turn_on',
    'turn_off',
    'toggle',
  };

  @override
  Future<bool> execute(PluginContext context) async {
    final baseUrl = await context.storage.getString(_kHaBaseUrlStorageKey);
    final token = await context.storage.getString(_kHaTokenStorageKey);
    if (baseUrl == null || baseUrl.isEmpty) {
      context.logger.error('Home Assistant base URL is not configured');
      return false;
    }
    if (token == null || token.isEmpty) {
      context.logger.error('Home Assistant access token is not configured');
      return false;
    }

    final domain = entityId.split('.').first;
    final url = Uri.parse('$baseUrl/api/services/$domain/$service');

    final client = clientBuilder();
    try {
      context.logger.info(
        'Calling Home Assistant: $domain/$service for $entityId',
      );

      final response = await client.post(
        url,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'entity_id': entityId}),
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        context.logger.error(
          'Home Assistant service call failed: ${response.statusCode} '
          '${response.body}',
        );
        return false;
      }

      context.eventBus.emit('plugin.home_assistant.service_called', {
        'entity_id': entityId,
        'service': service,
      });

      if (confirmStateAfterSecs == 0 || expectedState == null) {
        // Fire and forget — done.
        return true;
      }

      // Allow Home Assistant a moment to reflect the new state, then GET
      // the entity state and confirm.
      await Future<void>.delayed(Duration(seconds: confirmStateAfterSecs));
      final stateUrl = Uri.parse('$baseUrl/api/states/$entityId');
      final stateResponse = await client.get(
        stateUrl,
        headers: {'Authorization': 'Bearer $token'},
      );
      if (stateResponse.statusCode != 200) {
        context.logger.warning(
          'Home Assistant state confirm failed: '
          '${stateResponse.statusCode} ${stateResponse.body}',
        );
        // Service call succeeded, confirm failed — treat the node as
        // succeeded but log the inconsistency.
        return true;
      }
      try {
        final decoded = jsonDecode(stateResponse.body) as Map<String, dynamic>;
        final actualState =
            (decoded['state'] as String?)?.trim().toLowerCase() ?? '';
        if (actualState != expectedState) {
          context.logger.error(
            'Home Assistant entity $entityId is in state "$actualState"; '
            'expected "$expectedState"',
          );
          return false;
        }
        context.eventBus.emit('plugin.home_assistant.state_confirmed', {
          'entity_id': entityId,
          'state': actualState,
        });
        return true;
      } on FormatException catch (e) {
        context.logger.error(
          'Home Assistant state body was not valid JSON: ${stateResponse.body}',
          e,
        );
        return false;
      }
    } catch (e, stackTrace) {
      context.logger.error('Home Assistant call threw', e, stackTrace);
      return false;
    } finally {
      client.close();
    }
  }
}
