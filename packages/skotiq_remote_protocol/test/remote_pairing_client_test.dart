import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

/// Minimal in-process HTTP server that emulates the headless pairing surface
/// so we can exercise [RemotePairingClient] end-to-end over real loopback TCP
/// without mocking `http`. Records the paths it served so a test can assert
/// the pairing code was (or was not) transmitted.
class _FakePairingServer {
  _FakePairingServer({this.fingerprint});

  final String? fingerprint;
  late final HttpServer _server;
  final List<String> servedPaths = <String>[];

  int get port => _server.port;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(_serve());
  }

  Future<void> _serve() async {
    await for (final request in _server) {
      servedPaths.add(request.uri.path);
      // Drain the request body so the socket can be reused.
      await request.drain<void>();
      switch (request.uri.path) {
        case '/api/info':
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'name': 'Fake',
              'version': '2.6.0',
              'apiVersion': '2.6.0',
              'authRequired': true,
              'pairingSupported': true,
              if (fingerprint != null) 'fingerprint': fingerprint,
            }),
          );
          break;
        case '/api/pairing/verify':
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'token': 'scoped-token-abc',
              'tokenScope': 'control',
              'expiresAt': DateTime.now()
                  .toUtc()
                  .add(const Duration(hours: 12))
                  .toIso8601String(),
            }),
          );
          break;
        default:
          request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    }
  }

  Future<void> stop() => _server.close(force: true);
}

void main() {
  group('computeServerFingerprint', () {
    test('is stable for the same secret', () {
      final a = computeServerFingerprint('skotiq-test-secret');
      final b = computeServerFingerprint('skotiq-test-secret');
      expect(a, equals(b));
      expect(a.length, 64);
    });

    test('rejects empty secret', () {
      expect(() => computeServerFingerprint(''), throwsArgumentError);
    });
  });

  group('QrConnectionData pairingCode', () {
    test('round-trips pairingCode in QR JSON', () {
      const payload = '''
{"service":"skotiq","host":"192.168.1.10","port":8080,"version":"2.5.0","fingerprint":"abcdef1234567890","pairingCode":"STAR-LYRA-1234"}
''';
      final data = QrConnectionData.parseStrict(payload);
      expect(data.pairingCode, 'STAR-LYRA-1234');
      expect(data.toJson()['pairingCode'], 'STAR-LYRA-1234');
    });
  });

  group('RemotePairingClient scheme', () {
    test('asserts an invalid scheme at construction', () {
      expect(
        () => RemotePairingClient(host: 'h', port: 1, scheme: 'ftp'),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('RemotePairingClient fingerprint pinning', () {
    late _FakePairingServer server;

    tearDown(() async {
      await server.stop();
    });

    test('verify succeeds when the live fingerprint matches the pin', () async {
      server = _FakePairingServer(fingerprint: 'PINNED-FP-001');
      await server.start();
      final client = RemotePairingClient(
        host: '127.0.0.1',
        port: server.port,
        pinnedFingerprint: 'pinned-fp-001', // case-insensitive match
      );

      final result = await client.verify(
        code: 'STAR-LYRA-1234',
        deviceId: 'device-1',
        deviceName: 'Test Phone',
      );

      expect(result.success, isTrue);
      expect(result.token, 'scoped-token-abc');
      // Pre-flight hit /api/info, then /api/pairing/verify.
      expect(server.servedPaths, contains('/api/info'));
      expect(server.servedPaths, contains('/api/pairing/verify'));
    });

    test(
      'verify throws and never sends the code when fingerprint differs',
      () async {
        server = _FakePairingServer(fingerprint: 'SERVER-FP-REAL');
        await server.start();
        final client = RemotePairingClient(
          host: '127.0.0.1',
          port: server.port,
          pinnedFingerprint: 'EXPECTED-FP-DIFFERENT',
        );

        await expectLater(
          client.verify(
            code: 'STAR-LYRA-1234',
            deviceId: 'device-1',
            deviceName: 'Test Phone',
          ),
          throwsA(isA<RemotePairingFingerprintMismatch>()),
        );

        // The whole point of pinning: the code must NOT have been transmitted.
        expect(server.servedPaths, contains('/api/info'));
        expect(server.servedPaths, isNot(contains('/api/pairing/verify')));
      },
    );

    test(
      'verify fails closed when the server reports no fingerprint',
      () async {
        server = _FakePairingServer(fingerprint: null);
        await server.start();
        final client = RemotePairingClient(
          host: '127.0.0.1',
          port: server.port,
          pinnedFingerprint: 'EXPECTED-FP',
        );

        await expectLater(
          client.verify(
            code: 'STAR-LYRA-1234',
            deviceId: 'device-1',
            deviceName: 'Test Phone',
          ),
          throwsA(
            isA<RemotePairingFingerprintMismatch>().having(
              (e) => e.actual,
              'actual',
              isNull,
            ),
          ),
        );
        expect(server.servedPaths, isNot(contains('/api/pairing/verify')));
      },
    );

    test('verify skips the pre-flight entirely when no pin is set', () async {
      server = _FakePairingServer(fingerprint: 'IRRELEVANT');
      await server.start();
      final client = RemotePairingClient(host: '127.0.0.1', port: server.port);

      final result = await client.verify(
        code: 'STAR-LYRA-1234',
        deviceId: 'device-1',
        deviceName: 'Test Phone',
      );

      expect(result.success, isTrue);
      // No pin → no /api/info pre-flight; only the verify call happened.
      expect(server.servedPaths, isNot(contains('/api/info')));
      expect(server.servedPaths, contains('/api/pairing/verify'));
    });

    test('fetchFingerprint returns the advertised value', () async {
      server = _FakePairingServer(fingerprint: 'FETCHED-FP');
      await server.start();
      final client = RemotePairingClient(host: '127.0.0.1', port: server.port);
      expect(await client.fetchFingerprint(), 'FETCHED-FP');
    });
  });
}
