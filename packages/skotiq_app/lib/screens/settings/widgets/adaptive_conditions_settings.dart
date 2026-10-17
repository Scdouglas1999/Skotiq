// Adaptive sky-conditions swap defaults.
//
// These controls persist the defaults that seed newly-created
// TargetScheduler nodes. Existing scheduler nodes keep their own
// per-node values.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'settings_widgets.dart';

class AdaptiveConditionsSettings extends ConsumerStatefulWidget {
  final bool isMobile;

  const AdaptiveConditionsSettings({
    super.key,
    this.isMobile = false,
  });

  @override
  ConsumerState<AdaptiveConditionsSettings> createState() =>
      _AdaptiveConditionsSettingsState();
}

class _AdaptiveConditionsSettingsState
    extends ConsumerState<AdaptiveConditionsSettings> {
  final _thresholdController = TextEditingController();
  final _hysteresisController = TextEditingController();
  final _weightControllers = <String, TextEditingController>{
    'transparency': TextEditingController(),
    'seeing': TextEditingController(),
    'cloud': TextEditingController(),
    'wind': TextEditingController(),
  };
  String? _weightError;

  @override
  void dispose() {
    _thresholdController.dispose();
    _hysteresisController.dispose();
    for (final controller in _weightControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);

    return settingsAsync.when(
      loading: () => SettingsLoadingState(
        isMobile: widget.isMobile,
      ),
      error: (error, stack) => SettingsErrorState(
        isMobile: widget.isMobile,
        error: error,
        onRetry: () => ref.invalidate(appSettingsProvider),
      ),
      data: (settings) {
        final authority = ref.watch(backendProvider);
        final notifier = ref.read(appSettingsProvider.notifier);
        final weightTotal = settings.conditionsScoreWeights.values.fold<double>(
          0,
          (sum, value) => sum + value,
        );

        return SettingsPage(
          title: 'Adaptive conditions',
          description:
              'Defaults for sky-conditions target swapping in new scheduler nodes',
          isMobile: widget.isMobile,
          hideHeader: widget.isMobile,
          children: [
            SettingsSection(
              title: 'Swap defaults',
              isMobile: widget.isMobile,
              children: [
                SettingRow(
                  icon: LucideIcons.toggleLeft,
                  title: 'Enabled for new schedulers',
                  subtitle:
                      'New TargetScheduler nodes start with adaptive swap enabled and use the score floor below. Existing nodes are not changed.',
                  trailing: KeyedSubtree(
                    key: const ValueKey('adaptiveSwapEnabledToggle'),
                    child: SettingsSwitch(
                      value: settings.adaptiveSwapEnabledByDefault,
                      onChanged: (value) async {
                        await notifier.setAdaptiveSwapEnabledByDefault(value);
                      },
                    ),
                  ),
                  isMobile: widget.isMobile,
                ),
                SettingRow(
                  icon: LucideIcons.gauge,
                  title: 'Score floor',
                  subtitle:
                      'When the live conditions score falls below this 0-100 floor, the scheduler can swap to a better target.',
                  trailing: SettingsNumberInput(
                    key: const ValueKey('adaptiveSwapThresholdInput'),
                    controller: _thresholdController,
                    authoritativeValue: settings.adaptiveSwapDefaultThreshold,
                    authorityKey: authority,
                    suffix: '',
                    min: 0,
                    max: 100,
                    decimals: 0,
                    onChanged: (value) async {
                      await notifier.setAdaptiveSwapDefaultThreshold(value);
                    },
                    isMobile: widget.isMobile,
                  ),
                  isMobile: widget.isMobile,
                  stackOnMobile: true,
                ),
                SettingRow(
                  icon: LucideIcons.timerReset,
                  title: 'Swap hysteresis',
                  subtitle:
                      'Minimum seconds between adaptive target swaps. Range 0-3600.',
                  trailing: SettingsNumberInput(
                    key: const ValueKey('adaptiveSwapHysteresisInput'),
                    controller: _hysteresisController,
                    authoritativeValue:
                        settings.adaptiveSwapDefaultHysteresisSecs,
                    authorityKey: authority,
                    suffix: 's',
                    min: 0,
                    max: 3600,
                    decimals: 0,
                    onChanged: (value) async {
                      await notifier
                          .setAdaptiveSwapDefaultHysteresisSecs(value);
                    },
                    isMobile: widget.isMobile,
                  ),
                  isMobile: widget.isMobile,
                  stackOnMobile: true,
                  isLast: true,
                ),
              ],
            ),
            const SizedBox(height: 28),
            SettingsSection(
              title: 'Score weights',
              isMobile: widget.isMobile,
              children: [
                _WeightRow(
                  key: const ValueKey('adaptiveSwapTransparencyWeightRow'),
                  icon: LucideIcons.eye,
                  title: 'Transparency weight',
                  subtitle:
                      'Influence of cloudless, clear-sky transparency in the composed conditions score.',
                  controller: _weightControllers['transparency']!,
                  inputKey:
                      const ValueKey('adaptiveSwapTransparencyWeightInput'),
                  authoritativeValue:
                      settings.conditionsScoreWeights['transparency'] ?? 0,
                  authorityKey: authority,
                  isMobile: widget.isMobile,
                  onChanged: (value) =>
                      _setWeight(notifier, settings, 'transparency', value),
                ),
                _WeightRow(
                  icon: LucideIcons.aperture,
                  title: 'Seeing weight',
                  subtitle:
                      'Influence of star sharpness and atmospheric steadiness.',
                  controller: _weightControllers['seeing']!,
                  inputKey: const ValueKey('adaptiveSwapSeeingWeightInput'),
                  authoritativeValue:
                      settings.conditionsScoreWeights['seeing'] ?? 0,
                  authorityKey: authority,
                  isMobile: widget.isMobile,
                  onChanged: (value) =>
                      _setWeight(notifier, settings, 'seeing', value),
                ),
                _WeightRow(
                  icon: LucideIcons.cloud,
                  title: 'Cloud weight',
                  subtitle: 'Influence of cloud cover and opacity estimates.',
                  controller: _weightControllers['cloud']!,
                  inputKey: const ValueKey('adaptiveSwapCloudWeightInput'),
                  authoritativeValue:
                      settings.conditionsScoreWeights['cloud'] ?? 0,
                  authorityKey: authority,
                  isMobile: widget.isMobile,
                  onChanged: (value) =>
                      _setWeight(notifier, settings, 'cloud', value),
                ),
                _WeightRow(
                  icon: LucideIcons.wind,
                  title: 'Wind weight',
                  subtitle:
                      'Influence of wind speed when choosing whether to stay on target.',
                  controller: _weightControllers['wind']!,
                  inputKey: const ValueKey('adaptiveSwapWindWeightInput'),
                  authoritativeValue:
                      settings.conditionsScoreWeights['wind'] ?? 0,
                  authorityKey: authority,
                  isMobile: widget.isMobile,
                  onChanged: (value) =>
                      _setWeight(notifier, settings, 'wind', value),
                  isLast: true,
                ),
              ],
            ),
            const SizedBox(height: 16),
            _WeightTotalCallout(
              total: weightTotal,
            ),
            if (_weightError != null) ...[
              const SizedBox(height: SkotiqTokens.spaceSm),
              Text(
                _weightError!,
                key: const Key('adaptiveSwapWeightError'),
                style: SkotiqTypography.caption.copyWith(
                  color: SkotiqColors.of(context).error,
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Future<void> _setWeight(
    AppSettingsNotifier notifier,
    AppSettingsState settings,
    String key,
    double value,
  ) async {
    final next = Map<String, double>.from(settings.conditionsScoreWeights)
      ..[key] = value;
    final total = next.values.fold<double>(0, (sum, v) => sum + v);
    // Zeroing the last non-zero weight is not a de-emphasis, it is an off
    // switch: AdaptiveSwapService.compose returns null when the weight total
    // is <= 0, the driver pushes that null to the executor, and every swap
    // decision from then on is ConditionsUnknown. Refusing the write keeps
    // the feature configurable instead of silently disabled; the number field
    // rolls back to its stored value when this throws.
    if (total <= 0) {
      const message =
          'At least one score weight must be above zero. With every weight at '
          '0 no conditions score can be computed and adaptive swapping stops '
          'running.';
      if (mounted) setState(() => _weightError = message);
      throw ArgumentError.value(value, key, message);
    }
    if (mounted && _weightError != null) {
      setState(() => _weightError = null);
    }
    await notifier.setConditionsScoreWeights(next);
  }
}

class _WeightRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final TextEditingController controller;
  final ValueKey<String> inputKey;
  final double authoritativeValue;
  final Object authorityKey;
  final bool isMobile;

  /// Returns a future so a refused write (see `_setWeight`) propagates back
  /// into [SettingsNumberInput], which rolls the field back to the stored
  /// value. A `void` signature would swallow the rejection and leave the
  /// field showing a number that was never saved.
  final Future<void> Function(double) onChanged;
  final bool isLast;

  const _WeightRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.controller,
    required this.inputKey,
    required this.authoritativeValue,
    required this.authorityKey,
    required this.isMobile,
    required this.onChanged,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    return SettingRow(
      icon: icon,
      title: title,
      subtitle: subtitle,
      trailing: SettingsNumberInput(
        key: inputKey,
        controller: controller,
        authoritativeValue: authoritativeValue,
        authorityKey: authorityKey,
        suffix: '',
        min: 0,
        max: 10,
        decimals: 2,
        onChanged: onChanged,
        isMobile: isMobile,
      ),
      isMobile: isMobile,
      stackOnMobile: true,
      isLast: isLast,
    );
  }
}

class _WeightTotalCallout extends StatelessWidget {
  final double total;

  const _WeightTotalCallout({
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final nearOne = (total - 1.0).abs() < 0.001;
    // A zero total is not a balance problem, it is a dead feature: compose()
    // bails at `weightTotal <= 0` and no score is ever produced. Saying
    // "the composer renormalizes available axes" here would be false.
    final noAxes = total <= 0;
    final color = nearOne ? colors.info : colors.warning;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: SkotiqDecorations.chip(colors, tone: color),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            nearOne ? LucideIcons.info : LucideIcons.alertTriangle,
            size: 16,
            color: color,
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Expanded(
            child: Text(
              noAxes
                  ? 'Weights sum to 0.00. No conditions score can be computed, '
                      'so adaptive swapping will not run — every scheduler '
                      'decision falls back to "conditions unknown". Set at '
                      'least one weight above zero.'
                  : nearOne
                      ? 'Weights sum to ${total.toStringAsFixed(2)}. The composer will preserve the configured balance.'
                      : 'Weights sum to ${total.toStringAsFixed(2)}. The composer renormalizes available axes at runtime, but keeping the total near 1.00 makes the score easier to reason about.',
              style: SkotiqTypography.caption.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
