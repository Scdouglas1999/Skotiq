part of '../mobile_widgets.dart';

class CompassCalibrationDialog extends StatelessWidget {
  const CompassCalibrationDialog({super.key});

  @override
  Widget build(BuildContext context) {
    // Tokenized surface so this dialog respects Red Night theme.
    final colors = SkotiqColors.of(context);
    return AlertDialog(
      backgroundColor: colors.surfaceOverlay,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8)),
      title: Row(
        children: [
          Icon(SkotiqIcons.compass, color: colors.info, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Compass Calibration',
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize18,
                fontWeight: FontWeight.bold,
                color: colors.textPrimary,
              ),
            ),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: AdaptiveDialogConstraints.hybrid(
          context,
          designMaxWidth: 400,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'For accurate sky aiming, calibrate your compass by moving your device in a figure-8 pattern several times.',
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize14,
                height: 1.4,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: SkotiqDecorations.emphasisSurface(colors.info),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Tips for best results:',
                    style: SkotiqTypography.h6.copyWith(color: colors.info),
                  ),
                  const SizedBox(height: 8),
                  const _CalibrationTip(
                      text: 'Move away from metal objects and magnets'),
                  const _CalibrationTip(
                      text: 'Remove phone cases with magnetic clasps'),
                  const _CalibrationTip(
                      text: 'Rotate device slowly in all three axes'),
                  const _CalibrationTip(
                      text:
                          'A colored dot shows accuracy: green = good, red = poor'),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Accuracy of a few degrees is typical for phone compasses. This mode is best for quick sky orientation, not precision pointing.',
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize11,
                color: colors.textMuted,
                height: 1.3,
              ),
            ),
          ],
        ),
      ),
      actions: [
        SkotiqButton(
          onPressed: () => Navigator.of(context).pop(false),
          label: 'Cancel',
          variant: ButtonVariant.ghost,
        ),
        SkotiqButton(
          onPressed: () => Navigator.of(context).pop(true),
          label: 'Enable Sky Aiming',
        ),
      ],
    );
  }
}

class _CalibrationTip extends StatelessWidget {
  final String text;

  const _CalibrationTip({required this.text});

  @override
  Widget build(BuildContext context) {
    final accent = SkotiqColors.of(context).info;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Icon(SkotiqIcons.check, size: 12, color: accent),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                  fontSize: SkotiqTypography.fontSize12, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
}
