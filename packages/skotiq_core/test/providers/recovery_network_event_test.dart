import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/backend/bridge_event_mapper.dart';

class _NetworkBackendNotifier extends BackendNotifier {
  _NetworkBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

void main() {
  test('DeviceDisconnected recovery cause has stable labels', () {
    final cause = RecoveryCause.deviceDisconnected();

    expect(cause.kind, 'DeviceDisconnected');
    expect(cause.displayLabel, 'Device disconnected');
    expect(cause.wireKey, 'device_disconnected');
    expect(RecoveryCause.fromJson('DeviceDisconnected'), cause);
  });

  group('Recovery events over NetworkBackend', () {
    test(
      'skotiqEventsProvider delivers typed RecoveryStarted from WS',
      () async {
        final started = Completer<void>();
        final server = await _startServer((socket) {
          Timer(const Duration(milliseconds: 50), () {
            final now = DateTime.utc(2026, 5, 23, 14);
            socket.add(
              jsonEncode({
                'type': 'event',
                'timestamp': now.millisecondsSinceEpoch,
                'severity': 'critical',
                'category': 'sequencer',
                'eventType': 'RecoveryStarted',
                'data': recoveryFieldsFromTyped(
                  startedAtIso: now.toIso8601String(),
                  causeKind: 'WeatherUnsafe',
                  causeCustomLabel: null,
                  lastAttemptAtIso: now.toIso8601String(),
                  attemptCount: 2,
                  maxAttempts: 5,
                  retryIntervalSecs: 300.0,
                  maxDurationSecs: 1800.0,
                  phase: 'Attempting',
                  lastError: 'cloud cover',
                ),
              }),
            );
          });
          socket.listen((message) {
            final data = jsonDecode(message as String) as Map<String, dynamic>;
            if (data['type'] == 'ping') {
              socket.add(jsonEncode({'type': 'pong'}));
            }
          });
        });

        final backend = NetworkBackend(
          serverHost: InternetAddress.loopbackIPv4.address,
          serverPort: server.port,
          webSocketPort: server.port,
          webSocketHeartbeatInterval: const Duration(milliseconds: 50),
          webSocketHeartbeatTimeout: const Duration(milliseconds: 250),
        );

        final container = ProviderContainer(
          overrides: [
            backendProvider.overrideWith(
              (ref) => _NetworkBackendNotifier(ref, backend),
            ),
          ],
        );
        addTearDown(container.dispose);

        container.read(recoveryEventBridgeProvider);

        container.listen(skotiqEventsProvider, (_, next) {
          next.whenData((event) {
            final envelope = recoveryEnvelopeFromBridgeForTest(event);
            if (envelope?.kind == RecoveryEventKind.started) {
              if (!started.isCompleted) started.complete();
            }
          });
        }, fireImmediately: true);

        try {
          await started.future.timeout(const Duration(seconds: 3));
          await _waitUntil(
            () => container.read(currentRecoveryProvider) != null,
          );

          final live = container.read(currentRecoveryProvider);
          expect(live, isNotNull);
          expect(live!.cause.kind, 'WeatherUnsafe');
          expect(live.attemptCount, 2);
          expect(live.maxAttempts, 5);
          expect(live.phase, RecoveryPhase.attempting);
          expect(
            container.read(sequenceProgressProvider).state,
            SequenceExecutionState.recovering,
          );
        } finally {
          backend.dispose();
          await server.close(force: true);
        }
      },
    );
  });
}

Future<HttpServer> _startServer(
  void Function(WebSocket socket) onConnect, {
  Map<String, dynamic> infoBody = const {'version': '2.5.0'},
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

  server.listen((request) async {
    if (request.uri.path == '/api/info') {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(infoBody));
      await request.response.close();
      return;
    }

    if (request.uri.path == '/events') {
      final socket = await WebSocketTransformer.upgrade(request);
      onConnect(socket);
      return;
    }

    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  });

  return server;
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  if (!condition()) {
    fail('Condition not met within $timeout');
  }
}
