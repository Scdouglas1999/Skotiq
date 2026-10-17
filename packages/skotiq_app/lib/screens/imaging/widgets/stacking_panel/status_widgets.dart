part of '../stacking_panel.dart';

class _ErrorBanner extends StatelessWidget {
  final String message;
  final SkotiqColors colors;
  final VoidCallback? onRetry;

  const _ErrorBanner({
    required this.message,
    required this.colors,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceLg),
      child: SkotiqBanner(
        title: 'Live stacking needs attention',
        message: message,
        tone: BannerTone.error,
        action: onRetry == null
            ? null
            : SkotiqButton(
                label: 'Retry preview',
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                onPressed: onRetry,
              ),
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  final SkotiqColors colors;

  const _StatRow({
    required this.label,
    required this.value,
    this.valueColor,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return KeyValueList(rows: [(label, value)]);
  }
}

/// Caption + rule that separates one unit of measure from another inside the
/// Statistics list (frame counts above, pixel counts below).
class _StatGroupHeader extends StatelessWidget {
  final String label;
  final SkotiqColors colors;

  const _StatGroupHeader({
    required this.label,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: SkotiqTokens.spaceMd),
        Container(height: 1, color: colors.border),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            label.toUpperCase(),
            style: SkotiqTypography.caption.copyWith(
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
                color: colors.textMuted),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// Inline warning shown when the sigma-clipper rejected an unusually high
/// fraction of pixels on the most recent frame. The Rust engine accumulates
/// rejections silently; surfacing it here lets the observer react (refocus,
/// fix tracking, abandon the frame) instead of finding out hours later.
class _RejectionWarning extends StatelessWidget {
  final double rate;
  final SkotiqColors colors;

  const _RejectionWarning({
    required this.rate,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final isError = rate >= _rejectionErrorThreshold;
    final accent = isError ? colors.error : colors.warning;
    final label = isError
        ? 'Very high sigma rejection on last frame'
        : 'Elevated sigma rejection on last frame';
    final detail = isError
        ? 'Above ${(_rejectionErrorThreshold * 100).toStringAsFixed(0)}% rejected -- '
            'check for clouds, drift, or a satellite trail.'
        : 'Above ${(_rejectionWarningThreshold * 100).toStringAsFixed(0)}% rejected -- '
            'seeing, dithering, or alignment may be off.';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: SkotiqDecorations.emphasisSurface(
        accent,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isError ? SkotiqIcons.critical : SkotiqIcons.warning,
            size: 14,
            color: accent,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: SkotiqTypography.labelStrongSm.copyWith(color: accent),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: SkotiqTypography.caption
                      .copyWith(color: colors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Visual indicator of alignment quality based on stacking statistics.
class _AlignmentQualityBar extends StatelessWidget {
  final LiveStackingStats stats;
  final SkotiqColors colors;

  const _AlignmentQualityBar({
    required this.stats,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    // Calculate quality from rejection ratio and alignment residual.
    // Quality = 1.0 means perfect, 0.0 means all frames rejected.
    double quality;
    String qualityLabel;
    Color qualityColor;

    if (stats.totalFramesAttempted == 0) {
      quality = 0.0;
      qualityLabel = 'No data';
      qualityColor = colors.textMuted;
    } else {
      final acceptanceRate =
          stats.stackedFrameCount / stats.totalFramesAttempted;
      // Residual penalty: >2px is poor, <0.5px is great
      final residualPenalty =
          (stats.avgAlignmentResidual / 2.0).clamp(0.0, 1.0);
      quality =
          (acceptanceRate * (1.0 - residualPenalty * 0.3)).clamp(0.0, 1.0);

      if (quality >= 0.8) {
        qualityLabel = 'Excellent';
        qualityColor = colors.success;
      } else if (quality >= 0.6) {
        qualityLabel = 'Good';
        qualityColor = colors.primary;
      } else if (quality >= 0.4) {
        qualityLabel = 'Fair';
        qualityColor = colors.warning;
      } else {
        qualityLabel = 'Poor';
        qualityColor = colors.error;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Alignment quality',
                style: SkotiqTypography.caption
                    .copyWith(color: colors.textSecondary)),
            Text(qualityLabel,
                style: SkotiqTypography.labelStrongSm
                    .copyWith(color: qualityColor)),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
          child: LinearProgressIndicator(
            value: quality,
            minHeight: 6,
            backgroundColor: colors.border,
            valueColor: AlwaysStoppedAnimation<Color>(qualityColor),
          ),
        ),
      ],
    );
  }
}
