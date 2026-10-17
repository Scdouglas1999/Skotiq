// Comet, solar, lunar, and remote-observatory node-tree factories.
part of '../templates_tab.dart';

Map<String, SequenceNode> _createCometNodes() {
  const rootId = 'comet-root';
  const coolId = 'comet-cool';
  const slewId = 'comet-slew';
  const centerId = 'comet-center';
  const startGuideId = 'comet-startguide';
  const outerLoopId = 'comet-outer-loop';
  const innerLoopId = 'comet-inner-loop';
  const expId = 'comet-exp';
  const recenterAfterId = 'comet-recenter';
  const stopGuideId = 'comet-stopguide';
  const warmId = 'comet-warm';
  const parkId = 'comet-park';

  return {
    rootId: InstructionSetNode(
      id: rootId,
      name: 'Comet/Asteroid Tracking Sequence',
      childIds: const [
        coolId,
        slewId,
        centerId,
        startGuideId,
        outerLoopId,
        stopGuideId,
        warmId,
        parkId
      ],
    ),
    coolId: CoolCameraNode(
        id: coolId, targetTemp: -10, parentId: rootId, orderIndex: 0),
    slewId: SlewNode(
        id: slewId, name: 'Slew to Target', parentId: rootId, orderIndex: 1),
    centerId: CenterNode(
        id: centerId,
        name: 'Initial Center on Target',
        parentId: rootId,
        orderIndex: 2),
    startGuideId: StartGuidingNode(
      id: startGuideId,
      name: 'Start Guiding',
      settlePixels: 1.5,
      settleTime: 10.0,
      settleTimeout: 60.0,
      autoSelectStar: true,
      parentId: rootId,
      orderIndex: 3,
    ),
    outerLoopId: LoopNode(
      id: outerLoopId,
      name: 'Capture While Dark',
      conditionType: LoopConditionType.whileDark,
      parentId: rootId,
      orderIndex: 4,
      childIds: const [innerLoopId, recenterAfterId],
    ),
    // Inner loop: capture 10 frames between re-centering
    innerLoopId: LoopNode(
      id: innerLoopId,
      name: 'Frame Burst (10 frames)',
      conditionType: LoopConditionType.count,
      repeatCount: 10,
      parentId: outerLoopId,
      orderIndex: 0,
      childIds: const [expId],
    ),
    expId: ExposureNode(
      id: expId,
      name: 'Light Frame',
      durationSecs: 60,
      count: 1,
      binning: BinningMode.one,
      ditherEvery: 0, // No dithering for moving targets
      parentId: innerLoopId,
      orderIndex: 0,
    ),
    // Re-center on moving target after each burst
    recenterAfterId: CenterNode(
      id: recenterAfterId,
      name: 'Re-center on Moving Target',
      parentId: outerLoopId,
      orderIndex: 1,
    ),
    stopGuideId: StopGuidingNode(
        id: stopGuideId, name: 'Stop Guiding', parentId: rootId, orderIndex: 5),
    warmId: WarmCameraNode(
        id: warmId, ratePerMin: 5, parentId: rootId, orderIndex: 6),
    parkId: ParkNode(
        id: parkId, name: 'Park Mount', parentId: rootId, orderIndex: 7),
  };
}

/// Solar Ha template - daytime solar imaging with frequent autofocus
/// Structure:
/// InstructionSet (root)
/// ├── Loop (count: 100)
/// │   ├── TakeExposure (0.01s, high gain: 400)
/// │   └── Conditional (every 10th iteration - use Recovery with filter change trigger)
/// │       └── Autofocus
/// └── Notification ("Solar session complete")
///
/// Note: For solar imaging, we use short exposures and high gain.
/// The conditional autofocus uses a temperature shift trigger as a proxy
/// for periodic refocusing since seeing conditions change rapidly.
Map<String, SequenceNode> _createSolarNodes() {
  const rootId = 'solar-root';
  const loopId = 'solar-loop';
  const expId = 'solar-exp';
  const recoveryId = 'solar-recovery';
  const recoveryFocusId = 'solar-recovery-focus';
  const notifyId = 'solar-notify';

  return {
    rootId: InstructionSetNode(
      id: rootId,
      name: 'Solar Ha Sequence',
      childIds: const [loopId, notifyId],
    ),
    loopId: LoopNode(
      id: loopId,
      name: 'Solar Capture Loop',
      conditionType: LoopConditionType.count,
      repeatCount: 100,
      parentId: rootId,
      orderIndex: 0,
      childIds: const [expId, recoveryId],
    ),
    expId: ExposureNode(
      id: expId,
      name: 'Solar Frame',
      durationSecs: 0.01, // 10ms exposure for solar
      count: 1,
      gain: 400, // High gain for solar Ha
      binning: BinningMode.one,
      parentId: loopId,
      orderIndex: 0,
    ),
    // Recovery node triggers periodic autofocus based on temperature drift
    // This serves as a proxy for "every N frames" since solar seeing changes rapidly
    recoveryId: RecoveryNode(
      id: recoveryId,
      name: 'Periodic Focus Check',
      recoveryAction: RecoveryActionType.autofocus,
      maxRetries: 1,
      triggerType: TriggerType.temperatureShift,
      triggerThreshold:
          0.5, // Trigger on small temp changes as proxy for periodic focus
      parentId: loopId,
      orderIndex: 1,
      childIds: const [recoveryFocusId],
    ),
    recoveryFocusId: AutofocusNode(
      id: recoveryFocusId,
      method: AutofocusMethod.vCurve,
      parentId: recoveryId,
      orderIndex: 0,
    ),
    notifyId: NotificationNode(
      id: notifyId,
      name: 'Session Complete',
      title: 'Solar Session Complete',
      message: 'Solar Ha imaging session has finished capturing 100 frames.',
      level: NotificationLevel.success,
      parentId: rootId,
      orderIndex: 1,
    ),
  };
}

/// Lunar Surface template - high-resolution lunar imaging with lucky imaging bursts
/// Structure:
/// InstructionSet (root)
/// ├── Slew
/// ├── CenterTarget
/// ├── Loop (count: 5)  [Multiple video bursts]
/// │   ├── TakeExposure (0.05s, video burst, high gain: 300)
/// │   └── Autofocus
/// └── Notification ("Lunar capture complete")
Map<String, SequenceNode> _createLunarNodes() {
  const rootId = 'lunar-root';
  const slewId = 'lunar-slew';
  const centerId = 'lunar-center';
  const loopId = 'lunar-loop';
  const expId = 'lunar-exp';
  const focusId = 'lunar-focus';
  const notifyId = 'lunar-notify';

  return {
    rootId: InstructionSetNode(
      id: rootId,
      name: 'Lunar Surface Sequence',
      childIds: const [slewId, centerId, loopId, notifyId],
    ),
    slewId: SlewNode(
        id: slewId,
        name: 'Slew to Lunar Target',
        parentId: rootId,
        orderIndex: 0),
    centerId: CenterNode(
        id: centerId,
        name: 'Center on Lunar Feature',
        parentId: rootId,
        orderIndex: 1),
    loopId: LoopNode(
      id: loopId,
      name: 'Video Burst Loop',
      conditionType: LoopConditionType.count,
      repeatCount: 5,
      parentId: rootId,
      orderIndex: 2,
      childIds: const [expId, focusId],
    ),
    expId: ExposureNode(
      id: expId,
      name: 'Lunar Video Burst',
      durationSecs: 0.05, // 50ms exposures for lucky imaging
      count: 500, // 500 frames per burst (25 seconds of video)
      gain: 300,
      binning: BinningMode.one,
      parentId: loopId,
      orderIndex: 0,
    ),
    focusId: AutofocusNode(
      id: focusId,
      name: 'Refocus Between Bursts',
      method: AutofocusMethod.vCurve,
      parentId: loopId,
      orderIndex: 1,
    ),
    notifyId: NotificationNode(
      id: notifyId,
      name: 'Capture Complete',
      title: 'Lunar Capture Complete',
      message:
          'Lunar surface imaging session has finished with 5 video bursts.',
      level: NotificationLevel.success,
      parentId: rootId,
      orderIndex: 3,
    ),
  };
}

/// Remote Observatory template - full remote operation with safety monitors
/// Structure:
/// InstructionSet (root)
/// ├── Conditional (weatherSafe)
/// │   └── InstructionSet (main sequence)
/// │       ├── CoolCamera
/// │       ├── Slew
/// │       ├── CenterTarget
/// │       ├── Autofocus
/// │       ├── StartGuiding
/// │       ├── Loop (whileDark)
/// │       │   ├── TakeExposure (L, 120s)
/// │       │   ├── TakeExposure (R, 120s)
/// │       │   ├── TakeExposure (G, 120s)
/// │       │   ├── TakeExposure (B, 120s)
/// │       │   └── Dither
/// │       ├── StopGuiding
/// │       ├── WarmCamera
/// │       └── Park
/// └── InstructionSet (emergency fallback - weather unsafe)
///     ├── Park
///     └── Notification ("Weather unsafe - parked")
Map<String, SequenceNode> _createRemoteObservatoryNodes() {
  const rootId = 'remote-root';

  // Weather conditional
  const weatherCondId = 'remote-weather-cond';

  // Main sequence nodes
  const mainSeqId = 'remote-main';
  const coolId = 'remote-cool';
  const slewId = 'remote-slew';
  const centerId = 'remote-center';
  const focusId = 'remote-focus';
  const startGuideId = 'remote-startguide';
  const loopId = 'remote-loop';
  const lId = 'remote-l';
  const rId = 'remote-r';
  const gId = 'remote-g';
  const bId = 'remote-b';
  const ditherId = 'remote-dither';
  const stopGuideId = 'remote-stopguide';
  const warmId = 'remote-warm';
  const parkId = 'remote-park';

  // Emergency fallback nodes
  const emergencyId = 'remote-emergency';
  const emergencyParkId = 'remote-emergency-park';
  const emergencyNotifyId = 'remote-emergency-notify';

  return {
    rootId: InstructionSetNode(
      id: rootId,
      name: 'Remote Observatory Sequence',
      childIds: const [weatherCondId, emergencyId],
    ),

    // Weather safety conditional - only proceed if weather is safe
    weatherCondId: ConditionalNode(
      id: weatherCondId,
      name: 'Weather Safe Check',
      conditionType: ConditionalType.weatherSafe,
      parentId: rootId,
      orderIndex: 0,
      childIds: const [mainSeqId],
    ),

    // Main imaging sequence (executed when weather is safe)
    mainSeqId: InstructionSetNode(
      id: mainSeqId,
      name: 'Main Imaging Sequence',
      parentId: weatherCondId,
      orderIndex: 0,
      childIds: const [
        coolId,
        slewId,
        centerId,
        focusId,
        startGuideId,
        loopId,
        stopGuideId,
        warmId,
        parkId
      ],
    ),
    coolId: CoolCameraNode(
        id: coolId, targetTemp: -10, parentId: mainSeqId, orderIndex: 0),
    slewId: SlewNode(
        id: slewId, name: 'Slew to Target', parentId: mainSeqId, orderIndex: 1),
    centerId: CenterNode(
        id: centerId,
        name: 'Plate Solve & Center',
        parentId: mainSeqId,
        orderIndex: 2),
    focusId: AutofocusNode(
        id: focusId,
        method: AutofocusMethod.vCurve,
        parentId: mainSeqId,
        orderIndex: 3),
    startGuideId: StartGuidingNode(
      id: startGuideId,
      name: 'Start Guiding',
      settlePixels: 1.5,
      settleTime: 10.0,
      settleTimeout: 60.0,
      autoSelectStar: true,
      parentId: mainSeqId,
      orderIndex: 4,
    ),
    loopId: LoopNode(
      id: loopId,
      name: 'LRGB Capture While Dark',
      conditionType: LoopConditionType.whileDark,
      parentId: mainSeqId,
      orderIndex: 5,
      childIds: const [lId, rId, gId, bId, ditherId],
    ),
    lId: ExposureNode(
      id: lId,
      name: 'Luminance',
      durationSecs: 120,
      count: 1,
      filter: 'L',
      binning: BinningMode.one,
      parentId: loopId,
      orderIndex: 0,
    ),
    rId: ExposureNode(
      id: rId,
      name: 'Red',
      durationSecs: 120,
      count: 1,
      filter: 'R',
      binning: BinningMode.one,
      parentId: loopId,
      orderIndex: 1,
    ),
    gId: ExposureNode(
      id: gId,
      name: 'Green',
      durationSecs: 120,
      count: 1,
      filter: 'G',
      binning: BinningMode.one,
      parentId: loopId,
      orderIndex: 2,
    ),
    bId: ExposureNode(
      id: bId,
      name: 'Blue',
      durationSecs: 120,
      count: 1,
      filter: 'B',
      binning: BinningMode.one,
      parentId: loopId,
      orderIndex: 3,
    ),
    ditherId: DitherNode(
      id: ditherId,
      name: 'Dither',
      pixels: 5.0,
      settleTime: 30,
      parentId: loopId,
      orderIndex: 4,
    ),
    stopGuideId: StopGuidingNode(
        id: stopGuideId,
        name: 'Stop Guiding',
        parentId: mainSeqId,
        orderIndex: 6),
    warmId: WarmCameraNode(
        id: warmId, ratePerMin: 5, parentId: mainSeqId, orderIndex: 7),
    parkId: ParkNode(
        id: parkId, name: 'Park Mount', parentId: mainSeqId, orderIndex: 8),

    // Emergency fallback sequence (executed when weather is NOT safe)
    // This runs as a parallel branch when the conditional fails
    emergencyId: InstructionSetNode(
      id: emergencyId,
      name: 'Emergency Shutdown',
      parentId: rootId,
      orderIndex: 1,
      childIds: const [emergencyParkId, emergencyNotifyId],
    ),
    emergencyParkId: ParkNode(
      id: emergencyParkId,
      name: 'Emergency Park',
      parentId: emergencyId,
      orderIndex: 0,
    ),
    emergencyNotifyId: NotificationNode(
      id: emergencyNotifyId,
      name: 'Weather Alert',
      title: 'Weather Unsafe - Observatory Parked',
      message:
          'Weather conditions are unsafe. The mount has been parked and the session was not started.',
      level: NotificationLevel.warning,
      parentId: emergencyId,
      orderIndex: 1,
    ),
  };
}
