// The rate-limit / brute-force-lockout client key MUST be derived from the
// real TCP socket peer, NOT the client-controlled `x-forwarded-for` /
// `x-real-ip` headers. Otherwise an attacker on the default direct-bind
// deployment can rotate the forwarding header to evade both the pairing
// lockout (PairingAttemptTracker) and the bearer-token failure limiter
// (TokenResolver).
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/auth/pairing_service.dart';
import 'package:skotiq_desktop/headless_api/handlers.dart';
import 'package:skotiq_desktop/headless_api_server.dart';

import '../headless_api/handler_test_helpers.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart'
    show PairingDatabase;
import 'package:shelf/shelf.dart';

void main() {
  group('headlessRateLimitClientKey', () {
    test(
      'default keys off the socket peer, ignoring spoofed forwarding headers',
      () {
        final request = _request(
          peer: InternetAddress('192.168.1.50'),
          headers: {
            'x-forwarded-for': '203.0.113.9',
            'x-real-ip': '203.0.113.10',
          },
        );

        expect(
          headlessRateLimitClientKey(request, trustForwardedHeaders: false),
          '192.168.1.50',
        );
      },
    );

    test('forwarding headers are ignored for a non-loopback peer even when '
        'trustForwardedHeaders is enabled', () {
      final request = _request(
        peer: InternetAddress('192.168.1.50'),
        headers: {'x-forwarded-for': '203.0.113.9'},
      );

      // The peer is a direct LAN client, not the loopback proxy, so the
      // forged header must not influence the key.
      expect(
        headlessRateLimitClientKey(request, trustForwardedHeaders: true),
        '192.168.1.50',
      );
    });

    test('trustForwardedHeaders + loopback peer honours X-Forwarded-For', () {
      final request = _request(
        peer: InternetAddress.loopbackIPv4,
        headers: {'x-forwarded-for': '203.0.113.9, 70.0.0.1'},
      );

      // Behind the documented loopback nginx proxy the REAL client IP (first
      // hop of XFF) becomes the lockout key.
      expect(
        headlessRateLimitClientKey(request, trustForwardedHeaders: true),
        '203.0.113.9',
      );
    });

    test('trustForwardedHeaders + loopback peer falls back to X-Real-IP', () {
      final request = _request(
        peer: InternetAddress.loopbackIPv4,
        headers: {'x-real-ip': '198.51.100.7'},
      );

      expect(
        headlessRateLimitClientKey(request, trustForwardedHeaders: true),
        '198.51.100.7',
      );
    });

    test('trustForwardedHeaders + loopback peer with no forwarding headers '
        'falls back to the socket peer', () {
      final request = _request(peer: InternetAddress.loopbackIPv4);

      expect(
        headlessRateLimitClientKey(request, trustForwardedHeaders: true),
        InternetAddress.loopbackIPv4.address,
      );
    });

    test('no socket connection info falls back to the requested host', () {
      final request = _request(peer: null);

      expect(
        headlessRateLimitClientKey(request, trustForwardedHeaders: false),
        '10.0.0.5',
      );
    });
  });

  group('end-to-end (key off socket, not spoofed XFF)', () {
    test(
      'pairing brute-force locks out even when X-Forwarded-For rotates',
      () async {
        final database = PairingDatabase.forTesting(NativeDatabase.memory());
        final pairingService = PairingService(database: database);
        final container = createHeadlessTestContainer(
          overrides: [
            appVersionProvider.overrideWithValue(
              const AppVersionInfo(version: '2.5.0', buildNumber: 5),
            ),
          ],
        );
        final server = HeadlessApiServer(
          port: 0,
          container: container,
          bindLocalOnly: true,
          authToken: 'admin-token',
          pairingService: pairingService,
        );
        await server.start();
        final client = HttpClient();
        final baseUri = Uri.parse('http://127.0.0.1:${server.actualPort}');

        try {
          // PairingAttemptTracker.maxFailuresPerWindow == 5. Five wrong codes,
          // each with a DIFFERENT spoofed X-Forwarded-For, must still all land
          // in the SAME bucket (keyed off the loopback socket), so the sixth
          // attempt is locked out.
          for (var i = 0; i < 5; i++) {
            final resp = await _verify(
              client,
              baseUri,
              forwardedFor: '203.0.113.$i',
            );
            expect(
              resp.statusCode,
              HttpStatus.unauthorized,
              reason: 'attempt $i should be a normal invalid-code 401',
            );
          }

          final locked = await _verify(
            client,
            baseUri,
            forwardedFor: '203.0.113.99',
          );
          expect(locked.statusCode, HttpStatus.tooManyRequests);
          expect(locked.body['error'], 'Pairing attempts temporarily locked');
        } finally {
          client.close(force: true);
          await server.stop();
          await pairingService.close();
          container.dispose();
        }
      },
    );

    test(
      'repeated bad bearer tokens with rotating XFF trip the token limiter',
      () async {
        final container = createHeadlessTestContainer(
          overrides: [
            appVersionProvider.overrideWithValue(
              const AppVersionInfo(version: '2.5.0', buildNumber: 5),
            ),
          ],
        );
        final server = HeadlessApiServer(
          port: 0,
          container: container,
          bindLocalOnly: true,
          authToken: 'admin-token',
        );
        await server.start();
        final client = HttpClient();
        final baseUri = Uri.parse('http://127.0.0.1:${server.actualPort}');

        try {
          // TokenResolver.maxFailuresPerWindow == 30. Thirty bad tokens, each
          // with a rotating spoofed X-Forwarded-For, must accumulate in the
          // single loopback-keyed bucket; the 31st is shed with 429.
          for (var i = 0; i < 30; i++) {
            final resp = await _badToken(
              client,
              baseUri,
              forwardedFor: '198.51.100.$i',
            );
            expect(
              resp.statusCode,
              HttpStatus.forbidden,
              reason: 'attempt $i should be a normal invalid-token 403',
            );
          }

          final shed = await _badToken(
            client,
            baseUri,
            forwardedFor: '198.51.100.250',
          );
          expect(shed.statusCode, HttpStatus.tooManyRequests);
          expect(shed.body['error'], 'Rate limit exceeded');
        } finally {
          client.close(force: true);
          await server.stop();
          container.dispose();
        }
      },
    );
  });
}

/// Builds an in-process [Request] with an optional fake socket peer attached
/// the same way shelf_io does (`shelf.io.connection_info`).
Request _request({
  required InternetAddress? peer,
  Map<String, String> headers = const {},
}) {
  return Request(
    'POST',
    Uri.parse('http://10.0.0.5:8080/api/pairing/verify'),
    headers: headers,
    context: peer == null
        ? const <String, Object>{}
        : {'shelf.io.connection_info': _FakeConnectionInfo(peer)},
  );
}

class _FakeConnectionInfo implements HttpConnectionInfo {
  _FakeConnectionInfo(this.remoteAddress);

  @override
  final InternetAddress remoteAddress;

  @override
  int get localPort => 0;

  @override
  int get remotePort => 0;
}

Future<_Resp> _verify(
  HttpClient client,
  Uri baseUri, {
  required String forwardedFor,
}) async {
  final request = await client.openUrl(
    'POST',
    baseUri.replace(path: '/api/pairing/verify'),
  );
  request.headers.set('Content-Type', 'application/json');
  request.headers.set('X-Forwarded-For', forwardedFor);
  request.headers.set('X-Real-IP', forwardedFor);
  request.add(utf8.encode(jsonEncode({'code': '000000'})));
  return _readResponse(await request.close());
}

Future<_Resp> _badToken(
  HttpClient client,
  Uri baseUri, {
  required String forwardedFor,
}) async {
  final request = await client.openUrl(
    'GET',
    baseUri.replace(path: '/api/status'),
  );
  request.headers.set('Authorization', 'Bearer wrong-$forwardedFor');
  request.headers.set('X-Forwarded-For', forwardedFor);
  request.headers.set('X-Real-IP', forwardedFor);
  return _readResponse(await request.close());
}

Future<_Resp> _readResponse(HttpClientResponse response) async {
  final text = await response.transform(utf8.decoder).join();
  final parsed = text.trim().isEmpty
      ? <String, dynamic>{}
      : jsonDecode(text) as Map<String, dynamic>;
  return _Resp(statusCode: response.statusCode, body: parsed);
}

class _Resp {
  const _Resp({required this.statusCode, required this.body});

  final int statusCode;
  final Map<String, dynamic> body;
}
