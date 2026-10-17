import 'package:drift/drift.dart' show Value;

import '../../database/daos/guide_rms_history_dao.dart';
import '../../database/daos/images_dao.dart';
import '../../database/database.dart';

/// Summarizes session guiding telemetry into Smart Night's per-mount history.
///
/// The exposure planner already knows how to use recent guide RMS to cap
/// sub-exposure recommendations. This collector is the write side: at the end
/// of a sequence run, read valid per-frame RMS values and append one compact
/// session-level sample for the current mount.
class GuideRmsCollector {
  final ImagesDao _imagesDao;
  final GuideRmsHistoryDao _guideRmsHistoryDao;

  const GuideRmsCollector({
    required ImagesDao imagesDao,
    required GuideRmsHistoryDao guideRmsHistoryDao,
  }) : _imagesDao = imagesDao,
       _guideRmsHistoryDao = guideRmsHistoryDao;

  /// Collect a single history sample for [sessionId].
  ///
  /// Returns the inserted row id, or `null` when there is no mount id or no
  /// usable guiding telemetry. Invalid RMS values are ignored instead of
  /// poisoning the mount model.
  Future<int?> collectSession({
    required int sessionId,
    required String? mountId,
    DateTime? recordedAt,
  }) async {
    final trimmedMountId = mountId?.trim();
    if (trimmedMountId == null || trimmedMountId.isEmpty) {
      return null;
    }

    final images = await _imagesDao.getImagesForSession(sessionId);
    final samples = images.where((image) {
      final rms = image.guidingRmsTotal;
      return rms != null && rms.isFinite && rms > 0;
    }).toList();
    if (samples.isEmpty) {
      return null;
    }

    final rmsTotal = samples.fold<double>(
      0,
      (sum, image) => sum + image.guidingRmsTotal!,
    );
    final exposureTotal = samples.fold<double>(
      0,
      (sum, image) => sum + image.exposureDuration,
    );
    final targetIds = samples
        .map((image) => image.targetId)
        .whereType<int>()
        .toSet();

    return _guideRmsHistoryDao.insertSample(
      GuideRmsHistoryCompanion.insert(
        sessionId: sessionId.toString(),
        mountId: trimmedMountId,
        targetId: targetIds.length == 1
            ? Value(targetIds.single)
            : const Value.absent(),
        totalRmsArcsec: rmsTotal / samples.length,
        sampleCount: samples.length,
        exposureSeconds: Value(exposureTotal / samples.length),
        recordedAt: recordedAt ?? DateTime.now(),
      ),
    );
  }
}
