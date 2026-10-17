// Tests for MobilePairingService scheme + fingerprint-pinning wiring.
//
// The service is a thin wrapper over RemotePairingClient that persists a
// stable device id and forwards the operator's pairing code. P3 must thread
// the transport `scheme` (https for a TLS-fronted tailnet rig) and the known
// server `pinnedFingerprint` (the MITM pre-flight) through to the client — if
// either is dropped, pairing-over-Tailscale either 400s (wrong scheme) or
// transmits the code before verifying server identity (no pin). These tests
// pin that wiring end-to-end against a real loopback HTTP server.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_mobile/services/mobile_pairing_service.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-process HTTP server emulating the headless pairing surface. Records the
/// served paths so a test can assert the code was (or was not) transmitted.
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
            jsonEncode({'token': 'scoped-token-abc', 'tokenScope': 'control'}),
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
  late _FakePairingServer server;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() async {
    await server.stop();
  });

  test(
    'threads pinnedFingerprint: verify fails closed before sending the code',
    () async {
      server = _FakePairingServer(fingerprint: 'SERVER-FP-REAL');
      await server.start();
      final service = MobilePairingService(
        host: '127.0.0.1',
        port: server.port,
        pinnedFingerprint: 'EXPECTED-FP-DIFFERENT',
      );

      await expectLater(
        service.pairWithCode(code: 'STAR-LYRA-1234'),
        throwsA(isA<RemotePairingFingerprintMismatch>()),
      );

      // The pre-flight identity check must run AND must abort before the code is
      // transmitted — the whole point of pinning on the Tailscale path.
      expect(server.servedPaths, contains('/api/info'));
      expect(server.servedPaths, isNot(contains('/api/pairing/verify')));
    },
  );

  test(
    'threads a matching pin: pairing completes after the pre-flight',
    () async {
      server = _FakePairingServer(fingerprint: 'PINNED-FP-001');
      await server.start();
      final service = MobilePairingService(
        host: '127.0.0.1',
        port: server.port,
        pinnedFingerprint: 'pinned-fp-001', // case-insensitive
      );

      final result = await service.pairWithCode(code: 'STAR-LYRA-1234');

      expect(result.success, isTrue);
      expect(result.token, 'scoped-token-abc');
      expect(server.servedPaths, contains('/api/info'));
      expect(server.servedPaths, contains('/api/pairing/verify'));
    },
  );

  test(
    'threads scheme: an https service does not reach a cleartext server',
    () async {
      // The fake serves plain HTTP. A service constructed with scheme:'https'
      // must dial TLS — which a cleartext loopback server cannot complete — so
      // the verify endpoint is never reached. If the scheme were silently
      // dropped to http, the call would succeed over the fake and serve
      // /api/pairing/verify. The negative therefore proves the scheme was
      // honoured. (Construction-level scheme validation itself is covered by
      // RemotePairingClient's own tests.)
      server = _FakePairingServer(fingerprint: null);
      await server.start();
      final service = MobilePairingService(
        host: '127.0.0.1',
        port: server.port,
        scheme: 'https',
      );

      await expectLater(
        service.pairWithCode(code: 'STAR-LYRA-1234'),
        throwsA(anything),
      );
      expect(server.servedPaths, isNot(contains('/api/pairing/verify')));
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test('no pin set: the pre-flight is skipped (LAN first-pair flow)', () async {
    server = _FakePairingServer(fingerprint: 'IRRELEVANT');
    await server.start();
    final service = MobilePairingService(host: '127.0.0.1', port: server.port);

    final result = await service.pairWithCode(code: 'STAR-LYRA-1234');

    expect(result.success, isTrue);
    expect(server.servedPaths, isNot(contains('/api/info')));
    expect(server.servedPaths, contains('/api/pairing/verify'));
  });
}
