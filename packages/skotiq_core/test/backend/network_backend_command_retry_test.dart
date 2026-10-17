// Non-idempotent hardware command POSTs (relative focuser/rotator moves, mount
// move-axis/pulse-guide, camera expose) must NOT be auto-retried by the
// transient-failure retry wrapper. A single user-issued relative move /
// exposure must result in at most ONE hardware actuation, even when the first
// request times out on a slow remote link — otherwise an impatient transport
// retry double-actuates the rig.
//
// Two complementary checks:
//   1. Real loopback HttpServer that delays the FIRST response past the client
//      request timeout, then succeeds — the literal "slow link" scenario. The
//      server must receive exactly one request (one actuation).
//   2. Deterministic FakeNetworkClient transient-5xx check that pins
//      maxAttempts==1 for these helpers (parity with connectDevice) while
//      proving the idempotent GET path still fires its 3 retries.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/models/backend/device_types.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart'
    show FrameType;

import '../fakes/fakes.dart';

void main() {
  group('non-idempotent command retry safety (real loopback server)', () {
    late HttpServer server;
    late Map<String, int> hitCounts;
    late Set<String> delayFirstHitPaths;
    final backends = <NetworkBackend>[];

    setUp(() async {
      hitCounts = {};
      delayFirstHitPaths = {};
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest request) async {
        final path = request.uri.path;
        // Count at receipt — this is the point a real host would begin the
        // hardware actuation, before it ever sends a response.
        final count = (hitCounts[path] = (hitCounts[path] ?? 0) + 1);
        await request.drain<Object?>();
        if (delayFirstHitPaths.contains(path) && count == 1) {
          // Outlast the client's request timeout so the first attempt fails
          // with a TimeoutException while the "actuation" has already happened.
          await Future<void>.delayed(const Duration(milliseconds: 1500));
        }
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write('{"status":"ok"}');
        await request.response.close();
      });
    });

    tearDown(() async {
      for (final backend in backends) {
        backend.dispose();
      }
      backends.clear();
      await server.close(force: true);
    });

    NetworkBackend buildBackend() {
      final backend = NetworkBackend(
        serverHost: '127.0.0.1',
        serverPort: server.port,
        webSocketPort: server.port,
        autoConnectWebSocket: false,
        // Short ceiling so the delayed first response trips a TimeoutException
        // quickly; the fast (non-delayed) responses on loopback land well under
        // this.
        requestTimeout: const Duration(milliseconds: 300),
      );
      backends.add(backend);
      return backend;
    }

    test('focuserMoveRelative actuates at most once when the first '
        'response times out', () async {
      delayFirstHitPaths.add('/api/focuser/move-relative');
      final backend = buildBackend();

      await expectLater(
        backend.focuserMoveRelative('focuser-1', 250),
        throwsA(isA<TimeoutException>()),
      );

      expect(
        hitCounts['/api/focuser/move-relative'],
        1,
        reason: 'a timed-out relative move must NOT be auto-resent',
      );
    });

    test('rotatorMoveRelative actuates at most once when the first '
        'response times out', () async {
      delayFirstHitPaths.add('/api/rotator/move-relative');
      final backend = buildBackend();

      await expectLater(
        backend.rotatorMoveRelative('rotator-1', 5.0),
        throwsA(isA<TimeoutException>()),
      );

      expect(hitCounts['/api/rotator/move-relative'], 1);
    });

    test('cameraStartExposure actuates at most once when the first '
        'response times out', () async {
      delayFirstHitPaths.add('/api/camera/expose');
      final backend = buildBackend();

      await expectLater(
        backend.cameraStartExposure(
          deviceId: 'cam-1',
          // Keep the exposure component at zero so this transport-level test
          // still exercises the deliberately tiny 300 ms request ceiling.
          exposureTime: 0,
          frameType: FrameType.light,
        ),
        throwsA(isA<TimeoutException>()),
      );

      expect(
        hitCounts['/api/camera/expose'],
        1,
        reason: 'a timed-out exposure must NOT launch a second capture',
      );
    });

    test('mountMoveAxis actuates at most once when the first '
        'response times out', () async {
      delayFirstHitPaths.add('/api/mount/move-axis');
      final backend = buildBackend();

      await expectLater(
        backend.mountMoveAxis('mount-1', 0, 2.0),
        throwsA(isA<TimeoutException>()),
      );

      expect(hitCounts['/api/mount/move-axis'], 1);
    });

    test('mountPulseGuide actuates at most once when the first '
        'response times out', () async {
      delayFirstHitPaths.add('/api/mount/pulse-guide');
      final backend = buildBackend();

      await expectLater(
        backend.mountPulseGuide(
          deviceId: 'mount-1',
          direction: 'north',
          durationMs: 500,
        ),
        throwsA(isA<TimeoutException>()),
      );

      expect(
        hitCounts['/api/mount/pulse-guide'],
        1,
        reason: 'a timed-out guide pulse must NOT be auto-resent',
      );
    });
  });

  group('retry-policy parity (FakeNetworkClient)', () {
    late FakeNetworkClient fake;
    final backends = <NetworkBackend>[];

    setUp(() {
      fake = FakeNetworkClient();
    });

    tearDown(() {
      for (final backend in backends) {
        backend.dispose();
      }
      backends.clear();
    });

    NetworkBackend buildBackend() {
      final backend = NetworkBackend(
        serverHost: '127.0.0.1',
        serverPort: 9999,
        webSocketPort: 9999,
        httpClient: fake,
        autoConnectWebSocket: false,
      );
      backends.add(backend);
      return backend;
    }

    // A persistent transient 5xx is the retry path's "keep trying" signal. The
    // non-idempotent helpers must still issue exactly ONE POST (maxAttempts==1,
    // parity with connectDevice), never the default 3.
    void expectSingleAttemptOnTransient5xx(
      String endpoint,
      Future<void> Function(NetworkBackend) invoke,
    ) {
      test('$endpoint issues exactly one POST on a transient 5xx '
          '(maxAttempts==1)', () async {
        fake.setResponse(
          endpoint,
          method: 'POST',
          status: 503,
          body: 'service unavailable',
        );
        final backend = buildBackend();

        await expectLater(invoke(backend), throwsA(isA<Object>()));

        expect(
          fake.requestsFor(endpoint),
          hasLength(1),
          reason: 'non-idempotent command must not be auto-retried',
        );
      });
    }

    expectSingleAttemptOnTransient5xx(
      '/api/focuser/move-relative',
      (b) => b.focuserMoveRelative('focuser-1', 250),
    );
    expectSingleAttemptOnTransient5xx(
      '/api/rotator/move-relative',
      (b) => b.rotatorMoveRelative('rotator-1', 5.0),
    );
    expectSingleAttemptOnTransient5xx(
      '/api/mount/move-axis',
      (b) => b.mountMoveAxis('mount-1', 0, 2.0),
    );
    expectSingleAttemptOnTransient5xx(
      '/api/mount/pulse-guide',
      (b) => b.mountPulseGuide(
        deviceId: 'mount-1',
        direction: 'north',
        durationMs: 500,
      ),
    );
    expectSingleAttemptOnTransient5xx(
      '/api/camera/expose',
      (b) => b.cameraStartExposure(
        deviceId: 'cam-1',
        exposureTime: 30,
        frameType: FrameType.light,
      ),
    );

    test('idempotent GET still retries 3x on a transient 5xx '
        '(retry policy preserved)', () async {
      fake.setResponse(
        '/api/devices',
        method: 'GET',
        status: 500,
        body: 'upstream unavailable',
      );
      final backend = buildBackend();

      await expectLater(
        backend.discoverDevices(DeviceType.camera),
        throwsA(isA<Object>()),
      );

      expect(
        fake.requestsFor('/api/devices'),
        hasLength(3),
        reason: 'GET/idempotent retry behaviour must be preserved',
      );
    });
  });
}
