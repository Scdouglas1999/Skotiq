import 'package:drift/drift.dart';

import '../database.dart';
import '../tables/flat_history.dart';

part 'flat_history_dao.g.dart';

@DriftAccessor(tables: [FlatHistory])
class FlatHistoryDao extends DatabaseAccessor<SkotiqDatabase>
    with _$FlatHistoryDaoMixin {
  FlatHistoryDao(super.db);

  /// Get recent calibrations for a filter, optionally filtered by equipment profile
  Future<List<FlatHistoryEntry>> getRecentCalibrations({
    required String filterName,
    int? equipmentProfileId,
    int limit = 10,
  }) {
    final query = select(flatHistory)
      ..where((t) => t.filterName.equals(filterName))
      ..orderBy([(t) => OrderingTerm.desc(t.timestamp)])
      ..limit(limit);

    if (equipmentProfileId != null) {
      query.where((t) => t.equipmentProfileId.equals(equipmentProfileId));
    }

    return query.get();
  }

  /// Get suggested starting exposure based on historical data
  /// Returns average of last N successful calibrations for this filter
  Future<double?> getSuggestedExposure({
    required String filterName,
    int? equipmentProfileId,
    int sampleSize = 5,
  }) async {
    final entries = await getRecentCalibrations(
      filterName: filterName,
      equipmentProfileId: equipmentProfileId,
      limit: sampleSize,
    );

    if (entries.isEmpty) return null;

    final sum = entries.fold<double>(0, (sum, e) => sum + e.exposureTime);
    return sum / entries.length;
  }

  /// Record a successful calibration
  Future<int> recordCalibration({
    required String filterName,
    required double exposureTime,
    required double histogramTarget,
    required int actualAdu,
    int? equipmentProfileId,
    int? panelBrightness,
    double? skyAduRate,
    String? twilightPhase,
    int gain = 0,
    int binning = 1,
  }) {
    return into(flatHistory).insert(
      FlatHistoryCompanion.insert(
        filterName: filterName,
        exposureTime: exposureTime,
        histogramTarget: histogramTarget,
        actualAdu: actualAdu,
        equipmentProfileId: Value(equipmentProfileId),
        panelBrightness: Value(panelBrightness),
        skyAduRate: Value(skyAduRate),
        twilightPhase: Value(twilightPhase),
        gain: Value(gain),
        binning: Value(binning),
      ),
    );
  }

  /// Remote calibration API — fetch by id.
  Future<FlatHistoryEntry?> getById(int id) {
    return (select(
      flatHistory,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// Remote calibration API — filtered listing.
  ///
  /// Arguments are independent filters; null/missing means "no constraint".
  /// Returns newest-first up to [limit] rows. Callers MUST validate and
  /// clamp [limit] at the handler layer before delegating here.
  Future<List<FlatHistoryEntry>> listFiltered({
    String? filterName,
    int? equipmentProfileId,
    int? gain,
    DateTime? since,
    int limit = 100,
  }) {
    var query = select(flatHistory)
      ..orderBy([(t) => OrderingTerm.desc(t.timestamp)])
      ..limit(limit);

    if (filterName != null) {
      query = query..where((t) => t.filterName.equals(filterName));
    }
    if (equipmentProfileId != null) {
      query = query
        ..where((t) => t.equipmentProfileId.equals(equipmentProfileId));
    }
    if (gain != null) {
      query = query..where((t) => t.gain.equals(gain));
    }
    if (since != null) {
      query = query..where((t) => t.timestamp.isBiggerOrEqualValue(since));
    }
    return query.get();
  }

  /// Insert a flat-history row from API input. Companion-based so
  /// optional fields preserve their nullability.
  Future<int> insertEntry(FlatHistoryCompanion entry) {
    return into(flatHistory).insert(entry);
  }

  /// Paginated listing for the remote read API. Newest-first by
  /// `timestamp`. The `?panelKey=` query parameter falls onto
  /// `panelBrightness` (no separate panel-id column in this table —
  /// callers can stringify their panel-brightness mapping). Callers MUST
  /// validate / clamp [limit] and [offset].
  Future<List<FlatHistoryEntry>> listPaginated({
    String? filterName,
    int? panelBrightness,
    int limit = 200,
    int offset = 0,
  }) {
    var query = select(flatHistory)
      ..orderBy([(t) => OrderingTerm.desc(t.timestamp)])
      ..limit(limit, offset: offset);
    if (filterName != null) {
      query = query..where((t) => t.filterName.equals(filterName));
    }
    if (panelBrightness != null) {
      query = query..where((t) => t.panelBrightness.equals(panelBrightness));
    }
    return query.get();
  }

  /// Row count matching [listPaginated]'s filters.
  Future<int> countFiltered({String? filterName, int? panelBrightness}) async {
    final countExpr = flatHistory.id.count();
    final query = selectOnly(flatHistory)..addColumns([countExpr]);
    if (filterName != null) {
      query.where(flatHistory.filterName.equals(filterName));
    }
    if (panelBrightness != null) {
      query.where(flatHistory.panelBrightness.equals(panelBrightness));
    }
    final row = await query.getSingle();
    return row.read(countExpr) ?? 0;
  }

  /// Delete a single flat-history row by id. Returns number of
  /// rows affected (0 or 1) so the handler can map 0 to 404.
  Future<int> deleteById(int id) {
    return (delete(flatHistory)..where((t) => t.id.equals(id))).go();
  }

  /// Recommendation source for the headless calibration API.
  ///
  /// Searches the most recent matching [FlatHistoryEntry] for the given
  /// filter/profile/gain combination. Returns null when no row matches.
  /// The caller derives an age-based confidence label (`high` / `medium` /
  /// `low`) from `entry.timestamp`.
  Future<FlatHistoryEntry?> findMostRecentMatch({
    required String filterName,
    int? equipmentProfileId,
    int? gain,
  }) async {
    var query = select(flatHistory)
      ..where((t) => t.filterName.equals(filterName))
      ..orderBy([(t) => OrderingTerm.desc(t.timestamp)])
      ..limit(1);

    if (equipmentProfileId != null) {
      query = query
        ..where((t) => t.equipmentProfileId.equals(equipmentProfileId));
    }
    if (gain != null) {
      query = query..where((t) => t.gain.equals(gain));
    }
    return query.getSingleOrNull();
  }

  /// Clear old history entries (keep last N per filter)
  Future<void> pruneHistory({int keepPerFilter = 50}) async {
    await transaction(() async {
      // Get distinct filter names
      final filters =
          await (selectOnly(flatHistory, distinct: true)
                ..addColumns([flatHistory.filterName]))
              .map((row) => row.read(flatHistory.filterName)!)
              .get();

      for (final filter in filters) {
        // Get IDs to keep
        final keepIds =
            await (select(flatHistory)
                  ..where((t) => t.filterName.equals(filter))
                  ..orderBy([(t) => OrderingTerm.desc(t.timestamp)])
                  ..limit(keepPerFilter))
                .map((e) => e.id)
                .get();

        if (keepIds.isNotEmpty) {
          // Delete entries not in keep list
          await (delete(flatHistory)..where(
                (t) => t.filterName.equals(filter) & t.id.isNotIn(keepIds),
              ))
              .go();
        }
      }
    });
  }
}
