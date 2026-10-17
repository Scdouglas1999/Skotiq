part of '../interactive_sky_view.dart';

/// Angular-measurement overlay: a ruler between two sky points showing their
/// great-circle separation and the position angle of the end point as seen
/// from the start (North-through-East convention).
///
/// The endpoints are stored as celestial coordinates so the ruler stays pinned
/// to the sky as the user pans or zooms — each paint re-projects them through
/// the shared [SkyFovProjector], the same projection the sky painter uses, so
/// the drawn line always lands exactly where the user dragged.
///
/// This is a pure overlay painter. It is mounted on the animated overlay
/// RepaintBoundary, so drawing/clearing the ruler never repaints the expensive
/// static base layer.
class _MeasurementOverlayPainter extends CustomPainter {
  final SkyViewState viewState;
  final CelestialCoordinate start;
  final CelestialCoordinate end;

  /// Local sidereal time (hours) at the current epoch, required to project in
  /// the horizontal view frame. Null in the equatorial frame.
  final double? lstHours;

  /// Observer latitude (degrees), required for the horizontal-frame projection.
  final double latitude;

  static const Color _lineColor = Color(0xFF7DD3FC); // sky-300, schematic cyan

  _MeasurementOverlayPainter({
    required this.viewState,
    required this.start,
    required this.end,
    required this.lstHours,
    required this.latitude,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final scale =
        math.min(size.width, size.height) / 2 / (viewState.fieldOfView / 2);

    final p1 = _project(start, center, scale);
    final p2 = _project(end, center, scale);
    if (p1 == null || p2 == null) return;

    final separationDeg = AstronomyCalculations.angularSeparation(
      ra1Deg: start.ra * 15,
      dec1Deg: start.dec,
      ra2Deg: end.ra * 15,
      dec2Deg: end.dec,
    );
    final positionAngleDeg = AstronomyCalculations.positionAngle(
      ra1Deg: start.ra * 15,
      dec1Deg: start.dec,
      ra2Deg: end.ra * 15,
      dec2Deg: end.dec,
    );

    // Connecting line.
    final linePaint = Paint()
      ..color = _lineColor
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawLine(p1, p2, linePaint);

    // End-point markers (small tick rings).
    final markerPaint = Paint()
      ..color = _lineColor
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(p1, 4, markerPaint);
    canvas.drawCircle(p2, 4, markerPaint);

    _paintReadout(
      canvas,
      size: size,
      anchor: p2,
      separationDeg: separationDeg,
      positionAngleDeg: positionAngleDeg,
    );
  }

  /// Project a celestial coordinate through the shared [SkyFovProjector], the
  /// same projection the sky painter and the FOV overlays use.
  ///
  /// Hardcoding one projection branch here would leave the ruler drifting away
  /// from the stars it is drawn between: numerically right, pointing at the
  /// wrong pair of objects.
  Offset? _project(CelestialCoordinate coord, Offset center, double scale) {
    return SkyFovProjector(
      viewState: viewState,
      screenCenter: center,
      pixelsPerDegree: scale,
      latitude: latitude,
      lstHours: lstHours,
    ).project(coord);
  }

  void _paintReadout(
    Canvas canvas, {
    required Size size,
    required Offset anchor,
    required double separationDeg,
    required double positionAngleDeg,
  }) {
    final textPainter = TextPainter(
      text: TextSpan(
        text:
            '${_formatSeparation(separationDeg)}\n'
            'PA ${positionAngleDeg.toStringAsFixed(1)}°',
        style: const TextStyle(
          color: _lineColor,
          fontSize: 11,
          fontWeight: FontWeight.w500,
          height: 1.3,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();

    // Place the readout offset from the end marker, then nudge it back inside
    // the canvas so a measurement near the right/bottom edge stays readable.
    const pad = 6.0;
    final boxWidth = textPainter.width + pad * 2;
    final boxHeight = textPainter.height + pad * 2;
    var origin = Offset(anchor.dx + 10, anchor.dy + 10);
    if (origin.dx - pad + boxWidth > size.width) {
      origin = Offset(size.width - boxWidth + pad, origin.dy);
    }
    if (origin.dx - pad < 0) {
      origin = Offset(pad, origin.dy);
    }
    if (origin.dy - pad + boxHeight > size.height) {
      origin = Offset(origin.dx, size.height - boxHeight + pad);
    }
    if (origin.dy - pad < 0) {
      origin = Offset(origin.dx, pad);
    }
    final bg = Rect.fromLTWH(
      origin.dx - pad,
      origin.dy - pad,
      boxWidth,
      boxHeight,
    );

    final bgPaint = Paint()..color = const Color(0xCC0B1622);
    canvas.drawRRect(
      RRect.fromRectAndRadius(bg, const Radius.circular(4)),
      bgPaint,
    );
    final borderPaint = Paint()
      ..color = _lineColor.withValues(alpha: 0.4)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    canvas.drawRRect(
      RRect.fromRectAndRadius(bg, const Radius.circular(4)),
      borderPaint,
    );

    textPainter.paint(canvas, origin);
  }

  /// Format an angular separation with the most readable unit: degrees for
  /// wide spans, arcminutes for sub-degree, arcseconds for very tight pairs.
  static String _formatSeparation(double degrees) {
    if (degrees >= 1.0) {
      return '${degrees.toStringAsFixed(2)}°';
    }
    final arcmin = degrees * 60;
    if (arcmin >= 1.0) {
      return "${arcmin.toStringAsFixed(1)}'";
    }
    final arcsec = degrees * 3600;
    return '${arcsec.toStringAsFixed(1)}"';
  }

  @override
  bool shouldRepaint(covariant _MeasurementOverlayPainter oldDelegate) {
    return viewState != oldDelegate.viewState ||
        start != oldDelegate.start ||
        end != oldDelegate.end ||
        lstHours != oldDelegate.lstHours ||
        latitude != oldDelegate.latitude;
  }
}
