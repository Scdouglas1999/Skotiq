part of '../sequence_time_estimator.dart';

extension _SequenceTimeEstimatorWindowSolver on SequenceTimeEstimator {
  DateTime? _effectiveStartAfter(TargetHeaderNode node) {
    final triggerTime = _startTimeAfter(node.startWhen);
    return _maxDate(node.startAfter, triggerTime);
  }

  DateTime? _effectiveEndBefore(TargetHeaderNode node) {
    final triggerTime = _endTimeAfter(node.endWhen);
    return _minDate(node.endBefore, triggerTime);
  }

  double _effectiveMinAltitude(
    TargetHeaderNode node,
    double globalMinAltitude,
  ) {
    final triggerAltitude = _startAltitudeAbove(node.startWhen);
    return [
      globalMinAltitude,
      if (node.minAltitude != null) node.minAltitude!,
      if (triggerAltitude != null) triggerAltitude,
    ].reduce((a, b) => a > b ? a : b);
  }

  DateTime? _startTimeAfter(TargetTrigger? trigger) {
    return switch (trigger) {
      null => null,
      TimeAfterTrigger(unixSeconds: final ts) => _fromUnixSeconds(ts),
      AndTrigger(children: final children) =>
        children
            .map(_startTimeAfter)
            .whereType<DateTime>()
            .fold<DateTime?>(null, _maxDate),
      // An OR can be satisfied by a non-time term, so waiting on one branch
      // would fabricate precision the runtime does not guarantee.
      OrTrigger() => null,
      _ => null,
    };
  }

  DateTime? _endTimeAfter(TargetTrigger? trigger) {
    return switch (trigger) {
      null => null,
      TimeAfterTrigger(unixSeconds: final ts) => _fromUnixSeconds(ts),
      OrTrigger(children: final children) =>
        children
            .map(_endTimeAfter)
            .whereType<DateTime>()
            .fold<DateTime?>(null, _minDate),
      // AND requires every term to become true, so a TimeAfter child is only
      // a lower bound, not a reliable stop cap.
      AndTrigger() => null,
      _ => null,
    };
  }

  double? _startAltitudeAbove(TargetTrigger? trigger) {
    return switch (trigger) {
      null => null,
      AltitudeAboveTrigger(altitudeDeg: final altitude) => altitude,
      AndTrigger(children: final children) =>
        children.map(_startAltitudeAbove).whereType<double>().fold<double?>(
          null,
          (current, next) {
            if (current == null) return next;
            return current > next ? current : next;
          },
        ),
      // As with time ORs, an altitude OR may be satisfied by a different
      // branch; treating it as a hard floor would over-constrain simulation.
      OrTrigger() => null,
      _ => null,
    };
  }

  DateTime? _maxDate(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }

  DateTime? _minDate(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isBefore(b) ? a : b;
  }

  /// Walks the sequence the same way [estimateSequenceTiming] does but returns
  /// the final cumulative clock instead of the per-node timing list. Used by
  /// [estimateTotalDuration] so loop-multiplied time (which advances the clock
  /// without adding a timeline entry) is reflected in the total.
  DateTime _walkEndTime(
    Sequence sequence,
    DateTime startTime, {
    double? latitude,
    double? longitude,
  }) {
    final throwaway = <NodeTiming>[];
    final locationContext = (latitude != null && longitude != null)
        ? _LocationContext(
            latitude: latitude,
            longitude: longitude,
            date: startTime,
          )
        : null;

    var currentTime = startTime;
    if (sequence.rootNodeId == null) {
      for (final target in sequence.targetHeaders) {
        currentTime = _processNode(
          node: target,
          sequence: sequence,
          currentTime: currentTime,
          timings: throwaway,
          currentTargetHeaderId: target.id,
          loopIterationNote: null,
          locationContext: locationContext,
        );
      }
    } else {
      final rootNode = sequence.nodes[sequence.rootNodeId];
      if (rootNode != null && rootNode.isEnabled) {
        currentTime = _processNode(
          node: rootNode,
          sequence: sequence,
          currentTime: currentTime,
          timings: throwaway,
          currentTargetHeaderId: null,
          loopIterationNote: null,
          locationContext: locationContext,
        );
      }
    }
    return currentTime;
  }
}
