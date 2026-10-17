// Integration coverage for the pairing / WebSocket throttling:
//   * POST /api/pairing/start is rate-limited (429) per socket peer.
//   * POST /api/pairing/lan-claim is rate-limited (429) per socket peer so a
//     LAN flood cannot mint session tokens without bound.
//   * the legacy WS ?token= auth path routes failed attempts through the same
//     bearer-token failure limiter (429) as the Authorization header, while a
//     valid token still upgrades.

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api/auth/pairing_service.dart';
import 'package:skotiq_desktop/headless_api/route_metadata.dart';
import 'package:skotiq_desktop/headless_api_server.dart';

import '../headless_api/handler_test_helpers.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

void main() {
  group('pairing + WS throttling', () {
    late ProviderContainer container;
    late HeadlessApiServer server;
    late HttpClient client;
    late Uri baseUri;
    late PairingService pairingService;

    setUp(() async {
      final database = PairingDatabase.forTesting(NativeDatabase.memory());
      pairingService = PairingService(database: database);
      container = createHeadlessTestContainer(
        overrides: [
          appVersionProvider.overrideWithValue(
            const AppVersionInfo(version: '2.5.0', buildNumber: 5),
          ),
        ],
      );
      server = HeadlessApiServer(
        port: 0,
        container: container,
        bindLocalOnly: true,
        authToken: 'admin-token',
        pairingService: pairingService,
      );
      await server.start();
      client = HttpClient();
      baseUri = Uri.parse('http://127.0.0.1:${server.actualPort}');
    });

    tearDown(() async {
      client.close(force: true);
      await server.stop();
      await pairingService.close();
      container.dispose();
    });

    test('POST /api/pairing/start is throttled with 429', () async {
      for (var i = 0; i < defaultControlRateLimitMaxRequests; i++) {
        final ok = await _post(client, baseUri, '/api/pairing/start');
        expect(
          ok.statusCode,
          isNot(HttpStatus.tooManyRequests),
          reason: 'start #$i should be allowed',
        );
      }

      final blocked = await _post(client, baseUri, '/api/pairing/start');
      expect(blocked.statusCode, HttpStatus.tooManyRequests);
      expect(blocked.body['code'], 'rate_limited');
      expect(blocked.headers['retry-after'], isNotNull);
    });

    test('POST /api/pairing/lan-claim is throttled with 429', () async {
      // From loopback the claim is refused (not a private-LAN source), but the
      // endpoint rate limit runs ahead of the handler, so a flood still trips
      // the shared 429 — bounding how many claims (and thus tokens) one peer
      // can drive.
      for (var i = 0; i < defaultControlRateLimitMaxRequests; i++) {
        final refused = await _post(client, baseUri, '/api/pairing/lan-claim');
        expect(
          refused.statusCode,
          isNot(HttpStatus.tooManyRequests),
          reason: 'lan-claim #$i should reach the handler',
        );
      }

      final blocked = await _post(client, baseUri, '/api/pairing/lan-claim');
      expect(blocked.statusCode, HttpStatus.tooManyRequests);
      expect(blocked.body['code'], 'rate_limited');
    });

    test('a valid legacy ?token= still upgrades the WebSocket', () async {
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:${server.actualPort}/events'
        '?token=admin-token&apiVersion=2.5.0',
      );
      try {
        expect(socket.readyState, WebSocket.open);
      } finally {
        await socket.close();
      }
    });

    test('repeated bad ?token= WS attempts trip the 429 limiter', () async {
      // The bearer-token failure limiter trips at 30 failures/min (the
      // TokenResolver default). Each bad attempt is rejected (not 429) until
      // the threshold, then the next is a 429 — the same lockout the
      // Authorization-header path enforces.
      for (var i = 0; i < 30; i++) {
        final attempt = await _wsTokenAttempt(
          server.actualPort,
          'garbage-token-$i',
        );
        expect(
          attempt,
          isNot(HttpStatus.tooManyRequests),
          reason: 'bad WS attempt #$i should be a normal rejection, not 429',
        );
      }

      final blocked = await _wsTokenAttempt(server.actualPort, 'garbage-final');
      expect(blocked, HttpStatus.tooManyRequests);
    });
  });
}

Future<_Resp> _post(HttpClient client, Uri baseUri, String path) async {
  final request = await client.openUrl('POST', baseUri.replace(path: path));
  request.headers.contentType = ContentType.json;
  request.write('{}');
  final response = await request.close();
  final text = await response.transform(utf8.decoder).join();
  final headers = <String, String>{};
  response.headers.forEach((name, values) {
    headers[name.toLowerCase()] = values.join(',');
  });
  return _Resp(
    statusCode: response.statusCode,
    headers: headers,
    body: text.trim().isEmpty
        ? const <String, dynamic>{}
        : jsonDecode(text) as Map<String, dynamic>,
  );
}

/// Sends a raw WebSocket upgrade with a bearer token in the query string and
/// returns the HTTP status the server answered with (the upgrade is rejected
/// for a bad/garbage token, so the server replies with a normal HTTP response).
Future<int> _wsTokenAttempt(int port, String token) async {
  final socket = await Socket.connect('127.0.0.1', port);
  socket.write(
    'GET /api/ws?token=$token HTTP/1.1\r\n'
    'Host: 127.0.0.1:$port\r\n'
    'Connection: Upgrade\r\n'
    'Upgrade: websocket\r\n'
    'Sec-WebSocket-Version: 13\r\n'
    'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
    '\r\n',
  );
  await socket.flush();
  final responseText = await utf8.decoder.bind(socket).join();
  await socket.close();
  final statusLine = responseText.split('\r\n').first;
  return int.parse(statusLine.split(' ')[1]);
}

class _Resp {
  final int statusCode;
  final Map<String, String> headers;
  final Map<String, dynamic> body;

  const _Resp({
    required this.statusCode,
    required this.headers,
    required this.body,
  });
}
