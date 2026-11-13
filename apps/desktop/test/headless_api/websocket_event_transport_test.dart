import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_desktop/headless_api/auth_policy.dart';
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
      scopedAuthTokens: const {'control-token': HeadlessTokenScope.control},
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

  group('a credential setting change', () {
    SkotiqEvent webhookChanged() => SkotiqEvent(
      timestamp: DateTime.now().millisecondsSinceEpoch,
      severity: EventSeverity.info,
      category: EventCategory.system,
      eventType: settingsChangedEventType,
      data: const {
        'key': 'discordWebhook',
        'value': 'https://discord.com/api/webhooks/1/secret',
      },
    );

    Future<StreamIterator<dynamic>> connect(
      String token, {
      String? since,
    }) async {
      final linked = await WebSocket.connect(
        'ws://127.0.0.1:${server.actualPort}'
        '/events?token=$token&apiVersion=2.6.0${since ?? ''}',
      );
      addTearDown(linked.close);
      final frames = StreamIterator<dynamic>(linked);
      addTearDown(frames.cancel);
      return frames;
    }

    Future<Map> nextEvent(StreamIterator<dynamic> frames) async {
      while (await frames.moveNext()) {
        final frame = jsonDecode(frames.current as String) as Map;
        if (frame['type'] == 'event') return frame;
      }
      fail('the socket closed before an event arrived');
    }

    test('reaches a link with admin access as the value and any other link '
        'as the marker', () async {
      final control = await connect('control-token');
      // The control socket's first frame says it is attached.
      expect(await control.moveNext(), isTrue);

      server.broadcastEvent(webhookChanged());

      expect(
        ((await nextEvent(messages))['data'] as Map)['value'],
        'https://discord.com/api/webhooks/1/secret',
      );
      expect(
        ((await nextEvent(control))['data'] as Map)['value'],
        credentialSetMarker,
      );
    });

    test('is replayed and listed with the marker to a link without admin '
        'access', () async {
      final stamped = server.broadcastEvent(webhookChanged())!;
      await nextEvent(messages);

      final replayed = await connect(
        'control-token',
        since: '&since=0&instance=${stamped.serverInstanceId}',
      );
      final replay = await nextEvent(replayed);
      expect(replay['replay'], isTrue);
      expect((replay['data'] as Map)['value'], credentialSetMarker);

      Future<List> recentEvents(String token) async {
        final client = HttpClient();
        addTearDown(client.close);
        final request = await client.getUrl(
          Uri.parse(
            'http://127.0.0.1:${server.actualPort}/api/runtime/recent-events',
          ),
        );
        request.headers.set('Authorization', 'Bearer $token');
        final response = await request.close();
        expect(response.statusCode, HttpStatus.ok);
        final body =
            jsonDecode(await utf8.decodeStream(response))
                as Map<String, dynamic>;
        return [
          for (final event in body['events'] as List)
            if ((event as Map)['eventType'] == settingsChangedEventType) event,
        ];
      }

      expect(
        ((await recentEvents('control-token')).single['data'] as Map)['value'],
        credentialSetMarker,
      );
      expect(
        ((await recentEvents('admin-token')).single['data'] as Map)['value'],
        'https://discord.com/api/webhooks/1/secret',
      );
    });
  });
}
