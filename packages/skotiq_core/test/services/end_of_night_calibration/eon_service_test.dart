import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart' as db;

db.CapturedImage frame(
  int id, {
  required String type,
  required double exposure,
  String dir = '/n',
  int gain = 76,
  int offset = 15,
  double? sensorTemp = -10.0,
}) {
  final at = DateTime(2026, 10, 22, 6).add(Duration(seconds: id));
  return db.CapturedImage(
    id: id,
    filePath: '$dir/${type}_${exposure}s_$id.fits',
    fileName: '${type}_${exposure}s_$id.fits',
    fileFormat: 'fits',
    frameType: type,
    exposureDuration: exposure,
    gain: gain,
    offset: offset,
    binX: 1,
    binY: 1,
    sensorTemp: sensorTemp,
    isPlateSolved: false,
    capturedAt: at,
    createdAt: at,
    isAccepted: true,
  );
}

class FakeRig implements EonRig {
  List<db.CapturedImage> lights = [
    for (var i = 0; i < 4; i++) frame(i, type: 'light', exposure: 90),
    for (var i = 4; i < 8; i++) frame(i, type: 'light', exposure: 120),
  ];
  List<String>? wheel = ['L', 'R', 'G', 'B', 'Ha', 'SII', 'OIII', 'DARK'];
  EonCameraInfo? cameraInfo = const EonCameraInfo(
    canCool: true,
    coolerOn: true,
    targetTempC: -10,
    sensorTempC: -10.1,
  );
  String runStatus = 'completed';
  int framesPerDarkGroup = 20;
  int biasFrames = 50;
  Set<double> leakyExposures = {};
  final calls = <String>[];
  final notifications = <(String, String, bool)>[];
  final sequences = <Sequence>[];
  final built = <CalibrationMasterBuildRequest>[];
  Map<String, Object?>? saved;
  Completer<void>? runGate;

  @override
  DateTime now() => DateTime(2026, 10, 22, 6, 30);

  @override
  Future<List<db.CapturedImage>> lightFramesSince(DateTime since) async {
    calls.add('lights since $since');
    return lights;
  }

  @override
  Future<EonCameraInfo?> camera() async => cameraInfo;

  @override
  Future<List<String>?> filterNames() async => wheel;

  @override
  Future<String?> stopGuiding() async {
    calls.add('stopGuiding');
    return 'Guiding stopped';
  }

  @override
  Future<String> secureMount(EonMountAction action) async {
    calls.add('mount ${action.name}');
    return 'Mount sent home';
  }

  @override
  Future<EonRunResult> runSequence(Sequence sequence) async {
    calls.add('run');
    sequences.add(sequence);
    final gate = runGate;
    if (gate != null) await gate.future;
    return EonRunResult(runId: 31, runStatus: runStatus);
  }

  @override
  Future<void> stopRun() async {
    calls.add('stopRun');
    runGate?.complete();
  }

  @override
  Future<List<db.CapturedImage>> framesOfRun(int runId) async {
    var id = 100;
    return [
      for (var i = 0; i < framesPerDarkGroup; i++)
        frame(id++, type: 'dark', exposure: 90, dir: '/n/Dark'),
      for (var i = 0; i < framesPerDarkGroup; i++)
        frame(id++, type: 'dark', exposure: 120, dir: '/n/Dark'),
      for (var i = 0; i < biasFrames; i++)
        frame(id++, type: 'bias', exposure: 0.001, dir: '/n/Bias'),
    ];
  }

  @override
  Future<CalibrationMasterBuildResult> buildMaster(
    CalibrationMasterBuildRequest request,
  ) async {
    built.add(request);
    final first = lightsOrFrame(request.framePaths.first);
    if (leakyExposures.contains(first)) {
      throw 'light leak: 15 of 20 frames read more than 5.0 ADU above the '
          'first frames (233.0 ADU); no master was written';
    }
    return CalibrationMasterBuildResult(
      outputPath: request.outputPath,
      kind: request.kind,
      width: 4656,
      height: 3520,
      frameCount: request.framePaths.length,
      leakingFrames: const [],
      frameLevels: const [],
      leakBaseline: 233,
      leakThreshold: 5,
      masterMean: 233,
      rejectionFraction: 0.002,
      exposureSecs: first,
      gain: 76,
      offset: 15,
      binX: 1,
      binY: 1,
      ccdTempMean: -10,
      setTemp: -10,
    );
  }

  double lightsOrFrame(String path) =>
      double.parse(RegExp(r'_([0-9.]+)s_').firstMatch(path)!.group(1)!);

  @override
  Future<int> registerMaster(
    CalibrationMasterBuildResult built,
    String frameType,
  ) async {
    calls.add('register $frameType ${built.exposureSecs}');
    return built.exposureSecs!.round() + 1000;
  }

  @override
  Future<String> warmUpCamera() async {
    calls.add('warmUp');
    return 'Camera warm-up started';
  }

  @override
  Future<void> notify(
    String title,
    String message, {
    bool problem = false,
  }) async {
    notifications.add((title, message, problem));
  }

  @override
  Future<void> saveReport(Map<String, Object?> report) async {
    saved = report;
  }
}

void main() {
  late FakeRig rig;
  late EndOfNightCalibrationService service;
  const settings = EonSettings(enabled: true);

  setUp(() {
    rig = FakeRig();
    service = EndOfNightCalibrationService(rig, () async => settings);
  });

  test('takes the night\'s darks and bias through the dark slot', () async {
    final report = await service.run(reason: 'dawn ended imaging');

    expect(report.phase, EonPhase.finished, reason: report.summary);
    expect(rig.calls.take(3), [
      'lights since 2026-10-21 14:30:00.000',
      'stopGuiding',
      'mount home',
    ]);
    expect(rig.calls, containsAllInOrder(['run', 'warmUp']));
    final exposures = rig.sequences.single.nodes.values
        .whereType<ExposureNode>()
        .toList();
    expect(exposures.map((e) => e.filter).toSet(), {'DARK'});
    expect(isCalibrationOnlySequence(rig.sequences.single), isTrue);

    expect(rig.built.map((b) => (b.kind, b.framePaths.length)).toList(), [
      ('dark', 20),
      ('dark', 20),
      ('bias', 50),
    ]);
    expect(
      rig.built.first.outputPath,
      '/n/Dark/Masters/MasterDark_90s_g76_o15_m10C_bin1_20261022-0630.fits',
    );
    expect(report.masters.where((m) => m.built), hasLength(3));
    expect(report.problems, isEmpty);
    expect(rig.notifications.map((n) => n.$1).toList(), [
      'End-of-night calibration started',
      'End-of-night calibration finished',
    ]);
    expect(rig.notifications.last.$3, isFalse);
    expect(rig.saved?['phase'], 'finished');
    expect(service.state.phase, EonPhase.finished);
  });

  test('no dark slot and "skip" takes nothing and says why', () async {
    rig.wheel = ['L', 'R', 'G', 'B'];
    final report = await service.run(
      reason: 'manual',
      settings: settings.copyWith(noDarkSlot: EonNoDarkSlotPolicy.skip),
    );
    expect(report.phase, EonPhase.skipped);
    expect(report.summary, contains('no dark slot'));
    expect(rig.calls, isNot(contains('run')));
    expect(rig.notifications.single.$3, isTrue);
  });

  test('no dark slot asks for a cap and goes ahead once confirmed', () async {
    rig.wheel = null;
    final done = service.run(reason: 'manual');
    await pumpUntil(() => service.waitingForCap);
    expect(rig.notifications.last.$1, 'Cap the telescope for darks');
    expect(service.confirmCapped(), isTrue);
    final report = await done;
    expect(report.phase, EonPhase.finished, reason: report.summary);
    expect(report.darkSlot, contains('capped'));
    expect(
      rig.sequences.single.nodes.values.whereType<ExposureNode>().map(
        (e) => e.filter,
      ),
      everyElement(isNull),
    );
  });

  test('stopping while waiting for a cap takes nothing', () async {
    rig.wheel = null;
    final done = service.run(reason: 'manual');
    await pumpUntil(() => service.waitingForCap);
    await service.cancel();
    final report = await done;
    expect(report.phase, EonPhase.cancelled);
    expect(rig.calls, isNot(contains('run')));
  });

  test('stopping during the run stops the run', () async {
    rig.runGate = Completer<void>();
    rig.runStatus = 'stopped';
    final done = service.run(reason: 'manual');
    await pumpUntil(() => rig.calls.contains('run'));
    await service.cancel();
    final report = await done;
    expect(rig.calls, contains('stopRun'));
    expect(report.phase, EonPhase.cancelled);
  });

  test('a leaking group is reported and the others still build', () async {
    rig.leakyExposures = {120};
    final report = await service.run(reason: 'manual');
    expect(report.phase, EonPhase.finished);
    expect(report.masters.where((m) => m.built), hasLength(2));
    expect(report.problems.single, startsWith('Light leak in the 120 s darks'));
    expect(rig.notifications.last.$3, isTrue);
  });

  test('a short run builds what it took and reports the shortfall', () async {
    rig.runStatus = 'stopped';
    rig.framesPerDarkGroup = 7;
    final report = await service.run(reason: 'manual');
    expect(report.phase, EonPhase.finished);
    expect(
      report.problems,
      containsAll([
        'The calibration run ended stopped before taking every frame',
        'Only 7 frames were taken for the 90 s darks, gain 76, offset 15, '
            'bin 1x1',
      ]),
    );
  });

  test('a night without lights is skipped', () async {
    rig.lights = [];
    final report = await service.run(reason: 'manual');
    expect(report.phase, EonPhase.skipped);
    expect(rig.calls, isNot(contains('run')));
  });

  test('no camera is a failure, notified', () async {
    rig.cameraInfo = null;
    final report = await service.run(reason: 'manual');
    expect(report.phase, EonPhase.failed);
    expect(rig.notifications.single.$1, 'End-of-night calibration failed');
  });

  test('a second start while running is refused', () async {
    rig.runGate = Completer<void>();
    final first = service.run(reason: 'manual');
    await pumpUntil(() => rig.calls.contains('run'));
    expect(
      () => service.run(reason: 'manual'),
      throwsA(isA<EonBusyException>()),
    );
    rig.runGate!.complete();
    await first;
  });
}

Future<void> pumpUntil(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}
