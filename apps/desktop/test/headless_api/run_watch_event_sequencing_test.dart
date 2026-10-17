import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api_server.dart';

import 'handler_test_helpers.dart';

/// The run-watch SSE feed and the WebSocket `/events` feed carry the SAME
/// stamped event.
///
/// The phone's run-watch feed de-dupes on the pair (serverInstanceId, seq) the
/// server stamps, because a host stamps a whole burst with one millisecond and
/// a timestamp+type key collapses those siblings onto one row. That pair only
/// works if the event reaching the SSE fan-out is the STAMPED one: the
/// lifecycle used to broadcast the stamped copy to the WebSocket clients and
/// hand the RAW, seq-less original to the run-watch controller, so every event
/// on this feed arrived with no seq at all and the de-dup had nothing to key
/// on.
void main() {
  late ProviderContainer container;
  late HeadlessApiServer server;

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
  });

  tearDown(() async {
    await server.stop();
    container.dispose();
  });

  test('the run-watch feed carries the seq its de-dup keys on', () async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${server.actualPort}/api/run-watch/events'),
    );
    request.headers.set('Authorization', 'Bearer admin-token');
    final response = await request.close();
    expect(response.statusCode, 200);

    final frames = <String>[];
    final gotTwo = Completer<void>();
    final sub = response.transform(utf8.decoder).listen((chunk) {
      frames.add(chunk);
      final data = frames
          .join()
          .split('\n')
          .where((line) => line.startsWith('data: '))
          .toList();
      if (data.length >= 2 && !gotTwo.isCompleted) gotTwo.complete();
    });
    addTearDown(sub.cancel);

    // Let the SSE controller's onListen run before anything is published:
    // this is a broadcast stream, so an event published first reaches nobody.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final hub = container.read(hostMutationEventHubProvider);
    // Two events in the SAME millisecond, of the SAME type — the burst a
    // timestamp+type key collapses to one row.
    hub.publishRemoteOnly(entityType: 'sequencer', action: 'paused');
    hub.publishRemoteOnly(entityType: 'sequencer', action: 'paused');

    await gotTwo.future.timeout(const Duration(seconds: 5));

    final payloads = frames
        .join()
        .split('\n')
        .where((line) => line.startsWith('data: '))
        .map((line) => jsonDecode(line.substring(6)) as Map<String, dynamic>)
        .toList();
    expect(payloads, hasLength(greaterThanOrEqualTo(2)));

    for (final payload in payloads) {
      expect(
        payload['seq'],
        isA<int>(),
        reason:
            'a run-watch event with no seq leaves the feed de-duping on '
            'timestamp+type, which drops same-millisecond siblings',
      );
      expect(payload['serverInstanceId'], isA<String>());
    }
    // The pair the client keys on actually separates the two.
    expect(payloads[0]['seq'], isNot(payloads[1]['seq']));
    expect(payloads[0]['serverInstanceId'], payloads[1]['serverInstanceId']);
  });
}
