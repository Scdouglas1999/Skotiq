/// History rows the host keeps per night: observation log entries, guiding
/// RMS samples and polar alignment runs (`DbReadApi`).
library;

import '../wire_time.dart';

/// One row of `GET /api/notes-journal`, which serves the observation log.
class RemoteNotesJournalEntry {
  const RemoteNotesJournalEntry({
    required this.id,
    required this.timestamp,
    required this.objectName,
    required this.ra,
    required this.dec,
    this.objectType,
    this.catalogId,
    this.altitude,
    this.azimuth,
    this.notes,
    this.rating,
    this.equipmentProfileId,
    this.seeingConditions,
    this.transparency,
    this.locationName,
    this.latitude,
    this.longitude,
  });

  factory RemoteNotesJournalEntry.fromJson(Map<String, dynamic> json) {
    return RemoteNotesJournalEntry(
      id: (json['id'] as num).toInt(),
      timestamp: parseWireTime(json['timestamp'] as String),
      objectName: json['objectName'] as String? ?? '',
      objectType: json['objectType'] as String?,
      catalogId: json['catalogId'] as String?,
      ra: (json['ra'] as num?)?.toDouble() ?? 0.0,
      dec: (json['dec'] as num?)?.toDouble() ?? 0.0,
      altitude: (json['altitude'] as num?)?.toDouble(),
      azimuth: (json['azimuth'] as num?)?.toDouble(),
      notes: json['notes'] as String?,
      rating: (json['rating'] as num?)?.toInt(),
      equipmentProfileId: (json['equipmentProfileId'] as num?)?.toInt(),
      seeingConditions: json['seeingConditions'] as String?,
      transparency: json['transparency'] as String?,
      locationName: json['locationName'] as String?,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
    );
  }

  final int id;
  final DateTime timestamp;
  final String objectName;
  final String? objectType;
  final String? catalogId;

  /// Hours.
  final double ra;
  final double dec;
  final double? altitude;
  final double? azimuth;
  final String? notes;
  final int? rating;
  final int? equipmentProfileId;
  final String? seeingConditions;
  final String? transparency;
  final String? locationName;
  final double? latitude;
  final double? longitude;

  Map<String, dynamic> toJson() => {
    'id': id,
    'timestamp': timestamp.toWireTime(),
    'objectName': objectName,
    'objectType': objectType,
    'catalogId': catalogId,
    'ra': ra,
    'dec': dec,
    'altitude': altitude,
    'azimuth': azimuth,
    'notes': notes,
    'rating': rating,
    'equipmentProfileId': equipmentProfileId,
    'seeingConditions': seeingConditions,
    'transparency': transparency,
    'locationName': locationName,
    'latitude': latitude,
    'longitude': longitude,
  };
}

/// One row of `GET /api/guide-rms-history`.
class RemoteGuideRmsHistoryEntry {
  const RemoteGuideRmsHistoryEntry({
    required this.id,
    required this.totalRmsArcsec,
    required this.sampleCount,
    required this.recordedAt,
    this.sessionId,
    this.mountId,
    this.targetId,
    this.exposureSeconds,
  });

  factory RemoteGuideRmsHistoryEntry.fromJson(Map<String, dynamic> json) {
    return RemoteGuideRmsHistoryEntry(
      id: (json['id'] as num).toInt(),
      sessionId: _sessionId(json['sessionId']),
      mountId: json['mountId'] as String?,
      targetId: (json['targetId'] as num?)?.toInt(),
      totalRmsArcsec: (json['totalRmsArcsec'] as num?)?.toDouble() ?? 0.0,
      sampleCount: (json['sampleCount'] as num?)?.toInt() ?? 0,
      exposureSeconds: (json['exposureSeconds'] as num?)?.toDouble(),
      recordedAt: parseWireTime(json['recordedAt'] as String),
    );
  }

  final int id;
  final int? sessionId;
  final String? mountId;
  final int? targetId;
  final double totalRmsArcsec;
  final int sampleCount;
  final double? exposureSeconds;
  final DateTime recordedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'sessionId': sessionId,
    'mountId': mountId,
    'targetId': targetId,
    'totalRmsArcsec': totalRmsArcsec,
    'sampleCount': sampleCount,
    'exposureSeconds': exposureSeconds,
    'recordedAt': recordedAt.toWireTime(),
  };

  // Hosts up to 8.2.0 sent the stored text id ("113"); later hosts send the
  // number. Accept both so a client works against either.
  static int? _sessionId(Object? raw) {
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim());
    return null;
  }
}

/// One row of `GET /api/polar-alignment-history`.
class RemotePolarAlignmentHistoryEntry {
  const RemotePolarAlignmentHistoryEntry({
    required this.id,
    required this.startedAt,
    required this.completedAt,
    required this.autoCompleted,
    required this.isNorth,
    this.equipmentProfileId,
    this.initialAzimuthError,
    this.initialAltitudeError,
    this.initialTotalError,
    this.finalAzimuthError,
    this.finalAltitudeError,
    this.finalTotalError,
    this.configJson,
  });

  factory RemotePolarAlignmentHistoryEntry.fromJson(Map<String, dynamic> json) {
    return RemotePolarAlignmentHistoryEntry(
      id: (json['id'] as num).toInt(),
      equipmentProfileId: (json['equipmentProfileId'] as num?)?.toInt(),
      initialAzimuthError: (json['initialAzimuthError'] as num?)?.toDouble(),
      initialAltitudeError: (json['initialAltitudeError'] as num?)?.toDouble(),
      initialTotalError: (json['initialTotalError'] as num?)?.toDouble(),
      finalAzimuthError: (json['finalAzimuthError'] as num?)?.toDouble(),
      finalAltitudeError: (json['finalAltitudeError'] as num?)?.toDouble(),
      finalTotalError: (json['finalTotalError'] as num?)?.toDouble(),
      startedAt: parseWireTime(json['startedAt'] as String),
      completedAt: parseWireTime(json['completedAt'] as String),
      autoCompleted: json['autoCompleted'] as bool? ?? false,
      isNorth: json['isNorth'] as bool? ?? true,
      configJson: json['configJson'] as String?,
    );
  }

  final int id;
  final int? equipmentProfileId;
  final double? initialAzimuthError;
  final double? initialAltitudeError;
  final double? initialTotalError;
  final double? finalAzimuthError;
  final double? finalAltitudeError;
  final double? finalTotalError;
  final DateTime startedAt;
  final DateTime completedAt;
  final bool autoCompleted;
  final bool isNorth;
  final String? configJson;

  Map<String, dynamic> toJson() => {
    'id': id,
    'equipmentProfileId': equipmentProfileId,
    'initialAzimuthError': initialAzimuthError,
    'initialAltitudeError': initialAltitudeError,
    'initialTotalError': initialTotalError,
    'finalAzimuthError': finalAzimuthError,
    'finalAltitudeError': finalAltitudeError,
    'finalTotalError': finalTotalError,
    'startedAt': startedAt.toWireTime(),
    'completedAt': completedAt.toWireTime(),
    'autoCompleted': autoCompleted,
    'isNorth': isNorth,
    'configJson': configJson,
  };
}
