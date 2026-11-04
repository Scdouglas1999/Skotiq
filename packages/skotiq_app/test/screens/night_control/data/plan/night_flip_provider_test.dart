// SY-28 / SY-33 (sync night 2026-11-03). During a flip that kept failing
// after the pier change, a client linked to the host showed only "Running
// 28%": no attempt, no failure, no next try, although the host sent a
// progress event per failed attempt ("attempt 2/4 failed, retrying in
// 60s"). After the flip had moved the mount to pier east and the host said
// it must not flip again, Tonight still offered "Flip now" and announced a
// flip in Coming up and on the altitude chart.
//
// The events are built the way a linked client gets them: the host's wire
// envelope rebuilt by `bridgeEventFromCoreEvent`.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/actions/manual_action_gating.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_flip_provider.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_plan_inputs.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_run_phase_provider.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_core/skotiq_core.dart' hide TwilightTimes;
import 'package:skotiq_core/skotiq_core_events.dart' as sk_events;
import 'package:skotiq_core/src/backend/bridge_event_mapper.dart';

class _Mount extends MountStateNotifier {
  _Mount(super.ref) {
    state = const MountState(
      connectionState: DeviceConnectionState.connected,
      isTracking: true,
      sideOfPier: 'West',
    );
  }

  void pier(String side) => state = state.copyWith(sideOfPier: side);
}

class _Progress extends SequenceProgressNotifier {
  _Progress(String? message) {
    state = SequenceProgress(message: message);
  }
}

final _t0 = DateTime(2026, 11, 3, 22, 37, 54);

sk_events.SkotiqEvent _wire(
  DateTime at,
  String eventType,
  Map<String, dynamic> data, {
  EventSeverity severity = EventSeverity.info,
}) =>
    bridgeEventFromCoreEvent(
      SkotiqEvent(
        timestamp: at.millisecondsSinceEpoch,
        severity: severity,
        category: EventCategory.sequencer,
        eventType: eventType,
        data: data,
      ),
    );

sk_events.SkotiqEvent _triggerFired(DateTime at) => _wire(at, 'TriggerFired', {
      'trigger_id': 'meridian_flip',
      'trigger_name': 'Meridian Flip',
      'action': 'MeridianFlip(MeridianFlipConfig { max_retries: 3 })',
    });

sk_events.SkotiqEvent _attemptFailed(DateTime at, int n, int delay) =>
    _wire(at, 'InstructionProgress', {
      'node_id': 'trigger:meridian_flip',
      'instruction': 'MeridianFlip',
      'progress_percent': 25.0 * n,
      'detail': 'attempt $n/4 failed, retrying in ${delay}s',
    });

sk_events.SkotiqEvent _outcome(DateTime at, String outcome) => _wire(
    at,
    'MeridianFlipOutcome',
    {
      'outcome': outcome,
      'target_name': 'NGC 7814',
      'new_pier_side': outcome == 'success' ? 'East' : 'Unknown',
      'duration_secs': 0.0,
      'attempts': 4,
      'failed_steps': <String>[],
      if (outcome != 'success') 'error': 'Plate solve failed: no solution',
    },
    severity:
        outcome == 'success' ? EventSeverity.info : EventSeverity.critical);

class _Rig {
  _Rig({String? message, DateTime? now}) {
    container = ProviderContainer(
      overrides: [
        clockProvider.overrideWithValue(const SystemClock()),
        nightNowProvider.overrideWithValue((now ?? _t0).toUtc()),
        nightRunPhaseProvider.overrideWithValue(NightRunPhase.running),
        mountStateProvider.overrideWith(_Mount.new),
        sequenceProgressProvider.overrideWith((ref) => _Progress(message)),
        eventHistoryProvider.overrideWith((ref) => EventHistoryNotifier()),
      ],
    );
    container.listen(nightFlipProvider, (_, __) {});
  }

  late final ProviderContainer container;

  void emit(sk_events.SkotiqEvent event) =>
      container.read(eventHistoryProvider.notifier).addEvent(event);

  void pier(String side) =>
      (container.read(mountStateProvider.notifier) as _Mount).pier(side);

  NightFlipState get flip => container.read(nightFlipProvider);
  NightFlipStepVm? get step => container.read(nightFlipStepProvider);
}

void main() {
  test('no flip under way, no row', () {
    final rig = _Rig();
    addTearDown(rig.container.dispose);
    expect(rig.step, isNull);
  });

  test('the trigger firing shows the flip with the run message', () {
    final rig = _Rig(message: 'Meridian flip: slewing to the east side');
    addTearDown(rig.container.dispose);
    rig.emit(_triggerFired(_t0));

    expect(rig.step?.status, PlanStepStatus.active);
    expect(
      rig.step?.detail,
      const NightText.literal('Meridian flip: slewing to the east side'),
    );
  });

  test('a failed attempt shows the count and the next try', () {
    final rig = _Rig(now: _t0.add(const Duration(minutes: 4, seconds: 40)));
    addTearDown(rig.container.dispose);
    rig.emit(_triggerFired(_t0));
    // 22:42:26 "attempt 2/4 failed, retrying in 60s": next try 22:43:26.
    rig.emit(_attemptFailed(DateTime(2026, 11, 3, 22, 42, 26), 2, 60));

    expect(rig.step?.status, PlanStepStatus.active);
    expect(
      rig.step?.detail,
      const NightText(
        'nightCtlFlipAttemptFailed',
        params: {'attempt': '2', 'max': '4', 'time': '22:43'},
      ),
    );
  });

  test('past the wait, the next attempt is under way', () {
    final rig = _Rig(now: DateTime(2026, 11, 3, 22, 44));
    addTearDown(rig.container.dispose);
    rig.emit(_triggerFired(_t0));
    rig.emit(_attemptFailed(DateTime(2026, 11, 3, 22, 42, 26), 2, 60));

    expect(
      rig.step?.detail,
      const NightText('nightCtlFlipAttempt',
          params: {'attempt': '3', 'max': '4'}),
    );
  });

  test('a client that missed the trigger learns of the flip from its progress',
      () {
    final rig = _Rig();
    addTearDown(rig.container.dispose);
    rig.emit(_attemptFailed(_t0, 1, 30));
    expect(rig.flip.inProgress, isTrue);
    expect(rig.step?.status, PlanStepStatus.active);
  });

  test('a failed flip stays on the list until the run is resumed', () {
    final rig = _Rig();
    addTearDown(rig.container.dispose);
    rig.emit(_triggerFired(_t0));
    rig.emit(_outcome(DateTime(2026, 11, 3, 22, 51, 28), 'failed'));

    expect(rig.step?.status, PlanStepStatus.failed);
    expect(
      rig.step?.detail,
      const NightText(
        'nightCtlFlipFailed',
        params: {'attempts': '4', 'time': '22:51'},
      ),
    );

    rig.emit(_wire(DateTime(2026, 11, 3, 22, 52, 7), 'Resumed', const {}));
    expect(rig.step, isNull);
  });

  test('a successful flip leaves the list and is done for this transit', () {
    final rig = _Rig();
    addTearDown(rig.container.dispose);
    rig.emit(_triggerFired(_t0));
    rig.emit(_outcome(_t0.add(const Duration(minutes: 3)), 'success'));

    expect(rig.step, isNull);
    expect(rig.flip.doneForThisTransit, isTrue);
  });

  test(
      'the mount taking the other side of the pier during the flip makes it '
      'done, even when the flip then fails', () {
    final rig = _Rig();
    addTearDown(rig.container.dispose);
    rig.emit(_triggerFired(_t0));
    expect(rig.flip.doneForThisTransit, isFalse);

    rig.pier('East');
    expect(rig.flip.doneForThisTransit, isTrue);

    rig.emit(_outcome(DateTime(2026, 11, 3, 22, 51, 28), 'failed'));
    expect(rig.flip.doneForThisTransit, isTrue);
    expect(rig.step?.detail.key, 'nightCtlFlipFailedMoved');
  });

  test('a pier change with no flip under way is not a flip', () {
    final rig = _Rig();
    addTearDown(rig.container.dispose);
    rig.pier('East');
    expect(rig.flip.doneForThisTransit, isFalse);
  });

  test('a new run starts with no flip behind it', () {
    final rig = _Rig();
    addTearDown(rig.container.dispose);
    final execution =
        rig.container.read(sequenceExecutionStateProvider.notifier);
    execution.state = SequenceExecutionState.running;
    rig.emit(_triggerFired(_t0));
    rig.pier('East');
    expect(rig.flip.doneForThisTransit, isTrue);

    execution.state = SequenceExecutionState.failed;
    execution.state = SequenceExecutionState.running;
    expect(rig.flip.doneForThisTransit, isFalse);
    expect(rig.flip.inProgress, isFalse);
  });

  test('the next flip trigger starts over', () {
    final rig = _Rig();
    addTearDown(rig.container.dispose);
    rig.emit(_triggerFired(_t0));
    rig.pier('East');
    expect(rig.flip.doneForThisTransit, isTrue);

    rig.emit(_triggerFired(_t0.add(const Duration(hours: 3))));
    expect(rig.flip.doneForThisTransit, isFalse);
    expect(rig.flip.inProgress, isTrue);
  });

  group('Flip now', () {
    NightActionInputs inputs({required bool flipDone}) => NightActionInputs(
          canCommand: true,
          runState: SequenceExecutionState.running,
          action: ManualActionState.idle,
          mountConnected: true,
          mountTracking: true,
          flipDone: flipDone,
        );

    test('is offered while the flip is still ahead', () {
      final shown = inputs(flipDone: false);
      expect(visibleManualActions(shown), contains(ManualActionId.flip));
      expect(manualActionDisabledReason(shown, ManualActionId.flip), isNull);
    });

    test('is gone once the mount flipped this transit', () {
      final done = inputs(flipDone: true);
      expect(visibleManualActions(done), isNot(contains(ManualActionId.flip)));
      expect(
        manualActionDisabledReason(done, ManualActionId.flip),
        const NightText('nightActWhyFlipDone'),
      );
    });
  });
}
