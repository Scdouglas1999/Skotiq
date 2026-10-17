import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../database/database.dart' as db;
import '../../providers/database_provider.dart';
import '../../services/imaging_records_repository.dart';
import '../../providers/science_provider.dart';
import '../../services/logging_service.dart';
import 'frame_grade_rules.dart';

/// Applies [FrameGradeRules] to a single frame immediately after capture.
///
/// This is the SGP-class "auto-reject bad subs" feature: thresholds are
/// evaluated on every light frame once its quality metrics are in the DB.
/// Rejection only flips `isAccepted` — files are never deleted.
class FrameAutoGrader {
  final Ref _ref;

  FrameAutoGrader(this._ref);

  /// Returns `true` when the frame was rejected, `false` when accepted or
  /// skipped, `null` when grading did not run (disabled / not a light).
  Future<bool?> gradeCapturedFrame({required db.CapturedImage image}) async {
    if (image.frameType.toLowerCase() != 'light') return null;
    if (!image.isAccepted) return false;

    final settings = await _ref.read(scienceSettingsProvider.future);
    if (!settings.autoFrameGradingEnabled) return null;

    final rules = settings.resolvedFrameGradeRules();
    if (rules.isEmpty) return null;

    // gradeFrame requires the caller to supply FWHM / eccentricity or those
    // rules silently never fire. FWHM is now persisted on captured_images by
    // the stats path — prefer it; fall back to the per-tile PSF medians
    // (written earlier in this same pipeline run) only when it's absent.
    // Eccentricity stays PSF-tile-derived. When neither source has the
    // metric it stays null and that rule is skipped, matching the "cannot
    // grade this dimension" contract.
    double? fwhm;
    double? eccentricity;
    if (rules.maxFwhm != null || rules.maxEccentricity != null) {
      if (rules.maxFwhm != null) {
        fwhm = await _ref.read(imagesDaoProvider).getFwhm(image.id);
      }
      if (fwhm == null || rules.maxEccentricity != null) {
        final psfMetrics = await _psfFieldMetrics(image.id);
        fwhm ??= psfMetrics.fwhm;
        eccentricity = psfMetrics.eccentricity;
      }
    }

    final reason = rules.gradeFrame(
      image,
      fwhm: fwhm,
      eccentricity: eccentricity,
    );
    if (reason == null) return false;

    await _ref
        .read(imagingRecordsRepositoryProvider)
        .rejectImage(image.id, reason);
    _ref
        .read(loggingServiceProvider)
        .info(
          'Auto-rejected frame ${image.id} (${image.fileName}): $reason',
          source: 'FrameAutoGrader',
        );
    return true;
  }

  /// Field-wide median FWHM / eccentricity from the frame's PSF tiles.
  /// Tiles with no stars carry zeroed metrics and are excluded so an empty
  /// corner can't drag the frame value down.
  Future<({double? fwhm, double? eccentricity})> _psfFieldMetrics(
    int capturedImageId,
  ) async {
    final tiles = await _ref
        .read(scienceDaoProvider)
        .getPsfTilesForImage(capturedImageId);
    final fwhms = <double>[];
    final eccs = <double>[];
    for (final tile in tiles) {
      if (tile.starCount <= 0) continue;
      if (tile.medianFwhm.isFinite && tile.medianFwhm > 0) {
        fwhms.add(tile.medianFwhm);
      }
      if (tile.medianEccentricity.isFinite && tile.medianEccentricity > 0) {
        eccs.add(tile.medianEccentricity);
      }
    }
    return (fwhm: _median(fwhms), eccentricity: _median(eccs));
  }

  double? _median(List<double> values) {
    if (values.isEmpty) return null;
    final sorted = values.toList(growable: false)..sort();
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2.0;
  }
}

final frameAutoGraderProvider = Provider<FrameAutoGrader>((ref) {
  return FrameAutoGrader(ref);
});
