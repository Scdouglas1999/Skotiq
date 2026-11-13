import '../../../database/database.dart' as db;
import '../../../utils/utc_timestamp.dart';

/// Decode a `/api/sessions` wire row into the Drift [db.ImagingSession] shape.
db.ImagingSession imagingSessionFromWireJson(Map<String, dynamic> json) {
  return db.ImagingSession(
    id: json['id'] as int,
    name: json['name'] as String?,
    profileId: json['profileId'] as int?,
    targetId: json['targetId'] as int?,
    startTime: wireTimestamp(json['startTime']),
    endTime: json['endTime'] == null ? null : wireTimestamp(json['endTime']),
    totalExposures: json['totalExposures'] as int? ?? 0,
    successfulExposures: json['successfulExposures'] as int? ?? 0,
    failedExposures: json['failedExposures'] as int? ?? 0,
    totalIntegrationSecs:
        (json['totalIntegrationSecs'] as num?)?.toDouble() ?? 0.0,
    avgTemperature: (json['avgTemperature'] as num?)?.toDouble(),
    avgHumidity: (json['avgHumidity'] as num?)?.toDouble(),
    avgSeeing: (json['avgSeeing'] as num?)?.toDouble(),
    avgHfr: (json['avgHfr'] as num?)?.toDouble(),
    avgGuidingRms: (json['avgGuidingRms'] as num?)?.toDouble(),
    autofocusCount: json['autofocusCount'] as int? ?? 0,
    notes: json['notes'] as String?,
    status: json['status'] as String? ?? 'completed',
    sequenceId: json['sequenceId'] as int?,
    equipmentSnapshot: json['equipmentSnapshot'] as String?,
  );
}

/// Coerce a wire timestamp — epoch milliseconds or ISO-8601 — into a
/// [DateTime], falling back to the epoch for anything else.
///
/// The string form routes through [tryParseUtcTimestamp] because
/// `DateTime.tryParse` reads an offset-less ISO string as *local* time: a phone
/// in a different timezone than the appliance would otherwise render every
/// session start/end shifted by the offset delta, with no error. The host emits
/// both shapes across its endpoints, so the coercion has to be safe for both.
DateTime wireTimestamp(Object? value) {
  if (value is int) {
    return DateTime.fromMillisecondsSinceEpoch(value);
  }
  if (value is String) {
    return tryParseUtcTimestamp(value) ??
        DateTime.fromMillisecondsSinceEpoch(0);
  }
  return DateTime.fromMillisecondsSinceEpoch(0);
}
