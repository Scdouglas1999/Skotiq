// RA against Dec error for the recent guide steps, in pixels: a dot per step
// around the lock position, the newest one ringed.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../data/session/guide_series_provider.dart';

/// How many of the newest samples the plot draws.
const int kGuideScatterSamples = 200;

/// The plot's half-width in px: the smallest of these that holds every dot.
const List<double> _scales = <double>[0.5, 1, 2, 4, 8, 16];

class NightGuideScatter extends StatelessWidget {
  const NightGuideScatter({
    super.key,
    required this.samples,
    required this.semanticLabel,
  });

  /// Oldest first.
  final List<NightGuideSample> samples;
  final String semanticLabel;

  /// The half-width the plot uses for [samples].
  static double scaleFor(List<NightGuideSample> samples) {
    var worst = 0.0;
    for (final s in samples) {
      worst = math.max(worst, math.max(s.raPx.abs(), s.decPx.abs()));
    }
    return _scales.firstWhere((scale) => worst <= scale,
        orElse: () => _scales.last);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final recent = samples.length > kGuideScatterSamples
        ? samples.sublist(samples.length - kGuideScatterSamples)
        : samples;
    final scale = scaleFor(recent);
    return Semantics(
      label: semanticLabel,
      image: true,
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.well,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _ScatterPainter(
                  samples: recent,
                  scale: scale,
                  axis: colors.border,
                  ring: colors.borderHighlight,
                  dot: SkotiqChartColors.forTheme(
                    SkotiqChartColors.seriesBlue,
                    colors,
                  ),
                  newest: colors.primary,
                ),
              ),
            ),
            Positioned(
              right: 4,
              bottom: 2,
              child: Text(
                '±${_scaleLabel(scale)} px',
                style: SkotiqTypography.captionSm
                    .copyWith(color: colors.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _scaleLabel(double scale) => scale == scale.roundToDouble()
      ? scale.toInt().toString()
      : scale.toString();
}

class _ScatterPainter extends CustomPainter {
  _ScatterPainter({
    required this.samples,
    required this.scale,
    required this.axis,
    required this.ring,
    required this.dot,
    required this.newest,
  });

  final List<NightGuideSample> samples;
  final double scale;
  final Color axis;
  final Color ring;
  final Color dot;
  final Color newest;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) / 2 - 4;
    final axisPaint = Paint()
      ..color = axis
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(center.dx - radius, center.dy),
      Offset(center.dx + radius, center.dy),
      axisPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - radius),
      Offset(center.dx, center.dy + radius),
      axisPaint,
    );
    canvas.drawCircle(
      center,
      radius / 2,
      Paint()
        ..color = ring
        ..style = PaintingStyle.stroke,
    );

    Offset at(NightGuideSample s) => Offset(
          center.dx + (s.raPx / scale).clamp(-1.0, 1.0) * radius,
          // Dec north up.
          center.dy - (s.decPx / scale).clamp(-1.0, 1.0) * radius,
        );

    final dotPaint = Paint()..color = dot.withValues(alpha: 0.7);
    for (final s in samples) {
      canvas.drawCircle(at(s), 1.6, dotPaint);
    }
    if (samples.isNotEmpty) {
      canvas.drawCircle(
        at(samples.last),
        3.2,
        Paint()
          ..color = newest
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(_ScatterPainter old) =>
      !identical(old.samples, samples) ||
      old.scale != scale ||
      old.axis != axis ||
      old.dot != dot ||
      old.newest != newest ||
      old.ring != ring;
}
