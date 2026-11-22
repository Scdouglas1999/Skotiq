import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/settings.dart';

/// Each place that planned a night built its Smart Night inputs by its own
/// rule. The reference functions below are those rules as the sites wrote
/// them; the shared builder must answer the same for every input.

SmartNightSettings _helperBefore(
  AppSettingsState settings,
  EquipmentProfileModel profile,
) => SmartNightSettings(
  targetSnr: settings.smartNightTargetSnr,
  subExposureCeilingSecs: settings.smartNightSubExposureCeilingSecs,
  subExposureFloorSecs: settings.smartNightSubExposureFloorSecs,
  coolDownTargetC: profile.defaultCoolingTemp ?? -10.0,
  hasCoverCalibrator:
      profile.coverCalibratorId != null &&
      profile.coverCalibratorId!.trim().isNotEmpty,
);

SmartNightSettings _dialogSeedBefore(
  AppSettingsState app,
  SmartNightSettings settings,
) {
  final maxHours = app.smartNightMaxSessionHours;
  final defaultIntegrationHours =
      app.smartNightDefaultIntegrationBudgetMinsPerTarget / 60.0;
  return settings.copyWith(
    maxSessionHours: maxHours ?? settings.maxSessionHours,
    afEveryFrames: app.smartNightDefaultAfCadenceFrames,
    defaultIntegrationBudgetHours: defaultIntegrationHours,
    includeFlatsAtEnd: app.smartNightIncludeFlatsAtEnd,
    useSchedulerForMultiTarget: app.smartNightUseSchedulerForMultiTarget,
    schedulerTargetThreshold: app.smartNightSchedulerTargetThreshold,
    polarAlignmentStaleAfterDays: app.smartNightPolarAlignmentStaleAfterDays,
    subExposureFloorSecs: app.smartNightSubExposureFloorSecs,
    subExposureCeilingSecs: app.smartNightSubExposureCeilingSecs,
    targetSnr: app.smartNightTargetSnr,
  );
}

SmartNightSettings _optimizerBefore(AppSettingsState settings) =>
    SmartNightSettings(
      targetSnr: settings.smartNightTargetSnr,
      subExposureCeilingSecs: settings.smartNightSubExposureCeilingSecs,
      subExposureFloorSecs: settings.smartNightSubExposureFloorSecs,
    );

void main() {
  const apps = <AppSettingsState>[
    AppSettingsState(),
    AppSettingsState(
      smartNightTargetSnr: 45,
      smartNightSubExposureCeilingSecs: 180,
      smartNightSubExposureFloorSecs: 20,
      smartNightMaxSessionHours: 7.5,
      smartNightDefaultAfCadenceFrames: 12,
      smartNightDefaultIntegrationBudgetMinsPerTarget: 150,
      smartNightIncludeFlatsAtEnd: true,
      smartNightUseSchedulerForMultiTarget: false,
      smartNightSchedulerTargetThreshold: 4,
      smartNightPolarAlignmentStaleAfterDays: 3,
    ),
  ];
  const profiles = <EquipmentProfileModel>[
    EquipmentProfileModel(name: 'none'),
    EquipmentProfileModel(name: 'blank', coverCalibratorId: ''),
    EquipmentProfileModel(name: 'spaces', coverCalibratorId: '   '),
    EquipmentProfileModel(
      name: 'named',
      coverCalibratorId: 'flatpanel-1',
      defaultCoolingTemp: -5,
    ),
  ];
  const wizardStates = <SmartNightSettings>[
    SmartNightSettings(),
    SmartNightSettings(hasCoverCalibrator: true, maxSessionHours: 9),
  ];

  test('Plan tonight inputs are unchanged', () {
    for (final app in apps) {
      for (final profile in profiles) {
        final after = SmartNightInputs.withExposureLimits(
          app,
          SmartNightSettings(
            coolDownTargetC: SmartNightInputs.coolDownTargetC(profile),
            hasCoverCalibrator: SmartNightInputs.hasCoverCalibrator(profile),
          ),
        );
        expect(
          after.toJson(),
          _helperBefore(app, profile).toJson(),
          reason: profile.name,
        );
      }
    }
  });

  test('the wizard seed is unchanged', () {
    for (final app in apps) {
      for (final wizard in wizardStates) {
        expect(
          SmartNightInputs.withWizardDefaults(app, wizard).toJson(),
          _dialogSeedBefore(app, wizard).toJson(),
        );
      }
    }
  });

  test('the planner estimate inputs are unchanged', () {
    for (final app in apps) {
      expect(
        SmartNightInputs.withExposureLimits(app).toJson(),
        _optimizerBefore(app).toJson(),
      );
    }
  });

  test('a blank cover calibrator id is no calibrator, at every site', () {
    expect(
      [
        for (final p in profiles)
          if (SmartNightInputs.hasCoverCalibrator(p)) p.name,
      ],
      ['named'],
    );
  });
}
