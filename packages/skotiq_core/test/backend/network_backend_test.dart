// Smoke tests for `NetworkBackend` request/response paths, using the
// `FakeNetworkClient` MockClient-based fake so no real HTTP server is needed.
//
// Why: `NetworkBackend` is the Mobile app's contract surface with the
// headless desktop. Before a later refactor rewrites it, we need a guard that:
//
//   * GETs go to the documented endpoints (`/api/devices`)
//   * HTTP failure codes are surfaced as `SkotiqError`, never silently
// dropped or returned as empty lists (no silent fallbacks here)
//   * Malformed JSON propagates as an exception
//   * The pairing token is sent in the `Authorization: Bearer ...` header
//
// These are intentionally a small set of high-signal cases; full coverage
// of every endpoint is the follow-on scope of W-TEST.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:skotiq_core/src/backend/disconnected_backend.dart';
import 'package:skotiq_core/src/backend/skotiq_exception.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/models/backend/device_types.dart';
import 'package:skotiq_core/src/models/backend/image_result.dart';
import 'package:skotiq_core/src/models/errors/skotiq_error.dart';
import 'package:skotiq_core/src/models/equipment_profile.dart';
import 'package:skotiq_core/src/models/plate_solver.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';

import '../fakes/fakes.dart';
import '../harness/in_memory_database.dart';

NetworkBackend _buildBackend(
  FakeNetworkClient fake, {
  String? authToken,
  Future<String?> Function()? refreshAuthToken,
}) {
  return NetworkBackend(
    serverHost: '127.0.0.1',
    serverPort: 9999,
    webSocketPort: 9999,
    authToken: authToken,
    refreshAuthToken: refreshAuthToken,
    httpClient: fake,
    autoConnectWebSocket: false,
  );
}

void main() {
  group('NetworkBackend (FakeNetworkClient)', () {
    late FakeNetworkClient fake;
    late NetworkBackend backend;

    setUp(() {
      fake = FakeNetworkClient();
    });

    tearDown(() {
      backend.dispose();
    });

    test(
      'discoverDevices issues a GET /api/devices and decodes the body',
      () async {
        fake.setResponse(
          '/api/devices',
          method: 'GET',
          body:
              '{"devices":[{"id":"sim:cam:0","name":"Sim Camera",'
              '"deviceType":"camera","driverType":"simulator",'
              '"description":"","driverVersion":"1.0"}]}',
        );
        backend = _buildBackend(fake);

        final devices = await backend.discoverDevices(DeviceType.camera);

        expect(devices, hasLength(1));
        expect(devices.single.id, 'sim:cam:0');
        expect(devices.single.driverType, DriverType.simulator);

        final issued = fake.requestsFor('/api/devices');
        expect(issued, hasLength(1));
        expect(issued.single.method, 'GET');
      },
    );

    test('a 401 response is surfaced as a structured SkotiqError, '
        'not silently swallowed', () async {
      // 401 is non-transient, so we expect exactly one request and an
      // immediate failure.
      fake.setResponse(
        '/api/devices',
        method: 'GET',
        status: 401,
        body: '{"error":"unauthorized","message":"missing pairing token"}',
      );
      backend = _buildBackend(fake);

      // The fail-closed contract: errors propagate; they are not returned
      // as an empty device list.
      await expectLater(
        backend.discoverDevices(DeviceType.camera),
        throwsA(
          isA<SkotiqError>().having(
            (e) => e.message,
            'message',
            contains('missing pairing token'),
          ),
        ),
      );
      expect(fake.requestsFor('/api/devices'), hasLength(1));
    });

    test('refreshes auth token once after 401 and retries discovery', () async {
      fake.setResponseSequence(
        '/api/devices',
        method: 'GET',
        responses: [
          (
            status: 401,
            body: '{"error":"unauthorized","message":"expired token"}',
            headers: null,
          ),
          (
            status: 200,
            body:
                '{"devices":[{"id":"sim:cam:1","name":"Sim Camera",'
                '"deviceType":"camera","driverType":"simulator",'
                '"description":"","driverVersion":"1.0"}]}',
            headers: null,
          ),
        ],
      );
      var refreshCount = 0;
      backend = _buildBackend(
        fake,
        authToken: 'expired-token',
        refreshAuthToken: () async {
          refreshCount++;
          return 'fresh-token';
        },
      );

      final devices = await backend.discoverDevices(DeviceType.camera);

      expect(devices, hasLength(1));
      expect(refreshCount, 1);
      final requests = fake.requestsFor('/api/devices');
      expect(requests, hasLength(2));
      expect(
        _headerValue(requests.first.headers, 'Authorization'),
        'Bearer expired-token',
      );
      expect(
        _headerValue(requests.last.headers, 'Authorization'),
        'Bearer fresh-token',
      );
    });

    test('a 500 response is retried as a transient failure and surfaces '
        'as a recoverable SkotiqError', () async {
      // Use a plain (non-JSON) body so `_parseErrorResponse` exercises the
      // HTTP-status-based fallback path; that path marks 5xx as recoverable
      // (`_isTransientStatusCode`), which is the behaviour we want to lock
      // in. A structured legacy `{error, message}` body would short-circuit
      // to `SkotiqError.fromString`, which is HTTP-status-blind.
      fake.setResponse(
        '/api/devices',
        method: 'GET',
        status: 500,
        body: 'upstream unavailable',
      );
      backend = _buildBackend(fake);

      try {
        await backend.discoverDevices(DeviceType.camera);
        fail('Expected discoverDevices to throw on persistent 500');
      } on SkotiqError catch (err) {
        expect(
          err.isRecoverable,
          isTrue,
          reason: '5xx must surface as transient/recoverable',
        );
        expect(err.message, contains('500'));
      }

      // The retry policy fires 3 attempts for transient failures.
      expect(fake.requestsFor('/api/devices'), hasLength(3));
    });

    test('malformed JSON in a 200 response is surfaced, not returned as '
        'empty', () async {
      fake.setResponse(
        '/api/devices',
        method: 'GET',
        body: '{this is not valid json',
      );
      backend = _buildBackend(fake);

      // Critical: silent `return []` here would mask backend corruption.
      // We assert that *some* exception propagates.
      await expectLater(
        backend.discoverDevices(DeviceType.camera),
        throwsA(isA<Object>()),
      );
    });

    test(
      'profile save preserves the authoritative id returned by the host',
      () async {
        fake.setResponse(
          '/api/profiles',
          method: 'POST',
          body: '{"status":"saved","id":"42"}',
        );
        backend = _buildBackend(fake);

        await backend.saveProfile(
          const EquipmentProfile(id: '', name: 'Remote Rig'),
        );

        expect(backend.lastSavedProfileId, '42');
        expect(fake.requestsFor('/api/profiles'), hasLength(1));
      },
    );

    test(
      'profile save rejects a success response without a valid id',
      () async {
        fake.setResponse(
          '/api/profiles',
          method: 'POST',
          body: '{"status":"saved"}',
        );
        backend = _buildBackend(fake);

        await expectLater(
          backend.saveProfile(
            const EquipmentProfile(id: '', name: 'Remote Rig'),
          ),
          throwsA(isA<FormatException>()),
        );
        expect(backend.lastSavedProfileId, isNull);
      },
    );

    test(
      'request headers include the pairing token when authToken is set',
      () async {
        fake.setResponse('/api/devices', method: 'GET', body: '{"devices":[]}');
        backend = _buildBackend(fake, authToken: 'secret-token-abc');

        await backend.discoverDevices(DeviceType.camera);

        final captured = fake.requestsFor('/api/devices').single;
        // Why: `package:http` normalises header names to lowercase on the
        // wire, so we look up case-insensitively. The header *value* is
        // load-bearing — it carries the pairing token.
        final auth = _headerValue(captured.headers, 'Authorization');
        expect(
          auth,
          'Bearer secret-token-abc',
          reason: 'Authorization header must carry the bearer token when set',
        );
        // The compat-version and trace-id headers are always added by
        // `_addAuthHeaders`; lock that in so future refactors don't drop
        // them silently.
        final keys = captured.headers.keys.map((k) => k.toLowerCase()).toList();
        expect(keys, contains('x-skotiq-api-version'));
        expect(keys, contains('x-request-id'));
      },
    );

    test('secondary rig operations target the host sequencer routes', () async {
      fake.setResponse(
        '/api/sequencer/secondary-rig',
        method: 'GET',
        body: jsonEncode({
          'armed': true,
          'running': true,
          'cameraId': 'remote-camera-2',
        }),
      );
      fake.setResponse(
        '/api/sequencer/secondary-rig/start',
        method: 'POST',
        body: '{"status":"started"}',
      );
      fake.setResponse(
        '/api/sequencer/secondary-rig/stop',
        method: 'POST',
        body: '{"status":"stopped"}',
      );
      backend = _buildBackend(fake);

      final status = await backend.secondaryRigGetStatus();
      await backend.secondaryRigStart({
        'cameraId': 'remote-camera-2',
        'exposureSecs': 60.0,
        'saveBasePath': '/data/skotiq',
      });
      await backend.secondaryRigStop();

      expect(status['cameraId'], 'remote-camera-2');
      final start = fake
          .requestsFor('/api/sequencer/secondary-rig/start')
          .single;
      expect(start.method, 'POST');
      final payload = jsonDecode(start.body!) as Map<String, dynamic>;
      expect(payload['saveBasePath'], '/data/skotiq');
      expect(
        fake.requestsFor('/api/sequencer/secondary-rig/stop'),
        hasLength(1),
      );
    });

    test(
      'omits the Authorization header when no authToken is configured',
      () async {
        fake.setResponse('/api/devices', method: 'GET', body: '{"devices":[]}');
        backend = _buildBackend(fake);

        await backend.discoverDevices(DeviceType.camera);

        final captured = fake.requestsFor('/api/devices').single;
        // Why: anonymous callers must not send an empty/bogus Authorization
        // header — the headless server treats presence-but-empty as a
        // misconfigured client.
        expect(_headerValue(captured.headers, 'Authorization'), isNull);
      },
    );

    test('cameraGetLastImage uses GET /api/camera/last-image/jpeg', () async {
      final bitmap = img.Image(width: 4, height: 2);
      bitmap.setPixelRgba(0, 0, 10, 20, 30, 255);
      final jpegBytes = img.encodeJpg(bitmap, quality: 90);
      final metaHeader = base64Encode(
        utf8.encode(
          jsonEncode({
            'width': 4,
            'height': 2,
            'encodedWidth': 4,
            'encodedHeight': 2,
            'histogram': List<int>.filled(256, 0),
            'stats': const ImageStatsResult(
              min: 0,
              max: 100,
              mean: 50,
              median: 50,
              stdDev: 10,
              starCount: 3,
            ).toJson(),
            'exposureTime': 1.5,
            'timestamp': '2026-05-23T12:00:00.000Z',
            'isColor': false,
          }),
        ),
      );

      fake.setBinaryResponse(
        '/api/camera/last-image/jpeg',
        bodyBytes: jpegBytes,
        headers: {'content-type': 'image/jpeg', 'x-image-meta': metaHeader},
      );
      backend = _buildBackend(fake);

      final image = await backend.cameraGetLastImage('cam-1');

      expect(image, isNotNull);
      expect(image!.width, 4);
      expect(image.height, 2);
      expect(image.displayData.length, 4 * 2 * 4);
      expect(image.stats.starCount, 3);

      final issued = fake.requestsFor('/api/camera/last-image/jpeg');
      expect(issued, hasLength(1));
      expect(issued.single.method, 'GET');
      expect(issued.single.url.queryParameters['deviceId'], 'cam-1');
      expect(fake.requestsFor('/api/camera/last-image'), isEmpty);
    });

    test('cameraGetLastImage returns null when JPEG endpoint is 404', () async {
      fake.setBinaryResponse(
        '/api/camera/last-image/jpeg',
        status: 404,
        bodyBytes: utf8.encode(
          '{"error":"no_image","message":"No image captured"}',
        ),
        headers: const {'content-type': 'application/json'},
      );
      backend = _buildBackend(fake);

      final image = await backend.cameraGetLastImage('cam-1');
      expect(image, isNull);
    });

    test('getLastRawImageData decodes little-endian u16 pixels', () async {
      fake.setBinaryResponse(
        '/api/imaging/raw-data',
        bodyBytes: const [
          0x00,
          0x00,
          0x01,
          0x00,
          0xff,
          0x00,
          0x00,
          0x01,
          0x34,
          0x12,
          0xff,
          0xff,
        ],
      );
      backend = _buildBackend(fake);

      final pixels = await backend.getLastRawImageData('cam-1');

      expect(pixels, [0, 1, 255, 256, 0x1234, 0xffff]);
      final issued = fake.requestsFor('/api/imaging/raw-data');
      expect(issued, hasLength(1));
      expect(issued.single.url.queryParameters['deviceId'], 'cam-1');
    });

    test('getLastRawImageData rejects an odd-length payload', () async {
      fake.setBinaryResponse(
        '/api/imaging/raw-data',
        bodyBytes: const [0x00, 0x01, 0x02],
      );
      backend = _buildBackend(fake);

      await expectLater(
        backend.getLastRawImageData('cam-1'),
        throwsA(isA<IoException>()),
      );
    });

    test('detectPlateSolvers GETs the HOST /api/plate-solver/detect and '
        'decodes the host filesystem probe', () async {
      // Remote-parity: a phone's plate-solver setup must probe the HOST,
      // not the phone. This proves the NetworkBackend forwards detection to
      // the host endpoint and returns what the host found on its disk.
      fake.setResponse(
        '/api/plate-solver/detect',
        method: 'GET',
        body:
            '{"astapPath":"C:/ASTAP/astap.exe",'
            '"astrometryPath":null,'
            '"catalogName":"V17",'
            '"catalogMagnitudeLimit":17.0,'
            '"catalogPath":"C:/ASTAP"}',
      );
      backend = _buildBackend(fake);

      final detection = await backend.detectPlateSolvers();

      expect(fake.requestsFor('/api/plate-solver/detect'), hasLength(1));
      expect(detection.astapPath, 'C:/ASTAP/astap.exe');
      expect(detection.astrometryPath, isNull);
      expect(detection.catalogName, 'V17');
      expect(detection.catalogMagnitudeLimit, 17.0);
      expect(detection.catalogPath, 'C:/ASTAP');
      expect(detection.hasAnySolver, isTrue);
    });

    test('getPlateSolverConfig GETs the HOST /api/plate-solver/config and '
        'decodes the host-persisted preference', () async {
      fake.setResponse(
        '/api/plate-solver/config',
        method: 'GET',
        body:
            '{"astapPath":"C:/ASTAP/astap.exe",'
            '"astrometryPath":"",'
            '"catalogPath":"C:/ASTAP",'
            '"solverChoice":"astap"}',
      );
      backend = _buildBackend(fake);

      final pref = await backend.getPlateSolverConfig();

      expect(fake.requestsFor('/api/plate-solver/config'), hasLength(1));
      expect(pref.astapPath, 'C:/ASTAP/astap.exe');
      expect(pref.astrometryPath, '');
      expect(pref.catalogPath, 'C:/ASTAP');
      expect(pref.choice, PlateSolverChoice.astap);
    });

    test('setPlateSolverConfig POSTs the preference to the HOST '
        '/api/plate-solver/config', () async {
      fake.setResponse(
        '/api/plate-solver/config',
        method: 'POST',
        body: '{"status":"saved"}',
      );
      backend = _buildBackend(fake);

      await backend.setPlateSolverConfig(
        const PlateSolverPreference(
          astapPath: 'C:/ASTAP/astap.exe',
          astrometryPath: '',
          catalogPath: 'C:/ASTAP',
          choice: PlateSolverChoice.astap,
        ),
      );

      final posts = fake
          .requestsFor('/api/plate-solver/config')
          .where((r) => r.method == 'POST')
          .toList();
      expect(posts, hasLength(1));
      final sent = jsonDecode(posts.single.body!) as Map<String, dynamic>;
      expect(sent['astapPath'], 'C:/ASTAP/astap.exe');
      expect(sent['catalogPath'], 'C:/ASTAP');
      expect(sent['solverChoice'], 'astap');
    });

    test(
      'getConnectedDevices decodes deviceType field from host API',
      () async {
        fake.setResponse(
          '/api/devices/connected',
          method: 'GET',
          body:
              '{"devices":[{"id":"ascom:mount:0","name":"My Mount",'
              '"deviceType":"mount","driverType":"ascom",'
              '"description":"","driverVersion":"1.0"}]}',
        );
        backend = _buildBackend(fake);

        final devices = await backend.getConnectedDevices();

        expect(devices, hasLength(1));
        expect(devices.single.id, 'ascom:mount:0');
        expect(devices.single.deviceType, DeviceType.mount);
        expect(devices.single.driverType, DriverType.ascom);
      },
    );

    test('plate solve awaits a queued host job before decoding', () async {
      fake.setResponse(
        '/api/plate-solve',
        method: 'POST',
        body: '{"jobId":"solve-1","status":"queued"}',
      );
      fake.setResponse(
        '/api/jobs/solve-1',
        method: 'GET',
        body: jsonEncode({
          'jobId': 'solve-1',
          'operation': 'plate-solve',
          'state': 'succeeded',
          'result': {
            'success': true,
            'ra': 12.3,
            'dec': -4.5,
            'pixelScale': 1.2,
            'rotation': 3.4,
            'fieldWidth': 2.0,
            'fieldHeight': 1.5,
            'solveTimeSecs': 0.8,
          },
        }),
      );
      backend = _buildBackend(fake);

      final result = await backend.plateSolve(
        imagePath: '/host/frame.fits',
        timeoutSeconds: 47,
      );

      expect(result.success, isTrue);
      expect(result.ra, 12.3);
      final solveRequest = fake.requestsFor('/api/plate-solve').single;
      final solveBody = jsonDecode(solveRequest.body!) as Map<String, dynamic>;
      expect(solveBody['timeoutSeconds'], 47);
      expect(fake.requestsFor('/api/jobs/solve-1'), hasLength(1));
    });

    test('autofocus awaits a queued host job before decoding', () async {
      fake.setResponse(
        '/api/focuser/autofocus/start',
        method: 'POST',
        body: '{"jobId":"af-1","status":"queued"}',
      );
      fake.setResponse(
        '/api/jobs/af-1',
        method: 'GET',
        body: jsonEncode({
          'jobId': 'af-1',
          'operation': 'focuser.autofocus',
          'state': 'succeeded',
          'result': {
            'bestPosition': 12345,
            'bestHfr': 1.8,
            'focusData': <Object>[],
            'method': 'VCurve',
            'timestamp': 1,
            'curveFitQuality': 0.95,
            'backlashApplied': true,
          },
        }),
      );
      backend = _buildBackend(fake);

      final result = await backend.autofocusStart(
        deviceId: 'focuser-1',
        cameraId: 'camera-1',
        exposureTime: 2,
        stepSize: 50,
        stepsOut: 4,
        gain: 123,
        offset: 17,
        curveFitting: 'Parabolic',
        numberOfAttempts: 3,
        exposuresPerPoint: 2,
        rSquaredThreshold: 0.91,
        outerCropRatio: 0.8,
        innerCropRatio: 0.1,
        useBrightestNStars: 20,
        focuserSettleTimeMs: 750,
        backlashCompMethod: 'Inward',
        backlashIn: 120,
        backlashOut: 30,
      );

      expect(result.bestPosition, 12345);
      expect(result.bestHfr, 1.8);
      final request = fake.requestsFor('/api/focuser/autofocus/start').single;
      final payload = jsonDecode(request.body!) as Map<String, dynamic>;
      expect(payload['curveFitting'], 'Parabolic');
      expect(payload['gain'], 123);
      expect(payload['offset'], 17);
      expect(payload['numberOfAttempts'], 3);
      expect(payload['exposuresPerPoint'], 2);
      expect(payload['rSquaredThreshold'], 0.91);
      expect(payload['outerCropRatio'], 0.8);
      expect(payload['innerCropRatio'], 0.1);
      expect(payload['useBrightestNStars'], 20);
      expect(payload['focuserSettleTimeMs'], 750);
      expect(payload['backlashCompMethod'], 'Inward');
      expect(payload['backlashIn'], 120);
      expect(payload['backlashOut'], 30);
    });

    test('center on target returns the queued job result envelope', () async {
      fake.setResponse(
        '/api/framing/center-on-target',
        method: 'POST',
        body: '{"jobId":"center-1","status":"queued"}',
      );
      fake.setResponse(
        '/api/jobs/center-1',
        method: 'GET',
        body: jsonEncode({
          'jobId': 'center-1',
          'operation': 'framing.center-on-target',
          'state': 'succeeded',
          'result': {
            'success': true,
            'iterations': 2,
            'finalOffsetArcsec': 4.2,
            'iterationHistory': <Object>[],
          },
        }),
      );
      backend = _buildBackend(fake);

      final result = await backend.centerOnTarget(ra: 10, dec: 20);

      expect(result['success'], isTrue);
      expect(result['iterations'], 2);
    });

    test('webSocketPort defaults to serverPort when explicitly set', () {
      backend = NetworkBackend(
        serverHost: '127.0.0.1',
        serverPort: 4321,
        webSocketPort: 4321,
        autoConnectWebSocket: false,
      );
      expect(backend.serverPort, 4321);
      expect(backend.webSocketPort, 4321);
      backend.dispose();
    });
  });

  group('BackendNotifier remote connect', () {
    test(
      'rolls back to a disconnected backend when the handshake fails',
      () async {
        final container = ProviderContainer(
          overrides: [inMemoryDatabaseOverride()],
        );
        addTearDown(container.dispose);

        // Nothing is listening on this port, so the `/api/info` handshake is
        // refused. connect() must NOT leave the half-built NetworkBackend
        // installed — a refused connection is not a connection, and
        // isRemoteModeProvider / ConnectionSettings must not read it as one.
        await expectLater(
          container
              .read(backendProvider.notifier)
              .connect('127.0.0.1', 8765, authToken: 'test-token'),
          throwsA(
            isA<SkotiqError>().having(
              (e) => e.isRecoverable,
              'isRecoverable',
              isTrue,
            ),
          ),
          reason:
              'A refused connection must surface as a (retryable) failure, '
              'not a silent success.',
        );

        final backend = container.read(backendProvider);
        expect(
          backend,
          isA<DisconnectedBackend>(),
          reason:
              'A failed handshake must roll back to DisconnectedBackend, '
              'not leave a stale NetworkBackend that reads as connected.',
        );
        expect(
          container.read(isRemoteModeProvider),
          isFalse,
          reason:
              'isRemoteModeProvider must report false after a failed '
              'connect — otherwise file paths resolve against a server that '
              'was never reached.',
        );
      },
    );

    test('a failed connect stays retryable', () async {
      final container = ProviderContainer(
        overrides: [inMemoryDatabaseOverride()],
      );
      addTearDown(container.dispose);
      final notifier = container.read(backendProvider.notifier);

      await expectLater(
        notifier.connect('127.0.0.1', 8765, authToken: 'test-token'),
        throwsA(isA<SkotiqError>()),
      );
      expect(container.read(backendProvider), isA<DisconnectedBackend>());

      // A second attempt behaves identically — the first failure did not wedge
      // the notifier in a half-connected state, and the rolled-back backend
      // did not leak a background reconnect loop that would poison the retry.
      await expectLater(
        notifier.connect('127.0.0.1', 8765, authToken: 'test-token'),
        throwsA(isA<SkotiqError>()),
      );
      expect(container.read(backendProvider), isA<DisconnectedBackend>());
      expect(container.read(isRemoteModeProvider), isFalse);
    });
  });
}

/// Case-insensitive header lookup. `package:http` lowercases header names
/// on the wire, but the production code writes them in mixed case via
/// `_addAuthHeaders`, so tests must compare without regard to case.
String? _headerValue(Map<String, String> headers, String name) {
  final lower = name.toLowerCase();
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == lower) {
      return entry.value;
    }
  }
  return null;
}
