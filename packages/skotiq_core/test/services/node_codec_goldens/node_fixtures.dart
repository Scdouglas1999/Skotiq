// One instance of every sequence node type, twice: with every field set to a
// value that differs from its default, and with nothing but the required
// fields. Both sets share ids (`n-<Type>`) so a diff between them lists every
// field the diff service knows about.

import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';

final DateTime _t0 = DateTime.utc(2026, 3, 14, 22, 30);
final DateTime _t1 = DateTime.utc(2026, 3, 15, 4, 45);

String nodeId(String type) => 'n-$type';

/// Every node type with every field set.
List<SequenceNode> fullNodes() => [
  TargetHeaderNode(
    id: nodeId('TargetHeader'),
    name: 'M31 field',
    comment: 'north panel',
    isEnabled: false,
    targetName: 'M31',
    raHours: 0.712,
    decDegrees: 41.27,
    rotation: 12.5,
    priority: 3,
    minAltitude: 25,
    maxAltitude: 80,
    startAfter: _t0,
    endBefore: _t1,
    mosaicPanel: const MosaicPanelInfo(
      mosaicName: 'M31 2x2',
      panelIndex: 1,
      totalPanels: 4,
      row: 0,
      column: 1,
    ),
    integrationBudget: const IntegrationBudget(
      totalSecs: 7200,
      perFilter: {
        'L': FilterBudgetEntry.absolute(3600),
        'R': FilterBudgetEntry.ratio(0.25),
      },
      stopOnBudgetMet: false,
    ),
    startWhen: const TargetTrigger.and([
      TargetTrigger.altitudeAbove(35),
      TargetTrigger.hourAngleBetween(minHa: -2, maxHa: 3),
    ]),
    endWhen: const TargetTrigger.timeBefore(1773550000),
    triggerPollIntervalSecs: 45,
    brightnessTierHint: BrightnessTier.medium,
    catalogTargetId: 4242,
  ),
  LoopNode(
    id: nodeId('Loop'),
    name: 'Until dawn',
    comment: 'loop note',
    conditionType: LoopConditionType.untilTime,
    repeatCount: 7,
    repeatUntil: _t1,
    repeatUntilAltitude: 22.5,
    integrationTimeTarget: 5400,
    maxSafetyIterations: 99,
  ),
  ParallelNode(
    id: nodeId('Parallel'),
    name: 'Both',
    comment: 'parallel note',
    requiredSuccesses: 2,
  ),
  ConditionalNode(
    id: nodeId('Conditional'),
    name: 'If safe',
    comment: 'conditional note',
    conditionType: ConditionalType.safetyMonitorSafe,
    thresholdValue: 1.25,
    thresholdTime: _t0,
    safetyMonitorId: 'safety-2',
  ),
  RecoveryNode(
    id: nodeId('Recovery'),
    name: 'Recover clouds',
    comment: 'recovery note',
    recoveryAction: RecoveryActionType.continueExecution,
    maxRetries: 5,
    triggerType: TriggerType.cloudCoverThreshold,
    triggerThreshold: 2.5,
    hfrThresholdPercent: 30,
    hfrConsecutiveFrames: 4,
    triggerEveryNFrames: 12,
    focusDriftWindowSize: 14,
    focusDriftMinIncreasingCount: 6,
    focusDriftMinTotalIncrease: 0.75,
    guidingFailedDurationSecs: 45,
    cloudMinutesBefore: 15,
    cloudCoverageThresholdPercent: 65,
    cloudOpeningMinDurationSecs: 420,
    cloudCoverMaxPercent: 85,
    cloudCoverDurationSecs: 90,
    transparencyBelowThreshold: 0.55,
    transparencyDurationSecs: 75,
  ),
  InstructionSetNode(
    id: nodeId('InstructionSet'),
    name: 'Group',
    comment: 'set note',
  ),
  TargetSchedulerNode(
    id: nodeId('TargetScheduler'),
    name: 'Pick best',
    comment: 'scheduler note',
    altitudeWeight: 0.3,
    moonDistanceWeight: 0.2,
    transitProximityWeight: 0.1,
    darknessWeight: 0.25,
    airmassWeight: 0.15,
    minScoreToRun: 42,
    recomputeEveryNExposures: 8,
    finishIterationOnSwitch: false,
    swapOnConditionsBelow: 55,
    swapHysteresisSecs: 240,
    brightnessTierPreferences: const BrightnessTierPreferences(
      faintMinScore: 75,
      mediumMinScore: 55,
      brightMinScore: 35,
    ),
    maxConditionsScoreAgeSecs: 450,
    minMoonSeparationDeg: 40,
    horizonProfile: const HorizonProfile(
      id: 7,
      name: 'Trees',
      samples: [HorizonSample(0, 12), HorizonSample(180, 20)],
    ),
  ),
  SlewNode(
    id: nodeId('SlewToTarget'),
    name: 'Slew custom',
    comment: 'slew note',
    useTargetCoords: false,
    customRa: 5.5,
    customDec: -5.4,
  ),
  CenterNode(
    id: nodeId('CenterTarget'),
    name: 'Center custom',
    comment: 'center note',
    accuracyArcsec: 2.5,
    maxAttempts: 7,
    useTargetCoords: false,
    customRa: 5.6,
    customDec: -5.3,
    exposureDuration: 8,
    filter: 'L',
  ),
  ExposureNode(
    id: nodeId('TakeExposure'),
    name: 'Ha subs',
    comment: 'exposure note',
    durationSecs: 300,
    count: 24,
    frameType: FrameType.flat,
    filter: 'Ha',
    filterIndex: 4,
    gain: 120,
    offset: 30,
    binning: BinningMode.two,
    ditherEvery: 5,
    triggers: const [
      {
        'condition': {'HfrAbove': 3.5},
        'action': 'Autofocus',
        'debounce_secs': 45.0,
      },
    ],
    adaptiveExposure: const AdaptiveExposureConfig(
      targetSnr: 40,
      referenceSkyBrightnessMag: 20.5,
      minExposureSecs: 10,
      maxExposureSecs: 900,
      perFilterEnabled: {'Ha': true},
      perFilterMinSecs: {'Ha': 60},
      perFilterMaxSecs: {'Ha': 1200},
    ),
  ),
  SmartExposureNode(
    id: nodeId('SmartExposure'),
    name: 'LRGB smart',
    comment: 'smart note',
    plans: const [
      FilterPlan(
        filterName: 'L',
        filterIndex: 0,
        count: 30,
        durationSecs: 120,
        gain: 100,
        offset: 20,
        binning: BinningMode.two,
        ditherEvery: 4,
      ),
      FilterPlan(filterName: 'R', count: 10, durationSecs: 180),
    ],
    rotateFilters: false,
    ditherOnFilterChange: true,
    integrationBudgetSecs: 10800,
    batchSize: 3,
    loopUntilStopped: true,
  ),
  AutofocusNode(
    id: nodeId('Autofocus'),
    name: 'Focus custom',
    comment: 'focus note',
    method: AutofocusMethod.quadratic,
    stepSize: 80,
    stepsOut: 9,
    exposuresPerPoint: 2,
    exposureDuration: 4.5,
    useSettingsDefaults: false,
    maxDurationSecs: 900,
  ),
  DitherNode(
    id: nodeId('Dither'),
    name: 'Dither big',
    comment: 'dither note',
    pixels: 8,
    settleTime: 20,
    settlePixels: 0.8,
    settleTimeout: 90,
    raOnly: true,
    pattern: DitherPattern.grid,
    gridSize: 5,
  ),
  StartGuidingNode(
    id: nodeId('StartGuiding'),
    name: 'Guide',
    comment: 'guide note',
    settlePixels: 0.9,
    settleTime: 15,
    settleTimeout: 75,
    autoSelectStar: false,
  ),
  StopGuidingNode(
    id: nodeId('StopGuiding'),
    name: 'Stop guide',
    comment: 'stop note',
  ),
  FilterChangeNode(
    id: nodeId('ChangeFilter'),
    name: 'To OIII',
    comment: 'filter note',
    filterName: 'OIII',
    filterPosition: 5,
  ),
  CoolCameraNode(
    id: nodeId('CoolCamera'),
    name: 'Cool deep',
    comment: 'cool note',
    targetTemp: -20,
    durationMins: 15,
  ),
  WarmCameraNode(
    id: nodeId('WarmCamera'),
    name: 'Warm slow',
    comment: 'warm note',
    ratePerMin: 1.5,
    targetTemp: 15,
  ),
  RotatorNode(
    id: nodeId('MoveRotator'),
    name: 'Rotate',
    comment: 'rotator note',
    targetAngle: 92.5,
    relative: true,
  ),
  ParkNode(id: nodeId('Park'), name: 'Park it', comment: 'park note'),
  UnparkNode(id: nodeId('Unpark'), name: 'Unpark it', comment: 'unpark note'),
  HomeMountNode(
    id: nodeId('HomeMount'),
    name: 'Home it',
    comment: 'home note',
  ),
  WaitTimeNode(
    id: nodeId('WaitForTime'),
    name: 'Wait dusk',
    comment: 'wait note',
    waitUntil: _t0,
    waitForTwilight: TwilightType.nautical,
  ),
  DelayNode(
    id: nodeId('Delay'),
    name: 'Pause',
    comment: 'delay note',
    seconds: 42.5,
  ),
  NotificationNode(
    id: nodeId('Notification'),
    name: 'Tell me',
    comment: 'notify note',
    title: 'Done',
    message: 'Target {target} finished',
    level: NotificationLevel.warning,
    explicitTransports: const [
      NotificationTransportKind.discord,
      NotificationTransportKind.email,
    ],
  ),
  ScriptNode(
    id: nodeId('RunScript'),
    name: 'Script',
    comment: 'script note',
    scriptPath: '/opt/rig/flats.sh',
    arguments: const ['--fast', '-n', '3'],
    timeoutSecs: 120,
  ),
  MeridianFlipNode(
    id: nodeId('MeridianFlip'),
    name: 'Flip',
    comment: 'flip note',
    triggerMethod: MeridianTriggerMethod.hourAngleThreshold,
    minutesPastMeridian: 7,
    minutesBeforeLimit: 12,
    hourAngleThreshold: 0.75,
    pauseGuiding: false,
    autoCenter: false,
    refocusAfter: true,
    settleTime: 20,
    resumeGuiding: false,
    maxRetries: 5,
    failureAction: FlipFailureAction.abortAndPark,
    useGlobalDefaults: false,
  ),
  OpenDomeNode(
    id: nodeId('OpenDome'),
    name: 'Open',
    comment: 'open dome note',
    shutterOnly: true,
  ),
  CloseDomeNode(
    id: nodeId('CloseDome'),
    name: 'Close',
    comment: 'close dome note',
    shutterOnly: true,
  ),
  ParkDomeNode(
    id: nodeId('ParkDome'),
    name: 'Park dome',
    comment: 'park dome note',
    shutterOnly: true,
  ),
  PolarAlignmentNode(
    id: nodeId('PolarAlignment'),
    name: 'Polar',
    comment: 'polar note',
    exposureDuration: 3.5,
    binning: 1,
    startAltitude: 50,
    rotationStep: 25,
    gain: 150,
    offset: 15,
    startFromCurrent: false,
    isNorth: false,
    manualSlew: true,
  ),
  OpenCoverNode(
    id: nodeId('OpenCover'),
    name: 'Open cover',
    comment: 'open cover note',
    timeoutSecs: 75,
  ),
  CloseCoverNode(
    id: nodeId('CloseCover'),
    name: 'Close cover',
    comment: 'close cover note',
    timeoutSecs: 80,
  ),
  CalibratorOnNode(
    id: nodeId('CalibratorOn'),
    name: 'Panel on',
    comment: 'calibrator on note',
    brightness: 200,
    timeoutSecs: 40,
  ),
  CalibratorOffNode(
    id: nodeId('CalibratorOff'),
    name: 'Panel off',
    comment: 'calibrator off note',
    timeoutSecs: 35,
  ),
  LiveStackingNode(
    id: nodeId('LiveStacking'),
    name: 'Stack live',
    comment: 'live note',
    mode: LiveStackingMode.recordAndBroadcast,
    stackMethod: LiveStackingMethod.sigma,
    maxFramesToStack: 50,
    broadcastEnabled: false,
    authToken: 'secret-token',
    watermarkText: 'Backyard',
    thumbnailWidth: 1920,
    thumbnailHeight: 1080,
  ),
  SciencePhotometryNode(
    id: nodeId('SciencePhotometry'),
    name: 'Photometry',
    comment: 'science note',
    targetDesignation: 'V0376 Per',
    referenceStars: const ['ref-a', 'ref-b'],
    maxCadenceGapSecs: 1.5,
    filter: 'V',
    exposureSecs: 30,
    count: 120,
    reduceLive: false,
    applyDifferential: false,
    quality: const PhotometryQualityGates(
      minSnr: 75,
      maxFwhmArcsec: 3.5,
      requireAllRefsVisible: false,
      maxAirmass: 2.0,
    ),
    gain: 100,
    offset: 20,
    binning: BinningMode.two,
  ),
  PluginInstructionNode(
    id: nodeId('PluginNode'),
    name: 'Plugin step',
    comment: 'plugin note',
    pluginId: 'com.example.rig',
    nodeTypeId: 'flat-panel-sweep',
    configJson: '{"level":3}',
    timeoutSecs: 600,
    pluginName: 'Example Rig',
    iconHint: 'wrench',
  ),
];

/// Every node type with only the fields its constructor requires.
List<SequenceNode> defaultNodes() => [
  TargetHeaderNode(
    id: nodeId('TargetHeader'),
    targetName: 'M31',
    raHours: 0.712,
    decDegrees: 41.27,
  ),
  LoopNode(id: nodeId('Loop')),
  ParallelNode(id: nodeId('Parallel')),
  ConditionalNode(id: nodeId('Conditional')),
  RecoveryNode(id: nodeId('Recovery')),
  InstructionSetNode(id: nodeId('InstructionSet')),
  TargetSchedulerNode(id: nodeId('TargetScheduler')),
  SlewNode(id: nodeId('SlewToTarget')),
  CenterNode(id: nodeId('CenterTarget')),
  ExposureNode(id: nodeId('TakeExposure')),
  SmartExposureNode(id: nodeId('SmartExposure')),
  AutofocusNode(id: nodeId('Autofocus')),
  DitherNode(id: nodeId('Dither')),
  StartGuidingNode(id: nodeId('StartGuiding')),
  StopGuidingNode(id: nodeId('StopGuiding')),
  FilterChangeNode(id: nodeId('ChangeFilter'), filterName: 'L'),
  CoolCameraNode(id: nodeId('CoolCamera')),
  WarmCameraNode(id: nodeId('WarmCamera')),
  RotatorNode(id: nodeId('MoveRotator')),
  ParkNode(id: nodeId('Park')),
  UnparkNode(id: nodeId('Unpark')),
  HomeMountNode(id: nodeId('HomeMount')),
  WaitTimeNode(id: nodeId('WaitForTime')),
  DelayNode(id: nodeId('Delay')),
  NotificationNode(id: nodeId('Notification')),
  ScriptNode(id: nodeId('RunScript')),
  MeridianFlipNode(id: nodeId('MeridianFlip')),
  OpenDomeNode(id: nodeId('OpenDome')),
  CloseDomeNode(id: nodeId('CloseDome')),
  ParkDomeNode(id: nodeId('ParkDome')),
  PolarAlignmentNode(id: nodeId('PolarAlignment')),
  OpenCoverNode(id: nodeId('OpenCover')),
  CloseCoverNode(id: nodeId('CloseCover')),
  CalibratorOnNode(id: nodeId('CalibratorOn')),
  CalibratorOffNode(id: nodeId('CalibratorOff')),
  LiveStackingNode(id: nodeId('LiveStacking')),
  SciencePhotometryNode(id: nodeId('SciencePhotometry')),
  PluginInstructionNode(
    id: nodeId('PluginNode'),
    pluginId: 'com.example.rig',
    nodeTypeId: 'flat-panel-sweep',
  ),
];

/// [nodes] as children of one root instruction set, in list order.
Sequence flatSequence(String id, List<SequenceNode> nodes) {
  final children = <String, SequenceNode>{};
  for (final (i, node) in nodes.indexed) {
    children[node.id] = node.copyWith(parentId: 'root', orderIndex: i);
  }
  return Sequence(
    id: id,
    name: 'Every node ($id)',
    description: 'golden',
    rootNodeId: 'root',
    nodes: {
      'root': InstructionSetNode(
        id: 'root',
        name: 'Root',
        childIds: [for (final node in nodes) node.id],
      ),
      ...children,
    },
    createdAt: _t0,
    modifiedAt: _t1,
  );
}

/// A codec-independent picture of a decoded node: its class and every value
/// it compares by.
Map<String, Object?> dumpNode(SequenceNode node) => {
  'class': node.runtimeType.toString(),
  'nodeType': node.nodeType,
  'props': [for (final p in node.props) plain(p)],
};

Object? plain(Object? value) {
  if (value == null || value is num || value is bool || value is String) {
    return value;
  }
  if (value is Enum) return value.name;
  if (value is DateTime) return value.toUtc().toIso8601String();
  if (value is Duration) return value.inMilliseconds;
  if (value is List) return [for (final v in value) plain(v)];
  if (value is Set) return [for (final v in value) plain(v)]..sort(_byString);
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    return {
      for (final k in keys)
        k: plain(value.entries.firstWhere((e) => e.key.toString() == k).value),
    };
  }
  try {
    return plain((value as dynamic).toJson());
  } on NoSuchMethodError {
    return value.toString();
  }
}

int _byString(Object? a, Object? b) => '$a'.compareTo('$b');
