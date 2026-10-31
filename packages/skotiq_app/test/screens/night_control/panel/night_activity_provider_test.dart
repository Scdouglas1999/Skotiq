import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_plan_inputs.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_run_phase_provider.dart';
import 'package:skotiq_app/screens/night_control/data/plan/plan_steps_provider.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_app/screens/night_control/panel/overview/night_activity_provider.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  test('run lifecycle wins over leftover hardware activity', () {
    for (final (phase, execution, expected) in [
      (
        NightRunPhase.ready,
        SequenceExecutionState.idle,
        NightActivityKind.ready
      ),
      (
        NightRunPhase.armed,
        SequenceExecutionState.idle,
        NightActivityKind.ready
      ),
      (
        NightRunPhase.pausedByUser,
        SequenceExecutionState.paused,
        NightActivityKind.paused
      ),
      (
        NightRunPhase.stopping,
        SequenceExecutionState.finalizing,
        NightActivityKind.stopping
      ),
      (
        NightRunPhase.finished,
        SequenceExecutionState.completed,
        NightActivityKind.finished
      ),
      (
        NightRunPhase.finished,
        SequenceExecutionState.failed,
        NightActivityKind.failed
      ),
    ]) {
      expect(
          resolveNightActivity(
              phase: phase,
              execution: execution,
              autofocusRunning: true,
              exposing: true,
              flipping: true),
          expected);
    }
  });

  test('nested focus, centering and flip own their camera exposures', () {
    final exposure = ExposureNode(id: 'capture', durationSecs: 180, count: 60);
    for (final (detail, expected) in [
      ('Autofocus', NightActivityKind.focus),
      ('Center', NightActivityKind.center),
      ('Exposure', NightActivityKind.capture),
    ]) {
      expect(
          resolveNightActivity(
              phase: NightRunPhase.running,
              execution: SequenceExecutionState.running,
              node: exposure,
              detailKind: detail,
              exposing: true),
          expected);
    }
    for (final (step, expected) in [
      (FlipStep.slewingToTarget, NightActivityKind.flip),
      (FlipStep.plateSolvingAndCentering, NightActivityKind.center),
      (FlipStep.refocusing, NightActivityKind.focus),
      (FlipStep.settling, NightActivityKind.guide),
    ]) {
      expect(
          resolveNightActivity(
              phase: NightRunPhase.running,
              execution: SequenceExecutionState.running,
              node: exposure,
              exposing: true,
              flipping: true,
              flipStep: step),
          expected);
    }
  });

  test('a paused manual action gets its operation panel', () {
    expect(
        resolveNightActivity(
            phase: NightRunPhase.pausedForAction,
            execution: SequenceExecutionState.paused,
            manualAction: ManualActionId.autofocus),
        NightActivityKind.focus);
    expect(
        resolveNightActivity(
            phase: NightRunPhase.pausedForAction,
            execution: SequenceExecutionState.paused,
            manualAction: ManualActionId.center),
        NightActivityKind.center);
  });

  test('real provider follows sequence progress and ignores background solves',
      () {
    final node = ExposureNode(id: 'capture', durationSecs: 180, count: 60);
    final container = ProviderContainer(overrides: [
      activeEquipmentProfileProvider.overrideWithValue(null),
      nightRunPhaseProvider.overrideWithValue(NightRunPhase.running),
      sequenceExecutionStateProvider
          .overrideWith((ref) => SequenceExecutionState.running),
      nightActiveStepProvider.overrideWithValue(NightPlanEntry(
          node: node, depth: 0, multiplier: 1, openEnded: false)),
    ]);
    addTearDown(container.dispose);
    final subscription = container.listen(nightActivityProvider, (_, next) {});
    addTearDown(subscription.close);
    final progress = container.read(sequenceProgressProvider.notifier);
    progress.updateProgress(currentNodeId: node.id, currentTarget: 'M74');
    container.read(cameraStateProvider.notifier).setExposing(true);
    container
        .read(exposureProgressProvider.notifier)
        .updateProgress(90, 90, 50);
    expect(
        container.read(nightActivityProvider).kind, NightActivityKind.capture);
    expect(container.read(nightActivityProvider).progress, 0.5);
    container.read(plateSolveStateProvider.notifier).state =
        const PlateSolveState(isSolving: true);
    expect(
        container.read(nightActivityProvider).kind, NightActivityKind.capture);
    progress.updateNodeStructuredProgress(node.id, 40,
        const UnknownInstructionProgressDetail(kind: 'Autofocus', rawJson: {}));
    expect(container.read(nightActivityProvider).kind, NightActivityKind.focus);
    progress.updateNodeStatus(node.id, NodeStatus.success);
    expect(
        container.read(nightActivityProvider).kind, NightActivityKind.capture);
    progress.updateNodeStatus(node.id, NodeStatus.running);
    progress.updateNodeStructuredProgress(node.id, 100,
        const UnknownInstructionProgressDetail(kind: 'Autofocus', rawJson: {}));
    expect(
        container.read(nightActivityProvider).kind, NightActivityKind.capture);
    container.read(exposureProgressProvider.notifier).startDownload();
    expect(container.read(nightActivityProvider).progress, isNull);
    container.read(sequenceExecutionStateProvider.notifier).state =
        SequenceExecutionState.recovering;
    expect(
        container.read(nightActivityProvider).kind, NightActivityKind.recovery);
  });

  test('centering transitions use current telemetry, never an old solve result',
      () {
    final container = ProviderContainer(overrides: [
      activeEquipmentProfileProvider.overrideWithValue(null),
      nightRunPhaseProvider.overrideWithValue(NightRunPhase.running),
      sequenceExecutionStateProvider
          .overrideWith((ref) => SequenceExecutionState.running),
      nightActiveStepProvider.overrideWithValue(NightPlanEntry(
          node: CenterNode(id: 'center'),
          depth: 0,
          multiplier: 1,
          openEnded: false)),
    ]);
    addTearDown(container.dispose);
    final subscription = container.listen(nightActivityProvider, (_, next) {});
    addTearDown(subscription.close);
    final p = container.read(sequenceProgressProvider.notifier);
    p.updateProgress(currentNodeId: 'center');
    p.updateNodeStructuredProgress(
        'center',
        20,
        const UnknownInstructionProgressDetail(kind: 'Center', rawJson: {
          'attempt': 2,
          'max_attempts': 5,
          'last_separation_arcsec': 35.4,
        }));
    var vm = container.read(nightActivityProvider);
    expect(vm.kind, NightActivityKind.center);
    expect(vm.metrics.map((m) => m.value), contains('35.4″'));
    container.read(centeringStatusProvider.notifier).state =
        const CenteringStatus(
            state: CenteringState.completed,
            currentIteration: 4,
            maxIterations: 10,
            currentOffsetArcsec: 1.2,
            iterationHistory: []);
    vm = container.read(nightActivityProvider);
    expect(vm.metrics.map((m) => m.value), contains('35.4″'));
    expect(vm.metrics.map((m) => m.value), isNot(contains('1.2″')));
    container.read(cameraStateProvider.notifier).setExposing(true);
    expect(container.read(nightActivityProvider).title.key,
        'nightActivityCenterExposure');
    container.read(cameraStateProvider.notifier).setExposing(false);
    container.read(mountStateProvider.notifier).setSlewing(true);
    expect(container.read(nightActivityProvider).title.key,
        'nightActivityCenterSlew');
    container.read(mountStateProvider.notifier).setSlewing(false);
    expect(
        container.read(nightActivityProvider).title.key, 'nightActivityCenter');
    p.updateNodeStatus('center', NodeStatus.success);
    expect(
        container.read(nightActivityProvider).kind, NightActivityKind.waiting);
  });
  test('native trigger flip uses structured progress outside the plan tree',
      () {
    final container = ProviderContainer(overrides: [
      activeEquipmentProfileProvider.overrideWithValue(null),
      nightRunPhaseProvider.overrideWithValue(NightRunPhase.running),
      sequenceExecutionStateProvider
          .overrideWith((ref) => SequenceExecutionState.running),
      nightActiveStepProvider.overrideWithValue(NightPlanEntry(
          node: ExposureNode(id: 'exposure'),
          depth: 0,
          multiplier: 1,
          openEnded: true)),
    ]);
    addTearDown(container.dispose);
    final progress = container.read(sequenceProgressProvider.notifier);
    progress.updateProgress(currentNodeId: 'trigger:flip');
    progress.updateNodeStructuredProgress(
        'trigger:flip',
        50,
        InstructionProgressDetail.fromStructuredData(
            detailKind: 'MeridianFlip',
            detailJson: const {'phase': 'Verifying tracking'}));
    final vm = container.read(nightActivityProvider);
    expect(vm.kind, NightActivityKind.flip);
    expect(vm.progress, 0.5);
    expect(vm.detail, 'Verifying tracking');
    progress.updateNodeStatus('trigger:flip', NodeStatus.success);
    expect(
        container.read(nightActivityProvider).kind, NightActivityKind.capture);
  });

  test('paused and failed lifecycle never inherits a stale flip title', () {
    final phase = StateProvider((ref) => NightRunPhase.pausedByUser);
    final container = ProviderContainer(overrides: [
      activeEquipmentProfileProvider.overrideWithValue(null),
      nightRunPhaseProvider.overrideWith((ref) => ref.watch(phase)),
      nightActiveStepProvider.overrideWithValue(null),
      sequenceExecutionStateProvider
          .overrideWith((ref) => SequenceExecutionState.paused),
    ]);
    addTearDown(container.dispose);
    container.read(flipExecutionStateProvider.notifier).state =
        FlipExecutionState.executing;
    container.read(flipCurrentStepProvider.notifier).state =
        FlipStep.slewingToTarget;
    expect(
        container.read(nightActivityProvider).title.key, 'nightActivityPaused');
    expect(container.read(nightActivityProvider).context, isNull);
    container.read(phase.notifier).state = NightRunPhase.stopping;
    container.read(sequenceExecutionStateProvider.notifier).state =
        SequenceExecutionState.cleanupFailed;
    expect(
        container.read(nightActivityProvider).kind, NightActivityKind.failed);
    expect(container.read(nightActivityProvider).context, isNull);
  });
}
