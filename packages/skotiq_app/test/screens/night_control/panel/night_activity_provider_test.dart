import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_plan_inputs.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_run_phase_provider.dart';
import 'package:skotiq_app/screens/night_control/data/plan/plan_steps_provider.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_app/screens/night_control/panel/overview/night_activity_provider.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

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
      (
        const AutofocusInstructionProgressDetail(step: 2, totalSteps: 9),
        NightActivityKind.focus
      ),
      (
        const CenterInstructionProgressDetail(attempt: 1, maxAttempts: 3),
        NightActivityKind.center
      ),
      (
        const ExposureInstructionProgressDetail(
            frame: 1, total: 60, durationSecs: 180),
        NightActivityKind.capture
      ),
    ]) {
      expect(
          resolveNightActivity(
              phase: NightRunPhase.running,
              execution: SequenceExecutionState.running,
              node: exposure,
              detail: detail,
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
      nightActiveStepProvider.overrideWithValue(NightPlanEntry(
          node: node, depth: 0, multiplier: 1, openEnded: false)),
    ]);
    addTearDown(container.dispose);
    container
        .read(runRecordProvider.notifier)
        .setLifecycle(SequenceExecutionState.running);
    final subscription = container.listen(nightActivityProvider, (_, next) {});
    addTearDown(subscription.close);
    final progress = container.read(runRecordProvider.notifier);
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
        const AutofocusInstructionProgressDetail(step: 2, totalSteps: 9));
    expect(container.read(nightActivityProvider).kind, NightActivityKind.focus);
    progress.updateNodeStatus(node.id, NodeStatus.success);
    expect(
        container.read(nightActivityProvider).kind, NightActivityKind.capture);
    progress.updateNodeStatus(node.id, NodeStatus.running);
    progress.updateNodeStructuredProgress(node.id, 100,
        const AutofocusInstructionProgressDetail(step: 9, totalSteps: 9));
    expect(
        container.read(nightActivityProvider).kind, NightActivityKind.capture);
    container.read(exposureProgressProvider.notifier).startDownload();
    expect(container.read(nightActivityProvider).progress, isNull);
    container
        .read(runRecordProvider.notifier)
        .setLifecycle(SequenceExecutionState.recovering);
    expect(
        container.read(nightActivityProvider).kind, NightActivityKind.recovery);
  });

  test('a run frame the camera exposes reads as capturing, with progress',
      () {
    // A run's frame is taken by the native camera, not the app's capture
    // service; the host follows it from the camera's own events.
    final node = ExposureNode(id: 'capture', durationSecs: 180, count: 60);
    final container = ProviderContainer(overrides: [
      activeEquipmentProfileProvider.overrideWithValue(null),
      nightRunPhaseProvider.overrideWithValue(NightRunPhase.running),
      nightActiveStepProvider.overrideWithValue(NightPlanEntry(
          node: node, depth: 0, multiplier: 1, openEnded: false)),
    ]);
    addTearDown(container.dispose);
    final progress = container.read(runRecordProvider.notifier);
    progress.setLifecycle(SequenceExecutionState.running);
    final subscription = container.listen(nightActivityProvider, (_, next) {});
    addTearDown(subscription.close);
    progress.updateProgress(currentNodeId: node.id);
    progress.updateNodeStructuredProgress(
        node.id,
        10,
        const ExposureInstructionProgressDetail(
            frame: 3, total: 60, durationSecs: 180));
    SkotiqEvent camera(String type, Map<String, dynamic> data) => SkotiqEvent(
          timestamp: 0,
          category: EventCategory.imaging,
          eventType: type,
          severity: EventSeverity.info,
          data: data,
        );
    followHostCameraExposure(
        container, camera('ExposureStarted', {'duration_secs': 180.0, 'frame_type': 'light'}));
    followHostCameraExposure(container,
        camera('ExposureProgress', {'progress': 0.25, 'remainingSecs': 135.0}));
    final vm = container.read(nightActivityProvider);
    expect(vm.kind, NightActivityKind.capture);
    expect(vm.title.key, 'nightActivityCapture');
    expect(vm.progress, closeTo(0.25, 1e-9));
  });

  test('centering transitions use current telemetry, never an old solve result',
      () {
    final container = ProviderContainer(overrides: [
      activeEquipmentProfileProvider.overrideWithValue(null),
      nightRunPhaseProvider.overrideWithValue(NightRunPhase.running),
      nightActiveStepProvider.overrideWithValue(NightPlanEntry(
          node: CenterNode(id: 'center'),
          depth: 0,
          multiplier: 1,
          openEnded: false)),
    ]);
    addTearDown(container.dispose);
    container
        .read(runRecordProvider.notifier)
        .setLifecycle(SequenceExecutionState.running);
    final subscription = container.listen(nightActivityProvider, (_, next) {});
    addTearDown(subscription.close);
    final p = container.read(runRecordProvider.notifier);
    p.updateProgress(currentNodeId: 'center');
    p.updateNodeStructuredProgress(
        'center',
        20,
        const CenterInstructionProgressDetail(
            attempt: 2, maxAttempts: 5, lastSeparationArcsec: 35.4));
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
      nightActiveStepProvider.overrideWithValue(NightPlanEntry(
          node: ExposureNode(id: 'exposure'),
          depth: 0,
          multiplier: 1,
          openEnded: true)),
    ]);
    addTearDown(container.dispose);
    final progress = container.read(runRecordProvider.notifier);
    progress.setLifecycle(SequenceExecutionState.running);
    progress.updateProgress(currentNodeId: 'trigger:flip');
    progress.updateNodeStructuredProgress(
        'trigger:flip',
        50,
        InstructionProgressDetail.fromStructuredData(
            detailKind: kMeridianFlipProgressDetailKind,
            detailJson: const {
              'StepStarted': {
                'step': 'VerifyingPierSide',
                'step_index': 3,
                'total_steps': 9,
              },
            }));
    progress.updateNodeProgress('trigger:flip', 50, 'Meridian flip');
    final vm = container.read(nightActivityProvider);
    expect(vm.kind, NightActivityKind.flip);
    expect(vm.progress, 0.5);
    expect(vm.detail, 'Meridian flip');
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
    ]);
    addTearDown(container.dispose);
    container
        .read(runRecordProvider.notifier)
        .setLifecycle(SequenceExecutionState.paused);
    container.read(flipExecutionStateProvider.notifier).state =
        FlipExecutionState.executing;
    container.read(flipCurrentStepProvider.notifier).state =
        FlipStep.slewingToTarget;
    expect(
        container.read(nightActivityProvider).title.key, 'nightActivityPaused');
    expect(container.read(nightActivityProvider).context, isNull);
    container.read(phase.notifier).state = NightRunPhase.stopping;
    container
        .read(runRecordProvider.notifier)
        .setLifecycle(SequenceExecutionState.cleanupFailed);
    expect(
        container.read(nightActivityProvider).kind, NightActivityKind.failed);
    expect(container.read(nightActivityProvider).context, isNull);
  });
}
