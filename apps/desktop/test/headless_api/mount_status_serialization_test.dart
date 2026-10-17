import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/device_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

/// Regression guard for `GET /api/mount/status`.
///
/// The endpoint must answer through `getMountStatus()` — the domain type with
/// a real `toJson()`, matching `/api/equipment/mount/status`. The raw
/// flutter_rust_bridge `MountStatus` from `backend.mountGetStatus()` has no
/// `toJson()`, so `jsonEncode` throws and every remote client receives
/// `{"error":"internal_error"}` instead of mount telemetry.
///
/// Only [getMountStatus] is modeled; any other call loud-fails through
/// [noSuchMethod] so an accidental dependency surfaces immediately.
class _FakeDeviceBackend implements DeviceBackend {
  final MountStatus status;
  final List<DeviceInfo> connected;
  String? lastQueriedDeviceId;
  _FakeDeviceBackend(this.status, {this.connected = const []});

  @override
  Future<MountStatus> getMountStatus(String deviceId) async {
    lastQueriedDeviceId = deviceId;
    return status;
  }

  @override
  Future<List<DeviceInfo>> getConnectedDevices() async => connected;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DeviceInfo _mountInfo(String id) => DeviceInfo(
  id: id,
  name: 'Mount $id',
  deviceType: DeviceType.mount,
  driverType: DriverType.simulator,
  description: '',
  driverVersion: '',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DeviceHandlers.handleMountGetStatus', () {
    late Directory loggerTempDir;
    late LoggingService logger;

    setUp(() async {
      loggerTempDir = await Directory.systemTemp.createTemp('ns_mount_status_');
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

    test('serializes mount status as JSON (no internal_error)', () async {
      final backend = _FakeDeviceBackend(
        const MountStatus(
          connected: true,
          tracking: true,
          slewing: false,
          parked: false,
          atHome: false,
          sideOfPier: PierSide.east,
          rightAscension: 5.5,
          declination: -5.4,
          altitude: 30,
          azimuth: 120,
          siderealTime: 12.3,
          trackingRate: TrackingRate.sidereal,
          canPark: true,
          canSlew: true,
          canSync: true,
          canPulseGuide: true,
          canSetTrackingRate: true,
          availability: {'altitude': 'available', 'azimuth': 'unsupported'},
        ),
      );
      final container = ProviderContainer(
        overrides: [
          loggingServiceProvider.overrideWithValue(logger),
          deviceBackendProvider.overrideWithValue(backend),
        ],
      );
      addTearDown(container.dispose);
      final handlers = DeviceHandlers(container);

      final response = await translateHandlerErrors(
        handlers.handleMountGetStatus(
          Request(
            'GET',
            Uri.parse('http://localhost/api/mount/status?deviceId=mount-1'),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['rightAscension'], 5.5);
      expect(body['declination'], -5.4);
      expect(body['sideOfPier'], 'east');
      expect(body['trackingRate'], 'sidereal');
      // availability must be plain wire strings, not 'FieldAvailability.*'.
      final availability = body['availability'] as Map;
      expect(availability['altitude'], 'available');
      expect(availability['azimuth'], 'unsupported');
    });

    // A tablet that just wants "the" mount gets it: an omitted `deviceId`
    // falls back to the single connected mount rather than passing an empty
    // string to the backend, which answers an opaque 500 ("Device not found:").
    test('no deviceId falls back to the connected mount', () async {
      final backend = _FakeDeviceBackend(
        const MountStatus(
          connected: true,
          tracking: false,
          slewing: false,
          parked: true,
          atHome: false,
          sideOfPier: PierSide.west,
          rightAscension: 1.0,
          declination: 2.0,
          altitude: 0,
          azimuth: 0,
          siderealTime: 0,
          trackingRate: TrackingRate.sidereal,
          canPark: true,
          canSlew: true,
          canSync: true,
          canPulseGuide: true,
          canSetTrackingRate: true,
          availability: {},
        ),
        connected: [_mountInfo('mount-xyz')],
      );
      final container = ProviderContainer(
        overrides: [
          loggingServiceProvider.overrideWithValue(logger),
          deviceBackendProvider.overrideWithValue(backend),
        ],
      );
      addTearDown(container.dispose);
      final handlers = DeviceHandlers(container);

      final response = await translateHandlerErrors(
        handlers.handleMountGetStatus(
          Request('GET', Uri.parse('http://localhost/api/mount/status')),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      // The connected mount's id was used, not the empty string.
      expect(backend.lastQueriedDeviceId, 'mount-xyz');
    });

    // With no mount connected and no deviceId, surface a clean 400 rather than
    // an opaque 500.
    test('no deviceId and no mount connected returns 400, not 500', () async {
      final backend = _FakeDeviceBackend(
        const MountStatus(
          connected: false,
          tracking: false,
          slewing: false,
          parked: false,
          atHome: false,
          sideOfPier: PierSide.west,
          rightAscension: 0,
          declination: 0,
          altitude: 0,
          azimuth: 0,
          siderealTime: 0,
          trackingRate: TrackingRate.sidereal,
          canPark: false,
          canSlew: false,
          canSync: false,
          canPulseGuide: false,
          canSetTrackingRate: false,
          availability: {},
        ),
      );
      final container = ProviderContainer(
        overrides: [
          loggingServiceProvider.overrideWithValue(logger),
          deviceBackendProvider.overrideWithValue(backend),
        ],
      );
      addTearDown(container.dispose);
      final handlers = DeviceHandlers(container);

      final response = await translateHandlerErrors(
        handlers.handleMountGetStatus(
          Request('GET', Uri.parse('http://localhost/api/mount/status')),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(backend.lastQueriedDeviceId, isNull);
    });
  });
}
