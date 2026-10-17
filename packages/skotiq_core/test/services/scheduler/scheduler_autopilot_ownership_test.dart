// Who owns the run the autopilot is about to stop?
//
// Two adjacent inputs a naive ownership check does not survive:
//
//   1. the operator's Stop racing a dispatch that is still STARTING a run
//      (rather than landing mid-run), which leaves an orphan sequence exposing
//      with the autopilot showing Idle; and
//   2. the autopilot's own run ending by any path the engine never hears about
//      (operator Stop, abort, failure — only a natural completion reaches the
//      trigger stream), after which `currentTargetId != null` still claims
//      ownership and the next no-eligible tick stops the operator's manual
//      sequence.
//
// The sink here models the executor rather than merely counting calls: it
// tracks WHICH run is loaded, so `ownsRun` can be answered the way the real
// `_ExecutorSequenceSink` answers it (owner + loaded plan id + run active).
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/scheduler/scheduler_status.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/services/scheduler/scheduler_engine.dart';

/// Executor stand-in: remembers the run it was given and whether it is still
/// the active one, which is exactly what ownership asks about.
class _ExecutorSink implements SchedulerSequenceSink, SchedulerRunOwnership {
  final List<Sequence> dispatched = [];
  final List<String> calls = [];

  /// Sequence id of the run the executor currently has loaded and active.
  String? activeRunId;

  /// When set, `dispatchSequence` blocks on it — the window in which the
  /// executor is starting a run and the operator can still press Stop.
  Completer<void>? gate;

  int stopCount = 0;
  int parkCount = 0;
  int releaseCount = 0;

  /// The operator stops the run (or it fails/aborts) WITHOUT the engine ever
  /// hearing about it, then loads something of their own.
  void operatorTakesOver({String? manualRunId}) {
    activeRunId = manualRunId;
  }

  @override
  Future<void> dispatchSequence(Sequence sequence) async {
    calls.add('dispatch-begin');
    final g = gate;
    if (g != null) await g.future;
    dispatched.add(sequence);
    activeRunId = sequence.id;
    calls.add('dispatch-end');
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

  /// Every takeover in this file is the operator's doing.
  @override
  SchedulerRunEnding endingFor(String sequenceId) =>
      SchedulerRunEnding.stoppedByOperator;
}

const _site = SchedulerSite(
  latitudeDegrees: 40.0,
  longitudeDegrees: -75.0,
  localOffset: Duration(hours: -5),
);

DateTime _fixedNow() => DateTime.utc(2026, 5, 11, 4, 0);

SchedulerCandidate _candidate({
  required int id,
  required String name,
  required double raHours,
  required double decDegrees,
}) {
  return SchedulerCandidate(
    targetId: id,
    name: name,
    raHours: raHours,
    decDegrees: decDegrees,
    userPriority: 5,
    goals: const [],
    capturedCounts: const [],
    availableFilters: const ['L', 'R', 'G', 'B'],
    constraints: const [],
    horizonProfiles: const {},
  );
}

void main() {
  group('SchedulerEngine — autopilot run ownership', () {
    test(
      'stop() during an in-flight dispatch does not leave an orphan run',
      () async {
        final sink = _ExecutorSink()..gate = Completer<void>();
        final engine = SchedulerEngine(
          site: _site,
          sequenceSink: sink,
          candidateLoader: () async => [
            _candidate(id: 1, name: 'Bode', raHours: 14.0, decDegrees: 30.0),
          ],
          clock: _fixedNow,
        );

        final starting = engine.start();
        // Let the evaluation reach dispatchSequence and block inside it.
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(sink.calls, contains('dispatch-begin'));
        expect(sink.calls, isNot(contains('dispatch-end')));

        // The operator presses "Stop autopilot" while the executor is still
        // starting the run.
        final stopping = engine.stop();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        // The executor now finishes starting: a run exists from here on.
        sink.gate!.complete();
        await starting;
        await stopping;

        final stopIdx = sink.calls.indexOf('stop');
        final startedIdx = sink.calls.indexOf('dispatch-end');
        expect(
          startedIdx,
          greaterThanOrEqualTo(0),
          reason: 'the dispatch did start a run',
        );
        expect(
          stopIdx,
          greaterThan(startedIdx),
          reason:
              'the run the autopilot started must not outlive the stop meant '
              'to end it (orphan run). calls=${sink.calls}',
        );
        expect(
          sink.activeRunId,
          isNull,
          reason: 'nothing may still be exposing once the autopilot is idle',
        );
        expect(
          engine.status.currentTargetId,
          isNull,
          reason: 'a stopped autopilot must not claim it owns a target',
        );
        expect(engine.status.state, SchedulerState.idle);
        expect(
          sink.releaseCount,
          greaterThanOrEqualTo(1),
          reason: 'the editor slot goes back to the operator',
        );
        await engine.dispose();
      },
    );

    test(
      'a run the autopilot no longer owns is never stopped by a tick',
      () async {
        final sink = _ExecutorSink();
        var eligible = true;
        final engine = SchedulerEngine(
          site: _site,
          sequenceSink: sink,
          candidateLoader: () async => [
            eligible
                ? _candidate(id: 1, name: 'Bode', raHours: 14.0, decDegrees: 30)
                : _candidate(
                    id: 1,
                    name: 'Below horizon',
                    raHours: 14.0,
                    decDegrees: -80.0,
                  ),
          ],
          clock: _fixedNow,
        );
        await engine.start();
        expect(sink.dispatched.length, 1);

        // The operator presses Stop in the sequencer (or the run fails/aborts)
        // and then starts a sequence of their own. Nothing about any of this
        // reaches the engine — that is the point: SequencerEvent_Stopped is not
        // mapped to a trigger, so `currentTargetId` stays set.
        sink.operatorTakesOver(manualRunId: 'operator-manual-run');
        expect(engine.status.currentTargetId, isNotNull);

        eligible = false;
        await engine.evaluateNow(reason: 'tick');

        expect(
          sink.stopCount,
          0,
          reason:
              'the autopilot no longer has a run of its own; this stop would '
              "land on the operator's manual sequence. calls=${sink.calls}",
        );
        expect(
          sink.activeRunId,
          'operator-manual-run',
          reason: "the operator's run is still running",
        );
        await engine.dispose();
      },
    );

    test(
      'a tick still stops the autopilot\'s OWN run when nothing is eligible',
      () async {
        final sink = _ExecutorSink();
        var eligible = true;
        final engine = SchedulerEngine(
          site: _site,
          sequenceSink: sink,
          candidateLoader: () async => [
            eligible
                ? _candidate(
                    id: 1,
                    name: 'Bode',
                    raHours: 14.0,
                    decDegrees: 30.0,
                  )
                : _candidate(
                    id: 1,
                    name: 'Below horizon',
                    raHours: 14.0,
                    decDegrees: -80.0,
                  ),
          ],
          clock: _fixedNow,
        );
        await engine.start();
        expect(sink.dispatched.length, 1);
        expect(sink.activeRunId, sink.dispatched.first.id);

        eligible = false;
        await engine.evaluateNow(reason: 'tick');

        expect(
          sink.stopCount,
          1,
          reason: 'this run IS the autopilot\'s, so the tick may end it',
        );
        expect(
          engine.lastDecision!.reasoning,
          contains(allOf(contains('Stopped'), contains('Bode'))),
        );
        await engine.dispose();
      },
    );

    test('stop() leaves a run the operator owns alone', () async {
      final sink = _ExecutorSink();
      final engine = SchedulerEngine(
        site: _site,
        sequenceSink: sink,
        candidateLoader: () async => [
          _candidate(id: 1, name: 'Bode', raHours: 14.0, decDegrees: 30.0),
        ],
        clock: _fixedNow,
      );
      await engine.start();
      expect(sink.dispatched.length, 1);

      // Operator stops the autopilot's run and starts their own, then presses
      // "Stop autopilot".
      sink.operatorTakesOver(manualRunId: 'operator-manual-run');
      await engine.stop();

      expect(
        sink.stopCount,
        0,
        reason: 'disengaging the autopilot must not end a manual run',
      );
      expect(sink.activeRunId, 'operator-manual-run');
      expect(
        sink.releaseCount,
        greaterThanOrEqualTo(1),
        reason: 'ownership is still handed back',
      );
      await engine.dispose();
    });
  });
}
