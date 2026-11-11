import '../../../database/daos/observation_logs_dao.dart'
    show ObservationLogStats;
import '../../../database/database.dart' show ObservationLogEntry;

/// The log of visual observations kept in the imaging host's database.
abstract interface class ObservationLog {
  /// Every entry, newest first.
  Stream<List<ObservationLogEntry>> watchAllLogs();

  /// Catalog ids of every logged object.
  Stream<Set<String>> watchObservedCatalogIds();

  Future<ObservationLogStats> getStats();

  /// Returns the new entry's id.
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
  });

  Future<void> deleteLog(int id);

  /// Returns how many entries were deleted, or null when the host does not
  /// report a count.
  Future<int?> deleteAllLogs();

  Future<String> exportToCsv();
}
