
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart' as db;
import 'database_provider.dart';
import 'package:skotiq_astro/skotiq_astro.dart';

/// Lookup key for imaging history: object name + J2000 coordinates.
class ImagingHistoryQuery {
  final String objectName;
  final double raHours;
  final double decDegrees;

  const ImagingHistoryQuery({
    required this.objectName,
    required this.raHours,
    required this.decDegrees,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ImagingHistoryQuery &&
          other.objectName == objectName &&
          other.raHours == raHours &&
          other.decDegrees == decDegrees;

  @override
  int get hashCode => Object.hash(objectName, raHours, decDegrees);
}

/// Aggregated imaging history for a celestial object.
class ImagingHistory {
  /// The matched target from the database (null if no match).
  final db.Target? target;

  /// Total integration time across all sessions, in seconds.
  final double totalIntegrationSecs;

  /// Per-filter frame counts: filter name -> accepted frame count.
  final Map<String, int> filterCounts;

  /// Per-filter integration time in seconds: filter name -> total seconds.
  final Map<String, double> filterIntegrationSecs;

  /// Number of imaging sessions for this target.
  final int sessionCount;

  /// When this target was last imaged (end of most recent session).
  final DateTime? lastImaged;

  /// Goal integration time from the target, in seconds (0 if unset).
  final double goalIntegrationSecs;

  const ImagingHistory({
    required this.target,
    required this.totalIntegrationSecs,
    required this.filterCounts,
    required this.filterIntegrationSecs,
    required this.sessionCount,
    required this.lastImaged,
    required this.goalIntegrationSecs,
  });

  /// Completion fraction (0.0 - 1.0), or 0.0 if no goal is set.
  double get completionFraction {
    if (goalIntegrationSecs <= 0) return 0.0;
    return (totalIntegrationSecs / goalIntegrationSecs).clamp(0.0, 1.0);
  }

  /// Whether any imaging data exists.
  bool get hasData => totalIntegrationSecs > 0 || sessionCount > 0;

  bool get hasGoal => goalIntegrationSecs > 0;

  static const empty = ImagingHistory(
    target: null,
    totalIntegrationSecs: 0,
    filterCounts: {},
    filterIntegrationSecs: {},
    sessionCount: 0,
    lastImaged: null,
    goalIntegrationSecs: 0,
  );
}

/// Provider that looks up imaging history for a celestial object by matching
/// against the targets database using name or coordinate proximity (~1 arcmin).
final imagingHistoryProvider =
    FutureProvider.family<ImagingHistory, ImagingHistoryQuery>((
      ref,
      query,
    ) async {
      final allTargets = await ref.watch(allDbTargetsProvider.future);
      final allSessions = await ref.watch(allSessionsProvider.future);
      final allImages = await ref.watch(allDbImagesProvider.future);

      db.Target? matched;

      final queryLower = query.objectName.toLowerCase().trim();

      for (final t in allTargets) {
        if (t.name.toLowerCase().trim() == queryLower) {
          matched = t;
          break;
        }
      }

      // Try catalog ID match if no name match.
      if (matched == null) {
        for (final t in allTargets) {
          if (t.catalogId != null &&
              t.catalogId!.toLowerCase().trim() == queryLower) {
            matched = t;
            break;
          }
        }
      }

      // Try coordinate proximity (~1 arcmin = 1/60 degree).
      if (matched == null) {
        const maxSepArcmin = 1.0;
        double bestSep = double.infinity;

        for (final t in allTargets) {
          final sep =
              AstronomyCalculations.angularSeparation(
                ra1Deg: query.raHours * 15.0,
                dec1Deg: query.decDegrees,
                ra2Deg: t.ra * 15.0,
                dec2Deg: t.dec,
              ) *
              60.0;
          if (sep < maxSepArcmin && sep < bestSep) {
            bestSep = sep;
            matched = t;
          }
        }
      }

      if (matched == null) {
        return ImagingHistory.empty;
      }

      final target = matched;

      final sessions = allSessions
          .where((session) => session.targetId == target.id)
          .toList(growable: false);

      double totalIntegration = 0;
      int sessionCount = sessions.length;
      DateTime? lastImaged;

      for (final s in sessions) {
        totalIntegration += s.totalIntegrationSecs;
        final candidate = s.endTime ?? s.startTime;
        if (lastImaged == null || candidate.isAfter(lastImaged)) {
          lastImaged = candidate;
        }
      }

      final targetImages = allImages
          .where((image) => image.targetId == target.id)
          .toList(growable: false);
      final filterCounts = <String, int>{};
      final filterIntegrationSecs = <String, double>{};
      for (final img in targetImages) {
        if (img.filter != null && img.isAccepted && img.frameType == 'light') {
          filterCounts[img.filter!] = (filterCounts[img.filter!] ?? 0) + 1;
          filterIntegrationSecs[img.filter!] =
              (filterIntegrationSecs[img.filter!] ?? 0.0) +
              img.exposureDuration;
        }
      }

      return ImagingHistory(
        target: target,
        totalIntegrationSecs: totalIntegration,
        filterCounts: filterCounts,
        filterIntegrationSecs: filterIntegrationSecs,
        sessionCount: sessionCount,
        lastImaged: lastImaged,
        goalIntegrationSecs: target.goalIntegrationSecs,
      );
    });
