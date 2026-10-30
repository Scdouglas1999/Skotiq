import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';

class OverlayChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final SkotiqColors colors;

  const OverlayChip({
    super.key,
    required this.icon,
    required this.label,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      // absolute: HUD chip drawn over the live image canvas
      decoration: BoxDecoration(
        color: ImageOverlayColors.shadow.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
        border: Border.all(
            color: ImageOverlayColors.foreground.withValues(alpha: 0.1)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: ImageOverlayColors.secondary),
          const SizedBox(width: 6),
          Text(
            label,
            style: SkotiqTypography.caption
                .copyWith(color: ImageOverlayColors.secondary),
          ),
        ],
      ),
    );
  }
}

class HistogramPainter extends CustomPainter {
  final List<int> histogram;
  final Color color;

  HistogramPainter({required this.histogram, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (histogram.isEmpty) return;

    final maxVal = histogram.reduce((a, b) => a > b ? a : b);
    if (maxVal == 0) return;

    final paint = Paint()
      ..color = color.withValues(alpha: 0.7)
      ..style = PaintingStyle.fill;

    final barWidth = size.width / histogram.length;

    for (int i = 0; i < histogram.length; i++) {
      final barHeight = (histogram[i] / maxVal) * size.height;
      canvas.drawRect(
        Rect.fromLTWH(
          i * barWidth,
          size.height - barHeight,
          barWidth,
          barHeight,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant HistogramPainter oldDelegate) {
    return histogram != oldDelegate.histogram;
  }
}

/// Exposure progress drawn AROUND the frame on screen, never over it.
///
/// A looping operator watches each frame while the next one exposes, so the
/// canvas keeps showing the last image: progress is a thin line along the top
/// edge and one compact pill at the top centre, and neither takes the pointer.
/// (This used to be a 70% black scrim with a ring, which hid every frame of a
/// loop for the whole of the next exposure.)
class ExposureProgressOverlay extends StatelessWidget {
  final ExposureProgress progress;
  final SkotiqColors colors;

  /// The operator has asked for this exposure to stop and the abort is in
  /// flight.
  ///
  /// The countdown MUST stop here. `ExposureProgress` keeps ticking after a
  /// cancel — the native waiter goes on publishing progress until the driver
  /// reports not-exposing or the duration deadline passes — so a running bar
  /// counts down to a frame that will never arrive. Nothing is known about how
  /// long the driver takes to honour an abort, so this state is indeterminate
  /// by construction.
  final bool isAborting;

  const ExposureProgressOverlay({
    super.key,
    required this.progress,
    required this.colors,
    this.isAborting = false,
  });

  @override
  Widget build(BuildContext context) {
    final statusText = isAborting
        ? 'Stopping exposure...'
        : (progress.isDownloading ? 'Downloading...' : 'Exposing...');
    final indeterminate = isAborting || progress.isDownloading;
    final progressValue = (progress.percent / 100.0).clamp(0.0, 1.0);
    final muted =
        SkotiqTypography.caption.copyWith(color: colors.textSecondary);

    return IgnorePointer(
      child: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(
              value: indeterminate ? null : progressValue,
              minHeight: 3,
              backgroundColor: Colors.transparent,
              valueColor: AlwaysStoppedAnimation<Color>(colors.primary),
            ),
          ),
          Positioned(
            top: SkotiqTokens.spaceMd,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: SkotiqTokens.spaceMd,
                  vertical: SkotiqTokens.spaceXs,
                ),
                decoration: BoxDecoration(
                  color: colors.surfaceOverlay.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(SkotiqTokens.radiusFull),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (indeterminate) ...[
                      SkotiqSpinner(size: 12, color: colors.primary),
                      const SizedBox(width: SkotiqTokens.spaceSm),
                    ],
                    Text(
                      statusText,
                      style: SkotiqTypography.caption.copyWith(
                        color: colors.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (!indeterminate) ...[
                      Text('  ·  ', style: muted),
                      Text(
                        '${progress.remaining.toStringAsFixed(1)}s remaining',
                        style: muted,
                      ),
                    ],
                    if (progress.totalFrames != null) ...[
                      Text('  ·  ', style: muted),
                      Text(
                        'Frame ${progress.frameNumber} of ${progress.totalFrames}',
                        style: muted,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
