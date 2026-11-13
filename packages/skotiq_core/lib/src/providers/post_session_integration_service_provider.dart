import 'dart:math' as math;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' show PlateSolveResult;
import 'database_provider.dart';
import 'darkroom_pass/pass_providers.dart' show passReporterProvider;
import '../services/color_calibration_service.dart';
import '../services/plate_solve_service.dart';
import '../services/wcs/gnomonic_projection.dart';
import '../services/post_session_integration_service.dart';
import 'calibration_library_service_providers.dart';
import 'color_calibration_service_provider.dart';
import 'plate_solve_service_provider.dart';
import 'post_session_seam_provider.dart';

/// Provider for the [PostSessionIntegrationService].
///
/// The [MasterPlateSolver] closure is wired here (the provider boundary, where
/// the `PlateSolveService` Riverpod handle lives): it plate-solves the finished
/// master FITS via `solveWithFallback` and converts the `PlateSolveResult` to
/// the eight CD-matrix WCS scalars using the same sign convention as the native
/// source of truth (`WcsInfo::from_plate_solve`, `imaging/src/fits.rs:1094`):
/// `cd1_1 = -scale·cosθ`, `cd1_2 = cd2_1 = scale·sinθ`, `cd2_2 = scale·cosθ`,
/// with `scale` in deg/px and `θ` the field rotation. The reference pixel is the
/// image centre. Fail-soft: a non-success solve (no solver installed, solve
/// failure) yields null, so WCS persistence is skipped without aborting the
/// master persist.
final postSessionIntegrationServiceProvider = Provider<PostSessionIntegrationService>((
  ref,
) {
  return PostSessionIntegrationService(
    passReporter: ref.watch(passReporterProvider),
    mastersDao: ref.watch(integratedMastersDaoProvider),
    seam: ref.watch(postSessionSeamProvider),
    // Calibration Library Manager: routes un-pinned master selection through
    // the transparent scored matcher so its warnings reach the outcome /
    // morning report.
    calibrationLibrary: ref.watch(calibrationLibraryProvider),
    // Catalog colour calibration of the finished master, wired at the provider
    // boundary (where the `ColorCalibrationService` + its on-disk HYG catalog
    // live). The closure delegates to `ColorCalibrationService.calibrate`, which
    // detects + photometers stars, cross-matches catalogue B–V via the supplied
    // WCS, solves the per-channel white balance, and writes the rebalanced
    // master. Returns null on the fail-soft *skipped* result (too few matches /
    // no catalog) so the gate persists nothing rather than a phantom path.
    colorCalibrator:
        ({
          required String masterFits,
          required String outputFits,
          required SolvedWcs wcs,
          required int channels,
        }) async {
          final service = ref.read(colorCalibrationServiceProvider);
          final result = await service.calibrate(
            masterFits: masterFits,
            outputFits: outputFits,
            wcs: wcs,
            channels: channels,
          );
          if (ColorCalibrationService.wasSkipped(result)) return null;
          return result.outputPath;
        },
    plateSolver:
        ({
          required String imagePath,
          required int imageWidth,
          required int imageHeight,
          double? hintRaHours,
          double? hintDecDegrees,
        }) async {
          final solveService = ref.read(plateSolveServiceProvider);
          final PlateSolveResult solve;
          try {
            solve = await solveService.solveWithFallback(
              imagePath: imagePath,
              hintRaHours: hintRaHours,
              hintDecDegrees: hintDecDegrees,
            );
          } on SolverNotAvailableError {
            // No configured solver — stay un-annotated, never throw out of the
            // optional WCS step.
            return null;
          }
          if (!solve.success) return null;

          // Convert (ra°, dec°, pixelScale arcsec/px, rotation°) to the CD matrix.
          final scaleDeg = solve.pixelScale / 3600.0;
          final rotRad = solve.rotation * math.pi / 180.0;
          final cosRot = math.cos(rotRad);
          final sinRot = math.sin(rotRad);
          return MasterWcsSolution(
            crval1: solve.ra,
            crval2: solve.dec,
            crpix1: imageWidth / 2.0,
            crpix2: imageHeight / 2.0,
            cd1_1:
                -scaleDeg * cosRot, // Negative for RA increasing to the left.
            cd1_2: scaleDeg * sinRot,
            cd2_1: scaleDeg * sinRot,
            cd2_2: scaleDeg * cosRot,
          );
        },
  );
});
