import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/models/backend/backend_types.dart';
import 'package:skotiq_core/src/models/equipment_profile_model.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/providers/profiles_provider.dart';
import 'package:skotiq_core/src/providers/sequence/run_record.dart';
import 'package:skotiq_core/src/services/device_reconnect_coordinator.dart';

import '../mocks/mock_backend.dart';

/// What a lost camera does to the run, by the state the run is in: every live
/// run gets a checkpoint, and the coordinator lifts only the pause it placed.
void main() {
  const cameraId = 'sim_camera_1';
  late MockBackend backend;
  late ProviderContainer container;
  late DeviceReconnectCoordinator coordinator;
  late List<String> calls;

  setUpAll(registerMocktailFallbackValues);

  setUp(() {
    backend = MockBackend();
    when(
      () => backend.nativeReconnectedDeviceTypes,
    ).thenReturn(DeviceType.values.toSet());
    calls = [];
    when(() => backend.saveCheckpoint()).thenAnswer((_) async {
      calls.add('checkpoint');
    });
    container = ProviderContainer(
      overrides: [
        activeEquipmentProfileProvider.overrideWithValue(
          const EquipmentProfileModel(id: 1, name: 'Rig', cameraId: cameraId),
        ),
      ],
    );
    final run = container.read(runRecordProvider.notifier);
    coordinator = container.read(
      Provider(
        (ref) => DeviceReconnectCoordinator(
          ref: ref,
          backend: backend,
          hostOwnsRecovery: false,
          pauseSequence: ({origin}) async {
            calls.add(origin == null ? 'pause' : 'pause: $origin');
            run.setLifecycle(SequenceExecutionState.paused);
          },
          resumeSequence: () async {
            calls.add('resume');
            run.setLifecycle(SequenceExecutionState.running);
          },
          surfaceReconnecting: (deviceId) {},
        ),
      ),
    );
  });

  tearDown(() => container.dispose());

  void runIs(SequenceExecutionState state) =>
      container.read(runRecordProvider.notifier).setLifecycle(state);

  Future<void> cameraDropsAndComesBack() async {
    final camera = container.read(cameraStateProvider.notifier);
    camera.setDisconnected();
    await coordinator.handleCriticalDeviceDisconnect('camera', cameraId);
    camera.setConnecting(cameraId, 'Camera');
    camera.setConnected();
    await coordinator.onAuthoritativeDeviceConnected(
      DeviceType.camera,
      cameraId,
    );
  }

  test('a running run is checkpointed, paused, and resumed when the camera '
      'is back', () async {
    runIs(SequenceExecutionState.running);
    await cameraDropsAndComesBack();
    expect(calls, ['checkpoint', 'pause: camera disconnected', 'resume']);
  });

  test('a run inside a recovery is checkpointed and paused too', () async {
    runIs(SequenceExecutionState.recovering);
    await cameraDropsAndComesBack();
    expect(calls, ['checkpoint', 'pause: camera disconnected', 'resume']);
  });

  test('a run a manual action holds is paused under the device loss too, so '
      'that pause outlives the hold', () async {
    runIs(SequenceExecutionState.running);
    runIs(SequenceExecutionState.paused);
    container.read(runRecordProvider.notifier).setHeldByAction(true);
    final camera = container.read(cameraStateProvider.notifier);
    camera.setDisconnected();
    await coordinator.handleCriticalDeviceDisconnect('camera', cameraId);
    expect(calls, ['checkpoint', 'pause: camera disconnected']);
  });

  test('a run the operator paused is checkpointed and stays paused', () async {
    runIs(SequenceExecutionState.running);
    runIs(SequenceExecutionState.paused);
    await cameraDropsAndComesBack();
    expect(calls, ['checkpoint']);
    expect(
      container.read(runRecordProvider).lifecycle,
      SequenceExecutionState.paused,
    );
  });

  test('a pause the coordinator placed is not lifted after the operator '
      'resumed and paused again', () async {
    runIs(SequenceExecutionState.running);
    final camera = container.read(cameraStateProvider.notifier);
    camera.setDisconnected();
    await coordinator.handleCriticalDeviceDisconnect('camera', cameraId);
    runIs(SequenceExecutionState.running);
    runIs(SequenceExecutionState.paused);
    camera.setConnecting(cameraId, 'Camera');
    camera.setConnected();
    await coordinator.onAuthoritativeDeviceConnected(
      DeviceType.camera,
      cameraId,
    );
    expect(calls, ['checkpoint', 'pause: camera disconnected']);
  });

  test(
    'a run restored from its checkpoint and not started is left alone',
    () async {
      runIs(SequenceExecutionState.idle);
      await cameraDropsAndComesBack();
      expect(calls, isEmpty);
      expect(
        container.read(runRecordProvider).lifecycle,
        SequenceExecutionState.idle,
      );
    },
  );
}
