import '../../models/equipment_profile_model.dart';
import '../../settings/app_settings_state.g.dart';
import '../smart_night_models.dart';

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

  /// The inputs of a night planned on [profile]: [base] with the stored
  /// wizard defaults ([withWizardDefaults]) and the profile's cool-down
  /// set-point. Plan tonight, the planner's estimate and the wizard's seed
  /// all start here.
  static SmartNightSettings forNight(
    AppSettingsState app,
    EquipmentProfileModel? profile, [
    SmartNightSettings base = const SmartNightSettings(),
  ]) => withWizardDefaults(app, base).copyWith(
    coolDownTargetC: profile == null
        ? defaultCoolDownTargetC
        : coolDownTargetC(profile),
  );

  /// The camera set-point a night cools to on [profile].
  static double coolDownTargetC(EquipmentProfileModel profile) =>
      profile.defaultCoolingTemp ?? defaultCoolDownTargetC;

  /// Whether [profile] names a cover calibrator: an id with text in it. A
  /// blank id is no calibrator.
  static bool hasCoverCalibrator(EquipmentProfileModel profile) =>
      profile.coverCalibratorId?.trim().isNotEmpty ?? false;
}
