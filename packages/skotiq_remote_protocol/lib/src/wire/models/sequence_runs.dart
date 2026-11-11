/// Past sequence runs and what the replay view reads about one of them
/// (`DbReadApi`).
library;

import '../json_fields.dart';

/// One row of `GET /api/sequence-runs`.
class RemoteSequenceRun {
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
    final startedAt = requiredDate(json, 'startedAt', context);
    final endedAt = optionalDate(json, 'endedAt', context);
    if (endedAt != null && endedAt.isBefore(startedAt)) {
      throw const FormatException(
        'sequence-run row endedAt precedes startedAt',
      );
    }
    return RemoteSequenceRun(
      id: requiredInt(json, 'id', context, min: 1),
      sequenceId: optionalInt(json, 'sequenceId', context, min: 1),
      sequenceName: optionalString(json, 'sequenceName', context),
      startedAt: startedAt,
      endedAt: endedAt,
      status: requiredString(json, 'status', context),
      statsJson: optionalString(json, 'statsJson', context, allowEmpty: true),
    );
  }

  final int id;
  final int? sequenceId;
  final String? sequenceName;
  final DateTime startedAt;
  final DateTime? endedAt;
  final String status;
  final String? statsJson;

  Map<String, dynamic> toJson() => {
    'id': id,
    'sequenceId': sequenceId,
    'sequenceName': sequenceName,
    'startedAt': startedAt.toIso8601String(),
    'endedAt': endedAt?.toIso8601String(),
    'status': status,
    'statsJson': statsJson,
  };
}

/// The `run` object of `GET /api/sequence-runs/<runId>`: the list row plus
/// what the replay header shows without loading the frames.
class RemoteSequenceRunDetail {
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
    final startedAt = requiredDate(json, 'startedAt', context);
    final endedAt = optionalDate(json, 'endedAt', context);
    if (endedAt != null && endedAt.isBefore(startedAt)) {
      throw const FormatException(
        'sequence-run detail endedAt precedes startedAt',
      );
    }
    return RemoteSequenceRunDetail(
      id: requiredInt(json, 'id', context, min: 1),
      sequenceId: optionalInt(json, 'sequenceId', context, min: 1),
      sequenceName: optionalString(json, 'sequenceName', context),
      startedAt: startedAt,
      endedAt: endedAt,
      status: requiredString(json, 'status', context),
      statsJson: optionalString(json, 'statsJson', context, allowEmpty: true),
      frameCount: requiredInt(json, 'frameCount', context, min: 0),
      targetName: optionalString(json, 'targetName', context),
    );
  }

  final int id;
  final int? sequenceId;
  final String? sequenceName;
  final DateTime startedAt;
  final DateTime? endedAt;
  final String status;
  final String? statsJson;

  /// Frames the run captured.
  final int frameCount;

  /// Target of the run's first frame that has one; absent when no frame
  /// names a target.
  final String? targetName;

  Duration? get duration {
    final end = endedAt;
    if (end == null) return null;
    return end.difference(startedAt);
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'sequenceId': sequenceId,
    'sequenceName': sequenceName,
    'startedAt': startedAt.toIso8601String(),
    'endedAt': endedAt?.toIso8601String(),
    'status': status,
    'statsJson': statsJson,
    'frameCount': frameCount,
    if (targetName != null) 'targetName': targetName,
  };
}

/// The two persisted sequence documents needed for "diff vs previous run"
/// (`diffContext` of `GET /api/sequence-runs/<runId>?includeDiffContext=true`).
///
/// Fetched only on request rather than embedded in every run row: sequence
/// snapshots can be large, while only the diff action needs them.
class RemoteSequenceRunDiffContext {
  const RemoteSequenceRunDiffContext({
    required this.runId,
    required this.sequenceId,
    required this.currentSnapshotJson,
    required this.previousSnapshotJson,
  });

  factory RemoteSequenceRunDiffContext.fromJson(Map<String, dynamic> json) {
    const context = 'sequence-run diff context';
    return RemoteSequenceRunDiffContext(
      runId: requiredInt(json, 'runId', context, min: 1),
      sequenceId: optionalInt(json, 'sequenceId', context, min: 1),
      currentSnapshotJson: optionalString(json, 'currentSnapshotJson', context),
      previousSnapshotJson: optionalString(
        json,
        'previousSnapshotJson',
        context,
      ),
    );
  }

  final int runId;
  final int? sequenceId;
  final String? currentSnapshotJson;
  final String? previousSnapshotJson;

  Map<String, dynamic> toJson() => {
    'runId': runId,
    'sequenceId': sequenceId,
    'currentSnapshotJson': currentSnapshotJson,
    'previousSnapshotJson': previousSnapshotJson,
  };
}

/// One log entry in `GET /api/sequence-runs/<runId>/events`.
class RemoteReplayEvent {
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
    final timestamp = requiredDate(json, 'timestamp', context);
    final timestampMs = requiredInt(json, 'timestampMs', context, min: 1);
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
      severity: requiredString(json, 'severity', context),
      source: optionalString(json, 'source', context),
      message: requiredString(json, 'message', context),
      fields: fields,
    );
  }

  final DateTime timestamp;

  /// [timestamp] in Unix milliseconds, so the scrubber compares integers
  /// on every drag frame instead of parsing dates.
  final int timestampMs;
  final String severity;
  final String? source;
  final String message;
  final Map<String, dynamic>? fields;

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toUtc().toIso8601String(),
    'timestampMs': timestampMs,
    'severity': severity,
    if (source != null) 'source': source,
    'message': message,
    if (fields != null) 'fields': fields,
  };
}

/// `GET /api/sequence-runs/<runId>/events`. The host keeps recent log
/// entries in a ring buffer, so a page for an older run can be missing
/// entries; [isPartial] and [partialReason] say so.
class RemoteReplayEventsPage {
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
    final total = requiredInt(json, 'total', 'replay-events page', min: 0);
    if (total < items.length) {
      throw FormatException(
        'Replay-events total $total is smaller than ${items.length} rows',
      );
    }
    final partial = json['is_partial'];
    if (partial is! bool) {
      throw const FormatException('Replay-events is_partial must be a boolean');
    }
    final partialReason = optionalString(
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
      source: requiredString(json, 'source', 'replay-events page'),
    );
  }

  final List<RemoteReplayEvent> items;
  final int total;
  final bool isPartial;
  final String? partialReason;

  /// Where the host read the entries from.
  final String source;

  Map<String, dynamic> toJson() => {
    'items': items.map((event) => event.toJson()).toList(growable: false),
    'total': total,
    'is_partial': isPartial,
    'source': source,
    if (partialReason != null) 'partialReason': partialReason,
  };
}

/// One captured frame in `GET /api/sequence-runs/<runId>/frames`. Pixels
/// are not included; they come from the image endpoints by [id].
class RemoteReplayFrame {
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
    final capturedAt = requiredDate(json, 'capturedAt', context);
    final capturedAtMs = requiredInt(json, 'capturedAtMs', context, min: 1);
    if (capturedAt.millisecondsSinceEpoch != capturedAtMs) {
      throw const FormatException(
        'replay frame capturedAt and capturedAtMs disagree',
      );
    }
    final frameType = requiredString(json, 'frameType', context);
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
      id: requiredInt(json, 'id', context, min: 1),
      fileName: requiredString(json, 'fileName', context),
      filePath: requiredString(json, 'filePath', context),
      capturedAt: capturedAt,
      capturedAtMs: capturedAtMs,
      frameType: frameType,
      exposureDuration: requiredDouble(
        json,
        'exposureDuration',
        context,
        min: 0,
      ),
      filter: optionalString(json, 'filter', context),
      gain: optionalInt(json, 'gain', context, min: 0),
      offset: optionalInt(json, 'offset', context, min: 0),
      binX: requiredInt(json, 'binX', context, min: 1),
      binY: requiredInt(json, 'binY', context, min: 1),
      sensorTemp: optionalDouble(json, 'sensorTemp', context),
      hfr: optionalDouble(json, 'hfr', context, min: 0),
      starCount: optionalInt(json, 'starCount', context, min: 0),
      background: optionalDouble(json, 'background', context),
      noise: optionalDouble(json, 'noise', context, min: 0),
      qualityScore: optionalDouble(json, 'qualityScore', context),
      guidingRmsRa: optionalDouble(json, 'guidingRmsRa', context, min: 0),
      guidingRmsDec: optionalDouble(json, 'guidingRmsDec', context, min: 0),
      guidingRmsTotal: optionalDouble(json, 'guidingRmsTotal', context, min: 0),
      mountRa: optionalDouble(json, 'mountRa', context),
      mountDec: optionalDouble(json, 'mountDec', context),
      mountAltitude: optionalDouble(json, 'mountAltitude', context),
      mountAzimuth: optionalDouble(json, 'mountAzimuth', context),
      focuserPosition: optionalInt(json, 'focuserPosition', context, min: 0),
      isAccepted: isAccepted,
      rejectionReason: optionalString(json, 'rejectionReason', context),
      sessionId: optionalInt(json, 'sessionId', context, min: 1),
      targetId: optionalInt(json, 'targetId', context, min: 1),
    );
  }

  final int id;
  final String fileName;
  final String filePath;
  final DateTime capturedAt;

  /// [capturedAt] in Unix milliseconds.
  final int capturedAtMs;
  final String frameType;

  /// Seconds.
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

  /// Hours.
  final double? mountRa;
  final double? mountDec;
  final double? mountAltitude;
  final double? mountAzimuth;
  final int? focuserPosition;
  final bool isAccepted;
  final String? rejectionReason;
  final int? sessionId;
  final int? targetId;

  Map<String, dynamic> toJson() => {
    'id': id,
    'fileName': fileName,
    'filePath': filePath,
    'capturedAt': capturedAt.toIso8601String(),
    'capturedAtMs': capturedAtMs,
    'frameType': frameType,
    'exposureDuration': exposureDuration,
    'filter': filter,
    'gain': gain,
    'offset': offset,
    'binX': binX,
    'binY': binY,
    'sensorTemp': sensorTemp,
    'hfr': hfr,
    'starCount': starCount,
    'background': background,
    'noise': noise,
    'qualityScore': qualityScore,
    'guidingRmsRa': guidingRmsRa,
    'guidingRmsDec': guidingRmsDec,
    'guidingRmsTotal': guidingRmsTotal,
    'mountRa': mountRa,
    'mountDec': mountDec,
    'mountAltitude': mountAltitude,
    'mountAzimuth': mountAzimuth,
    'focuserPosition': focuserPosition,
    'isAccepted': isAccepted,
    'rejectionReason': rejectionReason,
    'sessionId': sessionId,
    'targetId': targetId,
  };
}
