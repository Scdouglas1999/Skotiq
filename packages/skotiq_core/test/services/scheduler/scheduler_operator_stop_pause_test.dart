// An operator Stop of an autopilot-dispatched run PAUSES the autopilot.
//
// The engine asks the sink HOW its dispatched run ended: a failure or a natural
// completion still re-dispatches, so one failed run does not end the unattended
// night, but a stop somebody else commanded parks the autopilot in `paused`
// with `pausedByOperatorStop` set. Otherwise the next tick finds the rig free
// and dispatches the same target again, overruling the operator who stopped it.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/scheduler/scheduler_status.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/services/scheduler/scheduler_engine.dart';

class _ExecutorSink implements SchedulerSequenceSink, SchedulerRunOwnership {
  final List<Sequence> dispatched = [];
  final List<String> calls = [];

  /// Sequence id of the run the executor currently has loaded and active.
  /// Null when the executor is settled (idle / completed / failed).
  String? activeRunId;

  /// How the last run that left [activeRunId] ended — what the real sink reads
  /// off the executor's terminal state.
  SchedulerRunEnding ending = SchedulerRunEnding.unknown;

  /// The operator pressed Stop on the run the autopilot dispatched.
  void operatorStopsTheRun() {
    activeRunId = null;
    ending = SchedulerRunEnding.stoppedByOperator;
  }

  /// The run died on its own (a failed Center, a mount fault).
  void dispatchedRunFailed() {
    activeRunId = null;
    ending = SchedulerRunEnding.failed;
  }

  @override
  Future<void> dispatchSequence(Sequence sequence) async {
    calls.add('dispatch');
    dispatched.add(sequence);
    activeRunId = sequence.id;
    ending = SchedulerRunEnding.unknown;
  }

  @override
  Future<void> pauseSequence() async => calls.add('pause');

  @override
  Future<void> resumeSequence() async => calls.add('resume');

  @override
  Future<void> stopSequence() async {
    calls.add('stop');
    activeRunId = null;
  }

  @override
  Future<void> parkForEndOfNight() async {
    calls.add('park');
    activeRunId = null;
  }

  @override
  Future<void> releaseSequenceOwnership() async => calls.add('release');

  @override
  bool ownsRun(String sequenceId) => activeRunId == sequenceId;

  @override
  bool get hasActiveRun => activeRunId != null;

  @override
  SchedulerRunEnding endingFor(String sequenceId) => ending;
}

const _site = SchedulerSite(
  latitudeDegrees: 40.0,
  longitudeDegrees: -75.0,
  localOffset: Duration(hours: -5),
);

/// Local midnight-ish at the test site: the Sun is well down, so every tick
/// here is an ordinary mid-night tick.
DateTime _night() => DateTime.utc(2026, 5, 11, 4, 0);

SchedulerCandidate _candidate() {
  return SchedulerCandidate(
    targetId: 1,
    name: 'Bode',
    raHours: 14.0,
    decDegrees: 30.0,
    userPriority: 5,
    goals: const [],
    capturedCounts: const [],
    availableFilters: const ['L', 'R', 'G', 'B'],
    constraints: const [],
    horizonProfiles: const {},
  );
}

void main() {
  group('SchedulerEngine — an operator Stop pauses the autopilot', () {
    test('the engine pauses instead of re-dispatching', () async {
      final sink = _ExecutorSink();
      final engine = SchedulerEngine(
        site: _site,
        sequenceSink: sink,
        candidateLoader: () async => [_candidate()],
        clock: _night,
      );

      await engine.start();
      expect(sink.dispatched.length, 1);

      sink.operatorStopsTheRun();
      await engine.evaluateNow(reason: 'tick');

      expect(
        engine.status.state,
        SchedulerState.paused,
        reason:
            'the operator stopped the run the autopilot started — the autopilot '
            'must stand down, not overrule them. calls=${sink.calls}',
      );
      expect(
        engine.status.pausedByOperatorStop,
        isTrue,
        reason: 'the UI needs to know WHY it is paused to offer a resume',
      );
      expect(
        sink.dispatched.length,
        1,
        reason: 'nothing may be dispatched by the tick that noticed the stop',
      );
      expect(engine.status.currentTargetName, isNull);
      await engine.dispose();
    });

    test('ticks keep dispatching nothing until the operator resumes', () async {
      final sink = _ExecutorSink();
      final engine = SchedulerEngine(
        site: _site,
        sequenceSink: sink,
        candidateLoader: () async => [_candidate()],
        clock: _night,
      );

      await engine.start();
      sink.operatorStopsTheRun();
      await engine.evaluateNow(reason: 'tick');

      await engine.evaluateNow(reason: 'tick');
      await engine.evaluateNow(reason: 'tick');

      expect(
        sink.dispatched.length,
        1,
        reason:
            'the silent re-dispatch arrived ~44 s after the Stop: every tick '
            'while paused must leave the rig alone. calls=${sink.calls}',
      );
      expect(engine.status.state, SchedulerState.paused);
      await engine.dispose();
    });

    test('resume hands the night back to the autopilot', () async {
      final sink = _ExecutorSink();
      final engine = SchedulerEngine(
        site: _site,
        sequenceSink: sink,
        candidateLoader: () async => [_candidate()],
        clock: _night,
      );

      await engine.start();
      sink.operatorStopsTheRun();
      await engine.evaluateNow(reason: 'tick');

      await engine.resume();

      expect(engine.status.state, SchedulerState.running);
      expect(engine.status.pausedByOperatorStop, isFalse);
      expect(
        sink.dispatched.length,
        2,
        reason: 'resuming re-dispatches the winner. calls=${sink.calls}',
      );
      expect(
        sink.calls,
        isNot(contains('resume')),
        reason:
            'there is no paused run to resume — the operator stopped it — and '
            'resumeSequence would throw against a settled executor',
      );
      await engine.dispose();
    });

    test('a run that FAILED still re-dispatches', () async {
      final sink = _ExecutorSink();
      final engine = SchedulerEngine(
        site: _site,
        sequenceSink: sink,
        candidateLoader: () async => [_candidate()],
        clock: _night,
      );

      await engine.start();
      sink.dispatchedRunFailed();

      await engine.evaluateNow(reason: 'tick');

      expect(
        sink.dispatched.length,
        2,
        reason:
            'one failed run must not end the unattended night — nobody stopped '
            'anything, so there is no operator decision to respect',
      );
      expect(engine.status.state, SchedulerState.running);
      expect(engine.status.pausedByOperatorStop, isFalse);
      await engine.dispose();
    });

    test('a Start after the pause clears the operator-stop flag', () async {
      final sink = _ExecutorSink();
      final engine = SchedulerEngine(
        site: _site,
        sequenceSink: sink,
        candidateLoader: () async => [_candidate()],
        clock: _night,
      );

      await engine.start();
      sink.operatorStopsTheRun();
      await engine.evaluateNow(reason: 'tick');
      await engine.stop();

      await engine.start();

      expect(engine.status.state, SchedulerState.running);
      expect(engine.status.pausedByOperatorStop, isFalse);
      await engine.dispose();
    });
  });
}
