import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart'
    show
        ApiCenteringRequest,
        ApiCenteringStep,
        ApiCenteringStep_Capturing,
        ApiCenteringStep_Correcting,
        ApiCenteringStep_Finished,
        ApiCenteringStep_Solved,
        apiCancelCentering,
        apiCenterOnTarget;
import '../backend/remote_host.dart';
import '../models/app_screen.dart';
import '../models/equipment/equipment_models.dart' show DeviceConnectionState;
import '../providers/constellation_provider.dart'
    show coImagingSessionServiceProvider;
import '../providers/equipment_provider.dart';
import '../providers/logging_service_provider.dart';
import '../providers/smart_notification_service_provider.dart';
part 'centering_service/centering_models.dart';

/// Where a centering runs: the sequence's Center step in this process's
/// native sequencer, or the linked host's centering.
abstract interface class CenteringRunner {
  /// The run's steps, the last always [ApiCenteringStep_Finished].
  Stream<ApiCenteringStep> center(ApiCenteringRequest request);

  /// Stops the run in progress.
  Future<void> cancel();
}

/// The Center step of this process's native sequencer.
final class NativeCenteringRunner implements CenteringRunner {
  const NativeCenteringRunner();

  @override
  Stream<ApiCenteringStep> center(ApiCenteringRequest request) =>
      apiCenterOnTarget(request: request);

  @override
  Future<void> cancel() async => apiCancelCentering();
}

/// The linked host's centering: the host runs its Center step and answers
/// with the attempts it solved and how it ended.
final class HostCenteringRunner implements CenteringRunner {
  HostCenteringRunner(this._host);

  final HostPointing _host;
  String? _jobId;

  @override
  Stream<ApiCenteringStep> center(ApiCenteringRequest request) async* {
    final jobId = await _host.startCentering(
      raHours: request.raHours,
      decDegrees: request.decDegrees,
      maxAttempts: request.maxAttempts,
      accuracyArcsec: request.accuracyArcsec,
      exposureSecs: request.exposureSecs,
      syncMount: request.syncMount,
    );
    _jobId = jobId;
    try {
      final job = await _host.awaitJobCompletion(
        jobId,
        timeout: const Duration(minutes: 10),
        pollInterval: const Duration(seconds: 1),
      );
      final outcome = job.result ?? job.error?['details'];
      for (final attempt
          in (outcome is Map ? outcome['iterationHistory'] : null)
                  as List<dynamic>? ??
              const []) {
        if (attempt case {
          'iterationNumber': final int number,
          'solvedRa': final num ra,
          'solvedDec': final num dec,
          'offsetArcsec': final num separation,
        }) {
          yield ApiCenteringStep.solved(
            attempt: number,
            raHours: ra.toDouble(),
            decDegrees: dec.toDouble(),
            separationArcsec: separation.toDouble(),
          );
        }
      }
      yield ApiCenteringStep.finished(
        centered: job.state == 'succeeded',
        cancelled: job.state == 'cancelled',
        message: switch (job.state) {
          'succeeded' => 'Centered on the imaging host',
          'cancelled' => 'Centering stopped',
          _ =>
            job.error?['message'] as String? ??
                'Centering did not reach the target.',
        },
      );
    } finally {
      _jobId = null;
    }
  }

  @override
  Future<void> cancel() async {
    final jobId = _jobId;
    if (jobId != null) await _host.cancelJob(jobId);
  }
}

/// Centering on a target by hand (Slew & center, the centering dialog, the
/// Go to panel, a client's center request), run by the sequence's Center
/// step, so the guider is stopped for the move, the frames take the camera's
/// stated defaults and the solves search near the target as they do in a run.
class CenteringService {
  CenteringService(this._ref, {CenteringRunner? runner})
    : _runner = runner ?? const NativeCenteringRunner();

  final Ref _ref;
  final CenteringRunner _runner;

  bool _abortRequested = false;
  bool _isRunning = false;
  bool _retired = false;

  /// True while a centering run has been asked to stop but hasn't returned yet.
  bool get isAborting => _abortRequested;

  /// True until the active centering run has ended.
  bool get isRunning => _isRunning;

  /// Stops the centering run: the exposure or slew under way is aborted and
  /// the run ends as aborted. Safe to call when no run is active.
  Future<void> stop() async {
    if (!_isRunning || _abortRequested) return;
    _abortRequested = true;
    await _runner.cancel();
  }

  /// Retire this service when its backend changes: a run still in progress
  /// is stopped.
  void retire() {
    if (_retired) return;
    _retired = true;
    if (_isRunning) unawaited(stop());
  }

  /// Center on target coordinates (RA hours, Dec degrees, J2000).
  Future<CenteringResult> centerOnTarget({
    required double targetRa,
    required double targetDec,
    CenteringConfig config = const CenteringConfig(),
    void Function(CenteringStatus)? onStatusUpdate,
  }) async {
    final refusal = _refusal(targetRa, targetDec, config);
    if (refusal != null) return _failure(refusal, const []);
    if (_isRunning) {
      return _failure(
        'Another centering operation is already running',
        const [],
      );
    }

    _isRunning = true;
    _abortRequested = false;
    try {
      final framed = await _coImagingFramedTarget(targetRa, targetDec);
      if (_abortRequested) return _failure('Aborted by user', const []);
      final result = await _run(
        framed?.raHours ?? targetRa,
        framed?.decDeg ?? targetDec,
        config,
        onStatusUpdate,
      );
      _logOutcome(result, config);
      return result;
    } finally {
      _isRunning = false;
      _abortRequested = false;
    }
  }

  Future<CenteringResult> _run(
    double targetRa,
    double targetDec,
    CenteringConfig config,
    void Function(CenteringStatus)? onStatusUpdate,
  ) async {
    final mount = _ref.read(mountStateProvider);
    final camera = _ref.read(cameraStateProvider);
    final mountId = mount.deviceId;
    final cameraId = camera.deviceId;
    if (mountId == null ||
        mount.connectionState != DeviceConnectionState.connected) {
      return _failure('Mount not connected', const []);
    }
    if (cameraId == null ||
        camera.connectionState != DeviceConnectionState.connected) {
      return _failure('Camera not connected', const []);
    }

    final iterations = <CenteringIteration>[];
    void report(
      CenteringState state,
      int attempt,
      String message, {
      CenteringIteration? solved,
    }) => onStatusUpdate?.call(
      CenteringStatus(
        state: state,
        currentIteration: attempt,
        maxIterations: config.maxIterations,
        currentOffsetArcsec: solved?.offsetArcsec,
        currentOffsetArcmin: solved?.offsetArcmin,
        message: message,
        iterationHistory: List.unmodifiable(iterations),
        solvedRa: solved?.solvedRa,
        solvedDec: solved?.solvedDec,
      ),
    );

    final steps = _runner.center(
      ApiCenteringRequest(
        mountId: mountId,
        cameraId: cameraId,
        filterWheelId: _ref.read(filterWheelStateProvider).deviceId,
        raHours: targetRa,
        decDegrees: targetDec,
        accuracyArcsec: config.toleranceArcsec,
        maxAttempts: config.maxIterations,
        exposureSecs: config.exposureTime,
        syncMount: config.syncMount,
      ),
    );
    ApiCenteringStep_Finished? finished;
    var timedOut = false;
    final deadline = Timer(config.overallTimeout, () {
      timedOut = true;
      unawaited(_runner.cancel());
    });
    try {
      await for (final step in steps) {
        switch (step) {
          case ApiCenteringStep_Capturing(:final attempt):
            report(
              CenteringState.exposing,
              attempt,
              'Taking centering image (attempt $attempt/${config.maxIterations})...',
            );
          case ApiCenteringStep_Solved(
            :final attempt,
            :final raHours,
            :final decDegrees,
            :final separationArcsec,
          ):
            final solved = CenteringIteration(
              iterationNumber: attempt,
              solvedRa: raHours,
              solvedDec: decDegrees,
              targetRa: targetRa,
              targetDec: targetDec,
              offsetArcsec: separationArcsec,
              offsetArcmin: separationArcsec / 60.0,
              plateSolveSuccess: true,
              timestamp: DateTime.now(),
            );
            iterations.add(solved);
            report(
              CenteringState.verifying,
              attempt,
              'Offset: ${(separationArcsec / 60.0).toStringAsFixed(2)} arcmin',
              solved: solved,
            );
          case ApiCenteringStep_Correcting(:final attempt):
            report(
              CenteringState.slewing,
              attempt,
              'Slewing to target...',
              solved: iterations.lastOrNull,
            );
          case final ApiCenteringStep_Finished done:
            finished = done;
        }
      }
    } catch (e) {
      if (_abortRequested) return _failure('Aborted by user', iterations);
      return _failure('Centering failed: $e', iterations);
    } finally {
      deadline.cancel();
    }
    if (timedOut) {
      return _failure(
        'Centering timed out after ${config.overallTimeout.inSeconds} seconds',
        iterations,
      );
    }

    final attempts = iterations.isEmpty ? 0 : iterations.last.iterationNumber;
    final done = finished;
    if (done == null) {
      return _failure('Centering ended without a result', iterations);
    }
    if (done.cancelled || _abortRequested) {
      return _failure('Aborted by user', iterations);
    }
    if (!done.centered) return _failure(done.message, iterations);
    // A step centers only on a solve, so the last attempt carries the offset.
    final solved = iterations.lastOrNull;
    final offset = solved?.offsetArcsec;
    if (solved == null || offset == null) {
      return _failure(
        'Centering reported centered without a solve',
        iterations,
      );
    }
    report(
      CenteringState.completed,
      attempts,
      'Target centered successfully!',
      solved: solved,
    );
    _ref
        .read(smartNotificationServiceProvider)
        .showSuccessIfNotOnScreens(
          message:
              'Target centered (offset: ${(offset / 60.0).toStringAsFixed(2)} arcmin)',
          relevantScreens: [AppScreen.imaging, AppScreen.sequencer],
          title: 'Centering Complete',
        );
    return CenteringResult.success(
      finalOffsetArcsec: offset,
      iterations: attempts,
      iterationHistory: iterations,
    );
  }

  CenteringResult _failure(
    String message,
    List<CenteringIteration> iterations,
  ) => CenteringResult.failure(
    errorMessage: message,
    iterations: iterations.isEmpty ? 0 : iterations.last.iterationNumber,
    iterationHistory: iterations,
  );

  static String? _refusal(double ra, double dec, CenteringConfig config) {
    if (!ra.isFinite || ra < 0 || ra > 24) {
      return 'Target RA must be between 0 and 24 hours';
    }
    if (!dec.isFinite || dec < -90 || dec > 90) {
      return 'Target declination must be between -90° and +90°';
    }
    if (config.maxIterations < 1) {
      return 'Centering requires at least one iteration';
    }
    if (!config.toleranceArcsec.isFinite || config.toleranceArcsec <= 0) {
      return 'Centering tolerance must be greater than zero';
    }
    if (!config.exposureTime.isFinite || config.exposureTime <= 0) {
      return 'Centering exposure time must be greater than zero';
    }
    if (config.overallTimeout <= Duration.zero) {
      return 'Centering timeout must be greater than zero';
    }
    return null;
  }

  /// The center of this rig's tile when [raHours]/[decDeg] belongs to a
  /// co-imaging session it is in, so the rigs tile the field; null for an
  /// ordinary target. A failed lookup centers on the raw target.
  Future<({double raHours, double decDeg})?> _coImagingFramedTarget(
    double raHours,
    double decDeg,
  ) async {
    try {
      final framed = await _ref
          .read(coImagingSessionServiceProvider)
          .framedCenterForPoint(
            centerRaDeg: raHours * 15.0,
            centerDecDeg: decDeg,
          );
      if (framed == null) return null;
      final framedRaHours = framed.raDeg / 15.0;
      if (framedRaHours == raHours && framed.decDeg == decDeg) return null;
      _ref
          .read(loggingServiceProvider)
          .info(
            'Co-imaging: framing this rig on its assigned coverage tile '
            '(${framedRaHours.toStringAsFixed(4)}h, '
            '${framed.decDeg.toStringAsFixed(4)} deg) instead of the raw center '
            '(${raHours.toStringAsFixed(4)}h, ${decDeg.toStringAsFixed(4)} deg).',
            source: 'CenteringService',
          );
      return (raHours: framedRaHours, decDeg: framed.decDeg);
    } catch (e) {
      _ref
          .read(loggingServiceProvider)
          .warning(
            'Co-imaging framing-offset resolve failed; centering on the raw '
            'target: $e',
            source: 'CenteringService',
          );
      return null;
    }
  }

  void _logOutcome(CenteringResult result, CenteringConfig config) {
    final attempts =
        '${result.iterations} attempt${result.iterations == 1 ? '' : 's'}';
    final logger = _ref.read(loggingServiceProvider);
    final offset = result.finalOffsetArcsec;
    if (result.success) {
      logger.info(
        'Centering done after $attempts: '
        '${offset == null ? 'on target' : '${offset.toStringAsFixed(1)}" from the target'}'
        ' (accuracy ${config.toleranceArcsec.toStringAsFixed(1)}")',
        source: 'CenteringService',
      );
    } else {
      logger.warning(
        'Centering ended after $attempts without reaching the target: '
        '${result.errorMessage ?? 'no reason given'}',
        source: 'CenteringService',
      );
    }
  }
}
