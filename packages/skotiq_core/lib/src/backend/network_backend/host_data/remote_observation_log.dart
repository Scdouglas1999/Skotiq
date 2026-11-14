import 'package:flutter/foundation.dart' show listEquals, setEquals;

import '../../../database/daos/observation_logs_dao.dart';
import '../../../database/database.dart' show ObservationLogEntry;
import '../../network_backend.dart';
import '../../roles/host_data/observation_log.dart';
import 'host_poll.dart';

/// The observation log of a linked host, read through its notes journal
/// (`/api/notes-journal` serves the `observation_logs` table).
final class RemoteObservationLog implements ObservationLog {
  RemoteObservationLog(this._host);

  final NetworkBackend _host;
  final _poll = HostPoll('observation log');

  /// The list the last fetch returned, so the statistics describe the same
  /// entries the list on screen shows without a second round of requests.
  List<ObservationLogEntry>? _latest;

  @override
  Stream<List<ObservationLogEntry>> watchAllLogs() =>
      _poll.watch(_fetch, listEquals);

  @override
  Stream<Set<String>> watchObservedCatalogIds() => _poll.watch(
    () async => {
      for (final log in await _fetch())
        if (log.catalogId != null && log.catalogId!.isNotEmpty) log.catalogId!,
    },
    setEquals,
  );

  @override
  Future<ObservationLogStats> getStats() async =>
      _statsFromLogs(_latest ?? await _fetch());

  @override
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
  }) => _changing(
    () => _host.createObservationLog(
      timestamp: timestamp,
      objectName: objectName,
      ra: ra,
      dec: dec,
      objectType: objectType,
      catalogId: catalogId,
      altitude: altitude,
      azimuth: azimuth,
      notes: notes,
      rating: rating,
      equipmentProfileId: equipmentProfileId,
      seeingConditions: seeingConditions,
      transparency: transparency,
      locationName: locationName,
      latitude: latitude,
      longitude: longitude,
    ),
  );

  @override
  Future<void> deleteLog(int id) =>
      _changing(() => _host.deleteObservationLog(id));

  @override
  Future<int?> deleteAllLogs() async {
    await _changing(_host.deleteAllObservationLogs);
    return null;
  }

  @override
  Future<String> exportToCsv() async => observationLogsToCsv(await _fetch());

  Future<T> _changing<T>(Future<T> Function() write) async {
    try {
      return await write();
    } finally {
      _latest = null;
      _poll.refresh();
    }
  }

  Future<List<ObservationLogEntry>> _fetch() async {
    const pageSize = 1000;
    final rows = <RemoteNotesJournalEntry>[];
    var offset = 0;
    while (true) {
      final page = await _host.fetchNotesJournal(
        limit: pageSize,
        offset: offset,
      );
      rows.addAll(page.items);
      offset += page.items.length;
      if (offset >= page.total || page.items.isEmpty) break;
    }

    // The host orders newest first already; sorting keeps `.first`/`.last` in
    // [_statsFromLogs] right even if a page boundary reorders ties.
    return _latest = rows.map(_observationLogFromRemote).toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  }
}

ObservationLogEntry _observationLogFromRemote(RemoteNotesJournalEntry row) {
  return ObservationLogEntry(
    id: row.id,
    timestamp: row.timestamp,
    objectName: row.objectName,
    objectType: row.objectType,
    catalogId: row.catalogId,
    ra: row.ra,
    dec: row.dec,
    altitude: row.altitude,
    azimuth: row.azimuth,
    notes: row.notes,
    rating: row.rating,
    equipmentProfileId: row.equipmentProfileId,
    seeingConditions: row.seeingConditions,
    transparency: row.transparency,
    locationName: row.locationName,
    latitude: row.latitude,
    longitude: row.longitude,
  );
}

/// The summary the local DAO's `getStats()` would give for [logs].
ObservationLogStats _statsFromLogs(List<ObservationLogEntry> logs) {
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
  // `logs` is newest first.
  return ObservationLogStats(
    totalObservations: logs.length,
    uniqueObjects: uniqueObjects.length,
    averageRating: ratedCount > 0 ? ratingSum / ratedCount : 0,
    firstObservation: logs.last.timestamp,
    lastObservation: logs.first.timestamp,
  );
}
