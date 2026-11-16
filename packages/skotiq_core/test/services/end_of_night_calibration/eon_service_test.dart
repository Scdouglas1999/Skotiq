import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/utils.dart';
import 'package:skotiq_core/src/database/database.dart' as db;

db.DbCapturedImage frame(
  int id, {
  required String type,
  required double exposure,
  String dir = '/n',
  int gain = 76,
  int offset = 15,
  int bin = 1,
  double? sensorTemp = -10.0,
}) {
  final at = DateTime(2026, 10, 22, 6).add(Duration(seconds: id));
  return db.DbCapturedImage(
    id: id,
    filePath: '$dir/${type}_${exposure}s_$id.fits',
    fileName: '${type}_${exposure}s_$id.fits',
    fileFormat: 'fits',
    frameType: type,
    exposureDuration: exposure,
    gain: gain,
    offset: offset,
    binX: bin,
    binY: bin,
    sensorTemp: sensorTemp,
    isPlateSolved: false,
    capturedAt: at,
    createdAt: at,
    isAccepted: true,
  );
}

class FakeRig implements EonRig {
  List<db.DbCapturedImage> lights = [
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
  SequenceRunStatus runStatus = SequenceRunStatus.completed;
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
  Future<List<db.DbCapturedImage>> lightFramesSince(DateTime since) async {
    calls.add('lights since $since');
    return lights;
  }

  @override
  Future<EonCameraInfo?> camera() async => cameraInfo;

  @override
  Future<List<String>?> filterNames() async => wheel;

  /// The wheel's slot; the calibration run moves it to the dark slot its
  /// exposures name, as the native run does.
  int? wheelPosition = 0;
  final filterMoves = <int>[];
  Object? filterMoveError;
  Object? runError;

  @override
  Future<int?> filterPosition() async => wheel == null ? null : wheelPosition;

  @override
  Future<void> moveFilter(int position) async {
    filterMoves.add(position);
    if (filterMoveError != null) throw filterMoveError!;
    wheelPosition = position;
  }

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
    final darkIndex = sequence.nodes.values
        .whereType<ExposureNode>()
        .map((n) => n.filterIndex)
        .whereType<int>()
        .firstOrNull;
    if (darkIndex != null) wheelPosition = darkIndex;
    if (runError != null) throw runError!;
    final gate = runGate;
    if (gate != null) await gate.future;
    return EonRunResult(runId: 31, runStatus: runStatus);
  }

  @override
  Future<void> stopRun() async {
    calls.add('stopRun');
    runGate?.complete();
  }

  /// The run's frames; null takes the night's default darks and bias.
  List<db.DbCapturedImage>? runFrames;

  @override
  Future<List<db.DbCapturedImage>> framesOfRun(int runId) async {
    if (runFrames != null) return runFrames!;
    var id = 100;
    final frames = [
      for (var i = 0; i < framesPerDarkGroup; i++)
        frame(id++, type: 'dark', exposure: 90, dir: '/n/Dark'),
      for (var i = 0; i < framesPerDarkGroup; i++)
        frame(id++, type: 'dark', exposure: 120, dir: '/n/Dark'),
      for (var i = 0; i < biasFrames; i++)
        frame(id++, type: 'bias', exposure: 0.001, dir: '/n/Bias'),
    ];
    for (final f in frames) {
      headers.putIfAbsent(
        f.filePath,
        () => FrameHeader(const {'SET-TEMP': -10}),
      );
    }
    return frames;
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

  /// The frames' headers by path; a frame missing here has a header without
  /// the cards the step reads.
  final headers = <String, FrameHeader>{};

  /// Paths whose header cannot be read.
  final unreadable = <String>{};

  @override
  Future<FrameHeader> frameHeader(String path) async {
    if (unreadable.contains(path)) throw 'not a FITS file';
    return headers[path] ?? FrameHeader(const {});
  }

  double lightsOrFrame(String path) =>
      double.parse(RegExp(r'_([0-9.]+)s_').firstMatch(path)!.group(1)!);

  double darkToleranceC = 2.0;

  @override
  Future<double> darkTemperatureToleranceC() async => darkToleranceC;

  @override
  Future<int> registerMaster(
    CalibrationMasterBuildResult built,
    String frameType,
  ) async {
    calls.add('register $frameType ${built.exposureSecs}');
    return built.exposureSecs!.round() + 1000;
  }

  CameraWarmupOutcome warmUpOutcome = CameraWarmupOutcome.started;

  @override
  Future<CameraWarmupOutcome> warmUpCamera() async {
    calls.add('warmUp');
    return warmUpOutcome;
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

  test(
    'frames read off the set-point their header states are left out, and said',
    () async {
      rig.lights = [
        frame(1, type: 'light', exposure: 3, sensorTemp: 1.2),
        frame(2, type: 'light', exposure: 3, sensorTemp: 0.2),
      ];
      var id = 100;
      db.DbCapturedImage dark(double sensor, double setPoint) {
        final f = frame(
          id++,
          type: 'dark',
          exposure: 3,
          dir: '/n/Dark',
          sensorTemp: sensor,
        );
        rig.headers[f.filePath] = FrameHeader({'SET-TEMP': setPoint});
        return f;
      }

      rig.runFrames = [
        // Taken while the sensor was still warming from the night's -10 C.
        dark(-9.7, 1),
        dark(-5.5, 1),
        for (var i = 0; i < 5; i++) dark(1.1, 1),
        for (var i = 0; i < 4; i++) dark(0.1, 0),
      ];

      final report = await service.run(reason: 'manual');

      expect(
        {
          for (final b in rig.built)
            b.outputPath.split('/').last: b.framePaths.length,
        },
        {
          'MasterDark_3s_g76_o15_p1C_bin1_20261022-0630.fits': 5,
          'MasterDark_3s_g76_o15_p0C_bin1_20261022-0630.fits': 4,
        },
      );
      expect(
        report.problems,
        contains(
          '2 of the 7 3 s darks, gain 76, offset 15, bin 1x1, 1 °C read more '
          'than 2 °C from the set-point and were left out',
        ),
      );
    },
  );

  test(
    'a group with too few frames at its set-point is said, not built',
    () async {
      rig.lights = [frame(1, type: 'light', exposure: 3, sensorTemp: 1)];
      var id = 100;
      rig.runFrames = [
        for (final t in [-9.7, -8.1, 1.0])
          frame(id++, type: 'dark', exposure: 3, dir: '/n/Dark', sensorTemp: t),
      ];
      for (final f in rig.runFrames!) {
        rig.headers[f.filePath] = FrameHeader(const {'SET-TEMP': 1.0});
      }

      final report = await service.run(reason: 'manual');

      expect(rig.built, isEmpty);
      final outcome = report.masters.single;
      expect(outcome.built, isFalse);
      expect(outcome.label, '3 s darks, gain 76, offset 15, bin 1x1, 1 °C');
      expect(
        outcome.error,
        'a master needs at least 2 frames at the set-point',
      );
      expect(report.phase, EonPhase.failed);
    },
  );

  test('a frame whose header cannot be read is left out, and said', () async {
    final frames = await rig.framesOfRun(31);
    rig.unreadable.add(frames.first.filePath);

    final report = await service.run(reason: 'manual');

    expect(rig.built.first.framePaths, hasLength(19));
    expect(
      report.problems,
      contains(
        '1 frame could not be read and was left out of the masters '
        '(dark_90.0s_100.fits: not a FITS file)',
      ),
    );
  });

  group('the rig night of 2026-11-16', () {
    // Five set-points, the sensor readings each block's frames recorded, and
    // the set-point each frame's header states.
    var id = 100;
    List<double> spread(double from, double to, int count) => [
      for (var i = 0; i < count; i++)
        count == 1 ? from : from + (to - from) * i / (count - 1),
    ];
    List<db.DbCapturedImage> block(
      String type,
      double exposure, {
      required int gain,
      required int offset,
      required int bin,
      required double setPoint,
      required List<double> temps,
    }) {
      final frames = <db.DbCapturedImage>[];
      for (final t in temps) {
        final f = frame(
          id++,
          type: type,
          exposure: exposure,
          dir: '/n/${type == 'bias' ? 'Bias' : 'Dark'}',
          gain: gain,
          offset: offset,
          bin: bin,
          sensorTemp: t,
        );
        rig.headers[f.filePath] = FrameHeader({'SET-TEMP': setPoint});
        frames.add(f);
      }
      return frames;
    }

    setUp(() {
      id = 100;
      rig.cameraInfo = const EonCameraInfo(
        canCool: true,
        coolerOn: true,
        targetTempC: -10,
        sensorTempC: -10,
      );
      rig.lights = [
        frame(1, type: 'light', exposure: 30, sensorTemp: -10),
        for (final (i, t) in [(2, -6.1), (3, -4.0)])
          frame(
            i,
            type: 'light',
            exposure: 3,
            gain: 600,
            offset: 21,
            bin: 2,
            sensorTemp: t,
          ),
        for (final (i, t) in [(4, 0.1), (5, 1.0)])
          frame(
            i,
            type: 'light',
            exposure: 3,
            gain: 139,
            offset: 21,
            sensorTemp: t,
          ),
      ];
      const g76 = (gain: 76, offset: 15, bin: 1);
      const g600 = (gain: 600, offset: 21, bin: 2);
      const g139 = (gain: 139, offset: 21, bin: 1);
      rig.runFrames = [
        for (final (s, setPoint, exposure, darks, bias) in [
          (g76, -10.0, 30.0, spread(-10.0, -9.8, 20), spread(-10.0, -9.9, 10)),
          (g600, -6.0, 3.0, spread(-6.2, -5.0, 20), spread(-6.1, -5.9, 10)),
          // The bias block was skipped after 4 frames.
          (g600, -4.0, 3.0, spread(-6.0, -3.5, 20), spread(-4.1, -3.9, 4)),
          // ... and this one after 3.
          (g139, 0.0, 3.0, spread(-0.6, 0.5, 20), spread(0.0, 0.1, 3)),
          (g139, 1.0, 3.0, spread(0.2, 1.3, 20), spread(0.9, 1.1, 10)),
        ]) ...[
          ...block(
            'dark',
            exposure,
            gain: s.gain,
            offset: s.offset,
            bin: s.bin,
            setPoint: setPoint,
            temps: darks,
          ),
          ...block(
            'bias',
            0.001,
            gain: s.gain,
            offset: s.offset,
            bin: s.bin,
            setPoint: setPoint,
            temps: bias,
          ),
        ],
      ];
    });

    test(
      'builds one master per set-point and setting, never mixing blocks',
      () async {
        final report = await service.run(reason: 'dawn ended imaging');

        final built = {
          for (final b in rig.built)
            b.outputPath
                    .split('/')
                    .last
                    .replaceFirst('_20261022-0630.fits', ''):
                b.framePaths.length,
        };
        expect(built, {
          'MasterDark_30s_g76_o15_m10C_bin1': 20,
          'MasterBias_g76_o15_m10C_bin1': 10,
          'MasterDark_3s_g600_o21_m6C_bin2': 20,
          'MasterBias_g600_o21_m6C_bin2': 10,
          'MasterDark_3s_g600_o21_m4C_bin2': 20,
          'MasterBias_g600_o21_m4C_bin2': 4,
          'MasterDark_3s_g139_o21_p0C_bin1': 20,
          'MasterBias_g139_o21_p0C_bin1': 3,
          'MasterDark_3s_g139_o21_p1C_bin1': 20,
          'MasterBias_g139_o21_p1C_bin1': 10,
        });
        expect(report.masters.where((m) => m.built), hasLength(10));
        expect(
          report.problems.where((p) => p.contains('left out')),
          isEmpty,
          reason: '${report.problems}',
        );
      },
    );
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

  test(
    'stopping during the run stops the frames and still builds masters',
    () async {
      rig.runGate = Completer<void>();
      rig.runStatus = SequenceRunStatus.stopped;
      rig.framesPerDarkGroup = 5;
      final done = service.run(reason: 'manual');
      await pumpUntil(() => rig.calls.contains('run'));
      await service.cancel();
      final report = await done;
      expect(rig.calls, contains('stopRun'));
      expect(report.phase, EonPhase.cancelled);
      expect(report.masters.where((m) => m.built), hasLength(3));
      expect(report.summary, contains('Stopped'));
      expect(report.summary, contains('Built 3 of 3 masters'));
      expect(rig.notifications.last.$1, 'End-of-night calibration stopped');
    },
  );

  test('the cap request says when the darks are skipped', () async {
    rig.wheel = null;
    final done = service.run(reason: 'manual');
    await pumpUntil(() => service.waitingForCap);
    expect(
      service.state.capDeadline,
      DateTime(2026, 10, 22, 6, 30).add(const Duration(minutes: 30)),
    );
    await service.cancel();
    await done;
    expect(service.state.capDeadline, isNull);
  });

  test('a leaking group is reported and the others still build', () async {
    rig.leakyExposures = {120};
    final report = await service.run(reason: 'manual');
    expect(report.phase, EonPhase.finished);
    expect(report.masters.where((m) => m.built), hasLength(2));
    expect(report.problems.single, startsWith('Light leak in the 120 s darks'));
    expect(rig.notifications.last.$3, isTrue);
  });

  test('every master built and every group left unbuilt is logged', () async {
    final dataRoot = Directory.systemTemp.createTempSync('eon-log');
    final logging = LoggingService(
      applicationSupportDirectoryProvider: () async => dataRoot,
      environment: {skotiqDataDirEnv: dataRoot.path},
      nativeInitWithLogging: ({logDirectory}) {},
      nativeInit: () {},
      currentLogFileProvider: () => null,
    );
    await logging.initialize();
    Log.attach(logging);
    final lines = <LogEntry>[];
    final subscription = logging.logEntryStream.listen(lines.add);
    addTearDown(() async {
      await subscription.cancel();
      Log.detach(logging);
      await logging.dispose();
      dataRoot.deleteSync(recursive: true);
    });
    rig.leakyExposures = {120};

    await service.run(reason: 'manual');
    await Future<void>.delayed(Duration.zero);

    final logged = [
      for (final e in lines)
        if (e.source == 'EndOfNightCalibration') e.message,
    ];
    expect(
      logged,
      containsAllInOrder([
        startsWith(
          'End-of-night calibration built the 90 s darks, gain 76, offset 15, '
          'bin 1x1, -10 °C master from 20 of 20 frames: /n/Dark/Masters/',
        ),
        startsWith(
          'End-of-night calibration built no master for the 120 s darks, '
          'gain 76, offset 15, bin 1x1, -10 °C: light leak',
        ),
        startsWith(
          'End-of-night calibration built the bias, gain 76, offset 15, '
          'bin 1x1, -10 °C master from 50 of 50 frames',
        ),
        startsWith('Built 2 of 3 masters from 90 frames'),
      ]),
    );
  });

  test('a short run builds what it took and reports the shortfall', () async {
    rig.runStatus = SequenceRunStatus.stopped;
    rig.framesPerDarkGroup = 7;
    final report = await service.run(reason: 'manual');
    expect(report.phase, EonPhase.finished);
    expect(
      report.problems,
      containsAll([
        'The calibration run was stopped before taking every frame',
        'Only 7 frames were taken for the 90 s darks, gain 76, offset 15, '
            'bin 1x1, -10 °C',
      ]),
    );
  });

  test('a deferred warm-up still happens when the step skips', () async {
    rig.wheel = ['L', 'R', 'G', 'B'];
    final skipping = EndOfNightCalibrationService(
      rig,
      () async => settings.copyWith(noDarkSlot: EonNoDarkSlotPolicy.skip),
    );
    final report = await skipping.run(reason: 'dawn', forceWarmUp: true);
    expect(report.phase, EonPhase.skipped);
    expect(rig.calls, contains('warmUp'));
    expect(rig.notifications.map((n) => n.$1), contains('Camera warm-up'));
  });

  test('a deferred warm-up of a cooler that was off says only that', () async {
    rig.wheel = ['L', 'R', 'G', 'B'];
    rig.warmUpOutcome = CameraWarmupOutcome.coolerAlreadyOff;
    final skipping = EndOfNightCalibrationService(
      rig,
      () async => settings.copyWith(noDarkSlot: EonNoDarkSlotPolicy.skip),
    );
    await skipping.run(reason: 'dawn', forceWarmUp: true);
    String warmUpNote() =>
        rig.notifications.singleWhere((n) => n.$1 == 'Camera warm-up').$2;
    expect(warmUpNote(), 'The cooler was already off.');

    rig.notifications.clear();
    rig.warmUpOutcome = CameraWarmupOutcome.started;
    await skipping.run(reason: 'dawn', forceWarmUp: true);
    expect(
      warmUpNote(),
      'The plan left the camera cold for calibration: Camera warm-up started.',
    );
  });

  test(
    'a deferred warm-up runs after the frames even with warm-up off',
    () async {
      final noWarm = EndOfNightCalibrationService(
        rig,
        () async => settings.copyWith(warmUp: false),
      );
      await noWarm.run(reason: 'dawn', forceWarmUp: true);
      expect(rig.calls, containsAllInOrder(['run', 'warmUp']));
      expect(rig.calls.where((c) => c == 'warmUp'), hasLength(1));
    },
  );

  test('a skip without a deferred warm-up leaves the camera alone', () async {
    rig.wheel = ['L', 'R', 'G', 'B'];
    final skipping = EndOfNightCalibrationService(
      rig,
      () async => settings.copyWith(noDarkSlot: EonNoDarkSlotPolicy.skip),
    );
    await skipping.run(reason: 'manual');
    expect(rig.calls, isNot(contains('warmUp')));
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

  group('the filter wheel goes back where it was', () {
    setUp(() => rig.wheelPosition = 4);

    test('after a finished run', () async {
      final report = await service.run(reason: 'dawn ended imaging');
      expect(report.phase, EonPhase.finished, reason: report.summary);
      expect(rig.filterMoves, [4]);
      expect(rig.wheelPosition, 4);
      expect(report.filterRestored, 'Filter wheel put back on Ha (position 5)');
      expect(report.toJson()['filterRestored'], report.filterRestored);
    });

    test('after a stopped run', () async {
      rig.runGate = Completer<void>();
      rig.runStatus = SequenceRunStatus.stopped;
      final running = service.run(reason: 'manual');
      await pumpUntil(() => rig.calls.contains('run'));
      expect(rig.wheelPosition, 7);
      await service.cancel();
      final report = await running;
      expect(report.phase, EonPhase.cancelled, reason: report.summary);
      expect(rig.wheelPosition, 4);
    });

    test('after a run stopped from outside the step', () async {
      // POST /api/sequencer/stop ends the native run; the step only sees
      // the run come back stopped.
      rig.runStatus = SequenceRunStatus.stopped;
      final report = await service.run(reason: 'manual');
      expect(report.runStatus, 'stopped');
      expect(rig.wheelPosition, 4);
    });

    test('after a run that failed to run at all', () async {
      rig.runError = StateError('the sequencer refused the plan');
      final report = await service.run(reason: 'manual');
      expect(report.phase, EonPhase.failed);
      expect(rig.wheelPosition, 4);
    });

    test('a failed move back is a problem in the report', () async {
      rig.filterMoveError = 'wheel did not answer';
      final report = await service.run(reason: 'manual');
      expect(rig.wheelPosition, 7);
      expect(
        report.problems,
        contains(
          'The filter wheel could not be put back on Ha (position 5) after '
          'the darks: wheel did not answer',
        ),
      );
    });

    test('a wheel that started on the dark slot is left there', () async {
      rig.wheelPosition = 7;
      await service.run(reason: 'manual');
      expect(rig.filterMoves, isEmpty);
    });

    test('darks behind a cap never touch the wheel', () async {
      rig.wheel = null;
      final capped = service.run(
        reason: 'manual',
        settings: const EonSettings(enabled: true),
      );
      await pumpUntil(() => service.waitingForCap);
      service.confirmCapped();
      await capped;
      expect(rig.filterMoves, isEmpty);
    });
  });
}

Future<void> pumpUntil(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}
