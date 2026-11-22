import '../../models/equipment_profile_model.dart';
import '../../settings/app_settings_state.g.dart';
import '../smart_night_models.dart';

/// How a site decides that the rig has a cover calibrator from the profile.
enum CoverCalibratorRule {
  /// Any calibrator id counts, a blank one included (the Smart Night wizard).
  anyId,

  /// Only an id with text in it counts (Plan tonight and the planners).
  namedId,
}

/// The Smart Night inputs that come from the app settings and the active
/// equipment profile, for every place that plans a night.
abstract final class SmartNightInputs {
  /// The cool-down target of a profile that sets none.
  static const double defaultCoolDownTargetC = -10.0;

  /// [base] with the exposure limits of the Smart Night settings: target
  /// SNR, sub-exposure ceiling and floor.
  static SmartNightSettings withExposureLimits(
    AppSettingsState app, [
    SmartNightSettings base = const SmartNightSettings(),
  ]) => base.copyWith(
    targetSnr: app.smartNightTargetSnr,
    subExposureCeilingSecs: app.smartNightSubExposureCeilingSecs,
    subExposureFloorSecs: app.smartNightSubExposureFloorSecs,
  );

  /// [base] with every default the Smart Night settings store for the
  /// wizard: session length, autofocus cadence, per-target budget, flats,
  /// scheduler hand-off, polar-alignment age and the exposure limits.
  static SmartNightSettings withWizardDefaults(
    AppSettingsState app,
    SmartNightSettings base,
  ) => withExposureLimits(
    app,
    base.copyWith(
      maxSessionHours: app.smartNightMaxSessionHours ?? base.maxSessionHours,
      afEveryFrames: app.smartNightDefaultAfCadenceFrames,
      defaultIntegrationBudgetHours:
          app.smartNightDefaultIntegrationBudgetMinsPerTarget / 60.0,
      includeFlatsAtEnd: app.smartNightIncludeFlatsAtEnd,
      useSchedulerForMultiTarget: app.smartNightUseSchedulerForMultiTarget,
      schedulerTargetThreshold: app.smartNightSchedulerTargetThreshold,
      polarAlignmentStaleAfterDays: app.smartNightPolarAlignmentStaleAfterDays,
    ),
  );

  /// The camera set-point a night cools to on [profile].
  static double coolDownTargetC(EquipmentProfileModel profile) =>
      profile.defaultCoolingTemp ?? defaultCoolDownTargetC;

  /// Whether [profile] names a cover calibrator, by [rule].
  static bool hasCoverCalibrator(
    EquipmentProfileModel profile, {
    required CoverCalibratorRule rule,
  }) {
    final id = profile.coverCalibratorId;
    if (id == null) return false;
    return switch (rule) {
      CoverCalibratorRule.anyId => true,
      CoverCalibratorRule.namedId => id.trim().isNotEmpty,
    };
  }
}
