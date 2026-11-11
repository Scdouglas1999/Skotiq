
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart' as db;
import 'database_provider.dart';
import 'project_tracking_provider.dart';
import 'scheduler_provider.dart' show integrationGoalsStreamProvider;
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

  /// Exposure of the target's accepted light frames, in seconds.
  final double totalIntegrationSecs;

  /// Per-filter frame counts: filter name -> accepted frame count.
  final Map<String, int> filterCounts;

  /// Per-filter integration time in seconds: filter name -> total seconds.
  final Map<String, double> filterIntegrationSecs;

  /// Number of imaging sessions for this target.
  final int sessionCount;

  /// When the target's newest light frame was taken.
  final DateTime? lastImaged;

  /// The target's integration goals in seconds (0 if none).
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
      final allGoals = await ref.watch(integrationGoalsStreamProvider.future);

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

      final progress = ref
          .read(projectTrackingServiceProvider)
          .summarize(
            targets: [matched],
            sessions: allSessions,
            frames: allImages,
            goals: allGoals,
          )
          .single;

      return ImagingHistory(
        target: matched,
        totalIntegrationSecs: progress.integratedSecs,
        filterCounts: {for (final f in progress.filters) f.filter: f.frames},
        filterIntegrationSecs: {
          for (final f in progress.filters) f.filter: f.seconds,
        },
        sessionCount: progress.sessionCount,
        lastImaged: progress.lastImagedAt,
        goalIntegrationSecs: progress.goalIntegrationSecs,
      );
    });
