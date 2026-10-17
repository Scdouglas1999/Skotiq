part of '../smart_night_service.dart';

/// One sidereal day — the period on which a fixed target's horizon crossings
/// repeat. [TargetVisibilityInfo] reports rise/set for a single noon-to-noon
/// day picked by whoever called the scorer, so those instants have to be
/// stepped by whole sidereal days before they mean anything relative to an
/// arbitrary imaging interval.
const Duration _siderealDay = Duration(hours: 23, minutes: 56, seconds: 4);

/// The latest `crossing + n × sidereal day` that is at or before [notAfter].
DateTime _crossingAtOrBefore(DateTime crossing, DateTime notAfter) {
  final cycles =
      notAfter.difference(crossing).inMicroseconds /
      _siderealDay.inMicroseconds;
  return crossing.add(_siderealDay * cycles.floor());
}

/// The earliest `crossing + n × sidereal day` that is at or after [notBefore].
DateTime _crossingAtOrAfter(DateTime crossing, DateTime notBefore) {
  final cycles =
      notBefore.difference(crossing).inMicroseconds /
      _siderealDay.inMicroseconds;
  return crossing.add(_siderealDay * cycles.ceil());
}

/// Pick the longer of two candidate windows, tolerating nulls.
(DateTime, DateTime)? _longerWindow(
  (DateTime, DateTime)? a,
  (DateTime, DateTime)? b,
) {
  if (a == null) return b;
  if (b == null) return a;
  return b.$2.difference(b.$1) > a.$2.difference(a.$1) ? b : a;
}

extension _SmartNightSequenceEmitter on SmartNightService {
  Sequence _emitSingleTargetSequence({
    required EquipmentProfileModel profile,
    required SmartNightPlannedTarget planned,
    required SmartNightStrategy strategy,
    required SmartNightSettings settings,
    required SmartNightContext context,
    required bool includeSessionPreamble,
    required bool? includeSessionShutdown,
    required bool fillWindow,
  }) {
    final nodes = <String, SequenceNode>{};
    final childOrder = <String>[];
    final rootId = SmartNightService._uuid.v4();

    SequenceNode addRootChild(SequenceNode node) {
      childOrder.add(node.id);
      nodes[node.id] = node;
      return node;
    }

    if (includeSessionPreamble) {
      addRootChild(
        CoolCameraNode(
          id: SmartNightService._uuid.v4(),
          name:
              'Cool camera to ${settings.coolDownTargetC.toStringAsFixed(0)}°C',
          targetTemp: settings.coolDownTargetC,
          durationMins: 10.0,
          parentId: rootId,
          orderIndex: childOrder.length - 1,
        ),
      );
      addRootChild(
        UnparkNode(
          id: SmartNightService._uuid.v4(),
          name: 'Unpark mount',
          parentId: rootId,
          orderIndex: childOrder.length - 1,
        ),
      );
    }

    final header = _emitTargetHeaderSubtree(
      profile: profile,
      planned: planned,
      strategy: strategy,
      settings: settings,
      context: context,
      nodesAccumulator: nodes,
      fillWindow: fillWindow,
    );
    final updatedHeader = header.copyWith(
      parentId: rootId,
      orderIndex: childOrder.length,
    );
    nodes[updatedHeader.id] = updatedHeader;
    childOrder.add(updatedHeader.id);

    if (includeSessionShutdown ?? includeSessionPreamble) {
      addRootChild(
        WarmCameraNode(
          id: SmartNightService._uuid.v4(),
          name: 'Warm camera',
          parentId: rootId,
          orderIndex: childOrder.length - 1,
        ),
      );
      addRootChild(
        ParkNode(
          id: SmartNightService._uuid.v4(),
          name: 'Park mount',
          parentId: rootId,
          orderIndex: childOrder.length - 1,
        ),
      );
    }

    final root = InstructionSetNode(
      id: rootId,
      name: '${planned.suggestion.targetName} Plan',
      childIds: childOrder,
    );
    nodes[rootId] = root;

    return Sequence.create(
      name: '${planned.suggestion.targetName} Plan',
      description: _composeSequenceDescription([planned], strategy, settings),
      nodes: nodes,
      rootNodeId: rootId,
    );
  }

  /// Build a CameraExposureSpec for [profile] through the sensor-spec
  /// resolution chain: the user's own entry, then the manufacturer's published
  /// specification. The live camera and the remembered reading are out of
  /// reach on this path — it runs off a profile with no provider container —
  /// but neither reports read noise, full well or QE anyway.
  ///
  /// A field that misses at every tier falls back to the same conservative
  /// planning estimate the shared exposure context uses, so the two agree.
  CameraExposureSpec _cameraSpecFromProfile(EquipmentProfileModel profile) {
    final specs = CameraSensorSpecResolver().resolve(
      CameraSensorSpecInputs(
        cameraName: profile.cameraName,
        cameraId: profile.cameraId,
        gain: profile.defaultGain,
        overrides: _hardwareSpecs.overridesFor(
          cameraName: profile.cameraName,
          cameraId: profile.cameraId,
          gain: profile.defaultGain,
        ),
      ),
    );
    return CameraExposureSpec(
      readNoiseE: specs.readNoiseE?.value ?? _kUnknownCameraReadNoiseE,
      fullWellE: specs.fullWellE?.value ?? _kUnknownCameraFullWellE,
      qePeak: specs.qePeakFraction?.value ?? _kUnknownCameraQePeak,
    );
  }

  /// Conservative stand-ins for a camera whose figures nothing publishes.
  /// Kept in step with `session_optimizer_provider`'s planning estimates.
  static const double _kUnknownCameraReadNoiseE = 3.5;
  static const double _kUnknownCameraFullWellE = 18000;
  static const double _kUnknownCameraQePeak = 0.65;

  /// Seconds of integration budget for one target: sampled time above
  /// [minAltitude] during tonight, capped by rise/set and optional budget.
  double _integrationWindowSecs({
    required TargetSuggestion suggestion,
    required double intervalWindowSecs,
    required double? integrationBudgetHours,
    required SmartNightSettings settings,
  }) {
    final sampledSecs = (suggestion.visibility.hoursAboveMinAlt ?? 0) * 3600;
    final naturalSecs = sampledSecs > 0
        ? math.min(sampledSecs, intervalWindowSecs)
        : intervalWindowSecs;
    final budgetSecs =
        (integrationBudgetHours ?? settings.defaultIntegrationBudgetHours) *
        3600;
    return math.min(naturalSecs, budgetSecs);
  }

  /// Compute the usable window inside `[intervalStart, intervalEnd]`
  /// where the target is above [minAltitude]. Returns null if the
  /// target never reaches that altitude during the interval.
  ///
  /// The visibility's rise/set are the crossings of ONE noon-to-noon day, and
  /// which day that is depends on the date the scorer handed
  /// `AstronomyCalculations.calculateObjectVisibility` — the night scorer
  /// passes the night MIDPOINT, which for any night that straddles midnight is
  /// the morning-after date, so the crossings it gets back describe the NEXT
  /// day. Clipping this interval with those raw instants deleted the entire
  /// night for every target with a finite rise/set (only circumpolar targets,
  /// which report no crossings at all, survived). Horizon crossings repeat
  /// every sidereal day, so step them onto the cycle that actually overlaps
  /// the interval first, then clip.
  (DateTime, DateTime)? _usableTargetWindow({
    required TargetSuggestion suggestion,
    required DateTime intervalStart,
    required DateTime intervalEnd,
    required double minAltitude,
  }) {
    final v = suggestion.visibility;
    final peakAlt = v.peakAltitude ?? v.currentAltitude;
    if (peakAlt < minAltitude) return null;

    (DateTime, DateTime)? clip(DateTime? upStart, DateTime? upEnd) {
      var start = intervalStart;
      var end = intervalEnd;
      if (upStart != null && upStart.isAfter(start)) start = upStart;
      if (upEnd != null && upEnd.isBefore(end)) end = upEnd;
      return start.isBefore(end) ? (start, end) : null;
    }

    final rise = v.riseTime;
    final set = v.setTime;
    // No crossings at all — circumpolar (never-rises was rejected by the peak
    // altitude gate above), so the target is up for the whole interval.
    if (rise == null && set == null) return clip(null, null);
    if (set == null) return clip(_crossingAtOrBefore(rise!, intervalEnd), null);
    if (rise == null) return clip(null, _crossingAtOrAfter(set, intervalStart));

    // Both crossings known: rebuild the up-period that overlaps the interval
    // as [rise, following set]. A target can be up at both ends of the
    // interval and dip below the horizon in the middle (high declination, low
    // culmination inside the dark window), which yields two disjoint usable
    // spans — this returns one contiguous window by contract, so take the
    // longer of the two.
    final risen = _crossingAtOrBefore(rise, intervalEnd);
    final sets = _crossingAtOrAfter(set, risen);
    return _longerWindow(
      clip(risen, sets),
      clip(risen.subtract(_siderealDay), sets.subtract(_siderealDay)),
    );
  }

  String _composeTargetRationale({
    required TargetSuggestion suggestion,
    required List<SmartNightFilterPlan> filterPlans,
    required double windowSecs,
  }) {
    final hours = (windowSecs / 3600).toStringAsFixed(1);
    final filters = filterPlans
        .map((p) => smartNightFilterLabel(p.filterName))
        .join('+');
    final integrationHours =
        (filterPlans.fold<double>(0, (s, p) => s + p.integrationSecs) / 3600)
            .toStringAsFixed(1);
    return 'Selected ${suggestion.targetName} '
        '(score ${suggestion.totalScore.toStringAsFixed(0)}/100, '
        'window ${hours}h). '
        'Imaging $filters for ${integrationHours}h total.';
  }

  /// Compose the actual Sequence object — a complete tree the executor
  /// can run end-to-end:
  ///
  ///   Sequence
  ///   └─ InstructionSet root
  ///      ├─ CoolCamera
  ///      ├─ Unpark
  ///      ├─ PolarAlignment      (optional, only if stale)
  ///      ├─ [TargetScheduler | linear]
  ///      │  └─ TargetHeader … N
  ///      │     ├─ Slew + Center
  ///      │     ├─ StartGuiding
  ///      │     ├─ Autofocus (initial)
  ///      │     ├─ SmartExposure (per strategy filter rotation)
  ///      │     │   carries integration budget + AF cadence triggers
  ///      │     └─ MeridianFlip   (auto-enabled per profile setting)
  ///      ├─ Flats               (optional; cover calibrator path)
  ///      ├─ WarmCamera
  ///      ├─ Park
  ///      └─ WeatherRecovery     (parallel; optional)
  Sequence _emitSequence({
    required EquipmentProfileModel profile,
    required double latitudeDeg,
    required SmartNightStrategy strategy,
    required SmartNightSettings settings,
    required SmartNightContext context,
    required List<SmartNightPlannedTarget> planned,
    SmartNightFlatPlan? flatPlan,
  }) {
    final nodes = <String, SequenceNode>{};
    final childOrder = <String>[];

    final rootId = SmartNightService._uuid.v4();
    SequenceNode addRootChild(SequenceNode node) {
      childOrder.add(node.id);
      nodes[node.id] = node;
      return node;
    }

    // -- 1. Cool camera (always — needed before any imaging)
    addRootChild(
      CoolCameraNode(
        id: SmartNightService._uuid.v4(),
        name: 'Cool camera to ${settings.coolDownTargetC.toStringAsFixed(0)}°C',
        targetTemp: settings.coolDownTargetC,
        durationMins: 10.0,
        parentId: rootId,
        orderIndex: childOrder.length - 1,
      ),
    );

    // -- 2. Unpark mount
    addRootChild(
      UnparkNode(
        id: SmartNightService._uuid.v4(),
        name: 'Unpark mount',
        parentId: rootId,
        orderIndex: childOrder.length - 1,
      ),
    );

    // -- 3. Polar alignment if stale
    if (settings.prependPolarAlignmentIfStale &&
        context.daysSinceLastPolarAlignment != null &&
        context.daysSinceLastPolarAlignment! >
            settings.polarAlignmentStaleAfterDays) {
      addRootChild(
        PolarAlignmentNode(
          id: SmartNightService._uuid.v4(),
          name:
              'Polar alignment '
              '(${context.daysSinceLastPolarAlignment} days since last)',
          startFromCurrent: true,
          isNorth: latitudeSign(latitudeDeg),
          parentId: rootId,
          orderIndex: childOrder.length - 1,
        ),
      );
    }

    // -- 4. Targets
    final targetHeaders = <TargetHeaderNode>[];
    for (final p in planned) {
      final targetHeader = _emitTargetHeaderSubtree(
        profile: profile,
        planned: p,
        strategy: strategy,
        settings: settings,
        context: context,
        nodesAccumulator: nodes,
      );
      targetHeaders.add(targetHeader);
    }
    if (targetHeaders.length > 1 &&
        settings.useSchedulerForMultiTarget &&
        targetHeaders.length >= settings.schedulerTargetThreshold) {
      // Wrap in a TargetSchedulerNode for >=3 targets so the executor
      // can swap between them based on score / altitude during the
      // night.
      final schedulerId = SmartNightService._uuid.v4();
      final scheduler = TargetSchedulerNode(
        id: schedulerId,
        name: 'Target scheduler (${targetHeaders.length} targets)',
        childIds: targetHeaders.map((h) => h.id).toList(),
        parentId: rootId,
        orderIndex: childOrder.length,
        // Opt the in-sequence scheduler into adaptive sky-conditions swapping
        // when the preset is on. This is a config value on the in-sequence
        // node — the already-built swap engine consults it; it never touches
        // the live autopilot's W1–W5 decision math. recomputeEveryNExposures
        // already defaults to 5 (ON) on the node ctor.
        swapOnConditionsBelow: settings.adaptiveTargetSwap
            ? SmartNightSettings.adaptiveSwapConditionsFloor
            : null,
        // Carry the operator's site horizon into the behavior-tree scheduler
        // so it respects the same azimuth horizon mask the live autopilot
        // already uses (an additive hard-reject layer — only ever makes a
        // candidate less runnable, never more).
        horizonProfile: context.horizonProfile,
      );
      // Re-parent the headers to the scheduler.
      for (var i = 0; i < targetHeaders.length; i++) {
        final updated = targetHeaders[i].copyWith(
          parentId: schedulerId,
          orderIndex: i,
        );
        nodes[updated.id] = updated;
      }
      childOrder.add(schedulerId);
      nodes[schedulerId] = scheduler;
    } else {
      // Linear chain — append each TargetHeader directly under the root.
      for (var i = 0; i < targetHeaders.length; i++) {
        final updated = targetHeaders[i].copyWith(
          parentId: rootId,
          orderIndex: childOrder.length,
        );
        nodes[updated.id] = updated;
        childOrder.add(updated.id);
      }
    }

    // -- 5. Flats (if user has a cover calibrator AND opted in)
    if (settings.includeFlatsAtEnd && settings.hasCoverCalibrator) {
      final filtersForFlats = <String>{};
      for (final pt in planned) {
        for (final fp in pt.filterPlans) {
          filtersForFlats.add(fp.filterName);
        }
      }
      _emitPanelFlats(
        profile: profile,
        settings: settings,
        filtersForFlats: filtersForFlats,
        flatPlan: flatPlan,
        rootId: rootId,
        nodes: nodes,
        childOrder: childOrder,
        addRootChild: addRootChild,
      );
    } else if (settings.includeFlatsAtEnd && !settings.hasCoverCalibrator) {
      // No panel → leave a NotificationNode reminder; we never schedule
      // unattended sky-flats. The user gets a heads-up at session end.
      addRootChild(
        NotificationNode(
          id: SmartNightService._uuid.v4(),
          name: 'Flats reminder',
          title: 'No flat panel detected',
          message:
              'No flat panel detected — remember to shoot manual flats next '
              'session for this equipment profile.',
          level: NotificationLevel.info,
          explicitTransports: const [NotificationTransportKind.inApp],
          parentId: rootId,
          orderIndex: childOrder.length - 1,
        ),
      );
    }

    // -- 5b. Dark Library Refresh (opt-in; only when settings flag set AND
    // structured requirements are present). The camera is still at its
    // cooling target at this point, which matches the lights' temperature
    // bucket — so the captured darks calibrate the lights we just shot.
    // Placed AFTER flats (when flats run) so the cover sequencing is
    // not interleaved, and BEFORE warm/park so the cooled sensor state
    // is preserved.
    if (settings.autoScheduleMissingDarks &&
        context.missingDarkRequirements.isNotEmpty) {
      final framesPerCombo = math.max(1, settings.darkFramesPerRequirement);
      final darkGroupId = SmartNightService._uuid.v4();
      final darkChildren = <SequenceNode>[];
      final coverAvailable = settings.hasCoverCalibrator;
      if (coverAvailable) {
        darkChildren.add(
          CloseCoverNode(
            id: SmartNightService._uuid.v4(),
            name: 'Close cover for darks',
            parentId: darkGroupId,
          ),
        );
      } else {
        // No cover → the executor can't physically block light; emit a
        // notification so the user covers the OTA manually before the
        // dark run begins. We do NOT silently skip — capturing "darks"
        // with the sensor still seeing sky light would corrupt the
        // library.
        darkChildren.add(
          NotificationNode(
            id: SmartNightService._uuid.v4(),
            name: 'Cover OTA for darks',
            title: 'Cover the OTA',
            message:
                'Dark library refresh is about to start. Cover the OTA '
                'to block all stray light before continuing — uncovered '
                '"darks" will corrupt the library.',
            level: NotificationLevel.warning,
            explicitTransports: const [NotificationTransportKind.inApp],
            parentId: darkGroupId,
          ),
        );
      }
      for (final req in context.missingDarkRequirements) {
        final tempLabel = req.targetTemp == null
            ? 'any'
            : '${req.targetTemp!.toStringAsFixed(0)}°C';
        darkChildren.add(
          ExposureNode(
            id: SmartNightService._uuid.v4(),
            name:
                'Darks — ${req.durationSecs.toStringAsFixed(0)}s '
                '@ G${req.gain} ($tempLabel, bin ${req.binX}x${req.binY})',
            durationSecs: req.durationSecs,
            count: framesPerCombo,
            frameType: FrameType.dark,
            gain: req.gain,
            offset: req.offset,
            binning: _binningModeForInt(req.binX),
            ditherEvery: 0,
            parentId: darkGroupId,
          ),
        );
      }
      if (coverAvailable) {
        darkChildren.add(
          OpenCoverNode(
            id: SmartNightService._uuid.v4(),
            name: 'Open cover after darks',
            parentId: darkGroupId,
          ),
        );
      }
      for (var i = 0; i < darkChildren.length; i++) {
        final reparented = _reparented(darkChildren[i], darkGroupId, i);
        nodes[reparented.id] = reparented;
      }
      final darkGroup = InstructionSetNode(
        id: darkGroupId,
        name:
            'Dark Library Refresh — '
            '${context.missingDarkRequirements.length} combinations',
        parentId: rootId,
        orderIndex: childOrder.length,
        childIds: darkChildren.map((n) => n.id).toList(),
      );
      nodes[darkGroupId] = darkGroup;
      childOrder.add(darkGroupId);
    }

    // -- 6. Warm camera + park (always — clean shutdown)
    addRootChild(
      WarmCameraNode(
        id: SmartNightService._uuid.v4(),
        name: 'Warm camera',
        parentId: rootId,
        orderIndex: childOrder.length - 1,
      ),
    );
    addRootChild(
      ParkNode(
        id: SmartNightService._uuid.v4(),
        name: 'Park mount',
        parentId: rootId,
        orderIndex: childOrder.length - 1,
      ),
    );

    // -- 7. Weather recovery (optional, prepended as a sibling under
    // the root so the executor's parallel watchdog can interrupt the
    // imaging branch when the storm arrives). Condition lives in
    // [SmartNightService.willInjectWeatherRecovery] so the plan preview shares the same
    // threshold.
    if (SmartNightService.willInjectWeatherRecovery(context)) {
      addRootChild(
        RecoveryNode(
          id: SmartNightService._uuid.v4(),
          name: 'Cloud arriving — auto-park',
          triggerType: TriggerType.weatherUnsafe,
          recoveryAction: RecoveryActionType.parkAndAbort,
          maxRetries: 1,
          parentId: rootId,
          orderIndex: childOrder.length - 1,
          comment:
              'Cloud forecast probability '
              '${(context.rainOrCloudProbability! * 100).toStringAsFixed(0)}% '
              'within next ${context.cloudArrivalLeadTimeMinutes} min',
        ),
      );
    }

    // Compose the root.
    final root = InstructionSetNode(
      id: rootId,
      name:
          'Smart Night — '
          '${planned.map((p) => p.suggestion.targetName).join(", ")}',
      childIds: childOrder,
    );
    nodes[rootId] = root;

    return Sequence.create(
      name: _composeSequenceName(planned, strategy),
      description: _composeSequenceDescription(planned, strategy, settings),
      nodes: nodes,
      rootNodeId: rootId,
    );
  }

  /// Emit the end-of-night panel-flat instruction group.
  ///
  /// Flats are emitted ONLY for filters that have an ADU-calibrated exposure
  /// in [flatPlan] (sourced from the `flat_history` table, where each row
  /// records the exposure that hit a target histogram percentage). Each
  /// calibrated filter uses the SAME exposure + panel brightness its recorded
  /// row achieved the ADU target with — never a blind fixed exposure.
  ///
  /// Filters with no calibration (and the case where NO calibration data is
  /// available at all) produce a loud [NotificationNode] reminder instead of
  /// a guessed exposure: an uncalibrated panel flat that misses half-well does
  /// not calibrate the lights, so the run fails loud rather than capturing
  /// wrong data.
  void _emitPanelFlats({
    required EquipmentProfileModel profile,
    required SmartNightSettings settings,
    required Set<String> filtersForFlats,
    required SmartNightFlatPlan? flatPlan,
    required String rootId,
    required Map<String, SequenceNode> nodes,
    required List<String> childOrder,
    required SequenceNode Function(SequenceNode) addRootChild,
  }) {
    // Resolve the calibrated exposure for each requested filter, partitioning
    // into "has ADU calibration" vs "needs one-time calibration".
    final calibrated = <String, SmartNightFlatExposure>{};
    final uncalibrated = <String>[];
    for (final filter in filtersForFlats) {
      final exposure = flatPlan?.perFilter[filter];
      if (exposure != null && exposure.exposureSecs > 0) {
        calibrated[filter] = exposure;
      } else {
        uncalibrated.add(filter);
      }
    }
    uncalibrated.sort();

    // No filter has ADU-calibrated data → do NOT emit blind flats. Surface a
    // loud reminder so the user runs the Flat Wizard once to learn the
    // exposures.
    if (calibrated.isEmpty) {
      addRootChild(
        NotificationNode(
          id: SmartNightService._uuid.v4(),
          name: 'Flats need calibration',
          title: 'Automated flats skipped — no calibrated exposures',
          message:
              'Smart Night will not shoot blind flats. Run the Flat Wizard '
              'once for ${uncalibrated.isEmpty ? "your filters" : uncalibrated.map(smartNightFilterLabel).join(", ")} '
              'so the ADU-targeted exposure + panel brightness are learned; '
              'after that, Smart Night will reuse them automatically.',
          level: NotificationLevel.warning,
          explicitTransports: const [NotificationTransportKind.inApp],
          parentId: rootId,
          orderIndex: childOrder.length - 1,
        ),
      );
      return;
    }

    final flatGroupId = SmartNightService._uuid.v4();
    final flatGroup = InstructionSetNode(
      id: flatGroupId,
      name: 'Flats — ${calibrated.length} filters',
      parentId: rootId,
      orderIndex: childOrder.length,
      childIds: const [],
    );
    final flatChildren = <SequenceNode>[];

    flatChildren.add(
      CloseCoverNode(
        id: SmartNightService._uuid.v4(),
        name: 'Close cover',
        parentId: flatGroupId,
      ),
    );

    // Group calibrated filters by the panel brightness that produced their
    // target ADU so the panel is set once per brightness level (matching the
    // calibration conditions). Filters whose calibration came from sky flats
    // (panelBrightness == null) cannot drive the panel to a known level — they
    // are reported as uncalibrated for the panel path below.
    final byBrightness = <int, List<SmartNightFlatExposure>>{};
    for (final exposure in calibrated.values) {
      final brightness = exposure.panelBrightness;
      if (brightness == null) {
        uncalibrated.add(exposure.filterName);
        continue;
      }
      byBrightness.putIfAbsent(brightness, () => []).add(exposure);
    }
    uncalibrated.sort();

    final sortedBrightness = byBrightness.keys.toList()..sort();
    for (final brightness in sortedBrightness) {
      flatChildren.add(
        CalibratorOnNode(
          id: SmartNightService._uuid.v4(),
          name: 'Calibrator on (brightness $brightness)',
          brightness: brightness,
          parentId: flatGroupId,
        ),
      );
      final exposures = byBrightness[brightness]!
        ..sort((a, b) => a.filterName.compareTo(b.filterName));
      for (final exposure in exposures) {
        final unfiltered = exposure.filterName.trim().isEmpty;
        if (!unfiltered) {
          flatChildren.add(
            FilterChangeNode(
              id: SmartNightService._uuid.v4(),
              name: 'Change filter → ${exposure.filterName}',
              filterName: exposure.filterName,
              parentId: flatGroupId,
            ),
          );
        }
        flatChildren.add(
          ExposureNode(
            id: SmartNightService._uuid.v4(),
            name:
                'Flats — ${smartNightFilterLabel(exposure.filterName)} '
                '(${exposure.exposureSecs.toStringAsFixed(2)}s @ '
                '${exposure.histogramTargetPercent.toStringAsFixed(0)}% hist)',
            durationSecs: exposure.exposureSecs,
            count: settings.flatCountPerFilter,
            frameType: FrameType.flat,
            filter: unfiltered ? null : exposure.filterName,
            gain: profile.defaultGain,
            offset: profile.defaultOffset,
            ditherEvery: 0, // no dither for flats
            parentId: flatGroupId,
            comment:
                'ADU-calibrated: previously hit '
                '${exposure.actualAdu} ADU at panel brightness $brightness.',
          ),
        );
      }
    }

    flatChildren.add(
      CalibratorOffNode(
        id: SmartNightService._uuid.v4(),
        name: 'Calibrator off',
        parentId: flatGroupId,
      ),
    );
    flatChildren.add(
      OpenCoverNode(
        id: SmartNightService._uuid.v4(),
        name: 'Open cover',
        parentId: flatGroupId,
      ),
    );
    for (var i = 0; i < flatChildren.length; i++) {
      final reparented = _reparented(flatChildren[i], flatGroupId, i);
      nodes[reparented.id] = reparented;
    }
    nodes[flatGroupId] = flatGroup.copyWith(
      childIds: flatChildren.map((n) => n.id).toList(),
    );
    childOrder.add(flatGroupId);

    // Any requested filter without a panel-calibrated exposure gets a loud
    // reminder appended after the flat group — never a blind exposure.
    if (uncalibrated.isNotEmpty) {
      addRootChild(
        NotificationNode(
          id: SmartNightService._uuid.v4(),
          name: 'Flats skipped for uncalibrated filters',
          title: 'Some filters have no calibrated flat exposure',
          message:
              'Flats were captured for '
              '${calibrated.keys.where((f) => !uncalibrated.contains(f)).map(smartNightFilterLabel).join(", ")}. '
              'No ADU-calibrated panel exposure exists for: '
              '${uncalibrated.toSet().map(smartNightFilterLabel).join(", ")}. Run the Flat Wizard '
              'once for these filters so Smart Night can reuse the exposures.',
          level: NotificationLevel.warning,
          explicitTransports: const [NotificationTransportKind.inApp],
          parentId: rootId,
          orderIndex: childOrder.length - 1,
        ),
      );
    }
  }

  /// Build the per-target sub-tree under a TargetHeaderNode and write
  /// each node into [nodesAccumulator]. Returns the header itself so
  /// the caller can re-parent it under the scheduler / root.
  TargetHeaderNode _emitTargetHeaderSubtree({
    required EquipmentProfileModel profile,
    required SmartNightPlannedTarget planned,
    required SmartNightStrategy strategy,
    required SmartNightSettings settings,
    required SmartNightContext context,
    required Map<String, SequenceNode> nodesAccumulator,
    bool fillWindow = false,
  }) {
    final headerId = SmartNightService._uuid.v4();
    final children = <SequenceNode>[];

    // 1. Slew to target
    children.add(
      SlewNode(
        id: SmartNightService._uuid.v4(),
        name: 'Slew → ${planned.suggestion.targetName}',
        useTargetCoords: true,
        parentId: headerId,
      ),
    );

    // 2. Center via plate solve
    children.add(
      CenterNode(
        id: SmartNightService._uuid.v4(),
        name: 'Center via plate solve',
        accuracyArcsec: 5.0,
        maxAttempts: 5,
        useTargetCoords: true,
        parentId: headerId,
      ),
    );

    // 3. Initial autofocus — BEFORE guiding. Running autofocus moves the
    //    focuser through a V-curve (and the executor stops guiding for the
    //    duration), so starting guiding first would just be interrupted. Focus
    //    first, then guide on the now-sharp stars.
    children.add(
      AutofocusNode(
        id: SmartNightService._uuid.v4(),
        name: 'Initial autofocus',
        useSettingsDefaults: true,
        parentId: headerId,
      ),
    );

    // 4. Start guiding when profile has a guider and target is usable. Placed
    //    after the initial autofocus so the freshly-started guiding is not
    //    immediately torn down by it.
    if (_profileHasGuider(profile) &&
        (planned.suggestion.visibility.peakAltitude ??
                planned.suggestion.visibility.currentAltitude) >=
            settings.minAltitudeDeg) {
      children.add(
        StartGuidingNode(
          id: SmartNightService._uuid.v4(),
          name: 'Start guiding',
          autoSelectStar: true,
          parentId: headerId,
        ),
      );
    }

    // 5. The capture block — the heart of the night. A rig with no filter
    //    wheel gets a plain ExposureNode: SmartExposure exists to rotate
    //    filters, and emitting one would put a ChangeFilter instruction (and
    //    a filter-wheel requirement) into a sequence that has no wheel to
    //    drive.
    children.add(
      planned.isUnfiltered
          ? _emitUnfilteredExposure(
              profile: profile,
              planned: planned,
              settings: settings,
              parentId: headerId,
            )
          : _emitSmartExposure(
              profile: profile,
              planned: planned,
              settings: settings,
              context: context,
              fillWindow: fillWindow,
              parentId: headerId,
            ),
    );

    if (fillWindow && planned.isUnfiltered) {
      final capture = children.removeLast();
      final loop = LoopNode(
        name: 'Image until end of window',
        conditionType: LoopConditionType.untilTime,
        repeatUntil: planned.windowEnd,
        parentId: headerId,
        childIds: [capture.id],
      );
      nodesAccumulator[capture.id] = capture.copyWith(parentId: loop.id);
      children.add(loop);
    }

    // 6. Optional meridian flip recovery — only inject when the target
    // crosses the meridian during its imaging window. The executor's
    // meridian-flip path is already enabled at the profile level; this
    // node makes the flip explicit on the timeline so Run Dashboard
    // shows it. Condition lives in [SmartNightService.willInjectMeridianFlip] so the plan
    // preview shares the exact same rule.
    if (SmartNightService.willInjectMeridianFlip(planned)) {
      children.add(
        MeridianFlipNode(
          id: SmartNightService._uuid.v4(),
          name: 'Meridian flip',
          autoCenter: true,
          refocusAfter: true,
          resumeGuiding: true,
          parentId: headerId,
          useGlobalDefaults: false,
        ),
      );
    }

    final integrationSecsTotal = planned.filterPlans.fold<double>(
      0,
      (sum, fp) => sum + fp.integrationSecs,
    );
    final perFilterBudget = <String, FilterBudgetEntry>{
      for (final fp in planned.filterPlans)
        fp.filterName: FilterBudgetEntry.absolute(fp.integrationSecs),
    };
    final integrationBudget = IntegrationBudget(
      totalSecs: integrationSecsTotal,
      perFilter: perFilterBudget,
      stopOnBudgetMet: !fillWindow,
    );

    final header = TargetHeaderNode(
      id: headerId,
      name: 'Target — ${planned.suggestion.targetName}',
      targetName: planned.suggestion.targetName,
      raHours: planned.suggestion.raHours,
      decDegrees: planned.suggestion.decDegrees,
      priority: 0,
      minAltitude: settings.minAltitudeDeg,
      startAfter: planned.windowStart,
      endBefore: planned.windowEnd,
      integrationBudget: integrationBudget,
      // Explicit triggers take precedence over legacy time fields in the
      // executor, so include both altitude and time in the conditions.
      startWhen: AndTrigger([
        AltitudeAboveTrigger(settings.minAltitudeDeg),
        TimeAfterTrigger(planned.windowStart.millisecondsSinceEpoch ~/ 1000),
      ]),
      endWhen: OrTrigger([
        AltitudeBelowTrigger(settings.minAltitudeDeg),
        TimeAfterTrigger(planned.windowEnd.millisecondsSinceEpoch ~/ 1000),
      ]),
      childIds: children.map((c) => c.id).toList(),
    );

    for (var i = 0; i < children.length; i++) {
      final reparented = _reparented(children[i], headerId, i);
      nodesAccumulator[reparented.id] = reparented;
    }
    nodesAccumulator[headerId] = header;
    return header;
  }

  /// Build the SmartExposureNode for a target — rotates filters per
  /// the strategy, applies the AF cadence trigger, optionally toggles
  /// adaptive exposures, and clamps the total integration to the per-
  /// target budget.
  SmartExposureNode _emitSmartExposure({
    required EquipmentProfileModel profile,
    required SmartNightPlannedTarget planned,
    required SmartNightSettings settings,
    required SmartNightContext context,
    required String parentId,
    bool fillWindow = false,
  }) {
    final plans = planned.filterPlans.map((fp) {
      final defaults = resolveCameraCaptureDefaults(
        cameraName: profile.cameraName,
        filterName: fp.filterName,
        profileGain: profile.defaultGain,
        profileOffset: profile.defaultOffset,
        library: _cameraLibrary,
      );
      return FilterPlan(
        filterName: fp.filterName,
        count: fp.count,
        durationSecs: fp.durationSecs,
        gain: settings.gainOverride ?? defaults.gain,
        offset: settings.offsetOverride ?? defaults.offset,
        binning: _binningModeForInt(profile.defaultBinX),
        ditherEvery: settings.ditherEveryFrames,
      );
    }).toList();
    return SmartExposureNode(
      id: SmartNightService._uuid.v4(),
      name:
          'Smart Exposure — '
          '${planned.filterPlans.map((p) => p.filterName).join("+")}',
      plans: plans,
      rotateFilters: true,
      ditherOnFilterChange: false,
      integrationBudgetSecs: fillWindow ? 0 : planned.integrationSecs,
      loopUntilStopped: fillWindow,
      batchSize: 1,
      parentId: parentId,
    );
  }

  /// Build the capture block for a rig with no filter wheel.
  ///
  /// `filter` and `filterIndex` are left null so the executor takes the
  /// frames with whatever is in the light path and never asks a wheel that
  /// isn't there to move — the same contract manual capture uses.
  ExposureNode _emitUnfilteredExposure({
    required EquipmentProfileModel profile,
    required SmartNightPlannedTarget planned,
    required SmartNightSettings settings,
    required String parentId,
  }) {
    final plan = planned.filterPlans.single;
    final defaults = resolveCameraCaptureDefaults(
      cameraName: profile.cameraName,
      filterName: plan.filterName,
      profileGain: profile.defaultGain,
      profileOffset: profile.defaultOffset,
      library: _cameraLibrary,
    );
    return ExposureNode(
      id: SmartNightService._uuid.v4(),
      name:
          'Exposures — ${plan.count} × '
          '${plan.durationSecs.toStringAsFixed(0)}s (no filter)',
      durationSecs: plan.durationSecs,
      gain: settings.gainOverride ?? defaults.gain,
      offset: settings.offsetOverride ?? defaults.offset,
      binning: _binningModeForInt(profile.defaultBinX),
      count: plan.count,
      frameType: FrameType.light,
      ditherEvery: settings.ditherEveryFrames,
      parentId: parentId,
    );
  }

  /// Re-parent a node and update its orderIndex. Uses copyWith so we
  /// stay polymorphic across SequenceNode subclasses.
  SequenceNode _reparented(SequenceNode node, String parentId, int orderIndex) {
    return node.copyWith(parentId: parentId, orderIndex: orderIndex);
  }

  /// Map a numeric binning factor (1..4) onto its [BinningMode] enum value.
  /// Used when materialising dark-library [DarkFrameRequirement]s into
  /// [ExposureNode]s — the requirement stores binX/binY as ints, the
  /// node stores a [BinningMode]. Anything outside 1..4 falls back to 1x1
  /// because the executor cannot drive non-square / >4× binning paths.
  BinningMode _binningModeForInt(int bin) {
    switch (bin) {
      case 2:
        return BinningMode.two;
      case 3:
        return BinningMode.three;
      case 4:
        return BinningMode.four;
      case 1:
      default:
        return BinningMode.one;
    }
  }
}
