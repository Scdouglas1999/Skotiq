// Full-stack tunnel test:
//
//   fake appliance HTTP/WS server  <--loopback--  RelayUplink (appliance)
//        |                                              | outbound WS
//        |                                              v
//        +----------------------------------------- RelayServer
//                                                       ^ WS
//                                                       |
//   client HTTP/WS  --loopback-->  RelayTunnelClient (phone)
//
// Everything runs in one isolate on loopback ephemeral ports. This proves
// the whole splice end to end: registration, stream-id rewriting across the
// relay, half-close (HTTP request/response), a WebSocket upgrade carried as
// opaque tunnel bytes, and concurrent streams over a single uplink.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:skotiq_relay/skotiq_relay.dart';
import 'package:test/test.dart';

void main() {
  late RelayServer relay;
  late HttpServer fakeAppliance;
  late RelayUplink uplink;
  RelayTunnelClient? tunnel;

  setUp(() async {
    // 1. Fake "headless" appliance HTTP server with a REST route and a WS
    //    echo upgrade.
    fakeAppliance = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    fakeAppliance.listen((request) async {
      if (request.uri.path == '/api/info') {
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'mode': 'headless', 'version': '2.0.0'}));
        await request.response.close();
        return;
      }
      if (request.uri.path == '/ws/echo' &&
          WebSocketTransformer.isUpgradeRequest(request)) {
        final ws = await WebSocketTransformer.upgrade(request);
        ws.listen((m) => ws.add('echo:$m'), onDone: () {});
        return;
      }
      if (request.uri.path == '/api/big') {
        // 256 KiB body to exercise multi-frame chunking through the tunnel.
        request.response
          ..statusCode = 200
          ..add(List.filled(256 * 1024, 0x41));
        await request.response.close();
        return;
      }
      request.response.statusCode = 404;
      await request.response.close();
    });

    // 2. Relay on an ephemeral port.
    relay = RelayServer(const RelayServerConfig(port: 0));
    await relay.start();

    // 3. Appliance uplink dialing the relay, proxying to the fake server.
    final registered = Completer<String>();
    uplink = RelayUplink(
      relayUrl: Uri.parse('ws://127.0.0.1:${relay.port}'),
      localPort: fakeAppliance.port,
      credentialsStore: MemoryRelayCredentialsStore(),
      onStatus: (s) {
        if (s.state == RelayUplinkState.connected &&
            s.applianceId != null &&
            !registered.isCompleted) {
          registered.complete(s.applianceId!);
        }
      },
    );
    uplink.start();
    final applianceId = await registered.future.timeout(
      const Duration(seconds: 10),
    );

    // 4. Phone tunnel client.
    tunnel = await RelayTunnelClient.connect(
      relayUrl: Uri.parse('ws://127.0.0.1:${relay.port}'),
      applianceId: applianceId,
    );
  });

  tearDown(() async {
    await tunnel?.close();
    await uplink.stop();
    await relay.stop();
    await fakeAppliance.close(force: true);
  });

  test('REST GET round-trips through the tunnel', () async {
    final client = HttpClient();
    final req = await client.getUrl(
      Uri.parse('http://127.0.0.1:${tunnel!.localPort}/api/info'),
    );
    final resp = await req.close();
    expect(resp.statusCode, 200);
    final body = jsonDecode(await resp.transform(utf8.decoder).join()) as Map;
    expect(body['mode'], 'headless');
    client.close();
  });

  test('a large response is reassembled intact across mux frames', () async {
    final client = HttpClient();
    final req = await client.getUrl(
      Uri.parse('http://127.0.0.1:${tunnel!.localPort}/api/big'),
    );
    final resp = await req.close();
    expect(resp.statusCode, 200);
    final bytes = await resp.fold<int>(0, (sum, chunk) => sum + chunk.length);
    expect(bytes, 256 * 1024);
    client.close();
  });

  test('WebSocket upgrade flows through the tunnel', () async {
    final ws = await WebSocket.connect(
      'ws://127.0.0.1:${tunnel!.localPort}/ws/echo',
    );
    final replies = <String>[];
    final got = Completer<void>();
    ws.listen((m) {
      replies.add(m as String);
      if (replies.length == 2 && !got.isCompleted) got.complete();
    });
    ws.add('hello');
    ws.add('world');
    await got.future.timeout(const Duration(seconds: 5));
    expect(replies, ['echo:hello', 'echo:world']);
    await ws.close();
  });

  test('concurrent REST requests share one uplink correctly', () async {
    final client = HttpClient();
    Future<String> fetchMode() async {
      final req = await client.getUrl(
        Uri.parse('http://127.0.0.1:${tunnel!.localPort}/api/info'),
      );
      final resp = await req.close();
      final body = jsonDecode(await resp.transform(utf8.decoder).join()) as Map;
      return body['mode'] as String;
    }

    final results = await Future.wait(List.generate(8, (_) => fetchMode()));
    expect(results, everyElement('headless'));
    client.close();
  });

  test('a second phone can tunnel through the same appliance', () async {
    final second = await RelayTunnelClient.connect(
      relayUrl: Uri.parse('ws://127.0.0.1:${relay.port}'),
      applianceId: uplink.applianceId!,
    );
    try {
      final client = HttpClient();
      final req = await client.getUrl(
        Uri.parse('http://127.0.0.1:${second.localPort}/api/info'),
      );
      final resp = await req.close();
      expect(resp.statusCode, 200);
      await resp.drain<void>();
      client.close();
    } finally {
      await second.close();
    }
  });
}
