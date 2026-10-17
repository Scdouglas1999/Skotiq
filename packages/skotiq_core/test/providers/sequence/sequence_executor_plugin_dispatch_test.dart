// Verify the SequenceExecutor routes a typed
// `PluginNodeRequested` event through the `pluginNodeDispatcherProvider`
// and posts the verdict back through `backend.sequencerPluginNodeFinished`.
//
// We don't pull in the real `PluginNodeExecutor` here — that lives in
// `skotiq_plugins`, which `skotiq_core` does NOT depend on.
// Instead we override the dispatcher provider with a synchronous stub
// that captures the request and returns a canned verdict. This proves
// the Rust↔Dart roundtrip plumbing on the Dart side end-to-end:
//
//   * The event-stream subscription forwards the typed
//     `PluginNodeRequested` payload into `_handleSequencerEvent`.
//   * `_dispatchPluginNode` reads the (overridden) dispatcher provider
//     and invokes it with the request.
//   * The verdict is forwarded to `backend.sequencerPluginNodeFinished`
//     with the verbatim `success` / `message` / `structuredDetailJson`.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart' as bridge_event;

import '../../mocks/mock_backend.dart';

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

void main() {
  setUpAll(() {
    registerMocktailFallbackValues();
  });

  late MockBackend backend;
  late StreamController<bridge_event.SkotiqEvent> eventController;

  setUp(() {
    backend = MockBackend();
    eventController = StreamController<bridge_event.SkotiqEvent>.broadcast();
    when(() => backend.eventStream).thenAnswer((_) => eventController.stream);
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    when(() => backend.dispatchPluginNodesLocally).thenReturn(true);
  });

  tearDown(() async {
    await eventController.close();
  });

  ProviderContainer buildContainer({required PluginNodeDispatcher dispatcher}) {
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
        pluginNodeDispatcherProvider.overrideWithValue(dispatcher),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test(
    'routes PluginNodeRequested → dispatcher → sequencerPluginNodeFinished',
    () async {
      PluginNodeDispatchRequest? capturedRequest;
      Future<PluginNodeDispatchResult> dispatcher(
        PluginNodeDispatchRequest request,
      ) async {
        capturedRequest = request;
        return const PluginNodeDispatchResult(
          success: true,
          message: 'delivered',
          structuredDetailJson: '{"phase":"finished","delivery_id":"test-1"}',
        );
      }

      final container = buildContainer(dispatcher: dispatcher);
      final executor = container.read(sequenceExecutorProvider);

      when(
        () => backend.sequencerPluginNodeFinished(
          nodeId: any(named: 'nodeId'),
          success: any(named: 'success'),
          message: any(named: 'message'),
          structuredDetailJson: any(named: 'structuredDetailJson'),
        ),
      ).thenAnswer((_) async {});

      executor.handleSequencerEventForTest(
        bridge_event.SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: bridge_event.EventSeverity.info,
          category: bridge_event.EventCategory.sequencer,
          eventType: 'PluginNodeRequested',
          data: const {
            'node_id': 'plugin-node-1',
            'plugin_id': 'com.example.pushover',
            'node_type_id': 'pushover.notify',
            'config_json': '{"title":"E2E","message":"Hello"}',
            'display_name': 'Pushover',
            'timeout_secs': 30,
          },
        ),
      );

      // The dispatcher runs async + the reply is fire-and-forget; poll
      // the mock until the verdict was posted.
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        try {
          verify(
            () => backend.sequencerPluginNodeFinished(
              nodeId: 'plugin-node-1',
              success: true,
              message: 'delivered',
              structuredDetailJson:
                  '{"phase":"finished","delivery_id":"test-1"}',
            ),
          ).called(1);
          // If verify succeeded, also check the dispatcher saw the right
          // request payload.
          expect(capturedRequest, isNotNull);
          expect(capturedRequest!.pluginId, 'com.example.pushover');
          expect(capturedRequest!.nodeTypeId, 'pushover.notify');
          expect(
            capturedRequest!.configJson,
            '{"title":"E2E","message":"Hello"}',
          );
          expect(capturedRequest!.displayName, 'Pushover');
          expect(capturedRequest!.timeoutSecs, 30);
          return;
        } catch (_) {
          // not yet — keep polling
        }
      }
      fail('SequenceExecutor never posted the plugin verdict to the backend');
    },
  );

  test(
    'failure verdict propagates through to sequencerPluginNodeFinished(success=false)',
    () async {
      Future<PluginNodeDispatchResult> dispatcher(
        PluginNodeDispatchRequest request,
      ) async {
        return const PluginNodeDispatchResult(
          success: false,
          message: 'HTTP 500',
        );
      }

      final container = buildContainer(dispatcher: dispatcher);
      final executor = container.read(sequenceExecutorProvider);

      when(
        () => backend.sequencerPluginNodeFinished(
          nodeId: any(named: 'nodeId'),
          success: any(named: 'success'),
          message: any(named: 'message'),
          structuredDetailJson: any(named: 'structuredDetailJson'),
        ),
      ).thenAnswer((_) async {});

      executor.handleSequencerEventForTest(
        bridge_event.SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: bridge_event.EventSeverity.info,
          category: bridge_event.EventCategory.sequencer,
          eventType: 'PluginNodeRequested',
          data: const {
            'node_id': 'plugin-node-fail',
            'plugin_id': 'com.example.failing',
            'node_type_id': 'failing.always',
            'config_json': '',
            'display_name': null,
            'timeout_secs': 10,
          },
        ),
      );

      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        try {
          verify(
            () => backend.sequencerPluginNodeFinished(
              nodeId: 'plugin-node-fail',
              success: false,
              message: 'HTTP 500',
              structuredDetailJson: null,
            ),
          ).called(1);
          return;
        } catch (_) {
          // poll
        }
      }
      fail('SequenceExecutor never posted the failure verdict to the backend');
    },
  );

  test(
    'dispatcher throw is caught and surfaced as a failure verdict',
    () async {
      Future<Never> dispatcher(PluginNodeDispatchRequest request) async {
        throw StateError('boom');
      }

      final container = buildContainer(dispatcher: dispatcher);
      final executor = container.read(sequenceExecutorProvider);

      when(
        () => backend.sequencerPluginNodeFinished(
          nodeId: any(named: 'nodeId'),
          success: any(named: 'success'),
          message: any(named: 'message'),
          structuredDetailJson: any(named: 'structuredDetailJson'),
        ),
      ).thenAnswer((_) async {});

      executor.handleSequencerEventForTest(
        bridge_event.SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: bridge_event.EventSeverity.info,
          category: bridge_event.EventCategory.sequencer,
          eventType: 'PluginNodeRequested',
          data: const {
            'node_id': 'plugin-node-throws',
            'plugin_id': 'com.example.broken',
            'node_type_id': 'broken.kaboom',
            'config_json': '',
            'display_name': null,
            'timeout_secs': 5,
          },
        ),
      );

      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        try {
          verify(
            () => backend.sequencerPluginNodeFinished(
              nodeId: 'plugin-node-throws',
              success: false,
              message: any(named: 'message', that: contains('boom')),
              structuredDetailJson: any(named: 'structuredDetailJson'),
            ),
          ).called(1);
          return;
        } catch (_) {
          // poll
        }
      }
      fail('SequenceExecutor never posted the throw-fallback verdict');
    },
  );

  test('network/remote backends leave plugin dispatch to the host', () async {
    when(() => backend.dispatchPluginNodesLocally).thenReturn(false);
    var dispatched = false;
    Future<PluginNodeDispatchResult> dispatcher(
      PluginNodeDispatchRequest request,
    ) async {
      dispatched = true;
      return const PluginNodeDispatchResult(success: true);
    }

    final container = buildContainer(dispatcher: dispatcher);
    final executor = container.read(sequenceExecutorProvider);

    when(
      () => backend.sequencerPluginNodeFinished(
        nodeId: any(named: 'nodeId'),
        success: any(named: 'success'),
        message: any(named: 'message'),
        structuredDetailJson: any(named: 'structuredDetailJson'),
      ),
    ).thenAnswer((_) async {});

    executor.handleSequencerEventForTest(
      bridge_event.SkotiqEvent(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        severity: bridge_event.EventSeverity.info,
        category: bridge_event.EventCategory.sequencer,
        eventType: 'PluginNodeRequested',
        data: const {
          'node_id': 'plugin-node-remote',
          'plugin_id': 'com.example.remote',
          'node_type_id': 'remote.noop',
          'config_json': '{}',
          'display_name': null,
          'timeout_secs': 5,
        },
      ),
    );

    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(dispatched, isFalse);
    verifyNever(
      () => backend.sequencerPluginNodeFinished(
        nodeId: any(named: 'nodeId'),
        success: any(named: 'success'),
        message: any(named: 'message'),
        structuredDetailJson: any(named: 'structuredDetailJson'),
      ),
    );
  });
}
