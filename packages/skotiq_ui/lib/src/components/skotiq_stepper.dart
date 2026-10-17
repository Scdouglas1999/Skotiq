import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';

/// A compact `-`/`+` integer stepper for dense rows (e.g. sequencer tree
/// quick-edit) and forms.
///
/// Renders a bordered [SkotiqColors.surfaceAlt] pill containing a minus
/// button, a tabular numeric readout (so digits never shift the layout), and a
/// plus button. The minus button disables at [min] and the plus button
/// disables at [max]; disabled buttons dim to [SkotiqTokens.opacityDisabled]
/// and do not invoke [onChanged].
///
/// Every emitted value is clamped to the inclusive `[min, max]` range, so
/// callers can route the result straight into a `copyWith` without re-clamping.
///
/// ```dart
/// SkotiqStepper(
///   value: node.count,
///   min: 1,
///   max: 999,
///   semanticLabel: 'Exposure count',
///   onChanged: (v) => ref
///       .read(currentSequenceProvider.notifier)
///       .updateNode(node.copyWith(count: v)),
/// )
/// ```
class SkotiqStepper extends StatelessWidget {
  /// The current value. Expected to already lie within `[min, max]`; values
  /// outside the range are displayed verbatim but the buttons still respect the
  /// bounds.
  final int value;

  /// Called with the new, range-clamped value when the user taps a button.
  final ValueChanged<int> onChanged;

  /// Inclusive lower bound. The minus button is disabled at or below this.
  final int min;

  /// Inclusive upper bound. The plus button is disabled at or above this.
  final int max;

  /// Amount added/subtracted per tap.
  final int step;

  /// Tighter padding and smaller icons for dense tree rows.
  final bool compact;

  /// Accessibility label describing what the value represents. The current
  /// value is exposed separately as the semantics `value`.
  final String? semanticLabel;

  const SkotiqStepper({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 1,
    this.max = 9999,
    this.step = 1,
    this.compact = false,
    this.semanticLabel,
  }) : assert(min <= max, 'min must be <= max'),
       assert(step > 0, 'step must be positive');

  bool get _canDecrement => value > min;
  bool get _canIncrement => value < max;

  void _decrement() {
    if (!_canDecrement) return;
    onChanged((value - step).clamp(min, max));
  }

  void _increment() {
    if (!_canIncrement) return;
    onChanged((value + step).clamp(min, max));
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final double iconSize = compact ? SkotiqTokens.iconXs : SkotiqTokens.iconSm;
    // A min-width sized for four digits keeps the readout from reflowing as the
    // value changes; tabular figures handle digit-width parity.
    final double valueMinWidth = compact ? 24 : 30;

    return Semantics(
      label: semanticLabel,
      value: '$value',
      container: true,
      child: Container(
        decoration: BoxDecoration(
          color: colors.surfaceAlt,
          borderRadius: SkotiqTokens.borderRadiusSm,
          border: Border.all(color: colors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _StepperButton(
              icon: LucideIcons.minus,
              iconSize: iconSize,
              compact: compact,
              colors: colors,
              isEnabled: _canDecrement,
              semanticLabel: 'Decrease',
              onTap: _decrement,
            ),
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compact
                    ? SkotiqTokens.spaceXs
                    : SkotiqTokens.spaceSm,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: valueMinWidth),
                child: Text(
                  '$value',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  style: SkotiqTypography.withTabular(
                    SkotiqTypography.monoSm,
                  ).copyWith(color: colors.textPrimary),
                ),
              ),
            ),
            _StepperButton(
              icon: LucideIcons.plus,
              iconSize: iconSize,
              compact: compact,
              colors: colors,
              isEnabled: _canIncrement,
              semanticLabel: 'Increase',
              onTap: _increment,
            ),
          ],
        ),
      ),
    );
  }
}

/// One end button of a [SkotiqStepper]. Provides a comfortable tap target,
/// a hover fill, and a disabled (dimmed, non-interactive) state.
class _StepperButton extends StatelessWidget {
  final IconData icon;
  final double iconSize;
  final bool compact;
  final SkotiqColors colors;
  final bool isEnabled;
  final String semanticLabel;
  final VoidCallback onTap;

  const _StepperButton({
    required this.icon,
    required this.iconSize,
    required this.compact,
    required this.colors,
    required this.isEnabled,
    required this.semanticLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final EdgeInsets padding = compact
        ? const EdgeInsets.symmetric(
            horizontal: SkotiqTokens.spaceXs,
            vertical: SkotiqTokens.spaceXs,
          )
        : SkotiqTokens.paddingSm;

    final Color iconColor = isEnabled
        ? colors.textSecondary
        : colors.textSecondary.withValues(alpha: SkotiqTokens.opacityDisabled);

    return Semantics(
      button: true,
      enabled: isEnabled,
      label: semanticLabel,
      child: MouseRegion(
        cursor: isEnabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: InkWell(
          onTap: isEnabled ? onTap : null,
          borderRadius: SkotiqTokens.borderRadiusSm,
          hoverColor: colors.surfaceHover,
          customBorder: RoundedRectangleBorder(
            borderRadius: SkotiqTokens.borderRadiusSm,
          ),
          child: Padding(
            padding: padding,
            child: Icon(icon, size: iconSize, color: iconColor),
          ),
        ),
      ),
    );
  }
}
