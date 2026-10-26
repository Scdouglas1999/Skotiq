import 'dart:async';
import 'dart:math' as math;

import '../../../services/logging_service.dart';
import '../../../services/science/science_processing_service.dart';
import '../sequencer_run_event.dart';

/// Sends each light frame a run records through the per-frame science
/// pipeline, the same processing a manual capture gets.
///
/// A frame is queued once its `captured_images` row exists and the frame
/// watch has assessed it, so the pipeline reuses the frame watch's plate
/// solve from the row instead of running a second solve of the same file.
/// When no assessment arrives within [assessmentWait] the frame is queued
/// anyway and the pipeline solves it itself. A frame whose solve the frame
/// watch attempted and failed is processed without a solve.
///
/// Science is informational: nothing here blocks, delays or fails the run or
/// the frame's registration, and the pipeline runs one frame at a time.
class RunFrameScience {
  RunFrameScience({
    required LoggingService Function() logger,
    Duration Function(double? exposureSecs)? assessmentWait,
  }) : _loggerFn = logger,
       _assessmentWait = assessmentWait ?? defaultAssessmentWait;

  final LoggingService Function() _loggerFn;
  final Duration Function(double? exposureSecs) _assessmentWait;

  /// Assessments still expected, by the path the frame was saved at.
  final Map<String, Completer<FrameAssessed?>> _awaiting =
      <String, Completer<FrameAssessed?>>{};

  /// The frame watch solves a frame while the next one exposes, so its
  /// assessment can trail the frame by up to about two exposures.
  static Duration defaultAssessmentWait(double? exposureSecs) {
    final exposure = (exposureSecs != null && exposureSecs.isFinite)
        ? exposureSecs
        : 0.0;
    return Duration(seconds: math.max(120, (exposure * 3).ceil()));
  }

  /// Whether a frame of [frameType] gets science processing.
  static bool appliesTo(String? frameType, String filePath) =>
      filePath.isNotEmpty && (frameType ?? 'light').toLowerCase() == 'light';

  /// Start waiting for the frame watch's assessment of the frame at [path].
  /// Call when the frame is registered, before its row insert, so an
  /// assessment that arrives while the insert is in flight is not missed.
  Future<FrameAssessed?> expectAssessment(String path, double? exposureSecs) {
    final completer = Completer<FrameAssessed?>();
    _awaiting[path]?.complete(null);
    _awaiting[path] = completer;
    final wait = _assessmentWait(exposureSecs);
    return completer.future.timeout(
      wait,
      onTimeout: () {
        if (identical(_awaiting[path], completer)) _awaiting.remove(path);
        return null;
      },
    );
  }

  /// The frame watch finished with the frame at [path] (its solve, if any,
  /// is already on the row).
  void assessed(String path, FrameAssessed event) {
    final completer = _awaiting.remove(path);
    if (completer != null && !completer.isCompleted) {
      completer.complete(event);
    }
  }

  /// Queue the frame for science once [assessment] settles. Returns the
  /// future of the whole wait-and-process, which never throws.
  Future<void> queue({
    required ScienceProcessingService science,
    required Future<FrameAssessed?> assessment,
    required String filePath,
    required int capturedImageId,
    required int? sessionId,
  }) async {
    final logger = _loggerFn();
    try {
      final assessed = await assessment;
      final watchSolveFailed =
          assessed != null && assessed.solveAttempted && !assessed.plateSolved;
      final outcome = await science.processFrame(
        imagePath: filePath,
        capturedImageId: capturedImageId,
        sessionId: sessionId,
        solveIfUnsolved: !watchSolveFailed,
      );
      if (outcome.kind == ScienceFrameOutcomeKind.failed) {
        logger.warning(
          'Science processing of sequence frame $filePath failed: '
          '${outcome.error}',
          source: 'SequenceExecutor',
        );
      }
    } catch (e) {
      logger.warning(
        'Could not queue sequence frame $filePath for science processing: $e',
        source: 'SequenceExecutor',
      );
    }
  }
}
