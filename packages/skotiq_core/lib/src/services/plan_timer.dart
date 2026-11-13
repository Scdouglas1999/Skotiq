import '../models/sequence/sequence_models.dart';
import 'pre_session_simulator.dart';
import 'sequence_time_estimator.dart';

/// A plan's estimated timing from [start]: every node in run order, the whole
/// run, and when the dawn park stops it.
class PlanTiming {
  const PlanTiming({
    required this.start,
    required this.timings,
    required this.total,
    this.runEndsBy,
  });

  final DateTime start;

  /// The nodes in run order (see [SequenceTimeEstimator.estimateSequenceTiming]).
  final List<NodeTiming> timings;

  /// The whole run, the autofocus runs the executor adds included.
  final Duration total;

  /// When the dawn park stops the run, or null when nothing does.
  final DateTime? runEndsBy;

  DateTime get end => start.add(total);

  /// [nodeId]'s timing, or null when the walk did not reach it.
  NodeTiming? of(String nodeId) {
    for (final timing in timings) {
      if (timing.nodeId == nodeId) return timing;
    }
    return null;
  }
}

/// The one way a plan's time is estimated, with everything that changes the
/// answer: the overhead model, the site (target windows, waits for dark), the
/// dawn park and the autofocus runs the executor adds by itself. Every surface
/// that shows a plan's length or end takes it from here, so the same plan gets
/// the same answer everywhere (`planTimerProvider` builds it from settings).
class PlanTimer {
  const PlanTimer({
    this.estimator = const SequenceTimeEstimator(),
    this.site,
    this.runEndsBy = _nothingEndsTheRun,
    this.autoFocusOnFilterChange = false,
    this.autoFocusEveryMinutes = 0,
    this.minAltitude = 20.0,
  });

  final SequenceTimeEstimator estimator;

  /// The observing site, or null when none is set.
  final ({double latitude, double longitude})? site;

  /// When a run started at the given time is stopped by the dawn park.
  final DateTime? Function(DateTime start) runEndsBy;

  final bool autoFocusOnFilterChange;
  final int autoFocusEveryMinutes;

  /// The horizon the visibility checks use, in degrees.
  final double minAltitude;

  static DateTime? _nothingEndsTheRun(DateTime start) => null;

  PlanTiming time(Sequence sequence, DateTime start) {
    final endsBy = site == null ? null : runEndsBy(start);
    return PlanTiming(
      start: start,
      timings: estimator.estimateSequenceTiming(
        sequence,
        start,
        latitude: site?.latitude,
        longitude: site?.longitude,
        runEndsBy: endsBy,
      ),
      total: estimator.estimateTotalDuration(
        sequence,
        start,
        latitude: site?.latitude,
        longitude: site?.longitude,
        autoFocusOnFilterChange: autoFocusOnFilterChange,
        autoFocusEveryMinutes: autoFocusEveryMinutes,
        runEndsBy: endsBy,
      ),
      runEndsBy: endsBy,
    );
  }

  /// The pre-flight simulation of [sequence] from [start] with the same
  /// inputs as [time]. [framesDone] is what a continued run already has.
  PreSessionSimulationResult simulate(
    Sequence sequence, {
    required DateTime start,
    DateTime? darkWindowStart,
    DateTime? darkWindowEnd,
    Map<String, int> framesDone = const {},
  }) => PreSessionSimulator(estimator: estimator).simulate(
    sequence,
    start: start,
    latitude: site?.latitude,
    longitude: site?.longitude,
    minAltitude: minAltitude,
    darkWindowStart: darkWindowStart,
    darkWindowEnd: darkWindowEnd,
    runEndsBy: site == null ? null : runEndsBy(start),
    autoFocusOnFilterChange: autoFocusOnFilterChange,
    autoFocusEveryMinutes: autoFocusEveryMinutes,
    framesDone: framesDone,
  );
}
