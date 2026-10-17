import 'package:drift/drift.dart';

import '../database.dart';
import '../tables/observation_logs.dart';

part 'observation_logs_dao.g.dart';

@DriftAccessor(tables: [ObservationLogs])
class ObservationLogsDao extends DatabaseAccessor<SkotiqDatabase>
    with _$ObservationLogsDaoMixin {
  ObservationLogsDao(super.db);

  /// Insert a new observation log entry. Returns the generated row ID.
  Future<int> insertLog({
    required DateTime timestamp,
    required String objectName,
    required double ra,
    required double dec,
    String? objectType,
    String? catalogId,
    double? altitude,
    double? azimuth,
    String? notes,
    int? rating,
    int? equipmentProfileId,
    String? seeingConditions,
    String? transparency,
    String? locationName,
    double? latitude,
    double? longitude,
  }) {
    return into(observationLogs).insert(
      ObservationLogsCompanion.insert(
        timestamp: timestamp,
        objectName: objectName,
        ra: ra,
        dec: dec,
        objectType: Value(objectType),
        catalogId: Value(catalogId),
        altitude: Value(altitude),
        azimuth: Value(azimuth),
        notes: Value(notes),
        rating: Value(rating),
        equipmentProfileId: Value(equipmentProfileId),
        seeingConditions: Value(seeingConditions),
        transparency: Value(transparency),
        locationName: Value(locationName),
        latitude: Value(latitude),
        longitude: Value(longitude),
      ),
    );
  }

  /// Update an existing observation log entry.
  Future<bool> updateLog(ObservationLogEntry entry) {
    return update(observationLogs).replace(entry);
  }

  /// Delete a single observation log entry by ID.
  Future<int> deleteLog(int id) {
    return (delete(observationLogs)..where((t) => t.id.equals(id))).go();
  }

  /// Get a single observation log entry by ID.
  Future<ObservationLogEntry?> getLogById(int id) async {
    final query = select(observationLogs)..where((t) => t.id.equals(id));
    final results = await query.get();
    return results.isEmpty ? null : results.first;
  }

  /// Get all observation logs, ordered by most recent first.
  Future<List<ObservationLogEntry>> getAllLogs({int? limit}) {
    final query = select(observationLogs)
      ..orderBy([(t) => OrderingTerm.desc(t.timestamp)]);
    if (limit != null) {
      query.limit(limit);
    }
    return query.get();
  }

  /// Watch all observation logs as a reactive stream (most recent first).
  Stream<List<ObservationLogEntry>> watchAllLogs({int? limit}) {
    final query = select(observationLogs)
      ..orderBy([(t) => OrderingTerm.desc(t.timestamp)]);
    if (limit != null) {
      query.limit(limit);
    }
    return query.watch();
  }

  /// Get observation logs within a date range.
  Future<List<ObservationLogEntry>> getLogsByDateRange({
    required DateTime start,
    required DateTime end,
  }) {
    final query = select(observationLogs)
      ..where(
        (t) =>
            t.timestamp.isBiggerOrEqualValue(start) &
            t.timestamp.isSmallerOrEqualValue(end),
      )
      ..orderBy([(t) => OrderingTerm.desc(t.timestamp)]);
    return query.get();
  }

  /// Get observation logs for a specific object (by catalog ID or name).
  Future<List<ObservationLogEntry>> getLogsByObject(String objectQuery) {
    final query = select(observationLogs)
      ..where(
        (t) =>
            t.objectName.like('%$objectQuery%') |
            t.catalogId.like('%$objectQuery%'),
      )
      ..orderBy([(t) => OrderingTerm.desc(t.timestamp)]);
    return query.get();
  }

  /// Get observation logs filtered by rating.
  Future<List<ObservationLogEntry>> getLogsByMinRating(int minRating) {
    final query = select(observationLogs)
      ..where((t) => t.rating.isBiggerOrEqualValue(minRating))
      ..orderBy([(t) => OrderingTerm.desc(t.timestamp)]);
    return query.get();
  }

  /// Get observation logs for a specific equipment profile.
  Future<List<ObservationLogEntry>> getLogsByProfile(int profileId) {
    final query = select(observationLogs)
      ..where((t) => t.equipmentProfileId.equals(profileId))
      ..orderBy([(t) => OrderingTerm.desc(t.timestamp)]);
    return query.get();
  }

  /// Get all distinct catalog IDs that have been observed.
  /// Useful for planetarium marker rendering.
  Future<Set<String>> getObservedCatalogIds() async {
    final query = selectOnly(observationLogs, distinct: true)
      ..addColumns([observationLogs.catalogId])
      ..where(observationLogs.catalogId.isNotNull());
    final results = await query
        .map((row) => row.read(observationLogs.catalogId))
        .get();
    return results.whereType<String>().toSet();
  }

  /// Get all distinct object names that have been observed.
  /// Useful for planetarium marker rendering.
  Future<Set<String>> getObservedObjectNames() async {
    final query = selectOnly(observationLogs, distinct: true)
      ..addColumns([observationLogs.objectName]);
    final results = await query
        .map((row) => row.read(observationLogs.objectName))
        .get();
    return results.whereType<String>().toSet();
  }

  /// Watch the set of observed catalog IDs as a reactive stream.
  Stream<Set<String>> watchObservedCatalogIds() {
    final query = selectOnly(observationLogs, distinct: true)
      ..addColumns([observationLogs.catalogId])
      ..where(observationLogs.catalogId.isNotNull());
    return query
        .map((row) => row.read(observationLogs.catalogId))
        .watch()
        .map((list) => list.whereType<String>().toSet());
  }

  /// Export all observation logs as a list of maps suitable for CSV generation.
  Future<List<Map<String, dynamic>>> exportAllLogs() async {
    final logs = await getAllLogs();
    return logs
        .map(
          (log) => {
            'id': log.id,
            'timestamp': log.timestamp.toIso8601String(),
            'object_name': log.objectName,
            'object_type': log.objectType ?? '',
            'catalog_id': log.catalogId ?? '',
            'ra': log.ra,
            'dec': log.dec,
            'altitude': log.altitude ?? '',
            'azimuth': log.azimuth ?? '',
            'notes': log.notes ?? '',
            'rating': log.rating ?? '',
            'seeing_conditions': log.seeingConditions ?? '',
            'transparency': log.transparency ?? '',
            'location_name': log.locationName ?? '',
            'latitude': log.latitude ?? '',
            'longitude': log.longitude ?? '',
          },
        )
        .toList();
  }

  /// Generate CSV string of all observation logs.
  Future<String> exportToCsv() async {
    return observationLogsToCsv(await getAllLogs());
  }

  /// Get total count of observation logs.
  Future<int> getLogCount() async {
    final countExpr = observationLogs.id.count();
    final query = selectOnly(observationLogs)..addColumns([countExpr]);
    final result = await query.map((row) => row.read(countExpr)).getSingle();
    return result ?? 0;
  }

  /// Paginated listing for the remote read API ("notes journal").
  /// Filter by [equipmentProfileId] when provided. Newest-first by
  /// `timestamp`. Caller MUST validate / clamp [limit] / [offset].
  Future<List<ObservationLogEntry>> listPaginated({
    int? equipmentProfileId,
    int limit = 200,
    int offset = 0,
  }) {
    final query = select(observationLogs)
      ..orderBy([(t) => OrderingTerm.desc(t.timestamp)])
      ..limit(limit, offset: offset);
    if (equipmentProfileId != null) {
      query.where((t) => t.equipmentProfileId.equals(equipmentProfileId));
    }
    return query.get();
  }

  /// Row count matching [listPaginated]'s filter.
  Future<int> countFiltered({int? equipmentProfileId}) async {
    final countExpr = observationLogs.id.count();
    final query = selectOnly(observationLogs)..addColumns([countExpr]);
    if (equipmentProfileId != null) {
      query.where(
        observationLogs.equipmentProfileId.equals(equipmentProfileId),
      );
    }
    final row = await query.getSingle();
    return row.read(countExpr) ?? 0;
  }

  /// Get observation statistics.
  Future<ObservationLogStats> getStats() async {
    final logs = await getAllLogs();
    if (logs.isEmpty) {
      return const ObservationLogStats(
        totalObservations: 0,
        uniqueObjects: 0,
        averageRating: 0,
        firstObservation: null,
        lastObservation: null,
      );
    }

    final uniqueObjects = <String>{};
    double ratingSum = 0;
    int ratedCount = 0;

    for (final log in logs) {
      uniqueObjects.add(log.catalogId ?? log.objectName);
      if (log.rating != null) {
        ratingSum += log.rating!;
        ratedCount++;
      }
    }

    return ObservationLogStats(
      totalObservations: logs.length,
      uniqueObjects: uniqueObjects.length,
      averageRating: ratedCount > 0 ? ratingSum / ratedCount : 0,
      firstObservation: logs.last.timestamp,
      lastObservation: logs.first.timestamp,
    );
  }

  /// Delete all observation logs for a specific equipment profile.
  Future<int> deleteLogsForProfile(int profileId) {
    return (delete(
      observationLogs,
    )..where((t) => t.equipmentProfileId.equals(profileId))).go();
  }

  /// Delete all observation logs.
  Future<int> deleteAllLogs() {
    return delete(observationLogs).go();
  }
}

/// Encode observation logs using the same CSV schema on both local and remote
/// clients. Keeping this pure avoids touching the controller's database when a
/// remote client exports the host-polled rows.
String observationLogsToCsv(Iterable<ObservationLogEntry> logs) {
  final rows = logs
      .map(
        (log) => <String, dynamic>{
          'id': log.id,
          'timestamp': log.timestamp.toIso8601String(),
          'object_name': log.objectName,
          'object_type': log.objectType ?? '',
          'catalog_id': log.catalogId ?? '',
          'ra': log.ra,
          'dec': log.dec,
          'altitude': log.altitude ?? '',
          'azimuth': log.azimuth ?? '',
          'notes': log.notes ?? '',
          'rating': log.rating ?? '',
          'seeing_conditions': log.seeingConditions ?? '',
          'transparency': log.transparency ?? '',
          'location_name': log.locationName ?? '',
          'latitude': log.latitude ?? '',
          'longitude': log.longitude ?? '',
        },
      )
      .toList(growable: false);
  if (rows.isEmpty) return '';

  final headers = rows.first.keys.join(',');
  final dataRows = rows.map((row) {
    return row.values
        .map((value) {
          final text = value.toString();
          if (text.contains(',') || text.contains('"') || text.contains('\n')) {
            return '"${text.replaceAll('"', '""')}"';
          }
          return text;
        })
        .join(',');
  });
  return [headers, ...dataRows].join('\n');
}

/// Summary statistics for observation logs.
class ObservationLogStats {
  final int totalObservations;
  final int uniqueObjects;
  final double averageRating;
  final DateTime? firstObservation;
  final DateTime? lastObservation;

  const ObservationLogStats({
    required this.totalObservations,
    required this.uniqueObjects,
    required this.averageRating,
    required this.firstObservation,
    required this.lastObservation,
  });
}
