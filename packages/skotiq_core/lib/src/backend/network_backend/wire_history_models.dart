part of '../network_backend.dart';

/// Wire row for `/api/sequence-management/summaries`.
///
/// The remote sequence library must use the host's persisted metadata rather
/// than reconstructing a lossy summary from full sequence documents. Every
/// field is required except the two genuinely nullable display values, so a
/// mismatched/legacy response fails loudly instead of looking like an empty
/// tag/favorite/run history.
class RemoteSequenceSummary {
  final int id;
  final String name;
  final int nodeCount;
  final int targetCount;
  final int exposureCount;
  final int totalIntegrationSecs;
  final String? primaryTargetName;
  final DateTime? lastRunAt;
  final int runCount;
  final List<String> tags;
  final bool isFavorite;
  final DateTime createdAt;
  final DateTime modifiedAt;

  const RemoteSequenceSummary({
    required this.id,
    required this.name,
    required this.nodeCount,
    required this.targetCount,
    required this.exposureCount,
    required this.totalIntegrationSecs,
    required this.runCount,
    required this.tags,
    required this.isFavorite,
    required this.createdAt,
    required this.modifiedAt,
    this.primaryTargetName,
    this.lastRunAt,
  });

  factory RemoteSequenceSummary.fromJson(Map<String, dynamic> json) {
    const context = 'sequence-summary row';
    final runCount = _historyRequiredInt(json, 'runCount', context, min: 0);
    final lastRunAt = _historyOptionalDate(json, 'lastRunAt', context);
    if ((runCount == 0) != (lastRunAt == null)) {
      throw const FormatException(
        'sequence-summary row runCount and lastRunAt disagree',
      );
    }
    final createdAt = _historyRequiredDate(json, 'createdAt', context);
    final modifiedAt = _historyRequiredDate(json, 'modifiedAt', context);
    if (modifiedAt.isBefore(createdAt)) {
      throw const FormatException(
        'sequence-summary row modifiedAt precedes createdAt',
      );
    }
    return RemoteSequenceSummary(
      id: _historyRequiredInt(json, 'id', context, min: 1),
      name: _historyRequiredString(json, 'name', context),
      nodeCount: _historyRequiredInt(json, 'nodeCount', context, min: 0),
      targetCount: _historyRequiredInt(json, 'targetCount', context, min: 0),
      exposureCount: _historyRequiredInt(
        json,
        'exposureCount',
        context,
        min: 0,
      ),
      totalIntegrationSecs: _historyRequiredInt(
        json,
        'totalIntegrationSecs',
        context,
        min: 0,
      ),
      primaryTargetName: _historyOptionalString(
        json,
        'primaryTargetName',
        context,
      ),
      lastRunAt: lastRunAt,
      runCount: runCount,
      tags: _historyRequiredStringList(json, 'tags', context),
      isFavorite: _historyRequiredBool(json, 'isFavorite', context),
      createdAt: createdAt,
      modifiedAt: modifiedAt,
    );
  }
}

/// Metadata-only wire row for a stored sequence's version-history list.
class RemoteSequenceVersionSummary {
  final int id;
  final int sequenceId;
  final String? label;
  final DateTime createdAt;

  const RemoteSequenceVersionSummary({
    required this.id,
    required this.sequenceId,
    required this.createdAt,
    this.label,
  });

  factory RemoteSequenceVersionSummary.fromJson(Map<String, dynamic> json) {
    const context = 'sequence-version summary row';
    return RemoteSequenceVersionSummary(
      id: _historyRequiredInt(json, 'id', context, min: 1),
      sequenceId: _historyRequiredInt(json, 'sequenceId', context, min: 1),
      label: _historyOptionalString(json, 'label', context, allowEmpty: true),
      createdAt: _historyRequiredDate(json, 'createdAt', context),
    );
  }
}

/// Full wire row returned only when the operator chooses a version to restore.
class RemoteSequenceVersion extends RemoteSequenceVersionSummary {
  final String snapshotJson;

  const RemoteSequenceVersion({
    required super.id,
    required super.sequenceId,
    required this.snapshotJson,
    required super.createdAt,
    super.label,
  });

  factory RemoteSequenceVersion.fromJson(Map<String, dynamic> json) {
    const context = 'sequence-version row';
    return RemoteSequenceVersion(
      id: _historyRequiredInt(json, 'id', context, min: 1),
      sequenceId: _historyRequiredInt(json, 'sequenceId', context, min: 1),
      snapshotJson: _historyRequiredString(json, 'snapshotJson', context),
      label: _historyOptionalString(json, 'label', context, allowEmpty: true),
      createdAt: _historyRequiredDate(json, 'createdAt', context),
    );
  }
}

class RemotePage<T> {
  final List<T> items;
  final int total;

  const RemotePage({required this.items, required this.total});

  factory RemotePage.fromJson(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic>) itemFromJson,
  ) {
    final rawItems = json['items'];
    if (rawItems is! List) {
      throw const FormatException(
        'Malformed paginated response: missing items list',
      );
    }
    final items = <T>[];
    for (var index = 0; index < rawItems.length; index++) {
      final raw = rawItems[index];
      if (raw is! Map) {
        throw FormatException('Paginated response row $index is not an object');
      }
      try {
        items.add(itemFromJson(raw.cast<String, dynamic>()));
      } on TypeError catch (error) {
        throw FormatException(
          'Paginated response row $index has non-string keys',
          error,
        );
      }
    }
    final total = _historyRequiredInt(
      json,
      'total',
      'paginated response',
      min: 0,
    );
    if (total < items.length) {
      throw FormatException(
        'Paginated response total $total is smaller than its ${items.length} rows',
      );
    }
    return RemotePage(items: List.unmodifiable(items), total: total);
  }
}

/// Wire row for `/api/sequence-runs`.
class RemoteSequenceRun {
  final int id;
  final int? sequenceId;
  final String? sequenceName;
  final DateTime startedAt;
  final DateTime? endedAt;
  final String status;
  final String? statsJson;

  const RemoteSequenceRun({
    required this.id,
    required this.startedAt,
    required this.status,
    this.sequenceId,
    this.sequenceName,
    this.endedAt,
    this.statsJson,
  });

  factory RemoteSequenceRun.fromJson(Map<String, dynamic> json) {
    const context = 'sequence-run row';
    final startedAt = _historyRequiredDate(json, 'startedAt', context);
    final endedAt = _historyOptionalDate(json, 'endedAt', context);
    if (endedAt != null && endedAt.isBefore(startedAt)) {
      throw const FormatException(
        'sequence-run row endedAt precedes startedAt',
      );
    }
    return RemoteSequenceRun(
      id: _historyRequiredInt(json, 'id', context, min: 1),
      sequenceId: _historyOptionalInt(json, 'sequenceId', context, min: 1),
      sequenceName: _historyOptionalString(json, 'sequenceName', context),
      startedAt: startedAt,
      endedAt: endedAt,
      status: _historyRequiredString(json, 'status', context),
      statsJson: _historyOptionalString(
        json,
        'statsJson',
        context,
        allowEmpty: true,
      ),
    );
  }
}

/// Wire row for `/api/notes-journal`.
class RemoteNotesJournalEntry {
  final int id;
  final DateTime timestamp;
  final String objectName;
  final String? objectType;
  final String? catalogId;
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
      timestamp: DateTime.parse(json['timestamp'] as String),
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
}

/// Wire row for `/api/db/notes` — the operator's per-target / per-run
/// journal notes (the `notes_journal` table). Mirrors `JournalNote.toJson`
/// the host serializes. Tolerant defaults so a malformed/partial row never
/// blanks the whole notes panel.
class RemoteJournalNote {
  final String id;
  final String targetId;
  final int? sequenceRunId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? title;
  final String body;
  final List<String> tags;
  final List<String> attachments;
  final String? sentiment;

  const RemoteJournalNote({
    required this.id,
    required this.targetId,
    required this.createdAt,
    required this.updatedAt,
    required this.body,
    this.sequenceRunId,
    this.title,
    this.tags = const [],
    this.attachments = const [],
    this.sentiment,
  });

  factory RemoteJournalNote.fromJson(Map<String, dynamic> json) {
    return RemoteJournalNote(
      id: json['id'] as String? ?? '',
      targetId: json['targetId'] as String? ?? '',
      sequenceRunId: (json['sequenceRunId'] as num?)?.toInt(),
      createdAt:
          _parseDateField(json['createdAt']) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      updatedAt:
          _parseDateField(json['updatedAt']) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      title: json['title'] as String?,
      body: json['body'] as String? ?? '',
      tags: _stringList(json['tags']),
      attachments: _stringList(json['attachments']),
      sentiment: json['sentiment'] as String?,
    );
  }

  static List<String> _stringList(Object? raw) {
    if (raw is List) {
      return raw.whereType<String>().toList(growable: false);
    }
    return const <String>[];
  }
}

/// Wire row for `/api/guide-rms-history`.
class RemoteGuideRmsHistoryEntry {
  final int id;
  final int? sessionId;
  final String? mountId;
  final int? targetId;
  final double totalRmsArcsec;
  final int sampleCount;
  final double? exposureSeconds;
  final DateTime recordedAt;

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
      sessionId: (json['sessionId'] as num?)?.toInt(),
      mountId: json['mountId'] as String?,
      targetId: (json['targetId'] as num?)?.toInt(),
      totalRmsArcsec: (json['totalRmsArcsec'] as num?)?.toDouble() ?? 0.0,
      sampleCount: (json['sampleCount'] as num?)?.toInt() ?? 0,
      exposureSeconds: (json['exposureSeconds'] as num?)?.toDouble(),
      recordedAt: DateTime.parse(json['recordedAt'] as String),
    );
  }
}

/// Wire row for `/api/polar-alignment-history`.
class RemotePolarAlignmentHistoryEntry {
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
      startedAt: DateTime.parse(json['startedAt'] as String),
      completedAt: DateTime.parse(json['completedAt'] as String),
      autoCompleted: json['autoCompleted'] as bool? ?? false,
      isNorth: json['isNorth'] as bool? ?? true,
      configJson: json['configJson'] as String?,
    );
  }
}

/// Wire row for `/api/db/dark-library`. Distinct from
/// [RemoteDarkLibraryEntry] in `models/calibration/`: that one is the
/// calibration UI's projection which elides several columns the
/// raw read surface keeps (master frame path, master count).
class RemoteDbDarkLibraryRow {
  final int id;
  final String filePath;
  final String frameType;
  final double exposureTime;
  final int gain;
  final int offset;
  final int binX;
  final int binY;
  final double? temperature;
  final int width;
  final int height;
  final String? masterDarkPath;
  final int masterFrameCount;
  final DateTime createdAt;

  const RemoteDbDarkLibraryRow({
    required this.id,
    required this.filePath,
    required this.frameType,
    required this.exposureTime,
    required this.gain,
    required this.offset,
    required this.binX,
    required this.binY,
    required this.width,
    required this.height,
    required this.masterFrameCount,
    required this.createdAt,
    this.temperature,
    this.masterDarkPath,
  });

  factory RemoteDbDarkLibraryRow.fromJson(Map<String, dynamic> json) {
    return RemoteDbDarkLibraryRow(
      id: (json['id'] as num).toInt(),
      filePath: json['filePath'] as String? ?? '',
      frameType: json['frameType'] as String? ?? 'dark',
      exposureTime: (json['exposureTime'] as num?)?.toDouble() ?? 0.0,
      gain: (json['gain'] as num?)?.toInt() ?? 0,
      offset: (json['offset'] as num?)?.toInt() ?? 0,
      binX: (json['binX'] as num?)?.toInt() ?? 1,
      binY: (json['binY'] as num?)?.toInt() ?? 1,
      temperature: (json['temperature'] as num?)?.toDouble(),
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
      masterDarkPath: json['masterDarkPath'] as String?,
      masterFrameCount: (json['masterFrameCount'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }
}

/// Wire row for `/api/db/flat-history`. See [RemoteDbDarkLibraryRow]
/// for the rationale for keeping this distinct from
/// [RemoteFlatHistoryEntry].
class RemoteDbFlatHistoryRow {
  final int id;
  final String filterName;
  final double exposureTime;
  final double histogramTarget;
  final double actualAdu;
  final int? equipmentProfileId;
  final int? panelBrightness;
  final double? skyAduRate;
  final String? twilightPhase;
  final int gain;
  final int binning;
  final DateTime timestamp;

  const RemoteDbFlatHistoryRow({
    required this.id,
    required this.filterName,
    required this.exposureTime,
    required this.histogramTarget,
    required this.actualAdu,
    required this.gain,
    required this.binning,
    required this.timestamp,
    this.equipmentProfileId,
    this.panelBrightness,
    this.skyAduRate,
    this.twilightPhase,
  });

  factory RemoteDbFlatHistoryRow.fromJson(Map<String, dynamic> json) {
    return RemoteDbFlatHistoryRow(
      id: (json['id'] as num).toInt(),
      filterName: json['filterName'] as String? ?? '',
      exposureTime: (json['exposureTime'] as num?)?.toDouble() ?? 0.0,
      histogramTarget: (json['histogramTarget'] as num?)?.toDouble() ?? 0.0,
      actualAdu: (json['actualAdu'] as num?)?.toDouble() ?? 0.0,
      equipmentProfileId: (json['equipmentProfileId'] as num?)?.toInt(),
      panelBrightness: (json['panelBrightness'] as num?)?.toInt(),
      skyAduRate: (json['skyAduRate'] as num?)?.toDouble(),
      twilightPhase: json['twilightPhase'] as String?,
      gain: (json['gain'] as num?)?.toInt() ?? 0,
      binning: (json['binning'] as num?)?.toInt() ?? 1,
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }
}

// Wire types for per-run replay endpoints.

class RemoteSequenceRunDetail {
  final int id;
  final int? sequenceId;
  final String? sequenceName;
  final DateTime startedAt;
  final DateTime? endedAt;
  final String status;
  final String? statsJson;
  final int frameCount;
  final String? targetName;

  const RemoteSequenceRunDetail({
    required this.id,
    required this.startedAt,
    required this.status,
    required this.frameCount,
    this.sequenceId,
    this.sequenceName,
    this.endedAt,
    this.statsJson,
    this.targetName,
  });

  factory RemoteSequenceRunDetail.fromJson(Map<String, dynamic> json) {
    const context = 'sequence-run detail';
    final startedAt = _historyRequiredDate(json, 'startedAt', context);
    final endedAt = _historyOptionalDate(json, 'endedAt', context);
    if (endedAt != null && endedAt.isBefore(startedAt)) {
      throw const FormatException(
        'sequence-run detail endedAt precedes startedAt',
      );
    }
    return RemoteSequenceRunDetail(
      id: _historyRequiredInt(json, 'id', context, min: 1),
      sequenceId: _historyOptionalInt(json, 'sequenceId', context, min: 1),
      sequenceName: _historyOptionalString(json, 'sequenceName', context),
      startedAt: startedAt,
      endedAt: endedAt,
      status: _historyRequiredString(json, 'status', context),
      statsJson: _historyOptionalString(
        json,
        'statsJson',
        context,
        allowEmpty: true,
      ),
      frameCount: _historyRequiredInt(json, 'frameCount', context, min: 0),
      targetName: _historyOptionalString(json, 'targetName', context),
    );
  }

  Duration? get duration {
    final end = endedAt;
    if (end == null) return null;
    return end.difference(startedAt);
  }
}

/// The two persisted sequence documents needed for "diff vs previous run".
///
/// This is fetched explicitly rather than embedded in every run-history row:
/// sequence snapshots can be large, while only the diff action needs them.
class RemoteSequenceRunDiffContext {
  final int runId;
  final int? sequenceId;
  final String? currentSnapshotJson;
  final String? previousSnapshotJson;

  const RemoteSequenceRunDiffContext({
    required this.runId,
    required this.sequenceId,
    required this.currentSnapshotJson,
    required this.previousSnapshotJson,
  });

  factory RemoteSequenceRunDiffContext.fromJson(Map<String, dynamic> json) {
    const context = 'sequence-run diff context';
    return RemoteSequenceRunDiffContext(
      runId: _historyRequiredInt(json, 'runId', context, min: 1),
      sequenceId: _historyOptionalInt(json, 'sequenceId', context, min: 1),
      currentSnapshotJson: _historyOptionalString(
        json,
        'currentSnapshotJson',
        context,
      ),
      previousSnapshotJson: _historyOptionalString(
        json,
        'previousSnapshotJson',
        context,
      ),
    );
  }
}

class RemoteReplayEvent {
  final DateTime timestamp;
  final int timestampMs;
  final String severity;
  final String? source;
  final String message;
  final Map<String, dynamic>? fields;

  const RemoteReplayEvent({
    required this.timestamp,
    required this.timestampMs,
    required this.severity,
    required this.message,
    this.source,
    this.fields,
  });

  factory RemoteReplayEvent.fromJson(Map<String, dynamic> json) {
    const context = 'replay event';
    final timestamp = _historyRequiredDate(json, 'timestamp', context);
    final timestampMs = _historyRequiredInt(
      json,
      'timestampMs',
      context,
      min: 1,
    );
    if (timestamp.millisecondsSinceEpoch != timestampMs) {
      throw const FormatException(
        'replay event timestamp and timestampMs disagree',
      );
    }
    final rawFields = json['fields'];
    Map<String, dynamic>? fields;
    if (rawFields != null) {
      if (rawFields is! Map) {
        throw const FormatException('replay event fields must be an object');
      }
      try {
        fields = rawFields.cast<String, dynamic>();
      } on TypeError catch (error) {
        throw FormatException(
          'replay event fields have non-string keys',
          error,
        );
      }
    }
    return RemoteReplayEvent(
      timestamp: timestamp,
      timestampMs: timestampMs,
      severity: _historyRequiredString(json, 'severity', context),
      source: _historyOptionalString(json, 'source', context),
      message: _historyRequiredString(json, 'message', context),
      fields: fields,
    );
  }
}

class RemoteReplayEventsPage {
  final List<RemoteReplayEvent> items;
  final int total;
  final bool isPartial;
  final String? partialReason;
  final String source;

  const RemoteReplayEventsPage({
    required this.items,
    required this.total,
    required this.isPartial,
    required this.source,
    this.partialReason,
  });

  factory RemoteReplayEventsPage.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    if (rawItems is! List) {
      throw const FormatException(
        'Malformed replay-events page: missing items list',
      );
    }
    final items = <RemoteReplayEvent>[];
    for (var index = 0; index < rawItems.length; index++) {
      final raw = rawItems[index];
      if (raw is! Map) {
        throw FormatException('Replay-events row $index is not an object');
      }
      try {
        items.add(RemoteReplayEvent.fromJson(raw.cast<String, dynamic>()));
      } on TypeError catch (error) {
        throw FormatException(
          'Replay-events row $index has non-string keys',
          error,
        );
      }
    }
    final total = _historyRequiredInt(
      json,
      'total',
      'replay-events page',
      min: 0,
    );
    if (total < items.length) {
      throw FormatException(
        'Replay-events total $total is smaller than ${items.length} rows',
      );
    }
    final partial = json['is_partial'];
    if (partial is! bool) {
      throw const FormatException('Replay-events is_partial must be a boolean');
    }
    final partialReason = _historyOptionalString(
      json,
      'partialReason',
      'replay-events page',
    );
    if (partial && partialReason == null) {
      throw const FormatException(
        'Replay-events partial response omitted partialReason',
      );
    }
    if (!partial && partialReason != null) {
      throw const FormatException(
        'Replay-events complete response included partialReason',
      );
    }
    return RemoteReplayEventsPage(
      items: List.unmodifiable(items),
      total: total,
      isPartial: partial,
      partialReason: partialReason,
      source: _historyRequiredString(json, 'source', 'replay-events page'),
    );
  }
}

class RemoteReplayFrame {
  final int id;
  final String fileName;
  final String filePath;
  final DateTime capturedAt;
  final int capturedAtMs;
  final String frameType;
  final double exposureDuration;
  final String? filter;
  final int? gain;
  final int? offset;
  final int binX;
  final int binY;
  final double? sensorTemp;
  final double? hfr;
  final int? starCount;
  final double? background;
  final double? noise;
  final double? qualityScore;
  final double? guidingRmsRa;
  final double? guidingRmsDec;
  final double? guidingRmsTotal;
  final double? mountRa;
  final double? mountDec;
  final double? mountAltitude;
  final double? mountAzimuth;
  final int? focuserPosition;
  final bool isAccepted;
  final String? rejectionReason;
  final int? sessionId;
  final int? targetId;

  const RemoteReplayFrame({
    required this.id,
    required this.fileName,
    required this.filePath,
    required this.capturedAt,
    required this.capturedAtMs,
    required this.frameType,
    required this.exposureDuration,
    required this.binX,
    required this.binY,
    required this.isAccepted,
    this.filter,
    this.gain,
    this.offset,
    this.sensorTemp,
    this.hfr,
    this.starCount,
    this.background,
    this.noise,
    this.qualityScore,
    this.guidingRmsRa,
    this.guidingRmsDec,
    this.guidingRmsTotal,
    this.mountRa,
    this.mountDec,
    this.mountAltitude,
    this.mountAzimuth,
    this.focuserPosition,
    this.rejectionReason,
    this.sessionId,
    this.targetId,
  });

  factory RemoteReplayFrame.fromJson(Map<String, dynamic> json) {
    const context = 'replay frame';
    final capturedAt = _historyRequiredDate(json, 'capturedAt', context);
    final capturedAtMs = _historyRequiredInt(
      json,
      'capturedAtMs',
      context,
      min: 1,
    );
    if (capturedAt.millisecondsSinceEpoch != capturedAtMs) {
      throw const FormatException(
        'replay frame capturedAt and capturedAtMs disagree',
      );
    }
    final frameType = _historyRequiredString(json, 'frameType', context);
    const validFrameTypes = {
      'light',
      'dark',
      'flat',
      'bias',
      'darkflat',
      'snapshot',
    };
    if (!validFrameTypes.contains(frameType.toLowerCase())) {
      throw FormatException('replay frame has unknown frameType "$frameType"');
    }
    final isAccepted = json['isAccepted'];
    if (isAccepted is! bool) {
      throw const FormatException('replay frame isAccepted must be a boolean');
    }
    return RemoteReplayFrame(
      id: _historyRequiredInt(json, 'id', context, min: 1),
      fileName: _historyRequiredString(json, 'fileName', context),
      filePath: _historyRequiredString(json, 'filePath', context),
      capturedAt: capturedAt,
      capturedAtMs: capturedAtMs,
      frameType: frameType,
      exposureDuration: _historyRequiredDouble(
        json,
        'exposureDuration',
        context,
        min: 0,
      ),
      filter: _historyOptionalString(json, 'filter', context),
      gain: _historyOptionalInt(json, 'gain', context, min: 0),
      offset: _historyOptionalInt(json, 'offset', context, min: 0),
      binX: _historyRequiredInt(json, 'binX', context, min: 1),
      binY: _historyRequiredInt(json, 'binY', context, min: 1),
      sensorTemp: _historyOptionalDouble(json, 'sensorTemp', context),
      hfr: _historyOptionalDouble(json, 'hfr', context, min: 0),
      starCount: _historyOptionalInt(json, 'starCount', context, min: 0),
      background: _historyOptionalDouble(json, 'background', context),
      noise: _historyOptionalDouble(json, 'noise', context, min: 0),
      qualityScore: _historyOptionalDouble(json, 'qualityScore', context),
      guidingRmsRa: _historyOptionalDouble(
        json,
        'guidingRmsRa',
        context,
        min: 0,
      ),
      guidingRmsDec: _historyOptionalDouble(
        json,
        'guidingRmsDec',
        context,
        min: 0,
      ),
      guidingRmsTotal: _historyOptionalDouble(
        json,
        'guidingRmsTotal',
        context,
        min: 0,
      ),
      mountRa: _historyOptionalDouble(json, 'mountRa', context),
      mountDec: _historyOptionalDouble(json, 'mountDec', context),
      mountAltitude: _historyOptionalDouble(json, 'mountAltitude', context),
      mountAzimuth: _historyOptionalDouble(json, 'mountAzimuth', context),
      focuserPosition: _historyOptionalInt(
        json,
        'focuserPosition',
        context,
        min: 0,
      ),
      isAccepted: isAccepted,
      rejectionReason: _historyOptionalString(json, 'rejectionReason', context),
      sessionId: _historyOptionalInt(json, 'sessionId', context, min: 1),
      targetId: _historyOptionalInt(json, 'targetId', context, min: 1),
    );
  }
}

// Wire types for the plugin management endpoints.

/// Wire row for `/api/plugins`.
///
/// New hosts report the live, compiled-in plugin runtime. Older hosts may
/// return archive-registry rows, so [source], [runtimeLoaded], and [canEnable]
/// let clients distinguish an executable plugin from a stored artifact.
class RemotePluginManifest {
  final String id;
  final String name;
  final String version;
  final String? description;
  final String? author;
  final bool enabled;
  final bool signed;
  final bool signatureValid;
  final String? sha256;
  final int? sizeBytes;
  final DateTime? installedAt;
  final String? installedFilename;
  final String? loadError;
  final String source;
  final bool runtimeLoaded;
  final bool canEnable;

  const RemotePluginManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.enabled,
    required this.signed,
    required this.signatureValid,
    this.description,
    this.author,
    this.sha256,
    this.sizeBytes,
    this.installedAt,
    this.installedFilename,
    this.loadError,
    this.source = 'uploadedArchive',
    this.runtimeLoaded = false,
    this.canEnable = false,
  });

  factory RemotePluginManifest.fromJson(Map<String, dynamic> json) {
    return RemotePluginManifest(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      version: json['version'] as String? ?? '',
      description: json['description'] as String?,
      author: json['author'] as String?,
      enabled: json['enabled'] as bool? ?? false,
      signed: json['signed'] as bool? ?? false,
      signatureValid: json['signatureValid'] as bool? ?? false,
      sha256: json['sha256'] as String?,
      sizeBytes: (json['sizeBytes'] as num?)?.toInt(),
      installedAt: _parseDateField(json['installedAt']),
      installedFilename: json['installedFilename'] as String?,
      loadError: json['loadError'] as String?,
      source: json['source'] as String? ?? 'uploadedArchive',
      runtimeLoaded: json['runtimeLoaded'] as bool? ?? false,
      canEnable: json['canEnable'] as bool? ?? false,
    );
  }
}

int _historyRequiredInt(
  Map<String, dynamic> json,
  String key,
  String context, {
  required int min,
}) {
  if (!json.containsKey(key)) {
    throw FormatException('$context is missing $key');
  }
  final value = json[key];
  if (value is! num || !value.isFinite || value != value.truncateToDouble()) {
    throw FormatException('$context.$key must be an integer');
  }
  final result = value.toInt();
  if (result < min) {
    throw FormatException('$context.$key must be at least $min');
  }
  return result;
}

int? _historyOptionalInt(
  Map<String, dynamic> json,
  String key,
  String context, {
  required int min,
}) {
  if (!json.containsKey(key) || json[key] == null) return null;
  return _historyRequiredInt(json, key, context, min: min);
}

double _historyRequiredDouble(
  Map<String, dynamic> json,
  String key,
  String context, {
  double? min,
}) {
  if (!json.containsKey(key)) {
    throw FormatException('$context is missing $key');
  }
  final value = json[key];
  if (value is! num || !value.isFinite || (min != null && value < min)) {
    throw FormatException('$context.$key must be a valid finite number');
  }
  return value.toDouble();
}

double? _historyOptionalDouble(
  Map<String, dynamic> json,
  String key,
  String context, {
  double? min,
}) {
  if (!json.containsKey(key) || json[key] == null) return null;
  return _historyRequiredDouble(json, key, context, min: min);
}

String _historyRequiredString(
  Map<String, dynamic> json,
  String key,
  String context, {
  bool allowEmpty = false,
}) {
  final value = json[key];
  if (value is! String || (!allowEmpty && value.trim().isEmpty)) {
    throw FormatException('$context.$key must be a valid string');
  }
  return value;
}

String? _historyOptionalString(
  Map<String, dynamic> json,
  String key,
  String context, {
  bool allowEmpty = false,
}) {
  if (!json.containsKey(key) || json[key] == null) return null;
  return _historyRequiredString(json, key, context, allowEmpty: allowEmpty);
}

bool _historyRequiredBool(
  Map<String, dynamic> json,
  String key,
  String context,
) {
  final value = json[key];
  if (value is! bool) {
    throw FormatException('$context.$key must be a boolean');
  }
  return value;
}

List<String> _historyRequiredStringList(
  Map<String, dynamic> json,
  String key,
  String context,
) {
  final value = json[key];
  if (value is! List) {
    throw FormatException('$context.$key must be a string array');
  }
  final result = <String>[];
  for (var index = 0; index < value.length; index++) {
    final item = value[index];
    if (item is! String || item.trim().isEmpty) {
      throw FormatException('$context.$key[$index] must be a non-empty string');
    }
    result.add(item);
  }
  return List.unmodifiable(result);
}

DateTime _historyRequiredDate(
  Map<String, dynamic> json,
  String key,
  String context,
) {
  final raw = _historyRequiredString(json, key, context);
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) {
    throw FormatException('$context.$key is not a valid timestamp');
  }
  return parsed;
}

DateTime? _historyOptionalDate(
  Map<String, dynamic> json,
  String key,
  String context,
) {
  if (!json.containsKey(key) || json[key] == null) return null;
  return _historyRequiredDate(json, key, context);
}

/// Helper function to consolidate HTTP response bytes
Future<List<int>> consolidateHttpClientResponseBytes(
  HttpClientResponse response,
) {
  final completer = Completer<List<int>>();
  final chunks = <List<int>>[];

  response.listen(
    (chunk) => chunks.add(chunk),
    onDone: () => completer.complete(chunks.expand((x) => x).toList()),
    onError: completer.completeError,
    cancelOnError: true,
  );

  return completer.future;
}
