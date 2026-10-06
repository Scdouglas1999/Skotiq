// ignore_for_file: invalid_use_of_protected_member
// Mobile layout and filter-settings builders of _AutofocusSettingsState.
part of '../autofocus_settings.dart';

extension _AutofocusMobileLayout on _AutofocusSettingsState {
  List<Widget> _buildMobileLayout(
    AppSettingsState settings,
    AppSettingsNotifier notifier,
  ) {
    return [
      SettingRow(
        icon: LucideIcons.filter,
        title: 'Use filter offsets',
        subtitle: 'Apply focus offsets when changing filters',
        trailing: SettingsSwitch(
          value: settings.useFilterFocusOffsets,
          onChanged: (value) => notifier.setUseFilterFocusOffsets(value),
        ),
        isMobile: true,
      ),
      SettingRow(
        icon: LucideIcons.arrowUpDown,
        title: 'Initial offset steps',
        subtitle: 'Steps out from center for V-curve',
        trailing: _afNumberInput(
          controller: _initialOffsetStepsController,
          suffix: '',
          min: 1,
          max: 20,
          decimals: 0,
          onChanged: (value) => notifier.setAfInitialOffsetSteps(value.toInt()),
          isMobile: true,
        ),
        isMobile: true,
      ),
      SettingRow(
        icon: LucideIcons.activity,
        title: 'Autofocus method',
        trailing: SettingsDropdown(
          value: settings.afMethod,
          items: const ['Star HFR'],
          onChanged: (value) {
            return notifier.setAfMethod(value);
          },
          isMobile: true,
        ),
        isMobile: true,
      ),
      SettingRow(
        icon: LucideIcons.trendingUp,
        title: 'Curve fitting strategy',
        trailing: SettingsDropdown(
          value: settings.afCurveFitting,
          items: AutofocusSettings.curveFittingOptions,
          onChanged: (value) {
            return notifier.setAfCurveFitting(value);
          },
          isMobile: true,
        ),
        isMobile: true,
      ),
      SettingRow(
        icon: LucideIcons.moveVertical,
        title: 'Step size',
        subtitle: 'Focuser steps between measurement points',
        trailing: _afNumberInput(
          controller: _stepSizeController,
          suffix: '',
          min: 1,
          max: 10000,
          decimals: 0,
          onChanged: (value) => notifier.setAfStepSize(value.toInt()),
          isMobile: true,
        ),
        isMobile: true,
      ),
      SettingRow(
        icon: LucideIcons.timer,
        title: 'Exposure time',
        subtitle: 'Default AF frame exposure',
        trailing: _afNumberInput(
          controller: _exposureTimeController,
          suffix: 's',
          min: 0.1,
          max: 300,
          decimals: 1,
          onChanged: (value) => notifier.setAfExposureTime(value),
          isMobile: true,
        ),
        isMobile: true,
      ),
      SettingRow(
        icon: LucideIcons.pause,
        title: 'Disable guiding during AF',
        subtitle: 'Stop autoguider while focusing',
        trailing: SettingsSwitch(
          value: settings.afDisableGuidingDuringAf,
          onChanged: (value) => notifier.setAfDisableGuidingDuringAf(value),
        ),
        isMobile: true,
      ),
      SettingRow(
        icon: LucideIcons.repeat,
        title: 'Number of attempts',
        subtitle: 'Retry count on failure',
        trailing: _afNumberInput(
          controller: _numberOfAttemptsController,
          suffix: '',
          min: 1,
          max: 10,
          decimals: 0,
          onChanged: (value) => notifier.setAfNumberOfAttempts(value.toInt()),
          isMobile: true,
        ),
        isMobile: true,
      ),
      SettingRow(
        icon: LucideIcons.sparkles,
        title: 'Use brightest n stars',
        subtitle:
            'Default 10. 0 uses every detected star; faint ones skew the HFR',
        trailing: _afNumberInput(
          controller: _brightestNStarsController,
          suffix: '',
          min: 0,
          max: 500,
          decimals: 0,
          onChanged: (value) => notifier.setAfUseBrightestNStars(value.toInt()),
          isMobile: true,
        ),
        isMobile: true,
      ),
      SettingRow(
        icon: LucideIcons.maximize2,
        title: 'Outer crop ratio',
        subtitle: 'Must be greater than the inner crop ratio',
        trailing: _afNumberInput(
          controller: _outerCropRatioController,
          suffix: '',
          min: 0.01,
          max: 1.0,
          decimals: 2,
          onChanged: (value) => notifier.setAfOuterCropRatio(value),
          isMobile: true,
        ),
        isMobile: true,
      ),
      SettingRow(
        icon: LucideIcons.minimize2,
        title: 'Inner crop ratio',
        subtitle: 'Central exclusion; must be smaller than outer',
        trailing: _afNumberInput(
          controller: _innerCropRatioController,
          suffix: '',
          min: 0.0,
          max: 1.0,
          decimals: 2,
          onChanged: (value) => notifier.setAfInnerCropRatio(value),
          isMobile: true,
        ),
        isMobile: true,
      ),
      SettingRow(
        icon: LucideIcons.grid,
        title: 'Binning',
        trailing: _afNumberInput(
          controller: _binningController,
          suffix: '',
          min: 1,
          max: 4,
          decimals: 0,
          onChanged: (value) => notifier.setAfBinning(value.toInt()),
          isMobile: true,
        ),
        isMobile: true,
      ),
      SettingRow(
        icon: LucideIcons.checkCircle,
        title: 'R\u00B2 threshold',
        subtitle: 'Minimum acceptable curve fit quality',
        trailing: _afNumberInput(
          controller: _rSquaredThresholdController,
          suffix: '',
          min: 0.0,
          max: 1.0,
          decimals: 2,
          onChanged: (value) => notifier.setAfRSquaredThreshold(value),
          isMobile: true,
        ),
        isMobile: true,
      ),
      SettingRow(
        icon: LucideIcons.alertTriangle,
        title: 'HFR tolerance on failure',
        subtitle: kAfFailureToleranceSubtitle,
        trailing: _afNumberInput(
          controller: _failureToleranceController,
          suffix: '\u00D7',
          min: 0.0,
          max: 10.0,
          decimals: 2,
          onChanged: (value) => notifier.setAfFailureHfrToleranceRatio(value),
          isMobile: true,
        ),
        isMobile: true,
      ),
      SettingRow(
        icon: LucideIcons.clock,
        title: 'Focuser settle time',
        subtitle: 'Wait after focuser move',
        trailing: _afNumberInput(
          controller: _focuserSettleTimeController,
          suffix: 'ms',
          min: 0,
          max: 10000,
          decimals: 0,
          onChanged: (value) =>
              notifier.setAfFocuserSettleTimeMs(value.toInt()),
          isMobile: true,
        ),
        isMobile: true,
      ),
      SettingRow(
        icon: LucideIcons.layers,
        title: 'Exposures per point',
        subtitle: 'Frames to average per focus position',
        trailing: _afNumberInput(
          controller: _exposuresPerPointController,
          suffix: '',
          min: 1,
          max: 20,
          decimals: 0,
          onChanged: (value) => notifier.setAfExposuresPerPoint(value.toInt()),
          isMobile: true,
        ),
        isMobile: true,
      ),
      SettingRow(
        icon: LucideIcons.arrowLeftRight,
        title: 'Backlash compensation',
        trailing: SettingsDropdown(
          value: settings.afBacklashCompMethod,
          items: const ['None', 'Overshoot', 'Absolute'],
          onChanged: (value) {
            return notifier.setAfBacklashCompMethod(value);
          },
          isMobile: true,
        ),
        isMobile: true,
      ),
      SettingRow(
        icon: LucideIcons.arrowLeft,
        title: 'Backlash IN',
        trailing: _afNumberInput(
          controller: _backlashInController,
          suffix: '',
          min: 0,
          max: 10000,
          decimals: 0,
          onChanged: (value) => notifier.setAfBacklashIn(value.toInt()),
          isMobile: true,
        ),
        isMobile: true,
      ),
      SettingRow(
        icon: LucideIcons.arrowRight,
        title: 'Backlash OUT',
        trailing: _afNumberInput(
          controller: _backlashOutController,
          suffix: '',
          min: 0,
          max: 10000,
          decimals: 0,
          onChanged: (value) => notifier.setAfBacklashOut(value.toInt()),
          isMobile: true,
        ),
        isLast: true,
        isMobile: true,
      ),
    ];
  }
}
