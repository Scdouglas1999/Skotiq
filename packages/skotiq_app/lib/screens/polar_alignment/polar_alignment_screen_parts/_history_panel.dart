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

  /// How large a turn the current total error calls for, as a heading and a
  /// one-line hint, in the error's colour.
  Widget _buildAdjustmentMagnitude(
      SkotiqColors colors, PolarAlignmentError error) {
    final totalArcsec = error.totalError;
    final (String magnitudeText, String adjustmentHint, Color magnitudeColor) =
        totalArcsec < 10
            ? ('Micro adjustments', 'Barely touch the knobs', colors.success)
            : totalArcsec < 30
                ? ('1/8 turn', 'Very small movements', colors.success)
                : totalArcsec < 60
                    ? ('1/4 turn', 'Small, careful movements', colors.info)
                    : totalArcsec < 120
                        ? ('1/2 turn', 'Medium adjustments', colors.warning)
                        : (
                            'Large adjustments',
                            'Significant correction needed',
                            colors.error,
                          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          magnitudeText,
          style: SkotiqTypography.bodyStrong.copyWith(color: magnitudeColor),
        ),
        Text(
          adjustmentHint,
          style: SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
        ),
      ],
    );
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
