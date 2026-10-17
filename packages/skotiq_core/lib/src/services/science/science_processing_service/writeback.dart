part of '../science_processing_service.dart';

extension _ScienceProcessingWriteback on ScienceProcessingService {
  /// Stamp the science measurements gathered for this frame back into the
  /// captured FITS file's header so external pipelines can use them. This
  /// is a no-op when:
  ///   * the user has disabled writeback in settings,
  ///   * the file isn't a FITS (.fits/.fts/.fit) on disk,
  ///   * no science fields were produced (calibration + transparency both
  ///     came back empty).
  ///
  /// Errors here are logged but never rethrown — a failed writeback must
  /// not retroactively fail a capture that has already been recorded.
  Future<void> _runAutoGrade({required int capturedImageId}) async {
    final settings = await _ref.read(scienceSettingsProvider.future);
    if (!settings.autoFrameGradingEnabled) {
      _status.skipStage(
        ScienceStage.autoGrade,
        note: 'Auto frame grading disabled in settings',
      );
      return;
    }

    final sw = _status.beginStage(ScienceStage.autoGrade);
    try {
      final fresh = await _imagesRepo.getImageById(capturedImageId);
      if (fresh == null) {
        _status.skipStage(
          ScienceStage.autoGrade,
          note: 'Captured image row not found',
        );
        return;
      }
      final rejected = await _ref
          .read(frameAutoGraderProvider)
          .gradeCapturedFrame(image: fresh);
      if (rejected == null) {
        _status.skipStage(ScienceStage.autoGrade, note: 'Not a light frame');
      } else if (rejected) {
        _status.endStage(
          ScienceStage.autoGrade,
          ScienceStageOutcome.ok,
          stopwatch: sw,
          note: 'Frame rejected by quality thresholds',
        );
      } else {
        _status.endStage(
          ScienceStage.autoGrade,
          ScienceStageOutcome.ok,
          stopwatch: sw,
          note: 'Frame passed quality thresholds',
        );
      }
    } catch (error) {
      _status.endStage(
        ScienceStage.autoGrade,
        ScienceStageOutcome.failed,
        stopwatch: sw,
        note: error.toString(),
      );
    }
  }

  Future<void> _runFitsHeaderWriteback({
    required String imagePath,
    required db.CapturedImage? capturedImage,
    required ScienceSettings globalSettings,
    required FramePhotometricCalibration? calibration,
    required TransparencySample? transparency,
  }) async {
    if (!globalSettings.fitsHeaderWritebackEnabled) {
      _status.skipStage(
        ScienceStage.fitsWriteback,
        note: 'FITS header writeback disabled in settings',
      );
      return;
    }
    final lower = imagePath.toLowerCase();
    if (!(lower.endsWith('.fits') ||
        lower.endsWith('.fts') ||
        lower.endsWith('.fit'))) {
      _status.skipStage(
        ScienceStage.fitsWriteback,
        note: 'Not a FITS file — writeback skipped',
      );
      return;
    }
    final updates = ScienceProcessingService.buildScienceWritebackKeywords(
      calibration: calibration,
      transparency: transparency,
      buildTag: _ref.read(appVersionLabelProvider),
    );
    if (updates.isEmpty) {
      _status.skipStage(
        ScienceStage.fitsWriteback,
        note: 'No science fields produced for this frame',
      );
      return;
    }

    final sw = _status.beginStage(ScienceStage.fitsWriteback);
    try {
      final writer = FitsHeaderWriter();
      final result = await writer.updateKeywords(imagePath, updates);
      final summary = StringBuffer()
        ..write('${result.keywordsUpdated} updated, ')
        ..write('${result.keywordsInjected} injected');
      if (result.headerGrew) {
        summary.write(' (header grew to ${result.headerBlocks} blocks)');
      }
      _status.endStage(
        ScienceStage.fitsWriteback,
        ScienceStageOutcome.ok,
        stopwatch: sw,
        note: summary.toString(),
      );
    } catch (error, stack) {
      _logger.warning(
        'FITS writeback failed for $imagePath: $error\n$stack',
        source: 'ScienceProcessingService',
      );
      _status.endStage(
        ScienceStage.fitsWriteback,
        ScienceStageOutcome.failed,
        stopwatch: sw,
        note: error.toString(),
      );
    }
  }
}
