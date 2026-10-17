import 'dart:async';
import 'dart:math' as math;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' show PlateSolveResult;
import '../backend/roles/device_backend.dart';
import 'plate_solve_service.dart';
import 'imaging_service.dart';
import 'device_service.dart';
import 'smart_notification_service.dart';
import '../providers/backend_provider.dart';
import '../providers/constellation_provider.dart'
    show coImagingSessionServiceProvider;
import '../providers/equipment_provider.dart';
import '../providers/imaging_provider.dart' show exposureSettingsProvider;
import '../providers/current_screen_provider.dart';
import 'logging_service.dart' show loggingServiceProvider;
import '../models/imaging/imaging_models.dart';
import '../models/equipment/equipment_models.dart';
part 'centering_service/centering_models.dart';
part 'centering_service/centering_loop.dart';
part 'centering_service/slew_settle.dart';
part 'centering_service/centering_geometry.dart';

/// Service for automated target centering using plate solving
class CenteringService {
  final Ref _ref;
  final DeviceBackend _backend;

  /// Interval between mount-status polls during post-slew settle.
  ///
  /// 500ms keeps UI status reasonably fresh without hammering the bridge.
  static const Duration _defaultPollInterval = Duration(milliseconds: 500);

  /// Upper bound (in ticks) on the post-slew settle wait. 120 × 500ms = 60s
  /// — preserves the existing wall-clock budget for slow-but-working mounts.
  static const int _defaultMaxPollTicks = 120;

  /// Maximum number of consecutive `getMountStatus` failures tolerated
  /// during the settle poll before aborting centering with a typed
  /// [CenteringMountUnresponsiveException].
  ///
  /// 6 ticks × [_pollInterval] = 3 seconds of unbroken failure. A single
  /// transient blip (e.g. one missed COM frame, INDI reconnect) recovers on
  /// the next tick and never trips this threshold; a permanently-broken
  /// mount fails fast at 3s rather than dragging out the full 60s timeout.
  static const int _maxConsecutiveQueryFailures = 6;

  final Duration _pollInterval;
  final int _maxPollTicks;

  // Flag flipped by [stop]; checked at every centering loop yield-point so the
  // user-visible Abort path returns promptly and the post-stop status is
  // explicit ("aborted") rather than ambiguous.
  bool _abortRequested = false;
  bool _isRunning = false;
  bool _retired = false;
  bool _captureInFlight = false;
  bool _slewInFlight = false;
  Future<void>? _stopFuture;
  ImagingService? _ownedImagingService;
  DeviceService? _ownedDeviceService;

  CenteringService(
    this._ref, {
    DeviceBackend? backend,
    Duration slewPollInterval = _defaultPollInterval,
    int maxSlewPollTicks = _defaultMaxPollTicks,
  }) : _backend = backend ?? _ref.read(deviceBackendProvider),
       _pollInterval = slewPollInterval,
       _maxPollTicks = maxSlewPollTicks;

  /// True while a centering run has been asked to stop but hasn't returned yet.
  bool get isAborting => _abortRequested;

  /// True until the active centering owner's Future has fully settled.
  bool get isRunning => _isRunning;

  /// Abort the current centering run.
  ///
  /// Cancels the in-flight exposure (so the camera doesn't sit idle for the
  /// remainder of [CenteringConfig.exposureTime]) and aborts any in-progress
  /// mount slew, then sets the abort flag that the centering loop polls. The
  /// loop returns a [CenteringResult.failure] with `errorMessage: 'Aborted'`.
  ///
  /// Safe to call when no run is active. Only hardware currently owned by this
  /// service is interrupted, so an idle stop cannot cancel an unrelated camera
  /// exposure or mount slew.
  Future<void> stop() async {
    if (!_isRunning) return;
    _abortRequested = true;

    final existing = _stopFuture;
    if (existing != null) {
      await existing;
      return;
    }

    final operation = _stopOwnedHardware();
    _stopFuture = operation;
    await operation;
  }

  /// Retire this service when its backend changes. Any old-host work keeps
  /// unwinding against the services captured at admission and cannot abort or
  /// slew hardware on the replacement host.
  void retire() {
    if (_retired) return;
    _retired = true;
    if (!_isRunning) return;
    _abortRequested = true;
    unawaited(_stopOwnedHardware().catchError((_) {}));
  }

  /// Center on target coordinates with iterative plate solve and slew
  ///
  /// Returns a [CenteringResult] with success status and iteration history
  Future<CenteringResult> centerOnTarget({
    required double targetRa,
    required double targetDec,
    required PlateSolverConfig solverConfig,
    CenteringConfig config = const CenteringConfig(),
    void Function(CenteringStatus)? onStatusUpdate,
  }) async {
    final validationError = _validateRequest(
      targetRa: targetRa,
      targetDec: targetDec,
      solverConfig: solverConfig,
      config: config,
    );
    if (validationError != null) {
      return CenteringResult.failure(
        errorMessage: validationError,
        iterations: 0,
        iterationHistory: const [],
      );
    }

    if (_isRunning) {
      return CenteringResult.failure(
        errorMessage: 'Another centering operation is already running',
        iterations: 0,
        iterationHistory: const [],
      );
    }

    _isRunning = true;
    _abortRequested = false;
    final workFuture = _runCentering(
      targetRa: targetRa,
      targetDec: targetDec,
      solverConfig: solverConfig,
      config: config,
      onStatusUpdate: onStatusUpdate,
    );
    try {
      return await workFuture.timeout(
        config.overallTimeout,
        onTimeout: () async {
          await stop();
          CenteringResult? settledResult;
          try {
            settledResult = await workFuture;
          } catch (_) {
            // The timeout remains the user-facing terminal reason. Waiting for
            // the owner Future here is about hardware settlement, not replacing
            // it with a secondary cancellation exception.
          }
          return CenteringResult.failure(
            errorMessage:
                'Centering timed out after ${config.overallTimeout.inSeconds} seconds',
            iterations: settledResult?.iterations ?? 0,
            iterationHistory:
                settledResult?.iterationHistory ?? const <CenteringIteration>[],
          );
        },
      );
    } finally {
      final stopFuture = _stopFuture;
      try {
        if (stopFuture != null) {
          await stopFuture;
        }
      } finally {
        _isRunning = false;
        _abortRequested = false;
        _captureInFlight = false;
        _slewInFlight = false;
        _stopFuture = null;
        _ownedImagingService = null;
        _ownedDeviceService = null;
      }
    }
  }
}

/// Provider for the centering service
final centeringServiceProvider = Provider<CenteringService>((ref) {
  final backend = ref.watch(deviceBackendProvider);
  final service = CenteringService(
    ref,
    backend: backend,
    slewPollInterval: ref.watch(centeringSlewPollIntervalProvider),
    maxSlewPollTicks: ref.watch(centeringSlewMaxPollTicksProvider),
  );
  ref.onDispose(service.retire);
  return service;
});

/// Timing seams used by deterministic centering lifecycle tests.
final centeringSlewPollIntervalProvider = Provider<Duration>(
  (ref) => const Duration(milliseconds: 500),
);
final centeringSlewMaxPollTicksProvider = Provider<int>((ref) => 120);

/// Provider for centering status
final centeringStatusProvider = StateProvider<CenteringStatus>((ref) {
  return CenteringStatus.idle();
});

/// Provider for last centering result
final lastCenteringResultProvider = StateProvider<CenteringResult?>(
  (ref) => null,
);
