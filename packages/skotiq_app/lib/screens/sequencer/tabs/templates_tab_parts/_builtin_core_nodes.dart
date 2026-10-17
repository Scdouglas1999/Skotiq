// Core beginner, broadband, and narrowband node-tree factories.
part of '../templates_tab.dart';

Map<String, SequenceNode> _createLrgbTemplateNodes() {
  const rootId = 'lrgb-root';
  const coolId = 'lrgb-cool';
  const focusId = 'lrgb-focus';
  const loopId = 'lrgb-loop';
  const lId = 'lrgb-l';
  const rId = 'lrgb-r';
  const gId = 'lrgb-g';
  const bId = 'lrgb-b';
  const warmId = 'lrgb-warm';

  return {
    rootId: InstructionSetNode(
      id: rootId,
      name: 'LRGB Sequence',
      childIds: const [coolId, focusId, loopId, warmId],
    ),
    coolId: CoolCameraNode(
        id: coolId, targetTemp: -10, parentId: rootId, orderIndex: 0),
    focusId: AutofocusNode(
        id: focusId,
        method: AutofocusMethod.vCurve,
        parentId: rootId,
        orderIndex: 1),
    loopId: LoopNode(
      id: loopId,
      name: 'Capture Loop',
      conditionType: LoopConditionType.forever,
      parentId: rootId,
      orderIndex: 2,
      childIds: const [lId, rId, gId, bId],
    ),
    lId: ExposureNode(
        id: lId,
        name: 'Luminance',
        durationSecs: 120,
        count: 1,
        filter: 'L',
        binning: BinningMode.one,
        parentId: loopId,
        orderIndex: 0),
    rId: ExposureNode(
        id: rId,
        name: 'Red',
        durationSecs: 120,
        count: 1,
        filter: 'R',
        binning: BinningMode.one,
        parentId: loopId,
        orderIndex: 1),
    gId: ExposureNode(
        id: gId,
        name: 'Green',
        durationSecs: 120,
        count: 1,
        filter: 'G',
        binning: BinningMode.one,
        parentId: loopId,
        orderIndex: 2),
    bId: ExposureNode(
        id: bId,
        name: 'Blue',
        durationSecs: 120,
        count: 1,
        filter: 'B',
        binning: BinningMode.one,
        parentId: loopId,
        orderIndex: 3),
    warmId: WarmCameraNode(
        id: warmId, ratePerMin: 5, parentId: rootId, orderIndex: 3),
  };
}

Map<String, SequenceNode> _createNarrowbandTemplateNodes() {
  const rootId = 'nb-root';
  const coolId = 'nb-cool';
  const focusId = 'nb-focus';
  const loopId = 'nb-loop';
  const haId = 'nb-ha';
  const oiiiId = 'nb-oiii';
  const siiId = 'nb-sii';
  const warmId = 'nb-warm';

  return {
    rootId: InstructionSetNode(
      id: rootId,
      name: 'Narrowband Sequence',
      childIds: const [coolId, focusId, loopId, warmId],
    ),
    coolId: CoolCameraNode(
        id: coolId, targetTemp: -15, parentId: rootId, orderIndex: 0),
    focusId: AutofocusNode(
        id: focusId,
        method: AutofocusMethod.vCurve,
        parentId: rootId,
        orderIndex: 1),
    loopId: LoopNode(
      id: loopId,
      name: 'Narrowband Loop',
      conditionType: LoopConditionType.forever,
      parentId: rootId,
      orderIndex: 2,
      childIds: const [haId, oiiiId, siiId],
    ),
    haId: ExposureNode(
        id: haId,
        name: 'H-alpha',
        durationSecs: 180,
        count: 1,
        filter: 'Ha',
        binning: BinningMode.one,
        parentId: loopId,
        orderIndex: 0),
    oiiiId: ExposureNode(
        id: oiiiId,
        name: 'OIII',
        durationSecs: 180,
        count: 1,
        filter: 'OIII',
        binning: BinningMode.one,
        parentId: loopId,
        orderIndex: 1),
    siiId: ExposureNode(
        id: siiId,
        name: 'SII',
        durationSecs: 180,
        count: 1,
        filter: 'SII',
        binning: BinningMode.one,
        parentId: loopId,
        orderIndex: 2),
    warmId: WarmCameraNode(
        id: warmId, ratePerMin: 5, parentId: rootId, orderIndex: 3),
  };
}

Map<String, SequenceNode> _createMosaicTemplateNodes() {
  const rootId = 'mosaic-root';
  const slewId = 'mosaic-slew';
  const centerId = 'mosaic-center';
  const focusId = 'mosaic-focus';
  const loopId = 'mosaic-loop';
  const lId = 'mosaic-l';
  const haId = 'mosaic-ha';

  return {
    rootId: InstructionSetNode(
      id: rootId,
      name: 'Mosaic Panel',
      childIds: const [slewId, centerId, focusId, loopId],
    ),
    slewId: SlewNode(
        id: slewId, name: 'Slew to Panel', parentId: rootId, orderIndex: 0),
    centerId: CenterNode(
        id: centerId,
        name: 'Plate Solve & Center',
        parentId: rootId,
        orderIndex: 1),
    focusId: AutofocusNode(
        id: focusId,
        method: AutofocusMethod.vCurve,
        parentId: rootId,
        orderIndex: 2),
    loopId: LoopNode(
      id: loopId,
      name: 'Panel Capture',
      conditionType: LoopConditionType.count,
      repeatCount: 10,
      parentId: rootId,
      orderIndex: 3,
      childIds: const [lId, haId],
    ),
    lId: ExposureNode(
        id: lId,
        name: 'Luminance',
        durationSecs: 300,
        count: 1,
        filter: 'L',
        binning: BinningMode.one,
        parentId: loopId,
        orderIndex: 0),
    haId: ExposureNode(
        id: haId,
        name: 'H-alpha',
        durationSecs: 300,
        count: 1,
        filter: 'Ha',
        binning: BinningMode.one,
        parentId: loopId,
        orderIndex: 1),
  };
}

Map<String, SequenceNode> _createQuickCaptureNodes() {
  const rootId = 'quick-root';
  const expId = 'quick-exp';

  return {
    rootId: InstructionSetNode(
      id: rootId,
      name: 'Quick Capture',
      childIds: const [expId],
    ),
    expId: ExposureNode(
        id: expId,
        name: 'Test Shot',
        durationSecs: 10,
        count: 5,
        filter: 'L',
        binning: BinningMode.one,
        parentId: rootId,
        orderIndex: 0),
  };
}

Map<String, SequenceNode> _createBeginnerTemplateNodes() {
  const rootId = 'beginner-root';
  const coolId = 'beginner-cool';
  const slewId = 'beginner-slew';
  const centerId = 'beginner-center';
  const focusId = 'beginner-focus';
  const loopId = 'beginner-loop';
  const lId = 'beginner-l';
  const ditherAfter = 'beginner-dither';
  const warmId = 'beginner-warm';
  const parkId = 'beginner-park';

  return {
    rootId: InstructionSetNode(
      id: rootId,
      name: 'Beginner DSO Sequence',
      childIds: const [
        coolId,
        slewId,
        centerId,
        focusId,
        loopId,
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
    loopId: LoopNode(
      id: loopId,
      name: 'Capture Loop',
      conditionType: LoopConditionType.count,
      repeatCount: 20,
      parentId: rootId,
      orderIndex: 4,
      childIds: const [lId, ditherAfter],
    ),
    lId: ExposureNode(
        id: lId,
        name: 'Luminance',
        durationSecs: 120,
        count: 1,
        filter: 'L',
        binning: BinningMode.one,
        parentId: loopId,
        orderIndex: 0),
    ditherAfter: DitherNode(
        id: ditherAfter,
        name: 'Dither',
        pixels: 5.0,
        settleTime: 30,
        parentId: loopId,
        orderIndex: 1),
    warmId: WarmCameraNode(
        id: warmId, ratePerMin: 5, parentId: rootId, orderIndex: 5),
    parkId: ParkNode(
        id: parkId, name: 'Park Mount', parentId: rootId, orderIndex: 6),
  };
}

/// First Light template - absolute beginner, point and shoot
/// Structure:
/// InstructionSet (root)
/// ├── CoolCamera (temp: -10)
/// ├── Slew
/// ├── Loop (count: 20)
/// │   └── TakeExposure (30s, no filter change)
/// ├── WarmCamera
/// └── Park
Map<String, SequenceNode> _createFirstLightNodes() {
  const rootId = 'fl-root';
  const coolId = 'fl-cool';
  const slewId = 'fl-slew';
  const loopId = 'fl-loop';
  const expId = 'fl-exp';
  const warmId = 'fl-warm';
  const parkId = 'fl-park';

  return {
    rootId: InstructionSetNode(
      id: rootId,
      name: 'First Light Sequence',
      childIds: const [coolId, slewId, loopId, warmId, parkId],
    ),
    coolId: CoolCameraNode(
        id: coolId, targetTemp: -10, parentId: rootId, orderIndex: 0),
    slewId: SlewNode(
        id: slewId, name: 'Slew to Target', parentId: rootId, orderIndex: 1),
    loopId: LoopNode(
      id: loopId,
      name: 'Capture Loop',
      conditionType: LoopConditionType.count,
      repeatCount: 20,
      parentId: rootId,
      orderIndex: 2,
      childIds: const [expId],
    ),
    expId: ExposureNode(
      id: expId,
      name: 'Light Frame',
      durationSecs: 30,
      count: 1,
      binning: BinningMode.one,
      parentId: loopId,
      orderIndex: 0,
    ),
    warmId: WarmCameraNode(
        id: warmId, ratePerMin: 5, parentId: rootId, orderIndex: 3),
    parkId: ParkNode(
        id: parkId, name: 'Park Mount', parentId: rootId, orderIndex: 4),
  };
}

/// One-Shot Color (OSC) template - for color cameras without filter wheels
/// Structure:
/// InstructionSet (root)
/// ├── CoolCamera (temp: -10)
/// ├── Slew
/// ├── CenterTarget (plate solve)
/// ├── Autofocus
/// ├── StartGuiding
/// ├── Loop (whileDark)
/// │   ├── TakeExposure (120s)
/// │   └── Dither (5px)
/// ├── StopGuiding
/// ├── WarmCamera
/// └── Park
Map<String, SequenceNode> _createOscNodes() {
  const rootId = 'osc-root';
  const coolId = 'osc-cool';
  const slewId = 'osc-slew';
  const centerId = 'osc-center';
  const focusId = 'osc-focus';
  const startGuideId = 'osc-startguide';
  const loopId = 'osc-loop';
  const expId = 'osc-exp';
  const ditherId = 'osc-dither';
  const stopGuideId = 'osc-stopguide';
  const warmId = 'osc-warm';
  const parkId = 'osc-park';

  return {
    rootId: InstructionSetNode(
      id: rootId,
      name: 'OSC Sequence',
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
      childIds: const [expId, ditherId],
    ),
    expId: ExposureNode(
      id: expId,
      name: 'Light Frame',
      durationSecs: 120,
      count: 1,
      binning: BinningMode.one,
      parentId: loopId,
      orderIndex: 0,
    ),
    ditherId: DitherNode(
      id: ditherId,
      name: 'Dither',
      pixels: 5.0,
      settleTime: 30,
      parentId: loopId,
      orderIndex: 1,
    ),
    stopGuideId: StopGuidingNode(
        id: stopGuideId, name: 'Stop Guiding', parentId: rootId, orderIndex: 6),
    warmId: WarmCameraNode(
        id: warmId, ratePerMin: 5, parentId: rootId, orderIndex: 7),
    parkId: ParkNode(
        id: parkId, name: 'Park Mount', parentId: rootId, orderIndex: 8),
  };
}

/// Ha-OIII Bicolor template - two-filter narrowband imaging
/// Structure:
/// InstructionSet (root)
/// ├── CoolCamera (-15°C for narrowband)
/// ├── Slew
/// ├── CenterTarget
/// ├── Autofocus
/// ├── StartGuiding
/// ├── Loop (whileDark)
/// │   ├── TakeExposure (Ha, 180s)
/// │   ├── TakeExposure (OIII, 180s)
/// │   └── Dither
/// ├── StopGuiding
/// ├── WarmCamera
/// └── Park
Map<String, SequenceNode> _createHaOiiiNodes() {
  const rootId = 'haoiii-root';
  const coolId = 'haoiii-cool';
  const slewId = 'haoiii-slew';
  const centerId = 'haoiii-center';
  const focusId = 'haoiii-focus';
  const startGuideId = 'haoiii-startguide';
  const loopId = 'haoiii-loop';
  const haId = 'haoiii-ha';
  const oiiiId = 'haoiii-oiii';
  const ditherId = 'haoiii-dither';
  const stopGuideId = 'haoiii-stopguide';
  const warmId = 'haoiii-warm';
  const parkId = 'haoiii-park';

  return {
    rootId: InstructionSetNode(
      id: rootId,
      name: 'Ha-OIII Bicolor Sequence',
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
        id: coolId, targetTemp: -15, parentId: rootId, orderIndex: 0),
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
      name: 'Bicolor Capture While Dark',
      conditionType: LoopConditionType.whileDark,
      parentId: rootId,
      orderIndex: 5,
      childIds: const [haId, oiiiId, ditherId],
    ),
    haId: ExposureNode(
      id: haId,
      name: 'H-alpha',
      durationSecs: 180,
      count: 1,
      filter: 'Ha',
      binning: BinningMode.one,
      parentId: loopId,
      orderIndex: 0,
    ),
    oiiiId: ExposureNode(
      id: oiiiId,
      name: 'OIII',
      durationSecs: 180,
      count: 1,
      filter: 'OIII',
      binning: BinningMode.one,
      parentId: loopId,
      orderIndex: 1,
    ),
    ditherId: DitherNode(
      id: ditherId,
      name: 'Dither',
      pixels: 5.0,
      settleTime: 30,
      parentId: loopId,
      orderIndex: 2,
    ),
    stopGuideId: StopGuidingNode(
        id: stopGuideId, name: 'Stop Guiding', parentId: rootId, orderIndex: 6),
    warmId: WarmCameraNode(
        id: warmId, ratePerMin: 5, parentId: rootId, orderIndex: 7),
    parkId: ParkNode(
        id: parkId, name: 'Park Mount', parentId: rootId, orderIndex: 8),
  };
}

/// SHO Hubble Palette template - full Hubble Palette narrowband with weather safety
/// Structure:
/// InstructionSet (root)
/// ├── Conditional (weatherSafe)
/// │   └── InstructionSet (imaging sequence)
/// │       ├── CoolCamera (-15°C)
/// │       ├── Slew
/// │       ├── CenterTarget
/// │       ├── Autofocus
/// │       ├── StartGuiding
/// │       ├── Loop (whileDark)
/// │       │   ├── TakeExposure (SII, 300s)
/// │       │   ├── TakeExposure (Ha, 300s)
/// │       │   ├── TakeExposure (OIII, 300s)
/// │       │   └── Dither
/// │       ├── StopGuiding
/// │       ├── WarmCamera
/// │       └── Park
/// └── Park (fallback if weather unsafe)
Map<String, SequenceNode> _createShoNodes() {
  const rootId = 'sho-root';
  const weatherCondId = 'sho-weather';
  const mainSeqId = 'sho-main';
  const coolId = 'sho-cool';
  const slewId = 'sho-slew';
  const centerId = 'sho-center';
  const focusId = 'sho-focus';
  const startGuideId = 'sho-startguide';
  const loopId = 'sho-loop';
  const siiId = 'sho-sii';
  const haId = 'sho-ha';
  const oiiiId = 'sho-oiii';
  const ditherId = 'sho-dither';
  const stopGuideId = 'sho-stopguide';
  const warmId = 'sho-warm';
  const parkId = 'sho-park';
  const fallbackParkId = 'sho-fallback-park';

  return {
    rootId: InstructionSetNode(
      id: rootId,
      name: 'SHO Hubble Palette Sequence',
      childIds: const [weatherCondId, fallbackParkId],
    ),
    weatherCondId: ConditionalNode(
      id: weatherCondId,
      name: 'Weather Safe Check',
      conditionType: ConditionalType.weatherSafe,
      parentId: rootId,
      orderIndex: 0,
      childIds: const [mainSeqId],
    ),
    mainSeqId: InstructionSetNode(
      id: mainSeqId,
      name: 'SHO Imaging',
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
        id: coolId, targetTemp: -15, parentId: mainSeqId, orderIndex: 0),
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
      name: 'SHO Capture While Dark',
      conditionType: LoopConditionType.whileDark,
      parentId: mainSeqId,
      orderIndex: 5,
      childIds: const [siiId, haId, oiiiId, ditherId],
    ),
    siiId: ExposureNode(
      id: siiId,
      name: 'SII',
      durationSecs: 300,
      count: 1,
      filter: 'SII',
      binning: BinningMode.one,
      parentId: loopId,
      orderIndex: 0,
    ),
    haId: ExposureNode(
      id: haId,
      name: 'H-alpha',
      durationSecs: 300,
      count: 1,
      filter: 'Ha',
      binning: BinningMode.one,
      parentId: loopId,
      orderIndex: 1,
    ),
    oiiiId: ExposureNode(
      id: oiiiId,
      name: 'OIII',
      durationSecs: 300,
      count: 1,
      filter: 'OIII',
      binning: BinningMode.one,
      parentId: loopId,
      orderIndex: 2,
    ),
    ditherId: DitherNode(
      id: ditherId,
      name: 'Dither',
      pixels: 5.0,
      settleTime: 30,
      parentId: loopId,
      orderIndex: 3,
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
    fallbackParkId: ParkNode(
        id: fallbackParkId,
        name: 'Weather Unsafe - Park',
        parentId: rootId,
        orderIndex: 1),
  };
}

/// LRGB + Ha Enhanced template - broadband with hydrogen-alpha enhancement
/// Structure:
/// InstructionSet (root)
/// ├── CoolCamera (-10°C)
/// ├── Slew
/// ├── CenterTarget
/// ├── Autofocus
/// ├── StartGuiding
/// ├── Loop (whileDark)
/// │   ├── TakeExposure (L, 120s)
/// │   ├── TakeExposure (R, 120s)
/// │   ├── TakeExposure (G, 120s)
/// │   ├── TakeExposure (B, 120s)
/// │   ├── TakeExposure (Ha, 180s)
/// │   └── Dither
/// ├── StopGuiding
/// ├── WarmCamera
/// └── Park
Map<String, SequenceNode> _createLrgbHaNodes() {
  const rootId = 'lrgbha-root';
  const coolId = 'lrgbha-cool';
  const slewId = 'lrgbha-slew';
  const centerId = 'lrgbha-center';
  const focusId = 'lrgbha-focus';
  const startGuideId = 'lrgbha-startguide';
  const loopId = 'lrgbha-loop';
  const lId = 'lrgbha-l';
  const rId = 'lrgbha-r';
  const gId = 'lrgbha-g';
  const bId = 'lrgbha-b';
  const haId = 'lrgbha-ha';
  const ditherId = 'lrgbha-dither';
  const stopGuideId = 'lrgbha-stopguide';
  const warmId = 'lrgbha-warm';
  const parkId = 'lrgbha-park';

  return {
    rootId: InstructionSetNode(
      id: rootId,
      name: 'LRGB + Ha Enhanced Sequence',
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
      name: 'LRGB+Ha Capture While Dark',
      conditionType: LoopConditionType.whileDark,
      parentId: rootId,
      orderIndex: 5,
      childIds: const [lId, rId, gId, bId, haId, ditherId],
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
    haId: ExposureNode(
      id: haId,
      name: 'H-alpha Enhancement',
      durationSecs: 180,
      count: 1,
      filter: 'Ha',
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

/// Multi-Target Night template - image multiple targets with altitude switching
/// Structure:
/// InstructionSet (root)
/// ├── CoolCamera (-10°C)
/// ├── Target 1 InstructionSet
/// │   ├── Conditional (altitudeAbove: 30°)
/// │   │   └── InstructionSet
/// │   │       ├── Slew
/// │   │       ├── CenterTarget
/// │   │       ├── Autofocus
/// │   │       ├── StartGuiding
/// │   │       ├── Loop (count: 10)
/// │   │       │   ├── TakeExposure (L, 120s)
/// │   │       │   └── Dither
/// │   │       └── StopGuiding
/// ├── Target 2 InstructionSet (same structure)
/// ├── WarmCamera
/// └── Park
