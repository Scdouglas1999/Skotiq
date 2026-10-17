import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api_server.dart';

import 'handler_test_helpers.dart';

void main() {
  late ProviderContainer container;
  late HeadlessApiServer server;
  late WebSocket socket;
  late StreamIterator<dynamic> messages;

  setUp(() async {
    container = createHeadlessTestContainer(
      overrides: [
        appVersionProvider.overrideWithValue(
          const AppVersionInfo(version: '6.0.0', buildNumber: 1),
        ),
      ],
    );
    server = HeadlessApiServer(
      port: 0,
      container: container,
      bindLocalOnly: true,
      authToken: 'admin-token',
      webSocketHeartbeatInterval: const Duration(hours: 1),
      webSocketHeartbeatTimeout: const Duration(hours: 2),
    );
    await server.start();
    socket = await WebSocket.connect(
      'ws://127.0.0.1:${server.actualPort}'
      '/events?token=admin-token&apiVersion=2.6.0',
    );
    messages = StreamIterator<dynamic>(socket);
    expect(await messages.moveNext(), isTrue);
    expect(
      (jsonDecode(messages.current as String) as Map)['type'],
      'collaboration_state',
    );
  });

  tearDown(() async {
    await messages.cancel();
    await socket.close();
    await server.stop();
    container.dispose();
  });

  test('upgrade control flow is not logged as a request failure', () async {
    await Future<void>.delayed(Duration.zero);

    final failures = container
        .read(loggingServiceProvider)
        .getRecentLogs()
        .where(
          (entry) =>
              entry.message.contains('underlying data stream was hijacked') ||
              entry.message.contains('GET /events failed'),
        );
    expect(failures, isEmpty);
  });

  test(
    'BigInt event fields are serialized without dropping the event',
    () async {
      server.broadcastEvent(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.info,
          category: EventCategory.equipment,
          eventType: 'HeartbeatStatusChanged',
          data: {
            'small': BigInt.from(42),
            'large': BigInt.parse('18446744073709551615'),
            'nested': [
              {'rtt': BigInt.from(17)},
            ],
          },
        ),
      );

      expect(await messages.moveNext(), isTrue);
      final event = jsonDecode(messages.current as String) as Map;
      expect(event['type'], 'event');
      expect(event['eventType'], 'HeartbeatStatusChanged');
      final data = event['data'] as Map;
      expect(data['small'], 42);
      expect(data['large'], '18446744073709551615');
      expect((data['nested'] as List).single, {'rtt': 17});

      final encodingFailures = container
          .read(loggingServiceProvider)
          .getRecentLogs()
          .where(
            (entry) =>
                entry.message.contains('Error encoding event for broadcast'),
          );
      expect(encodingFailures, isEmpty);
    },
  );
}
