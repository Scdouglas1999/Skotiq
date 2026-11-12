// A remote client's Start, Stop and checkpoint restore act on the imaging
// host's run: the client opens no session or run record of its own, and the
// plan the host starts is the one the client's operator sees.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/in_memory_database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

SequencerStatus _status(String state) => SequencerStatus(
  state: state,
  currentNodeId: null,
  currentNodeName: null,
  progress: 0,
  message: null,
);

/// The plan the operator opened from the host's library: it carries the
/// HOST's row id, which does not exist in this client's own database.
Sequence _hostPlan() {
  const rootId = 'root-m45';
  const targetId = 'target-m45';
  return Sequence.create(
    name: 'QA M45 pair',
    nodes: {
      rootId: InstructionSetNode(
        id: rootId,
        name: 'Sequence',
        childIds: const [targetId],
      ),
      targetId: TargetHeaderNode(
        id: targetId,
        name: 'M45',
        targetName: 'M45',
        raHours: 3.79,
        decDegrees: 24.1,
      ),
    },
    rootNodeId: rootId,
    databaseId: 4,
  );
}

void main() {
  late _MockNetworkBackend host;
  late ProviderContainer container;

  setUp(() {
    host = _MockNetworkBackend();
    when(() => host.eventStream).thenAnswer((_) => const Stream.empty());
    when(() => host.serverHost).thenReturn('127.0.0.1');
    when(
      () => host.putOpenEditorSequence(
        any(),
        databaseId: any(named: 'databaseId'),
        isDirty: any(named: 'isDirty'),
      ),
    ).thenAnswer((_) async {});
    when(() => host.sequencerStart()).thenAnswer((_) async {});
    when(
      () => host.sequencerStopOnHost(
        preserveCheckpoint: any(named: 'preserveCheckpoint'),
      ),
    ).thenAnswer((_) async {});
    container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith((ref) => _FixedBackendNotifier(ref, host)),
      ],
    );
  });

  tearDown(() => container.dispose());

  test('Start sends the open plan to the host and starts the host run, '
      'opening no local session or run record', () async {
    when(
      () => host.sequencerGetStatus(),
    ).thenAnswer((_) async => _status('running'));
    container.read(currentSequenceProvider.notifier).loadSequence(_hostPlan());

    await container.read(sequenceExecutorProvider).start();

    final sent = verify(
      () => host.putOpenEditorSequence(
        captureAny(),
        databaseId: captureAny(named: 'databaseId'),
        isDirty: false,
      ),
    ).captured;
    expect((sent[0] as Map<String, dynamic>)['name'], 'QA M45 pair');
    expect(sent[1], 4);
    verify(() => host.sequencerStart()).called(1);
    expect(
      container.read(sequenceExecutionStateProvider),
      SequenceExecutionState.running,
    );
    expect(container.read(currentRunIdProvider), isNull);
    expect(container.read(sessionStateProvider).dbSessionId, isNull);
    final db = container.read(databaseProvider);
    expect(await db.select(db.sequenceRuns).get(), isEmpty);
    expect(await db.sessionsDao.getActiveSessions(), isEmpty);
  });

  test('a refused host start surfaces its reason and a later start '
      'still reaches the host', () async {
    when(
      () => host.sequencerGetStatus(),
    ).thenAnswer((_) async => _status('idle'));
    when(() => host.sequencerStart()).thenThrow(
      const ServerError(
        code: 'sequence_validation_failed',
        message: 'Target M45 is below the horizon',
        httpStatus: 400,
      ),
    );
    container.read(currentSequenceProvider.notifier).loadSequence(_hostPlan());
    final executor = container.read(sequenceExecutorProvider);

    await expectLater(
      executor.start(),
      throwsA(
        isA<ServerError>().having(
          (e) => e.message,
          'message',
          contains('below the horizon'),
        ),
      ),
    );

    when(() => host.sequencerStart()).thenAnswer((_) async {});
    await executor.start();
    verify(() => host.sequencerStart()).called(2);
  });

  test('Stop goes to the host executor with the operator checkpoint '
      'choice', () async {
    when(
      () => host.sequencerGetStatus(),
    ).thenAnswer((_) async => _status('idle'));
    container
        .read(runRecordProvider.notifier)
        .setLifecycle(SequenceExecutionState.running);

    await container
        .read(sequenceExecutorProvider)
        .stop(preserveCheckpoint: true);

    verify(() => host.sequencerStopOnHost(preserveCheckpoint: true)).called(1);
    verifyNever(() => host.sequencerStop(origin: any(named: 'origin')));
    expect(
      container.read(sequenceExecutionStateProvider),
      SequenceExecutionState.idle,
    );
  });

  test('a restored host checkpoint is continued on the host without '
      'replacing its plan', () async {
    when(() => host.resumeFromCheckpoint()).thenAnswer((_) async {});
    when(() => host.getCheckpointInfo()).thenAnswer((_) async => null);
    when(
      () => host.sequencerGetStatus(),
    ).thenAnswer((_) async => _status('running'));
    container.read(currentSequenceProvider.notifier).loadSequence(_hostPlan());
    final executor = container.read(sequenceExecutorProvider);

    await executor.restoreFromCheckpoint();
    expect(executor.hasRestoredCheckpoint, isTrue);
    await executor.start();

    verify(() => host.resumeFromCheckpoint()).called(1);
    verifyNever(
      () => host.putOpenEditorSequence(
        any(),
        databaseId: any(named: 'databaseId'),
        isDirty: any(named: 'isDirty'),
      ),
    );
    verify(() => host.sequencerStart()).called(1);
    expect(executor.hasRestoredCheckpoint, isFalse);
  });
}
