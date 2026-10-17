import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/disconnected_backend.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/equipment/equipment_models.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/providers/profiles_provider.dart';
import 'package:skotiq_core/src/services/device_service.dart';

void main() {
  test('profile accessory IDs cannot command disconnected hardware', () async {
    final backend = _OpticalTrainBackend();
    final container = _container(
      backend,
      profile: const EquipmentProfileModel(
        name: 'Rig',
        filterWheelId: 'profile-wheel',
        rotatorId: 'profile-rotator',
      ),
    );
    addTearDown(container.dispose);
    final service = container.read(deviceServiceProvider);

    await expectLater(
      service.setFilterWheelPosition(0),
      throwsA(isA<Exception>()),
    );
    await expectLater(service.moveRotatorTo(90), throwsA(isA<Exception>()));

    expect(backend.filterMoveCalls, 0);
    expect(backend.rotatorMoveCalls, 0);
  });

  test('filter wheel moves are exclusive and backend-swap tracked', () async {
    final backend = _OpticalTrainBackend(blockFilterMove: true);
    final container = _container(backend);
    addTearDown(container.dispose);
    _connectFilterWheel(container);
    final service = container.read(deviceServiceProvider);

    final firstMove = service.setFilterWheelPosition(1);
    await backend.filterMoveStarted.future;
    await expectLater(
      service.setFilterWheelPosition(2),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      service.setFilterWheelNames(const ['Lum', 'Red', 'Green']),
      throwsA(isA<StateError>()),
    );

    var swapPrepared = false;
    final prepare = service.prepareForBackendSwap().then((_) {
      swapPrepared = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(swapPrepared, isFalse);

    backend.releaseFilterMove.complete();
    await expectLater(firstMove, throwsA(isA<StateError>()));
    await prepare;
    expect(swapPrepared, isTrue);
    expect(backend.filterMoveCalls, 1);
  });

  test(
    'filter positions and names honor reported wheel capabilities',
    () async {
      final backend = _OpticalTrainBackend(filterCount: 3);
      final container = _container(backend);
      addTearDown(container.dispose);
      _connectFilterWheel(container);
      final service = container.read(deviceServiceProvider);

      await expectLater(
        service.setFilterWheelPosition(3),
        throwsA(isA<RangeError>()),
      );
      await service.setFilterWheelNames(const ['Lum', 'Red', 'Green']);

      expect(backend.filterMoveCalls, 0);
      expect(backend.writtenNames, ['Lum', 'Red', 'Green']);
      expect(container.read(filterWheelStateProvider).filterNames, [
        'Lum',
        'Red',
        'Green',
      ]);
    },
  );

  test(
    'connection-time profile names are written through the backend',
    () async {
      final backend = _OpticalTrainBackend();
      final container = _container(
        backend,
        profile: const EquipmentProfileModel(
          name: 'Rig',
          filterNames: ['Lum', 'Ha', 'OIII'],
        ),
      );
      addTearDown(container.dispose);

      await container
          .read(deviceServiceProvider)
          .connectFilterWheel('simulator:filterwheel:0');

      expect(backend.writtenNames, ['Lum', 'Ha', 'OIII']);
      expect(container.read(filterWheelStateProvider).filterNames, [
        'Lum',
        'Ha',
        'OIII',
      ]);
    },
  );

  test('rotator rejects unsupported/range-invalid absolute moves', () async {
    final backend = _OpticalTrainBackend(
      rotatorCapabilities: const RotatorCapabilities(
        canMoveAbsolute: true,
        minAngleDeg: 0,
        maxAngleDeg: 270,
      ),
    );
    final container = _container(backend);
    addTearDown(container.dispose);
    _connectRotator(container);
    final service = container.read(deviceServiceProvider);

    await expectLater(service.moveRotatorTo(double.nan), throwsArgumentError);
    await expectLater(service.moveRotatorTo(300), throwsA(isA<RangeError>()));
    expect(backend.rotatorMoveCalls, 0);
  });

  test('rotator commands serialize while halt remains interruptible', () async {
    final backend = _OpticalTrainBackend(blockRotatorMove: true);
    final container = _container(backend);
    addTearDown(container.dispose);
    _connectRotator(container);
    final service = container.read(deviceServiceProvider);

    final move = service.moveRotatorRelative(15);
    await backend.rotatorMoveStarted.future;
    await expectLater(service.syncRotatorToPa(45), throwsA(isA<StateError>()));

    await service.haltRotator();
    expect(backend.rotatorHaltCalls, 1);
    backend.releaseRotatorMove.complete();
    await expectLater(move, throwsA(isA<StateError>()));
  });

  test(
    'rotator sync is capability-gated and refreshes reported angle',
    () async {
      final backend = _OpticalTrainBackend(
        rotatorCapabilities: const RotatorCapabilities(canSync: true),
      );
      final container = _container(backend);
      addTearDown(container.dispose);
      _connectRotator(container);

      await container.read(deviceServiceProvider).syncRotatorToPa(123);

      expect(backend.syncedPa, 123);
      expect(container.read(rotatorStateProvider).position, 123);
    },
  );

  test('rotator connection seeds its real initial position', () async {
    final backend = _OpticalTrainBackend()..rotatorPosition = 87.5;
    final container = _container(backend);
    addTearDown(container.dispose);

    await container
        .read(deviceServiceProvider)
        .connectRotator('simulator:rotator:0');

    final state = container.read(rotatorStateProvider);
    expect(state.connectionState, DeviceConnectionState.connected);
    expect(state.position, 87.5);
    expect(state.mechanicalPosition, 87.5);
  });
}

ProviderContainer _container(
  SkotiqBackend backend, {
  EquipmentProfileModel? profile,
}) {
  return ProviderContainer(
    overrides: [
      backendProvider.overrideWith((ref) => _BackendNotifier(ref, backend)),
      activeEquipmentProfileProvider.overrideWithValue(profile),
    ],
  );
}

void _connectFilterWheel(ProviderContainer container) {
  container.read(filterWheelStateProvider.notifier)
    ..setConnecting('wheel-1', 'Wheel')
    ..setConnected(filterNames: const ['L', 'R', 'G'])
    ..updatePosition(0);
}

void _connectRotator(ProviderContainer container) {
  container.read(rotatorStateProvider.notifier)
    ..setConnecting('rotator-1', 'Rotator')
    ..setConnected()
    ..updatePosition(0, mechanicalPosition: 0);
}

class _BackendNotifier extends BackendNotifier {
  _BackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

class _OpticalTrainBackend extends DisconnectedBackend {
  _OpticalTrainBackend({
    this.blockFilterMove = false,
    this.blockRotatorMove = false,
    this.filterCount = 3,
    this.rotatorCapabilities = const RotatorCapabilities(
      canMoveAbsolute: true,
      canHalt: true,
      canSync: true,
      canReverse: true,
    ),
  });

  final bool blockFilterMove;
  final bool blockRotatorMove;
  final int filterCount;
  final RotatorCapabilities rotatorCapabilities;
  final filterMoveStarted = Completer<void>();
  final releaseFilterMove = Completer<void>();
  final rotatorMoveStarted = Completer<void>();
  final releaseRotatorMove = Completer<void>();
  var filterPosition = 0;
  var filterMoving = false;
  var filterMoveCalls = 0;
  List<String>? writtenNames;
  var rotatorPosition = 0.0;
  var rotatorMoving = false;
  var rotatorMoveCalls = 0;
  var rotatorHaltCalls = 0;
  double? syncedPa;

  @override
  Future<void> connectDevice(DeviceType type, String deviceId) async {}

  @override
  Future<List<DeviceInfo>> getConnectedDevices() async => const [];

  @override
  Future<FilterWheelCapabilities?> getFilterWheelCapabilities(
    String deviceId,
  ) async {
    return FilterWheelCapabilities(
      positionCount: filterCount,
      canSetFilterNames: true,
    );
  }

  @override
  Future<void> filterWheelSetPosition(String deviceId, int position) async {
    filterMoveCalls++;
    filterMoving = true;
    if (!filterMoveStarted.isCompleted) filterMoveStarted.complete();
    if (blockFilterMove) await releaseFilterMove.future;
    filterPosition = position;
    filterMoving = false;
  }

  @override
  Future<FilterWheelStatus> getFilterWheelStatus(String deviceId) async {
    return FilterWheelStatus(
      connected: true,
      position: filterPosition,
      moving: filterMoving,
      filterCount: filterCount,
      filterNames: const ['L', 'R', 'G'],
    );
  }

  @override
  Future<void> filterWheelSetNames(String deviceId, List<String> names) async {
    writtenNames = List<String>.from(names);
  }

  @override
  Future<RotatorCapabilities?> getRotatorCapabilities(String deviceId) async {
    return rotatorCapabilities;
  }

  @override
  Future<RotatorStatus> getRotatorStatus(String deviceId) async {
    return RotatorStatus(
      connected: true,
      position: rotatorPosition,
      moving: rotatorMoving,
      mechanicalPosition: rotatorPosition,
      isMoving: rotatorMoving,
      canReverse: rotatorCapabilities.canReverse,
    );
  }

  @override
  Future<void> rotatorMoveTo(String deviceId, double angle) async {
    rotatorMoveCalls++;
    rotatorPosition = angle;
  }

  @override
  Future<void> rotatorMoveRelative(String deviceId, double delta) async {
    rotatorMoveCalls++;
    rotatorMoving = true;
    if (!rotatorMoveStarted.isCompleted) rotatorMoveStarted.complete();
    if (blockRotatorMove) await releaseRotatorMove.future;
    if (rotatorMoving) rotatorPosition = (rotatorPosition + delta) % 360;
    rotatorMoving = false;
  }

  @override
  Future<void> rotatorHalt(String deviceId) async {
    rotatorHaltCalls++;
    rotatorMoving = false;
  }

  @override
  Future<double> rotatorGetAngle(String deviceId) async => rotatorPosition;

  @override
  Future<void> rotatorSyncToPa(String deviceId, double pa) async {
    syncedPa = pa;
    rotatorPosition = pa;
  }
}
