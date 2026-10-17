// ignore_for_file: unused_element, unused_field

part of '../sky_renderer.dart';

extension _SkyCanvasPainterSolarBodies on SkyCanvasPainter {
  void _drawSun(Canvas canvas, Size size, Offset center, double scale) {
    if (sunPosition == null) return;

    final (ra, dec) = sunPosition!;
    final coord = CelestialCoordinate(
      ra: ra / 15,
      dec: dec,
    ); // ra is in degrees, convert to hours
    final offset = _celestialToScreen(coord, center, scale);
    if (offset == null) return;

    const sunColor = Color(0xFFFFEB3B);

    // Outer glow
    _drawGlow(canvas, offset, 25, sunColor, 20.0, opacity: 0.25);

    // Mid glow
    _drawGlow(canvas, offset, 15, sunColor, 10.0, opacity: 0.5);

    // Sun disc (always drawn)
    final sunPaint = Paint()
      ..color = sunColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(offset, 10, sunPaint);

    // Sun label
    const textStyle = TextStyle(
      color: sunColor,
      fontSize: 10,
      fontWeight: FontWeight.bold,
    );
    final textPainter = TextPainter(
      text: const TextSpan(text: 'SUN', style: textStyle),
      textDirection: ui.TextDirection.ltr,
    );
    textPainter.layout();
    // Reserve space like every other label pass. Painting this one blind is
    // what produced the "JUPISUNER" overstrike whenever the Sun and a planet
    // were close together on screen — a routine occurrence, since the planets
    // never stray far from the ecliptic.
    final labelPos = _labelManager.findPlacement(
      offset + Offset(-textPainter.width / 2, 18),
      Size(textPainter.width, textPainter.height),
      size,
    );
    if (labelPos != null) {
      textPainter.paint(canvas, labelPos);
    }
  }

  void _drawMoon(Canvas canvas, Size size, Offset center, double scale) {
    if (moonPosition == null) return;

    final (ra, dec, rawIlluminationPercent) = moonPosition!;
    // The tuple carries a PERCENT (see SkyCanvasPainter.moonPosition); the
    // terminator geometry and the `illumination >= 0.5` lit/dark test below are
    // both in fractions. Converting once here is the only place the two units
    // meet. Sanitised at the same time so neither the phase geometry nor the
    // label can be fed a NaN or an out-of-range value from upstream ephemeris.
    final illumination = rawIlluminationPercent.isFinite
        ? (rawIlluminationPercent / 100).clamp(0.0, 1.0)
        : 0.0;
    final coord = CelestialCoordinate(
      ra: ra / 15,
      dec: dec,
    ); // ra is in degrees, convert to hours
    final offset = _celestialToScreen(coord, center, scale);
    if (offset == null) return;

    // Moon apparent diameter ~31 arcminutes (0.517 degrees)
    // Scale with zoom so it appears correct relative to the sky
    const apparentSizeDeg = 31.0 / 60.0;
    final moonPixelRadius = (apparentSizeDeg / 2) * scale;
    final moonRadius = moonPixelRadius.clamp(8.0, 80.0);

    // Glow scaled to moon size
    final glowRadius = moonRadius * 1.6;
    if (qualityConfig.useBlurEffects) {
      final glowPaint = _PaintCache.getBlurPaint(
        moonRadius * 0.8,
        const Color(0xFFB0BEC5),
        alpha: 0.19,
      );
      canvas.drawCircle(offset, glowRadius, glowPaint);
    } else {
      final glowPaint = Paint()..color = const Color(0x30B0BEC5);
      canvas.drawCircle(offset, glowRadius, glowPaint);
    }

    // Moon base (dark side)
    final darkPaint = Paint()
      ..color = const Color(0xFF37474F)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(offset, moonRadius, darkPaint);

    // Phase rendering. illumination: 0 = new moon, 1 = full moon (fraction).
    final litPaint = Paint()
      ..color = const Color(0xFFECEFF1)
      ..style = PaintingStyle.fill;

    if (illumination > 0.01) {
      // The phase is drawn in a local frame whose +x axis is the bright limb,
      // then rotated so that limb faces the Sun. Without the rotation the lune
      // is pinned to one screen side and is simply wrong for most of the month.
      // Falls back to a left-lit orientation when the Sun position is unknown
      // or the local sky frame cannot be probed.
      final limbAngle = moonBrightLimbScreenAngle(size) ?? math.pi;

      canvas.save();
      canvas.translate(offset.dx, offset.dy);
      canvas.rotate(limbAngle);

      final disc = Rect.fromCircle(center: Offset.zero, radius: moonRadius);
      canvas.clipPath(Path()..addOval(disc));

      // Lit hemisphere: the half-disc on the bright-limb side.
      canvas.drawArc(disc, -math.pi / 2, math.pi, true, litPaint);

      // The terminator ellipse is centred on the Moon (it is the projection of
      // a great circle through the disc's centre, so it cannot hug a limb).
      // Painting it lit past first quarter grows the half-disc into a gibbous
      // phase; painting it dark before first quarter carves it into a crescent.
      final semiMinor =
          moonRadius *
          MoonPhaseGeometry.terminatorSemiAxisFraction(illumination);
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset.zero,
          width: semiMinor * 2,
          height: moonRadius * 2,
        ),
        illumination >= 0.5 ? litPaint : darkPaint,
      );

      canvas.restore();
    }

    // Moon outline
    final outlinePaint = Paint()
      ..color = const Color(0x60ECEFF1)
      ..style = PaintingStyle.stroke
      ..strokeWidth = moonRadius > 20 ? 1.5 : 1.0;
    canvas.drawCircle(offset, moonRadius, outlinePaint);

    // Moon label with illumination %
    final illuminationPct = (illumination * 100).round();
    final labelStyle = TextStyle(
      color: const Color(0xFFB0BEC5),
      fontSize: moonRadius > 20 ? 11 : 10,
      fontWeight: FontWeight.w500,
    );
    final textPainter = _TextCache.get('MOON $illuminationPct%', labelStyle);
    final preferredPos =
        offset + Offset(-textPainter.width / 2, moonRadius + 6);
    final labelPos = _labelManager.findPlacement(
      preferredPos,
      Size(textPainter.width, textPainter.height),
      size,
    );
    if (labelPos != null) {
      textPainter.paint(canvas, labelPos);
    }
  }

  void _drawPlanets(Canvas canvas, Size size, Offset center, double scale) {
    for (final planet in planets) {
      // PlanetData has ra in hours and dec in degrees
      final coord = CelestialCoordinate(ra: planet.ra, dec: planet.dec);
      final offset = _celestialToScreen(coord, center, scale);
      if (offset == null) continue;

      // Convert int color to Color
      final planetColor = Color(planet.color);

      // Planet glow - use cached blur
      if (qualityConfig.useBlurEffects) {
        final glowPaint = _PaintCache.getBlurPaint(6, planetColor, alpha: 0.3);
        canvas.drawCircle(offset, 8, glowPaint);
      } else {
        final glowPaint = Paint()..color = planetColor.withValues(alpha: 0.3);
        canvas.drawCircle(offset, 8, glowPaint);
      }

      // Planet disc - size based on magnitude
      final radius = _magnitudeToRadius(planet.magnitude) * 1.5 + 2;
      final planetPaint = Paint()
        ..color = planetColor
        ..style = PaintingStyle.fill;
      canvas.drawCircle(offset, radius, planetPaint);

      // Add planet-specific details in quality mode
      if (qualityConfig.enablePlanetDetails && radius > 3) {
        _drawPlanetDetails(canvas, offset, radius, planet.name, planetColor);
      }

      // Planet label with collision avoidance
      final fontSize = _getLabelFontSize(planet.magnitude, 'planet');
      final textStyle = TextStyle(
        color: planetColor,
        fontSize: fontSize,
        fontWeight: FontWeight.w600, // Planets always prominent
      );
      final textPainter = TextPainter(
        text: TextSpan(text: planet.name.toUpperCase(), style: textStyle),
        textDirection: ui.TextDirection.ltr,
      );
      textPainter.layout();

      // Find non-overlapping placement (preferred below planet)
      final preferredPos = offset + Offset(-textPainter.width / 2, radius + 4);
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

  /// Draw planet-specific details (Saturn rings, Jupiter bands)
  void _drawPlanetDetails(
    Canvas canvas,
    Offset center,
    double radius,
    String planetName,
    Color planetColor,
  ) {
    final name = planetName.toLowerCase();

    if (name == 'saturn') {
      _drawSaturnRings(canvas, center, radius, planetColor);
    } else if (name == 'jupiter') {
      _drawJupiterBands(canvas, center, radius, planetColor);
    } else if (name == 'mars') {
      _drawMarsPolarCap(canvas, center, radius);
    }
  }

  /// Draw Saturn's iconic ring system
  void _drawSaturnRings(
    Canvas canvas,
    Offset center,
    double radius,
    Color planetColor,
  ) {
    // Ring ellipse surrounding the planet
    final ringWidth = radius * 2.8;
    final ringHeight = radius * 0.8; // Tilted view

    // Outer ring (A ring)
    final outerRingPaint = Paint()
      ..color = const Color(0xFFD4C8A8).withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = radius * 0.15;
    canvas.drawOval(
      Rect.fromCenter(center: center, width: ringWidth, height: ringHeight),
      outerRingPaint,
    );

    // Inner ring (B ring - brighter)
    final innerRingPaint = Paint()
      ..color = const Color(0xFFE8DCC0).withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = radius * 0.2;
    canvas.drawOval(
      Rect.fromCenter(
        center: center,
        width: ringWidth * 0.75,
        height: ringHeight * 0.75,
      ),
      innerRingPaint,
    );

    // Cassini Division (dark gap)
    final divisionPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = radius * 0.05;
    canvas.drawOval(
      Rect.fromCenter(
        center: center,
        width: ringWidth * 0.82,
        height: ringHeight * 0.82,
      ),
      divisionPaint,
    );

    // Redraw planet disc on top of back-side ring portion
    final planetPaint = Paint()
      ..color = planetColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius, planetPaint);
  }

  /// Draw Jupiter's cloud bands
  void _drawJupiterBands(
    Canvas canvas,
    Offset center,
    double radius,
    Color planetColor,
  ) {
    // Subtle horizontal bands
    final bandPaint = Paint()
      ..color = const Color(0xFF8B6914).withValues(alpha: 0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = radius * 0.15;

    // Draw 3 bands at different latitudes
    for (final offset in [-0.5, 0.0, 0.5]) {
      final bandY = center.dy + radius * offset * 0.7;
      final bandWidth = radius * math.sqrt(1 - offset * offset * 0.5);

      canvas.drawLine(
        Offset(center.dx - bandWidth, bandY),
        Offset(center.dx + bandWidth, bandY),
        bandPaint,
      );
    }

    // Great Red Spot hint for larger renderings
    if (radius > 5) {
      final spotPaint = Paint()
        ..color = const Color(0xFFB86B4A).withValues(alpha: 0.4);
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(center.dx + radius * 0.3, center.dy + radius * 0.25),
          width: radius * 0.4,
          height: radius * 0.25,
        ),
        spotPaint,
      );
    }
  }

  /// Draw Mars polar ice cap hint
  void _drawMarsPolarCap(Canvas canvas, Offset center, double radius) {
    // Small white cap at the top
    final capPaint = Paint()..color = Colors.white.withValues(alpha: 0.5);

    final capPath = Path();
    capPath.moveTo(center.dx - radius * 0.4, center.dy - radius * 0.7);
    capPath.quadraticBezierTo(
      center.dx,
      center.dy - radius * 1.1,
      center.dx + radius * 0.4,
      center.dy - radius * 0.7,
    );
    capPath.close();

    canvas.drawPath(capPath, capPaint);
  }
}
