import '../models/sequence/sequence_models.dart';
import 'sequence_time_estimator.dart';

enum PreSessionSimulationSeverity { info, warning, error }

class PreSessionSimulationSegment {
  final String nodeId;
  final String nodeName;
  final String nodeType;
  final DateTime start;
  final DateTime end;
  final Duration duration;
  final String? targetHeaderId;
  final String? targetName;
  final List<String> notes;

  const PreSessionSimulationSegment({
    required this.nodeId,
    required this.nodeName,
    required this.nodeType,
    required this.start,
    required this.end,
    required this.duration,
    this.targetHeaderId,
    this.targetName,
    this.notes = const [],
  });
}

class PreSessionSimulationIssue {
  final PreSessionSimulationSeverity severity;
  final String message;
  final String? targetHeaderId;

  const PreSessionSimulationIssue({
    required this.severity,
    required this.message,
    this.targetHeaderId,
  });
}

class PreSessionSimulationResult {
  final DateTime start;
  final DateTime end;
  final Duration duration;
  final List<PreSessionSimulationSegment> segments;
  final Map<String, TargetWindow> targetWindows;
  final List<PreSessionSimulationIssue> issues;

  const PreSessionSimulationResult({
    required this.start,
    required this.end,
    required this.duration,
    required this.segments,
    required this.targetWindows,
    required this.issues,
  });

  bool get hasBlockingIssues => issues.any(
    (issue) => issue.severity == PreSessionSimulationSeverity.error,
  );
}

/// Pure pre-session simulator.
///
/// This is the service layer behind the eventual "simulate tonight" Gantt. It
/// deliberately wraps [SequenceTimeEstimator] rather than inventing a second
/// timing model, and returns UI-neutral segments/issues that can be rendered by
/// the pre-flight dialog, Smart Night, or a future timeline view.
class PreSessionSimulator {
  final SequenceTimeEstimator _estimator;

  const PreSessionSimulator({
    SequenceTimeEstimator estimator = const SequenceTimeEstimator(),
  }) : _estimator = estimator;

  PreSessionSimulationResult simulate(
    Sequence sequence, {
    required DateTime start,
    double? latitude,
    double? longitude,
    double minAltitude = 20.0,
    DateTime? darkWindowStart,
    DateTime? darkWindowEnd,
  }) {
    final analysis = latitude == null || longitude == null
        ? (
            timings: _estimator.estimateSequenceTiming(sequence, start),
            windows: const <String, TargetWindow>{},
            conflicts: const <String>[],
          )
        : _estimator.analyzeSequence(
            sequence,
            start,
            latitude: latitude,
            longitude: longitude,
            minAltitude: minAltitude,
          );

    final segments = analysis.timings
        .map((timing) => _segmentFromTiming(sequence, timing))
        .toList(growable: false);
    // The end of the run, not the end of the last RENDERED segment.
    //
    // `estimateSequenceTiming` deliberately emits detail for a single pass of
    // a Count loop (each entry carries a "Showing 1 of N" note) while advancing
    // its own clock by the whole loop. Taking `segments.last.end` therefore
    // billed a sequence that ends in `Loop(count: N)` for ONE iteration, so the
    // pre-flight "Duration"/"Ends" pair disagreed with the Builder's estimate
    // chip — which reads `estimateTotalDuration` — by the loop factor. Ask the
    // estimator for the same total the chip shows; `estimateTotalDuration`
    // already takes the later of its own walk end and the last timing entry, so
    // this can only ever move the end later, never earlier.
    final walkEnd = start.add(
      _estimator.estimateTotalDuration(
        sequence,
        start,
        latitude: latitude,
        longitude: longitude,
      ),
    );
    final end = segments.isEmpty
        ? start
        : (walkEnd.isAfter(segments.last.end) ? walkEnd : segments.last.end);
    final issues = <PreSessionSimulationIssue>[
      ...analysis.conflicts.map(
        (message) => PreSessionSimulationIssue(
          severity: PreSessionSimulationSeverity.warning,
          message: message,
        ),
      ),
      ..._windowIssues(analysis.windows),
      if (darkWindowStart != null && start.isBefore(darkWindowStart))
        PreSessionSimulationIssue(
          severity: PreSessionSimulationSeverity.warning,
          message:
              'Sequence is expected to start at ${_formatTime(start)}, '
              'before the dark window starts at ${_formatTime(darkWindowStart)}.',
        ),
      if (darkWindowEnd != null && end.isAfter(darkWindowEnd))
        PreSessionSimulationIssue(
          severity: PreSessionSimulationSeverity.warning,
          message:
              'Sequence is expected to end at ${_formatTime(end)}, '
              'after the dark window ends at ${_formatTime(darkWindowEnd)}.',
        ),
    ];

    return PreSessionSimulationResult(
      start: start,
      end: end,
      duration: end.difference(start),
      segments: segments,
      targetWindows: Map.unmodifiable(analysis.windows),
      issues: List.unmodifiable(issues),
    );
  }

  PreSessionSimulationSegment _segmentFromTiming(
    Sequence sequence,
    NodeTiming timing,
  ) {
    final target = timing.targetHeaderId == null
        ? null
        : sequence.nodes[timing.targetHeaderId!];
    return PreSessionSimulationSegment(
      nodeId: timing.nodeId,
      nodeName: timing.nodeName,
      nodeType: timing.nodeType,
      start: timing.estimatedStart,
      end: timing.estimatedEnd,
      duration: timing.duration,
      targetHeaderId: timing.targetHeaderId,
      targetName: target is TargetHeaderNode ? target.targetName : null,
      notes: timing.warnings ?? const [],
    );
  }

  Iterable<PreSessionSimulationIssue> _windowIssues(
    Map<String, TargetWindow> windows,
  ) sync* {
    for (final window in windows.values) {
      if (window.neverRises) {
        yield PreSessionSimulationIssue(
          severity: PreSessionSimulationSeverity.error,
          targetHeaderId: window.targetId,
          message:
              '${window.targetName} never rises above the simulation '
              'altitude floor.',
        );
      } else if (!window.isCircumpolar && window.setTime == null) {
        yield PreSessionSimulationIssue(
          severity: PreSessionSimulationSeverity.warning,
          targetHeaderId: window.targetId,
          message: '${window.targetName} visibility window is incomplete.',
        );
      }
    }
  }

  String _formatTime(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';
}
