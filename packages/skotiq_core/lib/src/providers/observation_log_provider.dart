import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/network_backend.dart';
import '../database/daos/observation_logs_dao.dart';
import '../database/database.dart';
import '../utils/resilient_poll_stream.dart';
import 'backend_provider.dart';
import 'database_provider.dart';

const _notProvided = Object();

/// DAO provider for ObservationLogsDao.
final observationLogsDaoProvider = Provider<ObservationLogsDao>((ref) {
  return ObservationLogsDao(ref.watch(databaseProvider));
});

/// Reactive stream of all observation log entries (newest first).
///
/// On a remote client (`NetworkBackend`) observation logs live only in the
/// master's DB; the slave's local table is never populated. We poll the
/// host's `GET /api/notes-journal` (which serves the `observation_logs`
/// table) and map each [RemoteNotesJournalEntry] onto the local
/// [ObservationLogEntry] shape the log panel + planetarium markers read.
final observationLogsProvider = StreamProvider<List<ObservationLogEntry>>((
  ref,
) {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    return _pollRemoteObservationLogs(backend);
  }
  return ref.watch(observationLogsDaoProvider).watchAllLogs();
});

/// Reactive stream of observed catalog IDs, used for planetarium markers.
final observedCatalogIdsProvider = StreamProvider<Set<String>>((ref) {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    return _pollRemoteObservationLogs(backend).map(
      (logs) => logs
          .map((l) => l.catalogId)
          .whereType<String>()
          .where((id) => id.isNotEmpty)
          .toSet(),
    );
  }
  return ref.watch(observationLogsDaoProvider).watchObservedCatalogIds();
});

/// Observation log statistics (refreshes when logs change).
final observationLogStatsProvider = FutureProvider<ObservationLogStats>((
  ref,
) async {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    final logs = await ref.watch(observationLogsProvider.future);
    return _statsFromLogs(logs);
  }
  // Depend on the logs stream so stats refresh on any change
  ref.watch(observationLogsProvider);
  return ref.read(observationLogsDaoProvider).getStats();
});

/// Polls the host's observation logs, emitting only on change (mirrors the
/// `_pollRemote` change-guard in `database_provider.dart`).
Stream<List<ObservationLogEntry>> _pollRemoteObservationLogs(
  NetworkBackend backend, {
  Duration interval = const Duration(seconds: 10),
}) => resilientDistinctPoll(
  fetch: () => _fetchRemoteObservationLogs(backend),
  unchanged: listEquals,
  interval: interval,
);

Future<List<ObservationLogEntry>> _fetchRemoteObservationLogs(
  NetworkBackend backend,
) async {
  const pageSize = 1000;
  final rows = <RemoteNotesJournalEntry>[];
  var offset = 0;
  while (true) {
    final page = await backend.fetchNotesJournal(
      limit: pageSize,
      offset: offset,
    );
    rows.addAll(page.items);
    offset += page.items.length;
    if (offset >= page.total || page.items.isEmpty) break;
  }

  final mapped = rows.map(_observationLogFromRemote).toList()
    // Host orders newest-first already; keep that invariant so `.first`/`.last`
    // the stats reader relies on stay correct.
    ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  return mapped;
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

/// Reconstructs [ObservationLogStats] from a host-polled log list so the
/// remote path produces the same summary the local DAO `getStats()` would.
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
  // `logs` is newest-first (see _fetchRemoteObservationLogs).
  return ObservationLogStats(
    totalObservations: logs.length,
    uniqueObjects: uniqueObjects.length,
    averageRating: ratedCount > 0 ? ratingSum / ratedCount : 0,
    firstObservation: logs.last.timestamp,
    lastObservation: logs.first.timestamp,
  );
}

/// StateNotifier for managing observation log UI interactions.
final observationLogNotifierProvider =
    StateNotifierProvider<ObservationLogNotifier, ObservationLogUiState>((ref) {
      return ObservationLogNotifier(ref);
    });

/// UI state for observation log management.
class ObservationLogUiState {
  final bool isSaving;
  final String? statusMessage;
  final String? errorMessage;
  final String? filterQuery;
  final int? filterMinRating;
  final DateTime? filterStartDate;
  final DateTime? filterEndDate;

  const ObservationLogUiState({
    this.isSaving = false,
    this.statusMessage,
    this.errorMessage,
    this.filterQuery,
    this.filterMinRating,
    this.filterStartDate,
    this.filterEndDate,
  });

  ObservationLogUiState copyWith({
    bool? isSaving,
    Object? statusMessage = _notProvided,
    Object? errorMessage = _notProvided,
    Object? filterQuery = _notProvided,
    Object? filterMinRating = _notProvided,
    Object? filterStartDate = _notProvided,
    Object? filterEndDate = _notProvided,
  }) {
    return ObservationLogUiState(
      isSaving: isSaving ?? this.isSaving,
      statusMessage: identical(statusMessage, _notProvided)
          ? this.statusMessage
          : statusMessage as String?,
      errorMessage: identical(errorMessage, _notProvided)
          ? this.errorMessage
          : errorMessage as String?,
      filterQuery: identical(filterQuery, _notProvided)
          ? this.filterQuery
          : filterQuery as String?,
      filterMinRating: identical(filterMinRating, _notProvided)
          ? this.filterMinRating
          : filterMinRating as int?,
      filterStartDate: identical(filterStartDate, _notProvided)
          ? this.filterStartDate
          : filterStartDate as DateTime?,
      filterEndDate: identical(filterEndDate, _notProvided)
          ? this.filterEndDate
          : filterEndDate as DateTime?,
    );
  }
}

class ObservationLogNotifier extends StateNotifier<ObservationLogUiState> {
  final Ref ref;
  int _authorityRevision = 0;
  final Map<int, Object> _deletingLogs = {};
  Object? _deleteAllToken;
  Future<String?>? _exportInFlight;

  ObservationLogNotifier(this.ref) : super(const ObservationLogUiState()) {
    ref.listen(backendProvider, (previous, next) {
      if (!mounted || identical(previous, next)) return;
      _authorityRevision++;
      _deletingLogs.clear();
      _deleteAllToken = null;
      _exportInFlight = null;
      state = state.copyWith(
        isSaving: false,
        statusMessage: null,
        errorMessage: null,
      );
    });
  }

  ObservationLogsDao get _dao => ref.read(observationLogsDaoProvider);

  void _refreshLogs() {
    ref.invalidate(observationLogsProvider);
    ref.invalidate(observedCatalogIdsProvider);
  }

  /// Log a new observation.
  Future<int?> logObservation({
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
  }) async {
    if (state.isSaving) return null;
    final backend = ref.read(backendProvider);
    final dao = _dao;
    final authority = _authorityRevision;
    state = state.copyWith(isSaving: true, errorMessage: null);

    try {
      final id = backend is NetworkBackend
          ? await backend.createObservationLog(
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
            )
          : await dao.insertLog(
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
            );
      if (!_isCurrentAuthority(authority, backend, dao)) return null;
      _refreshLogs();
      state = state.copyWith(
        isSaving: false,
        statusMessage: 'Observation logged for $objectName',
      );
      return id;
    } catch (e) {
      if (_isCurrentAuthority(authority, backend, dao)) {
        state = state.copyWith(
          isSaving: false,
          errorMessage: 'Failed to log observation: $e',
        );
      }
      return null;
    }
  }

  /// Delete an observation log entry.
  Future<bool> deleteLog(int id) async {
    if (_deletingLogs.containsKey(id)) return false;
    final token = Object();
    _deletingLogs[id] = token;
    final backend = ref.read(backendProvider);
    final dao = _dao;
    final authority = _authorityRevision;
    state = state.copyWith(errorMessage: null);
    try {
      if (backend is NetworkBackend) {
        await backend.deleteObservationLog(id);
      } else {
        await dao.deleteLog(id);
      }
      if (!_isCurrentAuthority(authority, backend, dao)) return false;
      _refreshLogs();
      state = state.copyWith(
        statusMessage: 'Observation deleted.',
        errorMessage: null,
      );
      return true;
    } catch (e) {
      if (_isCurrentAuthority(authority, backend, dao)) {
        state = state.copyWith(
          errorMessage: 'Failed to delete observation: $e',
        );
      }
      return false;
    } finally {
      if (identical(_deletingLogs[id], token)) _deletingLogs.remove(id);
    }
  }

  /// Export all logs to CSV.
  Future<String?> exportCsv() {
    final existing = _exportInFlight;
    if (existing != null) return existing;
    final backend = ref.read(backendProvider);
    final dao = _dao;
    final authority = _authorityRevision;
    late final Future<String?> operation;
    operation = _exportCsv(backend, dao, authority).whenComplete(() {
      if (identical(_exportInFlight, operation)) _exportInFlight = null;
    });
    _exportInFlight = operation;
    return operation;
  }

  Future<String?> _exportCsv(
    Object backend,
    ObservationLogsDao dao,
    int authority,
  ) async {
    state = state.copyWith(errorMessage: null);
    try {
      final csv = backend is NetworkBackend
          ? observationLogsToCsv(await _fetchRemoteObservationLogs(backend))
          : await dao.exportToCsv();
      if (!_isCurrentAuthority(authority, backend, dao)) return null;
      if (csv.isEmpty) {
        state = state.copyWith(statusMessage: 'No observations to export.');
        return null;
      }
      state = state.copyWith(
        statusMessage: 'Export complete.',
        errorMessage: null,
      );
      return csv;
    } catch (e) {
      if (_isCurrentAuthority(authority, backend, dao)) {
        state = state.copyWith(errorMessage: 'Failed to export: $e');
      }
      return null;
    }
  }

  /// Delete all observation logs.
  Future<void> deleteAllLogs() async {
    if (_deleteAllToken != null) return;
    final token = Object();
    _deleteAllToken = token;
    final backend = ref.read(backendProvider);
    final dao = _dao;
    final authority = _authorityRevision;
    try {
      if (backend is NetworkBackend) {
        await backend.deleteAllObservationLogs();
        if (!_isCurrentAuthority(authority, backend, dao)) return;
        _refreshLogs();
        state = state.copyWith(statusMessage: 'Deleted all observations.');
      } else {
        final count = await dao.deleteAllLogs();
        if (!_isCurrentAuthority(authority, backend, dao)) return;
        _refreshLogs();
        state = state.copyWith(statusMessage: 'Deleted $count observations.');
      }
    } catch (e) {
      if (_isCurrentAuthority(authority, backend, dao)) {
        state = state.copyWith(
          errorMessage: 'Failed to delete observations: $e',
        );
      }
    } finally {
      if (identical(_deleteAllToken, token)) _deleteAllToken = null;
    }
  }

  bool _isCurrentAuthority(
    int authority,
    Object backend,
    ObservationLogsDao dao,
  ) {
    return mounted &&
        authority == _authorityRevision &&
        identical(backend, ref.read(backendProvider)) &&
        identical(dao, ref.read(observationLogsDaoProvider));
  }

  /// Set filter query text.
  void setFilterQuery(String? query) {
    state = state.copyWith(filterQuery: query);
  }

  /// Set minimum rating filter.
  void setFilterMinRating(int? rating) {
    state = state.copyWith(filterMinRating: rating);
  }

  /// Set date range filter.
  void setFilterDateRange(DateTime? start, DateTime? end) {
    state = state.copyWith(filterStartDate: start, filterEndDate: end);
  }

  /// Clear status/error messages.
  void clearMessages() {
    state = state.copyWith(statusMessage: null, errorMessage: null);
  }
}
