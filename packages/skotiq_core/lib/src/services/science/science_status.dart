/// Live status model for the science processing pipeline.
///
/// `ScienceProcessingService` broadcasts a [ScienceProcessingStatus] every
/// time a stage starts, completes, or fails. Providers and UI listen so users
/// can see what science is doing — instead of inferring it from empty cards
/// and silent log lines.
///
/// Stages match the major work units inside the processing pipeline:
///   * [ScienceStage.frameQuality]   — immediate quality lane (clip, noise…)
///   * [ScienceStage.plateSolve]     — resolve WCS for science products
///   * [ScienceStage.calibration]    — photometric zero point + lim mag
///   * [ScienceStage.transparency]   — atmospheric extinction estimate
///   * [ScienceStage.psfMap]         — PSF / FWHM field map
///   * [ScienceStage.residuals]      — astrometric residual vectors
///   * [ScienceStage.photometry]     — per-target differential photometry
///   * [ScienceStage.movingObjects]  — multi-frame moving object detection
library;

import 'dart:async';

/// Identifies one logical stage of the science processing pipeline.
enum ScienceStage {
  frameQuality('Frame quality'),
  plateSolve('Plate solve'),
  calibration('Calibration'),
  transparency('Transparency'),
  psfMap('PSF map'),
  residuals('Astrometric residuals'),
  photometry('Photometry'),
  movingObjects('Moving objects'),

  /// Writes the science measurements (MAGZP, MAGZPERR, MAGZPSRC, TRANSPAR,
  /// NSHA_VER) back into the captured frame's FITS header so
  /// external pipelines (PixInsight, AstroPixelProcessor, Siril) can read
  /// Skotiq's products without going through the database.
  fitsWriteback('FITS writeback'),

  /// Evaluates capture-time quality thresholds and may reject the frame in
  /// the database (never deletes files).
  autoGrade('Auto grade');

  const ScienceStage(this.displayName);
  final String displayName;
}

/// Outcome of a single stage for a single frame.
enum ScienceStageOutcome {
  /// Stage is currently running.
  running,

  /// Stage produced data and persisted at least one row.
  ok,

  /// Stage was skipped on purpose (disabled in settings / session config,
  /// frame type wasn't `light`, etc.).
  skipped,

  /// Stage ran but had nothing to produce (e.g. <8 catalog matches,
  /// not enough frames for moving-object detection). Not an error.
  noData,

  /// Stage failed with a recoverable error. The capture itself still
  /// succeeded — only the science derivative failed.
  failed,
}

/// Result of one stage for one frame. Immutable.
class ScienceStageResult {
  final ScienceStage stage;
  final ScienceStageOutcome outcome;

  /// Human-readable note: "skipped (transparency disabled)",
  /// "12 stars matched", "no WCS available", etc.
  final String? note;

  /// Wall-clock duration of the stage in milliseconds. `null` while running.
  final int? durationMs;

  /// Capture path being processed.
  final String? imagePath;

  /// DB id of the [CapturedImages] row, when available.
  final int? capturedImageId;

  /// Session id, when available.
  final int? sessionId;

  final DateTime timestamp;

  const ScienceStageResult({
    required this.stage,
    required this.outcome,
    required this.timestamp,
    this.note,
    this.durationMs,
    this.imagePath,
    this.capturedImageId,
    this.sessionId,
  });

  ScienceStageResult copyWith({
    ScienceStageOutcome? outcome,
    String? note,
    int? durationMs,
  }) {
    return ScienceStageResult(
      stage: stage,
      outcome: outcome ?? this.outcome,
      timestamp: timestamp,
      note: note ?? this.note,
      durationMs: durationMs ?? this.durationMs,
      imagePath: imagePath,
      capturedImageId: capturedImageId,
      sessionId: sessionId,
    );
  }
}

/// Aggregate status for a single frame across all stages.
class ScienceFrameStatus {
  final String imagePath;
  final int? capturedImageId;
  final int? sessionId;
  final DateTime startedAt;
  final DateTime? finishedAt;

  /// Stage results keyed by [ScienceStage]. A missing entry means the stage
  /// has not been attempted for this frame yet.
  final Map<ScienceStage, ScienceStageResult> stages;

  const ScienceFrameStatus({
    required this.imagePath,
    required this.startedAt,
    required this.stages,
    this.capturedImageId,
    this.sessionId,
    this.finishedAt,
  });

  bool get isComplete => finishedAt != null;

  /// True if any attempted stage failed. Skipped/noData are not failures.
  bool get hasFailure =>
      stages.values.any((r) => r.outcome == ScienceStageOutcome.failed);

  /// Stages currently running for this frame.
  Iterable<ScienceStage> get runningStages => stages.entries
      .where((e) => e.value.outcome == ScienceStageOutcome.running)
      .map((e) => e.key);

  ScienceFrameStatus copyWith({
    DateTime? finishedAt,
    Map<ScienceStage, ScienceStageResult>? stages,
  }) {
    return ScienceFrameStatus(
      imagePath: imagePath,
      capturedImageId: capturedImageId,
      sessionId: sessionId,
      startedAt: startedAt,
      finishedAt: finishedAt ?? this.finishedAt,
      stages: stages ?? this.stages,
    );
  }
}

/// Lifecycle event emitted by [ScienceProcessingService].
class ScienceProcessingEvent {
  /// Stage status change. May reflect a new frame (`stageResult` is running)
  /// or a completed/failed/noData/skipped result.
  final ScienceStageResult stageResult;

  /// Snapshot of the queue depth at the time of the event. The processing
  /// service runs one frame at a time today; this number is the number of
  /// frames waiting to be picked up.
  final int queueDepth;

  /// `true` when this event marks the last stage of a frame (i.e. the
  /// `processCapturedFrame` call is about to return).
  final bool frameCompleted;

  const ScienceProcessingEvent({
    required this.stageResult,
    required this.queueDepth,
    this.frameCompleted = false,
  });
}

/// In-memory tracker for the current processing status of every frame.
///
/// Owned by [ScienceProcessingService]. Exposed via
/// `scienceProcessingStatusProvider` so the UI can render live progress.
///
/// Thread-safety: all mutations happen on the Dart isolate thread that owns
/// the processing service. Listeners receive immutable snapshots.
class ScienceProcessingStatusTracker {
  final StreamController<ScienceProcessingEvent> _controller =
      StreamController<ScienceProcessingEvent>.broadcast();

  /// Most recently processed frames (newest first). Capped to [_historyCap]
  /// so we never grow unbounded across a long session.
  static const int _historyCap = 32;
  final List<ScienceFrameStatus> _history = <ScienceFrameStatus>[];

  /// Currently in-flight frame, if any. We process one frame at a time.
  ScienceFrameStatus? _inflight;

  int _queueDepth = 0;

  /// Public stream of stage-level events.
  Stream<ScienceProcessingEvent> get events => _controller.stream;

  /// Snapshot of recent frames, newest first. Includes the in-flight frame
  /// at index 0 when present.
  List<ScienceFrameStatus> snapshot() {
    return <ScienceFrameStatus>[if (_inflight != null) _inflight!, ..._history];
  }

  /// Most recent completed frame (failed or successful), if any.
  ScienceFrameStatus? get lastCompleted =>
      _history.isEmpty ? null : _history.first;

  ScienceFrameStatus? get inflight => _inflight;

  int get queueDepth => _queueDepth;

  /// Most recent failed stage result across all tracked frames. Useful for
  /// surfacing a single "last error" line in the UI.
  ScienceStageResult? get lastFailure {
    for (final frame in snapshot()) {
      for (final result in frame.stages.values) {
        if (result.outcome == ScienceStageOutcome.failed) {
          return result;
        }
      }
    }
    return null;
  }

  /// Called by [ScienceProcessingService] when a new frame enters the queue.
  void enqueue() {
    _queueDepth++;
  }

  /// Called when an enqueued frame is dropped without processing (e.g. a
  /// dark/flat/bias that the science pipeline skips before [beginFrame]).
  /// Without this, every non-light capture would permanently inflate the
  /// reported queue depth.
  void dequeue() {
    _queueDepth = _queueDepth > 0 ? _queueDepth - 1 : 0;
  }

  /// Called when processing of [imagePath] begins. Initializes the in-flight
  /// frame status record.
  void beginFrame({
    required String imagePath,
    int? capturedImageId,
    int? sessionId,
  }) {
    _queueDepth = _queueDepth > 0 ? _queueDepth - 1 : 0;
    _inflight = ScienceFrameStatus(
      imagePath: imagePath,
      capturedImageId: capturedImageId,
      sessionId: sessionId,
      startedAt: DateTime.now(),
      stages: const <ScienceStage, ScienceStageResult>{},
    );
  }

  /// Mark [stage] as currently running for the in-flight frame.
  Stopwatch beginStage(ScienceStage stage) {
    final stopwatch = Stopwatch()..start();
    final frame = _inflight;
    if (frame == null) {
      // Stage ran without an active frame — emit a one-off event so the UI
      // still hears about it. This is defensive; the normal path always
      // calls beginFrame first.
      final result = ScienceStageResult(
        stage: stage,
        outcome: ScienceStageOutcome.running,
        timestamp: DateTime.now(),
      );
      _emit(result, frameCompleted: false);
      return stopwatch;
    }
    final result = ScienceStageResult(
      stage: stage,
      outcome: ScienceStageOutcome.running,
      timestamp: DateTime.now(),
      imagePath: frame.imagePath,
      capturedImageId: frame.capturedImageId,
      sessionId: frame.sessionId,
    );
    final next = Map<ScienceStage, ScienceStageResult>.from(frame.stages)
      ..[stage] = result;
    _inflight = frame.copyWith(stages: next);
    _emit(result);
    return stopwatch;
  }

  /// Mark [stage] complete with [outcome] for the in-flight frame.
  void endStage(
    ScienceStage stage,
    ScienceStageOutcome outcome, {
    Stopwatch? stopwatch,
    String? note,
  }) {
    final frame = _inflight;
    final durationMs = stopwatch == null
        ? null
        : (stopwatch..stop()).elapsedMilliseconds;
    if (frame == null) {
      _emit(
        ScienceStageResult(
          stage: stage,
          outcome: outcome,
          timestamp: DateTime.now(),
          durationMs: durationMs,
          note: note,
        ),
      );
      return;
    }
    final priorRunning = frame.stages[stage];
    final result = ScienceStageResult(
      stage: stage,
      outcome: outcome,
      timestamp: priorRunning?.timestamp ?? DateTime.now(),
      durationMs: durationMs,
      note: note,
      imagePath: frame.imagePath,
      capturedImageId: frame.capturedImageId,
      sessionId: frame.sessionId,
    );
    final next = Map<ScienceStage, ScienceStageResult>.from(frame.stages)
      ..[stage] = result;
    _inflight = frame.copyWith(stages: next);
    _emit(result);
  }

  /// Convenience: record a stage that was skipped synchronously (e.g.
  /// because the feature is disabled). No stopwatch needed.
  void skipStage(ScienceStage stage, {String? note}) {
    final frame = _inflight;
    final timestamp = DateTime.now();
    final result = ScienceStageResult(
      stage: stage,
      outcome: ScienceStageOutcome.skipped,
      timestamp: timestamp,
      note: note,
      imagePath: frame?.imagePath,
      capturedImageId: frame?.capturedImageId,
      sessionId: frame?.sessionId,
    );
    if (frame != null) {
      final next = Map<ScienceStage, ScienceStageResult>.from(frame.stages)
        ..[stage] = result;
      _inflight = frame.copyWith(stages: next);
    }
    _emit(result);
  }

  /// Called when the in-flight frame has finished all its stages (or was
  /// abandoned due to a top-level exception).
  void endFrame() {
    final frame = _inflight;
    if (frame == null) {
      return;
    }
    final finished = frame.copyWith(finishedAt: DateTime.now());
    _history.insert(0, finished);
    if (_history.length > _historyCap) {
      _history.removeRange(_historyCap, _history.length);
    }
    _inflight = null;

    // Emit a synthetic completion event so listeners that only care about
    // "did a frame just finish?" don't have to track every stage.
    _emit(
      ScienceStageResult(
        stage: finished.stages.keys.isEmpty
            ? ScienceStage.frameQuality
            : finished.stages.keys.last,
        outcome: finished.hasFailure
            ? ScienceStageOutcome.failed
            : ScienceStageOutcome.ok,
        timestamp: finished.finishedAt!,
        imagePath: finished.imagePath,
        capturedImageId: finished.capturedImageId,
        sessionId: finished.sessionId,
        note: finished.hasFailure ? 'Frame completed with failures' : null,
      ),
      frameCompleted: true,
    );
  }

  /// Used in tests. Drops all state and emits no event.
  void reset() {
    _history.clear();
    _inflight = null;
    _queueDepth = 0;
  }

  Future<void> dispose() => _controller.close();

  void _emit(ScienceStageResult result, {bool frameCompleted = false}) {
    if (_controller.isClosed) return;
    _controller.add(
      ScienceProcessingEvent(
        stageResult: result,
        queueDepth: _queueDepth + (_inflight == null ? 0 : 1),
        frameCompleted: frameCompleted,
      ),
    );
  }
}
