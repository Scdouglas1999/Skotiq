part of '../scheduler_engine.dart';

extension _SchedulerEngineScoring on SchedulerEngine {
  TargetScore _scoreCandidate(SchedulerCandidate c, DateTime now) {
    final rejections = <String>[];

    // Altitude / azimuth.
    final (alt, az) = _calculateAltAz(
      raHours: c.raHours,
      decDegrees: c.decDegrees,
      time: now,
    );

    // Hard constraint: minimum altitude.
    if (alt < _config.minAltitudeDegrees) {
      rejections.add(
        'altitude ${alt.toStringAsFixed(1)}° below site minimum ${_config.minAltitudeDegrees.toStringAsFixed(1)}°',
      );
    }

    // Hard constraint: twilight / Sun altitude. Never image while the Sun is
    // above the configured darkness threshold. This makes the engine wait for
    // darkness at dusk and stop at dawn (the empty-eligible path in
    // _evaluateOnce stops the running sequence once every candidate is
    // rejected).
    final (sunAlt, _) = SkyCalculations.sunAltAz(
      time: now,
      latitudeDegrees: _site.latitudeDegrees,
      longitudeDegrees: _site.longitudeDegrees,
    );
    if (sunAlt > _config.maxSunAltitudeDegrees) {
      rejections.add(
        'Sun ${sunAlt.toStringAsFixed(1)}° above darkness limit ${_config.maxSunAltitudeDegrees.toStringAsFixed(1)}° — too bright to image',
      );
    }

    // Hard constraint: equipment / filter availability.
    final remainingByGoal = <IntegrationGoalProgress>[];
    for (var i = 0; i < c.goals.length; i++) {
      remainingByGoal.add(
        IntegrationGoalProgress(
          goal: c.goals[i],
          capturedCount: c.capturedCounts[i],
        ),
      );
    }
    final stillNeeded = remainingByGoal
        .where((p) => p.remainingFrames > 0)
        .toList();
    if (stillNeeded.isEmpty && c.goals.isNotEmpty) {
      rejections.add('all integration goals complete');
    }
    final filtersOnEquipmentLower = c.availableFilters
        .map((f) => f.toLowerCase())
        .toSet();
    final hasUsableGoal = stillNeeded.isEmpty
        ? c
              .goals
              .isEmpty // no goals at all is fine - free-form imaging
        : stillNeeded.any(
            (p) =>
                // An EMPTY goal filter means "no filter requirement", which is
                // what a rig with no filter wheel has to be able to express.
                // Matching it against the wheel's filter list rejected it —
                // `availableFilters` is empty on such a rig, so `contains('')`
                // is false — and the effect was inverted: a wheel-less target
                // that scheduled fine free-form became UNSCHEDULABLE the moment
                // the operator followed the empty-state prompt and added a goal.
                p.goal.filter.isEmpty ||
                filtersOnEquipmentLower.contains(p.goal.filter.toLowerCase()),
          );
    if (c.goals.isNotEmpty && !hasUsableGoal && stillNeeded.isNotEmpty) {
      final missingFilters = stillNeeded
          .map((p) => p.goal.filter)
          .toSet()
          .toList();
      rejections.add(
        'required filter${missingFilters.length == 1 ? '' : 's'} not in '
        'equipment wheel (${missingFilters.join(", ")})',
      );
    }

    // Hard constraint: time-window / moon / horizon.
    final localTime = now.toUtc().add(_site.localOffset);
    double scheduledWindowBoost = 0.0;
    for (final ct in c.constraints.where((x) => x.enabled)) {
      switch (ct.kind) {
        case TargetConstraintKind.timeWindow:
          if (ct.timeWindow != null &&
              !ct.timeWindow!.containsLocal(localTime)) {
            rejections.add(
              'outside time window ${ct.timeWindow!.startMinutes ~/ 60}:${(ct.timeWindow!.startMinutes % 60).toString().padLeft(2, '0')}-${ct.timeWindow!.endMinutes ~/ 60}:${(ct.timeWindow!.endMinutes % 60).toString().padLeft(2, '0')}',
            );
          }
          break;
        case TargetConstraintKind.moonIlluminationMax:
          final moon = _moonPosition(now);
          if (ct.moonIlluminationMax != null &&
              moon.illumination > ct.moonIlluminationMax!) {
            rejections.add(
              'moon illumination ${(moon.illumination * 100).toStringAsFixed(0)}% exceeds max ${(ct.moonIlluminationMax! * 100).toStringAsFixed(0)}%',
            );
          }
          break;
        case TargetConstraintKind.moonSeparationMin:
          final minSep = ct.moonSeparationMinDeg;
          if (minSep != null) {
            final moon = _moonPosition(now);
            final sep = _angularSeparation(
              ra1Hours: c.raHours,
              dec1Degrees: c.decDegrees,
              ra2Hours: moon.raHours,
              dec2Degrees: moon.decDegrees,
            );
            if (sep < minSep) {
              rejections.add(
                'moon separation ${sep.toStringAsFixed(0)}° below minimum '
                '${minSep.toStringAsFixed(0)}° '
                '(moon ${(moon.illumination * 100).toStringAsFixed(0)}% lit)',
              );
            }
          }
          break;
        case TargetConstraintKind.customHorizon:
          final profile = c.horizonProfiles[ct.customHorizonId];
          if (profile == null) {
            rejections.add(
              'horizon profile ${ct.customHorizonId} not loaded (orchestrator bug)',
            );
          } else {
            final minAlt = profile.minAltitudeAt(az);
            if (alt < minAlt) {
              rejections.add(
                'altitude ${alt.toStringAsFixed(1)}° below horizon profile "${profile.name}" (${minAlt.toStringAsFixed(1)}° at az ${az.toStringAsFixed(0)}°)',
              );
            }
          }
          break;
        case TargetConstraintKind.scheduledWindow:
          // Never a hard-fail — the window adds a score boost during its
          // active range and is silent otherwise. Selection forcing is
          // handled in _evaluateOnce via [_hasActiveScheduledWindow]. We
          // accumulate the boost here so an inactive window contributes
          // nothing.
          final sw = ct.scheduledWindow;
          if (sw != null && sw.containsUtc(now)) {
            scheduledWindowBoost += sw.priorityBoost.clamp(0.0, 1.0);
          }
          break;
      }
    }

    // Compute factors regardless so the UI can show them even on rejected
    // candidates.
    final altitudeFactor = _altitudeFactor(alt);
    final meridianFactor = _meridianFactor(raHours: c.raHours, now: now);
    final (moonFactor, moonDetail) = _moonFactor(
      raHours: c.raHours,
      decDegrees: c.decDegrees,
      now: now,
    );
    final (timeFactor, timeDetail) = _timeRemainingFactor(
      raHours: c.raHours,
      decDegrees: c.decDegrees,
      now: now,
    );
    final filterFactor = _filterCoverageFactor(
      remainingByGoal,
      c.availableFilters,
    );
    final priorityFactor = _userPriorityFactor(c.userPriority);

    final w = _config.weights;
    final factors = <ScoreFactor>[
      ScoreFactor(
        name: 'altitude',
        value: altitudeFactor,
        weight: w.altitude,
        weighted: altitudeFactor * w.altitude,
        detail: 'alt ${alt.toStringAsFixed(1)}°',
      ),
      ScoreFactor(
        name: 'meridian',
        value: meridianFactor,
        weight: w.meridian,
        weighted: meridianFactor * w.meridian,
      ),
      ScoreFactor(
        name: 'moon',
        value: moonFactor,
        weight: w.moon,
        weighted: moonFactor * w.moon,
        detail: moonDetail,
      ),
      ScoreFactor(
        name: 'timeRemaining',
        value: timeFactor,
        weight: w.timeRemaining,
        weighted: timeFactor * w.timeRemaining,
        detail: timeDetail,
      ),
      ScoreFactor(
        name: 'filterCoverage',
        value: filterFactor,
        weight: w.filterCoverage,
        weighted: filterFactor * w.filterCoverage,
      ),
      ScoreFactor(
        name: 'userPriority',
        value: priorityFactor,
        weight: w.userPriority,
        weighted: priorityFactor * w.userPriority,
      ),
      if (scheduledWindowBoost > 0)
        ScoreFactor(
          name: 'scheduledWindow',
          value: scheduledWindowBoost.clamp(0.0, 1.0),
          weight: 1.0,
          weighted: scheduledWindowBoost.clamp(0.0, 1.0),
          detail: 'forced-window boost',
        ),
    ];
    // Fold the soft factors into a total via the shared aggregation contract.
    // The engine uses ADDITIVE mode (Σ of weighted factors, NOT divided by the
    // weight-sum), deliberately different from the planner/node NORMALIZED
    // model; only the aggregation primitive is shared.
    final total = WeightedScore.total([
      for (final f in factors)
        WeightedFactor(name: f.name, value: f.value, weight: f.weight),
    ], mode: WeightedScoreMode.additive);

    return TargetScore(
      targetId: c.targetId,
      targetName: c.name,
      totalScore: total,
      factors: factors,
      hardConstraintFailed: rejections.isNotEmpty,
      rejectionReasons: rejections,
    );
  }

  /// Altitude factor: 0 at minAltitude, 1 at 90°, sin² ramp between.
  double _altitudeFactor(double altDeg) {
    final minAlt = _config.minAltitudeDegrees;
    if (altDeg <= minAlt) return 0.0;
    if (altDeg >= 90.0) return 1.0;
    final normalized = (altDeg - minAlt) / (90.0 - minAlt);
    final s = math.sin(normalized * math.pi / 2);
    return s * s;
  }

  /// Meridian-proximity factor: 1 at the meridian, falling linearly to 0
  /// when hour angle reaches ±6h.
  double _meridianFactor({required double raHours, required DateTime now}) {
    final lst = _localSiderealTime(now);
    var ha = lst - raHours;
    while (ha > 12) {
      ha -= 24;
    }
    while (ha < -12) {
      ha += 24;
    }
    final absH = ha.abs();
    if (absH >= 6.0) return 0.0;
    return 1.0 - (absH / 6.0);
  }

  /// Moon factor: penalty for being close to the moon, weighted by lunar
  /// illumination. Returns 1.0 when target is outside the avoidance
  /// radius OR the moon is dark (illumination ~0).
  (double, String) _moonFactor({
    required double raHours,
    required double decDegrees,
    required DateTime now,
  }) {
    final moon = _moonPosition(now);
    final sep = _angularSeparation(
      ra1Hours: raHours,
      dec1Degrees: decDegrees,
      ra2Hours: moon.raHours,
      dec2Degrees: moon.decDegrees,
    );
    final radius = _config.moonAvoidanceRadiusDegrees;
    if (sep >= radius) {
      return (
        1.0,
        'sep ${sep.toStringAsFixed(0)}° ill ${(moon.illumination * 100).toStringAsFixed(0)}%',
      );
    }
    final closeness = 1.0 - (sep / radius);
    final penalty = closeness * moon.illumination;
    final factor = (1.0 - penalty).clamp(0.0, 1.0);
    return (
      factor,
      'sep ${sep.toStringAsFixed(0)}° ill ${(moon.illumination * 100).toStringAsFixed(0)}%',
    );
  }

  /// Time-remaining factor: how many hours the target stays above the
  /// engine's min altitude tonight, divided by 10 (saturating at 1.0).
  /// Targets with <30 minutes left score very low.
  (double, String) _timeRemainingFactor({
    required double raHours,
    required double decDegrees,
    required DateTime now,
  }) {
    final endHorizon = _hoursUntilSettingBelowMin(
      raHours: raHours,
      decDegrees: decDegrees,
      now: now,
    );
    final hours = endHorizon.clamp(0.0, 10.0);
    final factor = hours / 10.0;
    return (factor, 'visible ${hours.toStringAsFixed(2)} h');
  }

  /// Hours from `now` until the target's altitude drops below min.
  /// Returns 0 if already below, 24 if circumpolar above the threshold.
  double _hoursUntilSettingBelowMin({
    required double raHours,
    required double decDegrees,
    required DateTime now,
  }) {
    final lat = _site.latitudeDegrees * math.pi / 180.0;
    final dec = decDegrees * math.pi / 180.0;
    final minAlt = _config.minAltitudeDegrees * math.pi / 180.0;

    final sinThresh = math.sin(minAlt);
    final center = math.sin(dec) * math.sin(lat);
    final amplitude = (math.cos(dec) * math.cos(lat)).abs();
    final minSin = center - amplitude;
    final maxSin = center + amplitude;
    if (maxSin < sinThresh) return 0.0;
    if (minSin >= sinThresh) return 24.0;

    final denominator = math.cos(dec) * math.cos(lat);
    if (denominator.abs() < 1e-12) return 24.0;
    final cosH = (sinThresh - center) / denominator;
    if (cosH <= -1.0) return 24.0;
    if (cosH >= 1.0) return 0.0;
    final haHorizon = math.acos(cosH) * 180.0 / math.pi / 15.0; // hours

    final lst = _localSiderealTime(now);
    var ha = lst - raHours;
    while (ha > 12) {
      ha -= 24;
    }
    while (ha < -12) {
      ha += 24;
    }
    if (ha.abs() >= haHorizon) return 0.0;
    final hoursToSet = (haHorizon - ha) * 0.9972695663;
    if (hoursToSet < 0) return 0.0;
    return hoursToSet;
  }

  /// Filter coverage factor: fraction of total goal frames still needed,
  /// gated by whether the equipment wheel can produce those filters.
  /// 1.0 when the target has the most uncaptured data available; 0.0 when
  /// fully imaged. Targets with no goals at all score a neutral 0.5 so
  /// they aren't ranked above an actively-incomplete target.
  double _filterCoverageFactor(
    List<IntegrationGoalProgress> progress,
    List<String> availableFilters,
  ) {
    if (progress.isEmpty) return 0.5;
    final available = availableFilters.map((f) => f.toLowerCase()).toSet();
    var totalNeeded = 0;
    var totalGoal = 0;
    for (final p in progress) {
      totalGoal += p.goal.frameCount;
      // Same rule as the admission check and buildSequenceForCandidate: an
      // empty goal filter means "no filter requirement". Testing it for
      // membership of the wheel's filter list scored an unfiltered goal on a
      // wheel-less rig as already-complete, so the autopilot ranked a target
      // it had never imaged below one that was finished.
      if (p.goal.filter.isNotEmpty &&
          !available.contains(p.goal.filter.toLowerCase())) {
        continue;
      }
      totalNeeded += p.remainingFrames;
    }
    if (totalGoal <= 0) return 0.5;
    return (totalNeeded / totalGoal).clamp(0.0, 1.0);
  }

  /// User priority factor: priority field (assumed 0..10) scaled into [0, 1].
  /// Values outside 0..10 are clamped — they're still meaningful, just
  /// saturated.
  double _userPriorityFactor(int priority) {
    final v = priority.clamp(0, 10);
    return v / 10.0;
  }
}
