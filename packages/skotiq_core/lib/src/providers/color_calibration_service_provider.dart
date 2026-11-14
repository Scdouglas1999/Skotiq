import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import '../services/color_calibration_service.dart';
import 'post_session_seam_provider.dart';

/// Provider for the [ColorCalibrationService]. The star cone search binds the
/// real on-disk HYG catalog; tests override [postSessionSeamProvider] and may
/// construct the service directly with an in-memory [StarConeSearch] stub.
final colorCalibrationServiceProvider = Provider<ColorCalibrationService>((
  ref,
) {
  return ColorCalibrationService(
    seam: ref.watch(postSessionSeamProvider),
    starSearch: (center, radiusDegrees, {maxMagnitude}) => CatalogManager
        .instance
        .stars
        .getStarsNear(center, radiusDegrees, maxMagnitude: maxMagnitude),
  );
});
