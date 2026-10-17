import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Confirmation for the Sequencer toolbar's "Slew to Target".
///
/// A slew is a physical action that can point the mount below the horizon, so
/// it is confirmed before it is commanded rather than firing on a single click.
///
/// Returns true when the operator confirms the move.
Future<bool> showSlewToTargetConfirmation(
  BuildContext context, {
  required String targetName,
  required double raHours,
  required double decDegrees,
  double? altitudeDegrees,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => _SlewToTargetDialog(
      targetName: targetName,
      raHours: raHours,
      decDegrees: decDegrees,
      altitudeDegrees: altitudeDegrees,
    ),
  );
  return confirmed ?? false;
}

class _SlewToTargetDialog extends StatelessWidget {
  const _SlewToTargetDialog({
    required this.targetName,
    required this.raHours,
    required this.decDegrees,
    required this.altitudeDegrees,
  });

  final String targetName;
  final double raHours;
  final double decDegrees;
  final double? altitudeDegrees;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final altitude = altitudeDegrees;
    final belowHorizon = altitude != null && altitude <= 0;

    return SkotiqDialog(
      title: 'Slew to $targetName?',
      icon: LucideIcons.navigation,
      width: 460,
      actions: [
        SkotiqButton(
          label: 'Cancel',
          variant: ButtonVariant.outline,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        SkotiqButton(
          label: 'Slew now',
          icon: LucideIcons.navigation,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'The mount will move now.',
            style: SkotiqTypography.body.copyWith(
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          Text(
            'RA ${CoordinateParser.formatRaHms(raHours)}   '
            'Dec ${CoordinateParser.formatDecDms(decDegrees)}',
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textSecondary,
              fontFamily: 'monospace',
            ),
          ),
          if (altitude != null) ...[
            const SizedBox(height: SkotiqTokens.spaceSm),
            Text(
              'Altitude ${altitude.toStringAsFixed(1)}°',
              style: SkotiqTypography.bodySm.copyWith(
                color: belowHorizon ? colors.warning : colors.textSecondary,
              ),
            ),
          ],
          if (belowHorizon) ...[
            const SizedBox(height: SkotiqTokens.spaceMd),
            SkotiqInlineBanner(
              severity: SkotiqAlertSeverity.warning,
              message:
                  '$targetName is below the horizon. The mount would point at '
                  'the ground.',
            ),
          ],
        ],
      ),
    );
  }
}
