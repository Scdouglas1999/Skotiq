/// A long-running operation the host runs as a job (`JobApi`), as its job
/// snapshots and admission answers describe it.
library;

import '../wire_time.dart';

/// Where a job is in its life. Transitions:
///   queued  -> running -> succeeded | failed | cancelled
///   queued  -> cancelled (when cancelled before the host picks it up)
enum JobState {
  queued,
  running,
  succeeded,
  failed,
  cancelled;

  String get wireName => name;

  bool get isTerminal =>
      this == succeeded || this == failed || this == cancelled;

  /// The state [wire] names, or null for one this build does not know.
  static JobState? fromWire(String wire) {
    for (final state in values) {
      if (state.wireName == wire) return state;
    }
    return null;
  }
}

/// The work the host runs as a job, by its wire name. The host starts jobs
/// only from this list, and clients that react to a job's end switch on it.
enum JobOperation {
  plateSolve('plate-solve'),
  centerOnTarget('framing.center-on-target'),
  autofocus('focuser.autofocus'),
  backlashCalibration('focuser.backlash-calibration'),
  catalogDownload('catalog.download'),
  backfillThumbnails('image.backfill-thumbnails'),
  updateCheck('system.update.check'),
  updateDownload('system.update.download'),
  updateApply('system.update.apply'),
  updateRollback('system.update.rollback'),
  postSessionIntegrate('post-session.integrate'),
  postSessionDrizzle('post-session.drizzle'),
  postSessionAnalyzeNight('post-session.analyze-night'),
  postSessionBuildMasterFlat('post-session.build-master-flat'),
  postSessionColorCalibrate('post-session.color-calibrate'),
  postSessionDetectStars('post-session.detect-stars'),
  postSessionExtractBackground('post-session.extract-background'),
  postSessionMasterAccumulate('post-session.master-accumulate');

  const JobOperation(this.wire);

  final String wire;

  /// True for the update jobs, which run one at a time.
  bool get isUpdate =>
      this == updateCheck ||
      this == updateDownload ||
      this == updateApply ||
      this == updateRollback;

  /// The operation [wire] names, or null for one this build does not know.
  static JobOperation? fromWire(String wire) {
    for (final operation in values) {
      if (operation.wire == wire) return operation;
    }
    return null;
  }
}

/// One job. [state] stays a string so a host that adds a lifecycle phase
/// does not break older clients.
class RemoteJob {
  final String jobId;
  final String operation;
  final String? deviceId;
  final String? commandId;
  final String state;
  final double? progress;
  final String? progressMessage;
  final Map<String, dynamic>? result;
  final Map<String, dynamic>? error;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const RemoteJob({
    required this.jobId,
    required this.operation,
    required this.state,
    this.deviceId,
    this.commandId,
    this.progress,
    this.progressMessage,
    this.result,
    this.error,
    this.createdAt,
    this.updatedAt,
  });

  /// [state] as this build knows it; null for a phase it does not know.
  JobState? get knownState => JobState.fromWire(state);

  bool get isTerminal => knownState?.isTerminal == true;

  factory RemoteJob.fromJson(
    Map<String, dynamic> json, {
    String? fallbackOperation,
  }) {
    final jobId = json['jobId'];
    if (jobId is! String || jobId.trim().isEmpty) {
      throw const FormatException('Remote job response is missing `jobId`.');
    }
    final rawOperation = json['operation'];
    final operation = rawOperation is String && rawOperation.trim().isNotEmpty
        ? rawOperation
        : fallbackOperation;
    if (operation == null || operation.trim().isEmpty) {
      throw const FormatException(
        'Remote job response is missing `operation`.',
      );
    }
    // Admission endpoints return `{jobId, status: queued}` while snapshots
    // return `{jobId, operation, state: ...}`. Treat both as the same wire
    // contract instead of turning every newly-started job into `unknown`.
    final rawState = json['state'] ?? json['status'];
    if (rawState is! String || rawState.trim().isEmpty) {
      throw const FormatException('Remote job response is missing job state.');
    }
    return RemoteJob(
      jobId: jobId,
      operation: operation,
      deviceId: json['deviceId'] as String?,
      commandId: json['commandId'] as String?,
      state: rawState,
      progress: (json['progress'] as num?)?.toDouble(),
      progressMessage: json['progressMessage'] as String?,
      result: json['result'] is Map
          ? Map<String, dynamic>.from(json['result'] as Map)
          : null,
      error: json['error'] is Map
          ? Map<String, dynamic>.from(json['error'] as Map)
          : null,
      createdAt: _parseDate(json['createdAt']),
      updatedAt: _parseDate(json['updatedAt']),
    );
  }

  Map<String, dynamic> toJson() => {
    'jobId': jobId,
    'operation': operation,
    if (deviceId != null) 'deviceId': deviceId,
    if (commandId != null) 'commandId': commandId,
    'state': state,
    if (createdAt != null) 'createdAt': createdAt!.toWireTime(),
    if (updatedAt != null) 'updatedAt': updatedAt!.toWireTime(),
    if (progress != null) 'progress': progress,
    if (progressMessage != null) 'progressMessage': progressMessage,
    if (result != null) 'result': result,
    if (error != null) 'error': error,
  };

  /// Construct from the `data` map of a job-category SkotiqEvent.
  /// The wire shape there is a subset of [fromJson] (no createdAt /
  /// updatedAt — the event itself carries the timestamp).
  factory RemoteJob.fromEventData(Map<String, dynamic> data) {
    return RemoteJob(
      jobId: data['jobId'] as String? ?? '',
      operation: data['operation'] as String? ?? '',
      deviceId: data['deviceId'] as String?,
      commandId: data['commandId'] as String?,
      state: data['state'] as String? ?? 'unknown',
      progress: (data['progress'] as num?)?.toDouble(),
      progressMessage: data['message'] as String?,
      result: data['result'] is Map
          ? Map<String, dynamic>.from(data['result'] as Map)
          : null,
      error: data['error'] is Map
          ? Map<String, dynamic>.from(data['error'] as Map)
          : null,
    );
  }

  static DateTime? _parseDate(Object? raw) {
    if (raw is! String) return null;
    return tryParseWireTime(raw);
  }
}
