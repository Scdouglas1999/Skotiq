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
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: Colors.white70),
          const SizedBox(width: 6),
          Text(
            label,
            style: SkotiqTypography.caption.copyWith(color: Colors.white70),
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

class ExposureProgressOverlay extends StatelessWidget {
  final ExposureProgress progress;
  final SkotiqColors colors;

  /// The operator has asked for this exposure to stop and the abort is in
  /// flight.
  ///
  /// The countdown MUST stop here. `ExposureProgress` keeps ticking after a
  /// cancel — the native waiter goes on publishing progress until the driver
  /// reports not-exposing or the duration deadline passes — so a running ring
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
    final progressValue = (progress.percent / 100.0).clamp(0.0, 1.0);

    return Container(
      // absolute: exposure progress scrim over the live image canvas
      color: Colors.black.withValues(alpha: 0.7),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 80,
              height: 80,
              child: Stack(
                children: [
                  isAborting
                      ? const SkotiqMark(
                          motion: SkotiqMarkMotion.loading, size: 80)
                      : CircularProgressIndicator(
                          value: progressValue,
                          strokeWidth: 4,
                          backgroundColor: colors.surfaceAlt,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(colors.primary),
                        ),
                  if (!isAborting)
                    Center(
                      child: Text(
                        '${progress.percent.toStringAsFixed(0)}%',
                        style: SkotiqTypography.sectionTitle
                            .copyWith(color: colors.primary),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              statusText,
              style: SkotiqTypography.bodyStrong.copyWith(
                  // absolute: status label over the live image canvas
                  color: Colors.white),
            ),
            const SizedBox(height: 4),
            if (!isAborting && !progress.isDownloading)
              Text(
                '${progress.remaining.toStringAsFixed(1)}s remaining',
                style: SkotiqTypography.caption.copyWith(
                    // absolute: remaining-time label over the live image canvas
                    color: Colors.white70),
              ),
            if (progress.totalFrames != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Frame ${progress.frameNumber} of ${progress.totalFrames}',
                  style: SkotiqTypography.caption.copyWith(
                      // absolute: frame-count label over the live image canvas
                      color: Colors.white54),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
