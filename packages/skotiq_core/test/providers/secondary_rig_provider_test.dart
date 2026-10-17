import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../fakes/fakes.dart';
import '../harness/in_memory_database.dart';

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }

  void replaceWith(SkotiqBackend backend) => state = backend;
}

class _MockNetworkBackend extends Mock implements NetworkBackend {}

Map<String, dynamic> _idleStatus() => {
  'armed': false,
  'running': false,
  'cameraId': null,
  'rigLabel': 'Secondary',
  'framesCaptured': 0,
  'framesAborted': 0,
  'plannedFrames': null,
  'waitingForDither': false,
  'exposing': false,
  'ditherPending': false,
  'forcedProceeds': 0,
  'lastError': null,
};

void main() {
  test('nullable secondary settings can be explicitly cleared', () {
    final container = ProviderContainer(
      overrides: [inMemoryDatabaseOverride()],
    );
    addTearDown(container.dispose);
    final notifier = container.read(secondaryRigConfigProvider.notifier);

    notifier.setCamera('camera-2');
    notifier.setGain(100);
    notifier.setOffset(20);
    notifier.setFilterName('L');
    notifier.setTargetTemp(-10);
    notifier.setCamera(null);
    notifier.setGain(null);
    notifier.setOffset(null);
    notifier.setFilterName(null);
    notifier.setTargetTemp(null);

    final config = container.read(secondaryRigConfigProvider);
    expect(config.cameraId, isNull);
    expect(config.gain, isNull);
    expect(config.offset, isNull);
    expect(config.filterName, isNull);
    expect(config.targetTempC, isNull);
  });

  test('remote secondary stop is sent to the imaging host', () async {
    final fake = FakeNetworkClient()
      ..setResponse(
        '/api/sequencer/secondary-rig/stop',
        method: 'POST',
        body: '{"status":"stopped"}',
      );
    final backend = NetworkBackend(
      serverHost: '127.0.0.1',
      serverPort: 9999,
      webSocketPort: 9999,
      httpClient: fake,
      autoConnectWebSocket: false,
    );
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container.read(secondaryRigControllerProvider).stop();

    expect(fake.requestsFor('/api/sequencer/secondary-rig/stop'), hasLength(1));
  });

  test('remote status decoding fails closed on missing safety fields', () {
    expect(
      () => SecondaryRigStatus.fromJson({'armed': false, 'running': false}),
      throwsFormatException,
    );
  });

  test('host switch clears the previous rig camera selection', () {
    final hostA = NetworkBackend(
      serverHost: 'rig-a.local',
      autoConnectWebSocket: false,
    );
    final hostB = NetworkBackend(
      serverHost: 'rig-b.local',
      autoConnectWebSocket: false,
    );
    late _TestBackendNotifier backendNotifier;
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith((ref) {
          backendNotifier = _TestBackendNotifier(ref, hostA);
          return backendNotifier;
        }),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(hostA.dispose);
    addTearDown(hostB.dispose);

    container.read(secondaryRigConfigProvider.notifier).setCamera('camera-a');
    expect(container.read(secondaryRigConfigProvider).cameraId, 'camera-a');

    backendNotifier.replaceWith(hostB);

    expect(container.read(secondaryRigConfigProvider).cameraId, isNull);
  });

  test(
    'queued old-host actions are discarded and do not block the new host',
    () async {
      final hostA = _MockNetworkBackend();
      final hostB = _MockNetworkBackend();
      final oldHostGate = Completer<void>();
      when(hostA.secondaryRigStop).thenAnswer((_) => oldHostGate.future);
      when(hostB.secondaryRigStop).thenAnswer((_) async {});
      late _TestBackendNotifier backendNotifier;
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith((ref) {
            backendNotifier = _TestBackendNotifier(ref, hostA);
            return backendNotifier;
          }),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(secondaryRigControllerProvider);
      final inFlightOnA = controller.stop();
      await Future<void>.delayed(Duration.zero);
      final queuedOnA = controller.stop();
      final queuedExpectation = expectLater(queuedOnA, throwsStateError);

      backendNotifier.replaceWith(hostB);
      expect(container.read(secondaryRigOperationInProgressProvider), isFalse);

      await controller.stop();
      verify(hostB.secondaryRigStop).called(1);

      oldHostGate.complete();
      await inFlightOnA;
      await queuedExpectation;
      verify(hostA.secondaryRigStop).called(1);
    },
  );

  test('status result from the previous host is discarded', () async {
    final hostA = _MockNetworkBackend();
    final hostB = _MockNetworkBackend();
    final statusGate = Completer<Map<String, dynamic>>();
    when(hostA.secondaryRigGetStatus).thenAnswer((_) => statusGate.future);
    late _TestBackendNotifier backendNotifier;
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith((ref) {
          backendNotifier = _TestBackendNotifier(ref, hostA);
          return backendNotifier;
        }),
      ],
    );
    addTearDown(container.dispose);

    final status = container.read(secondaryRigControllerProvider).getStatus();
    backendNotifier.replaceWith(hostB);
    statusGate.complete(_idleStatus());

    await expectLater(status, throwsStateError);
  });
}
