import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../harness/in_memory_database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _MockIntegrationGoalService extends Mock
    implements IntegrationGoalService {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void replaceWith(SkotiqBackend backend) => state = backend;
}

void main() {
  test(
    'remote scheduler snapshot is sourced entirely from the imaging host',
    () async {
      final backend = _MockNetworkBackend();
      final evaluatedAt = DateTime.utc(2026, 7, 13, 3, 4, 5);
      when(backend.getSchedulerState).thenAnswer(
        (_) async => {
          'status': {
            'state': 'running',
            'currentTargetId': 42,
            'currentTargetName': 'M 42',
            'nextEvaluationAt': evaluatedAt
                .add(const Duration(minutes: 1))
                .toIso8601String(),
          },
          'decision': {
            'chosenTargetId': 42,
            'chosenTargetName': 'M 42',
            'score': 2.5,
            'reasoning': ['best target'],
            'scoredCandidates': <Object?>[],
            'rejected': <Object?>[],
            'evaluatedAt': evaluatedAt.toIso8601String(),
            'isSwitch': false,
          },
          'config': SchedulerConfig.defaults
              .copyWith(minAltitudeDegrees: 33)
              .toStorageJson(),
        },
      );
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
          schedulerEngineProvider.overrideWith(
            (ref) => throw StateError('remote UI must not construct an engine'),
          ),
        ],
      );
      addTearDown(container.dispose);

      final snapshot = await container.read(
        schedulerRemoteSnapshotProvider.future,
      );

      expect(snapshot.status.state, SchedulerState.running);
      expect(snapshot.status.currentTargetId, 42);
      expect(snapshot.decision.chosenTargetName, 'M 42');
      expect(snapshot.config.minAltitudeDegrees, 33);
      verify(backend.getSchedulerState).called(1);
    },
  );

  test('scheduler status wire format round-trips nullable runtime fields', () {
    final original = SchedulerStatus(
      state: SchedulerState.paused,
      currentTargetId: 7,
      currentTargetName: 'NGC 7000',
      nextEvaluationAt: DateTime.utc(2026, 7, 13, 1, 2, 3),
      lastError: 'guide star lost',
    );

    expect(SchedulerStatus.fromJson(original.toJson()), original);
  });

  test(
    'candidate load aborts instead of mixing hosts after backend replacement',
    () async {
      final oldBackend = _MockNetworkBackend();
      final replacementBackend = _MockNetworkBackend();
      final goalService = _MockIntegrationGoalService();
      final targetsGate = Completer<List<Map<String, dynamic>>>();
      final targetsStarted = Completer<void>();
      when(oldBackend.getAllTargets).thenAnswer((_) {
        targetsStarted.complete();
        return targetsGate.future;
      });
      // Queue membership is read from the host before the catalog is (a target
      // the operator removed from the scheduler must not be loaded at all).
      when(
        oldBackend.getSchedulerQueueRemovedTargets,
      ).thenAnswer((_) async => <int>{});

      late _FixedBackendNotifier backendNotifier;
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith((ref) {
            return backendNotifier = _FixedBackendNotifier(ref, oldBackend);
          }),
          activeEquipmentProfileProvider.overrideWith((ref) => null),
          integrationGoalServiceProvider.overrideWithValue(goalService),
        ],
      );
      addTearDown(container.dispose);

      final pending = container.read(schedulerCandidateLoaderProvider).load();
      await targetsStarted.future;
      backendNotifier.replaceWith(replacementBackend);
      targetsGate.complete([
        {'id': 7, 'name': 'M 31', 'ra': 0.71, 'dec': 41.27, 'priority': 5},
      ]);

      await expectLater(
        pending,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('backend changed'),
          ),
        ),
      );
      verify(oldBackend.getAllTargets).called(1);
      verifyNever(oldBackend.getTargetConstraints);
      verifyNever(replacementBackend.getAllTargets);
      verifyNever(replacementBackend.getTargetConstraints);
    },
  );
}
