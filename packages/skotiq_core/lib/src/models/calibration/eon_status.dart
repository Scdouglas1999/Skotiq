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

  /// Where the wheel was put back after the calibration run, when it ran
  /// through the dark slot.
  String? filterRestored;
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
    'filterRestored': filterRestored,
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
  const EonStatus({
    this.phase = EonPhase.idle,
    this.message,
    this.report,
    this.capDeadline,
  });

  final EonPhase phase;
  final String? message;
  final EonReport? report;

  /// While waiting for a cap: when the darks are skipped if nobody confirms.
  final DateTime? capDeadline;

  Map<String, Object?> toJson() => {
    'phase': phase.name,
    'message': message,
    'report': report?.toJson(),
    'capDeadline': capDeadline?.toUtc().toIso8601String(),
  };

  /// The phase, message and cap deadline of a host's status as [toJson]
  /// writes it; the report stays on the host. Null when [json] is not one.
  static EonStatus? fromHostJson(Object? json) {
    if (json is! Map) return null;
    final phase = EonPhase.values
        .where((p) => p.name == json['phase'])
        .firstOrNull;
    if (phase == null) return null;
    final deadline = json['capDeadline'];
    return EonStatus(
      phase: phase,
      message: json['message'] as String?,
      capDeadline: deadline is String
          ? DateTime.tryParse(deadline)?.toLocal()
          : null,
    );
  }
}

/// Why a calibration step could not start.
class EonBusyException implements Exception {
  const EonBusyException(this.message);
  final String message;
  @override
  String toString() => message;
}
