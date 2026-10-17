// ignore_for_file: unused_element, unused_field

part of '../sky_renderer.dart';

extension _SkyCanvasPainterSmallBodies on SkyCanvasPainter {
  /// Draw satellites as bright moving dots with labels.
  void _drawSatellites(Canvas canvas, Size size, Offset center, double scale) {
    const satelliteColor = Color(0xFFFFD740); // Amber/gold
    const eclipsedColor = Color(0x80FF6E40); // Dim orange for eclipsed

    for (final sat in satellites) {
      final coord = CelestialCoordinate(ra: sat.ra, dec: sat.dec);
      final offset = _celestialToScreen(coord, center, scale);
      if (offset == null) continue;
      if (!_isInView(offset, size)) continue;

      final color = sat.isEclipsed ? eclipsedColor : satelliteColor;
      final isIss = sat.name.contains('ISS') || sat.name.contains('ZARYA');
      final dotRadius = isIss ? 4.0 : 2.5;

      // Glow for illuminated satellites
      if (!sat.isEclipsed) {
        if (qualityConfig.useBlurEffects) {
          final glowPaint = _PaintCache.getBlurPaint(4, color, alpha: 0.4);
          canvas.drawCircle(offset, dotRadius + 3, glowPaint);
        } else {
          final glowPaint = Paint()..color = color.withValues(alpha: 0.3);
          canvas.drawCircle(offset, dotRadius + 3, glowPaint);
        }
      }

      // Main dot
      final dotPaint = Paint()
        ..color = color
        ..style = PaintingStyle.fill;
      canvas.drawCircle(offset, dotRadius, dotPaint);

      // Cross-hair for ISS
      if (isIss && !sat.isEclipsed) {
        final crossPaint = Paint()
          ..color = color.withValues(alpha: 0.6)
          ..strokeWidth = 1.0
          ..style = PaintingStyle.stroke;
        const crossSize = 8.0;
        canvas.drawLine(
          Offset(offset.dx - crossSize, offset.dy),
          Offset(offset.dx + crossSize, offset.dy),
          crossPaint,
        );
        canvas.drawLine(
          Offset(offset.dx, offset.dy - crossSize),
          Offset(offset.dx, offset.dy + crossSize),
          crossPaint,
        );
      }

      // Label for ISS and bright satellites above horizon
      if ((isIss || sat.elevation > 20) && !sat.isEclipsed) {
        final labelText = isIss ? 'ISS' : sat.name;
        final truncatedLabel = labelText.length > 16
            ? '${labelText.substring(0, 14)}..'
            : labelText;
        final textStyle = TextStyle(
          color: color.withValues(alpha: 0.9),
          fontSize: isIss ? 11.0 : 9.0,
          fontWeight: isIss ? FontWeight.w600 : FontWeight.w400,
        );
        final textPainter = TextPainter(
          text: TextSpan(text: truncatedLabel, style: textStyle),
          textDirection: TextDirection.ltr,
        );
        textPainter.layout();

        final preferredPos =
            offset + Offset(-textPainter.width / 2, dotRadius + 4);
        final labelPos = _labelManager.findPlacement(
          preferredPos,
          Size(textPainter.width, textPainter.height),
          size,
        );
        if (labelPos != null) {
          textPainter.paint(canvas, labelPos);
        }
      }
    }
  }

  /// Draw variable stars with distinctive double-ring markers.
  void _drawVariableStars(
    Canvas canvas,
    Size size,
    Offset center,
    double scale,
  ) {
    const varColor = Color(0xFF40C4FF); // Light blue for variable markers

    for (final vs in variableStars) {
      final coord = vs.coordinates;
      final offset = _celestialToScreen(coord, center, scale);
      if (offset == null) continue;
      if (!_isInView(offset, size)) continue;

      final estMag = vs.estimateMagnitude(observationTime);
      final magRange = vs.magMin - vs.magMax;
      final brightnessFraction = magRange > 0
          ? ((vs.magMin - estMag) / magRange).clamp(0.0, 1.0)
          : 0.5;

      // Outer ring (fixed size, bigger for brighter stars)
      final outerRadius = 5.0 + (8.0 - vs.magMax).clamp(0.0, 4.0);
      final outerPaint = Paint()
        ..color = varColor.withValues(alpha: 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2;
      canvas.drawCircle(offset, outerRadius, outerPaint);

      // Inner circle pulses based on current brightness
      final innerRadius = outerRadius * (0.3 + 0.5 * brightnessFraction);
      final innerPaint = Paint()
        ..color = varColor.withValues(alpha: 0.3 + 0.5 * brightnessFraction)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(offset, innerRadius, innerPaint);

      // Second outer ring
      final outerRing2Paint = Paint()
        ..color = varColor.withValues(alpha: 0.25)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8;
      canvas.drawCircle(offset, outerRadius + 2.5, outerRing2Paint);

      // Label for bright variables (magMax < 5)
      if (vs.magMax < 5.0) {
        final labelText = vs.name.length > 14
            ? '${vs.name.substring(0, 12)}..'
            : vs.name;
        final textStyle = TextStyle(
          color: varColor.withValues(alpha: 0.85),
          fontSize: 9.0,
          fontWeight: FontWeight.w400,
        );
        final tp = TextPainter(
          text: TextSpan(text: labelText, style: textStyle),
          textDirection: TextDirection.ltr,
        );
        tp.layout();
        final preferredPos = offset + Offset(-tp.width / 2, outerRadius + 5);
        final labelPos = _labelManager.findPlacement(
          preferredPos,
          Size(tp.width, tp.height),
          size,
        );
        if (labelPos != null) {
          tp.paint(canvas, labelPos);
        }
      }
    }
  }

  /// Draw minor planets (asteroids as diamonds, comets with fuzzy tail).
  void _drawMinorPlanets(
    Canvas canvas,
    Size size,
    Offset center,
    double scale,
  ) {
    const asteroidColor = Color(0xFFBCAAA4);
    const cometColor = Color(0xFF81D4FA);

    for (final body in minorPlanets) {
      if (body.visualMag > 14.0) continue;

      final coord = body.coordinates;
      final offset = _celestialToScreen(coord, center, scale);
      if (offset == null) continue;
      if (!_isInView(offset, size)) continue;

      final isBright = body.visualMag < 10.0;

      if (body.isComet) {
        // Comet: fuzzy coma + tail
        final comaRadius = isBright ? 5.0 : 3.0;
        if (qualityConfig.useBlurEffects) {
          final comaPaint = _PaintCache.getBlurPaint(3, cometColor, alpha: 0.3);
          canvas.drawCircle(offset, comaRadius + 2, comaPaint);
        } else {
          canvas.drawCircle(
            offset,
            comaRadius + 2,
            Paint()..color = cometColor.withValues(alpha: 0.2),
          );
        }
        canvas.drawCircle(
          offset,
          comaRadius * 0.6,
          Paint()..color = cometColor.withValues(alpha: isBright ? 0.8 : 0.5),
        );

        // Tail (anti-sunward, simplified as upper-right)
        final tailLen = isBright ? 18.0 : 10.0;
        final tailEnd = Offset(
          offset.dx + tailLen * 0.7,
          offset.dy - tailLen * 0.7,
        );
        canvas.drawLine(
          offset,
          tailEnd,
          Paint()
            ..shader = ui.Gradient.linear(offset, tailEnd, [
              cometColor.withValues(alpha: 0.4),
              cometColor.withValues(alpha: 0.0),
            ])
            ..strokeWidth = isBright ? 3.0 : 2.0
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round,
        );
        // Dust tail
        final dustEnd = Offset(
          offset.dx + tailLen * 0.5,
          offset.dy - tailLen * 0.9,
        );
        canvas.drawLine(
          offset,
          dustEnd,
          Paint()
            ..shader = ui.Gradient.linear(offset, dustEnd, [
              cometColor.withValues(alpha: 0.2),
              cometColor.withValues(alpha: 0.0),
            ])
            ..strokeWidth = isBright ? 5.0 : 3.0
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round,
        );

        if (body.visualMag < 10.0) {
          _drawMinorPlanetLabel(
            canvas,
            offset,
            body.name,
            comaRadius + 5,
            size,
            cometColor,
          );
        }
      } else {
        // Asteroid: diamond shape
        final ds = isBright ? 4.0 : 2.5;
        final path = Path()
          ..moveTo(offset.dx, offset.dy - ds)
          ..lineTo(offset.dx + ds, offset.dy)
          ..lineTo(offset.dx, offset.dy + ds)
          ..lineTo(offset.dx - ds, offset.dy)
          ..close();
        canvas.drawPath(
          path,
          Paint()
            ..color = asteroidColor.withValues(alpha: isBright ? 0.9 : 0.6),
        );
        canvas.drawPath(
          path,
          Paint()
            ..color = asteroidColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.8,
        );

        if (body.visualMag < 9.0) {
          _drawMinorPlanetLabel(
            canvas,
            offset,
            body.name,
            ds + 4,
            size,
            asteroidColor,
          );
        }
      }
    }
  }

  void _drawMinorPlanetLabel(
    Canvas canvas,
    Offset offset,
    String name,
    double yOffset,
    Size size,
    Color color,
  ) {
    final labelText = name.length > 14 ? '${name.substring(0, 12)}..' : name;
    final tp = TextPainter(
      text: TextSpan(
        text: labelText,
        style: TextStyle(color: color.withValues(alpha: 0.85), fontSize: 9.0),
      ),
      textDirection: TextDirection.ltr,
    );
    tp.layout();
    final preferredPos = offset + Offset(-tp.width / 2, yOffset);
    final labelPos = _labelManager.findPlacement(
      preferredPos,
      Size(tp.width, tp.height),
      size,
    );
    if (labelPos != null) {
      tp.paint(canvas, labelPos);
    }
  }
}
