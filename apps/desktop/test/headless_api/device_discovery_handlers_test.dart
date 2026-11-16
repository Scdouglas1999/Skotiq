import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/settings.dart';
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

  /// Per-type delay, to hold a scan open.
  final Map<DeviceType, Duration> delays;

  /// Count of `discoverDevices` invocations per type.
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
    final failure = failures[deviceType];
    if (failure != null) {
      throw StateError(failure);
    }
    return devicesByType[deviceType] ?? const [];
  }

  /// Devices `getConnectedDevices` reports.
  List<DeviceInfo> connected = const [];

  @override
  Future<List<DeviceInfo>> getConnectedDevices() async => connected;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockDeviceService extends Mock implements DeviceService {}

/// A host with no Alpaca or INDI server set, so a scan asks only the
/// in-process backends.
class _NoServerSettings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async =>
      const AppSettingsState(indiServerHost: '', alpacaServerHost: '');
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
  setUpAll(() => registerFallbackValue(DeviceType.camera));

  // The drawer under Equipment > Devices and GET /api/devices read the last
  // scan only, so a rig connected from its profile listed "0 found". Both now
  // read the devices the host knows about, and a scan from the API is the
  // app's one scan.
  group('DeviceDiscoveryHandlers scan and known devices', () {
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

    ProviderContainer containerWith(
      _FakeDeviceBackend backend, {
      EquipmentProfileModel? profile,
    }) {
      final service = _MockDeviceService();
      when(() => service.discoverDevices(any())).thenAnswer(
        (invocation) => backend.discoverDevices(
          invocation.positionalArguments.single as DeviceType,
        ),
      );
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      return ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          loggingServiceProvider.overrideWithValue(logger),
          deviceBackendProvider.overrideWithValue(backend),
          deviceServiceProvider.overrideWithValue(service),
          appSettingsProvider.overrideWith(_NoServerSettings.new),
          activeEquipmentProfileProvider.overrideWithValue(profile),
        ],
      );
    }

    Future<Map> post(
      DeviceDiscoveryHandlers handlers, [
      String query = '',
    ]) async {
      final response = await translateHandlerErrors(
        handlers.handleDiscoverDevices(
          Request(
            'POST',
            Uri.parse('http://localhost/api/devices/discover$query'),
          ),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      return jsonDecode(await response.readAsString()) as Map;
    }

    Future<Map> get(DeviceDiscoveryHandlers handlers) async {
      final response = await translateHandlerErrors(
        handlers.handleGetDevices(
          Request('GET', Uri.parse('http://localhost/api/devices')),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      return jsonDecode(await response.readAsString()) as Map;
    }

    test('a scan from the API is the scan the host screen shows', () async {
      final backend = _FakeDeviceBackend(
        devicesByType: {
          DeviceType.camera: [_device('cam-1', DeviceType.camera)],
          DeviceType.mount: [_device('mount-1', DeviceType.mount)],
        },
      );
      final container = containerWith(backend);
      addTearDown(container.dispose);

      final body = await post(DeviceDiscoveryHandlers(container));

      final ids = (body['devices'] as List).cast<Map>().map((d) => d['id']);
      expect(ids.toSet(), {'cam-1', 'mount-1'});
      expect(body.containsKey('discoveryErrors'), isFalse);
      expect(
        container.read(unifiedDiscoveryProvider).rawDevices.map((d) => d.id),
        unorderedEquals(['cam-1', 'mount-1']),
      );
    });

    test('scans asked for at once share one scan', () async {
      final backend = _FakeDeviceBackend(
        devicesByType: {
          DeviceType.camera: [_device('cam-1', DeviceType.camera)],
        },
        delays: {DeviceType.camera: const Duration(milliseconds: 30)},
      );
      final container = containerWith(backend);
      addTearDown(container.dispose);
      final handlers = DeviceDiscoveryHandlers(container);

      final answers = await Future.wait([post(handlers), post(handlers)]);
      final sweepsOfOneScan = backend.callCounts[DeviceType.camera];
      await post(handlers);

      for (final body in answers) {
        expect((body['devices'] as List).cast<Map>().map((d) => d['id']), [
          'cam-1',
        ]);
      }
      expect(
        backend.callCounts[DeviceType.camera],
        sweepsOfOneScan! * 2,
        reason: 'two scans at once probed twice; a later one probes again',
      );
    });

    test('a backend whose scan failed is named in discoveryErrors, the rest '
        'are listed', () async {
      final backend = _FakeDeviceBackend(
        devicesByType: {
          DeviceType.camera: [_device('cam-1', DeviceType.camera)],
        },
        failures: {DeviceType.filterWheel: 'TouptekSdk DLL missing'},
      );
      final container = containerWith(backend);
      addTearDown(container.dispose);

      final body = await post(DeviceDiscoveryHandlers(container));

      expect((body['devices'] as List).cast<Map>().map((d) => d['id']), [
        'cam-1',
      ]);
      final errors = (body['discoveryErrors'] as Map).cast<String, dynamic>();
      expect(
        errors[DriverType.native.name],
        contains('TouptekSdk DLL missing'),
      );
    });

    test('?deviceType= answers only that type', () async {
      final backend = _FakeDeviceBackend(
        devicesByType: {
          DeviceType.camera: [_device('cam-1', DeviceType.camera)],
          DeviceType.mount: [_device('mount-1', DeviceType.mount)],
        },
      );
      final container = containerWith(backend);
      addTearDown(container.dispose);

      final body = await post(
        DeviceDiscoveryHandlers(container),
        '?deviceType=camera',
      );
      expect((body['devices'] as List).cast<Map>().map((d) => d['id']), [
        'cam-1',
      ]);
    });

    test('GET /api/devices lists the connected and profile devices with '
        'their state, and never scans', () async {
      final backend = _FakeDeviceBackend();
      final container = containerWith(
        backend,
        profile: const EquipmentProfileModel(
          id: 1,
          name: 'Sim Rig',
          cameraId: 'sim_camera_1',
          mountId: 'sim_mount_1',
        ),
      );
      addTearDown(container.dispose);
      container.read(cameraStateProvider.notifier)
        ..setConnecting('sim_camera_1', 'Simulated Camera')
        ..setConnected();

      final body = await get(DeviceDiscoveryHandlers(container));

      expect(backend.callCounts, isEmpty, reason: 'a GET scanned');
      expect(body['lastScanAt'], isNull);
      final rows = (body['devices'] as List).cast<Map>();
      expect(rows.map((d) => (d['id'], d['state'], d['inProfile'])), [
        ('sim_camera_1', 'connected', true),
        ('sim_mount_1', 'disconnected', true),
      ]);
      expect(rows.first['name'], 'Simulated Camera');
      expect(rows.first['driverType'], 'simulator');
      resetAllEquipmentStateNotifiers(container);
    });

    test('GET /api/devices adds what the last scan found and when', () async {
      final backend = _FakeDeviceBackend(
        devicesByType: {
          DeviceType.focuser: [_device('focuser-1', DeviceType.focuser)],
        },
      );
      final container = containerWith(backend);
      addTearDown(container.dispose);
      final handlers = DeviceDiscoveryHandlers(container);

      await post(handlers);
      final body = await get(handlers);

      expect(body['lastScanAt'], isA<String>());
      final row = (body['devices'] as List).cast<Map>().single;
      expect(row['id'], 'focuser-1');
      expect(row['foundByScan'], isTrue);
      expect(row['state'], 'disconnected');
    });

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

  // SY-09 / QP-02: the host's cards say "EAF" and "PegasusAstro NYX101" while
  // a linked client showed the driver names "ZWO EAF 0" and
  // "PegasusAstroNYX101 Telescope" it read from this endpoint.
  group('DeviceDiscoveryHandlers.handleGetConnectedDevices', () {
    late Directory loggerTempDir;
    late LoggingService logger;

    setUp(() async {
      loggerTempDir = await Directory.systemTemp.createTemp(
        'sk_device_connected_names_test_',
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

    test('names each device as the host\'s own card does', () async {
      final backend = _FakeDeviceBackend()
        ..connected = [
          DeviceInfo(
            id: 'native:zwo_eaf:0',
            name: 'ZWO EAF 0',
            deviceType: DeviceType.focuser,
            driverType: DriverType.native,
            description: '',
            driverVersion: '1.0',
          ),
          DeviceInfo(
            id: 'native:zwo_efw:0',
            name: 'ZWO EFW 0',
            deviceType: DeviceType.filterWheel,
            driverType: DriverType.native,
            description: '',
            driverVersion: '1.0',
          ),
        ];
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          loggingServiceProvider.overrideWithValue(logger),
          deviceBackendProvider.overrideWithValue(backend),
        ],
      );
      addTearDown(container.dispose);
      container
          .read(focuserStateProvider.notifier)
          .setConnecting('native:zwo_eaf:0', 'EAF');
      container.read(focuserStateProvider.notifier).setConnected();

      final response = await translateHandlerErrors(
        DeviceDiscoveryHandlers(container).handleGetConnectedDevices(
          Request('GET', Uri.parse('http://localhost/api/devices/connected')),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      final devices = (body['devices'] as List).cast<Map>();

      final focuser = devices.singleWhere((d) => d['deviceType'] == 'focuser');
      expect(focuser['name'], 'EAF');
      expect(focuser['driverName'], 'ZWO EAF 0');
      // No card on this host for the wheel yet: the driver's name stands.
      final wheel = devices.singleWhere(
        (d) => d['deviceType'] == 'filterWheel',
      );
      expect(wheel['name'], 'ZWO EFW 0');
    });
  });
}
