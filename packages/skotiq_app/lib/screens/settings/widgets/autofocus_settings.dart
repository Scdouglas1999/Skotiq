import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'settings_widgets.dart';
part 'autofocus_settings/filter_settings_row.dart';
part 'autofocus_settings/filter_settings_mobile_card.dart';

part 'autofocus_settings/mobile_layout.dart';
part 'autofocus_settings/filter_settings_builders.dart';

/// What a failed autofocus does, stated where its one remaining setting
/// lives. There is no failure action to choose: a failed autofocus never
/// parks the mount or ends the run (owner decision 2026-10-06).
const String kAfFailureToleranceSubtitle =
    'A failed autofocus never parks or ends the run: the focuser goes back '
    'where it was, you get a notification, and imaging continues. Frames '
    'within this multiple of your good HFR are reported as usable. '
    '0 = don\u2019t judge the frames';

class AutofocusSettingsPage extends ConsumerStatefulWidget {
  final bool isMobile;

  /// When true, render without an own scroll view (embedded in a merged
  /// section's single outer scroll) and without the page header.
  final bool embedded;

  const AutofocusSettingsPage({
    super.key,
    this.isMobile = false,
    this.embedded = false,
  });

  @override
  ConsumerState<AutofocusSettingsPage> createState() =>
      _AutofocusSettingsState();
}

class _AutofocusSettingsState extends ConsumerState<AutofocusSettingsPage> {
  // General AF controllers
  final _initialOffsetStepsController = TextEditingController();
  final _stepSizeController = TextEditingController();
  final _exposureTimeController = TextEditingController();
  final _numberOfAttemptsController = TextEditingController();
  final _brightestNStarsController = TextEditingController();
  final _outerCropRatioController = TextEditingController();
  final _innerCropRatioController = TextEditingController();
  final _binningController = TextEditingController();
  final _rSquaredThresholdController = TextEditingController();
  final _failureToleranceController = TextEditingController();
  final _focuserSettleTimeController = TextEditingController();
  final _exposuresPerPointController = TextEditingController();
  final _backlashInController = TextEditingController();
  final _backlashOutController = TextEditingController();

  late AppSettingsState _renderedSettings;
  late Object _renderedAuthority;

  @override
  void dispose() {
    _initialOffsetStepsController.dispose();
    _stepSizeController.dispose();
    _exposureTimeController.dispose();
    _numberOfAttemptsController.dispose();
    _brightestNStarsController.dispose();
    _outerCropRatioController.dispose();
    _innerCropRatioController.dispose();
    _binningController.dispose();
    _rSquaredThresholdController.dispose();
    _failureToleranceController.dispose();
    _focuserSettleTimeController.dispose();
    _exposuresPerPointController.dispose();
    _backlashInController.dispose();
    _backlashOutController.dispose();
    super.dispose();
  }

  Widget _afNumberInput({
    Key? key,
    required TextEditingController controller,
    required String suffix,
    required double min,
    required double max,
    required int decimals,
    required FutureOr<void> Function(double) onChanged,
    double? width,
    bool isMobile = false,
  }) {
    final settings = _renderedSettings;
    final authoritativeValue = switch (controller) {
      _ when identical(controller, _initialOffsetStepsController) =>
        settings.afInitialOffsetSteps.toDouble(),
      _ when identical(controller, _stepSizeController) =>
        settings.afStepSize.toDouble(),
      _ when identical(controller, _exposureTimeController) =>
        settings.afExposureTime,
      _ when identical(controller, _numberOfAttemptsController) =>
        settings.afNumberOfAttempts.toDouble(),
      _ when identical(controller, _brightestNStarsController) =>
        settings.afUseBrightestNStars.toDouble(),
      _ when identical(controller, _outerCropRatioController) =>
        settings.afOuterCropRatio,
      _ when identical(controller, _innerCropRatioController) =>
        settings.afInnerCropRatio,
      _ when identical(controller, _binningController) =>
        settings.afBinning.toDouble(),
      _ when identical(controller, _rSquaredThresholdController) =>
        settings.afRSquaredThreshold,
      _ when identical(controller, _failureToleranceController) =>
        settings.afFailureHfrToleranceRatio,
      _ when identical(controller, _focuserSettleTimeController) =>
        settings.afFocuserSettleTimeMs.toDouble(),
      _ when identical(controller, _exposuresPerPointController) =>
        settings.afExposuresPerPoint.toDouble(),
      _ when identical(controller, _backlashInController) =>
        settings.afBacklashIn.toDouble(),
      _ when identical(controller, _backlashOutController) =>
        settings.afBacklashOut.toDouble(),
      _ => throw StateError('Unknown autofocus settings controller'),
    };
    return SettingsNumberInput(
      key: key,
      controller: controller,
      authoritativeValue: authoritativeValue,
      authorityKey: _renderedAuthority,
      suffix: suffix,
      min: min,
      max: max,
      decimals: decimals,
      onChanged: onChanged,
      width: width,
      isMobile: isMobile,
    );
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);
    final filterWheelState = ref.watch(filterWheelStateProvider);

    return settingsAsync.when(
      loading: () => SettingsLoadingState(
        isMobile: widget.isMobile,
        scrollable: !widget.embedded,
      ),
      error: (error, stack) => SettingsErrorState(
        isMobile: widget.isMobile,
        error: error,
        onRetry: () => ref.invalidate(appSettingsProvider),
      ),
      data: (settings) {
        _renderedSettings = settings;
        _renderedAuthority = ref.watch(backendProvider);
        final notifier = ref.read(appSettingsProvider.notifier);

        return SettingsPage(
          title: 'Autofocus',
          description:
              'Configure autofocus behavior, curve fitting, and per-filter settings',
          isMobile: widget.isMobile,
          hideHeader: widget.isMobile || widget.embedded,
          scrollable: !widget.embedded,
          children: [
            SettingsSection(
              // Not 'Autofocus': the merged page already bands this pane
              // AUTOFOCUS, and an eyebrow repeating it printed the word twice
              // in a row once section labels became uppercase.
              title: 'Behavior',
              isMobile: widget.isMobile,
              children: [
                if (!widget.isMobile)
                  _buildDesktopTwoColumnLayout(settings, notifier)
                else
                  ..._buildMobileLayout(settings, notifier),
              ],
            ),
            _buildFilterSettingsSection(settings, notifier, filterWheelState),
          ],
        );
      },
    );
  }

  Widget _buildDesktopTwoColumnLayout(
      AppSettingsState settings, AppSettingsNotifier notifier) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Left column
          Expanded(
            child: Column(
              children: [
                _buildAfSettingRow(
                  icon: LucideIcons.filter,
                  title: 'Use filter offsets',
                  subtitle: 'Apply focus offsets when changing filters',
                  trailing: SettingsSwitch(
                    value: settings.useFilterFocusOffsets,
                    onChanged: (value) =>
                        notifier.setUseFilterFocusOffsets(value),
                  ),
                ),
                _buildAfSettingRow(
                  icon: LucideIcons.arrowUpDown,
                  title: 'Initial offset steps',
                  subtitle: 'Steps out from center for V-curve',
                  trailing: _afNumberInput(
                    controller: _initialOffsetStepsController,
                    suffix: '',
                    min: 1,
                    max: 20,
                    decimals: 0,
                    onChanged: (value) =>
                        notifier.setAfInitialOffsetSteps(value.toInt()),
                  ),
                ),
                _buildAfSettingRow(
                  icon: LucideIcons.activity,
                  title: 'Autofocus method',
                  trailing: SettingsDropdown(
                    value: settings.afMethod,
                    items: const ['Star HFR'],
                    onChanged: (value) {
                      return notifier.setAfMethod(value);
                    },
                  ),
                ),
                _buildAfSettingRow(
                  icon: LucideIcons.trendingUp,
                  title: 'Curve fitting strategy',
                  trailing: SettingsDropdown(
                    value: settings.afCurveFitting,
                    items: AutofocusSettings.curveFittingOptions,
                    onChanged: (value) {
                      return notifier.setAfCurveFitting(value);
                    },
                    width: 150,
                  ),
                ),
                _buildAfSettingRow(
                  icon: LucideIcons.repeat,
                  title: 'Number of attempts',
                  subtitle: 'Retry count on failure',
                  trailing: _afNumberInput(
                    controller: _numberOfAttemptsController,
                    suffix: '',
                    min: 1,
                    max: 10,
                    decimals: 0,
                    onChanged: (value) =>
                        notifier.setAfNumberOfAttempts(value.toInt()),
                  ),
                ),
                _buildAfSettingRow(
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
                    onChanged: (value) =>
                        notifier.setAfUseBrightestNStars(value.toInt()),
                  ),
                ),
                _buildAfSettingRow(
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
                  ),
                ),
                _buildAfSettingRow(
                  icon: LucideIcons.grid,
                  title: 'Binning',
                  trailing: _afNumberInput(
                    controller: _binningController,
                    suffix: '',
                    min: 1,
                    max: 4,
                    decimals: 0,
                    onChanged: (value) => notifier.setAfBinning(value.toInt()),
                  ),
                ),
                _buildAfSettingRow(
                  icon: LucideIcons.checkCircle,
                  title: 'R\u00B2 threshold',
                  subtitle: 'Minimum acceptable curve fit quality',
                  trailing: _afNumberInput(
                    controller: _rSquaredThresholdController,
                    suffix: '',
                    min: 0.0,
                    max: 1.0,
                    decimals: 2,
                    onChanged: (value) =>
                        notifier.setAfRSquaredThreshold(value),
                  ),
                ),
                _buildAfSettingRow(
                  icon: LucideIcons.alertTriangle,
                  title: 'HFR tolerance on failure',
                  subtitle: kAfFailureToleranceSubtitle,
                  trailing: _afNumberInput(
                    controller: _failureToleranceController,
                    suffix: '\u00D7',
                    min: 0.0,
                    max: 10.0,
                    decimals: 2,
                    onChanged: (value) =>
                        notifier.setAfFailureHfrToleranceRatio(value),
                  ),
                  isLast: true,
                ),
              ],
            ),
          ),
          const SizedBox(width: 24),
          // Right column
          Expanded(
            child: Column(
              children: [
                _buildAfSettingRow(
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
                  ),
                ),
                _buildAfSettingRow(
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
                  ),
                ),
                _buildAfSettingRow(
                  icon: LucideIcons.pause,
                  title: 'Disable guiding during AF',
                  subtitle: 'Stop autoguider while focusing',
                  trailing: SettingsSwitch(
                    value: settings.afDisableGuidingDuringAf,
                    onChanged: (value) =>
                        notifier.setAfDisableGuidingDuringAf(value),
                  ),
                ),
                _buildAfSettingRow(
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
                  ),
                ),
                _buildAfSettingRow(
                  icon: LucideIcons.layers,
                  title: 'Exposures per point',
                  subtitle: 'Frames to average per focus position',
                  trailing: _afNumberInput(
                    controller: _exposuresPerPointController,
                    suffix: '',
                    min: 1,
                    max: 20,
                    decimals: 0,
                    onChanged: (value) =>
                        notifier.setAfExposuresPerPoint(value.toInt()),
                  ),
                ),
                _buildAfSettingRow(
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
                  ),
                ),
                _buildAfSettingRow(
                  icon: LucideIcons.arrowLeftRight,
                  title: 'Backlash compensation',
                  trailing: SettingsDropdown(
                    value: settings.afBacklashCompMethod,
                    items: const ['None', 'Overshoot', 'Absolute'],
                    onChanged: (value) {
                      return notifier.setAfBacklashCompMethod(value);
                    },
                    width: 150,
                  ),
                ),
                _buildAfSettingRow(
                  icon: LucideIcons.arrowLeft,
                  title: 'Backlash IN',
                  trailing: _afNumberInput(
                    controller: _backlashInController,
                    suffix: '',
                    min: 0,
                    max: 10000,
                    decimals: 0,
                    onChanged: (value) =>
                        notifier.setAfBacklashIn(value.toInt()),
                  ),
                ),
                _buildAfSettingRow(
                  icon: LucideIcons.arrowRight,
                  title: 'Backlash OUT',
                  trailing: _afNumberInput(
                    controller: _backlashOutController,
                    suffix: '',
                    min: 0,
                    max: 10000,
                    decimals: 0,
                    onChanged: (value) =>
                        notifier.setAfBacklashOut(value.toInt()),
                  ),
                  isLast: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Helper to build a compact setting row for the two-column desktop layout.
  Widget _buildAfSettingRow({
    required IconData icon,
    required String title,
    String? subtitle,
    required Widget trailing,
    bool isLast = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : Border(
                bottom: BorderSide(
                  color: SkotiqColors.of(context).border.withValues(alpha: 0.3),
                ),
              ),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: SkotiqColors.of(context).well,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusButton),
            ),
            child: Icon(icon,
                size: 14, color: SkotiqColors.of(context).textSecondary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: SkotiqTypography.labelSm
                      .copyWith(color: SkotiqColors.of(context).textPrimary),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    style: SkotiqTypography.captionSm.copyWith(
                      color: SkotiqColors.of(context).textMuted,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Flexible, not fixed: this page lays its rows out in TWO columns, so
          // each row gets about half the 880 px reading column (06 §Settings)
          // — 411 px — and a fixed-width dropdown beside a 32 px icon and a
          // label overflowed it. The control gives way after the label now.
          Flexible(
            child: Align(alignment: Alignment.centerRight, child: trailing),
          ),
        ],
      ),
    );
  }
}

/// A single row in the filter settings table (desktop).
