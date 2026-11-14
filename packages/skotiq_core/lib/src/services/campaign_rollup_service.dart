import '../models/imaging/frame_type_record.dart';
import '../database/daos/targets_dao.dart';
import '../database/database.dart';
import '../models/campaign_rollup.dart';
import 'project_tracking_service.dart';
import 'scheduler/integration_goal_service.dart';
import '../models/scheduler/integration_goal.dart';
import '../backend/roles/host_data/imaging_records.dart';

/// Builds a multi-night [CampaignRollup] for one target (Feature B).
///
/// Pure read-only derivation: aggregates rows from `imaging_sessions`,
/// `captured_images`, and `integration_goals`. No background state, no
/// timers, no notifications — the panel can re-call `buildForTarget` at
/// any time and the answer will reflect the current database state.
///
/// Filter matching is **case-insensitive**, matching the rest of the
/// scheduler stack — operators typing 'Lum' should not see different
/// numbers from a session that captured frames labelled 'L'. We collapse
/// to lowercase internally and surface the most common original-case label
/// in the rollup so the UI doesn't show 'l' / 'lum' / 'LUM' separately.
class CampaignRollupService {
  final ImagingRecords _records;
  final TargetsDao _targetsDao;
  final IntegrationGoalService _goalService;

  CampaignRollupService({
    required ImagingRecords records,
    required TargetsDao targetsDao,
    required IntegrationGoalService goalService,
  }) : _records = records,
       _targetsDao = targetsDao,
       _goalService = goalService;

  /// Throws when [targetId] does not exist — same fail-loud policy as
  /// `SessionReportService.buildReport`.
  Future<CampaignRollup> buildForTarget(
    int targetId, {
    Iterable<DbTarget>? targetCatalog,
  }) async {
    DbTarget? target;
    if (targetCatalog != null) {
      for (final candidate in targetCatalog) {
        if (candidate.id == targetId) {
          target = candidate;
          break;
        }
      }
    } else {
      target = await _targetsDao.getTargetById(targetId);
    }
    if (target == null) {
      throw StateError('Target $targetId not found');
    }
    return _build(target);
  }

  /// Convenience for the analytics panel: bulk-load every target in the
  /// catalog. Returns rollups keyed by target id; targets with no sessions
  /// still appear with empty per-filter / per-session lists so the panel
  /// can render "no captures yet" tiles.
  Future<Map<int, CampaignRollup>> buildForAllTargets({
    Iterable<DbTarget>? targetCatalog,
  }) async {
    final targets =
        targetCatalog?.toList(growable: false) ??
        await _targetsDao.getAllTargets();
    final out = <int, CampaignRollup>{};
    for (final target in targets) {
      out[target.id] = await _build(target);
    }
    return out;
  }

  Future<CampaignRollup> _build(DbTarget target) async {
    final imagesForTarget = await _records.getImagesForTarget(target.id);
    final namingSessions = await _records.getSessionsForTarget(target.id);
    final sessionIds = targetSessionIds(
      target.id,
      frames: imagesForTarget,
      sessions: namingSessions,
    );
    final allSessions = [
      for (final session in namingSessions)
        if (sessionIds.contains(session.id)) session,
    ];
    for (final id in sessionIds) {
      if (allSessions.any((s) => s.id == id)) continue;
      final session = await _records.getSessionById(id);
      if (session != null) allSessions.add(session);
    }
    final lightFrames = imagesForTarget
        .where((i) => i.isLight)
        .toList(growable: false);

    final accepted = acceptedLightsByFilter(lightFrames);
    final goals = await _goalService.listForTarget(target.id);
    final goal = TargetGoal.of(
      accepted: accepted,
      goals: goals,
      oldTotalGoalSecs: target.goalIntegrationSecs,
    );
    final filters = _filterRows(accepted, goals);

    final targetSecsBySession = <int, double>{};
    for (final frame in lightFrames) {
      final id = frame.sessionId;
      if (id == null) continue;
      targetSecsBySession[id] =
          (targetSecsBySession[id] ?? 0) + frame.exposureDuration;
    }
    final sessionRefs = allSessions
        .map(
          (s) => CampaignSessionRef(
            sessionId: s.id,
            sessionName: s.name,
            startTime: s.startTime,
            endTime: s.endTime,
            status: s.status,
            sessionIntegrationSecs: targetSecsBySession[s.id] ?? 0.0,
            avgHfr: s.avgHfr,
            avgGuidingRms: s.avgGuidingRms,
            avgSeeing: s.avgSeeing,
          ),
        )
        .toList(growable: false);
    sessionRefs.sort((a, b) => b.startTime.compareTo(a.startTime));

    DateTime? firstAt;
    DateTime? lastAt;
    for (final s in sessionRefs) {
      if (firstAt == null || s.startTime.isBefore(firstAt)) {
        firstAt = s.startTime;
      }
      if (lastAt == null || s.startTime.isAfter(lastAt)) lastAt = s.startTime;
    }

    final totalCapturedSecs = filters.fold<double>(
      0.0,
      (sum, f) => sum + f.capturedIntegrationSecs,
    );

    final hfrInputs = <_WeightedSample>[];
    final seeingInputs = <double>[];
    final efficiencyInputs = <double>[];
    for (final s in allSessions) {
      if (s.avgHfr != null) {
        final weight = s.successfulExposures > 0
            ? s.successfulExposures.toDouble()
            : 1.0;
        hfrInputs.add(_WeightedSample(value: s.avgHfr!, weight: weight));
      }
      if (s.avgSeeing != null) seeingInputs.add(s.avgSeeing!);
      // Efficiency only makes sense for closed sessions; an active session
      // would skew downward as the clock advances.
      final end = s.endTime;
      if (end != null && s.totalIntegrationSecs > 0.0) {
        final wallSecs = end.difference(s.startTime).inMilliseconds / 1000.0;
        if (wallSecs > 0.0) {
          final eff = (s.totalIntegrationSecs / wallSecs).clamp(0.0, 1.0);
          efficiencyInputs.add(eff);
        }
      }
    }

    double? weightedMean(List<_WeightedSample> samples) {
      if (samples.isEmpty) return null;
      var sum = 0.0;
      var weightSum = 0.0;
      for (final s in samples) {
        sum += s.value * s.weight;
        weightSum += s.weight;
      }
      if (weightSum <= 0) return null;
      return sum / weightSum;
    }

    double? simpleMean(List<double> samples) {
      if (samples.isEmpty) return null;
      return samples.reduce((a, b) => a + b) / samples.length;
    }

    return CampaignRollup(
      targetId: target.id,
      targetName: target.name,
      sessions: sessionRefs,
      filters: filters,
      firstSessionAt: firstAt,
      lastSessionAt: lastAt,
      totalCapturedIntegrationSecs: totalCapturedSecs,
      allFiltersGoalSecs: goal.allFilters ? goal.goalSecs : null,
      goalDoneSecs: goal.doneSecs,
      meanSessionHfr: weightedMean(hfrInputs),
      meanSessionSeeing: simpleMean(seeingInputs),
      meanEffectiveImagingFraction: simpleMean(efficiencyInputs) ?? 0.0,
      generatedAt: DateTime.now(),
    );
  }

  /// One row per goal, holding the share of its filter's accepted time that
  /// goal counts ([acceptedPerGoal]), then one row per captured filter no goal
  /// names. A goal with no frames yet still has its row, so the panel shows
  /// the goal before the first night.
  List<CampaignFilterRollup> _filterRows(
    List<FilterIntegration> accepted,
    List<IntegrationGoal> goals,
  ) {
    final shares = acceptedPerGoal(accepted, goals);
    final named = <String>{};
    final rows = <CampaignFilterRollup>[];
    for (var i = 0; i < goals.length; i++) {
      final goal = goals[i];
      final share = shares[i];
      // The spelling the frames carry, which also names the unfiltered group.
      final group = acceptedInGoalFilter(accepted, goal.filter);
      named.add(group.filter.toLowerCase());
      rows.add(
        CampaignFilterRollup(
          filter: group.filter.trim().isEmpty ? 'Unfiltered' : group.filter,
          capturedFrames: share.frames,
          capturedIntegrationSecs: share.seconds,
          goalExposureSecs: goal.exposureSeconds,
          goalFrames: goal.frameCount,
          meanCapturedExposureSecs: group.frames > 0
              ? group.seconds / group.frames
              : null,
        ),
      );
    }
    for (final f in accepted) {
      if (named.contains(f.filter.toLowerCase())) continue;
      rows.add(
        CampaignFilterRollup(
          filter: f.filter,
          capturedFrames: f.frames,
          capturedIntegrationSecs: f.seconds,
          goalExposureSecs: null,
          goalFrames: null,
          meanCapturedExposureSecs: f.frames > 0 ? f.seconds / f.frames : null,
        ),
      );
    }
    // Sorted by index so two goals in one filter keep their goal order.
    final order = List<int>.generate(rows.length, (i) => i)
      ..sort((a, b) {
        final byName = rows[a].filter.toLowerCase().compareTo(
          rows[b].filter.toLowerCase(),
        );
        return byName != 0 ? byName : a.compareTo(b);
      });
    return [for (final i in order) rows[i]];
  }
}

class _WeightedSample {
  final double value;
  final double weight;

  const _WeightedSample({required this.value, required this.weight});
}
