part of '../sequence_repository.dart';

extension _SequenceRepositoryNodeDecoder on SequenceRepository {
  SequenceNode? _dbNodeToModel(db.SequenceNode dbNode) {
    final props = decodeJsonObjectString(
      dbNode.properties,
      context:
          'sequence_nodes.properties for node ${dbNode.nodeId} (${dbNode.specificType})',
    );

    switch (dbNode.specificType) {
      case 'exposure':
      case 'TakeExposure':
        // Recover the adaptive-exposure block. Both
        // camelCase (Dart canonical) and snake_case (Rust JSON shape)
        // are honoured so legacy + future-saved JSON both load.
        AdaptiveExposureConfig? adaptive;
        final adaptiveRaw =
            (props['adaptiveExposure'] ?? props['adaptive_exposure']) as Map?;
        if (adaptiveRaw != null) {
          adaptive = AdaptiveExposureConfig.fromJson(
            adaptiveRaw.cast<String, dynamic>(),
          );
        }
        return ExposureNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          durationSecs: (props['durationSecs'] as num?)?.toDouble() ?? 60.0,
          count: (props['count'] as num?)?.toInt() ?? 10,
          frameType: _stringToFrameType(props['frameType'] as String?),
          filter: props['filter'] as String?,
          filterIndex: (props['filterIndex'] as num?)?.toInt(),
          gain: (props['gain'] as num?)?.toInt(),
          offset: (props['offset'] as num?)?.toInt(),
          binning: _stringToBinning(props['binning'] as String?),
          ditherEvery: (props['ditherEvery'] as num?)?.toInt(),
          triggers: ((props['triggers'] as List?) ?? const [])
              .whereType<Map>()
              .map((trigger) => trigger.cast<String, dynamic>())
              .toList(growable: false),
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
          adaptiveExposure: adaptive,
        );

      case 'slew':
      case 'SlewToTarget':
        return SlewNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          useTargetCoords: props['useTargetCoords'] as bool? ?? true,
          customRa: (props['customRa'] as num?)?.toDouble(),
          customDec: (props['customDec'] as num?)?.toDouble(),
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      case 'center':
      case 'CenterTarget':
        return CenterNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          useTargetCoords: props['useTargetCoords'] as bool? ?? true,
          customRa: (props['customRa'] as num?)?.toDouble(),
          customDec: (props['customDec'] as num?)?.toDouble(),
          accuracyArcsec: (props['accuracyArcsec'] as num?)?.toDouble() ?? 5.0,
          maxAttempts: (props['maxAttempts'] as num?)?.toInt() ?? 5,
          exposureDuration:
              (props['exposureDuration'] as num?)?.toDouble() ?? 5.0,
          filter: props['filter'] as String?,
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      case 'autofocus':
      case 'Autofocus':
        return AutofocusNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          method: _stringToAutofocusMethod(props['method'] as String?),
          stepSize: (props['stepSize'] as num?)?.toInt() ?? 100,
          stepsOut: (props['stepsOut'] as num?)?.toInt() ?? 7,
          exposuresPerPoint: (props['exposuresPerPoint'] as num?)?.toInt() ?? 1,
          exposureDuration:
              (props['exposureDuration'] as num?)?.toDouble() ?? 3.0,
          useSettingsDefaults: props['useSettingsDefaults'] as bool? ?? true,
          maxDurationSecs:
              (props['maxDurationSecs'] as num?)?.toDouble() ?? 600.0,
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      case 'dither':
      case 'Dither':
        return DitherNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          pixels: (props['pixels'] as num?)?.toDouble() ?? 5.0,
          settlePixels: (props['settlePixels'] as num?)?.toDouble() ?? 1.5,
          settleTime: (props['settleTime'] as num?)?.toDouble() ?? 30.0,
          settleTimeout: (props['settleTimeout'] as num?)?.toDouble() ?? 120.0,
          raOnly: props['raOnly'] as bool? ?? false,
          pattern: _parseDitherPattern(props['pattern']),
          gridSize: (props['gridSize'] as num?)?.toInt() ?? 3,
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      case 'filterChange':
      case 'ChangeFilter':
        return FilterChangeNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          filterName: props['filterName'] as String? ?? '',
          filterPosition: (props['filterPosition'] as num?)?.toInt(),
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      case 'coolCamera':
      case 'CoolCamera':
        return CoolCameraNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          targetTemp: (props['targetTemp'] as num?)?.toDouble() ?? -10.0,
          durationMins: (props['durationMins'] as num?)?.toDouble(),
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      case 'warmCamera':
      case 'WarmCamera':
        return WarmCameraNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          ratePerMin: (props['ratePerMin'] as num?)?.toDouble() ?? 2.0,
          targetTemp: (props['targetTemp'] as num?)?.toDouble() ?? 20.0,
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      case 'rotator':
      case 'MoveRotator':
        return RotatorNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          targetAngle: (props['targetAngle'] as num?)?.toDouble() ?? 0.0,
          relative: props['relative'] as bool? ?? false,
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      case 'park':
      case 'Park':
        return ParkNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      case 'unpark':
      case 'Unpark':
        return UnparkNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      case 'waitTime':
      case 'WaitForTime':
        return WaitTimeNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          waitUntil: props['waitUntil'] != null
              ? DateTime.fromMillisecondsSinceEpoch(props['waitUntil'] as int)
              : null,
          waitForTwilight: _stringToTwilight(
            props['waitForTwilight'] as String?,
          ),
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      case 'delay':
      case 'Delay':
        return DelayNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          seconds: (props['seconds'] as num?)?.toDouble() ?? 5.0,
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      case 'notification':
      case 'Notification':
        return NotificationNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          title: props['title'] as String? ?? '',
          message: props['message'] as String? ?? '',
          level: _stringToNotificationLevel(props['level'] as String?),
          explicitTransports: _parseExplicitTransports(
            props['explicitTransports'],
          ),
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      case 'script':
      case 'RunScript':
        return ScriptNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          scriptPath: props['scriptPath'] as String? ?? '',
          arguments:
              (props['arguments'] as List<dynamic>?)?.cast<String>() ?? [],
          timeoutSecs: (props['timeoutSecs'] as num?)?.toInt(),
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      case 'targetGroup':
      case 'TargetHeader':
        return TargetHeaderNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          targetName: props['targetName'] as String? ?? '',
          raHours: (props['raHours'] as num?)?.toDouble() ?? 0.0,
          decDegrees: (props['decDegrees'] as num?)?.toDouble() ?? 0.0,
          rotation: (props['rotation'] as num?)?.toDouble(),
          minAltitude: (props['minAltitude'] as num?)?.toDouble(),
          maxAltitude: (props['maxAltitude'] as num?)?.toDouble(),
          priority: (props['priority'] as num?)?.toInt() ?? 0,
          startAfter: props['startAfter'] != null
              ? DateTime.fromMillisecondsSinceEpoch(props['startAfter'] as int)
              : null,
          endBefore: props['endBefore'] != null
              ? DateTime.fromMillisecondsSinceEpoch(props['endBefore'] as int)
              : null,
          mosaicPanel: props['mosaicPanel'] is Map
              ? MosaicPanelInfo.fromJson(
                  (props['mosaicPanel'] as Map).cast<String, dynamic>(),
                )
              : null,
          // Restore the integration budget. Absent
          // field stays null (pre-budget sequences keep working).
          integrationBudget: props['integrationBudget'] != null
              ? IntegrationBudget.fromJson(
                  props['integrationBudget'] as Map<String, dynamic>,
                )
              : null,
          // Per-target altitude/time crossings.
          startWhen: props['startWhen'] != null
              ? TargetTrigger.fromJson(
                  props['startWhen'] as Map<String, dynamic>,
                )
              : null,
          endWhen: props['endWhen'] != null
              ? TargetTrigger.fromJson(props['endWhen'] as Map<String, dynamic>)
              : null,
          triggerPollIntervalSecs:
              (props['triggerPollIntervalSecs'] as num?)?.toInt() ?? 30,
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      case 'loop':
      case 'Loop':
        return LoopNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          conditionType: _stringToLoopCondition(
            props['conditionType'] as String?,
          ),
          repeatCount: (props['repeatCount'] as num?)?.toInt() ?? 1,
          repeatUntil: props['repeatUntil'] != null
              ? DateTime.fromMillisecondsSinceEpoch(props['repeatUntil'] as int)
              : null,
          repeatUntilAltitude: (props['repeatUntilAltitude'] as num?)
              ?.toDouble(),
          integrationTimeTarget: (props['integrationTimeTarget'] as num?)
              ?.toDouble(),
          maxSafetyIterations: (props['maxSafetyIterations'] as num?)?.toInt(),
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      case 'parallel':
      case 'Parallel':
        return ParallelNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          requiredSuccesses: (props['requiredSuccesses'] as num?)?.toInt(),
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      case 'conditional':
      case 'Conditional':
        return ConditionalNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          conditionType: _stringToConditionalType(
            props['conditionType'] as String?,
          ),
          thresholdValue: (props['thresholdValue'] as num?)?.toDouble(),
          thresholdTime: props['thresholdTime'] != null
              ? DateTime.fromMillisecondsSinceEpoch(
                  props['thresholdTime'] as int,
                )
              : null,
          // Audit C2: optional per-monitor targeting for multi-safety
          // setups. Absent on legacy sequences (deserialises to null,
          // i.e. fall back to the aggregated check).
          safetyMonitorId: props['safetyMonitorId'] as String?,
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      case 'recovery':
      case 'Recovery':
        return RecoveryNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          recoveryAction: _stringToRecoveryAction(
            props['recoveryAction'] as String?,
          ),
          maxRetries: (props['maxRetries'] as num?)?.toInt() ?? 3,
          triggerType: _stringToTriggerType(props['triggerType'] as String?),
          triggerThreshold: (props['triggerThreshold'] as num?)?.toDouble(),
          hfrThresholdPercent:
              (props['hfrThresholdPercent'] as num?)?.toDouble() ?? 20.0,
          hfrConsecutiveFrames:
              (props['hfrConsecutiveFrames'] as num?)?.toInt() ?? 3,
          triggerEveryNFrames:
              (props['triggerEveryNFrames'] as num?)?.toInt() ?? 25,
          focusDriftWindowSize:
              (props['focusDriftWindowSize'] as num?)?.toInt() ?? 10,
          focusDriftMinIncreasingCount:
              (props['focusDriftMinIncreasingCount'] as num?)?.toInt() ?? 5,
          focusDriftMinTotalIncrease:
              (props['focusDriftMinTotalIncrease'] as num?)?.toDouble() ?? 0.5,
          guidingFailedDurationSecs:
              (props['guidingFailedDurationSecs'] as num?)?.toDouble() ?? 30.0,
          cloudMinutesBefore:
              (props['cloudMinutesBefore'] as num?)?.toDouble() ?? 10.0,
          cloudCoverageThresholdPercent:
              (props['cloudCoverageThresholdPercent'] as num?)?.toDouble() ??
              70.0,
          cloudOpeningMinDurationSecs:
              (props['cloudOpeningMinDurationSecs'] as num?)?.toDouble() ??
              300.0,
          cloudCoverMaxPercent:
              (props['cloudCoverMaxPercent'] as num?)?.toDouble() ?? 80.0,
          cloudCoverDurationSecs:
              (props['cloudCoverDurationSecs'] as num?)?.toDouble() ?? 60.0,
          transparencyBelowThreshold:
              (props['transparencyBelowThreshold'] as num?)?.toDouble() ?? 0.7,
          transparencyDurationSecs:
              (props['transparencyDurationSecs'] as num?)?.toDouble() ?? 60.0,
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      case 'startGuiding':
      case 'StartGuiding':
        return StartGuidingNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          settlePixels: (props['settlePixels'] as num?)?.toDouble() ?? 1.5,
          settleTime: (props['settleTime'] as num?)?.toDouble() ?? 10.0,
          settleTimeout: (props['settleTimeout'] as num?)?.toDouble() ?? 60.0,
          autoSelectStar: props['autoSelectStar'] as bool? ?? true,
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      case 'stopGuiding':
      case 'StopGuiding':
        return StopGuidingNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      case 'meridianFlip':
      case 'MeridianFlip':
        return MeridianFlipNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          triggerMethod: _stringToMeridianTriggerMethod(
            props['triggerMethod'] as String?,
          ),
          minutesPastMeridian:
              (props['minutesPastMeridian'] as num?)?.toDouble() ?? 5.0,
          minutesBeforeLimit:
              (props['minutesBeforeLimit'] as num?)?.toDouble() ?? 10.0,
          hourAngleThreshold:
              (props['hourAngleThreshold'] as num?)?.toDouble() ?? 0.5,
          pauseGuiding: props['pauseGuiding'] as bool? ?? true,
          autoCenter: props['autoCenter'] as bool? ?? true,
          refocusAfter: props['refocusAfter'] as bool? ?? false,
          settleTime: (props['settleTime'] as num?)?.toDouble() ?? 10.0,
          resumeGuiding: props['resumeGuiding'] as bool? ?? true,
          maxRetries: (props['maxRetries'] as num?)?.toInt() ?? 3,
          failureAction: _stringToFlipFailureAction(
            props['failureAction'] as String?,
          ),
          // Legacy DB rows carry no flag. Absence means `false` (use the
          // persisted per-node values verbatim) so an existing user sequence
          // keeps the behaviour its rows describe.
          useGlobalDefaults: props['useGlobalDefaults'] as bool? ?? false,
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      case 'openDome':
      case 'OpenDome':
        return OpenDomeNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          shutterOnly: props['shutterOnly'] as bool? ?? false,
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      case 'closeDome':
      case 'CloseDome':
        return CloseDomeNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          shutterOnly: props['shutterOnly'] as bool? ?? false,
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      case 'parkDome':
      case 'ParkDome':
        return ParkDomeNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          shutterOnly: props['shutterOnly'] as bool? ?? false,
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      case 'polarAlignment':
      case 'PolarAlignment':
        return PolarAlignmentNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          exposureDuration:
              (props['exposureDuration'] as num?)?.toDouble() ?? 2.0,
          binning: (props['binning'] as num?)?.toInt() ?? 2,
          startAltitude: (props['startAltitude'] as num?)?.toDouble() ?? 45.0,
          rotationStep: (props['rotationStep'] as num?)?.toDouble() ?? 20.0,
          gain: (props['gain'] as num?)?.toInt(),
          offset: (props['offset'] as num?)?.toInt(),
          startFromCurrent: props['startFromCurrent'] as bool? ?? true,
          isNorth: props['isNorth'] as bool? ?? true,
          manualSlew: props['manualSlew'] as bool? ?? false,
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      case 'instructionSet':
      case 'InstructionSet':
        return InstructionSetNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      // TargetScheduler. Two case strings cover both the
      // canonical Dart `nodeType` ('TargetScheduler') and the legacy
      // snake_case sent by the bridge layer ('target_scheduler').
      case 'targetScheduler':
      case 'TargetScheduler':
      case 'target_scheduler':
        return TargetSchedulerNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          altitudeWeight: (props['altitudeWeight'] as num?)?.toDouble() ?? 0.25,
          moonDistanceWeight:
              (props['moonDistanceWeight'] as num?)?.toDouble() ?? 0.25,
          transitProximityWeight:
              (props['transitProximityWeight'] as num?)?.toDouble() ?? 0.20,
          darknessWeight: (props['darknessWeight'] as num?)?.toDouble() ?? 0.15,
          airmassWeight: (props['airmassWeight'] as num?)?.toDouble() ?? 0.15,
          minScoreToRun: (props['minScoreToRun'] as num?)?.toDouble() ?? 30.0,
          recomputeEveryNExposures:
              (props['recomputeEveryNExposures'] as num?)?.toInt() ?? 0,
          finishIterationOnSwitch:
              props['finishIterationOnSwitch'] as bool? ?? true,
          swapOnConditionsBelow:
              (props['swapOnConditionsBelow'] as num?)?.toDouble() ??
              (props['swap_on_conditions_below'] as num?)?.toDouble(),
          swapHysteresisSecs:
              (props['swapHysteresisSecs'] as num?)?.toDouble() ??
              (props['swap_hysteresis_secs'] as num?)?.toDouble() ??
              180.0,
          brightnessTierPreferences: _parseBrightnessTierPreferences(
            props['brightnessTierPreferences'] ??
                props['brightness_tier_preferences'],
          ),
          maxConditionsScoreAgeSecs:
              (props['maxConditionsScoreAgeSecs'] as num?)?.toInt() ??
              (props['max_conditions_score_age_secs'] as num?)?.toInt() ??
              300,
          minMoonSeparationDeg:
              (props['minMoonSeparationDeg'] as num?)?.toDouble() ??
              (props['min_moon_separation_deg'] as num?)?.toDouble(),
          horizonProfile: _schedulerHorizonFromJson(
            props['horizonProfile'] ?? props['horizon_profile'],
          ),
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      // SmartExposure. Mirrors the case-string convention
      // above so DB rows written via `nodeType = 'SmartExposure'` or via
      // the snake_case bridge form both deserialize correctly.
      case 'smartExposure':
      case 'SmartExposure':
      case 'smart_exposure':
        return SmartExposureNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          plans: ((props['plans'] as List?) ?? const [])
              .whereType<Map>()
              .map((p) => FilterPlan.fromJson(p.cast<String, dynamic>()))
              .toList(growable: false),
          rotateFilters: props['rotateFilters'] as bool? ?? true,
          ditherOnFilterChange: props['ditherOnFilterChange'] as bool? ?? false,
          integrationBudgetSecs:
              (props['integrationBudgetSecs'] as num?)?.toDouble() ?? 0.0,
          batchSize: (props['batchSize'] as num?)?.toInt() ?? 1,
          loopUntilStopped: props['loopUntilStopped'] as bool? ?? false,
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      // Plugin-contributed instruction. The persisted node-type string
      // mirrors the Rust serde tag ("PluginNode"); lower / snake-case
      // spellings are also accepted for resilience against legacy DB rows. A
      // persisted plugin node with no `pluginId`/`nodeTypeId` is unusable but
      // still rehydrates (with empty identifiers), so the editor can surface
      // the broken node rather than silently dropping it.
      case 'pluginNode':
      case 'PluginNode':
      case 'plugin_node':
        return PluginInstructionNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          pluginId: props['pluginId'] as String? ?? '',
          nodeTypeId: props['nodeTypeId'] as String? ?? '',
          configJson: props['configJson'] as String? ?? '{}',
          timeoutSecs: (props['timeoutSecs'] as num?)?.toInt(),
          pluginName: props['pluginName'] as String? ?? '',
          iconHint: props['iconHint'] as String? ?? 'puzzle',
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      // LiveStacking. Same case-string convention as
      // SmartExposure above so DB rows written via either spelling
      // round-trip correctly.
      case 'liveStacking':
      case 'LiveStacking':
      case 'live_stacking':
        return LiveStackingNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          mode: LiveStackingMode.fromStorageKey(props['mode'] as String?),
          stackMethod: LiveStackingMethod.fromStorageKey(
            props['stackMethod'] as String?,
          ),
          maxFramesToStack: (props['maxFramesToStack'] as num?)?.toInt() ?? 0,
          broadcastEnabled: props['broadcastEnabled'] as bool? ?? true,
          broadcastPort: (props['broadcastPort'] as num?)?.toInt() ?? 8081,
          broadcastPath: props['broadcastPath'] as String? ?? '/broadcast',
          authToken: props['authToken'] as String?,
          watermarkText: props['watermarkText'] as String?,
          thumbnailWidth: (props['thumbnailWidth'] as num?)?.toInt() ?? 1280,
          thumbnailHeight: (props['thumbnailHeight'] as num?)?.toInt() ?? 720,
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      // Cover / calibrator / photometry nodes. These are palette-reachable
      // and were serialised by the encoder but had NO decoder case, so any
      // saved sequence containing one threw on reload and lost the ENTIRE
      // sequence (P0). Each accepts the canonical `nodeType` spelling plus a
      // snake_case alias for resilience against bridge-written rows.
      case 'openCover':
      case 'OpenCover':
      case 'open_cover':
        return OpenCoverNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          timeoutSecs: (props['timeoutSecs'] as num?)?.toInt() ?? 60,
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      case 'closeCover':
      case 'CloseCover':
      case 'close_cover':
        return CloseCoverNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          timeoutSecs: (props['timeoutSecs'] as num?)?.toInt() ?? 60,
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      case 'calibratorOn':
      case 'CalibratorOn':
      case 'calibrator_on':
        return CalibratorOnNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          brightness: (props['brightness'] as num?)?.toInt() ?? 128,
          timeoutSecs: (props['timeoutSecs'] as num?)?.toInt() ?? 30,
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      case 'calibratorOff':
      case 'CalibratorOff':
      case 'calibrator_off':
        return CalibratorOffNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          timeoutSecs: (props['timeoutSecs'] as num?)?.toInt() ?? 30,
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      case 'sciencePhotometry':
      case 'SciencePhotometry':
      case 'science_photometry':
        return SciencePhotometryNode(
          id: dbNode.nodeId,
          name: dbNode.name,
          targetDesignation: props['targetDesignation'] as String? ?? '',
          referenceStars: ((props['referenceStars'] as List?) ?? const [])
              .map((e) => e.toString())
              .toList(growable: false),
          maxCadenceGapSecs:
              (props['maxCadenceGapSecs'] as num?)?.toDouble() ?? 2.0,
          filter: props['filter'] as String? ?? 'Clear',
          exposureSecs: (props['exposureSecs'] as num?)?.toDouble() ?? 60.0,
          count: (props['count'] as num?)?.toInt() ?? 60,
          reduceLive: props['reduceLive'] as bool? ?? true,
          applyDifferential: props['applyDifferential'] as bool? ?? true,
          quality: props['quality'] is Map
              ? PhotometryQualityGates.fromJson(
                  (props['quality'] as Map).cast<String, dynamic>(),
                )
              : const PhotometryQualityGates(),
          gain: (props['gain'] as num?)?.toInt(),
          offset: (props['offset'] as num?)?.toInt(),
          binning: BinningMode.values.firstWhere(
            (b) => b.name == (props['binning'] as String?),
            orElse: () => BinningMode.one,
          ),
          parentId: dbNode.parentNodeId,
          orderIndex: dbNode.orderIndex,
          isEnabled: dbNode.isEnabled,
          comment: props['comment'] as String?,
        );

      default:
        return null;
    }
  }
}
