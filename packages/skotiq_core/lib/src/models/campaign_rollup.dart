/// Aggregated multi-night progress for a single target (Feature B).
///
/// Combines `imaging_sessions`, `captured_images`, `integration_goals`, and
/// `targets` rows to give the operator a single "where am I on this
/// campaign?" view. All numerics are derivations — no campaign-state is
/// persisted, so the rollup auto-refreshes whenever the underlying tables
/// change.
library;

/// Per-filter campaign rollup for one target.
class CampaignFilterRollup {
  /// Filter name as captured. "Unfiltered" when no filter was on the wheel
  /// (matches `SessionFilterReport` convention).
  final String filter;

  /// Total accepted light frames across every session.
  final int capturedFrames;

  /// Total accepted-frame integration time across every session, seconds.
  final double capturedIntegrationSecs;

  /// Per-frame exposure pulled from the matching integration goal, when one
  /// exists. Null when no goal has been set for this filter — the UI uses
  /// the captured-frame mean exposure instead.
  final double? goalExposureSecs;

  /// Desired total frame count from the matching integration goal. Null
  /// when no goal exists.
  final int? goalFrames;

  /// Mean exposure across all captured accepted frames. Used as a fallback
  /// when no goal exposure is defined. Null when zero frames captured.
  final double? meanCapturedExposureSecs;

  const CampaignFilterRollup({
    required this.filter,
    required this.capturedFrames,
    required this.capturedIntegrationSecs,
    required this.goalExposureSecs,
    required this.goalFrames,
    required this.meanCapturedExposureSecs,
  });

  /// True when an integration goal is configured for this filter.
  bool get hasGoal => goalFrames != null && goalFrames! > 0;

  /// Total seconds required to meet the goal. Null when no goal is set.
  double? get goalIntegrationSecs {
    if (!hasGoal) return null;
    final exp = goalExposureSecs ?? meanCapturedExposureSecs;
    if (exp == null) return null;
    return exp * goalFrames!;
  }

  /// Remaining frames clamped to zero. Null when no goal set.
  int? get remainingFrames {
    if (!hasGoal) return null;
    final r = goalFrames! - capturedFrames;
    return r < 0 ? 0 : r;
  }

  /// `[0.0, 1.0]` completion ratio. Null when no goal set.
  double? get percentComplete {
    if (!hasGoal) return null;
    final ratio = capturedFrames / goalFrames!;
    if (ratio < 0.0) return 0.0;
    if (ratio > 1.0) return 1.0;
    return ratio;
  }

  Map<String, dynamic> toJson() => {
    'filter': filter,
    'capturedFrames': capturedFrames,
    'capturedIntegrationSecs': capturedIntegrationSecs,
    'goalExposureSecs': goalExposureSecs,
    'goalFrames': goalFrames,
    'goalIntegrationSecs': goalIntegrationSecs,
    'remainingFrames': remainingFrames,
    'percentComplete': percentComplete,
  };
}

/// Brief reference to one of the target's sessions; used to surface a
/// clickable session list under the rollup and to compute "date range" and
/// session-count derivations.
class CampaignSessionRef {
  final int sessionId;
  final String? sessionName;
  final DateTime startTime;
  final DateTime? endTime;
  final String status;

  /// Integration time recorded on the session row, in seconds. Sourced from
  /// `imaging_sessions.totalIntegrationSecs` — may be 0 for active sessions.
  final double sessionIntegrationSecs;

  /// Mean HFR recorded on the session row. Null when not tracked.
  final double? avgHfr;

  /// Mean guide RMS recorded on the session row. Null when not tracked.
  final double? avgGuidingRms;

  /// Mean seeing recorded on the session row. Null when not tracked.
  final double? avgSeeing;

  const CampaignSessionRef({
    required this.sessionId,
    required this.sessionName,
    required this.startTime,
    required this.endTime,
    required this.status,
    required this.sessionIntegrationSecs,
    required this.avgHfr,
    required this.avgGuidingRms,
    required this.avgSeeing,
  });

  /// Wall-clock duration (`endTime - startTime`). Zero when end is null.
  Duration get wallClockDuration =>
      endTime == null ? Duration.zero : endTime!.difference(startTime);

  Map<String, dynamic> toJson() => {
    'sessionId': sessionId,
    'sessionName': sessionName,
    'startTime': startTime.toIso8601String(),
    'endTime': endTime?.toIso8601String(),
    'status': status,
    'sessionIntegrationSecs': sessionIntegrationSecs,
    'avgHfr': avgHfr,
    'avgGuidingRms': avgGuidingRms,
    'avgSeeing': avgSeeing,
  };
}

/// Multi-night campaign rollup for a single target.
class CampaignRollup {
  /// Foreign key into `targets`.
  final int targetId;

  /// Display name from the target row.
  final String targetName;

  /// Sessions that captured this target, sorted by `startTime` descending so
  /// the "most recent" session is first — matches how the UI lists them.
  final List<CampaignSessionRef> sessions;

  /// Per-filter rollup, sorted alphabetically by filter for stable display.
  final List<CampaignFilterRollup> filters;

  /// `MIN(sessions.startTime)`. Null when no sessions exist.
  final DateTime? firstSessionAt;

  /// `MAX(sessions.startTime)`. Null when no sessions exist.
  final DateTime? lastSessionAt;

  /// Total accepted-frame integration time across every session and filter,
  /// seconds. Derived from `captured_images` so it stays consistent with the
  /// per-filter rollup numbers (the session row's `totalIntegrationSecs`
  /// includes rejected frames in some older code paths).
  final double totalCapturedIntegrationSecs;

  /// Mean HFR across the target's sessions, weighted by frame count. Null
  /// when no session recorded an HFR for this target.
  final double? meanSessionHfr;

  /// Mean seeing across the target's sessions. Null when not tracked.
  final double? meanSessionSeeing;

  /// Mean "effective imaging" fraction across the target's sessions, in
  /// `[0.0, 1.0]`. Per-session efficiency is the session row's integration
  /// time divided by its wall-clock duration; this is the unweighted mean
  /// across all completed sessions in the campaign.
  final double meanEffectiveImagingFraction;

  /// When the rollup was generated.
  final DateTime generatedAt;

  const CampaignRollup({
    required this.targetId,
    required this.targetName,
    required this.sessions,
    required this.filters,
    required this.firstSessionAt,
    required this.lastSessionAt,
    required this.totalCapturedIntegrationSecs,
    required this.meanSessionHfr,
    required this.meanSessionSeeing,
    required this.meanEffectiveImagingFraction,
    required this.generatedAt,
  });

  /// Number of sessions in the campaign.
  int get sessionCount => sessions.length;

  /// True when at least one filter has a configured integration goal.
  bool get hasGoals => filters.any((f) => f.hasGoal);

  /// True when every filter goal is met (and at least one goal exists).
  bool get isComplete {
    if (!hasGoals) return false;
    return filters
        .where((f) => f.hasGoal)
        .every((f) => (f.percentComplete ?? 0.0) >= 1.0);
  }

  /// Sum of all per-filter `goalIntegrationSecs`. Null when no goals exist
  /// or none of the goals have an exposure (no captured frames either).
  double? get totalGoalIntegrationSecs {
    final goaled = filters.where((f) => f.hasGoal);
    if (goaled.isEmpty) return null;
    var sum = 0.0;
    var any = false;
    for (final f in goaled) {
      final g = f.goalIntegrationSecs;
      if (g != null) {
        sum += g;
        any = true;
      }
    }
    return any ? sum : null;
  }

  /// `[0.0, 1.0]` completion ratio summed across all goal-bearing filters.
  /// Null when no goals exist or the goal integration cannot be computed.
  double? get totalPercentComplete {
    final goalTotal = totalGoalIntegrationSecs;
    if (goalTotal == null || goalTotal <= 0) return null;
    final ratio = totalCapturedIntegrationSecs / goalTotal;
    if (ratio < 0.0) return 0.0;
    if (ratio > 1.0) return 1.0;
    return ratio;
  }

  Map<String, dynamic> toJson() => {
    'targetId': targetId,
    'targetName': targetName,
    'sessionCount': sessionCount,
    'sessions': sessions.map((s) => s.toJson()).toList(),
    'filters': filters.map((f) => f.toJson()).toList(),
    'firstSessionAt': firstSessionAt?.toIso8601String(),
    'lastSessionAt': lastSessionAt?.toIso8601String(),
    'totalCapturedIntegrationSecs': totalCapturedIntegrationSecs,
    'totalGoalIntegrationSecs': totalGoalIntegrationSecs,
    'totalPercentComplete': totalPercentComplete,
    'meanSessionHfr': meanSessionHfr,
    'meanSessionSeeing': meanSessionSeeing,
    'meanEffectiveImagingFraction': meanEffectiveImagingFraction,
    'generatedAt': generatedAt.toIso8601String(),
  };
}
