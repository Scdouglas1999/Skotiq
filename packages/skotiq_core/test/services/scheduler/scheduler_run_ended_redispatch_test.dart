// One failed run must not end the unattended night, the generated plan must be
// able to start from a parked mount, and the dawn park must answer the same
// ownership question every other engine-initiated teardown answers.
//
// All three have one shape: `_status.currentTargetId` is the LAST THING
// DISPATCHED, not "the run I own". Only a natural completion reaches the
// engine's trigger stream, so after a failure/abort/operator stop the field
// stays pinned, hysteresis reports isSwitch=false, and the autopilot keeps
// choosing the same target every tick while dispatching nothing.
//
// The sink models the executor (which run is loaded, whether ANY run is in
// flight) rather than counting calls, because both questions — "is the run I
// dispatched still active?" and "is somebody else's run active?" — have to be
// answerable to tell "my run ended, the rig is free" from "the operator took
// the rig back".
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

  int stopCount = 0;
  int parkCount = 0;
  int releaseCount = 0;

  /// How the run that left [activeRunId] ended, as the real sink reads it off
  /// the executor's terminal state.
  SchedulerRunEnding ending = SchedulerRunEnding.failed;

  /// The autopilot's own run ends by a path the engine never hears about — a
  /// failed Center, an abort. The executor settles and NOTHING is running
  /// afterwards. (An operator Stop is the same shape but a different verdict;
  /// it is covered in scheduler_operator_stop_pause_test.dart.)
  void dispatchedRunEnded() {
    activeRunId = null;
    ending = SchedulerRunEnding.failed;
  }

  /// The operator takes the rig back with a run of their own.
  void operatorTakesOver({String manualRunId = 'operator-manual-run'}) {
    activeRunId = manualRunId;
    ending = SchedulerRunEnding.stoppedByOperator;
  }

  @override
  Future<void> dispatchSequence(Sequence sequence) async {
    calls.add('dispatch');
    dispatched.add(sequence);
    activeRunId = sequence.id;
  }

  @override
  Future<void> pauseSequence() async => calls.add('pause');

  @override
  Future<void> resumeSequence() async => calls.add('resume');

  @override
  Future<void> stopSequence() async {
    stopCount++;
    calls.add('stop');
    activeRunId = null;
  }

  @override
  Future<void> parkForEndOfNight() async {
    parkCount++;
    calls.add('park');
    activeRunId = null;
  }

  @override
  Future<void> releaseSequenceOwnership() async {
    releaseCount++;
    calls.add('release');
  }

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

/// Local midnight-ish at the test site: the Sun is well down, so nothing here
/// is end-of-night.
DateTime _night() => DateTime.utc(2026, 5, 11, 4, 0);

/// Local noon at the test site: the Sun is up, i.e. the dawn-park path.
DateTime _day() => DateTime.utc(2026, 5, 11, 17, 0);

SchedulerCandidate _candidate({
  int id = 1,
  String name = 'Bode',
  double raHours = 14.0,
  double decDegrees = 30.0,
  List<String> filters = const ['L', 'R', 'G', 'B'],
}) {
  return SchedulerCandidate(
    targetId: id,
    name: name,
    raHours: raHours,
    decDegrees: decDegrees,
    userPriority: 5,
    goals: const [],
    capturedCounts: const [],
    availableFilters: filters,
    constraints: const [],
    horizonProfiles: const {},
  );
}

void main() {
  group('SchedulerEngine — a dispatched run that ended', () {
    test('the next eligible tick dispatches again after a run FAILS', () async {
      final sink = _ExecutorSink();
      final engine = SchedulerEngine(
        site: _site,
        sequenceSink: sink,
        candidateLoader: () async => [_candidate()],
        clock: _night,
      );

      await engine.start();
      expect(sink.dispatched.length, 1);
      final firstRunId = sink.dispatched.first.id;

      // The run fails 35 s in ("Center Target: Failed to center within 5.0\"").
      // The engine hears NOTHING: only SequencerEvent_Completed is mapped to a
      // trigger.
      sink.dispatchedRunEnded();

      await engine.evaluateNow(reason: 'tick');

      expect(
        sink.dispatched.length,
        2,
        reason:
            'one failed run must not end the unattended night — the target is '
            'still eligible and the rig is free, so this tick has to dispatch. '
            'calls=${sink.calls}',
      );
      expect(sink.dispatched.last.id, isNot(firstRunId));
      expect(
        engine.status.currentTargetId,
        1,
        reason: 'the newly dispatched run is the engine current target',
      );
      await engine.dispose();
    });

    test(
      'the panel stops claiming an Active target while nothing is imaging',
      () async {
        final sink = _ExecutorSink();
        var eligible = true;
        final engine = SchedulerEngine(
          site: _site,
          sequenceSink: sink,
          candidateLoader: () async => [
            eligible
                ? _candidate()
                : _candidate(name: 'Below horizon', decDegrees: -80.0),
          ],
          clock: _night,
        );
        await engine.start();
        sink.dispatchedRunEnded();
        // Nothing eligible on the next tick, so no re-dispatch can mask the
        // stale claim.
        eligible = false;

        await engine.evaluateNow(reason: 'tick');

        expect(
          engine.status.currentTargetName,
          isNull,
          reason:
              'the status panel said "Active target M42-TEST" for four minutes '
              'after the run had failed',
        );
        await engine.dispose();
      },
    );

    test(
      'a manual run the operator started is NOT dispatched over (regression)',
      () async {
        final sink = _ExecutorSink();
        final engine = SchedulerEngine(
          site: _site,
          sequenceSink: sink,
          candidateLoader: () async => [_candidate()],
          clock: _night,
        );
        await engine.start();
        expect(sink.dispatched.length, 1);

        // The autopilot's run ended AND the operator loaded one of their own.
        sink.operatorTakesOver();

        await engine.evaluateNow(reason: 'tick');

        expect(
          sink.dispatched.length,
          1,
          reason:
              'the rig is not free: re-dispatching here would slew away from '
              "the operator's own run. calls=${sink.calls}",
        );
        expect(sink.activeRunId, 'operator-manual-run');
        await engine.dispose();
      },
    );
  });

  group('SchedulerEngine — generated plan starts from a parked mount', () {
    test('the plan unparks before it slews', () {
      final engine = SchedulerEngine(
        site: _site,
        sequenceSink: _ExecutorSink(),
        clock: _night,
      );

      final seq = engine.buildSequenceForCandidate(_candidate(name: 'M42'));
      final root = seq.nodes[seq.rootNodeId]! as TargetHeaderNode;
      final children = root.childIds
          .map((id) => seq.nodes[id]!)
          .toList(growable: false);

      expect(
        children.first,
        isA<UnparkNode>(),
        reason:
            'after a safing park (dawn, weather, a manual park) every autopilot '
            'dispatch failed in 0 s on "Mount is parked. Please unpark the '
            'mount before slewing." — the generated plan has to unpark first, '
            'exactly as the manual pre-start dialog offers to. '
            'got=${children.map((n) => n.nodeType).toList()}',
      );
      expect(children[1], isA<SlewNode>());
      expect(children[2], isA<CenterNode>());
    });
  });

  group('SchedulerEngine — the dawn park asks who owns the rig', () {
    test('parks at dawn when the autopilot owns the run', () async {
      final sink = _ExecutorSink();
      var clock = _night();
      final engine = SchedulerEngine(
        site: _site,
        sequenceSink: sink,
        candidateLoader: () async => [_candidate()],
        clock: () => clock,
      );
      await engine.start();
      expect(sink.dispatched.length, 1);

      clock = _day();
      await engine.evaluateNow(reason: 'tick');

      expect(sink.parkCount, 1, reason: 'this run IS the autopilot\'s');
      await engine.dispose();
    });

    test(
      "does not yank the mount out from under the operator's own run",
      () async {
        final sink = _ExecutorSink();
        var clock = _night();
        final engine = SchedulerEngine(
          site: _site,
          sequenceSink: sink,
          candidateLoader: () async => [_candidate()],
          clock: () => clock,
        );
        await engine.start();
        expect(sink.dispatched.length, 1);

        // Same takeover state the mid-night pins use — one tick later, at dawn.
        sink.operatorTakesOver();
        clock = _day();
        await engine.evaluateNow(reason: 'tick');

        expect(
          sink.parkCount,
          0,
          reason:
              'safeTheRig(park: true) PAUSES the running sequence first, so an '
              'unowned dawn park ends the operator\'s exposure with no '
              'ownership check and no warning — the same reasoning that gates '
              'the other two engine-initiated teardowns. '
              'calls=${sink.calls}',
        );
        expect(sink.activeRunId, 'operator-manual-run');
        expect(
          engine.lastDecision!.reasoning.join(' | '),
          contains('not parking'),
          reason: 'the operator has to be told why dawn passed without a park',
        );
        await engine.dispose();
      },
    );

    test('parks at dawn when the rig is idle after a failed run', () async {
      final sink = _ExecutorSink();
      var clock = _night();
      final engine = SchedulerEngine(
        site: _site,
        sequenceSink: sink,
        candidateLoader: () async => [_candidate()],
        clock: () => clock,
      );
      await engine.start();
      sink.dispatchedRunEnded();

      clock = _day();
      await engine.evaluateNow(reason: 'tick');

      expect(
        sink.parkCount,
        1,
        reason:
            'nobody is running: the mount may still be tracking into the '
            'ground, so dawn still parks it',
      );
      expect(engine.status.state, SchedulerState.running);
      await engine.dispose();
    });
  });
}
