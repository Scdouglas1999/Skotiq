import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api/auth/pairing_service.dart';
import 'package:skotiq_desktop/headless_api_server.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'handler_test_helpers.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

/// Regression coverage for the fail-closed auth posture: an unconfigured
/// headless server must NOT serve privileged endpoints unauthenticated, but the
/// pairing/discovery/dashboard bootstrap surface must remain reachable so a
/// fresh appliance can still be onboarded. The explicit
/// `--allow-unauthenticated` opt-in restores the legacy fully-open behaviour.
void main() {
  ProviderContainer makeContainer() => createHeadlessTestContainer(
    overrides: [
      appVersionProvider.overrideWithValue(
        const AppVersionInfo(version: '2.5.0', buildNumber: 5),
      ),
    ],
  );

  group('HeadlessApiServer fail-closed (no tokens, no opt-in)', () {
    late ProviderContainer container;
    late HeadlessApiServer server;
    late PairingService pairingService;
    late HttpClient client;
    late Uri baseUri;

    setUp(() async {
      pairingService = PairingService(
        database: PairingDatabase.forTesting(NativeDatabase.memory()),
      );
      container = makeContainer();
      server = HeadlessApiServer(
        port: 0,
        container: container,
        bindLocalOnly: true,
        // No authToken, no scoped tokens, no opt-in: the fresh-appliance case.
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

    test(
      'privileged endpoints reject with 401 instead of serving open',
      () async {
        for (final path in const ['/api/status', '/api/openapi.json']) {
          final response = await _request(client, baseUri, path);
          expect(
            response.statusCode,
            HttpStatus.unauthorized,
            reason: '$path must fail closed when no auth is configured',
          );
        }

        final control = await _request(
          client,
          baseUri,
          '/api/camera/expose',
          method: 'POST',
          body: const {'deviceId': 'camera-1', 'durationSeconds': 1},
        );
        expect(control.statusCode, HttpStatus.unauthorized);
      },
    );

    test('pairing and dashboard bootstrap surface stays reachable', () async {
      // /api/info is public so a client can discover the appliance pre-pairing.
      final info = await _request(client, baseUri, '/api/info');
      expect(info.statusCode, HttpStatus.ok);

      // The dashboard SPA must load before the operator holds any token.
      final dashboard = await _rawStatus(client, baseUri, '/dashboard');
      expect(dashboard, HttpStatus.ok);

      // The pairing verify endpoint is reachable without a bearer token. A bad
      // code is rejected by the HANDLER, not the auth middleware — so the
      // rejection must NOT carry the middleware's 'Authentication required'
      // body (that would mean the request never reached the pairing handler).
      final verifyBadCode = await _request(
        client,
        baseUri,
        '/api/pairing/verify',
        method: 'POST',
        body: const {
          'code': '000000',
          'deviceId': 'test-phone',
          'deviceName': 'Test Phone',
          'deviceType': 'mobile',
        },
      );
      expect(verifyBadCode.body['error'], isNot('Authentication required'));
    });

    test(
      'pairing bootstrap mints a token that unlocks privileged endpoints',
      () async {
        // A fresh appliance with no pre-shared token pairs a device out-of-band.
        final start = await pairingService.startPairing();
        final verify = await _request(
          client,
          baseUri,
          '/api/pairing/verify',
          method: 'POST',
          body: {
            'code': start.code,
            'deviceId': 'bootstrap-phone',
            'deviceName': 'Bootstrap Phone',
            'deviceType': 'mobile',
            'requestedScope': 'admin',
          },
        );
        expect(verify.statusCode, HttpStatus.ok);
        final token = verify.body['token'] as String;
        expect(token, isNotEmpty);

        // The freshly paired token now reaches a privileged endpoint that was
        // 401 a moment ago.
        final authed = await _request(
          client,
          baseUri,
          '/api/openapi.json',
          token: token,
        );
        expect(authed.statusCode, HttpStatus.ok);

        // ...while an anonymous request to the same endpoint is still closed.
        final anon = await _request(client, baseUri, '/api/openapi.json');
        expect(anon.statusCode, HttpStatus.unauthorized);
      },
    );
  });

  group('HeadlessApiServer --allow-unauthenticated opt-in', () {
    late ProviderContainer container;
    late HeadlessApiServer server;
    late PairingService pairingService;
    late HttpClient client;
    late Uri baseUri;

    setUp(() async {
      container = makeContainer();
      pairingService = PairingService(
        database: PairingDatabase.forTesting(NativeDatabase.memory()),
      );
      // Reproduce a real restarted rig: persisted sessions are hydrated after
      // the startup banner has already promised fully-open access. They must
      // not silently cancel the explicit operator override.
      await pairingService.database.addPairedDevice(
        deviceId: 'persisted-phone',
        deviceName: 'Persisted Phone',
        sessionToken: 'persisted-session-token',
        deviceType: 'mobile',
        expiresAt: DateTime.now().add(const Duration(days: 1)),
        authGrantSpec: 'admin',
      );
      server = HeadlessApiServer(
        port: 0,
        container: container,
        bindLocalOnly: true,
        // Explicit opt-in to the legacy fully-open behaviour with a persisted
        // pairing token present.
        allowUnauthenticated: true,
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

    test('serves privileged endpoints without a token', () async {
      // A view-scoped protected endpoint is fully served (static metadata, no
      // backend dependency) — proving auth is bypassed end to end.
      final openapi = await _request(client, baseUri, '/api/openapi.json');
      expect(openapi.statusCode, HttpStatus.ok);

      // /api/status depends on backend wiring the bare test container lacks, so
      // it may 500, but it must NOT be auth-rejected: reaching the handler is
      // the proof that the opt-in bypassed authentication.
      final status = await _request(client, baseUri, '/api/status');
      expect(status.statusCode, isNot(HttpStatus.unauthorized));
      expect(status.statusCode, isNot(HttpStatus.forbidden));
    });
  });

  group('HeadlessApiServer configured token (backward compatibility)', () {
    late ProviderContainer container;
    late HeadlessApiServer server;
    late HttpClient client;
    late Uri baseUri;

    setUp(() async {
      container = makeContainer();
      server = HeadlessApiServer(
        port: 0,
        container: container,
        bindLocalOnly: true,
        authToken: 'admin-token',
      );
      await server.start();
      client = HttpClient();
      baseUri = Uri.parse('http://127.0.0.1:${server.actualPort}');
    });

    tearDown(() async {
      client.close(force: true);
      await server.stop();
      container.dispose();
    });

    test('still rejects anonymous and accepts the configured token', () async {
      final anon = await _request(client, baseUri, '/api/openapi.json');
      expect(anon.statusCode, HttpStatus.unauthorized);

      final authed = await _request(
        client,
        baseUri,
        '/api/openapi.json',
        token: 'admin-token',
      );
      expect(authed.statusCode, HttpStatus.ok);
    });
  });
}

Future<_TestResponse> _request(
  HttpClient client,
  Uri baseUri,
  String path, {
  String method = 'GET',
  String? token,
  Map<String, dynamic>? body,
}) async {
  final request = await client.openUrl(method, baseUri.replace(path: path));
  if (token != null) {
    request.headers.set('Authorization', 'Bearer $token');
  }
  if (body != null) {
    request.headers.set('Content-Type', 'application/json');
    request.add(utf8.encode(jsonEncode(body)));
  }
  final response = await request.close();
  final text = await response.transform(utf8.decoder).join();
  final parsed = text.trim().isEmpty
      ? <String, dynamic>{}
      : jsonDecode(text) as Map<String, dynamic>;
  return _TestResponse(statusCode: response.statusCode, body: parsed);
}

Future<int> _rawStatus(HttpClient client, Uri baseUri, String path) async {
  final request = await client.getUrl(baseUri.replace(path: path));
  final response = await request.close();
  await response.drain<void>();
  return response.statusCode;
}

class _TestResponse {
  final int statusCode;
  final Map<String, dynamic> body;

  const _TestResponse({required this.statusCode, required this.body});
}
