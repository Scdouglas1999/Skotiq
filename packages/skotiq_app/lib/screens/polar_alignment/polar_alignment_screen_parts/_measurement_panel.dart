// ignore_for_file: unused_element

part of '../polar_alignment_screen.dart';

/// Which measurement point the published status is talking about.
///
/// `state.currentPoint` is the point that has been MEASURED — the run only
/// advances it once the next point's frame is in hand — so during a move it
/// still reads the point behind, while the status text names the destination.
/// When the status names a point, that number wins.
int _effectiveRunPoint(String status, int point) {
  final match = RegExp(r'point\s+(\d+)', caseSensitive: false).firstMatch(
    status,
  );
  final named = match == null ? null : int.tryParse(match.group(1)!);
  if (named == null || named < 1 || named > 3) return point;
  return named;
}

/// The activity line beside the spinner in the measuring panel.
///
/// Derived from the status the run publishes, so the two lines on the panel
/// cannot disagree. A fixed "Capturing Point N" spans the plate solve that
/// follows the exposure and goes minutes stale.
String _runActivityLabel(String status, int point) {
  final phrase = status.toLowerCase();
  final at = _effectiveRunPoint(status, point);
  if (phrase.contains('solv')) return 'Plate solving point $at of 3';
  if (phrase.contains('slew')) return 'Slewing to point $at of 3';
  if (phrase.contains('rotat')) return 'Rotating to point $at of 3';
  if (phrase.contains('captur') || phrase.contains('expos')) {
    return 'Capturing point $at of 3';
  }
  return 'Point $at of 3';
}

extension _MeasurementPanel on _PolarAlignmentScreenState {
  Widget _buildMeasuringStatus(SkotiqColors colors, PolarAlignmentState state) {
    final status = state.statusMessage;
    // One number for the whole panel: the progress list and the activity line
    // are describing the same instant, so they resolve the point the same way.
    final point = _effectiveRunPoint(status, state.currentPoint);

    return LayoutBuilder(
      builder: (context, constraints) {
        // Below ~520px the image + fixed side panel get too tight, so stack
        // the image above the progress panel in a phone column.
        // The center panel is vertically scrollable, so active content often
        // receives an unbounded height even on a wide viewport. A stretched
        // Row cannot lay out under that constraint; stack in that case and let
        // the scroll view own the vertical extent.
        final stack =
            constraints.maxWidth < 520 || !constraints.hasBoundedHeight;

        final imageArea = Container(
          key: PolarAlignmentTutorialKeys.imageView,
          decoration: BoxDecoration(
            color: colors.surfaceAlt,
            borderRadius: SkotiqTokens.borderRadiusInline8,
            border: Border.all(color: colors.border),
          ),
          child: Stack(
            children: [
              // Image display
              if (state.hasImage)
                Center(
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
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 60,
                        height: 60,
                        child: const SkotiqMark(
                            motion: SkotiqMarkMotion.loading, size: 60),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Waiting for image...',
                        style: TextStyle(
                          fontSize: SkotiqTypography.fontSize12,
                          color: colors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),

              // Solve coordinates overlay
              if (state.solvedRa != null && state.solvedDec != null)
                Positioned(
                  left: 12,
                  bottom: 12,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
                            Icon(SkotiqIcons.success,
                                size: 12, color: colors.success),
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
                          'RA: ${_formatRA(state.solvedRa!)}',
                          style: TextStyle(
                            fontSize: SkotiqTypography.fontSize11,
                            color: colors.textPrimary,
                            fontFamily: 'monospace',
                          ),
                        ),
                        Text(
                          'Dec: ${_formatDec(state.solvedDec!)}',
                          style: TextStyle(
                            fontSize: SkotiqTypography.fontSize11,
                            color: colors.textPrimary,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );

        final progressPanel = SkotiqCard(
          variant: CardVariant.subtle,
          borderRadius: SkotiqTokens.radiusInline8,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: stack ? MainAxisSize.min : MainAxisSize.max,
            children: [
              Text(
                'Progress',
                style: SkotiqTypography.h6.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: 16),
              _MeasurementProgressItem(
                colors: colors,
                label: 'Point 1',
                isActive: point == 1,
                isComplete: point > 1,
              ),
              const SizedBox(height: 8),
              _MeasurementProgressItem(
                colors: colors,
                label: 'Point 2',
                isActive: point == 2,
                isComplete: point > 2,
              ),
              const SizedBox(height: 8),
              _MeasurementProgressItem(
                colors: colors,
                label: 'Point 3',
                isActive: point == 3,
                isComplete: point > 3,
              ),
              const SizedBox(height: 24),
              Text(
                'Status',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  color: colors.textMuted,
                ),
              ),
              const SizedBox(height: 6),

              // Task 4.4: Solve progress indicator with timer
              if (status.toLowerCase().contains('solv'))
                _SolveProgressIndicator(colors: colors, status: status)
              else
                Text(
                  status,
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize12,
                    color: colors.textSecondary,
                  ),
                ),

              if (!stack) const Spacer() else const SizedBox(height: 16),
              // Mount activity indicator
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
                        _runActivityLabel(status, point),
                        style: TextStyle(
                          fontSize: SkotiqTypography.fontSize11,
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );

        if (stack) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Give the image a generous square-ish area then let the
                // progress panel flow beneath it.
                AspectRatio(aspectRatio: 4 / 3, child: imageArea),
                const SizedBox(height: 16),
                progressPanel,
              ],
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 2, child: imageArea),
              const SizedBox(width: 16),
              SizedBox(width: 180, child: progressPanel),
            ],
          ),
        );
      },
    );
  }

  String _formatRA(double degrees) => CoordinateFormat.ra(degrees / 15.0);

  String _formatDec(double degrees) {
    final sign = degrees >= 0 ? '+' : '-';
    final abs = degrees.abs();
    final d = abs.floor();
    final m = ((abs - d) * 60).floor();
    final s = (((abs - d) * 60 - m) * 60).toStringAsFixed(0);
    return '$sign${d.toString().padLeft(2, '0')}° ${m.toString().padLeft(2, '0')}\' $s"';
  }

  Widget _buildAdjustmentInstructions(
    SkotiqColors colors,
    PolarAlignmentState state,
    PolarAlignmentConfig config,
  ) {
    final error = state.currentError;

    // Direction text - use Left/Right/Up/Down as per UX design. Both point
    // the opposite way from the bullseye marker (the correction direction).
    final azDir = error != null ? error.azimuthAdjustment : kReadoutUnknown;
    final altDir = error != null ? error.altitudeAdjustment : kReadoutUnknown;

    return LayoutBuilder(
      builder: (context, constraints) {
        // See the measuring panel above: the surrounding active-state scroll
        // view supplies unbounded height, which makes a stretched Row invalid.
        final stack =
            constraints.maxWidth < 520 || !constraints.hasBoundedHeight;

        final imageArea = Container(
          decoration: BoxDecoration(
            color: colors.surfaceAlt,
            borderRadius: SkotiqTokens.borderRadiusInline8,
            border: Border.all(color: colors.border),
          ),
          child: Stack(
            children: [
              // Live image
              if (state.hasImage)
                Center(
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
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 60,
                        height: 60,
                        child: const SkotiqMark(
                            motion: SkotiqMarkMotion.loading, size: 60),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Capturing adjustment image...',
                        style: TextStyle(
                          fontSize: SkotiqTypography.fontSize12,
                          color: colors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),

              // Bullseye overlay
              Positioned.fill(
                child: CustomPaint(
                  painter: _BullseyeOverlayPainter(
                    colors: colors,
                    azimuthError: error?.azimuthError,
                    altitudeError: error?.altitudeError,
                  ),
                ),
              ),
            ],
          ),
        );

        final directionPanel = SkotiqCard(
          key: PolarAlignmentTutorialKeys.adjustment,
          variant: CardVariant.subtle,
          borderRadius: SkotiqTokens.radiusInline8,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: stack ? MainAxisSize.min : MainAxisSize.max,
            children: [
              Text(
                'Adjust mount',
                style: SkotiqTypography.h5.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: 20),

              // Azimuth direction
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

              // Altitude direction
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

              const SizedBox(height: 24),
              Divider(color: colors.border),
              const SizedBox(height: 16),

              // Total error
              Text(
                'Total error',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  color: colors.textMuted,
                ),
              ),
              const SizedBox(height: 4),
              if (error != null)
                Text(
                  formatPolarError(error.totalError),
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize28,
                    fontWeight: FontWeight.bold,
                    color: error.totalError < 30
                        ? colors.success
                        : error.totalError < 60
                            ? colors.warning
                            : colors.error,
                  ),
                )
              else
                Text(
                  kReadoutUnknown,
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize28,
                    fontWeight: FontWeight.bold,
                    color: colors.textMuted,
                  ),
                ),

              if (!stack) const Spacer() else const SizedBox(height: 20),

              // Progress toward threshold
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

              // Auto-complete indicator
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
                                  error.totalError <
                                      config.autoCompleteThreshold
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

        if (stack) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AspectRatio(aspectRatio: 4 / 3, child: imageArea),
                const SizedBox(height: 16),
                directionPanel,
              ],
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 2, child: imageArea),
              const SizedBox(width: 16),
              SizedBox(width: 200, child: directionPanel),
            ],
          ),
        );
      },
    );
  }

  /// Task 4.3: Before/After Summary Card
}
