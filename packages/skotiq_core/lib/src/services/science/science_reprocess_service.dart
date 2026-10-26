import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../database/daos/images_dao.dart';
import '../../database/daos/science_dao.dart';
import '../../providers/database_provider.dart';
import '../logging_service.dart';
import 'science_processing_service.dart';

/// Progress of one session's science reprocess.
class ScienceReprocessProgress {
  const ScienceReprocessProgress({
    required this.jobId,
    required this.sessionId,
    required this.force,
    required this.lightOnly,
    required this.state,
    required this.total,
    required this.done,
    required this.processed,
    required this.skipped,
    required this.failed,
    required this.alreadyProcessed,
    required this.startedAt,
    this.finishedAt,
    this.currentFile,
    this.lastError,
    this.failures = const [],
  });

  final String jobId;
  final int sessionId;
  final bool force;
  final bool lightOnly;

  /// `running`, `completed` or `failed` (the walk itself broke).
  final String state;

  /// Frames queued for this job; [done] of them are finished.
  final int total;
  final int done;
  final int processed;

  /// Frames the pipeline does not process (calibration frames).
  final int skipped;
  final int failed;

  /// Frames left out because they already had science results.
  final int alreadyProcessed;
  final DateTime startedAt;
  final DateTime? finishedAt;
  final String? currentFile;
  final String? lastError;

  /// The most recent failures, newest last, bounded.
  final List<ScienceReprocessFailure> failures;

  bool get isRunning => state == 'running';

  Map<String, Object?> toJson() => {
    'jobId': jobId,
    'sessionId': sessionId,
    'force': force,
    'lightOnly': lightOnly,
    'state': state,
    'total': total,
    'done': done,
    'processed': processed,
    'skipped': skipped,
    'failed': failed,
    'alreadyProcessed': alreadyProcessed,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'finishedAt': finishedAt?.toUtc().toIso8601String(),
    'currentFile': currentFile,
    'lastError': lastError,
    'failures': [for (final f in failures) f.toJson()],
  };
}

class ScienceReprocessFailure {
  const ScienceReprocessFailure({
    required this.capturedImageId,
    required this.filePath,
    required this.reason,
  });

  final int capturedImageId;
  final String filePath;
  final String reason;

  Map<String, Object?> toJson() => {
    'capturedImageId': capturedImageId,
    'filePath': filePath,
    'reason': reason,
  };
}

/// Runs a recorded session's frames through the per-frame science pipeline
/// after the fact, in capture order, one frame at a time, in the background.
///
/// Frames that already have science results are left alone unless forced;
/// the pipeline replaces a frame's products rather than adding to them, so a
/// frame processed twice (live and here) keeps one set. A session has at most
/// one job running; starting another while it runs returns the running one.
class ScienceReprocessService {
  ScienceReprocessService({
    required ImagesDao Function() images,
    required ScienceDao Function() science,
    required ScienceProcessingService Function() pipeline,
    required LoggingService Function() logger,
    Future<bool> Function(String path)? fileExists,
  }) : _images = images,
       _science = science,
       _pipeline = pipeline,
       _logger = logger,
       _fileExists = fileExists ?? ((path) => File(path).exists());

  final ImagesDao Function() _images;
  final ScienceDao Function() _science;
  final ScienceProcessingService Function() _pipeline;
  final LoggingService Function() _logger;
  final Future<bool> Function(String path) _fileExists;

  static const int _failuresKept = 50;
  static const String _source = 'ScienceReprocess';

  final Map<int, _Job> _jobs = <int, _Job>{};

  /// The latest job for [sessionId], running or finished; null when none ran.
  ScienceReprocessProgress? progress(int sessionId) =>
      _jobs[sessionId]?.snapshot();

  /// The future of [sessionId]'s current walk, for tests.
  Future<void>? jobFuture(int sessionId) => _jobs[sessionId]?.future;

  /// Start reprocessing [sessionId] and return its progress at once. With
  /// [force], frames that already have science results are processed again;
  /// with [lightOnly], only light frames are walked.
  Future<ScienceReprocessProgress> start(
    int sessionId, {
    bool force = false,
    bool lightOnly = true,
  }) async {
    final running = _jobs[sessionId];
    if (running != null && running.state == 'running') {
      return running.snapshot();
    }

    final rows = await _images().getImagesForSession(sessionId);
    final ordered = rows.toList()
      ..sort((a, b) {
        final byTime = a.capturedAt.compareTo(b.capturedAt);
        return byTime != 0 ? byTime : a.id.compareTo(b.id);
      });
    final candidates = lightOnly
        ? ordered.where((r) => r.frameType.toLowerCase() == 'light').toList()
        : ordered;
    final withScience = force
        ? const <int>{}
        : await _science().getCapturedImageIdsWithScience(sessionId);
    final queue = [
      for (final r in candidates)
        if (!withScience.contains(r.id)) (id: r.id, path: r.filePath),
    ];

    final startedAt = DateTime.now();
    final job = _Job(
      jobId: '$sessionId-${startedAt.millisecondsSinceEpoch}',
      sessionId: sessionId,
      force: force,
      lightOnly: lightOnly,
      total: queue.length,
      alreadyProcessed: candidates.length - queue.length,
      startedAt: startedAt,
    );
    _jobs[sessionId] = job;
    _logger().info(
      'Reprocessing science for session $sessionId: ${queue.length} '
      'frame(s) queued, ${job.alreadyProcessed} already processed '
      '(force=$force, lightOnly=$lightOnly).',
      source: _source,
    );
    job.future = _walk(job, queue);
    return job.snapshot();
  }

  Future<void> _walk(_Job job, List<({int id, String path})> queue) async {
    final pipeline = _pipeline();
    try {
      for (final frame in queue) {
        job.currentFile = frame.path;
        if (frame.path.isEmpty || !await _fileExists(frame.path)) {
          job.fail(
            frame.id,
            frame.path,
            frame.path.isEmpty
                ? 'Frame has no file path'
                : 'File not found: ${frame.path}',
            _failuresKept,
          );
          continue;
        }
        final outcome = await pipeline.processFrame(
          imagePath: frame.path,
          capturedImageId: frame.id,
          sessionId: job.sessionId,
        );
        switch (outcome.kind) {
          case ScienceFrameOutcomeKind.processed:
            job.processed++;
            job.done++;
          case ScienceFrameOutcomeKind.skipped:
            job.skipped++;
            job.done++;
          case ScienceFrameOutcomeKind.failed:
            job.fail(
              frame.id,
              frame.path,
              outcome.error ?? 'Science processing failed',
              _failuresKept,
            );
        }
        if (job.done % 25 == 0) {
          _logger().info(
            'Science reprocess of session ${job.sessionId}: '
            '${job.done}/${job.total} done, ${job.failed} failed.',
            source: _source,
          );
        }
      }
      job.state = 'completed';
    } catch (e) {
      job.state = 'failed';
      job.lastError = e.toString();
      _logger().error(
        'Science reprocess of session ${job.sessionId} stopped: $e',
        source: _source,
      );
    } finally {
      job.currentFile = null;
      job.finishedAt = DateTime.now();
      _logger().info(
        'Science reprocess of session ${job.sessionId} ${job.state}: '
        '${job.processed} processed, ${job.skipped} skipped, '
        '${job.failed} failed of ${job.total}.',
        source: _source,
      );
    }
  }
}

class _Job {
  _Job({
    required this.jobId,
    required this.sessionId,
    required this.force,
    required this.lightOnly,
    required this.total,
    required this.alreadyProcessed,
    required this.startedAt,
  });

  final String jobId;
  final int sessionId;
  final bool force;
  final bool lightOnly;
  final int total;
  final int alreadyProcessed;
  final DateTime startedAt;
  String state = 'running';
  int done = 0;
  int processed = 0;
  int skipped = 0;
  int failed = 0;
  String? currentFile;
  String? lastError;
  DateTime? finishedAt;
  final List<ScienceReprocessFailure> failures = [];
  Future<void> future = Future<void>.value();

  void fail(int id, String path, String reason, int keep) {
    failed++;
    done++;
    lastError = reason;
    failures.add(
      ScienceReprocessFailure(
        capturedImageId: id,
        filePath: path,
        reason: reason,
      ),
    );
    if (failures.length > keep) failures.removeAt(0);
  }

  ScienceReprocessProgress snapshot() => ScienceReprocessProgress(
    jobId: jobId,
    sessionId: sessionId,
    force: force,
    lightOnly: lightOnly,
    state: state,
    total: total,
    done: done,
    processed: processed,
    skipped: skipped,
    failed: failed,
    alreadyProcessed: alreadyProcessed,
    startedAt: startedAt,
    finishedAt: finishedAt,
    currentFile: currentFile,
    lastError: lastError,
    failures: List.unmodifiable(failures),
  );
}

final scienceReprocessServiceProvider = Provider<ScienceReprocessService>((
  ref,
) {
  return ScienceReprocessService(
    images: () => ref.read(imagesDaoProvider),
    science: () => ref.read(scienceDaoProvider),
    pipeline: () => ref.read(scienceProcessingServiceProvider),
    logger: () => ref.read(loggingServiceProvider),
  );
});
