import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_plugins/skotiq_plugins.dart';

/// A server that accepts the request and never answers.
http.Client _stalledServer() =>
    MockClient((_) => Completer<http.Response>().future);

/// Runs [nodeTypeId] of [plugin] against a stalled server and reports
/// the result if the node finished within a few seconds past
/// [pluginHttpTimeout], or null.
Future<PluginNodeExecutionResult?> _runAgainstStall(
  WidgetTester tester,
  SequencePlugin plugin,
  String nodeTypeId,
  Map<String, dynamic> params, {
  required Future<void> Function() configure,
}) async {
  final host = PluginHost(
    contextFactory: PluginContextFactory(
      storageFactory: (_) => InMemoryPluginStorage(),
    ),
  );
  await host.registerPlugin(plugin);
  await configure();
  final executor = PluginNodeExecutor(host: host, registry: host.nodeRegistry);
  PluginNodeExecutionResult? result;
  unawaited(
    executor
        .run(pluginId: plugin.id, nodeTypeId: nodeTypeId, params: params)
        .then((r) => result = r),
  );
  await tester.pump(pluginHttpTimeout + const Duration(seconds: 5));
  final finished = result;
  // Let the executor's own limit run out so no timer outlives the test.
  await tester.pump(const Duration(minutes: 11));
  await host.dispose();
  return finished;
}

void main() {
  testWidgets('a Pushover request to a stalled server fails the node', (
    tester,
  ) async {
    final plugin = PushoverNotificationPlugin(clientBuilder: _stalledServer);
    final result = await _runAgainstStall(
      tester,
      plugin,
      'pushover.notify',
      const {'title': 'Done', 'message': 'All targets imaged'},
      configure: () =>
          plugin.configureCredentials(apiToken: 'token', userKey: 'user'),
    );
    expect(result, isNotNull);
    expect(result!.success, isFalse);
  });

  testWidgets('a Discord request to a stalled server fails the node', (
    tester,
  ) async {
    final plugin = DiscordWebhookPlugin(clientBuilder: _stalledServer);
    final result = await _runAgainstStall(
      tester,
      plugin,
      plugin.nodeDefinitions.first.id,
      const {
        'webhookUrl': 'https://discord.com/api/webhooks/123/abc',
        'content': 'hi',
      },
      configure: () async {},
    );
    expect(result, isNotNull);
    expect(result!.success, isFalse);
  });

  testWidgets('a Home Assistant request to a stalled server fails the node', (
    tester,
  ) async {
    final plugin = HomeAssistantPlugin(clientBuilder: _stalledServer);
    final result = await _runAgainstStall(
      tester,
      plugin,
      'home_assistant.toggle',
      const {
        'entityId': 'switch.dew_heater',
        'service': 'turn_on',
        'confirmStateAfterSecs': 0,
      },
      configure: () => plugin.configureConnection(
        baseUrl: 'http://homeassistant.local:8123',
        accessToken: 'token',
      ),
    );
    expect(result, isNotNull);
    expect(result!.success, isFalse);
  });

  testWidgets('a Home Assistant state check to a stalled server fails', (
    tester,
  ) async {
    final plugin = HomeAssistantPlugin(
      clientBuilder: () => MockClient((request) {
        if (request.method == 'POST') {
          return Future.value(http.Response('[]', 200));
        }
        return Completer<http.Response>().future;
      }),
    );
    final result = await _runAgainstStall(
      tester,
      plugin,
      'home_assistant.toggle',
      const {
        'entityId': 'switch.dew_heater',
        'service': 'turn_on',
        'confirmStateAfterSecs': 1,
        'expectedState': 'on',
      },
      configure: () => plugin.configureConnection(
        baseUrl: 'http://homeassistant.local:8123',
        accessToken: 'token',
      ),
    );
    expect(result, isNotNull);
    expect(result!.success, isFalse);
  });
}
