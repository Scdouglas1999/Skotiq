/// Durable NINA-style multi-night campaign record (Phase B, v43).
///
/// A [Campaign] is the persisted `(target, filter, accepted, desired, last_date)`
/// counter that mirrors NINA's Target Scheduler campaign table. It is the
/// durable companion to the existing live derivation in `campaign_rollup.dart`:
/// the rollup recomputes accepted-frame counts from `captured_images` on every
/// open, while this record persists a denormalized `acceptedCount` that is
/// incremented on the acceptance path so the count survives without re-scanning
/// the whole image table, and tracks the wall-clock `lastCaptureAt` of the most
/// recent accepted frame (the "last_date" NINA shows per filter).
///
/// This record is ADDITIVE and orthogonal to `integration_goals`: it never
/// feeds the live `SchedulerEngine`'s goals-complete reject (which stays a
/// read-only derivation over `integration_goals.frame_count` +
/// `captured_images.is_accepted=1`). It is a UI-facing bookkeeping surface the
/// campaign view can later show; full UI is Phase F.
library;

/// One durable campaign row: the multi-night progress of a single
/// `(target, filter)` pair toward a desired accepted-frame count.
class Campaign {
  /// DB primary key (`campaigns.id`). Null for an unsaved record.
  final int? id;

  /// DB `targets.id` this campaign belongs to.
  final int targetId;

  /// Filter name as captured. Matched case-insensitively against captured
  /// frames the same way `IntegrationGoalService.capturedFrameCount` does.
  final String filter;

  /// Total accepted frames credited so far across every night. Incremented on
  /// the acceptance path (`SequenceExecutor._registerSequenceFrame`).
  final int acceptedCount;

  /// Desired total accepted-frame count — the campaign goal.
  final int desiredCount;

  /// Wall-clock of the most recent accepted frame credited to this campaign,
  /// UTC. Null when no frame has been credited yet (the NINA "last_date").
  final DateTime? lastCaptureAt;

  /// When the campaign row was first created (UTC).
  final DateTime createdAt;

  /// When the campaign row was last updated (UTC).
  final DateTime updatedAt;

  const Campaign({
    this.id,
    required this.targetId,
    required this.filter,
    required this.acceptedCount,
    required this.desiredCount,
    this.lastCaptureAt,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Remaining accepted frames clamped to zero.
  int get remaining {
    final r = desiredCount - acceptedCount;
    return r < 0 ? 0 : r;
  }

  /// True once the desired accepted-frame count has been reached.
  bool get isComplete => desiredCount > 0 && acceptedCount >= desiredCount;

  /// `[0.0, 1.0]` completion ratio. Zero when no desired count is set.
  double get percentComplete {
    if (desiredCount <= 0) return 0.0;
    final ratio = acceptedCount / desiredCount;
    if (ratio < 0.0) return 0.0;
    if (ratio > 1.0) return 1.0;
    return ratio;
  }

  Campaign copyWith({
    int? id,
    int? targetId,
    String? filter,
    int? acceptedCount,
    int? desiredCount,
    DateTime? lastCaptureAt,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Campaign(
      id: id ?? this.id,
      targetId: targetId ?? this.targetId,
      filter: filter ?? this.filter,
      acceptedCount: acceptedCount ?? this.acceptedCount,
      desiredCount: desiredCount ?? this.desiredCount,
      lastCaptureAt: lastCaptureAt ?? this.lastCaptureAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  String toString() =>
      'Campaign(target=$targetId, filter=$filter, '
      'accepted=$acceptedCount/$desiredCount)';
}
