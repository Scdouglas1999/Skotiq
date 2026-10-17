import 'package:skotiq_planetarium/skotiq_planetarium.dart';

import '../models/sequence/sequence_models.dart';
part 'sequence_time_estimator/timing_models.dart';
part 'sequence_time_estimator/node_durations.dart';
part 'sequence_time_estimator/window_solver.dart';

/// Service for estimating sequence execution timing with astronomical awareness.
///
/// This service walks a sequence tree to estimate when each node will execute,
/// calculates target visibility windows based on observer location, and
/// identifies timing conflicts where nodes may execute outside their target's
/// visibility window.
class SequenceTimeEstimator {
  /// Per-operation overhead model. Single source of truth shared with the
  /// tree-row rollup ([nodeRollupDurationProvider]) and the pre-flight
  /// simulation so the node chip, the timeline, the Pre-Flight duration and
  /// the run-dashboard total all agree. Construct via [SequenceTimeEstimator.new]
  /// with a config derived from the user's `SequencerDefaults` (see the app
  /// call sites); the no-arg `const` form uses [defaultEstimatorOverhead].
  final SequenceOverheadConfig overhead;

  /// Construct with an explicit overhead model. Defaults to
  /// [defaultEstimatorOverhead] (2 s download, 5 s dither, 30 s slew/center,
  /// 120 s meridian-flip base, 10 min cooling), not the
  /// [SequenceOverheadConfig] field defaults.
  const SequenceTimeEstimator({this.overhead = defaultEstimatorOverhead});

  // Default timing constants (in seconds unless noted)

  /// The estimator's overhead constants, expressed as a
  /// [SequenceOverheadConfig]. They differ from the [SequenceOverheadConfig]
  /// field defaults on purpose — lighter assumptions (2 s download, 5 s
  /// dither/settle, 30 s slew + center, 120 s meridian-flip base) that the
  /// time-estimator tests and timeline goldens are pinned to. App call sites
  /// override this with a config built from `SequencerDefaults` so the live
  /// estimate honours the operator's real cadence.
  static const SequenceOverheadConfig defaultEstimatorOverhead =
      SequenceOverheadConfig(
        downloadOverheadPerExposureSecs: 2.0,
        ditherSecs: 5.0,
        slewSecs: 30.0,
        centerTargetSecs: 30.0,
        meridianFlipSecs: 120.0,
        // 10 minutes, in seconds, for camera cooling.
        coolingSecs: 600.0,
      );

  /// Default cooling duration in minutes, derived from [overhead.coolingSecs]
  /// so a custom config flows through to the CoolCamera estimate.
  double get _defaultCoolingMins => overhead.coolingSecs / 60.0;

  static const int _defaultScriptTimeoutSecs = 60;

  /// Minimum altitude for target visibility calculations (degrees)
  static const double _defaultMinAltitude = 0.0;

  /// Estimate timing for all nodes in a sequence.
  ///
  /// Walks the sequence tree in depth-first execution order from the root node,
  /// calculating start and end times for each enabled node based on its type
  /// and parameters.
  ///
  /// [sequence] - The sequence to estimate timing for
  /// [startTime] - The intended start time of the sequence
  /// [latitude] - Observer latitude in degrees (optional, needed for twilight waits)
  /// [longitude] - Observer longitude in degrees (optional, needed for twilight waits)
  ///
  /// Returns a list of [NodeTiming] objects in execution order.
  List<NodeTiming> estimateSequenceTiming(
    Sequence sequence,
    DateTime startTime, {
    double? latitude,
    double? longitude,
  }) {
    final timings = <NodeTiming>[];
    var currentTime = startTime;

    // Create location context if coordinates provided
    final locationContext = (latitude != null && longitude != null)
        ? _LocationContext(
            latitude: latitude,
            longitude: longitude,
            date: startTime,
          )
        : null;

    if (sequence.rootNodeId == null) {
      // No root node - process all target headers as separate roots
      final targetHeaders = sequence.targetHeaders;
      for (final target in targetHeaders) {
        currentTime = _processNode(
          node: target,
          sequence: sequence,
          currentTime: currentTime,
          timings: timings,
          currentTargetHeaderId: target.id,
          loopIterationNote: null,
          locationContext: locationContext,
        );
      }
    } else {
      // Process from root node
      final rootNode = sequence.nodes[sequence.rootNodeId];
      if (rootNode != null && rootNode.isEnabled) {
        _processNode(
          node: rootNode,
          sequence: sequence,
          currentTime: currentTime,
          timings: timings,
          currentTargetHeaderId: null,
          loopIterationNote: null,
          locationContext: locationContext,
        );
      }
    }

    return timings;
  }

  /// Intrinsic duration of ONE instance of [node], excluding its children.
  ///
  /// Public so the sequencer tree's per-row rollup bills each node with the
  /// same model the timeline and the pre-flight simulation use. A second table
  /// of per-node costs disagrees with this one on every node it does not list
  /// (Delay, Wait, Park, Script and Rotator bill at zero) and on Cool Camera (a
  /// flat "cooling" constant instead of the node's own configured duration), so
  /// the Builder's estimate chip and the Pre-Flight simulation print different
  /// totals for the same sequence.
  ///
  /// [at] anchors the nodes whose duration depends on the clock (Wait Until);
  /// it defaults to now.
  Duration nodeDuration(SequenceNode node, {DateTime? at}) =>
      _estimateNodeDuration(node, at ?? DateTime.now(), null);

  /// Calculate visibility windows for all targets in a sequence.
  ///
  /// For each TargetHeaderNode in the sequence, calculates rise, transit, and
  /// set times based on the observer's location.
  ///
  /// [sequence] - The sequence containing target headers
  /// [date] - An instant within the observing night (in practice the run's
  ///   start time, via [analyzeSequence]). Resolved to the night that CONTAINS
  ///   it because the visibility scan runs local noon to noon.
  /// [latitude] - Observer latitude in degrees
  /// [longitude] - Observer longitude in degrees
  /// [minAltitude] - Minimum altitude in degrees for visibility (default: 0)
  ///
  /// Returns a map from target header node ID to [TargetWindow].
  Map<String, TargetWindow> calculateTargetWindows(
    Sequence sequence,
    DateTime date, {
    required double latitude,
    required double longitude,
    double minAltitude = _defaultMinAltitude,
  }) {
    final windows = <String, TargetWindow>{};
    final nightDate = AstronomyCalculations.nightDateOf(date);

    // Find all TargetHeaderNode instances in the sequence
    for (final node in sequence.nodes.values) {
      if (node is TargetHeaderNode && node.isEnabled) {
        final effectiveMinAltitude = _effectiveMinAltitude(node, minAltitude);
        final visibility = AstronomyCalculations.calculateObjectVisibility(
          raDeg: node.raHours * 15.0, // Convert RA hours to degrees
          decDeg: node.decDegrees,
          date: nightDate,
          latitudeDeg: latitude,
          longitudeDeg: longitude,
          minAltitude: effectiveMinAltitude,
        );

        windows[node.id] = TargetWindow(
          targetId: node.id,
          targetName: node.targetName,
          riseTime: visibility.riseTime,
          transitTime: visibility.transitTime,
          setTime: visibility.setTime,
          transitAltitude: visibility.transitAltitude,
          isCircumpolar: visibility.isCircumpolar,
          neverRises: visibility.neverRises,
          raDeg: node.raHours * 15.0,
          decDeg: node.decDegrees,
          latitudeDeg: latitude,
          longitudeDeg: longitude,
          minAltitudeDeg: effectiveMinAltitude,
        );
      }
    }

    return windows;
  }

  /// Find timing conflicts between node execution times and target visibility.
  ///
  /// Checks each node's execution window against its target's visibility window
  /// and returns warnings for any conflicts (e.g., exposures scheduled when
  /// target is below horizon).
  ///
  /// [timings] - List of node timings from [estimateSequenceTiming]
  /// [windows] - Map of target windows from [calculateTargetWindows]
  /// [sequence] - The sequence being analyzed
  ///
  /// Returns a list of warning strings describing any conflicts found.
  List<String> findTimingConflicts(
    List<NodeTiming> timings,
    Map<String, TargetWindow> windows,
    Sequence sequence,
  ) {
    final conflicts = <String>[];

    for (final timing in timings) {
      // Skip nodes without a target header
      if (timing.targetHeaderId == null) continue;

      final window = windows[timing.targetHeaderId];
      if (window == null) continue;
      final targetNode = sequence.nodes[timing.targetHeaderId];
      final targetName = targetNode is TargetHeaderNode
          ? targetNode.targetName
          : 'Target';

      if (targetNode is TargetHeaderNode) {
        final startAfter = _effectiveStartAfter(targetNode);
        if (startAfter != null && timing.estimatedStart.isBefore(startAfter)) {
          conflicts.add(
            '$targetName: "${timing.nodeName}" scheduled at ${_formatTime(timing.estimatedStart)} '
            'before target start time ${_formatTime(startAfter)}',
          );
        }

        final endBefore = _effectiveEndBefore(targetNode);
        if (endBefore != null && timing.estimatedEnd.isAfter(endBefore)) {
          conflicts.add(
            '$targetName: "${timing.nodeName}" ends at ${_formatTime(timing.estimatedEnd)} '
            'after target end time ${_formatTime(endBefore)}',
          );
        }
      }

      // Check if the node executes during the target's visibility window
      if (window.neverRises) {
        conflicts.add(
          '${window.targetName}: Target never rises above minimum altitude at this location',
        );
        continue;
      }

      if (window.isCircumpolar) {
        // Circumpolar targets are always visible, no conflict possible
        continue;
      }

      // Check start time
      if (!window.isVisibleAt(timing.estimatedStart)) {
        final start = timing.estimatedStart;
        if (window.riseTime != null && start.isBefore(window.riseTime!)) {
          conflicts.add(
            '$targetName: "${timing.nodeName}" scheduled at ${_formatTime(start)} '
            'before target rises at ${_formatTimeRelativeTo(window.riseTime!, start)}',
          );
        } else if (window.setTime != null) {
          conflicts.add(
            '$targetName: "${timing.nodeName}" scheduled at ${_formatTime(start)} '
            'after target sets at ${_formatTimeRelativeTo(window.setTime!, start)}',
          );
        }
      }

      // Check end time. The `isVisibleAt` guard keeps this from firing on a
      // set instant that belongs to a different night than the node: the
      // window solver reports one rise/set pair per noon-to-noon scan, so the
      // only trustworthy question is whether the target is actually down when
      // the node ends.
      final end = timing.estimatedEnd;
      if (window.setTime != null &&
          end.isAfter(window.setTime!) &&
          !window.isCircumpolar &&
          !window.isVisibleAt(end)) {
        conflicts.add(
          '$targetName: "${timing.nodeName}" ends at ${_formatTime(end)} '
          'after target sets at ${_formatTimeRelativeTo(window.setTime!, end)}',
        );
      }
    }

    // Deduplicate conflicts (same target may have multiple nodes)
    return conflicts.toSet().toList();
  }

  DateTime _fromUnixSeconds(int unixSeconds) =>
      DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);

  /// Convenience method to perform full timing analysis.
  ///
  /// Combines [estimateSequenceTiming], [calculateTargetWindows], and
  /// [findTimingConflicts] into a single call.
  ///
  /// Returns a tuple of (timings, windows, conflicts).
  ({
    List<NodeTiming> timings,
    Map<String, TargetWindow> windows,
    List<String> conflicts,
  })
  analyzeSequence(
    Sequence sequence,
    DateTime startTime, {
    required double latitude,
    required double longitude,
    double minAltitude = _defaultMinAltitude,
  }) {
    final timings = estimateSequenceTiming(
      sequence,
      startTime,
      latitude: latitude,
      longitude: longitude,
    );
    final windows = calculateTargetWindows(
      sequence,
      startTime,
      latitude: latitude,
      longitude: longitude,
      minAltitude: minAltitude,
    );
    final conflicts = findTimingConflicts(timings, windows, sequence);

    return (timings: timings, windows: windows, conflicts: conflicts);
  }

  /// Extra overhead (seconds) from autofocus runs the executor will splice in
  /// at runtime but which never appear as nodes in the sequence tree, so no
  /// per-node timing entry exists for them.
  ///
  /// Two synthetic-AF sources, both driven by app settings (mirroring the
  /// serializer's [_sequenceToJson] injection logic):
  ///
  ///   * [autoFocusOnFilterChange] — one AF run is injected after every
  ///     [FilterChangeNode] that is NOT already immediately followed by an
  ///     [AutofocusNode] sibling. We count those filter changes across the
  ///     whole tree and charge [overhead.autofocusSecs] each.
  ///   * [autoFocusEveryMinutes] — the AF-interval trigger fires roughly
  ///     every N minutes of run time. We approximate the count as
  ///     floor(estimatedTotalMinutes / N) and charge [overhead.autofocusSecs]
  ///     each. `0` (or negative) disables this term.
  ///
  /// This is read-only: it never mutates the [Sequence] (no synthetic nodes
  /// are inserted), matching how the estimator stays a pure function of the
  /// tree. Returns 0 when neither setting is active.
  double injectedAutofocusSecs(
    Sequence sequence, {
    required bool autoFocusOnFilterChange,
    int autoFocusEveryMinutes = 0,
    Duration? estimatedTotal,
  }) {
    double secs = 0.0;

    if (autoFocusOnFilterChange) {
      var injectedFilterChangeAf = 0;
      for (final node in sequence.nodes.values) {
        for (var i = 0; i < node.childIds.length; i++) {
          final child = sequence.nodes[node.childIds[i]];
          if (child is! FilterChangeNode || !child.isEnabled) continue;
          final nextId = i + 1 < node.childIds.length
              ? node.childIds[i + 1]
              : null;
          final next = nextId == null ? null : sequence.nodes[nextId];
          if (next is AutofocusNode) continue; // user already arranged AF
          injectedFilterChangeAf++;
        }
      }
      secs += injectedFilterChangeAf * overhead.autofocusSecs;
    }

    if (autoFocusEveryMinutes > 0 && estimatedTotal != null) {
      final totalMins = estimatedTotal.inSeconds / 60.0;
      final intervalRuns = (totalMins / autoFocusEveryMinutes).floor();
      if (intervalRuns > 0) {
        secs += intervalRuns * overhead.autofocusSecs;
      }
    }

    return secs;
  }

  /// Calculate the total estimated duration of a sequence.
  ///
  /// Note: For unbounded loops (forever, whileDark), this returns the duration
  /// of a single iteration only.
  ///
  /// [latitude] and [longitude] are optional but required for accurate twilight
  /// wait estimates. When [autoFocusOnFilterChange] / [autoFocusEveryMinutes]
  /// are supplied (from app settings), the runtime-injected autofocus runs the
  /// executor splices in are added on top (see [injectedAutofocusSecs]) so the
  /// run-dashboard total matches what actually executes.
  Duration estimateTotalDuration(
    Sequence sequence,
    DateTime startTime, {
    double? latitude,
    double? longitude,
    bool autoFocusOnFilterChange = false,
    int autoFocusEveryMinutes = 0,
  }) {
    final timings = estimateSequenceTiming(
      sequence,
      startTime,
      latitude: latitude,
      longitude: longitude,
    );
    if (timings.isEmpty) {
      return Duration.zero;
    }

    // The cumulative end clock is the latest end across all timing entries
    // PLUS any time the walk advanced past the last rendered entry. The
    // latter matters for Count loops: the timeline renders one iteration of
    // body detail (the last timing entry ends at the first pass), but the
    // walk advances the clock by the full loop. Re-walk to recover that
    // end-of-sequence clock and take the max so a loop-bounded sequence
    // reports its real duration.
    final walkEnd = _walkEndTime(
      sequence,
      startTime,
      latitude: latitude,
      longitude: longitude,
    );
    final lastTiming = timings.last;
    final end = lastTiming.estimatedEnd.isAfter(walkEnd)
        ? lastTiming.estimatedEnd
        : walkEnd;
    final baseTotal = end.difference(startTime);

    // Add runtime-injected autofocus overhead (filter-change AF + AF-interval
    // cadence) that has no node in the tree. Off unless the caller threads the
    // app's autofocus settings through.
    if (!autoFocusOnFilterChange && autoFocusEveryMinutes <= 0) {
      return baseTotal;
    }
    final afSecs = injectedAutofocusSecs(
      sequence,
      autoFocusOnFilterChange: autoFocusOnFilterChange,
      autoFocusEveryMinutes: autoFocusEveryMinutes,
      estimatedTotal: baseTotal,
    );
    return baseTotal + Duration(milliseconds: (afSecs * 1000).round());
  }
}
