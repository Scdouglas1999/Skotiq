// The phone pairs through core's RigPairingService with its own device id.
// The host record's transport `scheme` (https for a TLS-fronted tailnet rig)
// and known `fingerprint` (the MITM pre-flight) must reach the client: if
// either is dropped, pairing-over-Tailscale either 400s (wrong scheme) or
// transmits the code before verifying server identity (no pin). These tests
// pin that wiring end-to-end against a real loopback HTTP server.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/services.dart';
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
              'version': '8.2.1',
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

class _RecordingClient extends RemotePairingClient {
  _RecordingClient() : super(host: 'h', port: 1);

  final codes = <String>[];
  final types = <PairingDeviceType>[];

  static const _ok = RemotePairingVerifyResult(
    success: true,
    token: 'tok',
    tokenScope: 'admin',
  );

  @override
  Future<RemotePairingVerifyResult> verify({
    required String code,
    required String deviceId,
    required String deviceName,
    PairingDeviceType deviceType = PairingDeviceType.mobile,
    String requestedScope = 'control',
  }) async {
    codes.add(code);
    types.add(deviceType);
    return _ok;
  }

  @override
  Future<RemotePairingVerifyResult?> lanClaim({
    required String deviceId,
    required String deviceName,
    PairingDeviceType deviceType = PairingDeviceType.mobile,
    String? requestedScope,
  }) async {
    types.add(deviceType);
    return _ok;
  }
}

final _rig = DiscoveredServer(host: '192.168.1.50', webPort: 8099, name: 'rig');

Future<RigPairing> _pair(
  _FakePairingServer server, {
  String scheme = 'http',
  String? fingerprint,
}) => MobilePairingService.pairWithCode(
  DiscoveredServer(
    host: '127.0.0.1',
    webPort: server.port,
    name: 'Fake',
    scheme: scheme,
    fingerprint: fingerprint,
  ),
  code: 'STAR-LYRA-1234',
  fullAccess: true,
);

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
      await expectLater(
        _pair(server, fingerprint: 'EXPECTED-FP-DIFFERENT'),
        throwsA(
          isA<RigPairingFailure>().having(
            (f) => f.kind,
            'kind',
            RigPairingFailureKind.fingerprintMismatch,
          ),
        ),
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
      final result = await _pair(
        server,
        fingerprint: 'pinned-fp-001', // case-insensitive
      );

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
      await expectLater(_pair(server, scheme: 'https'), throwsA(anything));
      expect(server.servedPaths, isNot(contains('/api/pairing/verify')));
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test('no pin set: the pre-flight is skipped (LAN first-pair flow)', () async {
    server = _FakePairingServer(fingerprint: 'IRRELEVANT');
    await server.start();
    final result = await _pair(server);

    expect(result.token, 'scoped-token-abc');
    expect(server.servedPaths, isNot(contains('/api/info')));
    expect(server.servedPaths, contains('/api/pairing/verify'));
  });

  group('the phone pairs by the same rules as the desktop', () {
    setUp(() async {
      server = _FakePairingServer();
      await server.start();
    });

    test('a code typed with spaces is sent as the host shows it', () async {
      final client = _RecordingClient();

      await MobilePairingService.pairWithCode(
        _rig,
        code: 'star lyra 1234',
        fullAccess: true,
        clientFactory: (_) => client,
      );

      expect(client.codes, ['STAR-LYRA-1234']);
    });

    test('one tap names the same device type as a code', () async {
      final client = _RecordingClient();

      await MobilePairingService.pairOneTap(_rig, clientFactory: (_) => client);
      await MobilePairingService.pairWithCode(
        _rig,
        code: 'STAR-LYRA-1234',
        fullAccess: true,
        clientFactory: (_) => client,
      );

      expect(client.types, hasLength(2));
      expect(client.types.first, client.types.last);
      expect(client.types.first, MobilePairingService.platformDeviceType());
    });
  });

  group('a refused pairing reads as on the desktop', () {
    setUp(() async {
      server = _FakePairingServer();
      await server.start();
    });

    test('a wrong code says it does not match', () {
      const failure = RigPairingFailure(
        RigPairingFailureKind.invalidCode,
        'Invalid pairing code',
        hostMessage: 'Invalid pairing code',
        statusCode: 401,
      );

      expect(
        pairingFailureText(failure, _rig),
        "That code doesn't match the one rig shows. Check it and try again.",
      );
    });

    test('a request that never reached the host names the address', () {
      final failure = RigPairingFailure(
        RigPairingFailureKind.unreachable,
        'SocketException: refused',
        cause: const SocketException('refused'),
      );

      expect(
        pairingFailureText(failure, _rig),
        "Can't reach rig at 192.168.1.50:8099.",
      );
    });
  });
}
