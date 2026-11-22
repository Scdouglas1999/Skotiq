import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' show PlateSolveResult;

import '../models/sequence/instruction_progress_detail.dart'
    show CenterInstructionProgressDetail;
import '../services/centering_service.dart';
import '../services/manual_centering.dart';
import '../services/plate_solve_service.dart'
    show PlateSolveState, plateSolveStateProvider;
import 'centering_service_providers.dart';
import 'profiles_provider.dart';
import 'settings_provider.dart';

/// The one writer of the centering status and the last centering result:
/// a centering the operator starts by hand, a run's Center step, and the
/// state a linked host or client mirrors in.
class CenteringRun {
  CenteringRun(this._ref);

  final Ref _ref;

  StateController<CenteringStatus> get _status =>
      _ref.read(centeringStatusProvider.notifier);

  /// Slews to and centers on RA [raHours] / Dec [decDegrees] (J2000) with
  /// [ManualCentering], the solve exposure [exposureSeconds] or the
  /// profile's. The status ends on the outcome and the result becomes the
  /// last centering result, which the recent-solves list and every linked
  /// window read. A centering already under way is refused and publishes
  /// nothing. Null when [isCurrent] turns false before the run starts.
  /// While [isCurrent] is false the run publishes nothing.
  ///
  /// [config] replaces the manual centering (a client's request names its
  /// own). With [publishes] false the run leaves the status and the last
  /// result alone: the host's center routes pass it, because the client that
  /// asked runs its own CenteringRun and reports that run's status here.
  Future<CenteringResult?> center({
    required double raHours,
    required double decDegrees,
    double? exposureSeconds,
    CenteringConfig? config,
    bool publishes = true,
    bool Function()? isCurrent,
  }) async {
    bool current() => isCurrent?.call() ?? true;
    final centering =
        config ??
        ManualCentering.of(
          await _ref.read(appSettingsProvider.future),
          _ref.read(activeEquipmentProfileProvider),
          exposureSeconds: exposureSeconds,
        ).config;
    if (!current()) return null;
    final service = _ref.read(centeringServiceProvider);
    if (service.isRunning || !publishes) {
      // A running service refuses at once; the status and last result stay
      // those of the run that holds the loop.
      return service.centerOnTarget(
        targetRa: raHours,
        targetDec: decDegrees,
        config: centering,
      );
    }
    final result = await service.centerOnTarget(
      targetRa: raHours,
      targetDec: decDegrees,
      config: centering,
      onStatusUpdate: (status) {
        if (current()) _status.state = status;
      },
    );
    if (!current()) return result;
    // The loop's last status update is its last move, not its outcome.
    _status.state = _status.state.copyWith(
      state: result.success ? CenteringState.completed : CenteringState.error,
      currentIteration: result.iterations,
      currentOffsetArcsec: result.finalOffsetArcsec,
      message: result.success ? 'Centered' : result.errorMessage,
      iterationHistory: result.iterationHistory,
    );
    _ref.read(lastCenteringResultProvider.notifier).state = result;
    return result;
  }

  /// Stops the manual run under way, if any.
  Future<void> cancel() => _ref.read(centeringServiceProvider).stop();

  /// A run's native Center step reported [report]. RA on the wire is hours;
  /// the plate-solve result stores degrees.
  void reportRunStep(CenterInstructionProgressDetail report) {
    final solved =
        report.solvedRaHours != null && report.solvedDecDegrees != null;
    final CenteringState phase;
    if (report.attempt == 0 && report.lastSeparationArcsec != null) {
      phase = CenteringState.completed;
    } else if (solved) {
      phase = CenteringState.solving;
    } else {
      phase = CenteringState.exposing;
    }
    _status.state = CenteringStatus(
      state: phase,
      currentIteration: report.attempt,
      maxIterations: report.maxAttempts,
      currentOffsetArcsec: report.lastSeparationArcsec,
      iterationHistory: const [],
      solvedRa: report.solvedRaHours,
      solvedDec: report.solvedDecDegrees,
    );
    if (!solved) return;
    _ref.read(plateSolveStateProvider.notifier).state = PlateSolveState(
      isSolving: true,
      lastResult: _coordinateOnlySolve(
        raDegrees: report.solvedRaHours! * 15,
        decDegrees: report.solvedDecDegrees!,
      ),
    );
  }

  /// A run's native Center step ended with node status [status].
  void finishRunStep(String status) {
    final failed = status != 'success' && status != 'cancelled';
    final current = _status.state;
    _status.state = CenteringStatus(
      state: failed ? CenteringState.error : CenteringState.completed,
      currentIteration: current.currentIteration,
      maxIterations: current.maxIterations,
      currentOffsetArcsec: current.currentOffsetArcsec,
      iterationHistory: current.iterationHistory,
      solvedRa: current.solvedRa,
      solvedDec: current.solvedDec,
    );
    final solve = _ref.read(plateSolveStateProvider);
    _ref.read(plateSolveStateProvider.notifier).state = PlateSolveState(
      isSolving: false,
      lastResult: failed ? null : solve.lastResult,
      currentImage: solve.currentImage,
    );
  }

  /// The centering status the imaging host or a client sent.
  void adoptStatus(CenteringStatus status) => _status.state = status;

  /// The last centering result the imaging host or a client sent.
  void adoptResult(CenteringResult? result) =>
      _ref.read(lastCenteringResultProvider.notifier).state = result;
}

/// A solve that carries only the position a run's Center step reported.
PlateSolveResult _coordinateOnlySolve({
  required double raDegrees,
  required double decDegrees,
}) => PlateSolveResult(
  success: true,
  ra: raDegrees,
  dec: decDegrees,
  pixelScale: double.nan,
  rotation: double.nan,
  fieldWidth: double.nan,
  fieldHeight: double.nan,
  solveTimeSecs: double.nan,
  cd11: double.nan,
  cd12: double.nan,
  cd21: double.nan,
  cd22: double.nan,
  sipAOrder: 0,
  sipBOrder: 0,
  sipACoeffs: Float64List(0),
  sipBCoeffs: Float64List(0),
  sipApOrder: 0,
  sipBpOrder: 0,
  sipApCoeffs: Float64List(0),
  sipBpCoeffs: Float64List(0),
);

final centeringRunProvider = Provider<CenteringRun>(CenteringRun.new);
