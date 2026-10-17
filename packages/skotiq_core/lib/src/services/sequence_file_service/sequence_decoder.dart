part of '../sequence_file_service.dart';

extension _SequenceFileDecoder on SequenceFileService {
  SequenceNode _jsonToNode(Map<String, dynamic> json, {String? fallbackId}) {
    final rawType = json['nodeType'] as String?;
    if (rawType == null || rawType.trim().isEmpty) {
      throw const FormatException('Sequence node missing nodeType');
    }

    final nodeType = _normalizeNodeType(rawType);
    final id = (json['id'] as String?) ?? fallbackId ?? const Uuid().v4();
    final name = json['name'] as String?;
    final parentId = json['parentId'] as String?;
    final childIds =
        (json['childIds'] as List<dynamic>?)?.cast<String>() ?? const [];
    final orderIndex = (json['orderIndex'] as num?)?.toInt() ?? 0;
    final isEnabled = json['isEnabled'] as bool? ?? true;

    switch (nodeType) {
      case 'targetheader':
      case 'targetgroup':
        final targetName = json['targetName'] as String?;
        final raHours = json['raHours'] as num?;
        final decDegrees = json['decDegrees'] as num?;
        if (targetName == null || raHours == null || decDegrees == null) {
          throw const FormatException('Target node missing required fields');
        }
        return TargetHeaderNode(
          id: id,
          name: name ?? 'Target',
          targetName: targetName,
          raHours: raHours.toDouble(),
          decDegrees: decDegrees.toDouble(),
          rotation: (json['rotation'] as num?)?.toDouble(),
          priority: (json['priority'] as num?)?.toInt() ?? 0,
          minAltitude: (json['minAltitude'] as num?)?.toDouble(),
          maxAltitude: (json['maxAltitude'] as num?)?.toDouble(),
          startAfter: _parseDate(json['startAfter']),
          endBefore: _parseDate(json['endBefore']),
          mosaicPanel: json['mosaicPanel'] != null
              ? MosaicPanelInfo.fromJson(
                  json['mosaicPanel'] as Map<String, dynamic>,
                )
              : null,
          integrationBudget: json['integrationBudget'] is Map
              ? IntegrationBudget.fromJson(
                  (json['integrationBudget'] as Map).cast<String, dynamic>(),
                )
              : null,
          startWhen: json['startWhen'] is Map
              ? TargetTrigger.fromJson(
                  (json['startWhen'] as Map).cast<String, dynamic>(),
                )
              : null,
          endWhen: json['endWhen'] is Map
              ? TargetTrigger.fromJson(
                  (json['endWhen'] as Map).cast<String, dynamic>(),
                )
              : null,
          triggerPollIntervalSecs:
              (json['triggerPollIntervalSecs'] as num?)?.toInt() ?? 30,
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'loop':
        return LoopNode(
          id: id,
          name: name ?? 'Loop',
          conditionType: _parseLoopConditionType(json['conditionType']),
          repeatCount: (json['repeatCount'] as num?)?.toInt(),
          repeatUntil: _parseDate(json['repeatUntil']),
          repeatUntilAltitude: (json['repeatUntilAltitude'] as num?)
              ?.toDouble(),
          integrationTimeTarget: (json['integrationTimeTarget'] as num?)
              ?.toDouble(),
          maxSafetyIterations: (json['maxSafetyIterations'] as num?)?.toInt(),
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'parallel':
        return ParallelNode(
          id: id,
          name: name ?? 'Parallel',
          requiredSuccesses: (json['requiredSuccesses'] as num?)?.toInt(),
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'conditional':
        return ConditionalNode(
          id: id,
          name: name ?? 'Conditional',
          conditionType: _parseConditionalType(json['conditionType']),
          thresholdValue: (json['thresholdValue'] as num?)?.toDouble(),
          thresholdTime: _parseDate(json['thresholdTime']),
          // Audit C2 — per-monitor targeting for multi-safety setups.
          // Absent on sequences saved before C2 (deserialises to null).
          safetyMonitorId: json['safetyMonitorId'] as String?,
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'recovery':
        return RecoveryNode(
          id: id,
          name: name ?? 'Recovery',
          recoveryAction: _parseRecoveryActionType(json['recoveryAction']),
          maxRetries: (json['maxRetries'] as num?)?.toInt() ?? 3,
          triggerType: _parseTriggerType(json['triggerType']),
          triggerThreshold: (json['triggerThreshold'] as num?)?.toDouble(),
          hfrThresholdPercent:
              (json['hfrThresholdPercent'] as num?)?.toDouble() ?? 20.0,
          hfrConsecutiveFrames:
              (json['hfrConsecutiveFrames'] as num?)?.toInt() ?? 3,
          triggerEveryNFrames:
              (json['triggerEveryNFrames'] as num?)?.toInt() ?? 25,
          // FocusDrift trigger window. Default values
          // match the model constructor so legacy files without these
          // keys deserialize cleanly.
          focusDriftWindowSize:
              (json['focusDriftWindowSize'] as num?)?.toInt() ?? 10,
          focusDriftMinIncreasingCount:
              (json['focusDriftMinIncreasingCount'] as num?)?.toInt() ?? 5,
          focusDriftMinTotalIncrease:
              (json['focusDriftMinTotalIncrease'] as num?)?.toDouble() ?? 0.5,
          guidingFailedDurationSecs:
              (json['guidingFailedDurationSecs'] as num?)?.toDouble() ?? 30.0,
          cloudMinutesBefore:
              (json['cloudMinutesBefore'] as num?)?.toDouble() ?? 10.0,
          cloudCoverageThresholdPercent:
              (json['cloudCoverageThresholdPercent'] as num?)?.toDouble() ??
              70.0,
          cloudOpeningMinDurationSecs:
              (json['cloudOpeningMinDurationSecs'] as num?)?.toDouble() ??
              300.0,
          cloudCoverMaxPercent:
              (json['cloudCoverMaxPercent'] as num?)?.toDouble() ?? 80.0,
          cloudCoverDurationSecs:
              (json['cloudCoverDurationSecs'] as num?)?.toDouble() ?? 60.0,
          transparencyBelowThreshold:
              (json['transparencyBelowThreshold'] as num?)?.toDouble() ?? 0.7,
          transparencyDurationSecs:
              (json['transparencyDurationSecs'] as num?)?.toDouble() ?? 60.0,
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'instructionset':
        return InstructionSetNode(
          id: id,
          name: name ?? 'Instructions',
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'slewtotarget':
      case 'slew':
        return SlewNode(
          id: id,
          name: name ?? 'Slew to Target',
          useTargetCoords: json['useTargetCoords'] as bool? ?? true,
          customRa: (json['customRa'] as num?)?.toDouble(),
          customDec: (json['customDec'] as num?)?.toDouble(),
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'centertarget':
      case 'center':
        return CenterNode(
          id: id,
          name: name ?? 'Center Target',
          useTargetCoords: json['useTargetCoords'] as bool? ?? true,
          customRa: (json['customRa'] as num?)?.toDouble(),
          customDec: (json['customDec'] as num?)?.toDouble(),
          accuracyArcsec: (json['accuracyArcsec'] as num?)?.toDouble() ?? 5.0,
          maxAttempts: (json['maxAttempts'] as num?)?.toInt() ?? 5,
          exposureDuration:
              (json['exposureDuration'] as num?)?.toDouble() ?? 5.0,
          filter: json['filter'] as String?,
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'takeexposure':
      case 'exposure':
        final adaptiveRaw =
            (json['adaptiveExposure'] ?? json['adaptive_exposure']) as Map?;
        return ExposureNode(
          id: id,
          name: name ?? 'Take Exposures',
          durationSecs: (json['durationSecs'] as num?)?.toDouble() ?? 60.0,
          count: (json['count'] as num?)?.toInt() ?? 10,
          frameType: _parseFrameType(json['frameType']),
          filter: json['filter'] as String?,
          gain: (json['gain'] as num?)?.toInt(),
          offset: (json['offset'] as num?)?.toInt(),
          filterIndex: (json['filterIndex'] as num?)?.toInt(),
          binning: _parseBinningMode(json['binning']),
          ditherEvery: (json['ditherEvery'] as num?)?.toInt(),
          triggers: ((json['triggers'] as List?) ?? const [])
              .whereType<Map>()
              .map((trigger) => trigger.cast<String, dynamic>())
              .toList(growable: false),
          adaptiveExposure: adaptiveRaw == null
              ? null
              : AdaptiveExposureConfig.fromJson(
                  adaptiveRaw.cast<String, dynamic>(),
                ),
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'autofocus':
        return AutofocusNode(
          id: id,
          name: name ?? 'Autofocus',
          method: _parseAutofocusMethod(json['method']),
          stepSize: (json['stepSize'] as num?)?.toInt() ?? 100,
          stepsOut: (json['stepsOut'] as num?)?.toInt() ?? 7,
          exposuresPerPoint: (json['exposuresPerPoint'] as num?)?.toInt() ?? 1,
          exposureDuration:
              (json['exposureDuration'] as num?)?.toDouble() ?? 3.0,
          useSettingsDefaults: json['useSettingsDefaults'] as bool? ?? true,
          maxDurationSecs:
              (json['maxDurationSecs'] as num?)?.toDouble() ?? 600.0,
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'dither':
        return DitherNode(
          id: id,
          name: name ?? 'Dither',
          pixels: (json['pixels'] as num?)?.toDouble() ?? 5.0,
          settlePixels: (json['settlePixels'] as num?)?.toDouble() ?? 1.5,
          settleTime: (json['settleTime'] as num?)?.toDouble() ?? 30.0,
          settleTimeout: (json['settleTimeout'] as num?)?.toDouble() ?? 120.0,
          raOnly: json['raOnly'] as bool? ?? false,
          pattern: switch ((json['pattern'] as String?)?.toLowerCase()) {
            'grid' => DitherPattern.grid,
            _ => DitherPattern.random,
          },
          gridSize: (json['gridSize'] as num?)?.toInt() ?? 3,
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'startguiding':
        return StartGuidingNode(
          id: id,
          name: name ?? 'Start Guiding',
          settlePixels: (json['settlePixels'] as num?)?.toDouble() ?? 1.5,
          settleTime: (json['settleTime'] as num?)?.toDouble() ?? 10.0,
          settleTimeout: (json['settleTimeout'] as num?)?.toDouble() ?? 60.0,
          autoSelectStar: json['autoSelectStar'] as bool? ?? true,
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'stopguiding':
        return StopGuidingNode(
          id: id,
          name: name ?? 'Stop Guiding',
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'changefilter':
      case 'filterchange':
        return FilterChangeNode(
          id: id,
          name: name ?? 'Change Filter',
          filterName: json['filterName'] as String? ?? '',
          filterPosition: (json['filterPosition'] as num?)?.toInt(),
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'coolcamera':
        return CoolCameraNode(
          id: id,
          name: name ?? 'Cool Camera',
          targetTemp: (json['targetTemp'] as num?)?.toDouble() ?? -10.0,
          durationMins: (json['durationMins'] as num?)?.toDouble(),
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'warmcamera':
        return WarmCameraNode(
          id: id,
          name: name ?? 'Warm Camera',
          ratePerMin: (json['ratePerMin'] as num?)?.toDouble() ?? 2.0,
          targetTemp: (json['targetTemp'] as num?)?.toDouble() ?? 20.0,
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'moverotator':
      case 'rotator':
        return RotatorNode(
          id: id,
          name: name ?? 'Move Rotator',
          targetAngle: (json['targetAngle'] as num?)?.toDouble() ?? 0.0,
          relative: json['relative'] as bool? ?? false,
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'park':
        return ParkNode(
          id: id,
          name: name ?? 'Park Mount',
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'unpark':
        return UnparkNode(
          id: id,
          name: name ?? 'Unpark Mount',
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'waitfortime':
      case 'waittime':
        return WaitTimeNode(
          id: id,
          name: name ?? 'Wait for Time',
          waitUntil: _parseDate(json['waitUntil']),
          waitForTwilight: _parseTwilightType(json['waitForTwilight']),
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'delay':
        return DelayNode(
          id: id,
          name: name ?? 'Delay',
          seconds: (json['seconds'] as num?)?.toDouble() ?? 5.0,
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'notification':
        return NotificationNode(
          id: id,
          name: name ?? 'Send Notification',
          title: json['title'] as String? ?? '',
          message: json['message'] as String? ?? '',
          level: _parseNotificationLevel(json['level']),
          explicitTransports: _parseExplicitTransports(
            json['explicitTransports'],
          ),
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'runscript':
      case 'script':
        return ScriptNode(
          id: id,
          name: name ?? 'Run Script',
          scriptPath: json['scriptPath'] as String? ?? '',
          arguments:
              (json['arguments'] as List<dynamic>?)?.cast<String>() ?? const [],
          timeoutSecs: (json['timeoutSecs'] as num?)?.toInt(),
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'meridianflip':
        return MeridianFlipNode(
          id: id,
          name: name ?? 'Meridian Flip',
          triggerMethod: _parseMeridianTriggerMethod(json['triggerMethod']),
          minutesPastMeridian:
              (json['minutesPastMeridian'] as num?)?.toDouble() ?? 5.0,
          minutesBeforeLimit:
              (json['minutesBeforeLimit'] as num?)?.toDouble() ?? 10.0,
          hourAngleThreshold:
              (json['hourAngleThreshold'] as num?)?.toDouble() ?? 0.5,
          pauseGuiding: json['pauseGuiding'] as bool? ?? true,
          autoCenter: json['autoCenter'] as bool? ?? true,
          refocusAfter: json['refocusAfter'] as bool? ?? false,
          settleTime: (json['settleTime'] as num?)?.toDouble() ?? 10.0,
          resumeGuiding: json['resumeGuiding'] as bool? ?? true,
          maxRetries: json['maxRetries'] as int? ?? 3,
          failureAction: _parseFlipFailureAction(json['failureAction']),
          // Legacy sequences carry no global-defaults flag. Absence means
          // `false` (preserve the persisted per-node values verbatim) so an
          // existing user sequence never starts pulling from settings.
          useGlobalDefaults: json['useGlobalDefaults'] as bool? ?? false,
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'opendome':
        return OpenDomeNode(
          id: id,
          name: name ?? 'Open Dome',
          shutterOnly: json['shutterOnly'] as bool? ?? false,
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'closedome':
        return CloseDomeNode(
          id: id,
          name: name ?? 'Close Dome',
          shutterOnly: json['shutterOnly'] as bool? ?? false,
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'parkdome':
        return ParkDomeNode(
          id: id,
          name: name ?? 'Park Dome',
          shutterOnly: json['shutterOnly'] as bool? ?? false,
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'polalignment':
      case 'polaralignment':
        return PolarAlignmentNode(
          id: id,
          name: name ?? 'Polar Alignment',
          exposureDuration:
              (json['exposureDuration'] as num?)?.toDouble() ?? 2.0,
          binning: (json['binning'] as num?)?.toInt() ?? 2,
          startAltitude: (json['startAltitude'] as num?)?.toDouble() ?? 45.0,
          rotationStep: (json['rotationStep'] as num?)?.toDouble() ?? 20.0,
          gain: (json['gain'] as num?)?.toInt(),
          offset: (json['offset'] as num?)?.toInt(),
          startFromCurrent: json['startFromCurrent'] as bool? ?? true,
          isNorth: json['isNorth'] as bool? ?? true,
          manualSlew: json['manualSlew'] as bool? ?? false,
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      // TargetScheduler — case strings cover the
      // normalised canonical Dart `nodeType` ('TargetScheduler') plus the
      // snake_case form emitted by the bridge layer.
      case 'targetscheduler':
      case 'target_scheduler':
        return TargetSchedulerNode(
          id: id,
          name: name ?? 'Scheduler',
          altitudeWeight: (json['altitudeWeight'] as num?)?.toDouble() ?? 0.25,
          moonDistanceWeight:
              (json['moonDistanceWeight'] as num?)?.toDouble() ?? 0.25,
          transitProximityWeight:
              (json['transitProximityWeight'] as num?)?.toDouble() ?? 0.20,
          darknessWeight: (json['darknessWeight'] as num?)?.toDouble() ?? 0.15,
          airmassWeight: (json['airmassWeight'] as num?)?.toDouble() ?? 0.15,
          minScoreToRun: (json['minScoreToRun'] as num?)?.toDouble() ?? 30.0,
          recomputeEveryNExposures:
              (json['recomputeEveryNExposures'] as num?)?.toInt() ?? 0,
          finishIterationOnSwitch:
              json['finishIterationOnSwitch'] as bool? ?? true,
          swapOnConditionsBelow:
              (json['swapOnConditionsBelow'] as num?)?.toDouble() ??
              (json['swap_on_conditions_below'] as num?)?.toDouble(),
          swapHysteresisSecs:
              (json['swapHysteresisSecs'] as num?)?.toDouble() ??
              (json['swap_hysteresis_secs'] as num?)?.toDouble() ??
              180.0,
          brightnessTierPreferences: _parseBrightnessTierPreferences(
            json['brightnessTierPreferences'] ??
                json['brightness_tier_preferences'],
          ),
          maxConditionsScoreAgeSecs:
              (json['maxConditionsScoreAgeSecs'] as num?)?.toInt() ??
              (json['max_conditions_score_age_secs'] as num?)?.toInt() ??
              300,
          minMoonSeparationDeg:
              (json['minMoonSeparationDeg'] as num?)?.toDouble() ??
              (json['min_moon_separation_deg'] as num?)?.toDouble(),
          horizonProfile: _decodeHorizonProfile(
            json['horizonProfile'] ?? json['horizon_profile'],
          ),
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      // SmartExposure — case strings cover the canonical
      // Dart `nodeType` ('SmartExposure') normalised via
      // `_normalizeNodeType` (which lowercases) plus the snake_case form
      // emitted by the bridge layer.
      case 'smartexposure':
      case 'smart_exposure':
        return SmartExposureNode(
          id: id,
          name: name ?? 'Smart Exposure',
          plans: ((json['plans'] as List?) ?? const [])
              .whereType<Map>()
              .map((p) => FilterPlan.fromJson(p.cast<String, dynamic>()))
              .toList(growable: false),
          rotateFilters: json['rotateFilters'] as bool? ?? true,
          ditherOnFilterChange: json['ditherOnFilterChange'] as bool? ?? false,
          integrationBudgetSecs:
              (json['integrationBudgetSecs'] as num?)?.toDouble() ?? 0.0,
          batchSize: (json['batchSize'] as num?)?.toInt() ?? 1,
          loopUntilStopped: json['loopUntilStopped'] as bool? ?? false,
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      // Plugin-contributed instruction. The normaliser
      // strips underscores + lowercases, so 'PluginNode' / 'plugin_node'
      // / 'pluginnode' all land on the same case key.
      case 'pluginnode':
        return PluginInstructionNode(
          id: id,
          name: name ?? 'Plugin Node',
          pluginId: json['pluginId'] as String? ?? '',
          nodeTypeId: json['nodeTypeId'] as String? ?? '',
          configJson: json['configJson'] as String? ?? '{}',
          timeoutSecs: (json['timeoutSecs'] as num?)?.toInt(),
          pluginName: json['pluginName'] as String? ?? '',
          iconHint: json['iconHint'] as String? ?? 'puzzle',
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      // LiveStacking — broadcast / EAA node.
      case 'livestacking':
      case 'live_stacking':
        return LiveStackingNode(
          id: id,
          name: name ?? 'Live Stacking',
          mode: LiveStackingMode.fromStorageKey(json['mode'] as String?),
          stackMethod: LiveStackingMethod.fromStorageKey(
            json['stackMethod'] as String?,
          ),
          maxFramesToStack: (json['maxFramesToStack'] as num?)?.toInt() ?? 0,
          broadcastEnabled: json['broadcastEnabled'] as bool? ?? true,
          broadcastPort: (json['broadcastPort'] as num?)?.toInt() ?? 8081,
          broadcastPath: json['broadcastPath'] as String? ?? '/broadcast',
          authToken: json['authToken'] as String?,
          watermarkText: json['watermarkText'] as String?,
          thumbnailWidth: (json['thumbnailWidth'] as num?)?.toInt() ?? 1280,
          thumbnailHeight: (json['thumbnailHeight'] as num?)?.toInt() ?? 720,
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      // Cover / calibrator / photometry nodes. These are palette-reachable
      // and exported by the encoder, but had NO decoder case here — so any
      // exported sequence containing one threw `FormatException` on import
      // and the WHOLE sequence failed to load (P0). `_normalizeNodeType`
      // lowercases and strips separators, so 'OpenCover' → 'opencover' etc.
      case 'opencover':
        return OpenCoverNode(
          id: id,
          name: name ?? 'Open Cover',
          timeoutSecs: (json['timeoutSecs'] as num?)?.toInt() ?? 60,
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'closecover':
        return CloseCoverNode(
          id: id,
          name: name ?? 'Close Cover',
          timeoutSecs: (json['timeoutSecs'] as num?)?.toInt() ?? 60,
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'calibratoron':
        return CalibratorOnNode(
          id: id,
          name: name ?? 'Calibrator On',
          brightness: (json['brightness'] as num?)?.toInt() ?? 128,
          timeoutSecs: (json['timeoutSecs'] as num?)?.toInt() ?? 30,
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'calibratoroff':
        return CalibratorOffNode(
          id: id,
          name: name ?? 'Calibrator Off',
          timeoutSecs: (json['timeoutSecs'] as num?)?.toInt() ?? 30,
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      case 'sciencephotometry':
        return SciencePhotometryNode(
          id: id,
          name: name ?? 'Science Photometry',
          targetDesignation: json['targetDesignation'] as String? ?? '',
          referenceStars: ((json['referenceStars'] as List?) ?? const [])
              .map((e) => e.toString())
              .toList(growable: false),
          maxCadenceGapSecs:
              (json['maxCadenceGapSecs'] as num?)?.toDouble() ?? 2.0,
          filter: json['filter'] as String? ?? 'Clear',
          exposureSecs: (json['exposureSecs'] as num?)?.toDouble() ?? 60.0,
          count: (json['count'] as num?)?.toInt() ?? 60,
          reduceLive: json['reduceLive'] as bool? ?? true,
          applyDifferential: json['applyDifferential'] as bool? ?? true,
          quality: json['quality'] is Map
              ? PhotometryQualityGates.fromJson(
                  (json['quality'] as Map).cast<String, dynamic>(),
                )
              : const PhotometryQualityGates(),
          gain: (json['gain'] as num?)?.toInt(),
          offset: (json['offset'] as num?)?.toInt(),
          binning: BinningMode.values.firstWhere(
            (b) => b.name == (json['binning'] as String?),
            orElse: () => BinningMode.one,
          ),
          parentId: parentId,
          childIds: childIds,
          orderIndex: orderIndex,
          isEnabled: isEnabled,
        );

      default:
        throw FormatException('Unsupported sequence node type: $rawType');
    }
  }

  String _normalizeNodeType(String nodeType) {
    return nodeType.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
  }

  DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(value);
    }
    if (value is String) {
      return DateTime.parse(value);
    }
    return null;
  }

  // Enum wire conversion for the sequence FILE format. The tokens live in
  // `sequence_wire_codec.dart`, shared with the DB codec, so a document
  // written by either side reads back the same on both.

  FrameType _parseFrameType(dynamic value) =>
      enumFromWireOr(FrameType.values, value, FrameType.light);

  BinningMode _parseBinningMode(dynamic value) =>
      enumFromWireOr(BinningMode.values, value, BinningMode.one);

  AutofocusMethod _parseAutofocusMethod(dynamic value) =>
      autofocusMethodFromWire(value);

  LoopConditionType _parseLoopConditionType(dynamic value) =>
      enumFromWireOr(LoopConditionType.values, value, LoopConditionType.count);

  NotificationLevel _parseNotificationLevel(dynamic value) =>
      enumFromWireOr(NotificationLevel.values, value, NotificationLevel.info);

  List<NotificationTransportKind>? _parseExplicitTransports(dynamic raw) =>
      explicitTransportsFromWire(raw);

  ConditionalType _parseConditionalType(dynamic value) =>
      enumFromWireOr(ConditionalType.values, value, ConditionalType.always);

  RecoveryActionType _parseRecoveryActionType(dynamic value) =>
      recoveryActionFromWire(value, fallback: RecoveryActionType.retry);

  TriggerType? _parseTriggerType(dynamic value) =>
      enumFromWire(TriggerType.values, value);

  TwilightType? _parseTwilightType(dynamic value) =>
      enumFromWire(TwilightType.values, value);

  MeridianTriggerMethod _parseMeridianTriggerMethod(dynamic value) =>
      enumFromWireOr(
        MeridianTriggerMethod.values,
        value,
        MeridianTriggerMethod.minutesPastMeridian,
      );

  FlipFailureAction _parseFlipFailureAction(dynamic value) => enumFromWireOr(
    FlipFailureAction.values,
    value,
    FlipFailureAction.pauseAndAlert,
  );
}
