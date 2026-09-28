import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show LazyDatabase;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightshade_desktop/headless_api/auth/pairing_service.dart';
import 'package:nightshade_desktop/headless_api_server.dart';
import 'package:nightshade_core/nightshade_core.dart';

import 'handler_test_helpers.dart';
import 'package:nightshade_remote_protocol/nightshade_remote_protocol.dart';

void main() {
  group('HeadlessApiServer pairing', () {
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

    test('verify issues control scope by default', () async {
      final start = await pairingService.startPairing();

      final verify = await _request(
        client,
        baseUri,
        '/api/pairing/verify',
        method: 'POST',
        body: {
          'code': start.code,
          'deviceId': 'test-phone',
          'deviceName': 'Test Phone',
          'deviceType': 'mobile',
        },
      );

      expect(verify.statusCode, HttpStatus.ok);
      expect(verify.body['tokenScope'], 'control');

      final blocked = await _request(
        client,
        baseUri,
        '/api/backup/list',
        token: verify.body['token'] as String,
      );

      expect(blocked.statusCode, HttpStatus.forbidden);
      expect(blocked.body['tokenScope'], 'control');
      expect(blocked.body['requiredScope'], 'admin');
    });

    test('verify honors explicit admin scope request', () async {
      final start = await pairingService.startPairing();

      final verify = await _request(
        client,
        baseUri,
        '/api/pairing/verify',
        method: 'POST',
        body: {
          'code': start.code,
          'deviceId': 'test-admin-phone',
          'deviceName': 'Admin Phone',
          'deviceType': 'mobile',
          'requestedScope': 'admin',
        },
      );

      expect(verify.statusCode, HttpStatus.ok);
      expect(verify.body['tokenScope'], 'admin');

      final allowed = await _request(
        client,
        baseUri,
        '/api/openapi.json',
        token: verify.body['token'] as String,
      );

      expect(allowed.statusCode, HttpStatus.ok);
    });

    test('verify honors a fine-grained requestedScope', () async {
      final start = await pairingService.startPairing();

      final verify = await _request(
        client,
        baseUri,
        '/api/pairing/verify',
        method: 'POST',
        body: {
          'code': start.code,
          'deviceId': 'scoped-phone',
          'deviceName': 'Scoped Phone',
          'deviceType': 'mobile',
          'requestedScope': 'camera:control,mount:view',
        },
      );

      expect(verify.statusCode, HttpStatus.ok);
      expect(verify.body['tokenScope'], 'camera:control,mount:view');
      final token = verify.body['token'] as String;

      // The grant lets it read mount status but not slew.
      final slew = await _request(
        client,
        baseUri,
        '/api/mount/slew',
        method: 'POST',
        token: token,
        body: {'ra': 1.0, 'dec': 1.0},
      );
      expect(slew.statusCode, HttpStatus.forbidden);
      expect(slew.body['requiredResource'], 'mount');
      expect(slew.body['requiredLevel'], 'control');
    });

    // The one that must never regress: a pairing request for read-only has to
    // yield read-only. `view` used to resolve to the `control` grant alongside
    // `control`, so a browser that asked to watch was handed imaging control
    // and the disclosure sat in a `tokenScope` field no caller reads.
    test('a view request mints a view grant, never control', () async {
      final start = await pairingService.startPairing();

      final verify = await _request(
        client,
        baseUri,
        '/api/pairing/verify',
        method: 'POST',
        body: {
          'code': start.code,
          'deviceId': 'viewer-browser',
          'deviceName': 'Viewer',
          'deviceType': 'browser',
          'requestedScope': 'view',
        },
      );

      expect(verify.statusCode, HttpStatus.ok);
      expect(verify.body['tokenScope'], 'view');
      expect(verify.body['tokenScope'], isNot('control'));
      final token = verify.body['token'] as String;

      // It reads: the auth gate lets the read through. The test container
      // wires no sequencer service, so the handler behind the gate answers
      // 500 — what is under test here is that the refusal is not the gate's.
      final read = await _request(
        client,
        baseUri,
        '/api/sequencer/status',
        token: token,
      );
      expect(read.statusCode, isNot(HttpStatus.forbidden));

      // It does not command. Two different resources, so this is the grant's
      // level and not one endpoint's quirk.
      final pause = await _request(
        client,
        baseUri,
        '/api/sequencer/pause',
        method: 'POST',
        token: token,
        body: const {},
      );
      expect(pause.statusCode, HttpStatus.forbidden);
      expect(pause.body['requiredResource'], 'sequencer');
      expect(pause.body['requiredLevel'], 'control');
      expect(pause.body['tokenLevel'], 'view');

      final slew = await _request(
        client,
        baseUri,
        '/api/mount/slew',
        method: 'POST',
        token: token,
        body: {'ra': 1.0, 'dec': 1.0},
      );
      expect(slew.statusCode, HttpStatus.forbidden);
    });

    test('an omitted requestedScope still pairs at control', () async {
      final start = await pairingService.startPairing();
      final verify = await _request(
        client,
        baseUri,
        '/api/pairing/verify',
        method: 'POST',
        body: {
          'code': start.code,
          'deviceId': 'default-phone',
          'deviceName': 'Default Phone',
          'deviceType': 'mobile',
        },
      );
      expect(verify.statusCode, HttpStatus.ok);
      expect(verify.body['tokenScope'], 'control');
    });

    test(
      'a requestedScope the server cannot parse is refused, not widened',
      () async {
        final start = await pairingService.startPairing();
        final verify = await _request(
          client,
          baseUri,
          '/api/pairing/verify',
          method: 'POST',
          body: {
            'code': start.code,
            'deviceId': 'typo-phone',
            'deviceName': 'Typo Phone',
            'deviceType': 'mobile',
            'requestedScope': 'camera:viewe',
          },
        );
        // The old fallback handed this the full control grant — the widest
        // non-admin reach there is — for a misspelt request that had asked for
        // less than that.
        expect(verify.statusCode, HttpStatus.badRequest);
        expect(verify.body['error'], 'invalid_requested_scope');
        expect(verify.body.containsKey('token'), isFalse);
      },
    );

    test('info advertises fingerprint', () async {
      final response = await _request(client, baseUri, '/api/info');

      expect(response.statusCode, HttpStatus.ok);
      expect(response.body['fingerprint'], isA<String>());
      expect(
        (response.body['fingerprint'] as String).length,
        greaterThanOrEqualTo(32),
      );
    });

    // GET /api/pairing/active is admin-only and lists currently
    // valid pairing codes so a headless operator can fetch them via a
    // paired admin client without watching stdout.
    test('GET /api/pairing/active requires admin scope', () async {
      // First pair a control-scope client and confirm it cannot list.
      final start = await pairingService.startPairing();
      final verify = await _request(
        client,
        baseUri,
        '/api/pairing/verify',
        method: 'POST',
        body: {
          'code': start.code,
          'deviceId': 'control-phone',
          'deviceName': 'Control Phone',
          'deviceType': 'mobile',
        },
      );
      expect(verify.statusCode, HttpStatus.ok);
      final controlToken = verify.body['token'] as String;

      final blocked = await _request(
        client,
        baseUri,
        '/api/pairing/active',
        token: controlToken,
      );
      expect(blocked.statusCode, HttpStatus.forbidden);
    });

    test(
      'GET /api/pairing/active returns active sessions for admin tokens',
      () async {
        // Start a fresh pairing session that does NOT get verified — it
        // must show up in the active list.
        final start = await pairingService.startPairing();

        final list = await _request(
          client,
          baseUri,
          '/api/pairing/active',
          token: 'admin-token',
        );

        expect(list.statusCode, HttpStatus.ok);
        final sessions = list.body['sessions'] as List;
        expect(sessions, isNotEmpty);
        final entry = sessions.first as Map<String, dynamic>;
        expect(entry['code'], equals(start.code));
        expect(entry['expiresAt'], isA<String>());
        expect(entry['expiresInSeconds'], isA<int>());
      },
    );

    // TokenManager.revokeDevice must cause the in-memory
    // _pairedSessionTokens map to drop the corresponding session token
    // synchronously (via the SessionTokenRevocationListener installed at
    // start() / lazy-construct). A previously-accepted session token must
    // become 403 within the same request lifetime.
    test(
      'revoking a paired device evicts its session token immediately',
      () async {
        final start = await pairingService.startPairing();
        final verify = await _request(
          client,
          baseUri,
          '/api/pairing/verify',
          method: 'POST',
          body: {
            'code': start.code,
            'deviceId': 'revoke-target',
            'deviceName': 'Revoke Target',
            'deviceType': 'mobile',
          },
        );
        expect(verify.statusCode, HttpStatus.ok);
        final token = verify.body['token'] as String;

        // Sanity: the freshly-minted token is accepted by an endpoint that
        // takes a control-scope token (the verify path's default scope).
        final allowed = await _request(
          client,
          baseUri,
          '/api/devices',
          token: token,
        );
        expect(allowed.statusCode, HttpStatus.ok);

        // Revoke the device. This goes through the SAME PairingService /
        // TokenManager pair the server uses, so the registered
        // SessionTokenRevocationListener should fire and drop the token.
        await pairingService.tokenManager.revokeDevice('revoke-target');

        final blocked = await _request(
          client,
          baseUri,
          '/api/devices',
          token: token,
        );
        // Revoked tokens are unknown to _scopeForToken; the auth middleware
        // returns 403 (not 401) — see _scopeForToken null path.
        expect(blocked.statusCode, HttpStatus.forbidden);
      },
    );
  });

  test(
    'admin and fine-grained grants survive restart; malformed grants do not',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'nightshade_pairing_restart_',
      );
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final dbFile = File('${dir.path}/pairing.db');
      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      final firstContainer = createHeadlessTestContainer(
        overrides: [
          appVersionProvider.overrideWithValue(
            const AppVersionInfo(version: '2.5.0', buildNumber: 5),
          ),
        ],
      );
      final firstPairing = PairingService(
        database: PairingDatabase.forTesting(NativeDatabase(dbFile)),
      );
      final firstServer = HeadlessApiServer(
        port: 0,
        container: firstContainer,
        bindLocalOnly: true,
        authToken: 'host-admin-token',
        pairingService: firstPairing,
      );
      await firstServer.start();
      final firstUri = Uri.parse('http://127.0.0.1:${firstServer.actualPort}');

      String adminToken;
      String scopedToken;
      try {
        final adminStart = await firstPairing.startPairing();
        final adminVerify = await _request(
          client,
          firstUri,
          '/api/pairing/verify',
          method: 'POST',
          body: {
            'code': adminStart.code,
            'deviceId': 'restart-admin',
            'deviceName': 'Restart Admin',
            'requestedScope': 'admin',
          },
        );
        expect(adminVerify.statusCode, HttpStatus.ok);
        adminToken = adminVerify.body['token'] as String;

        final scopedStart = await firstPairing.startPairing();
        final scopedVerify = await _request(
          client,
          firstUri,
          '/api/pairing/verify',
          method: 'POST',
          body: {
            'code': scopedStart.code,
            'deviceId': 'restart-scoped',
            'deviceName': 'Restart Scoped',
            'requestedScope': 'camera:control,mount:view',
          },
        );
        expect(scopedVerify.statusCode, HttpStatus.ok);
        scopedToken = scopedVerify.body['token'] as String;

        expect(
          (await firstPairing.database.getPairedDevice(
            'restart-admin',
          ))!.authGrantSpec,
          'admin',
        );
        expect(
          (await firstPairing.database.getPairedDevice(
            'restart-scoped',
          ))!.authGrantSpec,
          'camera:control,mount:view',
        );
      } finally {
        await firstServer.stop();
        firstContainer.dispose();
      }

      // A damaged authorization record must never be guessed back into a
      // broad grant. Seed one directly so startup hydration exercises its
      // fail-closed path alongside the valid persisted rows.
      final seedDb = PairingDatabase.forTesting(NativeDatabase(dbFile));
      await seedDb.addPairedDevice(
        deviceId: 'restart-malformed',
        deviceName: 'Malformed Grant',
        sessionToken: 'malformed-session-token',
        deviceType: 'mobile',
        expiresAt: DateTime.now().add(const Duration(days: 1)),
        authGrantSpec: 'definitely-not-a-grant',
      );
      await seedDb.close();

      final secondContainer = createHeadlessTestContainer(
        overrides: [
          appVersionProvider.overrideWithValue(
            const AppVersionInfo(version: '2.5.0', buildNumber: 5),
          ),
        ],
      );
      final secondServer = HeadlessApiServer(
        port: 0,
        container: secondContainer,
        bindLocalOnly: true,
        authToken: 'host-admin-token',
        pairingService: PairingService(
          database: PairingDatabase.forTesting(NativeDatabase(dbFile)),
        ),
      );
      await secondServer.start();
      final secondUri = Uri.parse(
        'http://127.0.0.1:${secondServer.actualPort}',
      );
      try {
        final adminAllowed = await _request(
          client,
          secondUri,
          '/api/openapi.json',
          token: adminToken,
        );
        expect(adminAllowed.statusCode, HttpStatus.ok);

        final scopedReadAllowed = await _request(
          client,
          secondUri,
          '/api/mount/status',
          token: scopedToken,
        );
        expect(scopedReadAllowed.statusCode, isNot(HttpStatus.forbidden));

        final scopedWriteBlocked = await _request(
          client,
          secondUri,
          '/api/mount/slew',
          method: 'POST',
          token: scopedToken,
          body: {'ra': 1.0, 'dec': 1.0},
        );
        expect(scopedWriteBlocked.statusCode, HttpStatus.forbidden);

        final malformedBlocked = await _request(
          client,
          secondUri,
          '/api/mount/status',
          token: 'malformed-session-token',
        );
        expect(malformedBlocked.statusCode, HttpStatus.forbidden);
      } finally {
        await secondServer.stop();
        secondContainer.dispose();
      }
    },
    // Three servers, each opening a real file-backed database and running its
    // schema migration, plus a full stop/restart cycle to prove the grants
    // survive it. That is genuinely more than 30 seconds of work on an
    // ordinary machine, so the default per-test timeout fails it for being
    // slow rather than wrong.
    timeout: const Timeout(Duration(minutes: 5)),
  );

  // Regression for the GUI-mode restart outage: `start()` used to skip
  // `_hydratePairedSessionTokens` entirely when no PairingService had been
  // injected, so a host restart evicted every previously paired client —
  // their next request 403'd, and the client's retry loop drove the auth
  // limiter into a rolling 429 lockout. The lazy factory stands in for the
  // default `PairingService()` (which would resolve the real on-disk store).
  test(
    'start() hydrates paired tokens through the lazily-created PairingService',
    () async {
      final db = PairingDatabase.forTesting(NativeDatabase.memory());
      final lazyService = PairingService(database: db);
      addTearDown(() => lazyService.close());

      const sessionToken = 'persisted-session-token';
      await db.addPairedDevice(
        deviceId: 'lazy-device',
        deviceName: 'Lazy Device',
        sessionToken: sessionToken,
        deviceType: 'mobile',
        expiresAt: DateTime.now().add(const Duration(days: 1)),
        authGrantSpec: 'control',
      );

      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final lazyContainer = createHeadlessTestContainer(
        overrides: [
          appVersionProvider.overrideWithValue(
            const AppVersionInfo(version: '2.5.0', buildNumber: 5),
          ),
        ],
      );
      final lazyServer = HeadlessApiServer(
        port: 0,
        container: lazyContainer,
        bindLocalOnly: true,
        authToken: 'admin-token',
        // Deliberately NO pairingService — the fix under test is that
        // hydration itself performs the lazy construction.
        pairingServiceFactory: () => lazyService,
      );
      await lazyServer.start();
      final lazyUri = Uri.parse('http://127.0.0.1:${lazyServer.actualPort}');
      try {
        // The persisted token must authenticate immediately — no pairing
        // endpoint ran to construct the service first.
        final allowed = await _request(
          client,
          lazyUri,
          '/api/devices',
          token: sessionToken,
        );
        expect(allowed.statusCode, HttpStatus.ok);

        // The revocation listener must also be wired on the lazy path:
        // revoking the device evicts the token without a restart.
        await lazyService.tokenManager.revokeDevice('lazy-device');
        final blocked = await _request(
          client,
          lazyUri,
          '/api/devices',
          token: sessionToken,
        );
        expect(blocked.statusCode, HttpStatus.forbidden);
      } finally {
        await lazyServer.stop();
        lazyContainer.dispose();
      }
    },
  );

  test('a paired token is never refused as invalid while start() is still '
      'hydrating paired sessions', () async {
    // A real host opens the pairing database lazily on the first query, so
    // hydration takes as long as that open does. A request that lands in
    // that window must not be told its token is invalid: a remote client
    // treats that answer as terminal and asks the operator to re-pair.
    final dir = await Directory.systemTemp.createTemp('pairing_gate');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/pairing.sqlite');
    const sessionToken = 'persisted-session-token';
    final seed = PairingDatabase.forTesting(NativeDatabase(file));
    await seed.addPairedDevice(
      deviceId: 'gated-device',
      deviceName: 'Gated Device',
      sessionToken: sessionToken,
      deviceType: 'mobile',
      expiresAt: DateTime.now().add(const Duration(days: 1)),
      authGrantSpec: 'control',
    );
    await seed.close();

    final gate = Completer<void>();
    final gatedService = PairingService(
      database: PairingDatabase.forTesting(
        LazyDatabase(() async {
          await gate.future;
          return NativeDatabase(file);
        }),
      ),
    );
    addTearDown(() => gatedService.close());

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final gatedContainer = createHeadlessTestContainer(
      overrides: [
        appVersionProvider.overrideWithValue(
          const AppVersionInfo(version: '2.5.0', buildNumber: 5),
        ),
      ],
    );
    final gatedServer = HeadlessApiServer(
      port: 0,
      container: gatedContainer,
      bindLocalOnly: true,
      authToken: 'admin-token',
      pairingServiceFactory: () => gatedService,
    );
    final started = gatedServer.start();
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (gatedServer.actualPort == 0) {
        if (DateTime.now().isAfter(deadline)) {
          fail('server never bound');
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final uri = Uri.parse('http://127.0.0.1:${gatedServer.actualPort}');

      final duringHydration = _request(
        client,
        uri,
        '/api/devices',
        token: sessionToken,
      );
      // Let the request reach the server before hydration can finish.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      gate.complete();
      final response = await duringHydration;
      expect(
        response.statusCode,
        isNot(HttpStatus.forbidden),
        reason: 'a valid paired token was refused during start-up',
      );
      await started;
    } finally {
      if (!gate.isCompleted) gate.complete();
      await started;
      await gatedServer.stop();
      gatedContainer.dispose();
    }
  });

  test('a pairing database that never answers does not hang every '
      'request', () async {
    // The hold above waited on hydration with no bound. A database open that
    // never returns (a stuck disk) then held every request forever, the
    // public /api/info and an admin token included, where before the hold
    // they were answered.
    final gate = Completer<void>();
    final stuckService = PairingService(
      database: PairingDatabase.forTesting(
        LazyDatabase(() async {
          await gate.future;
          return NativeDatabase.memory();
        }),
      ),
    );
    addTearDown(() => stuckService.close());

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final stuckContainer = createHeadlessTestContainer(
      overrides: [
        appVersionProvider.overrideWithValue(
          const AppVersionInfo(version: '2.5.0', buildNumber: 5),
        ),
      ],
    );
    final stuckServer = HeadlessApiServer(
      port: 0,
      container: stuckContainer,
      bindLocalOnly: true,
      authToken: 'admin-token',
      pairingServiceFactory: () => stuckService,
    );
    final started = stuckServer.start();
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (stuckServer.actualPort == 0) {
        if (DateTime.now().isAfter(deadline)) {
          fail('server never bound');
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final uri = Uri.parse('http://127.0.0.1:${stuckServer.actualPort}');

      final responses =
          await Future.wait([
            _request(client, uri, '/api/info'),
            _request(client, uri, '/api/devices', token: 'admin-token'),
          ]).timeout(
            const Duration(seconds: 20),
            onTimeout: () => fail('requests hung behind a stuck hydration'),
          );
      expect(responses[0].statusCode, HttpStatus.ok);
      expect(responses[1].statusCode, HttpStatus.ok);
    } finally {
      gate.complete();
      await started;
      await stuckServer.stop();
      stuckContainer.dispose();
    }
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
    final encoded = jsonEncode(body);
    request.headers.set('Content-Type', 'application/json');
    request.add(utf8.encode(encoded));
  }
  final response = await request.close();
  final text = await response.transform(utf8.decoder).join();
  final parsed = text.trim().isEmpty
      ? <String, dynamic>{}
      : jsonDecode(text) as Map<String, dynamic>;
  return _TestResponse(statusCode: response.statusCode, body: parsed);
}

class _TestResponse {
  final int statusCode;
  final Map<String, dynamic> body;

  const _TestResponse({required this.statusCode, required this.body});
}
