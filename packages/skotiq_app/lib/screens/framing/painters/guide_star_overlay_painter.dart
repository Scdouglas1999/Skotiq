import 'package:flutter/material.dart';
// The pure guide-star finder result type lives in skotiq_core's models
// layer alongside the shared framing projection it is built on, and is not
// surfaced through the public barrel (an app->core src-model type, the same
// convention the framing painters and canvas use for FramingPlateScale /
// FramingSkyProjection).
// ignore: implementation_imports
import 'package:skotiq_core/src/models/framing_guide_star.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Marks candidate guide stars on the framing canvas.
///
/// Each [GuideStarCandidate] already carries its on-canvas projection
/// ([GuideStarCandidate.screenPosition]), computed through the SAME
/// [FramingSkyProjection] the survey background and FOV reticle register
/// through, so the markers land on the imagery to the pixel under any
/// pan / zoom / rotation. The painter only draws — selection and projection are
/// the pure core's job ([findGuideStarCandidates]).
///
/// A marker is a hollow ring (so the star underneath stays visible) with a small
/// magnitude label, sized inversely to brightness so the brightest, most usable
/// guide stars read largest. Everything is tinted from the design-system
/// [SkotiqColors] — no raw colors.
class GuideStarOverlayPainter extends CustomPainter {
  final List<GuideStarCandidate> candidates;
  final SkotiqColors colors;

  GuideStarOverlayPainter({
    required this.candidates,
    required this.colors,
  });

  /// Maps a magnitude onto a marker radius: brighter (smaller magnitude) ->
  /// larger ring. Clamped so even faint candidates stay tappable-sized and the
  /// brightest do not dominate.
  double _radiusForMagnitude(double magnitude) {
    // V ~ 2 -> ~11px, V ~ 10 -> ~5px.
    final r = 12.0 - magnitude * 0.7;
    return r.clamp(5.0, 12.0);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final ringPaint = Paint()
      ..color = colors.success
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    final tickPaint = Paint()
      ..color = colors.success.withValues(alpha: SkotiqTokens.opacityStrong)
      ..strokeWidth = 1.0;

    for (final star in candidates) {
      final center = star.screenPosition;
      // Skip anything that projected outside the painted box (e.g. a candidate
      // whose marker would clip the canvas edge); the FOV-inside test is in sky
      // space so a hair of slack at the border is possible.
      if (!center.dx.isFinite || !center.dy.isFinite) continue;

      final radius = _radiusForMagnitude(star.magnitude);

      // Hollow ring so the underlying star image stays visible.
      canvas.drawCircle(center, radius, ringPaint);

      // Reticle ticks at the four cardinal points read as a guide-star "lock".
      const gap = 2.0;
      const tickLen = 4.0;
      canvas.drawLine(
        Offset(center.dx, center.dy - radius - gap),
        Offset(center.dx, center.dy - radius - gap - tickLen),
        tickPaint,
      );
      canvas.drawLine(
        Offset(center.dx, center.dy + radius + gap),
        Offset(center.dx, center.dy + radius + gap + tickLen),
        tickPaint,
      );
      canvas.drawLine(
        Offset(center.dx - radius - gap, center.dy),
        Offset(center.dx - radius - gap - tickLen, center.dy),
        tickPaint,
      );
      canvas.drawLine(
        Offset(center.dx + radius + gap, center.dy),
        Offset(center.dx + radius + gap + tickLen, center.dy),
        tickPaint,
      );

      // Magnitude label, offset down-right of the marker.
      final label = TextPainter(
        text: TextSpan(
          text: star.magnitude.toStringAsFixed(1),
          style: SkotiqTypography.overline.copyWith(color: colors.success),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(
        canvas,
        Offset(center.dx + radius + 6, center.dy + radius / 2),
      );
    }
  }

  @override
  bool shouldRepaint(covariant GuideStarOverlayPainter oldDelegate) {
    return colors != oldDelegate.colors ||
        !_sameCandidates(oldDelegate.candidates);
  }

  bool _sameCandidates(List<GuideStarCandidate> other) {
    if (candidates.length != other.length) return false;
    for (var i = 0; i < candidates.length; i++) {
      if (candidates[i] != other[i]) return false;
    }
    return true;
  }
}
