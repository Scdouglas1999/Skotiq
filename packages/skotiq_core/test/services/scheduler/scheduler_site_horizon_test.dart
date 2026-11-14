// The scheduler's altitude floor is the site horizon when one is set for the
// property, otherwise its minimum altitude (owner, 2026-11-13).
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/models/site/site_horizon_profile.dart';
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

SchedulerSite _site(SiteHorizonProfile horizon) => SchedulerSite(
  latitudeDegrees: 40.0,
  longitudeDegrees: -75.0,
  localOffset: const Duration(hours: -5),
  horizon: horizon,
);

SiteHorizonProfile _allAround(double deg) => SiteHorizonProfile.fromJson(
  '{"N":$deg,"NE":$deg,"E":$deg,"SE":$deg,"S":$deg,"SW":$deg,"W":$deg,'
  '"NW":$deg}',
);

/// Local midnight-ish at the test site: the Sun is well down, so nothing here
/// is end-of-night.
DateTime _night() => DateTime.utc(2026, 5, 11, 4, 0);

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
  Future<int> dispatchesWith(SiteHorizonProfile horizon) async {
    final sink = _ExecutorSink();
    final engine = SchedulerEngine(
      site: _site(horizon),
      sequenceSink: sink,
      candidateLoader: () async => [_candidate()],
      clock: _night,
    );
    addTearDown(engine.dispose);
    await engine.start();
    return sink.dispatched.length;
  }

  test(
    'with no horizon set the minimum altitude admits a high target',
    () async {
      expect(await dispatchesWith(_allAround(0)), 1);
    },
  );

  test('a horizon set above the target refuses it', () async {
    expect(await dispatchesWith(_allAround(85)), 0);
  });
}
