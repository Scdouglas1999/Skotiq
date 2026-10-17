import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A lightweight, non-interactive overlay that draws concentric angular
/// reference rings centered on the current view center for visual aiming and
/// star-hopping.
///
/// Two ring sets are drawn:
///  * **Telrad** — the three standard Telrad reticle circles at 4°, 2° and 0.5°
///    diameter (the classic 1x reflex finder pattern).
///  * **Finder** — a single optical finder-scope circle (default 5° diameter,
///    typical of a 9x50 finder's true field).
///
/// The rings are specified as angular sizes (degrees of sky) and converted to
/// screen pixels using the same projection scale the sky painter uses, so they
/// stay angularly correct and scale as the user zooms.
///
/// This widget is intended to be wrapped in an [IgnorePointer] at the call
/// site so it never interferes with gestures / hit-testing on the sky view.
class FovRingsOverlay extends StatelessWidget {
  /// Current field of view (vertical/short-axis) in degrees. Drives the
  /// degrees→pixels scale together with the laid-out widget size.
  final double fieldOfView;

  /// View center right ascension in hours. Used only to trigger repaints when
  /// the view changes (the rings themselves are always centered on screen).
  final double centerRA;

  /// View center declination in degrees. Used only to trigger repaints.
  final double centerDec;

  /// Telrad ring diameters in degrees, outermost first.
  static const List<double> telradDiametersDeg = [4.0, 2.0, 0.5];

  /// Optical finder circle diameter in degrees.
  final double finderDiameterDeg;

  /// Ring stroke color.
  final Color color;

  const FovRingsOverlay({
    super.key,
    required this.fieldOfView,
    required this.centerRA,
    required this.centerDec,
    this.finderDiameterDeg = 5.0,
    this.color = const Color(0xFFFF5252),
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _FovRingsPainter(
        fieldOfView: fieldOfView,
        centerRA: centerRA,
        centerDec: centerDec,
        finderDiameterDeg: finderDiameterDeg,
        color: color,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _FovRingsPainter extends CustomPainter {
  final double fieldOfView;
  final double centerRA;
  final double centerDec;
  final double finderDiameterDeg;
  final Color color;

  _FovRingsPainter({
    required this.fieldOfView,
    required this.centerRA,
    required this.centerDec,
    required this.finderDiameterDeg,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (fieldOfView <= 0) return;

    final center = Offset(size.width / 2, size.height / 2);

    // Degrees → pixels. Identical mapping to FOVOverlayPainter and the sky
    // painter: the short screen axis spans `fieldOfView` degrees, so a single
    // degree of sky maps to `min(w, h) / fieldOfView` pixels.
    final scale = math.min(size.width, size.height) / 2 / (fieldOfView / 2);

    final ringPaint = Paint()
      ..color = color.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    // Telrad rings.
    for (final diameterDeg in FovRingsOverlay.telradDiametersDeg) {
      final radius = diameterDeg / 2 * scale;
      canvas.drawCircle(center, radius, ringPaint);
      _drawLabel(
        canvas,
        center + Offset(0, -radius - 7),
        _formatDeg(diameterDeg),
        color,
      );
    }

    // Optical finder circle — drawn dashed-thin and in a slightly cooler tone
    // so it reads as distinct from the Telrad set.
    final finderRadius = finderDiameterDeg / 2 * scale;
    final finderPaint = Paint()
      ..color = color.withValues(alpha: 0.4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    _drawDashedCircle(canvas, center, finderRadius, finderPaint);
    _drawLabel(
      canvas,
      center + Offset(0, finderRadius + 7),
      'Finder ${_formatDeg(finderDiameterDeg)}',
      color,
    );

    // Small center reference dot.
    final dotPaint = Paint()
      ..color = color.withValues(alpha: 0.8)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, 1.5, dotPaint);
  }

  String _formatDeg(double deg) {
    if (deg == deg.roundToDouble()) {
      return '${deg.toStringAsFixed(0)}°';
    }
    return '${deg.toStringAsFixed(1)}°';
  }

  void _drawDashedCircle(
    Canvas canvas,
    Offset center,
    double radius,
    Paint paint,
  ) {
    if (radius <= 0) return;
    const dashCount = 64;
    const dashFraction = 0.6; // portion of each segment that is drawn
    const sweep = 2 * math.pi / dashCount;
    final rect = Rect.fromCircle(center: center, radius: radius);
    for (var i = 0; i < dashCount; i++) {
      final start = i * sweep;
      canvas.drawArc(rect, start, sweep * dashFraction, false, paint);
    }
  }

  void _drawLabel(Canvas canvas, Offset position, String text, Color color) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color.withValues(alpha: 0.85),
          fontSize: 9,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      position - Offset(textPainter.width / 2, textPainter.height / 2),
    );
  }

  @override
  bool shouldRepaint(covariant _FovRingsPainter oldDelegate) {
    return fieldOfView != oldDelegate.fieldOfView ||
        centerRA != oldDelegate.centerRA ||
        centerDec != oldDelegate.centerDec ||
        finderDiameterDeg != oldDelegate.finderDiameterDeg ||
        color != oldDelegate.color;
  }
}
