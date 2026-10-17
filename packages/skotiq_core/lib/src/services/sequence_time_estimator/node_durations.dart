part of '../sequence_time_estimator.dart';

extension _SequenceTimeEstimatorNodeDurations on SequenceTimeEstimator {
  /// Process a single node and its children, returning the time after completion.
  DateTime _processNode({
    required SequenceNode node,
    required Sequence sequence,
    required DateTime currentTime,
    required List<NodeTiming> timings,
    required String? currentTargetHeaderId,
    required String? loopIterationNote,
    required _LocationContext? locationContext,
  }) {
    if (!node.isEnabled) {
      return currentTime;
    }

    if (node is TargetHeaderNode) {
      final startAfter = _effectiveStartAfter(node);
      if (startAfter != null && currentTime.isBefore(startAfter)) {
        currentTime = startAfter;
      }
    }

    // Update target header ID if this is a target header node
    final targetId = node is TargetHeaderNode ? node.id : currentTargetHeaderId;

    // Calculate duration for this node
    final nodeDuration = _estimateNodeDuration(
      node,
      currentTime,
      locationContext,
    );

    // Add timing entry if this node has a meaningful duration
    if (nodeDuration.inSeconds > 0) {
      final endTime = currentTime.add(nodeDuration);
      final warnings = <String>[];

      // Add loop iteration note if applicable
      if (loopIterationNote != null) {
        warnings.add(loopIterationNote);
      }

      timings.add(
        NodeTiming(
          nodeId: node.id,
          nodeName: node.name,
          nodeType: node.nodeType,
          estimatedStart: currentTime,
          estimatedEnd: endTime,
          duration: nodeDuration,
          warnings: warnings.isNotEmpty ? warnings : null,
          targetHeaderId: targetId,
        ),
      );

      currentTime = endTime;
    }

    // Process children in order
    if (node.childIds.isNotEmpty) {
      final children = sequence.getChildren(node.id);

      // Handle loop nodes specially - the timeline still renders detail for a
      // SINGLE iteration (with a "1 of N" warning), but the cumulative clock
      // must advance by the full loop so downstream nodes + the
      // meridian/dawn conflict checks see the real end time: advancing one
      // pass under-reports a Count loop by the loop factor. For unbounded or
      // condition-based loops the iteration count is not known statically, so
      // the single-pass estimate stands and the warning note says so.
      if (node is LoopNode) {
        final loopNote = _getLoopIterationNote(node);
        final loopStartTime = currentTime;
        for (final child in children) {
          currentTime = _processNode(
            node: child,
            sequence: sequence,
            currentTime: currentTime,
            timings: timings,
            currentTargetHeaderId: targetId,
            loopIterationNote: loopNote,
            locationContext: locationContext,
          );
        }
        if (node.conditionType == LoopConditionType.count) {
          final iterations = node.repeatCount ?? 1;
          if (iterations > 1) {
            final singlePass = currentTime.difference(loopStartTime);
            // Advance the clock by the remaining (count - 1) iterations'
            // worth of body time. The first pass is already reflected in
            // `currentTime` (and rendered in the timeline).
            currentTime = currentTime.add(singlePass * (iterations - 1));
          }
        }
      } else {
        for (final child in children) {
          currentTime = _processNode(
            node: child,
            sequence: sequence,
            currentTime: currentTime,
            timings: timings,
            currentTargetHeaderId: targetId,
            loopIterationNote: loopIterationNote,
            locationContext: locationContext,
          );
        }
      }
    }

    return currentTime;
  }

  /// Get a note describing loop iteration limitations.
  String _getLoopIterationNote(LoopNode node) {
    switch (node.conditionType) {
      case LoopConditionType.count:
        final count = node.repeatCount ?? 1;
        if (count > 1) {
          return 'Showing 1 of $count loop iterations';
        }
        return 'Single loop iteration';
      case LoopConditionType.forever:
        return 'Unbounded loop - showing single iteration estimate';
      case LoopConditionType.whileDark:
        return 'Loop until dawn - showing single iteration estimate';
      case LoopConditionType.untilTime:
        final until = node.repeatUntil;
        if (until != null) {
          return 'Loop until ${_formatTime(until)} - showing single iteration';
        }
        return 'Time-based loop - showing single iteration estimate';
      case LoopConditionType.untilAltitude:
        final alt = node.repeatUntilAltitude;
        if (alt != null) {
          return 'Loop until altitude below ${alt.toStringAsFixed(0)} degrees - showing single iteration';
        }
        return 'Altitude-based loop - showing single iteration estimate';
      case LoopConditionType.altitudeAbove:
        final alt = node.repeatUntilAltitude;
        if (alt != null) {
          return 'Loop until altitude above ${alt.toStringAsFixed(0)} degrees - showing single iteration';
        }
        return 'Altitude-based loop - showing single iteration estimate';
      case LoopConditionType.integrationTime:
        final target = node.integrationTimeTarget;
        if (target != null && target > 0) {
          final mins = (target / 60).round();
          return 'Loop until ${mins}m integration time reached - showing single iteration';
        }
        return 'Integration time loop - showing single iteration estimate';
    }
  }

  /// Format time for display.
  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  /// Format [time] for display next to [reference], adding the calendar date
  /// whenever the two fall on different days. A bare "03:41" printed beside a
  /// node scheduled at "12:47" reads as a time that already passed even when
  /// it is tomorrow morning's rise.
  String _formatTimeRelativeTo(DateTime time, DateTime reference) {
    final sameDay =
        time.year == reference.year &&
        time.month == reference.month &&
        time.day == reference.day;
    if (sameDay) return _formatTime(time);
    final month = time.month.toString().padLeft(2, '0');
    final day = time.day.toString().padLeft(2, '0');
    return '${_formatTime(time)} on $month-$day';
  }

  /// Calculate when the specified twilight type will occur.
  ///
  /// Returns the next occurrence of the specified twilight (dusk or dawn),
  /// or null if it can't be calculated (e.g., polar regions in summer).
  DateTime? _calculateTwilightWaitTime(
    DateTime currentTime,
    TwilightType twilightType,
    _LocationContext locationContext,
  ) {
    final twilightTimes = AstronomyCalculations.calculateTwilightTimes(
      date: locationContext.date,
      latitudeDeg: locationContext.latitude,
      longitudeDeg: locationContext.longitude,
    );

    // Determine which twilight time to use based on type
    // For imaging, we typically wait for evening twilight (dusk)
    DateTime? targetTime;
    switch (twilightType) {
      case TwilightType.civil:
        // Civil twilight: sun 6° below horizon
        targetTime = twilightTimes.civilDusk;
        break;
      case TwilightType.nautical:
        // Nautical twilight: sun 12° below horizon
        targetTime = twilightTimes.nauticalDusk;
        break;
      case TwilightType.astronomical:
        // Astronomical twilight: sun 18° below horizon (truly dark)
        targetTime = twilightTimes.astronomicalDusk;
        break;
    }

    if (targetTime == null) {
      // Twilight doesn't occur (e.g., polar summer)
      return null;
    }

    // If the twilight time has already passed today, it means we're
    // already past dusk - no wait needed
    if (targetTime.isBefore(currentTime)) {
      return null;
    }

    return targetTime;
  }

  /// Estimate the duration of a single node based on its type.
  Duration _estimateNodeDuration(
    SequenceNode node,
    DateTime currentTime,
    _LocationContext? locationContext,
  ) {
    // Exhaustive switch over the sealed SequenceNode hierarchy. A new node
    // subtype will fail to compile here rather than silently fall through to
    // a zero-duration default and mis-estimate sequence timing.
    return switch (node) {
      ExposureNode() => Duration(
        milliseconds:
            ((node.count * node.durationSecs +
                        node.count * overhead.downloadOverheadPerExposureSecs) *
                    1000)
                .round(),
      ),
      // SmartExposure. Sum of (count * duration) across
      // all plans + per-frame download overhead + one filter-change penalty
      // per plan + dither-cost for each dither point. When an integration
      // budget is set and is lower than the natural duration, we clamp to
      // the budget so the Run Dashboard's "estimated total" shrinks to
      // match expected behaviour.
      SmartExposureNode() => () {
        if (node.plans.isEmpty) return Duration.zero;
        // Per-plan integration time + per-frame download overhead.
        double secs = 0.0;
        for (final p in node.plans) {
          secs += p.count * p.durationSecs;
          secs += p.count * overhead.downloadOverheadPerExposureSecs;
          // Dither cost: one settle cycle per ditherEvery frames (treat
          // 0 / null as "no dither"). Same heuristic as ExposureNode but
          // applied per-plan.
          final every = p.ditherEvery ?? 0;
          if (every > 0) {
            final ditherCount = (p.count / every).floor();
            secs += ditherCount * overhead.ditherSecs;
          }
        }
        // One filter change per plan (skipped only if two consecutive
        // plans share the same filter — the estimator can't tell which
        // ones will overlap with the live current-filter state, so we
        // assume worst case). Mirrors the FilterChangeNode case below.
        secs += node.plans.length * overhead.filterChangeSecs;
        // Clamp to the integration budget when one is set. The budget
        // measures *integration* not wall-clock — we approximate by
        // capping the integration component only.
        if (node.integrationBudgetSecs > 0 &&
            node.totalIntegrationSecs > node.integrationBudgetSecs) {
          final overshoot =
              node.totalIntegrationSecs - node.integrationBudgetSecs;
          secs -= overshoot;
        }
        return Duration(milliseconds: (secs * 1000).round());
      }(),
      AutofocusNode() => Duration(
        // The Rust executor's AutofocusConfig has no exposures-per-point
        // field — the serializer never sends `node.exposuresPerPoint`, and
        // the runtime captures exactly one exposure per focus point. Estimate
        // against that authoritative per-point count of 1 so the timeline
        // matches what actually runs, rather than referencing an unsent
        // field that would over-estimate whenever the user set it > 1.
        milliseconds: (((node.stepsOut * 2 + 1) * node.exposureDuration) * 1000)
            .round(),
      ),
      DitherNode() => Duration(
        milliseconds:
            (((node.settleTime > 0 ? node.settleTime : overhead.ditherSecs)) *
                    1000)
                .round(),
      ),
      DelayNode() => Duration(milliseconds: (node.seconds * 1000).round()),
      WaitTimeNode() => _estimateWaitTimeDuration(
        node,
        currentTime,
        locationContext,
      ),
      SlewNode() => Duration(milliseconds: (overhead.slewSecs * 1000).round()),
      CenterNode() => () {
        // Centering involves multiple plate solves and slews. Estimate:
        // maxAttempts iterations of (expose + solve + slew). In practice,
        // usually succeeds in 1-3 attempts. Per-attempt cost is the node's
        // real exposure duration plus a plate-solve + half-slew overhead
        // drawn from the shared config (no magic 10 + slew/2 literal).
        final estimatedAttempts = (node.maxAttempts / 2).ceil();
        final secsPerAttempt =
            node.exposureDuration +
            overhead.plateSolveSecs +
            overhead.slewSecs / 2;
        final totalSecs = estimatedAttempts * secsPerAttempt;
        return Duration(milliseconds: (totalSecs * 1000).round());
      }(),
      MeridianFlipNode() => () {
        // Flip includes: stop guiding, slew, recenter, restart guiding.
        double totalSecs = overhead.meridianFlipSecs;
        if (node.autoCenter) {
          totalSecs += overhead.centerTargetSecs;
        }
        totalSecs += node.settleTime;
        return Duration(milliseconds: (totalSecs * 1000).round());
      }(),
      FilterChangeNode() => Duration(
        milliseconds: (overhead.filterChangeSecs * 1000).round(),
      ),
      RotatorNode() => const Duration(seconds: 15),
      ParkNode() || UnparkNode() => const Duration(seconds: 30),
      CoolCameraNode() => Duration(
        minutes: (node.durationMins ?? _defaultCoolingMins).round(),
      ),
      WarmCameraNode() => () {
        // Estimate warming time using a typical 30 C delta (e.g., -10 to +20)
        // at the configured rate. Guard the divisor: a zero / negative
        // ratePerMin (blank field, bad import) would otherwise produce
        // Infinity / NaN and a garbage Duration. Fall back to the model's
        // default rate of 2 C/min.
        const deltaTemp = 30.0;
        final rate = node.ratePerMin > 0 ? node.ratePerMin : 2.0;
        final mins = deltaTemp / rate;
        return Duration(minutes: mins.round());
      }(),
      StartGuidingNode() => Duration(
        milliseconds: (node.settleTimeout * 1000).round(),
      ),
      StopGuidingNode() => const Duration(seconds: 2),
      OpenDomeNode() ||
      CloseDomeNode() ||
      ParkDomeNode() => const Duration(seconds: 60),
      // Mechanical cover and calibrator toggles are quick — ~5 seconds covers
      // both the dust cover motion and the EL panel power cycle.
      OpenCoverNode() ||
      CloseCoverNode() ||
      CalibratorOnNode() ||
      CalibratorOffNode() => const Duration(seconds: 5),
      PolarAlignmentNode() => const Duration(minutes: 5),
      ScriptNode() => Duration(
        seconds:
            node.timeoutSecs ?? SequenceTimeEstimator._defaultScriptTimeoutSecs,
      ),
      NotificationNode() => Duration.zero,
      // Container nodes (TargetHeaderNode, LoopNode, ParallelNode,
      // ConditionalNode, RecoveryNode, InstructionSetNode) have no intrinsic
      // duration — their cost is the sum of their children, handled by the
      // recursive walk in `_processNode`.
      TargetHeaderNode() ||
      LoopNode() ||
      ParallelNode() ||
      ConditionalNode() ||
      RecoveryNode() ||
      InstructionSetNode() ||
      // TargetScheduler — duration is the sum of its
      // selected child's runtime, accounted for by the recursive walker.
      TargetSchedulerNode() ||
      // LiveStacking — side-effect node that arms the
      // broadcast service and returns immediately. The actual wall-clock
      // cost is paid by sibling exposure nodes, which are accounted for
      // separately. Zero intrinsic duration.
      LiveStackingNode() => Duration.zero,
      // Science: SciencePhotometry — count * exposure + per-frame
      // download overhead, plus one filter change at the start. No
      // dithering during photometry runs.
      SciencePhotometryNode() => Duration(
        milliseconds:
            ((node.count * node.exposureSecs +
                        node.count * overhead.downloadOverheadPerExposureSecs +
                        overhead.filterChangeSecs) *
                    1000)
                .round(),
      ),
      // Plugin nodes execute opaque user-authored logic, whose duration
      // cannot be estimated without round-tripping into the plugin, so the
      // optional per-node timeout is the upper bound. With no timeout
      // configured the estimator returns zero, matching how it treats
      // NotificationNode and other short-running side effects.
      PluginInstructionNode() =>
        node.timeoutSecs != null && node.timeoutSecs! > 0
            ? Duration(seconds: node.timeoutSecs!)
            : Duration.zero,
    };
  }

  /// Helper for [_estimateNodeDuration] that resolves a [WaitTimeNode] to a
  /// concrete duration, supporting both absolute wait-until timestamps and
  /// twilight-relative waits when a location context is available.
  Duration _estimateWaitTimeDuration(
    WaitTimeNode node,
    DateTime currentTime,
    _LocationContext? locationContext,
  ) {
    if (node.waitUntil != null) {
      final waitDuration = node.waitUntil!.difference(currentTime);
      if (waitDuration.isNegative) {
        return Duration.zero;
      }
      return waitDuration;
    }

    if (node.waitForTwilight != null && locationContext != null) {
      final twilightTime = _calculateTwilightWaitTime(
        currentTime,
        node.waitForTwilight!,
        locationContext,
      );
      if (twilightTime != null) {
        final waitDuration = twilightTime.difference(currentTime);
        if (waitDuration.isNegative) {
          return Duration.zero;
        }
        return waitDuration;
      }
    }
    return Duration.zero;
  }
}
