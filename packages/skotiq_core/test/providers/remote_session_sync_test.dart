import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:mocktail/mocktail.dart';

import 'package:skotiq_core/skotiq_core.dart';
import '../harness/in_memory_database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

/// hydrateRemoteSessionState invalidates the host-mirrored planner/scheduler
/// data providers on connect (projects, integration goals, target constraints,
/// scheduler preview, sequence runs, observing lists) so the slave shows the
/// host's rows immediately. In NetworkBackend mode those providers re-fetch via
/// these endpoints, so a mock must answer them or the (eager) StreamProvider
/// rebuild throws a null-future and aborts hydration before the mirrored state
/// is asserted. These stubs are intentionally empty payloads — the test only
/// cares that hydration completes, not what the planner data contains.
void _stubHydrationParityEndpoints(_MockNetworkBackend backend) {
  when(() => backend.getIntegrationGoals()).thenAnswer((_) async => const []);
  when(
    () => backend.getIntegrationGoals(targetId: any(named: 'targetId')),
  ).thenAnswer((_) async => const []);
  when(() => backend.getTargetConstraints()).thenAnswer((_) async => const []);
  when(
    () => backend.getTargetConstraints(targetId: any(named: 'targetId')),
  ).thenAnswer((_) async => const []);
  when(() => backend.getProjects()).thenAnswer((_) async => const []);
  when(() => backend.getObservingLists()).thenAnswer((_) async => const []);
  when(
    () => backend.getListedCatalogIds(listId: any(named: 'listId')),
  ).thenAnswer((_) async => const <String>{});
  when(() => backend.getListedCatalogIds()).thenAnswer((_) async => const {});
  when(() => backend.getSchedulerPreview()).thenAnswer(
    (_) async => SchedulerDecision(
      score: 0,
      reasoning: const [],
      scoredCandidates: const [],
      evaluatedAt: DateTime.fromMillisecondsSinceEpoch(0),
    ),
  );
  when(() => backend.getProfiles()).thenAnswer((_) async => const []);
  when(() => backend.getActiveProfile()).thenAnswer((_) async => null);
  when(
    () => backend.fetchSequenceRuns(
      sequenceId: any(named: 'sequenceId'),
      limit: any(named: 'limit'),
      offset: any(named: 'offset'),
    ),
  ).thenAnswer(
    (_) async => const RemotePage<RemoteSequenceRun>(items: [], total: 0),
  );
}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) {
    state = backend;
  }
}

void main() {
  setUpAll(() {
    registerFallbackValue(const Stream<SkotiqEvent>.empty());
  });

  group('remoteSessionSyncProvider', () {
    test(
      'late hydration from an old host cannot overwrite the new host',
      () async {
        final hostA = _MockNetworkBackend();
        final hostB = _MockNetworkBackend();
        final delayedStatus = Completer<SequencerStatus>();
        when(hostA.sequencerGetStatus).thenAnswer((_) => delayedStatus.future);
        when(
          () => hostA.eventStream,
        ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
        when(
          () => hostA.connectionState,
        ).thenReturn(BackendConnectionState.connected);

        when(hostB.sequencerGetStatus).thenAnswer(
          (_) async => const SequencerStatus(state: 'Idle', progress: 0),
        );
        when(hostB.getHostRuntimeState).thenAnswer(
          (_) async => const [
            HostRuntimeUpdate(
              channel: 'device.mount',
              revision: 5,
              value: {
                'state': 'connected',
                'deviceId': 'host-b-mount',
                'deviceName': 'Host B Mount',
                'readings': {'ra': 7.0, 'dec': 8.0, 'isTracking': true},
              },
            ),
          ],
        );
        when(
          () => hostB.eventStream,
        ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
        when(
          () => hostB.connectionState,
        ).thenReturn(BackendConnectionState.connected);
        _stubHydrationParityEndpoints(hostB);

        final container = ProviderContainer(
          overrides: [
            inMemoryDatabaseOverride(),
            backendProvider.overrideWith(
              (ref) => _FixedBackendNotifier(ref, hostA),
            ),
            loggingServiceProvider.overrideWithValue(LoggingService()),
          ],
        );
        addTearDown(container.dispose);
        container.read(remoteSessionSyncProvider);
        await pumpEventQueue();
        verify(hostA.sequencerGetStatus).called(1);

        final notifier =
            container.read(backendProvider.notifier) as _FixedBackendNotifier;
        notifier.switchTo(hostB);
        await pumpEventQueue(times: 20);
        delayedStatus.complete(
          const SequencerStatus(state: 'Running', progress: 0.5),
        );
        await pumpEventQueue(times: 20);

        final mount = container.read(mountStateProvider);
        expect(mount.deviceId, 'host-b-mount');
        expect(mount.ra, 7);
        expect(
          container.read(sequenceExecutionStateProvider),
          isNot(SequenceExecutionState.running),
        );
        verifyNever(hostA.getHostRuntimeState);
      },
    );

    test('no hydration fan-out while backend is in terminal error', () async {
      final backend = _MockNetworkBackend();
      when(
        () => backend.eventStream,
      ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
      when(
        () => backend.connectionState,
      ).thenReturn(BackendConnectionState.error);
      // Deliberately no hydration stubs: ANY fan-out call would hit an
      // unstubbed method — the verifyNevers below prove none was made.

      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
          loggingServiceProvider.overrideWithValue(LoggingService()),
        ],
      );
      addTearDown(container.dispose);

      container.read(remoteSessionSyncProvider);
      await pumpEventQueue(times: 10);

      verifyNever(() => backend.sequencerGetStatus());
      verifyNever(() => backend.getHostRuntimeState());
    });
  });
}
