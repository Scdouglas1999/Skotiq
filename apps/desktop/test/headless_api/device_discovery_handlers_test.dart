import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/device_discovery_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

/// Fake [DeviceBackend] that records every `discoverDevices` call and returns
/// scripted per-type results / failures. Only the discovery surface is modeled;
/// any other method the handler is not expected to touch routes through
/// [noSuchMethod] and throws, so an accidental extra dependency surfaces
/// immediately instead of silently returning null.
class _FakeDeviceBackend implements DeviceBackend {
  /// Devices to return per type. Types absent from the map return `[]`.
  final Map<DeviceType, List<DeviceInfo>> devicesByType;

  /// Types whose discovery should throw, mapped to the error message.
  final Map<DeviceType, String> failures;

  /// Records the order discovery completed so the test can assert that
  /// fan-out actually overlapped (slowest-first completion ordering).
  final List<DeviceType> completionOrder = [];

  /// Per-type artificial delay used to prove order-independence of the merge.
  final Map<DeviceType, Duration> delays;

  /// Count of `discoverDevices` invocations per type — asserts each type is
  /// swept exactly once (no duplicate probing).
  final Map<DeviceType, int> callCounts = {};

  /// Number of times `rescanDevices` was invoked — proves the rescan route
  /// reaches the host backend rather than no-op'ing.
  int rescanCallCount = 0;

  /// When set, `rescanDevices` throws with this message so the test can assert
  /// the handler surfaces host-side failure as a 500 instead of a fake success.
  final String? rescanFailure;

  _FakeDeviceBackend({
    this.devicesByType = const {},
    this.failures = const {},
    this.delays = const {},
    this.rescanFailure,
  });

  @override
  Future<void> rescanDevices() async {
    rescanCallCount++;
    final failure = rescanFailure;
    if (failure != null) {
      throw StateError(failure);
    }
  }

  @override
  Future<List<DeviceInfo>> discoverDevices(DeviceType deviceType) async {
    callCounts.update(deviceType, (v) => v + 1, ifAbsent: () => 1);
    final delay = delays[deviceType];
    if (delay != null) {
      await Future<void>.delayed(delay);
    }
    completionOrder.add(deviceType);
    final failure = failures[deviceType];
    if (failure != null) {
      throw StateError(failure);
    }
    return devicesByType[deviceType] ?? const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DeviceInfo _device(String id, DeviceType type) => DeviceInfo(
  id: id,
  name: 'dev-$id',
  deviceType: type,
  driverType: DriverType.native,
  description: 'desc-$id',
  driverVersion: '1.0',
);

void main() {
  // The handler's `_logInfo`/`_logWarning` read `loggingServiceProvider`. The
  // production provider spins up FFI + platform-channel initialization that is
  // unavailable in a unit test, so we install a hermetic no-FFI LoggingService
  // (matching the established pattern in device_handlers_test.dart).
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DeviceDiscoveryHandlers.handleGetDevices', () {
    late Directory loggerTempDir;
    late LoggingService logger;

    setUp(() async {
      loggerTempDir = await Directory.systemTemp.createTemp(
        'sk_device_discovery_handlers_test_',
      );
      logger = LoggingService(
        applicationSupportDirectoryProvider: () async => loggerTempDir,
        nativeInitWithLogging: ({logDirectory}) {},
        nativeInit: () {},
        currentLogFileProvider: () => null,
      );
      await logger.ensureInitialized();
    });

    tearDown(() async {
      await logger.dispose();
      if (await loggerTempDir.exists()) {
        await loggerTempDir.delete(recursive: true);
      }
    });

    ProviderContainer containerWith(DeviceBackend backend) => ProviderContainer(
      overrides: [
        loggingServiceProvider.overrideWithValue(logger),
        deviceBackendProvider.overrideWithValue(backend),
      ],
    );

    test('sweeps every device type exactly once and merges results', () async {
      final backend = _FakeDeviceBackend(
        devicesByType: {
          DeviceType.camera: [_device('cam-1', DeviceType.camera)],
          DeviceType.mount: [_device('mount-1', DeviceType.mount)],
          DeviceType.focuser: [_device('focuser-1', DeviceType.focuser)],
        },
      );
      final container = containerWith(backend);
      addTearDown(container.dispose);
      final handlers = DeviceDiscoveryHandlers(container);

      final response = await translateHandlerErrors(
        handlers.handleGetDevices(
          Request('GET', Uri.parse('http://localhost/api/devices')),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      final devices = (body['devices'] as List).cast<Map>();
      final ids = devices.map((d) => d['id']).toSet();
      expect(ids, {'cam-1', 'mount-1', 'focuser-1'});
      expect(body.containsKey('discoveryErrors'), isFalse);

      // Every supported type swept exactly once — no duplicate vendor probing.
      for (final type in DeviceType.values) {
        expect(
          backend.callCounts[type],
          1,
          reason: '${type.name} should be swept exactly once',
        );
      }
    });

    test(
      'dedupes a device reported under multiple type sweeps by id',
      () async {
        // The same physical device id surfaces under two different type sweeps.
        // The id-keyed merge must collapse it to a single entry regardless of
        // which sweep completed first.
        final shared = _device('shared-1', DeviceType.camera);
        final backend = _FakeDeviceBackend(
          devicesByType: {
            DeviceType.camera: [shared],
            DeviceType.filterWheel: [shared],
            DeviceType.mount: [_device('mount-1', DeviceType.mount)],
          },
          // Force the second sweep to finish first to prove order-independence.
          delays: {
            DeviceType.camera: const Duration(milliseconds: 30),
            DeviceType.filterWheel: const Duration(milliseconds: 5),
          },
        );
        final container = containerWith(backend);
        addTearDown(container.dispose);
        final handlers = DeviceDiscoveryHandlers(container);

        final response = await translateHandlerErrors(
          handlers.handleGetDevices(
            Request('GET', Uri.parse('http://localhost/api/devices')),
          ),
        );

        expect(response.statusCode, HttpStatus.ok);
        final body = jsonDecode(await response.readAsString()) as Map;
        final devices = (body['devices'] as List).cast<Map>();
        final ids = devices.map((d) => d['id']).toList();
        expect(
          ids.where((id) => id == 'shared-1').length,
          1,
          reason: 'shared device must appear exactly once after dedupe',
        );
        expect(ids.toSet(), {'shared-1', 'mount-1'});
      },
    );

    test('runs sweeps concurrently rather than sequentially', () async {
      // If the sweeps were sequential, the camera (slow) would always complete
      // before the mount (fast). With Future.wait fan-out the fast type
      // completes first even though it is iterated later, proving overlap.
      final backend = _FakeDeviceBackend(
        devicesByType: {
          DeviceType.camera: [_device('cam-1', DeviceType.camera)],
          DeviceType.mount: [_device('mount-1', DeviceType.mount)],
        },
        delays: {
          DeviceType.camera: const Duration(milliseconds: 40),
          DeviceType.mount: const Duration(milliseconds: 5),
        },
      );
      final container = containerWith(backend);
      addTearDown(container.dispose);
      final handlers = DeviceDiscoveryHandlers(container);

      final response = await translateHandlerErrors(
        handlers.handleGetDevices(
          Request('GET', Uri.parse('http://localhost/api/devices')),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      // Fast type finished before slow type → sweeps overlapped in time.
      expect(
        backend.completionOrder.indexOf(DeviceType.mount),
        lessThan(backend.completionOrder.indexOf(DeviceType.camera)),
        reason: 'fan-out should let the fast sweep finish before the slow one',
      );
    });

    test('per-type failure surfaces in discoveryErrors without dropping '
        'healthy types', () async {
      final backend = _FakeDeviceBackend(
        devicesByType: {
          DeviceType.camera: [_device('cam-1', DeviceType.camera)],
        },
        failures: {
          DeviceType.filterWheel: 'TouptekSdk DLL missing',
          DeviceType.dome: 'INDI server unreachable',
        },
      );
      final container = containerWith(backend);
      addTearDown(container.dispose);
      final handlers = DeviceDiscoveryHandlers(container);

      final response = await translateHandlerErrors(
        handlers.handleGetDevices(
          Request('GET', Uri.parse('http://localhost/api/devices')),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;

      // Healthy type still discovered.
      final ids = (body['devices'] as List)
          .cast<Map>()
          .map((d) => d['id'])
          .toSet();
      expect(ids, {'cam-1'});

      // Both failures surfaced, keyed by type name, with the exact message.
      final errors = (body['discoveryErrors'] as Map).cast<String, dynamic>();
      expect(
        errors[DeviceType.filterWheel.name],
        contains('TouptekSdk DLL missing'),
      );
      expect(errors[DeviceType.dome.name], contains('INDI server unreachable'));
      expect(errors.length, 2);
    });

    test(
      'honors explicit deviceType filter (single type, no fan-out)',
      () async {
        final backend = _FakeDeviceBackend(
          devicesByType: {
            DeviceType.camera: [_device('cam-1', DeviceType.camera)],
            DeviceType.mount: [_device('mount-1', DeviceType.mount)],
          },
        );
        final container = containerWith(backend);
        addTearDown(container.dispose);
        final handlers = DeviceDiscoveryHandlers(container);

        final response = await translateHandlerErrors(
          handlers.handleGetDevices(
            Request(
              'GET',
              Uri.parse('http://localhost/api/devices?deviceType=camera'),
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.ok);
        final body = jsonDecode(await response.readAsString()) as Map;
        final ids = (body['devices'] as List)
            .cast<Map>()
            .map((d) => d['id'])
            .toSet();
        expect(ids, {'cam-1'});
        // Only the requested type was swept.
        expect(backend.callCounts[DeviceType.camera], 1);
        expect(backend.callCounts[DeviceType.mount], isNull);
      },
    );

    test(
      'point-source discovery validates host and port before backend use',
      () async {
        final backend = _FakeDeviceBackend();
        final container = containerWith(backend);
        addTearDown(container.dispose);
        final handlers = DeviceDiscoveryHandlers(container);
        final methods = <Future<Response> Function(Request)>[
          handlers.handleDiscoverIndiAtAddress,
          handlers.handleDiscoverAlpacaAtAddress,
        ];

        for (final method in methods) {
          for (final query in const [
            'port=7624',
            'host=localhost&port=abc',
            'host=localhost&port=0',
            'host=localhost&port=65536',
          ]) {
            final response = await translateHandlerErrors(
              method(
                Request(
                  'GET',
                  Uri.parse('http://localhost/api/devices/discover?$query'),
                ),
              ),
            );
            expect(response.statusCode, HttpStatus.badRequest, reason: query);
          }
        }
      },
    );
  });

  group('DeviceDiscoveryHandlers.handleRescanDevices', () {
    late Directory loggerTempDir;
    late LoggingService logger;

    setUp(() async {
      loggerTempDir = await Directory.systemTemp.createTemp(
        'sk_device_rescan_handlers_test_',
      );
      logger = LoggingService(
        applicationSupportDirectoryProvider: () async => loggerTempDir,
        nativeInitWithLogging: ({logDirectory}) {},
        nativeInit: () {},
        currentLogFileProvider: () => null,
      );
      await logger.ensureInitialized();
    });

    tearDown(() async {
      await logger.dispose();
      if (await loggerTempDir.exists()) {
        await loggerTempDir.delete(recursive: true);
      }
    });

    ProviderContainer containerWith(DeviceBackend backend) => ProviderContainer(
      overrides: [
        loggingServiceProvider.overrideWithValue(logger),
        deviceBackendProvider.overrideWithValue(backend),
      ],
    );

    test('routes the rescan to the host backend and returns 200', () async {
      // Proves the remote-parity fix: POST /api/devices/rescan reaches the
      // host's DeviceBackend.rescanDevices() (on the real host this is the
      // FfiBackend driving the native hot-plug pass) rather than no-op'ing.
      final backend = _FakeDeviceBackend();
      final container = containerWith(backend);
      addTearDown(container.dispose);
      final handlers = DeviceDiscoveryHandlers(container);

      final response = await translateHandlerErrors(
        handlers.handleRescanDevices(
          Request('POST', Uri.parse('http://localhost/api/devices/rescan')),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(
        backend.rescanCallCount,
        1,
        reason: 'rescan must reach the host backend exactly once',
      );
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['status'], 'ok');
    });

    test(
      'surfaces a host-side rescan failure as 500 (no fake success)',
      () async {
        // A failing host rescan must NOT report success — the caller would
        // read an empty device list as "nothing attached".
        final backend = _FakeDeviceBackend(
          rescanFailure: 'ASI SDK init failed',
        );
        final container = containerWith(backend);
        addTearDown(container.dispose);
        final handlers = DeviceDiscoveryHandlers(container);

        final response = await translateHandlerErrors(
          handlers.handleRescanDevices(
            Request('POST', Uri.parse('http://localhost/api/devices/rescan')),
          ),
        );

        expect(response.statusCode, HttpStatus.internalServerError);
        expect(backend.rescanCallCount, 1);
      },
    );
  });
}
