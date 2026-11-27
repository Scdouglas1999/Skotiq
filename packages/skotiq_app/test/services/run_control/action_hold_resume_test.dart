// A manual action Tonight runs (an autofocus, a centering) holds the run
// paused while it uses the rig. Only the action resumes what it paused: a
// Resume or a Skip from any other surface would move the run on under it.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/services/night_actions/night_action_api.dart';
import 'package:skotiq_app/services/night_actions/night_action_controller.dart';
import 'package:skotiq_app/services/night_actions/night_rig_ops.dart';
import 'package:skotiq_app/services/run_control/run_control.dart';
import 'package:skotiq_app/services/sequence_action_service.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _RecordingExecutor extends SequenceExecutor {
  _RecordingExecutor(super.ref);

  int resumeCount = 0;
  int releaseCount = 0;
  int skipCount = 0;

  @override
  Future<void> resume() async => resumeCount++;

  @override
  Future<void> releaseActionHold({required bool resume}) async {
    releaseCount++;
    if (resume) resumeCount++;
  }

  @override
  Future<void> skip() async => skipCount++;
}

const _autofocusHold = ManualActionState(
  phase: ManualActionPhase.running,
  active: ManualActionId.autofocus,
  startedRunPause: true,
);

({ProviderContainer container, _RecordingExecutor executor}) _harness(
  ManualActionState action, {
  bool held = true,
}) {
  late _RecordingExecutor executor;
  final container = ProviderContainer(overrides: [
    inMemoryDatabaseOverride(),
    sequenceExecutorProvider.overrideWith((ref) {
      executor = _RecordingExecutor(ref);
      return executor;
    }),
    runRecordProvider.overrideWith(
      (ref) => RunRecordNotifier(
        ref,
        RunRecord(
          lifecycle: SequenceExecutionState.paused,
          heldByAction: held,
        ),
      ),
    ),
    nightActionStateProvider.overrideWithValue(action),
  ]);
  container.read(sequenceExecutorProvider);
  return (container: container, executor: executor);
}

void main() {
  test('a Resume while an action holds the pause leaves the run paused',
      () async {
    final h = _harness(_autofocusHold);
    addTearDown(h.container.dispose);

    final result =
        await h.container.read(sequenceActionServiceProvider).resume();

    expect(h.executor.resumeCount, 0);
    expect(result.isSuccess, isFalse);
  });

  test('a Skip while an action holds the pause does not move the run',
      () async {
    final h = _harness(_autofocusHold);
    addTearDown(h.container.dispose);

    final result = await h.container.read(sequenceActionServiceProvider).skip();

    expect(h.executor.skipCount, 0);
    expect(result.isSuccess, isFalse);
  });

  test('the action resumes the run it paused', () async {
    final h = _harness(_autofocusHold);
    addTearDown(h.container.dispose);

    final result = await h.container.read(nightRigOpsProvider).resumeRun();

    expect(h.executor.releaseCount, 1);
    expect(h.executor.resumeCount, 1);
    expect(result.isSuccess, isTrue);
  });

  test("another client's action holds the run here too", () async {
    final h = _harness(ManualActionState.idle);
    addTearDown(h.container.dispose);

    final service = h.container.read(sequenceActionServiceProvider);
    final resume = await service.resume();
    final skip = await service.skip();

    expect(h.executor.resumeCount, 0);
    expect(h.executor.skipCount, 0);
    expect(resume.isSuccess, isFalse);
    expect(skip.isSuccess, isFalse);
    expect(
      h.container.read(nightRunPhaseProvider),
      NightRunPhase.pausedForAction,
    );
  });

  test('a run the operator paused resumes from any surface', () async {
    final h = _harness(ManualActionState.idle, held: false);
    addTearDown(h.container.dispose);

    await h.container.read(sequenceActionServiceProvider).resume();
    await h.container.read(sequenceActionServiceProvider).skip();

    expect(h.executor.resumeCount, 1);
    expect(h.executor.skipCount, 1);
  });
}
