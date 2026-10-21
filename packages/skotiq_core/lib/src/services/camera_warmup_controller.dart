import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/skotiq_backend.dart';
import '../backend/skotiq_exception.dart'
    show ConnectionException, DeviceBusyException;
import '../models/equipment/equipment_models.dart';
import '../models/sequence/sequence_models.dart'
    show SequenceExecutionStateCapabilities;
import '../providers/capability_provider.dart';
import '../providers/equipment_provider.dart';
import '../providers/imaging_provider.dart' show coolingSettingsProvider;
import '../providers/sequence/sequence_progress.dart'
    show sequenceExecutionStateProvider;
import 'logging_service.dart';

/// What a call to [CameraWarmupController.start] did.
enum CameraWarmupOutcome {
  /// A gradual warm-up is now running.
  started,

  /// The cooler was already off; no command was sent.
  coolerAlreadyOff,

  /// The cooler was on but doing no work (sensor at ambient), so it was
  /// switched off at once.
  idleCoolerSwitchedOff,

  /// Canceled before it changed anything.
  canceled,
}

/// Cooler power, in percent, at or below which the cooler is doing no work.
const double _idleCoolerPowerPercent = 2.0;

/// The longest a single driver call may take before the warm-up treats it as
/// failed and carries on.
const Duration _driverCallTimeout = Duration(seconds: 20);

/// Drives the gradual camera warm-up routine.
///
/// Warming a cooled astrophotography sensor requires stepping the target
/// temperature up slowly to avoid thermal shock and condensation. The
/// algorithm is deliberately NOT temperature-aware: we keep raising the
/// setpoint until the cooler's PID loop reports near-zero power, then
/// disable the cooler. A temperature-based stopping condition would
/// stall in cold-ambient conditions where the cooler power hits zero
/// well before the sensor reaches an arbitrary target temperature.
///
/// Rules this controller keeps:
/// * A cooler that is off is never switched on, and one doing no work is
///   switched straight off: there is nothing to warm.
/// * A sequence run that owns the hardware owns the cooler; a manual warm-up
///   is refused while one does, and one already running stops if a run takes
///   over.
/// * A canceled warm-up never leaves the cooler at a set-point it seeded:
///   unless the caller is about to send its own cooler command, the set-point
///   the cooler held before the warm-up is put back.
/// * Every driver call is bounded by [_driverCallTimeout], so one that never
///   answers cannot stall the loop past its 30-minute safety limit.
class CameraWarmupController {
  CameraWarmupController({required Ref ref, required SkotiqBackend backend})
    : _ref = ref,
      _backend = backend;

  final Ref _ref;
  final SkotiqBackend _backend;

  _WarmupRun? _run;

  /// True while a warm-up is in progress.
  bool get isWarming => _run != null;

  /// Begin a gradual warm-up, or report why there is nothing to warm.
  ///
  /// Throws if the camera is not connected, has no live device id, or a
  /// sequence run currently owns the hardware. Any prior warm-up is superseded
  /// first, leaving the cooler where it is for this one to take over.
  Future<CameraWarmupOutcome> start({double ratePerMin = 2.0}) async {
    if (!ratePerMin.isFinite || ratePerMin <= 0) {
      throw ArgumentError.value(
        ratePerMin,
        'ratePerMin',
        'Warm-up rate must be a finite positive value',
      );
    }

    final cameraState = _ref.read(cameraStateProvider);
    if (cameraState.connectionState != DeviceConnectionState.connected) {
      throw const ConnectionException(
        message: 'Camera not connected',
        userMessage: 'The camera is not connected',
      );
    }

    final deviceId = cameraState.deviceId;
    if (deviceId == null || deviceId.isEmpty) {
      throw const ConnectionException(
        message: 'No camera device ID available',
        userMessage: 'The camera device is not available',
      );
    }

    if (_runOwnsHardware()) {
      throw DeviceBusyException(
        message: 'A sequence run owns the camera cooler',
        userMessage:
            'The running sequence controls the camera cooler. Stop the run '
            'before warming the camera by hand.',
        deviceId: deviceId,
      );
    }

    cancel(restorePriorSetting: false);
    final run = _WarmupRun(deviceId);
    _run = run;
    final notifier = _ref.read(cameraStateProvider.notifier);
    notifier.setWarming(true);

    void finishEarly() {
      if (!identical(_run, run)) return;
      _end(run);
      notifier.setWarming(false);
    }

    final status = await _readStatus(deviceId);
    if (run.canceled) return CameraWarmupOutcome.canceled;

    final coolerOn = status?.coolerOn ?? cameraState.isCooling;
    final coolerPower = status?.coolerPower ?? cameraState.coolerPower;
    final sensorTemp = status?.sensorTemp ?? cameraState.temperature;
    final tempText = sensorTemp?.toStringAsFixed(1) ?? '?';

    if (!coolerOn) {
      finishEarly();
      notifier.setCooling(false);
      _log(
        (l) => l.info(
          'Warm-up not needed: the cooler is already off '
          '(sensor $tempText°C), nothing to warm',
        ),
      );
      return CameraWarmupOutcome.coolerAlreadyOff;
    }

    if (coolerPower != null && coolerPower <= _idleCoolerPowerPercent) {
      try {
        await _bounded(
          _backend.cameraSetCooling(deviceId: deviceId, enabled: false),
        );
      } finally {
        finishEarly();
      }
      _markCoolerOff();
      _log(
        (l) => l.info(
          'Warm-up not needed: the cooler was idle '
          '(${coolerPower.toStringAsFixed(0)}% power, sensor $tempText°C) '
          'and is now off',
        ),
      );
      return CameraWarmupOutcome.idleCoolerSwitchedOff;
    }

    run.priorSetpoint = status?.targetTemp ?? cameraState.targetTemp;
    final startTemp = sensorTemp ?? run.priorSetpoint!;
    var currentSetpoint = startTemp;
    const tickInterval = Duration(seconds: 10);
    final stepPerTick = ratePerMin / 6.0; // six 10-second ticks per minute
    const maxWarmingDuration = Duration(minutes: 30);

    _log(
      (l) => l.info(
        'Starting gradual warm-up from ${startTemp.toStringAsFixed(1)}°C '
        'at ${ratePerMin.toStringAsFixed(1)}°C/min (power-based stopping); '
        'the cooler was holding '
        '${run.priorSetpoint!.toStringAsFixed(1)}°C',
      ),
    );

    // Seed the setpoint at the current sensor temperature so the cooler does
    // not first work harder before easing off.
    try {
      await _command(run, enabled: true, targetTemp: currentSetpoint);
    } catch (_) {
      // A failed seed command means no warm-up loop was started. Roll the
      // public state back instead of leaving every UI stuck on "Warming".
      finishEarly();
      rethrow;
    }
    if (run.canceled) return CameraWarmupOutcome.canceled;

    Future<void> disableCooler(String Function(double?) describe) async {
      final power = run.lastPower;
      await _command(run, enabled: false);
      if (run.canceled) return;
      _markCoolerOff();
      _log((l) => l.info(describe(power)));
    }

    // One tick of the warm-up state machine. Returns true when warming is
    // finished so the scheduler stops.
    //
    // Driven by a self-rescheduling one-shot Timer instead of Timer.periodic:
    // periodic ticks do not wait for the async body, so a slow set-point
    // command from tick N could land AFTER tick N+1 already disabled the
    // cooler, silently re-enabling it with no timer left to turn it off.
    Future<bool> runTick() async {
      final state = _ref.read(cameraStateProvider);
      if (state.connectionState != DeviceConnectionState.connected) {
        _log((l) => l.warning('Warm-up stopped: camera disconnected'));
        return true;
      }
      if (state.deviceId != deviceId) {
        // The camera was swapped or reconnected under a different id; the
        // set-points we are pushing would target the wrong device.
        _log(
          (l) => l.warning(
            'Warm-up stopped: camera device id changed '
            '($deviceId -> ${state.deviceId})',
          ),
        );
        return true;
      }
      if (_runOwnsHardware()) {
        _log(
          (l) => l.warning(
            'Warm-up stopped: a sequence run took over the camera; the '
            'cooler is left to the run',
          ),
        );
        return true;
      }

      final live = await _readStatus(deviceId);
      if (run.canceled) return true;
      if (live != null && !live.coolerOn) {
        _markCoolerOff();
        _log(
          (l) => l.info(
            'Warm-up ended: the cooler was switched off by another command '
            '(sensor ${live.sensorTemp?.toStringAsFixed(1) ?? "?"}°C)',
          ),
        );
        return true;
      }
      final coolerPower = live?.coolerPower ?? state.coolerPower;
      final temp = live?.sensorTemp ?? state.temperature;
      run.lastPower = coolerPower;

      if (coolerPower != null && coolerPower <= _idleCoolerPowerPercent) {
        try {
          await disableCooler(
            (power) =>
                'Warm-up complete. Cooler power reached '
                '${power?.toStringAsFixed(0) ?? "?"}%, cooler disabled. '
                'Sensor: ${temp?.toStringAsFixed(1) ?? "?"}°C',
          );
        } catch (e) {
          _log(
            (l) => l.error('Failed to disable cooler at end of warm-up: $e'),
          );
          // Keep the routine active and retry. Declaring completion here
          // would leave the physical cooler enabled with no owner to stop it.
          return false;
        }
        return true;
      }

      if (run.deadlinePassed) {
        try {
          await disableCooler(
            (power) =>
                'Warm-up safety timeout (30 min). Cooler disabled at power '
                '${power?.toStringAsFixed(0) ?? "unknown"}%, sensor '
                '${temp?.toStringAsFixed(1) ?? "?"}°C',
          );
        } catch (e) {
          _log(
            (l) =>
                l.error('Failed to disable cooler after warm-up timeout: $e'),
          );
          return false;
        }
        return true;
      }

      final reportedMax = _ref
          .read(cameraCapabilitiesProvider(deviceId))
          .valueOrNull
          ?.coolerMaxTempC;
      final maximumSetpoint = reportedMax != null && reportedMax.isFinite
          ? reportedMax
          : 20.0;
      currentSetpoint = (currentSetpoint + stepPerTick)
          .clamp(double.negativeInfinity, maximumSetpoint)
          .toDouble();
      try {
        await _command(run, enabled: true, targetTemp: currentSetpoint);
        if (!run.canceled) notifier.setTargetTemp(currentSetpoint);
      } catch (e) {
        _log(
          (l) => l.error(
            'Error during warm-up step '
            '(setpoint ${currentSetpoint.toStringAsFixed(1)}°C): $e',
          ),
        );
        // Not fatal: the next tick tries again, and the 30-minute safety
        // limit bounds the worst case.
      }
      return false;
    }

    void scheduleNextTick() {
      run.timer = Timer(tickInterval, () async {
        if (run.canceled) return;
        bool finished;
        try {
          finished = await runTick();
        } on Object catch (e) {
          // A throwing tick must never silently kill the loop with the
          // cooler still enabled: log and retry next tick; the 30-minute
          // safety limit bounds the worst case.
          _log((l) => l.error('Warm-up tick failed: $e'));
          finished = false;
        }
        if (run.canceled) return;
        if (finished) {
          _end(run);
          notifier.setWarming(false);
        } else {
          scheduleNextTick();
        }
      });
    }

    run.deadline = Timer(maxWarmingDuration, () => run.deadlinePassed = true);
    scheduleNextTick();
    return CameraWarmupOutcome.started;
  }

  /// Cancel any in-progress warm-up.
  ///
  /// With [restorePriorSetting] (an operator's explicit cancel) the cooler is
  /// put back to the set-point it held before the warm-up began, once any
  /// in-flight command has landed. Callers that send their own cooler command
  /// right after (cooler off, a new set-point, a disconnect) pass false and the
  /// cooler is left where the ramp reached. Either way the outcome is logged.
  void cancel({bool restorePriorSetting = true}) {
    final run = _run;
    if (run == null) return;
    run.canceled = true;
    run.restoreRequested = restorePriorSetting;
    run.timer?.cancel();
    run.deadline?.cancel();
    _run = null;
    try {
      _ref.read(cameraStateProvider.notifier).setWarming(false);
    } on Object {
      // Notifier may be unavailable during teardown; warming-state recovery
      // is strictly cosmetic at that point.
    }
    if (run.inFlight == 0) _settleCanceled(run);
  }

  /// Dispose the controller: stop the warm-up without sending any command.
  void dispose() => cancel(restorePriorSetting: false);

  bool _runOwnsHardware() {
    try {
      return _ref.read(sequenceExecutionStateProvider).ownsHardware;
    } on Object {
      return false;
    }
  }

  /// Finish a run that ended on its own (not canceled).
  void _end(_WarmupRun run) {
    run.timer?.cancel();
    run.deadline?.cancel();
    if (identical(_run, run)) _run = null;
  }

  void _markCoolerOff() {
    _ref.read(cameraStateProvider.notifier).setCooling(false);
    _ref.read(coolingSettingsProvider.notifier).state = _ref
        .read(coolingSettingsProvider)
        .copyWith(enabled: false);
  }

  Future<CameraStatus?> _readStatus(String deviceId) async {
    try {
      return await _bounded(_backend.getCameraStatus(deviceId));
    } on Object catch (e) {
      _log((l) => l.warning('Warm-up could not read camera status: $e'));
      return null;
    }
  }

  /// Send one cooler command on behalf of [run]. When the run was canceled
  /// while the command was in flight, the cancel is settled after it lands so
  /// a late set-point cannot outlive the restore.
  Future<void> _command(
    _WarmupRun run, {
    required bool enabled,
    double? targetTemp,
  }) async {
    run.inFlight++;
    try {
      await _bounded(
        _backend.cameraSetCooling(
          deviceId: run.deviceId,
          enabled: enabled,
          targetTemp: targetTemp,
        ),
      );
      if (enabled) run.seeded = true;
    } finally {
      run.inFlight--;
      if (run.canceled && run.inFlight == 0) _settleCanceled(run);
    }
  }

  void _settleCanceled(_WarmupRun run) {
    if (run.settled) return;
    run.settled = true;
    final prior = run.priorSetpoint;
    if (!run.seeded || prior == null) {
      _log((l) => l.info('Warm-up canceled before it changed the cooler'));
      return;
    }
    if (!run.restoreRequested) {
      _log(
        (l) => l.info(
          'Warm-up canceled; the cooler is left for the next cooler command',
        ),
      );
      return;
    }
    unawaited(_restorePrior(run.deviceId, prior));
  }

  Future<void> _restorePrior(String deviceId, double prior) async {
    try {
      await _bounded(
        _backend.cameraSetCooling(
          deviceId: deviceId,
          enabled: true,
          targetTemp: prior,
        ),
      );
      try {
        _ref.read(cameraStateProvider.notifier).setTargetTemp(prior);
      } on Object {
        // Teardown; the log line below is what matters.
      }
      _log(
        (l) => l.info(
          'Warm-up canceled; the cooler is back at the '
          '${prior.toStringAsFixed(1)}°C it held before',
        ),
      );
    } on Object catch (e) {
      _log(
        (l) => l.error(
          'Warm-up canceled, but putting the cooler back to '
          '${prior.toStringAsFixed(1)}°C failed: $e. The cooler is still on '
          'at the warm-up set-point.',
        ),
      );
    }
  }

  Future<T> _bounded<T>(Future<T> call) => call.timeout(
    _driverCallTimeout,
    onTimeout: () => throw TimeoutException(
      'The camera driver did not answer within '
      '${_driverCallTimeout.inSeconds} s',
    ),
  );

  void _log(void Function(LoggingService logger) emit) {
    try {
      final logger = _ref.read(loggingServiceProvider);
      emit(logger);
    } on Object catch (loggerErr) {
      // Diagnostic-only path; never let logger emission failures mask
      // a higher-priority cooling fault.
      // ignore: avoid_print
      print('CameraWarmupController: logger emission failed: $loggerErr');
    }
  }
}

/// One warm-up from start to its end or cancel.
class _WarmupRun {
  _WarmupRun(this.deviceId);

  final String deviceId;
  Timer? timer;

  /// Fires once the warm-up has run for its safety limit.
  Timer? deadline;
  bool deadlinePassed = false;
  bool canceled = false;
  bool restoreRequested = false;
  bool settled = false;

  /// True once a cooler-on command from this run has landed.
  bool seeded = false;
  int inFlight = 0;
  double? priorSetpoint;
  double? lastPower;
}
