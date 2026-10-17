// Multi-target, planetary, unattended, and mosaic node-tree factories.
part of '../templates_tab.dart';

Map<String, SequenceNode> _createMultiTargetNodes() {
  const rootId = 'multi-root';
  const coolId = 'multi-cool';

  // Target 1 nodes
  const target1CondId = 'multi-t1-cond';
  const target1SeqId = 'multi-t1-seq';
  const slew1Id = 'multi-t1-slew';
  const center1Id = 'multi-t1-center';
  const focus1Id = 'multi-t1-focus';
  const guide1StartId = 'multi-t1-guidestart';
  const loop1Id = 'multi-t1-loop';
  const exp1Id = 'multi-t1-exp';
  const dither1Id = 'multi-t1-dither';
  const guide1StopId = 'multi-t1-guidestop';

  // Target 2 nodes
  const target2CondId = 'multi-t2-cond';
  const target2SeqId = 'multi-t2-seq';
  const slew2Id = 'multi-t2-slew';
  const center2Id = 'multi-t2-center';
  const focus2Id = 'multi-t2-focus';
  const guide2StartId = 'multi-t2-guidestart';
  const loop2Id = 'multi-t2-loop';
  const exp2Id = 'multi-t2-exp';
  const dither2Id = 'multi-t2-dither';
  const guide2StopId = 'multi-t2-guidestop';

  const warmId = 'multi-warm';
  const parkId = 'multi-park';

  return {
    rootId: InstructionSetNode(
      id: rootId,
      name: 'Multi-Target Night Sequence',
      childIds: const [coolId, target1CondId, target2CondId, warmId, parkId],
    ),
    coolId: CoolCameraNode(
        id: coolId, targetTemp: -10, parentId: rootId, orderIndex: 0),

    // Target 1 with altitude conditional
    target1CondId: ConditionalNode(
      id: target1CondId,
      name: 'Target 1 Above 30 deg',
      conditionType: ConditionalType.altitudeAbove,
      thresholdValue: 30.0,
      parentId: rootId,
      orderIndex: 1,
      childIds: const [target1SeqId],
    ),
    target1SeqId: InstructionSetNode(
      id: target1SeqId,
      name: 'Target 1 Imaging',
      parentId: target1CondId,
      orderIndex: 0,
      childIds: const [
        slew1Id,
        center1Id,
        focus1Id,
        guide1StartId,
        loop1Id,
        guide1StopId
      ],
    ),
    slew1Id: SlewNode(
        id: slew1Id,
        name: 'Slew to Target 1',
        parentId: target1SeqId,
        orderIndex: 0),
    center1Id: CenterNode(
        id: center1Id,
        name: 'Center Target 1',
        parentId: target1SeqId,
        orderIndex: 1),
    focus1Id: AutofocusNode(
        id: focus1Id,
        method: AutofocusMethod.vCurve,
        parentId: target1SeqId,
        orderIndex: 2),
    guide1StartId: StartGuidingNode(
      id: guide1StartId,
      name: 'Start Guiding',
      settlePixels: 1.5,
      settleTime: 10.0,
      settleTimeout: 60.0,
      autoSelectStar: true,
      parentId: target1SeqId,
      orderIndex: 3,
    ),
    loop1Id: LoopNode(
      id: loop1Id,
      name: 'Target 1 Capture',
      conditionType: LoopConditionType.count,
      repeatCount: 10,
      parentId: target1SeqId,
      orderIndex: 4,
      childIds: const [exp1Id, dither1Id],
    ),
    exp1Id: ExposureNode(
      id: exp1Id,
      name: 'Luminance',
      durationSecs: 120,
      count: 1,
      filter: 'L',
      binning: BinningMode.one,
      parentId: loop1Id,
      orderIndex: 0,
    ),
    dither1Id: DitherNode(
      id: dither1Id,
      name: 'Dither',
      pixels: 5.0,
      settleTime: 30,
      parentId: loop1Id,
      orderIndex: 1,
    ),
    guide1StopId: StopGuidingNode(
        id: guide1StopId,
        name: 'Stop Guiding',
        parentId: target1SeqId,
        orderIndex: 5),

    // Target 2 with altitude conditional
    target2CondId: ConditionalNode(
      id: target2CondId,
      name: 'Target 2 Above 30 deg',
      conditionType: ConditionalType.altitudeAbove,
      thresholdValue: 30.0,
      parentId: rootId,
      orderIndex: 2,
      childIds: const [target2SeqId],
    ),
    target2SeqId: InstructionSetNode(
      id: target2SeqId,
      name: 'Target 2 Imaging',
      parentId: target2CondId,
      orderIndex: 0,
      childIds: const [
        slew2Id,
        center2Id,
        focus2Id,
        guide2StartId,
        loop2Id,
        guide2StopId
      ],
    ),
    slew2Id: SlewNode(
        id: slew2Id,
        name: 'Slew to Target 2',
        parentId: target2SeqId,
        orderIndex: 0),
    center2Id: CenterNode(
        id: center2Id,
        name: 'Center Target 2',
        parentId: target2SeqId,
        orderIndex: 1),
    focus2Id: AutofocusNode(
        id: focus2Id,
        method: AutofocusMethod.vCurve,
        parentId: target2SeqId,
        orderIndex: 2),
    guide2StartId: StartGuidingNode(
      id: guide2StartId,
      name: 'Start Guiding',
      settlePixels: 1.5,
      settleTime: 10.0,
      settleTimeout: 60.0,
      autoSelectStar: true,
      parentId: target2SeqId,
      orderIndex: 3,
    ),
    loop2Id: LoopNode(
      id: loop2Id,
      name: 'Target 2 Capture',
      conditionType: LoopConditionType.count,
      repeatCount: 10,
      parentId: target2SeqId,
      orderIndex: 4,
      childIds: const [exp2Id, dither2Id],
    ),
    exp2Id: ExposureNode(
      id: exp2Id,
      name: 'Luminance',
      durationSecs: 120,
      count: 1,
      filter: 'L',
      binning: BinningMode.one,
      parentId: loop2Id,
      orderIndex: 0,
    ),
    dither2Id: DitherNode(
      id: dither2Id,
      name: 'Dither',
      pixels: 5.0,
      settleTime: 30,
      parentId: loop2Id,
      orderIndex: 1,
    ),
    guide2StopId: StopGuidingNode(
        id: guide2StopId,
        name: 'Stop Guiding',
        parentId: target2SeqId,
        orderIndex: 5),

    warmId: WarmCameraNode(
        id: warmId, ratePerMin: 5, parentId: rootId, orderIndex: 3),
    parkId: ParkNode(
        id: parkId, name: 'Park Mount', parentId: rootId, orderIndex: 4),
  };
}

/// Planetary Capture template - high frame rate lucky imaging
/// Structure:
/// InstructionSet (root)
/// ├── Slew
/// ├── CenterTarget
/// ├── Loop (count: 10)
/// │   └── TakeExposure (30s, high gain: 300, video mode)
/// └── Park
Map<String, SequenceNode> _createPlanetaryNodes() {
  const rootId = 'planet-root';
  const slewId = 'planet-slew';
  const centerId = 'planet-center';
  const loopId = 'planet-loop';
  const expId = 'planet-exp';
  const parkId = 'planet-park';

  return {
    rootId: InstructionSetNode(
      id: rootId,
      name: 'Planetary Capture',
      childIds: const [slewId, centerId, loopId, parkId],
    ),
    slewId: SlewNode(
        id: slewId, name: 'Slew to Target', parentId: rootId, orderIndex: 0),
    centerId: CenterNode(
        id: centerId, name: 'Center Target', parentId: rootId, orderIndex: 1),
    loopId: LoopNode(
      id: loopId,
      name: 'Video Capture Loop',
      conditionType: LoopConditionType.count,
      repeatCount: 10,
      parentId: rootId,
      orderIndex: 2,
      childIds: const [expId],
    ),
    expId: ExposureNode(
      id: expId,
      name: 'Video Capture (30s)',
      durationSecs: 30,
      count: 1,
      gain: 300,
      binning: BinningMode.one,
      parentId: loopId,
      orderIndex: 0,
    ),
    parkId: ParkNode(
        id: parkId, name: 'Park Mount', parentId: rootId, orderIndex: 3),
  };
}

/// Unattended All-Night template - fully automated dusk-to-dawn imaging
/// Structure:
/// InstructionSet (root)
/// ├── CoolCamera (-10°C)
/// ├── Slew
/// ├── CenterTarget
/// ├── Autofocus
/// ├── StartGuiding
/// ├── Loop (whileDark)
/// │   ├── Conditional (hfrDegraded threshold: 4.0)
/// │   │   └── Autofocus
/// │   ├── TakeExposure (L, 120s)
/// │   ├── TakeExposure (R, 120s)
/// │   ├── TakeExposure (G, 120s)
/// │   ├── TakeExposure (B, 120s)
/// │   └── Dither
/// ├── StopGuiding
/// ├── WarmCamera
/// └── Park
Map<String, SequenceNode> _createUnattendedNodes() {
  const rootId = 'unattended-root';
  const coolId = 'unattended-cool';
  const slewId = 'unattended-slew';
  const centerId = 'unattended-center';
  const focusId = 'unattended-focus';
  const startGuideId = 'unattended-startguide';
  const loopId = 'unattended-loop';
  const recoveryId = 'unattended-recovery';
  const recoveryFocusId = 'unattended-recovery-focus';
  const lId = 'unattended-l';
  const rId = 'unattended-r';
  const gId = 'unattended-g';
  const bId = 'unattended-b';
  const ditherId = 'unattended-dither';
  const stopGuideId = 'unattended-stopguide';
  const warmId = 'unattended-warm';
  const parkId = 'unattended-park';

  return {
    rootId: InstructionSetNode(
      id: rootId,
      name: 'Unattended All-Night Sequence',
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
        id: coolId, targetTemp: -10, parentId: rootId, orderIndex: 0),
    slewId: SlewNode(
        id: slewId, name: 'Slew to Target', parentId: rootId, orderIndex: 1),
    centerId: CenterNode(
        id: centerId,
        name: 'Plate Solve & Center',
        parentId: rootId,
        orderIndex: 2),
    focusId: AutofocusNode(
        id: focusId,
        method: AutofocusMethod.vCurve,
        parentId: rootId,
        orderIndex: 3),
    startGuideId: StartGuidingNode(
      id: startGuideId,
      name: 'Start Guiding',
      settlePixels: 1.5,
      settleTime: 10.0,
      settleTimeout: 60.0,
      autoSelectStar: true,
      parentId: rootId,
      orderIndex: 4,
    ),
    loopId: LoopNode(
      id: loopId,
      name: 'Capture While Dark',
      conditionType: LoopConditionType.whileDark,
      parentId: rootId,
      orderIndex: 5,
      childIds: const [recoveryId, lId, rId, gId, bId, ditherId],
    ),
    // HFR recovery - triggers autofocus when HFR degrades above threshold
    recoveryId: RecoveryNode(
      id: recoveryId,
      name: 'HFR Recovery',
      recoveryAction: RecoveryActionType.autofocus,
      maxRetries: 3,
      triggerType: TriggerType.hfrDegraded,
      triggerThreshold: 4.0,
      parentId: loopId,
      orderIndex: 0,
      childIds: const [recoveryFocusId],
    ),
    recoveryFocusId: AutofocusNode(
      id: recoveryFocusId,
      method: AutofocusMethod.vCurve,
      parentId: recoveryId,
      orderIndex: 0,
    ),
    lId: ExposureNode(
      id: lId,
      name: 'Luminance',
      durationSecs: 120,
      count: 1,
      filter: 'L',
      binning: BinningMode.one,
      parentId: loopId,
      orderIndex: 1,
    ),
    rId: ExposureNode(
      id: rId,
      name: 'Red',
      durationSecs: 120,
      count: 1,
      filter: 'R',
      binning: BinningMode.one,
      parentId: loopId,
      orderIndex: 2,
    ),
    gId: ExposureNode(
      id: gId,
      name: 'Green',
      durationSecs: 120,
      count: 1,
      filter: 'G',
      binning: BinningMode.one,
      parentId: loopId,
      orderIndex: 3,
    ),
    bId: ExposureNode(
      id: bId,
      name: 'Blue',
      durationSecs: 120,
      count: 1,
      filter: 'B',
      binning: BinningMode.one,
      parentId: loopId,
      orderIndex: 4,
    ),
    ditherId: DitherNode(
      id: ditherId,
      name: 'Dither',
      pixels: 5.0,
      settleTime: 30,
      parentId: loopId,
      orderIndex: 5,
    ),
    stopGuideId: StopGuidingNode(
        id: stopGuideId, name: 'Stop Guiding', parentId: rootId, orderIndex: 6),
    warmId: WarmCameraNode(
        id: warmId, ratePerMin: 5, parentId: rootId, orderIndex: 7),
    parkId: ParkNode(
        id: parkId, name: 'Park Mount', parentId: rootId, orderIndex: 8),
  };
}

/// Comet/Asteroid Tracking template - moving target imaging with periodic re-centering
/// Structure:
/// InstructionSet (root)
/// ├── CoolCamera (-10°C)
/// ├── Slew
/// ├── CenterTarget
/// ├── StartGuiding
/// ├── Loop (whileDark)
/// │   ├── Loop (count: 10)  [Inner loop for frames between re-center]
/// │   │   └── TakeExposure (60s, no dither for moving targets)
/// │   └── CenterTarget (re-acquire moving target)
/// ├── StopGuiding
/// ├── WarmCamera
/// └── Park
