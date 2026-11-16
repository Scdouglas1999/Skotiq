import '../../models/imaging/imaging_models.dart' show FrameType;
import '../../database/rows/frame_type_record.dart';
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../database/database.dart' show DbCapturedImage;
import '../../models/sequence/sequence_models.dart';
import '../../models/sequence/sequence_run_status.dart';
import '../calibration/calibration_frame_groups.dart';
import '../calibration_master_builder.dart';
import '../camera_warmup_controller.dart' show CameraWarmupOutcome;
import '../frame_header.dart';
import '../../utils/logging_service.dart';
import 'eon_plan.dart';
import 'eon_settings.dart';
import '../../models/calibration/eon_status.dart';

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
  final SequenceRunStatus runStatus;
}

/// Everything the step does to the rig and the app, so the step itself can be
/// driven against a fake in tests.
abstract class EonRig {
  DateTime now();

  /// Light frames recorded since [since], oldest first.
  Future<List<DbCapturedImage>> lightFramesSince(DateTime since);

  /// The connected camera, or null when none is connected.
  Future<EonCameraInfo?> camera();

  /// Filter names of the connected wheel, or null when there is none.
  Future<List<String>?> filterNames();

  /// The wheel's current zero-based slot, or null when there is no wheel or
  /// it cannot be read.
  Future<int?> filterPosition();

  /// Move the wheel to the zero-based slot [position].
  Future<void> moveFilter(int position);

  /// Stop the guider; returns what was done, or null when nothing was guiding.
  Future<String?> stopGuiding();

  /// Move the mount out of the way; returns what was done. Throws when the
  /// mount was asked to move and did not.
  Future<String> secureMount(EonMountAction action);

  /// Load and run [sequence] to its end.
  Future<EonRunResult> runSequence(Sequence sequence);

  /// Stop the calibration run started by [runSequence].
  Future<void> stopRun();

  Future<List<DbCapturedImage>> framesOfRun(int runId);

  /// The header of the frame file at [path]; throws when it cannot be read.
  Future<FrameHeader> frameHeader(String path);

  Future<CalibrationMasterBuildResult> buildMaster(
    CalibrationMasterBuildRequest request,
  );

  /// How far, in °C, a dark's sensor temperature may be from a light's and
  /// still calibrate it: the dark library's tolerance.
  Future<double> darkTemperatureToleranceC();

  /// Add a master to the dark library; returns its row id.
  Future<int> registerMaster(
    CalibrationMasterBuildResult built,
    String frameType,
  );

  /// Start the gradual warm-up; returns what happened.
  Future<CameraWarmupOutcome> warmUpCamera();

  Future<void> notify(String title, String message, {bool problem = false});

  Future<void> saveReport(Map<String, Object?> report);
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
  bool _forceWarmUp = false;

  bool get isRunning => state.phase.isActive;

  /// Whether the step is waiting for the operator to confirm the cap.
  bool get waitingForCap => state.phase == EonPhase.waitingForCap;

  void _set(
    EonPhase phase,
    String message,
    EonReport report, {
    DateTime? capDeadline,
  }) {
    report.phase = phase;
    if (mounted) {
      state = EonStatus(
        phase: phase,
        message: message,
        report: report,
        capDeadline: capDeadline,
      );
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

  /// Run the step. [reason] says what ended the night. [forceWarmUp] is set
  /// when the run handed its own closing warm-up to this step: the camera is
  /// then warmed however the step ends, even if it takes no frames.
  Future<EonReport> run({
    required String reason,
    EonSettings? settings,
    bool forceWarmUp = false,
  }) async {
    if (isRunning) {
      throw const EonBusyException(
        'End-of-night calibration is already running',
      );
    }
    _cancelRequested = false;
    _forceWarmUp = forceWarmUp;
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
    if (forceWarmUp && report.warmUp == null) {
      final note = await _warmUpNote(
        'The plan left the camera cold for calibration',
      );
      report.warmUp = note.outcome;
      if (note.failed) report.problems.add(note.outcome);
      await _rig.notify('Camera warm-up', note.text);
    }
    await _rig.saveReport(report.toJson());
    return report;
  }

  /// Warm the camera a run left cold for a calibration step that then did not
  /// run, and tell the operator [why].
  Future<void> warmUpDeferredCamera(String why) async {
    await _rig.notify('Camera warm-up', (await _warmUpNote(why)).text);
  }

  /// Warm the camera up and say what happened, with [why] the warm-up was
  /// asked for. A cooler that was already off was never cold, so the note
  /// says only that.
  Future<({String outcome, String text, bool failed})> _warmUpNote(
    String why,
  ) async {
    try {
      final outcome = await _rig.warmUpCamera();
      final words = warmUpWords(outcome);
      return (
        outcome: words,
        text: outcome == CameraWarmupOutcome.coolerAlreadyOff
            ? '$words.'
            : '$why: $words.',
        failed: false,
      );
    } catch (e) {
      final words = 'Warming the camera up failed: $e';
      return (outcome: words, text: '$why: $words.', failed: true);
    }
  }

  void _finish(EonReport report, EonPhase phase, String summary) {
    report.finishedAt = _rig.now();
    report.summary = summary;
    Log.write(
      phase == EonPhase.failed ? LogLevel.warning : LogLevel.info,
      summary,
      source: _logSource,
    );
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
      sensorTempC: camera.sensorTempC,
      darkSlot: darkSlot,
    );
    final plannedText = [
      ...report.plannedDarks,
      '${config.biasCount} bias for each of ${needs.bias.length} '
          'gain/offset settings',
    ].join('; ');
    _set(EonPhase.capturing, 'Taking calibration frames', report);
    await _rig.notify('End-of-night calibration started', plannedText);

    // The slot the wheel was on before the darks, so it can be put back
    // however the run ends: a stopped run once left it on the dark slot and
    // the next night's centering frames were all taken through it.
    final filterBefore = darkSlot == null ? null : await _readFilterPosition();
    _runInFlight = true;
    final EonRunResult result;
    try {
      result = await _rig.runSequence(sequence);
    } finally {
      _runInFlight = false;
      if (darkSlot != null && filterBefore != null) {
        await _restoreFilter(filterBefore, darkSlot, report);
      }
    }
    // A stop ends the frames, not the night's calibration: the masters are
    // built from whatever was taken. A stop while they build ends that too.
    final stopped = _cancelRequested;
    _cancelRequested = false;
    report.runId = result.runId;
    report.runStatus = result.runStatus.token;
    if (result.runStatus != SequenceRunStatus.completed && !stopped) {
      report.problems.add(
        'The calibration run ${eonRunEndWords(result.runStatus)} before '
        'taking every frame',
      );
    }

    if ((config.warmUp || _forceWarmUp) && camera.canCool) {
      report.warmUp = await _attempt(
        report,
        'Warming the camera up',
        () async => warmUpWords(await _rig.warmUpCamera()),
      );
    }

    final frames = result.runId == null
        ? const <DbCapturedImage>[]
        : await _rig.framesOfRun(result.runId!);
    report.framesCaptured = frames.length;
    _set(EonPhase.buildingMasters, 'Building masters', report);
    await _buildMasters(
      frames,
      needs,
      config,
      report,
      toleranceC: await _rig.darkTemperatureToleranceC(),
    );

    if (_cancelRequested) return _cancelled(report);
    final built = report.masters.where((m) => m.built).length;
    final summary = StringBuffer(
      stopped
          ? 'Stopped after ${report.framesCaptured} frames. Built $built of '
                '${report.masters.length} masters from them into the dark '
                'library.'
          : 'Built $built of ${report.masters.length} masters from '
                '${report.framesCaptured} frames into the dark library.',
    );
    if (report.warmUp != null) summary.write(' ${report.warmUp}.');
    if (report.problems.isNotEmpty) {
      summary.write(' Problems: ${report.problems.join('; ')}.');
    }
    final failed = built == 0;
    _finish(
      report,
      stopped
          ? EonPhase.cancelled
          : failed
          ? EonPhase.failed
          : EonPhase.finished,
      summary.toString(),
    );
    await _rig.notify(
      stopped
          ? 'End-of-night calibration stopped'
          : failed
          ? 'End-of-night calibration built no masters'
          : 'End-of-night calibration finished',
      report.summary,
      problem: !stopped && (failed || report.problems.isNotEmpty),
    );
  }

  Future<int?> _readFilterPosition() async {
    try {
      return await _rig.filterPosition();
    } catch (_) {
      return null;
    }
  }

  /// Put the wheel back on [before] when the calibration run left it
  /// elsewhere. A failure is a problem in the report, not the end of the step.
  Future<void> _restoreFilter(
    int before,
    EonDarkSlot darkSlot,
    EonReport report,
  ) async {
    if (before == darkSlot.index) return;
    final now = await _readFilterPosition();
    if (now == before) return;
    final names = await _rig.filterNames().catchError((_) => null);
    final name = names != null && before < names.length
        ? '${names[before]} (position ${before + 1})'
        : 'position ${before + 1}';
    try {
      await _rig.moveFilter(before);
      report.filterRestored = 'Filter wheel put back on $name';
    } catch (e) {
      report.problems.add(
        'The filter wheel could not be put back on $name after the darks: $e',
      );
    }
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
      capDeadline: _rig.now().add(Duration(minutes: config.capWaitMinutes)),
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

  /// Build one master per [groupCalibrationFrames] group of the run's darks
  /// and bias: frame type, exposure, gain, offset, binning, read mode and the
  /// set-point each frame's header states. Frames read off their set-point
  /// are left out. Every master built and every group left unbuilt is logged
  /// and reported, with why.
  Future<void> _buildMasters(
    List<DbCapturedImage> frames,
    EonFrameNeeds needs,
    EonSettings config,
    EonReport report, {
    required double toleranceC,
  }) async {
    final read = <(DbCapturedImage, CalibrationFrameFacts)>[];
    final unread = <String>[];
    for (final frame in frames) {
      final type = frame.recordedFrameType;
      if (type != FrameType.dark && type != FrameType.bias) continue;
      try {
        final header = await _rig.frameHeader(frame.filePath);
        read.add((frame, CalibrationFrameFacts.fromHeader(header)));
      } catch (e) {
        unread.add('${p.basename(frame.filePath)}: $e');
      }
    }
    if (unread.isNotEmpty) {
      _problem(
        report,
        unread.length == 1
            ? '1 frame could not be read and was left out of the masters '
                  '(${unread.single})'
            : '${unread.length} frames could not be read and were left out '
                  'of the masters (${unread.first})',
      );
    }
    final groups = groupCalibrationFrames(read, toleranceC: toleranceC);
    for (final dark in needs.darks) {
      final taken = groups.any(
        (g) =>
            g.setting.type == FrameType.dark &&
            g.frames.isNotEmpty &&
            (g.setting.exposureSecs * 1000).round() ==
                (dark.exposureSecs * 1000).round() &&
            g.setting.gain == dark.gain &&
            g.setting.offset == dark.offset &&
            g.setting.binX == dark.binX &&
            g.setting.binY == dark.binY &&
            (g.setting.setPointC == null ||
                g.setting.setPointC == dark.setPointC),
      );
      if (!taken) _problem(report, 'No darks were taken for ${dark.label}');
    }
    final stamp = _stamp(report.startedAt);
    for (final (index, group) in groups.indexed) {
      if (_cancelRequested) return;
      final s = group.setting;
      final isBias = s.type == FrameType.bias;
      final type = s.type.record;
      final label = _groupLabel(group);
      final taken = group.frames.length + group.offSetPoint.length;
      if (group.offSetPoint.isNotEmpty) {
        _problem(
          report,
          '${group.offSetPoint.length} of the $taken $label read more than '
          '${_trimTemp(toleranceC)} °C from the set-point and were left out',
        );
      }
      if (taken < (isBias ? config.biasCount : config.darkCount)) {
        _problem(report, 'Only $taken frames were taken for the $label');
      }
      void unbuilt(String why) {
        Log.warning(
          'End-of-night calibration built no master for the $label: $why',
          source: _logSource,
        );
        report.masters.add(
          EonMasterOutcome(
            frameType: type,
            label: label,
            framesCaptured: taken,
            error: why,
          ),
        );
      }

      if (group.frames.length < 2) {
        unbuilt(
          group.offSetPoint.isEmpty
              ? 'a master needs at least 2 frames'
              : 'a master needs at least 2 frames at the set-point',
        );
        continue;
      }
      final readMode = s.readMode == null
          ? ''
          : '_${s.readMode!.replaceAll(RegExp(r'[^A-Za-z0-9-]'), '')}';
      final name =
          '${isBias ? 'MasterBias' : 'MasterDark_${_trim(s.exposureSecs)}s'}'
          '${s.gain == null ? '' : '_g${s.gain}'}'
          '${s.offset == null ? '' : '_o${s.offset}'}'
          '_${_tempTag(group.temperatureC)}_bin${s.binX}$readMode'
          '_$stamp.fits';
      final output = p.join(
        p.dirname(group.frames.first.filePath),
        'Masters',
        name,
      );
      final step =
          'Building master ${index + 1} of ${groups.length}: the $label, from '
          '${group.frames.length} frames';
      _set(EonPhase.buildingMasters, step, report);
      Log.info('End-of-night calibration: $step', source: _logSource);
      try {
        final built = await _rig.buildMaster(
          CalibrationMasterBuildRequest(
            kind: type,
            framePaths: [for (final f in group.frames) f.filePath],
            outputPath: output,
          ),
        );
        final id = await _rig.registerMaster(built, type);
        if (built.leakingFrames.isNotEmpty) {
          _problem(
            report,
            'Light leak: ${built.leakingFrames.length} of '
            '${group.frames.length} $label read brighter than the first '
            'frames and were left out',
          );
        }
        Log.info(
          'End-of-night calibration built the $label master from '
          '${built.frameCount} of $taken frames: ${built.outputPath}',
          source: _logSource,
        );
        report.masters.add(
          EonMasterOutcome(
            frameType: type,
            label: label,
            framesCaptured: taken,
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
        unbuilt(message);
      }
    }
  }

  static const _logSource = 'EndOfNightCalibration';

  /// Record [problem] in the report and the log.
  static void _problem(EonReport report, String problem) {
    report.problems.add(problem);
    Log.warning('End-of-night calibration: $problem', source: _logSource);
  }

  /// "3 s darks, gain 139, offset 21, bin 1x1, 1 °C", in the words the report
  /// and the log use for one master.
  static String _groupLabel(CalibrationFrameGroup group) {
    final s = group.setting;
    final temp = group.temperatureC;
    return [
      s.type == FrameType.bias ? 'bias' : '${_trim(s.exposureSecs)} s darks',
      gainOffsetLabel(s.gain, s.offset),
      'bin ${s.binX}x${s.binY}',
      if (s.readMode != null) 'read mode ${s.readMode}',
      if (temp != null)
        s.setPointC == null
            ? 'uncooled at ${_trimTemp(temp)} °C'
            : '${_trimTemp(temp)} °C',
    ].join(', ');
  }

  static String _trimTemp(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);

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

/// How a calibration run's recorded status reads in a sentence ("The
/// calibration run was stopped before taking every frame"); the status
/// itself (`paused-stopped`) is a record value, not words.
String eonRunEndWords(SequenceRunStatus runStatus) => switch (runStatus) {
  SequenceRunStatus.stopped ||
  SequenceRunStatus.stoppedResumable => 'was stopped',
  SequenceRunStatus.failed => 'failed',
  SequenceRunStatus.aborted => 'was ended',
  SequenceRunStatus.interrupted => 'was interrupted',
  SequenceRunStatus.completed ||
  SequenceRunStatus.running ||
  SequenceRunStatus.paused => 'ended',
};

/// What a warm-up did, as the report and the operator read it.
String warmUpWords(CameraWarmupOutcome outcome) => switch (outcome) {
  CameraWarmupOutcome.started => 'Camera warm-up started',
  CameraWarmupOutcome.coolerAlreadyOff => 'The cooler was already off',
  CameraWarmupOutcome.idleCoolerSwitchedOff =>
    'The cooler was idle and was switched off',
  CameraWarmupOutcome.canceled => 'Camera warm-up was canceled',
};
