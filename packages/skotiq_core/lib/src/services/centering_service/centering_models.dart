part of '../centering_service.dart';

/// Thrown when the mount status query fails for too many consecutive ticks
/// during the post-slew settle poll. Distinguishes a sustained
/// disconnect/hang from a single transient blip that the poll loop can ride
/// out.
///
/// Typed rather than a wait-out of the 60 s wall-clock cap, so callers and
/// tests see the actual failure mode instead of "centering timed out".
class CenteringMountUnresponsiveException implements Exception {
  /// Number of consecutive failed `getMountStatus` calls before giving up.
  final int consecutiveFailures;

  /// Total wall-clock duration spanned by [consecutiveFailures] at the
  /// poll-tick rate.
  final Duration elapsed;

  /// The underlying error from the most recent failed mount status query.
  final Object cause;

  const CenteringMountUnresponsiveException({
    required this.consecutiveFailures,
    required this.elapsed,
    required this.cause,
  });

  @override
  String toString() {
    final seconds = elapsed.inMilliseconds / 1000.0;
    return 'Mount status query failed $consecutiveFailures times '
        'consecutively over ${seconds.toStringAsFixed(1)}s '
        '— aborting centering. The mount may be disconnected or '
        'unresponsive. Last error: $cause';
  }
}

/// Thrown when the mount keeps reporting that it is slewing for the full
/// post-slew settle budget.
class CenteringSlewTimeoutException implements Exception {
  final Duration elapsed;

  const CenteringSlewTimeoutException({required this.elapsed});

  @override
  String toString() {
    final seconds = elapsed.inMilliseconds / 1000.0;
    return 'Mount was still slewing after ${seconds.toStringAsFixed(1)}s. '
        'Centering stopped instead of taking another exposure while the mount '
        'was moving.';
  }
}

/// Result of a centering operation
class CenteringResult {
  final bool success;
  final double? finalOffsetArcsec;
  final int iterations;
  final String? errorMessage;
  final List<CenteringIteration> iterationHistory;

  const CenteringResult({
    required this.success,
    this.finalOffsetArcsec,
    required this.iterations,
    this.errorMessage,
    required this.iterationHistory,
  });

  factory CenteringResult.success({
    required double finalOffsetArcsec,
    required int iterations,
    required List<CenteringIteration> iterationHistory,
  }) {
    return CenteringResult(
      success: true,
      finalOffsetArcsec: finalOffsetArcsec,
      iterations: iterations,
      errorMessage: null,
      iterationHistory: iterationHistory,
    );
  }

  factory CenteringResult.failure({
    required String errorMessage,
    required int iterations,
    required List<CenteringIteration> iterationHistory,
  }) {
    return CenteringResult(
      success: false,
      finalOffsetArcsec: null,
      iterations: iterations,
      errorMessage: errorMessage,
      iterationHistory: iterationHistory,
    );
  }
}

/// Single iteration of the centering process
class CenteringIteration {
  final int iterationNumber;
  final double? solvedRa;
  final double? solvedDec;
  final double? targetRa;
  final double? targetDec;
  final double? offsetArcsec;
  final double? offsetArcmin;
  final bool plateSolveSuccess;
  final String? errorMessage;
  final DateTime timestamp;

  const CenteringIteration({
    required this.iterationNumber,
    this.solvedRa,
    this.solvedDec,
    this.targetRa,
    this.targetDec,
    this.offsetArcsec,
    this.offsetArcmin,
    required this.plateSolveSuccess,
    this.errorMessage,
    required this.timestamp,
  });
}

/// Configuration for centering operation
class CenteringConfig {
  /// Maximum number of centering iterations
  final int maxIterations;

  /// Tolerance in arcseconds - centering succeeds if offset is below this
  final double toleranceArcsec;

  /// Exposure time for centering images in seconds
  final double exposureTime;

  /// Binning to use for centering images
  final int binning;

  /// Gain to use for centering images. When omitted, the current imaging gain
  /// is preserved.
  final int? gain;

  /// Offset to use for centering images. When omitted, the current imaging
  /// offset is preserved.
  final int? offset;

  /// Whether to sync the mount to the solved position before re-slewing.
  ///
  /// Defaults ON: with it off the correction slew is the SAME slew that
  /// produced the mis-pointed frame, so the measured offset is bit-identical
  /// on every iteration and the run can only end on max iterations. Off is for
  /// mounts that build a pointing model from syncs, where the operator wants
  /// the model left alone.
  final bool syncMount;

  /// Maximum wall-clock time for the full centering operation
  final Duration overallTimeout;

  const CenteringConfig({
    this.maxIterations = 5,
    this.toleranceArcsec = 30.0,
    this.exposureTime = 3.0,
    this.binning = 2,
    this.gain,
    this.offset,
    this.syncMount = true,
    this.overallTimeout = const Duration(minutes: 10),
  });
}

/// Current state of centering operation
enum CenteringState {
  idle,
  exposing,
  solving,
  slewing,
  verifying,
  completed,
  error,
}

/// Status information during centering
class CenteringStatus {
  final CenteringState state;
  final int currentIteration;
  final int maxIterations;
  final double? currentOffsetArcsec;
  final double? currentOffsetArcmin;
  final String? message;
  final List<CenteringIteration> iterationHistory;

  /// Path to the most recently captured centering image
  final String? lastImagePath;

  /// Solved RA of the most recent plate solve (hours)
  final double? solvedRa;

  /// Solved Dec of the most recent plate solve (degrees)
  final double? solvedDec;

  const CenteringStatus({
    required this.state,
    required this.currentIteration,
    required this.maxIterations,
    this.currentOffsetArcsec,
    this.currentOffsetArcmin,
    this.message,
    required this.iterationHistory,
    this.lastImagePath,
    this.solvedRa,
    this.solvedDec,
  });

  CenteringStatus copyWith({
    CenteringState? state,
    int? currentIteration,
    int? maxIterations,
    double? currentOffsetArcsec,
    double? currentOffsetArcmin,
    String? message,
    List<CenteringIteration>? iterationHistory,
    String? lastImagePath,
    double? solvedRa,
    double? solvedDec,
  }) {
    return CenteringStatus(
      state: state ?? this.state,
      currentIteration: currentIteration ?? this.currentIteration,
      maxIterations: maxIterations ?? this.maxIterations,
      currentOffsetArcsec: currentOffsetArcsec ?? this.currentOffsetArcsec,
      currentOffsetArcmin: currentOffsetArcmin ?? this.currentOffsetArcmin,
      message: message ?? this.message,
      iterationHistory: iterationHistory ?? this.iterationHistory,
      lastImagePath: lastImagePath ?? this.lastImagePath,
      solvedRa: solvedRa ?? this.solvedRa,
      solvedDec: solvedDec ?? this.solvedDec,
    );
  }

  factory CenteringStatus.idle() {
    return const CenteringStatus(
      state: CenteringState.idle,
      currentIteration: 0,
      maxIterations: 0,
      iterationHistory: [],
    );
  }
}
