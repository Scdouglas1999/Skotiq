// Value/model types for the Session Review surface.
part of '../session_review_controller.dart';

/// The core multi-night service's best-night value type, aliased so the
/// controller's UI-facing [BestNight] can shadow the bare name.
typedef CoreBestNight = core.BestNight;

/// Identifies which collection of subs the Session Review screen is reviewing:
/// a single imaging session, or every sub captured for a target (across nights).
class SessionReviewScope {
  /// Session id when scoped to one night, else null.
  final int? sessionId;

  /// Target id when scoped to all of a target's subs, else null.
  final int? targetId;

  const SessionReviewScope.session(int this.sessionId) : targetId = null;
  const SessionReviewScope.target(int this.targetId) : sessionId = null;

  bool get isSession => sessionId != null;

  @override
  bool operator ==(Object other) =>
      other is SessionReviewScope &&
      other.sessionId == sessionId &&
      other.targetId == targetId;

  @override
  int get hashCode => Object.hash(sessionId, targetId);
}

/// Which of the two renderings of the one [SessionReviewController] is showing:
/// the scrollable narrative (default) or the dense workbench. Held on
/// [SessionReviewState] so a single tap flips both views over the same model.
enum SessionReviewViewMode {
  /// The story view: hero → verdict → improvement curve → findings → growth.
  narrative,

  /// The dense panelled view: full sub table, field maps, mixer, A/B.
  workbench,
}

/// The distinguishable outcomes of [SessionReviewController.cullToRecommended],
/// so the UI can tell a genuine "already optimal" no-op apart from a stale-curve
/// guard bail (which deliberately rejects nothing).
enum CullOutcome {
  /// Subs were rejected down to the recommended keep-set.
  culled,

  /// The recommendation already keeps every accepted sub — nothing to reject.
  alreadyOptimal,

  /// The curve/population no longer maps to the live accepted subs, so the cull
  /// bailed without rejecting. Re-integrate to refresh before culling.
  staleCurve,
}

/// Result of [SessionReviewController.cullToRecommended]: the [outcome] and, for
/// [CullOutcome.culled], how many subs were [rejected].
class CullToRecommendedResult {
  final CullOutcome outcome;
  final int rejected;

  const CullToRecommendedResult(this.outcome, this.rejected);

  static const staleCurve = CullToRecommendedResult(CullOutcome.staleCurve, 0);
  static const alreadyOptimal =
      CullToRecommendedResult(CullOutcome.alreadyOptimal, 0);
}

/// Whether the improvement curve's "keep best N" cull can be offered *right
/// now*. Every guard [SessionReviewController.cullToRecommended] enforces is
/// evaluated here instead, so the rail decides at build time exactly what the
/// press handler would decide. Keeping the two in one place is the point: a
/// control must never render a specific, quantified action ("Keep best 1
/// (+0%)") that it would then unconditionally refuse.
enum CullOfferStatus {
  /// No curve, or a recommendation with no keep-set: render no action at all.
  none,

  /// A curve exists but its population no longer covers the live accepted subs,
  /// so the cull would bail without rejecting anything. Surface "analysis out
  /// of date" — never a keep-best action.
  stale,

  /// The recommendation keeps every accepted sub, or predicts no SNR gain, so
  /// pressing would reject nothing (or would reject subs for no benefit).
  alreadyOptimal,

  /// The cull would reject real subs for a real predicted gain.
  offerable,
}

/// [CullOfferStatus] plus the numbers a label may quote. The numbers are only
/// safe to render as a promise when [status] is [CullOfferStatus.offerable].
class CullRecommendationOffer {
  final CullOfferStatus status;

  /// The recommendation's keep count (0 when [status] is
  /// [CullOfferStatus.none]).
  final int keepN;

  /// Predicted SNR gain of the keep-set, in percent.
  final double gainPct;

  /// Size of the population the curve was computed over.
  final int populationSize;

  const CullRecommendationOffer({
    required this.status,
    required this.keepN,
    required this.gainPct,
    required this.populationSize,
  });

  static const none = CullRecommendationOffer(
    status: CullOfferStatus.none,
    keepN: 0,
    gainPct: 0,
    populationSize: 0,
  );

  /// True only when the cull would actually run — the single condition the UI
  /// may gate an enabled, quantified action on.
  bool get isOfferable => status == CullOfferStatus.offerable;

  // Value equality: the rail re-evaluates the offer on every controller tick
  // and only rebuilds when it actually changed.
  @override
  bool operator ==(Object other) =>
      other is CullRecommendationOffer &&
      other.status == status &&
      other.keepN == keepN &&
      other.gainPct == gainPct &&
      other.populationSize == populationSize;

  @override
  int get hashCode => Object.hash(status, keepN, gainPct, populationSize);
}

/// One point of a master's multi-night integration-time growth, projected for
/// the [GrowthCurvePanel]: cumulative integration *hours* as of a calendar
/// [date]. A thin UI mirror of the core [IntegrationGrowthPoint] (which carries
/// seconds + a running frame count) so the chart layer never touches the
/// service's wire model directly.
class GrowthPoint {
  /// Local calendar day (date-only; midnight UTC) the running total is as of.
  final DateTime date;

  /// Running cumulative integration time, in hours, through [date].
  final double cumulativeHours;

  /// Running accepted-frame count through [date].
  final int framesToDate;

  const GrowthPoint({
    required this.date,
    required this.cumulativeHours,
    required this.framesToDate,
  });

  /// Project a core [IntegrationGrowthPoint] (seconds) into UI hours.
  factory GrowthPoint.fromCore(IntegrationGrowthPoint p) => GrowthPoint(
        date: p.date,
        cumulativeHours: p.cumulativeIntegrationSeconds / 3600.0,
        framesToDate: p.framesToDate,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GrowthPoint &&
          other.date == date &&
          other.cumulativeHours == cumulativeHours &&
          other.framesToDate == framesToDate;

  @override
  int get hashCode => Object.hash(date, cumulativeHours, framesToDate);
}

/// The single best night folded into the reviewed master, for the
/// [GrowthCurvePanel] badge: the calendar [date] whose accepted subs carried
/// the highest mean integration weight, with its frame count and integration
/// time (hours). A thin UI mirror of the core [BestNight] service type
/// (which carries seconds) so the panels stay decoupled from the service model.
class BestNight {
  /// The night's local calendar day (date-only).
  final DateTime date;

  /// Mean integration weight over the night's accepted subs.
  final double meanWeight;

  /// Number of accepted subs folded that night.
  final int frameCount;

  /// Total integration time contributed that night, in hours.
  final double integrationHours;

  const BestNight({
    required this.date,
    required this.meanWeight,
    required this.frameCount,
    required this.integrationHours,
  });

  /// Project the core service [CoreBestNight] (seconds) into UI hours.
  factory BestNight.fromCore(CoreBestNight n) => BestNight(
        date: n.date,
        meanWeight: n.meanWeight,
        frameCount: n.frameCount,
        integrationHours: n.integrationSeconds / 3600.0,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BestNight &&
          other.date == date &&
          other.meanWeight == meanWeight &&
          other.frameCount == frameCount &&
          other.integrationHours == integrationHours;

  @override
  int get hashCode =>
      Object.hash(date, meanWeight, frameCount, integrationHours);
}

/// One single-channel narrowband master available to mix in the
/// [NarrowbandMixerPanel]: a labelled channel (e.g. `Ha`, `OIII`, `SII`) backed
/// by an on-disk linear FITS master.
class NarrowbandChannelRef {
  /// The persisted `integrated_masters` row id this channel comes from.
  final int masterId;

  /// Channel / filter label shown on the mixer row (e.g. `Ha`, `OIII`, `SII`).
  final String label;

  /// On-disk linear FITS master path the native combine consumes, or null when
  /// this master has not been finalized to a FITS yet.
  final String? fitsPath;

  const NarrowbandChannelRef({
    required this.masterId,
    required this.label,
    required this.fitsPath,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NarrowbandChannelRef &&
          other.masterId == masterId &&
          other.label == label &&
          other.fitsPath == fitsPath;

  @override
  int get hashCode => Object.hash(masterId, label, fitsPath);
}
