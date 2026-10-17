part of '../post_session_integration_service.dart';

/// Resolved calibration master paths for one filter group (the inputs to the
/// native `calibration` JSON block).
class ResolvedCalibration {
  final String? darkPath;
  final String? flatPath;
  final String? biasPath;
  final bool cosmeticCorrection;

  /// Operator-facing warnings produced by the Calibration Library matcher
  /// while selecting these masters (temperature mismatch, exposure scaling,
  /// stale flats, …). Empty for pinned selections. Not part of the native
  /// bridge JSON — surfaced on [PostSessionIntegrationOutcome].
  final List<String> warnings;

  const ResolvedCalibration({
    this.darkPath,
    this.flatPath,
    this.biasPath,
    this.cosmeticCorrection = true,
    this.warnings = const [],
  });

  Map<String, dynamic> toBridgeJson() => {
    if (darkPath != null) 'dark': darkPath,
    if (flatPath != null) 'flat': flatPath,
    if (biasPath != null) 'bias': biasPath,
    'cosmeticCorrection': cosmeticCorrection,
  };
}

/// The eight plate-solved WCS scalars in the CD-matrix form ASTAP /
/// `WcsInfo::from_plate_solve` (`imaging/src/fits.rs:1094`) emit. Returned by a
/// [MasterPlateSolver] and persisted verbatim via
/// [IntegratedMastersDao.updateWcs] so the catalog annotation overlay and colour
/// calibration can both reconstruct a `WcsOverlay`.
class MasterWcsSolution {
  final double crval1;
  final double crval2;
  final double crpix1;
  final double crpix2;
  final double cd1_1;
  final double cd1_2;
  final double cd2_1;
  final double cd2_2;

  const MasterWcsSolution({
    required this.crval1,
    required this.crval2,
    required this.crpix1,
    required this.crpix2,
    required this.cd1_1,
    required this.cd1_2,
    required this.cd2_1,
    required this.cd2_2,
  });
}

/// A fail-soft plate-solve of a finished master FITS. Implementations wrap
/// `PlateSolveService.solveWithFallback` (at the provider boundary, where the
/// Riverpod `_ref` lives) and convert the `PlateSolveResult` to the CD-matrix
/// [MasterWcsSolution]. Returns null when no solver is installed or the solve
/// fails — the master persist is never aborted by a missing solver.
///
/// [hintRaHours] / [hintDecDegrees] are the target's catalog coordinates when
/// known, to make the solve fast/robust (`apiPlateSolveNear`); a blind solve is
/// the fallback otherwise.
typedef MasterPlateSolver =
    Future<MasterWcsSolution?> Function({
      required String imagePath,
      required int imageWidth,
      required int imageHeight,
      double? hintRaHours,
      double? hintDecDegrees,
    });

/// A fail-soft catalog colour calibration of a finished master FITS.
/// Implementations wrap [ColorCalibrationService.calibrate] (at the provider
/// boundary, where the Riverpod `_ref` + on-disk star catalog live): they detect
/// + photometer stars on [masterFits], project them with [wcs], cross-match to
/// catalogue B–V, solve the per-channel white balance, and write the rebalanced
/// master to [outputFits].
///
/// Returns the written calibrated path on success, or null when no calibrator is
/// installed, the field cross-matched too few stars (a *skipped* result), or the
/// solve failed — the master persist is never aborted by colour calibration.
typedef MasterColorCalibrator =
    Future<String?> Function({
      required String masterFits,
      required String outputFits,
      required WcsOverlay wcs,
      required int channels,
    });

/// The outcome of one post-session integration run for a single filter group.
class PostSessionIntegrationOutcome {
  /// The persisted `integrated_masters` row id.
  final int masterId;

  /// The filter this group integrated (null/`'(none)'` for unfiltered).
  final String? filter;

  /// The decoded native integration result.
  final IntegrateSessionResult result;

  /// Warnings from the calibration auto-match for this group (see
  /// [ResolvedCalibration.warnings]). Empty when masters were pinned.
  final List<String> calibrationWarnings;

  const PostSessionIntegrationOutcome({
    required this.masterId,
    required this.filter,
    required this.result,
    this.calibrationWarnings = const [],
  });
}
