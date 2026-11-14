import '../models/equipment_profile_model.dart';
import 'centering_service.dart';
import 'plate_solve_service.dart';
import '../settings/app_settings_state.g.dart';

/// What a centering the operator starts by hand runs with: Slew & center from
/// a catalog card, the planetarium or Tonight, and a phone's or the web
/// dashboard's center request to the host. The solve frames use the active
/// profile's centering exposure, binning, gain and offset; the solves use the
/// Plate Solving settings. A sequence's Center step has its own settings.
class ManualCentering {
  ManualCentering.of(
    AppSettingsState settings,
    EquipmentProfileModel? profile, {
    double? exposureSeconds,
  }) : config = CenteringConfig(
         maxIterations: maxIterations,
         toleranceArcsec: toleranceArcsec,
         exposureTime: exposureSeconds ?? exposureFor(profile),
         binning: profile?.defaultBinX ?? 2,
         gain: profile?.defaultGain,
         offset: profile?.defaultOffset,
         syncMount: settings.centeringSyncMount,
       ),
       solver = PlateSolverConfig(
         timeoutSeconds: settings.plateSolveTimeout,
         searchRadius: settings.plateSolveSearchRadius,
       );

  /// Solve-and-correct passes before a run gives up.
  static const int maxIterations = 5;

  /// How close to the target, in arcseconds, counts as centered.
  static const double toleranceArcsec = 30.0;

  /// The solve exposure, in seconds, of a profile without one.
  static const double defaultExposureSeconds = 5.0;

  final CenteringConfig config;
  final PlateSolverConfig solver;

  /// The solve exposure, in seconds, of [profile]'s centering frames.
  static double exposureFor(EquipmentProfileModel? profile) {
    final exposure = profile?.defaultCenteringExposure;
    return exposure != null && exposure > 0 ? exposure : defaultExposureSeconds;
  }
}
