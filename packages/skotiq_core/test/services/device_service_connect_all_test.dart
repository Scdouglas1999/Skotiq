/// Connect-path contracts.
///
/// Connect methods run no precondition `discoverDevices` sweep. Well-formed
///   device ids are accepted directly; malformed ids throw
///   [InvalidDeviceIdException] up front; backend errors propagate.
///
/// `connectAllFromProfile` connects every configured device in
///   parallel and emits a [DeviceConnectProgress] stream so the UI can
///   render per-device chips without blocking on the slowest device.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart' hide CameraState;
import 'package:skotiq_core/src/models/backend/device_types.dart'
    as device_types;
import 'package:skotiq_core/src/models/equipment/equipment_models.dart'
    show DeviceConnectionState;
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/providers/profiles_provider.dart';
import 'package:skotiq_core/src/services/device_exceptions.dart';
import 'package:skotiq_core/src/services/device_service.dart';
import 'package:skotiq_core/src/utils/device_id.dart';

import '../harness/in_memory_database.dart';
import '../mocks/mock_backend.dart';

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

void main() {
  late ProviderContainer container;
  late MockBackend mockBackend;
  late StreamController<SkotiqEvent> eventStreamController;

  setUpAll(() {
    registerMocktailFallbackValues();
  });

  setUp(() {
    mockBackend = MockBackend();
    eventStreamController = StreamController<SkotiqEvent>.broadcast();

    when(
      () => mockBackend.eventStream,
    ).thenAnswer((_) => eventStreamController.stream);
    when(
      () => mockBackend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    // Default: no recommended settings on connect so tests that don't care
    // about the auto-detect path don't blow up on unstubbed calls.
    when(
      () => mockBackend.cameraGetRecommendedSettings(any()),
    ).thenAnswer((_) async => const CameraRecommendedSettings(notes: ''));

    container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, mockBackend),
        ),
        // The camera connect path reads `activeEquipmentProfileProvider` to
        // apply the profile's gain, which pulls in the real `databaseProvider`
        // and opens the on-disk SQLite file. Under a loaded machine two
        // containers' opens overlap and one loses with
        // `SqliteException(14): unable to open database file` — reported
        // against whichever connect test was running. See
        // `test/harness/in_memory_database.dart`.
        inMemoryDatabaseOverride(),
      ],
    );
    // Initialize DeviceService so event listeners are active.
    container.read(deviceServiceProvider);
  });

  tearDown(() {
    eventStreamController.close();
    container.dispose();
  });

  // Pure helper: format validator
  group('isValidDeviceIdFormat', () {
    test('accepts every known driver prefix', () {
      expect(isValidDeviceIdFormat('ascom:ASCOM.ZWO.Camera'), isTrue);
      expect(isValidDeviceIdFormat('alpaca:192.168.1.10:11111:0'), isTrue);
      expect(isValidDeviceIdFormat('indi:localhost:7624:CCD1'), isTrue);
      expect(isValidDeviceIdFormat('native:zwo:0'), isTrue);
      expect(isValidDeviceIdFormat('native:builtin_guider:multi_star'), isTrue);
      expect(isValidDeviceIdFormat('native:touptek:zwo:0'), isTrue);
      expect(isValidDeviceIdFormat('simulator:fake-mount-1'), isTrue);
      expect(isValidDeviceIdFormat('phd2:localhost:4400'), isTrue);
      expect(isValidDeviceIdFormat('phd2://localhost:4400'), isTrue);
    });

    test('accepts known single-token ids', () {
      expect(isValidDeviceIdFormat('phd2'), isTrue);
      expect(isValidDeviceIdFormat('phd2_guider'), isTrue);
      expect(isValidDeviceIdFormat('builtin_guider'), isTrue);
    });

    test('rejects malformed ids', () {
      expect(isValidDeviceIdFormat(''), isFalse);
      expect(isValidDeviceIdFormat('nonexistent-mount'), isFalse);
      expect(isValidDeviceIdFormat('camera-1'), isFalse);
      expect(isValidDeviceIdFormat('unknown:foo'), isFalse);
      // Bare prefix with no payload after the colon is malformed.
      expect(isValidDeviceIdFormat('ascom:'), isFalse);
      expect(isValidDeviceIdFormat('native:'), isFalse);
    });
  });

  // Connect methods reject malformed ids without doing discovery.
  group('connect format check', () {
    test('connectCamera with malformed id throws InvalidDeviceIdException '
        'and never calls discoverDevices/connectDevice', () async {
      final service = container.read(deviceServiceProvider);

      await expectLater(
        service.connectCamera('camera-1'),
        throwsA(
          isA<InvalidDeviceIdException>()
              .having((e) => e.deviceType, 'deviceType', 'camera')
              .having((e) => e.deviceId, 'deviceId', 'camera-1'),
        ),
      );

      verifyNever(() => mockBackend.discoverDevices(any()));
      verifyNever(() => mockBackend.connectDevice(DeviceType.camera, any()));
    });

    test('connectCamera with well-formed id reaches backend without prior '
        'discoverDevices call', () async {
      const deviceId = 'native:zwo:0';

      // discoverDevices is deliberately NOT stubbed: connect goes straight to
      // connectDevice, so a discovery precondition would fail this test.
      when(
        () => mockBackend.connectDevice(DeviceType.camera, deviceId),
      ).thenAnswer((_) async {});
      when(() => mockBackend.getCameraStatus(deviceId)).thenAnswer(
        (_) async => const CameraStatus(
          connected: true,
          state: device_types.CameraState.idle,
          sensorTemp: -10.0,
          coolerPower: 80.0,
          targetTemp: -10.0,
          coolerOn: true,
          gain: 100,
          offset: 50,
          binX: 1,
          binY: 1,
          sensorWidth: 4656,
          sensorHeight: 3520,
          pixelSizeX: 3.76,
          pixelSizeY: 3.76,
          maxAdu: 65535,
          canCool: true,
          canSetGain: true,
          canSetOffset: true,
        ),
      );
      when(
        () => mockBackend.startDeviceHeartbeat(
          deviceType: any(named: 'deviceType'),
          deviceId: any(named: 'deviceId'),
          intervalMs: any(named: 'intervalMs'),
        ),
      ).thenAnswer((_) async {});

      final service = container.read(deviceServiceProvider);
      await service.connectCamera(deviceId);

      // Discovery was NOT a precondition.
      verifyNever(() => mockBackend.discoverDevices(any()));
      // Backend connect call DID happen with the id verbatim.
      verify(
        () => mockBackend.connectDevice(DeviceType.camera, deviceId),
      ).called(1);
      // State reflects the success.
      expect(
        container.read(cameraStateProvider).connectionState,
        DeviceConnectionState.connected,
      );
    });

    test('connectMount preserves backend error when id is well-formed but '
        'device is not reachable', () async {
      const deviceId = 'ascom:ASCOM.ZWO.Mount';
      when(
        () => mockBackend.connectDevice(DeviceType.mount, deviceId),
      ).thenThrow(Exception('Driver refused: COM port busy'));

      final service = container.read(deviceServiceProvider);
      await expectLater(
        service.connectMount(deviceId),
        throwsA(
          predicate<Object>((e) => e.toString().contains('COM port busy')),
        ),
      );

      // Critically: the error came from the backend, not from a "device
      // not found" pre-check. Discovery was never invoked.
      verifyNever(() => mockBackend.discoverDevices(any()));
      // State is rolled back to disconnected.
      expect(
        container.read(mountStateProvider).connectionState,
        DeviceConnectionState.disconnected,
      );
    });

    test('every device-type connect rejects malformed ids', () async {
      final service = container.read(deviceServiceProvider);

      Future<void> expectInvalid(
        Future<void> Function() call,
        String expectedDeviceType,
      ) async {
        await expectLater(
          call(),
          throwsA(
            isA<InvalidDeviceIdException>().having(
              (e) => e.deviceType,
              'deviceType',
              expectedDeviceType,
            ),
          ),
        );
      }

      await expectInvalid(() => service.connectCamera('bad'), 'camera');
      await expectInvalid(() => service.connectMount('bad'), 'mount');
      await expectInvalid(() => service.connectFocuser('bad'), 'focuser');
      await expectInvalid(
        () => service.connectFilterWheel('bad'),
        'filter wheel',
      );
      // Guider has a PHD2 short-circuit; a non-PHD2 unknown id still hits
      // the standard format check.
      await expectInvalid(() => service.connectGuider('bad'), 'guider');
      await expectInvalid(() => service.connectRotator('bad'), 'rotator');
      await expectInvalid(() => service.connectDome('bad'), 'dome');
      await expectInvalid(
        () => service.connectWeather('bad'),
        'weather station',
      );
      await expectInvalid(
        () => service.connectSafetyMonitor('bad'),
        'safety monitor',
      );
      await expectInvalid(
        () => service.connectCoverCalibrator('bad'),
        'cover calibrator',
      );

      // None of these attempts should have reached the backend.
      verifyNever(() => mockBackend.connectDevice(any(), any()));
    });
  });

  // ConnectAllFromProfile streams per-device progress events.
  group('connectAllFromProfile', () {
    EquipmentProfileModel buildProfile({
      String? cameraId,
      String? mountId,
      String? focuserId,
    }) {
      return EquipmentProfileModel(
        id: 1,
        name: 'Test',
        cameraId: cameraId,
        mountId: mountId,
        focuserId: focuserId,
      );
    }

    test('emits connecting+connected for every configured device', () async {
      const cameraId = 'simulator:cam-1';
      const mountId = 'simulator:mount-1';
      const focuserId = 'simulator:foc-1';

      when(
        () => mockBackend.connectDevice(DeviceType.camera, cameraId),
      ).thenAnswer((_) async {});
      when(
        () => mockBackend.connectDevice(DeviceType.mount, mountId),
      ).thenAnswer((_) async {});
      when(
        () => mockBackend.connectDevice(DeviceType.focuser, focuserId),
      ).thenAnswer((_) async {});
      when(() => mockBackend.getCameraStatus(any())).thenAnswer(
        (_) async => const CameraStatus(
          connected: true,
          state: device_types.CameraState.idle,
          sensorTemp: 0,
          coolerPower: 0,
          targetTemp: 0,
          coolerOn: false,
          gain: 0,
          offset: 0,
          binX: 1,
          binY: 1,
          sensorWidth: 100,
          sensorHeight: 100,
          pixelSizeX: 1,
          pixelSizeY: 1,
          maxAdu: 65535,
          canCool: false,
          canSetGain: false,
          canSetOffset: false,
        ),
      );
      when(() => mockBackend.getMountStatus(any())).thenAnswer(
        (_) async => const MountStatus(
          connected: true,
          tracking: false,
          slewing: false,
          parked: false,
          atHome: false,
          sideOfPier: PierSide.east,
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
        ),
      );
      when(() => mockBackend.getFocuserStatus(any())).thenAnswer(
        (_) async => const FocuserStatus(
          connected: true,
          position: 0,
          moving: false,
          maxPosition: 1000,
          stepSize: 1,
          isAbsolute: true,
          hasTemperature: false,
        ),
      );
      when(
        () => mockBackend.startDeviceHeartbeat(
          deviceType: any(named: 'deviceType'),
          deviceId: any(named: 'deviceId'),
          intervalMs: any(named: 'intervalMs'),
        ),
      ).thenAnswer((_) async {});

      final service = container.read(deviceServiceProvider);
      final profile = buildProfile(
        cameraId: cameraId,
        mountId: mountId,
        focuserId: focuserId,
      );

      final events = <DeviceConnectProgress>[];
      await for (final e in service.connectAllFromProfile(profile)) {
        events.add(e);
      }

      // We should have exactly two events per device: connecting then
      // connected. Order across devices is not deterministic (they all
      // dispatch in parallel) so we group by deviceType.
      final byType = <String, List<DeviceConnectProgress>>{};
      for (final e in events) {
        byType.putIfAbsent(e.deviceType, () => []).add(e);
      }

      expect(byType.keys, containsAll(['camera', 'mount', 'focuser']));
      for (final type in ['camera', 'mount', 'focuser']) {
        final list = byType[type]!;
        expect(
          list,
          hasLength(2),
          reason: 'Expected connecting+connected for $type',
        );
        expect(list[0].status, DeviceConnectProgressStatus.connecting);
        expect(list[1].status, DeviceConnectProgressStatus.connected);
      }
    });

    test('one device failing does not block other devices', () async {
      const cameraId = 'simulator:cam-1';
      const mountId = 'simulator:mount-1';

      // Camera succeeds; mount fails. We must still see the camera's
      // connected event AND the mount's failed event with the original
      // error preserved.
      when(
        () => mockBackend.connectDevice(DeviceType.camera, cameraId),
      ).thenAnswer((_) async {});
      when(
        () => mockBackend.connectDevice(DeviceType.mount, mountId),
      ).thenThrow(Exception('Mount driver refused'));
      when(() => mockBackend.getCameraStatus(any())).thenAnswer(
        (_) async => const CameraStatus(
          connected: true,
          state: device_types.CameraState.idle,
          sensorTemp: 0,
          coolerPower: 0,
          targetTemp: 0,
          coolerOn: false,
          gain: 0,
          offset: 0,
          binX: 1,
          binY: 1,
          sensorWidth: 100,
          sensorHeight: 100,
          pixelSizeX: 1,
          pixelSizeY: 1,
          maxAdu: 65535,
          canCool: false,
          canSetGain: false,
          canSetOffset: false,
        ),
      );
      when(
        () => mockBackend.startDeviceHeartbeat(
          deviceType: any(named: 'deviceType'),
          deviceId: any(named: 'deviceId'),
          intervalMs: any(named: 'intervalMs'),
        ),
      ).thenAnswer((_) async {});

      final service = container.read(deviceServiceProvider);
      final profile = buildProfile(cameraId: cameraId, mountId: mountId);

      final events = <DeviceConnectProgress>[];
      await for (final e in service.connectAllFromProfile(profile)) {
        events.add(e);
      }

      // Final state per device-type.
      final cameraEvents = events
          .where((e) => e.deviceType == 'camera')
          .toList();
      final mountEvents = events.where((e) => e.deviceType == 'mount').toList();

      expect(
        cameraEvents.last.status,
        DeviceConnectProgressStatus.connected,
        reason: 'Camera should have succeeded despite mount failure.',
      );
      expect(mountEvents.last.status, DeviceConnectProgressStatus.failed);
      expect(
        mountEvents.last.errorMessage,
        contains('Mount driver refused'),
        reason: 'Backend error must be preserved verbatim on the event.',
      );
      expect(mountEvents.last.error, isA<Exception>());

      // State reflects the per-device outcome.
      expect(
        container.read(cameraStateProvider).connectionState,
        DeviceConnectionState.connected,
      );
      expect(
        container.read(mountStateProvider).connectionState,
        DeviceConnectionState.disconnected,
      );
    });

    test(
      'emits nothing and closes immediately when profile has no devices',
      () async {
        final service = container.read(deviceServiceProvider);
        final profile = buildProfile();

        final events = <DeviceConnectProgress>[];
        await for (final e in service.connectAllFromProfile(profile)) {
          events.add(e);
        }

        expect(events, isEmpty);
        verifyNever(() => mockBackend.connectDevice(any(), any()));
      },
    );

    test('malformed device id surfaces as a per-device failed event, not a '
        'stream error', () async {
      // +  interplay: a bad id in the profile must not
      // poison the entire sweep. The connect call throws
      // InvalidDeviceIdException, which the parallel dispatcher routes
      // onto the stream as a `failed` event so the sibling device can
      // still complete.
      const goodCamera = 'simulator:cam-good';
      const badMountId = 'totally-malformed';

      when(
        () => mockBackend.connectDevice(DeviceType.camera, goodCamera),
      ).thenAnswer((_) async {});
      when(() => mockBackend.getCameraStatus(any())).thenAnswer(
        (_) async => const CameraStatus(
          connected: true,
          state: device_types.CameraState.idle,
          sensorTemp: 0,
          coolerPower: 0,
          targetTemp: 0,
          coolerOn: false,
          gain: 0,
          offset: 0,
          binX: 1,
          binY: 1,
          sensorWidth: 100,
          sensorHeight: 100,
          pixelSizeX: 1,
          pixelSizeY: 1,
          maxAdu: 65535,
          canCool: false,
          canSetGain: false,
          canSetOffset: false,
        ),
      );
      when(
        () => mockBackend.startDeviceHeartbeat(
          deviceType: any(named: 'deviceType'),
          deviceId: any(named: 'deviceId'),
          intervalMs: any(named: 'intervalMs'),
        ),
      ).thenAnswer((_) async {});

      final service = container.read(deviceServiceProvider);
      final profile = buildProfile(cameraId: goodCamera, mountId: badMountId);

      final events = <DeviceConnectProgress>[];
      // The stream itself must close cleanly without errors.
      await expectLater(
        service.connectAllFromProfile(profile).forEach(events.add),
        completes,
      );

      final mountEvents = events.where((e) => e.deviceType == 'mount').toList();
      expect(mountEvents.last.status, DeviceConnectProgressStatus.failed);
      expect(mountEvents.last.error, isA<InvalidDeviceIdException>());

      // Camera connected normally despite the mount being malformed.
      expect(
        container.read(cameraStateProvider).connectionState,
        DeviceConnectionState.connected,
      );
    });
  });
}
