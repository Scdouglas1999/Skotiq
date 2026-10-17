import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/disconnected_backend.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/sequence/sequence_executor.dart';
import 'package:skotiq_core/src/providers/sequence/sequence_progress.dart';

import '../mocks/mock_backend.dart';

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }

  void replaceDirectly(SkotiqBackend backend) => state = backend;
}

ProviderContainer _container(
  MockBackend backend, {
  void Function(_TestBackendNotifier notifier)? captureNotifier,
}) {
  return ProviderContainer(
    overrides: [
      backendProvider.overrideWith((ref) {
        final notifier = _TestBackendNotifier(ref, backend);
        captureNotifier?.call(notifier);
        return notifier;
      }),
    ],
  );
}

void main() {
  test(
    'backend switch is rejected while a sequence owns the current host',
    () async {
      final backend = MockBackend();
      final container = _container(backend);
      addTearDown(container.dispose);
      container.read(sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.running;

      await expectLater(
        container.read(backendProvider.notifier).disconnect(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('Stop the active sequence first'),
          ),
        ),
      );

      expect(container.read(backendProvider), same(backend));
      verifyNever(backend.dispose);
    },
  );

  test(
    'backend switch is rejected during preflight launch admission',
    () async {
      final backend = MockBackend();
      final container = _container(backend);
      addTearDown(container.dispose);
      container.read(sequenceLaunchInFlightProvider.notifier).state = true;

      await expectLater(
        container.read(backendProvider.notifier).disconnect(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('launch is in progress'),
          ),
        ),
      );

      expect(container.read(backendProvider), same(backend));
      verifyNever(backend.dispose);
    },
  );

  test(
    'a valid host switch clears settled progress from the old host',
    () async {
      final backend = MockBackend();
      final container = _container(backend);
      addTearDown(container.dispose);
      container.read(sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.completed;
      container.read(sequenceProgressProvider.notifier)
        ..updateState(SequenceExecutionState.completed)
        ..updateProgress(currentNodeId: 'old-node', completedExposures: 12);

      await container.read(backendProvider.notifier).disconnect();

      expect(container.read(backendProvider), isA<DisconnectedBackend>());
      expect(
        container.read(sequenceExecutionStateProvider),
        SequenceExecutionState.idle,
      );
      expect(
        container.read(sequenceProgressProvider),
        const SequenceProgress(),
      );
      verify(backend.dispose).called(1);
    },
  );

  test(
    'sequence executor instances are backend-scoped and never retarget',
    () async {
      final backendA = MockBackend();
      final backendB = MockBackend();
      when(backendA.hasCheckpoint).thenAnswer((_) async => false);
      when(backendB.hasCheckpoint).thenAnswer((_) async => true);
      late _TestBackendNotifier notifier;
      final container = _container(
        backendA,
        captureNotifier: (value) => notifier = value,
      );
      addTearDown(container.dispose);

      final executorA = container.read(sequenceExecutorProvider);
      expect(await executorA.hasCheckpoint(), isFalse);

      notifier.replaceDirectly(backendB);
      final executorB = container.read(sequenceExecutorProvider);
      expect(executorB, isNot(same(executorA)));

      await expectLater(executorA.hasCheckpoint(), throwsA(isA<StateError>()));
      expect(await executorB.hasCheckpoint(), isTrue);
      verify(backendA.hasCheckpoint).called(1);
      verify(backendB.hasCheckpoint).called(1);
    },
  );
}
