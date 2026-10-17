import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api_server.dart';

import 'handler_test_helpers.dart';

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

class _PluginVerdict {
  final String nodeId;
  final bool success;
  final String? message;
  final String? structuredDetailJson;

  const _PluginVerdict({
    required this.nodeId,
    required this.success,
    this.message,
    this.structuredDetailJson,
  });
}

class _PluginDispatchBackend extends DisconnectedBackend {
  _PluginDispatchBackend({required this.events});

  final Stream<SkotiqEvent> events;
  bool dispatchLocally = true;
  final List<_PluginVerdict> verdicts = [];

  @override
  Stream<SkotiqEvent> get eventStream => events;

  @override
  bool get dispatchPluginNodesLocally => dispatchLocally;

  @override
  Future<void> sequencerPluginNodeFinished({
    required String nodeId,
    required bool success,
    String? message,
    String? structuredDetailJson,
  }) async {
    verdicts.add(
      _PluginVerdict(
        nodeId: nodeId,
        success: success,
        message: message,
        structuredDetailJson: structuredDetailJson,
      ),
    );
  }
}

void main() {
  late StreamController<SkotiqEvent> events;
  late _PluginDispatchBackend backend;
  ProviderContainer? container;
  HeadlessApiServer? server;

  setUp(() async {
    events = StreamController<SkotiqEvent>.broadcast();
    backend = _PluginDispatchBackend(events: events.stream);
  });

  tearDown(() async {
    await server?.stop();
    container?.dispose();
    await events.close();
  });

  Future<void> startServer({required PluginNodeDispatcher dispatcher}) async {
    final testContainer = createHeadlessTestContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
        pluginNodeDispatcherProvider.overrideWithValue(dispatcher),
      ],
    );
    container = testContainer;
    final testServer = HeadlessApiServer(port: 0, container: testContainer);
    server = testServer;
    await testServer.start();
  }

  SkotiqEvent pluginRequest(String nodeId) {
    return SkotiqEvent(
      timestamp: DateTime.now().millisecondsSinceEpoch,
      severity: EventSeverity.info,
      category: EventCategory.sequencer,
      eventType: 'PluginNodeRequested',
      data: {
        'node_id': nodeId,
        'plugin_id': 'com.example.notify',
        'node_type_id': 'notify.send',
        'config_json': '{"message":"hello"}',
        'display_name': 'Notify',
        'timeout_secs': 12,
      },
    );
  }

  test(
    'dispatches PluginNodeRequested events from the headless host stream',
    () async {
      PluginNodeDispatchRequest? captured;
      await startServer(
        dispatcher: (request) async {
          captured = request;
          return const PluginNodeDispatchResult(
            success: true,
            message: 'sent',
            structuredDetailJson: '{"provider":"test"}',
          );
        },
      );

      events.add(pluginRequest('plugin-node-headless'));

      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        if (backend.verdicts.isNotEmpty) {
          final verdict = backend.verdicts.single;
          expect(verdict.nodeId, 'plugin-node-headless');
          expect(verdict.success, isTrue);
          expect(verdict.message, 'sent');
          expect(verdict.structuredDetailJson, '{"provider":"test"}');
          expect(captured, isNotNull);
          expect(captured!.pluginId, 'com.example.notify');
          expect(captured!.nodeTypeId, 'notify.send');
          expect(captured!.configJson, '{"message":"hello"}');
          expect(captured!.displayName, 'Notify');
          expect(captured!.timeoutSecs, 12);
          return;
        }
      }

      fail('Headless API server never posted the plugin node verdict');
    },
  );

  test(
    'does not dispatch when the backend marks plugin dispatch remote',
    () async {
      backend.dispatchLocally = false;
      var dispatched = false;
      await startServer(
        dispatcher: (request) async {
          dispatched = true;
          return const PluginNodeDispatchResult(success: true);
        },
      );

      events.add(pluginRequest('plugin-node-network'));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(dispatched, isFalse);
      expect(backend.verdicts, isEmpty);
    },
  );
}
