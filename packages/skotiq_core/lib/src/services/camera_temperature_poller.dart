import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/network_backend.dart';
import '../backend/skotiq_backend.dart';
import '../models/imaging/imaging_models.dart' show CoolingStatus;
import '../providers/equipment_provider.dart';
import '../providers/imaging_provider.dart'
    show coolingStatusProvider, temperatureHistoryProvider;
import 'logging_service.dart';

/// Maximum absolute deviation, in degrees Celsius, between the live sensor
/// temperature and the cooling target at which the cooler is considered to
/// have reached its setpoint. A small band absorbs normal sensor jitter so the
/// "at target" indicator does not flicker once the camera has stabilised.
const double _atTargetToleranceC = 1.0;

/// Polls a connected camera's sensor temperature and cooler power on a
/// fixed cadence, pushing values into [cameraStateProvider] and
/// [temperatureHistoryProvider].
///
/// Separate from `DeviceService` so the polling lifecycle is owned by a
/// dedicated collaborator. The poller is started by
/// [DeviceService.connectCamera] and stopped by
/// [DeviceService.disconnectCamera] / `prepareForBackendSwap` /
/// `dispose`. A monotonic generation counter is used to ignore stale
/// timer ticks left over from a previous camera id, which is essential
/// when the user swaps cameras without explicitly disconnecting first.
class CameraTemperaturePoller {
  CameraTemperaturePoller({
    required Ref ref,
    required SkotiqBackend backend,
    Duration interval = const Duration(seconds: 5),
    Duration idleInterval = const Duration(seconds: 30),
  }) : _ref = ref,
       _backend = backend,
       _interval = interval,
       _idleInterval = idleInterval;

  final Ref _ref;
  final SkotiqBackend _backend;

  /// Poll cadence while the cooler is actively running — the sensor temperature
  /// is moving, so the UI wants frequent updates.
  final Duration _interval;

  /// Slower cadence while the cooler is off — with no active cooling the sensor
  /// only drifts slowly toward ambient, so frequent polling just spams the
  /// device bus (USB contention with the camera) and the debug log for no gain.
  final Duration _idleInterval;

  Timer? _timer;
  String? _connectedCameraId;
  int _generation = 0;

  /// Whether the last reading showed the cooler running. Drives the adaptive
  /// poll cadence; assumed true at start so the poller begins responsive and
  /// relaxes to [_idleInterval] only once it confirms the cooler is off.
  bool _coolerActive = true;

  /// Identifier of the camera currently being polled, if any.
  String? get connectedCameraId => _connectedCameraId;

  /// Begin polling [deviceId]. Cancels any in-progress polling first.
  void start(String deviceId) {
    _connectedCameraId = deviceId;
    final generation = ++_generation;
    _timer?.cancel();
    // Begin responsive (active cadence) until the first reading reports the
    // cooler state; thereafter [_pollThenReschedule] adapts the cadence.
    _coolerActive = true;
    // Poll immediately so the UI does not wait one tick for the first sample,
    // then schedule the next tick at the cadence matching the cooler state.
    unawaited(_pollThenReschedule(deviceId, generation));
  }

  /// Poll once, then — if still the active generation — schedule the next poll
  /// at [_interval] when the cooler is running or [_idleInterval] when it is
  /// off. A self-rescheduling timer (not [Timer.periodic]) so the cadence can
  /// change with the cooler state between ticks.
  Future<void> _pollThenReschedule(String deviceId, int generation) async {
    await _poll(deviceId, generation);
    if (_connectedCameraId != deviceId || _generation != generation) return;
    final delay = _coolerActive ? _interval : _idleInterval;
    _timer = Timer(delay, () => _pollThenReschedule(deviceId, generation));
  }

  /// Stop polling. Subsequent timer ticks (if any are mid-flight) are
  /// dropped by the generation guard.
  void stop() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _connectedCameraId = null;
  }

  /// Dispose the poller. Currently identical to [stop]; kept distinct so
  /// owners can call it from their own `dispose` hook unambiguously.
  void dispose() {
    stop();
  }

  Future<void> _poll(String deviceId, int generation) async {
    if (_connectedCameraId != deviceId || _generation != generation) {
      return;
    }
    // Auth-rejected host: every request can only 403 and the transport
    // already fails them fast — polling anyway would just write an
    // identical warning to the log every 5 s until the operator re-pairs.
    // Ticks keep rescheduling (each becomes a cheap flag check) so polling
    // resumes on its own once a reconnect clears the latch.
    final backend = _backend;
    if (backend is NetworkBackend && backend.isAuthTokenRejected) return;

    try {
      final status = await _backend.getCameraStatus(deviceId);
      if (_connectedCameraId != deviceId || _generation != generation) {
        return;
      }

      final temp = status.sensorTemp;
      final power = status.coolerPower;
      final targetTemp = status.targetTemp;

      try {
        final logger = _ref.read(loggingServiceProvider);
        logger.debug(
          'Camera temp: ${temp?.toStringAsFixed(1) ?? "null"}°C, '
          'power: ${power?.toStringAsFixed(0) ?? "null"}%, '
          'target: ${targetTemp?.toStringAsFixed(1) ?? "null"}°C',
          source: 'CameraTemperaturePoller',
        );
      } on Object catch (e) {
        // Why: logger lookup happens inside a temperature poll tick; if the
        // logging service itself is mid-disposal we must not propagate up the
        // poll loop. Diagnostic-only failure — emit to stderr so it isn't
        // fully silent.
        // ignore: avoid_print
        print('CameraTemperaturePoller: temp-log emission failed: $e');
      }

      if (temp != null) {
        _ref.read(cameraStateProvider.notifier).updateTemperature(temp, power);
        _ref.read(cameraStateProvider.notifier).setCooling(status.coolerOn);

        _ref
            .read(temperatureHistoryProvider.notifier)
            .addPoint(temp, targetTemp: targetTemp, coolerPower: power);

        // Publish a live cooling snapshot derived from this reading. We only
        // do this inside the `temp != null` branch: with no live sensor value
        // we have nothing to report and must not fabricate a "cooling" state
        // (errors-are-a-feature — a silent default would mask a stalled or
        // disconnected cooler). The target temperature comes from the status
        // when the driver reports one; otherwise we fall back to the
        // user-configured setpoint held in camera state so the UI can still
        // show what the camera is being asked to reach.
        final effectiveTarget =
            targetTemp ?? _ref.read(cameraStateProvider).targetTemp;
        final coolerPower = power ?? 0.0;
        // Cooler power is duty cycle, not the on/off authority. A regulated
        // cooler legitimately reports 0% while holding its target, and some
        // drivers do not expose power at all. CameraStatus.coolerOn is the
        // authoritative state on both FFI and remote backends.
        final isCooling = status.coolerOn;
        // Drive the adaptive poll cadence: frequent while cooling, relaxed when
        // the cooler is off. (Only updated on a real reading; a null/errored
        // poll leaves the cadence unchanged.)
        _coolerActive = isCooling;
        final isAtTarget =
            isCooling && (temp - effectiveTarget).abs() <= _atTargetToleranceC;

        _ref.read(coolingStatusProvider.notifier).state = CoolingStatus(
          currentTemp: temp,
          targetTemp: effectiveTarget,
          coolerPower: coolerPower,
          isCooling: isCooling,
          isAtTarget: isAtTarget,
        );
      }
    } catch (e) {
      if (_connectedCameraId != deviceId || _generation != generation) {
        return;
      }
      try {
        final logger = _ref.read(loggingServiceProvider);
        logger.warning(
          'Temperature polling error: $e',
          source: 'CameraTemperaturePoller',
        );
      } on Object catch (loggerErr) {
        // Why: nested catch around logger emission during the poll-loop's
        // error path. If the logging provider is itself disposing we must
        // not re-throw — that would mask the original temperature-polling
        // failure. Surface to stderr so it isn't fully silent.
        // ignore: avoid_print
        print(
          'CameraTemperaturePoller: warn-log emission failed: '
          '$loggerErr (original temp-poll error: $e)',
        );
      }
    }
  }
}
