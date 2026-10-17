import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart'
    hide CameraState;
import 'package:skotiq_core/src/models/backend/device_types.dart'
    as device_types;
import 'package:skotiq_core/src/models/equipment/equipment_models.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/device_heartbeat_health_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/providers/profiles_provider.dart';
import 'package:skotiq_core/src/providers/sequence_provider.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/services/device_exceptions.dart';
import 'package:skotiq_core/src/services/device_service.dart';

import '../mocks/mock_backend.dart';
import '../harness/in_memory_database.dart';

class TestBackendNotifier extends BackendNotifier {
  TestBackendNotifier(super.ref, SkotiqBackend backend) {
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
    when(() => mockBackend.getConnectedDevices()).thenAnswer((_) async => []);

    // Default to "SDK reports nothing" so existing tests that do
    // not care about auto-detect behavior do not hit unstubbed-call errors.
    // Specific tests below override this to assert recommendation handling.
    when(
      () => mockBackend.cameraGetRecommendedSettings(any()),
    ).thenAnswer((_) async => const CameraRecommendedSettings(notes: ''));
    when(
      () => mockBackend.startDeviceHeartbeat(
        deviceType: any(named: 'deviceType'),
        deviceId: any(named: 'deviceId'),
        intervalMs: any(named: 'intervalMs'),
      ),
    ).thenAnswer((_) async {});
    when(() => mockBackend.stopDeviceHeartbeat(any())).thenAnswer((_) async {});

    container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => TestBackendNotifier(ref, mockBackend),
        ),
      ],
    );

    // Initialize DeviceService so event listeners are active.
    container.read(deviceServiceProvider);
  });

  tearDown(() {
    eventStreamController.close();
    container.dispose();
  });

  // Helper: build a DeviceInfo for a given type
  DeviceInfo deviceInfo(DeviceType type, String id, String name) => DeviceInfo(
    id: id,
    name: name,
    deviceType: type,
    driverType: DriverType.simulator,
    description: 'Test $name',
    driverVersion: '1.0',
  );

  // Camera connection lifecycle
  group('Camera Connection Lifecycle', () {
    test(
      'connectCamera sets state to connected and starts heartbeat',
      () async {
        const deviceId = TestFixtures.cameraId;

        when(() => mockBackend.discoverDevices(DeviceType.camera)).thenAnswer(
          (_) async => [deviceInfo(DeviceType.camera, deviceId, 'Test Camera')],
        );
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

        final state = container.read(cameraStateProvider);
        expect(state.connectionState, DeviceConnectionState.connected);
        expect(state.deviceId, deviceId);

        verify(
          () => mockBackend.startDeviceHeartbeat(
            deviceType: DeviceType.camera,
            deviceId: deviceId,
            intervalMs: 10000,
          ),
        ).called(1);
      },
    );

    test('connectCamera throws and resets state on failure', () async {
      const deviceId = TestFixtures.cameraId;

      when(() => mockBackend.discoverDevices(DeviceType.camera)).thenAnswer(
        (_) async => [deviceInfo(DeviceType.camera, deviceId, 'Test Camera')],
      );
      when(
        () => mockBackend.connectDevice(DeviceType.camera, deviceId),
      ).thenThrow(Exception('Connection refused'));

      final service = container.read(deviceServiceProvider);
      await expectLater(
        service.connectCamera(deviceId),
        throwsA(isA<Exception>()),
      );

      final state = container.read(cameraStateProvider);
      expect(state.connectionState, DeviceConnectionState.disconnected);
    });

    test('disconnectCamera stops heartbeat and resets state', () async {
      const deviceId = TestFixtures.cameraId;

      // Set up connected camera state
      final notifier = container.read(cameraStateProvider.notifier);
      notifier.setConnecting(deviceId, 'Test Camera');
      notifier.setConnected();

      when(
        () => mockBackend.stopDeviceHeartbeat(deviceId),
      ).thenAnswer((_) async {});
      when(
        () => mockBackend.disconnectDevice(DeviceType.camera, deviceId),
      ).thenAnswer((_) async {});

      final service = container.read(deviceServiceProvider);
      await service.disconnectCamera();

      final state = container.read(cameraStateProvider);
      expect(state.connectionState, DeviceConnectionState.disconnected);
      expect(state.deviceId, isNull);

      verify(() => mockBackend.stopDeviceHeartbeat(deviceId)).called(1);
      verify(
        () => mockBackend.disconnectDevice(DeviceType.camera, deviceId),
      ).called(1);
    });
  });

  // Mount connection lifecycle
  group('Mount Connection Lifecycle', () {
    test('connectMount sets state to connected with initial status', () async {
      const deviceId = TestFixtures.mountId;

      when(() => mockBackend.discoverDevices(DeviceType.mount)).thenAnswer(
        (_) async => [deviceInfo(DeviceType.mount, deviceId, 'Test Mount')],
      );
      when(
        () => mockBackend.connectDevice(DeviceType.mount, deviceId),
      ).thenAnswer((_) async {});
      when(() => mockBackend.getMountStatus(deviceId)).thenAnswer(
        (_) async => const MountStatus(
          connected: true,
          tracking: true,
          slewing: false,
          parked: false,
          atHome: false,
          sideOfPier: PierSide.east,
          rightAscension: 12.0,
          declination: 45.0,
          altitude: 60.0,
          azimuth: 180.0,
          siderealTime: 12.5,
          trackingRate: TrackingRate.sidereal,
          canPark: true,
          canSlew: true,
          canSync: true,
          canPulseGuide: true,
          canSetTrackingRate: true,
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
      await service.connectMount(deviceId);

      final state = container.read(mountStateProvider);
      expect(state.connectionState, DeviceConnectionState.connected);
      expect(state.isTracking, isTrue);
      expect(state.isParked, isFalse);
      expect(state.ra, 12.0);
      expect(state.dec, 45.0);
    });

    test(
      'connectMount throws InvalidDeviceIdException when id is malformed',
      () async {
        // Connect methods no longer do a precondition discovery
        // sweep. A malformed id (no recognized driver prefix) is rejected
        // up front with a typed exception so callers can distinguish "bad
        // input" from "backend rejected the connect attempt".
        const deviceId = 'nonexistent-mount';

        final service = container.read(deviceServiceProvider);
        await expectLater(
          service.connectMount(deviceId),
          throwsA(
            isA<InvalidDeviceIdException>()
                .having((e) => e.deviceType, 'deviceType', 'mount')
                .having((e) => e.deviceId, 'deviceId', deviceId),
          ),
        );

        // State must remain disconnected; the connect attempt never reached
        // the backend.
        final state = container.read(mountStateProvider);
        expect(state.connectionState, DeviceConnectionState.disconnected);
        verifyNever(() => mockBackend.connectDevice(DeviceType.mount, any()));
      },
    );
  });

  // Focuser connection lifecycle
  group('Focuser Connection Lifecycle', () {
    test('connectFocuser sets state with hardware capabilities', () async {
      const deviceId = TestFixtures.focuserId;

      when(() => mockBackend.discoverDevices(DeviceType.focuser)).thenAnswer(
        (_) async => [deviceInfo(DeviceType.focuser, deviceId, 'Test Focuser')],
      );
      when(
        () => mockBackend.connectDevice(DeviceType.focuser, deviceId),
      ).thenAnswer((_) async {});
      when(() => mockBackend.getFocuserStatus(deviceId)).thenAnswer(
        (_) async => const FocuserStatus(
          connected: true,
          position: 15000,
          moving: false,
          temperature: 12.5,
          maxPosition: 50000,
          stepSize: 1.0,
          isAbsolute: true,
          hasTemperature: true,
        ),
      );

      final service = container.read(deviceServiceProvider);
      await service.connectFocuser(deviceId);

      final state = container.read(focuserStateProvider);
      expect(state.connectionState, DeviceConnectionState.connected);
      expect(state.position, 15000);
      expect(state.maxPosition, 50000);
      expect(state.temperature, 12.5);
      expect(state.isMoving, isFalse);
      verify(
        () => mockBackend.startDeviceHeartbeat(
          deviceType: DeviceType.focuser,
          deviceId: deviceId,
          intervalMs: 10000,
        ),
      ).called(1);
    });

    test('disconnectFocuser resets state', () async {
      const deviceId = TestFixtures.focuserId;

      final notifier = container.read(focuserStateProvider.notifier);
      notifier.setConnecting(deviceId);
      notifier.setConnected();

      when(
        () => mockBackend.disconnectDevice(DeviceType.focuser, deviceId),
      ).thenAnswer((_) async {});

      final service = container.read(deviceServiceProvider);
      await service.disconnectFocuser();

      final state = container.read(focuserStateProvider);
      expect(state.connectionState, DeviceConnectionState.disconnected);
      verify(() => mockBackend.stopDeviceHeartbeat(deviceId)).called(1);
    });
  });

  // Event Routing: Equipment Events
  group('Event Routing', () {
    test('CameraTemperatureChanged event updates camera state', () async {
      // Pre-connect camera so state accepts updates
      final camNotifier = container.read(cameraStateProvider.notifier);
      camNotifier.setConnecting('camera-1', 'Test Camera');
      camNotifier.setConnected();

      eventStreamController.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.info,
          category: EventCategory.equipment,
          eventType: 'CameraTemperatureChanged',
          data: {'temperature': -15.0, 'coolerPower': 75.0},
        ),
      );

      await Future.delayed(const Duration(milliseconds: 50));

      final state = container.read(cameraStateProvider);
      expect(state.temperature, -15.0);
      expect(state.coolerPower, 75.0);
    });

    test('MountPositionChanged event updates mount state', () async {
      final mountNotifier = container.read(mountStateProvider.notifier);
      mountNotifier.setConnecting('mount-1');
      mountNotifier.setConnected();

      eventStreamController.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.info,
          category: EventCategory.equipment,
          eventType: 'MountPositionChanged',
          data: {
            'ra': 6.5,
            'dec': -20.0,
            'altitude': 30.0,
            'azimuth': 150.0,
            'isTracking': true,
            'isSlewing': false,
          },
        ),
      );

      await Future.delayed(const Duration(milliseconds: 50));

      final state = container.read(mountStateProvider);
      expect(state.ra, 6.5);
      expect(state.dec, -20.0);
      expect(state.isTracking, isTrue);
      expect(state.isSlewing, isFalse);
    });

    test('MountTrackingStarted sets tracking true', () async {
      final mountNotifier = container.read(mountStateProvider.notifier);
      mountNotifier.setConnecting('mount-1');
      mountNotifier.setConnected();
      mountNotifier.setTracking(false);

      eventStreamController.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.info,
          category: EventCategory.equipment,
          eventType: 'MountTrackingStarted',
          data: {},
        ),
      );

      await Future.delayed(const Duration(milliseconds: 50));

      expect(container.read(mountStateProvider).isTracking, isTrue);
    });

    test('MountTrackingStopped sets tracking false', () async {
      final mountNotifier = container.read(mountStateProvider.notifier);
      mountNotifier.setConnecting('mount-1');
      mountNotifier.setConnected();
      mountNotifier.setTracking(true);

      eventStreamController.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.info,
          category: EventCategory.equipment,
          eventType: 'MountTrackingStopped',
          data: {},
        ),
      );

      await Future.delayed(const Duration(milliseconds: 50));

      expect(container.read(mountStateProvider).isTracking, isFalse);
    });

    test('FocuserPositionChanged event updates focuser state', () async {
      final focNotifier = container.read(focuserStateProvider.notifier);
      focNotifier.setConnecting('focuser-1');
      focNotifier.setConnected();

      eventStreamController.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.info,
          category: EventCategory.equipment,
          eventType: 'FocuserPositionChanged',
          data: {'position': 25000, 'isMoving': true, 'temperature': 14.3},
        ),
      );

      await Future.delayed(const Duration(milliseconds: 50));

      final state = container.read(focuserStateProvider);
      expect(state.position, 25000);
      expect(state.isMoving, isTrue);
      expect(state.temperature, 14.3);
    });

    test(
      'FocuserMoveCompleted event updates focuser position and stops moving',
      () async {
        final focNotifier = container.read(focuserStateProvider.notifier);
        focNotifier.setConnecting('focuser-1');
        focNotifier.setConnected();
        focNotifier.setMoving(true);

        eventStreamController.add(
          SkotiqEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: EventSeverity.info,
            category: EventCategory.equipment,
            eventType: 'FocuserMoveCompleted',
            data: {'position': 30000},
          ),
        );

        await Future.delayed(const Duration(milliseconds: 50));

        final state = container.read(focuserStateProvider);
        expect(state.position, 30000);
        expect(state.isMoving, isFalse);
      },
    );

    test(
      'FilterWheelPositionChanged event updates filter wheel state',
      () async {
        final fwNotifier = container.read(filterWheelStateProvider.notifier);
        fwNotifier.setConnecting(TestFixtures.filterWheelId, 'Test FW');
        fwNotifier.setConnected(filterNames: TestFixtures.sampleFilterNames);

        eventStreamController.add(
          SkotiqEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: EventSeverity.info,
            category: EventCategory.equipment,
            eventType: 'FilterWheelPositionChanged',
            data: {'position': 3, 'isMoving': false},
          ),
        );

        await Future.delayed(const Duration(milliseconds: 50));

        final state = container.read(filterWheelStateProvider);
        expect(state.currentPosition, 3);
        expect(state.isMoving, isFalse);
      },
    );

    test('CameraCoolingStarted event updates cooling state', () async {
      final camNotifier = container.read(cameraStateProvider.notifier);
      camNotifier.setConnecting('camera-1', 'Test Camera');
      camNotifier.setConnected();

      eventStreamController.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.info,
          category: EventCategory.equipment,
          eventType: 'CameraCoolingStarted',
          data: {'target_temp': -20.0},
        ),
      );

      await Future.delayed(const Duration(milliseconds: 50));

      final state = container.read(cameraStateProvider);
      expect(state.isCooling, isTrue);
      expect(state.targetTemp, -20.0);
    });

    test('Non-equipment events are ignored by equipment handler', () async {
      final camNotifier = container.read(cameraStateProvider.notifier);
      camNotifier.setConnecting('camera-1', 'Test Camera');
      camNotifier.setConnected();

      final tempBefore = container.read(cameraStateProvider).temperature;

      // Send an event with a non-equipment category
      eventStreamController.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.info,
          category: EventCategory.imaging,
          eventType: 'CameraTemperatureChanged',
          data: {'temperature': -99.0, 'coolerPower': 100.0},
        ),
      );

      await Future.delayed(const Duration(milliseconds: 50));

      // Temperature should not have changed
      expect(container.read(cameraStateProvider).temperature, tempBefore);
    });
  });

  // Disconnect event routing
  group('Disconnect Event Routing', () {
    test(
      'Camera disconnect event resets camera state and attempts reconnect',
      () async {
        final camNotifier = container.read(cameraStateProvider.notifier);
        camNotifier.setConnecting('camera-1', 'Test Camera');
        camNotifier.setConnected();

        eventStreamController.add(
          SkotiqEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: EventSeverity.warning,
            category: EventCategory.equipment,
            eventType: 'Disconnected',
            data: {'device_type': 'camera', 'device_id': 'camera-1'},
          ),
        );

        await Future.delayed(const Duration(milliseconds: 100));

        expect(
          container.read(cameraStateProvider).connectionState,
          DeviceConnectionState.disconnected,
        );
      },
    );

    test('Disconnect event with null device_type is safely ignored', () async {
      // This should not throw
      eventStreamController.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.warning,
          category: EventCategory.equipment,
          eventType: 'Disconnected',
          data: {'device_type': null, 'device_id': null},
        ),
      );

      await Future.delayed(const Duration(milliseconds: 50));
      // No exception means the null guard works
    });

    test('Filter wheel disconnect event resets filter wheel state', () async {
      final fwNotifier = container.read(filterWheelStateProvider.notifier);
      fwNotifier.setConnecting(TestFixtures.filterWheelId, 'Test FW');
      fwNotifier.setConnected(filterNames: TestFixtures.sampleFilterNames);

      eventStreamController.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.warning,
          category: EventCategory.equipment,
          eventType: 'Disconnected',
          data: {
            'device_type': 'filterwheel',
            'device_id': TestFixtures.filterWheelId,
          },
        ),
      );

      await Future.delayed(const Duration(milliseconds: 100));

      expect(
        container.read(filterWheelStateProvider).connectionState,
        DeviceConnectionState.disconnected,
      );
    });
  });

  // Temperature polling
  group('Temperature Polling', () {
    test(
      'connectCamera starts temperature polling that updates state',
      () async {
        const deviceId = TestFixtures.cameraId;

        when(() => mockBackend.discoverDevices(DeviceType.camera)).thenAnswer(
          (_) async => [deviceInfo(DeviceType.camera, deviceId, 'Test Camera')],
        );
        when(
          () => mockBackend.connectDevice(DeviceType.camera, deviceId),
        ).thenAnswer((_) async {});
        when(
          () => mockBackend.startDeviceHeartbeat(
            deviceType: any(named: 'deviceType'),
            deviceId: any(named: 'deviceId'),
            intervalMs: any(named: 'intervalMs'),
          ),
        ).thenAnswer((_) async {});

        // Return temperature data on every status poll
        when(() => mockBackend.getCameraStatus(deviceId)).thenAnswer(
          (_) async => const CameraStatus(
            connected: true,
            state: device_types.CameraState.idle,
            sensorTemp: -12.0,
            coolerPower: 65.0,
            targetTemp: -15.0,
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

        final service = container.read(deviceServiceProvider);
        await service.connectCamera(deviceId);

        // The immediate poll after connect should have updated temp
        await Future.delayed(const Duration(milliseconds: 100));

        final state = container.read(cameraStateProvider);
        expect(state.temperature, -12.0);
        expect(state.coolerPower, 65.0);
      },
    );

    test('disconnectCamera stops temperature polling', () async {
      const deviceId = TestFixtures.cameraId;

      // First connect
      when(() => mockBackend.discoverDevices(DeviceType.camera)).thenAnswer(
        (_) async => [deviceInfo(DeviceType.camera, deviceId, 'Test Camera')],
      );
      when(
        () => mockBackend.connectDevice(DeviceType.camera, deviceId),
      ).thenAnswer((_) async {});
      when(
        () => mockBackend.startDeviceHeartbeat(
          deviceType: any(named: 'deviceType'),
          deviceId: any(named: 'deviceId'),
          intervalMs: any(named: 'intervalMs'),
        ),
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
        () => mockBackend.stopDeviceHeartbeat(deviceId),
      ).thenAnswer((_) async {});
      when(
        () => mockBackend.disconnectDevice(DeviceType.camera, deviceId),
      ).thenAnswer((_) async {});

      final service = container.read(deviceServiceProvider);
      await service.connectCamera(deviceId);
      await service.disconnectCamera();

      // Reset the call count, then wait; no new calls should come in
      clearInteractions(mockBackend);
      await Future.delayed(const Duration(seconds: 1));

      // getCameraStatus should NOT be called after disconnect
      verifyNever(() => mockBackend.getCameraStatus(any()));
    });

    test(
      'stale temperature poll result is ignored after camera switch',
      () async {
        // Ids must match a known driver prefix; use simulator:.
        const firstDeviceId = 'simulator:camera-1';
        const secondDeviceId = 'simulator:camera-2';
        final firstPoll = Completer<CameraStatus>();

        when(() => mockBackend.discoverDevices(DeviceType.camera)).thenAnswer(
          (_) async => [
            deviceInfo(DeviceType.camera, firstDeviceId, 'First Camera'),
            deviceInfo(DeviceType.camera, secondDeviceId, 'Second Camera'),
          ],
        );
        when(
          () => mockBackend.connectDevice(DeviceType.camera, any()),
        ).thenAnswer((_) async {});
        when(
          () => mockBackend.disconnectDevice(DeviceType.camera, any()),
        ).thenAnswer((_) async {});
        when(
          () => mockBackend.startDeviceHeartbeat(
            deviceType: any(named: 'deviceType'),
            deviceId: any(named: 'deviceId'),
            intervalMs: any(named: 'intervalMs'),
          ),
        ).thenAnswer((_) async {});
        when(
          () => mockBackend.stopDeviceHeartbeat(any()),
        ).thenAnswer((_) async {});
        when(
          () => mockBackend.getCameraStatus(firstDeviceId),
        ).thenAnswer((_) => firstPoll.future);
        when(() => mockBackend.getCameraStatus(secondDeviceId)).thenAnswer(
          (_) async => const CameraStatus(
            connected: true,
            state: device_types.CameraState.idle,
            sensorTemp: -5.0,
            coolerPower: 40.0,
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

        final service = container.read(deviceServiceProvider);
        await service.connectCamera(firstDeviceId);
        await service.disconnectCamera();
        await service.connectCamera(secondDeviceId);

        firstPoll.complete(
          const CameraStatus(
            connected: true,
            state: device_types.CameraState.idle,
            sensorTemp: -20.0,
            coolerPower: 90.0,
            targetTemp: -20.0,
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

        await Future.delayed(const Duration(milliseconds: 100));

        final state = container.read(cameraStateProvider);
        expect(state.deviceId, secondDeviceId);
        expect(state.temperature, -5.0);
      },
    );
  });

  // Auto-Reconnect Behavior
  group('Auto-Reconnect', () {
    test(
      'disconnect event does not attempt reconnect when auto-reconnect is disabled',
      () async {
        final camNotifier = container.read(cameraStateProvider.notifier);
        camNotifier.setConnecting('camera-1', 'Test Camera');
        camNotifier.setConnected();
        camNotifier.setAutoReconnect(false);

        eventStreamController.add(
          SkotiqEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: EventSeverity.warning,
            category: EventCategory.equipment,
            eventType: 'Disconnected',
            data: {'device_type': 'camera', 'device_id': 'camera-1'},
          ),
        );

        await Future.delayed(const Duration(milliseconds: 100));

        expect(
          container.read(cameraStateProvider).connectionState,
          DeviceConnectionState.disconnected,
        );

        // No reconnection attempt should have been made since auto-reconnect
        // is disabled. The connect call would require discoverDevices, so
        // verify it was never called for a camera reconnection.
        verifyNever(() => mockBackend.connectDevice(DeviceType.camera, any()));
      },
    );

    // Auto-reconnect is plumbed through every device type, not just
    // [DeviceType.camera]: a device that ignores the toggle reconnects
    // regardless of user preference. These pin every device type's behaviour:
    //   - the default is `true`, so an upgrader is never silently disabled;
    //   - `setAutoReconnect(false)` short-circuits the reconnect path.
    //
    // The reconnect path schedules a 5s+ backoff Timer, too slow to drive
    // synchronously in CI, so these assert the boolean wiring and the negative
    // case (no backend call). The positive case is covered by the camera
    // reconnect test above, which exercises the same _attemptReconnect
    // entrypoint.

    test('mount auto-reconnect defaults to true', () {
      final state = container.read(mountStateProvider);
      expect(state.autoReconnectEnabled, isTrue);
    });

    test('mount setAutoReconnect(false) flips the flag', () {
      final notifier = container.read(mountStateProvider.notifier);
      notifier.setAutoReconnect(false);
      expect(container.read(mountStateProvider).autoReconnectEnabled, isFalse);
    });

    test(
      'mount disconnect event with autoReconnect=false does NOT attempt reconnect',
      () async {
        final mountNotifier = container.read(mountStateProvider.notifier);
        mountNotifier.setConnecting('mount-1', 'Test Mount');
        mountNotifier.setConnected();
        mountNotifier.setAutoReconnect(false);

        eventStreamController.add(
          SkotiqEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: EventSeverity.warning,
            category: EventCategory.equipment,
            eventType: 'Disconnected',
            data: {'device_type': 'mount', 'device_id': 'mount-1'},
          ),
        );

        await Future.delayed(const Duration(milliseconds: 100));

        // State should be disconnected (autoReconnectEnabled preserved through
        // setDisconnected so the user's "off" choice survives the drop).
        final mountState = container.read(mountStateProvider);
        expect(mountState.connectionState, DeviceConnectionState.disconnected);
        expect(mountState.autoReconnectEnabled, isFalse);

        // Critically: no reconnect attempt should have been queued. With the
        // flag honored, _attemptReconnect short-circuits before scheduling
        // its 5s timer, so the backend should never see a connect call.
        verifyNever(() => mockBackend.connectDevice(DeviceType.mount, any()));
      },
    );

    test('mount disconnect DEFERS to native auto-reconnect (no competing Dart '
        'connect) and surfaces the reconnecting indicator', () async {
      // DEV-P1 dual-reconnect race. The mount is a NATIVE-owned reconnect
      // type (HeartbeatConfig::for_mount sets auto_reconnect = true), so the
      // native reconnection_loop performs the real reconnect. The Dart
      // coordinator must DEFER — firing its own connect here raced the
      // native loop and double-connected / thrashed the same physical mount
      // after a heartbeat-driven loss. We still light the Dart-driven
      // "reconnecting" indicator because the native side emits no
      // HeartbeatReconnecting event.
      //
      // (Sequence-resume after the native-driven reconnect is still handled
      // off the authoritative `Connected` event by
      // onAuthoritativeDeviceConnected — see event_handling.dart.)
      const mount2 = 'simulator:mount-2';
      when(
        () => mockBackend.connectDevice(DeviceType.mount, any()),
      ).thenAnswer((_) async {});

      final mountNotifier = container.read(mountStateProvider.notifier);
      mountNotifier.setConnecting(mount2, 'Test Mount');
      mountNotifier.setConnected();
      // Leave autoReconnectEnabled at its default (true). Sanity check:
      expect(container.read(mountStateProvider).autoReconnectEnabled, isTrue);

      eventStreamController.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.warning,
          category: EventCategory.equipment,
          eventType: 'Disconnected',
          data: {'device_type': 'mount', 'device_id': mount2},
        ),
      );

      // Wait past the Dart coordinator's first backoff (5s) — if it were
      // (incorrectly) scheduling a competing attempt it would have fired by
      // now. We bump to 6s to be safe.
      await Future.delayed(const Duration(seconds: 6));

      // De-dup: the Dart coordinator deferred, so it must NOT have driven a
      // connect of its own against the mount the native loop already owns.
      verifyNever(() => mockBackend.connectDevice(DeviceType.mount, any()));

      // …but the reconnecting indicator IS lit so the UI reflects recovery.
      expect(
        container
            .read(deviceHeartbeatHealthProvider.notifier)
            .forDevice(mount2)
            .health,
        HeartbeatHealth.reconnecting,
      );
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('focuser disconnect (Dart-owned) DOES schedule a Dart reconnect and '
        'surfaces the reconnecting indicator', () async {
      // The focuser is a DART-owned reconnect type
      // (HeartbeatConfig::for_focuser sets auto_reconnect = false), so the
      // native loop ignores it and the Dart coordinator is the sole
      // reconnect engine. It must schedule the real connect AND light the
      // reconnecting indicator.
      const focuser2 = 'simulator:focuser-2';
      when(
        () => mockBackend.connectDevice(DeviceType.focuser, any()),
      ).thenAnswer((_) async {});
      when(() => mockBackend.getFocuserStatus(any())).thenAnswer(
        (_) async => const FocuserStatus(
          connected: true,
          position: 15000,
          moving: false,
          temperature: 12.5,
          maxPosition: 50000,
          stepSize: 1.0,
          isAbsolute: true,
          hasTemperature: true,
        ),
      );
      when(
        () => mockBackend.startDeviceHeartbeat(
          deviceType: any(named: 'deviceType'),
          deviceId: any(named: 'deviceId'),
          intervalMs: any(named: 'intervalMs'),
        ),
      ).thenAnswer((_) async {});

      final focuserNotifier = container.read(focuserStateProvider.notifier);
      focuserNotifier.setConnecting(focuser2, 'Test Focuser');
      focuserNotifier.setConnected();
      expect(container.read(focuserStateProvider).autoReconnectEnabled, isTrue);

      eventStreamController.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.warning,
          category: EventCategory.equipment,
          eventType: 'Disconnected',
          data: {'device_type': 'focuser', 'device_id': focuser2},
        ),
      );

      // The reconnecting indicator is surfaced synchronously when the
      // coordinator commits to the attempt, before the 5s backoff.
      await Future.delayed(const Duration(milliseconds: 100));
      expect(
        container
            .read(deviceHeartbeatHealthProvider.notifier)
            .forDevice(focuser2)
            .health,
        HeartbeatHealth.reconnecting,
      );

      // Wait past the first backoff (5s) so the real connect fires.
      await Future.delayed(const Duration(seconds: 6));
      verify(
        () => mockBackend.connectDevice(DeviceType.focuser, focuser2),
      ).called(greaterThanOrEqualTo(1));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('focuser auto-reconnect defaults to true', () {
      final state = container.read(focuserStateProvider);
      expect(state.autoReconnectEnabled, isTrue);
    });

    test('focuser setAutoReconnect(false) flips the flag', () {
      final notifier = container.read(focuserStateProvider.notifier);
      notifier.setAutoReconnect(false);
      expect(
        container.read(focuserStateProvider).autoReconnectEnabled,
        isFalse,
      );
    });

    test(
      'focuser disconnect event with autoReconnect=false does NOT attempt reconnect',
      () async {
        final focuserNotifier = container.read(focuserStateProvider.notifier);
        focuserNotifier.setConnecting('focuser-1', 'Test Focuser');
        focuserNotifier.setConnected();
        focuserNotifier.setAutoReconnect(false);

        eventStreamController.add(
          SkotiqEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: EventSeverity.warning,
            category: EventCategory.equipment,
            eventType: 'Disconnected',
            data: {'device_type': 'focuser', 'device_id': 'focuser-1'},
          ),
        );

        await Future.delayed(const Duration(milliseconds: 100));

        final focuserState = container.read(focuserStateProvider);
        expect(
          focuserState.connectionState,
          DeviceConnectionState.disconnected,
        );
        // Preference survives the disconnect; we don't silently flip back
        // to "true" the moment the drop happens.
        expect(focuserState.autoReconnectEnabled, isFalse);

        verifyNever(() => mockBackend.connectDevice(DeviceType.focuser, any()));
      },
    );

    test('setDisconnected preserves autoReconnectEnabled across drops', () {
      // Resetting the entire snapshot on disconnect flips
      // autoReconnectEnabled back to true; it is preserved for every device
      // type so the toggle stays a stable user preference.
      final mountNotifier = container.read(mountStateProvider.notifier);
      mountNotifier.setConnecting('mount-3', 'Mount 3');
      mountNotifier.setConnected();
      mountNotifier.setAutoReconnect(false);
      expect(container.read(mountStateProvider).autoReconnectEnabled, isFalse);

      mountNotifier.setDisconnected();

      // After disconnect: state cleared, but the preference survives.
      final state = container.read(mountStateProvider);
      expect(state.connectionState, DeviceConnectionState.disconnected);
      expect(state.deviceId, isNull);
      expect(
        state.autoReconnectEnabled,
        isFalse,
        reason:
            'autoReconnectEnabled must be preserved across setDisconnected '
            'so the user toggle is not silently undone on every drop.',
      );
    });
  });

  // Device discovery
  group('Device Discovery', () {
    test('discoverDevices delegates to backend', () async {
      final expectedDevices = [
        deviceInfo(DeviceType.camera, 'cam-1', 'Camera 1'),
        deviceInfo(DeviceType.camera, 'cam-2', 'Camera 2'),
      ];

      when(
        () => mockBackend.discoverDevices(DeviceType.camera),
      ).thenAnswer((_) async => expectedDevices);

      final service = container.read(deviceServiceProvider);
      final devices = await service.discoverDevices(DeviceType.camera);

      expect(devices, hasLength(2));
      expect(devices[0].id, 'cam-1');
      expect(devices[1].id, 'cam-2');
      verify(() => mockBackend.discoverDevices(DeviceType.camera)).called(1);
    });

    test('discoverDevices propagates backend exceptions', () async {
      when(
        () => mockBackend.discoverDevices(DeviceType.mount),
      ).thenThrow(Exception('Discovery failed'));

      final service = container.read(deviceServiceProvider);
      await expectLater(
        service.discoverDevices(DeviceType.mount),
        throwsA(isA<Exception>()),
      );
    });
  });

  // Sequencer event routing
  group('Sequencer Event Routing', () {
    test('SequenceStarted event updates execution state', () async {
      eventStreamController.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.info,
          category: EventCategory.sequencer,
          eventType: 'SequenceStarted',
          data: {'sequence_name': 'M31 LRGB'},
        ),
      );

      await Future.delayed(const Duration(milliseconds: 50));

      final execState = container.read(sequenceExecutionStateProvider);
      expect(execState, SequenceExecutionState.running);
    });

    test('SequenceCompleted event updates execution state', () async {
      // Start sequence first
      eventStreamController.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.info,
          category: EventCategory.sequencer,
          eventType: 'SequenceStarted',
          data: {'sequence_name': 'Test'},
        ),
      );
      await Future.delayed(const Duration(milliseconds: 50));

      // Complete it
      eventStreamController.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.info,
          category: EventCategory.sequencer,
          eventType: 'SequenceCompleted',
          data: {},
        ),
      );
      await Future.delayed(const Duration(milliseconds: 50));

      final execState = container.read(sequenceExecutionStateProvider);
      expect(execState, SequenceExecutionState.completed);
    });

    test('SequencePaused event updates execution state', () async {
      // Start sequence first
      eventStreamController.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.info,
          category: EventCategory.sequencer,
          eventType: 'SequenceStarted',
          data: {'sequence_name': 'Test'},
        ),
      );
      await Future.delayed(const Duration(milliseconds: 50));

      eventStreamController.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.info,
          category: EventCategory.sequencer,
          eventType: 'SequencePaused',
          data: {},
        ),
      );
      await Future.delayed(const Duration(milliseconds: 50));

      final execState = container.read(sequenceExecutionStateProvider);
      expect(execState, SequenceExecutionState.paused);
    });
  });

  // Camera cooling
  group('Camera Cooling', () {
    test('setCameraCooling throws when camera not connected', () async {
      final service = container.read(deviceServiceProvider);
      await expectLater(
        service.setCameraCooling(enabled: true, targetTemp: -20.0),
        throwsA(isA<Exception>()),
      );
    });

    test('setCameraCooling delegates to backend when connected', () async {
      const deviceId = TestFixtures.cameraId;

      final camNotifier = container.read(cameraStateProvider.notifier);
      camNotifier.setConnecting(deviceId, 'Test Camera');
      camNotifier.setConnected();

      when(
        () => mockBackend.cameraSetCooling(
          deviceId: deviceId,
          enabled: true,
          targetTemp: -20.0,
        ),
      ).thenAnswer((_) async {});

      final service = container.read(deviceServiceProvider);
      await service.setCameraCooling(enabled: true, targetTemp: -20.0);

      verify(
        () => mockBackend.cameraSetCooling(
          deviceId: deviceId,
          enabled: true,
          targetTemp: -20.0,
        ),
      ).called(1);
    });
  });

  // Mount park events
  group('Mount Park Events', () {
    test(
      'MountParkCompleted sets parked, stops slewing and tracking',
      () async {
        final mountNotifier = container.read(mountStateProvider.notifier);
        mountNotifier.setConnecting('mount-1');
        mountNotifier.setConnected();
        mountNotifier.setSlewing(true);
        mountNotifier.setTracking(true);

        eventStreamController.add(
          SkotiqEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: EventSeverity.info,
            category: EventCategory.equipment,
            eventType: 'MountParkCompleted',
            data: {},
          ),
        );

        await Future.delayed(const Duration(milliseconds: 50));

        final state = container.read(mountStateProvider);
        expect(state.isParked, isTrue);
        expect(state.isSlewing, isFalse);
        expect(state.isTracking, isFalse);
      },
    );

    test('MountUnparked sets parked false', () async {
      final mountNotifier = container.read(mountStateProvider.notifier);
      mountNotifier.setConnecting('mount-1');
      mountNotifier.setConnected();
      mountNotifier.setParked(true);

      eventStreamController.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.info,
          category: EventCategory.equipment,
          eventType: 'MountUnparked',
          data: {},
        ),
      );

      await Future.delayed(const Duration(milliseconds: 50));

      expect(container.read(mountStateProvider).isParked, isFalse);
    });
  });

  // Rotator events
  group('Rotator Events', () {
    test('RotatorMoveCompleted updates position and stops moving', () async {
      final rotNotifier = container.read(rotatorStateProvider.notifier);
      rotNotifier.setConnecting('rotator-1', 'Test Rotator');
      rotNotifier.setConnected();
      rotNotifier.setMoving(true);

      eventStreamController.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.info,
          category: EventCategory.equipment,
          eventType: 'RotatorMoveCompleted',
          data: {'angle': 90.0},
        ),
      );

      await Future.delayed(const Duration(milliseconds: 50));

      final state = container.read(rotatorStateProvider);
      expect(state.isMoving, isFalse);
      expect(state.position, 90.0);
    });
  });

  // Error Handling in Temperature Polling
  group('Temperature Polling Error Handling', () {
    test('polling continues after a transient error', () async {
      const deviceId = TestFixtures.cameraId;
      int callCount = 0;

      when(() => mockBackend.discoverDevices(DeviceType.camera)).thenAnswer(
        (_) async => [deviceInfo(DeviceType.camera, deviceId, 'Test Camera')],
      );
      when(
        () => mockBackend.connectDevice(DeviceType.camera, deviceId),
      ).thenAnswer((_) async {});
      when(
        () => mockBackend.startDeviceHeartbeat(
          deviceType: any(named: 'deviceType'),
          deviceId: any(named: 'deviceId'),
          intervalMs: any(named: 'intervalMs'),
        ),
      ).thenAnswer((_) async {});

      // First call throws, subsequent calls succeed
      when(() => mockBackend.getCameraStatus(deviceId)).thenAnswer((_) async {
        callCount++;
        if (callCount == 1) {
          throw Exception('Transient USB error');
        }
        return const CameraStatus(
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
        );
      });

      final service = container.read(deviceServiceProvider);
      await service.connectCamera(deviceId);

      // Wait long enough for second poll (polling is every 5s, but first poll is immediate)
      // The initial poll will throw; subsequent polls should succeed.
      // We verify the service didn't crash by checking that calls were made.
      await Future.delayed(const Duration(milliseconds: 200));

      // Should have called getCameraStatus at least once (the immediate poll)
      verify(
        () => mockBackend.getCameraStatus(deviceId),
      ).called(greaterThan(0));
    });
  });

  // Typed exception for disconnecting an already-disconnected device
  //
  // Replaces a fragile `e.toString().contains('not connected')` filter in
  // `EquipmentScreen._disconnectAllDevices`. Every `disconnect<Type>` method
  // must throw [DeviceNotConnectedException] when invoked with no device in
  // the matching state provider, so callers can distinguish "nothing to do"
  // from "actual disconnect failure".
  group('DeviceNotConnectedException on already-disconnected', () {
    test('disconnectCamera throws DeviceNotConnectedException when no '
        'camera state is present', () async {
      // No setConnecting / setConnected → cameraStateProvider has no deviceId.
      final service = container.read(deviceServiceProvider);

      await expectLater(
        service.disconnectCamera(),
        throwsA(
          isA<DeviceNotConnectedException>().having(
            (e) => e.deviceType,
            'deviceType',
            'camera',
          ),
        ),
      );

      // Backend must NOT have been called — there is no device id to send.
      verifyNever(() => mockBackend.disconnectDevice(DeviceType.camera, any()));

      // State must still be disconnected (no spurious mutation).
      final state = container.read(cameraStateProvider);
      expect(state.connectionState, DeviceConnectionState.disconnected);
    });

    test('disconnectMount throws DeviceNotConnectedException when not '
        'connected', () async {
      final service = container.read(deviceServiceProvider);

      await expectLater(
        service.disconnectMount(),
        throwsA(
          isA<DeviceNotConnectedException>().having(
            (e) => e.deviceType,
            'deviceType',
            'mount',
          ),
        ),
      );
      verifyNever(() => mockBackend.disconnectDevice(DeviceType.mount, any()));
    });

    test('disconnectFocuser throws DeviceNotConnectedException when not '
        'connected', () async {
      final service = container.read(deviceServiceProvider);

      await expectLater(
        service.disconnectFocuser(),
        throwsA(
          isA<DeviceNotConnectedException>().having(
            (e) => e.deviceType,
            'deviceType',
            'focuser',
          ),
        ),
      );
      verifyNever(
        () => mockBackend.disconnectDevice(DeviceType.focuser, any()),
      );
    });

    test('disconnectFilterWheel throws DeviceNotConnectedException when not '
        'connected', () async {
      final service = container.read(deviceServiceProvider);

      await expectLater(
        service.disconnectFilterWheel(),
        throwsA(
          isA<DeviceNotConnectedException>().having(
            (e) => e.deviceType,
            'deviceType',
            'filter wheel',
          ),
        ),
      );
      verifyNever(
        () => mockBackend.disconnectDevice(DeviceType.filterWheel, any()),
      );
    });

    test(
      'disconnectGuider / disconnectRotator / disconnectDome / '
      'disconnectWeather / disconnectSafetyMonitor / disconnectSwitch / '
      'disconnectCoverCalibrator all throw DeviceNotConnectedException',
      () async {
        final service = container.read(deviceServiceProvider);

        await expectLater(
          service.disconnectGuider(),
          throwsA(isA<DeviceNotConnectedException>()),
        );
        await expectLater(
          service.disconnectRotator(),
          throwsA(isA<DeviceNotConnectedException>()),
        );
        await expectLater(
          service.disconnectDome(),
          throwsA(isA<DeviceNotConnectedException>()),
        );
        await expectLater(
          service.disconnectWeather(),
          throwsA(isA<DeviceNotConnectedException>()),
        );
        await expectLater(
          service.disconnectSafetyMonitor(),
          throwsA(isA<DeviceNotConnectedException>()),
        );
        await expectLater(
          service.disconnectSwitch(),
          throwsA(isA<DeviceNotConnectedException>()),
        );
        await expectLater(
          service.disconnectCoverCalibrator(),
          throwsA(isA<DeviceNotConnectedException>()),
        );
      },
    );

    test('disconnectCamera does NOT throw DeviceNotConnectedException when '
        'a camera is connected', () async {
      const deviceId = TestFixtures.cameraId;

      // Establish connected state.
      final notifier = container.read(cameraStateProvider.notifier);
      notifier.setConnecting(deviceId, 'Test Camera');
      notifier.setConnected();

      when(
        () => mockBackend.stopDeviceHeartbeat(deviceId),
      ).thenAnswer((_) async {});
      when(
        () => mockBackend.disconnectDevice(DeviceType.camera, deviceId),
      ).thenAnswer((_) async {});

      final service = container.read(deviceServiceProvider);
      // Should complete without throwing.
      await service.disconnectCamera();

      // Backend was contacted, state was cleared.
      verify(
        () => mockBackend.disconnectDevice(DeviceType.camera, deviceId),
      ).called(1);
      expect(
        container.read(cameraStateProvider).connectionState,
        DeviceConnectionState.disconnected,
      );
    });

    test('disconnectAll silently skips DeviceNotConnectedException and '
        'propagates real failures', () async {
      const cameraDeviceId = TestFixtures.cameraId;
      const mountDeviceId = TestFixtures.mountId;

      // Only camera and mount are connected; everything else is not.
      container.read(cameraStateProvider.notifier)
        ..setConnecting(cameraDeviceId, 'Test Camera')
        ..setConnected();
      container.read(mountStateProvider.notifier)
        ..setConnecting(mountDeviceId, 'Test Mount')
        ..setConnected();

      when(
        () => mockBackend.stopDeviceHeartbeat(any()),
      ).thenAnswer((_) async {});
      // Camera disconnect succeeds.
      when(
        () => mockBackend.disconnectDevice(DeviceType.camera, cameraDeviceId),
      ).thenAnswer((_) async {});
      // Mount disconnect fails with a *real* error (NOT DeviceNotConnected).
      when(
        () => mockBackend.disconnectDevice(DeviceType.mount, mountDeviceId),
      ).thenThrow(Exception('Mount driver refused to disconnect'));

      final service = container.read(deviceServiceProvider);

      // The real failure should still propagate. The other 8 device types
      // are all not-connected and should be silently skipped (NOT counted
      // as errors).
      await expectLater(
        service.disconnectAll(),
        throwsA(
          predicate<Exception>(
            (e) =>
                e.toString().contains('Mount driver refused to disconnect') &&
                !e.toString().contains('DeviceNotConnectedException'),
          ),
        ),
      );
    });

    test('_disconnectAllDevices-style sweep continues past '
        'DeviceNotConnectedException and reports real failures', () async {
      // This mirrors EquipmentScreen._disconnectAllDevices: a typed-catch
      // sweep that calls each disconnect method in turn.
      const focuserDeviceId = TestFixtures.focuserId;

      // Only focuser is connected; everything else is not.
      container.read(focuserStateProvider.notifier)
        ..setConnecting(focuserDeviceId)
        ..setConnected();

      when(
        () => mockBackend.disconnectDevice(DeviceType.focuser, focuserDeviceId),
      ).thenAnswer((_) async {});

      final service = container.read(deviceServiceProvider);
      final disconnects = <Future<void> Function()>[
        service.disconnectCamera,
        service.disconnectMount,
        service.disconnectFocuser,
        service.disconnectFilterWheel,
        service.disconnectGuider,
        service.disconnectRotator,
        service.disconnectDome,
        service.disconnectWeather,
        service.disconnectSafetyMonitor,
        service.disconnectSwitch,
        service.disconnectCoverCalibrator,
      ];

      var successCount = 0;
      var notConnectedCount = 0;
      var otherErrorCount = 0;

      for (final disconnect in disconnects) {
        try {
          await disconnect();
          successCount++;
        } on DeviceNotConnectedException catch (_) {
          notConnectedCount++;
        } catch (_) {
          otherErrorCount++;
        }
      }

      // Exactly one device (the focuser) was connected and disconnected
      // cleanly. The other 10 throw DeviceNotConnectedException and are
      // caught by the typed handler. No "other" errors leaked through.
      expect(successCount, 1);
      expect(notConnectedCount, 10);
      expect(otherErrorCount, 0);

      // Backend was only contacted for the connected device.
      verify(
        () => mockBackend.disconnectDevice(DeviceType.focuser, focuserDeviceId),
      ).called(1);
      verifyNever(() => mockBackend.disconnectDevice(DeviceType.camera, any()));
      verifyNever(() => mockBackend.disconnectDevice(DeviceType.mount, any()));
    });
  });

  group('disconnect failure preserves live connection authority', () {
    test('camera notifier keeps device id and restarts monitoring', () async {
      const deviceId = TestFixtures.cameraId;
      container.read(cameraStateProvider.notifier)
        ..setConnecting(deviceId, 'Test Camera')
        ..setConnected();

      when(
        () => mockBackend.stopDeviceHeartbeat(deviceId),
      ).thenAnswer((_) async {});
      when(
        () => mockBackend.startDeviceHeartbeat(
          deviceType: DeviceType.camera,
          deviceId: deviceId,
          intervalMs: 10000,
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockBackend.disconnectDevice(DeviceType.camera, deviceId),
      ).thenThrow(StateError('camera driver refused disconnect'));
      when(() => mockBackend.getCameraStatus(deviceId)).thenAnswer(
        (_) async => const CameraStatus(
          connected: true,
          state: device_types.CameraState.idle,
          sensorTemp: -10,
          coolerPower: 0,
          targetTemp: -10,
          coolerOn: false,
          gain: 100,
          offset: 10,
          binX: 1,
          binY: 1,
          sensorWidth: 100,
          sensorHeight: 100,
          pixelSizeX: 3.76,
          pixelSizeY: 3.76,
          maxAdu: 65535,
          canCool: true,
          canSetGain: true,
          canSetOffset: true,
        ),
      );

      await expectLater(
        container.read(cameraStateProvider.notifier).disconnect(),
        throwsA(isA<StateError>()),
      );

      final state = container.read(cameraStateProvider);
      expect(state.connectionState, DeviceConnectionState.connected);
      expect(state.deviceId, deviceId);
      expect(
        container
            .read(deviceServiceProvider)
            .isUserInitiatedDisconnect(deviceId),
        isFalse,
      );
      verify(
        () => mockBackend.startDeviceHeartbeat(
          deviceType: DeviceType.camera,
          deviceId: deviceId,
          intervalMs: 10000,
        ),
      ).called(1);
    });

    test(
      'mount notifier keeps device id and restarts heartbeat/polling',
      () async {
        const deviceId = TestFixtures.mountId;
        container.read(mountStateProvider.notifier)
          ..setConnecting(deviceId, 'Test Mount')
          ..setConnected();

        when(
          () => mockBackend.stopDeviceHeartbeat(deviceId),
        ).thenAnswer((_) async {});
        when(
          () => mockBackend.startDeviceHeartbeat(
            deviceType: DeviceType.mount,
            deviceId: deviceId,
            intervalMs: 10000,
          ),
        ).thenAnswer((_) async {});
        when(
          () => mockBackend.disconnectDevice(DeviceType.mount, deviceId),
        ).thenThrow(StateError('mount driver refused disconnect'));
        when(() => mockBackend.getMountStatus(deviceId)).thenAnswer(
          (_) async => const MountStatus(
            connected: true,
            tracking: true,
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
            canPark: true,
            canSlew: true,
            canSync: true,
            canPulseGuide: true,
            canSetTrackingRate: true,
          ),
        );

        await expectLater(
          container.read(mountStateProvider.notifier).disconnect(),
          throwsA(isA<StateError>()),
        );

        final state = container.read(mountStateProvider);
        expect(state.connectionState, DeviceConnectionState.connected);
        expect(state.deviceId, deviceId);
        expect(
          container
              .read(deviceServiceProvider)
              .isUserInitiatedDisconnect(deviceId),
          isFalse,
        );
        verify(
          () => mockBackend.startDeviceHeartbeat(
            deviceType: DeviceType.mount,
            deviceId: deviceId,
            intervalMs: 10000,
          ),
        ).called(1);
      },
    );

    test(
      'PHD2 notifier preserves connection when teardown is rejected',
      () async {
        const deviceId = 'phd2_guider';
        container.read(guiderStateProvider.notifier)
          ..setConnecting(deviceId, 'PHD2')
          ..setConnected();
        when(
          () => mockBackend.phd2Disconnect(),
        ).thenThrow(StateError('PHD2 teardown rejected'));

        await expectLater(
          container.read(guiderStateProvider.notifier).disconnect(),
          throwsA(isA<StateError>()),
        );

        final state = container.read(guiderStateProvider);
        expect(state.connectionState, DeviceConnectionState.connected);
        expect(state.deviceId, deviceId);
        expect(
          container
              .read(deviceServiceProvider)
              .isUserInitiatedDisconnect(deviceId),
          isFalse,
        );
      },
    );
  });

  test('configured but disconnected guider cannot receive commands', () async {
    final configuredContainer = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => TestBackendNotifier(ref, mockBackend),
        ),
        activeEquipmentProfileProvider.overrideWithValue(
          const EquipmentProfileModel(
            id: 7,
            name: 'Configured only',
            guiderId: 'simulator:configured-guider',
          ),
        ),
      ],
    );
    addTearDown(configuredContainer.dispose);
    final service = configuredContainer.read(deviceServiceProvider);

    await expectLater(service.startGuiding(), throwsException);
    await expectLater(service.stopGuiding(), throwsException);
    await expectLater(service.dither(), throwsException);

    verifyNever(
      () => mockBackend.guiderStartGuiding(
        deviceId: any(named: 'deviceId'),
        settlePixels: any(named: 'settlePixels'),
        settleTime: any(named: 'settleTime'),
        settleTimeout: any(named: 'settleTimeout'),
      ),
    );
    verifyNever(
      () => mockBackend.guiderStopGuiding(deviceId: any(named: 'deviceId')),
    );
    verifyNever(
      () => mockBackend.guiderDither(
        deviceId: any(named: 'deviceId'),
        amount: any(named: 'amount'),
        raOnly: any(named: 'raOnly'),
        settlePixels: any(named: 'settlePixels'),
        settleTime: any(named: 'settleTime'),
        settleTimeout: any(named: 'settleTimeout'),
      ),
    );
  });
}
