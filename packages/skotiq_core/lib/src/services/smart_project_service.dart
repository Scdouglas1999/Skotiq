import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart' as db;
import '../models/imaging/integration_curve.dart';
import '../models/scheduler/integration_goal.dart';
import '../providers/database_provider.dart';
import 'scheduler/integration_goal_service.dart';

/// One point of an integrated master's multi-night growth: cumulative
/// integration time as of an observing night.
///
/// The x-axis is the observing night [date] of the last sub folded that night;
/// the y-axis is the running [cumulativeIntegrationSeconds] across every sub
/// folded on or before that night. [framesToDate] is the running accepted-frame
/// count.
class IntegrationGrowthPoint {
  /// The observing night this point covers, as a local date-only DateTime
  /// (local midnight). See [SmartProjectService.observingNightOf] for the
  /// noon-to-noon rule that assigns a capture to a night.
  final DateTime date;

  /// Running cumulative integration time (seconds) through this date.
  final double cumulativeIntegrationSeconds;

  /// Running accepted-frame count through this date.
  final int framesToDate;

  const IntegrationGrowthPoint({
    required this.date,
    required this.cumulativeIntegrationSeconds,
    required this.framesToDate,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is IntegrationGrowthPoint &&
          other.date == date &&
          other.cumulativeIntegrationSeconds == cumulativeIntegrationSeconds &&
          other.framesToDate == framesToDate;

  @override
  int get hashCode =>
      Object.hash(date, cumulativeIntegrationSeconds, framesToDate);
}

/// The single best night folded into a master: the observing night whose
/// accepted subs carried the highest mean integration weight.
class BestNight {
  /// The observing night, as a local date-only DateTime (local midnight). See
  /// [SmartProjectService.observingNightOf].
  final DateTime date;

  /// Mean integration weight over the night's accepted subs.
  final double meanWeight;

  /// Number of accepted subs folded that night.
  final int frameCount;

  /// Total integration seconds contributed that night.
  final double integrationSeconds;

  const BestNight({
    required this.date,
    required this.meanWeight,
    required this.frameCount,
    required this.integrationSeconds,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BestNight &&
          other.date == date &&
          other.meanWeight == meanWeight &&
          other.frameCount == frameCount &&
          other.integrationSeconds == integrationSeconds;

  @override
  int get hashCode =>
      Object.hash(date, meanWeight, frameCount, integrationSeconds);
}

/// Advisory recommendation to re-reference (re-register) an accumulating master
/// against a later, higher-quality night.
///
/// This is *advisory only*. The multi-night accumulator freezes its alignment
/// reference at the first night for parity; when a later night materially beats
/// that frozen reference's mean weight the operator may get a tighter master by
/// re-referencing — but it is never auto-applied (it would re-fold the whole
/// history). [gainFraction] is `(bestMeanWeight − referenceMeanWeight) /
/// referenceMeanWeight`.
class ReReferenceAdvice {
  /// True when a later night beats the frozen reference by the threshold.
  final bool recommended;

  /// The frozen-reference night (the earliest folded night).
  final DateTime referenceDate;

  /// Mean weight of the frozen reference night.
  final double referenceMeanWeight;

  /// The candidate (best later) night to re-reference against, when one exists.
  final DateTime? candidateDate;

  /// Mean weight of the candidate night.
  final double candidateMeanWeight;

  /// Fractional improvement of the candidate over the reference (>= 0).
  final double gainFraction;

  const ReReferenceAdvice({
    required this.recommended,
    required this.referenceDate,
    required this.referenceMeanWeight,
    required this.candidateDate,
    required this.candidateMeanWeight,
    required this.gainFraction,
  });

  /// A null-object advice for a master with no usable fold log.
  static ReReferenceAdvice none(DateTime epoch) => ReReferenceAdvice(
    recommended: false,
    referenceDate: epoch,
    referenceMeanWeight: 0,
    candidateDate: null,
    candidateMeanWeight: 0,
    gainFraction: 0,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReReferenceAdvice &&
          other.recommended == recommended &&
          other.referenceDate == referenceDate &&
          other.referenceMeanWeight == referenceMeanWeight &&
          other.candidateDate == candidateDate &&
          other.candidateMeanWeight == candidateMeanWeight &&
          other.gainFraction == gainFraction;

  @override
  int get hashCode => Object.hash(
    recommended,
    referenceDate,
    referenceMeanWeight,
    candidateDate,
    candidateMeanWeight,
    gainFraction,
  );
}

/// Result of writing a target-SNR deficit back to the scheduler.
///
/// Records, per filter folded into the master, how many extra frames were added
/// to the integration goal's `frame_count` to close the SNR gap. [applied] is
/// false (with an empty [perFilter]) when the master already meets/exceeds its
/// target SNR, when no target SNR is available, or when the master has no
/// target id to attach goals to.
class DeficitPushResult {
  /// True when at least one goal's `frame_count` was raised.
  final bool applied;

  /// The target SNR the deficit was computed against.
  final double targetSnr;

  /// The latest-achieved SNR read off the master's improvement curve.
  final double currentSnr;

  /// Estimated remaining integration seconds to reach [targetSnr].
  final double deficitSeconds;

  /// Per-filter frame deltas written via [IntegrationGoalService.upsert].
  final List<FilterDeficit> perFilter;

  const DeficitPushResult({
    required this.applied,
    required this.targetSnr,
    required this.currentSnr,
    required this.deficitSeconds,
    required this.perFilter,
  });

  static const DeficitPushResult notApplied = DeficitPushResult(
    applied: false,
    targetSnr: 0,
    currentSnr: 0,
    deficitSeconds: 0,
    perFilter: [],
  );
}

/// One filter's contribution to a deficit push: the extra frames raised and the
/// resulting goal frame_count.
class FilterDeficit {
  final String filter;
  final double exposureSeconds;

  /// Extra frames added to the goal's `frame_count`.
  final int deltaFrames;

  /// The goal's `frame_count` after the raise.
  final int newFrameCount;

  const FilterDeficit({
    required this.filter,
    required this.exposureSeconds,
    required this.deltaFrames,
    required this.newFrameCount,
  });
}

/// One folded sub, projected from the `integrated_master_frames` join against
/// `captured_images`. Internal to the growth/best-night/deficit math.
class _FoldedSub {
  /// The observing night the sub belongs to, noon-to-noon local, as a
  /// date-only local DateTime. See [SmartProjectService.observingNightOf].
  final DateTime captureDate;
  final double exposureSeconds;

  /// Per-frame integration weight, or null when the fold record carries no
  /// weight (e.g. an accumulate path that surfaces no native weight).
  /// Membership in the growth curve / frame counts / deficit total is decided by
  /// `accepted`, NOT by weight — a null-weight accepted sub still counts. Weight
  /// is consulted only for best-night mean-weight aggregation.
  final double? weight;
  final double? snr;
  final String filter; // '' when none

  const _FoldedSub({
    required this.captureDate,
    required this.exposureSeconds,
    required this.weight,
    required this.snr,
    required this.filter,
  });
}

/// Multi-night project intelligence over an accumulating master's fold log.
///
/// Reads the `integrated_master_frames` provenance (joined to `captured_images`
/// for capture date / exposure / filter) plus the master's `target_snr` /
/// `target_integration_s` / `improvement_curve_json` v42 columns, and computes:
///
///  * [growthCurve] — cumulative integration time vs calendar date,
///  * [bestNight] — the night with the highest mean integration weight,
///  * [reReferenceAdvice] — an advisory (never auto-applied) re-reference
///    recommendation when a later night materially beats the frozen reference,
///  * [pushDeficitToScheduler] — a target-SNR deficit written back to the
///    scheduler by RAISING `integration_goals.frame_count` per filter via
///    [IntegrationGoalService.upsert].
///
/// This service NEVER touches scheduler scoring or dispatch: the only write it
/// performs is `IntegrationGoalService.upsert` (raising `frame_count`). The
/// engine reads `remainingFrames = frame_count − capturedCount` read-only, so
/// raising `frame_count` is exactly how a "need N more seconds" deficit is
/// expressed.
class SmartProjectService {
  SmartProjectService({
    required db.SkotiqDatabase database,
    required IntegrationGoalService goals,
  }) : _db = database,
       _goals = goals;

  final db.SkotiqDatabase _db;
  final IntegrationGoalService _goals;

  /// Default re-reference advisory threshold: a later night must beat the
  /// frozen reference's mean weight by at least 15% to be recommended.
  static const double defaultReReferenceThreshold = 0.15;

  // Growth curve

  /// Integration-time growth points for [masterId]: cumulative integration
  /// seconds (and accepted-frame count) per observing night the master grew.
  ///
  /// Points are ordered ascending by date; one point per distinct observing
  /// night (noon-to-noon local, see [observingNightOf]), so a single run that
  /// crosses local midnight — or 00:00 UTC — stays one point.
  /// Returns an empty list when the master has no accepted folded subs.
  Future<List<IntegrationGrowthPoint>> growthCurve(int masterId) async {
    final subs = await _foldedSubs(masterId);
    if (subs.isEmpty) return const [];

    // Group accepted subs by observing night, then accumulate.
    final byDay = <DateTime, ({double seconds, int count})>{};
    for (final s in subs) {
      final prev = byDay[s.captureDate];
      byDay[s.captureDate] = (
        seconds: (prev?.seconds ?? 0) + s.exposureSeconds,
        count: (prev?.count ?? 0) + 1,
      );
    }
    final days = byDay.keys.toList()..sort();

    var cumSeconds = 0.0;
    var cumFrames = 0;
    final out = <IntegrationGrowthPoint>[];
    for (final day in days) {
      final entry = byDay[day]!;
      cumSeconds += entry.seconds;
      cumFrames += entry.count;
      out.add(
        IntegrationGrowthPoint(
          date: day,
          cumulativeIntegrationSeconds: cumSeconds,
          framesToDate: cumFrames,
        ),
      );
    }
    return out;
  }

  // Best night

  /// The observing night whose accepted subs carried the highest mean
  /// integration weight. Null when the master has no accepted folded subs.
  Future<BestNight?> bestNight(int masterId) async {
    final subs = await _foldedSubs(masterId);
    if (subs.isEmpty) return null;
    final nights = _meanWeightByNight(subs);
    if (nights.isEmpty) return null;

    BestNight? best;
    for (final n in nights) {
      if (best == null || n.meanWeight > best.meanWeight) best = n;
    }
    return best;
  }

  // Re-reference advisory

  /// Advisory re-reference recommendation for an accumulating master.
  ///
  /// Compares the frozen-reference night (the earliest folded night) against the
  /// best later night by mean weight; recommends re-referencing only when the
  /// later night beats the reference by at least [threshold] (fractional). Never
  /// auto-applied — purely advisory data for the UI.
  Future<ReReferenceAdvice> reReferenceAdvice(
    int masterId, {
    double threshold = defaultReReferenceThreshold,
  }) async {
    final subs = await _foldedSubs(masterId);
    final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    if (subs.isEmpty) return ReReferenceAdvice.none(epoch);

    final nights = _meanWeightByNight(subs)
      ..sort((a, b) => a.date.compareTo(b.date));
    final reference = nights.first;
    if (nights.length < 2) {
      return ReReferenceAdvice(
        recommended: false,
        referenceDate: reference.date,
        referenceMeanWeight: reference.meanWeight,
        candidateDate: null,
        candidateMeanWeight: 0,
        gainFraction: 0,
      );
    }

    // Best of the *later* nights.
    BestNight candidate = nights[1];
    for (final n in nights.skip(1)) {
      if (n.meanWeight > candidate.meanWeight) candidate = n;
    }

    final refWeight = reference.meanWeight;
    final gain = refWeight > 0
        ? (candidate.meanWeight - refWeight) / refWeight
        : 0.0;
    return ReReferenceAdvice(
      recommended: gain >= threshold,
      referenceDate: reference.date,
      referenceMeanWeight: refWeight,
      candidateDate: candidate.date,
      candidateMeanWeight: candidate.meanWeight,
      gainFraction: gain < 0 ? 0 : gain,
    );
  }

  // Target-SNR deficit → scheduler goals (the SAFE write seam)

  /// Estimate the integration shortfall to reach [targetSnr] for [masterId] and
  /// write it back to the scheduler by RAISING `integration_goals.frame_count`
  /// per filter (via [IntegrationGoalService.upsert]).
  ///
  /// The current SNR and the SNR-vs-time relationship come from the master's
  /// persisted `improvement_curve_json` ([IntegrationCurve]); when absent, the
  /// shot-noise model `SNR ∝ sqrt(time)` is used against the master's
  /// accumulated integration time. The deficit seconds are split across the
  /// master's filters proportionally to their existing integration time and
  /// converted to frames at each filter's median exposure.
  ///
  /// Returns [DeficitPushResult.notApplied] when the master already meets the
  /// target, has no target id, or has no folded subs. NEVER touches scheduler
  /// scoring/dispatch — the only mutation is the per-filter `frame_count` raise.
  Future<DeficitPushResult> pushDeficitToScheduler(
    int masterId,
    double targetSnr,
  ) async {
    final master = await _smartRow(masterId);
    if (master == null || master.targetId == null) {
      return DeficitPushResult.notApplied;
    }
    final targetId = master.targetId!;

    final subs = await _foldedSubs(masterId);
    if (subs.isEmpty) return DeficitPushResult.notApplied;

    final totalSeconds = subs.fold<double>(0, (a, s) => a + s.exposureSeconds);
    if (totalSeconds <= 0) return DeficitPushResult.notApplied;

    final currentSnr = _currentSnr(master, subs);
    if (currentSnr <= 0 || targetSnr <= currentSnr) {
      return DeficitPushResult(
        applied: false,
        targetSnr: targetSnr,
        currentSnr: currentSnr,
        deficitSeconds: 0,
        perFilter: const [],
      );
    }

    // Shot-noise: SNR ∝ sqrt(integration time). To go from currentSnr at
    // totalSeconds to targetSnr we need totalSeconds * (target/current)^2; the
    // deficit is that minus what we already have.
    final requiredSeconds =
        totalSeconds * math.pow(targetSnr / currentSnr, 2).toDouble();
    final deficitSeconds = requiredSeconds - totalSeconds;
    if (deficitSeconds <= 0) {
      return DeficitPushResult(
        applied: false,
        targetSnr: targetSnr,
        currentSnr: currentSnr,
        deficitSeconds: 0,
        perFilter: const [],
      );
    }

    // Split the deficit across filters proportional to each filter's existing
    // integration time, and convert to frames at each filter's median exposure.
    final perFilterSeconds = <String, double>{};
    final perFilterExposures = <String, List<double>>{};
    for (final s in subs) {
      perFilterSeconds[s.filter] =
          (perFilterSeconds[s.filter] ?? 0) + s.exposureSeconds;
      (perFilterExposures[s.filter] ??= []).add(s.exposureSeconds);
    }

    final existingGoals = await _goals.listForTarget(targetId);
    final results = <FilterDeficit>[];

    for (final entry in perFilterSeconds.entries) {
      final filter = entry.key;
      final filterSeconds = entry.value;
      final share = filterSeconds / totalSeconds;
      final filterDeficitSeconds = deficitSeconds * share;
      final exposure = _median(perFilterExposures[filter]!);
      if (exposure <= 0) continue;

      final deltaFrames = math.max(1, (filterDeficitSeconds / exposure).ceil());

      // Find an existing goal matching this (filter, exposure). Filter match is
      // case-insensitive to mirror IntegrationGoalService.capturedFrameCount.
      IntegrationGoal? existing;
      for (final g in existingGoals) {
        if (g.filter.toLowerCase() == filter.toLowerCase() &&
            _closeEnough(g.exposureSeconds, exposure)) {
          existing = g;
          break;
        }
      }

      // Idempotency: the deficit is a function of the master's state alone
      // (current vs target SNR, captured count), NOT of the goal's current
      // frame_count — so re-running with the same target must converge, never
      // double-count. We upsert the goal to an ABSOLUTE target,
      // `captured + deltaFrames` (the engine's `remaining = frame_count −
      // captured` then equals exactly the deficit frames), and never lower a
      // larger pre-existing operator goal. Running twice with the same target
      // SNR is a no-op the second time.
      final captured = await _goals.capturedFrameCount(
        targetId: targetId,
        filter: filter,
      );
      final deficitTarget = captured + deltaFrames;
      final int newFrameCount;
      if (existing != null) {
        newFrameCount = math.max(existing.frameCount, deficitTarget);
        await _goals.upsert(existing.copyWith(frameCount: newFrameCount));
      } else {
        newFrameCount = deficitTarget;
        await _goals.upsert(
          IntegrationGoal(
            targetId: targetId,
            filter: filter,
            exposureSeconds: exposure,
            frameCount: newFrameCount,
            createdAt: DateTime.now().toUtc(),
          ),
        );
      }

      results.add(
        FilterDeficit(
          filter: filter,
          exposureSeconds: exposure,
          deltaFrames: deltaFrames,
          newFrameCount: newFrameCount,
        ),
      );
    }

    return DeficitPushResult(
      applied: results.isNotEmpty,
      targetSnr: targetSnr,
      currentSnr: currentSnr,
      deficitSeconds: deficitSeconds,
      perFilter: results,
    );
  }

  // Internals

  /// The master's v42 smart columns (read directly — the typed
  /// [IntegratedMaster] model does not surface them).
  Future<_SmartMasterRow?> _smartRow(int masterId) async {
    final rows = await _db
        .customSelect(
          'SELECT target_id, target_snr, target_integration_s, '
          'improvement_curve_json FROM integrated_masters WHERE id = ? LIMIT 1',
          variables: [Variable<int>(masterId)],
        )
        .get();
    if (rows.isEmpty) return null;
    final r = rows.first;
    return _SmartMasterRow(
      targetId: r.readNullable<int>('target_id'),
      targetSnr: r.readNullable<double>('target_snr'),
      targetIntegrationS: r.readNullable<double>('target_integration_s'),
      improvementCurveJson: r.readNullable<String>('improvement_curve_json'),
    );
  }

  /// The accepted fold log for [masterId], one row per sub, joined to
  /// `captured_images` for capture date / exposure / filter.
  ///
  /// Membership is defined by `accepted = 1` ALONE — every accepted folded sub
  /// is returned, including ones with a null `weight`. The multi-night
  /// (accumulate) path records accepted folds with a null weight, so filtering
  /// on weight here would empty the growth curve, best night and scheduler
  /// deficit for exactly those masters. A null weight is treated as "absent"
  /// only by best-night mean-weight aggregation; it never removes a sub from
  /// the growth / frame-count / deficit totals. A *rejected* sub is recorded
  /// with `accepted = 0` and excluded by the WHERE clause, not by its weight.
  Future<List<_FoldedSub>> _foldedSubs(int masterId) async {
    final rows = await _db
        .customSelect(
          'SELECT f.weight AS weight, f.snr AS snr, '
          'ci.captured_at AS captured_at, ci.exposure_duration AS exposure, '
          'ci.filter AS filter '
          'FROM integrated_master_frames f '
          'JOIN captured_images ci ON ci.id = f.image_id '
          'WHERE f.master_id = ? AND f.accepted = 1 '
          'ORDER BY ci.captured_at ASC',
          variables: [Variable<int>(masterId)],
        )
        .get();

    final out = <_FoldedSub>[];
    for (final r in rows) {
      final capturedAtSec = r.read<int>('captured_at');
      final exposure = r.readNullable<double>('exposure') ?? 0.0;
      out.add(
        _FoldedSub(
          captureDate: observingNightOf(capturedAtSec),
          exposureSeconds: exposure,
          weight: r.readNullable<double>('weight'),
          snr: r.readNullable<double>('snr'),
          filter: (r.readNullable<String>('filter') ?? '').trim(),
        ),
      );
    }
    return out;
  }

  /// Per-night aggregation over the accepted fold log. `frameCount` and
  /// `integrationSeconds` count EVERY accepted sub for the night; `meanWeight` is
  /// averaged only over subs that carry a (non-null) weight, so a night of
  /// null-weight folds still reports its true frame count and integration time
  /// (with `meanWeight` 0 when no sub on that night had a weight).
  List<BestNight> _meanWeightByNight(List<_FoldedSub> subs) {
    final byDay =
        <
          DateTime,
          ({double weightSum, int weighted, double seconds, int count})
        >{};
    for (final s in subs) {
      final prev = byDay[s.captureDate];
      byDay[s.captureDate] = (
        weightSum: (prev?.weightSum ?? 0) + (s.weight ?? 0),
        weighted: (prev?.weighted ?? 0) + (s.weight != null ? 1 : 0),
        seconds: (prev?.seconds ?? 0) + s.exposureSeconds,
        count: (prev?.count ?? 0) + 1,
      );
    }
    final out = <BestNight>[];
    for (final entry in byDay.entries) {
      final v = entry.value;
      out.add(
        BestNight(
          date: entry.key,
          meanWeight: v.weighted > 0 ? v.weightSum / v.weighted : 0,
          frameCount: v.count,
          integrationSeconds: v.seconds,
        ),
      );
    }
    return out;
  }

  /// Latest **achieved** SNR for the master: the last point of the persisted
  /// improvement curve when present, else a shot-noise estimate from the
  /// master's achieved anchor (`target_snr` reached at `target_integration_s`),
  /// else 0.
  ///
  /// NOTE on the anchor's semantics: `target_snr`/`target_integration_s` are an
  /// ACHIEVED measurement (the SNR reached at the accumulated integration time —
  /// the last marginal-SNR curve point written by the integration pipeline), NOT
  /// the user's desired goal. The desired goal is the `targetSnr` parameter of
  /// [pushDeficitToScheduler]. So scaling `anchorSnr * sqrt(achieved/anchorSec)`
  /// is correct: it reconstructs the current SNR from a real achieved anchor.
  double _currentSnr(_SmartMasterRow master, List<_FoldedSub> subs) {
    final curve = _decodeCurve(master.improvementCurveJson);
    if (curve != null && curve.points.isNotEmpty) {
      // The curve's last point is the all-subs prediction (highest n).
      var best = curve.points.first;
      for (final p in curve.points) {
        if (p.n > best.n) best = p;
      }
      if (best.snr > 0) return best.snr;
    }

    // Fallback: anchor on the master's ACHIEVED (target_snr, target_integration_s)
    // and scale by sqrt(time) to the achieved integration time.
    final anchorSnr = master.targetSnr;
    final anchorSeconds = master.targetIntegrationS;
    final achieved = subs.fold<double>(0, (a, s) => a + s.exposureSeconds);
    if (anchorSnr != null &&
        anchorSnr > 0 &&
        anchorSeconds != null &&
        anchorSeconds > 0 &&
        achieved > 0) {
      return anchorSnr * math.sqrt(achieved / anchorSeconds);
    }
    return 0;
  }

  IntegrationCurve? _decodeCurve(String? json) {
    if (json == null || json.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(json);
      if (decoded is Map<String, dynamic>) {
        return IntegrationCurve.fromJson(decoded);
      }
    } catch (_) {
      // Corrupt blob → no curve; the shot-noise fallback takes over.
    }
    return null;
  }

  /// The observing night a capture belongs to, as a local date-only DateTime.
  ///
  /// Nights are bucketed noon-to-noon in the observer's local time — the same
  /// rule `TargetProgressService._nightStart` and the forecast planner use — and
  /// labelled with the date the night *started*. Grouping by UTC calendar day
  /// fails twice over: west of Greenwich every night is labelled a day late
  /// (21:00 EDT is 01:00 UTC the next day), and east of Greenwich the 00:00 UTC
  /// boundary falls in the MIDDLE of the observing night, splitting a single
  /// continuous run into two "nights" and halving its reported totals.
  static DateTime observingNightOf(int epochSeconds) {
    final local = DateTime.fromMillisecondsSinceEpoch(
      epochSeconds * 1000,
      isUtc: true,
    ).toLocal();
    final noonToday = DateTime(local.year, local.month, local.day, 12);
    final nightStart = local.isBefore(noonToday)
        ? noonToday.subtract(const Duration(days: 1))
        : noonToday;
    return DateTime(nightStart.year, nightStart.month, nightStart.day);
  }

  static double _median(List<double> values) {
    if (values.isEmpty) return 0;
    final sorted = [...values]..sort();
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[mid];
    return (sorted[mid - 1] + sorted[mid]) / 2;
  }

  static bool _closeEnough(double a, double b) => (a - b).abs() < 0.5;
}

/// The master's v42 smart columns, read directly off `integrated_masters`.
class _SmartMasterRow {
  final int? targetId;

  /// Achieved-anchor SNR: the SNR reached at [targetIntegrationS] (the last
  /// marginal-SNR curve point). NOT the user's desired goal — that is the
  /// `targetSnr` parameter of [SmartProjectService.pushDeficitToScheduler].
  final double? targetSnr;

  /// Achieved-anchor integration time (seconds) that [targetSnr] was reached at.
  final double? targetIntegrationS;
  final String? improvementCurveJson;

  const _SmartMasterRow({
    required this.targetId,
    required this.targetSnr,
    required this.targetIntegrationS,
    required this.improvementCurveJson,
  });
}

/// Riverpod provider for [SmartProjectService].
final smartProjectServiceProvider = Provider<SmartProjectService>((ref) {
  return SmartProjectService(
    database: ref.watch(databaseProvider),
    goals: ref.watch(integrationGoalServiceProvider),
  );
});
