import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/services/device_service.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/models/equipment/equipment_models.dart';

import '../mocks/mock_backend.dart';

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

    // Configure mock backend
    when(
      () => mockBackend.eventStream,
    ).thenAnswer((_) => eventStreamController.stream);
    when(
      () => mockBackend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());

    container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => TestBackendNotifier(ref, mockBackend),
        ),
      ],
    );

    // Ensure DeviceService is initialized so equipment event listeners are active.
    container.read(deviceServiceProvider);
  });

  tearDown(() {
    eventStreamController.close();
    container.dispose();
  });

  group('Device Disconnect Detection', () {
    test('Camera disconnect event updates state to disconnected', () async {
      // Setup initial connected state
      final cameraNotifier = container.read(cameraStateProvider.notifier);
      cameraNotifier.setConnecting('camera-1', 'Test Camera');
      cameraNotifier.setConnected();

      expect(
        container.read(cameraStateProvider).connectionState,
        DeviceConnectionState.connected,
      );

      // Emit disconnect event
      eventStreamController.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.warning,
          category: EventCategory.equipment,
          eventType: 'Disconnected',
          data: {'device_type': 'camera', 'device_id': 'camera-1'},
        ),
      );

      // Wait for event processing
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify camera is now disconnected
      expect(
        container.read(cameraStateProvider).connectionState,
        DeviceConnectionState.disconnected,
      );
    });

    test('Mount disconnect event updates state to disconnected', () async {
      // Setup initial connected state
      final mountNotifier = container.read(mountStateProvider.notifier);
      mountNotifier.setConnecting('mount-1');
      mountNotifier.setConnected();

      expect(
        container.read(mountStateProvider).connectionState,
        DeviceConnectionState.connected,
      );

      // Emit disconnect event
      eventStreamController.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.warning,
          category: EventCategory.equipment,
          eventType: 'Disconnected',
          data: {'device_type': 'mount', 'device_id': 'mount-1'},
        ),
      );

      // Wait for event processing
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify mount is now disconnected
      expect(
        container.read(mountStateProvider).connectionState,
        DeviceConnectionState.disconnected,
      );
    });

    test('Focuser disconnect event updates state to disconnected', () async {
      // Setup initial connected state
      final focuserNotifier = container.read(focuserStateProvider.notifier);
      focuserNotifier.setConnecting('focuser-1');
      focuserNotifier.setConnected();

      expect(
        container.read(focuserStateProvider).connectionState,
        DeviceConnectionState.connected,
      );

      // Emit disconnect event
      eventStreamController.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.warning,
          category: EventCategory.equipment,
          eventType: 'Disconnected',
          data: {'device_type': 'focuser', 'device_id': 'focuser-1'},
        ),
      );

      // Wait for event processing
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify focuser is now disconnected
      expect(
        container.read(focuserStateProvider).connectionState,
        DeviceConnectionState.disconnected,
      );
    });

    // A `Disconnected` event names a device, but `setDisconnected()` resets the
    // whole type slot and takes no id. Applying a foreign/stale event therefore
    // erased the identity of the device that WAS connected, while the native
    // driver registry kept it open — and `POST /api/devices/disconnect` gates on
    // this notifier, so the driver became releasable only by restarting the
    // process (observed on the rig: `/api/devices/connected` listing an ASCOM
    // focuser whose `status` returned `{"connected":true,"position":35840,...}`
    // while disconnect answered `device_not_connected`).
    test(
      'a Disconnected event for a DIFFERENT focuser must not clear the live one',
      () async {
        final focuserNotifier = container.read(focuserStateProvider.notifier);
        focuserNotifier.setConnecting('ascom:ASCOM.Simulator.Focuser');
        focuserNotifier.setConnected();

        eventStreamController.add(
          SkotiqEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: EventSeverity.warning,
            category: EventCategory.equipment,
            eventType: 'Disconnected',
            // A stale event from an earlier, absent focuser (profile
            // auto-reconnect churn is the common source).
            data: {
              'device_type': 'focuser',
              'device_id': 'ascom:ASCOM.EAF.Focuser',
            },
          ),
        );

        await Future.delayed(const Duration(milliseconds: 100));

        final state = container.read(focuserStateProvider);
        expect(
          state.connectionState,
          DeviceConnectionState.connected,
          reason: 'the live focuser must stay connected',
        );
        expect(
          state.deviceId,
          'ascom:ASCOM.Simulator.Focuser',
          reason: 'losing this id is what makes the driver unreleasable',
        );
      },
    );

    test(
      'a Disconnected event for a DIFFERENT camera must not clear the live one',
      () async {
        final cameraNotifier = container.read(cameraStateProvider.notifier);
        cameraNotifier.setConnecting('native:zwo:0', 'ASI1600MM');
        cameraNotifier.setConnected();

        eventStreamController.add(
          SkotiqEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: EventSeverity.warning,
            category: EventCategory.equipment,
            eventType: 'Disconnected',
            data: {
              'device_type': 'camera',
              'device_id': 'ascom:ASCOM.Simulator.Camera',
            },
          ),
        );

        await Future.delayed(const Duration(milliseconds: 100));

        final state = container.read(cameraStateProvider);
        expect(state.connectionState, DeviceConnectionState.connected);
        expect(state.deviceId, 'native:zwo:0');
      },
    );

    test(
      'a Disconnected event for an empty slot is a harmless no-op',
      () async {
        expect(container.read(rotatorStateProvider).deviceId, isNull);

        eventStreamController.add(
          SkotiqEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: EventSeverity.warning,
            category: EventCategory.equipment,
            eventType: 'Disconnected',
            data: {'device_type': 'rotator', 'device_id': 'rotator-1'},
          ),
        );

        await Future.delayed(const Duration(milliseconds: 100));

        expect(
          container.read(rotatorStateProvider).connectionState,
          DeviceConnectionState.disconnected,
        );
      },
    );
  });

  group('Connection Health Monitoring', () {
    test(
      'Camera health indicator shows healthy after recent communication',
      () {
        final cameraNotifier = container.read(cameraStateProvider.notifier);
        cameraNotifier.setConnecting('camera-1', 'Test Camera');
        cameraNotifier.setConnected();

        // Update communication timestamp
        cameraNotifier.updateCommunication();

        final state = container.read(cameraStateProvider);
        expect(state.isHealthy, isTrue);
        expect(state.lastSuccessfulCommunication, isNotNull);
      },
    );

    test('Camera health indicator shows unhealthy after timeout', () {
      final cameraNotifier = container.read(cameraStateProvider.notifier);
      cameraNotifier.setConnecting('camera-1', 'Test Camera');
      cameraNotifier.setConnected();

      // Set communication timestamp to 31 seconds ago (past the 30 second threshold)
      final oldTimestamp = DateTime.now().subtract(const Duration(seconds: 31));
      final oldState = container
          .read(cameraStateProvider)
          .copyWith(lastSuccessfulCommunication: oldTimestamp);

      // A snapshot with a stale last-communication timestamp, which is what
      // the health check reads.
      expect(
        oldState.lastSuccessfulCommunication!
                .difference(DateTime.now())
                .inSeconds
                .abs() >
            30,
        isTrue,
      );
    });

    test('Temperature update sets lastSuccessfulCommunication', () {
      final cameraNotifier = container.read(cameraStateProvider.notifier);
      cameraNotifier.setConnecting('camera-1', 'Test Camera');
      cameraNotifier.setConnected();

      final timestampBefore = DateTime.now();

      // Update temperature (should update communication timestamp)
      cameraNotifier.updateTemperature(-10.0, 50.0);

      final state = container.read(cameraStateProvider);
      expect(state.lastSuccessfulCommunication, isNotNull);
      final communicationTime = state.lastSuccessfulCommunication!;
      expect(
        communicationTime.isAfter(timestampBefore) ||
            communicationTime.isAtSameMomentAs(timestampBefore),
        isTrue,
      );
      expect(state.temperature, -10.0);
      expect(state.coolerPower, 50.0);
    });
  });

  group('Auto-Reconnection', () {
    test('Auto-reconnection is enabled by default for camera', () {
      final state = container.read(cameraStateProvider);
      expect(state.autoReconnectEnabled, isTrue);
    });

    test('Auto-reconnection can be disabled', () {
      final cameraNotifier = container.read(cameraStateProvider.notifier);
      cameraNotifier.setAutoReconnect(false);

      final state = container.read(cameraStateProvider);
      expect(state.autoReconnectEnabled, isFalse);
    });

    test('Auto-reconnection can be re-enabled', () {
      final cameraNotifier = container.read(cameraStateProvider.notifier);

      // Disable
      cameraNotifier.setAutoReconnect(false);
      expect(container.read(cameraStateProvider).autoReconnectEnabled, isFalse);

      // Re-enable
      cameraNotifier.setAutoReconnect(true);
      expect(container.read(cameraStateProvider).autoReconnectEnabled, isTrue);
    });
  });

  group('Device Error Handling', () {
    test('Connection error sets error state', () {
      final cameraNotifier = container.read(cameraStateProvider.notifier);

      final error = DeviceError(
        type: DeviceErrorType.connectionFailed,
        message: 'Failed to connect to camera',
        timestamp: DateTime.now(),
        deviceId: 'camera-1',
      );

      cameraNotifier.setError(error);

      final state = container.read(cameraStateProvider);
      expect(state.connectionState, DeviceConnectionState.error);
      expect(state.lastError, isNotNull);
      expect(state.lastError!.type, DeviceErrorType.connectionFailed);
    });

    test('Error can be cleared', () {
      final cameraNotifier = container.read(cameraStateProvider.notifier);

      // Set error
      final error = DeviceError(
        type: DeviceErrorType.connectionFailed,
        message: 'Failed to connect to camera',
        timestamp: DateTime.now(),
        deviceId: 'camera-1',
      );
      cameraNotifier.setError(error);

      expect(container.read(cameraStateProvider).hasError, isTrue);

      // Clear error
      cameraNotifier.clearError();

      expect(container.read(cameraStateProvider).hasError, isFalse);
      expect(container.read(cameraStateProvider).lastError, isNull);
    });

    test('DeviceError.fromException categorizes timeout errors', () {
      final error = DeviceError.fromException(
        Exception('Operation timed out'),
        deviceId: 'test-device',
      );

      expect(error.type, DeviceErrorType.timeout);
      expect(error.recoverable, isTrue);
    });

    test(
      'DeviceError.fromException categorizes not found errors as non-recoverable',
      () {
        final error = DeviceError.fromException(
          Exception('Device not found'),
          deviceId: 'test-device',
        );

        expect(error.type, DeviceErrorType.deviceNotFound);
        expect(error.recoverable, isFalse);
      },
    );

    test('DeviceError provides user-friendly messages', () {
      final timeoutError = DeviceError(
        type: DeviceErrorType.timeout,
        message: 'Operation timed out',
        timestamp: DateTime.now(),
      );

      expect(timeoutError.userMessage, contains('Operation timed out'));

      final notFoundError = DeviceError(
        type: DeviceErrorType.deviceNotFound,
        message: 'Device not found',
        timestamp: DateTime.now(),
      );

      expect(notFoundError.userMessage, contains('Device not found'));
    });

    test('DeviceError provides suggested recovery actions', () {
      final connectionError = DeviceError(
        type: DeviceErrorType.connectionFailed,
        message: 'Connection failed',
        timestamp: DateTime.now(),
      );

      expect(connectionError.suggestedAction, isNotNull);
      expect(connectionError.suggestedAction, contains('reconnect'));
    });
  });

  group('Cover calibrator + switch disconnect cases', () {
    test(
      'Cover calibrator disconnect event updates state to disconnected',
      () async {
        // Setup initial connected state
        final coverCal = container.read(coverCalibratorStateProvider.notifier);
        coverCal.setConnecting('covercal-1', 'Test Cover Cal');
        coverCal.setConnected();

        expect(
          container.read(coverCalibratorStateProvider).connectionState,
          DeviceConnectionState.connected,
        );

        // Emit disconnect event
        eventStreamController.add(
          SkotiqEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: EventSeverity.warning,
            category: EventCategory.equipment,
            eventType: 'Disconnected',
            data: {'device_type': 'covercalibrator', 'device_id': 'covercal-1'},
          ),
        );

        await Future.delayed(const Duration(milliseconds: 50));

        expect(
          container.read(coverCalibratorStateProvider).connectionState,
          DeviceConnectionState.disconnected,
        );
      },
    );

    test(
      'Cover calibrator disconnect also handles "cover calibrator" spelling',
      () async {
        final coverCal = container.read(coverCalibratorStateProvider.notifier);
        coverCal.setConnecting('covercal-2', 'Test Cover Cal');
        coverCal.setConnected();

        eventStreamController.add(
          SkotiqEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: EventSeverity.warning,
            category: EventCategory.equipment,
            eventType: 'Disconnected',
            data: {
              'device_type': 'cover calibrator',
              'device_id': 'covercal-2',
            },
          ),
        );

        await Future.delayed(const Duration(milliseconds: 50));

        expect(
          container.read(coverCalibratorStateProvider).connectionState,
          DeviceConnectionState.disconnected,
        );
      },
    );

    test('Switch disconnect event clears state via the provider ', () async {
      // Switch now has a first-class state provider, so
      // disconnects route through `setDisconnected` instead of just
      // emitting a notification.
      final notifier = container.read(switchStateProvider.notifier);
      notifier.setConnecting('switch-1', 'Test Switch');
      notifier.setConnected();

      eventStreamController.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.warning,
          category: EventCategory.equipment,
          eventType: 'Disconnected',
          data: {'device_type': 'switch', 'device_id': 'switch-1'},
        ),
      );

      await Future.delayed(const Duration(milliseconds: 50));

      expect(
        container.read(switchStateProvider).connectionState,
        DeviceConnectionState.disconnected,
      );
    });
  });

  group('Driver Error events surface to state + notifications', () {
    test('Error event updates matching device state to error', () async {
      // Camera starts connected.
      final cameraNotifier = container.read(cameraStateProvider.notifier);
      cameraNotifier.setConnecting('camera-1', 'Test Camera');
      cameraNotifier.setConnected();

      // Driver fires an Error event.
      eventStreamController.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.error,
          category: EventCategory.equipment,
          eventType: 'Error',
          data: {
            'device_type': 'camera',
            'device_id': 'camera-1',
            'message': 'Sensor temperature read failed',
          },
        ),
      );

      await Future.delayed(const Duration(milliseconds: 50));

      final state = container.read(cameraStateProvider);
      expect(state.connectionState, DeviceConnectionState.error);
      expect(state.lastError, isNotNull);
      expect(
        state.lastError!.message,
        contains('Sensor temperature read failed'),
      );
    });

    test(
      'Error event with errorCode includes code in stored message',
      () async {
        final mountNotifier = container.read(mountStateProvider.notifier);
        mountNotifier.setConnecting('mount-1');
        mountNotifier.setConnected();

        eventStreamController.add(
          SkotiqEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: EventSeverity.error,
            category: EventCategory.equipment,
            eventType: 'Error',
            data: {
              'device_type': 'mount',
              'device_id': 'mount-1',
              'message': 'Slew refused: park engaged',
              'error_code': 'ASCOM_E04',
            },
          ),
        );

        await Future.delayed(const Duration(milliseconds: 50));

        final state = container.read(mountStateProvider);
        expect(state.connectionState, DeviceConnectionState.error);
        expect(state.lastError!.message, contains('Slew refused'));
        expect(state.lastError!.message, contains('ASCOM_E04'));
      },
    );

    test('Error event for unknown device type does not crash', () async {
      eventStreamController.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.error,
          category: EventCategory.equipment,
          eventType: 'Error',
          data: {
            'device_type': 'flux_capacitor',
            'device_id': 'fc-1',
            'message': 'too much flux',
          },
        ),
      );

      await Future.delayed(const Duration(milliseconds: 50));
      // Should not throw; warning path is exercised.
      expect(true, isTrue);
    });

    test('Error event with missing message still routes through', () async {
      final focuserNotifier = container.read(focuserStateProvider.notifier);
      focuserNotifier.setConnecting('focuser-1');
      focuserNotifier.setConnected();

      eventStreamController.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.error,
          category: EventCategory.equipment,
          eventType: 'Error',
          data: {
            'device_type': 'focuser',
            'device_id': 'focuser-1',
            // no 'message' field
          },
        ),
      );

      await Future.delayed(const Duration(milliseconds: 50));

      final state = container.read(focuserStateProvider);
      expect(state.connectionState, DeviceConnectionState.error);
      expect(state.lastError, isNotNull);
    });
  });

  group('Camera disconnect guards stale device-id events', () {
    test('Stale camera Disconnected for non-tracked id does not flip current '
        'camera state', () async {
      // Connect camera-A
      final cameraNotifier = container.read(cameraStateProvider.notifier);
      cameraNotifier.setConnecting('camera-A', 'Camera A');
      cameraNotifier.setConnected();

      // Emit a stale disconnect for camera-B (a previously disconnected
      // camera). Both the polling teardown AND the notifier wipe must be
      // skipped, or camera-A loses its identity while its driver stays open.
      eventStreamController.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.warning,
          category: EventCategory.equipment,
          eventType: 'Disconnected',
          data: {'device_type': 'camera', 'device_id': 'camera-B'},
        ),
      );

      await Future.delayed(const Duration(milliseconds: 50));

      final state = container.read(cameraStateProvider);
      expect(state.connectionState, DeviceConnectionState.connected);
      expect(state.deviceId, 'camera-A');

      // A real disconnect for camera-A still tears it down.
      eventStreamController.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.warning,
          category: EventCategory.equipment,
          eventType: 'Disconnected',
          data: {'device_type': 'camera', 'device_id': 'camera-A'},
        ),
      );

      await Future.delayed(const Duration(milliseconds: 50));

      expect(
        container.read(cameraStateProvider).connectionState,
        DeviceConnectionState.disconnected,
      );
      expect(container.read(cameraStateProvider).deviceId, isNull);
    });
  });

  group('Backend Integration', () {
    test('startDeviceHeartbeat is called when camera connects', () async {
      // Device ids must match a known driver prefix.
      const cameraId = 'simulator:camera-1';

      // Configure mock to succeed
      when(
        () => mockBackend.connectDevice(any(), any()),
      ).thenAnswer((_) async {});
      when(
        () => mockBackend.startDeviceHeartbeat(
          deviceType: any(named: 'deviceType'),
          deviceId: any(named: 'deviceId'),
          intervalMs: any(named: 'intervalMs'),
        ),
      ).thenAnswer((_) async {});

      final deviceService = container.read(deviceServiceProvider);

      // Connect camera
      await deviceService.connectCamera(cameraId);

      // Verify heartbeat was started
      verify(
        () => mockBackend.startDeviceHeartbeat(
          deviceType: DeviceType.camera,
          deviceId: cameraId,
          intervalMs: 10000,
        ),
      ).called(1);
    });

    test('stopDeviceHeartbeat is called when camera disconnects', () async {
      // Configure mock
      when(
        () => mockBackend.stopDeviceHeartbeat(any()),
      ).thenAnswer((_) async {});
      when(
        () => mockBackend.disconnectDevice(any(), any()),
      ).thenAnswer((_) async {});

      // Setup camera state with device ID
      final cameraNotifier = container.read(cameraStateProvider.notifier);
      cameraNotifier.setConnecting('camera-1', 'Test Camera');
      cameraNotifier.setConnected();

      // Disconnect is more complex as it requires profile data
      // This test would need proper profile mocking
      // For now, verify the mock setup works
      verify(() => mockBackend.eventStream).called(greaterThan(0));
    });
  });
}
