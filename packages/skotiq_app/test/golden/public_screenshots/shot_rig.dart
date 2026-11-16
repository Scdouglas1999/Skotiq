// The rig at "now" on the night of [ShotNight]: settings, the equipment
// profile, every connected device, the guider, the loaded sequence and the
// run in progress. Every value is read from [ShotNight] so the screens agree.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/equipment/profile_actions.dart';
import 'package:skotiq_astro/skotiq_astro.dart' show CatalogManager, SkyCatalog;
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart' as planetarium;

import '../../harness/mock_backend.dart';
import '../surface_golden_harness.dart';
import 'shot_night.dart';

int _gb(int value) => value * 1024 * 1024 * 1024;

ShotNightRun get _tonight => ShotNight.tonight;
ShotFrame get lastFrame => _tonight.frames.last;

/// The frames of the current target tonight.
List<ShotFrame> get currentTargetFrames => _tonight.frames
    .where((f) => f.target.id == lastFrame.target.id)
    .toList(growable: false);

/// A clock that shows "now" as [ShotNight.now].
///
/// The title-bar clock asks for the real instant; this re-expresses an instant
/// near the real now as the same distance from the fiction's now. Every other
/// timestamp (the seeded frames) passes through unchanged.
class ShotClock implements Clock {
  const ShotClock();

  static Duration get _shift => ShotNight.now.difference(DateTime.now());

  @override
  DateTime now() => ShotNight.now;

  @override
  DateTime nowUtc() => ShotNight.now.toUtc();

  @override
  Duration get utcOffset => ShotNight.now.timeZoneOffset;

  @override
  DateTime fromUtc(DateTime utc) {
    final real = DateTime.now().toUtc();
    final local = utc.toLocal();
    if (utc.difference(real).abs() < const Duration(minutes: 5)) {
      return local.add(_shift);
    }
    return local;
  }
}

/// The frame on the stage and in the Imaging viewer: M31 from the Digitized
/// Sky Survey (see `test/fixtures/README.md`). Statistics that can be measured
/// from the pixels are measured; HFR, stars and eccentricity are the last
/// seeded frame's.
CapturedImageData? capturedFrame;

/// The frame as the backend's thumbnail cache serves it.
Uint8List? frameThumbnail;

Future<CapturedImageData> loadCapturedFrame() async {
  final file = File(
    '${SurfaceGoldenHarness.repoRoot().path}'
    '/packages/skotiq_app/test/fixtures/m31_dss2_gray.png',
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
  for (var i = 0; i < pixelCount; i++) {
    final value = rgba[i * 4];
    histogram[value]++;
    sum += value;
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
  image.dispose();
  final small = await (await ui.instantiateImageCodec(
    await file.readAsBytes(),
    targetWidth: 240,
  ))
      .getNextFrame();
  frameThumbnail =
      (await small.image.toByteData(format: ui.ImageByteFormat.png))!
          .buffer
          .asUint8List();
  small.image.dispose();
  final f = lastFrame;
  return CapturedImageData(
    width: width,
    height: height,
    displayData: rgba,
    histogram: histogram,
    stats: ImageStats(
      hfr: f.hfr,
      eccentricity: f.eccentricity,
      starCount: f.stars,
      median: median.toDouble(),
      mean: mean,
      stdDev: math.sqrt(variance / pixelCount),
      min: 0,
      max: 255,
    ),
    capturedAt: f.capturedAt,
    settings: ExposureSettings(
      exposureTime: f.exposureSecs,
      gain: ShotNight.gain,
      offset: ShotNight.offset,
      filter: f.filter,
    ),
    targetName: f.target.name,
    filePath: ShotNight.filePath(f),
    isColor: false,
  );
}

final screenshotProfile = EquipmentProfileModel(
  id: 1,
  name: ShotNight.profileName,
  description: 'Esprit 100ED on the EQ6-R, LRGB',
  isActive: true,
  cameraId: 'asi2600mm',
  mountId: 'eq6r',
  focuserId: 'eaf',
  filterWheelId: 'efw',
  guiderId: 'phd2',
  cameraName: ShotNight.camera,
  mountName: ShotNight.mount,
  focuserName: ShotNight.focuser,
  filterWheelName: ShotNight.filterWheel,
  guiderName: ShotNight.guider,
  telescopeName: ShotNight.telescope,
  telescopeFocalLength: ShotNight.focalLength,
  telescopeAperture: ShotNight.aperture,
  focalLength: ShotNight.focalLength,
  aperture: ShotNight.aperture,
  focalRatio: ShotNight.focalLength / ShotNight.aperture,
  defaultGain: ShotNight.gain,
  defaultOffset: ShotNight.offset,
  defaultCoolingTemp: ShotNight.setpoint,
  coolOnConnect: true,
  filterNames: ShotNight.filters,
  isDefault: true,
  createdAt: ShotNight.at(-30, 20, 0),
  updatedAt: ShotNight.at(-1, 18, 0),
);

class _Profiles extends EquipmentProfilesNotifier {
  @override
  Future<EquipmentProfilesState> build() async => EquipmentProfilesState(
        profiles: [screenshotProfile],
        activeProfile: screenshotProfile,
      );
}

class _Settings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState(
        theme: 'dark',
        imageOutputPath: 'D:\\Astro\\Skotiq',
        latitude: ShotNight.latitude,
        longitude: ShotNight.longitude,
        elevation: ShotNight.elevation,
        timezone: ShotNight.timezone,
        safetyFailMode: SafetyFailMode.failClosed,
      );
}

class _Observer extends planetarium.PlanetariumObserverNotifier {
  _Observer() {
    setLocation(
      latitude: ShotNight.latitude,
      longitude: ShotNight.longitude,
      elevation: ShotNight.elevation,
      locationName: ShotNight.siteName,
    );
  }
}

class _Camera extends CameraStateNotifier {
  _Camera(super.ref) {
    setConnecting('asi2600mm', ShotNight.camera);
    setConnected();
    setCooling(true);
    setTargetTemp(ShotNight.setpoint);
    applySetting(
        gain: ShotNight.gain, offset: ShotNight.offset, binning: '1x1');
    updateTemperature(-10.0, lastFrame.coolerPower.roundToDouble());
    setExposing(true, progress: 0.58);
  }
}

class _Mount extends MountStateNotifier {
  _Mount(super.ref) {
    final t = lastFrame.target;
    final (alt, az) = ShotNight.altAz(t, ShotNight.now);
    setConnecting('eq6r', ShotNight.mount);
    setConnected();
    updatePosition(t.raHours, t.decDegrees, alt, az);
    setParked(false);
    setTracking(true);
    // Past the meridian, after the run's flip.
    // ignore: invalid_use_of_protected_member
    state = state.copyWith(sideOfPier: 'East');
  }
}

/// PHD2 through a 200 mm guide scope and an ASI120MM Mini: 3.87"/px.
const double guidePixelScale = 3.87;

/// Total guide RMS in arcseconds over the last frames.
double get guideRmsRa => _rms(currentTargetFrames.map((f) => f.guideRa));
double get guideRmsDec => _rms(currentTargetFrames.map((f) => f.guideDec));
double get guideRmsTotal =>
    math.sqrt(guideRmsRa * guideRmsRa + guideRmsDec * guideRmsDec);

double _rms(Iterable<double> values) {
  final list = values.toList();
  return list.fold(0.0, (s, v) => s + v) / list.length;
}

class _Guider extends GuiderStateNotifier {
  _Guider(super.ref) {
    setConnecting('phd2', ShotNight.guider);
    setConnected();
    setGuiding(true);
    // PHD2 reports guide-camera pixels.
    updateRms(
      guideRmsRa / guidePixelScale,
      guideRmsDec / guidePixelScale,
      guideRmsTotal / guidePixelScale,
    );
    setPixelScale(guidePixelScale);
  }
}

class _Calibration extends CalibrationStateNotifier {
  _Calibration(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = Phd2CalibrationData(
      isCalibrated: true,
      calibratedAt: ShotNight.tonight.start.add(const Duration(minutes: 9)),
      raRate: 0.0121,
      decRate: 0.0117,
      rotationAngle: 1.4,
      decGuideMode: 'Auto',
    );
  }
}

/// Eighteen minutes of guiding ending at the real now (the graph draws a
/// rolling window ending at the wall clock), in guide-camera pixels as PHD2
/// reports them: the periodic error the mount leaves, seeing, and one dither.
/// About 0.5" RMS per axis at [guidePixelScale], as the frames record.
final guideTrace = <GuideGraphPoint>[
  for (var i = 360; i > 0; i--)
    GuideGraphPoint(
      1.75 *
          (0.34 * math.sin(i * 0.052) +
              0.19 * math.sin(i * 0.61 + 1.1) +
              0.08 * math.sin(i * 1.7) +
              (i > 140 && i < 146 ? 0.5 * (146 - i) / 6 : 0)) /
          guidePixelScale,
      1.75 *
          (0.26 * math.sin(i * 0.037 + 0.6) +
              0.17 * math.sin(i * 0.53 + 2.2) +
              0.07 * math.cos(i * 1.3) -
              (i > 140 && i < 146 ? 0.4 * (146 - i) / 6 : 0)) /
          guidePixelScale,
      DateTime.now().subtract(Duration(seconds: 3 * i)),
    ),
];

/// The guide star PHD2 shows: a 2.6 px HFD star on the guide camera's sky.
Phd2StarImage guideStarImage() {
  const size = 50;
  final random = math.Random(9);
  final pixels = Uint8List(size * size * 2);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final dx = x - 24.6;
      final dy = y - 25.2;
      final value = 1180 +
          random.nextDouble() * 160 +
          21000 * math.exp(-(dx * dx + dy * dy) / (2 * 1.35 * 1.35));
      final v = value.round().clamp(0, 65535);
      pixels[(y * size + x) * 2] = v & 0xff;
      pixels[(y * size + x) * 2 + 1] = v >> 8;
    }
  }
  return Phd2StarImage(
    frame: 2268,
    width: size,
    height: size,
    starX: 24.6,
    starY: 25.2,
    pixels: pixels,
  );
}

class _TargetHistory extends TargetDisplayHistoryNotifier {
  _TargetHistory(super.ref) {
    state = [
      for (final p in guideTrace.sublist(guideTrace.length - 50))
        GuideErrorPoint(raError: p.ra, decError: p.dec, timestamp: p.time),
    ];
  }
}

class _GuideGraph extends GuideGraphNotifier {
  _GuideGraph(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = guideTrace;
  }
}

class _GuideStats extends GuideStatsNotifier {
  _GuideStats(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = Phd2GuideStats(
      rmsRa: guideRmsRa / guidePixelScale,
      rmsDec: guideRmsDec / guidePixelScale,
      rmsTotal: guideRmsTotal / guidePixelScale,
      peakRa: 1.12 / guidePixelScale,
      peakDec: 0.94 / guidePixelScale,
      snr: 61.3,
      starMass: 24310,
      hfd: 2.6,
      starX: 642.7,
      starY: 410.2,
      frameCount: 2268,
    );
  }
}

class _Focuser extends FocuserStateNotifier {
  _Focuser(super.ref) {
    setConnecting('eaf', ShotNight.focuser);
    setConnected(maxPosition: 60000, stepSize: 1, isAbsolute: true);
    updatePosition(lastFrame.focuserPosition);
    updateTemperature(lastFrame.focuserTemp);
  }
}

class _FilterWheel extends FilterWheelStateNotifier {
  _FilterWheel(super.ref) {
    setConnecting('efw', ShotNight.filterWheel);
    setConnected(filterNames: ShotNight.filters);
    updatePosition(ShotNight.filters.indexOf(lastFrame.filter));
  }
}

class _Session extends SessionStateNotifier {
  _Session(super.ref) {
    final frames = _tonight.frames;
    final elapsed = ShotNight.now.difference(_tonight.start);
    // ignore: invalid_use_of_protected_member
    state = SessionState(
      isActive: true,
      // SessionState.duration counts from the wall clock.
      startTime: DateTime.now().subtract(elapsed),
      targetName: lastFrame.target.name,
      targetRa: lastFrame.target.raHours,
      targetDec: lastFrame.target.decDegrees,
      totalExposures: sequenceFrameTotal,
      completedExposures: frames.length,
      totalIntegrationSecs: _tonight.integrationSecs,
      currentFilter: lastFrame.filter,
      isCapturing: true,
      avgHfr: frames.fold(0.0, (s, f) => s + f.hfr) / frames.length,
      avgGuidingRmsRa: guideRmsRa,
      avgGuidingRmsDec: guideRmsDec,
      dbSessionId: _tonight.sessionId,
    );
  }
}

int get sequenceFrameTotal =>
    ShotNight.targets.fold(0, (s, t) => s + t.plan.framesPerNight);

double get sequenceIntegrationTotal => ShotNight.targets
    .fold(0.0, (s, t) => s + t.plan.framesPerNight * t.plan.exposureSecs);

String _key(ShotTarget t) => t.folder.toLowerCase();

/// The plan the run executes, with a node per target.
final screenshotSequence = () {
  final nodes = <String, SequenceNode>{};
  final rootChildren = <String>['unpark', 'cool'];
  nodes['unpark'] = UnparkNode(id: 'unpark', parentId: 'root', orderIndex: 0);
  nodes['cool'] = CoolCameraNode(
    id: 'cool',
    targetTemp: ShotNight.setpoint,
    parentId: 'root',
    orderIndex: 1,
  );
  for (final (i, t) in ShotNight.targets.indexed) {
    final k = _key(t);
    final header = 'target-$k';
    rootChildren.add(header);
    final children = [
      '$k-slew',
      '$k-center',
      '$k-guide',
      '$k-focus',
      '$k-lrgb',
      '$k-flip'
    ];
    nodes['$k-slew'] = SlewNode(id: '$k-slew', parentId: header, orderIndex: 0);
    nodes['$k-center'] = CenterNode(
      id: '$k-center',
      name: 'Center',
      accuracyArcsec: 20,
      exposureDuration: 6,
      filter: 'L',
      parentId: header,
      orderIndex: 1,
    );
    nodes['$k-guide'] = StartGuidingNode(
      id: '$k-guide',
      settlePixels: 1.0,
      settleTime: 10,
      parentId: header,
      orderIndex: 2,
    );
    nodes['$k-focus'] = AutofocusNode(
      id: '$k-focus',
      method: AutofocusMethod.vCurve,
      parentId: header,
      orderIndex: 3,
    );
    nodes['$k-lrgb'] = SmartExposureNode(
      id: '$k-lrgb',
      name: 'LRGB',
      plans: [
        for (final e in t.plan.frames.entries)
          FilterPlan(
            filterName: e.key,
            filterIndex: ShotNight.filters.indexOf(e.key),
            count: e.value,
            durationSecs: t.plan.exposureSecs,
            gain: ShotNight.gain,
            offset: ShotNight.offset,
            ditherEvery: 3,
          ),
      ],
      ditherOnFilterChange: false,
      parentId: header,
      orderIndex: 4,
    );
    nodes['$k-flip'] = MeridianFlipNode(
      id: '$k-flip',
      minutesPastMeridian: 5,
      autoCenter: true,
      refocusAfter: true,
      parentId: header,
      orderIndex: 5,
    );
    nodes[header] = TargetHeaderNode(
      id: header,
      name: t.name,
      targetName: t.name,
      raHours: t.raHours,
      decDegrees: t.decDegrees,
      minAltitude: 30,
      priority: 5,
      childIds: children,
      parentId: 'root',
      orderIndex: 2 + i,
    );
  }
  rootChildren.addAll(['stop-guiding', 'warm', 'park']);
  nodes['stop-guiding'] =
      StopGuidingNode(id: 'stop-guiding', parentId: 'root', orderIndex: 5);
  nodes['warm'] = WarmCameraNode(
    id: 'warm',
    ratePerMin: 5,
    parentId: 'root',
    orderIndex: 6,
  );
  nodes['park'] = ParkNode(id: 'park', parentId: 'root', orderIndex: 7);
  nodes['root'] = InstructionSetNode(
    id: 'root',
    name: ShotNight.sequenceName,
    childIds: rootChildren,
  );
  return Sequence(
    id: 'autumn-lrgb',
    name: ShotNight.sequenceName,
    description: 'NGC 7331, M31 and M1 in LRGB, each across the meridian.',
    createdAt: ShotNight.at(-9, 17, 30),
    modifiedAt: ShotNight.at(-1, 17, 40),
    estimatedDurationMins: ShotNight.tonight.slots.last.end
        .difference(ShotNight.tonight.start)
        .inMinutes,
    rootNodeId: 'root',
    nodes: nodes,
  );
}();

class _Sequence extends CurrentSequenceNotifier {
  // No Ref: the notifier enforces its running-sequence edit guard only when
  // it has one, and this fixture loads the plan while the run is running.
  _Sequence() : super() {
    loadSequence(screenshotSequence, discardUnsaved: true);
    markSaved();
  }
}

class _Run extends RunRecordNotifier {
  _Run() {
    final frames = _tonight.frames;
    final current = lastFrame.target;
    final k = _key(current);
    setLifecycle(SequenceExecutionState.running);
    setTotals(sequenceFrameTotal, sequenceIntegrationTotal);
    final perFilter = <String, int>{};
    for (final f in currentTargetFrames) {
      perFilter[f.filter] = (perFilter[f.filter] ?? 0) + 1;
    }
    updateProgress(
      currentNodeId: '$k-lrgb',
      currentNodeName: 'LRGB',
      currentNodeStatus: NodeStatus.running,
      completedExposures: frames.length,
      completedIntegrationSecs: _tonight.integrationSecs,
      elapsedSecs:
          ShotNight.now.difference(_tonight.start).inSeconds.toDouble(),
      estimatedRemainingSecs: _tonight.slots.last.end
          .difference(ShotNight.now)
          .inSeconds
          .toDouble(),
      currentTarget: current.name,
      currentFilter: lastFrame.filter,
      message: 'Capturing ${lastFrame.filter} on ${current.name}',
    );
    var done = true;
    for (final t in ShotNight.targets) {
      final tk = _key(t);
      final isCurrent = t.id == current.id;
      for (final step in ['slew', 'center', 'guide', 'focus']) {
        updateNodeStatus(
          '$tk-$step',
          done ? NodeStatus.success : NodeStatus.pending,
        );
      }
      updateNodeStatus(
        '$tk-lrgb',
        isCurrent
            ? NodeStatus.running
            : done
                ? NodeStatus.success
                : NodeStatus.pending,
      );
      updateNodeStatus(
        '$tk-flip',
        done && !isCurrent ? NodeStatus.success : NodeStatus.pending,
      );
      if (isCurrent) {
        final plan = t.plan.frames;
        updateNodeProgress(
          '$tk-lrgb',
          currentTargetFrames.length / t.plan.framesPerNight,
          [
            for (final f in plan.keys) '$f ${perFilter[f] ?? 0}/${plan[f]}',
          ].join(' - '),
        );
        done = false;
      }
    }
    updateNodeStatus('unpark', NodeStatus.success);
    updateNodeStatus('cool', NodeStatus.success);
    for (final id in ['stop-guiding', 'warm', 'park']) {
      updateNodeStatus(id, NodeStatus.pending);
    }
  }
}

const _solver = PlateSolverDetection(
  astapPath: 'C:\\Program Files\\astap\\astap.exe',
  catalogName: 'D50',
  catalogMagnitudeLimit: 17,
  catalogPath: 'C:\\Program Files\\astap',
);

/// The shared overrides: the rig, the run and the site.
List<Override> rigOverrides() => <Override>[
      clockProvider.overrideWithValue(const ShotClock()),
      planetarium.localSiderealTimeProvider
          .overrideWith((ref) => ShotNight.lst(ShotNight.now)),
      appSettingsProvider.overrideWith(_Settings.new),
      planetarium.observerLocationProvider.overrideWith((ref) => _Observer()),
      equipmentProfilesProvider.overrideWith(_Profiles.new),
      activeEquipmentProfileProvider.overrideWithValue(screenshotProfile),
      sortedProfilesProvider.overrideWithValue([screenshotProfile]),
      equipmentProfileListProvider.overrideWithValue([screenshotProfile]),
      selectedEquipmentProfileIdProvider
          .overrideWith((ref) => screenshotProfile.id),
      currentSequenceProvider.overrideWith((ref) => _Sequence()),
      selectedNodeIdProvider
          .overrideWith((ref) => '${_key(lastFrame.target)}-lrgb'),
      runRecordProvider.overrideWith((ref) => _Run()),
      plateSolverDetectionProvider.overrideWith((ref) async => _solver),
      plateSolverPreferenceProvider.overrideWith(
        (ref) async => const PlateSolverPreference(
          astapPath: 'C:\\Program Files\\astap\\astap.exe',
          choice: PlateSolverChoice.astap,
        ),
      ),
      captureDirDiskSpaceProvider.overrideWith((ref) async* {
        yield DiskSpaceInfo(
          path: 'D:\\Astro\\Skotiq',
          totalBytes: _gb(2000),
          freeBytes: _gb(1312),
          sampledAt: ShotNight.now,
        );
      }),
      sequenceDiskProjectionProvider.overrideWith((ref) async {
        return SequenceDiskProjectionSnapshot(
          projection: DiskSpaceProjection(
            freeBytes: _gb(1312),
            totalBytes: _gb(2000),
            projectedBytes: _gb(9),
            severity: DiskSpaceSeverity.info,
            headline: '1.3 TB free; tonight\'s run will use about 9 GB',
            detail: '1.3 TB will remain after the sequence completes.',
          ),
          capturePathConfigured: true,
        );
      }),
      currentImageProvider.overrideWith((ref) => capturedFrame),
      exposureSettingsProvider.overrideWith(
        (ref) => ExposureSettings(
          exposureTime: lastFrame.exposureSecs,
          gain: ShotNight.gain,
          offset: ShotNight.offset,
          filter: lastFrame.filter,
        ),
      ),
      // The countdown at the fiction's now, not the wall clock's.
      meridianCountdownProvider.overrideWith(
        (ref) => computeMeridianCountdown(
          mount: ref.watch(mountStateProvider),
          longitude: ShotNight.longitude,
          latitude: ShotNight.latitude,
          settings: ref.watch(effectiveMeridianFlipSettingsProvider),
          execState: ref.watch(sequenceExecutionStateProvider),
          enabled: ref.watch(isMeridianFlipEnabledProvider),
          nowUtc: ShotNight.now.toUtc(),
        ),
      ),
      phd2StateProvider.overrideWith((ref) => Phd2State.guiding),
      guideGraphProvider.overrideWith((ref) => _GuideGraph(ref)),
      targetDisplayHistoryProvider.overrideWith((ref) => _TargetHistory(ref)),
      calibrationStateProvider.overrideWith((ref) => _Calibration(ref)),
      guideStatsProvider.overrideWith((ref) => _GuideStats(ref)),
      cameraStateProvider.overrideWith((ref) => _Camera(ref)),
      mountStateProvider.overrideWith((ref) => _Mount(ref)),
      guiderStateProvider.overrideWith((ref) => _Guider(ref)),
      focuserStateProvider.overrideWith((ref) => _Focuser(ref)),
      filterWheelStateProvider.overrideWith((ref) => _FilterWheel(ref)),
      sessionStateProvider.overrideWith((ref) => _Session(ref)),
      activeTransientAlertsProvider.overrideWith(
        (ref) => Stream.value(const <TransientAlert>[]),
      ),
    ];

/// Master darks and bias for every sub length the run uses.
Future<void> seedDarkLibrary(SkotiqDatabase db) async {
  for (final secs in [120.0, 180.0, 240.0]) {
    await db.into(db.darkLibrary).insert(
          DarkLibraryCompanion.insert(
            filePath:
                'D:\\Astro\\Skotiq\\Darks\\dark_${secs.round()}s_-10C_g100.fits',
            exposureTime: secs,
            temperature: const Value(-10),
            gain: const Value(ShotNight.gain),
            offset: const Value(ShotNight.offset),
            width: const Value(ShotNight.sensorWidth),
            height: const Value(ShotNight.sensorHeight),
            masterDarkPath: Value(
              'D:\\Astro\\Skotiq\\Darks\\master_dark_${secs.round()}s_-10C_g100.xisf',
            ),
            masterFrameCount: const Value(40),
            createdAt: Value(ShotNight.at(-20, 14, 0)),
          ),
        );
  }
}

/// What the backend answers for the rig: frame thumbnails, PHD2's star image,
/// device heartbeats and the camera's capabilities.
void stubRigBackend(MockBackend backend) {
  when(() => backend.getImageThumbnail(any()))
      .thenAnswer((_) async => frameThumbnail!);
  when(() => backend.guiderGetStarImage(size: any(named: 'size')))
      .thenAnswer((_) async => guideStarImage());
  when(() => backend.getDeviceHealth(any())).thenAnswer(
    (_) async => (DateTime.now().millisecondsSinceEpoch - 2000, true),
  );
  when(() => backend.getCameraCapabilities(any())).thenAnswer(
    (_) async => const CameraCapabilities(
      maxWidth: ShotNight.sensorWidth,
      maxHeight: ShotNight.sensorHeight,
      bitDepth: 16,
      canSetCcdTemperature: true,
      canSetCooler: true,
      canGetCoolerPower: true,
      canBin: true,
      maxBinX: 4,
      maxBinY: 4,
      canSetGain: true,
      gainMin: 0,
      gainMax: 460,
      canSetOffset: true,
      offsetMin: 0,
      offsetMax: 100,
      canAbortExposure: true,
      canStopExposure: true,
      canSubframe: true,
      pixelSizeX: ShotNight.pixelSizeUm,
      pixelSizeY: ShotNight.pixelSizeUm,
      sensorType: 'Monochrome',
      exposureMin: 0.000032,
      exposureMax: 2000,
    ),
  );
}

/// Installs the OpenNGC copy that ships in the app, as the app does at start,
/// so the planner and the target search have their catalog.
Future<void> installBuiltInCatalog(String directory) async {
  final csv = File(
    '${SurfaceGoldenHarness.repoRoot().path}'
    '/packages/skotiq_core/assets/catalogs/NGC.csv',
  );
  await CatalogManager.instance.initialize(
    directory,
    builtIn: {SkyCatalog.dso: csv.readAsBytes},
  );
  await CatalogManager.instance.dsos.load();
}
