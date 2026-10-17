part of '../sequence_repository.dart';

extension _SequenceRepositoryNodeEncoder on SequenceRepository {
  Map<String, dynamic> _nodeToProperties(SequenceNode node) {
    // Exhaustive switch on the sealed SequenceNode hierarchy. Adding a new
    // node subtype produces a compile-time error here, preventing silent
    // empty-property persistence that would lose user-configured settings.
    return switch (node) {
      ExposureNode() => {
        'durationSecs': node.durationSecs,
        'count': node.count,
        'frameType': node.frameType.name,
        'filter': node.filter,
        'filterIndex': node.filterIndex,
        'gain': node.gain,
        'offset': node.offset,
        'binning': _binningToString(node.binning),
        'ditherEvery': node.ditherEvery,
        'triggers': node.triggers,
        // Per-node adaptive-exposure override. `null`
        // means "inherit from global default"; we serialise `null` too
        // so the absent-key vs. explicit-null distinction is
        // preserved on reload.
        'adaptiveExposure': node.adaptiveExposure?.toJson(),
      },
      SlewNode() => {
        'useTargetCoords': node.useTargetCoords,
        'customRa': node.customRa,
        'customDec': node.customDec,
      },
      CenterNode() => {
        'useTargetCoords': node.useTargetCoords,
        'customRa': node.customRa,
        'customDec': node.customDec,
        'accuracyArcsec': node.accuracyArcsec,
        'maxAttempts': node.maxAttempts,
        'exposureDuration': node.exposureDuration,
        'filter': node.filter,
      },
      AutofocusNode() => {
        'method': _autofocusMethodToString(node.method),
        'stepSize': node.stepSize,
        'stepsOut': node.stepsOut,
        'exposuresPerPoint': node.exposuresPerPoint,
        'exposureDuration': node.exposureDuration,
        'useSettingsDefaults': node.useSettingsDefaults,
        'maxDurationSecs': node.maxDurationSecs,
      },
      DitherNode() => {
        'pixels': node.pixels,
        'settlePixels': node.settlePixels,
        'settleTime': node.settleTime,
        'settleTimeout': node.settleTimeout,
        'raOnly': node.raOnly,
        'pattern': node.pattern.name,
        'gridSize': node.gridSize,
      },
      FilterChangeNode() => {
        'filterName': node.filterName,
        'filterPosition': node.filterPosition,
      },
      CoolCameraNode() => {
        'targetTemp': node.targetTemp,
        'durationMins': node.durationMins,
      },
      WarmCameraNode() => {
        'ratePerMin': node.ratePerMin,
        'targetTemp': node.targetTemp,
      },
      RotatorNode() => {
        'targetAngle': node.targetAngle,
        'relative': node.relative,
      },
      WaitTimeNode() => {
        'waitUntil': node.waitUntil?.millisecondsSinceEpoch,
        'waitForTwilight': node.waitForTwilight != null
            ? _twilightToString(node.waitForTwilight!)
            : null,
      },
      DelayNode() => {'seconds': node.seconds},
      NotificationNode() => {
        'title': node.title,
        'message': node.message,
        'level': _notificationLevelToString(node.level),
        if (node.explicitTransports != null)
          'explicitTransports': node.explicitTransports!
              .map((t) => t.storageKey)
              .toList(),
      },
      ScriptNode() => {
        'scriptPath': node.scriptPath,
        'arguments': node.arguments,
        'timeoutSecs': node.timeoutSecs,
      },
      TargetHeaderNode() => {
        'targetName': node.targetName,
        'raHours': node.raHours,
        'decDegrees': node.decDegrees,
        'rotation': node.rotation,
        'minAltitude': node.minAltitude,
        'maxAltitude': node.maxAltitude,
        'priority': node.priority,
        'startAfter': node.startAfter?.millisecondsSinceEpoch,
        'endBefore': node.endBefore?.millisecondsSinceEpoch,
        'mosaicPanel': node.mosaicPanel?.toJson(),
        // Persist the per-target integration budget
        // when configured. `null`/absent means "no budget enforcement"
        // — current default behaviour for existing sequences.
        if (node.integrationBudget != null)
          'integrationBudget': node.integrationBudget!.toJson(),
        // Per-target altitude/time crossings. Both fields
        // are optional; absent => no gate, which is the legacy
        // default for existing sequences.
        if (node.startWhen != null) 'startWhen': node.startWhen!.toJson(),
        if (node.endWhen != null) 'endWhen': node.endWhen!.toJson(),
        'triggerPollIntervalSecs': node.triggerPollIntervalSecs,
      },
      LoopNode() => {
        'conditionType': _loopConditionToString(node.conditionType),
        'repeatCount': node.repeatCount,
        'repeatUntil': node.repeatUntil?.millisecondsSinceEpoch,
        'repeatUntilAltitude': node.repeatUntilAltitude,
        'integrationTimeTarget': node.integrationTimeTarget,
        'maxSafetyIterations': node.maxSafetyIterations,
      },
      ParallelNode() => {'requiredSuccesses': node.requiredSuccesses},
      ConditionalNode() => {
        'conditionType': _conditionalTypeToString(node.conditionType),
        'thresholdValue': node.thresholdValue,
        'thresholdTime': node.thresholdTime?.millisecondsSinceEpoch,
        // Audit C2 — per-monitor targeting for multi-safety setups.
        'safetyMonitorId': node.safetyMonitorId,
      },
      RecoveryNode() => {
        'recoveryAction': _recoveryActionToString(node.recoveryAction),
        'maxRetries': node.maxRetries,
        'triggerType': node.triggerType?.name,
        'triggerThreshold': node.triggerThreshold,
        'hfrThresholdPercent': node.hfrThresholdPercent,
        'hfrConsecutiveFrames': node.hfrConsecutiveFrames,
        'triggerEveryNFrames': node.triggerEveryNFrames,
        'focusDriftWindowSize': node.focusDriftWindowSize,
        'focusDriftMinIncreasingCount': node.focusDriftMinIncreasingCount,
        'focusDriftMinTotalIncrease': node.focusDriftMinTotalIncrease,
        'guidingFailedDurationSecs': node.guidingFailedDurationSecs,
        'cloudMinutesBefore': node.cloudMinutesBefore,
        'cloudCoverageThresholdPercent': node.cloudCoverageThresholdPercent,
        'cloudOpeningMinDurationSecs': node.cloudOpeningMinDurationSecs,
        'cloudCoverMaxPercent': node.cloudCoverMaxPercent,
        'cloudCoverDurationSecs': node.cloudCoverDurationSecs,
        'transparencyBelowThreshold': node.transparencyBelowThreshold,
        'transparencyDurationSecs': node.transparencyDurationSecs,
      },
      MeridianFlipNode() => {
        'triggerMethod': node.triggerMethod.name,
        'minutesPastMeridian': node.minutesPastMeridian,
        'minutesBeforeLimit': node.minutesBeforeLimit,
        'hourAngleThreshold': node.hourAngleThreshold,
        'pauseGuiding': node.pauseGuiding,
        'autoCenter': node.autoCenter,
        'refocusAfter': node.refocusAfter,
        'settleTime': node.settleTime,
        'resumeGuiding': node.resumeGuiding,
        'maxRetries': node.maxRetries,
        'failureAction': node.failureAction.name,
        // Persist the override flag so reopening the sequence preserves
        // whether the user pinned per-node values or pulls from settings.
        'useGlobalDefaults': node.useGlobalDefaults,
      },
      OpenDomeNode() => {'shutterOnly': node.shutterOnly},
      CloseDomeNode() => {'shutterOnly': node.shutterOnly},
      ParkDomeNode() => {'shutterOnly': node.shutterOnly},
      StartGuidingNode() => {
        'settlePixels': node.settlePixels,
        'settleTime': node.settleTime,
        'settleTimeout': node.settleTimeout,
        'autoSelectStar': node.autoSelectStar,
      },
      PolarAlignmentNode() => {
        'exposureDuration': node.exposureDuration,
        'binning': node.binning,
        'startAltitude': node.startAltitude,
        'rotationStep': node.rotationStep,
        'gain': node.gain,
        'offset': node.offset,
        'startFromCurrent': node.startFromCurrent,
        'isNorth': node.isNorth,
        'manualSlew': node.manualSlew,
      },
      // TargetScheduler — persist all eight knobs so reload
      // round-trips structurally and the validator can re-check the weight
      // sum / scheduler-children rules on load.
      TargetSchedulerNode() => {
        'altitudeWeight': node.altitudeWeight,
        'moonDistanceWeight': node.moonDistanceWeight,
        'transitProximityWeight': node.transitProximityWeight,
        'darknessWeight': node.darknessWeight,
        'airmassWeight': node.airmassWeight,
        'minScoreToRun': node.minScoreToRun,
        'recomputeEveryNExposures': node.recomputeEveryNExposures,
        'finishIterationOnSwitch': node.finishIterationOnSwitch,
        'swapOnConditionsBelow': node.swapOnConditionsBelow,
        'swapHysteresisSecs': node.swapHysteresisSecs,
        'brightnessTierPreferences': node.brightnessTierPreferences.toJson(),
        'maxConditionsScoreAgeSecs': node.maxConditionsScoreAgeSecs,
        'minMoonSeparationDeg': node.minMoonSeparationDeg,
        'horizonProfile': _schedulerHorizonToJson(node.horizonProfile),
      },
      // SmartExposure — plans are serialised as a list of
      // FilterPlan JSON maps. We re-use FilterPlan.toJson() (which mirrors
      // the Rust serde shape) so the same blob round-trips through both
      // disk persistence and the executor's `_nodeToConfig` payload.
      SmartExposureNode() => {
        'plans': node.plans.map((p) => p.toJson()).toList(growable: false),
        'rotateFilters': node.rotateFilters,
        'ditherOnFilterChange': node.ditherOnFilterChange,
        'integrationBudgetSecs': node.integrationBudgetSecs,
        'batchSize': node.batchSize,
        'loopUntilStopped': node.loopUntilStopped,
      },
      // LiveStacking — flat key/value persistence.
      // `authToken` and `watermarkText` may be null; we keep them as
      // distinct keys (versus omitting) so the load path always reads
      // the same shape.
      LiveStackingNode() => {
        'mode': node.mode.storageKey,
        'stackMethod': node.stackMethod.storageKey,
        'maxFramesToStack': node.maxFramesToStack,
        'broadcastEnabled': node.broadcastEnabled,
        'broadcastPort': node.broadcastPort,
        'broadcastPath': node.broadcastPath,
        'authToken': node.authToken,
        'watermarkText': node.watermarkText,
        'thumbnailWidth': node.thumbnailWidth,
        'thumbnailHeight': node.thumbnailHeight,
      },
      // Science: SciencePhotometry — cadence-enforced
      // photometric capture node config.
      SciencePhotometryNode() => {
        'targetDesignation': node.targetDesignation,
        'referenceStars': node.referenceStars,
        'maxCadenceGapSecs': node.maxCadenceGapSecs,
        'filter': node.filter,
        'exposureSecs': node.exposureSecs,
        'count': node.count,
        'reduceLive': node.reduceLive,
        'applyDifferential': node.applyDifferential,
        'quality': node.quality.toJson(),
        'gain': node.gain,
        'offset': node.offset,
        'binning': node.binning.name,
      },
      // Plugin-contributed instruction. Pin pluginId,
      // nodeTypeId, opaque config blob, and friendly metadata so a
      // sequence containing plugin nodes still round-trips when the
      // plugin is temporarily unavailable (the editor surfaces a
      // "plugin missing" notice rather than silently dropping the node).
      PluginInstructionNode() => {
        'pluginId': node.pluginId,
        'nodeTypeId': node.nodeTypeId,
        'configJson': node.configJson,
        'timeoutSecs': node.timeoutSecs,
        'pluginName': node.pluginName,
        'iconHint': node.iconHint,
      },
      // Cover / calibrator nodes carry real config (timeout, brightness) that
      // must be persisted; the empty-props group below would drop it.
      OpenCoverNode() => {'timeoutSecs': node.timeoutSecs},
      CloseCoverNode() => {'timeoutSecs': node.timeoutSecs},
      CalibratorOnNode() => {
        'brightness': node.brightness,
        'timeoutSecs': node.timeoutSecs,
      },
      CalibratorOffNode() => {'timeoutSecs': node.timeoutSecs},
      // Side-effect-only nodes have no extra properties to persist beyond
      // the base fields (id/name/parentId/orderIndex/isEnabled/comment).
      InstructionSetNode() ||
      StopGuidingNode() ||
      ParkNode() ||
      UnparkNode() => const <String, dynamic>{},
    };
  }

  /// Wraps _nodeToProperties to include base-class fields like comment
  Map<String, dynamic> _nodeToPropertiesWithComment(SequenceNode node) {
    final props = _nodeToProperties(node);
    if (node.comment != null && node.comment!.isNotEmpty) {
      props['comment'] = node.comment;
    }
    return props;
  }
}
