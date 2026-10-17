part of '../imaging_records_repository.dart';

/// Decode a `/api/sessions` wire row into the Drift [db.ImagingSession] shape.
///
/// One copy on purpose: this repository and the remote `databaseProvider`
/// streams hydrate the same endpoint into the same row, and two hand-maintained
/// copies of one wire contract drift apart silently.
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

bool _thumbnailListsEqual(
  List<ProducingNodeThumbnail> previous,
  List<ProducingNodeThumbnail> next,
) {
  if (identical(previous, next)) return true;
  if (previous.length != next.length) return false;
  for (var index = 0; index < previous.length; index++) {
    final a = previous[index];
    final b = next[index];
    if (a.id != b.id ||
        a.filePath != b.filePath ||
        a.fileName != b.fileName ||
        a.filter != b.filter ||
        a.frameType != b.frameType ||
        a.hfr != b.hfr ||
        a.eccentricity != b.eccentricity ||
        a.fwhm != b.fwhm ||
        a.starCount != b.starCount ||
        a.exposureDuration != b.exposureDuration ||
        a.capturedAt != b.capturedAt ||
        a.isAccepted != b.isAccepted ||
        a.rejectionReason != b.rejectionReason ||
        a.runtimeGrade != b.runtimeGrade ||
        a.producingNodeId != b.producingNodeId ||
        a.producingRunId != b.producingRunId) {
      return false;
    }
  }
  return true;
}

ProducingNodeThumbnail _producingThumbnailFromApiJson(
  Map<String, dynamic> json,
) {
  final image = db.CapturedImage.fromJson(json);
  return ProducingNodeThumbnail(
    id: image.id,
    filePath: image.filePath,
    fileName: image.fileName,
    filter: image.filter,
    frameType: image.frameType,
    hfr: image.hfr,
    eccentricity: (json['eccentricity'] as num?)?.toDouble(),
    fwhm: (json['fwhm'] as num?)?.toDouble(),
    starCount: image.starCount,
    exposureDuration: image.exposureDuration,
    capturedAt: image.capturedAt,
    isAccepted: image.isAccepted,
    rejectionReason: image.rejectionReason,
    runtimeGrade: json['runtimeGrade'] as String?,
    producingNodeId: json['producingNodeId'] as String? ?? '',
    producingRunId: json['producingRunId'] as String?,
  );
}
