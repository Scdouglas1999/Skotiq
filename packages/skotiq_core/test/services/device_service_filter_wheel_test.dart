import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/equipment/equipment_models.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/services/device_service.dart';

import '../mocks/mock_backend.dart';

class TestBackendNotifier extends BackendNotifier {
  TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

void main() {
  late ProviderContainer container;
  late MockBackend mockBackend;
  late SkotiqDatabase database;
  late StreamController<SkotiqEvent> eventStreamController;

  setUpAll(() {
    registerMocktailFallbackValues();
  });

  setUp(() {
    // FilterWheelStateNotifier observes profile/settings streams. Keep those
    // dependencies in this test's database instead of opening the user's
    // filesystem-backed store and racing asynchronous cleanup between tests.
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    mockBackend = MockBackend();
    eventStreamController = StreamController<SkotiqEvent>.broadcast();

    when(
      () => mockBackend.eventStream,
    ).thenAnswer((_) => eventStreamController.stream);
    when(
      () => mockBackend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    when(() => mockBackend.getConnectedDevices()).thenAnswer((_) async => []);
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
        databaseProvider.overrideWithValue(database),
        backendProvider.overrideWith(
          (ref) => TestBackendNotifier(ref, mockBackend),
        ),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await eventStreamController.close();
    await database.close();
  });

  test('connectFilterWheel seeds state from backend status', () async {
    const deviceId = TestFixtures.filterWheelId;
    final filterNames = List<String>.from(TestFixtures.sampleFilterNames);
    final status = FilterWheelStatus(
      connected: true,
      position: 5,
      moving: false,
      filterCount: filterNames.length,
      filterNames: filterNames,
    );

    when(() => mockBackend.discoverDevices(DeviceType.filterWheel)).thenAnswer(
      (_) async => const [
        DeviceInfo(
          id: deviceId,
          name: 'Test Filter Wheel',
          deviceType: DeviceType.filterWheel,
          driverType: DriverType.ascom,
          description: 'Test filter wheel',
          driverVersion: '1.0',
        ),
      ],
    );
    when(
      () => mockBackend.connectDevice(DeviceType.filterWheel, deviceId),
    ).thenAnswer((_) async {});
    when(
      () => mockBackend.filterWheelGetNames(deviceId),
    ).thenAnswer((_) async => filterNames);
    when(
      () => mockBackend.getFilterWheelStatus(deviceId),
    ).thenAnswer((_) async => status);

    final service = container.read(deviceServiceProvider);
    await service.connectFilterWheel(deviceId);

    final state = container.read(filterWheelStateProvider);
    expect(state.connectionState, DeviceConnectionState.connected);
    expect(state.currentPosition, status.position);
    expect(state.filterNames, status.filterNames);
    expect(state.isMoving, status.moving);
    verify(
      () => mockBackend.startDeviceHeartbeat(
        deviceType: DeviceType.filterWheel,
        deviceId: deviceId,
        intervalMs: 10000,
      ),
    ).called(1);
  });

  test(
    'connectFilterWheel rejects an unresolved encoder position and cleans up',
    () async {
      const deviceId = TestFixtures.filterWheelId;
      final filterNames = List<String>.from(TestFixtures.sampleFilterNames);
      final unresolved = FilterWheelStatus(
        connected: true,
        position: -1,
        moving: false,
        filterCount: filterNames.length,
        filterNames: filterNames,
      );

      when(
        () => mockBackend.discoverDevices(DeviceType.filterWheel),
      ).thenAnswer(
        (_) async => const [
          DeviceInfo(
            id: deviceId,
            name: 'Test Filter Wheel',
            deviceType: DeviceType.filterWheel,
            driverType: DriverType.ascom,
            description: 'Test filter wheel',
            driverVersion: '1.0',
          ),
        ],
      );
      when(
        () => mockBackend.connectDevice(DeviceType.filterWheel, deviceId),
      ).thenAnswer((_) async {});
      when(
        () => mockBackend.getFilterWheelStatus(deviceId),
      ).thenAnswer((_) async => unresolved);
      when(
        () => mockBackend.disconnectDevice(DeviceType.filterWheel, deviceId),
      ).thenAnswer((_) async {});

      final service = container.read(deviceServiceProvider);
      await expectLater(
        service.connectFilterWheel(deviceId),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('did not report a valid position'),
          ),
        ),
      );

      expect(
        container.read(filterWheelStateProvider).connectionState,
        DeviceConnectionState.disconnected,
      );
      verify(
        () => mockBackend.disconnectDevice(DeviceType.filterWheel, deviceId),
      ).called(1);
      verifyNever(
        () => mockBackend.startDeviceHeartbeat(
          deviceType: DeviceType.filterWheel,
          deviceId: deviceId,
          intervalMs: any(named: 'intervalMs'),
        ),
      );
    },
  );

  test(
    'setFilterWheelPosition throws when device reports different position',
    () async {
      const deviceId = TestFixtures.filterWheelId;
      final filterNames = List<String>.from(TestFixtures.sampleFilterNames);

      // Seed connected filter wheel state
      final filterWheelNotifier = container.read(
        filterWheelStateProvider.notifier,
      );
      filterWheelNotifier.setConnecting(deviceId, 'Test Filter Wheel');
      filterWheelNotifier.setConnected(filterNames: filterNames);
      filterWheelNotifier.updatePosition(0);

      when(
        () => mockBackend.filterWheelSetPosition(deviceId, 1),
      ).thenAnswer((_) async {});
      when(() => mockBackend.getFilterWheelStatus(deviceId)).thenAnswer(
        (_) async => FilterWheelStatus(
          connected: true,
          position: 2, // Mismatch
          moving: false,
          filterCount: filterNames.length,
          filterNames: filterNames,
        ),
      );

      final service = container.read(deviceServiceProvider);
      await expectLater(
        service.setFilterWheelPosition(1),
        throwsA(isA<Exception>()),
      );
    },
  );

  test(
    'setFilterWheelPosition verify failure keeps moving when hardware still moving ',
    () async {
      const deviceId = TestFixtures.filterWheelId;
      final filterNames = List<String>.from(TestFixtures.sampleFilterNames);

      final filterWheelNotifier = container.read(
        filterWheelStateProvider.notifier,
      );
      filterWheelNotifier.setConnecting(deviceId, 'Test Filter Wheel');
      filterWheelNotifier.setConnected(filterNames: filterNames);
      filterWheelNotifier.updatePosition(0);

      when(
        () => mockBackend.filterWheelSetPosition(deviceId, 1),
      ).thenAnswer((_) async {});

      var pollCount = 0;
      when(() => mockBackend.getFilterWheelStatus(deviceId)).thenAnswer((
        _,
      ) async {
        pollCount++;
        if (pollCount == 1) {
          // Verify loop: stopped but wrong slot → immediate failure.
          return FilterWheelStatus(
            connected: true,
            position: 2,
            moving: false,
            filterCount: filterNames.length,
            filterNames: filterNames,
          );
        }
        // Recovery poll: wheel is still physically moving.
        return FilterWheelStatus(
          connected: true,
          position: -1,
          moving: true,
          filterCount: filterNames.length,
          filterNames: filterNames,
        );
      });

      final service = container.read(deviceServiceProvider);
      await expectLater(
        service.setFilterWheelPosition(1),
        throwsA(isA<Exception>()),
      );

      expect(container.read(filterWheelStateProvider).isMoving, isTrue);
      verify(() => mockBackend.filterWheelSetPosition(deviceId, 1)).called(1);
    },
  );
}
