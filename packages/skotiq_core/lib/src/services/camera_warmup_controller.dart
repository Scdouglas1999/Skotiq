import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/skotiq_backend.dart';
import '../backend/skotiq_exception.dart' show ConnectionException;
import '../models/equipment/equipment_models.dart';
import '../providers/capability_provider.dart';
import '../providers/equipment_provider.dart';
import '../providers/imaging_provider.dart' show coolingSettingsProvider;
import 'logging_service.dart';

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
/// Separate from `DeviceService` to isolate the periodic-timer state machine.
/// The controller owns its own cancellation flag and timer so the parent never
/// reaches into half-completed state during a backend swap or device-swap.
class CameraWarmupController {
  CameraWarmupController({required Ref ref, required SkotiqBackend backend})
    : _ref = ref,
      _backend = backend;

  final Ref _ref;
  final SkotiqBackend _backend;

  Timer? _timer;
  bool _cancelled = false;
  int _generation = 0;

  /// True while a warm-up timer is currently running.
  bool get isWarming => _timer != null;

  /// Begin a gradual warm-up. Throws if the camera is not connected or
  /// has no live device id. Any prior warm-up is cancelled first.
  Future<void> start({double ratePerMin = 2.0}) async {
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

    // Drop any in-flight warming before we touch state.
    cancel();
    final generation = ++_generation;

    final notifier = _ref.read(cameraStateProvider.notifier);
    notifier.setWarming(true);
    _cancelled = false;

    final currentTemp = cameraState.temperature ?? cameraState.targetTemp;

    const tickInterval = Duration(seconds: 10);
    final stepPerTick = ratePerMin / 6.0; // six 10-second ticks per minute
    var currentSetpoint = currentTemp;

    const maxWarmingDuration = Duration(minutes: 30);
    final warmingStartTime = DateTime.now();

    _log(
      (l) => l.info(
        'Starting gradual warm-up from ${currentTemp.toStringAsFixed(1)}°C '
        'at ${ratePerMin.toStringAsFixed(1)}°C/min (power-based stopping)',
      ),
    );

    // Keep cooler tracking, but seed the setpoint at the current sensor
    // temp so the cooler does not first work harder before easing off.
    try {
      await _backend.cameraSetCooling(
        deviceId: deviceId,
        enabled: true,
        targetTemp: currentSetpoint,
      );
    } catch (_) {
      // A failed seed command means no warm-up loop was started. Roll the
      // public state back instead of leaving every UI stuck on "Warming".
      if (_generation == generation) {
        notifier.setWarming(false);
        _cancelled = true;
      }
      rethrow;
    }

    // A second start/cancel may have superseded us while the driver command
    // was in flight. Never let this stale call install a fresh timer.
    if (_cancelled || _generation != generation) return;

    // One tick of the warm-up state machine. Returns true when warming is
    // finished (cooler disabled or unrecoverable) so the scheduler stops.
    //
    // Deliberately driven by a self-rescheduling one-shot Timer instead of
    // Timer.periodic: periodic ticks do not wait for the async body, so a
    // slow cameraSetCooling(enabled: true) from tick N could land AFTER
    // tick N+1 already disabled the cooler at the power threshold —
    // silently re-enabling the cooler with no timer left to turn it off.
    Future<bool> runTick() async {
      final state = _ref.read(cameraStateProvider);
      if (state.connectionState != DeviceConnectionState.connected) {
        _log((l) => l.warning('Warm-up stopped: camera disconnected'));
        return true;
      }
      if (state.deviceId != deviceId) {
        // Camera was swapped/reconnected under a different id mid-warmup;
        // the setpoints we are pushing would target the wrong device.
        _log(
          (l) => l.warning(
            'Warm-up stopped: camera device id changed '
            '($deviceId -> ${state.deviceId})',
          ),
        );
        return true;
      }

      final coolerPower = state.coolerPower;
      if (coolerPower != null && coolerPower <= 2.0) {
        try {
          await _backend.cameraSetCooling(deviceId: deviceId, enabled: false);
          if (_generation != generation) return true;
          notifier.setCooling(false);
          _ref.read(coolingSettingsProvider.notifier).state = _ref
              .read(coolingSettingsProvider)
              .copyWith(enabled: false);
          _log(
            (l) => l.info(
              'Warm-up complete. Cooler power reached '
              '${coolerPower.toStringAsFixed(0)}%, cooler disabled. '
              'Sensor: ${state.temperature?.toStringAsFixed(1) ?? "?"}°C',
            ),
          );
        } catch (e) {
          _log(
            (l) => l.error('Failed to disable cooler at end of warm-up: $e'),
          );
          // Keep the routine active and retry. Declaring completion here would
          // leave the physical cooler enabled with no owner left to stop it.
          return false;
        }
        return true;
      }

      if (DateTime.now().difference(warmingStartTime) > maxWarmingDuration) {
        try {
          await _backend.cameraSetCooling(deviceId: deviceId, enabled: false);
          if (_generation != generation) return true;
          notifier.setCooling(false);
          _ref.read(coolingSettingsProvider.notifier).state = _ref
              .read(coolingSettingsProvider)
              .copyWith(enabled: false);
          _log(
            (l) => l.warning(
              'Warm-up safety timeout (30 min). Cooler disabled at power '
              '${coolerPower?.toStringAsFixed(0) ?? "unknown"}%, sensor '
              '${state.temperature?.toStringAsFixed(1) ?? "?"}°C',
            ),
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
        await _backend.cameraSetCooling(
          deviceId: deviceId,
          enabled: true,
          targetTemp: currentSetpoint,
        );
        notifier.setTargetTemp(currentSetpoint);
      } catch (e) {
        _log(
          (l) => l.error(
            'Error during warm-up step '
            '(setpoint ${currentSetpoint.toStringAsFixed(1)}°C): $e',
          ),
        );
        // Don't cancel on transient errors - try again next tick
      }
      return false;
    }

    void scheduleNextTick() {
      _timer = Timer(tickInterval, () async {
        if (_cancelled || _generation != generation) {
          _timer = null;
          return;
        }
        bool finished;
        try {
          finished = await runTick();
        } on Object catch (e) {
          // A throwing tick must never silently kill the loop with the
          // cooler still enabled — log and retry next tick; the 30-minute
          // safety timeout above bounds the worst case.
          _log((l) => l.error('Warm-up tick failed: $e'));
          finished = false;
        }
        if (finished || _cancelled || _generation != generation) {
          _timer = null;
          if (_generation == generation) notifier.setWarming(false);
        } else {
          scheduleNextTick();
        }
      });
    }

    scheduleNextTick();
  }

  /// Cancel any in-progress warm-up. The cooler is left in whatever
  /// state it was in at the moment of cancellation (callers that need
  /// the cooler off should call `cameraSetCooling(enabled: false)`
  /// themselves).
  void cancel() {
    _generation++;
    _cancelled = true;
    _timer?.cancel();
    _timer = null;
    try {
      _ref.read(cameraStateProvider.notifier).setWarming(false);
    } on Object {
      // Notifier may be unavailable during teardown; warming-state
      // recovery is strictly cosmetic at that point.
    }
  }

  /// Dispose the controller. Currently identical to [cancel].
  void dispose() => cancel();

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
