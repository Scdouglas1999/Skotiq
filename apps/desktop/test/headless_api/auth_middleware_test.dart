import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightshade_desktop/headless_api/auth/public_paths.dart';
import 'package:nightshade_desktop/headless_api/auth_policy.dart';
import 'package:nightshade_desktop/headless_api_server.dart';
import 'package:nightshade_core/nightshade_core.dart';

import 'handler_test_helpers.dart';

void main() {
  group('HeadlessApiServer scoped auth middleware', () {
    late ProviderContainer container;
    late HeadlessApiServer server;
    late HttpClient client;
    late Uri baseUri;

    setUp(() async {
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
        scopedAuthTokens: const {
          'view-token': HeadlessTokenScope.view,
          'control-token': HeadlessTokenScope.control,
        },
        webSocketHeartbeatInterval: const Duration(milliseconds: 50),
        webSocketHeartbeatTimeout: const Duration(milliseconds: 500),
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

    test('requires a token for protected metadata endpoints', () async {
      final response = await _request(client, baseUri, '/api/openapi.json');

      expect(response.statusCode, HttpStatus.unauthorized);
      expect(response.body['error'], 'Authentication required');
    });

    test('allows view tokens on read endpoints', () async {
      final response = await _request(
        client,
        baseUri,
        '/api/openapi.json',
        token: 'view-token',
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(response.body['openapi'], '3.0.3');
    });

    test('advertises API compatibility metadata and headers', () async {
      final response = await _request(
        client,
        baseUri,
        '/api/info',
        requestId: 'test-api-info-1',
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers['x-request-id'], 'test-api-info-1');
      expect(response.body['version'], '2.5.0');
      expect(
        response.body['apiVersion'],
        RemoteApiCompatibility.serverApiVersion.format(),
      );
      expect(response.body['minimumSupportedApiVersion'], '2.4.0');
      expect(
        response.body['apiVersionHeader'],
        RemoteApiCompatibility.apiVersionHeader,
      );
      expect(
        response.headers[RemoteApiCompatibility.apiVersionHeader],
        RemoteApiCompatibility.serverApiVersion.format(),
      );
      expect(response.headers['x-nightshade-minimum-api-version'], '2.4.0');
    });

    // D4W-4. The auth-exempt surface used to be written out twice — once as
    // the middleware's allowlist, once as `/api/info`'s `publicEndpoints` —
    // and the published copy had drifted: it named seven paths while the
    // server actually answered thirteen without a token, omitting every
    // broadcast endpoint, the site root and the favicon. Both now read the one
    // declaration in `headless_api/auth/public_paths.dart`, and what is
    // asserted here is the behaviour: everything published answers
    // unauthenticated, and the omitted six are back in the catalog.
    test('publishes the endpoints it really serves without a token', () async {
      final info = await _request(client, baseUri, '/api/info');

      expect(info.statusCode, HttpStatus.ok);
      final published = (info.body['publicEndpoints'] as List).cast<String>();
      expect(published, equals(publishedPublicEndpoints()));
      expect(
        published,
        containsAll(<String>[
          '/api/broadcast/info',
          '/api/broadcast/live-stack',
          '/api/broadcast/sse',
          '/broadcast',
          '/',
          '/favicon.ico',
        ]),
      );

      for (final path in published) {
        final response = await _rawRequest(client, baseUri, path);
        expect(
          response.statusCode,
          isNot(HttpStatus.unauthorized),
          reason: '$path is published as public and must not demand a token',
        );
      }
    });

    test('serves the SPA bundle under a published root', () async {
      final response = await _rawRequest(client, baseUri, '/run-watch/');

      expect(response.statusCode, isNot(HttpStatus.unauthorized));
    });

    test(
      'a path that merely starts like a public root still needs a token',
      () async {
        final response = await _request(client, baseUri, '/dashboard-internal');

        expect(response.statusCode, HttpStatus.unauthorized);
      },
    );

    test('preserves caller-supplied request IDs on protected errors', () async {
      final response = await _request(
        client,
        baseUri,
        '/api/status',
        requestId: 'test-protected-status-1',
      );

      expect(response.statusCode, HttpStatus.unauthorized);
      expect(response.headers['x-request-id'], 'test-protected-status-1');
      expect(response.body['error'], 'Authentication required');
    });

    test(
      'rejects explicit incompatible client API versions before auth',
      () async {
        final tooOld = await _request(
          client,
          baseUri,
          '/api/status',
          apiVersion: '1.9.9',
        );
        final tooNew = await _request(
          client,
          baseUri,
          '/api/status',
          apiVersion: '3.0.0',
        );

        expect(tooOld.statusCode, HttpStatus.upgradeRequired);
        expect(tooOld.body['error'], 'client_too_old');
        expect(
          tooOld.body['serverApiVersion'],
          RemoteApiCompatibility.serverApiVersion.format(),
        );
        expect(tooOld.body['minimumSupportedApiVersion'], '2.4.0');

        expect(tooNew.statusCode, HttpStatus.upgradeRequired);
        expect(tooNew.body['error'], 'server_too_old');
        expect(tooNew.body['clientApiVersion'], '3.0.0');
      },
    );

    test('rejects incompatible WebSocket API versions before auth', () async {
      final tooOld = await _rawSocketRequest(baseUri, [
        'GET /events?apiVersion=1.9.9 HTTP/1.1',
        'Host: 127.0.0.1:${server.actualPort}',
        'Connection: Upgrade',
        'Upgrade: websocket',
        'Sec-WebSocket-Version: 13',
        'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==',
      ]);
      final tooNew = await _rawSocketRequest(baseUri, [
        'GET /events?apiVersion=3.0.0 HTTP/1.1',
        'Host: 127.0.0.1:${server.actualPort}',
        'Connection: Upgrade',
        'Upgrade: websocket',
        'Sec-WebSocket-Version: 13',
        'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==',
      ]);

      expect(tooOld.statusCode, HttpStatus.upgradeRequired);
      expect(tooOld.body['error'], 'client_too_old');
      expect(tooOld.body['minimumSupportedApiVersion'], '2.4.0');

      expect(tooNew.statusCode, HttpStatus.upgradeRequired);
      expect(tooNew.body['error'], 'server_too_old');
      expect(tooNew.body['clientApiVersion'], '3.0.0');
    });

    test('rejects oversized control requests before auth', () async {
      final response = await _rawSocketRequest(baseUri, [
        'POST /api/mount/slew HTTP/1.1',
        'Host: 127.0.0.1:${server.actualPort}',
        'Content-Type: application/json',
        'Content-Length: ${1024 * 1024 + 1}',
        'Connection: close',
      ], body: 'x' * (1024 * 1024 + 1));

      expect(response.statusCode, HttpStatus.requestEntityTooLarge);
      expect(response.body['error'], 'Request body too large');
      expect(response.body['maxBytes'], 1024 * 1024);
    });

    // The chunked-body buffering runs AFTER auth, so an AUTHENTICATED
    // over-limit chunked upload is still rejected with 413 — the streaming cap
    // applies in full to valid credentials. The unauthenticated case is
    // covered separately: it is rejected with 401 before any body is buffered
    // (see http_request_size_limit_test.dart).
    test('rejects chunked oversized control requests for authenticated '
        'callers', () async {
      final body = 'x' * (1024 * 1024 + 1);
      final response = await _rawSocketRequest(baseUri, [
        'POST /api/mount/slew HTTP/1.1',
        'Host: 127.0.0.1:${server.actualPort}',
        'Authorization: Bearer admin-token',
        'Content-Type: application/json',
        'Transfer-Encoding: chunked',
        'x-request-id: test-chunked-too-large-1',
        'Connection: close',
      ], body: '${body.length.toRadixString(16)}\r\n$body\r\n0\r\n\r\n');

      expect(response.statusCode, HttpStatus.requestEntityTooLarge);
      expect(response.body['error'], 'Request body too large');
      expect(response.body['maxBytes'], 1024 * 1024);
      expect(response.body['requestId'], 'test-chunked-too-large-1');
      expect(response.headers['x-request-id'], 'test-chunked-too-large-1');
    });

    test('rate limits repeated high-risk control requests', () async {
      _TestResponse? lastAllowed;
      for (var i = 0; i < 12; i++) {
        lastAllowed = await _request(
          client,
          baseUri,
          '/api/mount/park',
          method: 'POST',
          token: 'admin-token',
          body: const {'deviceId': 'mount-1'},
        );
      }

      expect(lastAllowed, isNotNull);
      expect(lastAllowed!.statusCode, isNot(HttpStatus.tooManyRequests));

      final blocked = await _request(
        client,
        baseUri,
        '/api/mount/park',
        method: 'POST',
        token: 'admin-token',
        requestId: 'test-rate-limited-1',
        body: const {'deviceId': 'mount-1'},
      );

      expect(blocked.statusCode, HttpStatus.tooManyRequests);
      expect(blocked.body['error'], 'Rate limit exceeded');
      expect(blocked.body['maxRequests'], 12);
      expect(blocked.body['requestId'], 'test-rate-limited-1');
      expect(blocked.headers['x-request-id'], 'test-rate-limited-1');
      expect(blocked.headers['retry-after'], isNotNull);
    });

    test('rejects view tokens on control endpoints', () async {
      final response = await _request(
        client,
        baseUri,
        '/api/camera/expose',
        method: 'POST',
        token: 'view-token',
        body: const {'deviceId': 'camera-1'},
      );

      expect(response.statusCode, HttpStatus.forbidden);
      // A genuine coarse shortfall: the pair ranks as a refusal on its own
      // terms, so the back-compat fields stay.
      expect(response.body['requiredScope'], 'control');
      expect(response.body['tokenScope'], 'view');
      expect(response.body['requiredResource'], 'camera');
      expect(response.body['requiredLevel'], 'control');
      expect(response.body['tokenLevel'], 'view');
    });

    test('rejects control tokens on admin endpoints', () async {
      final response = await _request(
        client,
        baseUri,
        '/api/backup/restore',
        method: 'POST',
        token: 'control-token',
        body: const {'filePath': 'backup.zip'},
      );

      expect(response.statusCode, HttpStatus.forbidden);
      expect(response.body['requiredScope'], 'admin');
      expect(response.body['tokenScope'], 'control');
    });

    test('keeps legacy auth token admin-compatible', () async {
      final response = await _request(
        client,
        baseUri,
        '/api/openapi.json',
        token: 'admin-token',
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(response.body['openapi'], '3.0.3');
    });

    test('serves dashboard static assets without auth', () async {
      final cases = <String, String>{
        '/dashboard': 'text/html',
        '/dashboard/css/dashboard.css': 'text/css',
        '/dashboard/js/api.js': 'application/javascript',
        '/dashboard/js/app.js': 'application/javascript',
      };

      for (final entry in cases.entries) {
        final response = await _rawRequest(client, baseUri, entry.key);

        expect(response.statusCode, HttpStatus.ok, reason: entry.key);
        expect(
          response.contentType,
          startsWith(entry.value),
          reason: entry.key,
        );
        expect(response.body, isNotEmpty, reason: entry.key);
      }
    });

    test('self-test reports release-critical runtime sections', () async {
      final info = await _request(client, baseUri, '/api/info');
      final selfTest = await _request(
        client,
        baseUri,
        '/api/self-test',
        token: 'admin-token',
      );

      expect(selfTest.statusCode, HttpStatus.ok);
      expect(selfTest.body['status'], anyOf('ok', 'degraded'));
      expect(selfTest.body['timestamp'], isA<String>());

      final platform = selfTest.body['platform'] as Map<String, dynamic>;
      expect(platform['operatingSystem'], isA<String>());
      expect(platform['executable'], isA<String>());

      final infoPlatformCapabilities =
          info.body['platformCapabilities'] as Map<String, dynamic>;
      expect(infoPlatformCapabilities['platform'], platform['operatingSystem']);
      _expectReleaseScopedDriverMatrix(infoPlatformCapabilities);

      final server = selfTest.body['server'] as Map<String, dynamic>;
      expect(server['authMode'], 'token');
      expect(server['authRequired'], isTrue);
      expect(server['authScopes'], containsAll(['admin', 'control', 'view']));

      final backend = selfTest.body['backend'] as Map<String, dynamic>;
      expect(backend['type'], isA<String>());
      expect(backend['connectedDevices'], isA<Map<String, dynamic>>());

      final deviceDrivers =
          selfTest.body['deviceDrivers'] as Map<String, dynamic>;
      expect(deviceDrivers['platform'], platform['operatingSystem']);
      expect(deviceDrivers['drivers'], isA<List<dynamic>>());
      _expectReleaseScopedDriverMatrix(deviceDrivers);

      expect(selfTest.body['storagePaths'], isA<List<dynamic>>());

      final database = selfTest.body['database'] as Map<String, dynamic>;
      expect(database['name'], 'driftDatabase');
      expect(database['status'], anyOf('ok', 'error'));

      final api = selfTest.body['api'] as Map<String, dynamic>;
      expect(api['selfTestEndpoint'], 'GET /api/self-test');
      expect(api['endpointCount'], (info.body['endpoints'] as List).length);
    });

    test(
      'WebSocket heartbeat pings clients and accepts pong replies',
      () async {
        final socket = await WebSocket.connect(
          'ws://127.0.0.1:${server.actualPort}/events'
          '?token=admin-token&apiVersion=2.5.0',
        );
        final receivedServerPing = Completer<void>();

        final subscription = socket.listen((message) {
          final data = jsonDecode(message as String) as Map<String, dynamic>;
          if (data['type'] == 'ping') {
            socket.add(
              jsonEncode({
                'type': 'pong',
                'timestamp': DateTime.now().toUtc().toIso8601String(),
              }),
            );
            if (!receivedServerPing.isCompleted) {
              receivedServerPing.complete();
            }
          }
        });

        try {
          await receivedServerPing.future.timeout(const Duration(seconds: 2));
          expect(socket.readyState, WebSocket.open);
        } finally {
          await subscription.cancel();
          await socket.close();
        }
      },
    );

    test('WebSocket heartbeat closes stale clients that do not pong', () async {
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:${server.actualPort}/events'
        '?token=admin-token&apiVersion=2.5.0',
      );
      final disconnected = Completer<void>();

      final subscription = socket.listen((_) {
        // Deliberately ignore server pings so the server timeout path runs.
      }, onDone: disconnected.complete);

      try {
        await disconnected.future.timeout(const Duration(seconds: 3));
      } finally {
        await subscription.cancel();
        await socket.close();
      }
    });

    test('collaboration.join uses authenticated identity, ignoring '
        'a spoofed viewerId from the client payload', () async {
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:${server.actualPort}/events'
        '?token=admin-token&apiVersion=2.5.0',
      );

      // Send a join with an obviously-spoofed viewerId. The server must
      // override it with the authenticated principal's digest (the
      // server's `computeServerFingerprint(admin-token)`).
      try {
        socket.add(
          jsonEncode({
            'type': 'collaboration.join',
            'viewerId': 'pretend-to-be-someone-else',
            'name': 'Spoofy McSpoof',
          }),
        );

        // Wait long enough for the upsertViewer call to propagate; the
        // server broadcasts a `collaboration_state` frame every time
        // viewers mutate, so we wait for that as a signal the upsert
        // completed.
        final stateFrameReceived = Completer<Map<String, dynamic>>();
        final subscription = socket.listen((message) {
          final data = jsonDecode(message as String) as Map<String, dynamic>;
          if (data['type'] == 'collaboration_state') {
            final state = data['state'];
            if (state is Map<String, dynamic>) {
              final viewers = (state['viewers'] as List?) ?? const [];
              if (viewers.whereType<Map<String, dynamic>>().any(
                (v) => v['name'] == 'Spoofy McSpoof',
              )) {
                if (!stateFrameReceived.isCompleted) {
                  stateFrameReceived.complete(state);
                }
              }
            }
          }
        });

        try {
          await stateFrameReceived.future.timeout(const Duration(seconds: 5));
        } finally {
          await subscription.cancel();
        }

        // Pull the post-join state off the collaboration manager and
        // verify the slot id is NOT the spoofed value.
        final viewers = server.collaborationManager.state.viewers;
        final spoofy = viewers
            .where((v) => v.name == 'Spoofy McSpoof')
            .toList(growable: false);
        expect(
          spoofy,
          hasLength(1),
          reason:
              'collaboration.join must always upsert a slot, even when '
              'the payload includes a spoofed viewerId',
        );
        expect(
          spoofy.single.viewerId,
          isNot('pretend-to-be-someone-else'),
          reason:
              'server MUST ignore client-supplied viewerId and use '
              'the authenticated principal\'s digest',
        );
        expect(
          spoofy.single.viewerId,
          isNotEmpty,
          reason: 'authenticated digest must not be empty',
        );
      } finally {
        await socket.close();
      }
    });

    /// Send [message] on an /events socket opened with [token], wait for the
    /// server to act on it, then read the handoff back over HTTP as admin.
    Future<({Object? handoff, List<Map<String, dynamic>> frames})>
    handoffAfterSocketMessage(
      String token,
      Map<String, dynamic> message,
    ) async {
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:${server.actualPort}/events'
        '?token=$token&apiVersion=2.5.0',
      );
      final frames = <Map<String, dynamic>>[];
      final subscription = socket.listen((raw) {
        frames.add(jsonDecode(raw as String) as Map<String, dynamic>);
      });
      try {
        socket.add(jsonEncode(message));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      } finally {
        await subscription.cancel();
        await socket.close();
      }
      final read = await _request(
        client,
        baseUri,
        '/api/session-handoff',
        token: 'admin-token',
      );
      expect(read.statusCode, HttpStatus.ok);
      return (handoff: read.body['sessionHandoff'], frames: frames);
    }

    test('a view token cannot set the session handoff over the event '
        'socket, as it cannot over HTTP', () async {
      final http = await _request(
        client,
        baseUri,
        '/api/session-handoff',
        method: 'POST',
        token: 'view-token',
        body: {'owner': 'intruder'},
      );
      expect(http.statusCode, HttpStatus.forbidden);

      final result = await handoffAfterSocketMessage('view-token', {
        'type': 'session_handoff.set',
        'handoff': {'owner': 'intruder'},
      });
      expect(
        result.handoff,
        isNull,
        reason: 'the socket let a view token hand the session over',
      );
      expect(
        result.frames.where((f) => f['type'] == 'error'),
        isNotEmpty,
        reason: 'the refusal is reported on the socket, not dropped',
      );
    });

    test('an admin token still sets and clears the session handoff over '
        'the event socket', () async {
      final set = await handoffAfterSocketMessage('admin-token', {
        'type': 'session_handoff.set',
        'handoff': {'owner': 'observatory'},
      });
      expect(set.handoff, {'owner': 'observatory'});

      final cleared = await handoffAfterSocketMessage('admin-token', {
        'type': 'session_handoff.clear',
      });
      expect(cleared.handoff, isNull);
    });

    test('a view token cannot post to the shared session over the event '
        'socket, as it cannot over HTTP', () async {
      final routes = {
        '/api/collaboration/preview': {
          'preview': {'frame': 'intruder'},
        },
        '/api/collaboration/chat': {'viewerName': 'Intruder', 'message': 'hi'},
        '/api/collaboration/annotations': {
          'annotationId': 'a1',
          'kind': 'label',
          'payload': {'text': 'intruder'},
        },
      };
      for (final entry in routes.entries) {
        final http = await _request(
          client,
          baseUri,
          entry.key,
          method: 'POST',
          token: 'view-token',
          body: entry.value,
        );
        expect(http.statusCode, HttpStatus.forbidden, reason: entry.key);
      }

      final result = await handoffAfterSocketMessage('view-token', {
        'type': 'collaboration.preview',
        'preview': {'frame': 'intruder'},
      });
      await handoffAfterSocketMessage('view-token', {
        'type': 'collaboration.chat',
        'viewerName': 'Intruder',
        'message': 'hi',
      });
      await handoffAfterSocketMessage('view-token', {
        'type': 'collaboration.annotation',
        'annotationId': 'a1',
        'kind': 'label',
        'payload': {'text': 'intruder'},
      });

      final state = server.collaborationManager.state;
      expect(
        state.preview,
        isNull,
        reason: 'the socket let a view token replace the shared preview',
      );
      expect(state.chat, isEmpty, reason: 'the socket let a view token chat');
      expect(
        state.annotations,
        isEmpty,
        reason: 'the socket let a view token annotate',
      );
      expect(
        result.frames.where((f) => f['type'] == 'error'),
        isNotEmpty,
        reason: 'the refusal is reported on the socket, not dropped',
      );
    });

    test('a control token still posts to the shared session over the event '
        'socket', () async {
      await handoffAfterSocketMessage('control-token', {
        'type': 'collaboration.preview',
        'preview': {'frame': 'rig'},
      });
      await handoffAfterSocketMessage('control-token', {
        'type': 'collaboration.chat',
        'viewerName': 'Operator',
        'message': 'focus looks good',
      });
      await handoffAfterSocketMessage('control-token', {
        'type': 'collaboration.annotation',
        'annotationId': 'a2',
        'kind': 'label',
        'payload': {'text': 'M31'},
      });

      final state = server.collaborationManager.state;
      expect(state.preview, {'frame': 'rig'});
      expect(state.chat, hasLength(1));
      expect(state.annotations, hasLength(1));
    });
  });

  group('HeadlessApiServer fine-grained auth middleware', () {
    late ProviderContainer container;
    late HeadlessApiServer server;
    late HttpClient client;
    late Uri baseUri;

    setUp(() async {
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
        fineGrainedAuthTokens: {
          // control the camera, only watch the mount.
          'cam-token': HeadlessAuthGrant.parseSpec(
            'camera:control,mount:view',
          )!,
        },
        webSocketHeartbeatInterval: const Duration(milliseconds: 50),
        webSocketHeartbeatTimeout: const Duration(milliseconds: 500),
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

    test('camera-scoped token may expose the camera', () async {
      final response = await _request(
        client,
        baseUri,
        '/api/camera/expose',
        method: 'POST',
        token: 'cam-token',
        body: const {'durationSeconds': 1},
      );
      // The grant permits the route; the handler may still 4xx/5xx on the
      // request body, but it must NOT be a 403 scope rejection.
      expect(response.statusCode, isNot(HttpStatus.forbidden));
    });

    test('camera-scoped token may read mount status', () async {
      final response = await _request(
        client,
        baseUri,
        '/api/mount/status',
        token: 'cam-token',
      );
      expect(response.statusCode, isNot(HttpStatus.forbidden));
    });

    test('camera-scoped token is forbidden from slewing the mount', () async {
      final response = await _request(
        client,
        baseUri,
        '/api/mount/slew',
        method: 'POST',
        token: 'cam-token',
        body: const {'ra': 1.0, 'dec': 1.0},
      );
      expect(response.statusCode, HttpStatus.forbidden);
      expect(response.body['requiredResource'], 'mount');
      expect(response.body['requiredLevel'], 'control');
      // What this credential holds on the resource it was refused for is the
      // fact that explains the refusal.
      expect(response.body['tokenLevel'], 'view');
      // The back-compat coarse pair is NOT emitted here, and that is the
      // point: `camera:control,mount:view` projects to the coarse scope
      // `control`, and the route's coarse requirement is `control`, so the
      // pair used to read requiredScope=control beside tokenScope=control —
      // the body asserting the requirement was satisfied on a refusal. A pair
      // that does not explain the outcome is left out rather than printed as
      // a contradiction; the coarse-shortfall case keeps it (see 'rejects
      // view tokens on control endpoints').
      expect(response.body.containsKey('requiredScope'), isFalse);
      expect(response.body.containsKey('tokenScope'), isFalse);
    });
  });
}

void _expectReleaseScopedDriverMatrix(Map<String, dynamic> report) {
  final drivers = (report['drivers'] as List<dynamic>)
      .cast<Map<String, dynamic>>();
  final byBackend = {
    for (final driver in drivers) driver['backend'] as String: driver,
  };

  expect(
    byBackend.keys,
    containsAll(['ascom', 'alpaca', 'indi', 'native', 'simulator']),
  );

  final ascom = byBackend['ascom']!;
  expect(ascom['label'], 'ASCOM COM');
  expect(
    ascom['supportedPlatforms'],
    equals([PlatformCapabilityMatrix.windows]),
  );
  expect(ascom['notes'], contains('Windows-only ASCOM driver installations'));
  if (report['platform'] == PlatformCapabilityMatrix.windows) {
    expect(ascom['status'], 'available');
    expect(ascom['unsupportedReason'], isNull);
  } else {
    expect(ascom['status'], 'unsupported');
    expect(ascom['unsupportedReason'], contains('Windows COM drivers'));
  }

  final native = byBackend['native']!;
  expect(native['status'], 'capability-gated');
  expect(native['unsupportedReason'], isNull);
  expect(native['notes'], contains('packaged libraries'));

  final indi = byBackend['indi']!;
  expect(indi['notes'], contains('reachable INDI server'));

  final simulator = byBackend['simulator']!;
  expect(simulator['status'], 'capability-gated');
  expect(simulator['notes'], contains('workflow-specific'));
}

Future<_TestResponse> _request(
  HttpClient client,
  Uri baseUri,
  String path, {
  String method = 'GET',
  String? token,
  String? apiVersion,
  String? requestId,
  Map<String, dynamic>? body,
}) async {
  final request = await client.openUrl(method, baseUri.resolve(path));
  request.headers.contentType = ContentType.json;
  if (requestId != null) {
    request.headers.set('x-request-id', requestId);
  }
  if (apiVersion != null) {
    request.headers.set(RemoteApiCompatibility.apiVersionHeader, apiVersion);
  }
  if (token != null) {
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  }
  if (body != null) {
    request.write(jsonEncode(body));
  }

  final response = await request.close();
  final responseBody = await response.transform(utf8.decoder).join();
  final headers = <String, String>{};
  response.headers.forEach((name, values) {
    headers[name.toLowerCase()] = values.join(',');
  });
  return _TestResponse(
    statusCode: response.statusCode,
    headers: headers,
    body: responseBody.isEmpty
        ? const <String, dynamic>{}
        : jsonDecode(responseBody) as Map<String, dynamic>,
  );
}

Future<_RawTestResponse> _rawRequest(
  HttpClient client,
  Uri baseUri,
  String path,
) async {
  final request = await client.getUrl(baseUri.resolve(path));
  final response = await request.close();
  return _RawTestResponse(
    statusCode: response.statusCode,
    contentType: response.headers.value(HttpHeaders.contentTypeHeader) ?? '',
    body: await response.transform(utf8.decoder).join(),
  );
}

Future<_TestResponse> _rawSocketRequest(
  Uri baseUri,
  List<String> headers, {
  String body = '',
}) async {
  final socket = await Socket.connect(baseUri.host, baseUri.port);
  socket.write('${headers.join('\r\n')}\r\n\r\n$body');
  await socket.flush();

  final responseText = await utf8.decoder.bind(socket).join();
  await socket.close();

  final separator = responseText.indexOf('\r\n\r\n');
  final head = separator == -1
      ? responseText
      : responseText.substring(0, separator);
  final responseBody = separator == -1
      ? ''
      : responseText.substring(separator + 4);
  final statusLine = head.split('\r\n').first;
  final statusCode = int.parse(statusLine.split(' ')[1]);
  final responseHeaders = <String, String>{};
  for (final line in head.split('\r\n').skip(1)) {
    final nameSeparator = line.indexOf(':');
    if (nameSeparator <= 0) {
      continue;
    }
    responseHeaders[line.substring(0, nameSeparator).toLowerCase()] = line
        .substring(nameSeparator + 1)
        .trim();
  }
  final parsedBody = responseBody.trim().isEmpty
      ? const <String, dynamic>{}
      : jsonDecode(responseBody) as Map<String, dynamic>;

  return _TestResponse(
    statusCode: statusCode,
    headers: responseHeaders,
    body: parsedBody,
  );
}

class _TestResponse {
  final int statusCode;
  final Map<String, String> headers;
  final Map<String, dynamic> body;

  const _TestResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
  });
}

class _RawTestResponse {
  final int statusCode;
  final String contentType;
  final String body;

  const _RawTestResponse({
    required this.statusCode,
    required this.contentType,
    required this.body,
  });
}
