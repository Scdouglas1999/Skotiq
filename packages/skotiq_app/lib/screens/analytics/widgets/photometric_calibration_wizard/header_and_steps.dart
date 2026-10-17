part of '../photometric_calibration_wizard.dart';

extension _PhotometricWizardHeaderAndSteps
    on _PhotometricCalibrationWizardState {
  Widget _buildHeader(SkotiqColors colors) {
    return Text(
      'Compute transformation coefficients for absolute photometry',
      style: SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
    );
  }

  Widget _buildStepIndicator(SkotiqColors colors) {
    const labels = ['Select Frame', 'Match Stars', 'Compute Fit', 'Save'];
    return LayoutBuilder(
      builder: (context, constraints) {
        final showAllLabels = constraints.maxWidth >= 360;
        final showRail = constraints.maxWidth >= 300;
        Widget circle(int index) {
          final isActive = index == _step;
          final isDone = index < _step;
          return Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isActive
                  ? colors.primary
                  : isDone
                      ? colors.primary.withValues(alpha: 0.7)
                      : colors.well,
              border: Border.all(
                color: isActive || isDone
                    ? colors.primary
                    : colors.border.withValues(alpha: 0.4),
              ),
            ),
            child: Center(
              child: isDone
                  ? Icon(LucideIcons.check,
                      color: colors.textPrimary, size: SkotiqTokens.iconXs)
                  : Text(
                      '${index + 1}',
                      style: SkotiqTypography.labelStrongSm.copyWith(
                        color: isActive ? colors.textPrimary : colors.textMuted,
                      ),
                    ),
            ),
          );
        }

        Widget connector(bool filled) => Container(
              height: 2,
              color: filled
                  ? colors.primary
                  : colors.border.withValues(alpha: 0.3),
            );

        return Column(
          children: [
            if (showRail)
              Row(
                children: List.generate(labels.length, (index) {
                  final isDone = index < _step;
                  return Expanded(
                    child: Row(
                      children: [
                        if (index > 0) Expanded(child: connector(isDone)),
                        circle(index),
                        if (index < labels.length - 1)
                          Expanded(child: connector(isDone)),
                      ],
                    ),
                  );
                }),
              )
            else
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: List.generate(labels.length, circle),
              ),
            const SizedBox(height: SkotiqTokens.spaceSm - 2),
            Row(
              children: List.generate(labels.length, (index) {
                final isActive = index == _step;
                return Expanded(
                  child: Text(
                    showAllLabels || isActive ? labels[index] : '',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: SkotiqTypography.labelSm.copyWith(
                      color: isActive ? colors.primary : colors.textMuted,
                      fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                );
              }),
            ),
          ],
        );
      },
    );
  }

  // Step 1: select a standard star field frame
}
