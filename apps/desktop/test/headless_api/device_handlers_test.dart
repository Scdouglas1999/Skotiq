import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/device_handlers.dart';
import 'package:skotiq_desktop/headless_api/validation.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

class _CancelledExposureBackend implements DeviceBackend {
  @override
  Future<void> cameraStartExposure({
    required String deviceId,
    required double exposureTime,
    required FrameType frameType,
    int? gain,
    int? offset,
    int binX = 1,
    int binY = 1,
    int? x,
    int? y,
    int? width,
    int? height,
  }) async {
    // This is the exact wrapper emitted by the live NetworkBackend after the
    // native camera reports an operator abort.
    throw const bridge.SkotiqError.operationFailed('Exposure cancelled');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A driver with nothing in its live-preview buffer.
///
/// Both shapes a real one produces are here: the null answer, and the zero-arg
/// `noImageAvailable` the FFI backend raises. [raise] also lets a test send an
/// unrelated failure through the same call, to prove only the empty-buffer case
/// is repainted as an empty preview.
class _EmptyPreviewBackend implements DeviceBackend {
  _EmptyPreviewBackend({this.raise});

  final Object? raise;

  @override
  Future<CapturedImageResult?> cameraGetLastImage(String deviceId) async {
    final error = raise;
    if (error != null) throw error;
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Reports [connected] from the driver registry and records every
/// `disconnectDevice` call, so a test can prove the disconnect endpoint really
/// released the driver rather than just returning 200.
class _RegistryBackend implements DeviceBackend {
  _RegistryBackend(this.connected);

  final List<DeviceInfo> connected;
  final List<(DeviceType, String)> disconnected = [];

  @override
  Future<List<DeviceInfo>> getConnectedDevices() async => connected;

  @override
  Future<void> disconnectDevice(DeviceType deviceType, String deviceId) async {
    disconnected.add((deviceType, deviceId));
    connected.removeWhere(
      (d) => d.id == deviceId && d.deviceType == deviceType,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DeviceInfo _registryFocuser(String id) => DeviceInfo(
  id: id,
  name: 'Simulator Focuser',
  deviceType: DeviceType.focuser,
  driverType: DriverType.ascom,
  description: 'ASCOM driver: $id',
  driverVersion: '1.0',
);

class _BusyFocuserBackend implements DeviceBackend {
  @override
  Future<void> focuserMoveTo(String deviceId, int position) async {
    throw const bridge.SkotiqError.operationFailed(
      'Failed to call method Move: Move Failure',
    );
  }

  @override
  Future<void> focuserMoveRelative(String deviceId, int delta) async {
    throw const bridge.SkotiqError.operationFailed(
      'Failed to call method Move: Move Failure',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  // Why these overrides:
  //   1. Every handler calls `_logInfo()`, which reads
  //      `loggingServiceProvider`. The production provider kicks off
  //      `unawaited(LoggingService.ensureInitialized())`, which invokes
  //      `getApplicationSupportDirectory()` (platform channel) and
  //      `bridge_api.apiInitWithLogging` (FFI cdylib). Both fail in a unit
  //      test. The async failure surfaces as an unhandled-error and the
  //      test runner attributes it to whichever test happens to still be
  //      in scope, producing a flaky `+N -1`.
  //   2. `handleFilterWheelGetPosition` reads `filterWheelStateProvider`,
  //      whose `FilterWheelStateNotifier` constructor calls
  //      `_ref.listen(activeEquipmentProfileProvider, ...)`. That chain
  //      mounts `equipmentProfilesNotifier` -> `databaseProvider`, and
  //      the default Drift `LazyDatabase` opens via
  //      `getApplicationDocumentsDirectory()` — another path_provider
  //      channel call that throws MissingPluginException in unit tests.
  //
  // Fix: install a TestWidgetsFlutterBinding (so plumbing exists), then
  // wire hermetic substitutes for both providers (in-memory DB +
  // no-FFI LoggingService). Together these eliminate every cross-test
  // microtask source identified above.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DeviceHandlers', () {
    late Directory loggerTempDir;
    late LoggingService logger;
    late SkotiqDatabase db;
    late ProviderContainer container;
    late DeviceHandlers handlers;

    setUp(() async {
      loggerTempDir = await Directory.systemTemp.createTemp(
        'ns_device_handlers_test_',
      );
      logger = LoggingService(
        applicationSupportDirectoryProvider: () async => loggerTempDir,
        nativeInitWithLogging: ({logDirectory}) {},
        nativeInit: () {},
        currentLogFileProvider: () => null,
      );
      await logger.ensureInitialized();
      db = SkotiqDatabase.forTesting(NativeDatabase.memory());

      container = ProviderContainer(
        overrides: [
          loggingServiceProvider.overrideWithValue(logger),
          databaseProvider.overrideWithValue(db),
        ],
      );
      handlers = DeviceHandlers(container);
    });

    tearDown(() async {
      container.dispose();
      await logger.dispose();
      await db.close();
      if (await loggerTempDir.exists()) {
        await loggerTempDir.delete(recursive: true);
      }
    });

    for (final endpoint in ['filter-wheel/names', 'rotator/status']) {
      test('$endpoint requires a non-empty deviceId query', () async {
        final invoke = endpoint == 'filter-wheel/names'
            ? handlers.handleFilterWheelGetNames
            : handlers.handleRotatorGetStatus;
        final response = await translateHandlerErrors(
          invoke(Request('GET', Uri.parse('http://localhost/api/$endpoint'))),
        );

        expect(response.statusCode, HttpStatus.badRequest);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['code'], 'invalid_request');
        expect(body['field'], 'deviceId');
      });
    }

    test(
      'camera expose malformed payload returns JSON internal error',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleCameraExpose(
            Request(
              'POST',
              Uri.parse('http://localhost/api/camera/expose'),
              body: jsonEncode({}),
            ),
          ),
        );

        expect(
          response.statusCode,
          anyOf(HttpStatus.badRequest, HttpStatus.internalServerError),
        );
        expect(response.headers['content-type'], 'application/json');
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['error'], isA<String>());
      },
    );

    test('camera expose rejects unsafe and partial capture settings', () async {
      final cases = <Map<String, Object?>>[
        {'deviceId': 'camera-1', 'exposureTime': 0},
        {'deviceId': 'camera-1', 'exposureTime': 86401},
        {'deviceId': 'camera-1', 'exposureTime': 1, 'binX': 0},
        {'deviceId': 'camera-1', 'exposureTime': 1, 'binY': 17},
        {'deviceId': 'camera-1', 'exposureTime': 1, 'gain': -1},
        {'deviceId': 'camera-1', 'exposureTime': 1, 'offset': -1},
        {'deviceId': 'camera-1', 'exposureTime': 1, 'x': 10, 'y': 10},
        {
          'deviceId': 'camera-1',
          'exposureTime': 1,
          'x': -1,
          'y': 0,
          'width': 100,
          'height': 100,
        },
        {
          'deviceId': 'camera-1',
          'exposureTime': 1,
          'x': 0,
          'y': 0,
          'width': 0,
          'height': 100,
        },
      ];

      for (final body in cases) {
        final response = await translateHandlerErrors(
          handlers.handleCameraExpose(
            Request(
              'POST',
              Uri.parse('http://localhost/api/camera/expose'),
              body: jsonEncode(body),
            ),
          ),
        );
        expect(response.statusCode, HttpStatus.badRequest, reason: '$body');
      }
    });

    test('an overlapping focuser move is a structured conflict', () async {
      final busyContainer = ProviderContainer(
        overrides: [
          loggingServiceProvider.overrideWithValue(logger),
          databaseProvider.overrideWithValue(db),
          deviceBackendProvider.overrideWithValue(_BusyFocuserBackend()),
        ],
      );
      addTearDown(busyContainer.dispose);
      final busyHandlers = DeviceHandlers(busyContainer);

      for (final request in [
        Request(
          'POST',
          Uri.parse('http://localhost/api/focuser/move-to'),
          body: jsonEncode({'deviceId': 'focuser-1', 'position': 100}),
        ),
        Request(
          'POST',
          Uri.parse('http://localhost/api/focuser/move-relative'),
          body: jsonEncode({'deviceId': 'focuser-1', 'delta': 10}),
        ),
      ]) {
        final response = request.url.path.endsWith('move-to')
            ? await busyHandlers.handleFocuserMoveTo(request)
            : await busyHandlers.handleFocuserMoveRelative(request);
        expect(response.statusCode, HttpStatus.conflict);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['code'], 'device_busy');
        expect(body['deviceId'], 'focuser-1');
      }
    });

    test(
      'camera expose maps an operator abort to a structured conflict',
      () async {
        container.dispose();
        container = ProviderContainer(
          overrides: [
            loggingServiceProvider.overrideWithValue(logger),
            databaseProvider.overrideWithValue(db),
            deviceBackendProvider.overrideWithValue(
              _CancelledExposureBackend(),
            ),
          ],
        );
        handlers = DeviceHandlers(container);

        final response = await translateHandlerErrors(
          handlers.handleCameraExpose(
            Request(
              'POST',
              Uri.parse('http://localhost/api/camera/expose'),
              body: jsonEncode({'deviceId': 'camera-1', 'exposureTime': 10}),
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.conflict);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['error'], 'exposure_cancelled');
        expect(body['message'], 'Exposure cancelled');
      },
    );

    // A device the driver registry still holds must ALWAYS be releasable.
    // Gating on the equipment state notifier alone is not enough: it mirrors
    // the registry and can lose a device when a stale `Disconnected` event for
    // another device of the same type wipes the slot, which would strand an
    // open driver that `/api/devices/connected` still lists.
    group('disconnect falls back to the driver registry', () {
      Future<(Response, _RegistryBackend)> disconnect(
        String deviceId,
        List<DeviceInfo> registry,
      ) async {
        final backend = _RegistryBackend(registry);
        container.dispose();
        container = ProviderContainer(
          overrides: [
            loggingServiceProvider.overrideWithValue(logger),
            databaseProvider.overrideWithValue(db),
            deviceBackendProvider.overrideWithValue(backend),
          ],
        );
        handlers = DeviceHandlers(container);
        final response = await translateHandlerErrors(
          handlers.handleDisconnectDevice(
            Request(
              'POST',
              Uri.parse('http://localhost/api/devices/disconnect'),
              body: jsonEncode({'deviceId': deviceId, 'deviceType': 'focuser'}),
            ),
          ),
        );
        return (response, backend);
      }

      test('releases a device the equipment state has lost', () async {
        const id = 'ascom:ASCOM.Simulator.Focuser';
        // Equipment state is empty (never set), registry still holds the driver.
        final (response, backend) = await disconnect(id, [
          _registryFocuser(id),
        ]);

        expect(response.statusCode, HttpStatus.ok);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['status'], 'disconnected');
        expect(body['deviceId'], id);
        expect(
          body['releasedFromDriverRegistry'],
          isTrue,
          reason: 'the response must not pretend this was a normal teardown',
        );
        expect(
          backend.disconnected,
          [(DeviceType.focuser, id)],
          reason:
              'the driver must actually be closed, not just reported closed',
        );
      });

      test('releases an orphan while another device holds the slot', () async {
        const orphan = 'sim_focuser_1';
        const tracked = 'ascom:ASCOM.Simulator.Focuser';
        final backendRegistry = [
          _registryFocuser(orphan),
          _registryFocuser(tracked),
        ];
        final backend = _RegistryBackend(backendRegistry);
        container.dispose();
        container = ProviderContainer(
          overrides: [
            loggingServiceProvider.overrideWithValue(logger),
            databaseProvider.overrideWithValue(db),
            deviceBackendProvider.overrideWithValue(backend),
          ],
        );
        handlers = DeviceHandlers(container);
        // Equipment state tracks `tracked`, so `orphan` mismatches it.
        container.read(focuserStateProvider.notifier).setConnecting(tracked);
        container.read(focuserStateProvider.notifier).setConnected();

        final response = await translateHandlerErrors(
          handlers.handleDisconnectDevice(
            Request(
              'POST',
              Uri.parse('http://localhost/api/devices/disconnect'),
              body: jsonEncode({'deviceId': orphan, 'deviceType': 'focuser'}),
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.ok);
        expect(backend.disconnected, [(DeviceType.focuser, orphan)]);
        expect(
          container.read(focuserStateProvider).deviceId,
          tracked,
          reason: 'releasing an orphan must not disturb the tracked device',
        );
      });

      test('still 409s when nothing anywhere holds the device', () async {
        final (response, backend) = await disconnect('sim_focuser_9', []);

        expect(response.statusCode, HttpStatus.conflict);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['error'], 'device_not_connected');
        expect(backend.disconnected, isEmpty);
      });
    });

    test('mount slew malformed payload returns JSON internal error', () async {
      final response = await translateHandlerErrors(
        handlers.handleMountSlew(
          Request(
            'POST',
            Uri.parse('http://localhost/api/mount/slew'),
            body: jsonEncode({'deviceId': 'mount-1'}),
          ),
        ),
      );

      expect(
        response.statusCode,
        anyOf(HttpStatus.badRequest, HttpStatus.internalServerError),
      );
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], isA<String>());
    });

    test(
      'autofocus rejects settings the hardware service cannot run',
      () async {
        final valid = <String, Object?>{
          'deviceId': 'focuser-1',
          'cameraId': 'camera-1',
          'exposureTime': 2,
          'stepSize': 100,
          'stepsOut': 7,
        };
        final cases = <Map<String, Object?>>[
          {...valid, 'exposureTime': 0.01},
          {...valid, 'stepSize': 0},
          {...valid, 'stepsOut': 51},
          {...valid, 'binning': 5},
          {...valid, 'numberOfAttempts': 0},
          {...valid, 'exposuresPerPoint': 21},
          {...valid, 'rSquaredThreshold': 1.1},
          {...valid, 'outerCropRatio': 0},
          {...valid, 'innerCropRatio': 0.8, 'outerCropRatio': 0.5},
          {...valid, 'useBrightestNStars': 501},
          {...valid, 'focuserSettleTimeMs': -1},
          {...valid, 'backlashIn': -1},
          {...valid, 'gain': -1},
        ];

        for (final body in cases) {
          final response = await translateHandlerErrors(
            handlers.handleAutofocusStart(
              Request(
                'POST',
                Uri.parse('http://localhost/api/focuser/autofocus/start'),
                body: jsonEncode(body),
              ),
            ),
          );
          expect(response.statusCode, HttpStatus.badRequest, reason: '$body');
        }
      },
    );

    test(
      'mount motion endpoints reject unsafe values before the backend',
      () async {
        final cases = <({String path, Map<String, Object?> body})>[
          (
            path: 'move-axis',
            body: {'deviceId': 'mount-1', 'axis': 2, 'rate': 1},
          ),
          (path: 'set-tracking-rate', body: {'deviceId': 'mount-1', 'rate': 4}),
          (
            path: 'pulse-guide',
            body: {
              'deviceId': 'mount-1',
              'direction': 'diagonal',
              'durationMs': 100,
            },
          ),
          (path: 'slew', body: {'deviceId': 'mount-1', 'ra': 12, 'dec': 91}),
          (path: 'slew', body: {'deviceId': 'mount-1', 'ra': 'NaN', 'dec': 0}),
        ];

        for (final testCase in cases) {
          final request = Request(
            'POST',
            Uri.parse('http://localhost/api/mount/${testCase.path}'),
            body: jsonEncode(testCase.body),
          );
          final response = await translateHandlerErrors(switch (testCase.path) {
            'move-axis' => handlers.handleMountMoveAxis(request),
            'set-tracking-rate' => handlers.handleMountSetTrackingRate(request),
            'pulse-guide' => handlers.handleMountPulseGuide(request),
            'slew' => handlers.handleMountSlew(request),
            _ => throw StateError('Unhandled test route'),
          });
          expect(
            response.statusCode,
            HttpStatus.badRequest,
            reason: testCase.path,
          );
        }
      },
    );

    // What is empty is THIS PROCESS's preview buffer, not the night. Measured
    // on a rig relaunched against its own database: this endpoint answered
    // "No image is available yet — capture an exposure first" while
    // `/api/images` listed 14 captures from the same evening, and the web
    // dashboard printed that absolute over its own gallery of them.
    group('an empty live preview says which emptiness it is', () {
      // Through the REAL error translator, not the test helper's collapse-to-
      // 500: what is being pinned is which errors this handler answers itself
      // and which it lets the translator's status table describe.
      Future<Response> lastImageJpeg({Object? raise}) async {
        container.dispose();
        container = ProviderContainer(
          overrides: [
            loggingServiceProvider.overrideWithValue(logger),
            databaseProvider.overrideWithValue(db),
            deviceBackendProvider.overrideWithValue(
              _EmptyPreviewBackend(raise: raise),
            ),
          ],
        );
        handlers = DeviceHandlers(container);
        final translated = errorTranslationMiddleware(
          logError: (_, {fields}) {},
          requestIdFor: (_) => 'test-request-id',
        )(handlers.handleCameraGetLastImageJpeg);
        return translated(
          Request(
            'GET',
            Uri.parse(
              'http://localhost/api/camera/last-image/jpeg?deviceId=cam-1',
            ),
          ),
        );
      }

      Future<void> expectScopedRefusal(Response response) async {
        expect(response.statusCode, HttpStatus.notFound);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['error'], 'no_live_preview');
        expect(
          body['scope'],
          'process',
          reason: 'the machine-readable half of the same fact',
        );
        expect(body['library'], '/api/images');
        expect(body['message'], contains('in this server process'));
        expect(
          body['message'],
          contains('/api/images'),
          reason: 'a client that has frames to show is told where they are',
        );
        // The two absolutes this replaced, in the words they were measured in.
        expect(
          body['message'],
          isNot(contains('No image has been captured yet')),
        );
        expect(body['message'], isNot(contains('capture an exposure first')));
      }

      test('a null buffer answers a scoped 404', () async {
        await expectScopedRefusal(await lastImageJpeg());
      });

      test("the driver's own noImageAvailable answers the same", () async {
        await expectScopedRefusal(
          await lastImageJpeg(
            raise: const bridge.SkotiqError.noImageAvailable(),
          ),
        );
      });

      test(
        'any other backend failure keeps its own status and words',
        () async {
          final response = await lastImageJpeg(
            raise: const bridge.SkotiqError.notConnected('cam-1'),
          );

          expect(
            response.statusCode,
            HttpStatus.conflict,
            reason: 'a disconnected camera is not an empty preview',
          );
          final body = jsonDecode(await response.readAsString()) as Map;
          expect(body['message'], contains('not connected'));
        },
      );
    });

    test('last image jpeg missing deviceId returns bad request', () async {
      final response = await translateHandlerErrors(
        handlers.handleCameraGetLastImageJpeg(
          Request(
            'GET',
            Uri.parse('http://localhost/api/camera/last-image/jpeg'),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], isA<String>());
    });

    test(
      'last image jpeg rejects malformed image options before backend use',
      () async {
        for (final query in const [
          'maxWidth=wide',
          'maxWidth=0',
          'maxWidth=20000',
          'quality=high',
          'quality=0',
          'quality=101',
        ]) {
          final response = await translateHandlerErrors(
            handlers.handleCameraGetLastImageJpeg(
              Request(
                'GET',
                Uri.parse(
                  'http://localhost/api/camera/last-image/jpeg?deviceId=cam-1&$query',
                ),
              ),
            ),
          );
          expect(response.statusCode, HttpStatus.badRequest, reason: query);
        }
      },
    );

    test(
      'rotator halt malformed payload returns JSON internal error',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleRotatorHalt(
            Request(
              'POST',
              Uri.parse('http://localhost/api/rotator/halt'),
              body: '{',
            ),
          ),
        );

        expect(
          response.statusCode,
          anyOf(HttpStatus.badRequest, HttpStatus.internalServerError),
        );
        expect(response.headers['content-type'], 'application/json');
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['error'], isA<String>());
      },
    );

    test('filter wheel get position returns 200 with null fields when '
        'disconnected', () async {
      // Why: with no driver connected (the bare ProviderContainer state),
      // FilterWheelStateNotifier reports
      // (currentPosition=null, isMoving=false, filterNames=[]). The
      // handler should still respond 200 with `position: null,
      // name: null, isMoving: false` — disconnection is not an error,
      // it's a real state phones need to render.
      final response = await translateHandlerErrors(
        handlers.handleFilterWheelGetPosition(
          Request(
            'GET',
            Uri.parse('http://localhost/api/filter-wheel/position'),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['position'], isNull);
      expect(body['name'], isNull);
      expect(body['isMoving'], isFalse);
    });
  });
}
