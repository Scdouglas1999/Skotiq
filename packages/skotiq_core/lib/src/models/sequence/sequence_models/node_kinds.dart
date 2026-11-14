part of '../sequence_models.dart';

/// The diff label of an exposure's gain; a sequence diff shows it as the
/// connected camera's sensitivity label ("ISO" for a DSLR).
const exposureGainDiffLabel = 'Gain';

/// Every node type, in palette order. [NodeKind.all] reads this list.
final List<NodeKind> nodeKinds = [
  NodeKinds.targetHeader,
  NodeKinds.loop,
  NodeKinds.parallel,
  NodeKinds.conditional,
  NodeKinds.recovery,
  NodeKinds.instructionSet,
  NodeKinds.targetScheduler,
  NodeKinds.slew,
  NodeKinds.center,
  NodeKinds.exposure,
  NodeKinds.smartExposure,
  NodeKinds.autofocus,
  NodeKinds.dither,
  NodeKinds.startGuiding,
  NodeKinds.stopGuiding,
  NodeKinds.filterChange,
  NodeKinds.coolCamera,
  NodeKinds.warmCamera,
  NodeKinds.rotator,
  NodeKinds.park,
  NodeKinds.unpark,
  NodeKinds.homeMount,
  NodeKinds.waitTime,
  NodeKinds.delay,
  NodeKinds.notification,
  NodeKinds.script,
  NodeKinds.meridianFlip,
  NodeKinds.openDome,
  NodeKinds.closeDome,
  NodeKinds.parkDome,
  NodeKinds.polarAlignment,
  NodeKinds.openCover,
  NodeKinds.closeCover,
  NodeKinds.calibratorOn,
  NodeKinds.calibratorOff,
  NodeKinds.liveStacking,
  NodeKinds.sciencePhotometry,
  NodeKinds.plugin,
];

String _orNone(Object? value) => value?.toString() ?? '(none)';
String _orDefault(Object? value) => value?.toString() ?? '(default)';

/// The recovery action token: the database spells `continueExecution` as
/// `continue`, and an unreadable database token has always meant "continue"
/// (see [RecoveryNode]'s `absentIn`).
final FieldCodec<RecoveryActionType> _recoveryActionCodec = FieldCodec.custom(
  encode: (action, store) => switch (store) {
    NodeStore.database => recoveryActionToDbWire(action),
    NodeStore.document => recoveryActionToFileWire(action),
  },
  decode: (raw, store) => raw is String && raw.toLowerCase() == 'continue'
      ? RecoveryActionType.continueExecution
      : enumFromWire(RecoveryActionType.values, raw),
);

final FieldCodec<AutofocusMethod> _autofocusMethodCodec = FieldCodec.custom(
  encode: (method, store) => method.name,
  decode: (raw, store) => autofocusMethodFromWire(raw),
);

final FieldCodec<List<NotificationTransportKind>?> _transportsCodec =
    FieldCodec.custom(
      encode: (transports, store) =>
          transports?.map((t) => t.storageKey).toList(),
      decode: (raw, store) => explicitTransportsFromWire(raw),
    );

final FieldCodec<HorizonProfile?> _horizonCodec = FieldCodec.custom(
  encode: (profile, store) => profile == null
      ? null
      : {
          if (profile.id != null) 'id': profile.id,
          'name': profile.name,
          'samples': profile.samples.map((s) => s.toJson()).toList(),
        },
  decode: (raw, store) {
    if (raw is! Map) return null;
    final map = raw.cast<String, dynamic>();
    final samples = map['samples'] as List<dynamic>? ?? const [];
    if (samples.isEmpty) return null;
    return HorizonProfile(
      id: (map['id'] as num?)?.toInt(),
      name: map['name'] as String? ?? 'Site horizon',
      samples: [
        for (final s in samples)
          HorizonSample.fromJson((s as Map).cast<String, dynamic>()),
      ],
    );
  },
);

final FieldCodec<List<FilterPlan>> _plansCodec = FieldCodec.custom(
  encode: (plans, store) =>
      plans.map((p) => p.toJson()).toList(growable: false),
  decode: (raw, store) => (raw as List)
      .whereType<Map>()
      .map((p) => FilterPlan.fromJson(p.cast<String, dynamic>()))
      .toList(growable: false),
);

final _targetName = NodeField<TargetHeaderNode, String>(
  'targetName',
  (n) => n.targetName,
  FieldCodec.text,
  requiredIn: {NodeStore.document},
);
final _targetRa = NodeField<TargetHeaderNode, double>(
  'raHours',
  (n) => n.raHours,
  FieldCodec.real,
  requiredIn: {NodeStore.document},
);
final _targetDec = NodeField<TargetHeaderNode, double>(
  'decDegrees',
  (n) => n.decDegrees,
  FieldCodec.real,
  requiredIn: {NodeStore.document},
);
final _targetRotation = NodeField<TargetHeaderNode, double?>(
  'rotation',
  (n) => n.rotation,
  FieldCodec.optionalReal,
);
final _targetPriority = NodeField<TargetHeaderNode, int>(
  'priority',
  (n) => n.priority,
  FieldCodec.integer,
);
final _targetMinAltitude = NodeField<TargetHeaderNode, double?>(
  'minAltitude',
  (n) => n.minAltitude,
  FieldCodec.optionalReal,
);
final _targetMaxAltitude = NodeField<TargetHeaderNode, double?>(
  'maxAltitude',
  (n) => n.maxAltitude,
  FieldCodec.optionalReal,
);
final _targetStartAfter = NodeField<TargetHeaderNode, DateTime?>(
  'startAfter',
  (n) => n.startAfter,
  FieldCodec.instant,
);
final _targetEndBefore = NodeField<TargetHeaderNode, DateTime?>(
  'endBefore',
  (n) => n.endBefore,
  FieldCodec.instant,
);
final _targetMosaicPanel = NodeField<TargetHeaderNode, MosaicPanelInfo?>(
  'mosaicPanel',
  (n) => n.mosaicPanel,
  FieldCodec.json((p) => p!.toJson(), MosaicPanelInfo.fromJson),
);
final _targetBudget = NodeField<TargetHeaderNode, IntegrationBudget?>(
  'integrationBudget',
  (n) => n.integrationBudget,
  FieldCodec.json((b) => b!.toJson(), IntegrationBudget.fromJson),
  omitWhenNull: true,
);
final _targetStartWhen = NodeField<TargetHeaderNode, TargetTrigger?>(
  'startWhen',
  (n) => n.startWhen,
  FieldCodec.json((t) => t!.toJson(), TargetTrigger.fromJson),
  omitWhenNull: true,
);
final _targetEndWhen = NodeField<TargetHeaderNode, TargetTrigger?>(
  'endWhen',
  (n) => n.endWhen,
  FieldCodec.json((t) => t!.toJson(), TargetTrigger.fromJson),
  omitWhenNull: true,
);
final _targetBrightnessTier = NodeField<TargetHeaderNode, BrightnessTier?>(
  'brightnessTierHint',
  (n) => n.brightnessTierHint,
  FieldCodec.optionalNamed(BrightnessTier.values),
  omitWhenNull: true,
);
final _targetPollSecs = NodeField<TargetHeaderNode, int>(
  'triggerPollIntervalSecs',
  (n) => n.triggerPollIntervalSecs,
  FieldCodec.integer,
);

final _loopCondition = NodeField<LoopNode, LoopConditionType>(
  'conditionType',
  (n) => n.conditionType,
  FieldCodec.named(LoopConditionType.values),
);
final _loopRepeatCount = NodeField<LoopNode, int?>(
  'repeatCount',
  (n) => n.repeatCount,
  FieldCodec.optionalInteger,
  absentIn: {NodeStore.database: 1},
);
final _loopRepeatUntil = NodeField<LoopNode, DateTime?>(
  'repeatUntil',
  (n) => n.repeatUntil,
  FieldCodec.instant,
);
final _loopUntilAltitude = NodeField<LoopNode, double?>(
  'repeatUntilAltitude',
  (n) => n.repeatUntilAltitude,
  FieldCodec.optionalReal,
);
final _loopIntegrationTarget = NodeField<LoopNode, double?>(
  'integrationTimeTarget',
  (n) => n.integrationTimeTarget,
  FieldCodec.optionalReal,
);
final _loopSafetyIterations = NodeField<LoopNode, int?>(
  'maxSafetyIterations',
  (n) => n.maxSafetyIterations,
  FieldCodec.optionalInteger,
);

final _parallelRequired = NodeField<ParallelNode, int?>(
  'requiredSuccesses',
  (n) => n.requiredSuccesses,
  FieldCodec.optionalInteger,
);

final _conditionalType = NodeField<ConditionalNode, ConditionalType>(
  'conditionType',
  (n) => n.conditionType,
  FieldCodec.named(ConditionalType.values),
);
final _conditionalThreshold = NodeField<ConditionalNode, double?>(
  'thresholdValue',
  (n) => n.thresholdValue,
  FieldCodec.optionalReal,
);
final _conditionalTime = NodeField<ConditionalNode, DateTime?>(
  'thresholdTime',
  (n) => n.thresholdTime,
  FieldCodec.instant,
);
final _conditionalMonitor = NodeField<ConditionalNode, String?>(
  'safetyMonitorId',
  (n) => n.safetyMonitorId,
  FieldCodec.optionalText,
);

final _recoveryAction = NodeField<RecoveryNode, RecoveryActionType>(
  'recoveryAction',
  (n) => n.recoveryAction,
  _recoveryActionCodec,
  absentIn: {NodeStore.database: RecoveryActionType.continueExecution},
);
final _recoveryMaxRetries = NodeField<RecoveryNode, int>(
  'maxRetries',
  (n) => n.maxRetries,
  FieldCodec.integer,
);
final _recoveryTrigger = NodeField<RecoveryNode, TriggerType?>(
  'triggerType',
  (n) => n.triggerType,
  FieldCodec.optionalNamed(TriggerType.values),
);
NodeField<RecoveryNode, double?> _recoveryOptionalReal(
  String key,
  double? Function(RecoveryNode n) read,
) => NodeField(key, read, FieldCodec.optionalReal);
NodeField<RecoveryNode, double> _recoveryReal(
  String key,
  double Function(RecoveryNode n) read,
) => NodeField(key, read, FieldCodec.real);
NodeField<RecoveryNode, int> _recoveryInt(
  String key,
  int Function(RecoveryNode n) read,
) => NodeField(key, read, FieldCodec.integer);
final _recoveryThreshold = _recoveryOptionalReal(
  'triggerThreshold',
  (n) => n.triggerThreshold,
);
final _recoveryHfrPercent = _recoveryReal(
  'hfrThresholdPercent',
  (n) => n.hfrThresholdPercent,
);
final _recoveryHfrFrames = _recoveryInt(
  'hfrConsecutiveFrames',
  (n) => n.hfrConsecutiveFrames,
);
final _recoveryEveryNFrames = _recoveryInt(
  'triggerEveryNFrames',
  (n) => n.triggerEveryNFrames,
);
final _recoveryDriftWindow = _recoveryInt(
  'focusDriftWindowSize',
  (n) => n.focusDriftWindowSize,
);
final _recoveryDriftCount = _recoveryInt(
  'focusDriftMinIncreasingCount',
  (n) => n.focusDriftMinIncreasingCount,
);
final _recoveryDriftIncrease = _recoveryReal(
  'focusDriftMinTotalIncrease',
  (n) => n.focusDriftMinTotalIncrease,
);
final _recoveryGuidingSecs = _recoveryReal(
  'guidingFailedDurationSecs',
  (n) => n.guidingFailedDurationSecs,
);
final _recoveryCloudMinutes = _recoveryReal(
  'cloudMinutesBefore',
  (n) => n.cloudMinutesBefore,
);
final _recoveryCloudCoverage = _recoveryReal(
  'cloudCoverageThresholdPercent',
  (n) => n.cloudCoverageThresholdPercent,
);
final _recoveryCloudOpening = _recoveryReal(
  'cloudOpeningMinDurationSecs',
  (n) => n.cloudOpeningMinDurationSecs,
);
final _recoveryCloudCoverMax = _recoveryReal(
  'cloudCoverMaxPercent',
  (n) => n.cloudCoverMaxPercent,
);
final _recoveryCloudCoverSecs = _recoveryReal(
  'cloudCoverDurationSecs',
  (n) => n.cloudCoverDurationSecs,
);
final _recoveryTransparency = _recoveryReal(
  'transparencyBelowThreshold',
  (n) => n.transparencyBelowThreshold,
);
final _recoveryTransparencySecs = _recoveryReal(
  'transparencyDurationSecs',
  (n) => n.transparencyDurationSecs,
);

NodeField<TargetSchedulerNode, double> _schedulerReal(
  String key,
  double Function(TargetSchedulerNode n) read,
) => NodeField(key, read, FieldCodec.real);
final _schedulerAltitude = _schedulerReal(
  'altitudeWeight',
  (n) => n.altitudeWeight,
);
final _schedulerMoon = _schedulerReal(
  'moonDistanceWeight',
  (n) => n.moonDistanceWeight,
);
final _schedulerTransit = _schedulerReal(
  'transitProximityWeight',
  (n) => n.transitProximityWeight,
);
final _schedulerDarkness = _schedulerReal(
  'darknessWeight',
  (n) => n.darknessWeight,
);
final _schedulerAirmass = _schedulerReal(
  'airmassWeight',
  (n) => n.airmassWeight,
);
final _schedulerMinScore = _schedulerReal(
  'minScoreToRun',
  (n) => n.minScoreToRun,
);
final _schedulerRecompute = NodeField<TargetSchedulerNode, int>(
  'recomputeEveryNExposures',
  (n) => n.recomputeEveryNExposures,
  FieldCodec.integer,
  absentIn: {NodeStore.database: 0, NodeStore.document: 0},
);
final _schedulerFinishIteration = NodeField<TargetSchedulerNode, bool>(
  'finishIterationOnSwitch',
  (n) => n.finishIterationOnSwitch,
  FieldCodec.flag,
);
final _schedulerSwapBelow = NodeField<TargetSchedulerNode, double?>(
  'swapOnConditionsBelow',
  (n) => n.swapOnConditionsBelow,
  FieldCodec.optionalReal,
  alternateKeys: const ['swap_on_conditions_below'],
);
final _schedulerHysteresis = NodeField<TargetSchedulerNode, double>(
  'swapHysteresisSecs',
  (n) => n.swapHysteresisSecs,
  FieldCodec.real,
  alternateKeys: const ['swap_hysteresis_secs'],
);
final _schedulerTiers =
    NodeField<TargetSchedulerNode, BrightnessTierPreferences>(
      'brightnessTierPreferences',
      (n) => n.brightnessTierPreferences,
      FieldCodec.json((p) => p.toJson(), BrightnessTierPreferences.fromJson),
      alternateKeys: const ['brightness_tier_preferences'],
    );
final _schedulerScoreAge = NodeField<TargetSchedulerNode, int>(
  'maxConditionsScoreAgeSecs',
  (n) => n.maxConditionsScoreAgeSecs,
  FieldCodec.integer,
  alternateKeys: const ['max_conditions_score_age_secs'],
);
final _schedulerMoonSeparation = NodeField<TargetSchedulerNode, double?>(
  'minMoonSeparationDeg',
  (n) => n.minMoonSeparationDeg,
  FieldCodec.optionalReal,
  alternateKeys: const ['min_moon_separation_deg'],
);
final _schedulerHorizon = NodeField<TargetSchedulerNode, HorizonProfile?>(
  'horizonProfile',
  (n) => n.horizonProfile,
  _horizonCodec,
  alternateKeys: const ['horizon_profile'],
);

final _slewUseTarget = NodeField<SlewNode, bool>(
  'useTargetCoords',
  (n) => n.useTargetCoords,
  FieldCodec.flag,
);
final _slewRa = NodeField<SlewNode, double?>(
  'customRa',
  (n) => n.customRa,
  FieldCodec.optionalReal,
);
final _slewDec = NodeField<SlewNode, double?>(
  'customDec',
  (n) => n.customDec,
  FieldCodec.optionalReal,
);

final _centerUseTarget = NodeField<CenterNode, bool>(
  'useTargetCoords',
  (n) => n.useTargetCoords,
  FieldCodec.flag,
);
final _centerRa = NodeField<CenterNode, double?>(
  'customRa',
  (n) => n.customRa,
  FieldCodec.optionalReal,
);
final _centerDec = NodeField<CenterNode, double?>(
  'customDec',
  (n) => n.customDec,
  FieldCodec.optionalReal,
);
final _centerAccuracy = NodeField<CenterNode, double>(
  'accuracyArcsec',
  (n) => n.accuracyArcsec,
  FieldCodec.real,
);
final _centerAttempts = NodeField<CenterNode, int>(
  'maxAttempts',
  (n) => n.maxAttempts,
  FieldCodec.integer,
);
final _centerExposure = NodeField<CenterNode, double>(
  'exposureDuration',
  (n) => n.exposureDuration,
  FieldCodec.real,
);
final _centerFilter = NodeField<CenterNode, String?>(
  'filter',
  (n) => n.filter,
  FieldCodec.optionalText,
);

final _exposureDuration = NodeField<ExposureNode, double>(
  'durationSecs',
  (n) => n.durationSecs,
  FieldCodec.real,
);
final _exposureCount = NodeField<ExposureNode, int>(
  'count',
  (n) => n.count,
  FieldCodec.integer,
);
final _exposureFrameType = NodeField<ExposureNode, FrameType>(
  'frameType',
  (n) => n.frameType,
  FieldCodec.named(FrameType.values),
);
final _exposureFilter = NodeField<ExposureNode, String?>(
  'filter',
  (n) => n.filter,
  FieldCodec.optionalText,
);
final _exposureFilterIndex = NodeField<ExposureNode, int?>(
  'filterIndex',
  (n) => n.filterIndex,
  FieldCodec.optionalInteger,
);
final _exposureGain = NodeField<ExposureNode, int?>(
  'gain',
  (n) => n.gain,
  FieldCodec.optionalInteger,
);
final _exposureOffset = NodeField<ExposureNode, int?>(
  'offset',
  (n) => n.offset,
  FieldCodec.optionalInteger,
);
final _exposureBinning = NodeField<ExposureNode, BinningMode>(
  'binning',
  (n) => n.binning,
  FieldCodec.named(BinningMode.values),
);
final _exposureDitherEvery = NodeField<ExposureNode, int?>(
  'ditherEvery',
  (n) => n.ditherEvery,
  FieldCodec.optionalInteger,
);
final _exposureTriggers = NodeField<ExposureNode, List<Map<String, dynamic>>>(
  'triggers',
  (n) => n.triggers,
  FieldCodec.objects,
);
final _exposureAdaptive = NodeField<ExposureNode, AdaptiveExposureConfig?>(
  'adaptiveExposure',
  (n) => n.adaptiveExposure,
  FieldCodec.json((c) => c!.toJson(), AdaptiveExposureConfig.fromJson),
  alternateKeys: const ['adaptive_exposure'],
);

final _smartPlans = NodeField<SmartExposureNode, List<FilterPlan>>(
  'plans',
  (n) => n.plans,
  _plansCodec,
);
final _smartRotate = NodeField<SmartExposureNode, bool>(
  'rotateFilters',
  (n) => n.rotateFilters,
  FieldCodec.flag,
);
final _smartDitherOnChange = NodeField<SmartExposureNode, bool>(
  'ditherOnFilterChange',
  (n) => n.ditherOnFilterChange,
  FieldCodec.flag,
);
final _smartBudget = NodeField<SmartExposureNode, double>(
  'integrationBudgetSecs',
  (n) => n.integrationBudgetSecs,
  FieldCodec.real,
);
final _smartBatch = NodeField<SmartExposureNode, int>(
  'batchSize',
  (n) => n.batchSize,
  FieldCodec.integer,
);
final _smartLoop = NodeField<SmartExposureNode, bool>(
  'loopUntilStopped',
  (n) => n.loopUntilStopped,
  FieldCodec.flag,
);

final _focusMethod = NodeField<AutofocusNode, AutofocusMethod>(
  'method',
  (n) => n.method,
  _autofocusMethodCodec,
);
final _focusStepSize = NodeField<AutofocusNode, int>(
  'stepSize',
  (n) => n.stepSize,
  FieldCodec.integer,
);
final _focusStepsOut = NodeField<AutofocusNode, int>(
  'stepsOut',
  (n) => n.stepsOut,
  FieldCodec.integer,
);
final _focusPerPoint = NodeField<AutofocusNode, int>(
  'exposuresPerPoint',
  (n) => n.exposuresPerPoint,
  FieldCodec.integer,
);
final _focusExposure = NodeField<AutofocusNode, double>(
  'exposureDuration',
  (n) => n.exposureDuration,
  FieldCodec.real,
);
final _focusUseSettings = NodeField<AutofocusNode, bool>(
  'useSettingsDefaults',
  (n) => n.useSettingsDefaults,
  FieldCodec.flag,
);
final _focusMaxSecs = NodeField<AutofocusNode, double>(
  'maxDurationSecs',
  (n) => n.maxDurationSecs,
  FieldCodec.real,
);

final _ditherPixels = NodeField<DitherNode, double>(
  'pixels',
  (n) => n.pixels,
  FieldCodec.real,
);
final _ditherSettlePixels = NodeField<DitherNode, double>(
  'settlePixels',
  (n) => n.settlePixels,
  FieldCodec.real,
);
final _ditherSettleTime = NodeField<DitherNode, double>(
  'settleTime',
  (n) => n.settleTime,
  FieldCodec.real,
);
final _ditherSettleTimeout = NodeField<DitherNode, double>(
  'settleTimeout',
  (n) => n.settleTimeout,
  FieldCodec.real,
);
final _ditherRaOnly = NodeField<DitherNode, bool>(
  'raOnly',
  (n) => n.raOnly,
  FieldCodec.flag,
);
final _ditherPattern = NodeField<DitherNode, DitherPattern>(
  'pattern',
  (n) => n.pattern,
  FieldCodec.named(DitherPattern.values),
);
final _ditherGridSize = NodeField<DitherNode, int>(
  'gridSize',
  (n) => n.gridSize,
  FieldCodec.integer,
);

final _guideSettlePixels = NodeField<StartGuidingNode, double>(
  'settlePixels',
  (n) => n.settlePixels,
  FieldCodec.real,
);
final _guideSettleTime = NodeField<StartGuidingNode, double>(
  'settleTime',
  (n) => n.settleTime,
  FieldCodec.real,
);
final _guideSettleTimeout = NodeField<StartGuidingNode, double>(
  'settleTimeout',
  (n) => n.settleTimeout,
  FieldCodec.real,
);
final _guideAutoSelect = NodeField<StartGuidingNode, bool>(
  'autoSelectStar',
  (n) => n.autoSelectStar,
  FieldCodec.flag,
);

final _filterName = NodeField<FilterChangeNode, String>(
  'filterName',
  (n) => n.filterName,
  FieldCodec.text,
);
final _filterPosition = NodeField<FilterChangeNode, int?>(
  'filterPosition',
  (n) => n.filterPosition,
  FieldCodec.optionalInteger,
);

final _coolTarget = NodeField<CoolCameraNode, double>(
  'targetTemp',
  (n) => n.targetTemp,
  FieldCodec.real,
);
final _coolMinutes = NodeField<CoolCameraNode, double?>(
  'durationMins',
  (n) => n.durationMins,
  FieldCodec.optionalReal,
);

final _warmRate = NodeField<WarmCameraNode, double>(
  'ratePerMin',
  (n) => n.ratePerMin,
  FieldCodec.real,
);
final _warmTarget = NodeField<WarmCameraNode, double>(
  'targetTemp',
  (n) => n.targetTemp,
  FieldCodec.real,
);

final _rotatorAngle = NodeField<RotatorNode, double>(
  'targetAngle',
  (n) => n.targetAngle,
  FieldCodec.real,
);
final _rotatorRelative = NodeField<RotatorNode, bool>(
  'relative',
  (n) => n.relative,
  FieldCodec.flag,
);

final _waitUntil = NodeField<WaitTimeNode, DateTime?>(
  'waitUntil',
  (n) => n.waitUntil,
  FieldCodec.instant,
);
final _waitTwilight = NodeField<WaitTimeNode, TwilightType?>(
  'waitForTwilight',
  (n) => n.waitForTwilight,
  FieldCodec.optionalNamed(TwilightType.values),
);

final _delaySeconds = NodeField<DelayNode, double>(
  'seconds',
  (n) => n.seconds,
  FieldCodec.real,
);

final _notifyTitle = NodeField<NotificationNode, String>(
  'title',
  (n) => n.title,
  FieldCodec.text,
);
final _notifyMessage = NodeField<NotificationNode, String>(
  'message',
  (n) => n.message,
  FieldCodec.text,
);
final _notifyLevel = NodeField<NotificationNode, NotificationLevel>(
  'level',
  (n) => n.level,
  FieldCodec.named(NotificationLevel.values),
);
final _notifyTransports =
    NodeField<NotificationNode, List<NotificationTransportKind>?>(
      'explicitTransports',
      (n) => n.explicitTransports,
      _transportsCodec,
      omitWhenNull: true,
    );

final _scriptPath = NodeField<ScriptNode, String>(
  'scriptPath',
  (n) => n.scriptPath,
  FieldCodec.text,
);
final _scriptArguments = NodeField<ScriptNode, List<String>>(
  'arguments',
  (n) => n.arguments,
  FieldCodec.texts,
);
final _scriptTimeout = NodeField<ScriptNode, int?>(
  'timeoutSecs',
  (n) => n.timeoutSecs,
  FieldCodec.optionalInteger,
);

final _flipTrigger = NodeField<MeridianFlipNode, MeridianTriggerMethod>(
  'triggerMethod',
  (n) => n.triggerMethod,
  FieldCodec.named(MeridianTriggerMethod.values),
);
NodeField<MeridianFlipNode, double> _flipReal(
  String key,
  double Function(MeridianFlipNode n) read,
) => NodeField(key, read, FieldCodec.real);
NodeField<MeridianFlipNode, bool> _flipFlag(
  String key,
  bool Function(MeridianFlipNode n) read,
) => NodeField(key, read, FieldCodec.flag);
final _flipMinutesPast = _flipReal(
  'minutesPastMeridian',
  (n) => n.minutesPastMeridian,
);
final _flipMinutesBefore = _flipReal(
  'minutesBeforeLimit',
  (n) => n.minutesBeforeLimit,
);
final _flipHourAngle = _flipReal(
  'hourAngleThreshold',
  (n) => n.hourAngleThreshold,
);
final _flipPauseGuiding = _flipFlag('pauseGuiding', (n) => n.pauseGuiding);
final _flipAutoCenter = _flipFlag('autoCenter', (n) => n.autoCenter);
final _flipRefocus = _flipFlag('refocusAfter', (n) => n.refocusAfter);
final _flipSettle = _flipReal('settleTime', (n) => n.settleTime);
final _flipResumeGuiding = _flipFlag('resumeGuiding', (n) => n.resumeGuiding);
final _flipMaxRetries = NodeField<MeridianFlipNode, int>(
  'maxRetries',
  (n) => n.maxRetries,
  FieldCodec.integer,
);
final _flipFailure = NodeField<MeridianFlipNode, FlipFailureAction>(
  'failureAction',
  (n) => n.failureAction,
  FieldCodec.named(FlipFailureAction.values),
);

/// A sequence saved before the flag existed keeps its own per-node values.
final _flipUseGlobal = NodeField<MeridianFlipNode, bool>(
  'useGlobalDefaults',
  (n) => n.useGlobalDefaults,
  FieldCodec.flag,
  absentIn: {NodeStore.database: false, NodeStore.document: false},
);

final _openDomeShutter = NodeField<OpenDomeNode, bool>(
  'shutterOnly',
  (n) => n.shutterOnly,
  FieldCodec.flag,
);
final _closeDomeShutter = NodeField<CloseDomeNode, bool>(
  'shutterOnly',
  (n) => n.shutterOnly,
  FieldCodec.flag,
);
final _parkDomeShutter = NodeField<ParkDomeNode, bool>(
  'shutterOnly',
  (n) => n.shutterOnly,
  FieldCodec.flag,
);

final _polarExposure = NodeField<PolarAlignmentNode, double>(
  'exposureDuration',
  (n) => n.exposureDuration,
  FieldCodec.real,
);
final _polarBinning = NodeField<PolarAlignmentNode, int>(
  'binning',
  (n) => n.binning,
  FieldCodec.integer,
);
final _polarStartAltitude = NodeField<PolarAlignmentNode, double>(
  'startAltitude',
  (n) => n.startAltitude,
  FieldCodec.real,
);
final _polarRotationStep = NodeField<PolarAlignmentNode, double>(
  'rotationStep',
  (n) => n.rotationStep,
  FieldCodec.real,
);
final _polarGain = NodeField<PolarAlignmentNode, int?>(
  'gain',
  (n) => n.gain,
  FieldCodec.optionalInteger,
);
final _polarOffset = NodeField<PolarAlignmentNode, int?>(
  'offset',
  (n) => n.offset,
  FieldCodec.optionalInteger,
);
final _polarFromCurrent = NodeField<PolarAlignmentNode, bool>(
  'startFromCurrent',
  (n) => n.startFromCurrent,
  FieldCodec.flag,
);
final _polarIsNorth = NodeField<PolarAlignmentNode, bool>(
  'isNorth',
  (n) => n.isNorth,
  FieldCodec.flag,
);
final _polarManualSlew = NodeField<PolarAlignmentNode, bool>(
  'manualSlew',
  (n) => n.manualSlew,
  FieldCodec.flag,
);

final _openCoverTimeout = NodeField<OpenCoverNode, int>(
  'timeoutSecs',
  (n) => n.timeoutSecs,
  FieldCodec.integer,
);
final _closeCoverTimeout = NodeField<CloseCoverNode, int>(
  'timeoutSecs',
  (n) => n.timeoutSecs,
  FieldCodec.integer,
);
final _calibratorBrightness = NodeField<CalibratorOnNode, int>(
  'brightness',
  (n) => n.brightness,
  FieldCodec.integer,
);
final _calibratorOnTimeout = NodeField<CalibratorOnNode, int>(
  'timeoutSecs',
  (n) => n.timeoutSecs,
  FieldCodec.integer,
);
final _calibratorOffTimeout = NodeField<CalibratorOffNode, int>(
  'timeoutSecs',
  (n) => n.timeoutSecs,
  FieldCodec.integer,
);

final _stackMode = NodeField<LiveStackingNode, LiveStackingMode>(
  'mode',
  (n) => n.mode,
  FieldCodec.custom(
    encode: (mode, store) => mode.storageKey,
    decode: (raw, store) => LiveStackingMode.fromStorageKey(raw as String?),
  ),
);
final _stackMethod = NodeField<LiveStackingNode, LiveStackingMethod>(
  'stackMethod',
  (n) => n.stackMethod,
  FieldCodec.custom(
    encode: (method, store) => method.storageKey,
    decode: (raw, store) => LiveStackingMethod.fromStorageKey(raw as String?),
  ),
);
final _stackMaxFrames = NodeField<LiveStackingNode, int>(
  'maxFramesToStack',
  (n) => n.maxFramesToStack,
  FieldCodec.integer,
);
final _stackBroadcast = NodeField<LiveStackingNode, bool>(
  'broadcastEnabled',
  (n) => n.broadcastEnabled,
  FieldCodec.flag,
);
final _stackToken = NodeField<LiveStackingNode, String?>(
  'authToken',
  (n) => n.authToken,
  FieldCodec.optionalText,
);
final _stackWatermark = NodeField<LiveStackingNode, String?>(
  'watermarkText',
  (n) => n.watermarkText,
  FieldCodec.optionalText,
);
final _stackThumbWidth = NodeField<LiveStackingNode, int>(
  'thumbnailWidth',
  (n) => n.thumbnailWidth,
  FieldCodec.integer,
);
final _stackThumbHeight = NodeField<LiveStackingNode, int>(
  'thumbnailHeight',
  (n) => n.thumbnailHeight,
  FieldCodec.integer,
);

final _scienceTarget = NodeField<SciencePhotometryNode, String>(
  'targetDesignation',
  (n) => n.targetDesignation,
  FieldCodec.text,
);
final _scienceRefs = NodeField<SciencePhotometryNode, List<String>>(
  'referenceStars',
  (n) => n.referenceStars,
  FieldCodec.texts,
);
final _scienceCadence = NodeField<SciencePhotometryNode, double>(
  'maxCadenceGapSecs',
  (n) => n.maxCadenceGapSecs,
  FieldCodec.real,
);
final _scienceFilter = NodeField<SciencePhotometryNode, String>(
  'filter',
  (n) => n.filter,
  FieldCodec.text,
);
final _scienceExposure = NodeField<SciencePhotometryNode, double>(
  'exposureSecs',
  (n) => n.exposureSecs,
  FieldCodec.real,
);
final _scienceCount = NodeField<SciencePhotometryNode, int>(
  'count',
  (n) => n.count,
  FieldCodec.integer,
);
final _scienceReduceLive = NodeField<SciencePhotometryNode, bool>(
  'reduceLive',
  (n) => n.reduceLive,
  FieldCodec.flag,
);
final _scienceDifferential = NodeField<SciencePhotometryNode, bool>(
  'applyDifferential',
  (n) => n.applyDifferential,
  FieldCodec.flag,
);
final _scienceQuality =
    NodeField<SciencePhotometryNode, PhotometryQualityGates>(
      'quality',
      (n) => n.quality,
      FieldCodec.json((q) => q.toJson(), PhotometryQualityGates.fromJson),
    );
final _scienceGain = NodeField<SciencePhotometryNode, int?>(
  'gain',
  (n) => n.gain,
  FieldCodec.optionalInteger,
);
final _scienceOffset = NodeField<SciencePhotometryNode, int?>(
  'offset',
  (n) => n.offset,
  FieldCodec.optionalInteger,
);
final _scienceBinning = NodeField<SciencePhotometryNode, BinningMode>(
  'binning',
  (n) => n.binning,
  FieldCodec.named(BinningMode.values),
);

final _pluginId = NodeField<PluginInstructionNode, String>(
  'pluginId',
  (n) => n.pluginId,
  FieldCodec.text,
);
final _pluginNodeTypeId = NodeField<PluginInstructionNode, String>(
  'nodeTypeId',
  (n) => n.nodeTypeId,
  FieldCodec.text,
);
final _pluginConfig = NodeField<PluginInstructionNode, String>(
  'configJson',
  (n) => n.configJson,
  FieldCodec.text,
);
final _pluginTimeout = NodeField<PluginInstructionNode, int?>(
  'timeoutSecs',
  (n) => n.timeoutSecs,
  FieldCodec.optionalInteger,
);
final _pluginName = NodeField<PluginInstructionNode, String>(
  'pluginName',
  (n) => n.pluginName,
  FieldCodec.text,
);
final _pluginIcon = NodeField<PluginInstructionNode, String>(
  'iconHint',
  (n) => n.iconHint,
  FieldCodec.text,
);

/// The node types, one entry each.
abstract final class NodeKinds {
  static final targetHeader = NodeKind<TargetHeaderNode>(
    wireName: 'TargetHeader',
    legacyNames: const ['targetGroup'],
    icon: 'target',
    category: NodeCategory.target,
    autoName: (node) => node.displayName,
    isContainer: true,
    requiredDevices: const {DeviceType.mount},
    create: () => TargetHeaderNode(targetName: '', raHours: 0, decDegrees: 0),
    fields: [
      _targetName,
      _targetRa,
      _targetDec,
      _targetRotation,
      _targetPriority,
      _targetMinAltitude,
      _targetMaxAltitude,
      _targetStartAfter,
      _targetEndBefore,
      _targetMosaicPanel,
      _targetBudget,
      _targetStartWhen,
      _targetEndWhen,
      _targetPollSecs,
      _targetBrightnessTier,
    ],
    build: (v) => TargetHeaderNode(
      targetName: v(_targetName),
      raHours: v(_targetRa),
      decDegrees: v(_targetDec),
      rotation: v(_targetRotation),
      priority: v(_targetPriority),
      minAltitude: v(_targetMinAltitude),
      maxAltitude: v(_targetMaxAltitude),
      startAfter: v(_targetStartAfter),
      endBefore: v(_targetEndBefore),
      mosaicPanel: v(_targetMosaicPanel),
      integrationBudget: v(_targetBudget),
      startWhen: v(_targetStartWhen),
      endWhen: v(_targetEndWhen),
      triggerPollIntervalSecs: v(_targetPollSecs),
      brightnessTierHint: v(_targetBrightnessTier),
    ),
    describe: (n) => 'Target "${n.targetName}"',
    diff: [
      NodeDiffLine.of(_targetName, 'Target name'),
      NodeDiffLine.of(_targetRa, 'RA (hours)', (v) => v.toStringAsFixed(4)),
      NodeDiffLine.of(_targetDec, 'Dec (degrees)', (v) => v.toStringAsFixed(4)),
      NodeDiffLine.of(
        _targetRotation,
        'Rotation',
        (v) => v?.toStringAsFixed(2) ?? '(none)',
      ),
      NodeDiffLine.of(_targetPriority, 'Priority'),
      NodeDiffLine.of(
        _targetMinAltitude,
        'Min altitude',
        (v) => v?.toStringAsFixed(0) ?? '(none)',
      ),
      NodeDiffLine.of(
        _targetMaxAltitude,
        'Max altitude',
        (v) => v?.toStringAsFixed(0) ?? '(none)',
      ),
      NodeDiffLine.summary(
        'Integration budget',
        (n) => n.integrationBudget == null ? '(none)' : 'set',
      ),
      NodeDiffLine.of(
        _targetBrightnessTier,
        'Brightness tier',
        (v) => v?.name ?? '(none)',
      ),
    ],
  );

  static final loop = NodeKind<LoopNode>(
    wireName: 'Loop',
    legacyNames: const ['loop'],
    icon: 'repeat',
    category: NodeCategory.logic,
    isContainer: true,
    create: LoopNode.new,
    fields: [
      _loopCondition,
      _loopRepeatCount,
      _loopRepeatUntil,
      _loopUntilAltitude,
      _loopIntegrationTarget,
      _loopSafetyIterations,
    ],
    build: (v) => LoopNode(
      conditionType: v(_loopCondition),
      repeatCount: v(_loopRepeatCount),
      repeatUntil: v(_loopRepeatUntil),
      repeatUntilAltitude: v(_loopUntilAltitude),
      integrationTimeTarget: v(_loopIntegrationTarget),
      maxSafetyIterations: v(_loopSafetyIterations),
    ),
    describe: (n) =>
        n.conditionType == LoopConditionType.count && n.repeatCount != null
        ? 'Loop x${n.repeatCount}'
        : 'Loop (${n.conditionType.name})',
    diff: [
      NodeDiffLine.of(_loopCondition, 'Loop condition', (v) => v.name),
      NodeDiffLine.of(_loopRepeatCount, 'Repeat count', _orNone),
      NodeDiffLine.of(_loopUntilAltitude, 'Repeat until altitude', _orNone),
      NodeDiffLine.of(
        _loopIntegrationTarget,
        'Integration target (s)',
        _orNone,
      ),
    ],
  );

  static final parallel = NodeKind<ParallelNode>(
    wireName: 'Parallel',
    legacyNames: const ['parallel'],
    icon: 'git-branch',
    category: NodeCategory.logic,
    isContainer: true,
    create: ParallelNode.new,
    fields: [_parallelRequired],
    build: (v) => ParallelNode(requiredSuccesses: v(_parallelRequired)),
    describe: (n) => 'Parallel',
    diff: [
      NodeDiffLine.of(
        _parallelRequired,
        'Required successes',
        (v) => v?.toString() ?? '(all)',
      ),
    ],
  );

  static final conditional = NodeKind<ConditionalNode>(
    wireName: 'Conditional',
    legacyNames: const ['conditional'],
    icon: 'git-merge',
    category: NodeCategory.logic,
    isContainer: true,
    create: ConditionalNode.new,
    fields: [
      _conditionalType,
      _conditionalThreshold,
      _conditionalTime,
      _conditionalMonitor,
    ],
    build: (v) => ConditionalNode(
      conditionType: v(_conditionalType),
      thresholdValue: v(_conditionalThreshold),
      thresholdTime: v(_conditionalTime),
      safetyMonitorId: v(_conditionalMonitor),
    ),
    describe: (n) => 'Conditional (${n.conditionType.name})',
    diff: [
      NodeDiffLine.of(_conditionalType, 'Condition', (v) => v.name),
      NodeDiffLine.of(_conditionalThreshold, 'Threshold', _orNone),
      NodeDiffLine.of(_conditionalMonitor, 'Safety monitor', _orDefault),
    ],
  );

  static final recovery = NodeKind<RecoveryNode>(
    wireName: 'Recovery',
    legacyNames: const ['recovery'],
    icon: 'shield-check',
    category: NodeCategory.logic,
    isContainer: true,
    create: RecoveryNode.new,
    fields: [
      _recoveryAction,
      _recoveryMaxRetries,
      _recoveryTrigger,
      _recoveryThreshold,
      _recoveryHfrPercent,
      _recoveryHfrFrames,
      _recoveryEveryNFrames,
      _recoveryDriftWindow,
      _recoveryDriftCount,
      _recoveryDriftIncrease,
      _recoveryGuidingSecs,
      _recoveryCloudMinutes,
      _recoveryCloudCoverage,
      _recoveryCloudOpening,
      _recoveryCloudCoverMax,
      _recoveryCloudCoverSecs,
      _recoveryTransparency,
      _recoveryTransparencySecs,
    ],
    build: (v) => RecoveryNode(
      recoveryAction: v(_recoveryAction),
      maxRetries: v(_recoveryMaxRetries),
      triggerType: v(_recoveryTrigger),
      triggerThreshold: v(_recoveryThreshold),
      hfrThresholdPercent: v(_recoveryHfrPercent),
      hfrConsecutiveFrames: v(_recoveryHfrFrames),
      triggerEveryNFrames: v(_recoveryEveryNFrames),
      focusDriftWindowSize: v(_recoveryDriftWindow),
      focusDriftMinIncreasingCount: v(_recoveryDriftCount),
      focusDriftMinTotalIncrease: v(_recoveryDriftIncrease),
      guidingFailedDurationSecs: v(_recoveryGuidingSecs),
      cloudMinutesBefore: v(_recoveryCloudMinutes),
      cloudCoverageThresholdPercent: v(_recoveryCloudCoverage),
      cloudOpeningMinDurationSecs: v(_recoveryCloudOpening),
      cloudCoverMaxPercent: v(_recoveryCloudCoverMax),
      cloudCoverDurationSecs: v(_recoveryCloudCoverSecs),
      transparencyBelowThreshold: v(_recoveryTransparency),
      transparencyDurationSecs: v(_recoveryTransparencySecs),
    ),
    describe: (n) => 'Recovery (${n.recoveryAction.name})',
    diff: [
      NodeDiffLine.of(_recoveryAction, 'Recovery action', (v) => v.name),
      NodeDiffLine.of(_recoveryMaxRetries, 'Max retries'),
    ],
  );

  static final instructionSet = NodeKind<InstructionSetNode>(
    wireName: 'InstructionSet',
    legacyNames: const ['instructionSet'],
    icon: 'list',
    category: NodeCategory.logic,
    isContainer: true,
    create: InstructionSetNode.new,
    fields: const [],
    build: (v) => InstructionSetNode(),
    describe: (n) => n.name,
  );

  static final targetScheduler = NodeKind<TargetSchedulerNode>(
    wireName: 'TargetScheduler',
    legacyNames: const ['targetScheduler', 'target_scheduler'],
    icon: 'scheduler',
    category: NodeCategory.logic,
    isContainer: true,
    requiredDevices: const {DeviceType.mount},
    create: TargetSchedulerNode.new,
    fields: [
      _schedulerAltitude,
      _schedulerMoon,
      _schedulerTransit,
      _schedulerDarkness,
      _schedulerAirmass,
      _schedulerMinScore,
      _schedulerRecompute,
      _schedulerFinishIteration,
      _schedulerSwapBelow,
      _schedulerHysteresis,
      _schedulerTiers,
      _schedulerScoreAge,
      _schedulerMoonSeparation,
      _schedulerHorizon,
    ],
    build: (v) => TargetSchedulerNode(
      altitudeWeight: v(_schedulerAltitude),
      moonDistanceWeight: v(_schedulerMoon),
      transitProximityWeight: v(_schedulerTransit),
      darknessWeight: v(_schedulerDarkness),
      airmassWeight: v(_schedulerAirmass),
      minScoreToRun: v(_schedulerMinScore),
      recomputeEveryNExposures: v(_schedulerRecompute),
      finishIterationOnSwitch: v(_schedulerFinishIteration),
      swapOnConditionsBelow: v(_schedulerSwapBelow),
      swapHysteresisSecs: v(_schedulerHysteresis),
      brightnessTierPreferences: v(_schedulerTiers),
      maxConditionsScoreAgeSecs: v(_schedulerScoreAge),
      minMoonSeparationDeg: v(_schedulerMoonSeparation),
      horizonProfile: v(_schedulerHorizon),
    ),
    describe: (n) => 'Target scheduler',
    diff: [
      NodeDiffLine.of(_schedulerAltitude, 'Altitude weight'),
      NodeDiffLine.of(_schedulerMoon, 'Moon-distance weight'),
      NodeDiffLine.of(_schedulerMinScore, 'Min score'),
    ],
  );

  static final slew = NodeKind<SlewNode>(
    wireName: 'SlewToTarget',
    legacyNames: const ['slew'],
    icon: 'compass',
    category: NodeCategory.instruction,
    requiredDevices: const {DeviceType.mount},
    stage: NodeStage.aim,
    create: SlewNode.new,
    fields: [_slewUseTarget, _slewRa, _slewDec],
    build: (v) => SlewNode(
      useTargetCoords: v(_slewUseTarget),
      customRa: v(_slewRa),
      customDec: v(_slewDec),
    ),
    describe: (n) => n.useTargetCoords
        ? 'Slew (target coords)'
        : 'Slew (RA ${n.customRa}, Dec ${n.customDec})',
    diff: [
      NodeDiffLine.of(_slewUseTarget, 'Uses target coords'),
      NodeDiffLine.of(_slewRa, 'Custom RA', _orNone),
      NodeDiffLine.of(_slewDec, 'Custom Dec', _orNone),
    ],
  );

  static final center = NodeKind<CenterNode>(
    wireName: 'CenterTarget',
    legacyNames: const ['center'],
    icon: 'crosshair',
    category: NodeCategory.instruction,
    filters: (node) => [node.filter],
    renameFilter: (node, rename) => node.filter == null
        ? node
        : node.copyWith(filter: rename(node.filter!)),
    requiredDevices: const {DeviceType.mount, DeviceType.camera},
    stage: NodeStage.aim,
    create: CenterNode.new,
    fields: [
      _centerUseTarget,
      _centerRa,
      _centerDec,
      _centerAccuracy,
      _centerAttempts,
      _centerExposure,
      _centerFilter,
    ],
    build: (v) => CenterNode(
      useTargetCoords: v(_centerUseTarget),
      customRa: v(_centerRa),
      customDec: v(_centerDec),
      accuracyArcsec: v(_centerAccuracy),
      maxAttempts: v(_centerAttempts),
      exposureDuration: v(_centerExposure),
      filter: v(_centerFilter),
    ),
    describe: (n) => 'Center (${n.accuracyArcsec}″)',
    diff: [
      NodeDiffLine.of(_centerAccuracy, 'Accuracy (arcsec)'),
      NodeDiffLine.of(_centerAttempts, 'Max attempts'),
    ],
  );

  static final exposure = NodeKind<ExposureNode>(
    wireName: 'TakeExposure',
    legacyNames: const ['exposure'],
    icon: 'camera',
    category: NodeCategory.instruction,
    filters: (node) => [node.filter],
    renameFilter: (node, rename) {
      final filter = node.filter;
      if (filter == null || rename(filter) == filter) return node;
      return node.copyWith(clearFilter: true).copyWith(filter: rename(filter));
    },
    requiredDevices: const {DeviceType.camera},
    stage: NodeStage.capture,
    create: ExposureNode.new,
    fields: [
      _exposureDuration,
      _exposureCount,
      _exposureFrameType,
      _exposureFilter,
      _exposureFilterIndex,
      _exposureGain,
      _exposureOffset,
      _exposureBinning,
      _exposureDitherEvery,
      _exposureTriggers,
      _exposureAdaptive,
    ],
    build: (v) => ExposureNode(
      durationSecs: v(_exposureDuration),
      count: v(_exposureCount),
      frameType: v(_exposureFrameType),
      filter: v(_exposureFilter),
      filterIndex: v(_exposureFilterIndex),
      gain: v(_exposureGain),
      offset: v(_exposureOffset),
      binning: v(_exposureBinning),
      ditherEvery: v(_exposureDitherEvery),
      triggers: v(_exposureTriggers),
      adaptiveExposure: v(_exposureAdaptive),
    ),
    describe: (n) {
      final filter = (n.filter == null || n.filter!.isEmpty)
          ? 'Unfiltered'
          : n.filter!;
      return 'Exposure ${n.durationSecs.toStringAsFixed(0)}s '
          'x${n.count} ($filter)';
    },
    diff: [
      NodeDiffLine.of(_exposureDuration, 'Exposure duration', (v) => '${v}s'),
      NodeDiffLine.of(_exposureCount, 'Frame count'),
      NodeDiffLine.of(_exposureFrameType, 'Frame type', (v) => v.name),
      NodeDiffLine.of(_exposureFilter, 'Filter', _orNone),
      NodeDiffLine.of(
        _exposureFilterIndex,
        'Filter index',
        (v) => v?.toString() ?? '(auto)',
      ),
      NodeDiffLine.of(_exposureGain, exposureGainDiffLabel, _orDefault),
      NodeDiffLine.of(_exposureOffset, 'Offset', _orDefault),
      NodeDiffLine.of(_exposureBinning, 'Binning', (v) => v.name),
      NodeDiffLine.of(
        _exposureDitherEvery,
        'Dither every',
        (v) => v?.toString() ?? '(off)',
      ),
      NodeDiffLine.summary('Triggers', (n) => '${n.triggers.length}'),
    ],
    captures: (n) => [
      (filter: n.filter, count: n.count, exposureSecs: n.durationSecs),
    ],
  );

  static final smartExposure = NodeKind<SmartExposureNode>(
    wireName: 'SmartExposure',
    legacyNames: const ['smartExposure', 'smart_exposure'],
    icon: 'layers',
    category: NodeCategory.instruction,
    filters: (node) => [for (final plan in node.plans) plan.filterName],
    renameFilter: (node, rename) => node.copyWith(
      plans: [
        for (final plan in node.plans)
          rename(plan.filterName) == plan.filterName
              ? plan
              : plan.copyWith(
                  filterName: rename(plan.filterName),
                  filterIndex: null,
                ),
      ],
    ),
    requiredDevices: const {DeviceType.camera, DeviceType.filterWheel},
    stage: NodeStage.capture,
    create: SmartExposureNode.new,
    fields: [
      _smartPlans,
      _smartRotate,
      _smartDitherOnChange,
      _smartBudget,
      _smartBatch,
      _smartLoop,
    ],
    build: (v) => SmartExposureNode(
      plans: v(_smartPlans),
      rotateFilters: v(_smartRotate),
      ditherOnFilterChange: v(_smartDitherOnChange),
      integrationBudgetSecs: v(_smartBudget),
      batchSize: v(_smartBatch),
      loopUntilStopped: v(_smartLoop),
    ),
    describe: (n) => 'Smart exposure (${n.plans.length} plans)',
    diff: [
      NodeDiffLine.summary('Plan count', (n) => '${n.plans.length}'),
      NodeDiffLine.of(_smartRotate, 'Rotate filters'),
      NodeDiffLine.of(_smartBudget, 'Integration budget (s)'),
      NodeDiffLine.of(_smartLoop, 'Loop until stopped'),
    ],
    // Looping until stopped, the run ignores the plan counts.
    captures: (n) => n.loopUntilStopped
        ? const []
        : [
            for (final plan in n.plans)
              (
                filter: plan.filterName,
                count: plan.count,
                exposureSecs: plan.durationSecs,
              ),
          ],
  );

  static final autofocus = NodeKind<AutofocusNode>(
    wireName: 'Autofocus',
    legacyNames: const ['autofocus'],
    icon: 'focus',
    category: NodeCategory.instruction,
    requiredDevices: const {DeviceType.camera, DeviceType.focuser},
    stage: NodeStage.prepare,
    create: AutofocusNode.new,
    fields: [
      _focusMethod,
      _focusStepSize,
      _focusStepsOut,
      _focusPerPoint,
      _focusExposure,
      _focusUseSettings,
      _focusMaxSecs,
    ],
    build: (v) => AutofocusNode(
      method: v(_focusMethod),
      stepSize: v(_focusStepSize),
      stepsOut: v(_focusStepsOut),
      exposuresPerPoint: v(_focusPerPoint),
      exposureDuration: v(_focusExposure),
      useSettingsDefaults: v(_focusUseSettings),
      maxDurationSecs: v(_focusMaxSecs),
    ),
    describe: (n) => 'Autofocus (${n.method.name})',
    diff: [
      NodeDiffLine.of(_focusMethod, 'Method', (v) => v.name),
      NodeDiffLine.of(_focusStepSize, 'Step size'),
      NodeDiffLine.of(_focusExposure, 'Exposure', (v) => '${v}s'),
    ],
  );

  static final dither = NodeKind<DitherNode>(
    wireName: 'Dither',
    legacyNames: const ['dither'],
    icon: 'shuffle',
    category: NodeCategory.instruction,
    requiredDevices: const {DeviceType.guider},
    create: DitherNode.new,
    fields: [
      _ditherPixels,
      _ditherSettlePixels,
      _ditherSettleTime,
      _ditherSettleTimeout,
      _ditherRaOnly,
      _ditherPattern,
      _ditherGridSize,
    ],
    build: (v) => DitherNode(
      pixels: v(_ditherPixels),
      settlePixels: v(_ditherSettlePixels),
      settleTime: v(_ditherSettleTime),
      settleTimeout: v(_ditherSettleTimeout),
      raOnly: v(_ditherRaOnly),
      pattern: v(_ditherPattern),
      gridSize: v(_ditherGridSize),
    ),
    describe: (n) => 'Dither ${n.pixels.toStringAsFixed(1)}px',
    diff: [
      NodeDiffLine.of(_ditherPixels, 'Pixels'),
      NodeDiffLine.of(_ditherSettlePixels, 'Settle pixels'),
      NodeDiffLine.of(_ditherRaOnly, 'RA only'),
      NodeDiffLine.of(_ditherPattern, 'Pattern', (v) => v.name),
      NodeDiffLine.of(_ditherGridSize, 'Grid size', (v) => '${v}x$v'),
    ],
  );

  static final startGuiding = NodeKind<StartGuidingNode>(
    wireName: 'StartGuiding',
    legacyNames: const ['startGuiding'],
    icon: 'crosshair',
    category: NodeCategory.instruction,
    requiredDevices: const {DeviceType.guider},
    stage: NodeStage.prepare,
    create: StartGuidingNode.new,
    fields: [
      _guideSettlePixels,
      _guideSettleTime,
      _guideSettleTimeout,
      _guideAutoSelect,
    ],
    build: (v) => StartGuidingNode(
      settlePixels: v(_guideSettlePixels),
      settleTime: v(_guideSettleTime),
      settleTimeout: v(_guideSettleTimeout),
      autoSelectStar: v(_guideAutoSelect),
    ),
    describe: (n) => 'Start guiding',
    diff: [
      NodeDiffLine.of(_guideSettlePixels, 'Settle pixels'),
      NodeDiffLine.of(_guideSettleTime, 'Settle time', (v) => '${v}s'),
      NodeDiffLine.of(_guideAutoSelect, 'Auto select star'),
    ],
  );

  static final stopGuiding = NodeKind<StopGuidingNode>(
    wireName: 'StopGuiding',
    legacyNames: const ['stopGuiding'],
    icon: 'x-circle',
    category: NodeCategory.instruction,
    requiredDevices: const {DeviceType.guider},
    create: StopGuidingNode.new,
    fields: const [],
    build: (v) => StopGuidingNode(),
    describe: (n) => 'Stop guiding',
  );

  static final filterChange = NodeKind<FilterChangeNode>(
    wireName: 'ChangeFilter',
    legacyNames: const ['filterChange'],
    icon: 'circle',
    category: NodeCategory.instruction,
    filters: (node) => [node.filterName],
    renameFilter: (node, rename) => rename(node.filterName) == node.filterName
        ? node
        : FilterChangeNode(
            id: node.id,
            name: node.name,
            isEnabled: node.isEnabled,
            childIds: node.childIds,
            parentId: node.parentId,
            orderIndex: node.orderIndex,
            comment: node.comment,
            filterName: rename(node.filterName),
          ),
    autoName: (node) =>
        node.filterName.trim().isEmpty ? '' : 'Filter: ${node.filterName}',
    requiredDevices: const {DeviceType.filterWheel},
    create: () => FilterChangeNode(filterName: ''),
    fields: [_filterName, _filterPosition],
    build: (v) => FilterChangeNode(
      filterName: v(_filterName),
      filterPosition: v(_filterPosition),
    ),
    describe: (n) => 'Filter change → ${n.filterName}',
    diff: [
      NodeDiffLine.of(_filterName, 'Filter name'),
      NodeDiffLine.of(
        _filterPosition,
        'Filter position',
        (v) => v?.toString() ?? '(by name)',
      ),
    ],
  );

  static final coolCamera = NodeKind<CoolCameraNode>(
    wireName: 'CoolCamera',
    legacyNames: const ['coolCamera'],
    icon: 'snowflake',
    category: NodeCategory.instruction,
    requiredDevices: const {DeviceType.camera},
    stage: NodeStage.prepare,
    create: CoolCameraNode.new,
    fields: [_coolTarget, _coolMinutes],
    build: (v) => CoolCameraNode(
      targetTemp: v(_coolTarget),
      durationMins: v(_coolMinutes),
    ),
    describe: (n) => 'Cool camera → ${n.targetTemp}C',
    diff: [
      NodeDiffLine.of(_coolTarget, 'Target temp', (v) => '${v}C'),
      NodeDiffLine.of(_coolMinutes, 'Duration (min)'),
    ],
  );

  static final warmCamera = NodeKind<WarmCameraNode>(
    wireName: 'WarmCamera',
    legacyNames: const ['warmCamera'],
    icon: 'flame',
    category: NodeCategory.instruction,
    requiredDevices: const {DeviceType.camera},
    create: WarmCameraNode.new,
    fields: [_warmRate, _warmTarget],
    build: (v) =>
        WarmCameraNode(ratePerMin: v(_warmRate), targetTemp: v(_warmTarget)),
    describe: (n) => 'Warm camera → ${n.targetTemp}C',
    diff: [
      NodeDiffLine.of(_warmRate, 'Rate (C/min)'),
      NodeDiffLine.of(_warmTarget, 'Target temp', (v) => '${v}C'),
    ],
  );

  static final rotator = NodeKind<RotatorNode>(
    wireName: 'MoveRotator',
    legacyNames: const ['rotator'],
    icon: 'rotate-cw',
    category: NodeCategory.instruction,
    requiredDevices: const {DeviceType.rotator},
    stage: NodeStage.prepare,
    create: RotatorNode.new,
    fields: [_rotatorAngle, _rotatorRelative],
    build: (v) => RotatorNode(
      targetAngle: v(_rotatorAngle),
      relative: v(_rotatorRelative),
    ),
    describe: (n) => 'Rotate to ${n.targetAngle}°',
    diff: [
      NodeDiffLine.of(_rotatorAngle, 'Target angle', (v) => '$v°'),
      NodeDiffLine.of(_rotatorRelative, 'Relative'),
    ],
  );

  static final park = NodeKind<ParkNode>(
    wireName: 'Park',
    legacyNames: const ['park'],
    icon: 'parking-circle',
    category: NodeCategory.instruction,
    requiredDevices: const {DeviceType.mount},
    create: ParkNode.new,
    fields: const [],
    build: (v) => ParkNode(),
    describe: (n) => 'Park mount',
  );

  static final unpark = NodeKind<UnparkNode>(
    wireName: 'Unpark',
    legacyNames: const ['unpark'],
    icon: 'unlock',
    category: NodeCategory.instruction,
    requiredDevices: const {DeviceType.mount},
    stage: NodeStage.aim,
    create: UnparkNode.new,
    fields: const [],
    build: (v) => UnparkNode(),
    describe: (n) => 'Unpark mount',
  );

  static final homeMount = NodeKind<HomeMountNode>(
    wireName: 'HomeMount',
    legacyNames: const ['homemount', 'homeMount'],
    icon: 'home',
    category: NodeCategory.instruction,
    requiredDevices: const {DeviceType.mount},
    create: HomeMountNode.new,
    fields: const [],
    build: (v) => HomeMountNode(),
    describe: (n) => 'Home mount',
  );

  static final waitTime = NodeKind<WaitTimeNode>(
    wireName: 'WaitForTime',
    legacyNames: const ['waitTime'],
    icon: 'clock',
    category: NodeCategory.instruction,
    create: WaitTimeNode.new,
    fields: [_waitUntil, _waitTwilight],
    build: (v) => WaitTimeNode(
      waitUntil: v(_waitUntil),
      waitForTwilight: v(_waitTwilight),
    ),
    describe: (n) {
      if (n.waitUntil != null) {
        return 'Wait until ${n.waitUntil!.toIso8601String()}';
      }
      if (n.waitForTwilight != null) {
        return 'Wait for ${n.waitForTwilight!.name} twilight';
      }
      return 'Wait';
    },
    diff: [
      NodeDiffLine.of(
        _waitUntil,
        'Wait until',
        (v) => v?.toIso8601String() ?? '(none)',
      ),
      NodeDiffLine.of(
        _waitTwilight,
        'Wait for twilight',
        (v) => v?.name ?? '(none)',
      ),
    ],
  );

  static final delay = NodeKind<DelayNode>(
    wireName: 'Delay',
    legacyNames: const ['delay'],
    icon: 'timer',
    category: NodeCategory.instruction,
    create: DelayNode.new,
    fields: [_delaySeconds],
    build: (v) => DelayNode(seconds: v(_delaySeconds)),
    describe: (n) => 'Delay ${n.seconds}s',
    diff: [NodeDiffLine.of(_delaySeconds, 'Seconds')],
  );

  static final notification = NodeKind<NotificationNode>(
    wireName: 'Notification',
    legacyNames: const ['notification'],
    icon: 'bell',
    category: NodeCategory.instruction,
    create: NotificationNode.new,
    fields: [_notifyTitle, _notifyMessage, _notifyLevel, _notifyTransports],
    build: (v) => NotificationNode(
      title: v(_notifyTitle),
      message: v(_notifyMessage),
      level: v(_notifyLevel),
      explicitTransports: v(_notifyTransports),
    ),
    describe: (n) => 'Notification "${n.title}"',
    diff: [
      NodeDiffLine.of(_notifyTitle, 'Title'),
      NodeDiffLine.of(_notifyMessage, 'Message'),
      NodeDiffLine.of(_notifyLevel, 'Level', (v) => v.name),
    ],
  );

  static final script = NodeKind<ScriptNode>(
    wireName: 'RunScript',
    legacyNames: const ['script'],
    icon: 'code',
    category: NodeCategory.instruction,
    create: ScriptNode.new,
    fields: [_scriptPath, _scriptArguments, _scriptTimeout],
    build: (v) => ScriptNode(
      scriptPath: v(_scriptPath),
      arguments: v(_scriptArguments),
      timeoutSecs: v(_scriptTimeout),
    ),
    describe: (n) => 'Script ${n.scriptPath}',
    diff: [
      NodeDiffLine.of(_scriptPath, 'Script path'),
      NodeDiffLine.of(_scriptTimeout, 'Timeout (s)'),
    ],
  );

  static final meridianFlip = NodeKind<MeridianFlipNode>(
    wireName: 'MeridianFlip',
    legacyNames: const ['meridianFlip'],
    icon: 'refresh-cw',
    category: NodeCategory.trigger,
    requiredDevices: const {DeviceType.mount},
    create: MeridianFlipNode.new,
    fields: [
      _flipTrigger,
      _flipMinutesPast,
      _flipMinutesBefore,
      _flipHourAngle,
      _flipPauseGuiding,
      _flipAutoCenter,
      _flipRefocus,
      _flipSettle,
      _flipResumeGuiding,
      _flipMaxRetries,
      _flipFailure,
      _flipUseGlobal,
    ],
    build: (v) => MeridianFlipNode(
      triggerMethod: v(_flipTrigger),
      minutesPastMeridian: v(_flipMinutesPast),
      minutesBeforeLimit: v(_flipMinutesBefore),
      hourAngleThreshold: v(_flipHourAngle),
      pauseGuiding: v(_flipPauseGuiding),
      autoCenter: v(_flipAutoCenter),
      refocusAfter: v(_flipRefocus),
      settleTime: v(_flipSettle),
      resumeGuiding: v(_flipResumeGuiding),
      maxRetries: v(_flipMaxRetries),
      failureAction: v(_flipFailure),
      useGlobalDefaults: v(_flipUseGlobal),
    ),
    describe: (n) => 'Meridian flip',
    diff: [
      NodeDiffLine.of(_flipTrigger, 'Trigger method', (v) => v.name),
      NodeDiffLine.of(_flipMinutesPast, 'Minutes past meridian'),
      NodeDiffLine.of(_flipPauseGuiding, 'Pause guiding'),
    ],
  );

  static final openDome = NodeKind<OpenDomeNode>(
    wireName: 'OpenDome',
    legacyNames: const ['openDome'],
    icon: 'home',
    category: NodeCategory.instruction,
    requiredDevices: const {DeviceType.dome},
    create: OpenDomeNode.new,
    fields: [_openDomeShutter],
    build: (v) => OpenDomeNode(shutterOnly: v(_openDomeShutter)),
    describe: (n) => 'Open dome',
  );

  static final closeDome = NodeKind<CloseDomeNode>(
    wireName: 'CloseDome',
    legacyNames: const ['closeDome'],
    icon: 'home',
    category: NodeCategory.instruction,
    requiredDevices: const {DeviceType.dome},
    create: CloseDomeNode.new,
    fields: [_closeDomeShutter],
    build: (v) => CloseDomeNode(shutterOnly: v(_closeDomeShutter)),
    describe: (n) => 'Close dome',
  );

  static final parkDome = NodeKind<ParkDomeNode>(
    wireName: 'ParkDome',
    legacyNames: const ['parkDome'],
    icon: 'parking-circle',
    category: NodeCategory.instruction,
    requiredDevices: const {DeviceType.dome},
    create: ParkDomeNode.new,
    fields: [_parkDomeShutter],
    build: (v) => ParkDomeNode(shutterOnly: v(_parkDomeShutter)),
    describe: (n) => 'Park dome',
  );

  static final polarAlignment = NodeKind<PolarAlignmentNode>(
    wireName: 'PolarAlignment',
    legacyNames: const ['polarAlignment', 'polAlignment'],
    icon: 'compass',
    category: NodeCategory.instruction,
    requiredDevices: const {DeviceType.camera, DeviceType.mount},
    create: PolarAlignmentNode.new,
    fields: [
      _polarExposure,
      _polarBinning,
      _polarStartAltitude,
      _polarRotationStep,
      _polarGain,
      _polarOffset,
      _polarFromCurrent,
      _polarIsNorth,
      _polarManualSlew,
    ],
    build: (v) => PolarAlignmentNode(
      exposureDuration: v(_polarExposure),
      binning: v(_polarBinning),
      startAltitude: v(_polarStartAltitude),
      rotationStep: v(_polarRotationStep),
      gain: v(_polarGain),
      offset: v(_polarOffset),
      startFromCurrent: v(_polarFromCurrent),
      isNorth: v(_polarIsNorth),
      manualSlew: v(_polarManualSlew),
    ),
    describe: (n) => 'Polar alignment',
    diff: [
      NodeDiffLine.of(_polarExposure, 'Exposure', (v) => '${v}s'),
      NodeDiffLine.of(_polarStartAltitude, 'Start altitude', (v) => '$v°'),
      NodeDiffLine.of(_polarIsNorth, 'Is north'),
    ],
  );

  static final openCover = NodeKind<OpenCoverNode>(
    wireName: 'OpenCover',
    legacyNames: const ['openCover', 'open_cover'],
    icon: 'door-open',
    category: NodeCategory.instruction,
    requiredDevices: const {DeviceType.coverCalibrator},
    create: OpenCoverNode.new,
    fields: [_openCoverTimeout],
    build: (v) => OpenCoverNode(timeoutSecs: v(_openCoverTimeout)),
    describe: (n) => 'Open dust cover',
  );

  static final closeCover = NodeKind<CloseCoverNode>(
    wireName: 'CloseCover',
    legacyNames: const ['closeCover', 'close_cover'],
    icon: 'door-closed',
    category: NodeCategory.instruction,
    requiredDevices: const {DeviceType.coverCalibrator},
    create: CloseCoverNode.new,
    fields: [_closeCoverTimeout],
    build: (v) => CloseCoverNode(timeoutSecs: v(_closeCoverTimeout)),
    describe: (n) => 'Close dust cover',
  );

  static final calibratorOn = NodeKind<CalibratorOnNode>(
    wireName: 'CalibratorOn',
    legacyNames: const ['calibratorOn', 'calibrator_on'],
    icon: 'lightbulb',
    category: NodeCategory.instruction,
    requiredDevices: const {DeviceType.coverCalibrator},
    create: CalibratorOnNode.new,
    fields: [_calibratorBrightness, _calibratorOnTimeout],
    build: (v) => CalibratorOnNode(
      brightness: v(_calibratorBrightness),
      timeoutSecs: v(_calibratorOnTimeout),
    ),
    describe: (n) => 'Calibrator on',
  );

  static final calibratorOff = NodeKind<CalibratorOffNode>(
    wireName: 'CalibratorOff',
    legacyNames: const ['calibratorOff', 'calibrator_off'],
    icon: 'lightbulb-off',
    category: NodeCategory.instruction,
    requiredDevices: const {DeviceType.coverCalibrator},
    create: CalibratorOffNode.new,
    fields: [_calibratorOffTimeout],
    build: (v) => CalibratorOffNode(timeoutSecs: v(_calibratorOffTimeout)),
    describe: (n) => 'Calibrator off',
  );

  static final liveStacking = NodeKind<LiveStackingNode>(
    wireName: 'LiveStacking',
    legacyNames: const ['liveStacking', 'live_stacking'],
    icon: 'cast_connected',
    category: NodeCategory.instruction,
    create: LiveStackingNode.new,
    fields: [
      _stackMode,
      _stackMethod,
      _stackMaxFrames,
      _stackBroadcast,
      _stackToken,
      _stackWatermark,
      _stackThumbWidth,
      _stackThumbHeight,
    ],
    build: (v) => LiveStackingNode(
      mode: v(_stackMode),
      stackMethod: v(_stackMethod),
      maxFramesToStack: v(_stackMaxFrames),
      broadcastEnabled: v(_stackBroadcast),
      authToken: v(_stackToken),
      watermarkText: v(_stackWatermark),
      thumbnailWidth: v(_stackThumbWidth),
      thumbnailHeight: v(_stackThumbHeight),
    ),
    describe: (n) {
      final access = n.isPublic ? 'public' : 'private';
      return 'Live stacking ($access)';
    },
    diff: [
      NodeDiffLine.of(_stackMode, 'Mode', (v) => v.label),
      NodeDiffLine.of(_stackMethod, 'Stack method', (v) => v.label),
      NodeDiffLine.of(_stackBroadcast, 'Broadcast enabled'),
      NodeDiffLine.summary('Public access', (n) => '${n.isPublic}'),
      NodeDiffLine.of(_stackWatermark, 'Watermark', _orNone),
    ],
  );

  static final sciencePhotometry = NodeKind<SciencePhotometryNode>(
    wireName: 'SciencePhotometry',
    legacyNames: const ['sciencePhotometry', 'science_photometry'],
    icon: 'analytics',
    category: NodeCategory.instruction,
    requiredDevices: const {DeviceType.camera, DeviceType.filterWheel},
    create: SciencePhotometryNode.new,
    fields: [
      _scienceTarget,
      _scienceRefs,
      _scienceCadence,
      _scienceFilter,
      _scienceExposure,
      _scienceCount,
      _scienceReduceLive,
      _scienceDifferential,
      _scienceQuality,
      _scienceGain,
      _scienceOffset,
      _scienceBinning,
    ],
    build: (v) => SciencePhotometryNode(
      targetDesignation: v(_scienceTarget),
      referenceStars: v(_scienceRefs),
      maxCadenceGapSecs: v(_scienceCadence),
      filter: v(_scienceFilter),
      exposureSecs: v(_scienceExposure),
      count: v(_scienceCount),
      reduceLive: v(_scienceReduceLive),
      applyDifferential: v(_scienceDifferential),
      quality: v(_scienceQuality),
      gain: v(_scienceGain),
      offset: v(_scienceOffset),
      binning: v(_scienceBinning),
    ),
    describe: (n) =>
        'Photometry (${n.targetDesignation}, ${n.filter}, '
        '${n.count}x${n.exposureSecs.toStringAsFixed(0)}s)',
    diff: [
      NodeDiffLine.of(_scienceTarget, 'Target designation'),
      NodeDiffLine.of(_scienceFilter, 'Filter'),
      NodeDiffLine.of(_scienceExposure, 'Exposure (s)'),
      NodeDiffLine.of(_scienceCount, 'Count'),
      NodeDiffLine.of(_scienceCadence, 'Cadence gap (s)'),
      NodeDiffLine.summary(
        'Reference stars',
        (n) => n.referenceStars.join(','),
      ),
    ],
    captures: (n) => [
      (filter: n.filter, count: n.count, exposureSecs: n.exposureSecs),
    ],
  );

  static final plugin = NodeKind<PluginInstructionNode>(
    wireName: 'PluginNode',
    legacyNames: const ['pluginNode', 'plugin_node'],
    icon: 'puzzle',
    category: NodeCategory.instruction,
    create: () => PluginInstructionNode(pluginId: '', nodeTypeId: ''),
    fields: [
      _pluginId,
      _pluginNodeTypeId,
      _pluginConfig,
      _pluginTimeout,
      _pluginName,
      _pluginIcon,
    ],
    build: (v) => PluginInstructionNode(
      pluginId: v(_pluginId),
      nodeTypeId: v(_pluginNodeTypeId),
      configJson: v(_pluginConfig),
      timeoutSecs: v(_pluginTimeout),
      pluginName: v(_pluginName),
      iconHint: v(_pluginIcon),
    ),
    describe: (n) {
      final source = n.pluginName.isEmpty ? n.pluginId : n.pluginName;
      return 'Plugin: ${n.name} ($source)';
    },
    diff: [
      NodeDiffLine.of(_pluginId, 'Plugin id'),
      NodeDiffLine.of(_pluginNodeTypeId, 'Node type id'),
      NodeDiffLine.of(_pluginConfig, 'Config'),
      NodeDiffLine.of(_pluginTimeout, 'Timeout (s)', _orDefault),
    ],
  );
}
