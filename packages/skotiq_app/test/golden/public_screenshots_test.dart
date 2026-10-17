@Tags(['golden'])
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart';
import 'package:skotiq_app/screens/dashboard/dashboard_screen.dart';
import 'package:skotiq_app/screens/equipment/equipment_screen.dart';
import 'package:skotiq_app/screens/flat_wizard/flat_wizard_screen.dart';
import 'package:skotiq_app/screens/guiding/guiding_screen.dart';
import 'package:skotiq_app/screens/imaging/imaging_screen.dart';
import 'package:skotiq_app/screens/sequencer/sequencer_screen.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/run_dashboard_providers.dart';
import 'package:skotiq_app/screens/settings/settings_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
// Prefixed: this package and skotiq_core both export a TargetScore.
import 'package:skotiq_planetarium/skotiq_planetarium.dart'
    as planetarium;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../harness/harness.dart';
import 'surface_golden_harness.dart';

const _size = Size(1600, 900);

int _gb(int value) => value * 1024 * 1024 * 1024;

/// The night the screenshots depict. IC 434 sits in Orion, so this has to be a
/// winter evening — on a June night the target would be below the horizon all
/// night and every altitude and twilight figure on these screens would be a
/// lie. 22:14 on 15 January puts it just past transit at about 51 degrees.
final _sessionStart = DateTime(2026, 1, 15, 22, 14);

/// The frame shown in the Imaging viewer and the Tonight panel.
///
/// A real plate rather than a synthetic starfield: IC 434 from the UK Schmidt
/// Telescope, the same image `reports/tonight-readiness-*/HorseHead.fits`
/// carries. It is stretched and downscaled once, offline, into
/// `test/fixtures/ic434_horsehead_uk_schmidt.png`, so this test needs no FITS
/// decoder. Loaded once per run by [_loadCapturedFrame] and read by the
/// `currentImageProvider` override below.
CapturedImageData? _capturedFrame;

/// Builds [_capturedFrame] from the fixture PNG.
///
/// Every statistic that can be derived from the pixels — median, mean, min,
/// max, standard deviation, MAD — is computed here rather than typed in, so
/// the numbers on the readout row are true of the frame on screen. HFR,
/// eccentricity and star count cannot be had without running the detector, so
/// they are stated as what a good sub of this field looks like; they are
/// illustrative, and the only invented figures in the capture.
Future<CapturedImageData> _loadCapturedFrame() async {
  final file = File(
    '${SurfaceGoldenHarness.repoRoot().path}'
    '/packages/skotiq_app/test/fixtures/ic434_horsehead_uk_schmidt.png',
  );
  final codec = await ui.instantiateImageCodec(await file.readAsBytes());
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
      .buffer
      .asUint8List();
  final width = image.width;
  final height = image.height;
  final pixelCount = width * height;

  final histogram = List<int>.filled(256, 0);
  var sum = 0.0;
  var minValue = 255;
  var maxValue = 0;
  for (var i = 0; i < pixelCount; i++) {
    final value = rgba[i * 4]; // greyscale source, so R == G == B
    histogram[value]++;
    sum += value;
    if (value < minValue) minValue = value;
    if (value > maxValue) maxValue = value;
  }
  final mean = sum / pixelCount;

  var seen = 0;
  var median = 0;
  for (var bin = 0; bin < 256; bin++) {
    seen += histogram[bin];
    if (seen >= pixelCount ~/ 2) {
      median = bin;
      break;
    }
  }

  var variance = 0.0;
  for (var bin = 0; bin < 256; bin++) {
    final delta = bin - mean;
    variance += histogram[bin] * delta * delta;
  }
  variance /= pixelCount;

  var madSeen = 0;
  var mad = 0;
  final deviations = List<int>.filled(256, 0);
  for (var bin = 0; bin < 256; bin++) {
    deviations[(bin - median).abs()] += histogram[bin];
  }
  for (var bin = 0; bin < 256; bin++) {
    madSeen += deviations[bin];
    if (madSeen >= pixelCount ~/ 2) {
      mad = bin;
      break;
    }
  }

  image.dispose();

  return CapturedImageData(
    width: width,
    height: height,
    displayData: rgba,
    histogram: histogram,
    stats: ImageStats(
      hfr: 2.13,
      eccentricity: 0.31,
      starCount: 1184,
      median: median.toDouble(),
      mean: mean,
      stdDev: math.sqrt(variance),
      min: minValue.toDouble(),
      max: maxValue.toDouble(),
      mad: mad.toDouble(),
    ),
    capturedAt: _sessionStart.add(const Duration(hours: 3, minutes: 22)),
    settings: const ExposureSettings(
      exposureTime: 180,
      gain: 100,
      offset: 50,
      filter: 'Ha',
    ),
    targetName: 'IC 434 - Horsehead Nebula',
    filePath: r'D:\Astro\Skotiq\Captures\IC434\Ha\IC434_Ha_180s_0043.fits',
    isColor: false,
  );
}

/// A guide trace with the character of a decent night: sub-arcsecond, no
/// runaway, one small excursion. Deterministic so the capture is reproducible.
/// Timestamps run up to the wall clock, not the fixture date: the guide graph
/// draws a rolling window ending at "now", so a trace dated to the fixture's
/// January night falls entirely outside it and the graph renders empty.
final _guideTrace = <GuideGraphPoint>[
  for (var i = 220; i > 0; i--)
    GuideGraphPoint(
      0.30 * math.sin(i * 0.21) + 0.16 * math.sin(i * 0.77 + 1.1),
      0.25 * math.sin(i * 0.17 + 0.6) + 0.13 * math.sin(i * 0.61 + 2.2),
      DateTime.now().subtract(Duration(seconds: 4 * i)),
    ),
];

/// Past sessions for the Analytics history list. Dated backwards from the
/// night the screenshots depict so the list reads as a real observing run of
/// clear nights rather than one row.
final _pastSessions = <ImagingSession>[
  for (final (i, spec) in <(String, String, int, double, double, double)>[
    ('IC 434 - Horsehead Nebula', 'completed', 43, 12900, 2.13, 0.42),
    ('M42 - Orion Nebula', 'completed', 96, 17280, 1.94, 0.38),
    ('NGC 2264 - Christmas Tree', 'completed', 61, 10980, 2.41, 0.51),
    ('M45 - Pleiades', 'completed', 72, 8640, 1.88, 0.35),
    ('IC 405 - Flaming Star', 'aborted', 18, 3240, 3.12, 0.94),
    ('NGC 1499 - California', 'completed', 84, 15120, 2.07, 0.44),
  ].indexed)
    ImagingSession(
      id: 42 - i,
      name: spec.$1,
      profileId: 1,
      targetId: null,
      startTime: _sessionStart.subtract(Duration(days: i, minutes: 0)),
      endTime: _sessionStart.subtract(Duration(days: i)).add(
            Duration(seconds: spec.$4.toInt() + 2400),
          ),
      totalExposures: spec.$3 + 2,
      successfulExposures: spec.$3,
      failedExposures: 2,
      totalIntegrationSecs: spec.$4,
      avgTemperature: -10.2,
      avgHfr: spec.$5,
      avgGuidingRms: spec.$6,
      autofocusCount: 4,
      status: spec.$2,
    ),
];

final _schedulerDecision = SchedulerDecision(
  chosenTargetId: 434,
  chosenTargetName: 'IC 434 - Horsehead Nebula',
  score: 0.86,
  reasoning: const [
    'Past transit at 51 deg, strong Ha priority, and 6.9 hours before dawn.',
  ],
  scoredCandidates: const [
    TargetScore(
      targetId: 434,
      targetName: 'IC 434 - Horsehead Nebula',
      totalScore: 0.86,
      factors: [
        ScoreFactor(
          name: 'Altitude',
          value: 0.91,
          weight: 0.35,
          weighted: 0.32,
          detail: '51 deg above horizon',
        ),
        ScoreFactor(
          name: 'Priority',
          value: 0.9,
          weight: 0.3,
          weighted: 0.27,
          detail: 'project priority 5',
        ),
      ],
    ),
  ],
  evaluatedAt: DateTime(2026, 1, 15, 22, 45),
);

final _screenshotProfile = EquipmentProfileModel(
  id: 1,
  name: 'Backyard Pier',
  description: 'EQ6-R narrowband rig',
  isActive: true,
  cameraId: 'asi2600mm',
  mountId: 'eq6r',
  focuserId: 'eaf',
  filterWheelId: 'efw',
  guiderId: 'phd2',
  cameraName: 'ZWO ASI2600MM Pro',
  mountName: 'EQ6-R Pro',
  focuserName: 'ZWO EAF',
  filterWheelName: 'ZWO EFW 7x36',
  guiderName: 'PHD2',
  telescopeName: 'Esprit 100ED',
  telescopeFocalLength: 550,
  telescopeAperture: 100,
  focalLength: 550,
  aperture: 100,
  focalRatio: 5.5,
  defaultGain: 100,
  defaultOffset: 50,
  defaultCoolingTemp: -10,
  coolOnConnect: true,
  filterNames: const ['L', 'R', 'G', 'B', 'Ha', 'OIII', 'SII'],
  isDefault: true,
  createdAt: DateTime(2025, 12, 2),
  updatedAt: DateTime(2026, 1, 15),
);

final _screenshotSequence = Sequence(
  id: 'screenshot-narrowband',
  name: 'IC 434 Narrowband Run',
  description:
      'Unpark, slew, plate-solve, guide and focus, then twelve Ha/OIII/SII '
      'sets with a meridian flip, and park at the end.',
  createdAt: DateTime(2026, 1, 15, 21, 50),
  modifiedAt: DateTime(2026, 1, 15, 22, 35),
  // 36 frames at 180s is 108 minutes of shutter time. The rest is the
  // preamble, downloads, dithers, the flip and the shutdown.
  estimatedDurationMins: 146,
  rootNodeId: 'nb-root',
  nodes: {
    'nb-root': InstructionSetNode(
      id: 'nb-root',
      name: 'IC 434 Narrowband Run',
      childIds: const ['nb-target'],
    ),
    'nb-target': TargetHeaderNode(
      id: 'nb-target',
      name: 'IC 434',
      targetName: 'IC 434 - Horsehead Nebula',
      raHours: 5.683,
      decDegrees: -2.45,
      minAltitude: 30,
      priority: 5,
      childIds: const [
        'nb-unpark',
        'nb-cover',
        'nb-cool',
        'nb-slew',
        'nb-center',
        'nb-guide',
        'nb-focus',
        'nb-smart',
        'nb-flip',
        'nb-stop-guiding',
        'nb-warm',
        'nb-close',
        'nb-park',
      ],
      parentId: 'nb-root',
    ),
    'nb-unpark': UnparkNode(
      id: 'nb-unpark',
      parentId: 'nb-target',
      orderIndex: 0,
    ),
    'nb-cover': OpenCoverNode(
      id: 'nb-cover',
      parentId: 'nb-target',
      orderIndex: 1,
    ),
    'nb-cool': CoolCameraNode(
      id: 'nb-cool',
      targetTemp: -10,
      parentId: 'nb-target',
      orderIndex: 2,
    ),
    'nb-slew': SlewNode(
      id: 'nb-slew',
      parentId: 'nb-target',
      orderIndex: 3,
    ),
    'nb-center': CenterNode(
      id: 'nb-center',
      name: 'Center on plate solve',
      accuracyArcsec: 30,
      exposureDuration: 8,
      filter: 'L',
      parentId: 'nb-target',
      orderIndex: 4,
    ),
    'nb-guide': StartGuidingNode(
      id: 'nb-guide',
      settlePixels: 1.2,
      settleTime: 12,
      parentId: 'nb-target',
      orderIndex: 5,
    ),
    'nb-focus': AutofocusNode(
      id: 'nb-focus',
      method: AutofocusMethod.vCurve,
      parentId: 'nb-target',
      orderIndex: 6,
    ),
    // One row per filter, rotating a frame at a time, so the three
    // channels finish together instead of Ha draining first and the target
    // setting before SII starts. 3 x 12 x 180s is the 36 frames and 1h 48m
    // of shutter time the totals below have to add up to.
    'nb-smart': SmartExposureNode(
      id: 'nb-smart',
      name: 'Narrowband set',
      plans: const [
        FilterPlan(
          filterName: 'Ha',
          filterIndex: 4,
          count: 12,
          durationSecs: 180,
          gain: 100,
          offset: 50,
          ditherEvery: 3,
        ),
        FilterPlan(
          filterName: 'OIII',
          filterIndex: 5,
          count: 12,
          durationSecs: 180,
          gain: 100,
          offset: 50,
          ditherEvery: 3,
        ),
        FilterPlan(
          filterName: 'SII',
          filterIndex: 6,
          count: 12,
          durationSecs: 180,
          gain: 100,
          offset: 50,
          ditherEvery: 3,
        ),
      ],
      ditherOnFilterChange: true,
      parentId: 'nb-target',
      orderIndex: 7,
    ),
    // A trigger, not a step: it sits beside the capture node and watches the
    // whole target rather than running at one point in the order.
    'nb-flip': MeridianFlipNode(
      id: 'nb-flip',
      minutesPastMeridian: 2,
      autoCenter: true,
      refocusAfter: true,
      parentId: 'nb-target',
      orderIndex: 8,
    ),
    'nb-stop-guiding': StopGuidingNode(
      id: 'nb-stop-guiding',
      parentId: 'nb-target',
      orderIndex: 9,
    ),
    'nb-warm': WarmCameraNode(
      id: 'nb-warm',
      ratePerMin: 5,
      parentId: 'nb-target',
      orderIndex: 10,
    ),
    'nb-close': CloseCoverNode(
      id: 'nb-close',
      parentId: 'nb-target',
      orderIndex: 11,
    ),
    'nb-park': ParkNode(
      id: 'nb-park',
      parentId: 'nb-target',
      orderIndex: 12,
    ),
  },
);

class _ScreenshotSequence extends CurrentSequenceNotifier {
  // No [Ref]: the notifier only enforces its running-sequence edit guard when
  // it has one, and this fixture loads its canned plan while the execution
  // state is overridden to `running` — exactly the state the guard refuses.
  // A real notifier is never first-loaded mid-run; a screenshot fixture is.
  _ScreenshotSequence() : super() {
    loadSequence(_screenshotSequence, discardUnsaved: true);
    markSaved();
  }
}

class _ScreenshotProgress extends SequenceProgressNotifier {
  _ScreenshotProgress() {
    updateState(SequenceExecutionState.running);
    setTotals(36, 6480);
    // Six frames in, two of each filter, and the seventh - an Ha - is
    // exposing. Everything below has to agree with that: the ring, the
    // per-filter tallies and the integration total. An older fixture said 18
    // of 36 while the node underneath it said 7 of 12, so the tree and the
    // ring described different runs.
    updateProgress(
      currentNodeId: 'nb-smart',
      currentNodeName: 'Narrowband set',
      currentNodeStatus: NodeStatus.running,
      completedExposures: 6,
      completedIntegrationSecs: 1080,
      // 18 minutes of unpark, cooling, slew, plate solve, guider settle and
      // autofocus, then six frames at 180s plus downloads and dithers.
      elapsedSecs: 2250,
      estimatedRemainingSecs: 6510,
      currentTarget: 'IC 434 - Horsehead Nebula',
      currentFilter: 'Ha',
      message: 'Capturing Ha - frame 7 of 36',
    );
    updateNodeStatus('nb-unpark', NodeStatus.success);
    updateNodeStatus('nb-cover', NodeStatus.success);
    updateNodeStatus('nb-cool', NodeStatus.success);
    updateNodeStatus('nb-slew', NodeStatus.success);
    updateNodeStatus('nb-center', NodeStatus.success);
    updateNodeStatus('nb-guide', NodeStatus.success);
    updateNodeStatus('nb-focus', NodeStatus.success);
    updateNodeStatus('nb-smart', NodeStatus.running);
    // The flip is armed and watching. The target is still east of the
    // meridian, so it has not fired.
    updateNodeStatus('nb-flip', NodeStatus.pending);
    updateNodeStatus('nb-stop-guiding', NodeStatus.pending);
    updateNodeStatus('nb-warm', NodeStatus.pending);
    updateNodeStatus('nb-close', NodeStatus.pending);
    updateNodeStatus('nb-park', NodeStatus.pending);
    updateNodeProgress('nb-smart', 6 / 36, 'Ha 2/12 - OIII 2/12 - SII 2/12');
  }
}

/// The Equipment screen reads `equipmentProfilesProvider` — not the derived
/// list providers the fixture already overrode — and falls back to its
/// first-run "Set up your first rig" panel when that comes back empty. The
/// published screenshot said "5 connected" in the header above that panel.
/// The planetarium draws nothing without a site — it refuses to render
/// somebody else's sky — and the app pushes the site in from settings at
/// runtime, which the capture never does. The README's lead image was the
/// "No observing site set" panel.
class _ScreenshotObserver extends planetarium.PlanetariumObserverNotifier {
  _ScreenshotObserver() {
    setLocation(
      latitude: 34.744,
      longitude: -118.057,
      elevation: 780,
      locationName: 'Backyard Pier',
    );
  }
}

class _ScreenshotProfiles extends EquipmentProfilesNotifier {
  @override
  Future<EquipmentProfilesState> build() async => EquipmentProfilesState(
        profiles: [_screenshotProfile],
        activeProfile: _screenshotProfile,
      );
}

class _ScreenshotSettings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState(
        theme: 'dark',
        imageOutputPath: 'D:\\Astro\\Skotiq\\Captures',
        latitude: 34.744,
        longitude: -118.057,
        elevation: 780,
        timezone: 'America/Los_Angeles',
        safetyFailMode: SafetyFailMode.failOpen,
      );
}

class _ConnectedCamera extends CameraStateNotifier {
  _ConnectedCamera(super.ref) {
    setConnecting('asi2600mm', 'ZWO ASI2600MM Pro');
    setConnected();
    setCooling(true);
    setTargetTemp(-10);
    updateTemperature(-10.2, 41);
    setExposing(true, progress: 0.62);
  }
}

class _ConnectedMount extends MountStateNotifier {
  _ConnectedMount(super.ref) {
    setConnecting('eq6r', 'EQ6-R Pro');
    setConnected();
    updatePosition(5.683, -2.45, 51.2, 186.5);
    setTracking(true);
  }
}

class _ConnectedGuider extends GuiderStateNotifier {
  _ConnectedGuider(super.ref) {
    setConnecting('phd2', 'PHD2');
    setConnected();
    setGuiding(true);
    updateRms(0.31, 0.27, 0.42);
  }
}

class _CalibratedMount extends CalibrationStateNotifier {
  _CalibratedMount(super.ref) {
    // A screen that says "Guiding" in its header while the calibration card
    // says "Mount not calibrated" contradicts itself; PHD2 cannot guide an
    // uncalibrated mount.
    // ignore: invalid_use_of_protected_member
    state = Phd2CalibrationData(
      isCalibrated: true,
      calibratedAt:
          DateTime.now().subtract(const Duration(hours: 4, minutes: 6)),
      raRate: 0.0118,
      decRate: 0.0113,
      rotationAngle: 1.7,
      decGuideMode: 'Auto',
    );
  }
}

class _SeededGuideGraph extends GuideGraphNotifier {
  _SeededGuideGraph(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = _guideTrace;
  }
}

class _SeededGuideStats extends GuideStatsNotifier {
  _SeededGuideStats(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const Phd2GuideStats(
      rmsRa: 0.31,
      rmsDec: 0.27,
      rmsTotal: 0.42,
      peakRa: 0.94,
      peakDec: 0.81,
      snr: 42.6,
      starMass: 18240,
      hfd: 3.1,
      starX: 612.4,
      starY: 388.9,
      pixelScale: 1.34,
      frameCount: 1148,
    );
  }
}

class _ConnectedFocuser extends FocuserStateNotifier {
  _ConnectedFocuser(super.ref) {
    setConnecting('eaf', 'ZWO EAF');
    setConnected(maxPosition: 60000, stepSize: 1, isAbsolute: true);
    updatePosition(28420);
    updateTemperature(7.4);
  }
}

class _ConnectedFilterWheel extends FilterWheelStateNotifier {
  _ConnectedFilterWheel(super.ref) {
    setConnecting('efw', 'ZWO EFW 7x36');
    setConnected(filterNames: const ['L', 'R', 'G', 'B', 'Ha', 'OIII', 'SII']);
    updatePosition(4);
  }
}

class _ActiveSession extends SessionStateNotifier {
  _ActiveSession(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = SessionState(
      isActive: true,
      // Relative to the wall clock on purpose: SessionState.duration is
      // `DateTime.now().difference(startTime)`, so a fixed date makes the
      // "Running for" readout count the months since the fixture was written.
      // The published screenshot used to say 1989:00:06.
      startTime: DateTime.now().subtract(
        const Duration(hours: 4, minutes: 2),
      ),
      targetName: 'IC 434 - Horsehead Nebula',
      targetRa: 5.683,
      targetDec: -2.45,
      totalExposures: 72,
      completedExposures: 43,
      failedExposures: 1,
      rejectedExposures: 2,
      totalIntegrationSecs: 12900,
      currentFilter: 'Ha',
      isGuiding: true,
      isCapturing: true,
      avgHfr: 2.13,
      avgGuidingRmsRa: 0.31,
      avgGuidingRmsDec: 0.27,
      dbSessionId: 42,
    );
  }
}

class _SeededFlatWizard extends FlatWizardNotifier {
  _SeededFlatWizard(super.ref) {
    final now = DateTime(2026, 1, 15, 20, 40);
    // ignore: invalid_use_of_protected_member
    state = FlatWizardState(
      mode: FlatWizardMode.batch,
      globalSettings: const FlatWizardGlobalSettings(
        histogramTarget: 50,
        tolerancePercent: 8,
        minExposure: 0.01,
        maxExposure: 12,
        frameCount: 30,
        gain: 100,
        binning: 1,
        savePath: 'D:\\Astro\\Calibration\\Flats',
      ),
      filterSettings: const [
        FlatFilterSettings(
          filterName: 'L',
          filterPosition: 0,
          calibratedExposure: 0.72,
          capturedCount: 30,
          currentAdu: 32740,
          status: FilterCalibrationStatus.complete,
        ),
        FlatFilterSettings(
          filterName: 'R',
          filterPosition: 1,
          calibratedExposure: 1.14,
          capturedCount: 30,
          currentAdu: 32310,
          status: FilterCalibrationStatus.complete,
        ),
        FlatFilterSettings(
          filterName: 'Ha',
          filterPosition: 4,
          calibratedExposure: 3.8,
          capturedCount: 12,
          currentAdu: 33180,
          status: FilterCalibrationStatus.capturing,
        ),
      ],
      currentFilterIndex: 2,
      currentFrameIndex: 12,
      isCapturing: true,
      isExposing: true,
      exposureStartTime: now,
      currentExposureDuration: 3.8,
      aduHistory: [
        for (var i = 0; i < 12; i++)
          AduMeasurement(
            exposure: 2.8 + i * 0.08,
            adu: 29000 + i * 340,
            timestamp: now.add(Duration(seconds: i * 8)),
          ),
      ],
      skyBrightnessHistory: [
        for (var i = 0; i < 8; i++)
          SkyBrightnessMeasurement(
            adu: 24000 + i * 270,
            exposureUsed: 3.5,
            timestamp: now.add(Duration(minutes: i)),
          ),
      ],
      skyAduRate: 41.5,
      statusMessage: 'Capturing Ha flats: frame 12 of 30',
      showHistogramOverlay: true,
    );
  }
}

final _sharedOverrides = <Override>[
  appSettingsProvider.overrideWith(_ScreenshotSettings.new),
  planetarium.observerLocationProvider
      .overrideWith((ref) => _ScreenshotObserver()),
  equipmentProfilesProvider.overrideWith(_ScreenshotProfiles.new),
  activeEquipmentProfileProvider.overrideWithValue(_screenshotProfile),
  sortedProfilesProvider.overrideWithValue([_screenshotProfile]),
  equipmentProfileListProvider.overrideWithValue([_screenshotProfile]),
  selectedEquipmentProfileIdProvider
      .overrideWith((ref) => _screenshotProfile.id),
  smartNightExposureContextProvider.overrideWith((ref) async => null),
  currentSequenceProvider.overrideWith((ref) => _ScreenshotSequence()),
  selectedNodeIdProvider.overrideWith((ref) => 'nb-smart'),
  sequenceExecutionStateProvider.overrideWith(
    (ref) => SequenceExecutionState.running,
  ),
  sequenceProgressProvider.overrideWith((ref) => _ScreenshotProgress()),
  schedulerPreviewDecisionProvider.overrideWith((ref) async {
    return _schedulerDecision;
  }),
  captureDirDiskSpaceProvider.overrideWith((ref) async* {
    yield DiskSpaceInfo(
      path: 'D:\\Astro\\Skotiq\\Captures',
      totalBytes: _gb(2000),
      freeBytes: _gb(640),
      sampledAt: DateTime(2026, 1, 15, 22, 30),
    );
  }),
  sequenceDiskProjectionProvider.overrideWith((ref) async {
    return SequenceDiskProjectionSnapshot(
      projection: DiskSpaceProjection(
        freeBytes: _gb(640),
        totalBytes: _gb(2000),
        projectedBytes: _gb(48),
        severity: DiskSpaceSeverity.info,
        headline: '640 GB free; tonight\'s run will use ~48 GB',
        detail: '592 GB will remain after the sequence completes.',
      ),
      capturePathConfigured: true,
    );
  }),
  // The frame the viewer shows. Without this the Imaging canvas and the
  // Tonight frame panel render their "No frames yet" empty states, which is
  // what the published screenshots used to be.
  // Per-filter integration for the Tonight progress panel. Without it every
  // filter row reads "0 / 36" while the ring claims the run is underway.
  runDashboardSessionIntegrationProvider(42).overrideWith(
    (ref) async => const RunDashboardSessionIntegration(
      acceptedSecs: {'Ha': 1080},
      totalSecs: {'Ha': 1260},
    ),
  ),
  allSessionsProvider.overrideWith((ref) => Stream.value(_pastSessions)),
  currentImageProvider.overrideWith((ref) => _capturedFrame),
  phd2StateProvider.overrideWith((ref) => Phd2State.guiding),
  guideGraphProvider.overrideWith((ref) => _SeededGuideGraph(ref)),
  calibrationStateProvider.overrideWith((ref) => _CalibratedMount(ref)),
  guideStatsProvider.overrideWith((ref) => _SeededGuideStats(ref)),
  cameraStateProvider.overrideWith((ref) => _ConnectedCamera(ref)),
  mountStateProvider.overrideWith((ref) => _ConnectedMount(ref)),
  guiderStateProvider.overrideWith((ref) => _ConnectedGuider(ref)),
  focuserStateProvider.overrideWith((ref) => _ConnectedFocuser(ref)),
  filterWheelStateProvider.overrideWith((ref) => _ConnectedFilterWheel(ref)),
  sessionStateProvider.overrideWith((ref) => _ActiveSession(ref)),
  flatWizardProvider.overrideWith((ref) => _SeededFlatWizard(ref)),
  weatherStatusProvider.overrideWithValue(
    WeatherStatus(
      currentLevel: AlertLevel.clear,
      radarFrames: [
        for (var i = 0; i < 6; i++)
          RadarFrame(
            timestamp: DateTime(2026, 1, 15, 22, i * 10),
            tileUrlTemplate: '',
            north: 35.5,
            south: 34.0,
            east: -117.0,
            west: -119.2,
            opacity: 0.25 + i * 0.08,
            intensityGrid: [
              for (var r = 0; r < 8; r++)
                [for (var c = 0; c < 10; c++) ((r + c + i) % 7) / 7],
            ],
          ),
      ],
      currentFrameIndex: 4,
      lastUpdate: DateTime(2026, 1, 15, 22, 45),
    ),
  ),
  weatherSettingsProvider.overrideWithValue(
    WeatherSettings.defaultSettings.copyWith(autoParkEnabled: false),
  ),
];

Future<void> _capture(
  WidgetTester tester, {
  required Widget screen,
  required String fileName,
  List<Override> overrides = const [],
}) async {
  await SurfaceGoldenHarness.ensureCaptureFonts();

  final boundaryKey = GlobalKey();
  final handle = await pumpAppScreen(
    tester,
    RepaintBoundary(
      key: boundaryKey,
      child: SizedBox.fromSize(size: _size, child: screen),
    ),
    size: _size,
    theme: SkotiqTheme.dark,
    settle: false,
    registerTearDown: false,
    extraOverrides: [..._sharedOverrides, ...overrides],
  );

  try {
    // Let async providers draw their real loaded states, but stay below the
    // contextual-tour prompt delay so screenshots are not covered by onboarding.
    //
    // `runAsync` between pumps is what lets REAL async finish. The frame
    // viewer turns its RGBA buffer into a `ui.Image` off the widget tree, and
    // a pump-only loop never lets that future complete — the canvas stayed on
    // its loading spinner while everything around it rendered.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    await tester.pump(const Duration(milliseconds: 50));

    final boundary = boundaryKey.currentContext!.findRenderObject()!
        as RenderRepaintBoundary;
    final out = File('${SurfaceGoldenHarness.screenshotsDir().path}/$fileName');
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        if (bytes == null) {
          throw StateError('PNG encode failed for $fileName');
        }
        out.writeAsBytesSync(bytes.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });

    expect(out.existsSync(), isTrue);
    expect(out.lengthSync(), greaterThan(16 * 1024));
    expect(tester.takeException(), isNull);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    handle.container.dispose();
    await tester.pump(const Duration(milliseconds: 1));
  }
}

/// Planetarium, Plan, Weather and Framing are NOT generated here.
///
/// Each needs something a widget test cannot supply: the planetarium needs the
/// HYG star catalogue installed, Plan needs OpenNGC, the Weather radar needs
/// map tiles off the network, and Framing needs survey imagery fetched from
/// CDS for a real target. Rendered here they produced "No observing site set",
/// "Install the object catalog", a blank map, and an empty star field with no
/// target loaded, which is what the README carried. Those three are captured from the running app instead —
/// `tools/ui_audit/drive_linux.py` at 1600x900, matching this file's `_size`,
/// against a profile with the catalogues installed and a detected site. Adding
/// them back to the list below would overwrite the real captures with empty
/// states on the next run. See `assets/README.md`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('refresh public screenshots from real app screens',
      (tester) async {
    // Screens that read a persisted model (the focus model behind the Flat
    // Wizard and Analytics) resolve their file through path_provider, which
    // has no platform implementation under `flutter test`. Answer every
    // directory query with one scratch dir so the capture sees an honest
    // "nothing saved yet" instead of a MissingPluginException.
    final scratch = Directory.systemTemp.createTempSync('skotiq_shots_');
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProvider,
      (call) async => scratch.path,
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, null);
      scratch.deleteSync(recursive: true);
    });

    // Decode the frame fixture before the first capture. Image decoding needs
    // real async, which `pump` does not give it.
    await tester.runAsync(() async {
      _capturedFrame = await _loadCapturedFrame();
    });

    await _capture(
      tester,
      screen: const DashboardScreen(),
      fileName: 'desktop-dashboard.png',
    );
    await _capture(
      tester,
      screen: const SequencerScreen(),
      fileName: 'sequencer.png',
    );
    await _capture(
      tester,
      screen: const ImagingScreen(),
      fileName: 'imaging.png',
    );
    // Tab 1 (Profiles), not the default Devices tab. With a profile present
    // the Devices grid throws "LayoutBuilder does not support returning
    // intrinsic dimensions" out of the IntrinsicHeight in
    // progress_dashboard.dart:533 — a real defect, filed separately, that this
    // capture is not the place to work around. Profiles shows the same rig.
    await _capture(
      tester,
      screen: const EquipmentScreen(),
      fileName: 'equipment.png',
      overrides: [equipmentTabIndexProvider.overrideWith((ref) => 1)],
    );
    await _capture(
      tester,
      screen: const GuidingScreen(),
      fileName: 'guiding.png',
    );
    await _capture(
      tester,
      screen: const AnalyticsScreen(initialTab: AnalyticsTab.history),
      fileName: 'analytics.png',
    );
    await _capture(
      tester,
      screen: const FlatWizardScreen(),
      fileName: 'flat-wizard.png',
    );
    await _capture(
      tester,
      screen: const SettingsScreen(initialSection: 'equipment-profiles'),
      fileName: 'settings-equipment-profiles.png',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
}
