part of '../mosaic_project_service.dart';

extension _MosaicStitching on MosaicProjectService {
  // Helpers.

  Future<bool> _safeFitsHasWcs(
    Future<bool> Function(String fitsPath) probe,
    String fitsPath,
  ) async {
    try {
      return await probe(fitsPath);
    } catch (e, st) {
      _logSoftFailure('fitsHasWcs($fitsPath)', e, st);
      return false;
    }
  }

  /// Best-effort probe that a panel master FITS still exists on disk. A probe
  /// error degrades to `false` (treat as missing -> skip the panel) rather than
  /// aborting the whole stitch — a missing file must never poison the mosaic.
  Future<bool> _safeFitsExists(String fitsPath) async {
    try {
      return await File(fitsPath).exists();
    } catch (e, st) {
      _logSoftFailure('fitsExists($fitsPath)', e, st);
      return false;
    }
  }

  /// Accepted light subs for a capture target (the population the per-panel
  /// integration folds). Non-accepted subs are excluded so a panel's master is
  /// built only from frames that passed grading.
  Future<List<CapturedImage>> _acceptedSubsForTarget(int targetId) async {
    final all = await _imagesDao.getImagesForTarget(targetId);
    return all.where((s) => s.isAccepted).toList(growable: false);
  }

  /// The eight CD-matrix scalars as the `StitchMosaicArgs` `wcs` block, or null
  /// when the master has no persisted WCS (the native side then parses the FITS
  /// header instead). Mirrors the documented request shape.
  Map<String, dynamic>? _wcsArgs(IntegratedMaster master) {
    if (!master.hasWcs) return null;
    return <String, dynamic>{
      'crval1': master.wcsCrval1,
      'crval2': master.wcsCrval2,
      'crpix1': master.wcsCrpix1,
      'crpix2': master.wcsCrpix2,
      'cd1_1': master.wcsCd1_1,
      'cd1_2': master.wcsCd1_2,
      'cd2_1': master.wcsCd2_1,
      'cd2_2': master.wcsCd2_2,
    };
  }

  String _stitchStatsJson(MosaicStitchResult stitch, int panelCount) {
    return '{'
        '"panelCount":$panelCount,'
        '"overlapPairs":${stitch.overlapPairs},'
        '"meanPanelGain":${stitch.meanPanelGain},'
        '"outWidth":${stitch.outWidth},'
        '"outHeight":${stitch.outHeight}'
        '}';
  }

  void _logSoftFailure(String step, Object error, StackTrace stackTrace) {
    developer.log(
      'mosaic project step "$step" failed (continuing)',
      name: 'MosaicProjectService',
      error: error,
      stackTrace: stackTrace,
      level: 900, // WARNING
    );
  }
}
