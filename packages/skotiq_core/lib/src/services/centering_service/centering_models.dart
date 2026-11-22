part of '../centering_service.dart';

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

  /// The wire form the host answers a center request with, as the job result
  /// (or the failed job's `details`).
  Map<String, Object?> toJson() => {
    'success': success,
    'iterations': iterations,
    'finalOffsetArcsec': finalOffsetArcsec,
    'errorMessage': errorMessage,
    'iterationHistory': [for (final i in iterationHistory) i.toJson()],
  };

  /// The attempts in a [toJson] map that carry an attempt number. An entry
  /// without one, or a map without the list, gives no attempts.
  static List<CenteringIteration> iterationsFromJson(
    Map<Object?, Object?> json,
  ) {
    final history = json['iterationHistory'];
    if (history is! List) return const [];
    return [
      for (final entry in history)
        if (entry is Map) ?CenteringIteration.tryFromJson(entry),
    ];
  }

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

  Map<String, Object?> toJson() => {
    'iterationNumber': iterationNumber,
    'solvedRa': solvedRa,
    'solvedDec': solvedDec,
    'targetRa': targetRa,
    'targetDec': targetDec,
    'offsetArcsec': offsetArcsec,
    'offsetArcmin': offsetArcmin,
    'plateSolveSuccess': plateSolveSuccess,
    'errorMessage': errorMessage,
    'timestamp': timestamp.millisecondsSinceEpoch,
  };

  /// Reads one [toJson] entry; null when it has no integer attempt number.
  /// A number field of another type reads as absent.
  static CenteringIteration? tryFromJson(Map<Object?, Object?> json) {
    final number = json['iterationNumber'];
    if (number is! int) return null;
    double? real(String key) => switch (json[key]) {
      final num value => value.toDouble(),
      _ => null,
    };
    final timestamp = json['timestamp'];
    final error = json['errorMessage'];
    return CenteringIteration(
      iterationNumber: number,
      solvedRa: real('solvedRa'),
      solvedDec: real('solvedDec'),
      targetRa: real('targetRa'),
      targetDec: real('targetDec'),
      offsetArcsec: real('offsetArcsec'),
      offsetArcmin: real('offsetArcmin'),
      plateSolveSuccess: json['plateSolveSuccess'] == true,
      errorMessage: error is String ? error : null,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        timestamp is int ? timestamp : 0,
      ),
    );
  }

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

/// How a manual centering runs. The frames are taken at full resolution with
/// the camera's stated gain and offset, and solved near the target, as the
/// sequence's Center step does.
class CenteringConfig {
  final int maxIterations;

  /// Tolerance in arcseconds - centering succeeds if offset is below this
  final double toleranceArcsec;

  /// Exposure time for centering images in seconds
  final double exposureTime;

  /// Whether to sync the mount to each solve before re-slewing. Off, each
  /// correction is an offset slew by the measured error, for mounts that build
  /// a pointing model from syncs.
  final bool syncMount;

  /// Maximum wall-clock time for the full centering operation
  final Duration overallTimeout;

  /// [overallTimeout] unless a caller sets another; a host centering is
  /// waited on for this long.
  static const Duration defaultOverallTimeout = Duration(minutes: 10);

  const CenteringConfig({
    this.maxIterations = 5,
    this.toleranceArcsec = 30.0,
    this.exposureTime = 3.0,
    this.syncMount = true,
    this.overallTimeout = defaultOverallTimeout,
  });
}

enum CenteringState {
  idle,
  exposing,
  solving,
  slewing,
  verifying,
  completed,
  error,
}

class CenteringStatus {
  final CenteringState state;
  final int currentIteration;
  final int maxIterations;
  final double? currentOffsetArcsec;
  final double? currentOffsetArcmin;
  final String? message;
  final List<CenteringIteration> iterationHistory;

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
