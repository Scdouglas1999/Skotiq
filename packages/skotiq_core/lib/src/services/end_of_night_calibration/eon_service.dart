import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../database/database.dart' show CapturedImage;
import '../../models/sequence/sequence_models.dart';
import '../calibration_master_builder.dart';
import 'eon_plan.dart';
import 'eon_settings.dart';

/// The camera as the step needs to know it.
class EonCameraInfo {
  const EonCameraInfo({
    required this.canCool,
    required this.coolerOn,
    this.targetTempC,
    this.sensorTempC,
    this.minExposureSecs,
  });

  final bool canCool;
  final bool coolerOn;
  final double? targetTempC;
  final double? sensorTempC;
  final double? minExposureSecs;

  /// The set-point the night was cooled to, when the cooler is holding one.
  double? get setPointC => canCool && coolerOn ? targetTempC : null;
}

/// How the calibration run ended.
class EonRunResult {
  const EonRunResult({required this.runId, required this.runStatus});

  final int? runId;

  /// `completed`, `stopped`, `paused-stopped` or `failed`.
  final String runStatus;
}

/// Everything the step does to the rig and the app, so the step itself can be
/// driven against a fake in tests.
abstract class EonRig {
  DateTime now();

  /// Light frames recorded since [since], oldest first.
  Future<List<CapturedImage>> lightFramesSince(DateTime since);

  /// The connected camera, or null when none is connected.
  Future<EonCameraInfo?> camera();

  /// Filter names of the connected wheel, or null when there is none.
  Future<List<String>?> filterNames();

  /// Stop the guider; returns what was done, or null when nothing was guiding.
  Future<String?> stopGuiding();

  /// Move the mount out of the way; returns what was done. Throws when the
  /// mount was asked to move and did not.
  Future<String> secureMount(EonMountAction action);

  /// Load and run [sequence] to its end.
  Future<EonRunResult> runSequence(Sequence sequence);

  /// Stop the calibration run started by [runSequence].
  Future<void> stopRun();

  Future<List<CapturedImage>> framesOfRun(int runId);

  Future<CalibrationMasterBuildResult> buildMaster(
    CalibrationMasterBuildRequest request,
  );

  /// Add a master to the dark library; returns its row id.
  Future<int> registerMaster(
    CalibrationMasterBuildResult built,
    String frameType,
  );

  /// Start the gradual warm-up; returns what happened.
  Future<String> warmUpCamera();

  Future<void> notify(String title, String message, {bool problem = false});

  Future<void> saveReport(Map<String, Object?> report);
}

enum EonPhase {
  idle,
  preparing,
  waitingForCap,
  capturing,
  buildingMasters,
  finished,
  skipped,
  failed,
  cancelled;

  bool get isActive =>
      this == preparing ||
      this == waitingForCap ||
      this == capturing ||
      this == buildingMasters;
}

/// One master the step built, or tried to.
class EonMasterOutcome {
  const EonMasterOutcome({
    required this.frameType,
    required this.label,
    required this.framesCaptured,
    this.framesCombined,
    this.outputPath,
    this.libraryId,
    this.leakingFrames = const [],
    this.error,
  });

  final String frameType;
  final String label;
  final int framesCaptured;
  final int? framesCombined;
  final String? outputPath;
  final int? libraryId;
  final List<String> leakingFrames;
  final String? error;

  bool get built => libraryId != null;

  Map<String, Object?> toJson() => {
    'frameType': frameType,
    'label': label,
    'framesCaptured': framesCaptured,
    'framesCombined': framesCombined,
    'outputPath': outputPath,
    'libraryId': libraryId,
    'leakingFrames': leakingFrames,
    'error': error,
  };
}

/// What the step did, for the operator.
class EonReport {
  EonReport({required this.reason, required this.startedAt});

  final String reason;
  final DateTime startedAt;
  DateTime? finishedAt;
  EonPhase phase = EonPhase.preparing;
  String? guiding;
  String? mount;
  String? darkSlot;
  List<String> plannedDarks = const [];
  int plannedBiasFrames = 0;
  int? runId;
  String? runStatus;
  int framesCaptured = 0;
  final List<EonMasterOutcome> masters = [];
  String? warmUp;
  final List<String> problems = [];
  String summary = '';

  Map<String, Object?> toJson() => {
    'reason': reason,
    'phase': phase.name,
    'startedAt': startedAt.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
    'guiding': guiding,
    'mount': mount,
    'darkSlot': darkSlot,
    'plannedDarks': plannedDarks,
    'plannedBiasFrames': plannedBiasFrames,
    'runId': runId,
    'runStatus': runStatus,
    'framesCaptured': framesCaptured,
    'masters': [for (final m in masters) m.toJson()],
    'warmUp': warmUp,
    'problems': problems,
    'summary': summary,
  };
}

class EonStatus {
  const EonStatus({this.phase = EonPhase.idle, this.message, this.report});

  final EonPhase phase;
  final String? message;
  final EonReport? report;

  Map<String, Object?> toJson() => {
    'phase': phase.name,
    'message': message,
    'report': report?.toJson(),
  };
}

/// Why a calibration step could not start.
class EonBusyException implements Exception {
  const EonBusyException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// How far back the night's light frames are looked for.
const eonNightWindow = Duration(hours: 16);

/// The end-of-night calibration step: work out the darks and bias the night's
/// lights need, take them through the dark slot (or behind a cap the operator
/// confirms), build the masters into the dark library and warm the camera up.
class EndOfNightCalibrationService extends StateNotifier<EonStatus> {
  EndOfNightCalibrationService(this._rig, this._loadSettings)
    : super(const EonStatus());

  final EonRig _rig;
  final Future<EonSettings> Function() _loadSettings;
  Completer<bool>? _capConfirmation;
  bool _cancelRequested = false;
  bool _runInFlight = false;

  bool get isRunning => state.phase.isActive;

  /// Whether the step is waiting for the operator to confirm the cap.
  bool get waitingForCap => state.phase == EonPhase.waitingForCap;

  void _set(EonPhase phase, String message, EonReport report) {
    report.phase = phase;
    if (mounted) {
      state = EonStatus(phase: phase, message: message, report: report);
    }
  }

  /// The operator confirmed the telescope is capped.
  bool confirmCapped() {
    final pending = _capConfirmation;
    if (pending == null || pending.isCompleted) return false;
    pending.complete(true);
    return true;
  }

  /// Stop the step: ends the wait for a cap or stops the calibration run.
  Future<void> cancel() async {
    if (!isRunning) return;
    _cancelRequested = true;
    final pending = _capConfirmation;
    if (pending != null && !pending.isCompleted) pending.complete(false);
    if (_runInFlight) await _rig.stopRun();
  }

  /// Run the step. [reason] says what ended the night.
  Future<EonReport> run({required String reason, EonSettings? settings}) async {
    if (isRunning) {
      throw const EonBusyException(
        'End-of-night calibration is already running',
      );
    }
    _cancelRequested = false;
    final config = settings ?? await _loadSettings();
    final report = EonReport(reason: reason, startedAt: _rig.now());
    _set(EonPhase.preparing, 'Working out the frames tonight needs', report);
    try {
      await _run(config, report);
    } catch (e) {
      report.problems.add('$e');
      _finish(report, EonPhase.failed, 'End-of-night calibration failed: $e');
      await _rig.notify(
        'End-of-night calibration failed',
        report.summary,
        problem: true,
      );
    }
    await _rig.saveReport(report.toJson());
    return report;
  }

  void _finish(EonReport report, EonPhase phase, String summary) {
    report.finishedAt = _rig.now();
    report.summary = summary;
    _set(phase, summary, report);
  }

  Future<void> _run(EonSettings config, EonReport report) async {
    final lights = await _rig.lightFramesSince(
      _rig.now().subtract(eonNightWindow),
    );
    final camera = await _rig.camera();
    if (camera == null) {
      throw StateError('no camera is connected');
    }
    final needs = planFrameNeeds(lights, cameraSetPointC: camera.setPointC);
    if (needs.isEmpty) {
      _finish(
        report,
        EonPhase.skipped,
        'No light frames were taken tonight, so no darks or bias are needed.',
      );
      await _rig.notify('End-of-night calibration skipped', report.summary);
      return;
    }
    report.plannedDarks = [
      for (final d in needs.darks)
        '${config.darkCount} x ${d.label} (for ${d.lightCount} lights)',
    ];
    report.plannedBiasFrames = needs.bias.length * config.biasCount;

    report.guiding = await _attempt(report, 'Stopping guiding', () async {
      return await _rig.stopGuiding() ?? 'Nothing was guiding';
    });
    report.mount = await _attempt(
      report,
      'Moving the mount',
      () => _rig.secureMount(config.mountAction),
    );

    final darkSlot = findDarkSlot(await _rig.filterNames());
    if (darkSlot != null) {
      report.darkSlot = '${darkSlot.name} (position ${darkSlot.index + 1})';
    } else {
      final capped = await _awaitCap(config, report);
      if (!capped) return;
      report.darkSlot = 'none: the operator confirmed the telescope is capped';
    }
    if (_cancelRequested) return _cancelled(report);

    final sequence = buildCalibrationSequence(
      needs: needs,
      darkCount: config.darkCount,
      biasCount: config.biasCount,
      biasExposureSecs: _biasExposure(camera),
      cameraCanCool: camera.canCool,
      darkSlot: darkSlot,
    );
    final plannedText = [
      ...report.plannedDarks,
      '${config.biasCount} bias for each of ${needs.bias.length} '
          'gain/offset settings',
    ].join('; ');
    _set(EonPhase.capturing, 'Taking calibration frames', report);
    await _rig.notify('End-of-night calibration started', plannedText);

    _runInFlight = true;
    final EonRunResult result;
    try {
      result = await _rig.runSequence(sequence);
    } finally {
      _runInFlight = false;
    }
    report.runId = result.runId;
    report.runStatus = result.runStatus;
    if (result.runStatus != 'completed') {
      report.problems.add(
        'The calibration run ended ${result.runStatus} before taking every '
        'frame',
      );
    }

    if (config.warmUp && camera.canCool) {
      report.warmUp = await _attempt(
        report,
        'Warming the camera up',
        _rig.warmUpCamera,
      );
    }

    final frames = result.runId == null
        ? const <CapturedImage>[]
        : await _rig.framesOfRun(result.runId!);
    report.framesCaptured = frames.length;
    _set(EonPhase.buildingMasters, 'Building masters', report);
    await _buildMasters(frames, needs, config, report);

    if (_cancelRequested) return _cancelled(report);
    final built = report.masters.where((m) => m.built).length;
    final summary = StringBuffer(
      'Built $built of ${report.masters.length} masters from '
      '${report.framesCaptured} frames into the dark library.',
    );
    if (report.warmUp != null) summary.write(' ${report.warmUp}.');
    if (report.problems.isNotEmpty) {
      summary.write(' Problems: ${report.problems.join('; ')}.');
    }
    final failed = built == 0;
    _finish(
      report,
      failed ? EonPhase.failed : EonPhase.finished,
      summary.toString(),
    );
    await _rig.notify(
      failed
          ? 'End-of-night calibration built no masters'
          : 'End-of-night calibration finished',
      report.summary,
      problem: failed || report.problems.isNotEmpty,
    );
  }

  void _cancelled(EonReport report) {
    _finish(report, EonPhase.cancelled, 'End-of-night calibration stopped');
  }

  double _biasExposure(EonCameraInfo camera) {
    final min = camera.minExposureSecs;
    if (min == null || min <= 0) return 0.001;
    return min > 0.001 ? min : 0.001;
  }

  /// Run one preparation step; a failure is reported, not fatal: darks do not
  /// depend on where the mount is.
  Future<String> _attempt(
    EonReport report,
    String what,
    Future<String> Function() step,
  ) async {
    try {
      return await step();
    } catch (e) {
      final text = '$what failed: $e';
      report.problems.add(text);
      return text;
    }
  }

  Future<bool> _awaitCap(EonSettings config, EonReport report) async {
    if (config.noDarkSlot == EonNoDarkSlotPolicy.skip) {
      _finish(
        report,
        EonPhase.skipped,
        'No darks or bias were taken: the filter wheel has no dark slot and '
        'the settings say to skip rather than ask for a cap.',
      );
      await _rig.notify(
        'End-of-night calibration skipped',
        report.summary,
        problem: true,
      );
      return false;
    }
    final pending = Completer<bool>();
    _capConfirmation = pending;
    _set(
      EonPhase.waitingForCap,
      'Waiting for the telescope to be capped',
      report,
    );
    await _rig.notify(
      'Cap the telescope for darks',
      'The filter wheel has no dark slot. Cap the telescope, then confirm in '
          'Skotiq. Darks and bias are skipped if nobody confirms within '
          '${config.capWaitMinutes} minutes.',
      problem: true,
    );
    final capped = await pending.future.timeout(
      Duration(minutes: config.capWaitMinutes),
      onTimeout: () => false,
    );
    _capConfirmation = null;
    if (capped) return true;
    if (_cancelRequested) {
      _cancelled(report);
      return false;
    }
    _finish(
      report,
      EonPhase.skipped,
      'No darks or bias were taken: the filter wheel has no dark slot and '
      'nobody confirmed the telescope was capped within '
      '${config.capWaitMinutes} minutes.',
    );
    await _rig.notify(
      'End-of-night calibration skipped',
      report.summary,
      problem: true,
    );
    return false;
  }

  Future<void> _buildMasters(
    List<CapturedImage> frames,
    EonFrameNeeds needs,
    EonSettings config,
    EonReport report,
  ) async {
    final groups = <(String, int, int, int, int, int), List<CapturedImage>>{};
    for (final frame in frames) {
      final type = frame.frameType.toLowerCase();
      if (type != 'dark' && type != 'bias') continue;
      final gain = frame.gain;
      final offset = frame.offset;
      if (gain == null || offset == null) {
        report.problems.add(
          'Excluded ${frame.fileName} from master building: '
          'the recorded gain or offset is missing.',
        );
        continue;
      }
      final key = (
        type,
        (frame.exposureDuration * 1000).round(),
        gain,
        offset,
        frame.binX,
        frame.binY,
      );
      (groups[key] ??= []).add(frame);
    }
    for (final dark in needs.darks) {
      final key = (
        'dark',
        (dark.exposureSecs * 1000).round(),
        dark.gain,
        dark.offset,
        dark.binX,
        dark.binY,
      );
      if (!groups.containsKey(key)) {
        report.problems.add('No darks were taken for ${dark.label}');
      }
    }
    final stamp = _stamp(report.startedAt);
    for (final entry in groups.entries) {
      if (_cancelRequested) return;
      final (type, exposureMs, gain, offset, binX, binY) = entry.key;
      final group = entry.value;
      final exposure = exposureMs / 1000;
      final temps = [
        for (final f in group)
          if (f.sensorTemp != null) f.sensorTemp!,
      ];
      final temp = temps.isEmpty
          ? null
          : temps.reduce((a, b) => a + b) / temps.length;
      final label = type == 'bias'
          ? 'bias, gain $gain, offset $offset, bin ${binX}x$binY'
          : '${_trim(exposure)} s darks, gain $gain, offset $offset, '
                'bin ${binX}x$binY';
      if (type == 'dark' && group.length < config.darkCount ||
          type == 'bias' && group.length < config.biasCount) {
        report.problems.add(
          'Only ${group.length} frames were taken for the $label',
        );
      }
      if (group.length < 2) {
        report.masters.add(
          EonMasterOutcome(
            frameType: type,
            label: label,
            framesCaptured: group.length,
            error: 'a master needs at least 2 frames',
          ),
        );
        continue;
      }
      final name =
          '${type == 'bias' ? 'MasterBias' : 'MasterDark_${_trim(exposure)}s'}'
          '_g${gain}_o${offset}_${_tempTag(temp)}_bin$binX'
          '_$stamp.fits';
      final output = p.join(p.dirname(group.first.filePath), 'Masters', name);
      try {
        final built = await _rig.buildMaster(
          CalibrationMasterBuildRequest(
            kind: type,
            framePaths: [for (final f in group) f.filePath],
            outputPath: output,
          ),
        );
        final id = await _rig.registerMaster(built, type);
        if (built.leakingFrames.isNotEmpty) {
          report.problems.add(
            'Light leak: ${built.leakingFrames.length} of ${group.length} '
            '$label read brighter than the first frames and were left out',
          );
        }
        report.masters.add(
          EonMasterOutcome(
            frameType: type,
            label: label,
            framesCaptured: group.length,
            framesCombined: built.frameCount,
            outputPath: built.outputPath,
            libraryId: id,
            leakingFrames: built.leakingFrames,
          ),
        );
      } catch (e) {
        final message = '$e';
        report.problems.add(
          message.contains('light leak')
              ? 'Light leak in the $label: $message'
              : 'The $label master failed: $message',
        );
        report.masters.add(
          EonMasterOutcome(
            frameType: type,
            label: label,
            framesCaptured: group.length,
            error: message,
          ),
        );
      }
    }
  }

  static String _trim(double value) {
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    return value
        .toStringAsFixed(3)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceAll('.', 'p');
  }

  static String _tempTag(double? temp) {
    if (temp == null) return 'notemp';
    final rounded = temp.round();
    return rounded < 0 ? 'm${-rounded}C' : 'p${rounded}C';
  }

  static String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}';
  }
}
