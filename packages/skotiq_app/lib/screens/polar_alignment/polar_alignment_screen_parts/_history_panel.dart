// ignore_for_file: unused_element

part of '../polar_alignment_screen.dart';

/// How a persisted run must be presented in Alignment History.
///
/// A row is written for every terminal run — including one the operator
/// cancelled — so "there is a row" is not evidence of anything. Only the
/// residual against the threshold that run was configured with says whether the
/// polar axis actually got where the operator asked.
enum PolarAlignmentHistoryOutcome { reachedTarget, stopped }

/// Threshold (arcsec) the run was configured with, read back from the stored
/// config. Falls back to the model default when the JSON is unreadable — an
/// unparseable config must not be allowed to grade a row as a success.
double polarAlignmentHistoryThreshold(String configJson) {
  try {
    final decoded = jsonDecode(configJson);
    if (decoded is Map<String, dynamic>) {
      final value = decoded['autoCompleteThreshold'];
      if (value is num) return value.toDouble();
    }
  } on FormatException {
    // fall through to the default below
  }
  return const PolarAlignmentConfig().autoCompleteThreshold;
}

/// Grade a history row.
///
/// The measured final error determines the outcome; `autoCompleted` only says
/// who ended the run.
PolarAlignmentHistoryOutcome polarAlignmentHistoryOutcome({
  required double finalTotalError,
  required String configJson,
}) {
  return finalTotalError <= polarAlignmentHistoryThreshold(configJson)
      ? PolarAlignmentHistoryOutcome.reachedTarget
      : PolarAlignmentHistoryOutcome.stopped;
}

extension _HistoryPanel on _PolarAlignmentScreenState {
  Widget _buildAdjustmentTips(SkotiqColors colors) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: SkotiqTokens.borderRadiusInline8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TipItem(colors: colors, text: 'Make small adjustments'),
          _TipItem(colors: colors, text: 'Watch the error decrease'),
          _TipItem(colors: colors, text: 'Target < 1 arcmin for best results'),
          _TipItem(colors: colors, text: 'Click Done when satisfied'),
        ],
      ),
    );
  }

  /// Task 4.2: Adjustment magnitude guidance widget
  Widget _buildAdjustmentGuidance(
      SkotiqColors colors, PolarAlignmentError error) {
    // Calculate magnitude categories based on total error in arcseconds
    final totalArcsec = error.totalError;

    // Determine adjustment magnitude
    String magnitudeText;
    String adjustmentHint;
    Color magnitudeColor;
    IconData magnitudeIcon;

    if (totalArcsec < 10) {
      magnitudeText = 'Micro adjustments';
      adjustmentHint = 'Barely touch the knobs';
      magnitudeColor = colors.success;
      magnitudeIcon = SkotiqIcons.success;
    } else if (totalArcsec < 30) {
      magnitudeText = '1/8 turn';
      adjustmentHint = 'Very small movements';
      magnitudeColor = colors.success;
      magnitudeIcon = SkotiqIcons.arrowRight;
    } else if (totalArcsec < 60) {
      magnitudeText = '1/4 turn';
      adjustmentHint = 'Small, careful movements';
      magnitudeColor = colors.info;
      magnitudeIcon = SkotiqIcons.arrowRight;
    } else if (totalArcsec < 120) {
      magnitudeText = '1/2 turn';
      adjustmentHint = 'Medium adjustments';
      magnitudeColor = colors.warning;
      magnitudeIcon = LucideIcons.alertCircle;
    } else {
      magnitudeText = 'Large adjustments';
      adjustmentHint = 'Significant correction needed';
      magnitudeColor = colors.error;
      magnitudeIcon = SkotiqIcons.warning;
    }

    // Direction indicators
    final azDirection = error.azimuthAdjustment;
    final altDirection = error.altitudeAdjustment;
    final azMagnitude = error.azimuthError.abs();
    final altMagnitude = error.altitudeError.abs();

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: SkotiqDecorations.emphasisSurface(
        magnitudeColor,
        borderRadius: SkotiqTokens.borderRadiusInline8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(magnitudeIcon, size: 16, color: magnitudeColor),
              const SizedBox(width: 8),
              Text(
                magnitudeText,
                style: SkotiqTypography.h6.copyWith(color: magnitudeColor),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            adjustmentHint,
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize11,
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          // Azimuth direction
          if (azMagnitude > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Icon(
                    error.azimuthError > 0
                        ? SkotiqIcons.arrowLeft
                        : SkotiqIcons.arrowRight,
                    size: 12,
                    color: _getErrorMagnitudeColor(colors, azMagnitude),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Azimuth: $azDirection ${formatPolarError(azMagnitude)}',
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize11,
                        color: _getErrorMagnitudeColor(colors, azMagnitude),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          // Altitude direction
          if (altMagnitude > 1)
            Row(
              children: [
                Icon(
                  error.altitudeError > 0
                      ? SkotiqIcons.arrowDown
                      : SkotiqIcons.arrowUp,
                  size: 12,
                  color: _getErrorMagnitudeColor(colors, altMagnitude),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Altitude: $altDirection ${formatPolarError(altMagnitude)}',
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize11,
                      color: _getErrorMagnitudeColor(colors, altMagnitude),
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Color _getErrorMagnitudeColor(SkotiqColors colors, double arcsec) {
    if (arcsec < 10) return colors.success;
    if (arcsec < 30) return colors.info;
    if (arcsec < 60) return colors.warning;
    return colors.error;
  }

  /// History panel.
  ///
  /// Reads the STREAMING history provider
  /// (`polarAlignmentHistoryStreamProvider`) so a new run appears as soon as it
  /// completes; a one-shot Future here stays stale until the screen rebuilds.
  Widget _buildHistoryPanel(SkotiqColors colors) {
    final profileId = ref.watch(activeEquipmentProfileProvider)?.id;
    final historyAsync =
        ref.watch(polarAlignmentHistoryStreamProvider(profileId));

    return SkotiqCard(
      variant: CardVariant.standard,
      borderRadius: SkotiqTokens.radiusInline8,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(SkotiqIcons.history, size: 14, color: colors.textMuted),
              const SizedBox(width: 8),
              Text(
                'Alignment history',
                style: SkotiqTypography.h6.copyWith(color: colors.textPrimary),
              ),
            ],
          ),
          const SizedBox(height: 12),
          historyAsync.when(
            data: (history) {
              if (history.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Center(
                    child: Text(
                      'No alignment history yet',
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize11,
                        color: colors.textMuted,
                      ),
                    ),
                  ),
                );
              }

              return Column(
                children: history.take(5).map((entry) {
                  final improvementPercent = entry.initialTotalError > 0
                      ? ((entry.initialTotalError - entry.finalTotalError) /
                              entry.initialTotalError *
                              100)
                          .clamp(0.0, 100.0)
                      : 0.0;
                  final outcome = polarAlignmentHistoryOutcome(
                    finalTotalError: entry.finalTotalError,
                    configJson: entry.configJson,
                  );
                  final reachedTarget =
                      outcome == PolarAlignmentHistoryOutcome.reachedTarget;

                  final dateStr = _formatDate(entry.completedAt);

                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: colors.surface,
                      borderRadius: SkotiqTokens.borderRadiusMd,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          reachedTarget
                              ? SkotiqIcons.target
                              : LucideIcons.circleSlash,
                          size: 14,
                          color:
                              reachedTarget ? colors.success : colors.textMuted,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                dateStr,
                                style: TextStyle(
                                  fontSize: SkotiqTypography.fontSize10,
                                  color: colors.textMuted,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Final: ${formatPolarError(entry.finalTotalError)}',
                                style: SkotiqTypography.labelQuiet
                                    .copyWith(color: colors.textPrimary),
                              ),
                            ],
                          ),
                        ),
                        // A stopped run gets the word "Stopped", not a
                        // percentage: its "improvement" is the difference
                        // between two solves of an axis nobody touched, i.e.
                        // measurement noise dressed up as an achievement.
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: SkotiqDecorations.tintedBadge(
                            reachedTarget ? colors.success : colors.textMuted,
                            borderRadius: SkotiqTokens.borderRadiusInline4,
                          ),
                          child: Text(
                            reachedTarget
                                ? '+${improvementPercent.toStringAsFixed(0)}%'
                                : 'Stopped',
                            style: TextStyle(
                              fontSize: SkotiqTypography.fontSize10,
                              fontWeight: FontWeight.w600,
                              color: reachedTarget
                                  ? colors.success
                                  : colors.textMuted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              );
            },
            loading: () => const Center(
              child: const Padding(
                padding: const EdgeInsets.all(16),
                child: const SizedBox(
                  width: 20,
                  height: 20,
                  child: const SkotiqMark(
                      motion: SkotiqMarkMotion.loading, size: 20),
                ),
              ),
            ),
            error: (error, stack) => Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Failed to load history: $error',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  color: colors.error,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inDays == 0) {
      return 'Today ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    } else if (diff.inDays == 1) {
      return 'Yesterday';
    } else if (diff.inDays < 7) {
      return '${diff.inDays} days ago';
    } else {
      return '${date.month}/${date.day}/${date.year}';
    }
  }
}
