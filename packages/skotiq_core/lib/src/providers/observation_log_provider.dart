import '../errors/error_text.dart';
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'host_role.dart';

import '../backend/roles/host_data/observation_log.dart';
import '../database/daos/observation_logs_dao.dart';
import '../database/database.dart';
import 'async_scope.dart';
import 'backend_provider.dart';
import 'database_provider.dart';

const _notProvided = Object();

final observationLogsDaoProvider = Provider<ObservationLogsDao>((ref) {
  return ObservationLogsDao(ref.watch(databaseProvider));
});

/// The observation log of whichever machine is the imaging host: this
/// process's database, or the linked host's.
final observationLogProvider = hostRoleProvider<ObservationLog>(
  here: (ref) => ref.watch(observationLogsDaoProvider),
  linked: (ref, host) => host.observationLog,
);

/// Reactive stream of all observation log entries (newest first).
final observationLogsProvider = StreamProvider<List<ObservationLogEntry>>(
  (ref) => ref.watch(observationLogProvider).watchAllLogs(),
);

/// Reactive stream of observed catalog IDs, used for planetarium markers.
final observedCatalogIdsProvider = StreamProvider<Set<String>>(
  (ref) => ref.watch(observationLogProvider).watchObservedCatalogIds(),
);

/// Observation log statistics (refreshes when logs change).
final observationLogStatsProvider = FutureProvider<ObservationLogStats>((
  ref,
) async {
  // Wait for the list so the numbers describe what the list shows, and
  // recompute whenever it changes.
  await ref.watch(observationLogsProvider.future);
  return ref.read(observationLogProvider).getStats();
});

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
  final Map<int, Object> _deletingLogs = {};
  Object? _deleteAllToken;
  Future<String?>? _exportInFlight;

  /// Each operation belongs to the log it started on, which changes with the
  /// backend and with the local database.
  late final AsyncScopes<ObservationLog> _scopes = AsyncScopes(
    ref.read,
    observationLogProvider,
    alive: () => mounted,
  );

  ObservationLogNotifier(this.ref) : super(const ObservationLogUiState()) {
    ref.listen(backendProvider, (previous, next) {
      if (!mounted || identical(previous, next)) return;
      _scopes.cancelAll();
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
    final scope = _scopes.begin();
    state = state.copyWith(isSaving: true, errorMessage: null);

    try {
      final id = await scope.value.insertLog(
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
      if (scope.isStale) return null;
      state = state.copyWith(
        isSaving: false,
        statusMessage: 'Observation logged for $objectName',
      );
      return id;
    } catch (e) {
      if (scope.isCurrent) {
        state = state.copyWith(
          isSaving: false,
          errorMessage: 'Failed to log observation: ${userFacingError(e)}',
        );
      }
      return null;
    }
  }

  Future<bool> deleteLog(int id) async {
    if (_deletingLogs.containsKey(id)) return false;
    final token = Object();
    _deletingLogs[id] = token;
    final scope = _scopes.begin();
    state = state.copyWith(errorMessage: null);
    try {
      await scope.value.deleteLog(id);
      if (scope.isStale) return false;
      state = state.copyWith(
        statusMessage: 'Observation deleted.',
        errorMessage: null,
      );
      return true;
    } catch (e) {
      if (scope.isCurrent) {
        state = state.copyWith(
          errorMessage: 'Failed to delete observation: ${userFacingError(e)}',
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
    late final Future<String?> operation;
    operation = _exportCsv(_scopes.begin()).whenComplete(() {
      if (identical(_exportInFlight, operation)) _exportInFlight = null;
    });
    _exportInFlight = operation;
    return operation;
  }

  Future<String?> _exportCsv(AsyncScope<ObservationLog> scope) async {
    state = state.copyWith(errorMessage: null);
    try {
      final csv = await scope.value.exportToCsv();
      if (scope.isStale) return null;
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
      if (scope.isCurrent) {
        state = state.copyWith(
          errorMessage: 'Failed to export: ${userFacingError(e)}',
        );
      }
      return null;
    }
  }

  Future<void> deleteAllLogs() async {
    if (_deleteAllToken != null) return;
    final token = Object();
    _deleteAllToken = token;
    final scope = _scopes.begin();
    try {
      final count = await scope.value.deleteAllLogs();
      if (scope.isStale) return;
      state = state.copyWith(
        statusMessage: count == null
            ? 'Deleted all observations.'
            : 'Deleted $count observations.',
      );
    } catch (e) {
      if (scope.isCurrent) {
        state = state.copyWith(
          errorMessage: 'Failed to delete observations: ${userFacingError(e)}',
        );
      }
    } finally {
      if (identical(_deleteAllToken, token)) _deleteAllToken = null;
    }
  }

  void setFilterQuery(String? query) {
    state = state.copyWith(filterQuery: query);
  }

  void setFilterMinRating(int? rating) {
    state = state.copyWith(filterMinRating: rating);
  }

  void setFilterDateRange(DateTime? start, DateTime? end) {
    state = state.copyWith(filterStartDate: start, filterEndDate: end);
  }

  void clearMessages() {
    state = state.copyWith(statusMessage: null, errorMessage: null);
  }
}
