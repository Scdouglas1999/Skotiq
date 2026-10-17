// Tests for the plugin sequence-node registry and execution path.
//
// Verifies:
// * PluginHost auto-registers SequencePlugin nodes in the registry.
// * Disable / unregister drops registrations.
// * Re-enable re-publishes them.
// * PluginNodeExecutor surfaces validation failures, plugin exceptions,
//   and timeouts as structured failures instead of throwing.
// * The three example plugins (Pushover, Discord, Home Assistant)
//   validate their parameters and route through the registry correctly.
// * A no-network "dummy" plugin executes end-to-end through the registry
//   + executor pipeline.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_plugins/skotiq_plugins.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PluginNodeRegistry', () {
    test('compose / parse keys are symmetric', () {
      final key = PluginNodeRegistration.composeKey(
        'com.example.foo',
        'bar.qux',
      );
      expect(key, equals('com.example.foo::bar.qux'));

      final parsed = PluginNodeRegistration.parseKey(key);
      expect(parsed, isNotNull);
      expect(parsed!.pluginId, equals('com.example.foo'));
      expect(parsed.nodeTypeId, equals('bar.qux'));
    });

    test('malformed keys return null from parseKey', () {
      expect(PluginNodeRegistration.parseKey(''), isNull);
      expect(PluginNodeRegistration.parseKey('no-separator'), isNull);
      // Trailing separator with nothing after it is malformed; the parser
      // requires both halves to be non-empty.
      expect(PluginNodeRegistration.parseKey('foo::'), isNull);
      expect(PluginNodeRegistration.parseKey('::bar'), isNull);
    });

    test('host auto-registers sequence-plugin nodes', () async {
      final host = PluginHost();
      addTearDown(host.dispose);
      final plugin = _DummySequencePlugin();
      await host.registerPlugin(plugin);

      final registrations = host.nodeRegistry.registrations;
      expect(registrations, hasLength(3));
      expect(
        registrations.map((r) => r.definition.id).toSet(),
        equals({
          'dummy.always_succeeds',
          'dummy.always_fails',
          'dummy.requires_param',
        }),
      );
    });

    test('disable + re-enable round-trip republishes registrations', () async {
      final host = PluginHost();
      addTearDown(host.dispose);
      final plugin = _DummySequencePlugin();
      await host.registerPlugin(plugin);

      expect(host.nodeRegistry.registrations, hasLength(3));

      await host.setPluginEnabled(plugin.id, false);
      expect(host.nodeRegistry.registrations, isEmpty);

      await host.setPluginEnabled(plugin.id, true);
      expect(host.nodeRegistry.registrations, hasLength(3));
    });

    test('unregister drops every registration owned by the plugin', () async {
      final host = PluginHost();
      addTearDown(host.dispose);
      final plugin = _DummySequencePlugin();
      await host.registerPlugin(plugin);

      await host.unregisterPlugin(plugin.id);
      expect(host.nodeRegistry.registrations, isEmpty);
      expect(
        host.nodeRegistry.findDefinition(plugin.id, 'dummy.always_succeeds'),
        isNull,
      );
    });

    test(
      'changes stream emits a fresh snapshot on register / unregister',
      () async {
        final host = PluginHost();
        addTearDown(host.dispose);

        final snapshots = <List<PluginNodeRegistration>>[];
        final sub = host.nodeRegistry.changes.listen(snapshots.add);
        addTearDown(sub.cancel);

        final plugin = _DummySequencePlugin();
        await host.registerPlugin(plugin);
        await Future<void>.delayed(Duration.zero);
        expect(snapshots, isNotEmpty);
        expect(snapshots.last, hasLength(3));

        await host.unregisterPlugin(plugin.id);
        await Future<void>.delayed(Duration.zero);
        expect(snapshots.last, isEmpty);
      },
    );
  });

  group('PluginNodeExecutor', () {
    late PluginHost host;
    late PluginNodeExecutor executor;

    setUp(() async {
      host = PluginHost();
      executor = PluginNodeExecutor(host: host, registry: host.nodeRegistry);
    });

    tearDown(() async {
      await host.dispose();
    });

    test('unknown node returns structured failure', () async {
      final result = await executor.run(
        pluginId: 'no.such.plugin',
        nodeTypeId: 'no.such.node',
        params: const {},
      );
      expect(result.success, isFalse);
      expect(result.message, contains('Unknown plugin node'));
    });

    test('disabled plugin nodes fail closed', () async {
      final plugin = _DummySequencePlugin();
      await host.registerPlugin(plugin);
      await host.setPluginEnabled(plugin.id, false);

      // Even though the disabled-flow clears registrations, the executor
      // also explicitly checks isEnabled — this protects against a race
      // where a registration leaks through.
      final result = await executor.run(
        pluginId: plugin.id,
        nodeTypeId: 'dummy.always_succeeds',
        params: const {},
      );
      expect(result.success, isFalse);
    });

    test('validation failures surface as structured errors', () async {
      final plugin = _DummySequencePlugin();
      await host.registerPlugin(plugin);

      final result = await executor.run(
        pluginId: plugin.id,
        nodeTypeId: 'dummy.requires_param',
        params: const {},
      );
      expect(result.success, isFalse);
      expect(result.message, contains('required'));
    });

    test(
      'successful execute returns success with descriptive message',
      () async {
        final plugin = _DummySequencePlugin();
        await host.registerPlugin(plugin);

        final result = await executor.run(
          pluginId: plugin.id,
          nodeTypeId: 'dummy.always_succeeds',
          params: const {},
        );
        expect(result.success, isTrue);
        expect(result.message, contains('completed'));
      },
    );

    test('execute() returning false is reported as failure', () async {
      final plugin = _DummySequencePlugin();
      await host.registerPlugin(plugin);

      final result = await executor.run(
        pluginId: plugin.id,
        nodeTypeId: 'dummy.always_fails',
        params: const {},
      );
      expect(result.success, isFalse);
      expect(result.message, contains('reported failure'));
    });

    test(
      'plugin exceptions surface as structured failures, not thrown',
      () async {
        final plugin = _ThrowingSequencePlugin();
        await host.registerPlugin(plugin);

        final result = await executor.run(
          pluginId: plugin.id,
          nodeTypeId: 'throwing.boom',
          params: const {},
        );
        expect(result.success, isFalse);
        expect(result.message, contains('threw'));
      },
    );

    test('plugin timeouts are enforced', () async {
      final plugin = _HangingSequencePlugin();
      await host.registerPlugin(plugin);

      final exec = PluginNodeExecutor(
        host: host,
        registry: host.nodeRegistry,
        defaultTimeout: const Duration(milliseconds: 50),
      );
      final result = await exec.run(
        pluginId: plugin.id,
        nodeTypeId: 'hanging.forever',
        params: const {},
      );
      expect(result.success, isFalse);
      expect(result.message, contains('timed out'));
    });

    test('round-trip: register, execute multiple times, unregister', () async {
      final plugin = _CountingSequencePlugin();
      await host.registerPlugin(plugin);

      for (var i = 0; i < 3; i++) {
        final result = await executor.run(
          pluginId: plugin.id,
          nodeTypeId: 'counting.tick',
          params: const {},
        );
        expect(result.success, isTrue, reason: 'call $i should succeed');
      }
      expect(plugin.invocationCount, equals(3));

      await host.unregisterPlugin(plugin.id);
      final after = await executor.run(
        pluginId: plugin.id,
        nodeTypeId: 'counting.tick',
        params: const {},
      );
      expect(after.success, isFalse);
    });
  });

  group('PushoverNotificationPlugin', () {
    test('validates required title and message', () async {
      final plugin = PushoverNotificationPlugin();
      final host = PluginHost();
      addTearDown(host.dispose);
      await host.registerPlugin(plugin);

      final node = host.nodeRegistry
          .findDefinition(plugin.id, 'pushover.notify')!
          .definition
          .createNode({'title': '', 'message': ''});
      expect(node, isNotNull);
      expect(node!.validate(), contains('title'));

      final node2 = host.nodeRegistry
          .findDefinition(plugin.id, 'pushover.notify')!
          .definition
          .createNode({'title': 'Hello', 'message': ''});
      expect(node2!.validate(), contains('message'));
    });

    test('rejects invalid priority', () {
      final plugin = PushoverNotificationPlugin();
      final node = plugin.nodeDefinitions
          .firstWhere((d) => d.id == 'pushover.notify')
          .createNode({'title': 'Hi', 'message': 'Hello', 'priority': 99});
      expect(node!.validate(), contains('priority'));
    });

    test('reports failure when credentials are not configured', () async {
      final mockClient = MockClient(
        (_) async => http.Response('should not be called', 200),
      );
      final plugin = PushoverNotificationPlugin(
        clientBuilder: () => mockClient,
      );
      final host = PluginHost();
      addTearDown(host.dispose);
      await host.registerPlugin(plugin);

      final executor = PluginNodeExecutor(
        host: host,
        registry: host.nodeRegistry,
      );
      final result = await executor.run(
        pluginId: plugin.id,
        nodeTypeId: 'pushover.notify',
        params: const {'title': 'Frame captured', 'message': 'M31 L 60s'},
      );
      expect(result.success, isFalse);
    });

    test('successful Pushover POST returns success', () async {
      var posted = false;
      final mockClient = MockClient((request) async {
        posted = true;
        expect(
          request.url.toString(),
          equals('https://api.pushover.net/1/messages.json'),
        );
        return http.Response(
          jsonEncode({'status': 1, 'request': 'req-123'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final plugin = PushoverNotificationPlugin(
        clientBuilder: () => mockClient,
      );
      final host = PluginHost();
      addTearDown(host.dispose);
      await host.registerPlugin(plugin);
      await plugin.configureCredentials(
        apiToken: 'token123',
        userKey: 'user456',
      );

      final executor = PluginNodeExecutor(
        host: host,
        registry: host.nodeRegistry,
      );
      final result = await executor.run(
        pluginId: plugin.id,
        nodeTypeId: 'pushover.notify',
        params: const {
          'title': 'Sequence done',
          'message': 'All targets imaged successfully',
          'priority': 1,
        },
      );
      expect(result.success, isTrue, reason: 'message=${result.message}');
      expect(posted, isTrue);
    });

    test('Pushover server error fails the node', () async {
      final mockClient = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'status': 0,
            'errors': ['invalid token'],
          }),
          200,
        ),
      );
      final plugin = PushoverNotificationPlugin(
        clientBuilder: () => mockClient,
      );
      final host = PluginHost();
      addTearDown(host.dispose);
      await host.registerPlugin(plugin);
      await plugin.configureCredentials(apiToken: 'bad', userKey: 'bad');

      final executor = PluginNodeExecutor(
        host: host,
        registry: host.nodeRegistry,
      );
      final result = await executor.run(
        pluginId: plugin.id,
        nodeTypeId: 'pushover.notify',
        params: const {'title': 'x', 'message': 'y'},
      );
      expect(result.success, isFalse);
    });
  });

  group('DiscordWebhookPlugin', () {
    test('rejects non-https URLs', () {
      final plugin = DiscordWebhookPlugin();
      final node = plugin.nodeDefinitions.first.createNode({
        'webhookUrl': 'http://discord.com/api/webhooks/123/abc',
        'content': 'hi',
      });
      expect(node!.validate(), contains('https'));
    });

    test('rejects URLs that are not Discord domains', () {
      final plugin = DiscordWebhookPlugin();
      final node = plugin.nodeDefinitions.first.createNode({
        'webhookUrl': 'https://evil.example.com/webhooks/1/abc',
        'content': 'hi',
      });
      expect(node!.validate(), contains('discord'));
    });

    test('rejects lookalike Discord suffix domains', () {
      final plugin = DiscordWebhookPlugin();
      final node = plugin.nodeDefinitions.first.createNode({
        'webhookUrl': 'https://evil-discord.com/api/webhooks/123/abc',
        'content': 'hi',
      });
      expect(node!.validate(), contains('discord'));
    });

    test('requires content or embed', () {
      final plugin = DiscordWebhookPlugin();
      final node = plugin.nodeDefinitions.first.createNode({
        'webhookUrl': 'https://discord.com/api/webhooks/123/abc',
      });
      expect(node!.validate(), contains('content'));
    });

    test('successful POST returns true', () async {
      final mockClient = MockClient((request) async {
        expect(request.headers['content-type'], contains('application/json'));
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['content'], equals('hello world'));
        return http.Response('', 204);
      });
      final plugin = DiscordWebhookPlugin(clientBuilder: () => mockClient);
      final host = PluginHost();
      addTearDown(host.dispose);
      await host.registerPlugin(plugin);

      final executor = PluginNodeExecutor(
        host: host,
        registry: host.nodeRegistry,
      );
      final result = await executor.run(
        pluginId: plugin.id,
        nodeTypeId: 'discord.webhook',
        params: const {
          'webhookUrl': 'https://discord.com/api/webhooks/123/abc',
          'content': 'hello world',
        },
      );
      expect(result.success, isTrue, reason: 'message=${result.message}');
    });

    test('embed payload includes title + description + color', () async {
      Map<String, dynamic>? capturedBody;
      final mockClient = MockClient((request) async {
        capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('', 204);
      });
      final plugin = DiscordWebhookPlugin(clientBuilder: () => mockClient);
      final host = PluginHost();
      addTearDown(host.dispose);
      await host.registerPlugin(plugin);

      final executor = PluginNodeExecutor(
        host: host,
        registry: host.nodeRegistry,
      );
      final result = await executor.run(
        pluginId: plugin.id,
        nodeTypeId: 'discord.webhook',
        params: const {
          'webhookUrl': 'https://discord.com/api/webhooks/123/abc',
          'embedTitle': 'Sequence complete',
          'embedDescription': 'Captured 240/240 frames',
          'embedColor': 0x00FF00,
        },
      );
      expect(result.success, isTrue);
      expect(capturedBody, isNotNull);
      expect(capturedBody!['embeds'], isList);
      final embed = (capturedBody!['embeds'] as List).first as Map;
      expect(embed['title'], equals('Sequence complete'));
      expect(embed['description'], equals('Captured 240/240 frames'));
      expect(embed['color'], equals(0x00FF00));
    });
  });

  group('HomeAssistantPlugin', () {
    test('rejects non-http connection URLs', () async {
      final plugin = HomeAssistantPlugin();
      final host = PluginHost();
      addTearDown(host.dispose);
      await host.registerPlugin(plugin);

      expect(
        () => plugin.configureConnection(
          baseUrl: 'ftp://homeassistant.local',
          accessToken: 'token-abc',
        ),
        throwsA(isA<PluginException>()),
      );
    });

    test('rejects malformed entity ids', () {
      final plugin = HomeAssistantPlugin();
      final node = plugin.nodeDefinitions.first.createNode({
        'entityId': 'no-dot-here',
      });
      expect(node!.validate(), contains('domain.entity'));
    });

    test('rejects unsupported services', () {
      final plugin = HomeAssistantPlugin();
      final node = plugin.nodeDefinitions.first.createNode({
        'entityId': 'switch.dew_heater',
        'service': 'delete_universe',
      });
      expect(node!.validate(), contains('service'));
    });

    test('calls correct HA service endpoint', () async {
      Uri? requestUrl;
      Map<String, String>? requestHeaders;
      Map<String, dynamic>? requestBody;
      final mockClient = MockClient((request) async {
        requestUrl = request.url;
        requestHeaders = request.headers;
        requestBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('[]', 200);
      });
      final plugin = HomeAssistantPlugin(clientBuilder: () => mockClient);
      final host = PluginHost();
      addTearDown(host.dispose);
      await host.registerPlugin(plugin);
      await plugin.configureConnection(
        baseUrl: 'http://homeassistant.local:8123/',
        accessToken: 'token-abc',
      );

      final executor = PluginNodeExecutor(
        host: host,
        registry: host.nodeRegistry,
      );
      final result = await executor.run(
        pluginId: plugin.id,
        nodeTypeId: 'home_assistant.toggle',
        params: const {
          'entityId': 'switch.dew_heater',
          'service': 'turn_on',
          'confirmStateAfterSecs': 0,
        },
      );
      expect(result.success, isTrue, reason: 'message=${result.message}');
      expect(
        requestUrl.toString(),
        equals('http://homeassistant.local:8123/api/services/switch/turn_on'),
      );
      expect(requestHeaders!['authorization'], equals('Bearer token-abc'));
      expect(requestBody!['entity_id'], equals('switch.dew_heater'));
    });

    test('state confirmation reports failure on mismatch', () async {
      final mockClient = MockClient((request) async {
        if (request.method == 'POST') {
          return http.Response('[]', 200);
        }
        // GET /api/states/<entity>
        return http.Response(
          jsonEncode({'entity_id': 'switch.dew_heater', 'state': 'off'}),
          200,
        );
      });
      final plugin = HomeAssistantPlugin(clientBuilder: () => mockClient);
      final host = PluginHost();
      addTearDown(host.dispose);
      await host.registerPlugin(plugin);
      await plugin.configureConnection(
        baseUrl: 'http://homeassistant.local:8123',
        accessToken: 'token-abc',
      );

      final executor = PluginNodeExecutor(
        host: host,
        registry: host.nodeRegistry,
      );
      final result = await executor.run(
        pluginId: plugin.id,
        nodeTypeId: 'home_assistant.toggle',
        params: const {
          'entityId': 'switch.dew_heater',
          'service': 'turn_on',
          'confirmStateAfterSecs': 1,
          'expectedState': 'on',
        },
      );
      expect(result.success, isFalse);
      expect(result.message, contains('reported failure'));
    });
  });
}

// Test fixtures

/// A minimal SequencePlugin with two nodes; used by the registry / executor
/// tests above without needing any external services.
class _DummySequencePlugin extends SequencePlugin {
  @override
  String get id => 'com.skotiq.test.dummy';

  @override
  String get name => 'Test Dummy';

  @override
  String get version => '0.1.0';

  @override
  String get description => 'Test plugin';

  @override
  String get author => 'tests';

  @override
  Future<void> onLoad(PluginContext context) async {}

  @override
  Future<void> onUnload() async {}

  @override
  List<SequenceNodeDefinition> get nodeDefinitions => [
    SequenceNodeDefinition(
      id: 'dummy.always_succeeds',
      name: 'Dummy: Always Succeeds',
      category: 'Test',
      description: 'Returns success',
      createNode: (_) => _AlwaysSucceedsNode(),
    ),
    SequenceNodeDefinition(
      id: 'dummy.always_fails',
      name: 'Dummy: Always Fails',
      category: 'Test',
      description: 'Returns failure',
      createNode: (_) => _AlwaysFailsNode(),
    ),
    // Additional fixture: a node that rejects empty input via validate().
    SequenceNodeDefinition(
      id: 'dummy.requires_param',
      name: 'Dummy: Requires Param',
      category: 'Test',
      description: 'Validates a required string parameter',
      createNode: (params) => _RequiresParamNode(params['name'] as String?),
    ),
  ];
}

class _AlwaysSucceedsNode implements PluginSequenceNode {
  @override
  Future<bool> execute(PluginContext context) async => true;
  @override
  String? validate() => null;
}

class _AlwaysFailsNode implements PluginSequenceNode {
  @override
  Future<bool> execute(PluginContext context) async => false;
  @override
  String? validate() => null;
}

class _RequiresParamNode implements PluginSequenceNode {
  final String? name;
  _RequiresParamNode(this.name);
  @override
  Future<bool> execute(PluginContext context) async => true;
  @override
  String? validate() {
    if (name == null || name!.isEmpty) return 'name is required';
    return null;
  }
}

class _ThrowingSequencePlugin extends SequencePlugin {
  @override
  String get id => 'com.skotiq.test.throwing';
  @override
  String get name => 'Throwing';
  @override
  String get version => '0.1.0';
  @override
  String get description => 'Test plugin';
  @override
  String get author => 'tests';

  @override
  Future<void> onLoad(PluginContext context) async {}
  @override
  Future<void> onUnload() async {}

  @override
  List<SequenceNodeDefinition> get nodeDefinitions => [
    SequenceNodeDefinition(
      id: 'throwing.boom',
      name: 'Throwing: Boom',
      category: 'Test',
      description: 'Throws inside execute',
      createNode: (_) => _ThrowingNode(),
    ),
  ];
}

class _ThrowingNode implements PluginSequenceNode {
  @override
  Future<bool> execute(PluginContext context) async {
    throw StateError('intentional boom');
  }

  @override
  String? validate() => null;
}

class _HangingSequencePlugin extends SequencePlugin {
  @override
  String get id => 'com.skotiq.test.hanging';
  @override
  String get name => 'Hanging';
  @override
  String get version => '0.1.0';
  @override
  String get description => 'Test plugin';
  @override
  String get author => 'tests';

  @override
  Future<void> onLoad(PluginContext context) async {}
  @override
  Future<void> onUnload() async {}

  @override
  List<SequenceNodeDefinition> get nodeDefinitions => [
    SequenceNodeDefinition(
      id: 'hanging.forever',
      name: 'Hanging: Forever',
      category: 'Test',
      description: 'Never returns',
      createNode: (_) => _HangingNode(),
    ),
  ];
}

class _HangingNode implements PluginSequenceNode {
  @override
  Future<bool> execute(PluginContext context) async {
    final completer = Completer<bool>();
    // Never completes.
    return completer.future;
  }

  @override
  String? validate() => null;
}

class _CountingSequencePlugin extends SequencePlugin {
  int invocationCount = 0;

  @override
  String get id => 'com.skotiq.test.counting';
  @override
  String get name => 'Counting';
  @override
  String get version => '0.1.0';
  @override
  String get description => 'Test plugin';
  @override
  String get author => 'tests';

  @override
  Future<void> onLoad(PluginContext context) async {}
  @override
  Future<void> onUnload() async {}

  @override
  List<SequenceNodeDefinition> get nodeDefinitions => [
    SequenceNodeDefinition(
      id: 'counting.tick',
      name: 'Counting: Tick',
      category: 'Test',
      description: 'Increments a counter each invocation',
      createNode: (_) => _CountingNode(this),
    ),
  ];
}

class _CountingNode implements PluginSequenceNode {
  final _CountingSequencePlugin plugin;
  _CountingNode(this.plugin);

  @override
  Future<bool> execute(PluginContext context) async {
    plugin.invocationCount++;
    return true;
  }

  @override
  String? validate() => null;
}
