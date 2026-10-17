import '../database/daos/targets_dao.dart';
import 'imaging_records_repository.dart';
import '../database/database.dart';
import '../models/campaign_rollup.dart';
import 'scheduler/integration_goal_service.dart';

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
  final ImagingRecordsRepository _records;
  final TargetsDao _targetsDao;
  final IntegrationGoalService _goalService;

  CampaignRollupService({
    required ImagingRecordsRepository records,
    required TargetsDao targetsDao,
    required IntegrationGoalService goalService,
  }) : _records = records,
       _targetsDao = targetsDao,
       _goalService = goalService;

  /// Throws when [targetId] does not exist — same fail-loud policy as
  /// `SessionReportService.buildReport`.
  Future<CampaignRollup> buildForTarget(
    int targetId, {
    Iterable<Target>? targetCatalog,
  }) async {
    Target? target;
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
    Iterable<Target>? targetCatalog,
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

  Future<CampaignRollup> _build(Target target) async {
    final allSessions = await _records.getSessionsForTarget(target.id);
    final imagesForTarget = await _records.getImagesForTarget(target.id);
    final lightFrames = imagesForTarget
        .where((i) => i.frameType == 'light' && i.isAccepted)
        .toList(growable: false);

    final filters = _buildFilters(lightFrames, target.id);
    // Honor goals even when no light frames have been captured yet so the
    // UI can show a 0% progress bar for the new campaign.
    await _attachGoalsToFilters(filters, target.id);

    final sessionRefs = allSessions
        .map(
          (s) => CampaignSessionRef(
            sessionId: s.id,
            sessionName: s.name,
            startTime: s.startTime,
            endTime: s.endTime,
            status: s.status,
            sessionIntegrationSecs: s.totalIntegrationSecs,
            avgHfr: s.avgHfr,
            avgGuidingRms: s.avgGuidingRms,
            avgSeeing: s.avgSeeing,
          ),
        )
        .toList(growable: false);
    // Sorted descending so the most recent session is at the top.
    sessionRefs.sort((a, b) => b.startTime.compareTo(a.startTime));

    DateTime? firstAt;
    DateTime? lastAt;
    for (final s in sessionRefs) {
      if (firstAt == null || s.startTime.isBefore(firstAt)) {
        firstAt = s.startTime;
      }
      if (lastAt == null || s.startTime.isAfter(lastAt)) lastAt = s.startTime;
    }

    final totalCapturedSecs = lightFrames.fold<double>(
      0.0,
      (sum, f) => sum + f.exposureDuration,
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
      meanSessionHfr: weightedMean(hfrInputs),
      meanSessionSeeing: simpleMean(seeingInputs),
      meanEffectiveImagingFraction: simpleMean(efficiencyInputs) ?? 0.0,
      generatedAt: DateTime.now(),
    );
  }

  /// Build the per-filter rollup from accepted light frames; we lowercase
  /// for grouping but pick the most-frequently-occurring original-case
  /// label so the UI doesn't show 'L' / 'l' / 'Lum' as separate rows for
  /// the same filter.
  List<CampaignFilterRollup> _buildFilters(
    List<CapturedImage> lightFrames,
    int targetId,
  ) {
    final byLowerFilter = <String, _FilterBucket>{};
    for (final f in lightFrames) {
      final raw = (f.filter == null || f.filter!.isEmpty)
          ? 'Unfiltered'
          : f.filter!;
      final key = raw.toLowerCase();
      final bucket = byLowerFilter.putIfAbsent(key, () => _FilterBucket());
      bucket.totalFrames++;
      bucket.totalSecs += f.exposureDuration;
      bucket.labelCounts[raw] = (bucket.labelCounts[raw] ?? 0) + 1;
    }

    final out = <CampaignFilterRollup>[];
    for (final entry in byLowerFilter.entries) {
      final bucket = entry.value;
      final label = bucket.pickLabel();
      out.add(
        CampaignFilterRollup(
          filter: label,
          capturedFrames: bucket.totalFrames,
          capturedIntegrationSecs: bucket.totalSecs,
          goalExposureSecs: null,
          goalFrames: null,
          meanCapturedExposureSecs: bucket.totalFrames > 0
              ? bucket.totalSecs / bucket.totalFrames
              : null,
        ),
      );
    }
    out.sort(
      (a, b) => a.filter.toLowerCase().compareTo(b.filter.toLowerCase()),
    );
    return out;
  }

  /// Merge integration-goal rows into the per-filter list. Goals that have
  /// no captured frames yet are appended as zero-frame rows so the panel
  /// can show the goal even before the first night.
  Future<void> _attachGoalsToFilters(
    List<CampaignFilterRollup> filters,
    int targetId,
  ) async {
    final goals = await _goalService.listForTarget(targetId);
    if (goals.isEmpty) return;
    final byKey = <String, CampaignFilterRollup>{
      for (final f in filters) f.filter.toLowerCase(): f,
    };
    final merged = <CampaignFilterRollup>[];
    final consumed = <String>{};
    // First update existing filter rows in place by replacement.
    for (final goal in goals) {
      final key = goal.filter.toLowerCase();
      final existing = byKey[key];
      if (existing != null) {
        merged.add(
          CampaignFilterRollup(
            filter: existing.filter,
            capturedFrames: existing.capturedFrames,
            capturedIntegrationSecs: existing.capturedIntegrationSecs,
            goalExposureSecs: goal.exposureSeconds,
            goalFrames: goal.frameCount,
            meanCapturedExposureSecs: existing.meanCapturedExposureSecs,
          ),
        );
        consumed.add(key);
      } else {
        // Goal exists with no captured frames yet — show a goal-only row.
        merged.add(
          CampaignFilterRollup(
            filter: goal.filter,
            capturedFrames: 0,
            capturedIntegrationSecs: 0.0,
            goalExposureSecs: goal.exposureSeconds,
            goalFrames: goal.frameCount,
            meanCapturedExposureSecs: null,
          ),
        );
      }
    }
    // Carry through any captured filters with no matching goal.
    for (final entry in byKey.entries) {
      if (!consumed.contains(entry.key)) merged.add(entry.value);
    }
    merged.sort(
      (a, b) => a.filter.toLowerCase().compareTo(b.filter.toLowerCase()),
    );
    filters
      ..clear()
      ..addAll(merged);
  }
}

class _WeightedSample {
  final double value;
  final double weight;

  const _WeightedSample({required this.value, required this.weight});
}

class _FilterBucket {
  int totalFrames = 0;
  double totalSecs = 0.0;
  final Map<String, int> labelCounts = <String, int>{};

  /// Pick the most common original-case label as the display name; ties
  /// fall back to alphabetical order for determinism.
  String pickLabel() {
    String? best;
    int bestCount = -1;
    final keys = labelCounts.keys.toList()..sort();
    for (final key in keys) {
      final c = labelCounts[key]!;
      if (c > bestCount) {
        bestCount = c;
        best = key;
      }
    }
    return best ?? 'Unfiltered';
  }
}
