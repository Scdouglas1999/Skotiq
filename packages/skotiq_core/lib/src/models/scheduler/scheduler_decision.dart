import 'package:equatable/equatable.dart';

/// A single scoring factor contribution for a candidate target.
///
/// Carries the normalized factor value (0..1), its configured weight, and
/// the resulting weighted contribution. The UI uses this to explain why
/// the engine picked one target over another.
class ScoreFactor extends Equatable {
  final String name;
  final double value;
  final double weight;
  final double weighted;

  /// Optional human-readable detail (e.g. "altitude 62.3 deg").
  final String? detail;

  const ScoreFactor({
    required this.name,
    required this.value,
    required this.weight,
    required this.weighted,
    this.detail,
  });

  @override
  List<Object?> get props => [name, value, weight, weighted, detail];

  Map<String, dynamic> toJson() => {
    'name': name,
    'value': value,
    'weight': weight,
    'weighted': weighted,
    if (detail != null) 'detail': detail,
  };

  factory ScoreFactor.fromJson(Map<String, dynamic> j) => ScoreFactor(
    name: j['name'] as String? ?? '',
    value: (j['value'] as num?)?.toDouble() ?? 0,
    weight: (j['weight'] as num?)?.toDouble() ?? 0,
    weighted: (j['weighted'] as num?)?.toDouble() ?? 0,
    detail: j['detail'] as String?,
  );
}

/// Full breakdown of a single target's evaluation at a moment in time.
class TargetScore extends Equatable {
  final int targetId;
  final String targetName;

  /// Sum of all weighted factor contributions.
  final double totalScore;

  /// Each factor's value, weight, and weighted contribution.
  final List<ScoreFactor> factors;

  /// True if any hard constraint failed; if so, totalScore is recorded
  /// but the target is excluded from selection.
  final bool hardConstraintFailed;

  /// Constraint failure reasons (one entry per failing constraint).
  final List<String> rejectionReasons;

  const TargetScore({
    required this.targetId,
    required this.targetName,
    required this.totalScore,
    required this.factors,
    this.hardConstraintFailed = false,
    this.rejectionReasons = const [],
  });

  @override
  List<Object?> get props => [
    targetId,
    targetName,
    totalScore,
    factors,
    hardConstraintFailed,
    rejectionReasons,
  ];

  Map<String, dynamic> toJson() => {
    'targetId': targetId,
    'targetName': targetName,
    'totalScore': totalScore,
    'factors': factors.map((f) => f.toJson()).toList(),
    'hardConstraintFailed': hardConstraintFailed,
    'rejectionReasons': rejectionReasons,
  };

  factory TargetScore.fromJson(Map<String, dynamic> j) => TargetScore(
    targetId: (j['targetId'] as num?)?.toInt() ?? 0,
    targetName: j['targetName'] as String? ?? '',
    totalScore: (j['totalScore'] as num?)?.toDouble() ?? 0,
    factors: ((j['factors'] as List?) ?? const [])
        .map((e) => ScoreFactor.fromJson(e as Map<String, dynamic>))
        .toList(),
    hardConstraintFailed: j['hardConstraintFailed'] as bool? ?? false,
    rejectionReasons: ((j['rejectionReasons'] as List?) ?? const [])
        .map((e) => e as String)
        .toList(),
  );
}

/// A rejected candidate's why-not summary surfaced alongside the chosen
/// target on the decision panel. Each entry holds enough information for
/// the UI to render a compact "X — score 0.42 — moon too close" row plus
/// expand-to-show-full-breakdown affordance without re-querying the engine.
class RejectedCandidate extends Equatable {
  final int targetId;
  final String targetName;

  /// Score the candidate would have had absent its hard-constraint
  /// failures. Useful for ranking rejected entries next to the chosen one.
  final double score;

  /// Short single-line reason chip — the most operator-actionable text the
  /// engine could derive (e.g. "below horizon", "moon too close (12° / min
  /// 30°)", "outside time window 22:00–02:00", "score 0.42 < threshold
  /// 0.50", "lower priority than chosen (47% vs 78%)").
  final String primaryReason;

  /// Full per-constraint failure list (one entry per failed hard
  /// constraint, or empty for an eligible-but-lower-scoring candidate).
  final List<String> hardConstraintFailures;

  /// Full per-factor breakdown — same shape as the chosen target's so the
  /// UI can render the identical widget when the operator expands a
  /// rejected row.
  final List<ScoreFactor> factors;

  const RejectedCandidate({
    required this.targetId,
    required this.targetName,
    required this.score,
    required this.primaryReason,
    required this.hardConstraintFailures,
    required this.factors,
  });

  @override
  List<Object?> get props => [
    targetId,
    targetName,
    score,
    primaryReason,
    hardConstraintFailures,
    factors,
  ];

  Map<String, dynamic> toJson() => {
    'targetId': targetId,
    'targetName': targetName,
    'score': score,
    'primaryReason': primaryReason,
    'hardConstraintFailures': hardConstraintFailures,
    'factors': factors.map((f) => f.toJson()).toList(),
  };

  factory RejectedCandidate.fromJson(Map<String, dynamic> j) =>
      RejectedCandidate(
        targetId: (j['targetId'] as num?)?.toInt() ?? 0,
        targetName: j['targetName'] as String? ?? '',
        score: (j['score'] as num?)?.toDouble() ?? 0,
        primaryReason: j['primaryReason'] as String? ?? '',
        hardConstraintFailures:
            ((j['hardConstraintFailures'] as List?) ?? const [])
                .map((e) => e as String)
                .toList(),
        factors: ((j['factors'] as List?) ?? const [])
            .map((e) => ScoreFactor.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// The decision the scheduler made at a particular tick.
///
/// `chosenTargetId` is null when no candidate passed its hard constraints
/// (e.g. everything below the horizon, weather unsafe, etc.).
class SchedulerDecision extends Equatable {
  final int? chosenTargetId;
  final String? chosenTargetName;

  /// Score of the chosen target (0 if none chosen).
  final double score;

  /// One reasoning line per significant factor or rejection, suitable for
  /// rendering as a bulleted list in the Scheduler screen's decision panel.
  final List<String> reasoning;

  /// Every candidate's score breakdown for the current tick.
  /// Sorted descending by totalScore among eligible candidates first,
  /// then rejected candidates.
  final List<TargetScore> scoredCandidates;

  /// Per-candidate why-not summaries for every target the engine did NOT
  /// pick at this tick. Includes both hard-constraint-failed targets and
  /// eligible-but-lower-scoring runners-up.
  final List<RejectedCandidate> rejected;

  final DateTime evaluatedAt;

  /// True if this decision changed the active target relative to the
  /// previous decision. Useful for UI animations and logging.
  final bool isSwitch;

  const SchedulerDecision({
    this.chosenTargetId,
    this.chosenTargetName,
    required this.score,
    required this.reasoning,
    required this.scoredCandidates,
    required this.evaluatedAt,
    this.isSwitch = false,
    this.rejected = const [],
  });

  @override
  List<Object?> get props => [
    chosenTargetId,
    chosenTargetName,
    score,
    reasoning,
    scoredCandidates,
    evaluatedAt,
    isSwitch,
    rejected,
  ];

  Map<String, dynamic> toJson() => {
    if (chosenTargetId != null) 'chosenTargetId': chosenTargetId,
    if (chosenTargetName != null) 'chosenTargetName': chosenTargetName,
    'score': score,
    'reasoning': reasoning,
    'scoredCandidates': scoredCandidates.map((s) => s.toJson()).toList(),
    'rejected': rejected.map((r) => r.toJson()).toList(),
    'evaluatedAt': evaluatedAt.toIso8601String(),
    'isSwitch': isSwitch,
  };

  factory SchedulerDecision.fromJson(Map<String, dynamic> j) =>
      SchedulerDecision(
        chosenTargetId: (j['chosenTargetId'] as num?)?.toInt(),
        chosenTargetName: j['chosenTargetName'] as String?,
        score: (j['score'] as num?)?.toDouble() ?? 0,
        reasoning: ((j['reasoning'] as List?) ?? const [])
            .map((e) => e as String)
            .toList(),
        scoredCandidates: ((j['scoredCandidates'] as List?) ?? const [])
            .map((e) => TargetScore.fromJson(e as Map<String, dynamic>))
            .toList(),
        rejected: ((j['rejected'] as List?) ?? const [])
            .map((e) => RejectedCandidate.fromJson(e as Map<String, dynamic>))
            .toList(),
        evaluatedAt:
            DateTime.tryParse(j['evaluatedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        isSwitch: j['isSwitch'] as bool? ?? false,
      );
}
