part of '../overlay_painters.dart';

class ProjectedMovingTrack {
  final double imageX;
  final double imageY;
  final double positionAngleDegrees;
  final double motionArcsecPerMinute;
  final double confidence;

  const ProjectedMovingTrack({
    required this.imageX,
    required this.imageY,
    required this.positionAngleDegrees,
    required this.motionArcsecPerMinute,
    required this.confidence,
  });
}

/// Moving-track confidence ramp: a weak candidate.
@visibleForTesting
const Color namedTrackLowConfidence = Color(0xFFF59E0B);

/// Moving-track confidence ramp: a confident detection.
@visibleForTesting
const Color namedTrackHighConfidence = Color(0xFF22C55E);

class ScienceMovingTrackOverlayPainter extends CustomPainter {
  final List<ProjectedMovingTrack> tracks;
  final Offset imageOffset;
  final double zoomLevel;

  /// Confidence-ramp endpoints resolved for the active theme at construction.
  /// The ramp is a chart series — confidence is encoded in hue — and painted
  /// raw its confident end drew solid green over a red-night preview. `paint`
  /// lerps per track, so the remap has to happen before the loop.
  final Color lowConfidenceColor;
  final Color highConfidenceColor;

  ScienceMovingTrackOverlayPainter({
    required this.tracks,
    required this.imageOffset,
    required this.zoomLevel,
    required SkotiqColors colors,
  })  : lowConfidenceColor =
            SkotiqChartColors.forTheme(namedTrackLowConfidence, colors),
        highConfidenceColor =
            SkotiqChartColors.forTheme(namedTrackHighConfidence, colors);

  @override
  void paint(Canvas canvas, Size size) {
    if (tracks.isEmpty) {
      return;
    }

    for (final track in tracks) {
      final x = track.imageX * zoomLevel + imageOffset.dx;
      final y = track.imageY * zoomLevel + imageOffset.dy;
      if (x < -120 ||
          x > size.width + 120 ||
          y < -120 ||
          y > size.height + 120) {
        continue;
      }

      final confidenceColor = Color.lerp(
        lowConfidenceColor,
        highConfidenceColor,
        track.confidence.clamp(0.0, 1.0),
      )!;

      final trailLength =
          (8.0 + track.motionArcsecPerMinute * 1.8).clamp(8.0, 44.0).toDouble();
      final paRad = track.positionAngleDegrees * math.pi / 180.0;
      final dx = math.sin(paRad) * trailLength;
      final dy = -math.cos(paRad) * trailLength;
      final start = Offset(x - dx * 0.45, y - dy * 0.45);
      final end = Offset(x + dx * 0.55, y + dy * 0.55);

      final linePaint = Paint()
        ..color = confidenceColor.withValues(alpha: 0.86)
        ..strokeWidth = 1.6
        ..style = PaintingStyle.stroke;
      final pointPaint = Paint()
        ..color = confidenceColor.withValues(alpha: 0.95)
        ..style = PaintingStyle.fill;

      canvas.drawLine(start, end, linePaint);
      canvas.drawCircle(end, 2.2, pointPaint);
      canvas.drawCircle(
        Offset(x, y),
        3.6,
        Paint()
          // absolute: track point outline over the image canvas
          ..color = Colors.black.withValues(alpha: 0.35)
          ..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        Offset(x, y),
        2.0,
        pointPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant ScienceMovingTrackOverlayPainter oldDelegate) {
    return tracks != oldDelegate.tracks ||
        imageOffset != oldDelegate.imageOffset ||
        zoomLevel != oldDelegate.zoomLevel ||
        lowConfidenceColor != oldDelegate.lowConfidenceColor;
  }
}

/// Compass overlay showing N/E cardinal directions based on plate solve rotation.
///
/// Draws a semi-transparent circle with rotated N and E arrows in the
/// bottom-right corner. The rotation angle comes from WCS plate solve data,
