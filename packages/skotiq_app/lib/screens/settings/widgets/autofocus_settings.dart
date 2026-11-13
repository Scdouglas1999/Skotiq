import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'settings_widgets.dart';
part 'autofocus_settings/filter_settings_row.dart';
part 'autofocus_settings/filter_settings_mobile_card.dart';

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
  const AutofocusSettingsPage({
    super.key,
  });

  @override
  ConsumerState<AutofocusSettingsPage> createState() =>
      _AutofocusSettingsState();
}

typedef _AfField<T> = SettingField<AppSettingsState, T>;

AppSettingsNotifier _afNotifier(WidgetRef ref) =>
    ref.read(appSettingsProvider.notifier);

_AfField<int> _afInt({
  required String title,
  required int Function(AppSettingsState s) read,
  required FutureOr<void> Function(AppSettingsNotifier n, int v) write,
  required int min,
  required int max,
  String unit = '',
}) =>
    _AfField<int>(
      label: title,
      read: read,
      write: (ref, value) => write(_afNotifier(ref), value),
      codec: IntCodec(min: min, max: max, unit: unit),
    );

_AfField<double> _afNumber({
  required String title,
  required double Function(AppSettingsState s) read,
  required FutureOr<void> Function(AppSettingsNotifier n, double v) write,
  required double min,
  required double max,
  required int decimals,
  String unit = '',
}) =>
    _AfField<double>(
      label: title,
      read: read,
      write: (ref, value) => write(_afNotifier(ref), value),
      codec: NumberCodec(min: min, max: max, decimals: decimals, unit: unit),
    );

_AfField<bool> _afToggle({
  required String title,
  required bool Function(AppSettingsState s) read,
  required FutureOr<void> Function(AppSettingsNotifier n, bool v) write,
}) =>
    _AfField<bool>(
      label: title,
      read: read,
      write: (ref, value) => write(_afNotifier(ref), value),
    );

_AfField<String> _afChoice({
  required String title,
  required String Function(AppSettingsState s) read,
  required FutureOr<void> Function(AppSettingsNotifier n, String v) write,
  required List<String> choices,
}) =>
    _AfField<String>(
      label: title,
      read: read,
      write: (ref, value) => write(_afNotifier(ref), value),
      choices: choices,
      choiceLabel: (value) => value,
    );

/// One row of the Behavior group: the setting plus how the row presents it.
/// The desktop two-column layout and the phone list are both built from
/// [_afBehaviorRows], so a bound or a label exists once.
class _AfRow<T> {
  const _AfRow(
    this.icon,
    this.field, {
    this.subtitle,
    this.rightColumn = false,
    this.width,
  });

  final IconData icon;
  final _AfField<T> field;
  final String? subtitle;

  /// Which of the two desktop columns the row sits in.
  final bool rightColumn;

  final double? width;

  Widget control(AppSettingsState settings) =>
      SettingsField<AppSettingsState, T>(
        field: field,
        state: settings,
        width: width,
      );
}

/// The Behavior rows, in phone order. Desktop keeps this order within each
/// column.
final List<_AfRow<Object?>> _afBehaviorRows = [
  _AfRow<bool>(
    LucideIcons.filter,
    _afToggle(
      title: 'Use filter offsets',
      read: (s) => s.useFilterFocusOffsets,
      write: (n, v) => n.setUseFilterFocusOffsets(v),
    ),
    subtitle: 'Apply focus offsets when changing filters',
  ),
  _AfRow<int>(
    LucideIcons.arrowUpDown,
    _afInt(
      title: 'Initial offset steps',
      read: (s) => s.afInitialOffsetSteps,
      write: (n, v) => n.setAfInitialOffsetSteps(v),
      min: 1,
      max: 20,
    ),
    subtitle: 'Steps out from center for V-curve',
  ),
  _AfRow<String>(
    LucideIcons.activity,
    _afChoice(
      title: 'Autofocus method',
      read: (s) => s.afMethod,
      write: (n, v) => n.setAfMethod(v),
      choices: const ['Star HFR'],
    ),
  ),
  _AfRow<String>(
    LucideIcons.trendingUp,
    _afChoice(
      title: 'Curve fitting strategy',
      read: (s) => s.afCurveFitting,
      write: (n, v) => n.setAfCurveFitting(v),
      choices: AutofocusSettings.curveFittingOptions,
    ),
    width: 150,
  ),
  _AfRow<int>(
    LucideIcons.moveVertical,
    _afInt(
      title: 'Step size',
      read: (s) => s.afStepSize,
      write: (n, v) => n.setAfStepSize(v),
      min: 1,
      max: 10000,
    ),
    subtitle: 'Focuser steps between measurement points',
    rightColumn: true,
  ),
  _AfRow<double>(
    LucideIcons.timer,
    _afNumber(
      title: 'Exposure time',
      read: (s) => s.afExposureTime,
      write: (n, v) => n.setAfExposureTime(v),
      min: 0.1,
      max: 300,
      decimals: 1,
      unit: 's',
    ),
    subtitle: 'Default AF frame exposure',
    rightColumn: true,
  ),
  _AfRow<bool>(
    LucideIcons.pause,
    _afToggle(
      title: 'Disable guiding during AF',
      read: (s) => s.afDisableGuidingDuringAf,
      write: (n, v) => n.setAfDisableGuidingDuringAf(v),
    ),
    subtitle: 'Stop autoguider while focusing',
    rightColumn: true,
  ),
  _AfRow<int>(
    LucideIcons.repeat,
    _afInt(
      title: 'Number of attempts',
      read: (s) => s.afNumberOfAttempts,
      write: (n, v) => n.setAfNumberOfAttempts(v),
      min: 1,
      max: 10,
    ),
    subtitle: 'Retry count on failure',
  ),
  _AfRow<int>(
    LucideIcons.sparkles,
    _afInt(
      title: 'Use brightest n stars',
      read: (s) => s.afUseBrightestNStars,
      write: (n, v) => n.setAfUseBrightestNStars(v),
      min: 0,
      max: 500,
    ),
    subtitle: 'Default 10. 0 uses every detected star; faint ones skew the HFR',
  ),
  _AfRow<double>(
    LucideIcons.maximize2,
    _afNumber(
      title: 'Outer crop ratio',
      read: (s) => s.afOuterCropRatio,
      write: (n, v) => n.setAfOuterCropRatio(v),
      min: 0.01,
      max: 1.0,
      decimals: 2,
    ),
    subtitle: 'Must be greater than the inner crop ratio',
  ),
  _AfRow<double>(
    LucideIcons.minimize2,
    _afNumber(
      title: 'Inner crop ratio',
      read: (s) => s.afInnerCropRatio,
      write: (n, v) => n.setAfInnerCropRatio(v),
      min: 0.0,
      max: 1.0,
      decimals: 2,
    ),
    subtitle: 'Central exclusion; must be smaller than outer',
    rightColumn: true,
  ),
  _AfRow<int>(
    LucideIcons.grid,
    _afInt(
      title: 'Binning',
      read: (s) => s.afBinning,
      write: (n, v) => n.setAfBinning(v),
      min: 1,
      max: 4,
    ),
  ),
  _AfRow<double>(
    LucideIcons.checkCircle,
    _afNumber(
      title: 'R\u00B2 threshold',
      read: (s) => s.afRSquaredThreshold,
      write: (n, v) => n.setAfRSquaredThreshold(v),
      min: 0.0,
      max: 1.0,
      decimals: 2,
    ),
    subtitle: 'Minimum acceptable curve fit quality',
  ),
  _AfRow<double>(
    LucideIcons.alertTriangle,
    _afNumber(
      title: 'HFR tolerance on failure',
      read: (s) => s.afFailureHfrToleranceRatio,
      write: (n, v) => n.setAfFailureHfrToleranceRatio(v),
      min: 0.0,
      max: 10.0,
      decimals: 2,
      unit: '\u00D7',
    ),
    subtitle: kAfFailureToleranceSubtitle,
  ),
  _AfRow<int>(
    LucideIcons.clock,
    _afInt(
      title: 'Focuser settle time',
      read: (s) => s.afFocuserSettleTimeMs,
      write: (n, v) => n.setAfFocuserSettleTimeMs(v),
      min: 0,
      max: 10000,
      unit: 'ms',
    ),
    subtitle: 'Wait after focuser move',
    rightColumn: true,
  ),
  _AfRow<int>(
    LucideIcons.layers,
    _afInt(
      title: 'Exposures per point',
      read: (s) => s.afExposuresPerPoint,
      write: (n, v) => n.setAfExposuresPerPoint(v),
      min: 1,
      max: 20,
    ),
    subtitle: 'Frames to average per focus position',
    rightColumn: true,
  ),
  _AfRow<String>(
    LucideIcons.arrowLeftRight,
    _afChoice(
      title: 'Backlash compensation',
      read: (s) => s.afBacklashCompMethod,
      write: (n, v) => n.setAfBacklashCompMethod(v),
      choices: const ['None', 'Overshoot', 'Absolute'],
    ),
    rightColumn: true,
    width: 150,
  ),
  _AfRow<int>(
    LucideIcons.arrowLeft,
    _afInt(
      title: 'Backlash IN',
      read: (s) => s.afBacklashIn,
      write: (n, v) => n.setAfBacklashIn(v),
      min: 0,
      max: 10000,
    ),
    rightColumn: true,
  ),
  _AfRow<int>(
    LucideIcons.arrowRight,
    _afInt(
      title: 'Backlash OUT',
      read: (s) => s.afBacklashOut,
      write: (n, v) => n.setAfBacklashOut(v),
      min: 0,
      max: 10000,
    ),
    rightColumn: true,
  ),
];

class _AutofocusSettingsState extends ConsumerState<AutofocusSettingsPage> {
  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);
    final filterWheelState = ref.watch(filterWheelStateProvider);

    return settingsAsync.when(
      loading: () => const SettingsLoadingState(),
      error: (error, stack) => SettingsErrorState(
        error: error,
        onRetry: () => ref.invalidate(appSettingsProvider),
      ),
      data: (settings) {
        final notifier = ref.read(appSettingsProvider.notifier);

        return SettingsPage(
          title: 'Autofocus',
          description:
              'Configure autofocus behavior, curve fitting, and per-filter settings',
          children: [
            SettingsSection(
              // Not 'Autofocus': the merged page already bands this pane
              // AUTOFOCUS, and an eyebrow repeating it printed the word twice
              // in a row once section labels became uppercase.
              title: 'Behavior',
              children: [
                if (!SettingsFormScope.narrowOf(context))
                  _buildDesktopTwoColumnLayout(settings)
                else
                  for (final row in _afBehaviorRows)
                    SettingRow(
                      icon: row.icon,
                      title: row.field.label,
                      subtitle: row.subtitle,
                      trailing: row.control(settings),
                    ),
              ],
            ),
            _buildFilterSettingsSection(settings, notifier, filterWheelState),
          ],
        );
      },
    );
  }

  Widget _buildDesktopTwoColumnLayout(AppSettingsState settings) {
    Widget column({required bool right}) {
      final rows = [
        for (final row in _afBehaviorRows)
          if (row.rightColumn == right) row,
      ];
      return Expanded(
        child: Column(
          children: [
            for (final row in rows)
              _buildAfSettingRow(
                icon: row.icon,
                title: row.field.label,
                subtitle: row.subtitle,
                trailing: row.control(settings),
                isLast: identical(row, rows.last),
              ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          column(right: false),
          const SizedBox(width: 24),
          column(right: true),
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
