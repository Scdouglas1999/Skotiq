/// How one step of a night-end run ended.
enum NightEndStepState {
  /// Not reached yet.
  pending,
  running,
  done,

  /// Switched off, or nothing to do.
  skipped,

  /// Waits for the operator: a build held at the framing check.
  waiting,
  failed;

  bool get finished =>
      this == done || this == skipped || this == failed || this == waiting;
}

/// One step's state and what it did, in a sentence.
class NightEndStep {
  const NightEndStep(this.state, [this.detail]);

  final NightEndStepState state;
  final String? detail;

  static const pending = NightEndStep(NightEndStepState.pending);

  Map<String, dynamic> toJson() => {
    'state': state.name,
    if (detail != null) 'detail': detail,
  };

  factory NightEndStep.fromJson(Object? json) {
    if (json is! Map) return pending;
    return NightEndStep(
      NightEndStepState.values.asNameMap()[json['state']] ??
          NightEndStepState.pending,
      json['detail'] as String?,
    );
  }
}

/// One target of a night-end run: its build and its delivery.
class NightEndTarget {
  const NightEndTarget({
    required this.target,
    this.build = NightEndStep.pending,
    this.deliver = NightEndStep.pending,
    this.nights,
    this.directory,
    this.waitingForCalibration = false,
  });

  /// The target's name, the Darkroom's key for it.
  final String target;
  final NightEndStep build;
  final NightEndStep deliver;

  /// How many nights the build combined.
  final int? nights;
  final String? directory;
  final bool waitingForCalibration;

  NightEndTarget copyWith({
    NightEndStep? build,
    NightEndStep? deliver,
    int? nights,
    String? directory,
    bool? waitingForCalibration,
  }) => NightEndTarget(
    target: target,
    build: build ?? this.build,
    deliver: deliver ?? this.deliver,
    nights: nights ?? this.nights,
    directory: directory ?? this.directory,
    waitingForCalibration: waitingForCalibration ?? this.waitingForCalibration,
  );

  Map<String, dynamic> toJson() => {
    'target': target,
    'build': build.toJson(),
    'deliver': deliver.toJson(),
    if (nights != null) 'nights': nights,
    if (directory != null) 'directory': directory,
    'waitingForCalibration': waitingForCalibration,
  };

  factory NightEndTarget.fromJson(Map<String, dynamic> json) => NightEndTarget(
    target: json['target'] as String,
    build: NightEndStep.fromJson(json['build']),
    deliver: NightEndStep.fromJson(json['deliver']),
    nights: (json['nights'] as num?)?.toInt(),
    directory: json['directory'] as String?,
    waitingForCalibration: json['waitingForCalibration'] == true,
  );
}

/// What the end of one night did: calibration, a build per imaged target,
/// delivery and the morning message, each with its outcome. Saved, so the
/// Activity tab shows past nights and a run cut short by a restart carries on.
class NightEndRun {
  const NightEndRun({
    required this.id,
    required this.startedAt,
    required this.reason,
    this.sessionId,
    this.finishedAt,
    this.calibrate = NightEndStep.pending,
    this.targets = const [],
    this.message = NightEndStep.pending,
  });

  final String id;
  final int? sessionId;
  final DateTime startedAt;
  final DateTime? finishedAt;

  /// Why the night ended, in words ("dawn ended imaging").
  final String reason;
  final NightEndStep calibrate;
  final List<NightEndTarget> targets;
  final NightEndStep message;

  bool get finished => finishedAt != null;

  /// The delivery step over every target, for a one-line history.
  NightEndStep get deliver {
    final steps = [for (final t in targets) t.deliver];
    if (steps.isEmpty) {
      return const NightEndStep(NightEndStepState.skipped, 'Nothing built.');
    }
    if (steps.any((s) => s.state == NightEndStepState.running)) {
      return const NightEndStep(NightEndStepState.running);
    }
    if (steps.any((s) => s.state == NightEndStepState.failed)) {
      return NightEndStep(
        NightEndStepState.failed,
        steps.firstWhere((s) => s.state == NightEndStepState.failed).detail,
      );
    }
    if (steps.any((s) => s.state == NightEndStepState.done)) {
      return const NightEndStep(NightEndStepState.done);
    }
    if (steps.every((s) => s.state == NightEndStepState.skipped)) {
      return NightEndStep(NightEndStepState.skipped, steps.first.detail);
    }
    return NightEndStep(
      NightEndStepState.pending,
      steps.firstWhere((s) => s.state == NightEndStepState.pending).detail,
    );
  }

  /// The build step over every target.
  NightEndStep get build {
    final steps = [for (final t in targets) t.build];
    if (steps.isEmpty) return const NightEndStep(NightEndStepState.skipped);
    for (final state in [
      NightEndStepState.running,
      NightEndStepState.pending,
      NightEndStepState.failed,
      NightEndStepState.waiting,
      NightEndStepState.done,
    ]) {
      if (steps.any((s) => s.state == state)) return NightEndStep(state);
    }
    return NightEndStep(NightEndStepState.skipped, steps.first.detail);
  }

  NightEndRun copyWith({
    DateTime? finishedAt,
    bool clearFinishedAt = false,
    NightEndStep? calibrate,
    List<NightEndTarget>? targets,
    NightEndStep? message,
  }) => NightEndRun(
    id: id,
    sessionId: sessionId,
    startedAt: startedAt,
    reason: reason,
    finishedAt: clearFinishedAt ? null : finishedAt ?? this.finishedAt,
    calibrate: calibrate ?? this.calibrate,
    targets: targets ?? this.targets,
    message: message ?? this.message,
  );

  /// This run with [target]'s entry replaced by [update]'s result.
  NightEndRun withTarget(
    String target,
    NightEndTarget Function(NightEndTarget) update,
  ) => copyWith(
    targets: [for (final t in targets) t.target == target ? update(t) : t],
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    if (sessionId != null) 'sessionId': sessionId,
    'startedAt': startedAt.toUtc().toIso8601String(),
    if (finishedAt != null) 'finishedAt': finishedAt!.toUtc().toIso8601String(),
    'reason': reason,
    'calibrate': calibrate.toJson(),
    'targets': [for (final t in targets) t.toJson()],
    'message': message.toJson(),
  };

  factory NightEndRun.fromJson(Map<String, dynamic> json) => NightEndRun(
    id: json['id'] as String,
    sessionId: (json['sessionId'] as num?)?.toInt(),
    startedAt: DateTime.parse(json['startedAt'] as String).toLocal(),
    finishedAt: json['finishedAt'] == null
        ? null
        : DateTime.parse(json['finishedAt'] as String).toLocal(),
    reason: json['reason'] as String? ?? '',
    calibrate: NightEndStep.fromJson(json['calibrate']),
    targets: [
      for (final t in json['targets'] as List? ?? const [])
        NightEndTarget.fromJson(Map<String, dynamic>.from(t as Map)),
    ],
    message: NightEndStep.fromJson(json['message']),
  );
}
