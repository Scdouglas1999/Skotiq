part of '../polar_alignment_screen.dart';

extension _MeasurementPanel on _PolarAlignmentScreenState {
  /// The step card of the measuring phase: what the run is doing now, and the
  /// run's own status line or the solve timer under it.
  Widget _buildMeasuringCard(SkotiqColors colors, PolarAlignmentState state) {
    final status = state.statusMessage;
    // One number for the whole panel: the progress rail and the activity line
    // are describing the same instant, so they resolve the point the same way.
    final point = polarRunEffectivePoint(status, state.currentPoint);

    return SkotiqCard(
      variant: CardVariant.subtle,
      borderRadius: SkotiqTokens.radiusInline8,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // What the run is doing now leads the card; the run's own status
          // line, or the solve timer, is the detail under it. The point
          // list that used to head the card repeated the progress rail
          // directly above it.
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: colors.surfaceAlt,
              borderRadius: SkotiqTokens.borderRadiusMd,
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: SkotiqSpinner(size: 14, color: colors.primary),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    polarRunActivityLabel(status, point),
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize11,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          if (status.toLowerCase().contains('solv'))
            _SolveProgressIndicator(colors: colors, status: status)
          else
            Text(
              status,
              style: SkotiqTypography.bodySm.copyWith(
                color: colors.textSecondary,
              ),
            ),
        ],
      ),
    );
  }

  /// The live frame: the screen's main element while a run is in progress.
  ///
  /// No bullseye is drawn over it. The readout column carries the bullseye; a
  /// second, unscaled one over the stars plotted arcseconds on a pixel image
  /// and pinned every large error to its rim.
  Widget _buildLiveFrame(SkotiqColors colors, PolarAlignmentState state) {
    final waiting = state.phase == PolarAlignPhase.adjusting
        ? 'Capturing adjustment image...'
        : 'Waiting for image...';
    return Padding(
      padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
      child: Container(
        key: TourTarget.polarImageView.key,
        decoration: BoxDecoration(
          color: colors.surfaceAlt,
          borderRadius: SkotiqTokens.borderRadiusInline8,
          border: Border.all(color: colors.border),
        ),
        child: Stack(
          children: [
            if (state.hasImage)
              Positioned.fill(
                child: ClipRRect(
                  borderRadius: SkotiqTokens.borderRadiusInline8,
                  child: Image.memory(
                    state.imageData!,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  ),
                ),
              )
            else
              // Scaled down, never clipped: on a landscape phone the frame can
              // be shorter than the mark and its caption.
              Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 60,
                        height: 60,
                        child: SkotiqMark(
                            motion: SkotiqMarkMotion.loading, size: 60),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        waiting,
                        style: TextStyle(
                          fontSize: SkotiqTypography.fontSize12,
                          color: colors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (state.solvedRa != null && state.solvedDec != null)
              Positioned(
                left: 12,
                bottom: 12,
                child: _buildSolvedBadge(colors, state),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSolvedBadge(SkotiqColors colors, PolarAlignmentState state) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: colors.background.withValues(alpha: 0.85),
        borderRadius: SkotiqTokens.borderRadiusInline4,
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(SkotiqIcons.success, size: 12, color: colors.success),
              const SizedBox(width: 6),
              Text(
                'Plate solved',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize10,
                  fontWeight: FontWeight.w600,
                  color: colors.success,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'RA: ${CoordinateFormat.raReadoutFromDegrees(state.solvedRa!)}',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize11,
              color: colors.textPrimary,
              fontFamily: SkotiqTypography.fontFamilyMono,
            ),
          ),
          Text(
            'Dec: ${CoordinateFormat.decReadout(state.solvedDec!)}',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize11,
              color: colors.textPrimary,
              fontFamily: SkotiqTypography.fontFamilyMono,
            ),
          ),
        ],
      ),
    );
  }

  /// The step card of the adjustment phase: which way to turn each bolt, how
  /// hard, and how far the total is from the auto-complete threshold.
  Widget _buildAdjustCard(
    SkotiqColors colors,
    PolarAlignmentState state,
    PolarAlignmentConfig config,
  ) {
    final error = state.currentError;

    // Direction text - use Left/Right/Up/Down as per UX design. Both point
    // the opposite way from the bullseye marker (the correction direction).
    final azDir = error != null ? error.azimuthAdjustment : kReadoutUnknown;
    final altDir = error != null ? error.altitudeAdjustment : kReadoutUnknown;

    return SkotiqCard(
      key: TourTarget.polarAdjustment.key,
      variant: CardVariant.subtle,
      borderRadius: SkotiqTokens.radiusInline8,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Adjust mount',
            style: SkotiqTypography.h5.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: 20),

          Text(
            'Azimuth',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize11,
              color: colors.textMuted,
            ),
          ),
          const SizedBox(height: 4),
          if (error != null)
            Text(
              '$azDir ${formatPolarError(error.azimuthError.abs())}',
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize22,
                fontWeight: FontWeight.bold,
                color: error.azimuthError.abs() < 30
                    ? colors.success
                    : error.azimuthError.abs() < 60
                        ? colors.warning
                        : colors.error,
              ),
            )
          else
            Text(
              kReadoutUnknown,
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize22,
                fontWeight: FontWeight.bold,
                color: colors.textMuted,
              ),
            ),

          const SizedBox(height: 20),

          Text(
            'Altitude',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize11,
              color: colors.textMuted,
            ),
          ),
          const SizedBox(height: 4),
          if (error != null)
            Text(
              '$altDir ${formatPolarError(error.altitudeError.abs())}',
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize22,
                fontWeight: FontWeight.bold,
                color: error.altitudeError.abs() < 30
                    ? colors.success
                    : error.altitudeError.abs() < 60
                        ? colors.warning
                        : colors.error,
              ),
            )
          else
            Text(
              kReadoutUnknown,
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize22,
                fontWeight: FontWeight.bold,
                color: colors.textMuted,
              ),
            ),

          // How hard to turn, from the total. The total itself is the
          // loud readout under the bullseye; repeating it here, and again
          // with both directions in the settings column, put the same
          // three numbers on screen three times.
          if (error != null) ...[
            const SizedBox(height: SkotiqTokens.spaceLg),
            Divider(color: colors.border),
            const SizedBox(height: SkotiqTokens.spaceMd),
            _buildAdjustmentMagnitude(colors, error),
          ],

          const SizedBox(height: SkotiqTokens.spaceLg),

          Text(
            'Threshold: ${formatPolarError(config.autoCompleteThreshold)}',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize10,
              color: colors.textMuted,
            ),
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: SkotiqTokens.borderRadiusInline4,
            child: LinearProgressIndicator(
              value: error != null
                  ? (1.0 - (error.totalError / 120.0)).clamp(0.0, 1.0)
                  : 0.0,
              backgroundColor: colors.surfaceAlt,
              color: error != null
                  ? (error.totalError < 30
                      ? colors.success
                      : error.totalError < 60
                          ? colors.warning
                          : colors.error)
                  : colors.textMuted,
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 12),

          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: colors.surfaceAlt,
              borderRadius: SkotiqTokens.borderRadiusMd,
            ),
            child: Row(
              children: [
                Icon(
                  SkotiqIcons.target,
                  size: 14,
                  color: error != null &&
                          error.totalError < config.autoCompleteThreshold
                      ? colors.success
                      : colors.textMuted,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    error != null &&
                            error.totalError < config.autoCompleteThreshold
                        ? 'Below threshold!'
                        : 'Adjust to threshold',
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize11,
                      color: error != null &&
                              error.totalError < config.autoCompleteThreshold
                          ? colors.success
                          : colors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
