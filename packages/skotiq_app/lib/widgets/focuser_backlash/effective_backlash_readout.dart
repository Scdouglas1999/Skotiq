import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'focuser_backlash_calibration_dialog.dart';
import 'focuser_backlash_text.dart';

/// What the backlash setting is ACTUALLY worth right now, and where it came
/// from — the sub-line under a "Backlash compensation" field.
///
/// Rendered in the `camera_sensor_specs_dialog` provenance style: the value
/// above, the sentence that says where it came from directly underneath. A bare
/// number here is the failure mode the whole feature exists to fix — the owner's
/// EAF measured 105 steps near position 6600 and 83 steps near 2500, so "105"
/// on its own is not a fact about the focuser, it is a fact about one place on
/// its travel.
///
/// Precedence is stated, never applied silently: a value the operator typed
/// stays in force, and a measurement that exists alongside it is shown as on
/// record and NOT being used, with a one-tap way to adopt it if that is what
/// they wanted.
class EffectiveBacklashReadout extends ConsumerWidget {
  const EffectiveBacklashReadout({
    super.key,
    this.onUseMeasured,
    this.showCalibrateButton = true,
  });

  /// Called with the measured step count when the operator chooses to adopt it.
  /// When null, the "use the measured value" affordance is not offered — the
  /// host has no way to write the field.
  final ValueChanged<int>? onUseMeasured;

  /// Show the button that opens the calibration wizard.
  final bool showCalibrateButton;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final effective = ref.watch(effectiveFocuserBacklashProvider);
    final saved = ref.watch(savedFocuserBacklashProvider).valueOrNull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // `provenance` is authored in skotiq_core to read as the tail of
        // exactly these two sentences, so the wording of where a figure came
        // from lives in one place rather than being re-derived per surface.
        Text(
          effective.hasFigure
              ? '${effective.steps} steps, ${effective.provenance}.'
              : 'Backlash compensation is off: ${effective.provenance}.',
          style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
        ),
        if (effective.origin == FocuserBacklashOrigin.measured) ...[
          const SizedBox(height: SkotiqTokens.spaceXs),
          Text(
            'Backlash varies along the travel — measure again if you move a '
            'long way from that position.',
            style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
          ),
        ],
        // A figure they typed that the compensation-method switch is zeroing
        // before it reaches the engine. Said plainly, because the field
        // immediately above shows that number and would otherwise read as
        // being in force.
        if (effective.switchedOffOperatorSteps case final int switchedOff) ...[
          const SizedBox(height: SkotiqTokens.spaceXs),
          Text(
            'The $switchedOff steps above is switched off by the backlash '
            'compensation method in Autofocus settings, so it is not being '
            'applied.',
            style: SkotiqTypography.caption.copyWith(color: colors.warning),
          ),
        ],
        if (effective.origin == FocuserBacklashOrigin.operatorEntered &&
            saved != null) ...[
          const SizedBox(height: SkotiqTokens.spaceSm),
          _OperatorValueWins(
            effective: effective,
            saved: saved,
            onUseMeasured: onUseMeasured,
          ),
        ],
        if (showCalibrateButton) ...[
          const SizedBox(height: SkotiqTokens.spaceSm),
          SkotiqButton(
            label: effective.origin == FocuserBacklashOrigin.measured ||
                    saved != null
                ? 'Measure again'
                : 'Calibrate backlash',
            icon: LucideIcons.gitCompare,
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: () => FocuserBacklashCalibrationDialog.show(context),
          ),
        ],
      ],
    );
  }
}

/// The precedence statement: the typed value is in force, the measurement is
/// on record and inactive.
class _OperatorValueWins extends StatelessWidget {
  const _OperatorValueWins({
    required this.effective,
    required this.saved,
    required this.onUseMeasured,
  });

  final EffectiveFocuserBacklash effective;
  final FocuserBacklashCalibrationRecord saved;
  final ValueChanged<int>? onUseMeasured;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final where = backlashRecordSubLine(saved);
    final matches = saved.measurable && saved.steps == effective.steps;
    // A record can exist and hold no figure: "no backlash larger than N steps
    // was detectable" is a successful measurement, and describing it as "a
    // measurement of 0 steps" would read as a failed one.
    final sentence = !saved.measurable
        ? 'Your value is the one in force. A measurement ($where) found no '
            'backlash larger than '
            '${saved.resolutionLimitSteps.toStringAsFixed(0)} steps.'
        : matches
            ? 'Your value matches the measurement on record ($where).'
            : 'Your value is the one in force. A measurement of '
                '${saved.steps} steps ($where) is on record and is NOT being '
                'used.';
    final reassuring = matches || !saved.measurable;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              reassuring ? LucideIcons.check : LucideIcons.info,
              size: SkotiqTokens.iconXs,
              color: reassuring ? colors.success : colors.warning,
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Expanded(
              child: Text(
                sentence,
                style: SkotiqTypography.caption.copyWith(
                  color: reassuring ? colors.textMuted : colors.warning,
                ),
              ),
            ),
          ],
        ),
        if (!reassuring && onUseMeasured != null) ...[
          const SizedBox(height: SkotiqTokens.spaceXs),
          SkotiqButton(
            label: 'Use the measured ${saved.steps}',
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
            onPressed: () => onUseMeasured!(saved.steps),
          ),
        ],
      ],
    );
  }
}
