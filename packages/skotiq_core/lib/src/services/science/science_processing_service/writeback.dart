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
  Future<void> _runFitsHeaderWriteback({
    required String imagePath,
    required db.DbCapturedImage? capturedImage,
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
    if (!FrameFiles.isArchive(imagePath)) {
      _status.skipStage(
        ScienceStage.fitsWriteback,
        note: 'Not a FITS or XISF frame. Writeback skipped',
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
      await _ref.read(backendProvider).updateFrameCards(imagePath, updates);
      _status.endStage(
        ScienceStage.fitsWriteback,
        ScienceStageOutcome.ok,
        stopwatch: sw,
        note: '${updates.length} keywords written',
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
